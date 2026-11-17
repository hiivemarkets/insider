defmodule Insider.Live.TimelineCumulativeTest do
  # One live session per node, and the test suspends its Logger collector.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Collector.Admission
  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Owner
  alias Insider.Live.Timeline
  alias Insider.Live.TimelineScan

  @domain [:insider_timeline_cumulative]

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end
    end)

    # Only this test's log lines are recorded or shed, whatever else logs.
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger"],
               "logger_level" => "info",
               # Elixir's Logger prefixes a domain with :elixir.
               "logger_include" => [
                 %{"domain" => ["elixir" | Enum.map(@domain, &Atom.to_string/1)]}
               ]
             })

    %{id: id}
  end

  test "a page cursor issued before the scan, with losses during it, reports the cumulative total",
       %{id: id} do
    # 259 lines into a suspended collector whose inbox holds 256: 3 shed,
    # 256 recorded; then 244 more, so cursor 500 is issued with 3 shed.
    shed(259)
    assert {:ok, _batch} = Live.events_since(id, "latest")
    log(id, 244)
    read = read_to(id, 0, 500)
    assert %{"count" => 3} = Enum.find(read["gaps"], &(&1["reason"] == "logger_shed"))

    log(id, 500)
    assert {:ok, %{"next_receipt" => 1_000}} = Live.status(id)

    # A clock that spends 1,000 ms of a 2,000 ms budget per read: the
    # snapshot, then one page read (receipts 501..1,000), then the deadline.
    # After the snapshot one more line is shed, so the session has lost 4.
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    reader = fn session_id, cursor, options ->
      result = owner_read(session_id, cursor, options)
      if Agent.get(clock, & &1) == 0, do: shed(257)
      Agent.update(clock, &(&1 + 1_000))
      result
    end

    assert {:ok, scan, "deadline"} =
             TimelineScan.run(id, reader, 2_000, now: fn -> Agent.get(clock, & &1) end)

    result =
      Timeline.timeline(scan, %{
        request_id: "none",
        limit: 200,
        max_bytes: 262_144,
        human: false,
        ending: "deadline"
      })

    refute result["scan"]["complete"]

    assert %{"count" => 4, "scope" => "since_session_start"} =
             Enum.find(result["gaps"], &(&1["reason"] == "logger_shed"))

    # The public cumulative view agrees.
    assert {:ok, public} = Live.events_since(id, 0, %{"limit" => 1})
    assert %{"count" => 4} = Enum.find(public["gaps"], &(&1["reason"] == "logger_shed"))
  end

  test "a log line still in a suspended collector's inbox is in the scan once the collector runs",
       %{id: id} do
    collector = logger_collector()
    :ok = :sys.suspend(collector)
    # Admitted to the inbox by the logging process; the collector has not
    # drained it.
    emit(1)
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    # The scan's snapshot read drains the inboxes first, so it waits for the
    # collector; release it while the snapshot is pending.
    scan =
      Task.async(fn ->
        reader = fn session_id, cursor, options ->
          Agent.update(clock, &(&1 + 1))
          owner_read(session_id, cursor, options)
        end

        TimelineScan.run(id, reader, 4_000, now: fn -> Agent.get(clock, & &1) end)
      end)

    wait_for_pending_call(collector)
    :ok = :sys.resume(collector)
    assert {:ok, scan, nil} = Task.await(scan, 10_000)

    assert [%{"receipt" => 1, "event" => %{"payload" => %{"message" => "line 1"}}}] =
             Enum.reverse(scan.entries)

    assert scan.upper == 1
  end

  # The collector has a call waiting (the read's flush).
  defp wait_for_pending_call(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, waiting} when waiting > 0 ->
        :ok

      _none ->
        Process.sleep(1)
        wait_for_pending_call(pid)
    end
  end

  # Public reads from `cursor` until one ends at `target`, which issues
  # `target` as a cursor with the session's losses at that moment.
  defp read_to(id, cursor, target) do
    assert {:ok, %{"next_cursor" => next} = read} =
             Live.events_since(id, cursor, %{"limit" => 500, "max_bytes" => 1_048_576})

    cond do
      next == target -> read
      next > cursor -> read_to(id, next, target)
    end
  end

  # The read a timeline scan makes, through the owner's admission boundary.
  defp owner_read(session_id, cursor, options) do
    pid = Process.whereis(Owner)
    {:ok, admission} = Owner.admission(pid)
    :ok = Admission.acquire(admission, Owner.admitted_calls_max())
    deadline = System.monotonic_time(:millisecond) + 5_000

    GenServer.call(
      pid,
      {:admitted, admission, deadline, TimelineScan.request(session_id, cursor, options)},
      6_000
    )
  end

  # `count` lines into the suspended collector, whose inbox is empty (the
  # last read drained it): what exceeds its 256 slots is shed.
  defp shed(count) do
    collector = logger_collector()
    :ok = :sys.suspend(collector)
    emit(count)
    :ok = :sys.resume(collector)
  end

  # `count` lines in chunks of at most 200, each drained by a read that
  # issues only the newest cursor, so none is shed.
  defp log(id, count) do
    for chunk <- Enum.chunk_every(1..count, 200) do
      emit(length(chunk))
      assert {:ok, _batch} = Live.events_since(id, "latest")
    end
  end

  defp emit(count) do
    Task.await(
      Task.async(fn ->
        for n <- 1..count, do: Logger.info("line #{n}", domain: @domain)
      end),
      30_000
    )
  end

  defp logger_collector do
    session = :sys.get_state(Manager).active.pid
    Map.fetch!(:sys.get_state(session).components, :logger)
  end
end
