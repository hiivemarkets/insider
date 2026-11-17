defmodule Insider.InvariantTest do
  use ExUnit.Case, async: true

  alias Insider.Contract
  alias Insider.Fixtures.SemanticContract
  alias Insider.Invariant
  alias Insider.Incident.Capsule
  alias Insider.Incident.ExportPolicy
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Request
  alias Insider.Provenance
  alias Insider.Recorder
  alias Insider.Redaction.Policy

  defmodule FailureContract do
    use Insider.Contract, id: "test.invariant.failure", version: 1

    invariant(:explode, check: &explode/0)
    invariant(:block, check: &block/0)
    invariant(:secret_failure, check: &secret_failure/0, sensitivity: :secret)

    defp explode, do: raise("private invariant exception")

    defp block, do: Process.sleep(5_000)

    defp secret_failure, do: false
  end

  setup do
    executor = start_supervised!({Contract.Executor, name: nil, max_concurrency: 1})
    policy = policy!(:internal)

    recorder_pid =
      start_supervised!({Recorder, classification: {:internal, policy}, post_trigger_ms: 0})

    {:ok, recorder} = Recorder.handle(recorder_pid)

    {:ok, invariant} =
      Invariant.new(
        authority: "test-policy",
        boot_id: "boot-a",
        clock_id: "monotonic-us",
        executor: executor,
        recorder: recorder,
        redaction_policy: policy,
        source_instance_id: "invariant-a"
      )

    %{executor: executor, invariant: invariant, recorder: recorder}
  end

  test "a faulty semantic fixture creates one confirmed incident", %{
    invariant: invariant
  } do
    sample = SemanticContract.sample(7, [2, 3])

    outcome =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [sample],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :violation,
             execution: :complete,
             disclosure: :clear,
             recording: :frozen,
             confirmed: true,
             event: event,
             finding: finding,
             snapshot: snapshot
           } = outcome

    assert event.source == "contract"
    assert event.kind == "invariant_failed"
    assert event.severity == :error
    assert event.payload == false
    assert event.redactions == []
    assert event.attributes["contract_id"] == "insider.fixture.semantic"
    assert event.attributes["invariant"] == "total_matches_items"
    assert event.attributes["verdict"] == "violation"
    assert event.attributes["execution"] == "complete"
    assert event.attributes["disclosure"] == "clear"

    assert finding.detector == "semantic_invariant"
    assert finding.trigger_event_id == event.id
    assert finding.evidence_event_ids == [event.id]
    assert Enum.map(snapshot.events, & &1.event.id) == [event.id]
  end

  test "a passing fixture is recorded without freezing", %{
    invariant: invariant,
    recorder: recorder
  } do
    outcome =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(5, [2, 3])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :pass,
             execution: :complete,
             disclosure: :clear,
             recording: :recorded,
             confirmed: false,
             finding: nil,
             snapshot: nil
           } = outcome

    assert outcome.event.kind == "invariant_checked"
    assert outcome.event.payload == true
    assert {:error, :not_triggered} = Recorder.snapshot(recorder)
  end

  test "a malformed semantic sample fails the declared contract", %{invariant: invariant} do
    outcome =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [%{"items" => [2, 3]}],
        authorization_options()
      )

    assert outcome.verdict == :violation
    assert outcome.execution == :complete
    assert outcome.confirmed
  end

  test "a confirmed semantic incident assembles and round trips offline", %{
    invariant: invariant
  } do
    outcome =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(7, [2, 3])],
        authorization_options()
      )

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"commit" => "abc123"}},
        configuration: {:redacted, invariant.redaction_policy.fingerprint},
        dependencies: {:available, %{"lock" => "def456"}},
        runtime: {:available, %{"otp" => "29"}},
        target: {:available, %{"class" => "test"}}
      )

    {:ok, export_policy} =
      ExportPolicy.new(invariant.redaction_policy,
        finding: :internal,
        snapshot: :internal,
        event: :internal,
        provenance: :internal,
        authority: :internal,
        artifacts: :internal
      )

    assert {:ok, capsule} =
             Capsule.assemble(outcome.snapshot, outcome.finding, provenance,
               export_policy: export_policy,
               authority: [capture_audit_id: "capture-1", export_audit_id: "export-1"],
               artifacts: []
             )

    assert capsule.finding["detector"] == "semantic_invariant"
    assert capsule.finding["details"]["identity"]["invariant"] == "total_matches_items"
    assert {:ok, canonical} = Capsule.canonical_binary(capsule)
    assert {:ok, ^capsule} = Capsule.decode(canonical)

    for {attribute, contradiction} <- [
          {"invocation_status", "error"},
          {"invocation_reason", "callback_exception"},
          {"cleanup", "uncertain"}
        ] do
      [entry] = outcome.snapshot.events

      event = %{
        entry.event
        | attributes: Map.put(entry.event.attributes, attribute, contradiction)
      }

      {:ok, event_bytes} = Insider.Event.canonical_binary(event)

      snapshot = %{
        outcome.snapshot
        | events: [%{entry | event: event}],
          retained_bytes: byte_size(event_bytes)
      }

      assert {:error, _error} =
               Capsule.assemble(snapshot, outcome.finding, provenance,
                 export_policy: export_policy,
                 authority: [capture_audit_id: "capture-1", export_audit_id: "export-1"],
                 artifacts: []
               )
    end
  end

  test "exceptions and timeouts remain distinct non-incidents", %{invariant: invariant} do
    exception =
      Invariant.check(
        invariant,
        FailureContract,
        :explode,
        [],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :unknown,
             execution: :exception,
             recording: :recorded,
             confirmed: false
           } = exception

    refute inspect(exception) =~ "private invariant exception"

    timeout =
      Invariant.check(
        invariant,
        FailureContract,
        :block,
        [],
        authorization_options(timeout_ms: 100)
      )

    assert %Invariant.Outcome{
             verdict: :unknown,
             execution: :timeout,
             recording: :recorded,
             confirmed: false
           } = timeout
  end

  test "executor overload and unavailability remain distinct", %{
    executor: executor,
    invariant: invariant
  } do
    task =
      Task.async(fn ->
        Invariant.check(
          invariant,
          FailureContract,
          :block,
          [],
          authorization_options(timeout_ms: 200)
        )
      end)

    assert_eventually(fn -> DynamicSupervisor.count_children(executor).active == 1 end)

    overloaded =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(0, [])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :unknown,
             execution: :overloaded,
             confirmed: false
           } = overloaded

    Task.await(task)

    unavailable =
      invariant
      |> Map.put(:executor, self())
      |> Invariant.check(
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(0, [])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :unknown,
             execution: :unavailable,
             confirmed: false
           } = unavailable

    assert Process.alive?(executor)
  end

  test "a policy-redacted violation is evidence but not a confirmed incident", %{
    invariant: invariant
  } do
    outcome =
      Invariant.check(
        invariant,
        FailureContract,
        :secret_failure,
        [],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :violation,
             execution: :complete,
             disclosure: :redacted,
             recording: :recorded,
             confirmed: false,
             finding: nil,
             snapshot: nil
           } = outcome

    assert outcome.event.kind == "invariant_checked"
    assert outcome.event.payload == nil
    assert outcome.event.redactions == []
    assert outcome.redaction.manifest != []
  end

  test "recorder loss is visible and never confirms an incident", %{invariant: invariant} do
    GenServer.stop(invariant.recorder.pid)

    outcome =
      Invariant.check(
        invariant,
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(7, [2, 3])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :violation,
             execution: :complete,
             disclosure: :clear,
             recording: :dropped,
             confirmed: false,
             finding: nil,
             snapshot: nil
           } = outcome
  end

  test "pending recorder windows remain frozen but unconfirmed", %{invariant: invariant} do
    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, 1_000)
    clock = fn -> :atomics.get(now, 1) end

    recorder_pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Recorder, :start_link,
           [
             [
               classification: {:internal, invariant.redaction_policy},
               clock: clock,
               post_trigger_ms: 1
             ]
           ]}
      })

    {:ok, recorder} = Recorder.handle(recorder_pid)

    outcome =
      invariant
      |> Map.put(:recorder, recorder)
      |> Invariant.check(
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(7, [2, 3])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :violation,
             execution: :complete,
             disclosure: :clear,
             recording: :frozen,
             confirmed: false,
             finding: nil,
             snapshot: nil
           } = outcome

    assert outcome.error.message == "invariant snapshot is pending"

    other_recorder_pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Recorder, :start_link,
           [
             [
               classification: {:internal, invariant.redaction_policy},
               clock: clock,
               post_trigger_ms: 1
             ]
           ]}
      })

    {:ok, other_recorder} = Recorder.handle(other_recorder_pid)

    other_evaluator = %{
      invariant
      | recorder: other_recorder,
        sequence: :atomics.new(1, signed: false)
    }

    other_outcome =
      Invariant.check(
        other_evaluator,
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(8, [2, 3])],
        authorization_options()
      )

    assert other_outcome.event.id == outcome.event.id
    refute other_outcome.event == outcome.event

    :atomics.put(now, 1, 2_000)
    wrong_recorder = Invariant.resolve(other_evaluator, outcome)
    refute wrong_recorder.confirmed
    assert wrong_recorder.error.message == "invariant snapshot does not contain its trigger"

    tampered = %{outcome | event: %{outcome.event | payload: true}}
    refute Invariant.resolve(%{invariant | recorder: recorder}, tampered).confirmed

    resolved = Invariant.resolve(%{invariant | recorder: recorder}, outcome)

    assert %Invariant.Outcome{confirmed: true, finding: finding, snapshot: snapshot, error: nil} =
             resolved

    assert finding.trigger_event_id == outcome.event.id
    assert snapshot.trigger_event_id == outcome.event.id
    assert Invariant.resolve(%{invariant | recorder: recorder}, resolved) == resolved
  end

  test "invalid checks and disclosure failures remain explicit non-incidents", %{
    invariant: invariant
  } do
    invalid =
      Invariant.check(
        invariant,
        SemanticContract,
        :not_declared,
        [],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :unknown,
             execution: :invalid,
             disclosure: :clear,
             recording: :recorded,
             confirmed: false
           } = invalid

    failed_policy = %{invariant.redaction_policy | fingerprint: "invalid"}

    disclosure_failed =
      invariant
      |> Map.put(:redaction_policy, failed_policy)
      |> Invariant.check(
        SemanticContract,
        :total_matches_items,
        [SemanticContract.sample(5, [2, 3])],
        authorization_options()
      )

    assert %Invariant.Outcome{
             verdict: :pass,
             execution: :complete,
             disclosure: :failed,
             recording: :recorded,
             confirmed: false,
             redaction: nil
           } = disclosure_failed

    assert disclosure_failed.error.code == :redaction_failed
    assert disclosure_failed.event.severity == :warning
  end

  test "configuration validation is exact and bounded", %{invariant: invariant} do
    options = Map.from_struct(invariant) |> Map.delete(:sequence) |> Map.to_list()

    assert {:error, _error} = Invariant.new(Keyword.put(options, :unknown, true))
    assert {:error, _error} = Invariant.new(options ++ [authority: "duplicate"])
    assert {:error, _error} = Invariant.new(List.duplicate({:authority, "x"}, 100_000))
    assert {:error, _error} = Invariant.new([{:authority, "x"} | :improper])
    assert {:error, _error} = Invariant.new(:invalid)
    assert {:error, _error} = Invariant.new(Keyword.put(options, :authority, ""))

    assert %Invariant.Outcome{execution: :invalid, recording: :dropped} =
             Invariant.check(:invalid, SemanticContract, :total_matches_items, [], [])
  end

  defp policy!(maximum_sensitivity) do
    {:ok, policy} =
      Policy.new(
        id: "invariant-test",
        maximum_sensitivity: maximum_sensitivity,
        rules: []
      )

    policy
  end

  defp authorization_options(options \\ []) do
    timeout_ms = Keyword.get(options, :timeout_ms, 1_000)
    target = %{node: Atom.to_string(node())}
    now = System.monotonic_time(:millisecond)

    {:ok, grant} =
      Grant.new(
        reference: "invariant-test-grant",
        audit_id: "invariant-test-audit",
        scopes: ["contract.observe"],
        target: target,
        expires_at_monotonic: now + timeout_ms + 1_000
      )

    {:ok, request} =
      Request.new("contract.check",
        request_id: "invariant-test-request",
        environment: :test,
        target: target,
        capability: grant.reference,
        timeout_ms: timeout_ms,
        budget: %{max_duration_ms: timeout_ms, max_bytes: 65_536}
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "invariant-test",
        target_class: :host,
        grants: [grant],
        features: %{
          "contract.check" => %{available: true, provider: "test", isolation: :session_local}
        }
      )

    [request: request, context: context, timeout_ms: timeout_ms]
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(2)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
