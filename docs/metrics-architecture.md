# Metrics Architecture

This document describes how Hydra SRT collects and stores system-level statistics.

## Overview

Hydra SRT collects system metrics once per polling interval and uses the same data in two places:

1. Prometheus `/metrics` export (real-time monitoring).
2. DuckDB history in `stats_samples` (time-series analytics in UI/API).

The collection path is:

1. `HydraSrt.PromEx.Plugins.OsMon` polls OS metrics.
2. Plugin emits `:telemetry` events (`HydraSrt.Monitoring.OsMonTelemetry`).
3. `HydraSrt.Stats.SystemTelemetryCollector` listens to these events.
4. Collector converts events to rows and writes to DuckDB via `HydraSrt.Stats.Duckdb`.

## Collected Metric Groups

`OsMon` plugin emits:

- CPU utilization and load average.
- Memory and RAM usage.
- Swap usage.
- Network interface metrics (per interface).

## Network Metrics (Per Interface)

Network data is collected by `HydraSrt.Monitoring.NetIf`.

- Linux: reads kernel counters from `/sys/class/net/*/statistics/*` (fallback `/proc/net/dev`).
- macOS and FreeBSD: reads counters from `netstat -i -b -n` (`-W` is added on macOS).

The collector stores per-interface rows using:

- `entity_type = "net_if"`
- `entity_id = <interface_name>` (example: `eth0`, `en0`)

Metric keys written to `stats_samples`:

- `net_rx_bytes_total`
- `net_tx_bytes_total`
- `net_rx_packets_total`
- `net_tx_packets_total`
- `net_rx_errors_total`
- `net_tx_errors_total`
- `net_rx_dropped_total`
- `net_tx_dropped_total`
- `net_rx_bytes_per_sec`
- `net_tx_bytes_per_sec`
- `net_rx_packets_per_sec`
- `net_tx_packets_per_sec`
- `net_rx_errors_per_sec`
- `net_tx_errors_per_sec`
- `net_rx_dropped_per_sec`
- `net_tx_dropped_per_sec`

Rates are derived from counter deltas between polling intervals.

Note about Prometheus typing:

- `_total` network values are exported as polling snapshots via `last_value` (Gauge semantics in this PromEx path), not native Prometheus Counters.
- For rates in Hydra UI and DuckDB, Hydra computes deltas internally and stores explicit `*_per_sec` metrics.

## Configuration

System history collection is controlled by:

- `SYSTEM_METRICS_HISTORY_ENABLED`

Prometheus poll interval is controlled by:

- `PROM_POLL_RATE`
- `PROM_POLL_RATE` is also used as the system telemetry flush interval to DuckDB.
