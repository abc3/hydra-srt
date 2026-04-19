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

    queue.set_property("max-size-buffers", 200_u32);
    queue.set_property("max-size-time", 0_u64);

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

fn strip_internal_props(config: &ElementConfig) -> ElementConfig {
    let mut sanitized = config.clone();
    sanitized
        .props
        .retain(|key, _| !key.starts_with("hydra_"));
    sanitized
}
