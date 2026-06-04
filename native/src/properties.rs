use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use glib::prelude::StaticType;
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use serde_json::json;
use serde_json::Value;

use crate::config::ElementConfig;
use crate::output::StatsWriter;

pub fn apply_element_properties_with_logging(
    element: &gst::Element,
    config: &ElementConfig,
    writer: Option<&Arc<Mutex<Box<dyn StatsWriter>>>>,
) -> Result<()> {
    if (config.element_type == "srtsrc" || config.element_type == "srtsink")
        && !config.props.contains_key("uri")
    {
        if let Some(uri) = build_srt_uri(&config.props) {
            element.set_property("uri", uri.as_str());
        }
    }

    for (key, value) in &config.props {
        if config.element_type == "udpsink" && key == "address" {
            if let Some(host) = value.as_str() {
                element.set_property("host", host);
            }
            continue;
        }

        if key == "type" || !element.has_property(key.as_str(), None) {
            if key != "type" {
                emit_unsupported_property_warning(writer, &config.element_type, key);
            }
            continue;
        }

        let Some(prop) = element.find_property(key.as_str()) else {
            continue;
        };

        if (config.element_type == "srtsrc" || config.element_type == "srtsink") && key == "mode" {
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

fn emit_unsupported_property_warning(
    writer: Option<&Arc<Mutex<Box<dyn StatsWriter>>>>,
    element_type: &str,
    key: &str,
) {
    let Some(writer) = writer else {
        return;
    };

    let payload = json!({
        "event": "pipeline_log",
        "level": "WARN",
        "category": "native_config",
        "element": element_type,
        "file": "native/src/properties.rs",
        "function": "apply_element_properties",
        "message": format!("ignored unsupported property {key} on {element_type}"),
    })
    .to_string();

    if let Ok(mut guard) = writer.lock() {
        let _ = guard.send_message(&payload);
    }
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
    use crate::output::StatsWriter;
    use std::sync::{Arc, Mutex};

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

        apply_element_properties_with_logging(&element, &config, None)
            .expect("setting srtsrc properties should work");

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

        apply_element_properties_with_logging(&element, &config, None)
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

    #[test]
    fn emits_pipeline_log_for_unsupported_property() {
        init_gst();

        #[derive(Debug, Default)]
        struct MemoryWriter {
            messages: Arc<Mutex<Vec<String>>>,
        }

        impl StatsWriter for MemoryWriter {
            fn send_message(&mut self, message: &str) -> Result<()> {
                self.messages
                    .lock()
                    .expect("messages lock")
                    .push(message.to_string());
                Ok(())
            }
        }

        let element = gst::ElementFactory::make("fakesrc")
            .build()
            .expect("fakesrc element should be available for tests");
        let config = ElementConfig {
            element_type: "fakesrc".to_string(),
            props: BTreeMap::from([(
                "definitely-not-a-property".to_string(),
                Value::String("ignored".to_string()),
            )]),
        };
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));

        apply_element_properties_with_logging(&element, &config, Some(&writer))
            .expect("property application should not fail");

        let messages = messages.lock().expect("messages lock");
        assert_eq!(messages.len(), 1);

        let payload: Value = serde_json::from_str(&messages[0]).expect("warning should be JSON");
        assert_eq!(payload["event"], "pipeline_log");
        assert_eq!(payload["level"], "WARN");
        assert_eq!(payload["category"], "native_config");
        assert_eq!(payload["element"], "fakesrc");
        assert_eq!(
            payload["message"],
            "ignored unsupported property definitely-not-a-property on fakesrc"
        );
    }
}
