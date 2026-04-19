defmodule HydraSrt.E2E.Native.UdpListener do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stats(pid), do: GenServer.call(pid, :stats)

  def await_packets(pid, min_packets, timeout_ms) do
    await_stat(pid, timeout_ms, fn %{packets: packets} -> packets >= min_packets end)
  end

  def await_bytes(pid, min_bytes, timeout_ms) do
    await_stat(pid, timeout_ms, fn %{bytes: bytes} -> bytes >= min_bytes end)
  end

  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    test_pid = Keyword.fetch!(opts, :test_pid)

    {:ok, sock} =
      :gen_udp.open(port, [:binary, active: true, reuseaddr: true, ip: {127, 0, 0, 1}])

    state = %{
      sock: sock,
      port: port,
      test_pid: test_pid,
      packets: 0,
      bytes: 0
    }

    {:ok, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{packets: state.packets, bytes: state.bytes, port: state.port}, state}
  end

  def handle_info({:udp, sock, _ip, _src_port, data}, %{sock: sock} = state)
      when is_binary(data) do
    send(state.test_pid, {:udp_packet, state.port, byte_size(data)})

    {:noreply, %{state | packets: state.packets + 1, bytes: state.bytes + byte_size(data)}}
  end

  def terminate(_reason, %{sock: sock}) do
    :gen_udp.close(sock)
    :ok
  end

  defp await_stat(pid, timeout_ms, fun) when is_function(fun, 1) do
    start_ms = System.monotonic_time(:millisecond)
    do_await_stat(pid, start_ms, timeout_ms, fun)
  end

  defp do_await_stat(pid, start_ms, timeout_ms, fun) do
    state = stats(pid)

    if fun.(state) do
      {:ok, state}
    else
      now = System.monotonic_time(:millisecond)

      if now - start_ms > timeout_ms do
        {:error, state}
      else
        Process.sleep(50)
        do_await_stat(pid, start_ms, timeout_ms, fun)
      end
    end
  end
end
