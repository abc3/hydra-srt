use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;

use ipnet::IpNet;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::plan::PlanError;

/// An inclusive millisecond range checked during construction/deserialization.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct BoundedMs<const MIN: u64, const MAX: u64>(u64);

impl<const MIN: u64, const MAX: u64> BoundedMs<MIN, MAX> {
    pub fn new(value: u64) -> Result<Self, ConfigError> {
        if (MIN..=MAX).contains(&value) {
            Ok(Self(value))
        } else {
            Err(ConfigError::OutOfBounds {
                field: "milliseconds",
                value,
                min: MIN,
                max: MAX,
            })
        }
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}

impl<const MIN: u64, const MAX: u64> TryFrom<u64> for BoundedMs<MIN, MAX> {
    type Error = ConfigError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl<const MIN: u64, const MAX: u64> From<BoundedMs<MIN, MAX>> for u64 {
    fn from(value: BoundedMs<MIN, MAX>) -> Self {
        value.get()
    }
}

/// Inclusive NDI source queue bound checked at the parse boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct MaxQueueLength(u32);

impl MaxQueueLength {
    pub fn new(value: u64) -> Result<Self, ConfigError> {
        if (1..=64).contains(&value) {
            Ok(Self(value as u32))
        } else {
            Err(ConfigError::OutOfBounds {
                field: "max_queue_length",
                value,
                min: 1,
                max: 64,
            })
        }
    }

    pub const fn get(self) -> u32 {
        self.0
    }
}

impl TryFrom<u64> for MaxQueueLength {
    type Error = ConfigError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<MaxQueueLength> for u64 {
    fn from(value: MaxQueueLength) -> Self {
        u64::from(value.get())
    }
}

pub type NdiTimeoutMs = BoundedMs<1_000, 60_000>;

/// SRT latency in milliseconds (inclusive).
pub type LatencyMs = BoundedMs<0, 600_000>;

/// SRT poll-timeout in milliseconds (inclusive). `-1` means infinite in GStreamer SRT.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "i64", into = "i64")]
pub struct PollTimeoutMs(i32);

impl PollTimeoutMs {
    pub fn new(value: i64) -> Result<Self, ConfigError> {
        if (-1..=3_600_000).contains(&value) {
            Ok(Self(value as i32))
        } else {
            Err(ConfigError::OutOfBoundsSigned {
                field: "poll_timeout",
                value,
                min: -1,
                max: 3_600_000,
            })
        }
    }

    pub const fn get(self) -> i32 {
        self.0
    }
}

impl TryFrom<i64> for PollTimeoutMs {
    type Error = ConfigError;

    fn try_from(value: i64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<PollTimeoutMs> for i64 {
    fn from(value: PollTimeoutMs) -> Self {
        i64::from(value.get())
    }
}

/// Transport port in the inclusive range 1..=65535.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct Port(u16);

impl Port {
    pub fn new(value: u64) -> Result<Self, ConfigError> {
        if (1..=65535).contains(&value) {
            Ok(Self(value as u16))
        } else {
            Err(ConfigError::OutOfBounds {
                field: "port",
                value,
                min: 1,
                max: 65_535,
            })
        }
    }

    pub const fn get(self) -> u16 {
        self.0
    }
}

impl TryFrom<u64> for Port {
    type Error = ConfigError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<Port> for u64 {
    fn from(value: Port) -> Self {
        u64::from(value.get())
    }
}

/// MPEG-TS program number in the inclusive range 1..=65535.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct ProgramNumber(u16);

impl ProgramNumber {
    pub fn new(value: u64) -> Result<Self, ConfigError> {
        if (1..=65535).contains(&value) {
            Ok(Self(value as u16))
        } else {
            Err(ConfigError::OutOfBounds {
                field: "program_number",
                value,
                min: 1,
                max: 65_535,
            })
        }
    }

    pub const fn get(self) -> u16 {
        self.0
    }
}

impl TryFrom<u64> for ProgramNumber {
    type Error = ConfigError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<ProgramNumber> for u64 {
    fn from(value: ProgramNumber) -> Self {
        u64::from(value.get())
    }
}

/// IP address or validated hostname (never forwarded as an unchecked string).
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct HostAddress(String);

impl HostAddress {
    pub fn new(value: impl Into<String>) -> Result<Self, ConfigError> {
        let value = value.into();
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(ConfigError::InvalidHostAddress {
                value: value.clone(),
            });
        }
        if trimmed.parse::<IpAddr>().is_ok() {
            return Ok(Self(trimmed.to_owned()));
        }
        if is_bracketed_ipv6(trimmed) {
            return Ok(Self(trimmed.to_owned()));
        }
        if is_dns_hostname(trimmed) {
            return Ok(Self(trimmed.to_owned()));
        }
        Err(ConfigError::InvalidHostAddress {
            value: value.clone(),
        })
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for HostAddress {
    type Error = ConfigError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<HostAddress> for String {
    fn from(value: HostAddress) -> Self {
        value.0
    }
}

/// Network interface name used for multicast / bind iface properties.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct InterfaceName(String);

impl InterfaceName {
    pub fn new(value: impl Into<String>) -> Result<Self, ConfigError> {
        let value = value.into();
        let trimmed = value.trim();
        if trimmed.is_empty()
            || !trimmed
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
        {
            return Err(ConfigError::InvalidInterfaceName {
                value: value.clone(),
            });
        }
        Ok(Self(trimmed.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for InterfaceName {
    type Error = ConfigError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<InterfaceName> for String {
    fn from(value: InterfaceName) -> Self {
        value.0
    }
}

/// Validated `srt://` URI (scheme + host:port required).
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct SrtUri(String);

impl SrtUri {
    pub fn new(value: impl Into<String>) -> Result<Self, ConfigError> {
        let value = value.into();
        if !value.starts_with("srt://") {
            return Err(ConfigError::InvalidUri {
                scheme: "srt",
                value: value.clone(),
            });
        }
        let rest = &value["srt://".len()..];
        let authority = rest.split(['?', '#']).next().unwrap_or("");
        if !authority_has_host_port(authority) {
            return Err(ConfigError::InvalidUri {
                scheme: "srt",
                value: value.clone(),
            });
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SrtUri {
    type Error = ConfigError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<SrtUri> for String {
    fn from(value: SrtUri) -> Self {
        value.0
    }
}

/// Validated `rtmp://` URI (scheme + host required).
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RtmpUri(String);

impl RtmpUri {
    pub fn new(value: impl Into<String>) -> Result<Self, ConfigError> {
        let value = value.into();
        if !value.starts_with("rtmp://") {
            return Err(ConfigError::InvalidUri {
                scheme: "rtmp",
                value: value.clone(),
            });
        }
        let rest = &value["rtmp://".len()..];
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        if authority.is_empty() {
            return Err(ConfigError::InvalidUri {
                scheme: "rtmp",
                value: value.clone(),
            });
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for RtmpUri {
    type Error = ConfigError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<RtmpUri> for String {
    fn from(value: RtmpUri) -> Self {
        value.0
    }
}

/// Validated CIDR or single-host network for SRT access lists.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Cidr(IpNet);

impl Cidr {
    pub fn new(value: impl AsRef<str>) -> Result<Self, ConfigError> {
        let entry = value.as_ref().trim();
        if entry.is_empty() {
            return Err(ConfigError::InvalidCidr {
                value: entry.to_owned(),
            });
        }
        if let Ok(net) = entry.parse::<IpNet>() {
            return Ok(Self(net));
        }
        if let Ok(ip) = entry.parse::<IpAddr>() {
            return Ok(Self(IpNet::from(ip)));
        }
        Err(ConfigError::InvalidCidr {
            value: entry.to_owned(),
        })
    }

    pub fn as_ipnet(&self) -> IpNet {
        self.0
    }

    pub fn as_str(&self) -> String {
        self.0.to_string()
    }
}

impl TryFrom<String> for Cidr {
    type Error = ConfigError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<Cidr> for String {
    fn from(value: Cidr) -> Self {
        value.0.to_string()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaPolicy {
    VideoAndAudioRequired,
    VideoRequiredAudioOptional,
    VideoOnly,
    AudioOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NdiBandwidth {
    Highest,
    AudioOnly,
}

impl NdiBandwidth {
    /// Total mapping to the `ndisrc.bandwidth` integer property.
    pub const fn property_value(self) -> i32 {
        match self {
            Self::Highest => 100,
            Self::AudioOnly => 10,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum NdiColorFormat {
    #[serde(rename = "uyvy-bgra")]
    UyvyBgra,
    #[serde(rename = "fastest")]
    Fastest,
    #[serde(rename = "best")]
    Best,
    #[serde(rename = "bgrx-bgra")]
    BgrxBgra,
    #[serde(rename = "rgbx-rgba")]
    RgbxRgba,
    #[serde(rename = "uyvy-rgba")]
    UyvyRgba,
}

impl NdiColorFormat {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::UyvyBgra => "uyvy-bgra",
            Self::Fastest => "fastest",
            Self::Best => "best",
            Self::BgrxBgra => "bgrx-bgra",
            Self::RgbxRgba => "rgbx-rgba",
            Self::UyvyRgba => "uyvy-rgba",
        }
    }
}

/// Allowlisted `ndisrc timestamp-mode` nicks (gst-plugin-ndi).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum NdiTimestampMode {
    #[serde(rename = "auto")]
    Auto,
    #[serde(rename = "receive-time")]
    ReceiveTime,
    #[serde(rename = "timecode")]
    Timecode,
    #[serde(rename = "timestamp")]
    Timestamp,
    #[serde(rename = "receive-time-vs-timestamp")]
    ReceiveTimeVsTimestamp,
}

impl NdiTimestampMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::ReceiveTime => "receive-time",
            Self::Timecode => "timecode",
            Self::Timestamp => "timestamp",
            Self::ReceiveTimeVsTimestamp => "receive-time-vs-timestamp",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "NdiSourceWire", into = "NdiSourceWire")]
pub struct NdiSource {
    source_name: Option<String>,
    url_address: Option<String>,
    receiver_name: String,
    bandwidth: NdiBandwidth,
    color_format: NdiColorFormat,
    timestamp_mode: Option<NdiTimestampMode>,
    media_policy: MediaPolicy,
    connect_timeout_ms: NdiTimeoutMs,
    receive_timeout_ms: NdiTimeoutMs,
    track_discovery_timeout_ms: NdiTimeoutMs,
    max_queue_length: MaxQueueLength,
}

/// The serde-facing form carries the unknown-field rejection contract.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct NdiSourceWire {
    source_name: Option<String>,
    url_address: Option<String>,
    receiver_name: String,
    bandwidth: NdiBandwidth,
    color_format: NdiColorFormat,
    timestamp_mode: Option<NdiTimestampMode>,
    media_policy: MediaPolicy,
    connect_timeout_ms: NdiTimeoutMs,
    receive_timeout_ms: NdiTimeoutMs,
    track_discovery_timeout_ms: NdiTimeoutMs,
    max_queue_length: MaxQueueLength,
}

impl TryFrom<NdiSourceWire> for NdiSource {
    type Error = ConfigError;

    fn try_from(value: NdiSourceWire) -> Result<Self, Self::Error> {
        match (&value.source_name, &value.url_address) {
            (Some(_), None) | (None, Some(_)) => Ok(Self {
                source_name: value.source_name,
                url_address: value.url_address,
                receiver_name: value.receiver_name,
                bandwidth: value.bandwidth,
                color_format: value.color_format,
                timestamp_mode: value.timestamp_mode,
                media_policy: value.media_policy,
                connect_timeout_ms: value.connect_timeout_ms,
                receive_timeout_ms: value.receive_timeout_ms,
                track_discovery_timeout_ms: value.track_discovery_timeout_ms,
                max_queue_length: value.max_queue_length,
            }),
            _ => Err(ConfigError::InvalidNdiLocator),
        }
    }
}

impl From<NdiSource> for NdiSourceWire {
    fn from(value: NdiSource) -> Self {
        Self {
            source_name: value.source_name,
            url_address: value.url_address,
            receiver_name: value.receiver_name,
            bandwidth: value.bandwidth,
            color_format: value.color_format,
            timestamp_mode: value.timestamp_mode,
            media_policy: value.media_policy,
            connect_timeout_ms: value.connect_timeout_ms,
            receive_timeout_ms: value.receive_timeout_ms,
            track_discovery_timeout_ms: value.track_discovery_timeout_ms,
            max_queue_length: value.max_queue_length,
        }
    }
}

impl NdiSource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        source_name: Option<String>,
        url_address: Option<String>,
        receiver_name: String,
        bandwidth: NdiBandwidth,
        color_format: NdiColorFormat,
        timestamp_mode: Option<NdiTimestampMode>,
        media_policy: MediaPolicy,
        connect_timeout_ms: NdiTimeoutMs,
        receive_timeout_ms: NdiTimeoutMs,
        track_discovery_timeout_ms: NdiTimeoutMs,
        max_queue_length: MaxQueueLength,
    ) -> Result<Self, ConfigError> {
        NdiSourceWire {
            source_name,
            url_address,
            receiver_name,
            bandwidth,
            color_format,
            timestamp_mode,
            media_policy,
            connect_timeout_ms,
            receive_timeout_ms,
            track_discovery_timeout_ms,
            max_queue_length,
        }
        .try_into()
    }

    pub fn source_name(&self) -> Option<&str> {
        self.source_name.as_deref()
    }

    pub fn url_address(&self) -> Option<&str> {
        self.url_address.as_deref()
    }

    pub fn receiver_name(&self) -> &str {
        &self.receiver_name
    }

    pub const fn bandwidth(&self) -> NdiBandwidth {
        self.bandwidth
    }

    pub const fn color_format(&self) -> NdiColorFormat {
        self.color_format
    }

    pub const fn timestamp_mode(&self) -> Option<NdiTimestampMode> {
        self.timestamp_mode
    }

    pub const fn media_policy(&self) -> MediaPolicy {
        self.media_policy
    }

    pub const fn connect_timeout_ms(&self) -> NdiTimeoutMs {
        self.connect_timeout_ms
    }

    pub const fn receive_timeout_ms(&self) -> NdiTimeoutMs {
        self.receive_timeout_ms
    }

    pub const fn track_discovery_timeout_ms(&self) -> NdiTimeoutMs {
        self.track_discovery_timeout_ms
    }

    pub const fn max_queue_length(&self) -> MaxQueueLength {
        self.max_queue_length
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NdiDestination {
    sender_name: String,
    media_policy: MediaPolicy,
}

impl NdiDestination {
    pub fn new(sender_name: String, media_policy: MediaPolicy) -> Self {
        Self {
            sender_name,
            media_policy,
        }
    }

    pub fn sender_name(&self) -> &str {
        &self.sender_name
    }

    pub const fn media_policy(&self) -> MediaPolicy {
        self.media_policy
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LegacyKind {
    Srt,
    Udp,
    Rtp,
    Rtmp,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SrtMode {
    Listener,
    Caller,
    Rendezvous,
}

impl SrtMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Listener => "listener",
            Self::Caller => "caller",
            Self::Rendezvous => "rendezvous",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub enum Pbkeylen {
    None = 0,
    Aes128 = 16,
    Aes192 = 24,
    Aes256 = 32,
}

impl Pbkeylen {
    pub fn new(value: u64) -> Result<Self, ConfigError> {
        match value {
            0 => Ok(Self::None),
            16 => Ok(Self::Aes128),
            24 => Ok(Self::Aes192),
            32 => Ok(Self::Aes256),
            _ => Err(ConfigError::InvalidPbkeylen { value }),
        }
    }

    pub const fn as_i32(self) -> i32 {
        self as i32
    }
}

impl TryFrom<u64> for Pbkeylen {
    type Error = ConfigError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<Pbkeylen> for u64 {
    fn from(value: Pbkeylen) -> Self {
        value as u64
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SrtAccess {
    limit: bool,
    #[serde(default)]
    allowed: Vec<Cidr>,
    #[serde(default)]
    denied: Vec<Cidr>,
}

impl SrtAccess {
    pub fn new(limit: bool, allowed: Vec<Cidr>, denied: Vec<Cidr>) -> Self {
        Self {
            limit,
            allowed,
            denied,
        }
    }

    pub const fn limit(&self) -> bool {
        self.limit
    }

    pub fn allowed(&self) -> &[Cidr] {
        &self.allowed
    }

    pub fn denied(&self) -> &[Cidr] {
        &self.denied
    }
}

/// SRT source payload. `access` is source-only (rejected on destinations).
///
/// SRT carries the peer host/port in `uri` and expresses bind selection through
/// `localaddress`/`localport`; the udp-only `address`/`port`/`bind_address`/
/// `multicast_iface` fields have no SRT counterpart and fail closed here.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SrtSource {
    uri: SrtUri,
    mode: SrtMode,
    latency: Option<LatencyMs>,
    auto_reconnect: Option<bool>,
    keep_listening: Option<bool>,
    poll_timeout: Option<PollTimeoutMs>,
    passphrase: Option<String>,
    pbkeylen: Option<Pbkeylen>,
    streamid: Option<String>,
    localaddress: Option<HostAddress>,
    localport: Option<Port>,
    /// Inventory-consumed explicit auth flag (also forced from access/streamid).
    authentication: Option<bool>,
    access: Option<SrtAccess>,
    #[serde(skip_serializing_if = "Option::is_none")]
    program_number: Option<ProgramNumber>,
}

/// SRT destination payload. Unknown `access` field fails closed via deny_unknown_fields.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SrtDestination {
    uri: SrtUri,
    mode: SrtMode,
    latency: Option<LatencyMs>,
    auto_reconnect: Option<bool>,
    keep_listening: Option<bool>,
    poll_timeout: Option<PollTimeoutMs>,
    passphrase: Option<String>,
    pbkeylen: Option<Pbkeylen>,
    streamid: Option<String>,
    localaddress: Option<HostAddress>,
    localport: Option<Port>,
    authentication: Option<bool>,
}

macro_rules! srt_accessors {
    ($ty:ty) => {
        impl $ty {
            pub fn uri(&self) -> &SrtUri {
                &self.uri
            }
            pub const fn mode(&self) -> SrtMode {
                self.mode
            }
            pub const fn latency(&self) -> Option<LatencyMs> {
                self.latency
            }
            pub const fn auto_reconnect(&self) -> Option<bool> {
                self.auto_reconnect
            }
            pub const fn keep_listening(&self) -> Option<bool> {
                self.keep_listening
            }
            pub const fn poll_timeout(&self) -> Option<PollTimeoutMs> {
                self.poll_timeout
            }
            pub fn passphrase(&self) -> Option<&str> {
                self.passphrase.as_deref()
            }
            pub const fn pbkeylen(&self) -> Option<Pbkeylen> {
                self.pbkeylen
            }
            pub fn streamid(&self) -> Option<&str> {
                self.streamid.as_deref()
            }
            pub fn localaddress(&self) -> Option<&HostAddress> {
                self.localaddress.as_ref()
            }
            pub const fn localport(&self) -> Option<Port> {
                self.localport
            }
            pub const fn authentication(&self) -> Option<bool> {
                self.authentication
            }
        }
    };
}

srt_accessors!(SrtSource);
srt_accessors!(SrtDestination);

impl SrtSource {
    pub const fn program_number(&self) -> Option<ProgramNumber> {
        self.program_number
    }

    pub fn access(&self) -> Option<&SrtAccess> {
        self.access.as_ref()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        uri: SrtUri,
        mode: SrtMode,
        latency: Option<LatencyMs>,
        auto_reconnect: Option<bool>,
        keep_listening: Option<bool>,
        poll_timeout: Option<PollTimeoutMs>,
        passphrase: Option<String>,
        pbkeylen: Option<Pbkeylen>,
        streamid: Option<String>,
        localaddress: Option<HostAddress>,
        localport: Option<Port>,
        authentication: Option<bool>,
        access: Option<SrtAccess>,
        program_number: Option<ProgramNumber>,
    ) -> Self {
        Self {
            uri,
            mode,
            latency,
            auto_reconnect,
            keep_listening,
            poll_timeout,
            passphrase,
            pbkeylen,
            streamid,
            localaddress,
            localport,
            authentication,
            access,
            program_number,
        }
    }
}

impl SrtDestination {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        uri: SrtUri,
        mode: SrtMode,
        latency: Option<LatencyMs>,
        auto_reconnect: Option<bool>,
        keep_listening: Option<bool>,
        poll_timeout: Option<PollTimeoutMs>,
        passphrase: Option<String>,
        pbkeylen: Option<Pbkeylen>,
        streamid: Option<String>,
        localaddress: Option<HostAddress>,
        localport: Option<Port>,
        authentication: Option<bool>,
    ) -> Self {
        Self {
            uri,
            mode,
            latency,
            auto_reconnect,
            keep_listening,
            poll_timeout,
            passphrase,
            pbkeylen,
            streamid,
            localaddress,
            localport,
            authentication,
        }
    }
}

/// Shared UDP/RTP endpoint payload.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UdpEndpoint {
    address: HostAddress,
    port: Port,
    auto_multicast: Option<bool>,
    multicast_iface: Option<InterfaceName>,
    bind_address: Option<HostAddress>,
    #[serde(skip_serializing_if = "Option::is_none")]
    program_number: Option<ProgramNumber>,
}

impl UdpEndpoint {
    pub fn new(
        address: HostAddress,
        port: Port,
        auto_multicast: Option<bool>,
        multicast_iface: Option<InterfaceName>,
        bind_address: Option<HostAddress>,
        program_number: Option<ProgramNumber>,
    ) -> Self {
        Self {
            address,
            port,
            auto_multicast,
            multicast_iface,
            bind_address,
            program_number,
        }
    }

    pub fn address(&self) -> &HostAddress {
        &self.address
    }

    pub const fn port(&self) -> Port {
        self.port
    }

    pub const fn auto_multicast(&self) -> Option<bool> {
        self.auto_multicast
    }

    pub fn multicast_iface(&self) -> Option<&InterfaceName> {
        self.multicast_iface.as_ref()
    }

    pub fn bind_address(&self) -> Option<&HostAddress> {
        self.bind_address.as_ref()
    }

    pub const fn program_number(&self) -> Option<ProgramNumber> {
        self.program_number
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RtmpEndpoint {
    location: RtmpUri,
}

impl RtmpEndpoint {
    pub fn new(location: RtmpUri) -> Self {
        Self { location }
    }

    pub fn location(&self) -> &RtmpUri {
        &self.location
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum SourceEndpoint {
    Ndi {
        id: String,
        #[serde(default)]
        name: String,
        ndi: NdiSource,
    },
    Srt {
        id: String,
        #[serde(default)]
        name: String,
        srt: SrtSource,
    },
    Udp {
        id: String,
        #[serde(default)]
        name: String,
        udp: UdpEndpoint,
    },
    Rtp {
        id: String,
        #[serde(default)]
        name: String,
        rtp: UdpEndpoint,
    },
    Rtmp {
        id: String,
        #[serde(default)]
        name: String,
        rtmp: RtmpEndpoint,
    },
}

impl SourceEndpoint {
    pub fn id(&self) -> &str {
        match self {
            Self::Ndi { id, .. }
            | Self::Srt { id, .. }
            | Self::Udp { id, .. }
            | Self::Rtp { id, .. }
            | Self::Rtmp { id, .. } => id,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Ndi { name, .. }
            | Self::Srt { name, .. }
            | Self::Udp { name, .. }
            | Self::Rtp { name, .. }
            | Self::Rtmp { name, .. } => name,
        }
    }

    pub const fn is_ndi(&self) -> bool {
        matches!(self, Self::Ndi { .. })
    }

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum DestinationEndpoint {
    Ndi {
        id: String,
        #[serde(default)]
        name: String,
        ndi: NdiDestination,
    },
    Srt {
        id: String,
        #[serde(default)]
        name: String,
        srt: SrtDestination,
    },
    Udp {
        id: String,
        #[serde(default)]
        name: String,
        udp: UdpEndpoint,
    },
    /// Parsed so plan can reject with `UNSUPPORTED_GRAPH` (no RTP sink).
    Rtp {
        id: String,
        #[serde(default)]
        name: String,
        rtp: UdpEndpoint,
    },
    Rtmp {
        id: String,
        #[serde(default)]
        name: String,
        rtmp: RtmpEndpoint,
    },
}

impl DestinationEndpoint {
    pub fn id(&self) -> &str {
        match self {
            Self::Ndi { id, .. }
            | Self::Srt { id, .. }
            | Self::Udp { id, .. }
            | Self::Rtp { id, .. }
            | Self::Rtmp { id, .. } => id,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Ndi { name, .. }
            | Self::Srt { name, .. }
            | Self::Udp { name, .. }
            | Self::Rtp { name, .. }
            | Self::Rtmp { name, .. } => name,
        }
    }

    pub const fn is_ndi(&self) -> bool {
        matches!(self, Self::Ndi { .. })
    }

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteConfig {
    pub route_id: String,
    pub config_revision: String,
    pub process_instance_id: String,
    pub source: SourceEndpoint,
    pub destinations: Vec<DestinationEndpoint>,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("{field} value {value} is outside the inclusive range {min}..={max}")]
    OutOfBounds {
        field: &'static str,
        value: u64,
        min: u64,
        max: u64,
    },
    #[error("{field} value {value} is outside the inclusive range {min}..={max}")]
    OutOfBoundsSigned {
        field: &'static str,
        value: i64,
        min: i64,
        max: i64,
    },
    #[error("exactly one of source_name or url_address must be non-null")]
    InvalidNdiLocator,
    #[error("invalid {scheme} URI: {value}")]
    InvalidUri { scheme: &'static str, value: String },
    #[error("invalid host address: {value}")]
    InvalidHostAddress { value: String },
    #[error("invalid interface name: {value}")]
    InvalidInterfaceName { value: String },
    #[error("invalid CIDR: {value}")]
    InvalidCidr { value: String },
    #[error("pbkeylen must be one of 0, 16, 24, 32; got {value}")]
    InvalidPbkeylen { value: u64 },
}

/// Parses the only supported route configuration shape.
pub fn parse(input: &str) -> Result<RouteConfig, PlanError> {
    serde_json::from_str(input).map_err(PlanError::from)
}

fn is_bracketed_ipv6(value: &str) -> bool {
    value
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .is_some_and(|inner| inner.parse::<Ipv6Addr>().is_ok())
}

fn is_dns_hostname(value: &str) -> bool {
    if value.len() > 253 || value.starts_with('.') || value.ends_with('.') {
        return false;
    }
    value.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric())
            && label
                .chars()
                .last()
                .is_some_and(|c| c.is_ascii_alphanumeric())
            && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    })
}

fn authority_has_host_port(authority: &str) -> bool {
    if authority.is_empty() {
        return false;
    }
    if let Some(host) = authority.strip_prefix('[') {
        let Some((addr, rest)) = host.split_once(']') else {
            return false;
        };
        if addr.parse::<Ipv6Addr>().is_err() {
            return false;
        }
        return rest
            .strip_prefix(':')
            .and_then(|port| u16::from_str(port).ok())
            .is_some_and(|port| port > 0);
    }
    let Some((host, port)) = authority.rsplit_once(':') else {
        return false;
    };
    if host.is_empty() || u16::from_str(port).ok().is_none_or(|p| p == 0) {
        return false;
    }
    host.parse::<Ipv4Addr>().is_ok() || is_dns_hostname(host)
}

#[cfg(test)]
mod tests {
    use super::{
        parse, ConfigError, HostAddress, NdiBandwidth, NdiColorFormat, NdiTimestampMode, Pbkeylen,
        Port, ProgramNumber, SrtMode, SrtUri,
    };
    use crate::{plan, ErrorCode};

    const VALID_FIXTURES: &[&str] = &[
        include_str!("../tests/fixtures/valid_ndi_av.json"),
        include_str!("../tests/fixtures/valid_ndi_two_destinations.json"),
        include_str!("../tests/fixtures/valid_ndi_audio_only.json"),
        include_str!("../tests/fixtures/valid_legacy_srt_to_srt_udp.json"),
    ];

    const INVALID_PARSE_FIXTURES: &[&str] = &[
        include_str!("../tests/fixtures/invalid_unknown_ndi_field.json"),
        include_str!("../tests/fixtures/invalid_both_locator_fields.json"),
        include_str!("../tests/fixtures/invalid_neither_locator_field.json"),
        include_str!("../tests/fixtures/invalid_timeout_999.json"),
        include_str!("../tests/fixtures/invalid_timeout_60001.json"),
        include_str!("../tests/fixtures/invalid_metadata_only_bandwidth.json"),
        include_str!("../tests/fixtures/invalid_unknown_config_field.json"),
        include_str!("../tests/fixtures/invalid_bad_srt_uri_scheme.json"),
        include_str!("../tests/fixtures/invalid_out_of_range_port.json"),
        include_str!("../tests/fixtures/invalid_bad_pbkeylen.json"),
        include_str!("../tests/fixtures/invalid_bad_srt_mode.json"),
        include_str!("../tests/fixtures/invalid_unknown_srt_field.json"),
        include_str!("../tests/fixtures/invalid_srt_udp_only_field.json"),
        include_str!("../tests/fixtures/invalid_null_endpoint_name.json"),
    ];

    #[test]
    fn valid_fixture_matrix_parses_and_plans() {
        for fixture in VALID_FIXTURES {
            let config = parse(fixture).unwrap();
            plan(&config).unwrap();
        }
    }

    #[test]
    fn invalid_parse_fixture_matrix_is_config_invalid() {
        for fixture in INVALID_PARSE_FIXTURES {
            let error = parse(fixture).unwrap_err();
            assert_eq!(error.code(), ErrorCode::ConfigInvalid);
        }
    }

    #[test]
    fn bandwidth_mapping_and_color_allowlist_are_total() {
        assert_eq!(NdiBandwidth::Highest.property_value(), 100);
        assert_eq!(NdiBandwidth::AudioOnly.property_value(), 10);

        let formats = [
            (NdiColorFormat::UyvyBgra, "uyvy-bgra"),
            (NdiColorFormat::Fastest, "fastest"),
            (NdiColorFormat::Best, "best"),
            (NdiColorFormat::BgrxBgra, "bgrx-bgra"),
            (NdiColorFormat::RgbxRgba, "rgbx-rgba"),
            (NdiColorFormat::UyvyRgba, "uyvy-rgba"),
        ];
        for (format, expected) in formats {
            assert_eq!(format.as_str(), expected);
        }

        let modes = [
            (NdiTimestampMode::Auto, "auto"),
            (NdiTimestampMode::ReceiveTime, "receive-time"),
            (NdiTimestampMode::Timecode, "timecode"),
            (NdiTimestampMode::Timestamp, "timestamp"),
            (
                NdiTimestampMode::ReceiveTimeVsTimestamp,
                "receive-time-vs-timestamp",
            ),
        ];
        for (mode, expected) in modes {
            assert_eq!(mode.as_str(), expected);
        }
    }

    #[test]
    fn invalid_timestamp_mode_is_config_invalid_at_parse() {
        let fixture = r#"{
          "route_id":"r","config_revision":"c","process_instance_id":"p",
          "source":{"id":"s","kind":"ndi","ndi":{
            "source_name":"MACHINE (CHANNEL)","url_address":null,
            "receiver_name":"Hydra","bandwidth":"highest","color_format":"uyvy-bgra",
            "timestamp_mode":"not-a-timestamp-mode","media_policy":"video_only",
            "connect_timeout_ms":10000,"receive_timeout_ms":5000,
            "track_discovery_timeout_ms":10000,"max_queue_length":4
          }},
          "destinations":[{"id":"d","kind":"ndi","ndi":{
            "sender_name":"Out","media_policy":"video_only"
          }}]
        }"#;
        assert_eq!(parse(fixture).unwrap_err().code(), ErrorCode::ConfigInvalid);
    }

    #[test]
    fn srt_payload_names_the_udp_only_field_it_rejects() {
        let error = parse(include_str!(
            "../tests/fixtures/invalid_srt_udp_only_field.json"
        ))
        .unwrap_err();
        assert_eq!(error.code(), ErrorCode::ConfigInvalid);
        assert!(
            error.context().contains("unknown field `address`"),
            "rejection must name the offending field, got: {}",
            error.context()
        );
    }

    #[test]
    fn program_number_round_trips_through_serde() {
        let parsed: ProgramNumber = serde_json::from_str("12").expect("valid program number");
        assert_eq!(parsed.get(), 12);
        assert_eq!(serde_json::to_string(&parsed).expect("serializes"), "12");

        assert!(serde_json::from_str::<ProgramNumber>("0").is_err());
        assert!(serde_json::from_str::<ProgramNumber>("65536").is_err());
    }

    #[test]
    fn program_number_reports_its_bounds_when_rejected() {
        let error = ProgramNumber::new(65_536).expect_err("out of range");
        assert!(matches!(
            error,
            ConfigError::OutOfBounds {
                field: "program_number",
                value: 65_536,
                min: 1,
                max: 65_535,
            }
        ));
        assert_eq!(u64::from(ProgramNumber::new(12).unwrap()), 12);
    }

    #[test]
    fn newtypes_reject_invalid_values() {
        assert!(SrtUri::new("http://127.0.0.1:9000").is_err());
        assert!(SrtUri::new("srt://127.0.0.1:9000").is_ok());
        assert!(Port::new(0).is_err());
        assert!(Port::new(65535).is_ok());
        assert!(ProgramNumber::new(0).is_err());
        assert_eq!(ProgramNumber::new(65535).unwrap().get(), 65535);
        assert!(Pbkeylen::new(8).is_err());
        assert_eq!(Pbkeylen::new(16).unwrap(), Pbkeylen::Aes128);
        assert!(HostAddress::new("").is_err());
        assert!(HostAddress::new("127.0.0.1").is_ok());
        assert_eq!(SrtMode::Caller.as_str(), "caller");
    }
}
