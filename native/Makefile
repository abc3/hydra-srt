CC := gcc
CFLAGS := -Wall -Wextra -g `pkg-config --cflags gstreamer-1.0 libcjson cmocka srt`
LDFLAGS := `pkg-config --libs gstreamer-1.0 libcjson cmocka gio-2.0 srt`

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
	$(CC) -o $@ $^ $(LDFLAGS)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(INCLUDE_DIR) -c $< -o $@

$(BUILD_DIR)/%.o: $(TEST_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(INCLUDE_DIR) -c $< -o $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Available targets:"
	@echo "  make        - Build all targets"
	@echo "  make clean  - Remove compiled files"
	@echo "  make help   - Show this help message"
	@echo "  make test   - Run tests"

test: $(TEST_EXEC)
	./$(TEST_EXEC)

dummy_signal:
	ffmpeg -re \
		-f lavfi -i "testsrc=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -b:v 2000k \
		-c:a aac -b:a 128k \
		-f mpegts \
		"srt://127.0.0.1:8000?mode=caller&streamid=test1"

dummy_signal_with_pass:
	ffmpeg -re \
		-f lavfi -i "testsrc=size=1280x720:rate=30" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-c:v libx264 -preset veryfast -tune zerolatency -b:v 2000k \
		-c:a aac -b:a 128k \
		-f mpegts \
		"srt://127.0.0.1:8000?mode=caller&streamid=test1&passphrase=some_pass&pbkeylen=16"


