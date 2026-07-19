use std::fmt;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, RtmpEndpoint};
use serde_json::json;
use thiserror::Error;

use super::element::{link_detail, make_named_element, runtime_detail, set_property};
use crate::output::StatsWriter;

pub(crate) const RTMP_REMUX_DEFERRED_LINK_MAX_ATTEMPTS: u32 = 8;

/// Apply the typed RTMP location property.
pub fn apply(element: &gst::Element, config: &RtmpEndpoint) -> Result<(), (ErrorCode, String)> {
    set_property(element, "location", config.location().as_str())
}

pub fn configure_sink(element: &gst::Element) {
    element.set_property("sync", false);
    element.set_property("async", false);
}

#[derive(Debug, Error)]
#[error("{code}: {detail}")]
pub struct RtmpAdapterError {
    code: ErrorCode,
    detail: String,
}

impl RtmpAdapterError {
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

/// Typed destination remux link failures. Retryability and skip-non-AV are
/// properties of the variant, not string sentinels.
#[derive(Debug, Error)]
pub enum RtmpLinkError {
    #[error("no caps on parsebin pad")]
    NoCaps,
    #[error("skipping non A/V parsebin pad caps: {caps_name}")]
    SkipNonAv { caps_name: String },
    #[error("parsebin pad has no caps structure")]
    NoCapsStructure,
    #[error("parser has no sink pad")]
    ParserMissingSink,
    #[error("parser has no source pad")]
    ParserMissingSrc,
    #[error("failed to link parsebin to parser: {0:?}")]
    LinkParsebinToParser(gst::PadLinkError),
    #[error("failed to link parser to flvmux: {0:?}")]
    LinkParserToMux(gst::PadLinkError),
    #[error("failed to sync parser state: {0}")]
    SyncParser(#[source] glib::BoolError),
    #[error("failed to link parsebin to flvmux: {0:?}")]
    LinkParsebinToMux(gst::PadLinkError),
    #[error("{0}")]
    NotNegotiated(String),
    #[error("{0}")]
    Other(String),
}

impl RtmpLinkError {
    pub fn skip_non_av(&self) -> bool {
        matches!(self, Self::SkipNonAv { .. })
    }

    pub fn needs_caps_retry(&self) -> bool {
        matches!(self, Self::NoCaps)
    }

    pub fn is_retryable(&self) -> bool {
        !matches!(self, Self::SkipNonAv { .. } | Self::NotNegotiated(_))
    }

    fn from_link_failure(context: &str, error: gst::PadLinkError) -> Self {
        // Classify by the typed PadLinkError only — never by formatted strings.
        // PadLinkError has no NotNegotiated variant; wrap the typed error and keep
        // Noformat retryable so deferred remux can settle caps.
        match error {
            gst::PadLinkError::WrongHierarchy
            | gst::PadLinkError::WasLinked
            | gst::PadLinkError::WrongDirection
            | gst::PadLinkError::Noformat
            | gst::PadLinkError::Nosched
            | gst::PadLinkError::Refused => match context {
                "failed to link parsebin to parser" => Self::LinkParsebinToParser(error),
                "failed to link parser to flvmux" => Self::LinkParserToMux(error),
                "failed to link parsebin to flvmux" => Self::LinkParsebinToMux(error),
                _ => Self::Other(format!("{context}: {error:?}")),
            },
        }
    }
}

/// Adds the canonical RTMP source remux graph inside its endpoint bin.
pub fn build_source_contents(
    bin: &gst::Bin,
    source: &gst::Element,
) -> Result<Option<gst::Pad>, RtmpAdapterError> {
    let parsebin = make_element("parsebin", "rtmp_parsebin", "RTMP source parsebin")?;
    let mux = make_element("mpegtsmux", "rtmp_mpegtsmux", "RTMP source MPEG-TS muxer")?;
    bin.add_many([source, &parsebin, &mux])
        .map_err(runtime_error)?;
    source.link(&parsebin).map_err(link_error)?;
    connect_source_parsebin(bin, &parsebin, &mux);
    Ok(mux.static_pad("src"))
}

/// Adds the canonical RTMP destination remux graph inside its endpoint bin.
pub fn build_destination_contents(
    bin: &gst::Bin,
    queue: &gst::Element,
    sink: &gst::Element,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<Vec<(gst::Element, gst::Pad)>, RtmpAdapterError> {
    let suffix = sanitize_gst_element_suffix(bin.name().as_str());
    let parsebin = make_element(
        "parsebin",
        &rtmp_remux_element_name(&suffix, "parsebin"),
        "RTMP destination parsebin",
    )?;
    let mux = make_element(
        "flvmux",
        &rtmp_remux_element_name(&suffix, "flvmux"),
        "RTMP destination FLV muxer",
    )?;
    mux.set_property("streamable", true);
    bin.add_many([queue, &parsebin, &mux, sink])
        .map_err(runtime_error)?;
    queue.link(&parsebin).map_err(link_error)?;
    mux.link(sink).map_err(link_error)?;

    let video_pad = mux.request_pad_simple("video").ok_or_else(|| {
        RtmpAdapterError::new(
            ErrorCode::LinkFailed,
            "failed to request RTMP mux video pad",
        )
    })?;
    let audio_pad = match mux.request_pad_simple("audio") {
        Some(pad) => pad,
        None => {
            mux.release_request_pad(&video_pad);
            return Err(RtmpAdapterError::new(
                ErrorCode::LinkFailed,
                "failed to request RTMP mux audio pad",
            ));
        }
    };
    connect_destination_parsebin(bin, &parsebin, &video_pad, &audio_pad, writer);
    Ok(vec![(mux.clone(), video_pad), (mux, audio_pad)])
}

fn connect_source_parsebin(bin: &gst::Bin, parsebin: &gst::Element, mux: &gst::Element) {
    let bin_weak = bin.downgrade();
    let mux_weak = mux.downgrade();
    parsebin.connect_pad_added(move |_parsebin, src_pad| {
        let Some(bin) = bin_weak.upgrade() else {
            return;
        };
        let Some(mux) = mux_weak.upgrade() else {
            return;
        };
        if let Err(error) = link_source_pad_to_mux(&bin, &mux, src_pad) {
            eprintln!("failed to link RTMP parsed stream to MPEG-TS muxer: {error:#}");
        }
    });
}

fn link_source_pad_to_mux(
    bin: &gst::Bin,
    mux: &gst::Element,
    src_pad: &gst::Pad,
) -> Result<(), String> {
    if src_pad.is_linked() {
        return Ok(());
    }
    let caps = caps_for_pad(src_pad).ok_or_else(|| "no caps on parsebin pad".to_string())?;
    let queue = gst::ElementFactory::make("queue")
        .build()
        .map_err(|error| error.to_string())?;
    queue.set_property("max-size-buffers", 200_u32);
    queue.set_property("max-size-bytes", 0_u32);
    queue.set_property("max-size-time", 0_u64);
    let parser = parser_for_caps(&caps);
    bin.add(&queue).map_err(|error| error.to_string())?;
    if let Some(parser) = parser.as_ref() {
        if let Err(error) = bin.add(parser) {
            let _ = bin.remove(&queue);
            return Err(error.to_string());
        }
        configure_parser(parser);
    }

    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| "rtmp remux queue has no sink pad".to_string())?;
    let queue_src = queue
        .static_pad("src")
        .ok_or_else(|| "rtmp remux queue has no source pad".to_string())?;
    let mux_sink = mux
        .request_pad_simple("sink_%d")
        .ok_or_else(|| "failed to request mpegtsmux sink pad".to_string())?;
    let linked = src_pad.link(&queue_sink).is_ok()
        && if let Some(parser) = parser.as_ref() {
            let parser_sink = parser
                .static_pad("sink")
                .ok_or_else(|| "rtmp remux parser has no sink pad".to_string())?;
            let parser_src = parser
                .static_pad("src")
                .ok_or_else(|| "rtmp remux parser has no source pad".to_string())?;
            queue_src.link(&parser_sink).is_ok() && parser_src.link(&mux_sink).is_ok()
        } else {
            queue_src.link(&mux_sink).is_ok()
        };
    if !linked {
        mux.release_request_pad(&mux_sink);
        if let Some(parser) = parser.as_ref() {
            let _ = bin.remove(parser);
        }
        let _ = bin.remove(&queue);
        return Err("failed to link RTMP source remux chain".to_string());
    }
    queue
        .sync_state_with_parent()
        .map_err(|error| error.to_string())?;
    if let Some(parser) = parser.as_ref() {
        parser
            .sync_state_with_parent()
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn connect_destination_parsebin(
    bin: &gst::Bin,
    parsebin: &gst::Element,
    video_pad: &gst::Pad,
    audio_pad: &gst::Pad,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    let bin_weak = bin.downgrade();
    let video_pad = video_pad.clone();
    let audio_pad = audio_pad.clone();
    parsebin.connect_pad_added(move |_parsebin, src_pad| {
        let Some(bin) = bin_weak.upgrade() else {
            return;
        };
        handle_destination_pad_added(&bin, src_pad, &video_pad, &audio_pad, writer.clone());
    });
}

fn handle_destination_pad_added(
    bin: &gst::Bin,
    src_pad: &gst::Pad,
    video_pad: &gst::Pad,
    audio_pad: &gst::Pad,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    if src_pad.is_linked() {
        return;
    }
    match try_link_destination_pad(bin, src_pad, video_pad, audio_pad) {
        Ok(()) => emit_native_pipeline_log(
            &writer,
            "INFO",
            &format!("rtmp remux linked parsebin pad {}", src_pad.name()),
        ),
        Err(error) if error.skip_non_av() => {}
        Err(error) if error.needs_caps_retry() => {
            schedule_destination_pad_link(bin, src_pad, video_pad, audio_pad, writer);
        }
        Err(error) if error.is_retryable() => {
            emit_native_pipeline_log(
                &writer,
                "WARN",
                &format!("rtmp remux link failed, will retry: {error:#}"),
            );
            schedule_destination_pad_link(bin, src_pad, video_pad, audio_pad, writer);
        }
        Err(error) => emit_native_pipeline_log(
            &writer,
            "WARN",
            &format!("rtmp remux link failed: {error:#}"),
        ),
    }
}

fn schedule_destination_pad_link(
    bin: &gst::Bin,
    src_pad: &gst::Pad,
    video_pad: &gst::Pad,
    audio_pad: &gst::Pad,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    let bin_weak = bin.downgrade();
    let video_pad_weak = video_pad.downgrade();
    let audio_pad_weak = audio_pad.downgrade();
    let attempts = Arc::new(AtomicU32::new(0));
    let _ = src_pad.add_probe(
        gst::PadProbeType::EVENT_DOWNSTREAM | gst::PadProbeType::BUFFER,
        move |pad, info| {
            if pad.is_linked() {
                return gst::PadProbeReturn::Remove;
            }
            let ready = pad.current_caps().is_some_and(|caps| !caps.is_empty())
                || info
                    .event()
                    .is_some_and(|event| event.type_() == gst::EventType::Caps)
                || info.buffer().is_some();
            if !ready {
                return gst::PadProbeReturn::Ok;
            }
            let Some(bin) = bin_weak.upgrade() else {
                return gst::PadProbeReturn::Remove;
            };
            let Some(video_pad) = video_pad_weak.upgrade() else {
                return gst::PadProbeReturn::Remove;
            };
            let Some(audio_pad) = audio_pad_weak.upgrade() else {
                return gst::PadProbeReturn::Remove;
            };
            match try_link_destination_pad(&bin, pad, &video_pad, &audio_pad) {
                Ok(()) => gst::PadProbeReturn::Remove,
                Err(error) if !error.is_retryable() => {
                    emit_native_pipeline_log(
                        &writer,
                        "WARN",
                        &format!(
                            "rtmp remux deferred link gave up on pad {}: {error:#}",
                            pad.name()
                        ),
                    );
                    gst::PadProbeReturn::Remove
                }
                Err(error) => {
                    let attempt = attempts.fetch_add(1, Ordering::Relaxed) + 1;
                    if rtmp_deferred_link_attempt_exhausted(attempt) {
                        emit_native_pipeline_log(
                            &writer,
                            "WARN",
                            &format!(
                                "rtmp remux deferred link gave up on pad {} after {attempt} attempts: {error:#}",
                                pad.name()
                            ),
                        );
                        return gst::PadProbeReturn::Remove;
                    }
                    emit_native_pipeline_log(
                        &writer,
                        "WARN",
                        &format!(
                            "rtmp remux deferred link failed on pad {} (attempt {attempt}/{}), will retry: {error:#}",
                            pad.name(),
                            RTMP_REMUX_DEFERRED_LINK_MAX_ATTEMPTS
                        ),
                    );
                    gst::PadProbeReturn::Ok
                }
            }
        },
    );
}

fn try_link_destination_pad(
    bin: &gst::Bin,
    src_pad: &gst::Pad,
    video_pad: &gst::Pad,
    audio_pad: &gst::Pad,
) -> Result<(), RtmpLinkError> {
    if src_pad.is_linked() {
        return Ok(());
    }
    let caps = caps_for_pad(src_pad).ok_or(RtmpLinkError::NoCaps)?;
    let structure = caps.structure(0).ok_or(RtmpLinkError::NoCapsStructure)?;
    let mux_sink = if structure.name().starts_with("video/") {
        video_pad
    } else if structure.name().starts_with("audio/") {
        audio_pad
    } else {
        return Err(RtmpLinkError::SkipNonAv {
            caps_name: structure.name().to_string(),
        });
    };
    if mux_sink.is_linked() {
        return Ok(());
    }
    if let Some(parser) = parser_for_caps(&caps) {
        configure_parser(&parser);
        bin.add(&parser)
            .map_err(|error| RtmpLinkError::Other(error.to_string()))?;
        let parser_sink = parser
            .static_pad("sink")
            .ok_or(RtmpLinkError::ParserMissingSink)?;
        let parser_src = parser
            .static_pad("src")
            .ok_or(RtmpLinkError::ParserMissingSrc)?;
        if let Err(error) = src_pad.link(&parser_sink) {
            let _ = bin.remove(&parser);
            return Err(RtmpLinkError::from_link_failure(
                "failed to link parsebin to parser",
                error,
            ));
        }
        if let Err(error) = parser_src.link(mux_sink) {
            let _ = src_pad.unlink(&parser_sink);
            let _ = bin.remove(&parser);
            return Err(RtmpLinkError::from_link_failure(
                "failed to link parser to flvmux",
                error,
            ));
        }
        if let Err(error) = parser.sync_state_with_parent() {
            let _ = parser_src.unlink(mux_sink);
            let _ = src_pad.unlink(&parser_sink);
            let _ = bin.remove(&parser);
            return Err(RtmpLinkError::SyncParser(error));
        }
    } else if let Err(error) = src_pad.link(mux_sink) {
        return Err(RtmpLinkError::from_link_failure(
            "failed to link parsebin to flvmux",
            error,
        ));
    }
    Ok(())
}

fn caps_for_pad(pad: &gst::Pad) -> Option<gst::Caps> {
    if let Some(caps) = pad.current_caps() {
        if !caps.is_empty() {
            return Some(caps);
        }
    }
    let caps = pad.query_caps(None);
    (!caps.is_empty()).then_some(caps)
}

fn parser_for_caps(caps: &gst::Caps) -> Option<gst::Element> {
    let structure = caps.structure(0)?;
    let parser_name = match structure.name().as_str() {
        "video/x-h264" => "h264parse",
        "video/x-h265" => "h265parse",
        "video/x-h266" => "h266parse",
        "video/mpeg" => "mpegvideoparse",
        "audio/mpeg" => match structure.get::<i32>("mpegversion").ok() {
            Some(1) => "mpegaudioparse",
            Some(2) | Some(4) => "aacparse",
            _ => return None,
        },
        "audio/x-adts" => "aacparse",
        "audio/x-ac3" => "ac3parse",
        "audio/x-dts" => "dtsparse",
        _ => return None,
    };
    gst::ElementFactory::make(parser_name).build().ok()
}

fn configure_parser(parser: &gst::Element) {
    if parser.has_property("config-interval", None) {
        parser.set_property("config-interval", -1_i32);
    }
}

fn make_element(factory: &str, name: &str, role: &str) -> Result<gst::Element, RtmpAdapterError> {
    make_named_element(factory, name, role)
        .map_err(|(code, detail)| RtmpAdapterError::new(code, detail))
}

fn runtime_error(error: impl fmt::Display) -> RtmpAdapterError {
    let (code, detail) = runtime_detail(error);
    RtmpAdapterError::new(code, detail)
}

fn link_error(error: impl fmt::Display) -> RtmpAdapterError {
    let (code, detail) = link_detail(error);
    RtmpAdapterError::new(code, detail)
}

fn rtmp_remux_element_name(suffix: &str, element: &str) -> String {
    format!("rtmp_out_{element}_{suffix}")
}

pub(crate) fn sanitize_gst_element_suffix(raw: &str) -> String {
    let sanitized: String = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect();
    if sanitized
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic())
    {
        sanitized
    } else {
        format!("d_{sanitized}")
    }
}

pub(crate) fn rtmp_deferred_link_attempt_exhausted(attempt: u32) -> bool {
    attempt >= RTMP_REMUX_DEFERRED_LINK_MAX_ATTEMPTS
}

fn emit_native_pipeline_log(writer: &Arc<Mutex<Box<dyn StatsWriter>>>, level: &str, message: &str) {
    let payload = json!({
        "event": "pipeline_log",
        "level": level,
        "category": "rtmp_remux",
        "element": "parsebin",
        "file": "native/src/pipeline.rs",
        "function": "add_rtmp_sink_remux_path",
        "message": message,
    })
    .to_string();
    if let Ok(mut guard) = writer.lock() {
        let _ = guard.send_message(&payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::StdoutWriter;

    fn writer() -> Arc<Mutex<Box<dyn StatsWriter>>> {
        Arc::new(Mutex::new(Box::new(StdoutWriter::new())))
    }

    #[test]
    fn canonical_bin_graph_uses_stable_element_names_and_records_mux_pads() {
        let _ = gst::init();
        let source_bin = gst::Bin::with_name("source_route_a");
        let source = gst::ElementFactory::make("fakesrc")
            .build()
            .expect("source");
        build_source_contents(&source_bin, &source).expect("source contents");
        assert!(source_bin.by_name("rtmp_parsebin").is_some());
        assert!(source_bin.by_name("rtmp_mpegtsmux").is_some());

        let dest_bin = gst::Bin::with_name("dest_3_route_a");
        let queue = gst::ElementFactory::make("queue").build().expect("queue");
        let sink = gst::ElementFactory::make("fakesink").build().expect("sink");
        let requested = build_destination_contents(&dest_bin, &queue, &sink, writer())
            .expect("destination contents");
        assert!(dest_bin
            .by_name("rtmp_out_parsebin_dest_3_route_a")
            .is_some());
        assert!(dest_bin.by_name("rtmp_out_flvmux_dest_3_route_a").is_some());
        assert_eq!(requested.len(), 2);
        for (element, pad) in requested {
            element.release_request_pad(&pad);
        }
    }

    #[test]
    fn parser_selection_is_caps_driven() {
        let _ = gst::init();
        let h264 = gst::Caps::builder("video/x-h264").build();
        let raw = gst::Caps::builder("video/x-raw").build();
        assert_eq!(
            parser_for_caps(&h264)
                .and_then(|parser| parser.factory())
                .map(|factory| factory.name().to_string()),
            Some("h264parse".to_string())
        );
        assert!(parser_for_caps(&raw).is_none());
    }

    #[test]
    fn permanent_pad_link_errors_are_not_retryable() {
        let error =
            RtmpLinkError::NotNegotiated("NotNegotiated while linking parsebin to mux".to_string());
        assert!(!error.is_retryable());
        assert!(!RtmpLinkError::SkipNonAv {
            caps_name: "application/x-subtitle".to_string()
        }
        .is_retryable());
        assert!(RtmpLinkError::NoCaps.is_retryable());
        assert!(RtmpLinkError::NoCaps.needs_caps_retry());
        assert!(RtmpLinkError::SkipNonAv {
            caps_name: "application/x-subtitle".to_string()
        }
        .skip_non_av());
    }

    #[test]
    fn from_link_failure_classifies_by_typed_pad_link_error() {
        let noformat = RtmpLinkError::from_link_failure(
            "failed to link parsebin to flvmux",
            gst::PadLinkError::Noformat,
        );
        assert!(matches!(
            noformat,
            RtmpLinkError::LinkParsebinToMux(gst::PadLinkError::Noformat)
        ));
        assert!(noformat.is_retryable());

        let refused = RtmpLinkError::from_link_failure(
            "failed to link parsebin to parser",
            gst::PadLinkError::Refused,
        );
        assert!(matches!(
            refused,
            RtmpLinkError::LinkParsebinToParser(gst::PadLinkError::Refused)
        ));
        assert!(refused.is_retryable());
    }

    #[test]
    fn deferred_link_retries_are_bounded() {
        assert!(!rtmp_deferred_link_attempt_exhausted(
            RTMP_REMUX_DEFERRED_LINK_MAX_ATTEMPTS - 1
        ));
        assert!(rtmp_deferred_link_attempt_exhausted(
            RTMP_REMUX_DEFERRED_LINK_MAX_ATTEMPTS
        ));
    }

    #[test]
    fn element_suffixes_are_valid_gstreamer_names() {
        assert_eq!(
            sanitize_gst_element_suffix("route-1/output"),
            "route_1_output"
        );
        assert_eq!(sanitize_gst_element_suffix("1-route"), "d_1_route");
    }
}
