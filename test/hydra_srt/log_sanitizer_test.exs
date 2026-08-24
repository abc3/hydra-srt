defmodule HydraSrt.LogSanitizerTest do
  use ExUnit.Case, async: true

  alias HydraSrt.LogSanitizer

  test "masks the passphrase as a JSON field and inside the SRT uri" do
    payload =
      ~s({"srt":{"passphrase":"^Aa1Bb2Cc3Dd4Ee5^FG&H","uri":"srt://198.18.7.9:3947?mode=caller&passphrase=%5EAa1Bb2Cc3Dd4Ee5%5EFG%26H&pbkeylen=16"}})

    sanitized = LogSanitizer.sanitize_payload(payload)

    refute sanitized =~ "Aa1Bb2Cc3Dd4Ee5"
    refute sanitized =~ "%5EAa1"
    assert sanitized =~ ~s("passphrase":"[REDACTED]")
    assert sanitized =~ "passphrase=[REDACTED]"
    assert sanitized =~ "pbkeylen=16"
  end

  test "masks a passphrase containing escaped quotes" do
    payload = ~s({"passphrase":"pass\\"with\\"quotes","mode":"caller"})

    sanitized = LogSanitizer.sanitize_payload(payload)

    refute sanitized =~ "with"
    assert sanitized =~ ~s("passphrase":"[REDACTED]")
    assert sanitized =~ ~s("mode":"caller")
  end

  test "masks public peer addresses but keeps local bind addresses readable" do
    payload =
      ~s({"uri":"srt://198.18.7.9:3947","localaddress":"10.0.0.10","bind":"127.0.0.1","group":"239.1.1.1"})

    sanitized = LogSanitizer.sanitize_payload(payload)

    refute sanitized =~ "198.18.7.9"
    assert sanitized =~ "[REDACTED_IP]:3947"
    assert sanitized =~ ~s("localaddress":"10.0.0.10")
    assert sanitized =~ ~s("bind":"127.0.0.1")
    assert sanitized =~ ~s("group":"239.1.1.1")
  end

  test "public_ip? classifies local ranges as not public" do
    for local <- ["0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1"] do
      refute LogSanitizer.public_ip?(local), local
    end

    for local <- ["172.16.0.1", "172.31.255.255", "192.168.1.1", "239.1.1.1", "255.255.255.255"] do
      refute LogSanitizer.public_ip?(local), local
    end

    for public <- ["198.18.7.9", "8.8.8.8", "172.32.0.1", "100.128.0.1"] do
      assert LogSanitizer.public_ip?(public), public
    end
  end

  test "leaves non-binary payloads and ordinary numbers alone" do
    assert LogSanitizer.sanitize_payload(%{"passphrase" => "secret"}) == %{
             "passphrase" => "secret"
           }

    assert LogSanitizer.sanitize_payload(~s({"latency":1000,"port":3947})) ==
             ~s({"latency":1000,"port":3947})
  end
end
