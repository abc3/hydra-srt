use std::collections::HashSet;

use serde::Serialize;
use thiserror::Error;

use crate::config::{
    ConfigError, DestinationEndpoint, LegacyKind, NdiDestination, NdiSource, RouteConfig,
    RtmpEndpoint, SourceEndpoint, SrtDestination, SrtSource, UdpEndpoint,
};
use crate::reason::ErrorCode;
use crate::representations::{BranchTracks, MediaKind, RequiredMedia, TrackNeed};

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct GraphPlan {
    pub source: SourcePlan,
    pub branches: Vec<BranchPlan>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SourcePlan {
    pub endpoint_id: String,
    pub endpoint_name: String,
    pub adapter: SourceAdapterPlan,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SourceAdapterPlan {
    Ndi {
        config: NdiSource,
        media: RequiredMedia,
    },
    Srt {
        config: SrtSource,
        media: MediaKind,
    },
    Udp {
        config: UdpEndpoint,
        media: MediaKind,
    },
    Rtp {
        config: UdpEndpoint,
        media: MediaKind,
    },
    Rtmp {
        config: RtmpEndpoint,
        media: MediaKind,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BranchPlan {
    pub endpoint_id: String,
    pub endpoint_name: String,
    pub adapter: SinkAdapterPlan,
    pub queue: QueueClass,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SinkAdapterPlan {
    Ndi {
        config: NdiDestination,
        media: BranchTracks,
    },
    Srt {
        config: SrtDestination,
        media: MediaKind,
    },
    Udp {
        config: UdpEndpoint,
        media: MediaKind,
    },
    Rtmp {
        config: RtmpEndpoint,
        media: MediaKind,
    },
}

/// Selects the queue profile(s) used for one destination branch.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "class", rename_all = "snake_case")]
pub enum QueueClass {
    LegacyProgram,
    LegacyProgramLeaky,
    NdiRaw,
}

#[derive(Debug, Error)]
#[error("{code}: {context}")]
pub struct PlanError {
    code: ErrorCode,
    context: String,
}

impl PlanError {
    pub fn new(code: ErrorCode, context: impl Into<String>) -> Self {
        Self {
            code,
            context: context.into(),
        }
    }

    pub const fn code(&self) -> ErrorCode {
        self.code
    }

    pub fn context(&self) -> &str {
        &self.context
    }
}

impl From<ConfigError> for PlanError {
    fn from(error: ConfigError) -> Self {
        Self::new(ErrorCode::ConfigInvalid, error.to_string())
    }
}

impl From<serde_json::Error> for PlanError {
    fn from(error: serde_json::Error) -> Self {
        Self::new(ErrorCode::ConfigInvalid, error.to_string())
    }
}

pub fn plan(config: &RouteConfig) -> Result<GraphPlan, PlanError> {
    validate_envelope(config)?;

    // Exhaustive: a new source kind is a compile error (no `_ => plan_legacy`).
    match &config.source {
        SourceEndpoint::Ndi { id, name, ndi } => plan_ndi(config, id, name, ndi),
        SourceEndpoint::Srt { .. }
        | SourceEndpoint::Udp { .. }
        | SourceEndpoint::Rtp { .. }
        | SourceEndpoint::Rtmp { .. } => plan_program(config),
    }
}

fn validate_envelope(config: &RouteConfig) -> Result<(), PlanError> {
    if config.destinations.is_empty() {
        return Err(PlanError::new(
            ErrorCode::ConfigInvalid,
            "at least one destination is required",
        ));
    }

    let mut endpoint_ids = HashSet::with_capacity(config.destinations.len() + 1);
    endpoint_ids.insert(config.source.id());
    for destination in &config.destinations {
        if !endpoint_ids.insert(destination.id()) {
            return Err(PlanError::new(
                ErrorCode::ConfigInvalid,
                format!("duplicate endpoint id: {}", destination.id()),
            ));
        }
    }
    Ok(())
}

fn plan_ndi(
    config: &RouteConfig,
    source_id: &str,
    source_name: &str,
    ndi_source: &NdiSource,
) -> Result<GraphPlan, PlanError> {
    if config
        .destinations
        .iter()
        .any(|destination| !destination.is_ndi())
    {
        return Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            "NDI and legacy endpoints cannot be mixed",
        ));
    }

    let source_media = RequiredMedia::from(ndi_source.media_policy());
    let mut branches = Vec::with_capacity(config.destinations.len());

    for destination in &config.destinations {
        let DestinationEndpoint::Ndi { id, name, ndi } = destination else {
            return Err(PlanError::new(
                ErrorCode::UnsupportedGraph,
                "NDI and legacy endpoints cannot be mixed",
            ));
        };
        let sink_media = RequiredMedia::from(ndi.media_policy());
        let planned_media = branch_tracks(source_media, sink_media).map_err(|error| {
            PlanError::new(
                error.code(),
                format!("destination {id}: {}", error.context()),
            )
        })?;
        branches.push(BranchPlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SinkAdapterPlan::Ndi {
                config: ndi.clone(),
                media: planned_media,
            },
            queue: QueueClass::NdiRaw,
        });
    }

    Ok(GraphPlan {
        source: SourcePlan {
            endpoint_id: source_id.to_owned(),
            endpoint_name: source_name.to_owned(),
            adapter: SourceAdapterPlan::Ndi {
                config: ndi_source.clone(),
                media: source_media,
            },
        },
        branches,
    })
}

pub fn branch_tracks(
    source: RequiredMedia,
    sink: RequiredMedia,
) -> Result<BranchTracks, PlanError> {
    let video = plan_track("video", source.video, sink.video)?;
    let audio = plan_track("audio", source.audio, sink.audio)?;
    if !video && !audio {
        return Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            "source and destination have no definite track in common",
        ));
    }
    Ok(BranchTracks { video, audio })
}

fn plan_track(track: &str, source: TrackNeed, sink: TrackNeed) -> Result<bool, PlanError> {
    if sink == TrackNeed::Required && source != TrackNeed::Required {
        return Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            format!("destination requires {track}, but the source does not require it"),
        ));
    }
    Ok(sink != TrackNeed::Absent && source == TrackNeed::Required)
}

fn plan_program(config: &RouteConfig) -> Result<GraphPlan, PlanError> {
    if config.destinations.iter().any(DestinationEndpoint::is_ndi) {
        return Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            "legacy and NDI endpoints cannot be mixed",
        ));
    }

    let source = program_source_plan(&config.source)?;
    let mut branches = Vec::with_capacity(config.destinations.len());
    for destination in &config.destinations {
        branches.push(program_branch_plan(destination)?);
    }

    Ok(GraphPlan { source, branches })
}

fn program_source_plan(source: &SourceEndpoint) -> Result<SourcePlan, PlanError> {
    // Exhaustive: a new source kind is a compile error.
    match source {
        SourceEndpoint::Ndi { .. } => Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            "NDI source cannot use the program planner",
        )),
        SourceEndpoint::Srt { id, name, srt } => Ok(SourcePlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SourceAdapterPlan::Srt {
                config: srt.clone(),
                media: MediaKind::MpegTsProgram,
            },
        }),
        SourceEndpoint::Udp { id, name, udp } => Ok(SourcePlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SourceAdapterPlan::Udp {
                config: udp.clone(),
                media: MediaKind::MpegTsProgram,
            },
        }),
        SourceEndpoint::Rtp { id, name, rtp } => Ok(SourcePlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SourceAdapterPlan::Rtp {
                config: rtp.clone(),
                media: MediaKind::MpegTsProgram,
            },
        }),
        SourceEndpoint::Rtmp { id, name, rtmp } => Ok(SourcePlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SourceAdapterPlan::Rtmp {
                config: rtmp.clone(),
                media: MediaKind::MpegTsProgram,
            },
        }),
    }
}

fn program_branch_plan(destination: &DestinationEndpoint) -> Result<BranchPlan, PlanError> {
    // Exhaustive: a new destination kind is a compile error.
    match destination {
        DestinationEndpoint::Ndi { .. } => Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            "legacy and NDI endpoints cannot be mixed",
        )),
        DestinationEndpoint::Rtp { id, .. } => Err(PlanError::new(
            ErrorCode::UnsupportedGraph,
            format!("RTP destination is not supported (endpoint {id})"),
        )),
        DestinationEndpoint::Srt { id, name, srt } => Ok(BranchPlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SinkAdapterPlan::Srt {
                config: srt.clone(),
                media: MediaKind::MpegTsProgram,
            },
            queue: QueueClass::LegacyProgramLeaky,
        }),
        DestinationEndpoint::Udp { id, name, udp } => Ok(BranchPlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SinkAdapterPlan::Udp {
                config: udp.clone(),
                media: MediaKind::MpegTsProgram,
            },
            queue: QueueClass::LegacyProgram,
        }),
        DestinationEndpoint::Rtmp { id, name, rtmp } => Ok(BranchPlan {
            endpoint_id: id.clone(),
            endpoint_name: name.clone(),
            adapter: SinkAdapterPlan::Rtmp {
                config: rtmp.clone(),
                media: MediaKind::MpegTsProgram,
            },
            queue: QueueClass::LegacyProgramLeaky,
        }),
    }
}

impl SourceAdapterPlan {
    pub const fn legacy_kind(&self) -> Option<LegacyKind> {
        match self {
            Self::Ndi { .. } => None,
            Self::Srt { .. } => Some(LegacyKind::Srt),
            Self::Udp { .. } => Some(LegacyKind::Udp),
            Self::Rtp { .. } => Some(LegacyKind::Rtp),
            Self::Rtmp { .. } => Some(LegacyKind::Rtmp),
        }
    }
}

impl SinkAdapterPlan {
    pub const fn legacy_kind(&self) -> Option<LegacyKind> {
        match self {
            Self::Ndi { .. } => None,
            Self::Srt { .. } => Some(LegacyKind::Srt),
            Self::Udp { .. } => Some(LegacyKind::Udp),
            Self::Rtmp { .. } => Some(LegacyKind::Rtmp),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{branch_tracks, plan, QueueClass};
    use crate::{parse, BranchTracks, ErrorCode, MediaPolicy, RequiredMedia, TrackNeed};

    #[test]
    fn planning_error_fixture_matrix_locks_codes() {
        let cases = [
            (
                include_str!("../tests/fixtures/invalid_mixed_ndi_legacy.json"),
                ErrorCode::UnsupportedGraph,
            ),
            (
                include_str!("../tests/fixtures/invalid_empty_destinations.json"),
                ErrorCode::ConfigInvalid,
            ),
            (
                include_str!("../tests/fixtures/invalid_rtp_destination.json"),
                ErrorCode::UnsupportedGraph,
            ),
        ];

        for (fixture, expected_code) in cases {
            let config = parse(fixture).unwrap();
            assert_eq!(plan(&config).unwrap_err().code(), expected_code);
        }
    }

    #[test]
    fn rejects_unsatisfied_ndi_media_policy() {
        let fixture = include_str!("../tests/fixtures/invalid_unsatisfied_media.json");
        let error = plan(&parse(fixture).unwrap()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::UnsupportedGraph);
    }

    #[test]
    fn optional_audio_on_both_ends_builds_a_video_only_branch() {
        let config = parse(include_str!(
            "../tests/fixtures/valid_ndi_video_audio_optional.json"
        ))
        .unwrap();
        let graph = plan(&config).unwrap();
        assert_eq!(
            graph.branches[0].adapter,
            crate::SinkAdapterPlan::Ndi {
                config: crate::NdiDestination::new(
                    "Hydra Optional Output".to_string(),
                    MediaPolicy::VideoRequiredAudioOptional,
                ),
                media: BranchTracks {
                    video: true,
                    audio: false,
                },
            }
        );
        assert_eq!(
            serde_json::to_string_pretty(&graph).unwrap(),
            include_str!("../tests/fixtures/snapshot_ndi_video_optional_plan.json").trim()
        );
    }

    #[test]
    fn av_required_sink_rejects_optional_source_audio() {
        let config = parse(include_str!(
            "../tests/fixtures/invalid_optional_source_av_sink.json"
        ))
        .unwrap();
        assert_eq!(
            plan(&config).unwrap_err().code(),
            ErrorCode::UnsupportedGraph
        );
    }

    #[test]
    fn video_only_source_and_audio_only_sink_are_unsupported() {
        let config = parse(include_str!(
            "../tests/fixtures/invalid_video_source_audio_sink.json"
        ))
        .unwrap();
        assert_eq!(
            plan(&config).unwrap_err().code(),
            ErrorCode::UnsupportedGraph
        );
    }

    #[test]
    fn branch_tracks_rejects_an_empty_optional_branch() {
        let error = branch_tracks(
            RequiredMedia {
                video: TrackNeed::Optional,
                audio: TrackNeed::Absent,
            },
            RequiredMedia {
                video: TrackNeed::Optional,
                audio: TrackNeed::Absent,
            },
        )
        .unwrap_err();
        assert_eq!(error.code(), ErrorCode::UnsupportedGraph);
    }

    #[test]
    fn rejects_duplicate_ids_including_source_id() {
        let fixture = include_str!("../tests/fixtures/invalid_duplicate_ids.json");
        let error = plan(&parse(fixture).unwrap()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::ConfigInvalid);
    }

    #[test]
    fn ndi_graph_plan_snapshot_is_deterministic() {
        let config = parse(include_str!("../tests/fixtures/valid_ndi_audio_only.json")).unwrap();
        let graph = plan(&config).unwrap();
        assert_eq!(graph.branches[0].queue, QueueClass::NdiRaw);
        assert_eq!(
            serde_json::to_string_pretty(&graph).unwrap(),
            include_str!("../tests/fixtures/snapshot_ndi_audio_plan.json").trim()
        );
    }

    #[test]
    fn legacy_graph_plan_snapshot_is_deterministic() {
        let config = parse(include_str!(
            "../tests/fixtures/valid_legacy_srt_to_srt_udp.json"
        ))
        .unwrap();
        let graph = plan(&config).unwrap();
        assert_eq!(
            graph
                .branches
                .iter()
                .map(|branch| branch.queue)
                .collect::<Vec<_>>(),
            [QueueClass::LegacyProgramLeaky, QueueClass::LegacyProgram]
        );
        assert_eq!(
            serde_json::to_string_pretty(&graph).unwrap(),
            include_str!("../tests/fixtures/snapshot_legacy_plan.json").trim()
        );
    }
}
