//! Pure configuration and graph planning for HydraSRT native routes.

pub mod config;
pub mod plan;
pub mod reason;
pub mod representations;

pub use config::{
    parse, BoundedMs, Cidr, DestinationEndpoint, HlsEndAction, HlsSource, HlsTargetDurationMs,
    HlsUri, HostAddress, InterfaceName, LatencyMs, LegacyKind, MaxQueueLength, MediaPolicy,
    NdiBandwidth, NdiColorFormat, NdiDestination, NdiSource, NdiTimestampMode, Pbkeylen,
    PollTimeoutMs, Port, ProgramNumber, RouteConfig, RtmpEndpoint, RtmpUri, SourceEndpoint,
    SrtAccess, SrtDestination, SrtMode, SrtSource, SrtStreamIdMatch, SrtUri, UdpEndpoint,
};
pub use plan::{
    branch_tracks, plan, BranchPlan, GraphPlan, PlanError, QueueClass, SinkAdapterPlan,
    SourceAdapterPlan, SourcePlan,
};
pub use reason::ErrorCode;
pub use representations::{BranchTracks, MediaKind, RequiredMedia, TrackNeed};
