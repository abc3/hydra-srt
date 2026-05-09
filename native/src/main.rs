mod config;
mod lifecycle;
mod output;
mod pipeline;
mod properties;
mod runtime;
mod stats;

use std::io::{self, BufRead};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use gst::prelude::*;
use gstreamer as gst;

use crate::config::PipelineConfig;
use crate::lifecycle::{FailureReason, StopReason};
use crate::output::{StatsWriter, StdoutWriter};
use crate::pipeline::build_pipeline;
use crate::stats::start_stats_loop;

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
    let source_obj = runtime.source.clone().upcast::<gst::Object>();
    let lifecycle = runtime.lifecycle.clone();
    let processing_pending = runtime.processing_pending.clone();
    let eos_seen = Arc::new(AtomicBool::new(false));
    let eos_seen_ref = eos_seen.clone();
    let _bus_watch = bus
        .add_watch(move |_bus, msg| {
            use gst::MessageView;

            match msg.view() {
                MessageView::Error(err) => {
                    eprintln!("Error: {}", err.error());
                    let _ = lifecycle.emit_failed(FailureReason::RuntimeError);
                    main_loop.quit();
                }
                MessageView::Eos(..) => {
                    eos_seen_ref.store(true, Ordering::Relaxed);
                    main_loop.quit();
                }
                MessageView::Element(element) => {
                    if let Some(structure) = element.structure() {
                        let is_source_msg =
                            msg.src().map(|src| *src == source_obj).unwrap_or(false);

                        if is_source_msg && structure.name() == "connection-removed" {
                            if lifecycle.emit_reconnecting().unwrap_or(false) {
                                processing_pending.store(true, Ordering::Release);
                            }
                        }
                    }
                }
                MessageView::StateChanged(_state)
                    if msg.src().map(|src| *src == pipeline_obj).unwrap_or(false) => {}
                _ => {}
            }

            glib::ControlFlow::Continue
        })
        .context("failed to attach bus watch")?;

    runtime.lifecycle.emit_starting()?;
    runtime
        .pipeline
        .set_state(gst::State::Playing)
        .map_err(|err| {
            let _ = runtime.lifecycle.emit_failed(FailureReason::Startup);
            err
        })
        .context("failed to set pipeline to playing")?;

    runtime.loop_.run();

    runtime.running.store(false, Ordering::Relaxed);
    let stop_reason = match runtime.lifecycle.current_status()? {
        Some(crate::lifecycle::PipelineStatus::Failed) => StopReason::Failure,
        _ if eos_seen.load(Ordering::Relaxed) => StopReason::Eos,
        _ => StopReason::Shutdown,
    };
    runtime
        .pipeline
        .set_state(gst::State::Null)
        .context("failed to set pipeline to null")?;
    runtime.lifecycle.emit_stopped(stop_reason)?;

    Ok(())
}
