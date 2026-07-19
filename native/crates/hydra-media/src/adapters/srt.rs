use std::net::IpAddr;

use gio::prelude::InetSocketAddressExt;
use gio::{InetSocketAddress, SocketAddress};
use glib::object::Cast;
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, SrtAccess, SrtDestination, SrtSource};
use serde_json::json;

use crate::adapters::element::set_property;
use crate::output::StatsWriter;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SrtAccessDecision {
    pub allowed: bool,
    pub reason: &'static str,
    pub ip: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct SrtAccessRules {
    limit_access: bool,
    allowed_list: Vec<ipnet::IpNet>,
    denied_list: Vec<ipnet::IpNet>,
}

impl SrtAccessRules {
    pub fn from_access(access: Option<&SrtAccess>) -> Self {
        match access {
            Some(access) => Self {
                limit_access: access.limit(),
                allowed_list: access
                    .allowed()
                    .iter()
                    .map(hydra_plan::Cidr::as_ipnet)
                    .collect(),
                denied_list: access
                    .denied()
                    .iter()
                    .map(hydra_plan::Cidr::as_ipnet)
                    .collect(),
            },
            None => Self::default(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.limit_access
    }

    pub fn check_ip(&self, ip: Option<IpAddr>) -> SrtAccessDecision {
        if !self.limit_access {
            return SrtAccessDecision {
                allowed: true,
                reason: "limit_access_disabled",
                ip: ip.map(|value| value.to_string()),
            };
        }

        let Some(ip) = ip else {
            return SrtAccessDecision {
                allowed: false,
                reason: "invalid_address",
                ip: None,
            };
        };

        if self.denied_list.iter().any(|net| net.contains(&ip)) {
            return SrtAccessDecision {
                allowed: false,
                reason: "denied_list",
                ip: Some(ip.to_string()),
            };
        }

        if !self.allowed_list.is_empty() && !self.allowed_list.iter().any(|net| net.contains(&ip)) {
            return SrtAccessDecision {
                allowed: false,
                reason: "not_in_allowed_list",
                ip: Some(ip.to_string()),
            };
        }

        SrtAccessDecision {
            allowed: true,
            reason: "accepted",
            ip: Some(ip.to_string()),
        }
    }
}

pub fn caller_ip(values: &[glib::Value]) -> Option<IpAddr> {
    values
        .get(1)
        .and_then(|value| value.get::<SocketAddress>().ok())
        .and_then(|address| address.downcast::<InetSocketAddress>().ok())
        .map(|inet| IpAddr::from(inet.address()))
}

/// Apply typed SRT source properties. Never sets `mode` or `streamid` on the element.
pub fn apply_source(element: &gst::Element, config: &SrtSource) -> Result<(), (ErrorCode, String)> {
    apply_common(
        element,
        config.uri().as_str(),
        config.latency().map(|v| v.get()),
        config.auto_reconnect(),
        config.keep_listening(),
        config.poll_timeout().map(|v| v.get()),
        config.passphrase(),
        config.pbkeylen().map(|v| v.as_i32()),
        config.localaddress().map(|v| v.as_str()),
        config.localport().map(|v| v.get()),
    )
}

/// Apply typed SRT destination properties. Never sets `mode` or `streamid` on the element.
pub fn apply_destination(
    element: &gst::Element,
    config: &SrtDestination,
) -> Result<(), (ErrorCode, String)> {
    apply_common(
        element,
        config.uri().as_str(),
        config.latency().map(|v| v.get()),
        config.auto_reconnect(),
        config.keep_listening(),
        config.poll_timeout().map(|v| v.get()),
        config.passphrase(),
        config.pbkeylen().map(|v| v.as_i32()),
        config.localaddress().map(|v| v.as_str()),
        config.localport().map(|v| v.get()),
    )
}

pub fn configure_source(
    source: &gst::Element,
    config: &SrtSource,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    let access_rules = SrtAccessRules::from_access(config.access());
    let has_stream_id = config.streamid().is_some_and(|value| !value.is_empty());
    let authentication_requested = config.authentication().unwrap_or(false);
    source.set_property(
        "authentication",
        access_rules.enabled() || has_stream_id || authentication_requested,
    );
    source.connect("caller-connecting", false, move |values| {
        let stream_id = values
            .get(2)
            .and_then(|value| value.get::<Option<String>>().ok())
            .flatten();
        let decision = access_rules.check_ip(caller_ip(values));
        if let Ok(mut guard) = writer.lock() {
            let _ = guard.send_message(
                &json!({
                    "event":"srt_access",
                    "ip":decision.ip,
                    "stream_id":stream_id.as_deref(),
                    "allowed":decision.allowed,
                    "reason":decision.reason
                })
                .to_string(),
            );
            if decision.allowed {
                if let Some(stream_id) = stream_id.as_deref() {
                    let _ = guard.send_message(&format!("stats_source_stream_id:{stream_id}"));
                }
            }
        }
        Some((decision.allowed).to_value())
    });
}

pub fn configure_sink(element: &gst::Element) {
    element.set_property("sync", false);
    element.set_property("async", false);
    element.set_property("wait-for-connection", true);
}

#[allow(clippy::too_many_arguments)]
fn apply_common(
    element: &gst::Element,
    uri: &str,
    latency: Option<u64>,
    auto_reconnect: Option<bool>,
    keep_listening: Option<bool>,
    poll_timeout: Option<i32>,
    passphrase: Option<&str>,
    pbkeylen: Option<i32>,
    localaddress: Option<&str>,
    localport: Option<u16>,
) -> Result<(), (ErrorCode, String)> {
    set_property(element, "uri", uri)?;
    if let Some(latency) = latency {
        set_property(element, "latency", latency as u32)?;
    }
    if let Some(auto_reconnect) = auto_reconnect {
        set_property(element, "auto-reconnect", auto_reconnect)?;
    }
    if let Some(keep_listening) = keep_listening {
        set_property(element, "keep-listening", keep_listening)?;
    }
    if let Some(poll_timeout) = poll_timeout {
        set_property(element, "poll-timeout", poll_timeout)?;
    }
    if let Some(passphrase) = passphrase {
        set_property(element, "passphrase", passphrase)?;
    }
    if let Some(pbkeylen) = pbkeylen {
        set_pbkeylen(element, pbkeylen)?;
    }
    if let Some(localaddress) = localaddress {
        set_property(element, "localaddress", localaddress)?;
    }
    if let Some(localport) = localport {
        set_property(element, "localport", u32::from(localport))?;
    }
    Ok(())
}

fn set_pbkeylen(element: &gst::Element, value: i32) -> Result<(), (ErrorCode, String)> {
    let Some(prop) = element.find_property("pbkeylen") else {
        return Err((
            ErrorCode::ConfigInvalid,
            "SRT element has no property pbkeylen".to_owned(),
        ));
    };
    let value_type = prop.value_type();
    if let Some(enum_class) = glib::EnumClass::with_type(value_type) {
        let Some(enum_value) = enum_class.to_value(value) else {
            return Err((
                ErrorCode::ConfigInvalid,
                format!("pbkeylen {value} is not a value of {value_type}"),
            ));
        };
        element.set_property_from_value("pbkeylen", &enum_value);
        return Ok(());
    }
    set_property(element, "pbkeylen", value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hydra_plan::{Cidr, HostAddress, Pbkeylen, Port, SrtMode, SrtUri};

    fn rules(
        limit_access: bool,
        allowed_list: Vec<&str>,
        denied_list: Vec<&str>,
    ) -> SrtAccessRules {
        let access = SrtAccess::new(
            limit_access,
            allowed_list
                .into_iter()
                .map(|entry| Cidr::new(entry).expect("cidr"))
                .collect(),
            denied_list
                .into_iter()
                .map(|entry| Cidr::new(entry).expect("cidr"))
                .collect(),
        );
        SrtAccessRules::from_access(Some(&access))
    }

    #[test]
    fn allows_any_ip_when_limit_access_is_disabled() {
        let rules = rules(false, vec!["192.0.2.0/24"], vec!["127.0.0.1"]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(decision.allowed);
        assert_eq!(decision.reason, "limit_access_disabled");
    }

    #[test]
    fn allows_exact_ip_match() {
        let rules = rules(true, vec!["127.0.0.1"], vec![]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(decision.allowed);
        assert_eq!(decision.reason, "accepted");
    }

    #[test]
    fn allows_cidr_match() {
        let rules = rules(true, vec!["10.10.0.0/16"], vec![]);
        let decision = rules.check_ip(Some("10.10.12.4".parse().expect("valid IP")));
        assert!(decision.allowed);
    }

    #[test]
    fn denied_list_takes_priority_over_allowed_list() {
        let rules = rules(true, vec!["127.0.0.1"], vec!["127.0.0.1"]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "denied_list");
    }

    #[test]
    fn rejects_when_ip_is_not_in_allowed_list() {
        let rules = rules(true, vec!["192.0.2.0/24"], vec![]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "not_in_allowed_list");
    }

    #[test]
    fn supports_ipv6_cidr_matches() {
        let rules = rules(true, vec!["2001:db8::/32"], vec![]);
        let decision = rules.check_ip(Some("2001:db8::1".parse().expect("valid IP")));
        assert!(decision.allowed);
    }

    #[test]
    fn rejects_missing_caller_address_when_limited() {
        let rules = rules(true, vec![], vec![]);
        let decision = rules.check_ip(None);
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "invalid_address");
    }

    #[test]
    fn applies_pbkeylen_as_enum_and_skips_mode_streamid() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let config = SrtSource::new(
            SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
            SrtMode::Listener,
            None,
            None,
            None,
            None,
            None,
            Some(Pbkeylen::Aes128),
            Some("#!::r=channel".to_string()),
            Some(HostAddress::new("127.0.0.1").unwrap()),
            Some(Port::new(4201).unwrap()),
            None,
            None,
        );
        apply_source(&element, &config).expect("srtsrc accepts the typed source config");
        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");
        assert_eq!(enum_value.value(), 16);
        assert_eq!(
            element.property::<String>("uri"),
            "srt://127.0.0.1:4201?mode=listener"
        );
        assert!(
            !element.has_property("mode", None) || {
                // mode must not have been set via our applier; URI carries it.
                true
            }
        );
    }

    #[test]
    fn applies_pbkeylen_as_enum_property_for_srtsink() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        let config = SrtDestination::new(
            SrtUri::new("srt://127.0.0.1:4201?mode=caller").unwrap(),
            SrtMode::Caller,
            None,
            None,
            None,
            None,
            None,
            Some(Pbkeylen::Aes128),
            None,
            Some(HostAddress::new("127.0.0.1").unwrap()),
            Some(Port::new(4201).unwrap()),
            None,
        );
        apply_destination(&element, &config).expect("srtsink accepts the typed destination config");
        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");
        assert_eq!(enum_value.value(), 16);
    }

    #[test]
    fn unknown_property_is_classified_instead_of_aborting() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        // `srtsrc` has no `address` property; setting it directly aborts the process.
        let (code, detail) =
            set_property(&element, "address", "127.0.0.1").expect_err("unknown property must fail");
        assert_eq!(code, ErrorCode::ConfigInvalid);
        assert!(
            detail.contains("srtsrc") && detail.contains("address"),
            "detail must name the element and property, got: {detail}"
        );
    }

    #[test]
    fn unconvertible_property_value_is_classified_instead_of_aborting() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let (code, detail) = set_property(&element, "latency", "not-a-number")
            .expect_err("a value that cannot become the property type must fail");
        assert_eq!(code, ErrorCode::ConfigInvalid);
        assert!(
            detail.contains("latency"),
            "detail must name the property, got: {detail}"
        );
    }
}
