ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3
# Trixie ships GStreamer 1.26.x on amd64 and arm64 (bookworm-backports has no GST for arm64).
ARG DEBIAN_VERSION=trixie-20260610-slim
ARG NODE_MAJOR=24
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

ARG NODE_MAJOR=24

ENV MIX_ENV="prod"

# Install build dependencies
RUN apt-get update -y \
    && apt-get install -y build-essential git curl ca-certificates gnupg \
    && apt-get clean

# Install Rust via rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install Node.js for the web application build
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -y \
    && apt-get install -y nodejs \
    && apt-get clean

# GStreamer 1.26 from Trixie (native pipeline build deps).
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-tools \
    libcjson-dev \
    libsrt-openssl-dev \
    libcmocka-dev \
    libglib2.0-dev \
    pkg-config \
    && apt-get clean \
    && gst-launch-1.0 --version 2>&1 | tee /tmp/gst-version.txt \
    && grep -E '1\.26\.' /tmp/gst-version.txt

# Prepare build directory
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock VERSION ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy the rest of the application code
COPY priv priv
COPY lib lib
COPY native native
COPY web_app web_app
COPY rel rel

# Build the web application
RUN cd web_app \
    && npm ci \
    && npm run build

# Compile the Elixir application. This also builds native in release mode via mix compiler.
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/
RUN mix release

# Start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8
ENV MIX_ENV="prod"
ENV ECTO_IPV6 false
# Use IPv4 instead of IPv6 for Erlang distribution
ENV ERL_AFLAGS "-proto_dist inet_tcp"
# Runtime deps + GStreamer 1.26 from Trixie (install GStreamer after ffmpeg).
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    locales \
    iptables \
    net-tools \
    sudo \
    tini \
    curl \
    ffmpeg \
    libcjson1 \
    libsrt1.5-openssl \
    && apt-get install -y --no-install-recommends \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-tools \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    libgstreamer-plugins-bad1.0-0 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_* \
    && gst-launch-1.0 --version 2>&1 | tee /tmp/gst-version.txt \
    && grep -E '1\.26\.' /tmp/gst-version.txt

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR "/app"

# Create directory structure for mounted volumes
# These directories will be overridden by the volumes
RUN mkdir -p /app/backup && \
    chmod -R 777 /app/backup

# Copy the release from the builder stage
COPY --from=builder /app/_build/prod/rel/hydra_srt ./

# Overlay scripts (bin/server, bin/migrate) may lose +x in build context (e.g. Windows).
RUN chmod +x bin/server bin/migrate

COPY run.sh run.sh
RUN chmod +x run.sh

# Set the entrypoint
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/run.sh"]
CMD ["/app/bin/server"]
