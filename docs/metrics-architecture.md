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
- `entity_id = <node_name>:<interface_name>` (example: `hydra@127.0.0.1:eth0`)

This prevents collisions in multi-node setups where multiple nodes can have the same interface name.

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

## Node Analytics API

Node historical charts use:

- `GET /api/nodes/:id/analytics`

Implemented in:

- `HydraSrtWeb.NodeController.analytics/2`
- `HydraSrt.Stats.Analytics.fetch_node_timeseries/3`

The query:

- reads from `stats_samples`
- filters node metrics by `entity_type='node'` and `entity_id=:node_id`
- filters network metrics by `entity_type='net_if'` and `entity_id LIKE "#{node_id}:%"`
- aggregates by time bucket (`avg(value_double)`)

Returned node metrics:

- CPU usage (`cpu_util`)
- RAM usage (`ram_usage`)
- SWAP usage (`swap_usage`)
- Load average (`cpu_la_avg1`, `cpu_la_avg5`, `cpu_la_avg15`)
- Network rates (`net_rx_bytes_per_sec`, `net_tx_bytes_per_sec`)

For frontend compatibility, net interface ids are normalized from `node:iface` to `iface` in the API response keys.

## Time Windows and Downsampling

Time ranges are parsed in `HydraSrt.Stats.Analytics.parse_range/1` and bucket size is selected in `bucket_ms_for_range/3`.

Downsampling behavior:

- request accepts optional `max_points`
- default `max_points = 300`
- clamped to `[50, 2000]`
- bucket is chosen from discrete steps:
  - `10s`, `30s`, `1m`, `5m`, `15m`, `30m`, `1h`

This keeps chart point counts bounded for long windows (for example, 24h no longer returns minute-level full density by default).
