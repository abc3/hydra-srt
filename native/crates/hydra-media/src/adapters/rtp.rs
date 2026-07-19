use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, UdpEndpoint};

use crate::adapters::udp;

/// RTP source is `udpsrc` plus MP2T caps; depay is wired in `build.rs`.
pub fn apply_source(
    element: &gst::Element,
    config: &UdpEndpoint,
) -> Result<(), (ErrorCode, String)> {
    udp::apply_source(element, config)?;
    configure_source(element);
    Ok(())
}

pub fn configure_source(source: &gst::Element) {
    let caps = gst::Caps::builder("application/x-rtp")
        .field("media", "video")
        .field("clock-rate", 90_000_i32)
        .field("encoding-name", "MP2T")
        .build();
    source.set_property("caps", caps);
}
