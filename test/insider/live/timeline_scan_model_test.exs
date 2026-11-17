defmodule Insider.Live.TimelineScanModelTest do
  # A model of `events_since/3` and a controlled clock, so what a scan
  # reaches before its budget ends is exact.
  use ExUnit.Case, async: true

  alias Insider.Live.Timeline
  alias Insider.Live.TimelineScan

  # The model session: `retained` receipts with an event each, the rest up
  # to `newest` evicted, and cumulative losses since session start. A read
  # honours `"upto"` (default: the newest receipt) and `"limit"`, and counts
  # evictions exactly for the receipts it covers, as Insider.Live.Batch does.
  defp reader(session, clock, tick_ms) do
    fn "s", cursor, options ->
      Agent.update(clock, &(&1 + tick_ms))
      %{newest: newest} = state = Agent.get(session, & &1)
      cursor = if cursor == "latest", do: newest, else: cursor
      upto = Map.get(options, "upto") || newest
      limit = min(Map.get(options, "limit", 50), Map.get(state, :read_limit, 500))

      covered =
        (cursor + 1)..upto//1
        |> Enum.reduce_while({[], cursor}, fn receipt, {events, _last} ->
          cond do
            length(events) >= limit ->
              {:halt, {events, receipt - 1}}

            MapSet.member?(state.retained, receipt) ->
              {:cont, {[event(receipt) | events], receipt}}

            true ->
              {:cont, {events, receipt}}
          end
        end)

      {events, next} = covered
      events = Enum.reverse(events)
      evicted = next - cursor - length(events)

      gaps =
        Enum.reject(
          [
            %{"reason" => "evicted", "count" => evicted, "scope" => "receipt_range"},
            %{
              "reason" => "recorder_oversized",
              "count" => state.oversized,
              "scope" => "since_session_start"
            }
          ],
          &(&1["count"] == 0)
        )

      {:ok,
       %{
         "cursor" => cursor,
         "next_cursor" => next,
         "next_receipt" => newest,
         "events" => events,
         "gaps" => gaps
       }}
    end
  end

  defp event(receipt) do
    %{
      "receipt" => receipt,
      "redactions" => [],
      "event" => %{
        "source" => "logger",
        "kind" => "logger_message",
        "severity" => "info",
        "wall_time" =>
          DateTime.to_iso8601(DateTime.from_unix!(1_761_000_000_000_000 + receipt, :microsecond)),
        "subject" => %{"namespace" => "process", "scope" => "n@h", "value" => "<0.#{receipt}.0>"},
        "causality" => %{"trace_id" => nil, "span_id" => nil},
        "attributes" => %{},
        "payload" => %{
          "message" => "r#{receipt}",
          "metadata" => %{"request_id" => "req-#{receipt}"}
        }
      }
    }
  end

  defp session(newest, retained, oversized \\ 0) do
    {:ok, session} =
      Agent.start_link(fn ->
        %{newest: newest, retained: MapSet.new(retained), oversized: oversized}
      end)

    session
  end

  defp clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    clock
  end

  defp run(session, budget_ms, tick_ms) do
    clock = clock()
    now = fn -> Agent.get(clock, & &1) end
    TimelineScan.run("s", reader(session, clock, tick_ms), budget_ms, now: now)
  end

  defp result(scan, ending, request_id) do
    Timeline.timeline(scan, %{
      request_id: request_id,
      limit: 200,
      max_bytes: 262_144,
      human: false,
      ending: ending
    })
  end

  defp gap(result, reason), do: Enum.find(result["gaps"], &(&1["reason"] == reason))

  test "evictions across pages are counted once per receipt" do
    # 1,000 receipts, every one evicted: two pages, 1,000 evictions, not 1,500.
    assert {:ok, scan, nil} = run(session(1_000, []), 4_000, 10)
    result = result(scan, nil, "req-1")

    assert gap(result, "evicted")["count"] == 1_000
    assert result["scan"]["complete"]
    assert result["scan"]["unread"] == 0
    assert gap(result, "scan_truncated") == nil
  end

  test "sparse history: retained events and evictions add up to the receipts read" do
    retained = [3, 480, 501, 999, 1_200]
    assert {:ok, scan, nil} = run(session(1_200, retained), 4_000, 10)
    result = result(scan, nil, "req-480")

    assert result["seeds"] == 1
    assert gap(result, "evicted")["count"] == 1_200 - length(retained)
  end

  test "events and receipt-range losses after the snapshot belong to no page" do
    session = session(1_000, [1_000])
    clock = clock()
    read = reader(session, clock, 10)

    # After the snapshot, 500 more receipts arrive, all evicted.
    grow = fn id, cursor, options ->
      result = read.(id, cursor, options)
      Agent.update(session, &%{&1 | newest: 1_500})
      result
    end

    assert {:ok, scan, nil} =
             TimelineScan.run("s", grow, 4_000, now: fn -> Agent.get(clock, & &1) end)

    result = result(scan, nil, "req-1000")
    assert result["seeds"] == 1
    assert result["scan"]["next_cursor"] == 1_000
    assert gap(result, "evicted")["count"] == 999
  end

  test "a cumulative loss that grows during the scan is reported as last observed" do
    session = session(1_000, [1_000], 3)
    clock = clock()
    read = reader(session, clock, 10)

    # The snapshot sees 3 oversized events; the node rejects 8 more while the
    # scan reads its pages. Cumulative losses have no receipt, so the scan
    # reports what its last read observed.
    grow = fn id, cursor, options ->
      result = read.(id, cursor, options)
      Agent.update(session, &%{&1 | oversized: 11})
      result
    end

    assert {:ok, scan, nil} =
             TimelineScan.run("s", grow, 4_000, now: fn -> Agent.get(clock, & &1) end)

    assert %{"count" => 11, "scope" => "since_session_start"} =
             gap(result(scan, nil, "req-1000"), "recorder_oversized")
  end

  test "a budget that ends partway through the first page counts exactly what it did not read" do
    # Every read returns at most 85 events and costs 1,000 ms of a 2,000 ms
    # budget: the snapshot, then one read of receipts 501..585 of the first
    # page (501..1,000). The newest receipt, 1,000, is not reached.
    session = session(1_000, Enum.to_list(1..1_000))
    Agent.update(session, &Map.put(&1, :read_limit, 85))

    assert {:ok, scan, "deadline"} = run(session, 2_000, 1_000)
    result = result(scan, "deadline", "req-1000")

    assert result["seeds"] == 0
    assert result["scan"]["examined"] == 85
    assert result["scan"]["cursor"] == 500
    assert result["scan"]["next_cursor"] == 585
    assert result["scan"]["unread"] == 915
    assert %{"count" => 915, "scope" => "receipt_range"} = gap(result, "scan_truncated")
    assert result(scan, "deadline", "req-501")["seeds"] == 1
  end

  test "losses before any receipt are kept, and an empty session is complete" do
    assert {:ok, scan, nil} = run(session(0, [], 3), 4_000, 10)
    result = result(scan, nil, "req-1")

    assert result["items"] == []
    assert result["scan"]["complete"]
    assert %{"count" => 3, "scope" => "since_session_start"} = gap(result, "recorder_oversized")
  end

  test "cumulative losses are reported once across the snapshot and every page" do
    assert {:ok, scan, nil} = run(session(1_500, [1, 1_500], 4), 4_000, 10)
    result = result(scan, nil, "req-1")

    assert %{"count" => 4} = gap(result, "recorder_oversized")
  end

  test "a budget that ends after exactly one page finds the newest request and counts the rest" do
    # Each read takes 1,000 ms of a 2,000 ms budget: the snapshot, then one
    # page of 500 receipts (one read of up to 500 events), then the floor.
    retained = Enum.to_list(1..2_000)
    assert {:ok, scan, "deadline"} = run(session(2_000, retained), 2_000, 1_000)
    newest = result(scan, "deadline", "req-2000")

    assert newest["seeds"] == 1
    assert newest["scan"]["unread"] == 1_500
    assert newest["scan"]["cursor"] == 1_500
    assert %{"count" => 1_500, "scope" => "receipt_range"} = gap(newest, "scan_truncated")

    oldest = result(scan, "deadline", "req-1")
    assert oldest["items"] == []
    assert %{"count" => 1_500} = gap(oldest, "scan_truncated")
  end

  test "a budget spent by the snapshot reads nothing and reports everything unread" do
    assert {:ok, scan, "deadline"} = run(session(800, [800]), 1_000, 1_000)
    result = result(scan, "deadline", "req-800")

    assert result["items"] == []
    assert %{"count" => 800} = gap(result, "scan_truncated")
  end
end
