<img src="/web_app/public/logo.webp" alt="HydraSRT" width="400"/>

# HydraSRT – An Open Source Alternative to Haivision SRT Gateway

> ⚠️ **Pre-Alpha Status**: This project is in a very early development stage. Features may be incomplete, and breaking changes are expected.

- [Overview](#overview)
- [Motivation](#motivation)
- [Architecture](#architecture)
- [Docs](#docs)
- [Features](#features)
- [Inspiration](#inspiration)

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
- **Displays live stream statistics, logs, and route management tools**.
- **Supports dynamic updates** for seamless operation.

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

## Inspiration

- [Secure Reliable Transport](https://en.wikipedia.org/wiki/Secure_Reliable_Transport)
- [Haivision SRT Gateway](https://www.haivision.com/products/srt-gateway/)
