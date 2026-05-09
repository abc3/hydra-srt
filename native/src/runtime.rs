use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};

use gstreamer as gst;

use crate::lifecycle::PipelineLifecycleEmitter;

#[derive(Debug)]
pub struct DestMetrics {
    pub id: Option<String>,
    pub name: Option<String>,
    pub schema: Option<String>,
    pub kind: String,
    pub bytes_total: AtomicU64,
    pub bytes_last_interval: AtomicU64,
    pub bytes_per_sec: AtomicU64,
    pub sink_element: Option<gst::Element>,
}

#[derive(Debug)]
pub struct PipelineRuntime {
    pub pipeline: gst::Pipeline,
    pub loop_: glib::MainLoop,
    pub source: gst::Element,
    pub lifecycle: PipelineLifecycleEmitter,
    pub source_bytes_total: Arc<AtomicU64>,
    pub source_bytes_last_interval: Arc<AtomicU64>,
    pub source_bytes_per_sec: Arc<AtomicU64>,
    pub processing_pending: Arc<AtomicBool>,
    pub dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>>,
    pub running: Arc<AtomicBool>,
}
