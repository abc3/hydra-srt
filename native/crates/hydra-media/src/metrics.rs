use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstreamer as gst;
use gstreamer::prelude::*;

#[derive(Debug)]
pub struct DestMetrics {
    pub id: Option<String>,
    pub name: Option<String>,
    pub schema: Option<String>,
    pub kind: String,
    pub bytes_total: AtomicU64,
    pub bytes_last_interval: AtomicU64,
    pub bytes_per_sec: AtomicU64,
    pub drops: Arc<AtomicU64>,
    pub sink_element: Option<gst::Element>,
}

pub fn destination_metrics(
    id: Option<String>,
    name: Option<String>,
    schema: Option<String>,
    kind: impl Into<String>,
    sink_element: Option<gst::Element>,
) -> Arc<DestMetrics> {
    destination_metrics_with_drops(
        id,
        name,
        schema,
        kind,
        sink_element,
        Arc::new(AtomicU64::new(0)),
    )
}

pub fn destination_metrics_with_drops(
    id: Option<String>,
    name: Option<String>,
    schema: Option<String>,
    kind: impl Into<String>,
    sink_element: Option<gst::Element>,
    drops: Arc<AtomicU64>,
) -> Arc<DestMetrics> {
    Arc::new(DestMetrics {
        id,
        name,
        schema,
        kind: kind.into(),
        bytes_total: AtomicU64::new(0),
        bytes_last_interval: AtomicU64::new(0),
        bytes_per_sec: AtomicU64::new(0),
        drops,
        sink_element,
    })
}

pub fn add_destination_metrics_probe(src_pad: &gst::Pad, metrics: Arc<DestMetrics>) {
    src_pad.add_probe(
        gst::PadProbeType::BUFFER | gst::PadProbeType::BUFFER_LIST,
        move |_pad, info| {
            if let Some(buffer_size) = probe_buffer_size(info) {
                metrics
                    .bytes_total
                    .fetch_add(buffer_size, Ordering::Relaxed);
            }
            gst::PadProbeReturn::Ok
        },
    );
}

pub(crate) fn probe_buffer_size(info: &gst::PadProbeInfo) -> Option<u64> {
    if let Some(buffer) = info.buffer() {
        return Some(buffer.size() as u64);
    }
    info.buffer_list()
        .map(|buffer_list| buffer_list.iter().map(|buffer| buffer.size() as u64).sum())
}
