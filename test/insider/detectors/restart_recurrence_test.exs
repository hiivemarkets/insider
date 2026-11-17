defmodule Insider.Detectors.RestartRecurrenceTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Insider.Detectors.RestartRecurrence
  alias Insider.Detectors.RestartRecurrence.Error
  alias Insider.Detectors.RestartRecurrence.Finding, as: LegacyFinding
  alias Insider.Detectors.RestartRecurrence.State
  alias Insider.Event
  alias Insider.Finding

  test "state and legacy finding schemas retain explicit bounded defaults" do
    default_state = apply(State, :__struct__, [])

    assert default_state.last_observed_at == nil
    assert default_state.buckets == %{}
    assert default_state.seen == %{}

    {:ok, state} = RestartRecurrence.new(threshold: 3, window_ms: 1, max_keys: 256)

    assert state.last_observed_at == nil
    assert state.buckets == %{}
    assert state.seen == %{}

    default_finding = apply(LegacyFinding, :__struct__, [])
    assert default_finding.schema == nil
    assert default_finding.evidence_event_ids == nil

    finding = %LegacyFinding{
      schema: "insider.finding/v1",
      detector: "restart_recurrence",
      detector_version: "1",
      fingerprint: String.duplicate("a", 64),
      occurred_at_us: 1,
      count: 3,
      window_ms: 1,
      identity: %{"node" => "node-a"},
      reason_fingerprints: [String.duplicate("b", 64)],
      confidence: "medium",
      severity: "error",
      trigger_event_id: "event-3",
      evidence_event_ids: ["event-1", "event-2", "event-3"]
    }

    assert finding.detector == "restart_recurrence"
    assert finding.evidence_event_ids == ["event-1", "event-2", "event-3"]
  end

  test "emits once for distinct child incarnations in the inclusive window" do
    {:ok, state} = RestartRecurrence.new(threshold: 3, window_ms: 10)

    {state, []} = RestartRecurrence.observe(state, event(1), 1_000)
    {state, []} = RestartRecurrence.observe(state, event(2), 6_000)
    {state, [{:incident, finding}]} = RestartRecurrence.observe(state, event(3), 11_000)

    assert %Finding{
             schema: "insider.finding/v1",
             detector: "restart_recurrence",
             detector_version: "1",
             confidence: "medium",
             severity: "error",
             trigger_event_id: "event-3",
             evidence_event_ids: ["event-1", "event-2", "event-3"]
           } = finding

    assert finding.details == %{
             "count" => 3,
             "window_ms" => 10,
             "identity" => %{
               "node" => "node-a",
               "boot_id" => "boot-a",
               "supervisor" => "supervisor-a",
               "offender_id" => "worker-a"
             },
             "reason_fingerprints" => [String.duplicate("a", 64)]
           }

    assert byte_size(finding.fingerprint) == 64
    {state, []} = RestartRecurrence.observe(state, event(4), 12_000)
    assert map_size(state.buckets) == 1
    assert map_size(state.seen) == 3
  end

  test "a quiet interval rearms the same fingerprint" do
    {:ok, state} = RestartRecurrence.new(threshold: 2, window_ms: 10)
    {state, []} = RestartRecurrence.observe(state, event(1), 0)
    {state, [{:incident, first}]} = RestartRecurrence.observe(state, event(2), 1_000)
    {state, []} = RestartRecurrence.observe(state, event(3), 20_000)
    {_state, [{:incident, second}]} = RestartRecurrence.observe(state, event(4), 21_000)
    assert first.fingerprint == second.fingerprint
  end

  test "normal, shutdown, temporary, unrelated, and sparse events stay quiet" do
    {:ok, initial} = RestartRecurrence.new(threshold: 2, window_ms: 10)

    quiet = [
      event(1, reason_class: "normal"),
      event(2, reason_class: "shutdown"),
      event(3, restart_type: "temporary"),
      event(4, kind: "process_crashed")
    ]

    state =
      Enum.reduce(quiet, initial, fn event, state ->
        {state, []} = RestartRecurrence.observe(state, event, 1_000)
        state
      end)

    {state, []} = RestartRecurrence.observe(state, event(5), 1_000)
    {_state, []} = RestartRecurrence.observe(state, event(6), 12_000)
  end

  test "different logical children and duplicate incarnations do not form a storm" do
    {:ok, state} = RestartRecurrence.new(threshold: 2)
    {state, []} = RestartRecurrence.observe(state, event(1), 1)
    {state, []} = RestartRecurrence.observe(state, event(2, offender_id: "worker-b"), 2)
    {state, []} = RestartRecurrence.observe(state, event(3, offender_pid: "<0.1.0>"), 3)
    assert map_size(state.buckets) == 2
    assert map_size(state.seen) == 3

    conflicting = event(3, offender_pid: "<0.9.0>")

    assert {_state, [{:detector_error, %Error{reason: :event_id_conflict}}]} =
             RestartRecurrence.observe(state, conflicting, 4)
  end

  test "duplicate IDs are idempotent and conflicting IDs are explicit" do
    {:ok, state} = RestartRecurrence.new(threshold: 2)
    original = event(1)
    {state, []} = RestartRecurrence.observe(state, original, 1)
    {state, []} = RestartRecurrence.observe(state, original, 2)

    conflicting = %{
      original
      | attributes: Map.put(original.attributes, "offender_pid", "<0.9.0>")
    }

    assert {_state, [{:detector_error, %Error{reason: :event_id_conflict}}]} =
             RestartRecurrence.observe(state, conflicting, 3)
  end

  test "malformed target semantics, regressed receipt time, and capacity are visible" do
    {:ok, state} = RestartRecurrence.new(threshold: 2, max_keys: 1)
    malformed = %{event(1) | attributes: Map.delete(event(1).attributes, "restart_type")}

    assert {state, [{:detector_error, %Error{reason: :insufficient_restart_semantics}}]} =
             RestartRecurrence.observe(state, malformed, 1)

    {state, []} = RestartRecurrence.observe(state, event(1), 10)

    assert {^state, [{:detector_error, %Error{reason: :time_regressed}}]} =
             RestartRecurrence.observe(state, event(2), 9)

    other = event(3, offender_id: "worker-b")

    assert {_state, [{:detector_error, %Error{reason: :key_capacity}}]} =
             RestartRecurrence.observe(state, other, 11)
  end

  test "receipt time cannot regress across logical keys" do
    {:ok, state} = RestartRecurrence.new(threshold: 2)
    {state, []} = RestartRecurrence.observe(state, event(1), 10)

    assert {^state, [{:detector_error, %Error{reason: :time_regressed}}]} =
             RestartRecurrence.observe(state, event(2, offender_id: "worker-b"), 9)
  end

  test "candidate targets require collector provenance, a real PID, and a digest" do
    {:ok, state} = RestartRecurrence.new(threshold: 2)

    invalid_events = [
      event(1, semantic_projection: "forged"),
      event(2, domain: ["application"]),
      event(3, offender_pid: "not-a-pid"),
      event(4, reason_fingerprint: nil),
      event(5, reason_fingerprint: "abcd")
    ]

    Enum.reduce(invalid_events, state, fn event, state ->
      {state, outputs} = RestartRecurrence.observe(state, event, event.source_sequence)
      assert [{:detector_error, %Error{reason: :insufficient_restart_semantics}}] = outputs
      state
    end)
  end

  test "configuration and public inputs fail closed" do
    for options <- [
          [threshold: 1],
          [threshold: 33],
          [window_ms: 0],
          [max_keys: 0],
          [unknown: true],
          [threshold: 2, threshold: 3]
        ] do
      assert {:error, :invalid_options} = RestartRecurrence.new(options)
    end

    assert {:error, :invalid_options} = RestartRecurrence.new(:invalid)
    {:ok, state} = RestartRecurrence.new()

    assert {^state, [{:detector_error, %Error{reason: :invalid_event}}]} =
             RestartRecurrence.observe(state, %{}, 1)

    for invalid_id <- [String.duplicate("x", 100_000), <<255>>] do
      invalid = %{event(1) | id: invalid_id}

      assert {^state, [{:detector_error, %Error{reason: :invalid_event, event_id: nil}}]} =
               RestartRecurrence.observe(state, invalid, 1)
    end

    assert {^state, [{:detector_error, %Error{reason: :invalid_observed_at}}]} =
             RestartRecurrence.observe(state, event(1), :not_a_time)

    for time <- [1 <<< 1_000_000, -(1 <<< 1_000_000)] do
      assert {^state, [{:detector_error, %Error{reason: :invalid_observed_at}}]} =
               RestartRecurrence.observe(state, event(1), time)
    end
  end

  test "state remains bounded under sustained active storms" do
    {:ok, state} = RestartRecurrence.new(threshold: 3, max_keys: 2)

    state =
      Enum.reduce(1..1_000, state, fn sequence, state ->
        {state, _outputs} = RestartRecurrence.observe(state, event(sequence), sequence)
        state
      end)

    assert map_size(state.buckets) == 1
    assert map_size(state.seen) == 3

    assert [_, _, _] =
             state.buckets[{"node-a", "boot-a", "supervisor-a", "worker-a"}].observations
  end

  defp event(sequence, options \\ []) do
    kind = Keyword.get(options, :kind, "supervisor_child_terminated")

    Event.new!(
      id: "event-#{sequence}",
      node: "node-a",
      boot_id: "boot-a",
      source: "logger",
      kind: kind,
      severity: :error,
      monotonic_time: sequence,
      clock_id: "logger-sequence",
      source_instance_id: "logger-a",
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
      attributes: %{
        "domain" => Keyword.get(options, :domain, ["otp", "sasl"]),
        "label" => "supervisor.child_terminated",
        "message_type" => "report",
        "semantic_projection" => Keyword.get(options, :semantic_projection, "otp_supervisor/v1"),
        "supervisor" => Keyword.get(options, :supervisor, "supervisor-a"),
        "termination_context" => "child_terminated",
        "offender_id" => Keyword.get(options, :offender_id, "worker-a"),
        "offender_pid" => Keyword.get(options, :offender_pid, "<0.#{sequence}.0>"),
        "restart_type" => Keyword.get(options, :restart_type, "permanent"),
        "reason_class" => Keyword.get(options, :reason_class, "abnormal"),
        "reason_fingerprint" =>
          Keyword.get(options, :reason_fingerprint, String.duplicate("a", 64))
      },
      payload: nil,
      authority: "test-policy",
      redactions: [],
      extensions: %{}
    )
  end
end
