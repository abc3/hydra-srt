defmodule HydraSrt.Rtmp.PublisherRegistryTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Rtmp.PublisherRegistry

  defp unique_path, do: "/pub/#{System.unique_integer([:positive])}"

  describe "register/2" do
    test "registers the calling process as the active publisher" do
      path = unique_path()

      assert :ok = PublisherRegistry.register(path, self())
      assert PublisherRegistry.active?(path)
      assert PublisherRegistry.owner(path) == self()

      :ok = Registry.unregister(PublisherRegistry.registry(), path)
    end

    test "rejects a second, different publisher with a conflict" do
      path = unique_path()
      assert :ok = PublisherRegistry.register(path, self())

      try do
        assert {:error, {:conflict, owner}} =
                 register_from_spawn(path)

        assert owner == self()
        assert PublisherRegistry.owner(path) == self()
      after
        :ok = Registry.unregister(PublisherRegistry.registry(), path)
      end
    end
  end

  describe "unregister/1" do
    test "removes the calling publisher" do
      path = unique_path()
      :ok = PublisherRegistry.register(path, self())

      assert :ok = PublisherRegistry.unregister(path)
      refute PublisherRegistry.active?(path)
    end

    test "is a no-op when the caller is not the owner" do
      path = unique_path()
      :ok = PublisherRegistry.register(path, self())

      try do
        assert :ok = unregister_from_spawn(path)
        assert PublisherRegistry.owner(path) == self()
      after
        :ok = Registry.unregister(PublisherRegistry.registry(), path)
      end
    end

    test "is a no-op when no entry exists" do
      assert :ok = PublisherRegistry.unregister(unique_path())
    end
  end

  describe "auto-cleanup on publisher exit" do
    test "clears the slot when the publisher process dies" do
      path = unique_path()
      parent = self()

      pid =
        spawn(fn ->
          :ok = PublisherRegistry.register(path, self())
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert PublisherRegistry.owner(path) == pid

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert wait_for(fn -> not PublisherRegistry.active?(path) end)
    end
  end

  defp register_from_spawn(path) do
    parent = self()

    spawn(fn ->
      result = PublisherRegistry.register(path, self())
      send(parent, {:register_result, result})
    end)

    assert_receive {:register_result, result}, 1_000
    result
  end

  defp unregister_from_spawn(path) do
    parent = self()

    spawn(fn ->
      result = PublisherRegistry.unregister(path)
      send(parent, {:unregister_result, result})
    end)

    assert_receive {:unregister_result, result}, 1_000
    result
  end

  defp wait_for(fun, attempts \\ 50) do
    if fun.() do
      true
    else
      if attempts > 0 do
        Process.sleep(5)
        wait_for(fun, attempts - 1)
      else
        false
      end
    end
  end
end
