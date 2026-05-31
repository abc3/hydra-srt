use std::net::IpAddr;

use gio::prelude::InetSocketAddressExt;
use gio::{InetSocketAddress, SocketAddress};
use glib::object::Cast;
use ipnet::IpNet;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SrtAccessDecision {
    pub allowed: bool,
    pub reason: &'static str,
    pub ip: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct SrtAccessRules {
    limit_access: bool,
    allowed_list: Vec<IpNet>,
    denied_list: Vec<IpNet>,
}

impl SrtAccessRules {
    pub fn from_props(props: &std::collections::BTreeMap<String, Value>) -> Self {
        Self {
            limit_access: props
                .get("hydra_limit_access")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            allowed_list: parse_access_list(props.get("hydra_allowed_list")),
            denied_list: parse_access_list(props.get("hydra_denied_list")),
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

fn parse_access_list(value: Option<&Value>) -> Vec<IpNet> {
    value
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(Value::as_str)
                .filter_map(|entry| parse_access_entry(entry.trim()))
                .collect()
        })
        .unwrap_or_default()
}

fn parse_access_entry(entry: &str) -> Option<IpNet> {
    if entry.is_empty() {
        return None;
    }

    if let Ok(net) = entry.parse::<IpNet>() {
        return Some(net);
    }

    entry.parse::<IpAddr>().ok().map(IpNet::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    fn rules(
        limit_access: bool,
        allowed_list: Vec<&str>,
        denied_list: Vec<&str>,
    ) -> SrtAccessRules {
        let mut props = BTreeMap::new();
        props.insert("hydra_limit_access".to_string(), Value::Bool(limit_access));
        props.insert("hydra_allowed_list".to_string(), json!(allowed_list));
        props.insert("hydra_denied_list".to_string(), json!(denied_list));
        SrtAccessRules::from_props(&props)
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
    fn ignores_malformed_rules_without_crashing() {
        let rules = rules(true, vec!["not-an-ip"], vec!["also-bad"]);

        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));

        assert!(decision.allowed);
        assert_eq!(decision.reason, "accepted");
    }

    #[test]
    fn rejects_missing_caller_address_when_limited() {
        let rules = rules(true, vec![], vec![]);

        let decision = rules.check_ip(None);

        assert!(!decision.allowed);
        assert_eq!(decision.reason, "invalid_address");
    }
}
