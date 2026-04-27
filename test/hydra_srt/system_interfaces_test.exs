defmodule HydraSrt.SystemInterfacesTest do
  use ExUnit.Case, async: true

  alias HydraSrt.SystemInterfaces

  describe "parse_ifconfig/1" do
    test "extracts interfaces with ipv4 and cidr from hex netmask" do
      output = """
      lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
      \tinet 127.0.0.1 netmask 0xff000000
      en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
      \tinet 172.20.20.12 netmask 0xffffff00 broadcast 172.20.20.255
      en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
      \tinet 192.168.221.15 netmask 0xffffff00 broadcast 192.168.221.255
      """

      assert SystemInterfaces.parse_ifconfig(output) == [
               %{
                 "sys_name" => "lo0",
                 "ip" => "127.0.0.1/8",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000"
               },
               %{
                 "sys_name" => "en0",
                 "ip" => "172.20.20.12/24",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 172.20.20.12 netmask 0xffffff00 broadcast 172.20.20.255"
               },
               %{
                 "sys_name" => "en1",
                 "ip" => "192.168.221.15/24",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 192.168.221.15 netmask 0xffffff00 broadcast 192.168.221.255"
               }
             ]
    end

    test "keeps interfaces without ipv4 using ipv6 when available" do
      output = """
      awdl0: flags=8943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1500
      \tinet6 fe80::1886:73ff:fe17:f680%awdl0 prefixlen 64 scopeid 0xc
      en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
      \tinet 10.0.0.10 netmask 255.255.255.0 broadcast 10.0.0.255
      """

      assert SystemInterfaces.parse_ifconfig(output) == [
               %{
                 "sys_name" => "awdl0",
                 "ip" => "fe80::1886:73ff:fe17:f680%awdl0/64",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "awdl0: flags=8943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1500\n\tinet6 fe80::1886:73ff:fe17:f680%awdl0 prefixlen 64 scopeid 0xc"
               },
               %{
                 "sys_name" => "en0",
                 "ip" => "10.0.0.10/24",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 10.0.0.10 netmask 255.255.255.0 broadcast 10.0.0.255"
               }
             ]
    end

    test "marks multicast support based on flags" do
      output = """
      utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 2000
      \tinet 10.10.10.2 netmask 255.255.255.255
      gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280
      \tinet 10.20.20.1 netmask 255.255.255.255
      fake0: flags=8802<BROADCAST,SIMPLEX> mtu 1500
      \tinet 172.16.1.1 netmask 255.255.255.0
      """

      assert SystemInterfaces.parse_ifconfig(output) == [
               %{
                 "sys_name" => "utun0",
                 "ip" => "10.10.10.2/32",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 2000\n\tinet 10.10.10.2 netmask 255.255.255.255"
               },
               %{
                 "sys_name" => "gif0",
                 "ip" => "10.20.20.1/32",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280\n\tinet 10.20.20.1 netmask 255.255.255.255"
               },
               %{
                 "sys_name" => "fake0",
                 "ip" => "172.16.1.1/24",
                 "multicast_supported" => false,
                 "raw_description" =>
                   "fake0: flags=8802<BROADCAST,SIMPLEX> mtu 1500\n\tinet 172.16.1.1 netmask 255.255.255.0"
               }
             ]
    end

    test "keeps interfaces without any ip and uses dash placeholder" do
      output = """
      en4: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
      \tmedia: none
      \tstatus: inactive
      """

      assert SystemInterfaces.parse_ifconfig(output) == [
               %{
                 "sys_name" => "en4",
                 "ip" => "-",
                 "multicast_supported" => true,
                 "raw_description" =>
                   "en4: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmedia: none\n\tstatus: inactive"
               }
             ]
    end
  end
end
