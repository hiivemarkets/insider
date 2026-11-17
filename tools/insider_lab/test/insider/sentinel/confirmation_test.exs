defmodule Insider.Sentinel.ConfirmationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Receipt
  alias Insider.Sentinel.Confirmation.Record
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Sandbox
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.TestSupport.ConfirmationBodyIncomplete
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationBodyMatchingScenarioFailed
  alias Insider.TestSupport.ConfirmationBodyNone
  alias Insider.TestSupport.ConfirmationBodyRepaired
  alias Insider.TestSupport.ConfirmationBodyStale
  alias Insider.TestSupport.ConfirmationBodyUnrelated
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.ConfirmationProvider
  alias Insider.TestSupport.ExternalConfirmationBody
  alias Insider.TestSupport.ExternalConfirmationBodyBlocking
  alias Insider.TestSupport.ExternalConfirmationBodyEmptyExit2
  alias Insider.TestSupport.ExternalConfirmationBodyExit2
  alias Insider.TestSupport.ExternalConfirmationBodyNonmatchingExit2
  alias Insider.TestSupport.ExternalLeaseProvider
  alias Insider.TestSupport.ExternalLeaseRegistry

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}
  @external_body_stop_timeout_ms 1_000
  @external_cleanup_timeout_ms 500
  @external_client_slack_ms 500
  @external_client_wait_ms @external_body_stop_timeout_ms + @external_cleanup_timeout_ms +
                             @external_client_slack_ms

  setup do
    executor =
      start_supervised!(
        {Executor,
         name: nil,
         providers: [ConfirmationProvider, ExternalLeaseProvider],
         bodies: [
           ConfirmationBodyMatching,
           ConfirmationBodyMatchingScenarioFailed,
           ConfirmationBodyRepaired,
           ConfirmationBodyUnrelated,
           ConfirmationBodyNone,
           ConfirmationBodyIncomplete,
           ConfirmationBodyStale,
           ExternalConfirmationBody,
           ExternalConfirmationBodyBlocking,
           ExternalConfirmationBodyEmptyExit2,
           ExternalConfirmationBodyExit2,
           ExternalConfirmationBodyNonmatchingExit2
         ]}
      )

    %{executor: executor}
  end

  test "a live external process binds scenario observation to one provider lease", %{
    executor: executor
  } do
    {manifest, capsule, scenario, old_target} = external_inputs!()

    {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
    {request, context} = authority!(target, "external-confirmation", 5_000)
    observer = %{"id" => "test.external-observer", "version" => 1}

    assert {:ok, %Record{schema: "insider.confirmation-record/v2", confirmed: true} = record} =
             Confirmation.run(executor, manifest, capsule, scenario, target,
               request: request,
               context: context,
               body: ExternalConfirmationBody,
               observer: observer,
               repair_oracle: nil
             )

    execution = record.evidence["external_execution"]
    report = execution["report"]
    assert execution["owner_fingerprint"] == record.evidence["owner_fingerprint"]
    assert report["scenario_id"] == scenario.id
    assert report["observer"] == observer
    assert report["observed_fingerprints"] == [capsule.finding["fingerprint"]]
    assert execution["target_fingerprint"] == record.observed_target_fingerprint
    assert execution["cleanup"] == %{"process" => "down"}
    assert {:ok, bytes} = Record.canonical_binary(record)
    assert {:ok, ^record} = Record.decode(bytes)

    forged_owner = "sha256:" <> String.duplicate("f", 64)

    forged_external =
      execution
      |> Map.put("owner_fingerprint", forged_owner)
      |> put_in(["report", "owner_fingerprint"], forged_owner)
      |> readdress_map()

    forged_record =
      record
      |> Record.to_wire_map()
      |> put_in(["evidence", "external_execution"], forged_external)
      |> readdress_map()

    assert {:error, %Error{code: :invalid_confirmation_record}} =
             Record.decode_map(forged_record)
  end

  test "a nonzero external command exit can carry a matching failing-before observation", %{
    executor: executor
  } do
    {manifest, capsule, scenario, old_target} = external_inputs!()
    {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
    {request, context} = authority!(target, "external-exit-2", 5_000)

    assert {:ok, %Record{confirmed: true} = record} =
             Confirmation.run(executor, manifest, capsule, scenario, target,
               request: request,
               context: context,
               body: ExternalConfirmationBodyExit2,
               observer: %{"id" => "test.external-observer", "version" => 1},
               repair_oracle: nil
             )

    assert record.evidence["external_execution"]["status"] == "exited"
    assert record.evidence["external_execution"]["exit_status"] == 2
    assert record.outcome == "matching_failure"
  end

  test "nonzero empty, nonmatching, or caller-claimed repaired outcomes are infrastructure failures",
       %{
         executor: executor
       } do
    for {body, oracle, suffix} <- [
          {ExternalConfirmationBodyEmptyExit2, nil, "empty"},
          {ExternalConfirmationBodyNonmatchingExit2, nil, "nonmatching"},
          {ExternalConfirmationBodyEmptyExit2, @oracle, "repaired"}
        ] do
      {manifest, capsule, scenario, old_target} = external_inputs!()
      {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
      {request, context} = authority!(target, "external-exit-2-#{suffix}", 5_000)

      assert {:ok,
              %Record{
                confirmed: false,
                outcome: "infrastructure_failure",
                operational_status: "error"
              }} =
               Confirmation.run(executor, manifest, capsule, scenario, target,
                 request: request,
                 context: context,
                 body: body,
                 observer: %{"id" => "test.external-observer", "version" => 1},
                 repair_oracle: oracle
               )
    end
  end

  test "external evidence cannot confirm when the provider inventory proves a leftover", %{
    executor: executor
  } do
    {manifest, capsule, scenario, old_target} = external_inputs!("cleanup_partial")
    {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
    {request, context} = authority!(target, "external-leftover", 5_000)

    assert {:ok, %Record{confirmed: false, cleanup: %{"status" => "partial"}} = record} =
             Confirmation.run(executor, manifest, capsule, scenario, target,
               request: request,
               context: context,
               body: ExternalConfirmationBody,
               observer: %{"id" => "test.external-observer", "version" => 1},
               repair_oracle: nil
             )

    owner = record.evidence["owner_fingerprint"]
    on_exit(fn -> ExternalLeaseRegistry.force_purge(owner) end)
    assert owner == record.evidence["external_execution"]["owner_fingerprint"]
  end

  test "sandbox timeout stops the blocking external child before provider cleanup", %{
    executor: executor
  } do
    {manifest, capsule, scenario, old_target} = inputs!("external_audit_timeout", 9_001)
    {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
    {request, context} = authority!(target, "external-timeout", 5_000)

    assert %Result{
             status: :timeout,
             cleanup: %{status: :complete, remaining_count: 0},
             uncertainty: ["stopping target work is not rollback of external effects"],
             value: %{"owner_fingerprint" => owner}
           } =
             Sandbox.run(executor, target,
               request: request,
               context: context,
               body:
                 {ExternalConfirmationBodyBlocking, body_input(manifest, capsule, scenario),
                  @external_body_stop_timeout_ms}
             )

    assert_external_audit(owner)
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "explicit sandbox cancellation stops the blocking external child before cleanup", %{
    executor: executor
  } do
    {manifest, capsule, scenario, old_target} = inputs!("external_audit_cancel", 9_002)
    {:ok, target} = Target.new(ExternalLeaseProvider.identity(), old_target.provenance)
    {request, context} = authority!(target, "external-cancel", 5_000)

    assert {:ok, handle} =
             Sandbox.start_run(executor, target,
               request: request,
               context: context,
               body:
                 {ExternalConfirmationBodyBlocking, body_input(manifest, capsule, scenario),
                  @external_body_stop_timeout_ms}
             )

    await_external_child(
      target.provenance["fingerprint"],
      System.monotonic_time(:millisecond) + 5_000
    )

    assert :ok = Sandbox.cancel(handle, @external_client_wait_ms)

    assert %Result{
             status: :cancelled,
             cleanup: %{status: :complete, remaining_count: 0},
             uncertainty: ["stopping target work is not rollback of external effects"],
             value: %{"owner_fingerprint" => owner}
           } = Sandbox.await(handle, @external_client_wait_ms)

    assert_external_audit(owner)
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "an exact run-correlated finding confirms and round trips canonically", %{
    executor: executor
  } do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-match")

    assert {:ok, %Record{outcome: "matching_failure", confirmed: true} = record} =
             Confirmation.run(executor, manifest, capsule, scenario, target,
               request: request,
               context: context,
               body: ConfirmationBodyMatching,
               observer: @observer,
               repair_oracle: nil
             )

    assert record.operational_status == "completed"
    assert record.expected_fingerprint in record.observed_fingerprints
    assert record.requested_target_fingerprint == record.observed_target_fingerprint

    assert record.cleanup == %{
             "status" => "complete",
             "release" => "complete",
             "remaining_count" => 0,
             "remaining_fingerprint" => nil
           }

    assert record.evidence["owner_fingerprint"] == record.evidence["observation_run_fingerprint"]
    assert record.evidence["observer"] == @observer
    assert {:ok, bytes} = Record.canonical_binary(record)
    assert {:ok, ^record} = Record.decode(bytes)
  end

  test "scenario cleanup budget is forwarded for body stop and provider cleanup", %{
    executor: executor
  } do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-cleanup-budget", 590)

    assert {:ok, %Record{confirmed: true, cleanup: %{"status" => "complete"}}} =
             Confirmation.run(executor, manifest, capsule, scenario, target,
               request: request,
               context: context,
               body: ConfirmationBodyMatching,
               observer: @observer,
               repair_oracle: nil
             )
  end

  test "classifies repaired, unrelated, and nonreproduced without confirming", %{
    executor: executor
  } do
    for {body, oracle, expected_outcome} <- [
          {ConfirmationBodyRepaired, @oracle, "repaired"},
          {ConfirmationBodyUnrelated, nil, "unrelated_failure"},
          {ConfirmationBodyNone, nil, "nonreproduced"}
        ] do
      {manifest, capsule, scenario, target} = inputs!()
      {request, context} = authority!(target, "confirmation-#{inspect(body)}")

      assert {:ok, %Record{outcome: ^expected_outcome, confirmed: false}} =
               Confirmation.run(executor, manifest, capsule, scenario, target,
                 request: request,
                 context: context,
                 body: body,
                 observer: @observer,
                 repair_oracle: oracle
               )
    end
  end

  test "matching evidence dominates a scenario callback failure", %{executor: executor} do
    {_manifest, capsule, _scenario, target} = inputs!()
    scenario = scenario!(capsule.finding["fingerprint"], :failed)
    {:ok, manifest} = Manifest.new(capsule, Scenario.descriptor(scenario) |> elem(1))
    {request, context} = authority!(target, "confirmation-match-failed-scenario")

    assert {:ok, %Record{outcome: "matching_failure", confirmed: true}} =
             run(
               executor,
               manifest,
               capsule,
               scenario,
               target,
               request,
               context,
               ConfirmationBodyMatchingScenarioFailed
             )
  end

  test "incomplete observation is infrastructure failure with bounded evidence", %{
    executor: executor
  } do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-incomplete")

    assert {:ok,
            %Record{
              outcome: "infrastructure_failure",
              confirmed: false,
              outcome_reason: "observer_failed"
            } = record} =
             run(
               executor,
               manifest,
               capsule,
               scenario,
               target,
               request,
               context,
               ConfirmationBodyIncomplete
             )

    assert record.evidence["status"] == "incomplete"
  end

  test "an operational failure remains distinct and has no observed target fingerprint", %{
    executor: executor
  } do
    {manifest, capsule, scenario, target} = inputs!("acquire_error")
    {request, context} = authority!(target, "confirmation-acquire-failure")

    assert {:ok,
            %Record{
              outcome: "infrastructure_failure",
              operational_status: "error",
              observed_target_fingerprint: nil,
              requested_target_fingerprint: requested,
              confirmed: false
            }} = run(executor, manifest, capsule, scenario, target, request, context)

    assert requested == Target.target_fingerprint(target)
  end

  test "matching evidence survives incomplete cleanup but cannot confirm", %{executor: executor} do
    {manifest, capsule, scenario, target} = inputs!("cleanup_partial")
    {request, context} = authority!(target, "confirmation-partial-cleanup")

    assert {:ok,
            %Record{
              outcome: "matching_failure",
              operational_status: "error",
              operational_reason: "sandbox_failed",
              outcome_reason: nil,
              confirmed: false,
              cleanup: %{"status" => "partial"}
            }} = run(executor, manifest, capsule, scenario, target, request, context)
  end

  test "a stale receipt from another owner cannot confirm", %{executor: executor} do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-stale")

    assert {:ok,
            %Record{
              outcome: "infrastructure_failure",
              outcome_reason: "invalid_body_receipt",
              confirmed: false
            }} =
             run(
               executor,
               manifest,
               capsule,
               scenario,
               target,
               request,
               context,
               ConfirmationBodyStale
             )
  end

  test "rejects cross-bound manifest, scenario, target, and expected fingerprint before effects",
       %{executor: executor} do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-reject")
    other = scenario!(String.duplicate("e", 64), :ok)

    assert {:error, %Error{code: :confirmation_input_mismatch}} =
             run(executor, manifest, capsule, other, target, request, context)

    refute_received {:sandbox_allocation_intent, _owner, _pid, _mode, _unique}

    mismatched_target = target_with_unique!(2)

    assert {:error, %Error{code: :confirmation_input_mismatch}} =
             run(executor, manifest, capsule, scenario, mismatched_target, request, context)

    refute_received {:sandbox_allocation_intent, _owner, _pid, _mode, _unique}
  end

  test "record integrity rejects outcome and confirmation tampering", %{executor: executor} do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-integrity")
    assert {:ok, record} = run(executor, manifest, capsule, scenario, target, request, context)

    assert {:error, %Error{code: :invalid_confirmation_record}} =
             Record.validate(%{record | confirmed: false})

    assert {:error, %Error{code: :invalid_confirmation_record}} =
             Record.validate(%{record | outcome: "repaired"})
  end

  test "canonical record fixture and ingress reject malformed envelopes" do
    record = fixture_record!()
    {:ok, bytes} = Record.canonical_binary(record)

    assert bytes ==
             "test/fixtures/confirmation_record_v1.json"
             |> File.read!()
             |> String.trim_trailing("\n")

    assert {:ok, ^record} = Record.decode_map(Jason.decode!(bytes))

    assert {:error, %Error{code: :unsupported_confirmation_record_schema}} =
             Record.decode_map(%{"schema" => "insider.confirmation-record/v99"})

    assert {:error, %Error{code: :unsupported_confirmation_record_schema}} =
             Record.decode_map(%{"schema" => %{hostile: true}})

    assert {:error, %Error{code: :invalid_confirmation_record}} = Record.decode(bytes <> "\n")

    assert {:error, %Error{code: :confirmation_record_limit_exceeded}} =
             Record.decode(String.duplicate("x", 16_385))

    unknown = Map.put(Record.to_wire_map(record), "unknown", true)
    assert {:error, %Error{code: :invalid_confirmation_record}} = Record.decode_map(unknown)
  end

  test "canonical external confirmation v2 fixture cannot be downgraded by readdressing" do
    bytes = File.read!("test/fixtures/confirmation_record_v2.json") |> String.trim_trailing("\n")

    assert {:ok, %Record{schema: "insider.confirmation-record/v2"} = record} =
             Record.decode(bytes)

    assert {:ok, ^bytes} = Record.canonical_binary(record)

    downgraded =
      record
      |> Record.to_wire_map()
      |> Map.put("schema", "insider.confirmation-record/v1")
      |> readdress_map()

    assert {:error, %Error{code: :invalid_confirmation_record}} = Record.decode_map(downgraded)

    assert {:error, %Error{code: :unsupported_confirmation_record_schema}} =
             record
             |> Record.to_wire_map()
             |> Map.put("schema", "insider.confirmation-record/v999")
             |> Record.decode_map()
  end

  test "offline validation rejects semantic forgeries even with recomputed integrity" do
    record = fixture_record!()
    wire = Record.to_wire_map(record)

    partial_cleanup = %{
      "release" => "complete",
      "remaining_count" => 1,
      "remaining_fingerprint" => "sha256:" <> String.duplicate("3", 64),
      "status" => "partial"
    }

    complete_with_leftover = %{partial_cleanup | "status" => "complete"}
    unattempted_release = %{wire["cleanup"] | "release" => "not_attempted"}

    for forged <- [
          Map.put(wire, "outcome", "repaired"),
          put_in(wire, ["evidence", "observer"], nil),
          put_in(wire, ["evidence", "owner_fingerprint"], nil),
          put_in(wire, ["evidence", "lease_execution"], nil),
          put_in(wire, ["evidence", "scenario_status"], nil),
          Map.put(wire, "cleanup", complete_with_leftover),
          Map.put(wire, "cleanup", partial_cleanup),
          Map.put(wire, "cleanup", unattempted_release)
        ] do
      assert {:error, %Error{code: :invalid_confirmation_record}} =
               forged |> resign_record() |> Record.decode_map()
    end
  end

  test "receipt derives incompleteness from every observation-accounting field" do
    failures = [
      {"armed_before_scenario", false},
      {"finalized_after_scenario", false},
      {"complete", false},
      {"dropped", 1},
      {"gaps", 1},
      {"truncated", true}
    ]

    for {field, value} <- failures do
      options = receipt_options([])
      evidence = options |> Keyword.fetch!(:evidence) |> Map.put(field, value)

      options =
        options |> Keyword.put(:evidence, evidence) |> Keyword.put(:reason, "observer_failed")

      assert {:ok, receipt} = Receipt.new(options)
      assert receipt["evidence"][field] == value
    end

    complete = Receipt.new(receipt_options([])) |> elem(1)

    assert {:error, %Error{code: :invalid_confirmation_receipt}} =
             Receipt.validate(put_in(complete, ["evidence", "armed_before_scenario"], false))

    assert {:error, %Error{code: :invalid_confirmation_receipt}} =
             Receipt.validate(Map.put(complete, "unknown", true))

    assert {:error, %Error{code: :invalid_confirmation_receipt}} =
             Receipt.new(receipt_options([]) ++ [reason: nil])

    incomplete_failed =
      receipt_options([])
      |> Keyword.put(:scenario_status, "failed")
      |> Keyword.update!(:evidence, &Map.put(&1, "complete", false))
      |> Keyword.put(:reason, "scenario_failed")

    assert {:error, %Error{code: :invalid_confirmation_receipt}} =
             Receipt.new(incomplete_failed)

    for malformed <- [
          Map.put(complete, "evidence", nil),
          Map.put(complete, "repair_oracle", 42),
          Map.put(complete, "observer", 42),
          Map.put(complete, "manifest_id", 42),
          Map.put(complete, "expected_fingerprint", 42),
          Map.put(complete, "lease_execution", 42)
        ] do
      assert {:error, %Error{code: :invalid_confirmation_receipt}} =
               Receipt.validate(malformed)
    end

    assert {:error, %Error{code: :invalid_confirmation_receipt}} = Receipt.validate(42)
  end

  test "external confirmation receipt rejects independently valid outer binding changes" do
    {:ok, external} =
      "test/fixtures/external_process_receipt_v1.json"
      |> File.read!()
      |> String.trim_trailing("\n")
      |> Insider.Sentinel.ExternalProcess.Receipt.decode()

    report = external["report"]

    options =
      receipt_options(report["observed_fingerprints"])
      |> Keyword.merge(
        scenario_id: report["scenario_id"],
        expected_fingerprint: report["expected_fingerprint"],
        owner_fingerprint: report["owner_fingerprint"],
        observed_target_fingerprint: report["target_fingerprint"],
        observation_run_fingerprint: report["owner_fingerprint"],
        observer: report["observer"],
        scenario_status: "failed",
        reason: "scenario_failed",
        external_execution: external
      )

    assert {:ok, receipt} = Receipt.new_external(options)

    for forged <- [
          Map.put(receipt, "owner_fingerprint", "sha256:" <> String.duplicate("9", 64)),
          Map.put(receipt, "scenario_id", "sha256:" <> String.duplicate("8", 64)),
          Map.put(receipt, "expected_fingerprint", String.duplicate("7", 64)),
          Map.put(receipt, "observed_target_fingerprint", String.duplicate("6", 64))
        ] do
      assert {:error, %Error{code: :invalid_confirmation_receipt}} = Receipt.validate(forged)
    end
  end

  test "strict record options reject an oversized keyword list before construction" do
    options =
      fixture_record!()
      |> Record.to_wire_map()
      |> Map.drop(["id", "integrity", "schema"])
      |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)

    assert {:error, %Error{code: :invalid_confirmation_record}} =
             Record.new(options ++ [extra: true])
  end

  test "malformed or oversized confirmation options are rejected before admission", %{
    executor: executor
  } do
    {manifest, capsule, scenario, target} = inputs!()
    {request, context} = authority!(target, "confirmation-options")

    options = [
      request: request,
      context: context,
      body: ConfirmationBodyMatching,
      observer: @observer,
      repair_oracle: nil,
      extra: true
    ]

    assert {:error, %Error{code: :confirmation_input_mismatch}} =
             Confirmation.run(executor, manifest, capsule, scenario, target, options)

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  property "receipt accepts only sorted unique bounded fingerprint evidence" do
    check all(values <- uniq_list_of(binary(length: 32), max_length: 16), max_runs: 20) do
      normalized = values |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.sort()

      assert {:ok, receipt} = Receipt.new(receipt_options(normalized))

      assert {:error, %Error{code: :invalid_confirmation_receipt}} =
               Receipt.validate(%{
                 receipt
                 | "observed_incident_fingerprints" => [
                     String.duplicate("0", 64),
                     String.duplicate("0", 64)
                   ]
               })
    end
  end

  defp run(
         executor,
         manifest,
         capsule,
         scenario,
         target,
         request,
         context,
         body \\ ConfirmationBodyMatching
       ) do
    Confirmation.run(executor, manifest, capsule, scenario, target,
      request: request,
      context: context,
      body: body,
      observer: @observer,
      repair_oracle: nil
    )
  end

  defp inputs!(mode \\ "success", unique \\ 1) do
    inputs!(mode, unique, %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 400})
  end

  defp external_inputs!(mode \\ "success") do
    inputs!(mode, 1, %{
      "cleanup_timeout_ms" => @external_cleanup_timeout_ms,
      "max_duration_ms" => @external_cleanup_timeout_ms + 1
    })
  end

  defp inputs!(mode, unique, limits) do
    capsule = capsule!(mode, unique)
    expected = capsule.finding["fingerprint"]
    scenario = scenario!(expected, :ok, limits)
    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)

    {:ok, target} =
      Target.new(%{"id" => "test.confirmation-sandbox", "version" => 1}, capsule.provenance)

    {manifest, capsule, scenario, target}
  end

  defp scenario!(expected, status) do
    scenario!(expected, status, %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 400})
  end

  defp scenario!(expected, status, limits) do
    {:ok, contract} = Contract.describe(ConfirmationContract)

    steps =
      if status == :failed,
        do: [%{"id" => "failure", "type" => "action", "name" => "fail", "arguments" => []}],
        else: [
          %{"id" => "observe", "type" => "observation", "name" => "echo", "arguments" => ["ok"]}
        ]

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "confirmation-seed",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: steps,
        expected_incident_fingerprints: [expected],
        limits: limits
      )

    scenario
  end

  defp capsule!(mode, unique) do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json") |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)
    target = target_with_unique!(unique, mode)
    wire = legacy |> Capsule.to_wire_map() |> Map.put("provenance", target.provenance)
    content_digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> content_digest)
      |> put_in(["integrity", "content_digest"], content_digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp target_with_unique!(unique, mode \\ "success") do
    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => mode, "unique" => unique}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    {:ok, target} =
      Target.new(%{"id" => "test.confirmation-sandbox", "version" => 1}, provenance)

    target
  end

  defp authority!(target, request_id, timeout_ms \\ 1_500) do
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 10, max_bytes: 65_536)

    {:ok, request} =
      Request.new("verification.run",
        request_id: request_id,
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "verification-grant",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "verification-grant",
        audit_id: "verification-audit",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "confirmation-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "confirmation-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp body_input(manifest, capsule, scenario),
    do: %{
      "capsule_id" => capsule.id,
      "expected_fingerprint" => capsule.finding["fingerprint"],
      "manifest_id" => manifest.id,
      "observer" => %{"id" => "test.external-observer", "version" => 1},
      "repair_oracle" => nil,
      "scenario" => Scenario.to_wire_map(scenario)
    }

  defp await_external_child(target_fingerprint, deadline) do
    cond do
      ExternalLeaseRegistry.child_started_for_target?(target_fingerprint) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("external child did not start")

      true ->
        receive do
        after
          5 -> await_external_child(target_fingerprint, deadline)
        end
    end
  end

  defp assert_external_audit(owner) do
    on_exit(fn -> ExternalLeaseRegistry.purge_audit(owner) end)
    audit = ExternalLeaseRegistry.audit(owner)
    assert audit["process_down_before_provider_cleanup"]
    assert audit["process_down_after_provider_cleanup"]
    assert audit["root_removed"]
  end

  defp readdress_map(wire) do
    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp receipt_options(observed) do
    owner = "sha256:" <> String.duplicate("a", 64)

    [
      manifest_id: "sha256:" <> String.duplicate("b", 64),
      capsule_id: "sha256:" <> String.duplicate("c", 64),
      scenario_id: "sha256:" <> String.duplicate("d", 64),
      target_id: "sha256:" <> String.duplicate("e", 64),
      expected_fingerprint: String.duplicate("f", 64),
      owner_fingerprint: owner,
      observed_target_fingerprint: String.duplicate("1", 64),
      observation_run_fingerprint: owner,
      observer: @observer,
      lease_execution: "confirmed",
      scenario_status: "completed",
      observed_incident_fingerprints: observed,
      evidence: %{
        "armed_before_scenario" => true,
        "complete" => true,
        "dropped" => 0,
        "finalized_after_scenario" => true,
        "gaps" => 0,
        "truncated" => false
      },
      repair_oracle: nil,
      reason: nil
    ]
  end

  defp fixture_record! do
    expected = String.duplicate("f", 64)
    owner = "sha256:" <> String.duplicate("a", 64)

    {:ok, record} =
      Record.new(
        capsule_id: "sha256:" <> String.duplicate("c", 64),
        cleanup: %{
          "release" => "complete",
          "remaining_count" => 0,
          "remaining_fingerprint" => nil,
          "status" => "complete"
        },
        confirmed: true,
        evidence: %{
          "armed_before_scenario" => true,
          "complete" => true,
          "dropped" => 0,
          "finalized_after_scenario" => true,
          "gaps" => 0,
          "lease_execution" => "confirmed",
          "observation_run_fingerprint" => owner,
          "observer" => @observer,
          "owner_fingerprint" => owner,
          "receipt_digest" => String.duplicate("2", 64),
          "repair_oracle" => nil,
          "scenario_status" => "completed",
          "status" => "complete",
          "truncated" => false
        },
        expected_fingerprint: expected,
        manifest_id: "sha256:" <> String.duplicate("b", 64),
        observed_fingerprints: [expected],
        observed_target_fingerprint: String.duplicate("1", 64),
        operational_reason: nil,
        operational_status: "completed",
        outcome: "matching_failure",
        outcome_reason: nil,
        requested_target_fingerprint: String.duplicate("1", 64),
        scenario_id: "sha256:" <> String.duplicate("d", 64),
        uncertainty: []
      )

    record
  end

  defp resign_record(wire) do
    content_digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> content_digest)
    |> put_in(["integrity", "content_digest"], content_digest)
  end
end
