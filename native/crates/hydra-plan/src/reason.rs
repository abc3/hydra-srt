/// Stable machine-readable error classification used by the route wire protocol.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorCode {
    ConfigInvalid,
    ElementMissing,
    NdiPluginMissing,
    NdiPluginIncompatible,
    NdiRuntimeMissing,
    NdiRequiredVideoMissing,
    NdiRequiredAudioMissing,
    NdiReceiveTimeout,
    NdiSourceEos,
    SourceEos,
    NdiSenderStartFailed,
    LinkFailed,
    NegotiationFailed,
    UnsupportedGraph,
    SrtAuthFailed,
    SrtNoDataSinceStart,
    SrtDataStalledAfterStart,
    RuntimeError,
    Shutdown,
}

impl ErrorCode {
    /// Returns the locked wire representation of this code.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ConfigInvalid => "CONFIG_INVALID",
            Self::ElementMissing => "ELEMENT_MISSING",
            Self::NdiPluginMissing => "NDI_PLUGIN_MISSING",
            Self::NdiPluginIncompatible => "NDI_PLUGIN_INCOMPATIBLE",
            Self::NdiRuntimeMissing => "NDI_RUNTIME_MISSING",
            Self::NdiRequiredVideoMissing => "NDI_REQUIRED_VIDEO_MISSING",
            Self::NdiRequiredAudioMissing => "NDI_REQUIRED_AUDIO_MISSING",
            Self::NdiReceiveTimeout => "NDI_RECEIVE_TIMEOUT",
            Self::NdiSourceEos => "NDI_SOURCE_EOS",
            Self::SourceEos => "SOURCE_EOS",
            Self::NdiSenderStartFailed => "NDI_SENDER_START_FAILED",
            Self::LinkFailed => "LINK_FAILED",
            Self::NegotiationFailed => "NEGOTIATION_FAILED",
            Self::UnsupportedGraph => "UNSUPPORTED_GRAPH",
            Self::SrtAuthFailed => "SRT_AUTH_FAILED",
            Self::SrtNoDataSinceStart => "SRT_NO_DATA_SINCE_START",
            Self::SrtDataStalledAfterStart => "SRT_DATA_STALLED_AFTER_START",
            Self::RuntimeError => "RUNTIME_ERROR",
            Self::Shutdown => "SHUTDOWN",
        }
    }
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

// `as_str` is the single source of truth for the wire strings; serde must
// never diverge from it, so Serialize is implemented through it instead of a
// second derive-generated name table.
impl serde::Serialize for ErrorCode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::ErrorCode;

    #[test]
    fn every_error_code_has_its_locked_wire_string() {
        let cases = [
            (ErrorCode::ConfigInvalid, "CONFIG_INVALID"),
            (ErrorCode::ElementMissing, "ELEMENT_MISSING"),
            (ErrorCode::NdiPluginMissing, "NDI_PLUGIN_MISSING"),
            (ErrorCode::NdiPluginIncompatible, "NDI_PLUGIN_INCOMPATIBLE"),
            (ErrorCode::NdiRuntimeMissing, "NDI_RUNTIME_MISSING"),
            (
                ErrorCode::NdiRequiredVideoMissing,
                "NDI_REQUIRED_VIDEO_MISSING",
            ),
            (
                ErrorCode::NdiRequiredAudioMissing,
                "NDI_REQUIRED_AUDIO_MISSING",
            ),
            (ErrorCode::NdiReceiveTimeout, "NDI_RECEIVE_TIMEOUT"),
            (ErrorCode::NdiSourceEos, "NDI_SOURCE_EOS"),
            (ErrorCode::SourceEos, "SOURCE_EOS"),
            (ErrorCode::NdiSenderStartFailed, "NDI_SENDER_START_FAILED"),
            (ErrorCode::LinkFailed, "LINK_FAILED"),
            (ErrorCode::NegotiationFailed, "NEGOTIATION_FAILED"),
            (ErrorCode::UnsupportedGraph, "UNSUPPORTED_GRAPH"),
            (ErrorCode::SrtAuthFailed, "SRT_AUTH_FAILED"),
            (ErrorCode::SrtNoDataSinceStart, "SRT_NO_DATA_SINCE_START"),
            (
                ErrorCode::SrtDataStalledAfterStart,
                "SRT_DATA_STALLED_AFTER_START",
            ),
            (ErrorCode::RuntimeError, "RUNTIME_ERROR"),
            (ErrorCode::Shutdown, "SHUTDOWN"),
        ];

        for (code, expected) in cases {
            assert_eq!(code.as_str(), expected);
            assert_eq!(
                serde_json::to_string(&code).unwrap(),
                format!("\"{expected}\"")
            );
        }
    }
}
