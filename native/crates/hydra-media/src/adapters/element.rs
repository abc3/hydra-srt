use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::ErrorCode;

/// Shared element factory helper used by all adapters.
pub(crate) fn make_element(factory: &str, role: &str) -> Result<gst::Element, (ErrorCode, String)> {
    gst::ElementFactory::make(factory).build().map_err(|error| {
        (
            ErrorCode::ElementMissing,
            format!("failed to create {role} from factory {factory}: {error}"),
        )
    })
}

/// Shared named element factory helper (RTMP remux stable names).
pub(crate) fn make_named_element(
    factory: &str,
    name: &str,
    role: &str,
) -> Result<gst::Element, (ErrorCode, String)> {
    gst::ElementFactory::make(factory)
        .name(name)
        .build()
        .map_err(|error| {
            (
                ErrorCode::ElementMissing,
                format!("failed to create {role} from factory {factory}: {error}"),
            )
        })
}

/// Applies a config-derived property.
///
/// `glib::ObjectExt::set_property` aborts the process when the property does not
/// exist or the value cannot be converted, so every config-derived property goes
/// through this guard and fails closed with a classified error instead.
pub(crate) fn set_property(
    element: &gst::Element,
    name: &str,
    value: impl ToValue,
) -> Result<(), (ErrorCode, String)> {
    let value = value.to_value();
    let supplied = value.type_();
    let Some(property) = element.find_property(name) else {
        return Err((
            ErrorCode::ConfigInvalid,
            format!("{} has no property {name}", element_name(element)),
        ));
    };

    let target = property.value_type();
    let value = if supplied == target {
        value
    } else {
        value.transform_with_type(target).map_err(|_| {
            (
                ErrorCode::ConfigInvalid,
                format!(
                    "{} property {name} expects {target} but the config supplies {supplied}",
                    element_name(element)
                ),
            )
        })?
    };

    element.set_property_from_value(name, &value);
    Ok(())
}

fn element_name(element: &gst::Element) -> String {
    element
        .factory()
        .map_or_else(|| element.type_().name().to_owned(), |f| f.name().into())
}

pub(crate) fn runtime_detail(error: impl std::fmt::Display) -> (ErrorCode, String) {
    (ErrorCode::RuntimeError, error.to_string())
}

pub(crate) fn link_detail(error: impl std::fmt::Display) -> (ErrorCode, String) {
    (ErrorCode::LinkFailed, error.to_string())
}
