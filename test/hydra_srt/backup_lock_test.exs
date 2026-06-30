defmodule HydraSrt.BackupLockTest do
  use ExUnit.Case, async: false

  alias HydraSrt.BackupLock

  test "runs backup operations one at a time on the local node" do
    parent = self()

    first =
      Task.async(fn ->
        BackupLock.run(fn ->
          send(parent, :first_started)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :first_started

    second =
      Task.async(fn ->
        BackupLock.run(fn ->
          send(parent, :second_started)
          :ok
        end)
      end)

    refute_receive :second_started, 50
    send(Process.whereis(BackupLock), :release)

    assert :ok = Task.await(first)
    assert_receive :second_started
    assert :ok = Task.await(second)
  end
end
