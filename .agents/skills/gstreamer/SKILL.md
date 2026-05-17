---
name: gstreamer
description: Use this skill for GStreamer pipeline development and debugging: graph design, caps negotiation issues, latency, synchronization, and runtime diagnostics.
---

# GStreamer Skill

## When to use
Use for tasks with `gst-launch`, pipeline graphs, plugin selection, caps negotiation, timing/sync, encoder/decoder tuning, or stream reliability.

## Workflow
1. Define expected media contract first: codec, resolution, framerate, latency budget.
2. Build minimal pipeline that works end-to-end.
3. Add elements incrementally and validate after each addition.
4. Capture logs and DOT graphs when behavior diverges.
5. Lock in working caps and buffering strategy.

## Core commands
- Quick run: `gst-launch-1.0 ...`
- Inspect plugin: `gst-inspect-1.0 <element>`
- Verbose logs: `GST_DEBUG=2 gst-launch-1.0 ...`
- Focused logs: `GST_DEBUG=GST_CAPS:6,GST_PADS:6,GST_EVENT:5 gst-launch-1.0 ...`
- Dump graphs:
  `GST_DEBUG_DUMP_DOT_DIR=/tmp GST_DEBUG=3 gst-launch-1.0 ...`
  then render with Graphviz (`dot -Tpng file.dot -o graph.png`).

## Debug heuristics
- If no data flow: verify pad link compatibility and capsfilter placement.
- If negotiation fails: inspect upstream/downstream caps and force explicit caps near boundaries.
- If latency spikes: inspect queue sizes, leaky settings, and encoder tune/preset.
- If A/V drift: inspect timestamps, clock selection, and sync flags.
- If intermittent drops: check jitter buffer, network burst tolerance, and keyframe interval.

## Reliability patterns
- Use queues between thread domains.
- Set explicit caps at critical boundaries.
- Prefer explicit parser/payloader/depayloader elements rather than implicit auto-plugging in production.
- Add watchdog/health probes for long-running pipelines.

## Validation checklist
- Startup time and steady-state latency measured.
- Recovery behavior tested (source restart / network jitter).
- CPU and memory stable under expected load.
- Logs include enough signal for postmortem.
