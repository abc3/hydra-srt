BUILD_DIR := target/debug
BIN := $(BUILD_DIR)/hydra_srt_pipeline_rs
ROUTE_ID ?= rs_demo
SOURCE_PORT ?= 8000
SINK_PORT ?= 8002
UDP_PORT ?= 8003
PASSPHRASE ?= some_pass_1
PBKEYLEN ?= 16

.PHONY: all
all: build

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make build                  - Build the Rust pipeline binary"
	@echo "  make check                  - cargo check"
	@echo "  make run ARGS=<route_id>    - Run cargo run with custom args"
	@echo "  make demo_srt_to_udp        - Start rs-native with SRT source -> UDP sink config"
	@echo "  make demo_srt_to_srt        - Start rs-native with SRT source -> SRT sink config"
	@echo "  make demo_srt_to_udp_pass   - Start rs-native with encrypted SRT source -> UDP sink config"
	@echo "  make dummy_signal           - Send ffmpeg SRT test signal to SOURCE_PORT"
	@echo "  make dummy_signal_with_pass - Send encrypted ffmpeg SRT test signal to SOURCE_PORT"
	@echo "  make play_udp               - Play UDP output from UDP_PORT"
	@echo "  make clean                  - cargo clean"

.PHONY: build
build:
	cargo build

.PHONY: check
check:
	cargo check

.PHONY: run
run:
	GST_REGISTRY_FORK=no cargo run -- $(ARGS)

.PHONY: demo_srt_to_udp
demo_srt_to_udp:
	printf '%s\n' '{"source":{"type":"srtsrc","uri":"srt://127.0.0.1:$(SOURCE_PORT)?mode=listener","localaddress":"127.0.0.1","localport":$(SOURCE_PORT),"auto-reconnect":true,"keep-listening":false,"mode":"listener"},"sinks":[{"type":"udpsink","address":"127.0.0.1","host":"127.0.0.1","port":$(UDP_PORT),"hydra_destination_id":"udp_demo","hydra_destination_name":"udp_demo","hydra_destination_schema":"UDP"}]}' | GST_REGISTRY_FORK=no cargo run -- $(ROUTE_ID)

.PHONY: demo_srt_to_srt
demo_srt_to_srt:
	printf '%s\n' '{"source":{"type":"srtsrc","uri":"srt://127.0.0.1:$(SOURCE_PORT)?mode=listener","localaddress":"127.0.0.1","localport":$(SOURCE_PORT),"auto-reconnect":true,"keep-listening":false,"mode":"listener"},"sinks":[{"type":"srtsink","localaddress":"127.0.0.1","localport":$(SINK_PORT),"mode":"caller","uri":"srt://127.0.0.1:$(SINK_PORT)?mode=caller","hydra_destination_id":"srt_demo","hydra_destination_name":"srt_demo","hydra_destination_schema":"SRT"}]}' | GST_REGISTRY_FORK=no cargo run -- $(ROUTE_ID)

.PHONY: demo_srt_to_udp_pass
demo_srt_to_udp_pass:
	printf '%s\n' '{"source":{"type":"srtsrc","uri":"srt://127.0.0.1:$(SOURCE_PORT)?mode=listener&passphrase=$(PASSPHRASE)&pbkeylen=$(PBKEYLEN)","localaddress":"127.0.0.1","localport":$(SOURCE_PORT),"auto-reconnect":true,"keep-listening":false,"mode":"listener","passphrase":"$(PASSPHRASE)","pbkeylen":$(PBKEYLEN)},"sinks":[{"type":"udpsink","address":"127.0.0.1","host":"127.0.0.1","port":$(UDP_PORT),"hydra_destination_id":"udp_demo","hydra_destination_name":"udp_demo","hydra_destination_schema":"UDP"}]}' | GST_REGISTRY_FORK=no cargo run -- $(ROUTE_ID)

.PHONY: dummy_signal
dummy_signal:
	ffmpeg -hide_banner -loglevel error -re \
		-f lavfi -i "testsrc2=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p -profile:v baseline -g 60 \
		-colorspace bt709 -color_primaries bt709 -color_trc bt709 \
		-c:a aac -b:a 128k -ar 48000 -ac 2 \
		-f mpegts "srt://127.0.0.1:$(SOURCE_PORT)?mode=caller&pkt_size=1316"

.PHONY: dummy_signal_with_pass
dummy_signal_with_pass:
	ffmpeg -hide_banner -loglevel error -re \
		-f lavfi -i "testsrc=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -b:v 2000k \
		-c:a aac -b:a 128k \
		-f mpegts \
		"srt://127.0.0.1:$(SOURCE_PORT)?mode=caller&streamid=test1&passphrase=$(PASSPHRASE)&pbkeylen=$(PBKEYLEN)"

.PHONY: play_udp
play_udp:
	ffplay "udp://127.0.0.1:$(UDP_PORT)"

.PHONY: clean
clean:
	cargo clean
