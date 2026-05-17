defmodule HydraSrt.Stats.PipelineLogParserTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.PipelineLogParser

  @valid_line_with_element "0:00:00.123456789 1234 0x7f8b9c000b70 WARN srt src/srt.c:123:srt_connect:<srt-src> connection failed"

  @valid_line_without_element "0:00:01.000000000 99 0xabc INFO category file.c:1:init: hello world"

  test "parse/1 extracts GStreamer debug fields from a valid line" do
    assert {:ok, log} = PipelineLogParser.parse(@valid_line_with_element)

    assert log.gst_ts == "0:00:00.123456789"
    assert log.pid == 1234
    assert log.thread_id == "0x7f8b9c000b70"
    assert log.level == "WARN"
    assert log.category == "srt"
    assert log.file == "src/srt.c"
    assert log.line == 123
    assert log.function == "srt_connect"
    assert log.element == "srt-src"
    assert log.message == "connection failed"
  end

  test "parse/1 returns nil element when angle brackets are absent" do
    assert {:ok, log} = PipelineLogParser.parse(@valid_line_without_element)

    assert log.level == "INFO"
    assert log.element == nil
    assert log.message == "hello world"
  end

  test "parse/1 accepts uppercase hex thread ids" do
    line = "0:00:00.123456789 1234 0x7F8B9C000B70 WARN srt src/srt.c:1:fn: msg"

    assert {:ok, log} = PipelineLogParser.parse(line)
    assert log.thread_id == "0x7F8B9C000B70"
  end

  test "parse/1 returns error for non-GStreamer lines" do
    assert :error = PipelineLogParser.parse("not a gstreamer log line")
    assert :error = PipelineLogParser.parse("")
  end
end
