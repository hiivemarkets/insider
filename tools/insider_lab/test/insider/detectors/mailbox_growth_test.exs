defmodule Insider.Detectors.MailboxGrowthTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Insider.Detectors.MailboxGrowth
  alias Insider.Detectors.MailboxGrowth.Error
  alias Insider.Collector.Poller
  alias Insider.Event
  alias Insider.Finding
  alias Insider.Fixtures
  alias Insider.Identity.Subject
  alias Insider.Recorder

  defmodule SequenceProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: {:ok, :complete, %{"process_count" => 1}, []}

    @impl true
    def process_sample(agent) do
      {queue, reductions} =
        Agent.get_and_update(agent, fn
          [sample] -> {sample, [sample]}
          [sample | rest] -> {sample, rest}
        end)

      {:ok, :complete, %{"message_queue_len" => queue, "reductions_total" => reductions}, []}
    end
  end

  test "emits one bounded finding for sustained growth without observed reductions" do
    {:ok, state} =
      MailboxGrowth.new(
        sample_count: 3,
        window_ms: 10,
        minimum_queue_length: 10,
        minimum_growth: 4
      )

    {state, []} = MailboxGrowth.observe(state, sample(1, 6, 100), 1_000)
    {state, []} = MailboxGrowth.observe(state, sample(2, 9, 100), 6_000)

    {state, [{:finding, finding}]} =
      MailboxGrowth.observe(state, sample(3, 12, 100), 11_000)

    assert %Finding{
             schema: "insider.finding/v1",
             detector: "mailbox_growth",
             detector_version: "1",
             occurred_at_us: 11_000,
             confidence: "medium",
             severity: "warning",
             trigger_event_id: "sample-3",
             evidence_event_ids: ["sample-1", "sample-2", "sample-3"]
           } = finding

    assert finding.details == %{
             "sample_count" => 3,
             "window_ms" => 10,
             "identity" => %{
               "node" => "node-a",
               "boot_id" => "boot-a",
               "process_pid" => "<0.10.0>",
               "process_generation" => nil
             },
             "queue_start" => 6,
             "queue_end" => 12,
             "queue_growth" => 6,
             "reductions_start" => 100,
             "reductions_end" => 100
           }

    assert byte_size(finding.fingerprint) == 64
    {_state, []} = MailboxGrowth.observe(state, sample(4, 14, 100), 12_000)
  end

  test "progress, plateaus, declines, and burst recovery stay quiet" do
    {:ok, initial} = detector()

    sequences = [
      [{1, 10, 0}, {2, 20, 1}, {3, 30, 1}],
      [{1, 10, 0}, {2, 20, 0}, {3, 20, 0}],
      [{1, 10, 0}, {2, 20, 0}, {3, 5, 0}, {4, 30, 0}],
      [{1, 10, 0}, {2, 30, 0}, {3, 0, 0}, {4, 40, 0}]
    ]

    Enum.each(sequences, fn sequence ->
      Enum.reduce(sequence, initial, fn {id, queue, reductions}, state ->
        {state, []} = MailboxGrowth.observe(state, sample(id, queue, reductions), id * 1_000)
        state
      end)
    end)
  end

  test "minimum queue and total growth thresholds are both required" do
    {:ok, initial} =
      MailboxGrowth.new(minimum_queue_length: 20, minimum_growth: 10, window_ms: 10)

    for queues <- [[1, 5, 9], [15, 19, 20]] do
      {_state, outputs} = observe_queues(initial, queues, 0)
      assert outputs == []
    end

    {_state, [{:finding, _finding}]} = observe_queues(initial, [10, 15, 20], 0)
  end

  test "declared intentional buffers are ignored before consuming capacity" do
    ignored = Subject.new!("process", "<0.10.0>", "node-a")
    {:ok, state} = MailboxGrowth.new(max_keys: 1, ignored_subjects: [ignored])

    {state, []} = MailboxGrowth.observe(state, sample(1, 10, 0), 1)
    assert state.buckets == %{}
    assert state.seen == %{}

    other = [pid: "<0.11.0>"]

    {_state, [{:finding, _finding}]} =
      {state, []}
      |> observe_one(sample(2, 10, 0, other), 2)
      |> observe_one(sample(3, 11, 0, other), 3)
      |> observe_one(sample(4, 12, 0, other), 4)
  end

  test "the receipt-time window is inclusive and one microsecond outside resets" do
    {:ok, state} = detector(window_ms: 10)
    {_state, [{:finding, _finding}]} = observe_at(state, [0, 5_000, 10_000])

    {:ok, state} = detector(window_ms: 10)
    {_state, []} = observe_at(state, [0, 5_000, 10_001])
  end

  test "recovery and a full quiet window rearm an active fingerprint" do
    {:ok, state} = detector(window_ms: 10)
    {state, [{:finding, first}]} = observe_queues(state, [10, 11, 12], 0)
    {state, []} = MailboxGrowth.observe(state, sample(4, 1, 0), 4_000)
    {state, []} = MailboxGrowth.observe(state, sample(5, 10, 0), 5_000)
    {state, [{:finding, second}]} = MailboxGrowth.observe(state, sample(6, 11, 0), 6_000)
    assert first.fingerprint == second.fingerprint

    {state, []} = MailboxGrowth.observe(state, sample(7, 13, 0), 20_000)
    {state, []} = MailboxGrowth.observe(state, sample(8, 14, 0), 21_000)
    {_state, [{:finding, third}]} = MailboxGrowth.observe(state, sample(9, 15, 0), 22_000)
    assert third.fingerprint == first.fingerprint
  end

  test "unavailable samples and truncated cycles break candidate continuity" do
    {:ok, state} = detector()
    {state, []} = MailboxGrowth.observe(state, sample(1, 10, 0), 1)

    for status <- ["partial", "timeout", "failed"] do
      unavailable = sample(2, 0, 0, status: status)

      assert {cleared, [{:detector_error, %Error{reason: :sample_unavailable}}]} =
               MailboxGrowth.observe(state, unavailable, 2)

      assert cleared.buckets == %{}
    end

    for status <- ["protected", "exited"] do
      assert {cleared, []} = MailboxGrowth.observe(state, sample(2, 0, 0, status: status), 2)
      assert cleared.buckets == %{}
    end

    {state, []} = MailboxGrowth.observe(state, sample(3, 11, 0, cycle: 2), 3)

    assert {state, [{:detector_error, %Error{reason: :evidence_gap}}]} =
             MailboxGrowth.observe(state, poll_cycle(4), 4)

    assert state.buckets == %{}
    {_state, []} = MailboxGrowth.observe(state, sample(5, 12, 0), 5)

    {:ok, state} = detector()

    {state, []} =
      MailboxGrowth.observe(state, sample(6, 10, 0, cycle: 1, source_sequence: 1), 6)

    other_stream_gap = %{poll_cycle(7) | source_instance_id: "poller-b"}

    {state, [{:detector_error, %Error{reason: :evidence_gap}}]} =
      MailboxGrowth.observe(state, other_stream_gap, 7)

    assert map_size(state.buckets) == 1

    {state, []} =
      MailboxGrowth.observe(state, sample(8, 11, 0, cycle: 2, source_sequence: 2), 8)

    {_state, [{:finding, _finding}]} =
      MailboxGrowth.observe(state, sample(9, 12, 0, cycle: 3, source_sequence: 3), 9)
  end

  test "malformed target samples are errors while unrelated events are ignored" do
    {:ok, state} = detector()
    malformed = sample(1, 10, 0) |> put_in([Access.key!(:attributes), "metrics"], %{})

    assert {state, [{:detector_error, %Error{reason: :insufficient_sample}}]} =
             MailboxGrowth.observe(state, malformed, 1)

    wrong_scope = put_in(sample(2, 10, 0).subject["scope"], "node-b")

    assert {_state, [{:detector_error, %Error{reason: :insufficient_sample}}]} =
             MailboxGrowth.observe(state, wrong_scope, 2)

    vm = %{sample(3, 10, 0) | kind: "vm_sample", subject: nil}
    logger = %{sample(4, 10, 0) | source: "logger", kind: "process_sample"}
    {state, []} = MailboxGrowth.observe(state, vm, 3)
    {_state, []} = MailboxGrowth.observe(state, logger, 4)

    {:ok, state} = detector()
    {state, []} = MailboxGrowth.observe(state, sample(5, 10, 0, cycle: 1), 5)
    malformed_identity = put_in(sample(6, 99, 0, cycle: 2).subject["scope"], "node-b")

    {state, [{:detector_error, %Error{reason: :insufficient_sample}}]} =
      MailboxGrowth.observe(state, malformed_identity, 6)

    assert state.buckets == %{}
    {state, []} = MailboxGrowth.observe(state, sample(7, 11, 0, cycle: 3), 7)
    {_state, []} = MailboxGrowth.observe(state, sample(8, 12, 0, cycle: 4), 8)
  end

  test "cycle gaps and reordered source positions cannot manufacture continuity" do
    {:ok, state} = detector()
    {state, []} = MailboxGrowth.observe(state, sample(1, 10, 0, cycle: 1), 1)

    assert {state, [{:detector_error, %Error{reason: :evidence_gap}}]} =
             MailboxGrowth.observe(state, sample(2, 11, 0, cycle: 3), 2)

    {_state, []} = MailboxGrowth.observe(state, sample(3, 12, 0, cycle: 4), 3)

    {:ok, state} = detector()
    {state, []} = MailboxGrowth.observe(state, sample(4, 10, 0, cycle: 3), 4)

    assert {_state, [{:detector_error, %Error{reason: :sample_order_conflict}}]} =
             MailboxGrowth.observe(state, sample(5, 11, 0, cycle: 2), 5)

    {:ok, state} = detector()
    {state, []} = MailboxGrowth.observe(state, sample(6, 10, 0, cycle: 1), 6)

    assert {_state, [{:detector_error, %Error{reason: :sample_order_conflict}}]} =
             MailboxGrowth.observe(
               state,
               sample(7, 11, 0, cycle: 2, source_sequence: 6),
               7
             )
  end

  test "identity and poller streams remain isolated and key capacity is explicit" do
    {:ok, state} = detector(max_keys: 2)
    {state, []} = MailboxGrowth.observe(state, sample(1, 10, 0), 1)
    {state, []} = MailboxGrowth.observe(state, sample(2, 11, 0, source_instance: "poller-b"), 2)

    full = sample(3, 12, 0, pid: "<0.11.0>")

    assert {state, [{:detector_error, %Error{reason: :key_capacity}}]} =
             MailboxGrowth.observe(state, full, 3)

    assert map_size(state.buckets) == 2

    {:ok, mixed_state} = detector()

    {mixed_state, []} =
      MailboxGrowth.observe(mixed_state, sample(4, 10, 0, cycle: 1), 4)

    {mixed_state, []} =
      MailboxGrowth.observe(
        mixed_state,
        sample(5, 11, 0, cycle: 1, source_instance: "poller-b"),
        5
      )

    {_mixed_state, []} =
      MailboxGrowth.observe(mixed_state, sample(6, 12, 0, cycle: 2), 6)

    isolated = [boot_id: "boot-b", generation: "generation-b", source_instance: "poller-c"]
    {:ok, other_state} = detector(max_keys: 4)
    {other_state, []} = MailboxGrowth.observe(other_state, sample(4, 10, 0, isolated), 4)
    assert map_size(other_state.buckets) == 1
  end

  test "duplicates are idempotent, conflicts and reductions regression are visible" do
    {:ok, state} = detector()
    original = sample(1, 10, 100)
    {state, []} = MailboxGrowth.observe(state, original, 1)
    {state, []} = MailboxGrowth.observe(state, original, 2)

    conflicting = put_in(original.attributes["metrics"]["message_queue_len"], 11)

    assert {state, [{:detector_error, %Error{reason: :event_id_conflict}}]} =
             MailboxGrowth.observe(state, conflicting, 3)

    assert {state, [{:detector_error, %Error{reason: :reductions_regressed}}]} =
             MailboxGrowth.observe(state, sample(2, 12, 99), 4)

    assert [_observation] = Map.fetch!(state.buckets, key()).observations
  end

  test "configuration and public inputs fail closed" do
    ignored = Subject.new!("process", "<0.10.0>", "node-a")
    wrong_namespace = Subject.new!("worker", "<0.10.0>", "node-a")
    missing_scope = Subject.new!("process", "<0.10.0>")

    for options <- [
          [sample_count: 2],
          [sample_count: 33],
          [window_ms: 0],
          [minimum_queue_length: 0],
          [minimum_growth: 0],
          [max_keys: 0],
          [ignored_subjects: [wrong_namespace]],
          [ignored_subjects: [missing_scope]],
          [ignored_subjects: [ignored, ignored]],
          [ignored_subjects: List.duplicate(ignored, 33)],
          [unknown: true],
          [sample_count: 3, sample_count: 4]
        ] do
      assert {:error, :invalid_options} = MailboxGrowth.new(options)
    end

    assert {:error, :invalid_options} = MailboxGrowth.new(:invalid)
    {:ok, state} = detector()

    assert {^state, [{:detector_error, %Error{reason: :invalid_event}}]} =
             MailboxGrowth.observe(state, %{}, 1)

    for invalid_id <- [String.duplicate("x", 100_000), <<255>>] do
      invalid = %{sample(1, 10, 0) | id: invalid_id}

      assert {^state, [{:detector_error, %Error{reason: :invalid_event, event_id: nil}}]} =
               MailboxGrowth.observe(state, invalid, 1)
    end

    assert {^state, [{:detector_error, %Error{reason: :invalid_observed_at}}]} =
             MailboxGrowth.observe(state, sample(1, 10, 0), :invalid)

    {state, []} = MailboxGrowth.observe(state, sample(1, 10, 0), 10)

    assert {^state, [{:detector_error, %Error{reason: :time_regressed}}]} =
             MailboxGrowth.observe(state, sample(2, 11, 0), 9)

    for time <- [1 <<< 1_000_000, -(1 <<< 1_000_000)] do
      assert {_state, [{:detector_error, %Error{reason: :invalid_observed_at}}]} =
               MailboxGrowth.observe(state, sample(3, 12, 0), time)
    end
  end

  test "state stays bounded during sustained growth" do
    {:ok, state} = detector(sample_count: 32, max_keys: 1)

    state =
      Enum.reduce(1..1_000, state, fn sequence, state ->
        {state, _outputs} =
          MailboxGrowth.observe(state, sample(sequence, sequence, 0), sequence)

        state
      end)

    assert map_size(state.buckets) == 1
    assert map_size(state.seen) == 32
    assert Enum.count_until(Map.fetch!(state.buckets, key()).observations, 33) == 32
  end

  test "the real mailbox fixture separates faulty growth from its healthy control" do
    faulty = Fixtures.run!(:mailbox_growth, :faulty, work_items: 20)
    healthy = Fixtures.run!(:mailbox_growth, :healthy, work_items: 20)
    {:ok, initial} = detector(minimum_growth: 10)

    faulty_queues = [0 | faulty.samples.queue_growth]
    {_state, [{:finding, _finding}]} = observe_queues(initial, faulty_queues, 0)

    healthy_queues = [0 | healthy.samples.queue_growth]
    healthy_reductions = [0 | healthy.samples.progress_samples]

    {_state, outputs} =
      Enum.zip(healthy_queues, healthy_reductions)
      |> Enum.with_index(1)
      |> Enum.reduce({initial, []}, fn {{queue, reductions}, sequence}, {state, outputs} ->
        {state, emitted} =
          MailboxGrowth.observe(state, sample(sequence, queue, reductions), sequence * 1_000)

        {state, outputs ++ emitted}
      end)

    assert outputs == []
    assert faulty.cleanup.status == :complete
    assert healthy.cleanup.status == :complete
  end

  test "real Poller and Recorder events drive the detector contract" do
    assert [{:finding, %Finding{details: %{"queue_start" => 10, "queue_end" => 12}}}] =
             poller_outputs([{10, 0}, {11, 0}, {12, 0}])

    assert poller_outputs([{10, 0}, {11, 1}, {12, 2}]) == []
  end

  defp detector(overrides \\ []) do
    MailboxGrowth.new(
      Keyword.merge(
        [sample_count: 3, window_ms: 10, minimum_queue_length: 10, minimum_growth: 2],
        overrides
      )
    )
  end

  defp observe_queues(state, queues, reductions) do
    queues
    |> Enum.with_index(1)
    |> Enum.reduce({state, []}, fn {queue, sequence}, {state, outputs} ->
      {state, emitted} =
        MailboxGrowth.observe(state, sample(sequence, queue, reductions), sequence * 1_000)

      {state, outputs ++ emitted}
    end)
  end

  defp observe_at(state, times) do
    times
    |> Enum.with_index(1)
    |> Enum.reduce({state, []}, fn {time, sequence}, {state, outputs} ->
      {state, emitted} = MailboxGrowth.observe(state, sample(sequence, 9 + sequence, 0), time)
      {state, outputs ++ emitted}
    end)
  end

  defp observe_one({state, outputs}, event, observed_at) do
    {state, emitted} = MailboxGrowth.observe(state, event, observed_at)
    {state, outputs ++ emitted}
  end

  defp poller_outputs(samples) do
    {:ok, sample_agent} = Agent.start_link(fn -> samples end)

    {:ok, recorder} =
      Recorder.start_link(
        classification: Insider.TestRecorderClassification.binding(),
        max_events: 64,
        post_trigger_ms: 0
      )

    {:ok, handle} = Recorder.handle(recorder)

    {:ok, poller} =
      Poller.start_link(handle,
        authority: "mailbox-integration",
        boot_id: "boot-integration",
        clock_id: "monotonic-us",
        initial_delay_ms: 0,
        interval_ms: 10,
        source_instance_id: "poller-integration",
        targets: [sample_agent],
        provider: SequenceProvider,
        # A loaded host may delay a probe; a timed-out probe would record an
        # unavailable sample and end the run of three before it qualifies.
        probe_timeout_ms: 1_000,
        cleanup_timeout_ms: 10,
        cycle_timeout_ms: 1_010
      )

    assert_eventually(
      fn ->
        match?({:ok, %{cycles_completed: completed}} when completed >= 3, Poller.status(poller))
      end,
      10_000
    )

    GenServer.stop(poller)
    trigger = %{sample(10_000, 0, 0) | source: "agent", kind: "invariant_failed", subject: nil}
    assert {:ok, _freeze_id} = Recorder.freeze(handle, trigger)
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    # The detector's window is checked against the Recorder's receipt times,
    # which depend on how promptly the host schedules the 10 ms cycles; three
    # samples took more than 100 ms on a loaded CI runner. The window under
    # test here is the contract of the evidence (consecutive cycles, queue
    # growth, no reductions), not the host's scheduling, so it is the
    # maximum. The window bound itself is covered by the unit tests above.
    {:ok, detector} = detector(window_ms: 60_000)

    {_detector, outputs} =
      snapshot.events
      |> Enum.filter(fn entry ->
        entry.event.source_instance_id == "poller-integration" and
          entry.event.kind == "process_sample"
      end)
      |> Enum.sort_by(& &1.receipt)
      |> Enum.reduce({detector, []}, fn entry, {detector, outputs} ->
        {detector, emitted} =
          MailboxGrowth.observe(detector, entry.event, entry.received_at)

        {detector, outputs ++ emitted}
      end)

    GenServer.stop(recorder)
    Agent.stop(sample_agent)
    outputs
  end

  defp assert_eventually(assertion, attempts \\ 1_000)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      receive after: (1 -> assert_eventually(assertion, attempts - 1))
    end
  end

  defp sample(sequence, queue, reductions, options \\ []) do
    node_name = Keyword.get(options, :node, "node-a")
    pid = Keyword.get(options, :pid, "<0.10.0>")
    generation = Keyword.get(options, :generation)
    status = Keyword.get(options, :status, "complete")
    cycle = Keyword.get(options, :cycle, sequence)

    Event.new!(
      id: Keyword.get(options, :id, "sample-#{sequence}"),
      node: node_name,
      boot_id: Keyword.get(options, :boot_id, "boot-a"),
      source: "poller",
      kind: "process_sample",
      severity: :debug,
      monotonic_time: sequence,
      clock_id: "monotonic-us",
      source_instance_id: Keyword.get(options, :source_instance, "poller-a"),
      source_sequence: Keyword.get(options, :source_sequence, sequence),
      wall_time: nil,
      subject: Subject.new!("process", pid, node_name),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: generation
      },
      attributes: %{
        "cleanup" => "observed",
        "cycle_id" => Integer.to_string(cycle, 36),
        "field_set" => "otp_process_scalar/v1",
        "metrics" => %{
          "message_queue_len" => queue,
          "reductions_total" => reductions
        },
        "observer_effect" => "synchronous_runtime_inspection",
        "probe_status" => status,
        "provider" => "Elixir.Insider.Collector.Poller.Erlang",
        "sample_duration_us" => 1,
        "timeout_cancellation" => "not_applicable",
        "unavailable" => []
      },
      payload: nil,
      authority: "test-policy",
      redactions: [],
      extensions: %{}
    )
  end

  defp poll_cycle(sequence) do
    event = sample(sequence, 0, 0)

    %{
      event
      | kind: "poll_cycle",
        subject: nil,
        attributes: %{
          "cleanup" => "not_started",
          "cycle_id" => "cycle-a",
          "field_set" => "poll_cycle/v1",
          "metrics" => %{"skipped_probes" => 1},
          "observer_effect" => "none",
          "probe_status" => "truncated",
          "provider" => "Elixir.Insider.Collector.Poller.Erlang",
          "sample_duration_us" => 0,
          "timeout_cancellation" => "not_applicable",
          "unavailable" => ["cycle_deadline"]
        }
    }
  end

  defp key,
    do: {"node-a", "boot-a", "<0.10.0>", nil, "poller-a"}
end
