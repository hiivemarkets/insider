defmodule Insider.Live.SlotWorkerTest do
  use ExUnit.Case, async: true

  alias Insider.Live.SlotWorker

  defp options(slots, overrides \\ []) do
    Keyword.merge(
      [slots: slots, heap_words: 1_000_000, include_shared_binaries: false, await_ms: 1_000],
      overrides
    )
  end

  defp slots, do: [:"slot_worker_test_#{System.unique_integer([:positive])}"]

  test "returns the work's result and leaves nothing registered" do
    [slot] = slots = slots()
    assert {:ok, :done} = SlotWorker.run(fn -> {:ok, :done} end, options(slots))
    assert Process.whereis(slot) == nil
  end

  test "a caller is busy while every slot is held" do
    [slot] = slots = slots()
    test = self()

    holder =
      spawn(fn ->
        SlotWorker.run(
          fn ->
            send(test, {:holding, self()})
            receive do: (:release -> :ok)
          end,
          options(slots, await_ms: 5_000)
        )
      end)

    assert_receive {:holding, worker}, 1_000
    assert Process.whereis(slot) == worker
    assert {:error, %{"code" => "busy"}} = SlotWorker.run(fn -> :never end, options(slots))
    send(worker, :release)
    ref = Process.monitor(holder)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 1_000
  end

  test "a worker that exits is unavailable" do
    assert {:error, %{"code" => "unavailable"}} =
             SlotWorker.run(fn -> exit(:boom) end, options(slots()))
  end

  test "a worker over its heap limit is killed and unavailable" do
    assert {:error, %{"code" => "unavailable"}} =
             SlotWorker.run(
               fn -> Enum.to_list(1..1_000_000) end,
               options(slots(), heap_words: 10_000)
             )
  end

  test "a late worker is killed and the call is a timeout" do
    test = self()

    assert {:error, %{"code" => "timeout"}} =
             SlotWorker.run(
               fn ->
                 send(test, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               options(slots(), await_ms: 50)
             )

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
  end
end
