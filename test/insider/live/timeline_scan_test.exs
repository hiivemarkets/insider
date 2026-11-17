defmodule Insider.Live.TimelineScanTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Live

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end
    end)

    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "info"})

    # A long history of other requests, then the one the reader wants. The
    # history is logged in paced chunks, each drained by a read, so the
    # Logger inbox (256) and the Recorder's rate limit (1,000 a second) drop
    # none of it.
    for chunk <- 0..9 do
      Task.await(
        Task.async(fn ->
          for n <- (chunk * 200 + 1)..(chunk * 200 + 200) do
            Logger.metadata(request_id: "old-#{n}")
            Logger.info("handled old request #{n}")
          end
        end),
        60_000
      )

      assert {:ok, _batch} = Live.events_since(id, "latest")
      Process.sleep(250)
    end

    pid =
      Task.await(
        Task.async(fn ->
          Logger.metadata(request_id: "target-1")
          Logger.info("handled the target request")
          self() |> :erlang.pid_to_list() |> to_string()
        end)
      )

    assert {:ok, %{"gaps" => []}} = Live.events_since(id, 0, %{"limit" => 1})
    %{id: id, pid: pid}
  end

  test "the public timeline finds a request, or reports the receipts it did not read",
       %{id: id} do
    # No timing is assumed: a complete scan finds both requests; a scan the
    # budget ended without a match reports the receipts it did not read.
    for request_id <- ["target-1", "old-1"] do
      assert {:ok, result} = Live.timeline(id, %{"request_id" => request_id})

      cond do
        result["scan"]["complete"] ->
          assert result["seeds"] == 1, request_id
          refute Enum.any?(result["gaps"], &(&1["reason"] == "scan_truncated"))

        result["seeds"] == 0 ->
          assert Enum.any?(
                   result["gaps"],
                   &(&1["reason"] == "scan_truncated" and &1["count"] > 0)
                 )

        true ->
          assert result["seeds"] == 1
      end
    end
  end
end
