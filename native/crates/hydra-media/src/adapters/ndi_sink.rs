use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{BranchTracks, ErrorCode, NdiDestination};

use super::element::{
    link_detail, make_element as make_element_pair, runtime_detail, set_property,
};
use super::ndi_source::{configure_raw_queue, NdiAdapterError, NdiTrack};
use crate::branch::{QueueProfile, QueueProfiles};

pub struct NdiSinkBin {
    pub bin: gst::Bin,
    pub sink: gst::Element,
    pub input_pads: Vec<(NdiTrack, gst::Pad)>,
    pub metric_pads: Vec<gst::Pad>,
    pub requested_pads: Vec<(gst::Element, gst::Pad)>,
    pub drops: Arc<AtomicU64>,
}

pub fn build(
    config: &NdiDestination,
    media: BranchTracks,
    bin_name: &str,
    profiles: QueueProfiles,
) -> Result<NdiSinkBin, NdiAdapterError> {
    let QueueProfiles::NdiRaw { video, audio } = profiles else {
        return Err(NdiAdapterError::new(
            ErrorCode::ConfigInvalid,
            "NDI destination requires raw queue profiles",
        ));
    };
    match (media.video, media.audio) {
        (true, true) => build_av(config, bin_name, video, audio),
        (true, false) => build_single_track(config, bin_name, NdiTrack::Video, video),
        (false, true) => build_single_track(config, bin_name, NdiTrack::Audio, audio),
        (false, false) => Err(NdiAdapterError::new(
            ErrorCode::UnsupportedGraph,
            "NDI destination has no planned media tracks",
        )),
    }
}

fn build_av(
    config: &NdiDestination,
    bin_name: &str,
    video_profile: QueueProfile,
    audio_profile: QueueProfile,
) -> Result<NdiSinkBin, NdiAdapterError> {
    let bin = gst::Bin::with_name(bin_name);
    let video_queue = make_element("queue", "NDI destination video queue")?;
    let audio_queue = make_element("queue", "NDI destination audio queue")?;
    let combiner = make_element("ndisinkcombiner", "NDI sink combiner")?;
    let sink = make_element("ndisink", "NDI sink")?;
    set_property(&sink, "ndi-name", config.sender_name())
        .map_err(|(code, detail)| NdiAdapterError::new(code, detail))?;

    let drops = configure_raw_queue(&video_queue, NdiTrack::Video, video_profile)
        .unwrap_or_else(|| Arc::new(AtomicU64::new(0)));
    let _ = configure_raw_queue(&audio_queue, NdiTrack::Audio, audio_profile);
    bin.add_many([&video_queue, &audio_queue, &combiner, &sink])
        .map_err(runtime_error)?;
    combiner.link(&sink).map_err(link_error)?;

    let video_target = combiner.static_pad("video").ok_or_else(|| {
        NdiAdapterError::new(
            ErrorCode::NdiPluginIncompatible,
            "ndisinkcombiner has no static video pad",
        )
    })?;
    let audio_target = combiner.request_pad_simple("audio").ok_or_else(|| {
        NdiAdapterError::new(
            ErrorCode::NdiPluginIncompatible,
            "ndisinkcombiner failed to provide its audio request pad",
        )
    })?;
    let video_src = required_static_pad(&video_queue, "src", "video queue source")?;
    let audio_src = required_static_pad(&audio_queue, "src", "audio queue source")?;
    if let Err(error) = video_src.link(&video_target) {
        combiner.release_request_pad(&audio_target);
        return Err(link_error(error));
    }
    if let Err(error) = audio_src.link(&audio_target) {
        combiner.release_request_pad(&audio_target);
        return Err(link_error(error));
    }

    let video_input = add_input_ghost_pad(&bin, &video_queue, NdiTrack::Video)?;
    let audio_input = add_input_ghost_pad(&bin, &audio_queue, NdiTrack::Audio)?;
    Ok(NdiSinkBin {
        bin,
        sink,
        input_pads: vec![
            (NdiTrack::Video, video_input),
            (NdiTrack::Audio, audio_input),
        ],
        metric_pads: vec![video_src, audio_src],
        requested_pads: vec![(combiner, audio_target)],
        drops,
    })
}

fn build_single_track(
    config: &NdiDestination,
    bin_name: &str,
    track: NdiTrack,
    profile: QueueProfile,
) -> Result<NdiSinkBin, NdiAdapterError> {
    let bin = gst::Bin::with_name(bin_name);
    let queue = make_element("queue", "NDI destination raw queue")?;
    let sink = make_element("ndisink", "NDI sink")?;
    set_property(&sink, "ndi-name", config.sender_name())
        .map_err(|(code, detail)| NdiAdapterError::new(code, detail))?;
    let drops =
        configure_raw_queue(&queue, track, profile).unwrap_or_else(|| Arc::new(AtomicU64::new(0)));
    bin.add_many([&queue, &sink]).map_err(runtime_error)?;
    queue.link(&sink).map_err(link_error)?;

    let input = add_input_ghost_pad(&bin, &queue, track)?;
    let metric_pad = required_static_pad(&queue, "src", "NDI destination queue source")?;
    Ok(NdiSinkBin {
        bin,
        sink,
        input_pads: vec![(track, input)],
        metric_pads: vec![metric_pad],
        requested_pads: Vec::new(),
        drops,
    })
}

fn add_input_ghost_pad(
    bin: &gst::Bin,
    queue: &gst::Element,
    track: NdiTrack,
) -> Result<gst::Pad, NdiAdapterError> {
    let target = required_static_pad(queue, "sink", "NDI destination queue sink")?;
    let name = match track {
        NdiTrack::Video => "video",
        NdiTrack::Audio => "audio",
    };
    let ghost = gst::GhostPad::builder_with_target(&target)
        .map_err(runtime_error)?
        .name(name)
        .build();
    bin.add_pad(&ghost).map_err(runtime_error)?;
    Ok(ghost.upcast())
}

fn required_static_pad(
    element: &gst::Element,
    name: &str,
    role: &str,
) -> Result<gst::Pad, NdiAdapterError> {
    element.static_pad(name).ok_or_else(|| {
        NdiAdapterError::new(
            ErrorCode::LinkFailed,
            format!("{role} pad {name} is unavailable"),
        )
    })
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
    use hydra_plan::{BranchTracks, MediaPolicy};

    use super::*;

    #[test]
    fn ndi_sink_variants_build_and_av_records_exactly_one_audio_request_pad() {
        let _ = gst::init();
        if gst::ElementFactory::find("ndisrc").is_none() {
            eprintln!("skipped: ndi plugin absent");
            return;
        }
        let cases = [
            (
                MediaPolicy::VideoAndAudioRequired,
                BranchTracks {
                    video: true,
                    audio: true,
                },
                2,
                1,
            ),
            (
                MediaPolicy::VideoOnly,
                BranchTracks {
                    video: true,
                    audio: false,
                },
                1,
                0,
            ),
            (
                MediaPolicy::AudioOnly,
                BranchTracks {
                    video: false,
                    audio: true,
                },
                1,
                0,
            ),
        ];
        for (policy, tracks, expected_inputs, expected_requests) in cases {
            let config = NdiDestination::new("Hydra test output".to_string(), policy);
            let built = build(
                &config,
                tracks,
                "dest_ndi",
                crate::branch::profiles_for(hydra_plan::QueueClass::NdiRaw),
            )
            .expect("NDI sink bin");
            assert_eq!(built.input_pads.len(), expected_inputs);
            assert_eq!(built.requested_pads.len(), expected_requests);
            assert_eq!(built.sink.factory().expect("factory").name(), "ndisink");
            for (element, pad) in &built.requested_pads {
                element.release_request_pad(pad);
            }
        }
    }
}
