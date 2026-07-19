use std::io::{self, BufRead};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::ErrorCode;
use serde::Serialize;

use crate::output::{send_json_line, StatsWriter};

const MAX_DEVICES: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct NdiDevice {
    display_name: String,
    device_class: String,
    caps: String,
    properties: String,
}

#[derive(Serialize)]
struct SnapshotEvent<'a> {
    event: &'static str,
    helper_instance_id: &'a str,
    devices: Vec<NdiDevice>,
    truncated: bool,
}

#[derive(Serialize)]
struct DeviceEvent<'a> {
    event: &'static str,
    helper_instance_id: &'a str,
    device: NdiDevice,
}

#[derive(Serialize)]
struct CapabilityEvent<'a> {
    event: &'static str,
    helper_instance_id: &'a str,
    ok: bool,
    reason_code: ErrorCode,
}

pub(crate) fn sanitize_device_string(input: &str) -> String {
    let mut output = String::new();
    for character in input.chars().filter(|character| !character.is_control()) {
        if output.len() + character.len_utf8() > 256 {
            break;
        }
        output.push(character);
    }
    output
}

pub(crate) fn device_from_gst(device: &gst::Device) -> NdiDevice {
    NdiDevice {
        display_name: sanitize_device_string(&device.display_name()),
        device_class: sanitize_device_string(&device.device_class()),
        caps: sanitize_device_string(
            &device
                .caps()
                .map(|caps| caps.to_string())
                .unwrap_or_default(),
        ),
        properties: sanitize_device_string(
            &device
                .properties()
                .map(|properties| properties.to_string())
                .unwrap_or_default(),
        ),
    }
}

pub(crate) fn emit_capability_missing(
    writer: &mut dyn StatsWriter,
    helper_instance_id: &str,
) -> Result<()> {
    emit_capability_unavailable(writer, helper_instance_id, ErrorCode::NdiPluginMissing)
}

fn emit_capability_unavailable(
    writer: &mut dyn StatsWriter,
    helper_instance_id: &str,
    reason_code: ErrorCode,
) -> Result<()> {
    send_json_line(
        writer,
        &CapabilityEvent {
            event: "ndi_capability",
            helper_instance_id,
            ok: false,
            reason_code,
        },
    )
}

pub fn run(writer: Arc<Mutex<Box<dyn StatsWriter>>>, helper_instance_id: &str) -> Result<()> {
    if gst::ElementFactory::find("ndisrc").is_none() {
        let mut writer = writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?;
        return emit_capability_missing(writer.as_mut(), helper_instance_id);
    }

    let monitor = gst::DeviceMonitor::new();
    let caps = gst::Caps::builder("application/x-ndi").build();
    monitor
        .add_filter(Some("Source/Network"), Some(&caps))
        .ok_or_else(|| anyhow!("failed to add NDI device monitor filter"))?;
    if monitor.start().is_err() {
        let mut writer = writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?;
        return emit_capability_unavailable(
            writer.as_mut(),
            helper_instance_id,
            ErrorCode::NdiRuntimeMissing,
        );
    }
    {
        let devices = monitor
            .devices()
            .into_iter()
            .map(|device| device_from_gst(&device))
            .collect();
        let mut guard = writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?;
        emit_snapshot(guard.as_mut(), helper_instance_id, devices)?;
    }

    let helper_instance_id = helper_instance_id.to_string();
    let bus = monitor.bus();
    while bus.pop().is_some() {}
    let _bus_watch = bus.add_watch(move |_, message| {
        let event = match message.view() {
            gst::MessageView::DeviceAdded(added) => Some(("ndi_device_added", added.device())),
            gst::MessageView::DeviceRemoved(removed) => {
                Some(("ndi_device_removed", removed.device()))
            }
            _ => None,
        };
        if let Some((event, device)) = event {
            if let Ok(mut writer) = writer.lock() {
                let _ = send_json_line(
                    writer.as_mut(),
                    &DeviceEvent {
                        event,
                        helper_instance_id: &helper_instance_id,
                        device: device_from_gst(&device),
                    },
                );
            }
        }
        glib::ControlFlow::Continue
    })?;

    let loop_ = glib::MainLoop::new(None, false);
    let stdin_loop = loop_.clone();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        glib::MainContext::default().invoke(move || stdin_loop.quit());
    });
    #[cfg(unix)]
    let _sigterm = {
        let signal_loop = loop_.clone();
        glib::source::unix_signal_add(15, move || {
            signal_loop.quit();
            glib::ControlFlow::Break
        })
    };
    loop_.run();
    monitor.stop();
    Ok(())
}

fn emit_snapshot(
    writer: &mut dyn StatsWriter,
    helper_instance_id: &str,
    devices: Vec<NdiDevice>,
) -> Result<()> {
    let truncated = devices.len() > MAX_DEVICES;
    let devices = devices.into_iter().take(MAX_DEVICES).collect();
    send_json_line(
        writer,
        &SnapshotEvent {
            event: "ndi_device_snapshot",
            helper_instance_id,
            devices,
            truncated,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizer_strips_controls_and_caps_at_a_utf8_boundary() {
        let input = format!("ok\u{0000}\u{0008}{}tail", "é".repeat(200));
        let output = sanitize_device_string(&input);
        assert!(!output.chars().any(char::is_control));
        assert!(output.len() <= 256);
        assert!(std::str::from_utf8(output.as_bytes()).is_ok());
    }

    #[test]
    fn snapshot_json_is_bounded() {
        let devices = (0..257)
            .map(|index| NdiDevice {
                display_name: index.to_string(),
                device_class: "Source/Network".to_string(),
                caps: "application/x-ndi".to_string(),
                properties: String::new(),
            })
            .collect::<Vec<_>>();
        let mut output = Vec::new();
        struct Writer<'a>(&'a mut Vec<String>);
        impl StatsWriter for Writer<'_> {
            fn send_message(&mut self, message: &str) -> Result<()> {
                self.0.push(message.to_string());
                Ok(())
            }
        }
        emit_snapshot(&mut Writer(&mut output), "helper-1", devices).expect("emits");
        let value: serde_json::Value = serde_json::from_str(&output[0]).expect("json");
        assert_eq!(value["event"], "ndi_device_snapshot");
        assert_eq!(value["helper_instance_id"], "helper-1");
        assert_eq!(value["devices"].as_array().map(Vec::len), Some(256));
        assert_eq!(value["truncated"], true);
    }
}
