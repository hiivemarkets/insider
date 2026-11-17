defmodule Insider.Sentinel.VerificationTest do
  use ExUnit.Case, async: true

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.Verification
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Receipt
  alias Insider.Sentinel.Verification.Record
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationBodyNone
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.ExternalConfirmationBodyExit2
  alias Insider.TestSupport.ExternalLeaseProvider
  alias Insider.TestSupport.ExternalVerificationBody
  alias Insider.TestSupport.VerificationBody
  alias Insider.TestSupport.VerificationBodyChangedFailure
  alias Insider.TestSupport.VerificationBodyBlocking
  alias Insider.TestSupport.VerificationBodyCancelled
  alias Insider.TestSupport.VerificationBodyFailedGate
  alias Insider.TestSupport.VerificationBodyFailingAfter
  alias Insider.TestSupport.VerificationBodyLeak
  alias Insider.TestSupport.VerificationBodyMissingGate
  alias Insider.TestSupport.VerificationBodyReceiptFailure
  alias Insider.TestSupport.VerificationBodyScenarioTimeout
  alias Insider.TestSupport.VerificationBodySuccess
  alias Insider.TestSupport.VerificationBodyTargetMismatch
  alias Insider.TestSupport.VerificationBodyDriftConfiguration
  alias Insider.TestSupport.VerificationBodyDriftDependencies
  alias Insider.TestSupport.VerificationBodyDriftRuntime
  alias Insider.TestSupport.VerificationBodyDriftTarget
  alias Insider.TestSupport.VerificationBodyDuplicateEvidence
  alias Insider.TestSupport.VerificationBodyErrorPartial
  alias Insider.TestSupport.VerificationBodyInventedOwner
  alias Insider.TestSupport.VerificationBodyUnchangedCode
  alias Insider.TestSupport.VerificationBodyUnknownGate
  alias Insider.TestSupport.VerificationBodyWrongBinding
  alias Insider.TestSupport.VerificationBodyWrongGateName
  alias Insider.TestSupport.VerificationProvider

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}
  @verification_bodies [
    VerificationBodySuccess,
    VerificationBodyFailingAfter,
    VerificationBodyChangedFailure,
    VerificationBodyMissingGate,
    VerificationBodyFailedGate,
    VerificationBodyTargetMismatch,
    VerificationBodyLeak
  ]

  # The scenario cleanup budget is forwarded as both the body stop budget and
  # the provider cleanup budget of every sandbox run, and the registry keeps
  # 50 ms of the cleanup budget for the inventory. A busy CI node can stall
  # the provider release for longer than the rest of a small budget, so the
  # fixture runs get generous budgets. Verification.run admits up to four
  # runs under one absolute deadline, and each admission needs both budgets
  # left on it. A passing run never waits them out.
  @cleanup_timeout_ms 1_000
  @request_timeout_ms 2 * @cleanup_timeout_ms + 8_000

  test "two fresh failures followed by two independent repaired runs verify canonically" do
    executor = executor!()
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("bounded repair")
    {request, context} = authority!(target, "success")

    assert {:ok, %Record{status: "verified", reasons: []} = record} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodySuccess,
               repair_oracle: @oracle
             )

    assert [_first_before, _second_before] = record.before_records
    assert [_first_after, _second_after] = record.after_attempts
    assert Enum.all?(record.after_attempts, &(&1["status"] == "completed"))
    assert record.executor_counts == %{"active" => 0, "quarantined" => 0}

    [first_before, second_before] = record.before_records
    source_id = regression.confirmed_record["id"]
    refute first_before["id"] == second_before["id"]
    refute first_before["id"] == source_id
    refute second_before["id"] == source_id

    refute first_before["evidence"]["observation_run_fingerprint"] ==
             second_before["evidence"]["observation_run_fingerprint"]

    [first_after, second_after] = record.after_attempts
    refute first_after["owner_fingerprint"] == second_after["owner_fingerprint"]

    Enum.each(record.after_attempts, fn attempt ->
      receipt = attempt["receipt"]
      assert receipt["owner_fingerprint"] == attempt["owner_fingerprint"]
      assert receipt["observation_run_fingerprint"] == attempt["owner_fingerprint"]
      assert receipt["observed_fingerprints"] == []
      assert receipt["evidence"]["complete"]
      assert receipt["evidence"]["dropped"] == 0
      assert receipt["evidence"]["gaps"] == 0

      assert attempt["cleanup"] == %{
               "release" => "complete",
               "remaining_count" => 0,
               "remaining_fingerprint" => nil,
               "status" => "complete"
             }

      assert Enum.sort(Map.keys(receipt["gates"])) == ["resources", "runtime", "static"]

      Enum.each(receipt["gates"], fn {_name, gate} ->
        assert gate["status"] == "passed"

        assert gate["code_fingerprint"] ==
                 receipt["post_provenance"]["components"]["code"]["fingerprint"]
      end)

      refute receipt["pre_provenance"]["components"]["code"]["fingerprint"] ==
               receipt["post_provenance"]["components"]["code"]["fingerprint"]

      for component <- ["configuration", "dependencies", "runtime", "target"] do
        assert receipt["pre_provenance"]["components"][component]["fingerprint"] ==
                 receipt["post_provenance"]["components"][component]["fingerprint"]
      end
    end)

    duplicate_attempt =
      second_after
      |> Map.put("owner_fingerprint", first_after["owner_fingerprint"])
      |> put_in(["receipt", "owner_fingerprint"], first_after["owner_fingerprint"])
      |> put_in(
        ["receipt", "observation_run_fingerprint"],
        first_after["owner_fingerprint"]
      )
      |> put_in(
        ["receipt", "oracle", "receipt_digest"],
        first_after["receipt"]["oracle"]["receipt_digest"]
      )

    before_records =
      Enum.map(record.before_records, fn wire ->
        {:ok, before_record} = ConfirmationRecord.decode_map(wire)
        before_record
      end)

    assert {:ok, %Record{status: "invalid", reasons: duplicate_reasons}} =
             Record.new(
               regression,
               candidate,
               @oracle,
               before_records,
               [first_after, duplicate_attempt],
               %{active: 0, quarantined: 0}
             )

    assert "duplicate_after_run" in duplicate_reasons

    uncertain_attempt = Map.put(first_after, "uncertainty", ["post observation uncertain"])

    assert {:ok, %Record{status: "invalid", reasons: uncertain_reasons}} =
             Record.new(
               regression,
               candidate,
               @oracle,
               before_records,
               [uncertain_attempt, second_after],
               %{active: 0, quarantined: 0}
             )

    assert "after_uncertain" in uncertain_reasons

    forged_uncertainty =
      record
      |> Record.to_wire_map()
      |> put_in(["after_attempts", Access.at(0), "uncertainty"], ["forged uncertainty"])
      |> readdress()

    assert {:error, %Error{code: :invalid_verification_record}} =
             Record.decode_map(forged_uncertainty)

    assert {:ok, bytes} = Record.canonical_binary(record)
    assert {:ok, ^record} = Record.decode(bytes)

    [first_attempt | _rest] = record.after_attempts
    assert {:ok, receipt_bytes} = Receipt.canonical_binary(first_attempt["receipt"])
    assert {:ok, _receipt} = Receipt.decode(receipt_bytes)

    forged =
      record
      |> Record.to_wire_map()
      |> put_in(["oracle", "id"], "test.forged-oracle")
      |> readdress()

    assert {:error, %Error{code: :invalid_verification_record}} = Record.decode_map(forged)
    assert VerificationBody.invocations(candidate.id) == 2
  end

  test "canonical external verification v2 fixture rejects downgrade and hostile ingress" do
    bytes = File.read!("test/fixtures/verification_receipt_v2.json") |> String.trim_trailing("\n")

    assert {:ok, %{"schema" => "insider.verification-receipt/v2"} = receipt} =
             Receipt.decode(bytes)

    assert {:ok, ^bytes} = Receipt.canonical_binary(receipt)

    assert {:error, %Error{code: :invalid_verification_receipt}} =
             receipt
             |> Map.put("schema", "insider.verification-receipt/v1")
             |> Receipt.decode_map()

    assert {:error, %Error{code: :unsupported_verification_receipt_schema}} =
             receipt
             |> Map.put("schema", "insider.verification-receipt/v999")
             |> Receipt.decode_map()

    assert {:error, %Error{code: :verification_receipt_limit_exceeded}} =
             Receipt.decode(String.duplicate("x", 32_769))

    assert Receipt.to_wire_map(receipt) == receipt

    assert {:error, %Error{code: :unsupported_verification_receipt_schema}} =
             Receipt.decode_map(Map.delete(receipt, "schema"))

    assert {:error, %Error{code: :invalid_verification_receipt}} = Receipt.decode_map(42)
    assert {:error, %Error{code: :invalid_verification_receipt}} = Receipt.validate(42)

    for forged <- [
          Map.put(receipt, "owner_fingerprint", "sha256:" <> String.duplicate("9", 64)),
          Map.put(receipt, "scenario_id", "sha256:" <> String.duplicate("8", 64)),
          Map.put(receipt, "expected_fingerprint", String.duplicate("7", 64)),
          Map.put(receipt, "observed_fingerprints", [String.duplicate("6", 64)]),
          Map.put(receipt, "oracle", nil),
          Map.put(receipt, "gates", %{"resources" => nil, "runtime" => nil, "static" => nil})
        ] do
      assert {:error, %Error{code: :invalid_verification_receipt}} = Receipt.validate(forged)
    end
  end

  test "Verification.run performs external before and after work on four independent owner leases" do
    executor = executor!([ExternalConfirmationBodyExit2, ExternalVerificationBody])

    {regression, manifest, capsule, target} =
      inputs!(
        executor,
        ExternalLeaseProvider,
        ExternalConfirmationBodyExit2,
        %{"id" => "test.external-observer", "version" => 1},
        15_000,
        1_000
      )

    candidate = candidate!("external bounded repair")
    {request, context} = authority!(target, "external-success", 15_000)

    assert {:ok, %Record{status: "verified", reasons: []} = record} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ExternalConfirmationBodyExit2,
               verification_body: ExternalVerificationBody,
               repair_oracle: @oracle
             )

    before_executions = Enum.map(record.before_records, & &1["evidence"]["external_execution"])
    after_executions = Enum.map(record.after_attempts, & &1["receipt"]["external_execution"])
    executions = before_executions ++ after_executions

    assert Enum.all?(before_executions, &(&1["exit_status"] == 2))
    assert Enum.all?(after_executions, &(&1["exit_status"] == 0))

    assert Enum.all?(
             executions,
             &(&1["lease_protocol"] == %{"armed" => 1, "scenario" => 2, "finalized" => 3})
           )

    assert executions |> Enum.map(& &1["owner_fingerprint"]) |> Enum.uniq() |> length() == 4
    assert executions |> Enum.map(& &1["lease_fingerprint"]) |> Enum.uniq() |> length() == 4

    Enum.each(record.after_attempts, fn attempt ->
      execution = attempt["receipt"]["external_execution"]
      assert execution["owner_fingerprint"] == attempt["owner_fingerprint"]
      assert execution["target_fingerprint"] == attempt["target_fingerprint"]
      assert execution["report"]["observed_fingerprints"] == []
    end)
  end

  test "passing before invalidates and never dispatches the candidate body" do
    executor = executor!()
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("passing-before repair")
    {request, context} = authority!(target, "passing-before")

    assert {:ok, %Record{status: "invalid", reasons: reasons}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyNone,
               verification_body: VerificationBodySuccess,
               repair_oracle: @oracle
             )

    assert "passing_before" in reasons
    assert VerificationBody.invocations(candidate.id) == 0
  end

  test "failing-after, changed failure, missing or failed gates, and target mismatch invalidate" do
    for {body, expected_reason} <- [
          {VerificationBodyFailingAfter, "failing_after"},
          {VerificationBodyChangedFailure, "changed_failure"},
          {VerificationBodyMissingGate, "missing_gate"},
          {VerificationBodyFailedGate, "failed_gate"},
          {VerificationBodyTargetMismatch, "target_mismatch"}
        ] do
      executor = executor!([body])
      {regression, manifest, capsule, target} = inputs!(executor)
      candidate = candidate!("repair #{expected_reason}")
      {request, context} = authority!(target, expected_reason)

      assert {:ok, %Record{status: "invalid", reasons: reasons}} =
               Verification.run(executor, regression, manifest, capsule, target, candidate,
                 request: request,
                 context: context,
                 confirmation_body: ConfirmationBodyMatching,
                 verification_body: body,
                 repair_oracle: @oracle
               )

      assert expected_reason in reasons
    end
  end

  test "invented owner, unchanged code, provenance drift, bad gates and bindings invalidate" do
    for {body, expected_reason} <- [
          {VerificationBodyInventedOwner, "receipt_binding_mismatch"},
          {VerificationBodyUnchangedCode, "repair_not_applied"},
          {VerificationBodyDriftConfiguration, "target_mismatch"},
          {VerificationBodyDriftDependencies, "target_mismatch"},
          {VerificationBodyDriftRuntime, "target_mismatch"},
          {VerificationBodyDriftTarget, "target_mismatch"},
          {VerificationBodyUnknownGate, "invalid_after_receipt"},
          {VerificationBodyWrongBinding, "receipt_binding_mismatch"},
          {VerificationBodyErrorPartial, "after_run_failed"},
          {VerificationBodyDuplicateEvidence, "duplicate_after_run"},
          {VerificationBodyWrongGateName, "invalid_after_receipt"}
        ] do
      executor = executor!([body])
      {regression, manifest, capsule, target} = inputs!(executor)
      candidate = candidate!("adversarial #{inspect(body)}")
      {request, context} = authority!(target, "adversarial")

      assert {:ok, %Record{status: "invalid", reasons: reasons}} =
               Verification.run(executor, regression, manifest, capsule, target, candidate,
                 request: request,
                 context: context,
                 confirmation_body: ConfirmationBodyMatching,
                 verification_body: body,
                 repair_oracle: @oracle
               )

      assert expected_reason in reasons
    end
  end

  test "a nonallowlisted body produces durable invalid evidence" do
    executor = executor!()
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("not allowlisted")
    {request, context} = authority!(target, "nonallowlisted")

    assert {:ok, %Record{status: "invalid", reasons: reasons}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: __MODULE__,
               repair_oracle: @oracle
             )

    assert "after_run_failed" in reasons
    assert VerificationBody.invocations(candidate.id) == 0
  end

  test "an immediately body-cancelled after run is durably invalid" do
    executor = executor!([VerificationBodyCancelled])
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("cancelled after")
    {request, context} = authority!(target, "cancelled-after")

    assert {:ok, %Record{status: "invalid", reasons: reasons}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodyCancelled,
               repair_oracle: @oracle
             )

    assert "after_run_failed" in reasons
    assert VerificationBody.invocations(candidate.id) == 2
  end

  test "a blocked first after run consumes the shared absolute deadline" do
    executor = executor!([VerificationBodyBlocking])
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("blocking after")
    {request, context} = authority!(target, "blocking-after", 2 * @cleanup_timeout_ms + 3_000)

    assert {:ok, %Record{status: "invalid", reasons: reasons}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodyBlocking,
               repair_oracle: @oracle
             )

    assert "after_run_failed" in reasons
    assert "after_uncertain" in reasons

    deadlines = VerificationBody.deadlines(candidate.id)
    assert VerificationBody.invocations(candidate.id) in [1, 2]
    assert [first_deadline | _rest] = deadlines

    admission_shape =
      case deadlines do
        [_one] -> :bounded
        [_one, _two] -> :bounded
        _other -> :invalid
      end

    assert admission_shape == :bounded
    assert [_one_deadline] = Enum.uniq(deadlines)
    assert Enum.all?(deadlines, &(&1 <= first_deadline))
  end

  test "an inner verification scenario timeout is durably invalid and cleans up" do
    executor = executor!([VerificationBodyScenarioTimeout])
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("inner scenario timeout")
    {request, context} = authority!(target, "inner-scenario-timeout")

    assert {:ok, %Record{status: "invalid", reasons: reasons} = record} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodyScenarioTimeout,
               repair_oracle: @oracle
             )

    assert "after_run_failed" in reasons

    assert VerificationBody.outcomes(candidate.id) == [
             :verification_scenario_failed,
             :verification_scenario_failed
           ]

    assert Enum.all?(record.after_attempts, fn attempt ->
             attempt["status"] == "error" and attempt["uncertainty"] == [] and
               attempt["cleanup"] == %{
                 "release" => "complete",
                 "remaining_count" => 0,
                 "remaining_fingerprint" => nil,
                 "status" => "complete"
               }
           end)

    assert record.executor_counts == %{"active" => 0, "quarantined" => 0}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "verification receipt construction failure is typed and cleans up" do
    executor = executor!([VerificationBodyReceiptFailure])
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("invalid receipt construction")
    {request, context} = authority!(target, "receipt-construction")

    assert {:ok, %Record{status: "invalid", reasons: reasons} = record} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodyReceiptFailure,
               repair_oracle: @oracle
             )

    assert "after_run_failed" in reasons

    assert VerificationBody.outcomes(candidate.id) == [
             :verification_receipt_failed,
             :verification_receipt_failed
           ]

    assert Enum.all?(record.after_attempts, &(&1["cleanup"]["status"] == "complete"))
    assert record.executor_counts == %{"active" => 0, "quarantined" => 0}
  end

  test "outright before confirmation errors never dispatch candidate work" do
    executor = executor!()
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("before error")
    {request, context} = authority!(target, "before-error")

    assert {:ok, %Record{status: "invalid", reasons: reasons}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: __MODULE__,
               verification_body: VerificationBodySuccess,
               repair_oracle: @oracle
             )

    assert "before_run_failed" in reasons
    assert VerificationBody.invocations(candidate.id) == 0
  end

  test "provider leftovers invalidate verification and remain visible in executor counts" do
    executor = executor!()
    {regression, manifest, capsule, target} = inputs!(executor)
    candidate = candidate!("leaking repair")
    {request, context} = authority!(target, "leak")

    assert {:ok, %Record{status: "invalid", reasons: reasons, executor_counts: counts}} =
             Verification.run(executor, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodyLeak,
               repair_oracle: @oracle
             )

    assert "resource_leak" in reasons
    assert "executor_leak" in reasons
    assert counts["quarantined"] == 2
  end

  test "candidate ingress is canonical, bounded, and atom safe" do
    candidate = candidate!("diff", "unified-diff/v1")
    assert {:ok, bytes} = Candidate.canonical_binary(candidate)
    assert {:ok, ^candidate} = Candidate.decode(bytes)

    assert {:error, %Error{code: :verification_candidate_limit_exceeded}} =
             Candidate.new(String.duplicate("x", 16_385), "opaque/v1")

    huge_wire =
      candidate
      |> Candidate.to_wire_map()
      |> Map.put("content_base64", String.duplicate("A", 1_000_000))

    assert {:error, %Error{code: :invalid_verification_candidate}} =
             Candidate.decode_map(huge_wire)

    assert {:error, %Error{code: :invalid_verification_candidate}} =
             Candidate.new("diff", "shell-command/v1")

    hostile = "verification_hostile_atom_key"
    assert_raise ArgumentError, fn -> String.to_existing_atom(hostile) end

    assert {:error, %Error{code: :invalid_verification_candidate}} =
             candidate
             |> Candidate.to_wire_map()
             |> Map.put(hostile, true)
             |> Candidate.decode_map()

    assert_raise ArgumentError, fn -> String.to_existing_atom(hostile) end

    assert {:error, %Error{code: :invalid_verification_receipt}} =
             Receipt.new([{:regression_id, "sha256:" <> String.duplicate("0", 64)} | :improper])

    huge_options = List.duplicate({:regression_id, "untrusted"}, 100_000)
    assert {:error, %Error{code: :invalid_verification_receipt}} = Receipt.new(huge_options)

    assert {:error, %Error{code: :verification_receipt_limit_exceeded}} =
             Receipt.decode(String.duplicate("x", 32_769))

    assert {:error, %Error{code: :verification_record_limit_exceeded}} =
             Record.decode(String.duplicate("x", 262_145))
  end

  defp executor!(additional_bodies \\ []) do
    child =
      Supervisor.child_spec(
        {Executor,
         name: nil,
         providers: [VerificationProvider, ExternalLeaseProvider],
         bodies:
           Enum.uniq([
             ConfirmationBodyMatching,
             ConfirmationBodyNone | @verification_bodies ++ additional_bodies
           ])},
        id: make_ref()
      )

    start_supervised!(child)
  end

  defp inputs!(executor) do
    inputs!(executor, VerificationProvider, ConfirmationBodyMatching, @observer)
  end

  defp inputs!(executor, provider, confirmation_body, observer) do
    inputs!(executor, provider, confirmation_body, observer, @request_timeout_ms)
  end

  defp inputs!(executor, provider, confirmation_body, observer, timeout_ms) do
    inputs!(executor, provider, confirmation_body, observer, timeout_ms, @cleanup_timeout_ms)
  end

  defp inputs!(
         executor,
         provider,
         confirmation_body,
         observer,
         timeout_ms,
         cleanup_timeout_ms
       ) do
    capsule = capsule!()
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "verification-seed",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: [
          %{
            "id" => "observe",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["baseline"]
          }
        ],
        expected_incident_fingerprints: [expected],
        limits: %{"cleanup_timeout_ms" => cleanup_timeout_ms, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)
    {:ok, target} = Target.new(provider.identity(), capsule.provenance)
    {request, context} = authority!(target, "source", timeout_ms)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: confirmation_body,
        observer: observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)
    {regression, manifest, capsule, target}
  end

  defp capsule! do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json") |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => "baseline"}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    wire =
      legacy |> Capsule.to_wire_map() |> Map.put("provenance", Provenance.to_wire_map(provenance))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> digest)
      |> put_in(["integrity", "content_digest"], digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp authority!(target, id, timeout_ms \\ @request_timeout_ms) do
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 20, max_bytes: 262_144)

    {:ok, request} =
      Request.new("verification.run",
        request_id: "verification-#{id}",
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
        audit_id: "verification-audit-#{id}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "verification-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "verification-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp candidate!(content, format \\ "opaque/v1") do
    {:ok, candidate} = Candidate.new(content, format)
    VerificationBody.reset(candidate.id)

    on_exit(fn ->
      VerificationBody.reset(candidate.id)
      refute VerificationBody.tracked?(candidate.id)
    end)

    candidate
  end

  defp readdress(wire) do
    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> put_in(["integrity", "content_digest"], digest)
  end
end
