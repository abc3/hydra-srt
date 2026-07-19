use serde::Serialize;

use crate::config::MediaPolicy;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    MpegTsProgram,
}

/// Whether a media policy requires, accepts, or excludes one track.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackNeed {
    Required,
    Optional,
    Absent,
}

/// Per-track requirements used by source readiness and branch planning.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct RequiredMedia {
    pub video: TrackNeed,
    pub audio: TrackNeed,
}

/// Definite tracks that a static destination branch must build.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct BranchTracks {
    pub video: bool,
    pub audio: bool,
}

impl From<MediaPolicy> for RequiredMedia {
    fn from(policy: MediaPolicy) -> Self {
        match policy {
            MediaPolicy::VideoAndAudioRequired => Self {
                video: TrackNeed::Required,
                audio: TrackNeed::Required,
            },
            MediaPolicy::VideoRequiredAudioOptional => Self {
                video: TrackNeed::Required,
                audio: TrackNeed::Optional,
            },
            MediaPolicy::VideoOnly => Self {
                video: TrackNeed::Required,
                audio: TrackNeed::Absent,
            },
            MediaPolicy::AudioOnly => Self {
                video: TrackNeed::Absent,
                audio: TrackNeed::Required,
            },
        }
    }
}

impl RequiredMedia {
    pub const fn has_video(self) -> bool {
        !matches!(self.video, TrackNeed::Absent)
    }

    pub const fn has_audio(self) -> bool {
        !matches!(self.audio, TrackNeed::Absent)
    }

    pub const fn video_optional(self) -> bool {
        matches!(self.video, TrackNeed::Optional)
    }

    pub const fn audio_optional(self) -> bool {
        matches!(self.audio, TrackNeed::Optional)
    }
}

#[cfg(test)]
mod tests {
    use super::{RequiredMedia, TrackNeed};
    use crate::MediaPolicy;

    #[test]
    fn media_policy_derivation_locks_track_requirements() {
        let av = RequiredMedia::from(MediaPolicy::VideoAndAudioRequired);
        let video_optional_audio = RequiredMedia::from(MediaPolicy::VideoRequiredAudioOptional);
        let video = RequiredMedia::from(MediaPolicy::VideoOnly);
        let audio = RequiredMedia::from(MediaPolicy::AudioOnly);

        assert_eq!(av.video, TrackNeed::Required);
        assert_eq!(av.audio, TrackNeed::Required);
        assert_eq!(video_optional_audio.video, TrackNeed::Required);
        assert_eq!(video_optional_audio.audio, TrackNeed::Optional);
        assert_eq!(video.video, TrackNeed::Required);
        assert_eq!(video.audio, TrackNeed::Absent);
        assert_eq!(audio.video, TrackNeed::Absent);
        assert_eq!(audio.audio, TrackNeed::Required);
    }

    #[test]
    fn required_media_serializes_only_enum_backed_track_states() {
        let cases = [
            (
                MediaPolicy::VideoAndAudioRequired,
                serde_json::json!({"video": "required", "audio": "required"}),
            ),
            (
                MediaPolicy::VideoRequiredAudioOptional,
                serde_json::json!({"video": "required", "audio": "optional"}),
            ),
            (
                MediaPolicy::VideoOnly,
                serde_json::json!({"video": "required", "audio": "absent"}),
            ),
            (
                MediaPolicy::AudioOnly,
                serde_json::json!({"video": "absent", "audio": "required"}),
            ),
        ];

        for (policy, expected) in cases {
            assert_eq!(
                serde_json::to_value(RequiredMedia::from(policy)).unwrap(),
                expected
            );
        }
    }
}
