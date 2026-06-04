use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;

const MIN_CAPTURE_WINDOW: Duration = Duration::from_secs(2);
const MAX_CAPTURE_WINDOW: Duration = Duration::from_secs(10);

/// Opens the thumbnail branch valve only for a short capture window on each interval.
pub struct ThumbnailScheduler {
    valve: gst::Element,
    interval: Duration,
    capture_window: Duration,
    #[allow(dead_code)]
    capture_timeout_source: Mutex<Option<glib::SourceId>>,
}

impl std::fmt::Debug for ThumbnailScheduler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThumbnailScheduler")
            .field("interval", &self.interval)
            .field("capture_window", &self.capture_window)
            .finish()
    }
}

impl ThumbnailScheduler {
    pub fn new(valve: gst::Element, interval: Duration) -> Arc<Self> {
        Arc::new(Self {
            valve,
            interval,
            capture_window: capture_window_for_interval(interval),
            capture_timeout_source: Mutex::new(None),
        })
    }

    pub fn start(self: &Arc<Self>) {
        self.begin_capture_window();
    }

    pub fn on_frame_captured(self: &Arc<Self>) {
        self.close_valve();
        self.clear_capture_timeout();
        self.schedule_next(self.interval);
    }

    fn begin_capture_window(self: &Arc<Self>) {
        self.valve.set_property("drop", false);
        self.clear_capture_timeout();

        let scheduler = Arc::clone(self);
        let source = glib::timeout_add_local(self.capture_window, move || {
            scheduler.end_capture_window_without_frame();
            glib::ControlFlow::Break
        });

        if let Ok(mut guard) = self.capture_timeout_source.lock() {
            *guard = Some(source);
        }
    }

    fn end_capture_window_without_frame(self: &Arc<Self>) {
        self.close_valve();
        self.clear_capture_timeout();
        self.schedule_next(self.interval);
    }

    fn schedule_next(self: &Arc<Self>, delay: Duration) {
        let scheduler = Arc::clone(self);
        glib::timeout_add_local(delay, move || {
            scheduler.begin_capture_window();
            glib::ControlFlow::Break
        });
    }

    fn close_valve(&self) {
        self.valve.set_property("drop", true);
    }

    fn clear_capture_timeout(&self) {
        let Ok(mut guard) = self.capture_timeout_source.lock() else {
            return;
        };

        if let Some(source) = guard.take() {
            source.remove();
        }
    }
}

fn capture_window_for_interval(interval: Duration) -> Duration {
    interval.min(MAX_CAPTURE_WINDOW).max(MIN_CAPTURE_WINDOW)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_window_is_bounded() {
        assert_eq!(
            capture_window_for_interval(Duration::from_millis(500)),
            MIN_CAPTURE_WINDOW
        );
        assert_eq!(
            capture_window_for_interval(Duration::from_secs(5)),
            Duration::from_secs(5)
        );
        assert_eq!(
            capture_window_for_interval(Duration::from_secs(3600)),
            MAX_CAPTURE_WINDOW
        );
    }
}
