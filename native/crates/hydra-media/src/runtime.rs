use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};

use gstreamer as gst;

use crate::adapters::srt::SrtCallerRegistry;
use crate::events::Transport;
use crate::lifecycle::PipelineLifecycleEmitter;
use crate::metrics::DestMetrics;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EndpointDescriptor {
    pub bin_name: String,
    pub endpoint_id: String,
    pub direction: crate::events::EndpointDirection,
    pub transport: Transport,
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
    pub srt_callers: Option<Arc<SrtCallerRegistry>>,
}
