use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ProbeBufferTiming {
    pub bytes: u64,
    pub pts: Option<Duration>,
    pub duration: Option<Duration>,
}

pub(crate) fn probe_buffer_timings(info: &gst::PadProbeInfo) -> Vec<ProbeBufferTiming> {
    if let Some(buffer) = info.buffer() {
        return vec![buffer_timing(buffer)];
    }
    info.buffer_list()
        .map(|buffer_list| buffer_list.iter().map(buffer_timing).collect())
        .unwrap_or_default()
}

fn buffer_timing(buffer: &gst::BufferRef) -> ProbeBufferTiming {
    ProbeBufferTiming {
        bytes: buffer.size() as u64,
        pts: buffer.pts().map(|pts| Duration::from_nanos(pts.nseconds())),
        duration: buffer
            .duration()
            .map(|duration| Duration::from_nanos(duration.nseconds())),
    }
}

pub(crate) fn probe_buffer_size(info: &gst::PadProbeInfo) -> Option<u64> {
    if let Some(buffer) = info.buffer() {
        return Some(buffer.size() as u64);
    }
    info.buffer_list()
        .map(|buffer_list| buffer_list.iter().map(|buffer| buffer.size() as u64).sum())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffer_list_probe_counts_each_byte_once() {
        gst::init().expect("gstreamer");
        let src_pad = gst::Pad::builder(gst::PadDirection::Src).build();
        let sink_pad = gst::Pad::builder(gst::PadDirection::Sink)
            .chain_function(|_, _, _| Ok(gst::FlowSuccess::Ok))
            .build();
        src_pad.link(&sink_pad).expect("link pads");
        sink_pad.set_active(true).expect("activate sink pad");
        src_pad.set_active(true).expect("activate source pad");

        let metrics = destination_metrics(None, None, None, "test", None);
        add_destination_metrics_probe(&src_pad, metrics.clone());
        let buffer_list = gst::BufferList::from([
            gst::Buffer::with_size(100).expect("buffer"),
            gst::Buffer::with_size(200).expect("buffer"),
            gst::Buffer::with_size(300).expect("buffer"),
        ]);

        src_pad.push_list(buffer_list).expect("push buffer list");

        assert_eq!(metrics.bytes_total.load(Ordering::Relaxed), 600);
    }

    #[test]
    fn buffer_timing_reads_media_timestamps() {
        gst::init().expect("gstreamer");
        let mut buffer = gst::Buffer::with_size(100).expect("buffer");
        buffer
            .get_mut()
            .expect("writable buffer")
            .set_pts(gst::ClockTime::from_mseconds(250));
        buffer
            .get_mut()
            .expect("writable buffer")
            .set_duration(gst::ClockTime::from_mseconds(40));

        assert_eq!(
            buffer_timing(buffer.as_ref()),
            ProbeBufferTiming {
                bytes: 100,
                pts: Some(Duration::from_millis(250)),
                duration: Some(Duration::from_millis(40)),
            }
        );
    }
}
