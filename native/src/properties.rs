use std::collections::BTreeMap;

use anyhow::Result;
use glib::prelude::StaticType;
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use serde_json::Value;

use crate::config::ElementConfig;

pub fn apply_element_properties(element: &gst::Element, config: &ElementConfig) -> Result<()> {
    if (config.element_type == "srtsrc" || config.element_type == "srtsink")
        && !config.props.contains_key("uri")
    {
        if let Some(uri) = build_srt_uri(&config.props) {
            element.set_property("uri", uri.as_str());
        }
    }

    for (key, value) in &config.props {
        if key == "type" || !element.has_property(key.as_str(), None) {
            continue;
        }

        let Some(prop) = element.find_property(key.as_str()) else {
            continue;
        };

        if (config.element_type == "srtsrc" || config.element_type == "srtsink") && key == "mode" {
            continue;
        }

        if config.element_type == "udpsink" && key == "address" {
            if let Some(host) = value.as_str() {
                element.set_property("host", host);
            }
            continue;
        }

        match value {
            Value::Bool(v) => element.set_property(key.as_str(), *v),
            Value::Number(v) => {
                let value_type = prop.value_type();

                if value_type == u32::static_type() {
                    if let Some(uv) = v.as_u64().and_then(|n| u32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    } else if let Some(iv) = v.as_i64().and_then(|n| u32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    }
                } else if value_type == u64::static_type() {
                    if let Some(uv) = v.as_u64() {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    } else if let Some(iv) = v.as_i64().and_then(|n| u64::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    }
                } else if value_type.is_a(glib::Type::ENUM) {
                    let enum_value = v
                        .as_i64()
                        .and_then(|n| i32::try_from(n).ok())
                        .or_else(|| v.as_u64().and_then(|n| i32::try_from(n).ok()));

                    if let (Some(iv), Some(enum_class)) =
                        (enum_value, glib::EnumClass::with_type(value_type))
                    {
                        if let Some(enum_value) = enum_class.to_value(iv) {
                            element.set_property_from_value(key.as_str(), &enum_value);
                        }
                    }
                } else if value_type == i32::static_type() {
                    if let Some(iv) = v.as_i64().and_then(|n| i32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    } else if let Some(uv) = v.as_u64().and_then(|n| i32::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    }
                } else if value_type == i64::static_type() {
                    if let Some(iv) = v.as_i64() {
                        element.set_property_from_value(key.as_str(), &iv.to_value());
                    } else if let Some(uv) = v.as_u64().and_then(|n| i64::try_from(n).ok()) {
                        element.set_property_from_value(key.as_str(), &uv.to_value());
                    }
                } else if value_type == f32::static_type() {
                    if let Some(fv) = v.as_f64() {
                        element.set_property_from_value(key.as_str(), &(fv as f32).to_value());
                    }
                } else if value_type == f64::static_type() {
                    if let Some(fv) = v.as_f64() {
                        element.set_property_from_value(key.as_str(), &fv.to_value());
                    }
                } else if let Some(iv) = v.as_i64().and_then(|n| i32::try_from(n).ok()) {
                    element.set_property_from_value(key.as_str(), &iv.to_value());
                }
            }
            Value::String(v) => element.set_property(key.as_str(), v.as_str()),
            _ => {}
        }
    }

    Ok(())
}

pub fn build_srt_uri(props: &BTreeMap<String, Value>) -> Option<String> {
    let mode = props
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("listener");

    let (host, port) = match mode {
        "caller" | "rendezvous" => {
            let host = props
                .get("address")
                .or_else(|| props.get("host"))
                .or_else(|| props.get("localaddress"))
                .and_then(Value::as_str)
                .unwrap_or("127.0.0.1");

            let port = props
                .get("port")
                .or_else(|| props.get("localport"))
                .and_then(Value::as_u64)?;

            (host, port)
        }
        _ => {
            let host = props
                .get("localaddress")
                .or_else(|| props.get("address"))
                .or_else(|| props.get("host"))
                .and_then(Value::as_str)
                .unwrap_or("127.0.0.1");

            let port = props
                .get("localport")
                .or_else(|| props.get("port"))
                .and_then(Value::as_u64)?;

            (host, port)
        }
    };

    let mut query = Vec::new();
    for key in ["mode"] {
        if let Some(value) = props.get(key) {
            match value {
                Value::String(s) if !s.is_empty() => query.push(format!("{key}={s}")),
                Value::Number(n) => query.push(format!("{key}={n}")),
                Value::Bool(b) => query.push(format!("{key}={b}")),
                _ => {}
            }
        }
    }

    let query = if query.is_empty() {
        String::new()
    } else {
        format!("?{}", query.join("&"))
    };

    Some(format!("srt://{host}:{port}{query}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ElementConfig;

    fn init_gst() {
        let _ = gst::init();
    }

    #[test]
    fn applies_pbkeylen_as_enum_property() {
        init_gst();

        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");

        let config = ElementConfig {
            element_type: "srtsrc".to_string(),
            props: BTreeMap::from([
                (
                    "localaddress".to_string(),
                    Value::String("127.0.0.1".to_string()),
                ),
                ("localport".to_string(), Value::Number(4201_u64.into())),
                ("mode".to_string(), Value::String("listener".to_string())),
                ("pbkeylen".to_string(), Value::Number(16_u64.into())),
            ]),
        };

        apply_element_properties(&element, &config).expect("setting srtsrc properties should work");

        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");

        assert_eq!(enum_value.value(), 16);
    }

    #[test]
    fn applies_pbkeylen_as_enum_property_for_srtsink() {
        init_gst();

        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");

        let config = ElementConfig {
            element_type: "srtsink".to_string(),
            props: BTreeMap::from([
                (
                    "localaddress".to_string(),
                    Value::String("127.0.0.1".to_string()),
                ),
                ("localport".to_string(), Value::Number(4201_u64.into())),
                ("mode".to_string(), Value::String("caller".to_string())),
                ("pbkeylen".to_string(), Value::Number(16_u64.into())),
            ]),
        };

        apply_element_properties(&element, &config)
            .expect("setting srtsink properties should work");

        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");

        assert_eq!(enum_value.value(), 16);
    }

    #[test]
    fn build_srt_uri_only_embeds_transport_fields() {
        let props = BTreeMap::from([
            (
                "localaddress".to_string(),
                Value::String("127.0.0.1".to_string()),
            ),
            ("localport".to_string(), Value::Number(4201_u64.into())),
            ("mode".to_string(), Value::String("listener".to_string())),
            (
                "passphrase".to_string(),
                Value::String("secret".to_string()),
            ),
            ("pbkeylen".to_string(), Value::Number(16_u64.into())),
            ("poll-timeout".to_string(), Value::Number(1000_u64.into())),
        ]);

        let uri = build_srt_uri(&props).expect("uri should be built");

        assert_eq!(uri, "srt://127.0.0.1:4201?mode=listener");
    }
}
