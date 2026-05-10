defmodule HydraSrt.Monitoring.NetIfTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Monitoring.NetIf

  test "parse_proc_net_dev parses linux counters" do
    input = """
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1048576 1000    0    0    0    0     0          0         1048576 1000    0    0    0    0     0       0
      eth0: 1234567 2000    1    2    0    0     0          0         7654321 3000    3    4    0    0     0       0
    """

    stats = NetIf.parse_proc_net_dev(input)

    assert stats["eth0"].rx_bytes == 1_234_567
    assert stats["eth0"].tx_bytes == 7_654_321
    assert stats["eth0"].rx_packets == 2_000
    assert stats["eth0"].tx_packets == 3_000
    assert stats["eth0"].rx_errors == 1
    assert stats["eth0"].tx_errors == 3
    assert stats["eth0"].rx_dropped == 2
    assert stats["eth0"].tx_dropped == 4
  end

  test "parse_netstat_ibn parses bsd-style link rows" do
    input = """
    Name    Mtu Network       Address              Ipkts Ierrs Idrop     Ibytes    Opkts Oerrs     Obytes  Coll
    en0    1500 <Link#4>      ac:de:48:00:11:22    1000     1     2     111111     2000     3     222222     0
    en0    1500 192.168.1/24  192.168.1.10             0     -     -          0        0     -          0     -
    lo0   16384 <Link#1>      00:00:00:00:00:00      500     0     0      33333      500     0      33333     0
    """

    stats = NetIf.parse_netstat_ibn(input)

    assert stats["en0"].rx_bytes == 111_111
    assert stats["en0"].tx_bytes == 222_222
    assert stats["en0"].rx_packets == 1_000
    assert stats["en0"].tx_packets == 2_000
    assert stats["en0"].rx_errors == 1
    assert stats["en0"].tx_errors == 3
    assert stats["en0"].rx_dropped == 2
  end

  test "rates computes per-second values and ignores resets" do
    prev = %{"eth0" => %{rx_bytes: 1000, tx_bytes: 500}}
    curr = %{"eth0" => %{rx_bytes: 1600, tx_bytes: 300}}

    rates = NetIf.rates(prev, curr, 1000)

    assert rates["eth0"].rx_bytes == 600.0
    refute Map.has_key?(rates["eth0"], :tx_bytes)
  end
end
