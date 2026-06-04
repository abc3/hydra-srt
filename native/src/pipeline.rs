use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use serde_json::{json, Value};

use crate::config::{ElementConfig, PipelineConfig};
use crate::lifecycle::PipelineLifecycleEmitter;
use crate::output::StatsWriter;
use crate::properties::apply_element_properties;
use crate::runtime::{DestMetrics, PipelineRuntime};
use crate::srt_access::{caller_ip, SrtAccessRules};
use crate::thumbnail_scheduler::ThumbnailScheduler;

pub fn build_pipeline(
    config: PipelineConfig,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<PipelineRuntime> {
    let pipeline = gst::Pipeline::new();
    let lifecycle = PipelineLifecycleEmitter::new(writer.clone());
    let source = gst::ElementFactory::make(&config.source.element_type)
        .build()
        .with_context(|| format!("failed to create source {}", config.source.element_type))?;
    let tee = gst::ElementFactory::make("tee")
        .build()
        .context("failed to create tee")?;
    let source_schema = config
        .source
        .props
        .get("hydra_source_schema")
        .and_then(Value::as_str)
        .unwrap_or("");
    let is_rtp_source = source_schema == "RTP";

    tee.set_property("allow-not-linked", true);
    apply_element_properties(&source, &strip_internal_props(&config.source))?;

    if source.find_property("do-timestamp").is_some() {
        source.set_property("do-timestamp", true);
    }

    if is_rtp_source {
        let caps = gst::Caps::builder("application/x-rtp")
            .field("media", "video")
            .field("clock-rate", 90_000_i32)
            .field("encoding-name", "MP2T")
            .build();
        source.set_property("caps", caps);
    }

    if config.source.element_type == "srtsrc" {
        let access_rules = SrtAccessRules::from_props(&config.source.props);
        let has_stream_id = config
            .source
            .props
            .get("streamid")
            .and_then(Value::as_str)
            .map(|value| !value.is_empty())
            .unwrap_or(false);
        let authentication_requested = config
            .source
            .props
            .get("authentication")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        // GStreamer only invokes `caller-connecting` on the SRT authentication path.
        source.set_property(
            "authentication",
            access_rules.enabled() || has_stream_id || authentication_requested,
        );
        let writer_ref = writer.clone();
        source.connect("caller-connecting", false, move |values| {
            let stream_id = values
                .get(2)
                .and_then(|value| value.get::<Option<String>>().ok())
                .flatten();
            let decision = access_rules.check_ip(caller_ip(values));

            if let Ok(mut guard) = writer_ref.lock() {
                let _ = guard.send_message(
                    &json!({
                        "event": "srt_access",
                        "ip": decision.ip,
                        "stream_id": stream_id.as_deref(),
                        "allowed": decision.allowed,
                        "reason": decision.reason,
                    })
                    .to_string(),
                );

                if decision.allowed {
                    if let Some(stream_id) = stream_id.as_deref() {
                        let _ = guard.send_message(&format!("stats_source_stream_id:{stream_id}"));
                    }
                }
            }

            if !decision.allowed {
                return Some(false.to_value());
            }

            Some(true.to_value())
        });
    }

    let source_stats_pad = if is_rtp_source {
        let depay = gst::ElementFactory::make("rtpmp2tdepay")
            .build()
            .context("failed to create rtpmp2tdepay")?;
        pipeline
            .add_many([&source, &depay, &tee])
            .context("failed to add source/depay/tee to pipeline")?;
        source
            .link(&depay)
            .context("failed to link source to rtpmp2tdepay")?;
        depay
            .link(&tee)
            .context("failed to link rtpmp2tdepay to tee")?;
        depay.static_pad("src")
    } else {
        pipeline
            .add_many([&source, &tee])
            .context("failed to add source/tee to pipeline")?;
        source.link(&tee).context("failed to link source to tee")?;
        source.static_pad("src")
    };

    let source_bytes_total = Arc::new(AtomicU64::new(0));
    let source_bytes_last_interval = Arc::new(AtomicU64::new(0));
    let source_bytes_per_sec = Arc::new(AtomicU64::new(0));
    let processing_pending = Arc::new(AtomicBool::new(true));
    let dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>> = Arc::new(Mutex::new(Vec::new()));

    if let Some(src_pad) = source_stats_pad {
        let bytes_counter = source_bytes_total.clone();
        let lifecycle_ref = lifecycle.clone();
        let processing_pending_ref = processing_pending.clone();
        src_pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
            if let Some(buffer) = info.buffer() {
                record_source_buffer(
                    &bytes_counter,
                    &processing_pending_ref,
                    &lifecycle_ref,
                    buffer.size() as u64,
                );
            }
            gst::PadProbeReturn::Ok
        });
    }

    let thumbnail_scheduler =
        add_thumbnail_branch_if_enabled(&pipeline, &tee, &config.source, writer.clone())?;

    for sink in config.sinks {
        add_sink_to_pipeline(&pipeline, &tee, sink, dest_metrics.clone())?;
    }

    Ok(PipelineRuntime {
        pipeline,
        loop_: glib::MainLoop::new(None, false),
        source,
        lifecycle,
        source_bytes_total,
        source_bytes_last_interval,
        source_bytes_per_sec,
        processing_pending,
        dest_metrics,
        running: Arc::new(AtomicBool::new(true)),
        thumbnail_scheduler,
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

    configure_branch_queue(&queue, &sink_config.element_type);

    apply_element_properties(&sink_element, &strip_internal_props(&sink_config))?;

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
    link_tee_branch(tee, &queue).context("failed to link tee to queue")?;
    queue
        .link(&sink_element)
        .context("failed to link queue to sink")?;

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

fn add_thumbnail_branch_if_enabled(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    source_config: &ElementConfig,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<Option<Arc<ThumbnailScheduler>>> {
    let Some(config) = thumbnail_config(source_config) else {
        return Ok(None);
    };

    let queue = gst::ElementFactory::make("queue")
        .name("hydra_thumbnail_queue")
        .build()
        .context("failed to create thumbnail queue")?;
    let valve = gst::ElementFactory::make("valve")
        .name("hydra_thumbnail_valve")
        .build()
        .context("failed to create thumbnail valve")?;
    valve.set_property("drop", true);
    let decodebin = gst::ElementFactory::make("decodebin")
        .name("hydra_thumbnail_decodebin")
        .build()
        .context("failed to create thumbnail decodebin")?;
    decodebin.set_property("force-sw-decoders", true);
    let videoconvert = gst::ElementFactory::make("videoconvert")
        .name("hydra_thumbnail_videoconvert")
        .build()
        .context("failed to create thumbnail videoconvert")?;
    let videoscale = gst::ElementFactory::make("videoscale")
        .name("hydra_thumbnail_videoscale")
        .build()
        .context("failed to create thumbnail videoscale")?;
    let jpegenc = gst::ElementFactory::make("jpegenc")
        .name("hydra_thumbnail_jpegenc")
        .build()
        .context("failed to create thumbnail jpegenc")?;
    let appsink = gst::ElementFactory::make("appsink")
        .name("hydra_thumbnail_appsink")
        .build()
        .context("failed to create thumbnail appsink")?;

    configure_thumbnail_queue(&queue);
    appsink.set_property("emit-signals", false);
    appsink.set_property("sync", false);
    appsink.set_property("async", false);
    appsink.set_property("max-buffers", 1_u32);
    appsink.set_property("drop", true);

    let appsink = appsink
        .dynamic_cast::<gst_app::AppSink>()
        .map_err(|_| anyhow!("thumbnail sink is not an appsink"))?;

    let scheduler = ThumbnailScheduler::new(valve.clone(), config.interval);
    configure_thumbnail_appsink(&appsink, config, scheduler.clone(), writer);

    pipeline
        .add_many([
            &queue,
            &valve,
            &decodebin,
            &videoconvert,
            &videoscale,
            &jpegenc,
            appsink.upcast_ref(),
        ])
        .context("failed to add thumbnail elements to pipeline")?;

    link_tee_branch(tee, &queue).context("failed to link tee to thumbnail queue")?;
    gst::Element::link_many([&queue, &valve, &decodebin])
        .context("failed to link thumbnail queue to valve to decodebin")?;
    gst::Element::link_many([&videoconvert, &videoscale, &jpegenc, appsink.upcast_ref()])
        .context("failed to link thumbnail encoder branch")?;

    let convert_sink = videoconvert
        .static_pad("sink")
        .context("thumbnail videoconvert sink pad missing")?;

    decodebin.connect_pad_added(move |_decodebin, src_pad| {
        if convert_sink.is_linked() {
            return;
        }

        if !thumbnail_pad_is_video(src_pad) {
            return;
        }

        if let Err(err) = src_pad.link(&convert_sink) {
            eprintln!("thumbnail decodebin pad link failed: {err:?}");
        }
    });

    Ok(Some(scheduler))
}

#[derive(Clone, Debug)]
struct ThumbnailConfig {
    source_id: String,
    interval: Duration,
}

fn thumbnail_config(source_config: &ElementConfig) -> Option<ThumbnailConfig> {
    if !source_config
        .props
        .get("hydra_thumbnail_enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return None;
    }

    let source_id = source_config
        .props
        .get("hydra_source_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let interval_ms = source_config
        .props
        .get("hydra_thumbnail_interval_ms")
        .and_then(Value::as_u64)
        .unwrap_or(5_000)
        .max(1_000);

    Some(ThumbnailConfig {
        source_id,
        interval: Duration::from_millis(interval_ms),
    })
}

fn configure_thumbnail_queue(queue: &gst::Element) {
    // Keep the thumbnail branch from applying backpressure to the tee fan-out, but retain
    // enough MPEG-TS data for decodebin to typefind, demux, and decode a frame.
    queue.set_property_from_str("leaky", "downstream");
    queue.set_property("max-size-buffers", 0_u32);
    queue.set_property("max-size-bytes", 0_u32);
    queue.set_property("max-size-time", 3_000_000_000_u64);
}

fn thumbnail_pad_is_video(src_pad: &gst::Pad) -> bool {
    let Some(caps) = src_pad.current_caps() else {
        return false;
    };

    caps.structure(0)
        .map(|structure| structure.name().starts_with("video/"))
        .unwrap_or(false)
}

fn configure_thumbnail_appsink(
    appsink: &gst_app::AppSink,
    config: ThumbnailConfig,
    scheduler: Arc<ThumbnailScheduler>,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    appsink.set_caps(Some(&gst::Caps::builder("image/jpeg").build()));
    appsink.set_callbacks(
        gst_app::AppSinkCallbacks::builder()
            .new_sample({
                move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Error)?;
                    let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
                    let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
                    let data_base64 = BASE64_STANDARD.encode(map.as_slice());
                    let payload = json!({
                        "event": "thumbnail",
                        "source_id": config.source_id,
                        "content_type": "image/jpeg",
                        "data_base64": data_base64,
                    });

                    if let Ok(mut guard) = writer.lock() {
                        let _ = guard.send_message(&payload.to_string());
                    }

                    scheduler.on_frame_captured();
                    Ok(gst::FlowSuccess::Ok)
                }
            })
            .build(),
    );
}

fn record_source_buffer(
    bytes_counter: &Arc<AtomicU64>,
    processing_pending: &Arc<AtomicBool>,
    lifecycle: &PipelineLifecycleEmitter,
    buffer_size: u64,
) {
    bytes_counter.fetch_add(buffer_size, Ordering::Relaxed);

    if processing_pending.swap(false, Ordering::AcqRel) {
        let _ = lifecycle.emit_processing();
    }
}

fn configure_branch_queue(queue: &gst::Element, sink_type: &str) {
    queue.set_property("max-size-buffers", 200_u32);
    queue.set_property("max-size-time", 0_u64);

    if sink_type == "srtsink" {
        // Keep one blocked SRT destination from applying backpressure to the whole tee fan-out.
        queue.set_property_from_str("leaky", "downstream");
    }
}

fn link_tee_branch(tee: &gst::Element, queue: &gst::Element) -> Result<()> {
    let tee_src_pad = tee
        .request_pad_simple("src_%u")
        .ok_or_else(|| anyhow!("failed to request tee src pad"))?;
    let queue_sink_pad = queue
        .static_pad("sink")
        .ok_or_else(|| anyhow!("queue has no sink pad"))?;

    tee_src_pad
        .link(&queue_sink_pad)
        .map(|_| ())
        .map_err(|err| anyhow!("failed to link tee request pad: {err:?}"))?;

    Ok(())
}

fn strip_internal_props(config: &ElementConfig) -> ElementConfig {
    let mut sanitized = config.clone();
    sanitized.props.retain(|key, _| !key.starts_with("hydra_"));
    sanitized
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ElementConfig, PipelineConfig};
    use crate::lifecycle::PipelineStatus;
    use crate::output::{StatsWriter, StdoutWriter};
    use serde_json::Value;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    fn init_gst() {
        let _ = gst::init();
    }

    #[test]
    fn builds_pipeline_with_multiple_tee_branches() {
        init_gst();

        let config = PipelineConfig {
            source: ElementConfig {
                element_type: "fakesrc".to_string(),
                props: BTreeMap::new(),
            },
            sinks: vec![
                ElementConfig {
                    element_type: "fakesink".to_string(),
                    props: BTreeMap::from([("sync".to_string(), Value::Bool(false))]),
                },
                ElementConfig {
                    element_type: "fakesink".to_string(),
                    props: BTreeMap::from([("sync".to_string(), Value::Bool(false))]),
                },
            ],
        };

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");
        assert_eq!(runtime.dest_metrics.lock().expect("metrics lock").len(), 2);
        assert!(runtime.pipeline.by_name("hydra_thumbnail_queue").is_none());
    }

    #[test]
    fn builds_pipeline_with_thumbnail_branch_when_enabled() {
        init_gst();

        let config = PipelineConfig {
            source: ElementConfig {
                element_type: "fakesrc".to_string(),
                props: BTreeMap::from([
                    (
                        "hydra_source_id".to_string(),
                        Value::String("source-1".to_string()),
                    ),
                    ("hydra_thumbnail_enabled".to_string(), Value::Bool(true)),
                    (
                        "hydra_thumbnail_interval_ms".to_string(),
                        Value::Number(2_000_u64.into()),
                    ),
                ]),
            },
            sinks: vec![ElementConfig {
                element_type: "fakesink".to_string(),
                props: BTreeMap::from([("sync".to_string(), Value::Bool(false))]),
            }],
        };

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");
        assert!(runtime.pipeline.by_name("hydra_thumbnail_queue").is_some());
        assert!(runtime.pipeline.by_name("hydra_thumbnail_valve").is_some());
        assert!(runtime.thumbnail_scheduler.is_some());
        assert!(runtime
            .pipeline
            .by_name("hydra_thumbnail_appsink")
            .is_some());
        assert_eq!(runtime.dest_metrics.lock().expect("metrics lock").len(), 1);
    }

    #[test]
    fn tracks_metrics_for_mixed_sink_types() {
        init_gst();

        let config = PipelineConfig {
            source: ElementConfig {
                element_type: "fakesrc".to_string(),
                props: BTreeMap::new(),
            },
            sinks: vec![
                ElementConfig {
                    element_type: "udpsink".to_string(),
                    props: BTreeMap::from([
                        (
                            "address".to_string(),
                            Value::String("127.0.0.1".to_string()),
                        ),
                        ("port".to_string(), Value::Number(4100_u64.into())),
                        (
                            "hydra_destination_id".to_string(),
                            Value::String("udp_dest".to_string()),
                        ),
                        (
                            "hydra_destination_name".to_string(),
                            Value::String("UDP Dest".to_string()),
                        ),
                        (
                            "hydra_destination_schema".to_string(),
                            Value::String("UDP".to_string()),
                        ),
                    ]),
                },
                ElementConfig {
                    element_type: "srtsink".to_string(),
                    props: BTreeMap::from([
                        (
                            "localaddress".to_string(),
                            Value::String("127.0.0.1".to_string()),
                        ),
                        ("localport".to_string(), Value::Number(4200_u64.into())),
                        ("mode".to_string(), Value::String("caller".to_string())),
                        (
                            "hydra_destination_id".to_string(),
                            Value::String("srt_dest".to_string()),
                        ),
                        (
                            "hydra_destination_name".to_string(),
                            Value::String("SRT Dest".to_string()),
                        ),
                        (
                            "hydra_destination_schema".to_string(),
                            Value::String("SRT".to_string()),
                        ),
                    ]),
                },
            ],
        };

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");
        let metrics = runtime.dest_metrics.lock().expect("metrics lock");

        assert_eq!(metrics.len(), 2);

        let udp_metrics = metrics
            .iter()
            .find(|metric| metric.id.as_deref() == Some("udp_dest"))
            .expect("udp metrics present");
        assert_eq!(udp_metrics.kind, "udpsink");
        assert!(udp_metrics.sink_element.is_none());

        let srt_metrics = metrics
            .iter()
            .find(|metric| metric.id.as_deref() == Some("srt_dest"))
            .expect("srt metrics present");
        assert_eq!(srt_metrics.kind, "srtsink");
        assert!(srt_metrics.sink_element.is_some());
    }

    #[test]
    fn keeps_srtsrc_authentication_false_by_default() {
        init_gst();

        let config = srtsrc_pipeline_config(BTreeMap::from([
            (
                "uri".to_string(),
                Value::String("srt://127.0.0.1:4201?mode=listener".to_string()),
            ),
            (
                "localaddress".to_string(),
                Value::String("127.0.0.1".to_string()),
            ),
            ("localport".to_string(), Value::Number(4201_u64.into())),
            ("mode".to_string(), Value::String("listener".to_string())),
        ]));

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");

        assert!(!runtime.source.property::<bool>("authentication"));
    }

    #[test]
    fn preserves_explicit_srtsrc_authentication_from_config() {
        init_gst();

        let config = srtsrc_pipeline_config(BTreeMap::from([
            (
                "uri".to_string(),
                Value::String("srt://127.0.0.1:4201?mode=listener".to_string()),
            ),
            (
                "localaddress".to_string(),
                Value::String("127.0.0.1".to_string()),
            ),
            ("localport".to_string(), Value::Number(4201_u64.into())),
            ("mode".to_string(), Value::String("listener".to_string())),
            ("authentication".to_string(), Value::Bool(true)),
        ]));

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");

        assert!(runtime.source.property::<bool>("authentication"));
    }

    #[test]
    fn enables_srtsrc_authentication_for_ip_access_hook() {
        init_gst();

        let config = srtsrc_pipeline_config(BTreeMap::from([
            (
                "uri".to_string(),
                Value::String("srt://127.0.0.1:4201?mode=listener".to_string()),
            ),
            (
                "localaddress".to_string(),
                Value::String("127.0.0.1".to_string()),
            ),
            ("localport".to_string(), Value::Number(4201_u64.into())),
            ("mode".to_string(), Value::String("listener".to_string())),
            ("hydra_limit_access".to_string(), Value::Bool(true)),
            (
                "hydra_denied_list".to_string(),
                Value::Array(vec![Value::String("127.0.0.1".to_string())]),
            ),
        ]));

        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(StdoutWriter::new())));

        let runtime = build_pipeline(config, writer).expect("pipeline should build");

        assert!(runtime.source.property::<bool>("authentication"));
    }

    #[test]
    fn makes_srt_branch_queue_leaky() {
        init_gst();

        let queue = gst::ElementFactory::make("queue")
            .build()
            .expect("queue should build");

        configure_branch_queue(&queue, "srtsink");

        assert_eq!(
            queue
                .property_value("leaky")
                .serialize()
                .expect("serialized leaky property"),
            "downstream"
        );
    }

    fn srtsrc_pipeline_config(source_props: BTreeMap<String, Value>) -> PipelineConfig {
        PipelineConfig {
            source: ElementConfig {
                element_type: "srtsrc".to_string(),
                props: source_props,
            },
            sinks: vec![ElementConfig {
                element_type: "fakesink".to_string(),
                props: BTreeMap::from([("sync".to_string(), Value::Bool(false))]),
            }],
        }
    }

    #[test]
    fn emits_processing_when_source_buffer_hook_runs() {
        init_gst();

        #[derive(Debug, Default)]
        struct MemoryWriter {
            messages: Arc<Mutex<Vec<String>>>,
        }

        impl StatsWriter for MemoryWriter {
            fn send_message(&mut self, message: &str) -> Result<()> {
                self.messages
                    .lock()
                    .expect("messages lock")
                    .push(message.to_string());
                Ok(())
            }
        }

        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));

        let lifecycle = PipelineLifecycleEmitter::new(writer);
        let bytes_counter = Arc::new(AtomicU64::new(0));
        let processing_pending = Arc::new(AtomicBool::new(true));

        assert_eq!(lifecycle.current_status().expect("initial status"), None);

        lifecycle.emit_starting().expect("starting");
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);

        assert_eq!(bytes_counter.load(Ordering::Relaxed), 376);
        assert_eq!(
            lifecycle.current_status().expect("status after buffers"),
            Some(PipelineStatus::Processing)
        );

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"starting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
            ]
        );
    }

    #[test]
    fn source_buffer_hook_can_promote_to_processing_before_starting_event() {
        init_gst();

        #[derive(Debug, Default)]
        struct MemoryWriter {
            messages: Arc<Mutex<Vec<String>>>,
        }

        impl StatsWriter for MemoryWriter {
            fn send_message(&mut self, message: &str) -> Result<()> {
                self.messages
                    .lock()
                    .expect("messages lock")
                    .push(message.to_string());
                Ok(())
            }
        }

        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));

        let lifecycle = PipelineLifecycleEmitter::new(writer);
        let bytes_counter = Arc::new(AtomicU64::new(0));
        let processing_pending = Arc::new(AtomicBool::new(true));

        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);

        assert_eq!(bytes_counter.load(Ordering::Relaxed), 376);
        assert_eq!(
            lifecycle.current_status().expect("status after buffers"),
            Some(PipelineStatus::Processing)
        );

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [r#"{"event":"pipeline_status","status":"processing"}"#,]
        );
    }

    #[test]
    fn source_buffer_hook_only_emits_processing_when_rearmed() {
        init_gst();

        #[derive(Debug, Default)]
        struct MemoryWriter {
            messages: Arc<Mutex<Vec<String>>>,
        }

        impl StatsWriter for MemoryWriter {
            fn send_message(&mut self, message: &str) -> Result<()> {
                self.messages
                    .lock()
                    .expect("messages lock")
                    .push(message.to_string());
                Ok(())
            }
        }

        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));

        let lifecycle = PipelineLifecycleEmitter::new(writer);
        let bytes_counter = Arc::new(AtomicU64::new(0));
        let processing_pending = Arc::new(AtomicBool::new(true));

        lifecycle.emit_starting().expect("starting");
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);

        lifecycle.emit_reconnecting().expect("reconnecting");
        processing_pending.store(true, Ordering::Release);
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);
        record_source_buffer(&bytes_counter, &processing_pending, &lifecycle, 188);

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"starting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
                r#"{"event":"pipeline_status","status":"reconnecting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
            ]
        );
    }
}
