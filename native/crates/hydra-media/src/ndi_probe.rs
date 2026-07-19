use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, RequiredMedia, SourceEndpoint, TrackNeed};
use serde::{Deserialize, Serialize};

use crate::adapters::ndi_source::{self, NdiTrack, TrackReadiness};
use crate::output::{send_json_line, StatsWriter};

#[derive(Serialize)]
pub struct ProbeResult<'a> {
    event: &'static str,
    probe_instance_id: &'a str,
    ok: bool,
    reason_code: Option<ErrorCode>,
    video_caps: Option<String>,
    audio_caps: Option<String>,
    elapsed_ms: u64,
}

/// The probe protocol accepts only the NDI source endpoint it is going to exercise.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeInput {
    source: SourceEndpoint,
}

struct ProbeTracks {
    video: ProbeTrack,
    audio: ProbeTrack,
}

struct ProbeTrack {
    readiness: TrackReadiness,
    caps: Option<String>,
}

impl ProbeTracks {
    fn new(timeout_ms: u64) -> Self {
        Self {
            video: ProbeTrack {
                readiness: TrackReadiness::new(timeout_ms),
                caps: None,
            },
            audio: ProbeTrack {
                readiness: TrackReadiness::new(timeout_ms),
                caps: None,
            },
        }
    }

    fn track_mut(&mut self, track: NdiTrack) -> &mut ProbeTrack {
        match track {
            NdiTrack::Video => &mut self.video,
            NdiTrack::Audio => &mut self.audio,
        }
    }

    fn complete(&self, media: RequiredMedia) -> bool {
        (!matches!(media.video, TrackNeed::Required) || self.video.readiness.ready())
            && (!matches!(media.audio, TrackNeed::Required) || self.audio.readiness.ready())
    }

    fn missing_code(&self, media: RequiredMedia) -> Option<ErrorCode> {
        if matches!(media.video, TrackNeed::Required) && !self.video.readiness.ready() {
            Some(ErrorCode::NdiRequiredVideoMissing)
        } else if matches!(media.audio, TrackNeed::Required) && !self.audio.readiness.ready() {
            Some(ErrorCode::NdiRequiredAudioMissing)
        } else {
            None
        }
    }
}

pub fn run(line: &str, writer: &mut dyn StatsWriter, probe_instance_id: &str) -> Result<()> {
    let started = Instant::now();
    let input = match serde_json::from_str::<ProbeInput>(line) {
        Ok(input) => input,
        Err(_) => {
            return emit_result(
                writer,
                probe_instance_id,
                false,
                Some(ErrorCode::ConfigInvalid),
                None,
                None,
                started,
            )
        }
    };
    let SourceEndpoint::Ndi { ndi, .. } = &input.source else {
        return emit_result(
            writer,
            probe_instance_id,
            false,
            Some(ErrorCode::ConfigInvalid),
            None,
            None,
            started,
        );
    };
    if gst::ElementFactory::find("ndisrc").is_none()
        || gst::ElementFactory::find("ndisrcdemux").is_none()
    {
        return emit_result(
            writer,
            probe_instance_id,
            false,
            Some(ErrorCode::NdiPluginMissing),
            None,
            None,
            started,
        );
    }

    let media = RequiredMedia::from(ndi.media_policy());
    let built = match ndi_source::build(ndi, media, "ndi_probe_source") {
        Ok(built) => built,
        Err(error) => {
            return emit_result(
                writer,
                probe_instance_id,
                false,
                Some(error.code()),
                None,
                None,
                started,
            )
        }
    };
    let pipeline = gst::Pipeline::new();
    pipeline
        .add(&built.bin)
        .context("failed to add NDI source bin to probe pipeline")?;
    let tracks = Arc::new(Mutex::new(ProbeTracks::new(
        ndi.track_discovery_timeout_ms().get(),
    )));
    for (track, output_pad) in built.output_pads {
        let sink = gst::ElementFactory::make("fakesink")
            .build()
            .context("failed to create probe fakesink")?;
        sink.set_property("sync", false);
        pipeline
            .add(&sink)
            .context("failed to add probe fakesink")?;
        let sink_pad = sink
            .static_pad("sink")
            .ok_or_else(|| anyhow!("probe fakesink has no sink pad"))?;
        output_pad
            .link(&sink_pad)
            .context("failed to link NDI probe output to fakesink")?;
        let tracks_ref = tracks.clone();
        output_pad.add_probe(
            gst::PadProbeType::EVENT_DOWNSTREAM
                | gst::PadProbeType::BUFFER
                | gst::PadProbeType::BUFFER_LIST,
            move |_pad, info| {
                if let Ok(mut tracks) = tracks_ref.lock() {
                    let probe_track = tracks.track_mut(track);
                    if info.buffer().is_some() || info.buffer_list().is_some() {
                        probe_track.readiness.observe_buffer();
                    }
                    if let Some(gst::PadProbeData::Event(event)) = info.data.as_ref() {
                        if let gst::EventView::Caps(caps) = event.view() {
                            probe_track.caps = Some(caps.caps().to_string());
                            probe_track.readiness.observe_caps(caps.caps().is_fixed());
                        }
                    }
                }
                gst::PadProbeReturn::Ok
            },
        );
    }
    if pipeline.set_state(gst::State::Playing).is_err() {
        let _ = pipeline.set_state(gst::State::Null);
        return emit_result(
            writer,
            probe_instance_id,
            false,
            Some(ErrorCode::NdiRuntimeMissing),
            None,
            None,
            started,
        );
    }
    let deadline = Duration::from_millis(ndi.track_discovery_timeout_ms().get());
    let bus = pipeline
        .bus()
        .ok_or_else(|| anyhow!("probe pipeline has no bus"))?;
    let mut internal_failure = None;
    while started.elapsed() < deadline {
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        if tracks
            .lock()
            .map_err(|_| anyhow!("probe track state poisoned"))?
            .complete(media)
        {
            break;
        }
        if let Some(message) = bus.timed_pop(gst::ClockTime::from_mseconds(20)) {
            if matches!(message.view(), gst::MessageView::Error(_)) {
                internal_failure = Some(ErrorCode::RuntimeError);
                break;
            }
        }
    }
    pipeline
        .set_state(gst::State::Null)
        .context("failed to stop NDI probe pipeline")?;
    let tracks = tracks
        .lock()
        .map_err(|_| anyhow!("probe track state poisoned"))?;
    let code = internal_failure.or_else(|| {
        (!tracks.complete(media))
            .then(|| tracks.missing_code(media))
            .flatten()
    });
    emit_result(
        writer,
        probe_instance_id,
        code.is_none(),
        code,
        tracks.video.caps.clone(),
        tracks.audio.caps.clone(),
        started,
    )
}

fn emit_result(
    writer: &mut dyn StatsWriter,
    probe_instance_id: &str,
    ok: bool,
    code: Option<ErrorCode>,
    video_caps: Option<String>,
    audio_caps: Option<String>,
    started: Instant,
) -> Result<()> {
    send_json_line(
        writer,
        &ProbeResult {
            event: "probe_result",
            probe_instance_id,
            ok,
            reason_code: code,
            video_caps,
            audio_caps,
            elapsed_ms: started.elapsed().as_millis() as u64,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_result_serializes_as_a_single_event() {
        let result = ProbeResult {
            event: "probe_result",
            probe_instance_id: "probe-1",
            ok: false,
            reason_code: Some(ErrorCode::NdiPluginMissing),
            video_caps: None,
            audio_caps: None,
            elapsed_ms: 12,
        };
        let value = serde_json::to_value(result).expect("serializes");
        assert_eq!(value["event"], "probe_result");
        assert_eq!(value["probe_instance_id"], "probe-1");
        assert_eq!(value["reason_code"], "NDI_PLUGIN_MISSING");
    }

    #[test]
    fn probe_input_accepts_only_an_ndi_source_endpoint() {
        let input = r#"{
          "source": {
            "id": "source-id",
            "kind": "ndi",
            "ndi": {
              "source_name": "test-source",
              "url_address": null,
              "receiver_name": "Hydra probe",
              "bandwidth": "highest",
              "color_format": "uyvy-bgra",
              "timestamp_mode": "receive-time-vs-timestamp",
              "media_policy": "video_only",
              "connect_timeout_ms": 1000,
              "receive_timeout_ms": 1000,
              "track_discovery_timeout_ms": 1000,
              "max_queue_length": 4
            }
          }
        }"#;
        assert!(serde_json::from_str::<ProbeInput>(input).is_ok());
        assert!(serde_json::from_str::<ProbeInput>(r#"{"source":{},"destinations":[]}"#).is_err());
    }
}
