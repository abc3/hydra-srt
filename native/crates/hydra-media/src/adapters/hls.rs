use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, HlsEndAction, HlsSource};
use serde_json::{json, Map, Value};
use thiserror::Error;

use super::element::{make_named_element, set_property};
use crate::events::EventSink;
use crate::metrics::{probe_buffer_timings, ProbeBufferTiming};
use crate::runtime::EndpointDescriptor;

const DEFAULT_TARGET_DURATION_MS: u64 = 5_000;
const EOS_POLICY_DATA_KEY: &str = "hydra-hls-eos-policy";
const MEDIA_INFO_INTERVAL: Duration = Duration::from_secs(2);
const BITRATE_WINDOW: Duration = Duration::from_secs(5);
const MIN_BITRATE_SPAN: Duration = Duration::from_secs(1);
const MAX_PTS_DISCONTINUITY: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct EosPolicy {
    pub live: bool,
    pub end_action: HlsEndAction,
}

#[derive(Debug, Error)]
#[error("{code}: {detail}")]
pub struct HlsAdapterError {
    code: ErrorCode,
    detail: String,
}

impl HlsAdapterError {
    fn new(code: ErrorCode, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }

    pub const fn code(&self) -> ErrorCode {
        self.code
    }

    pub fn detail(&self) -> &str {
        &self.detail
    }
}

pub fn apply(element: &gst::Element, config: &HlsSource) -> Result<(), (ErrorCode, String)> {
    set_property(element, "uri", config.uri().as_str())
}

pub fn validate_end_action(config: &HlsSource) -> Result<(), HlsAdapterError> {
    if config.end_action() == HlsEndAction::Stop {
        return Ok(());
    }
    Err(HlsAdapterError::new(
        ErrorCode::UnsupportedGraph,
        "HLS end_action hold and loop are not implemented",
    ))
}

pub fn set_eos_policy(source: &gst::Element, config: &HlsSource) {
    // The runtime descriptor intentionally stays transport-only. Keep the source policy on
    // the native element so health classification can use the plan without changing that API.
    let policy = EosPolicy {
        live: config.live(),
        end_action: config.end_action(),
    };
    // SAFETY: EosPolicy is Copy + 'static and remains owned by the GObject until replacement.
    unsafe { source.set_data(EOS_POLICY_DATA_KEY, policy) };
}

pub(crate) fn eos_policy(source: &gst::Element) -> Option<EosPolicy> {
    // SAFETY: The value was inserted under this key by set_eos_policy and has a static type.
    unsafe {
        source
            .data::<EosPolicy>(EOS_POLICY_DATA_KEY)
            .map(|value| *value.as_ref())
    }
}

pub fn build_source_contents(
    bin: &gst::Bin,
    source: &gst::Element,
    target_duration_ms: Option<u64>,
) -> Result<Option<gst::Pad>, HlsAdapterError> {
    let parsebin = make_named_element("parsebin", "hls_parsebin", "HLS source parsebin")
        .map_err(|(code, detail)| HlsAdapterError::new(code, detail))?;
    let mux = make_named_element("mpegtsmux", "hls_mpegtsmux", "HLS source MPEG-TS muxer")
        .map_err(|(code, detail)| HlsAdapterError::new(code, detail))?;
    let target_duration_ms = target_duration_ms.unwrap_or(DEFAULT_TARGET_DURATION_MS);
    let parsebin_weak = parsebin.downgrade();
    let bin_weak_for_source = bin.downgrade();
    let mux_weak_for_source = mux.downgrade();
    let parse_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));

    bin.add_many([source, &parsebin, &mux])
        .map_err(runtime_error)?;

    let parse_sink = parsebin.static_pad("sink").ok_or_else(|| {
        HlsAdapterError::new(ErrorCode::LinkFailed, "HLS parsebin has no sink pad")
    })?;
    connect_parsebin(bin, &parsebin, &mux, target_duration_ms);
    source.connect_pad_added(move |_source, source_pad| {
        let Some(initial_parsebin) = parsebin_weak.upgrade() else {
            return;
        };
        let parsebin = if parse_sink.is_linked() {
            let Some(bin) = bin_weak_for_source.upgrade() else {
                return;
            };
            let Some(mux) = mux_weak_for_source.upgrade() else {
                return;
            };
            let index = parse_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            let Ok(parsebin) = make_named_element(
                "parsebin",
                &format!("hls_parsebin_{index}"),
                "HLS source parsebin",
            )
            .map_err(|(code, detail)| HlsAdapterError::new(code, detail)) else {
                return;
            };
            if bin.add(&parsebin).is_err() {
                return;
            }
            if parsebin.sync_state_with_parent().is_err() {
                let _ = bin.remove(&parsebin);
                return;
            }
            connect_parsebin(&bin, &parsebin, &mux, target_duration_ms);
            parsebin
        } else {
            initial_parsebin
        };
        let Some(parse_sink) = parsebin.static_pad("sink") else {
            return;
        };
        if source_pad.link(&parse_sink).is_err() {
            eprintln!("failed to link HLS source pad to parsebin");
        }
    });

    mux.static_pad("src").map(Some).ok_or_else(|| {
        HlsAdapterError::new(ErrorCode::LinkFailed, "HLS muxer has no static src pad")
    })
}

pub fn attach_media_info_monitor(
    source: &gst::Element,
    event_sink: EventSink,
    endpoint: EndpointDescriptor,
    live: bool,
) {
    let Some(parent) = source
        .parent()
        .and_then(|object| object.downcast::<gst::Bin>().ok())
    else {
        return;
    };
    let state = Arc::new(Mutex::new(MediaInfoState::default()));
    for element in parent
        .iterate_recurse()
        .into_iter()
        .filter_map(Result::ok)
        .filter(|element| {
            element
                .factory()
                .is_some_and(|factory| factory.name() == "parsebin")
        })
    {
        install_parsebin_monitor(
            &element,
            state.clone(),
            event_sink.clone(),
            endpoint.clone(),
            live,
        );
    }
    let parent_weak_for_new = parent.downgrade();
    let state_for_new = state;
    let sink_for_new = event_sink;
    let endpoint_for_new = endpoint;
    let source_weak = source.downgrade();
    let state_for_timer = state_for_new.clone();
    let sink_for_timer = sink_for_new.clone();
    let endpoint_for_timer = endpoint_for_new.clone();
    source.connect_pad_added(move |_source, _pad| {
        let Some(parent) = parent_weak_for_new.upgrade() else {
            return;
        };
        for element in parent
            .iterate_recurse()
            .into_iter()
            .filter_map(Result::ok)
            .filter(|element| {
                element
                    .factory()
                    .is_some_and(|factory| factory.name() == "parsebin")
            })
        {
            install_parsebin_monitor(
                &element,
                state_for_new.clone(),
                sink_for_new.clone(),
                endpoint_for_new.clone(),
                live,
            );
        }
    });
    glib::timeout_add(MEDIA_INFO_INTERVAL, move || {
        let Some(source) = source_weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if source.current_state() == gst::State::Null {
            return glib::ControlFlow::Break;
        }
        emit_periodic(&state_for_timer, &sink_for_timer, &endpoint_for_timer, live);
        glib::ControlFlow::Continue
    });
}

fn install_parsebin_monitor(
    parsebin: &gst::Element,
    state: Arc<Mutex<MediaInfoState>>,
    event_sink: EventSink,
    endpoint: EndpointDescriptor,
    live: bool,
) {
    let parsebin_name = parsebin.name().to_string();
    let Ok(mut state_guard) = state.lock() else {
        return;
    };
    if !state_guard.monitored_parsebins.insert(parsebin_name) {
        return;
    }
    drop(state_guard);

    let state_for_added = state.clone();
    let sink_for_added = event_sink.clone();
    let endpoint_for_added = endpoint.clone();
    parsebin.connect_pad_added(move |_parsebin, pad| {
        install_caps_monitor(
            pad,
            state_for_added.clone(),
            sink_for_added.clone(),
            endpoint_for_added.clone(),
            live,
        );
    });
    for pad in parsebin.src_pads() {
        install_caps_monitor(
            &pad,
            state.clone(),
            event_sink.clone(),
            endpoint.clone(),
            live,
        );
    }
}

fn connect_parsebin(
    bin: &gst::Bin,
    parsebin: &gst::Element,
    mux: &gst::Element,
    target_duration_ms: u64,
) {
    let bin_weak = bin.downgrade();
    let mux_weak = mux.downgrade();
    let parsebin_name = parsebin.name().to_string();
    parsebin.connect_pad_added(move |_parsebin, parsed_pad| {
        let Some(bin) = bin_weak.upgrade() else {
            return;
        };
        let Some(mux) = mux_weak.upgrade() else {
            return;
        };
        if let Err(error) =
            link_parsed_pad(&bin, &mux, parsed_pad, target_duration_ms, &parsebin_name)
        {
            eprintln!("failed to link HLS parsed stream: {error}");
        }
    });
}

fn install_caps_monitor(
    pad: &gst::Pad,
    state: Arc<Mutex<MediaInfoState>>,
    event_sink: EventSink,
    endpoint: EndpointDescriptor,
    live: bool,
) {
    let pad_id = pad.as_ptr() as usize;
    let Ok(mut state_guard) = state.lock() else {
        return;
    };
    if !state_guard.monitored_pads.insert(pad_id) {
        return;
    }
    drop(state_guard);

    let lane = Arc::new(Mutex::new(None));
    let lane_for_probe = lane.clone();
    let state_for_probe = state.clone();
    let sink_for_probe = event_sink.clone();
    let endpoint_for_probe = endpoint.clone();
    let _ = pad.add_probe(gst::PadProbeType::EVENT_DOWNSTREAM, move |_pad, info| {
        let Some(gst::PadProbeData::Event(event)) = info.data.as_ref() else {
            return gst::PadProbeReturn::Ok;
        };
        let gst::EventView::Caps(caps_event) = event.view() else {
            return gst::PadProbeReturn::Ok;
        };
        let info = media_info_from_caps(caps_event.caps());
        if let Ok(mut lane) = lane_for_probe.lock() {
            *lane = info.as_ref().map(|info| info.0);
        }
        if let Some(info) = info {
            emit_if_changed(
                &state_for_probe,
                &sink_for_probe,
                &endpoint_for_probe,
                live,
                info,
            );
        }
        gst::PadProbeReturn::Ok
    });
    let bitrate_pad = downstream_mux_pad(pad).unwrap_or_else(|| pad.clone());
    let should_install_bitrate_probe = claim_bitrate_pad(&state, &bitrate_pad);
    if should_install_bitrate_probe {
        let lane_for_bitrate = lane.clone();
        let state_for_bitrate = state.clone();
        let _ = bitrate_pad.add_probe(
            gst::PadProbeType::BUFFER | gst::PadProbeType::BUFFER_LIST,
            move |_pad, info| {
                if let Some(lane) = lane_for_bitrate.lock().ok().and_then(|lane| *lane) {
                    for timing in probe_buffer_timings(info) {
                        record_bitrate(&state_for_bitrate, lane, timing);
                    }
                }
                gst::PadProbeReturn::Ok
            },
        );
    }
    if let Some(caps) = pad.current_caps().filter(|caps| !caps.is_empty()) {
        if let Some(info) = media_info_from_caps(&caps) {
            if let Ok(mut lane) = lane.lock() {
                *lane = Some(info.0);
            }
            emit_if_changed(&state, &event_sink, &endpoint, live, info);
        }
    }
}

fn downstream_mux_pad(pad: &gst::Pad) -> Option<gst::Pad> {
    let mut current = pad.clone();
    loop {
        let peer = current.peer()?;
        let element = peer.parent()?.downcast::<gst::Element>().ok()?;
        if element
            .factory()
            .is_some_and(|factory| factory.name() == "mpegtsmux")
        {
            return Some(current);
        }
        current = element.static_pad("src")?;
    }
}

fn claim_bitrate_pad(state: &Arc<Mutex<MediaInfoState>>, pad: &gst::Pad) -> bool {
    let Ok(mut state) = state.lock() else {
        return false;
    };
    state.monitored_bitrate_pads.insert(pad.as_ptr() as usize)
}

#[derive(Default)]
struct MediaInfoState {
    monitored_parsebins: HashSet<String>,
    monitored_pads: HashSet<usize>,
    video: Option<Value>,
    audio: Option<Value>,
    video_bitrate: BitrateAccumulator,
    audio_bitrate: BitrateAccumulator,
    monitored_bitrate_pads: HashSet<usize>,
}

struct BitrateSample {
    start: Duration,
    end: Duration,
    bytes: u64,
}

struct BitrateAccumulator {
    samples: VecDeque<BitrateSample>,
    window: Duration,
    last_end: Option<Duration>,
}

impl Default for BitrateAccumulator {
    fn default() -> Self {
        Self::new(BITRATE_WINDOW)
    }
}

impl BitrateAccumulator {
    fn new(window: Duration) -> Self {
        Self {
            samples: VecDeque::new(),
            window,
            last_end: None,
        }
    }

    fn record(&mut self, timing: ProbeBufferTiming) {
        let Some(start) = timing.pts else {
            return;
        };
        let Some(duration) = timing.duration else {
            return;
        };
        let Some(end) = start.checked_add(duration) else {
            return;
        };
        if timing.bytes == 0 || end <= start {
            return;
        }
        if self
            .last_end
            .is_some_and(|last_end| pts_discontinuity(last_end, start))
        {
            self.clear();
        }
        self.samples.push_back(BitrateSample {
            start,
            end,
            bytes: timing.bytes,
        });
        self.last_end = Some(end);
        self.discard_old(end);
    }

    fn bitrate_kbps(&mut self) -> Option<u64> {
        let end = self.last_end?;
        self.discard_old(end);
        let first = self.samples.front()?;
        let last = self.samples.back()?;
        let span = last.end.checked_sub(first.start)?;
        if span < MIN_BITRATE_SPAN {
            return None;
        }
        let bytes = self
            .samples
            .iter()
            .fold(0_u64, |bytes, sample| bytes.saturating_add(sample.bytes));
        let numerator = u128::from(bytes).saturating_mul(8_000_000);
        let denominator = span.as_nanos();
        let rounded = numerator.saturating_add(denominator / 2) / denominator;
        u64::try_from(rounded).ok()
    }

    fn clear(&mut self) {
        self.samples.clear();
        self.last_end = None;
    }

    fn discard_old(&mut self, end: Duration) {
        let cutoff = end.saturating_sub(self.window);
        while self
            .samples
            .front()
            .is_some_and(|sample| sample.end <= cutoff)
        {
            self.samples.pop_front();
        }
    }
}

fn pts_discontinuity(previous_end: Duration, start: Duration) -> bool {
    start > previous_end.saturating_add(MAX_PTS_DISCONTINUITY)
        || previous_end > start.saturating_add(MAX_PTS_DISCONTINUITY)
}

fn emit_if_changed(
    state: &Arc<Mutex<MediaInfoState>>,
    event_sink: &EventSink,
    endpoint: &EndpointDescriptor,
    live: bool,
    info: (MediaLane, Value),
) {
    let Ok(mut state) = state.lock() else {
        return;
    };
    let slot = match info.0 {
        MediaLane::Video => {
            if state.video.as_ref() != Some(&info.1) {
                state.video_bitrate.clear();
            }
            &mut state.video
        }
        MediaLane::Audio => {
            if state.audio.as_ref() != Some(&info.1) {
                state.audio_bitrate.clear();
            }
            &mut state.audio
        }
    };
    if slot.as_ref() == Some(&info.1) {
        return;
    }
    *slot = Some(info.1);
    let media_info = json!({
        "video": state.video.clone().unwrap_or(Value::Null),
        "audio": state.audio.clone().unwrap_or(Value::Null),
    });
    let _ = event_sink.emit_media_info(&endpoint.endpoint_id, live, None, media_info);
}

fn record_bitrate(state: &Arc<Mutex<MediaInfoState>>, lane: MediaLane, timing: ProbeBufferTiming) {
    let Ok(mut state) = state.lock() else {
        return;
    };
    match lane {
        MediaLane::Video => state.video_bitrate.record(timing),
        MediaLane::Audio => state.audio_bitrate.record(timing),
    }
}

fn emit_periodic(
    state: &Arc<Mutex<MediaInfoState>>,
    event_sink: &EventSink,
    endpoint: &EndpointDescriptor,
    live: bool,
) {
    let Ok(mut state) = state.lock() else {
        return;
    };
    let video_bitrate = state.video_bitrate.bitrate_kbps();
    let audio_bitrate = state.audio_bitrate.bitrate_kbps();
    let video_changed = set_lane_bitrate(&mut state.video, video_bitrate);
    let audio_changed = set_lane_bitrate(&mut state.audio, audio_bitrate);
    if !(video_changed || audio_changed || video_bitrate.is_some() || audio_bitrate.is_some()) {
        return;
    }
    let media_info = json!({
        "video": state.video.clone().unwrap_or(Value::Null),
        "audio": state.audio.clone().unwrap_or(Value::Null),
    });
    let _ = event_sink.emit_media_info(&endpoint.endpoint_id, live, None, media_info);
}

fn set_lane_bitrate(slot: &mut Option<Value>, bitrate_kbps: Option<u64>) -> bool {
    let Some(Value::Object(fields)) = slot else {
        return false;
    };
    let old = fields.get("bitrate_kbps").cloned();
    match bitrate_kbps {
        Some(bitrate_kbps) => {
            fields.insert("bitrate_kbps".to_string(), json!(bitrate_kbps));
        }
        None => {
            fields.remove("bitrate_kbps");
        }
    }
    old != fields.get("bitrate_kbps").cloned()
}

#[derive(Clone, Copy)]
enum MediaLane {
    Video,
    Audio,
}

fn media_info_from_caps(caps: &gst::CapsRef) -> Option<(MediaLane, Value)> {
    let structure = caps.structure(0)?;
    let name = structure.name();
    let mut fields = Map::new();
    if name.starts_with("video/") {
        fields.insert("codec".to_string(), json!(video_codec(name.as_str())));
        insert_i32(&mut fields, structure, "width");
        insert_i32(&mut fields, structure, "height");
        if let Ok(fps) = structure.get::<gst::Fraction>("framerate") {
            fields.insert(
                "fps".to_string(),
                json!(fps.numer() as f64 / fps.denom() as f64),
            );
        }
        return Some((MediaLane::Video, Value::Object(fields)));
    }
    if name.starts_with("audio/") {
        fields.insert(
            "codec".to_string(),
            json!(audio_codec(name.as_str(), structure)),
        );
        insert_i32(&mut fields, structure, "channels");
        insert_i32(&mut fields, structure, "rate");
        return Some((MediaLane::Audio, Value::Object(fields)));
    }
    None
}

fn insert_i32(fields: &mut Map<String, Value>, structure: &gst::StructureRef, name: &str) {
    if let Ok(value) = structure.get::<i32>(name) {
        fields.insert(name.to_string(), json!(value));
    }
}

fn video_codec(name: &str) -> &str {
    match name {
        "video/x-h264" => "H.264",
        "video/x-h265" => "H.265",
        "video/x-vp9" => "VP9",
        _ => name,
    }
}

fn audio_codec(name: &str, structure: &gst::StructureRef) -> String {
    match name {
        "audio/mpeg" if structure.get::<i32>("mpegversion").ok() == Some(4) => "AAC".to_string(),
        "audio/mpeg" => "MPEG audio".to_string(),
        "audio/x-ac3" => "AC-3".to_string(),
        "audio/x-opus" => "Opus".to_string(),
        _ => name.to_string(),
    }
}

pub(crate) fn link_parsed_pad(
    bin: &gst::Bin,
    mux: &gst::Element,
    parsed_pad: &gst::Pad,
    target_duration_ms: u64,
    parsebin_name: &str,
) -> Result<(), HlsAdapterError> {
    if parsed_pad.is_linked() {
        return Ok(());
    }
    let suffix = sanitize_name(&format!("{parsebin_name}_{}", parsed_pad.name()));
    let queue = make_named_element("queue", &format!("hls_queue_{suffix}"), "HLS pacing queue")
        .map_err(|(code, detail)| HlsAdapterError::new(code, detail))?;
    queue.set_property("max-size-buffers", 0_u32);
    queue.set_property("max-size-bytes", 0_u32);
    queue.set_property(
        "max-size-time",
        target_duration_ms.saturating_mul(1_000_000),
    );
    let pacer = make_named_element("identity", &format!("hls_pacer_{suffix}"), "HLS pacer")
        .map_err(|(code, detail)| HlsAdapterError::new(code, detail))?;
    // HLS downloads whole segments in bursts; sync restores the timestamps before
    // unsynchronised sinks fan the program out to receivers.
    pacer.set_property("sync", true);
    let caps = caps_for_pad(parsed_pad)
        .ok_or_else(|| HlsAdapterError::new(ErrorCode::LinkFailed, "HLS parsed pad has no caps"))?;
    let parser = parser_for_caps(&caps);
    if let Some(parser) = parser.as_ref() {
        configure_parser(parser);
        bin.add_many([&queue, &pacer, parser])
            .map_err(runtime_error)?;
        gst::Element::link_many([&queue, &pacer, parser]).map_err(link_error)?;
    } else {
        bin.add_many([&queue, &pacer]).map_err(runtime_error)?;
        queue.link(&pacer).map_err(link_error)?;
    }
    let queue_sink = queue.static_pad("sink").ok_or_else(|| {
        HlsAdapterError::new(ErrorCode::LinkFailed, "HLS pacing queue has no sink pad")
    })?;
    let output_src = parser
        .as_ref()
        .map_or_else(
            || pacer.static_pad("src"),
            |parser| parser.static_pad("src"),
        )
        .ok_or_else(|| {
            HlsAdapterError::new(ErrorCode::LinkFailed, "HLS pacing chain has no src pad")
        })?;
    let mux_sink = mux.request_pad_simple("sink_%d").ok_or_else(|| {
        HlsAdapterError::new(ErrorCode::LinkFailed, "failed to request HLS mux sink pad")
    })?;
    if let Err(error) = parsed_pad.link(&queue_sink) {
        mux.release_request_pad(&mux_sink);
        let _ = bin.remove(&pacer);
        let _ = bin.remove(&queue);
        return Err(HlsAdapterError::new(
            ErrorCode::LinkFailed,
            format!("failed to link HLS parsebin pad to pacing queue: {error:?}"),
        ));
    }
    if let Err(error) = output_src.link(&mux_sink) {
        let _ = parsed_pad.unlink(&queue_sink);
        mux.release_request_pad(&mux_sink);
        let _ = bin.remove(&pacer);
        if let Some(parser) = parser.as_ref() {
            let _ = bin.remove(parser);
        }
        let _ = bin.remove(&queue);
        return Err(HlsAdapterError::new(
            ErrorCode::LinkFailed,
            format!("failed to link HLS pacer to MPEG-TS muxer: {error:?}"),
        ));
    }
    queue.sync_state_with_parent().map_err(runtime_error)?;
    pacer.sync_state_with_parent().map_err(runtime_error)?;
    if let Some(parser) = parser.as_ref() {
        parser.sync_state_with_parent().map_err(runtime_error)?;
    }
    Ok(())
}

fn caps_for_pad(pad: &gst::Pad) -> Option<gst::Caps> {
    if let Some(caps) = pad.current_caps().filter(|caps| !caps.is_empty()) {
        return Some(caps);
    }
    let caps = pad.query_caps(None);
    (!caps.is_empty()).then_some(caps)
}

fn parser_for_caps(caps: &gst::Caps) -> Option<gst::Element> {
    let structure = caps.structure(0)?;
    let parser_name = match structure.name().as_str() {
        "video/x-h264" => "h264parse",
        "video/x-h265" => "h265parse",
        "audio/mpeg" if structure.get::<i32>("mpegversion").ok() == Some(4) => "aacparse",
        "audio/x-adts" => "aacparse",
        _ => return None,
    };
    gst::ElementFactory::make(parser_name).build().ok()
}

fn configure_parser(parser: &gst::Element) {
    if parser.has_property("config-interval", None) {
        parser.set_property("config-interval", -1_i32);
    }
}

fn sanitize_name(name: &str) -> String {
    name.chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn runtime_error(error: impl std::fmt::Display) -> HlsAdapterError {
    HlsAdapterError::new(ErrorCode::RuntimeError, error.to_string())
}

fn link_error(error: impl std::fmt::Display) -> HlsAdapterError {
    HlsAdapterError::new(ErrorCode::LinkFailed, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{EndpointDirection, RouteIdentity, Transport};
    use crate::output::StatsWriter;

    struct MemoryWriter(Arc<Mutex<Vec<String>>>);

    impl StatsWriter for MemoryWriter {
        fn send_message(&mut self, message: &str) -> anyhow::Result<()> {
            self.0
                .lock()
                .expect("messages lock")
                .push(message.to_string());
            Ok(())
        }
    }

    #[test]
    fn media_info_maps_verified_hls_caps() {
        let _ = gst::init();
        let caps = gst::Caps::builder("video/x-h264")
            .field("width", 1920_i32)
            .field("height", 1080_i32)
            .field("framerate", gst::Fraction::new(30, 1))
            .build();
        let (_, info) = media_info_from_caps(&caps).expect("video info");
        assert_eq!(info["codec"], "H.264");
        assert_eq!(info["width"], 1920);
        assert_eq!(info["height"], 1080);
        assert_eq!(info["fps"], 30.0);
        assert!(!info
            .as_object()
            .expect("video info object")
            .contains_key("bitrate_kbps"));
    }

    #[test]
    fn media_info_maps_all_supported_video_codecs() {
        let _ = gst::init();
        for (caps_name, codec) in [
            ("video/x-h264", "H.264"),
            ("video/x-h265", "H.265"),
            ("video/x-vp9", "VP9"),
            ("video/x-vp8", "video/x-vp8"),
        ] {
            let caps = gst::Caps::builder(caps_name).build();
            let (lane, info) = media_info_from_caps(&caps).expect("video info");
            assert!(matches!(lane, MediaLane::Video));
            assert_eq!(info["codec"], codec);
        }
    }

    #[test]
    fn media_info_maps_all_supported_audio_codecs() {
        let _ = gst::init();
        let cases = [
            ("audio/mpeg", Some(4), "AAC"),
            ("audio/mpeg", Some(1), "MPEG audio"),
            ("audio/x-ac3", None, "AC-3"),
            ("audio/x-opus", None, "Opus"),
            ("audio/x-custom", None, "audio/x-custom"),
        ];
        for (caps_name, mpegversion, codec) in cases {
            let mut builder = gst::Caps::builder(caps_name);
            if let Some(mpegversion) = mpegversion {
                builder = builder.field("mpegversion", mpegversion);
            }
            let caps = builder.build();
            let (lane, info) = media_info_from_caps(&caps).expect("audio info");
            assert!(matches!(lane, MediaLane::Audio));
            assert_eq!(info["codec"], codec);
        }
    }

    #[test]
    fn media_info_omits_optional_caps_fields_and_preserves_fractional_framerate() {
        let _ = gst::init();
        let video_caps = gst::Caps::builder("video/x-h265")
            .field("framerate", gst::Fraction::new(30_000, 1_001))
            .build();
        let (_, video_info) = media_info_from_caps(&video_caps).expect("video info");
        assert_eq!(video_info["codec"], "H.265");
        assert_eq!(video_info["fps"], 30_000.0 / 1_001.0);
        assert!(!video_info
            .as_object()
            .expect("video object")
            .contains_key("width"));
        assert!(!video_info
            .as_object()
            .expect("video object")
            .contains_key("height"));

        let audio_caps = gst::Caps::builder("audio/x-opus").build();
        let (_, audio_info) = media_info_from_caps(&audio_caps).expect("audio info");
        assert_eq!(audio_info["codec"], "Opus");
        assert!(!audio_info
            .as_object()
            .expect("audio object")
            .contains_key("channels"));
        assert!(!audio_info
            .as_object()
            .expect("audio object")
            .contains_key("rate"));
    }

    #[test]
    fn media_info_rejects_empty_and_non_media_caps() {
        let _ = gst::init();
        assert!(media_info_from_caps(&gst::Caps::new_empty()).is_none());
        let unknown = gst::Caps::builder("application/x-custom").build();
        assert!(media_info_from_caps(&unknown).is_none());
    }

    #[test]
    fn validate_end_action_accepts_stop_and_rejects_hold_and_loop() {
        let uri = hydra_plan::HlsUri::new("http://127.0.0.1/playlist.m3u8").expect("uri");
        for (end_action, valid) in [
            (HlsEndAction::Stop, true),
            (HlsEndAction::Hold, false),
            (HlsEndAction::Loop, false),
        ] {
            let config = HlsSource::new(uri.clone(), false, None, end_action);
            let result = validate_end_action(&config);
            assert_eq!(result.is_ok(), valid);
            if !valid {
                let error = result.expect_err("unsupported end action");
                assert_eq!(error.code(), ErrorCode::UnsupportedGraph);
                assert_eq!(
                    error.detail(),
                    "HLS end_action hold and loop are not implemented"
                );
            }
        }
    }

    fn timing(pts: Option<Duration>, duration: Option<Duration>, bytes: u64) -> ProbeBufferTiming {
        ProbeBufferTiming {
            pts,
            duration,
            bytes,
        }
    }

    #[test]
    fn bitrate_accumulator_uses_media_time() {
        let mut accumulator = BitrateAccumulator::new(Duration::from_secs(5));
        accumulator.record(timing(
            Some(Duration::ZERO),
            Some(Duration::from_secs(1)),
            312_500,
        ));

        assert_eq!(accumulator.bitrate_kbps(), Some(2_500));
    }

    #[test]
    fn bitrate_accumulators_keep_video_and_audio_separate() {
        let mut video = BitrateAccumulator::new(Duration::from_secs(5));
        let mut audio = BitrateAccumulator::new(Duration::from_secs(5));
        video.record(timing(
            Some(Duration::ZERO),
            Some(Duration::from_secs(1)),
            125_000,
        ));
        audio.record(timing(
            Some(Duration::ZERO),
            Some(Duration::from_secs(1)),
            6_250,
        ));

        assert_eq!(video.bitrate_kbps(), Some(1_000));
        assert_eq!(audio.bitrate_kbps(), Some(50));
    }

    #[test]
    fn bitrate_accumulator_ignores_a_buffer_without_pts() {
        let mut accumulator = BitrateAccumulator::new(Duration::from_secs(5));
        accumulator.record(timing(None, Some(Duration::from_secs(1)), 125_000));

        assert_eq!(accumulator.bitrate_kbps(), None);
    }

    #[test]
    fn bitrate_accumulator_ignores_a_buffer_without_duration() {
        let mut accumulator = BitrateAccumulator::new(Duration::from_secs(5));
        accumulator.record(timing(Some(Duration::ZERO), None, 125_000));

        assert_eq!(accumulator.bitrate_kbps(), None);
    }

    #[test]
    fn bitrate_accumulator_resets_at_a_pts_discontinuity() {
        let mut accumulator = BitrateAccumulator::new(Duration::from_secs(5));
        accumulator.record(timing(
            Some(Duration::ZERO),
            Some(Duration::from_secs(1)),
            125_000,
        ));
        accumulator.record(timing(
            Some(Duration::from_secs(30)),
            Some(Duration::from_secs(1)),
            250_000,
        ));

        assert_eq!(accumulator.bitrate_kbps(), Some(2_000));
    }

    #[test]
    fn bitrate_accumulator_discards_samples_older_than_media_window() {
        let mut accumulator = BitrateAccumulator::new(Duration::from_secs(5));
        for second in 0..7 {
            accumulator.record(timing(
                Some(Duration::from_secs(second)),
                Some(Duration::from_secs(1)),
                125_000,
            ));
        }

        assert_eq!(accumulator.bitrate_kbps(), Some(1_000));
    }

    #[test]
    fn lane_bitrate_key_is_added_only_for_a_measurement() {
        let mut lane = Some(json!({"codec": "H.264"}));

        assert!(!set_lane_bitrate(&mut lane, None));
        assert!(!lane
            .as_ref()
            .expect("lane")
            .as_object()
            .expect("lane object")
            .contains_key("bitrate_kbps"));
        assert!(set_lane_bitrate(&mut lane, Some(2_480)));
        assert_eq!(lane.as_ref().expect("lane")["bitrate_kbps"], 2_480);
        assert!(set_lane_bitrate(&mut lane, None));
        assert!(!lane
            .as_ref()
            .expect("lane")
            .as_object()
            .expect("lane object")
            .contains_key("bitrate_kbps"));
    }

    #[test]
    fn periodic_media_info_emits_measured_lane_bitrate() {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Box<dyn StatsWriter> = Box::new(MemoryWriter(messages.clone()));
        let event_sink = EventSink::new(
            Arc::new(Mutex::new(writer)),
            RouteIdentity {
                route_id: "route-1".to_string(),
                config_revision: "rev-1".to_string(),
                process_instance_id: "proc-1".to_string(),
            },
        );
        let endpoint = EndpointDescriptor {
            bin_name: "source_youtube".to_string(),
            endpoint_id: "source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        {
            let mut state = state.lock().expect("state lock");
            state.video = Some(json!({"codec": "H.264"}));
            state.video_bitrate.record(timing(
                Some(Duration::ZERO),
                Some(Duration::from_secs(1)),
                125_000,
            ));
        }

        emit_periodic(&state, &event_sink, &endpoint, true);

        let payload: Value = serde_json::from_str(&messages.lock().expect("messages lock")[0])
            .expect("media info event");
        assert_eq!(payload["event"], "media_info");
        assert_eq!(payload["media_info"]["video"]["bitrate_kbps"], 1_000);
        assert!(payload["media_info"]["audio"].is_null());
    }

    #[test]
    fn periodic_media_info_omits_bitrate_for_a_lane_without_bytes() {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Box<dyn StatsWriter> = Box::new(MemoryWriter(messages.clone()));
        let event_sink = EventSink::new(
            Arc::new(Mutex::new(writer)),
            RouteIdentity {
                route_id: "route-1".to_string(),
                config_revision: "rev-1".to_string(),
                process_instance_id: "proc-1".to_string(),
            },
        );
        let endpoint = EndpointDescriptor {
            bin_name: "source_youtube".to_string(),
            endpoint_id: "source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        {
            let mut state = state.lock().expect("state lock");
            state.video = Some(json!({"codec": "H.264"}));
            state.audio = Some(json!({"codec": "AAC"}));
            state.video_bitrate.record(timing(
                Some(Duration::ZERO),
                Some(Duration::from_secs(1)),
                125_000,
            ));
        }

        emit_periodic(&state, &event_sink, &endpoint, true);

        let payload: Value = serde_json::from_str(&messages.lock().expect("messages lock")[0])
            .expect("media info event");
        assert_eq!(payload["media_info"]["video"]["bitrate_kbps"], 1_000);
        assert!(!payload["media_info"]["audio"]
            .as_object()
            .expect("audio info")
            .contains_key("bitrate_kbps"));
    }

    #[test]
    fn caps_change_clears_only_the_affected_lane_bitrate() {
        let _ = gst::init();
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Box<dyn StatsWriter> = Box::new(MemoryWriter(messages.clone()));
        let event_sink = EventSink::new(
            Arc::new(Mutex::new(writer)),
            RouteIdentity {
                route_id: "route-1".to_string(),
                config_revision: "rev-1".to_string(),
                process_instance_id: "proc-1".to_string(),
            },
        );
        let endpoint = EndpointDescriptor {
            bin_name: "source_youtube".to_string(),
            endpoint_id: "source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        let h264 = gst::Caps::builder("video/x-h264").build();
        let h265 = gst::Caps::builder("video/x-h265").build();
        emit_if_changed(
            &state,
            &event_sink,
            &endpoint,
            true,
            media_info_from_caps(&h264).expect("H.264 info"),
        );
        {
            let mut state = state.lock().expect("state lock");
            state.video_bitrate.record(timing(
                Some(Duration::ZERO),
                Some(Duration::from_secs(1)),
                125_000,
            ));
            state.audio = Some(json!({"codec": "AAC"}));
            state.audio_bitrate.record(timing(
                Some(Duration::ZERO),
                Some(Duration::from_secs(1)),
                6_250,
            ));
        }
        emit_if_changed(
            &state,
            &event_sink,
            &endpoint,
            true,
            media_info_from_caps(&h265).expect("H.265 info"),
        );

        let mut state = state.lock().expect("state lock");
        assert_eq!(state.video_bitrate.bitrate_kbps(), None);
        assert_eq!(state.audio_bitrate.bitrate_kbps(), Some(50));
        drop(state);
        let payload: Value = serde_json::from_str(
            messages
                .lock()
                .expect("messages lock")
                .last()
                .expect("event"),
        )
        .expect("media info event");
        assert_eq!(payload["media_info"]["video"]["codec"], "H.265");
        assert!(!payload["media_info"]["video"]
            .as_object()
            .expect("video info")
            .contains_key("bitrate_kbps"));
    }

    #[test]
    fn parsebin_monitor_is_registered_once() {
        let _ = gst::init();
        let parsebin = gst::ElementFactory::make("parsebin")
            .name("test_hls_parsebin")
            .build()
            .expect("parsebin");
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Box<dyn StatsWriter> = Box::new(MemoryWriter(messages));
        let event_sink = EventSink::new(
            Arc::new(Mutex::new(writer)),
            RouteIdentity {
                route_id: "route-1".to_string(),
                config_revision: "rev-1".to_string(),
                process_instance_id: "proc-1".to_string(),
            },
        );
        let endpoint = EndpointDescriptor {
            bin_name: "source_youtube".to_string(),
            endpoint_id: "source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };

        install_parsebin_monitor(
            &parsebin,
            state.clone(),
            event_sink.clone(),
            endpoint.clone(),
            true,
        );
        install_parsebin_monitor(&parsebin, state.clone(), event_sink, endpoint, true);

        assert_eq!(
            state.lock().expect("state lock").monitored_parsebins.len(),
            1
        );
    }

    #[test]
    fn caps_monitor_is_registered_once_per_pad() {
        let _ = gst::init();
        let pad = gst::Pad::new(gst::PadDirection::Src);
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Box<dyn StatsWriter> = Box::new(MemoryWriter(messages));
        let event_sink = EventSink::new(
            Arc::new(Mutex::new(writer)),
            RouteIdentity {
                route_id: "route-1".to_string(),
                config_revision: "rev-1".to_string(),
                process_instance_id: "proc-1".to_string(),
            },
        );
        let endpoint = EndpointDescriptor {
            bin_name: "source_youtube".to_string(),
            endpoint_id: "source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let caps = gst::Caps::builder("video/x-h264").build();

        install_caps_monitor(
            &pad,
            state.clone(),
            event_sink.clone(),
            endpoint.clone(),
            true,
        );
        install_caps_monitor(&pad, state.clone(), event_sink, endpoint, true);
        pad.set_active(true).expect("activate pad");
        let _ = pad.push_event(gst::event::Caps::new(&caps));
        let mut buffer = gst::Buffer::with_size(125_000).expect("buffer");
        buffer
            .get_mut()
            .expect("writable buffer")
            .set_pts(gst::ClockTime::from_seconds(0));
        buffer
            .get_mut()
            .expect("writable buffer")
            .set_duration(gst::ClockTime::from_seconds(1));
        let _ = pad.push(buffer);

        let mut state = state.lock().expect("state lock");
        assert_eq!(state.monitored_pads.len(), 1);
        assert_eq!(state.video_bitrate.bitrate_kbps(), Some(1_000));
    }

    #[test]
    fn bitrate_probe_is_registered_once_per_target_pad() {
        let _ = gst::init();
        let state = Arc::new(Mutex::new(MediaInfoState::default()));
        let pad = gst::Pad::new(gst::PadDirection::Src);

        assert!(claim_bitrate_pad(&state, &pad));
        assert!(!claim_bitrate_pad(&state, &pad));
        assert_eq!(
            state
                .lock()
                .expect("state lock")
                .monitored_bitrate_pads
                .len(),
            1
        );
    }

    #[test]
    fn bitrate_monitor_uses_the_pad_before_the_muxer() {
        let _ = gst::init();
        for factory in ["appsrc", "queue", "identity", "mpegtsmux"] {
            if gst::ElementFactory::find(factory).is_none() {
                return;
            }
        }
        let bin = gst::Bin::with_name("hls_monitor_test");
        let appsrc = gst::ElementFactory::make("appsrc")
            .name("hls_monitor_input")
            .build()
            .expect("appsrc");
        let queue = gst::ElementFactory::make("queue")
            .name("hls_monitor_queue")
            .build()
            .expect("queue");
        let pacer = gst::ElementFactory::make("identity")
            .name("hls_monitor_pacer")
            .build()
            .expect("identity");
        let mux = gst::ElementFactory::make("mpegtsmux")
            .name("hls_monitor_mux")
            .build()
            .expect("mpegtsmux");
        bin.add_many([&appsrc, &queue, &pacer, &mux])
            .expect("add monitor elements");
        gst::Element::link_many([&appsrc, &queue, &pacer]).expect("link monitor elements");
        let mux_sink = mux.request_pad_simple("sink_%d").expect("mux sink");
        pacer
            .static_pad("src")
            .expect("pacer src")
            .link(&mux_sink)
            .expect("link pacer to mux");

        let parsed_pad = appsrc.static_pad("src").expect("appsrc src");
        let bitrate_pad = downstream_mux_pad(&parsed_pad).expect("bitrate pad");

        assert_eq!(bitrate_pad.name(), "src");
        assert_eq!(
            bitrate_pad
                .parent()
                .expect("bitrate pad parent")
                .downcast::<gst::Element>()
                .expect("bitrate element")
                .name(),
            "hls_monitor_pacer"
        );
    }
}
