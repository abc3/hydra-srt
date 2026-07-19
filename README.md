<br />
<p align="center">
  <img src="/web_app/public/logo.webp" alt="HydraSRT" width="400"/>
</p>

<h1 align="center">HydraSRT</h1>

<p align="center">
  An open-source alternative to Haivision SRT Gateway.
  <br />
  <a href="https://github.com/streamband/hydra-srt/issues/new">Report Bug</a>
  ·
  <a href="https://github.com/streamband/hydra-srt/issues/new?labels=enhancement">Request Feature</a>
</p>

## Status

> **Project Status**: Beta.

[![GitHub License](https://img.shields.io/github/license/streamband/hydra-srt)](https://github.com/streamband/hydra-srt/blob/main/LICENSE)

### Supported transports

| Transport | Input | Output |
| --------- | ----- | ------ |
| SRT       | ✔     | ✔      |
| UDP       | ✔     | ✔      |
| RTMP      | ✔     | ✔      |
| RTP       | ✔     | —      |
| [NDI](docs/ndi.md) | ✔ | ✔ |

NDI is off by default. It needs the NDI runtime, which is not shipped with HydraSRT and
is installed by the operator: see [docs/ndi.md](docs/ndi.md).

### Planned transports

| Transport | Input | Output |
| --------- | ----- | ------ |
| HLS       | —     | —      |
| WebRTC    | —     | —      |
| MoQ       | —     | —      |

### Capabilities

RTMP output remuxes the route MPEG-TS stream to FLV without decoding. It supports codecs accepted by GStreamer's FLV muxer, such as H.264 video and AAC/MP3 audio.

| Capability | Notes | Status |
| ---------- | ----- | ------ |
| One-to-many distribution | Single source to multiple unicast/multicast outputs | Beta |
| Reliability | Source failover and reconnection | Beta |
| Security | SRT passphrase and stream ID | Beta |
| Observability | Prometheus metrics, route stats, and pipeline logs | Beta |

Missing a feature? [Open an issue](https://github.com/streamband/hydra-srt/issues/new?labels=enhancement).

## Overview

<p align="center">
  <img src="docs/images/hydrasrt-dashboard.png" alt="HydraSRT operations dashboard" width="1200" />
</p>

HydraSRT is an open-source alternative to Haivision SRT Gateway for reliable video transport and routing. It manages SRT, UDP, and RTP streams with built-in failover, supervision, metrics, and a modern web UI and API designed for broadcast and live production workflows.

Built with Elixir(Erlang/OTP), Rust, and GStreamer, HydraSRT combines strong fault isolation with lightweight orchestration. The BEAM supervises routing and control logic, while isolated media pipelines run only where active streams are present, providing high reliability with low system overhead.

## Architecture

HydraSRT has three layers:

```mermaid
flowchart LR
  UI[React UI] -->|REST/WebSocket| API[Phoenix API]
  API --> Control[Elixir/OTP Supervisor]
  Control -->|spawns & monitors| Pipeline1[Rust Pipeline 1]
  Control -->|spawns & monitors| Pipeline2[Rust Pipeline 2]
  Control -->|spawns & monitors| PipelineN[Rust Pipeline N]
  Control --> SQLite[(SQLite Config)]
  Control --> VictoriaMetrics[(VictoriaMetrics)]
  Control --> VictoriaLogs[(VictoriaLogs)]
```

**Management & Control (Elixir/OTP)**
- Supervises routes and restarts failed route processes
- Stores configuration and route state in SQLite
- Exposes REST and WebSocket APIs
- Handles failover and source switching

**Streaming & Processing (Rust + GStreamer)**
- Runs each route as an isolated OS process
- Uses GStreamer for media processing
- Keeps pipeline crashes limited to the affected route

**User Interface (React + Vite)**
- Route management dashboard
- Real-time status over WebSocket
- Historical metrics and logs

See [docs/architecture.md](docs/architecture.md) for details.

## Quick Start

### Docker

```bash
docker compose up
```

Open [http://127.0.0.1:4000](http://127.0.0.1:4000) and log in with `admin` / `password123`.

The default Compose file uses Linux host networking. If your Docker Engine cannot use Linux host networking, run with explicit port mappings:

```bash
docker compose -f docker-compose.yml -f docker-compose.ports.yml up
```

Host networking is intended for native Linux, including WSL2 only when Docker Engine runs inside the WSL distro.

### Local Development

```bash
# First-time setup
mix setup

# Start dev server (Elixir + Vite)
make dev
```

Web UI: [http://localhost:5173](http://localhost:5173).

Setup, deployment, and troubleshooting: [docs/development.md](docs/development.md).

## Features

- SRT source and destination modes: Listener, Caller, Rendezvous
- UDP sources and destinations
- RTP (TS over RTP) sources
- SRT authentication with passphrase and stream ID support
- Source failover with primary + backup sources, automatic failover, and manual source switching
- System metrics via Prometheus `/metrics`
- Historical analytics and route events stored in VictoriaMetrics
- Historical pipeline logs stored in VictoriaLogs
- Real-time route status updates over WebSocket

## Documentation

| Document                              | Purpose                               |
| ------------------------------------- | ------------------------------------- |
| [docs/development.md](docs/development.md) | Setup, deployment, and Docker guide |
| [docs/architecture.md](docs/architecture.md) | System design and technical details |
| [docs/api.md](docs/api.md)            | REST API documentation                |
| [docs/mcp.md](docs/mcp.md)            | MCP server, tokens, and client setup |
| [docs/envs.md](docs/envs.md)          | Environment variables reference       |
| [docs/ndi.md](docs/ndi.md)            | Installing and enabling NDI           |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## License

Apache 2.0. See [LICENSE](LICENSE).

## Inspiration

- [Secure Reliable Transport](https://en.wikipedia.org/wiki/Secure_Reliable_Transport)
- [Haivision SRT Gateway](https://www.haivision.com/products/srt-gateway/)

## Contact

Use GitHub issues: [https://github.com/streamband/hydra-srt/issues](https://github.com/streamband/hydra-srt/issues)
