CC := gcc
# NOTE:
# - We only require cmocka when building native tests (make test), not for the main binary.
# - cJSON comes from libcjson-dev on CI.
CFLAGS := -Wall -Wextra -g `pkg-config --cflags gstreamer-1.0 gio-2.0 srt libcjson`
LDFLAGS := `pkg-config --libs gstreamer-1.0 gio-2.0 srt libcjson`

SRC_DIR := src
BUILD_DIR := build
INCLUDE_DIR := include
TEST_DIR := tests

SRCS := $(wildcard $(SRC_DIR)/*.c)
OBJS := $(patsubst $(SRC_DIR)/%.c, $(BUILD_DIR)/%.o, $(SRCS))

TESTS := $(wildcard $(TEST_DIR)/*.c)
TEST_OBJS := $(patsubst $(TEST_DIR)/%.c, $(BUILD_DIR)/%.o, $(TESTS))

OBJS_NO_MAIN := $(filter-out $(BUILD_DIR)/main.o, $(OBJS))

MAIN_EXEC := $(BUILD_DIR)/hydra_srt_pipeline
TEST_EXEC := $(BUILD_DIR)/test_runner

all: $(MAIN_EXEC)

$(MAIN_EXEC): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

$(TEST_EXEC): $(TEST_OBJS) $(OBJS_NO_MAIN)
	$(CC) -o $@ $^ $(LDFLAGS) `pkg-config --libs cmocka`

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(INCLUDE_DIR) -c $< -o $@

$(BUILD_DIR)/%.o: $(TEST_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) `pkg-config --cflags cmocka` -I$(INCLUDE_DIR) -c $< -o $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Available targets:"
	@echo "  make              - Build all targets"
	@echo "  make clean        - Remove compiled files"
	@echo "  make help         - Show this help message"
	@echo "  make test         - Run tests"
	@echo "  make dummy_signal - Run dymmy_signal"

test: $(TEST_EXEC)
	./$(TEST_EXEC)

dummy_signal:
	ffmpeg -re \
		-f lavfi -i "testsrc2=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p -profile:v baseline -g 60 \
		-colorspace bt709 -color_primaries bt709 -color_trc bt709 \
		-c:a aac -b:a 128k -ar 48000 -ac 2 \
		-f mpegts "srt://127.0.0.1:8000?mode=listener&pkt_size=1316"

dummy_gs:
	gst-launch-1.0 -v \
	srtsrc uri="srt://:8000?mode=listener&streamid=test1" ! \
	queue ! \
	udpsink host=224.0.0.3 port=1234 auto-multicast=true


dummy_signal_with_pass:
	ffmpeg -re \
		-f lavfi -i "testsrc=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -b:v 2000k \
		-c:a aac -b:a 128k \
		-f mpegts \
		"srt://127.0.0.1:8000?mode=caller&streamid=test1&passphrase=some_pass&pbkeylen=16"


