use std::collections::{HashMap, HashSet};
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
    let srt_callers = runtime.srt_callers.clone();

    thread::spawn(move || {
        let mut source_srt_previous = None;
        let mut destination_srt_previous: HashMap<String, HashMap<String, u64>> = HashMap::new();
        let mut caller_srt_previous: HashMap<String, HashMap<String, u64>> = HashMap::new();

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
            let callers = enrich_callers(callers, srt_callers.as_ref(), &mut caller_srt_previous);
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
                let mut srt = endpoint_stats_json(stats);
                add_interval_metrics(&mut srt, SrtDirection::Receive, &mut source_srt_previous);
                source_obj.insert("srt".into(), srt);
            } else {
                source_srt_previous = None;
            }
            root.insert("source".into(), Value::Object(source_obj));

            let mut dests_json = Vec::new();
            if let Ok(guard) = dest_metrics.lock() {
                let current_destination_keys = guard
                    .iter()
                    .map(|dest| destination_srt_key(dest.id.as_ref(), &dest.kind))
                    .collect::<HashSet<_>>();
                prune_destination_srt_previous(
                    &mut destination_srt_previous,
                    &current_destination_keys,
                );

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
                    dest_obj.insert(
                        "drops".into(),
                        Value::Number(dest.drops.load(Ordering::Relaxed).into()),
                    );

                    let destination_key = destination_srt_key(dest.id.as_ref(), &dest.kind);
                    if let Some(sink_element) = dest.sink_element.as_ref() {
                        let sink_stats = stats_property(sink_element);
                        if let Some(sink_stats) = sink_stats.as_ref() {
                            let mut srt = endpoint_stats_json(sink_stats);
                            let mut previous = destination_srt_previous.remove(&destination_key);
                            add_interval_metrics(&mut srt, SrtDirection::Send, &mut previous);
                            if let Some(previous) = previous {
                                destination_srt_previous.insert(destination_key, previous);
                            }
                            dest_obj.insert("srt".into(), srt);
                        } else {
                            destination_srt_previous.remove(&destination_key);
                        }
                    } else {
                        destination_srt_previous.remove(&destination_key);
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

fn destination_srt_key(id: Option<&String>, kind: &str) -> String {
    id.cloned().unwrap_or_else(|| kind.to_string())
}

fn prune_destination_srt_previous(
    previous: &mut HashMap<String, HashMap<String, u64>>,
    current_keys: &HashSet<String>,
) {
    previous.retain(|key, _| current_keys.contains(key));
}

fn endpoint_stats_json(stats: &gst::Structure) -> Value {
    let direct = structure_to_json(stats);
    if direct
        .as_object()
        .is_some_and(|stats| stats.contains_key("rtt-ms"))
    {
        return direct;
    }

    let callers = extract_callers_from_stats(stats).unwrap_or_default();
    match callers.as_slice() {
        [] => direct,
        [caller] => caller.clone(),
        _ => aggregate_caller_stats(&callers),
    }
}

fn aggregate_caller_stats(callers: &[Value]) -> Value {
    const SUM_FIELDS: [&str; 17] = [
        "packets-sent",
        "packets-sent-lost",
        "packets-retransmitted",
        "packet-ack-received",
        "packet-nack-received",
        "send-duration-us",
        "bytes-sent",
        "bytes-retransmitted",
        "bytes-sent-dropped",
        "packets-sent-dropped",
        "packets-received",
        "packets-received-lost",
        "packets-received-retransmitted",
        "packets-received-dropped",
        "packet-ack-sent",
        "packet-nack-sent",
        "bytes-received",
    ];
    const SUM_DOUBLE_FIELDS: [&str; 2] = ["send-rate-mbps", "receive-rate-mbps"];
    const MAX_FIELDS: [&str; 2] = ["rtt-ms", "negotiated-latency-ms"];

    let mut aggregated = Map::new();

    for field in SUM_FIELDS {
        let values = callers
            .iter()
            .filter_map(|caller| caller.get(field))
            .filter_map(Value::as_u64)
            .collect::<Vec<_>>();
        if !values.is_empty() {
            aggregated.insert(
                field.into(),
                Value::Number(values.iter().sum::<u64>().into()),
            );
        }
    }

    for field in SUM_DOUBLE_FIELDS {
        let values = callers
            .iter()
            .filter_map(|caller| caller.get(field))
            .filter_map(Value::as_f64)
            .collect::<Vec<_>>();
        if !values.is_empty() {
            if let Some(number) = serde_json::Number::from_f64(values.iter().sum()) {
                aggregated.insert(field.into(), Value::Number(number));
            }
        }
    }

    for field in MAX_FIELDS {
        let value = callers
            .iter()
            .filter_map(|caller| caller.get(field))
            .filter_map(Value::as_f64)
            .reduce(f64::max);
        if let Some(number) = value.and_then(serde_json::Number::from_f64) {
            aggregated.insert(field.into(), Value::Number(number));
        }
    }

    let bandwidth = callers
        .iter()
        .filter_map(|caller| caller.get("bandwidth-mbps"))
        .filter_map(Value::as_f64)
        .reduce(f64::min);
    if let Some(number) = bandwidth.and_then(serde_json::Number::from_f64) {
        aggregated.insert("bandwidth-mbps".into(), Value::Number(number));
    }

    Value::Object(aggregated)
}

#[derive(Clone, Copy)]
enum SrtDirection {
    Receive,
    Send,
}

fn counters_regressed(current: &HashMap<String, u64>, previous: &HashMap<String, u64>) -> bool {
    current.iter().any(|(key, current_value)| {
        previous
            .get(key)
            .is_some_and(|previous_value| current_value < previous_value)
    })
}

fn counter_delta(
    current: &HashMap<String, u64>,
    previous: &HashMap<String, u64>,
    key: &str,
) -> Option<u64> {
    let current = *current.get(key)?;
    let previous = *previous.get(key)?;
    if current < previous {
        None
    } else {
        Some(current - previous)
    }
}

fn add_interval_metrics(
    stats: &mut Value,
    direction: SrtDirection,
    previous: &mut Option<HashMap<String, u64>>,
) {
    let Some(stats_obj) = stats.as_object_mut() else {
        *previous = None;
        return;
    };

    let (received_key, lost_key, retransmitted_key, dropped_key, nack_key) = match direction {
        SrtDirection::Receive => (
            "packets-received",
            "packets-received-lost",
            "packets-received-retransmitted",
            "packets-received-dropped",
            "packet-nack-sent",
        ),
        SrtDirection::Send => (
            "packets-sent",
            "packets-sent-lost",
            "packets-retransmitted",
            "packets-sent-dropped",
            "packet-nack-received",
        ),
    };

    let tracked_keys = [
        received_key,
        lost_key,
        retransmitted_key,
        dropped_key,
        nack_key,
    ];

    let current: HashMap<String, u64> = tracked_keys
        .iter()
        .filter_map(|key| {
            stats_obj
                .get(*key)
                .and_then(Value::as_u64)
                .map(|value| ((*key).to_string(), value))
        })
        .collect();

    let interval_reset = previous
        .as_ref()
        .is_some_and(|previous_values| counters_regressed(&current, previous_values));

    let interval_values = if interval_reset {
        None
    } else {
        previous.as_ref().map(|previous_values| {
            let loss_percent = counter_delta(&current, previous_values, received_key)
                .zip(counter_delta(&current, previous_values, lost_key))
                .and_then(|(total, lost)| {
                    let denominator = match direction {
                        SrtDirection::Receive => total + lost,
                        SrtDirection::Send => total,
                    };
                    (denominator > 0).then_some((lost as f64 / denominator as f64) * 100.0)
                });
            let retransmitted = counter_delta(&current, previous_values, retransmitted_key)
                .map(|value| value as f64);
            let dropped =
                counter_delta(&current, previous_values, dropped_key).map(|value| value as f64);
            let nack = counter_delta(&current, previous_values, nack_key).map(|value| value as f64);
            [loss_percent, retransmitted, dropped, nack]
        })
    };

    for (index, metric_name) in [
        "packet-loss-percent",
        "retransmitted-packets-per-sec",
        "dropped-packets-per-sec",
        "nack-packets-per-sec",
    ]
    .iter()
    .enumerate()
    {
        let value = interval_values
            .as_ref()
            .and_then(|values| values[index])
            .and_then(serde_json::Number::from_f64)
            .map(Value::Number)
            .unwrap_or(Value::Null);
        stats_obj.insert((*metric_name).to_string(), value);
    }

    *previous = (!current.is_empty()).then_some(current);
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

fn enrich_callers(
    mut callers: Vec<Value>,
    registry: Option<&Arc<crate::adapters::srt::SrtCallerRegistry>>,
    previous: &mut HashMap<String, HashMap<String, u64>>,
) -> Vec<Value> {
    let mut current_addresses = HashSet::new();
    for caller in &mut callers {
        let Some(object) = caller.as_object_mut() else {
            continue;
        };
        object.remove("stream-id");
        let Some(address) = object
            .get("caller-address")
            .and_then(Value::as_str)
            .map(str::to_owned)
        else {
            continue;
        };
        current_addresses.insert(address.clone());
        if let Some(registry) = registry {
            if let Some(stream_id) = registry.stream_id(&address) {
                object.insert("stream-id".into(), Value::String(stream_id));
            }
        }
        let mut caller_previous = previous.remove(&address);
        add_interval_metrics(caller, SrtDirection::Receive, &mut caller_previous);
        if let Some(caller_previous) = caller_previous {
            previous.insert(address, caller_previous);
        }
    }
    previous.retain(|address, _| current_addresses.contains(address));
    callers
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

#[cfg(test)]
mod tests {
    use super::{
        add_interval_metrics, aggregate_caller_stats, enrich_callers,
        prune_destination_srt_previous, SrtDirection,
    };
    use crate::adapters::srt::SrtCallerRegistry;
    use serde_json::json;
    use std::collections::{HashMap, HashSet};

    #[test]
    fn receive_interval_metrics_use_partial_srtsrc_counters() {
        let mut previous = None;
        let mut first = json!({
            "packets-received": 100,
            "packets-received-lost": 10,
            "packet-nack-sent": 3
        });
        add_interval_metrics(&mut first, SrtDirection::Receive, &mut previous);
        assert!(first["packet-loss-percent"].is_null());

        let mut second = json!({
            "packets-received": 190,
            "packets-received-lost": 20,
            "packet-nack-sent": 7
        });
        add_interval_metrics(&mut second, SrtDirection::Receive, &mut previous);
        assert_eq!(second["packet-loss-percent"], json!(10.0));
        assert_eq!(second["nack-packets-per-sec"], json!(4.0));
        assert!(second["retransmitted-packets-per-sec"].is_null());
        assert!(second["dropped-packets-per-sec"].is_null());
    }

    #[test]
    fn receive_interval_metrics_are_null_then_derived() {
        let mut previous = None;
        let mut first = json!({
            "packets-received": 100,
            "packets-received-lost": 10,
            "packets-received-retransmitted": 4,
            "packets-received-dropped": 2,
            "packet-nack-sent": 3
        });
        add_interval_metrics(&mut first, SrtDirection::Receive, &mut previous);
        assert!(first["packet-loss-percent"].is_null());

        let mut second = json!({
            "packets-received": 190,
            "packets-received-lost": 20,
            "packets-received-retransmitted": 9,
            "packets-received-dropped": 3,
            "packet-nack-sent": 7
        });
        add_interval_metrics(&mut second, SrtDirection::Receive, &mut previous);
        assert_eq!(second["packet-loss-percent"], json!(10.0));
        assert_eq!(second["retransmitted-packets-per-sec"], json!(5.0));
        assert_eq!(second["dropped-packets-per-sec"], json!(1.0));
        assert_eq!(second["nack-packets-per-sec"], json!(4.0));
    }

    #[test]
    fn counter_reset_produces_null_interval_metrics() {
        let mut previous = None;
        let mut first = json!({
            "packets-sent": 100,
            "packets-sent-lost": 10,
            "packets-retransmitted": 4,
            "packets-sent-dropped": 2,
            "packet-nack-received": 3
        });
        add_interval_metrics(&mut first, SrtDirection::Send, &mut previous);

        let mut reset = json!({
            "packets-sent": 1,
            "packets-sent-lost": 0,
            "packets-retransmitted": 0,
            "packets-sent-dropped": 0,
            "packet-nack-received": 0
        });
        add_interval_metrics(&mut reset, SrtDirection::Send, &mut previous);
        assert!(reset["packet-loss-percent"].is_null());
        assert!(reset["retransmitted-packets-per-sec"].is_null());
    }

    #[test]
    fn caller_stats_are_aggregated_for_listener_endpoints() {
        let callers = vec![
            json!({
                "packets-sent": 100,
                "packets-sent-lost": 3,
                "send-rate-mbps": 1.2,
                "bandwidth-mbps": 8.0,
                "rtt-ms": 15.0
            }),
            json!({
                "packets-sent": 200,
                "packets-sent-lost": 5,
                "send-rate-mbps": 1.3,
                "bandwidth-mbps": 6.0,
                "rtt-ms": 25.0
            }),
        ];

        let aggregated = aggregate_caller_stats(&callers);
        assert_eq!(aggregated["packets-sent"], json!(300));
        assert_eq!(aggregated["packets-sent-lost"], json!(8));
        assert_eq!(aggregated["send-rate-mbps"], json!(2.5));
        assert_eq!(aggregated["bandwidth-mbps"], json!(6.0));
        assert_eq!(aggregated["rtt-ms"], json!(25.0));
    }

    #[test]
    fn destination_previous_state_is_pruned_to_current_destinations() {
        let mut previous = HashMap::from([
            (
                "dest-1".to_string(),
                HashMap::from([("packets-sent".to_string(), 10)]),
            ),
            (
                "removed".to_string(),
                HashMap::from([("packets-sent".to_string(), 20)]),
            ),
        ]);
        let current_keys = HashSet::from(["dest-1".to_string()]);

        prune_destination_srt_previous(&mut previous, &current_keys);

        assert!(previous.contains_key("dest-1"));
        assert!(!previous.contains_key("removed"));
    }

    #[test]
    fn caller_interval_metrics_are_independent_and_stream_ids_are_enriched() {
        let registry = std::sync::Arc::new(SrtCallerRegistry::new());
        let first_ip = "192.0.2.1".parse().expect("valid IP");
        let second_ip = "192.0.2.2".parse().expect("valid IP");
        registry.mark_active(
            "192.0.2.1:4000".to_string(),
            first_ip,
            4000,
            Some("studio-a".to_string()),
        );
        registry.mark_active(
            "192.0.2.2:4001".to_string(),
            second_ip,
            4001,
            Some("studio-b".to_string()),
        );
        let mut previous = HashMap::new();
        let first = enrich_callers(
            vec![
                json!({"caller-address":"192.0.2.1:4000","packets-received":100,"packets-received-lost":10}),
                json!({"caller-address":"192.0.2.2:4001","packets-received":200,"packets-received-lost":20}),
            ],
            Some(&registry),
            &mut previous,
        );
        assert!(first[0]["packet-loss-percent"].is_null());
        assert!(first[1]["packet-loss-percent"].is_null());
        assert_eq!(first[0]["stream-id"], json!("studio-a"));
        assert_eq!(first[1]["stream-id"], json!("studio-b"));

        let second = enrich_callers(
            vec![
                json!({"caller-address":"192.0.2.1:4000","packets-received":190,"packets-received-lost":20}),
                json!({"caller-address":"192.0.2.2:4001","packets-received":290,"packets-received-lost":30}),
            ],
            Some(&registry),
            &mut previous,
        );
        assert_eq!(second[0]["packet-loss-percent"], json!(10.0));
        assert_eq!(second[1]["packet-loss-percent"], json!(10.0));
    }

    #[test]
    fn caller_previous_state_is_pruned_when_an_address_disappears() {
        let registry = std::sync::Arc::new(SrtCallerRegistry::new());
        let first_ip = "192.0.2.1".parse().expect("valid IP");
        let second_ip = "192.0.2.2".parse().expect("valid IP");
        registry.mark_active("192.0.2.1:4000".to_string(), first_ip, 4000, None);
        registry.mark_active("192.0.2.2:4001".to_string(), second_ip, 4001, None);
        let mut previous = HashMap::new();
        enrich_callers(
            vec![
                json!({"caller-address":"192.0.2.1:4000","packets-received":100}),
                json!({"caller-address":"192.0.2.2:4001","packets-received":100}),
            ],
            Some(&registry),
            &mut previous,
        );
        enrich_callers(
            vec![json!({"caller-address":"192.0.2.1:4000","packets-received":110})],
            Some(&registry),
            &mut previous,
        );
        assert!(!previous.contains_key("192.0.2.2:4001"));
        let returning = enrich_callers(
            vec![json!({"caller-address":"192.0.2.2:4001","packets-received":10})],
            Some(&registry),
            &mut previous,
        );
        assert!(returning[0]["retransmitted-packets-per-sec"].is_null());
        assert!(returning[0]["packet-loss-percent"].is_null());
    }
}
