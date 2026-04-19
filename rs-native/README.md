# rs-native

Rust implementation of the `hydra_srt_pipeline` process.

Current contract compatibility:

- reads `route_id` from `argv[1]`
- reads one JSON line from `stdin`
- writes `route_id:<id>` to `stdout`
- writes `stats_source_stream_id:<stream_id>` to `stdout` on SRT caller connection
- emits periodic JSON stats to `stdout` with the current Elixir/UI shape

Current implementation scope:

- source types: `srtsrc`, `udpsrc`
- sink types: `srtsink`, `udpsink`
- throughput counters via pad probes
- SRT stats via the GStreamer `stats` property on `srtsrc` / `srtsink`
- caller acceptance via `caller-connecting`

Build:

```bash
mix compile.rs_native
```

Run examples:

```bash
cd rs-native
make demo_srt_to_udp
```

Send a test SRT stream into the Rust runner:

```bash
cd rs-native
make dummy_signal
```

Watch the forwarded UDP output:

```bash
cd rs-native
make play_udp
```

Other useful demo targets:

- `make demo_srt_to_srt`
- `make demo_srt_to_udp_pass`
- `make dummy_signal_with_pass`

You can override ports and route id:

```bash
cd rs-native
make demo_srt_to_udp ROUTE_ID=my_route SOURCE_PORT=9000 UDP_PORT=9003
```
