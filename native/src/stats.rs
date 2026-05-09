use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use gio::prelude::InetSocketAddressExt;
use gio::{InetSocketAddress, SocketAddress};
use glib::object::Cast;
use glib::object::ObjectExt;
use gstreamer as gst;
use serde_json::{Map, Value};

use crate::output::StatsWriter;
use crate::runtime::PipelineRuntime;

pub fn start_stats_loop(runtime: &PipelineRuntime, writer: Arc<Mutex<Box<dyn StatsWriter>>>) {
    let source = runtime.source.clone();
    let running = runtime.running.clone();
    let source_bytes_total = runtime.source_bytes_total.clone();
    let source_bytes_last_interval = runtime.source_bytes_last_interval.clone();
    let source_bytes_per_sec = runtime.source_bytes_per_sec.clone();
    let dest_metrics = runtime.dest_metrics.clone();

    thread::spawn(move || {
        while running.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_secs(1));

            let current_total = source_bytes_total.load(Ordering::Relaxed);
            let last_total = source_bytes_last_interval.swap(current_total, Ordering::Relaxed);
            source_bytes_per_sec.store(current_total.saturating_sub(last_total), Ordering::Relaxed);

            let source_stats = stats_property(&source);

            let bytes_total = source_stats
                .as_ref()
                .and_then(|stats| stats.get::<u64>("bytes-received-total").ok())
                .unwrap_or(current_total);

            let mut root = Map::new();
            root.insert(
                "total-bytes-received".into(),
                Value::Number(bytes_total.into()),
            );

            let callers = source_stats
                .as_ref()
                .and_then(extract_callers_from_stats)
                .unwrap_or_default();
            root.insert(
                "connected-callers".into(),
                Value::Number((callers.len() as u64).into()),
            );
            root.insert("callers".into(), Value::Array(callers));

            let mut source_obj = Map::new();
            source_obj.insert(
                "type".into(),
                Value::String(source.type_().name().to_string()),
            );
            source_obj.insert("bytes_in_total".into(), Value::Number(current_total.into()));
            source_obj.insert(
                "bytes_in_per_sec".into(),
                Value::Number(source_bytes_per_sec.load(Ordering::Relaxed).into()),
            );
            if let Some(stats) = source_stats.as_ref() {
                source_obj.insert("srt".into(), structure_to_json(stats));
            }
            root.insert("source".into(), Value::Object(source_obj));

            let mut dests_json = Vec::new();
            if let Ok(guard) = dest_metrics.lock() {
                for dest in guard.iter() {
                    let total = dest.bytes_total.load(Ordering::Relaxed);
                    let last = dest.bytes_last_interval.swap(total, Ordering::Relaxed);
                    dest.bytes_per_sec
                        .store(total.saturating_sub(last), Ordering::Relaxed);

                    let mut dest_obj = Map::new();
                    if let Some(id) = &dest.id {
                        dest_obj.insert("id".into(), Value::String(id.clone()));
                    }
                    if let Some(name) = &dest.name {
                        dest_obj.insert("name".into(), Value::String(name.clone()));
                    }
                    if let Some(schema) = &dest.schema {
                        dest_obj.insert("schema".into(), Value::String(schema.clone()));
                    }
                    dest_obj.insert("type".into(), Value::String(dest.kind.clone()));
                    dest_obj.insert("bytes_out_total".into(), Value::Number(total.into()));
                    dest_obj.insert(
                        "bytes_out_per_sec".into(),
                        Value::Number(dest.bytes_per_sec.load(Ordering::Relaxed).into()),
                    );

                    if let Some(sink_element) = dest.sink_element.as_ref() {
                        let sink_stats = stats_property(sink_element);
                        if let Some(sink_stats) = sink_stats.as_ref() {
                            dest_obj.insert("srt".into(), structure_to_json(sink_stats));
                        }
                    }

                    dests_json.push(Value::Object(dest_obj));
                }
            }
            root.insert("destinations".into(), Value::Array(dests_json));

            if let Ok(mut guard) = writer.lock() {
                let _ = guard.send_message(&Value::Object(root).to_string());
            }
        }
    });
}

fn stats_property(element: &gst::Element) -> Option<gst::Structure> {
    if element.has_property("stats", None) {
        element.property::<Option<gst::Structure>>("stats")
    } else {
        None
    }
}

fn extract_callers_from_stats(stats: &gst::Structure) -> Option<Vec<Value>> {
    let callers = stats.value("callers").ok()?;
    let array = callers.get::<glib::ValueArray>().ok()?;
    let mut out = Vec::new();

    for caller in array.iter() {
        if let Ok(structure) = caller.get::<gst::Structure>() {
            out.push(structure_to_json(&structure));
        }
    }

    Some(out)
}

fn structure_to_json(structure: &gst::Structure) -> Value {
    let mut obj = Map::new();

    for (field_name, value) in structure.iter() {
        if let Ok(v) = value.get::<bool>() {
            obj.insert(field_name.to_string(), Value::Bool(v));
            continue;
        }
        if let Ok(v) = value.get::<i32>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<u32>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<i64>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<u64>() {
            obj.insert(field_name.to_string(), Value::Number(v.into()));
            continue;
        }
        if let Ok(v) = value.get::<f64>() {
            if let Some(num) = serde_json::Number::from_f64(v) {
                obj.insert(field_name.to_string(), Value::Number(num));
            }
            continue;
        }
        if field_name == "caller-address" {
            if let Ok(address) = value.get::<SocketAddress>() {
                if let Ok(inet) = address.downcast::<InetSocketAddress>() {
                    let ip = inet.address().to_string();
                    let port = inet.port();
                    obj.insert(
                        field_name.to_string(),
                        Value::String(format!("{ip}:{port}")),
                    );
                }
            }
            continue;
        }
    }

    Value::Object(obj)
}
