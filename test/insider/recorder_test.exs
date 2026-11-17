defmodule Insider.RecorderTest do
  use ExUnit.Case, async: true

  alias Insider.Event
  alias Insider.Recorder
  alias Insider.Recorder.Classification

  test "classification helpers reject malformed values at every public boundary" do
    {sensitivity, policy} = Insider.TestRecorderClassification.binding()
    assert {:ok, binding} = Classification.binding(sensitivity, policy)

    assert {:error, :invalid_classification} = Classification.binding(:unknown, policy)
    refute Classification.valid_binding?(:not_a_binding)
    refute Classification.valid_binding?(Map.put(binding, :unexpected, true))
    assert {:error, :invalid_classification} = Classification.bind(:event, <<>>, binding)
    assert {:error, :invalid_classification} = Classification.validate(:value, :event, <<>>)
    assert {:error, :invalid_classification} = Classification.decode_map(:value, :event)
    assert {:error, :invalid_classification} = Classification.to_wire_map(:value, :event)
    assert {:error, :invalid_classification} = Classification.canonical_binary(:value, :event)
  end

  test "rejects invalid and unbounded configuration" do
    classification = Insider.TestRecorderClassification.binding()

    assert {:error, :invalid_options} = Recorder.start_link([])
    assert {:error, :invalid_options} = Recorder.start_link(classification: :forged)

    assert {:error, :invalid_options} =
             Recorder.start_link(classification: classification, max_events: 0)

    assert {:error, :invalid_options} =
             Recorder.start_link(classification: classification, max_rate_keys: 4_097)

    assert {:error, :invalid_options} =
             Recorder.start_link(classification: classification, unknown: true)

    for {option, value} <- [
          admission_stall_ms: -1,
          admission_stall_ms: 5_001,
          admission_stall_ms: :infinity,
          admission_wait_ms: 1_000,
          max_admission_waiters: 64
        ] do
      assert {:error, :invalid_options} =
               Recorder.start_link([{:classification, classification}, {option, value}])
    end

    assert {:error, :invalid_options} =
             Recorder.start_link(
               classification: classification,
               max_events: 2,
               max_events: 3
             )

    assert {:error, :invalid_options} = Recorder.start_link(:invalid)
  end

  test "normal evidence is circular within the event bound" do
    handle = start_recorder(max_events: 3, post_trigger_ms: 0)

    for sequence <- 1..4, do: assert(:ok = Recorder.record(handle, event(sequence)))

    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 3
    assert status.counters.evicted == 1

    assert {:ok, _freeze_id} = Recorder.freeze(handle, event(4))
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert Enum.map(snapshot.events, & &1.event.id) == ~w(event-2 event-3 event-4)
    assert snapshot.retained_count == 3
    assert snapshot.retained_bytes <= handle.config.max_bytes
  end

  test "normal evidence never displaces protected evidence" do
    handle = start_recorder(max_events: 2, post_trigger_ms: 0)

    assert :ok = Recorder.record(handle, event(1, kind: "process_crashed"))
    assert :ok = Recorder.record(handle, event(2))
    assert :ok = Recorder.record(handle, event(3))
    assert {:ok, _freeze_id} = Recorder.freeze(handle, event(4, kind: "invariant_failed"))
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    assert Enum.map(snapshot.events, &{&1.event.id, &1.priority}) == [
             {"event-1", :protected},
             {"event-4", :protected}
           ]

    assert snapshot.counters.evicted == 2
  end

  test "normal evidence is shed when only protected evidence can make room" do
    handle = start_recorder(max_events: 1)

    assert :ok = Recorder.record(handle, event(1, kind: "process_crashed"))
    assert {:dropped, :priority_protected} = Recorder.record(handle, event(2))
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 1
    assert status.counters.priority_protected == 1
  end

  test "canonical byte accounting never exceeds its hard logical bound" do
    first = event(1)
    {:ok, bytes} = Event.canonical_binary(first)
    {sensitivity, policy} = Insider.TestRecorderClassification.binding()
    {:ok, classification} = Classification.new(first, sensitivity, policy)
    {:ok, sidecar} = Classification.canonical_binary(classification, first)
    aggregate_bound = byte_size(bytes) + byte_size(sidecar)
    handle = start_recorder(max_events: 4, max_bytes: aggregate_bound)

    assert :ok = Recorder.record(handle, first)
    assert :ok = Recorder.record(handle, event(2))
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 1
    assert status.storage_bytes <= aggregate_bound
    assert status.retained_bytes <= byte_size(bytes)

    too_small = start_recorder(max_bytes: aggregate_bound - 1)
    assert {:dropped, :oversized} = Recorder.record(too_small, first)
  end

  test "rate and rate-key state are bounded on recorder-local time" do
    {clock, now} = clock(1_000)

    handle =
      start_recorder(
        clock: clock,
        rate_limit_count: 1,
        rate_window_ms: 10,
        max_rate_keys: 2
      )

    assert :ok = Recorder.record(handle, event(1))
    assert {:dropped, :rate_limited} = Recorder.record(handle, event(2))

    :atomics.put(now, 1, 11_000)
    assert :ok = Recorder.record(handle, event(3))

    assert {:dropped, :rate_key_capacity} =
             Recorder.record(handle, event(4, source: "other", kind: "other.event"))

    assert {:ok, status} = Recorder.status(handle)
    assert status.rate_keys == 2
    assert status.counters.rate_limited == 1
    assert status.counters.rate_key_capacity == 1
  end

  test "rate expiry removes only stale source and kind keys" do
    {clock, now} = clock(1_000)

    handle =
      start_recorder(clock: clock, rate_limit_count: 1, rate_window_ms: 10, max_rate_keys: 4)

    assert :ok = Recorder.record(handle, event(1, source: "early", kind: "early.signal"))

    :atomics.put(now, 1, 5_000)
    assert :ok = Recorder.record(handle, event(2, source: "late", kind: "late.signal"))

    :atomics.put(now, 1, 11_000)

    assert {:dropped, :rate_limited} =
             Recorder.record(handle, event(3, source: "late", kind: "late.signal"))

    assert {:ok, status} = Recorder.status(handle)
    assert status.rate_keys == 2
    assert :ok = Recorder.record(handle, event(4, source: "new", kind: "new.signal"))

    assert {:ok, status} = Recorder.status(handle)
    assert status.rate_keys == 4
  end

  test "protected evidence bypasses source and kind rate shedding" do
    handle = start_recorder(rate_limit_count: 1)

    assert :ok = Recorder.record(handle, event(1, source: "agent", kind: "agent_command"))
    assert :ok = Recorder.record(handle, event(2, source: "agent", kind: "agent_command"))
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 2
    assert status.rate_keys == 0
  end

  test "duplicate IDs are idempotent and conflicting bytes are visible" do
    handle = start_recorder()
    original = event(1)

    assert :ok = Recorder.record(handle, original)
    assert :ok = Recorder.record(handle, original)

    assert {:dropped, :event_id_conflict} =
             Recorder.record(handle, %{original | payload: %{"changed" => true}})

    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 1
    assert status.counters.duplicate == 1
    assert status.counters.event_id_conflict == 1
  end

  test "trusted classification is bound outside Event fields and counted separately" do
    forged_claim = %{
      "attacker.classification" => %{
        "sensitivity" => "public",
        "policy_fingerprint" => String.duplicate("0", 64)
      }
    }

    recorded = event(1, extensions: forged_claim)
    handle = start_recorder(post_trigger_ms: 0)

    assert :ok = Recorder.record(handle, recorded)
    assert {:ok, _freeze_id} = Recorder.freeze(handle, recorded)
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert [entry] = snapshot.events
    assert entry.event.extensions == forged_claim
    assert entry.classification.sensitivity == :internal
    assert entry.classification.event_id == recorded.id
    refute entry.classification.policy_fingerprint == String.duplicate("0", 64)

    {:ok, canonical} = Event.canonical_binary(recorded)
    assert snapshot.retained_bytes == byte_size(canonical)
    assert snapshot.classification_bytes > 0

    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_bytes == snapshot.retained_bytes
    assert status.retained_classification_bytes == snapshot.classification_bytes
    assert status.storage_bytes == snapshot.retained_bytes + snapshot.classification_bytes
    assert status.storage_bytes <= handle.config.max_bytes
  end

  test "duplicate trust must match the canonical event and classification" do
    handle = start_recorder()
    recorded = event(1)
    assert :ok = Recorder.record(handle, recorded)

    [{event_id, receipt, canonical, classification}] = :ets.lookup(handle.ids, recorded.id)
    {sensitivity, _policy} = Insider.TestRecorderClassification.binding()

    {:ok, other_policy} =
      Insider.Redaction.Policy.new(
        id: "other-test-policy",
        maximum_sensitivity: :internal,
        rules: []
      )

    {:ok, other} = Classification.new(recorded, sensitivity, other_policy)
    true = :ets.insert(handle.ids, {event_id, receipt, canonical, other})

    assert {:dropped, :event_id_conflict} = Recorder.record(handle, recorded)
    assert classification != other
  end

  test "classification bytes participate in the hard aggregate storage bound" do
    recorded = event(1)
    {sensitivity, policy} = Insider.TestRecorderClassification.binding()
    {:ok, classification} = Classification.new(recorded, sensitivity, policy)
    {:ok, event_bytes} = Event.canonical_binary(recorded)
    {:ok, classification_bytes} = Classification.canonical_binary(classification, recorded)

    handle =
      start_recorder(max_bytes: byte_size(event_bytes) + byte_size(classification_bytes) - 1)

    assert {:dropped, :oversized} = Recorder.record(handle, recorded)
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 0
    assert status.counters.oversized == 1
  end

  test "classification rejects hostile fields before fingerprinting them" do
    recorded = event(1)
    {sensitivity, policy} = Insider.TestRecorderClassification.binding()
    {:ok, classification} = Classification.new(recorded, sensitivity, policy)
    {:ok, canonical} = Event.canonical_binary(recorded)
    oversized = String.duplicate("x", 1_048_576)

    for hostile <- [
          %{classification | policy_id: oversized},
          %{classification | policy_fingerprint: oversized},
          %{classification | fingerprint: oversized}
        ] do
      assert {:error, :invalid_classification} =
               Classification.validate(hostile, recorded, canonical)
    end
  end

  test "malformed and forged events are rejected without entering storage" do
    handle = start_recorder()
    valid = event(1)

    for invalid <- [
          %{},
          {:event, self()},
          %{valid | payload: fn -> :secret end},
          %{valid | source: <<255>>},
          %{valid | attributes: %{"secret" => String.duplicate("x", 20_000)}}
        ] do
      assert {:dropped, :invalid_event} = Recorder.record(handle, invalid)
    end

    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 0
    assert status.index_entries == 0
    assert status.counters.invalid_event == 5
  end

  test "classification failures are terminal and independently accounted" do
    handle = start_recorder(post_trigger_ms: 0)
    forged_binding = %{handle.config.classification | policy_id: <<255>>}
    forged_handle = %{handle | config: %{handle.config | classification: forged_binding}}

    assert {:dropped, :classification_failed} = Recorder.record(forged_handle, event(1))

    assert {:error, :classification_failed} =
             Recorder.freeze(forged_handle, event(2, kind: "invariant_failed"))

    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 0
    assert status.counters.offered == 2
    assert status.counters.classification_failed == 2

    trigger = event(3, kind: "invariant_failed")
    assert {:ok, _freeze_id} = Recorder.freeze(handle, trigger)
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert snapshot.counters.classification_failed == 2
    assert :dropped_evidence in snapshot.gaps
    assert snapshot.completeness == :incomplete
  end

  test "freeze uses recorder time and seals an immutable bounded window" do
    {clock, now} = clock(1_000)
    handle = start_recorder(clock: clock, pre_trigger_ms: 1, post_trigger_ms: 2)

    assert :ok = Recorder.record(handle, event(1))
    :atomics.put(now, 1, 2_000)
    assert {:ok, freeze_id} = Recorder.freeze(handle, event(2, kind: "invariant_failed"))
    assert {:pending, %{freeze_id: ^freeze_id}} = Recorder.snapshot(handle)

    :atomics.put(now, 1, 3_999)
    assert :ok = Recorder.record(handle, event(3))
    :atomics.put(now, 1, 4_000)
    assert {:dropped, :frozen} = Recorder.record(handle, event(4))
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert snapshot.freeze_status == :complete
    assert Enum.map(snapshot.events, & &1.event.id) == ~w(event-1 event-2 event-3)

    assert {:dropped, :frozen} = Recorder.record(handle, event(5))
    assert {:ok, after_close} = Recorder.snapshot(handle)
    assert snapshot == after_close
    refute :dropped_evidence in after_close.gaps
  end

  test "a zero-length window always contains its trigger" do
    handle = start_recorder(clock: ticking_clock(), pre_trigger_ms: 0, post_trigger_ms: 0)
    trigger = event(1, kind: "invariant_failed")

    assert {:ok, _freeze_id} = Recorder.freeze(handle, trigger)
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert Enum.map(snapshot.events, & &1.event.id) == [trigger.id]
    assert snapshot.retained_count == 1
  end

  test "a previously normal trigger is promoted and pinned under post-trigger pressure" do
    {clock, now} = clock(1_000)
    handle = start_recorder(clock: clock, max_events: 2, post_trigger_ms: 10)
    trigger = event(1)

    assert :ok = Recorder.record(handle, trigger)
    assert {:ok, freeze_id} = Recorder.freeze(handle, trigger)
    assert :ok = Recorder.record(handle, event(2))
    assert :ok = Recorder.record(handle, event(3))
    assert :ok = Recorder.record(handle, event(4, kind: "process_crashed"))
    assert {:ok, ^freeze_id} = Recorder.freeze(handle, trigger)

    :atomics.put(now, 1, 11_000)
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert Enum.map(snapshot.events, & &1.event.id) == [trigger.id, "event-4"]
    assert snapshot.opening_receipt == hd(snapshot.events).receipt
  end

  test "first freeze wins and repeating its trigger is idempotent" do
    handle = start_recorder(post_trigger_ms: 0)
    trigger = event(1, kind: "invariant_failed")

    assert {:ok, freeze_id} = Recorder.freeze(handle, trigger)
    assert {:ok, ^freeze_id} = Recorder.freeze(handle, trigger)

    assert {:error, :already_frozen} =
             Recorder.freeze(handle, event(2, kind: "process_crashed"))

    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.offered == 3
    assert status.counters.accepted == 1
    assert status.counters.freeze_idempotent == 1
    assert status.counters.already_frozen == 1
  end

  test "a repeated trigger ID with different canonical bytes is a conflict" do
    handle = start_recorder(post_trigger_ms: 0)
    trigger = event(1, kind: "invariant_failed")

    assert {:ok, _freeze_id} = Recorder.freeze(handle, trigger)

    assert {:error, :event_id_conflict} =
             Recorder.freeze(handle, %{trigger | payload: %{"changed" => true}})

    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.event_id_conflict == 1
    assert status.counters.freeze_idempotent == 0
  end

  test "known pressure and missing prehistory make completeness explicit" do
    {clock, _now} = clock(10_000)
    handle = start_recorder(clock: clock, max_events: 1, pre_trigger_ms: 20, post_trigger_ms: 0)

    assert :ok = Recorder.record(handle, event(1))
    assert {:ok, _freeze_id} = Recorder.freeze(handle, event(2, kind: "invariant_failed"))
    assert {:ok, snapshot} = Recorder.snapshot(handle)
    assert snapshot.completeness == :incomplete
    assert :evicted_evidence in snapshot.gaps
    assert :prehistory_unavailable in snapshot.gaps
  end

  test "producer calls do not queue behind a suspended recorder" do
    handle = start_recorder(max_events: 8)
    :sys.suspend(handle.pid)

    tasks =
      for sequence <- 1..100 do
        Task.async(fn -> Recorder.record(handle, event(sequence)) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 1_000))
    assert Enum.all?(results, &(&1 == :ok or match?({:dropped, _reason}, &1)))
    assert {:message_queue_len, 0} = Process.info(handle.pid, :message_queue_len)

    :sys.resume(handle.pid)
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count <= 8
    assert status.retained_bytes <= handle.config.max_bytes
  end

  test "a producer killed in its critical section cannot strand admission" do
    handle = start_recorder(clock: blocking_clock(self()))

    {pid, monitor} =
      spawn_monitor(fn -> Recorder.record(handle, event(1)) end)

    assert_receive {:producer_inside_lock, ^pid}, 1_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    assert :ok = Recorder.record(handle, event(2))
  end

  test "owner-death recovery rebuilds partial derived state from retained entries" do
    handle = start_recorder()
    first = event(1)
    partial = event(2)
    {:ok, canonical} = Event.canonical_binary(partial)
    {sensitivity, policy} = Insider.TestRecorderClassification.binding()
    {:ok, classification} = Classification.new(partial, sensitivity, policy)
    {:ok, classification_binary} = Classification.canonical_binary(classification, partial)
    parent = self()

    assert :ok = Recorder.record(handle, first)

    {pid, monitor} =
      spawn_monitor(fn ->
        claim_lock(handle)

        true =
          :ets.insert(handle.entries, {
            2,
            2,
            :normal,
            byte_size(canonical) + byte_size(classification_binary),
            canonical,
            classification,
            partial.id,
            [
              {:subject, partial.subject},
              {:logical_operation, partial.causality.logical_operation_id},
              {:trace, partial.causality.trace_id}
            ]
          })

        send(parent, :partial_write_installed)
      end)

    assert_receive :partial_write_installed, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = Recorder.record(handle, event(3))
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count == 3
    assert status.index_entries == 9
    assert status.counters.recovered_owner_death == 1
    assert status.storage_bytes == status.retained_bytes + status.retained_classification_bytes
  end

  test "owner-death recovery preserves conservative active rate state" do
    handle = start_recorder(rate_limit_count: 1)

    assert :ok = Recorder.record(handle, event(1))
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        claim_lock(handle)
        send(parent, :stale_rate_lock_installed)
      end)

    assert_receive :stale_rate_lock_installed, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert {:dropped, :rate_limited} = Recorder.record(handle, event(2))
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.recovered_owner_death == 1
    assert status.counters.rate_limited == 1
  end

  test "recorder loss cannot crash or block an unrelated host" do
    {:ok, host} = Agent.start_link(fn -> :healthy end)
    Process.unlink(host)
    handle = start_recorder()
    Process.unlink(handle.pid)
    monitor = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)

    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 1_000
    assert :undefined == :ets.info(handle.entries)
    assert :undefined == :ets.info(handle.control)
    assert {:dropped, :unavailable} = Recorder.record(handle, event(1))
    assert Agent.get(host, & &1) == :healthy
    Agent.stop(host)
  end

  test "concurrent pressure preserves count byte and index cardinality bounds" do
    handle = start_recorder(max_events: 20, max_rate_keys: 128, rate_limit_count: 1_000)

    results =
      1..500
      |> Task.async_stream(
        fn sequence -> Recorder.record(handle, event(sequence)) end,
        max_concurrency: 32,
        ordered: false,
        timeout: 1_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _result}, &1))
    assert {:ok, status} = Recorder.status(handle)
    assert status.retained_count <= 20
    assert status.retained_bytes <= handle.config.max_bytes
    assert status.index_entries <= status.retained_count * 4
    assert status.rate_keys <= 128
    assert status.counters.offered == 500
    assert status.counters.contended == 0

    accounted =
      status.counters
      |> Map.drop([:offered, :accepted, :evicted, :recovered_owner_death])
      |> Map.values()
      |> Enum.sum()

    assert status.counters.offered == status.counters.accepted + accounted
  end

  # Two writers admitting at the same moment used to lose one write
  # to the admission lock as `:contended`.
  test "concurrent writers at sustained load lose nothing to the admission lock" do
    writers = 8
    per_writer = 1_000
    total = writers * per_writer

    handle =
      start_recorder(
        max_events: total,
        max_bytes: 16 * 1_024 * 1_024,
        rate_limit_count: total
      )

    batches =
      for writer <- 1..writers do
        for sequence <- 1..per_writer do
          event(sequence, id: "writer-#{writer}-#{sequence}", source_instance_id: "w#{writer}")
        end
      end

    parent = self()
    go = make_ref()

    tasks =
      Enum.map(batches, fn batch ->
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (^go -> :ok)
          Enum.map(batch, &Recorder.record(handle, &1))
        end)
      end)

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid}, 5_000)
    for %Task{pid: pid} <- tasks, do: send(pid, go)
    results = Task.await_many(tasks, 60_000)

    assert results |> List.flatten() |> Enum.frequencies() == %{ok: total}
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.contended == 0
    assert status.counters.offered == total
    assert status.counters.accepted == total
    assert %{retained_count: ^total, next_receipt: ^total} = status

    # Receipts are consecutive, and each writer's events keep its own order.
    entries = read_all(handle, 0, [])
    assert Enum.map(entries, & &1.receipt) == Enum.to_list(1..total)

    for {writer, ids} <-
          Enum.group_by(entries, & &1.event["source_instance_id"], & &1.event["id"]) do
      "w" <> index = writer
      assert ids == Enum.map(1..per_writer, &"writer-#{index}-#{&1}")
    end
  end

  test "a writer that finds the lock held waits for its release and is admitted" do
    handle = start_recorder(clock: blocking_clock(self()))
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000
    assert holder_pid == holder.pid

    waiter = Task.async(fn -> with_mailbox(fn -> Recorder.record(handle, event(2)) end) end)
    await_queued(handle, waiter.pid)
    send(holder_pid, :release_clock)

    assert :ok = Task.await(holder, 1_000)
    assert {:ok, []} = Task.await(waiter, 1_000)
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-2)
    assert read.counters.contended == 0
    assert ticket_rows(handle) == 0
  end

  # The next writer in line used to spin on `:erlang.yield/0` until its turn.
  # A spinning process is always runnable, so its scheduler never sleeps or
  # takes work from another; on 2-scheduler CI runners the load harness's
  # overload phase then missed a 10 ms tick. The window is the measurement:
  # the waiter's reductions while the holder keeps the lock for 100 ms. A
  # waiter that sleeps between 1 ms polls spends a few thousand; one that
  # spins spends far more.
  test "a writer next in line for the lock sleeps until its turn instead of spinning" do
    handle = start_recorder(clock: blocking_clock(self()))
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    waiter = Task.async(fn -> with_mailbox(fn -> Recorder.record(handle, event(2)) end) end)
    await_queued(handle, waiter.pid)
    {:reductions, before} = Process.info(waiter.pid, :reductions)
    receive after: (100 -> :ok)
    {:reductions, waited} = Process.info(waiter.pid, :reductions)
    send(holder_pid, :release_clock)

    assert :ok = Task.await(holder, 1_000)
    assert {:ok, []} = Task.await(waiter, 1_000)
    assert waited - before < 20_000
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-2)
  end

  test "queued writers are admitted in arrival order" do
    handle = start_recorder(clock: blocking_clock(self()))
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    waiters =
      for sequence <- 2..5 do
        waiter =
          Task.async(fn -> with_mailbox(fn -> Recorder.record(handle, event(sequence)) end) end)

        await_queued(handle, waiter.pid)
        waiter
      end

    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)
    assert Task.await_many(waiters, 1_000) == List.duplicate({:ok, []}, 4)

    assert {:ok, read} = Recorder.read_since(handle, 0)

    assert Enum.map(read.entries, &{&1.receipt, &1.event["id"]}) ==
             Enum.map(1..5, &{&1, "event-#{&1}"})
  end

  test "a writer waiting on a holder that dies takes the lock over and is admitted" do
    handle = start_recorder(clock: blocking_clock(self()))
    {holder, monitor} = spawn_monitor(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, ^holder}, 1_000

    waiter = Task.async(fn -> Recorder.record(handle, event(2)) end)
    await_queued(handle, waiter.pid)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000

    assert :ok = Task.await(waiter, 1_000)
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.recovered_owner_death == 1
    assert status.counters.contended == 0
    assert status.retained_count == 1
  end

  test "a queued writer that dies does not stall the writers behind it" do
    handle = start_recorder(clock: blocking_clock(self()))
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    {dead, monitor} = spawn_monitor(fn -> Recorder.record(handle, event(2)) end)
    await_queued(handle, dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :killed}, 1_000

    waiter = Task.async(fn -> with_mailbox(fn -> Recorder.record(handle, event(3)) end) end)
    await_queued(handle, waiter.pid)
    send(holder_pid, :release_clock)

    assert :ok = Task.await(holder, 1_000)
    assert {:ok, []} = Task.await(waiter, 1_000)
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-3)
    assert ticket_rows(handle) == 0
  end

  test "a writer killed between taking its ticket and queueing is skipped after the stall bound" do
    handle = start_recorder(admission_stall_ms: 20)

    # Ticket 1 is taken and never claimed or registered, as by a writer
    # killed right after taking it.
    assert 1 == :ets.update_counter(handle.control, :tickets, 1)

    assert :ok = Recorder.record(handle, event(2))
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-2)
    assert read.counters.contended == 0
    assert ticket_rows(handle) == 0
  end

  test "a lock held past the stall bound is overdue until its holder releases it" do
    handle = start_recorder(clock: blocking_clock(self()), admission_stall_ms: 20)

    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    # The first caller waits until the holder has held the lock for the
    # stall bound; later callers find it overdue and give up at once without
    # taking a ticket. Each write is a counted loss, and no wake is left in
    # the caller's mailbox.
    assert {:dropped, :contended} = Recorder.record(handle, event(2))
    assert {:dropped, :contended} = Recorder.record(handle, event(3))
    assert {:error, :busy} = Recorder.freeze(handle, event(4, kind: "invariant_failed"))
    assert {:error, :busy} = Recorder.status(handle)
    assert {:error, :busy} = Recorder.snapshot(handle)
    assert {:messages, []} = Process.info(self(), :messages)
    assert ticket_rows(handle) <= 1

    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)

    assert :ok = Recorder.record(handle, event(5))
    assert {:ok, status} = Recorder.status(handle)
    assert status.counters.contended == 3
    assert status.counters.offered == 5
    assert status.counters.accepted == 2
    assert status.retained_count == 2
    assert ticket_rows(handle) == 0
  end

  # Queue rows grew past their bound under
  # concurrent callers. Behind an overdue holder no caller takes a ticket,
  # so the queue holds at most the writers that were already waiting.
  test "concurrent callers behind an overdue holder add no queue rows" do
    handle = start_recorder(clock: blocking_clock(self()), admission_stall_ms: 20)
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    first = Task.async(fn -> Recorder.record(handle, event(2)) end)
    assert {:dropped, :contended} = Task.await(first, 1_000)
    rows = ticket_rows(handle)

    results =
      3..202
      |> Task.async_stream(&Recorder.record(handle, event(&1)), max_concurrency: 50)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [{:dropped, :contended}]
    assert ticket_rows(handle) == rows
    assert rows <= 1

    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)
  end

  # A waiter that had given up could still take
  # the lock and record. A waiter that gives up hands its turn on and never
  # records, and the next writer is not held up by its abandoned turn.
  test "a waiter that gave up never records and its turn passes on" do
    handle = start_recorder(clock: blocking_clock(self()), admission_stall_ms: 20)
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    gave_up = Task.async(fn -> Recorder.record(handle, event(2)) end)
    assert {:dropped, :contended} = Task.await(gave_up, 1_000)

    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)
    assert :ok = Recorder.record(handle, event(3))

    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-3)
    assert read.counters.contended == 1
    assert ticket_rows(handle) == 0
  end

  # A served turn whose live writer never claims
  # it (suspended after its predecessor released) let every later call take
  # a ticket and leave an abandoned registration behind it. Once that turn
  # is stalled, callers give up without registering.
  test "a stalled unclaimed turn of a live writer stops new registrations" do
    handle = start_recorder(clock: blocking_clock(self()), admission_stall_ms: 20)
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    queued = Task.async(fn -> Recorder.record(handle, event(2)) end)
    await_queued(handle, queued.pid)
    true = :erlang.suspend_process(queued.pid)
    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)
    assert [{:lock, _serving, nil, _since, _dirty}] = :ets.lookup(handle.control, :lock)

    assert {:dropped, :contended} = Recorder.record(handle, event(3))
    rows = ticket_rows(handle)

    for sequence <- 4..203 do
      assert {:dropped, :contended} = Recorder.record(handle, event(sequence))
    end

    assert ticket_rows(handle) == rows
    assert rows <= 2

    true = :erlang.resume_process(queued.pid)
    assert :ok = Task.await(queued, 1_000)
    assert :ok = Recorder.record(handle, event(204))
    assert ticket_rows(handle) == 0

    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-2 event-204)
  end

  # When the Recorder died during a wait, the
  # writer's wake alias stayed active after the call returned.
  test "a writer waiting when the recorder dies leaves no active wake alias" do
    handle = start_recorder(clock: blocking_clock(self()))
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000
    parent = self()

    waiter =
      spawn(fn ->
        result = Recorder.record(handle, event(2))
        send(parent, {:returned, self(), result})
        receive do: (:check -> send(parent, {:mailbox, Process.info(self(), :messages)}))
      end)

    await_queued(handle, waiter)
    [[reply]] = :ets.match(handle.control, {{:ticket, :_}, waiter, :"$1"})

    monitor = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 1_000
    assert_receive {:returned, ^waiter, {:dropped, :unavailable}}, 1_000

    # Messages from one sender arrive in order: had the alias stayed active,
    # :late would be in the mailbox when :check is handled.
    send(reply, {reply, :late})
    send(waiter, :check)
    assert_receive {:mailbox, {:messages, []}}, 1_000

    send(holder_pid, :release_clock)
    Task.await(holder, 1_000)
  end

  test "killed waiters are skipped by the next writer without a stall" do
    handle = start_recorder(clock: blocking_clock(self()), admission_stall_ms: 5_000)
    holder = Task.async(fn -> Recorder.record(handle, event(1)) end)
    assert_receive {:producer_inside_lock, holder_pid}, 1_000

    for sequence <- 2..4 do
      {pid, monitor} = spawn_monitor(fn -> Recorder.record(handle, event(sequence)) end)
      await_queued(handle, pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    end

    send(holder_pid, :release_clock)
    assert :ok = Task.await(holder, 1_000)

    # The stall bound is 5 s; the dead turns are skipped at once.
    writer = Task.async(fn -> Recorder.record(handle, event(5)) end)
    assert :ok = Task.await(writer, 1_000)
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-1 event-5)
    assert ticket_rows(handle) == 0
  end

  test "a cursor read after N events returns exactly those events in receipt order without a freeze" do
    handle = start_recorder()

    for sequence <- 1..5, do: assert(:ok = Recorder.record(handle, event(sequence)))

    assert {:error, :not_triggered} = Recorder.snapshot(handle)
    assert {:ok, read} = Recorder.read_since(handle, 0)
    assert Enum.map(read.entries, & &1.receipt) == [1, 2, 3, 4, 5]
    assert Enum.map(read.entries, & &1.event["id"]) == Enum.map(1..5, &"event-#{&1}")
    assert %{next_cursor: 5, next_receipt: 5, evicted: 0, truncated: false} = read
    assert hd(read.entries).event == Event.to_wire_map(event(1))

    assert {:ok, read} = Recorder.read_since(handle, 2)
    assert Enum.map(read.entries, & &1.event["id"]) == ~w(event-3 event-4 event-5)

    assert {:ok, %{entries: [], next_cursor: 5, evicted: 0, truncated: false}} =
             Recorder.read_since(handle, 5)
  end

  test "a cursor read is bounded by count and bytes and always makes progress" do
    handle = start_recorder()

    for sequence <- 1..5, do: assert(:ok = Recorder.record(handle, event(sequence)))

    assert {:ok, first} = Recorder.read_since(handle, 0, limit: 2)
    assert Enum.map(first.entries, & &1.receipt) == [1, 2]
    assert %{next_cursor: 2, truncated: true, truncated_by: :limit, evicted: 0} = first

    assert {:ok, rest} = Recorder.read_since(handle, first.next_cursor, limit: 10)
    assert Enum.map(rest.entries, & &1.receipt) == [3, 4, 5]
    assert %{next_cursor: 5, truncated: false, truncated_by: nil} = rest

    assert {:ok, one_byte} = Recorder.read_since(handle, 0, max_bytes: 1)
    assert Enum.map(one_byte.entries, & &1.receipt) == [1]
    assert %{next_cursor: 1, truncated: true, truncated_by: :max_bytes, evicted: 0} = one_byte
  end

  test "eviction between cursor reads is an exact receipt-range count" do
    handle = start_recorder(max_events: 3)

    for sequence <- 1..2, do: assert(:ok = Recorder.record(handle, event(sequence)))
    assert {:ok, %{next_cursor: 2, evicted: 0}} = Recorder.read_since(handle, 0)

    for sequence <- 3..7, do: assert(:ok = Recorder.record(handle, event(sequence)))

    assert {:ok, read} = Recorder.read_since(handle, 2)
    assert Enum.map(read.entries, & &1.receipt) == [5, 6, 7]
    assert %{next_cursor: 7, evicted: 2, truncated: false} = read
    assert read.counters.evicted == 4

    assert {:ok, %{entries: [], next_cursor: 7, evicted: 0}} = Recorder.read_since(handle, 7)
  end

  test "a cursor read rejects forged cursors and options and survives recorder loss" do
    handle = start_recorder()
    assert :ok = Recorder.record(handle, event(1))

    assert {:error, :invalid_cursor} = Recorder.read_since(handle, -1)
    assert {:error, :invalid_cursor} = Recorder.read_since(handle, 2)
    assert {:error, :invalid_cursor} = Recorder.read_since(handle, "1")
    assert {:error, :invalid_options} = Recorder.read_since(handle, 0, limit: 0)
    assert {:error, :invalid_options} = Recorder.read_since(handle, 0, max_bytes: 0)
    assert {:error, :invalid_options} = Recorder.read_since(handle, 0, unknown: true)
    assert {:error, :invalid_options} = Recorder.read_since(:handle, 0, [])

    Process.unlink(handle.pid)
    monitor = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 1_000
    assert {:error, :unavailable} = Recorder.read_since(handle, 0)
  end

  defp start_recorder(options \\ []) do
    options =
      Keyword.put_new(options, :classification, Insider.TestRecorderClassification.binding())

    child = %{id: make_ref(), start: {Recorder, :start_link, [options]}}
    pid = start_supervised!(child)
    assert {:ok, handle} = Recorder.handle(pid)
    handle
  end

  defp read_all(handle, cursor, entries) do
    assert {:ok, read} = Recorder.read_since(handle, cursor, limit: 1_000)

    case read.entries do
      [] -> entries
      more -> read_all(handle, read.next_cursor, entries ++ more)
    end
  end

  # A writer that finds the lock held joins the Recorder's wait queue. This
  # poll observes that row, so a test releases the holder only once the
  # writer is really waiting. It is bounded by time, not by iterations (a
  # tight loop of 100,000 looks ran out before a loaded host scheduled the
  # writer at all), and yields between looks without sleeping, so it still
  # sees the row well inside a short admission_stall_ms.
  defp await_queued(handle, pid, deadline \\ nil)

  defp await_queued(handle, pid, nil),
    do: await_queued(handle, pid, System.monotonic_time(:millisecond) + 5_000)

  defp await_queued(handle, pid, deadline) do
    cond do
      :ets.match(handle.control, {{:ticket, :_}, pid, :_}) != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{inspect(pid)} never queued for the lock")

      true ->
        :erlang.yield()
        await_queued(handle, pid, deadline)
    end
  end

  defp ticket_rows(handle), do: length(:ets.match(handle.control, {{:ticket, :_}, :_, :_}))

  # Runs a write and returns its result with the messages left in the
  # writer's mailbox, which must be none.
  defp with_mailbox(write) do
    result = write.()
    {:messages, messages} = Process.info(self(), :messages)
    {result, messages}
  end

  # Takes the free lock as a writer does, for a process that then dies
  # holding it.
  defp claim_lock(handle) do
    ticket = :ets.update_counter(handle.control, :tickets, 1)
    [{:lock, ^ticket, nil, _since, dirty}] = :ets.lookup(handle.control, :lock)
    now = System.monotonic_time(:millisecond)
    true = :ets.insert(handle.control, {:lock, ticket, self(), now, dirty})
  end

  defp event(sequence, overrides \\ []) do
    Event.new!(
      Keyword.merge(
        [
          id: "event-#{sequence}",
          node: "node-test",
          boot_id: "boot-test",
          source: "fixture",
          kind: "runtime_signal",
          severity: :info,
          monotonic_time: sequence,
          clock_id: "clock-test",
          source_instance_id: "fixture-test",
          source_sequence: sequence,
          wall_time: nil,
          subject: %{"namespace" => "process", "scope" => nil, "value" => "worker"},
          causality: %{
            trace_id: "trace",
            span_id: nil,
            parent_event_id: nil,
            logical_operation_id: "operation",
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

  defp clock(initial) do
    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, initial)
    {fn -> :atomics.get(now, 1) end, now}
  end

  defp ticking_clock do
    now = :atomics.new(1, signed: true)
    fn -> :atomics.add_get(now, 1, 1) end
  end

  defp blocking_clock(parent) do
    calls = :atomics.new(1, signed: false)

    fn ->
      case :atomics.add_get(calls, 1, 1) do
        2 ->
          send(parent, {:producer_inside_lock, self()})
          receive do: (:release_clock -> 2)

        call ->
          call
      end
    end
  end
end
