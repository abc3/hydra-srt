use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::QueueClass;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Leaky {
    None,
    Downstream,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueProfile {
    pub max_size_buffers: u32,
    pub max_size_bytes: u32,
    pub max_size_time_ns: u64,
    pub leaky: Leaky,
}

const LEGACY_PROGRAM_BRANCH: QueueProfile = QueueProfile {
    max_size_buffers: 200,
    max_size_bytes: 0,   // Deliberately disabled for legacy program branches.
    max_size_time_ns: 0, // Deliberately disabled for legacy program branches.
    leaky: Leaky::None,
};

const LEGACY_PROGRAM_LEAKY_BRANCH: QueueProfile = QueueProfile {
    leaky: Leaky::Downstream,
    ..LEGACY_PROGRAM_BRANCH
};

// Provisional default pending benchmarking.
const NDI_RAW_VIDEO_BRANCH: QueueProfile = QueueProfile {
    max_size_buffers: 8,
    max_size_bytes: 0,   // Deliberately disabled for raw NDI video.
    max_size_time_ns: 0, // Deliberately disabled for raw NDI video.
    leaky: Leaky::Downstream,
};

// Provisional default pending benchmarking.
const NDI_RAW_AUDIO_BRANCH: QueueProfile = QueueProfile {
    max_size_buffers: 32,
    max_size_bytes: 0,   // Deliberately disabled for raw NDI audio.
    max_size_time_ns: 0, // Deliberately disabled for raw NDI audio.
    leaky: Leaky::None,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueProfiles {
    Program(QueueProfile),
    NdiRaw {
        video: QueueProfile,
        audio: QueueProfile,
    },
}

/// This is the only mapping from the pure plan's queue policy to media profiles.
pub const fn profiles_for(class: QueueClass) -> QueueProfiles {
    match class {
        QueueClass::LegacyProgram => QueueProfiles::Program(LEGACY_PROGRAM_BRANCH),
        QueueClass::LegacyProgramLeaky => QueueProfiles::Program(LEGACY_PROGRAM_LEAKY_BRANCH),
        QueueClass::NdiRaw => QueueProfiles::NdiRaw {
            video: NDI_RAW_VIDEO_BRANCH,
            audio: NDI_RAW_AUDIO_BRANCH,
        },
    }
}

#[derive(Debug)]
pub struct BranchHandle {
    pub bin: gst::Bin,
    pub tee_pad: gst::Pad,
    pub requested_pads: Vec<(gst::Element, gst::Pad)>,
}

impl BranchHandle {
    pub fn shutdown(&self, tee: &gst::Element) {
        for (element, pad) in self.requested_pads.iter().rev() {
            if let Some(peer) = pad.peer() {
                if pad.direction() == gst::PadDirection::Src {
                    let _ = pad.unlink(&peer);
                } else {
                    let _ = peer.unlink(pad);
                }
            }
            element.release_request_pad(pad);
        }

        if let Some(peer) = self.tee_pad.peer() {
            let _ = self.tee_pad.unlink(&peer);
        }
        tee.release_request_pad(&self.tee_pad);
    }
}

pub fn configure_queue(queue: &gst::Element, profile: QueueProfile) {
    queue.set_property("max-size-buffers", profile.max_size_buffers);
    queue.set_property("max-size-bytes", profile.max_size_bytes);
    queue.set_property("max-size-time", profile.max_size_time_ns);
    queue.set_property_from_str(
        "leaky",
        match profile.leaky {
            Leaky::None => "no",
            Leaky::Downstream => "downstream",
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_queue_class_maps_to_its_intended_profile() {
        assert_eq!(
            profiles_for(QueueClass::LegacyProgram),
            QueueProfiles::Program(QueueProfile {
                max_size_buffers: 200,
                max_size_bytes: 0,
                max_size_time_ns: 0,
                leaky: Leaky::None,
            })
        );
        assert_eq!(
            profiles_for(QueueClass::LegacyProgramLeaky),
            QueueProfiles::Program(QueueProfile {
                max_size_buffers: 200,
                max_size_bytes: 0,
                max_size_time_ns: 0,
                leaky: Leaky::Downstream,
            })
        );
        assert_eq!(
            profiles_for(QueueClass::NdiRaw),
            QueueProfiles::NdiRaw {
                video: QueueProfile {
                    max_size_buffers: 8,
                    max_size_bytes: 0,
                    max_size_time_ns: 0,
                    leaky: Leaky::Downstream,
                },
                audio: QueueProfile {
                    max_size_buffers: 32,
                    max_size_bytes: 0,
                    max_size_time_ns: 0,
                    leaky: Leaky::None,
                },
            }
        );
    }

    #[test]
    fn branch_shutdown_releases_tee_and_every_recorded_request_pad() {
        let _ = gst::init();
        let tee = gst::ElementFactory::make("tee").build().expect("tee");
        let requested_from = gst::ElementFactory::make("tee")
            .build()
            .expect("requested-pad owner");
        let tee_pad = tee.request_pad_simple("src_%u").expect("tee pad");
        let requested_pad = requested_from
            .request_pad_simple("src_%u")
            .expect("recorded pad");
        let handle = BranchHandle {
            bin: gst::Bin::with_name("dest_test"),
            tee_pad,
            requested_pads: vec![(requested_from.clone(), requested_pad)],
        };

        handle.shutdown(&tee);

        assert!(tee.src_pads().is_empty());
        assert!(requested_from.src_pads().is_empty());
    }
}
