use std::collections::BTreeMap;
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use gio::prelude::InetSocketAddressExt;
use gio::{InetSocketAddress, SocketAddress};
use glib::object::Cast;
use glib::prelude::StaticType;
use glib::value::ToValue;
use gst::prelude::*;
use gstreamer as gst;
use serde::Deserialize;
use serde_json::{Map, Value};

#[derive(Debug, Clone, Deserialize)]
struct PipelineConfig {
    source: ElementConfig,
    sinks: Vec<ElementConfig>,
}

#[derive(Debug, Clone, Deserialize)]
struct ElementConfig {
    #[serde(rename = "type")]
    element_type: String,
    #[serde(flatten)]
    props: BTreeMap<String, Value>,
}

trait StatsWriter: Send {
    fn send_message(&mut self, message: &str) -> Result<()>;
}

#[derive(Debug)]
struct StdoutWriter {
    stdout: io::Stdout,
}

impl StdoutWriter {
    fn new() -> Self {
        Self {
            stdout: io::stdout(),
        }
    }
}

impl StatsWriter for StdoutWriter {
    fn send_message(&mut self, message: &str) -> Result<()> {
        self.stdout
            .write_all(message.as_bytes())
            .context("failed to write message to stdout")?;
        self.stdout
            .write_all(b"\n")
            .context("failed to write newline to stdout")?;
        self.stdout.flush().context("failed to flush stdout")?;
        Ok(())
    }
}

#[derive(Debug)]
struct DestMetrics {
    id: Option<String>,
    name: Option<String>,
    schema: Option<String>,
    kind: String,
    bytes_total: AtomicU64,
    bytes_last_interval: AtomicU64,
    bytes_per_sec: AtomicU64,
    sink_element: Option<gst::Element>,
}

#[derive(Debug)]
struct PipelineRuntime {
    pipeline: gst::Pipeline,
    loop_: glib::MainLoop,
    source: gst::Element,
    source_bytes_total: Arc<AtomicU64>,
    source_bytes_last_interval: Arc<AtomicU64>,
    source_bytes_per_sec: Arc<AtomicU64>,
    dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>>,
    running: Arc<AtomicBool>,
}

fn main() -> Result<()> {
    std::env::set_var("GST_REGISTRY_FORK", "no");
    gst::init().context("failed to initialize gstreamer")?;

    let route_id = std::env::args().nth(1);
    let stdin = io::stdin();
    let mut line = String::new();
    stdin
        .lock()
        .read_line(&mut line)
        .context("failed to read pipeline json from stdin")?;

    if line.trim().is_empty() {
        bail!("empty pipeline json from stdin");
    }

    let config: PipelineConfig =
        serde_json::from_str(&line).context("failed to parse pipeline config json")?;

    let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
        Arc::new(Mutex::new(Box::new(StdoutWriter::new())));
    if let Some(route_id) = route_id.as_deref() {
        writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?
            .send_message(&format!("route_id:{route_id}"))?;
    }

    let runtime = build_pipeline(config, writer.clone())?;
    start_stats_loop(&runtime, writer);

    let bus = runtime
        .pipeline
        .bus()
        .ok_or_else(|| anyhow!("pipeline has no bus"))?;

    let main_loop = runtime.loop_.clone();
    let pipeline_obj = runtime.pipeline.clone().upcast::<gst::Object>();
    let _bus_watch = bus
        .add_watch(move |_bus, msg| {
            use gst::MessageView;

            match msg.view() {
                MessageView::Error(err) => {
                    eprintln!("Error: {}", err.error());
                    main_loop.quit();
                }
                MessageView::StateChanged(state)
                    if msg
                        .src()
                        .map(|src| *src == pipeline_obj)
                        .unwrap_or(false) =>
                {
                    println!(
                        "Pipeline state changed from {} to {}",
                        format!("{:?}", state.old()),
                        format!("{:?}", state.current())
                    );
                }
                MessageView::Element(element) => {
                    if let Some(structure) = element.structure() {
                        if structure.name() == "GstSRTObject" {
                            println!("SRT Event: {}", structure.to_string());
                        }
                    }
                }
                _ => {}
            }

            glib::ControlFlow::Continue
        })
        .context("failed to attach bus watch")?;

    runtime
        .pipeline
        .set_state(gst::State::Playing)
        .context("failed to set pipeline to playing")?;

    runtime.loop_.run();

    runtime.running.store(false, Ordering::Relaxed);
    runtime
        .pipeline
        .set_state(gst::State::Null)
        .context("failed to set pipeline to null")?;

    Ok(())
}

fn build_pipeline(
    config: PipelineConfig,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<PipelineRuntime> {
    let pipeline = gst::Pipeline::new();
    let source = gst::ElementFactory::make(&config.source.element_type)
        .build()
        .with_context(|| format!("failed to create source {}", config.source.element_type))?;
    let tee = gst::ElementFactory::make("tee")
        .build()
        .context("failed to create tee")?;

    tee.set_property("allow-not-linked", true);
    apply_element_properties(&source, &config.source)?;

    if source.find_property("do-timestamp").is_some() {
        source.set_property("do-timestamp", true);
    }

    let source_stream_id = Arc::new(Mutex::new(None));
    if config.source.element_type == "srtsrc" {
        let has_stream_id = config
            .source
            .props
            .get("streamid")
            .and_then(Value::as_str)
            .map(|value| !value.is_empty())
            .unwrap_or(false);

        source.set_property("authentication", has_stream_id);

        let source_stream_id_ref = source_stream_id.clone();
        let writer_ref = writer.clone();
        source.connect("caller-connecting", false, move |values| {
            let stream_id = values
                .get(2)
                .and_then(|value| value.get::<Option<String>>().ok())
                .flatten();

            if let Some(stream_id) = stream_id {
                if let Ok(mut guard) = source_stream_id_ref.lock() {
                    *guard = Some(stream_id.clone());
                }

                if let Ok(mut guard) = writer_ref.lock() {
                    let _ = guard.send_message(&format!("stats_source_stream_id:{stream_id}"));
                }
            }

            Some(true.to_value())
        });
    }

    pipeline
        .add_many([&source, &tee])
        .context("failed to add source/tee to pipeline")?;
    source
        .link(&tee)
        .context("failed to link source to tee")?;

    let source_bytes_total = Arc::new(AtomicU64::new(0));
    let source_bytes_last_interval = Arc::new(AtomicU64::new(0));
    let source_bytes_per_sec = Arc::new(AtomicU64::new(0));
    let dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>> = Arc::new(Mutex::new(Vec::new()));

    if let Some(src_pad) = source.static_pad("src") {
        let bytes_counter = source_bytes_total.clone();
        src_pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
            if let Some(buffer) = info.buffer() {
                bytes_counter.fetch_add(buffer.size() as u64, Ordering::Relaxed);
            }
            gst::PadProbeReturn::Ok
        });
    }

    for sink in config.sinks {
        add_sink_to_pipeline(&pipeline, &tee, sink, dest_metrics.clone())?;
    }

    Ok(PipelineRuntime {
        pipeline,
        loop_: glib::MainLoop::new(None, false),
        source,
        source_bytes_total,
        source_bytes_last_interval,
        source_bytes_per_sec,
        dest_metrics,
        running: Arc::new(AtomicBool::new(true)),
    })
}

fn add_sink_to_pipeline(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    sink_config: ElementConfig,
    dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>>,
) -> Result<()> {
    let queue = gst::ElementFactory::make("queue")
        .build()
        .context("failed to create queue")?;
    let sink_element = gst::ElementFactory::make(&sink_config.element_type)
        .build()
        .with_context(|| format!("failed to create sink {}", sink_config.element_type))?;

    queue.set_property("max-size-buffers", 200_u32);
    queue.set_property("max-size-time", 0_u64);

    apply_element_properties(&sink_element, &sink_config)?;

    if sink_config.element_type == "udpsink" {
        sink_element.set_property("sync", false);
        sink_element.set_property("async", false);
    }

    if sink_config.element_type == "srtsink" {
        sink_element.set_property("sync", false);
        sink_element.set_property("async", false);
        sink_element.set_property("wait-for-connection", true);
    }

    pipeline
        .add_many([&queue, &sink_element])
        .context("failed to add sink elements to pipeline")?;
    gst::Element::link_many([tee, &queue, &sink_element]).context("failed to link sink branch")?;

    let metrics = Arc::new(DestMetrics {
        id: sink_config
            .props
            .get("hydra_destination_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        name: sink_config
            .props
            .get("hydra_destination_name")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        schema: sink_config
            .props
            .get("hydra_destination_schema")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        kind: sink_config.element_type.clone(),
        bytes_total: AtomicU64::new(0),
        bytes_last_interval: AtomicU64::new(0),
        bytes_per_sec: AtomicU64::new(0),
        sink_element: (sink_config.element_type == "srtsink").then_some(sink_element.clone()),
    });

    if let Some(src_pad) = queue.static_pad("src") {
        let metrics_ref = metrics.clone();
        src_pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
            if let Some(buffer) = info.buffer() {
                metrics_ref
                    .bytes_total
                    .fetch_add(buffer.size() as u64, Ordering::Relaxed);
            }
            gst::PadProbeReturn::Ok
        });
    }

    dest_metrics
        .lock()
        .map_err(|_| anyhow!("destination metrics mutex poisoned"))?
        .push(metrics);

    Ok(())
}

fn apply_element_properties(element: &gst::Element, config: &ElementConfig) -> Result<()> {
    if (config.element_type == "srtsrc" || config.element_type == "srtsink")
        && !config.props.contains_key("uri")
    {
        if let Some(uri) = build_srt_uri(&config.props) {
            element.set_property("uri", uri.as_str());
        }
    }

    for (key, value) in &config.props {
        if key == "type" || !element.has_property(key.as_str(), None) {
            continue;
        }

        let Some(prop) = element.find_property(key.as_str()) else {
            continue;
        };

        if config.element_type == "srtsrc" || config.element_type == "srtsink" {
            if key == "mode" {
                continue;
            }
        }

        if config.element_type == "udpsink" && key == "address" {
            if let Some(host) = value.as_str() {
                element.set_property("host", host);
            }
            continue;
        }

        match value {
            Value::Bool(v) => element.set_property(key.as_str(), *v),
            Value::Number(v) => {
                let value_type = prop.value_type();

                if value_type == u32::static_type() {
                    if let Some(uv) = v.as_u64().and_then(|n| u32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    } else if let Some(iv) = v.as_i64().and_then(|n| u32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    }
                } else if value_type == u64::static_type() {
                    if let Some(uv) = v.as_u64() {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    } else if let Some(iv) = v.as_i64().and_then(|n| u64::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    }
                } else if value_type == i32::static_type() || value_type.is_a(glib::Type::ENUM) {
                    if let Some(iv) = v.as_i64().and_then(|n| i32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    } else if let Some(uv) = v.as_u64().and_then(|n| i32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    }
                } else if value_type == i64::static_type() {
                    if let Some(iv) = v.as_i64() {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    } else if let Some(uv) = v.as_u64().and_then(|n| i64::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    }
                } else if value_type == f32::static_type() {
                    if let Some(fv) = v.as_f64() {
                        element.set_property_from_value(key.as_str(), &(fv as f32).to_value());
                    }
                } else if value_type == f64::static_type() {
                    if let Some(fv) = v.as_f64() {
                        element.set_property_from_value(key.as_str(), &fv.to_value());
                    }
                } else if let Some(iv) = v.as_i64().and_then(|n| i32::try_from(n).ok()) {
                    element.set_property_from_value(key.as_str(), &iv.to_value());
                }
            }
            Value::String(v) => element.set_property(key.as_str(), v.as_str()),
            _ => {}
        }
    }

    Ok(())
}

fn build_srt_uri(props: &BTreeMap<String, Value>) -> Option<String> {
    let mode = props
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("listener");

    let (host, port) = match mode {
        "caller" | "rendezvous" => {
            let host = props
                .get("address")
                .or_else(|| props.get("host"))
                .or_else(|| props.get("localaddress"))
                .and_then(Value::as_str)
                .unwrap_or("127.0.0.1");

            let port = props
                .get("port")
                .or_else(|| props.get("localport"))
                .and_then(Value::as_u64)?;

            (host, port)
        }
        _ => {
            let host = props
                .get("localaddress")
                .or_else(|| props.get("address"))
                .or_else(|| props.get("host"))
                .and_then(Value::as_str)
                .unwrap_or("127.0.0.1");

            let port = props
                .get("localport")
                .or_else(|| props.get("port"))
                .and_then(Value::as_u64)?;

            (host, port)
        }
    };

    let mut query = Vec::new();
    for key in ["mode", "passphrase", "pbkeylen", "poll-timeout"] {
        if let Some(value) = props.get(key) {
            match value {
                Value::String(s) if !s.is_empty() => query.push(format!("{key}={s}")),
                Value::Number(n) => query.push(format!("{key}={n}")),
                Value::Bool(b) => query.push(format!("{key}={b}")),
                _ => {}
            }
        }
    }

    let query = if query.is_empty() {
        String::new()
    } else {
        format!("?{}", query.join("&"))
    };

    Some(format!("srt://{host}:{port}{query}"))
}

fn start_stats_loop(runtime: &PipelineRuntime, writer: Arc<Mutex<Box<dyn StatsWriter>>>) {
    let source = runtime.source.clone();
    let running = runtime.running.clone();
    let source_bytes_total = runtime.source_bytes_total.clone();
    let source_bytes_last_interval = runtime.source_bytes_last_interval.clone();
    let source_bytes_per_sec = runtime.source_bytes_per_sec.clone();
    let dest_metrics = runtime.dest_metrics.clone();

    thread::spawn(move || {
        while running.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_secs(1));

            let current_total = source_bytes_total.load(Ordering::Relaxed);
            let last_total = source_bytes_last_interval.swap(current_total, Ordering::Relaxed);
            source_bytes_per_sec.store(current_total.saturating_sub(last_total), Ordering::Relaxed);

            let source_stats = source.property::<Option<gst::Structure>>("stats");

            let bytes_total = source_stats
                .as_ref()
                .and_then(|stats| stats.get::<u64>("bytes-received-total").ok())
                .unwrap_or(current_total);

            let mut root = Map::new();
            root.insert(
                "total-bytes-received".into(),
                Value::Number(bytes_total.into()),
            );

            let callers = source_stats
                .as_ref()
                .and_then(extract_callers_from_stats)
                .unwrap_or_default();
            root.insert("connected-callers".into(), Value::Number((callers.len() as u64).into()));
            root.insert("callers".into(), Value::Array(callers));

            let mut source_obj = Map::new();
            source_obj.insert("type".into(), Value::String(source.type_().name().to_string()));
            source_obj.insert(
                "bytes_in_total".into(),
                Value::Number(current_total.into()),
            );
            source_obj.insert(
                "bytes_in_per_sec".into(),
                Value::Number(source_bytes_per_sec.load(Ordering::Relaxed).into()),
            );
            if let Some(stats) = source_stats.as_ref() {
                source_obj.insert("srt".into(), structure_to_json(stats));
            }
            root.insert("source".into(), Value::Object(source_obj));

            let mut dests_json = Vec::new();
            if let Ok(guard) = dest_metrics.lock() {
                for dest in guard.iter() {
                    let total = dest.bytes_total.load(Ordering::Relaxed);
                    let last = dest.bytes_last_interval.swap(total, Ordering::Relaxed);
                    dest.bytes_per_sec
                        .store(total.saturating_sub(last), Ordering::Relaxed);

                    let mut dest_obj = Map::new();
                    if let Some(id) = &dest.id {
                        dest_obj.insert("id".into(), Value::String(id.clone()));
                    }
                    if let Some(name) = &dest.name {
                        dest_obj.insert("name".into(), Value::String(name.clone()));
                    }
                    if let Some(schema) = &dest.schema {
                        dest_obj.insert("schema".into(), Value::String(schema.clone()));
                    }
                    dest_obj.insert("type".into(), Value::String(dest.kind.clone()));
                    dest_obj.insert("bytes_out_total".into(), Value::Number(total.into()));
                    dest_obj.insert(
                        "bytes_out_per_sec".into(),
                        Value::Number(dest.bytes_per_sec.load(Ordering::Relaxed).into()),
                    );

                    if let Some(sink_element) = dest.sink_element.as_ref() {
                        let sink_stats = sink_element.property::<Option<gst::Structure>>("stats");
                        if let Some(sink_stats) = sink_stats.as_ref() {
                            dest_obj.insert("srt".into(), structure_to_json(sink_stats));
                        }
                    }

                    dests_json.push(Value::Object(dest_obj));
                }
            }
            root.insert("destinations".into(), Value::Array(dests_json));

            if let Ok(mut guard) = writer.lock() {
                let _ = guard.send_message(&Value::Object(root).to_string());
            }
        }
    });
}

fn extract_callers_from_stats(stats: &gst::Structure) -> Option<Vec<Value>> {
    let callers = stats.value("callers").ok()?;
    let array = callers.get::<glib::ValueArray>().ok()?;
    let mut out = Vec::new();

    for caller in array.iter() {
        if let Ok(structure) = caller.get::<gst::Structure>() {
            out.push(structure_to_json(&structure));
        }
    }

    Some(out)
}

fn structure_to_json(structure: &gst::Structure) -> Value {
    let mut obj = Map::new();

    for (field_name, value) in structure.iter() {
        if let Ok(v) = value.get::<bool>() {
            obj.insert(field_name.to_string(), Value::Bool(v));
            continue;
        }
        if let Ok(v) = value.get::<i32>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<u32>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<i64>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<u64>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<f64>() {
            if let Some(num) = serde_json::Number::from_f64(v) {
                obj.insert(field_name.to_string(), Value::Number(num));
            }
            continue;
        }
        if field_name == "caller-address" {
            if let Ok(address) = value.get::<SocketAddress>() {
                if let Ok(inet) = address.downcast::<InetSocketAddress>() {
                    let ip = inet.address().to_string();
                    let port = inet.port();
                    obj.insert(field_name.to_string(), Value::String(format!("{ip}:{port}")));
                }
            }
            continue;
        }
    }

    Value::Object(obj)
}
