use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::ErrorCode;

use crate::adapters::ndi_source::classify_readiness_details;
use crate::events::{EndpointDirection, EndpointState, EventSink, RetryDomain, Transport};
use crate::lifecycle::FailureReason;
use crate::runtime::{EndpointDescriptor, PipelineRuntime};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ErrorClassification {
    pub code: ErrorCode,
    pub retryable: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TypedGstError {
    Resource(gst::ResourceError),
    Core(gst::CoreError),
    Stream(gst::StreamError),
    Library(gst::LibraryError),
    Other,
}

pub fn classify_typed_error(error: TypedGstError) -> ErrorClassification {
    match error {
        TypedGstError::Core(
            gst::CoreError::Negotiation | gst::CoreError::Caps | gst::CoreError::Pad,
        )
        | TypedGstError::Stream(
            gst::StreamError::TypeNotFound
            | gst::StreamError::WrongType
            | gst::StreamError::CodecNotFound
            | gst::StreamError::Decode
            | gst::StreamError::Encode
            | gst::StreamError::Demux
            | gst::StreamError::Mux
            | gst::StreamError::Format,
        ) => ErrorClassification {
            code: ErrorCode::NegotiationFailed,
            retryable: false,
        },
        TypedGstError::Core(gst::CoreError::MissingPlugin) => ErrorClassification {
            code: ErrorCode::ElementMissing,
            retryable: false,
        },
        TypedGstError::Resource(_) => ErrorClassification {
            code: ErrorCode::RuntimeError,
            retryable: true,
        },
        TypedGstError::Core(_)
        | TypedGstError::Stream(_)
        | TypedGstError::Library(_)
        | TypedGstError::Other => ErrorClassification {
            code: ErrorCode::RuntimeError,
            retryable: true,
        },
    }
}

pub fn classify_gst_error(error: &glib::Error) -> ErrorClassification {
    let typed = if let Some(kind) = error.kind::<gst::ResourceError>() {
        TypedGstError::Resource(kind)
    } else if let Some(kind) = error.kind::<gst::CoreError>() {
        TypedGstError::Core(kind)
    } else if let Some(kind) = error.kind::<gst::StreamError>() {
        TypedGstError::Stream(kind)
    } else if let Some(kind) = error.kind::<gst::LibraryError>() {
        TypedGstError::Library(kind)
    } else {
        TypedGstError::Other
    };
    classify_typed_error(typed)
}

pub fn attach_bus_watch(
    runtime: &PipelineRuntime,
    event_sink: EventSink,
    endpoints: &[EndpointDescriptor],
    eos_seen: Arc<AtomicBool>,
) -> Result<gst::bus::BusWatchGuard> {
    let bus = runtime
        .pipeline
        .bus()
        .ok_or_else(|| anyhow::anyhow!("pipeline has no bus"))?;
    let endpoint_by_bin: HashMap<_, _> = endpoints
        .iter()
        .cloned()
        .map(|endpoint| (endpoint.bin_name.clone(), endpoint))
        .collect();
    let main_loop = runtime.loop_.clone();
    let pipeline_obj = runtime.pipeline.clone().upcast::<gst::Object>();
    let source_obj = runtime.source.clone().upcast::<gst::Object>();
    let lifecycle = runtime.lifecycle.clone();
    let processing_pending = runtime.processing_pending.clone();
    let route_playing = Arc::new(AtomicBool::new(false));

    bus.add_watch(move |_bus, msg| {
        use gst::MessageView;

        match msg.view() {
            MessageView::Error(error_message) => {
                let error = error_message.error();
                let endpoint = nearest_endpoint(msg.src(), &endpoint_by_bin);
                let classification = classify_error_message(
                    error_message,
                    endpoint.as_ref(),
                    route_playing.load(Ordering::Acquire),
                );
                let retry_domain = retry_domain(classification.retryable, endpoint.as_ref());
                let detail = error.to_string();

                if let Some(endpoint) = endpoint.as_ref() {
                    let _ = event_sink.emit_endpoint_health(
                        &endpoint.endpoint_id,
                        endpoint.direction,
                        endpoint.transport,
                        EndpointState::Failed,
                        Some(classification.code),
                        Some(classification.retryable),
                        Some(retry_domain),
                        Some(&detail),
                    );
                }
                let _ = event_sink.emit_route_terminal(
                    classification.code,
                    classification.retryable,
                    retry_domain,
                    Some(&detail),
                );
                eprintln!("Error: {error}");
                let _ = lifecycle.emit_failed(FailureReason::RuntimeError);
                main_loop.quit();
            }
            MessageView::Eos(..) => {
                if let Some(endpoint) = endpoint_by_bin.values().find(|endpoint| {
                    endpoint.direction == EndpointDirection::Source
                        && endpoint.transport == Transport::Ndi
                }) {
                    let code = ErrorCode::NdiSourceEos;
                    let detail = "NDI source reached end of stream";
                    let _ = event_sink.emit_endpoint_health(
                        &endpoint.endpoint_id,
                        endpoint.direction,
                        endpoint.transport,
                        EndpointState::Failed,
                        Some(code),
                        Some(true),
                        Some(RetryDomain::Route),
                        Some(detail),
                    );
                    let _ = event_sink.emit_route_terminal(
                        code,
                        true,
                        RetryDomain::Route,
                        Some(detail),
                    );
                    let _ = lifecycle.emit_failed(FailureReason::RuntimeError);
                } else {
                    eos_seen.store(true, Ordering::Relaxed);
                }
                main_loop.quit();
            }
            MessageView::StateChanged(state_changed) => {
                if msg.src().is_some_and(|source| *source == pipeline_obj)
                    && state_changed.current() == gst::State::Playing
                {
                    route_playing.store(true, Ordering::Release);
                }
                if state_changed.current() == gst::State::Playing
                    && message_source_is_factory(msg, "ndisink")
                {
                    if let Some(endpoint) = nearest_endpoint(msg.src(), &endpoint_by_bin) {
                        let _ = event_sink.emit_endpoint_health(
                            &endpoint.endpoint_id,
                            endpoint.direction,
                            endpoint.transport,
                            EndpointState::Advertising,
                            None,
                            None,
                            None,
                            None,
                        );
                    }
                }
            }
            MessageView::Element(element) => {
                if let Some(structure) = element.structure() {
                    let is_source_msg = msg.src().map(|src| *src == source_obj).unwrap_or(false);
                    if is_source_msg
                        && structure.name() == "connection-removed"
                        && lifecycle.emit_reconnecting().unwrap_or(false)
                    {
                        processing_pending.store(true, Ordering::Release);
                    }
                }
            }
            _ => {}
        }

        glib::ControlFlow::Continue
    })
    .context("failed to attach current bus watch")
}

fn classify_error_message(
    error_message: &gst::message::Error,
    endpoint: Option<&EndpointDescriptor>,
    route_playing: bool,
) -> ErrorClassification {
    if let Some(code) = classify_readiness_details(error_message.details()) {
        return ErrorClassification {
            code,
            retryable: true,
        };
    }
    if let Some(classification) = classify_ndi_sender_start_failure(endpoint, route_playing) {
        return classification;
    }
    classify_gst_error(&error_message.error())
}

fn classify_ndi_sender_start_failure(
    endpoint: Option<&EndpointDescriptor>,
    route_playing: bool,
) -> Option<ErrorClassification> {
    (!route_playing
        && endpoint.is_some_and(|endpoint| {
            endpoint.direction == EndpointDirection::Destination
                && endpoint.transport == Transport::Ndi
        }))
    .then_some(ErrorClassification {
        code: ErrorCode::NdiSenderStartFailed,
        retryable: true,
    })
}

fn message_source_is_factory(message: &gst::MessageRef, expected: &str) -> bool {
    message
        .src()
        .and_then(|source| source.downcast_ref::<gst::Element>())
        .and_then(gst::Element::factory)
        .is_some_and(|factory| factory.name() == expected)
}

fn nearest_endpoint(
    source: Option<&gst::Object>,
    endpoint_by_bin: &HashMap<String, EndpointDescriptor>,
) -> Option<EndpointDescriptor> {
    let mut current = source.cloned();
    while let Some(object) = current {
        let name = object.name();
        if (name.starts_with("dest_") || name.starts_with("source_"))
            && endpoint_by_bin.contains_key(name.as_str())
        {
            return endpoint_by_bin.get(name.as_str()).cloned();
        }
        current = object.parent();
    }
    None
}

fn retry_domain(retryable: bool, endpoint: Option<&EndpointDescriptor>) -> RetryDomain {
    if !retryable {
        RetryDomain::None
    } else if endpoint.is_some_and(|value| value.direction == EndpointDirection::Destination) {
        RetryDomain::Destination
    } else {
        RetryDomain::Route
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::adapters::ndi_source::{
        NDI_ERROR_DETAILS_NAME, NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON,
        NDI_REQUIRED_VIDEO_REASON,
    };

    #[test]
    fn typed_error_mapping_never_depends_on_message_text() {
        let cases = [
            (
                TypedGstError::Resource(gst::ResourceError::Read),
                ErrorCode::RuntimeError,
                true,
            ),
            (
                TypedGstError::Core(gst::CoreError::Negotiation),
                ErrorCode::NegotiationFailed,
                false,
            ),
            (
                TypedGstError::Core(gst::CoreError::MissingPlugin),
                ErrorCode::ElementMissing,
                false,
            ),
            (
                TypedGstError::Stream(gst::StreamError::Format),
                ErrorCode::NegotiationFailed,
                false,
            ),
            (TypedGstError::Other, ErrorCode::RuntimeError, true),
        ];

        for (input, code, retryable) in cases {
            assert_eq!(
                classify_typed_error(input),
                ErrorClassification { code, retryable }
            );
        }
    }

    #[test]
    fn ndi_source_resource_error_without_adapter_details_is_runtime_error() {
        assert_eq!(classify_readiness_details(None), None);
        assert_eq!(
            classify_typed_error(TypedGstError::Resource(gst::ResourceError::Read)),
            ErrorClassification {
                code: ErrorCode::RuntimeError,
                retryable: true,
            }
        );
    }

    #[test]
    fn ndi_source_receive_timeout_requires_adapter_details_discriminator() {
        let details = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
            .field(NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON)
            .build();
        assert_eq!(
            classify_readiness_details(Some(details.as_ref())),
            Some(ErrorCode::NdiReceiveTimeout)
        );

        let required_video = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
            .field(NDI_ERROR_REASON_FIELD, NDI_REQUIRED_VIDEO_REASON)
            .build();
        assert_eq!(
            classify_readiness_details(Some(required_video.as_ref())),
            Some(ErrorCode::NdiRequiredVideoMissing)
        );

        let unrelated = gst::Structure::builder("other-error").build();
        assert_eq!(classify_readiness_details(Some(unrelated.as_ref())), None);
    }

    #[test]
    fn retry_domain_tracks_attributed_endpoint_direction() {
        let source = EndpointDescriptor {
            bin_name: "source_a".to_string(),
            endpoint_id: "a".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Srt,
        };
        let destination = EndpointDescriptor {
            bin_name: "dest_b".to_string(),
            endpoint_id: "b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Udp,
        };
        assert_eq!(retry_domain(true, Some(&source)), RetryDomain::Route);
        assert_eq!(
            retry_domain(true, Some(&destination)),
            RetryDomain::Destination
        );
        assert_eq!(retry_domain(false, Some(&destination)), RetryDomain::None);
    }

    #[test]
    fn ndi_destination_failure_before_route_playing_is_sender_start_failure() {
        let endpoint = EndpointDescriptor {
            bin_name: "dest_0_ndi".to_string(),
            endpoint_id: "ndi-output".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Ndi,
        };
        assert_eq!(
            classify_ndi_sender_start_failure(Some(&endpoint), false),
            Some(ErrorClassification {
                code: ErrorCode::NdiSenderStartFailed,
                retryable: true,
            })
        );
        assert_eq!(
            retry_domain(true, Some(&endpoint)),
            RetryDomain::Destination
        );
        assert_eq!(
            classify_ndi_sender_start_failure(Some(&endpoint), true),
            None
        );
    }

    #[test]
    fn attribution_walks_from_message_source_to_nearest_endpoint_bin() {
        let _ = gst::init();
        let bin = gst::Bin::with_name("dest_sanitized_id");
        let child = gst::ElementFactory::make("identity")
            .build()
            .expect("identity element");
        bin.add(&child).expect("child in bin");
        let descriptor = EndpointDescriptor {
            bin_name: bin.name().to_string(),
            endpoint_id: "original-id".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let endpoints = HashMap::from([(descriptor.bin_name.clone(), descriptor.clone())]);

        assert_eq!(
            nearest_endpoint(Some(child.upcast_ref()), &endpoints),
            Some(descriptor)
        );
    }

    #[test]
    fn attribution_distinguishes_ids_with_the_same_sanitized_suffix() {
        let _ = gst::init();
        let first_bin = gst::Bin::with_name("dest_0_a_b");
        let second_bin = gst::Bin::with_name("dest_1_a_b");
        let first_child = gst::ElementFactory::make("identity")
            .build()
            .expect("first child");
        let second_child = gst::ElementFactory::make("identity")
            .build()
            .expect("second child");
        first_bin.add(&first_child).expect("first bin child");
        second_bin.add(&second_child).expect("second bin child");
        let first = EndpointDescriptor {
            bin_name: first_bin.name().to_string(),
            endpoint_id: "a-b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let second = EndpointDescriptor {
            bin_name: second_bin.name().to_string(),
            endpoint_id: "a_b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let endpoints = HashMap::from([
            (first.bin_name.clone(), first.clone()),
            (second.bin_name.clone(), second.clone()),
        ]);

        assert_eq!(
            nearest_endpoint(Some(first_child.upcast_ref()), &endpoints),
            Some(first)
        );
        assert_eq!(
            nearest_endpoint(Some(second_child.upcast_ref()), &endpoints),
            Some(second)
        );
    }
}
