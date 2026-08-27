use std::sync::{Arc, Mutex};

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, HlsEndAction, HlsSource};
use serde_json::{json, Map, Value};
use thiserror::Error;

use super::element::{make_named_element, set_property};
use crate::events::EventSink;
use crate::runtime::EndpointDescriptor;

const DEFAULT_TARGET_DURATION_MS: u64 = 5_000;
const EOS_POLICY_DATA_KEY: &str = "hydra-hls-eos-policy";

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
        let state_for_added = state.clone();
        let sink_for_added = event_sink.clone();
        let endpoint_for_added = endpoint.clone();
        element.connect_pad_added(move |_parsebin, pad| {
            install_caps_monitor(
                pad,
                state_for_added.clone(),
                sink_for_added.clone(),
                endpoint_for_added.clone(),
                live,
            );
        });
        for pad in element.src_pads() {
            install_caps_monitor(
                &pad,
                state.clone(),
                event_sink.clone(),
                endpoint.clone(),
                live,
            );
        }
    }
    let parent_for_new = parent.clone();
    let state_for_new = state;
    let sink_for_new = event_sink;
    let endpoint_for_new = endpoint;
    source.connect_pad_added(move |_source, _pad| {
        for element in parent_for_new
            .iterate_recurse()
            .into_iter()
            .filter_map(Result::ok)
            .filter(|element| {
                element
                    .factory()
                    .is_some_and(|factory| factory.name() == "parsebin")
            })
        {
            let state_for_added = state_for_new.clone();
            let sink_for_added = sink_for_new.clone();
            let endpoint_for_added = endpoint_for_new.clone();
            element.connect_pad_added(move |_parsebin, pad| {
                install_caps_monitor(
                    pad,
                    state_for_added.clone(),
                    sink_for_added.clone(),
                    endpoint_for_added.clone(),
                    live,
                );
            });
        }
    });
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
        if let Some(info) = media_info_from_caps(caps_event.caps()) {
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
    if let Some(caps) = pad.current_caps().filter(|caps| !caps.is_empty()) {
        if let Some(info) = media_info_from_caps(&caps) {
            emit_if_changed(&state, &event_sink, &endpoint, live, info);
        }
    }
}

#[derive(Default)]
struct MediaInfoState {
    video: Option<Value>,
    audio: Option<Value>,
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
        MediaLane::Video => &mut state.video,
        MediaLane::Audio => &mut state.audio,
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
    }
}
