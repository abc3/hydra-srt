use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use serde_json::Value;

use crate::config::{ElementConfig, PipelineConfig};
use crate::output::StatsWriter;
use crate::properties::apply_element_properties;
use crate::runtime::{DestMetrics, PipelineRuntime};

pub fn build_pipeline(
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
    apply_element_properties(&source, &strip_internal_props(&config.source))?;

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
    sanitized
        .props
        .retain(|key, _| !key.starts_with("hydra_"));
    sanitized
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ElementConfig, PipelineConfig};
    use crate::output::{StatsWriter, StdoutWriter};
    use serde_json::Value;
    use std::collections::BTreeMap;

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
                        ("address".to_string(), Value::String("127.0.0.1".to_string())),
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
                        ("localaddress".to_string(), Value::String("127.0.0.1".to_string())),
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
}
