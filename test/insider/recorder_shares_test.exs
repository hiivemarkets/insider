defmodule Insider.RecorderSharesTest do
  use ExUnit.Case, async: true

  alias Insider.Event
  alias Insider.Recorder
  alias Insider.Recorder.Config

  # Logger 10 events, Telemetry 4, Poller 4 of a 20-event Recorder; 2 are
  # reserved by no one.
  @shares %{"logger" => 50, "telemetry" => 20, "poller" => 20}

  test "a Logger flood cannot evict Telemetry or Poller evidence within their shares" do
    handle = start_recorder(max_events: 20, source_shares: @shares, other_share: 0)

    for sequence <- 1..4 do
      assert :ok = Recorder.record(handle, event("telemetry", sequence))
      assert :ok = Recorder.record(handle, event("poller", sequence))
    end

    for sequence <- 1..500, do: assert(:ok = Recorder.record(handle, event("logger", sequence)))

    retained = read_all(handle)

    assert ids(retained, "telemetry") == ids_of("telemetry", 1..4)
    assert ids(retained, "poller") == ids_of("poller", 1..4)
    # The flood kept the room no one else used, and lost its own oldest.
    assert ids(retained, "logger") == ids_of("logger", 489..500)

    assert {:ok, fill} = Recorder.fill(handle)
    assert %{evicted: 488, retained_events: 12, reserved_events: 10} = fill.sources["logger"]
    assert %{evicted: 0, retained_events: 4, reserved_events: 4} = fill.sources["telemetry"]
    assert %{evicted: 0, retained_events: 4, reserved_events: 4} = fill.sources["poller"]
    assert %{evicted: 0, retained_events: 0, reserved_events: 0} = fill.sources["other"]

    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.evicted == 488
    assert status.sources == fill.sources
  end

  test "a flood bound by bytes cannot evict a quiet source within its byte share" do
    handle =
      start_recorder(
        max_events: 1_000,
        max_bytes: 64 * 1_024,
        source_shares: %{"logger" => 50, "telemetry" => 20},
        other_share: 0
      )

    for sequence <- 1..3, do: assert(:ok = Recorder.record(handle, event("telemetry", sequence)))
    padding = %{"message" => String.duplicate("x", 2_000)}

    for sequence <- 1..200,
        do: assert(:ok = Recorder.record(handle, event("logger", sequence, attributes: padding)))

    retained = read_all(handle)
    assert ids(retained, "telemetry") == ids_of("telemetry", 1..3)
    assert {:ok, fill} = Recorder.fill(handle)
    assert fill.retained_bytes <= 64 * 1_024
    assert fill.sources["telemetry"].evicted == 0
    assert fill.sources["logger"].evicted > 0
    assert fill.sources["logger"].retained_bytes > fill.sources["logger"].reserved_bytes
  end

  test "a source over its share evicts its own oldest entries first" do
    handle = start_recorder(max_events: 10, source_shares: @shares, other_share: 0)

    for sequence <- 1..5 do
      assert :ok = Recorder.record(handle, event("logger", sequence))
      assert :ok = Recorder.record(handle, event("poller", sequence))
    end

    # The Poller holds 5 of its 2 reserved events, so its write takes its own oldest.
    assert :ok = Recorder.record(handle, event("poller", 6))
    assert ids(read_all(handle), "poller") == ids_of("poller", 2..6)
    assert ids(read_all(handle), "logger") == ids_of("logger", 1..5)

    # The Logger, at its 5 reserved events, also takes its own oldest.
    assert :ok = Recorder.record(handle, event("logger", 6))
    assert ids(read_all(handle), "logger") == ids_of("logger", 2..6)
    assert ids(read_all(handle), "poller") == ids_of("poller", 2..6)

    # Telemetry is within its share, so it takes from a source over its share.
    assert :ok = Recorder.record(handle, event("telemetry", 1))
    retained = read_all(handle)
    assert ids(retained, "poller") == ids_of("poller", 3..6)
    assert ids(retained, "logger") == ids_of("logger", 2..6)
    assert ids(retained, "telemetry") == ids_of("telemetry", 1..1)

    assert {:ok, fill} = Recorder.fill(handle)
    assert fill.sources["poller"].evicted == 2
    assert fill.sources["logger"].evicted == 1
  end

  test "sources without a share of their own draw on the other share together" do
    handle =
      start_recorder(max_events: 10, source_shares: %{"logger" => 60}, other_share: 40)

    assert :ok = Recorder.record(handle, event("agent_probe", 1))
    assert :ok = Recorder.record(handle, event("fixture", 1))
    for sequence <- 1..100, do: assert(:ok = Recorder.record(handle, event("logger", sequence)))

    retained = read_all(handle)
    assert ids(retained, "agent_probe") == ["agent_probe-1"]
    assert ids(retained, "fixture") == ["fixture-1"]
    assert {:ok, fill} = Recorder.fill(handle)
    assert %{retained_events: 2, reserved_events: 4, evicted: 0} = fill.sources["other"]
    assert Map.keys(fill.sources) == ["logger", "other"]
  end

  test "protected entries keep their precedence over every source's normal entries" do
    handle =
      start_recorder(
        max_events: 4,
        source_shares: %{"logger" => 50, "telemetry" => 50},
        other_share: 0,
        post_trigger_ms: 0
      )

    assert :ok = Recorder.record(handle, event("telemetry", 1))
    assert :ok = Recorder.record(handle, event("telemetry", 2))
    assert :ok = Recorder.record(handle, event("logger", 1, kind: "process_crashed"))
    assert :ok = Recorder.record(handle, event("logger", 2, kind: "process_crashed"))

    # A normal Logger write may evict neither protected entries nor Telemetry
    # within its share.
    assert {:dropped, :priority_protected} = Recorder.record(handle, event("logger", 3))

    # A protected write outranks every normal entry, after its own source's
    # and those over their share.
    assert :ok = Recorder.record(handle, event("logger", 4, kind: "process_crashed"))
    retained = read_all(handle)
    assert ids(retained, "telemetry") == ["telemetry-2"]
    assert ids(retained, "logger") == ids_of("logger", [1, 2, 4])

    # A protected Telemetry write within its share takes its own normal entry
    # when no source over its share has one...
    assert :ok = Recorder.record(handle, event("telemetry", 3, kind: "process_crashed"))
    assert ids(read_all(handle), "telemetry") == ["telemetry-3"]

    # ...and then the oldest protected entry of a source over its share.
    assert :ok = Recorder.record(handle, event("telemetry", 4, kind: "process_crashed"))
    assert ids(read_all(handle), "logger") == ids_of("logger", [2, 4])

    # A protected write over its own share takes its own oldest protected entry.
    assert {:ok, _freeze} = Recorder.freeze(handle, event("logger", 5, kind: "invariant_failed"))
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    assert snapshot.events |> Enum.map(& &1.event.id) |> Enum.sort() ==
             Enum.sort(["logger-4", "logger-5", "telemetry-3", "telemetry-4"])

    assert {:ok, fill} = Recorder.fill(handle)
    assert fill.sources["telemetry"].evicted == 2
    assert fill.sources["logger"].evicted == 2
  end

  test "owner-death recovery rebuilds each source's usage from retained entries" do
    handle = start_recorder(max_events: 20, source_shares: @shares, other_share: 0)

    for sequence <- 1..3, do: assert(:ok = Recorder.record(handle, event("logger", sequence)))
    for sequence <- 1..2, do: assert(:ok = Recorder.record(handle, event("poller", sequence)))
    assert {:ok, before} = Recorder.fill(handle)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        claim_lock(handle)
        # A holder that dies mid-write leaves the usage it was updating wrong.
        [{:state, state}] = :ets.lookup(handle.control, :state)
        true = :ets.insert(handle.control, {:state, %{state | sources: %{}}})
        send(parent, :partial_write_installed)
      end)

    assert_receive :partial_write_installed, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = Recorder.record(handle, event("telemetry", 1))

    assert {:ok, fill} = Recorder.fill(handle)
    assert fill.sources["logger"] == before.sources["logger"]
    assert fill.sources["poller"] == before.sources["poller"]
    assert %{retained_events: 1} = fill.sources["telemetry"]
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.recovered_owner_death == 1
  end

  # An eviction was attributed to its source only in
  # the writer's state, written after the new entry, so a writer killed in
  # between left the global `evicted` count at 1 and every source's at 0.
  test "a writer killed after evicting keeps the eviction attributed to its source" do
    gate = :atomics.new(1, [])
    parent = self()

    clock = fn ->
      if :atomics.get(gate, 1) == 1 do
        :atomics.put(gate, 1, 0)
        send(parent, {:evicted_and_paused, self()})
        receive do: (:never -> :ok)
      end

      System.monotonic_time(:microsecond)
    end

    handle =
      start_recorder(
        max_events: 2,
        source_shares: %{"logger" => 50, "poller" => 50},
        other_share: 0,
        clock: clock
      )

    assert :ok = Recorder.record(handle, event("logger", 1))
    assert :ok = Recorder.record(handle, event("poller", 1))

    # A protected Logger write over its share evicts its own normal entry,
    # then reads the clock for the new entry's time, where it is paused.
    :atomics.put(gate, 1, 1)

    {pid, monitor} =
      spawn_monitor(fn ->
        Recorder.record(handle, event("logger", 2, kind: "process_crashed"))
      end)

    assert_receive {:evicted_and_paused, ^pid}, 1_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    assert :ok = Recorder.record(handle, event("telemetry", 1))
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.recovered_owner_death == 1
    assert status.counters.evicted == 1
    assert %{evicted: 1, retained_events: 0} = status.sources["logger"]
    assert %{evicted: 0, retained_events: 1} = status.sources["poller"]

    total = status.sources |> Map.values() |> Enum.map(& &1.evicted) |> Enum.sum()
    assert total == status.counters.evicted
  end

  # The entry was deleted, then the total and the
  # source counts were bumped one after another, so a writer killed between
  # them left the total at 1 and every source at 0. Each eviction is now one
  # counter update, made before the deletion, and the total is the sum of
  # the sources. Each writer must really be evicting
  # when it is killed, so every round waits until its writer has filled the
  # Recorder and evicted, and the test asserts the evictions. Where a kill
  # lands is not controlled; the next test pins the boundary itself.
  test "writers killed while evicting never leave an eviction uncounted" do
    handle =
      start_recorder(
        max_events: 4,
        source_shares: %{"logger" => 50, "poller" => 50},
        other_share: 0
      )

    parent = self()

    for round <- 1..200 do
      {pid, monitor} =
        spawn_monitor(fn ->
          for sequence <- 1..100_000 do
            source = if rem(sequence, 3) == 0, do: "poller", else: "logger"
            :ok = Recorder.record(handle, event(source, round * 1_000_000 + sequence))
            if sequence == 5, do: send(parent, {:evicting, self()})
          end
        end)

      assert_receive {:evicting, ^pid}, 5_000
      spin(:rand.uniform(2_000))
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    end

    # A Logger write, which always has its own entries to evict, triggers
    # recovery of a lock left by the last kill.
    assert :ok = Recorder.record(handle, event("logger", 999_999_999))
    assert {:ok, status} = Recorder.status(handle)
    # Every round's writer recorded at least 5 events into 4 slots, so it
    # evicted at least once before it could be killed.
    gone = status.next_receipt - status.retained_count
    assert gone >= 200
    # Receipts are consecutive and admission losses get none, so every
    # receipt no longer retained was evicted and counted.
    assert status.counters.evicted >= gone

    total = status.sources |> Map.values() |> Enum.map(& &1.evicted) |> Enum.sum()
    assert total == status.counters.evicted
  end

  # The boundary itself, which a kill cannot hit deterministically: a holder
  # that counted an eviction and died before deleting the entry. The count
  # stays, the entry stays retained, and the counts overstate the evictions
  # by one, as documented, while the total still equals the sum of sources.
  test "a holder that counted an eviction and died before deleting it overcounts by one" do
    handle =
      start_recorder(
        max_events: 2,
        source_shares: %{"logger" => 50, "poller" => 50},
        other_share: 0
      )

    assert :ok = Recorder.record(handle, event("logger", 1))
    assert :ok = Recorder.record(handle, event("poller", 1))
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        claim_lock(handle)
        index = Map.fetch!(handle.config.group_indexes, "logger")
        :counters.add(handle.source_evictions, index, 1)
        send(parent, :counted_not_deleted)
      end)

    assert_receive :counted_not_deleted, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000

    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.recovered_owner_death == 1
    assert status.retained_count == 2
    assert %{evicted: 1, retained_events: 1} = status.sources["logger"]
    assert status.counters.evicted == 1
    assert status.next_receipt - status.retained_count == 0
  end

  defp spin(0), do: :ok
  defp spin(n), do: spin(n - 1)

  test "fill reports each source's share, reservation, usage, and evictions" do
    handle = start_recorder(max_events: 100, max_bytes: 100_000)
    assert :ok = Recorder.record(handle, event("logger", 1))

    assert {:ok, fill} = Recorder.fill(handle)

    assert Map.keys(fill.sources) ==
             Enum.sort(["other" | Map.keys(Config.default_source_shares())])

    assert %{
             share_percent: 25,
             reserved_events: 25,
             reserved_bytes: 25_000,
             retained_events: 1,
             retained_bytes: bytes,
             evicted: 0
           } = fill.sources["logger"]

    assert bytes == fill.retained_bytes
    assert fill.sources["other"].share_percent == Config.default_other_share()
    assert is_integer(fill.memory_bytes) and fill.memory_bytes > bytes
  end

  test "rejects malformed and oversubscribed shares" do
    classification = Insider.TestRecorderClassification.binding()

    for options <- [
          [source_shares: %{"logger" => 60, "telemetry" => 41}, other_share: 0],
          [source_shares: %{"logger" => 96}],
          [source_shares: %{"logger" => -1}],
          [source_shares: %{"logger" => 101}, other_share: 0],
          [source_shares: %{"logger" => 1.5}],
          [source_shares: %{"other" => 5}],
          [source_shares: %{"" => 5}],
          [source_shares: %{logger: 5}],
          [source_shares: %{String.duplicate("s", 65) => 5}],
          [source_shares: Map.new(1..17, &{"source#{&1}", 1})],
          [source_shares: [{"logger", 5}]],
          [other_share: -1],
          [other_share: 101],
          [other_share: :all]
        ] do
      assert {:error, :invalid_options} =
               Recorder.start_link([{:classification, classification} | options]),
             inspect(options)
    end

    assert {:ok, config} =
             Config.new(
               classification: classification,
               source_shares: %{"logger" => 100},
               other_share: 0
             )

    assert Config.group(config, "logger") == "logger"
    assert Config.group(config, "telemetry") == "other"
    assert Config.group(config, "other") == "other"
  end

  defp start_recorder(options) do
    options =
      options
      |> Keyword.put_new(:classification, Insider.TestRecorderClassification.binding())
      |> Keyword.put_new(:rate_limit_count, 10_000)

    child = %{id: make_ref(), start: {Recorder, :start_link, [options]}}
    pid = start_supervised!(child)
    assert {:ok, handle} = Recorder.handle(pid)
    handle
  end

  defp read_all(handle, cursor \\ 0, entries \\ []) do
    assert {:ok, read} = Recorder.read_since(handle, cursor, limit: 1_000)

    case read.entries do
      [] -> entries
      more -> read_all(handle, read.next_cursor, entries ++ more)
    end
  end

  defp ids(entries, source),
    do: for(%{event: %{"source" => ^source, "id" => id}} <- entries, do: id)

  defp ids_of(source, sequences), do: Enum.map(sequences, &"#{source}-#{&1}")

  defp claim_lock(handle) do
    ticket = :ets.update_counter(handle.control, :tickets, 1)
    [{:lock, ^ticket, nil, _since, dirty}] = :ets.lookup(handle.control, :lock)
    now = System.monotonic_time(:millisecond)
    true = :ets.insert(handle.control, {:lock, ticket, self(), now, dirty})
  end

  defp event(source, sequence, overrides \\ []) do
    Event.new!(
      Keyword.merge(
        [
          id: "#{source}-#{sequence}",
          node: "node-test",
          boot_id: "boot-test",
          source: source,
          kind: "runtime_signal",
          severity: :info,
          monotonic_time: sequence,
          clock_id: "clock-test",
          source_instance_id: source <> "-test",
          source_sequence: sequence,
          wall_time: nil,
          subject: nil,
          causality: %{
            trace_id: nil,
            span_id: nil,
            parent_event_id: nil,
            logical_operation_id: nil,
            process_generation: nil
          },
          attributes: %{},
          payload: nil,
          authority: "policy-test",
          redactions: [],
          extensions: %{}
        ],
        overrides
      )
    )
  end
end
