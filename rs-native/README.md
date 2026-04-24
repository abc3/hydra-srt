# rs-native

Rust implementation of the `hydra_srt_pipeline` process.

Current contract compatibility:

- reads `route_id` from `argv[1]`
- reads one JSON line from `stdin`
- writes `route_id:<id>` to `stdout`
- writes `stats_source_stream_id:<stream_id>` to `stdout` on SRT caller connection
- writes lifecycle status JSON lines to `stdout`
- emits periodic JSON stats to `stdout` with the current Elixir/UI shape

Lifecycle status events:

- format: JSON Lines
- event shape: `{"event":"pipeline_status","status":"starting"}`
- `stopped` / `failed` may include a machine-readable `reason`

Route pipeline lifecycle semantics:

- `starting`: the pipeline has entered startup and is waiting for proof of real source processing
- `processing`: the source has produced at least one real buffer into the pipeline for the current startup/reconnect cycle
- `reconnecting`: the source emitted a real reconnect/disconnect-recovery runtime signal and the pipeline is waiting to resume processing
- `failed`: the pipeline hit a runtime or startup error
- `stopped`: the pipeline shut down, reached EOS, or terminated after a failure

Legal transitions:

- `starting -> processing`
- `starting -> failed`
- `starting -> stopped`
- `processing -> reconnecting`
- `processing -> failed`
- `processing -> stopped`
- `reconnecting -> processing`
- `reconnecting -> failed`
- `reconnecting -> stopped`
- `failed -> stopped`

Notes and current limitations:

- `starting` is emitted before `set_state(Playing)` so the lifecycle state is armed before the source can deliver early buffers.
- `processing` is emitted from the first real source buffer, not from process spawn or `set_state` alone.
- `processing` is a one-shot transition for each startup/reconnect cycle. rs-native does not keep checking lifecycle state on every buffer after the pipeline is already processing.
- after `reconnecting`, rs-native re-arms `processing` and emits it again only when a new real source buffer arrives.
- `reconnecting` is currently emitted only when the source provides an explicit runtime reconnect hook. For `srtsrc`, rs-native uses the `connection-removed` element message, which GStreamer emits when `keep-listening=true` and the remote caller disconnects.
- `srtsrc` caller-mode `auto-reconnect=true` does not currently expose a clean machine-readable reconnect callback/message that rs-native can rely on. We intentionally do not infer reconnecting from log text like "Trying to reconnect".
- To support caller-mode reconnecting reliably in the future, rs-native needs either:
  - a dedicated GStreamer element message for reconnect-attempt-start / reconnect-attempt-finished, or
  - an exposed signal/callback from the SRT source object for reconnect loop entry.

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

Manual QA:

1. Build and run rs-native:

```bash
cd rs-native
make build
make demo_srt_to_udp ROUTE_ID=qa_route SOURCE_PORT=9000 UDP_PORT=9003
```

2. Confirm `starting`:

- after the process enters playback startup, stdout should include:
  `{"event":"pipeline_status","status":"starting"}`

3. Confirm `processing`:

```bash
cd rs-native
make dummy_signal SOURCE_PORT=9000
```

- once the source pushes real buffers, stdout should include:
  `{"event":"pipeline_status","status":"processing"}`
- rs-native emits this once for the current processing cycle; it does not re-emit `processing` for every subsequent buffer

4. Confirm `reconnecting` for SRT listener mode:

- run rs-native with `keep-listening=true` in the source config
- start `make dummy_signal SOURCE_PORT=9000`
- stop the sender abruptly
- when `srtsrc` emits `connection-removed`, stdout should include:
  `{"event":"pipeline_status","status":"reconnecting"}`
- start the sender again; once real source buffers resume, rs-native should emit `processing` again for that new cycle

5. Confirm `stopped`:

- stop rs-native cleanly or let the pipeline reach EOS
- stdout should include:
  `{"event":"pipeline_status","status":"stopped","reason":"shutdown"}`
  or
  `{"event":"pipeline_status","status":"stopped","reason":"eos"}`
- if a runtime error occurs first, rs-native should emit:
  `{"event":"pipeline_status","status":"failed","reason":"runtime_error"}`
  followed by
  `{"event":"pipeline_status","status":"stopped","reason":"failure"}`
