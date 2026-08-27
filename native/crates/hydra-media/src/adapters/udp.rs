use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, UdpEndpoint};

use crate::adapters::element::set_property;

/// Apply typed UDP/RTP source properties onto `udpsrc`.
pub fn apply_source(
    element: &gst::Element,
    config: &UdpEndpoint,
) -> Result<(), (ErrorCode, String)> {
    set_property(element, "address", config.address().as_str())?;
    set_property(element, "port", i32::from(config.port().get()))?;
    if let Some(auto_multicast) = config.auto_multicast() {
        set_property(element, "auto-multicast", auto_multicast)?;
    }
    if let Some(multicast_iface) = config.multicast_iface() {
        set_property(element, "multicast-iface", multicast_iface.as_str())?;
    }
    if let Some(bind_address) = config.bind_address() {
        set_property(element, "bind-address", bind_address.as_str())?;
    }
    Ok(())
}

/// Apply typed UDP sink properties. Remaps `address` → GStreamer `host`.
pub fn apply_sink(element: &gst::Element, config: &UdpEndpoint) -> Result<(), (ErrorCode, String)> {
    set_property(element, "host", config.address().as_str())?;
    set_property(element, "port", i32::from(config.port().get()))?;
    if let Some(bind_address) = config.bind_address() {
        set_property(element, "bind-address", bind_address.as_str())?;
    }
    if let Some(multicast_iface) = config.multicast_iface() {
        set_property(element, "multicast-iface", multicast_iface.as_str())?;
    }
    if let Some(auto_multicast) = config.auto_multicast() {
        set_property(element, "auto-multicast", auto_multicast)?;
    }
    Ok(())
}

pub fn configure_sink(element: &gst::Element) {
    element.set_property("sync", false);
    element.set_property("async", false);
}

#[cfg(test)]
mod tests {
    use super::*;
    use hydra_plan::{HostAddress, InterfaceName, Port};

    #[test]
    fn sink_remaps_address_to_host() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("udpsink")
            .build()
            .expect("udpsink");
        let config = UdpEndpoint::new(
            HostAddress::new("239.1.1.1").unwrap(),
            Port::new(5000).unwrap(),
            Some(true),
            Some(InterfaceName::new("lo").unwrap()),
            None,
            None,
        );
        apply_sink(&element, &config).expect("udpsink accepts the typed endpoint config");
        configure_sink(&element);
        assert_eq!(element.property::<String>("host"), "239.1.1.1");
        assert_eq!(element.property::<i32>("port"), 5000);
        assert!(!element.property::<bool>("sync"));
        assert!(!element.property::<bool>("async"));
    }
}
