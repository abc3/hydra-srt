<img src="/web_app/public/logo.webp" alt="HydraSRT" width="400"/>

# HydraSRT – An Open Source Alternative to Haivision SRT Gateway

> ⚠️ **Pre-Alpha Status**: This project is in a very early development stage. Features may be incomplete, and breaking changes are expected.

- [Overview](#overview)
- [Motivation](#motivation)
- [Architecture](#architecture)
- [Docs](#docs)
- [Features](#features)
- [Development](#development)
- [Deployment](#deployment)
- [Inspiration](#inspiration)
- [Contact](#contact)

## Overview

https://github.com/user-attachments/assets/8230f902-b037-424f-a337-a3828dac6a3c

HydraSRT is an open-source, high-performance alternative to the **Haivision SRT Gateway**. It is designed to provide a scalable and flexible solution for **Secure Reliable Transport (SRT)** video routing, with support for multiple streaming protocols.

## Motivation

HydraSRT aims to deliver a robust and adaptable solution for video routing, offering a scalable alternative to proprietary systems. It supports multiple streaming protocols, ensuring flexibility and high performance.

## Architecture

HydraSRT is structured into **three core layers**, each designed for efficiency, reliability, and modularity:

### **1. Management & Control Layer (Elixir)**

- **Manages streaming pipelines** and dynamic route configurations.
- **Exposes a REST API** for frontend interaction.
- **Uses [Khepri](https://rabbitmq.github.io/khepri/)** as a **persistent tree-based key-value store** for system state and configurations.

#### Cluster Mode

Coming soon...

### **2. Streaming & Processing Layer (Isolated C + GStreamer)**

- **Memory safety & stability** – The C-based application runs as a separate, isolated process, ensuring that memory leaks do not affect the Elixir control layer. Elixir can monitor for issues and terminate pipelines if necessary to maintain system stability.
- **High-performance video processing** via **GStreamer**.
- **Secure interprocess communication** with the Elixir layer.
<!-- - **Support for dynamic routing**, allowing real-time addition/removal of destinations. -->

### **3. User Interface Layer (Vite + React + Ant Design)**

- **Communicates with the backend via REST API** for real-time control.
- **Provides a dashboard and route management tools** for users to interact with the system.
- **Supports user authentication and session management** to ensure secure access.
- **Displays route status and allows for route configuration** through a user-friendly interface.

## Docs

Coming soon.

## Features

- [x] SRT Source Modes:
  - [x] Listener
  - [x] Caller
  - [x] Rendezvous
- [x] SRT Destination Modes:
  - [x] Listener
  - [x] Caller
  - [x] Rendezvous
- [x] SRT Authentication
- [x] SRT Source Statistics
- [ ] SRT Destination Statistics
- [x] UDP Support:
  - [x] Source
  - [x] Destination
- [ ] Cluster Mode
- [ ] Dynamic Routing
- [ ] RTSP
- [ ] RTMP
- [ ] HLS
- [ ] MPEG-DASH
- [ ] WebRTC

[Missed something? Add a request!](https://github.com/abc3/hydra-srt/issues/new)

## Development

To run HydraSRT locally, you'll need to start both the Elixir backend and the web UI.

### Backend

```bash
# Start the Elixir node
make dev
```

### Frontend

```bash
# Start the web UI
cd web_app && yarn dev
```

## Deployment

### Prerequisites

#### System Dependencies

Before deploying HydraSRT, ensure your system has the following dependencies installed:

1. **Elixir** (version 1.14 or later)
2. **Erlang/OTP** (compatible with your Elixir version)
3. **Node.js** and npm (for building the web application)

   > **Recommended**: Use [asdf](https://asdf-vm.com/) for managing Elixir, Erlang, and Node.js versions.
   > The project includes a `.tool-versions` file with the following versions:
   >
   > - Elixir 1.17.1-otp-27
   > - Erlang 27.0
   > - Node.js 18.13.0

4. **GStreamer** and related libraries for the C application:

   ```bash
   # Ubuntu/Debian
   sudo apt-get install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
     gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
     libcjson-dev libsrt-dev libcmocka-dev libgio2.0-dev pkg-config

   # macOS (using Homebrew)
   brew install gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad \
     cjson srt cmocka pkg-config
   ```

5. **Verify C application dependencies** are correctly installed:
   ```bash
   pkg-config --libs gstreamer-1.0 libcjson cmocka gio-2.0 srt
   ```
   This command should output the linking flags without errors. If you see errors, ensure all required packages are installed.

### Building for Production

1. **Clone the repository**:

   ```bash
   git clone https://github.com/abc3/hydra-srt.git
   cd hydra-srt
   ```

2. **Build the release**:

   ```bash
   # Get Elixir dependencies
   mix deps.get

   # Install JavaScript dependencies for the web application
   cd web_app && npm install && cd ..

   # Compile the project
   MIX_ENV=prod mix compile

   # Create the release (this will automatically build the web app and C application)
   MIX_ENV=prod mix release
   ```

   The release process will:

   - Compile the Elixir application
   - Build the C application using `make`
   - Build the web application using `npm run build`
   - Package everything into a self-contained release

### Running in Production

1. **Start the application**:

   ```bash
   # Start the application with interactive Elixir shell (recommended during early development)
   API_AUTH_USERNAME=your_username API_AUTH_PASSWORD=your_password _build/prod/rel/hydra_srt/bin/hydra_srt start_iex
   ```

   Or in daemon mode (for stable production environments):

   ```bash
   # Start the application in the background
   API_AUTH_USERNAME=your_username API_AUTH_PASSWORD=your_password _build/prod/rel/hydra_srt/bin/hydra_srt start
   ```

2. **Additional commands**:

   ```bash
   # To stop the application
   _build/prod/rel/hydra_srt/bin/hydra_srt stop

   # To connect to a running application remotely
   _build/prod/rel/hydra_srt/bin/hydra_srt remote

   # To see all available commands
   _build/prod/rel/hydra_srt/bin/hydra_srt
   ```

3. **Accessing the Web UI**:

   After starting the application, the web interface will be available at:

   ```
   http://your_server_ip:4000
   ```

   Where:

   - `your_server_ip` is the IP address or hostname of your server
   - `4000` is the default port (can be changed using the `PORT` environment variable)

   You'll need to use the credentials specified in `API_AUTH_USERNAME` and `API_AUTH_PASSWORD` to log in.

### Environment Variables

Configure HydraSRT using the following environment variables:

| Variable               | Description                             | Default          |
| ---------------------- | --------------------------------------- | ---------------- |
| `API_AUTH_USERNAME`    | Username for API authentication         | (required)       |
| `API_AUTH_PASSWORD`    | Password for API authentication         | (required)       |
| `PORT`                 | HTTP port for the API server            | 4000             |
| `RELEASE_COOKIE`       | Erlang distribution cookie              | (auto-generated) |
| `VICTORIAMETRICS_HOST` | Host for VictoriaMetrics metrics export | (optional)       |
| `VICTORIAMETRICS_PORT` | Port for VictoriaMetrics metrics export | (optional)       |

### Troubleshooting

1. **C Application Issues**:

   - Verify all dependencies are installed with `pkg-config --libs gstreamer-1.0 libcjson cmocka gio-2.0 srt`
   - Check the C application logs in `_build/prod/rel/hydra_srt/log/`

2. **Web Application Issues**:

   - Ensure Node.js and npm are installed and working correctly
   - Try building the web app manually: `cd web_app && npm install && npm run build`

3. **Elixir Application Issues**:

   - Ensure all required environment variables are set

4. **Metrics Monitoring**:

   - To enable metrics export to VictoriaMetrics, set both `VICTORIAMETRICS_HOST` and `VICTORIAMETRICS_PORT` environment variables
   - Example: `VICTORIAMETRICS_HOST=localhost VICTORIAMETRICS_PORT=8428 API_AUTH_USERNAME=admin API_AUTH_PASSWORD=password _build/prod/rel/hydra_srt/bin/hydra_srt start_iex`
   - You can visualize these metrics using Grafana or any other compatible dashboard tool

## Inspiration

- [Secure Reliable Transport](https://en.wikipedia.org/wiki/Secure_Reliable_Transport)
- [Haivision SRT Gateway](https://www.haivision.com/products/srt-gateway/)

## Contact

For support or inquiries, please contact me at [hydrasrt@abc3.dev](mailto:hydrasrt@abc3.dev).
