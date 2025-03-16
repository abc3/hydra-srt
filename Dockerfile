ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241111-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

ENV MIX_ENV="prod"

# Install build dependencies
RUN apt-get update -y \
    && apt-get install -y build-essential git curl ca-certificates gnupg \
    && apt-get clean

# Install Node.js 18.x
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -y \
    && apt-get install -y nodejs \
    && apt-get clean

# Install GStreamer and related libraries for the C application
RUN apt-get update -y \
    && apt-get install -y \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    libcjson-dev \
    libsrt-openssl-dev \
    libcmocka-dev \
    libglib2.0-dev \
    pkg-config \
    && apt-get clean

# Prepare build directory
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock ./
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

# Build the C application - ensure we clean first to force a rebuild for Linux
RUN cd native && make clean && make

# Build the web application
RUN cd web_app \
    && npm install \
    && npm run build

# Compile the Elixir application
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
# Set the DATABASE_DATA_DIR environment variable to point to the mounted volume
ENV DATABASE_DATA_DIR="/app/khepri"

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    iptables \
    sudo \
    tini \
    curl \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    libcjson1 \
    libsrt1.5-openssl \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR "/app"

# Create directory structure for mounted volumes
# These directories will be overridden by the volumes
RUN mkdir -p /app/khepri /app/backup && \
    chmod -R 777 /app/khepri /app/backup

# Copy the release from the builder stage
COPY --from=builder /app/_build/prod/rel/hydra_srt ./

COPY run.sh run.sh
RUN chmod +x run.sh

# Set the entrypoint
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/run.sh"]
CMD ["/app/bin/server"] 