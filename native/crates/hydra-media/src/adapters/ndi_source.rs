use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, NdiSource, QueueClass, RequiredMedia, TrackNeed};
use thiserror::Error;

use super::element::{
    link_detail, make_element as make_element_pair, runtime_detail, set_property,
};
use crate::branch::{configure_queue, profiles_for, QueueProfile, QueueProfiles};

// Provisional default pending benchmarking.
const VIDEO_CAPS_FORMAT: &str = "UYVY";
// Provisional default pending benchmarking.
const AUDIO_CAPS_FORMAT: &str = "F32LE";
pub(crate) const NDI_ERROR_DETAILS_NAME: &str = "hydra-ndi-source-error";
pub(crate) const NDI_ERROR_REASON_FIELD: &str = "reason";
pub const NDI_REQUIRED_VIDEO_REASON: i32 = 1;
pub const NDI_REQUIRED_AUDIO_REASON: i32 = 2;
pub const NDI_RECEIVE_TIMEOUT_REASON: i32 = 3;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum NdiTrack {
    Video,
    Audio,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrackReadiness {
    pub caps_seen: bool,
    pub buffer_seen: bool,
    pub deadline_ms: u64,
}

impl TrackReadiness {
    pub const fn new(deadline_ms: u64) -> Self {
        Self {
            caps_seen: false,
            buffer_seen: false,
            deadline_ms,
        }
    }

    pub fn observe_caps(&mut self, fixed: bool) {
        self.caps_seen |= fixed;
    }

    pub fn observe_buffer(&mut self) {
        self.buffer_seen = true;
    }

    pub const fn ready(self) -> bool {
        self.caps_seen && self.buffer_seen
    }

    pub const fn deadline_expired(self, elapsed_ms: u64) -> bool {
        elapsed_ms >= self.deadline_ms && !self.ready()
    }
}

#[derive(Debug, Error)]
#[error("{code}: {detail}")]
pub struct NdiAdapterError {
    code: ErrorCode,
    detail: String,
}

impl NdiAdapterError {
    pub fn new(code: ErrorCode, detail: impl Into<String>) -> Self {
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

pub struct NdiSourceBin {
    pub bin: gst::Bin,
    pub source: gst::Element,
    pub output_pads: Vec<(NdiTrack, gst::Pad)>,
    pub readiness: NdiReadinessMonitor,
}

#[derive(Clone)]
pub struct NdiReadinessMonitor {
    source: gst::Element,
    readiness: Arc<Mutex<ReadinessState>>,
    started: Arc<AtomicBool>,
    last_activity: Arc<Mutex<Option<Instant>>>,
    timeout_ms: u64,
}

impl NdiReadinessMonitor {
    /// True once `arm` has started the track discovery deadline.
    pub fn armed(&self) -> bool {
        self.started.load(Ordering::Acquire)
    }

    pub fn arm(&self, pipeline: &gst::Pipeline) {
        self.started.store(true, Ordering::Release);
        if let Ok(mut last_activity) = self.last_activity.lock() {
            *last_activity = Some(Instant::now());
        }
        let source = self.source.clone();
        let readiness = self.readiness.clone();
        let pipeline = pipeline.clone();
        let timeout_ms = self.timeout_ms;

        glib::timeout_add_once(Duration::from_millis(timeout_ms), move || {
            if pipeline.current_state() == gst::State::Null {
                return;
            }
            let missing = readiness
                .lock()
                .ok()
                .and_then(|state| state.missing_required_track(timeout_ms));
            let Some(track) = missing else {
                return;
            };
            let (reason, detail) = match track {
                NdiTrack::Video => (
                    NDI_REQUIRED_VIDEO_REASON,
                    "required NDI video did not produce fixed caps and a buffer before the discovery deadline",
                ),
                NdiTrack::Audio => (
                    NDI_REQUIRED_AUDIO_REASON,
                    "required NDI audio did not produce fixed caps and a buffer before the discovery deadline",
                ),
            };
            let details = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
                .field(NDI_ERROR_REASON_FIELD, reason)
                .build();
            gst::element_error!(
                source,
                gst::LibraryError::Settings,
                ("{detail}"),
                details: details
            );
        });
    }
}

#[derive(Debug)]
struct ReadinessState {
    media: RequiredMedia,
    video: TrackReadiness,
    audio: TrackReadiness,
}

impl ReadinessState {
    fn video_required(&self) -> bool {
        matches!(self.media.video, TrackNeed::Required)
    }

    fn audio_required(&self) -> bool {
        matches!(self.media.audio, TrackNeed::Required)
    }

    fn missing_required_track(&self, elapsed_ms: u64) -> Option<NdiTrack> {
        if self.video_required() && self.video.deadline_expired(elapsed_ms) {
            Some(NdiTrack::Video)
        } else if self.audio_required() && self.audio.deadline_expired(elapsed_ms) {
            Some(NdiTrack::Audio)
        } else {
            None
        }
    }

    fn track_mut(&mut self, track: NdiTrack) -> &mut TrackReadiness {
        match track {
            NdiTrack::Video => &mut self.video,
            NdiTrack::Audio => &mut self.audio,
        }
    }
}

pub fn build(
    config: &NdiSource,
    media: RequiredMedia,
    bin_name: &str,
) -> Result<NdiSourceBin, NdiAdapterError> {
    let bin = gst::Bin::with_name(bin_name);
    let source = make_element("ndisrc", "NDI source")?;
    let demux = make_element("ndisrcdemux", "NDI source demuxer")?;
    apply_properties(&source, config)?;
    let last_activity = Arc::new(Mutex::new(None));
    attach_runtime_timeout_probe(
        &source,
        config.receive_timeout_ms().get(),
        last_activity.clone(),
    )?;
    bin.add_many([&source, &demux]).map_err(runtime_error)?;
    source.link(&demux).map_err(link_error)?;

    let timeout_ms = config.track_discovery_timeout_ms().get();
    let readiness = Arc::new(Mutex::new(ReadinessState {
        media,
        video: TrackReadiness::new(timeout_ms),
        audio: TrackReadiness::new(timeout_ms),
    }));
    let started = Arc::new(AtomicBool::new(false));
    let mut output_pads = Vec::new();
    let video_sink = if media.has_video() {
        let chain = build_video_chain(&bin)?;
        output_pads.push((NdiTrack::Video, chain.output_pad));
        Some(chain.input_pad)
    } else {
        None
    };
    let audio_sink = if media.has_audio() {
        let chain = build_audio_chain(&bin)?;
        output_pads.push((NdiTrack::Audio, chain.output_pad));
        Some(chain.input_pad)
    } else {
        None
    };

    connect_dynamic_pads(
        &demux,
        video_sink,
        audio_sink,
        media,
        readiness.clone(),
        started.clone(),
    );
    demux.connect_no_more_pads(|_| {
        eprintln!("NDI demux emitted no-more-pads; readiness remains caps-and-buffer based");
    });

    Ok(NdiSourceBin {
        bin,
        source: source.clone(),
        output_pads,
        readiness: NdiReadinessMonitor {
            source,
            readiness,
            started,
            last_activity,
            timeout_ms,
        },
    })
}

pub fn classify_readiness_details(details: Option<&gst::StructureRef>) -> Option<ErrorCode> {
    let details = details?;
    if details.name() != NDI_ERROR_DETAILS_NAME {
        return None;
    }
    match details.get::<i32>(NDI_ERROR_REASON_FIELD).ok()? {
        NDI_REQUIRED_VIDEO_REASON => Some(ErrorCode::NdiRequiredVideoMissing),
        NDI_REQUIRED_AUDIO_REASON => Some(ErrorCode::NdiRequiredAudioMissing),
        NDI_RECEIVE_TIMEOUT_REASON => Some(ErrorCode::NdiReceiveTimeout),
        _ => None,
    }
}

fn attach_runtime_timeout_probe(
    source: &gst::Element,
    receive_timeout_ms: u64,
    last_activity: Arc<Mutex<Option<Instant>>>,
) -> Result<(), NdiAdapterError> {
    let source_pad = source.static_pad("src").ok_or_else(|| {
        NdiAdapterError::new(ErrorCode::LinkFailed, "NDI source has no static source pad")
    })?;
    let source_weak = source.downgrade();
    source_pad.add_probe(
        gst::PadProbeType::BUFFER
            | gst::PadProbeType::BUFFER_LIST
            | gst::PadProbeType::EVENT_DOWNSTREAM,
        move |_pad, info| {
            if info.buffer().is_some() || info.buffer_list().is_some() {
                if let Ok(mut activity) = last_activity.lock() {
                    *activity = Some(Instant::now());
                }
                return gst::PadProbeReturn::Ok;
            }
            let is_eos = info
                .data
                .as_ref()
                .is_some_and(|data| matches!(data, gst::PadProbeData::Event(event) if matches!(event.view(), gst::EventView::Eos(_))));
            if !is_eos {
                return gst::PadProbeReturn::Ok;
            }
            let timed_out = last_activity
                .lock()
                .ok()
                .and_then(|activity| *activity)
                .is_some_and(|activity| {
                    activity.elapsed() >= Duration::from_millis(receive_timeout_ms)
                });
            if !timed_out {
                return gst::PadProbeReturn::Ok;
            }
            let Some(source) = source_weak.upgrade() else {
                return gst::PadProbeReturn::Remove;
            };
            let details = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
                .field(NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON)
                .build();
            gst::element_error!(
                source,
                gst::ResourceError::Read,
                ("NDI source receive deadline expired"),
                details: details
            );
            gst::PadProbeReturn::Drop
        },
    );
    Ok(())
}

pub(crate) fn configure_raw_queue(
    queue: &gst::Element,
    track: NdiTrack,
    profile: QueueProfile,
) -> Option<Arc<AtomicU64>> {
    configure_queue(queue, profile);

    if track != NdiTrack::Video {
        return None;
    }
    let drops = Arc::new(AtomicU64::new(0));
    let drops_ref = drops.clone();
    queue.connect("overrun", false, move |_| {
        drops_ref.fetch_add(1, Ordering::Relaxed);
        None
    });
    Some(drops)
}

struct TrackChain {
    input_pad: gst::Pad,
    output_pad: gst::Pad,
}

fn build_video_chain(bin: &gst::Bin) -> Result<TrackChain, NdiAdapterError> {
    let queue = make_element("queue", "NDI video queue")?;
    let convert = make_element("videoconvert", "NDI video converter")?;
    let capsfilter = make_element("capsfilter", "NDI video caps filter")?;
    configure_queue(&queue, source_queue_profile(NdiTrack::Video));
    let caps = gst::Caps::builder("video/x-raw")
        .field("format", VIDEO_CAPS_FORMAT)
        .build();
    capsfilter.set_property("caps", caps);
    bin.add_many([&queue, &convert, &capsfilter])
        .map_err(runtime_error)?;
    gst::Element::link_many([&queue, &convert, &capsfilter]).map_err(link_error)?;
    add_track_ghost_pad(bin, NdiTrack::Video, &queue, &capsfilter)
}

fn build_audio_chain(bin: &gst::Bin) -> Result<TrackChain, NdiAdapterError> {
    let queue = make_element("queue", "NDI audio queue")?;
    let convert = make_element("audioconvert", "NDI audio converter")?;
    let resample = make_element("audioresample", "NDI audio resampler")?;
    let capsfilter = make_element("capsfilter", "NDI audio caps filter")?;
    configure_queue(&queue, source_queue_profile(NdiTrack::Audio));
    let caps = gst::Caps::builder("audio/x-raw")
        .field("format", AUDIO_CAPS_FORMAT)
        .field("layout", "interleaved")
        .build();
    capsfilter.set_property("caps", caps);
    bin.add_many([&queue, &convert, &resample, &capsfilter])
        .map_err(runtime_error)?;
    gst::Element::link_many([&queue, &convert, &resample, &capsfilter]).map_err(link_error)?;
    add_track_ghost_pad(bin, NdiTrack::Audio, &queue, &capsfilter)
}

fn source_queue_profile(track: NdiTrack) -> QueueProfile {
    let QueueProfiles::NdiRaw { video, audio } = profiles_for(QueueClass::NdiRaw) else {
        unreachable!("NDI raw queue class must map to raw queue profiles");
    };
    match track {
        NdiTrack::Video => video,
        NdiTrack::Audio => audio,
    }
}

fn add_track_ghost_pad(
    bin: &gst::Bin,
    track: NdiTrack,
    first: &gst::Element,
    last: &gst::Element,
) -> Result<TrackChain, NdiAdapterError> {
    let input_pad = first.static_pad("sink").ok_or_else(|| {
        NdiAdapterError::new(ErrorCode::LinkFailed, "track queue has no sink pad")
    })?;
    let output_target = last.static_pad("src").ok_or_else(|| {
        NdiAdapterError::new(ErrorCode::LinkFailed, "track caps filter has no source pad")
    })?;
    let name = match track {
        NdiTrack::Video => "video",
        NdiTrack::Audio => "audio",
    };
    let ghost = gst::GhostPad::builder_with_target(&output_target)
        .map_err(runtime_error)?
        .name(name)
        .build();
    bin.add_pad(&ghost).map_err(runtime_error)?;
    Ok(TrackChain {
        input_pad,
        output_pad: ghost.upcast(),
    })
}

fn connect_dynamic_pads(
    demux: &gst::Element,
    video_sink: Option<gst::Pad>,
    audio_sink: Option<gst::Pad>,
    media: RequiredMedia,
    readiness: Arc<Mutex<ReadinessState>>,
    started: Arc<AtomicBool>,
) {
    demux.connect_pad_added(move |demux, source_pad| {
        let (track, target, optional) = match source_pad.name().as_str() {
            "video" => (NdiTrack::Video, video_sink.as_ref(), media.video_optional()),
            "audio" => (NdiTrack::Audio, audio_sink.as_ref(), media.audio_optional()),
            unknown => {
                gst::element_error!(
                    demux,
                    gst::CoreError::Negotiation,
                    ("NDI demux produced unknown pad {unknown}")
                );
                return;
            }
        };
        let Some(target) = target else {
            return;
        };
        // Optional tracks that appear after PLAYING are ignored for this process instance.
        if optional && started.load(Ordering::Acquire) {
            return;
        }
        if target.is_linked() {
            gst::element_error!(
                demux,
                gst::CoreError::Negotiation,
                ("NDI demux produced duplicate {} pad", source_pad.name())
            );
            return;
        }

        let readiness_ref = readiness.clone();
        source_pad.add_probe(
            gst::PadProbeType::EVENT_DOWNSTREAM
                | gst::PadProbeType::BUFFER
                | gst::PadProbeType::BUFFER_LIST,
            move |_pad, info| {
                if let Ok(mut state) = readiness_ref.lock() {
                    if info.buffer().is_some() || info.buffer_list().is_some() {
                        state.track_mut(track).observe_buffer();
                    }
                    if let Some(gst::PadProbeData::Event(event)) = info.data.as_ref() {
                        if let gst::EventView::Caps(caps) = event.view() {
                            state.track_mut(track).observe_caps(caps.caps().is_fixed());
                        }
                    }
                }
                gst::PadProbeReturn::Ok
            },
        );
        if source_pad.link(target).is_err() {
            gst::element_error!(
                demux,
                gst::CoreError::Negotiation,
                ("failed to link NDI {} pad", source_pad.name())
            );
        }
    });
}

fn apply_properties(source: &gst::Element, config: &NdiSource) -> Result<(), NdiAdapterError> {
    set_ndi_property(source, "bandwidth", config.bandwidth().property_value())?;
    set_enum_property(
        source,
        "color-format",
        config.color_format().as_str(),
        ErrorCode::NdiPluginIncompatible,
    )?;
    // Absent timestamp_mode: leave the element's own default in place.
    if let Some(mode) = config.timestamp_mode() {
        set_enum_property(
            source,
            "timestamp-mode",
            mode.as_str(),
            ErrorCode::ConfigInvalid,
        )?;
    }
    if let Some(name) = config.source_name() {
        set_ndi_property(source, "ndi-name", name)?;
    } else if let Some(address) = config.url_address() {
        set_ndi_property(source, "url-address", address)?;
    }
    set_ndi_property(source, "receiver-ndi-name", config.receiver_name())?;
    set_ndi_property(
        source,
        "connect-timeout",
        config.connect_timeout_ms().get() as u32,
    )?;
    set_ndi_property(source, "timeout", config.receive_timeout_ms().get() as u32)?;
    set_ndi_property(source, "max-queue-length", config.max_queue_length().get())?;
    Ok(())
}

fn set_ndi_property(
    element: &gst::Element,
    property: &str,
    value: impl glib::value::ToValue,
) -> Result<(), NdiAdapterError> {
    set_property(element, property, value)
        .map_err(|(code, detail)| NdiAdapterError::new(code, detail))
}

fn set_enum_property(
    element: &gst::Element,
    property: &str,
    value: &str,
    failure_code: ErrorCode,
) -> Result<(), NdiAdapterError> {
    let pspec = element.find_property(property).ok_or_else(|| {
        NdiAdapterError::new(
            failure_code,
            format!("NDI plugin has no {property} property"),
        )
    })?;
    let enum_spec = pspec.downcast_ref::<glib::ParamSpecEnum>().ok_or_else(|| {
        NdiAdapterError::new(
            failure_code,
            format!("NDI plugin property {property} is not an enum"),
        )
    })?;
    let enum_class = enum_spec.enum_class();
    if enum_class.value_by_nick(value).is_none() {
        let accepted = enum_class
            .values()
            .iter()
            .map(|entry| entry.nick())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(NdiAdapterError::new(
            failure_code,
            format!("invalid {property} value {value}; accepted values: {accepted}"),
        ));
    }
    element.set_property_from_str(property, value);
    Ok(())
}

fn make_element(factory: &str, role: &str) -> Result<gst::Element, NdiAdapterError> {
    make_element_pair(factory, role).map_err(|(code, detail)| NdiAdapterError::new(code, detail))
}

fn runtime_error(error: impl std::fmt::Display) -> NdiAdapterError {
    let (code, detail) = runtime_detail(error);
    NdiAdapterError::new(code, detail)
}

fn link_error(error: impl std::fmt::Display) -> NdiAdapterError {
    let (code, detail) = link_detail(error);
    NdiAdapterError::new(code, detail)
}

#[cfg(test)]
mod tests {
    use hydra_plan::{
        BoundedMs, MaxQueueLength, MediaPolicy, NdiBandwidth, NdiColorFormat, NdiTimestampMode,
        RequiredMedia,
    };

    use super::*;

    #[test]
    fn readiness_derives_required_flags_from_required_media() {
        let deadline = 1_000;
        let mut state = ReadinessState {
            media: RequiredMedia::from(MediaPolicy::VideoRequiredAudioOptional),
            video: TrackReadiness::new(deadline),
            audio: TrackReadiness::new(deadline),
        };
        assert!(state.video_required());
        assert!(!state.audio_required());
        assert_eq!(
            state.missing_required_track(deadline),
            Some(NdiTrack::Video)
        );
        state.video.observe_caps(true);
        state.video.observe_buffer();
        assert_eq!(state.missing_required_track(deadline), None);
    }

    #[test]
    fn track_readiness_requires_fixed_caps_and_first_buffer_before_deadline() {
        let mut track = TrackReadiness::new(1_000);
        assert!(!track.ready());
        track.observe_caps(false);
        track.observe_buffer();
        assert!(!track.ready());
        assert!(track.deadline_expired(1_000));
        track.observe_caps(true);
        assert!(track.ready());
        assert!(!track.deadline_expired(1_000));
    }

    #[test]
    fn ndi_queue_profiles_set_all_three_limits_and_leak_modes() {
        let _ = gst::init();
        let video = gst::ElementFactory::make("queue")
            .build()
            .expect("video queue");
        let audio = gst::ElementFactory::make("queue")
            .build()
            .expect("audio queue");
        assert!(configure_raw_queue(
            &video,
            NdiTrack::Video,
            source_queue_profile(NdiTrack::Video),
        )
        .is_some());
        assert!(configure_raw_queue(
            &audio,
            NdiTrack::Audio,
            source_queue_profile(NdiTrack::Audio),
        )
        .is_none());

        assert_eq!(video.property::<u32>("max-size-buffers"), 8);
        assert_eq!(video.property::<u32>("max-size-bytes"), 0);
        assert_eq!(video.property::<u64>("max-size-time"), 0);
        assert_eq!(enum_property_nick(&video, "leaky"), "downstream");
        assert_eq!(audio.property::<u32>("max-size-buffers"), 32);
        assert_eq!(audio.property::<u32>("max-size-bytes"), 0);
        assert_eq!(audio.property::<u64>("max-size-time"), 0);
        assert_eq!(enum_property_nick(&audio, "leaky"), "no");
    }

    #[test]
    fn ndi_source_bin_builds_when_plugin_is_available() {
        let _ = gst::init();
        if gst::ElementFactory::find("ndisrc").is_none() {
            eprintln!("skipped: ndi plugin absent");
            return;
        }
        let config = NdiSource::new(
            Some("MACHINE (CHANNEL)".to_string()),
            None,
            "Hydra test".to_string(),
            NdiBandwidth::Highest,
            NdiColorFormat::UyvyBgra,
            Some(NdiTimestampMode::ReceiveTimeVsTimestamp),
            MediaPolicy::VideoAndAudioRequired,
            BoundedMs::new(10_000).expect("connect timeout"),
            BoundedMs::new(5_000).expect("receive timeout"),
            BoundedMs::new(10_000).expect("discovery timeout"),
            MaxQueueLength::new(4).expect("queue length"),
        )
        .expect("valid NDI source config");

        let built = build(
            &config,
            RequiredMedia::from(config.media_policy()),
            "source_ndi",
        )
        .expect("NDI source bin");
        assert_eq!(built.source.factory().expect("factory").name(), "ndisrc");
        assert_eq!(built.source.property::<i32>("bandwidth"), 100_i32);
        assert_eq!(
            built
                .source
                .property::<Option<String>>("ndi-name")
                .as_deref(),
            Some("MACHINE (CHANNEL)")
        );
        assert_eq!(
            built
                .source
                .property::<Option<String>>("url-address")
                .as_deref(),
            None
        );
        assert_eq!(
            built
                .source
                .property::<Option<String>>("receiver-ndi-name")
                .as_deref(),
            Some("Hydra test")
        );
        assert_eq!(built.source.property::<u32>("connect-timeout"), 10_000);
        assert_eq!(built.source.property::<u32>("timeout"), 5_000);
        assert_eq!(built.source.property::<u32>("max-queue-length"), 4);
        assert_eq!(
            enum_property_nick(&built.source, "color-format"),
            "uyvy-bgra"
        );
        assert_eq!(
            enum_property_nick(&built.source, "timestamp-mode"),
            "receive-time-vs-timestamp"
        );
        assert!(built.bin.static_pad("video").is_some());
        assert!(built.bin.static_pad("audio").is_some());
    }

    fn enum_property_nick(element: &gst::Element, property: &str) -> String {
        let value = element.property_value(property);
        let (_, enum_value) = glib::EnumValue::from_value(&value).expect("enum property value");
        enum_value.nick().to_string()
    }
}
