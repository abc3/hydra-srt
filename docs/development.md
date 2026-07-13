# Developing HydraSRT

Local development, release builds, and Docker usage.

## Prerequisites

### System Dependencies

Install:

1. **Elixir** (version 1.18.4 or later)
2. **Erlang/OTP** (version 27.3 or later)
3. **Node.js** and npm (version 24.2.0 or later, for building the web UI)

   > Use [asdf](https://asdf-vm.com/) or another version manager. `.tool-versions` currently pins:
   >
   > - Elixir 1.18.4-otp-27
   > - Erlang 27.3.4.1
   > - Node.js 24.2.0

4. **Rust**, Cargo, **GStreamer**, and related libraries for the streaming pipeline:

   ```bash
   # Ubuntu/Debian
   sudo apt-get install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
     gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
     libsrt-openssl-dev libglib2.0-dev pkg-config cargo rustc

   # macOS (using Homebrew)
   brew install gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad \
     srt pkg-config rust
   ```

5. **Verify streaming pipeline dependencies** are correctly installed:
   ```bash
   pkg-config --libs gstreamer-1.0 gstreamer-base-1.0 glib-2.0 srt
   ```
   This command should print linker flags. If it errors, install the missing GStreamer/SRT packages.

## Local Development

`make dev` starts Phoenix and the Vite dev server.

### First-time Setup

```bash
mix setup
```

### Starting the Development Server

```bash
make dev
```

The web UI dev server is fixed to:

- `host: localhost`
- `port: 5173`
- `strictPort: true`

If `5173` is busy, Vite fails instead of selecting another port.

Override for Docker/remote dev:

- `VITE_DEV_HOST` (example: `0.0.0.0`)
- `VITE_DEV_PORT` (example: `5173`)
- `VITE_DEV_STRICT_PORT` (example: `false`)

```bash
cd web_app
VITE_DEV_HOST=0.0.0.0 VITE_DEV_STRICT_PORT=false yarn dev
```

### Demo Mode

`DEMO_DATA=true` creates disabled demo routes.

```bash
DEMO_DATA=true make dev
```

When demo mode is enabled:

- `ffmpeg` must be available in `PATH` (startup fails if missing)
- five routes are created automatically (idempotent):
  - `demo_route` (SRT source):
    - source: `srt://127.0.0.1:4200?mode=caller`
    - destinations:
      - `srt://127.0.0.1:4211?mode=listener`
      - `udp://127.0.0.1:4212` (for local playback)
  - `demo_udp_route` (UDP source):
    - source: `udp://127.0.0.1:4201`
    - destinations:
      - `srt://127.0.0.1:4213?mode=listener`
      - `udp://127.0.0.1:4214` (for local playback)
  - `demo_rtp_route` (RTP source):
    - source: `rtp://127.0.0.1:4202`
    - destinations:
      - `srt://127.0.0.1:4205?mode=listener`
      - `udp://127.0.0.1:4206` (for local playback)
  - `demo_rtmp_route` (RTMP source):
    - source: `/live/test`
    - destinations:
      - `srt://127.0.0.1:4215?mode=listener`
      - `rtmp://127.0.0.1:1935/demo/routetest`
  - `demo_rtmp-client_route` (SRT source → UDP + RTMP client):
    - source: `srt://127.0.0.1:4200?mode=caller`
    - destinations:
      - `udp://127.0.0.1:4216` (for local playback; port 4216 avoids bind conflict with `demo_route` UDP on 4212)
      - `rtmp://127.0.0.1:1935/live/stream`
- routes are created with `enabled: false` (not auto-started)

After startup:

1. Open [http://localhost:5173/#/settings/signal-generation/srt](http://localhost:5173/#/settings/signal-generation/srt) (or `/udp`, `/rtp`, `/rtmp`)
2. Click `Start` in the `Signal generation` section for the active tab
3. Start the matching demo route from the Routes UI:
   - SRT tab → `demo_route`
   - UDP tab → `demo_udp_route`
   - RTP tab → `demo_rtp_route`
   - RTMP tab → `demo_rtmp_route`
   - SRT → RTMP client → `demo_rtmp-client_route` (start SRT signal generation, then this route)

Verify playback:

```bash
# demo_route SRT destination
ffplay -fflags nobuffer -flags low_delay -i "srt://127.0.0.1:4211?mode=caller"

# demo_route UDP destination
ffplay -fflags nobuffer -flags low_delay -i "udp://@:4212"

# demo_udp_route UDP destination
ffplay -fflags nobuffer -flags low_delay -i "udp://@:4214"

# demo_rtp_route UDP destination
ffplay -fflags nobuffer -flags low_delay -i "udp://@:4206"

# demo_rtmp_route SRT destination
ffplay -fflags nobuffer -flags low_delay -i "srt://127.0.0.1:4215?mode=caller"

# demo_rtmp_route RTMP destination
ffplay -fflags nobuffer -flags low_delay -i "rtmp://127.0.0.1:1935/demo/routetest"

# demo_rtmp-client_route UDP destination
ffplay -fflags nobuffer -flags low_delay -i "udp://@:4216"

# demo_rtmp-client_route RTMP destination (Hydra RTMP proxy on 127.0.0.1:1935)
ffplay -fflags nobuffer -flags low_delay -i "rtmp://127.0.0.1:1935/live/stream"
```

### Environment Variables

See [envs.md](envs.md).

## Building for Production

> HydraSRT is beta. Validate upgrades before production rollout.

1. **Clone the repository**:

   ```bash
   git clone https://github.com/streamband/hydra-srt.git
   cd hydra-srt
   ```

2. **Build the release**:

   ```bash
   mix deps.get

   cd web_app && npm install && cd ..

   MIX_ENV=prod mix compile

   MIX_ENV=prod mix release
   ```

   The release compiles Elixir, builds the Rust pipeline, builds the web app, and packages the release.

## Running in Production

Use `start_iex` when you want an interactive shell.

1. **Interactive shell**:

   ```bash
   PHX_SERVER=true DATABASE_PATH=/etc/hydra_srt/hydra_srt.db API_AUTH_USERNAME=your_username API_AUTH_PASSWORD=your_password _build/prod/rel/hydra_srt/bin/hydra_srt start_iex
   ```

   **Daemon mode**:

   ```bash
   PHX_SERVER=true DATABASE_PATH=/etc/hydra_srt/hydra_srt.db API_AUTH_USERNAME=your_username API_AUTH_PASSWORD=your_password _build/prod/rel/hydra_srt/bin/hydra_srt start
   ```

2. **Release commands**:

   ```bash
   _build/prod/rel/hydra_srt/bin/hydra_srt stop

   _build/prod/rel/hydra_srt/bin/hydra_srt remote

   _build/prod/rel/hydra_srt/bin/hydra_srt
   ```

3. **Open the UI**:

   ```
   http://your_server_ip:4000
   ```

   `4000` is the default port. Override with `PORT`.

## Running with Docker

The repository includes Compose files for the recommended Docker workflow.

### Quick Start with Docker Compose

Build the local image:

```bash
docker compose build
```

Start on native Linux:

```bash
docker compose up
```

On first start (fresh `./data/db` volume), the container will automatically run DB migrations.
To disable auto-migrations, set `RUN_MIGRATIONS=false`.
`docker-compose.yml` uses `DATABASE_PATH=/app/db/hydra_srt.db`, stores route metadata under `./data/db`, and starts VictoriaMetrics plus VictoriaLogs with 3-day retention for historical metrics, events, and pipeline logs.

The default Compose file uses `network_mode: "host"` so HydraSRT can bind directly to the host network. This is intended for native Linux, including WSL2 only when Docker Engine runs inside the WSL distro.

If your Docker Engine cannot use Linux host networking, start with the ports override:

```bash
docker compose -f docker-compose.yml -f docker-compose.ports.yml up
```

To override the DB path, credentials, demo mode, or `POOL_SIZE`, create a `.env` file:

```bash
echo "API_AUTH_USERNAME=admin" > .env
echo "API_AUTH_PASSWORD=password123" >> .env
echo "DATABASE_PATH=/app/db/hydra_srt.db" >> .env
echo "DEMO_DATA=false" >> .env
echo "POOL_SIZE=1" >> .env
```

Open the UI:

```
http://127.0.0.1:4000
```

Log in with `API_AUTH_USERNAME` and `API_AUTH_PASSWORD`.

Stop:

```bash
docker compose down
```

### Docker Networking

Docker networking modes:

- **Default (recommended on native Linux)**: host networking through `network_mode: "host"`.
- **Ports override**: bridge networking with explicit port mappings through `docker-compose.ports.yml`.

#### Default mode: host network

```bash
docker compose up --build
```

Web UI:

```
http://127.0.0.1:4000
```

Host network means:

- The container uses the host IP and interfaces.
- Container ports are exposed on the host network.
- Port conflicts must be handled on the host.

#### Ports override

```bash
docker compose -f docker-compose.yml -f docker-compose.ports.yml up -d
```

To stop:

```bash
docker compose -f docker-compose.yml -f docker-compose.ports.yml down
```

Use the ports override when Linux host networking is not available or not desired. Docker Desktop-backed setups do not provide the same host network behavior as a native Linux Docker Engine. On WSL2, host networking is only the expected Linux behavior when Docker Engine runs inside the WSL distro.

### Running the Published Image Directly

Use direct `docker run` only when you do not want to use the repository Compose files.

Prebuilt Docker image:

- [streamband/hydra-srt](https://hub.docker.com/r/streamband/hydra-srt)

Native Linux:

```bash
docker run --rm --network host \
  -v "$(pwd)/data/db:/app/db" \
  -e PHX_SERVER=true \
  -e DATABASE_PATH=/app/db/hydra_srt.db \
  -e VICTORIA_METRICS_URL=http://127.0.0.1:8428 \
  -e VICTORIA_LOGS_URL=http://127.0.0.1:9428 \
  -e API_AUTH_USERNAME=admin \
  -e API_AUTH_PASSWORD=password123 \
  streamband/hydra-srt:latest
```

Fallback with explicit port mappings:

```bash
docker run --rm -p 4000:4000 \
  -p 1935:1935 \
  -p 4100-4500:4100-4500/udp \
  -v "$(pwd)/data/db:/app/db" \
  -e PHX_SERVER=true \
  -e DATABASE_PATH=/app/db/hydra_srt.db \
  -e VICTORIA_METRICS_URL=http://host.docker.internal:8428 \
  -e VICTORIA_LOGS_URL=http://host.docker.internal:9428 \
  -e API_AUTH_USERNAME=admin \
  -e API_AUTH_PASSWORD=password123 \
  streamband/hydra-srt:latest
```

## Troubleshooting

1. **Streaming pipeline**:

   - Check dependencies: `pkg-config --libs gstreamer-1.0 gstreamer-base-1.0 glib-2.0 srt`
   - Rebuild the Rust binary with `mix compile.rs_native`

2. **Web app**:

   - Check Node/npm versions
   - Build manually: `cd web_app && npm install && npm run build`

3. **Elixir app**:

   - Check required environment variables

## Testing and Quality

```bash
mix q
mix test
```

Other useful commands:

```bash
E2E=true mix test --only e2e
cd native && cargo test
cd web_app && npm run test:unit
cd web_app && npm run test:e2e
make test_ci_local
```
