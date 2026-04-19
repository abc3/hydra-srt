mod config;
mod output;
mod pipeline;
mod properties;
mod runtime;
mod stats;

use std::io::{self, BufRead};
use std::sync::{Arc, Mutex};
use std::sync::atomic::Ordering;

use anyhow::{anyhow, bail, Context, Result};
use gst::prelude::*;
use gstreamer as gst;

use crate::config::PipelineConfig;
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
