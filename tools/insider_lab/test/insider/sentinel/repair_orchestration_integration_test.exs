defmodule Insider.Sentinel.RepairOrchestrationIntegrationTest do
  # The draft-creation provider fixture records its callbacks in one
  # process-independent state cell because the executor runs them in isolated
  # processes. Serial execution keeps those global observations attributable to
  # this test; every other resource below is unique to this test.
  use ExUnit.Case, async: false

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request, as: ProtocolRequest
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.CodingAgent.CandidateSubmission
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Dedup
  alias Insider.Sentinel.DraftCreation.Executor, as: DraftExecutor
  alias Insider.Sentinel.DraftCreation.Receipt
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.RepairReport.Manifest, as: RepairManifest
  alias Insider.Sentinel.Sandbox.Executor, as: SandboxExecutor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.SourceOwnership
  alias Insider.Sentinel.Verification
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Record, as: VerificationRecord
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.DraftCreationProvider, as: Provider
  alias Insider.TestSupport.DraftCreationProvider.DisclosureAuthority, as: Authority
  alias Insider.TestSupport.VerificationBody
  alias Insider.TestSupport.VerificationBodySuccess
  alias Insider.TestSupport.VerificationProvider

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}
  @declaration "lib/insider/sentinel/** sentinel-team\ntest/ test-team\n"

  setup do
    Provider.reset()
    on_exit(&Provider.reset/0)
    %{suffix: "repair-orchestration-#{System.unique_integer([:positive])}"}
  end

  test "the documented offline chain threads one candidate identity end to end", %{
    suffix: suffix
  } do
    sandbox = sandbox!()
    capsule = capsule!(suffix)
    {scenario, manifest, target} = scenario_inputs!(capsule, suffix)

    # Three fresh disposable confirmations: one materializes the regression and
    # two prove the bound defect reproduces before any candidate exists.
    [source, first_fresh, second_fresh] =
      for _run <- 1..3, do: confirm!(sandbox, manifest, capsule, scenario, target, suffix)

    assert {:ok, regression} = Regression.materialize(source, scenario)

    assert {:ok, handoff} =
             Handoff.new(capsule, manifest, regression, [first_fresh, second_fresh])

    assert handoff.evidence["evaluation"]["status"] == "failed"
    assert handoff.evidence["capsule"]["id"] == capsule.id

    candidate = candidate!(suffix)
    assert {:ok, submission} = CandidateSubmission.new(handoff, candidate)
    assert submission.status["candidate"] == "declared_unverified"
    assert submission.handoff["id"] == handoff.id

    # Verification never reuses the handoff's earlier failure runs.
    {request, context} = authority!(target, suffix)

    assert {:ok, verification} =
             Verification.run(sandbox, regression, manifest, capsule, target, candidate,
               request: request,
               context: context,
               confirmation_body: ConfirmationBodyMatching,
               verification_body: VerificationBodySuccess,
               repair_oracle: @oracle
             )

    assert verification.status == "verified"
    handoff_run_ids = Enum.map(handoff.evidence["confirmation_runs"], & &1["id"])
    verification_run_ids = Enum.map(verification.before_records, & &1["id"])
    assert handoff_run_ids -- verification_run_ids == handoff_run_ids
    refute source.id in verification_run_ids

    assert {:ok, repair_report} = RepairManifest.new(capsule, manifest, verification)
    assert {:ok, proposal} = DraftProposal.new(capsule, manifest, verification, repair_report)
    assert proposal.eligibility["provider_creation"] == "blocked"
    assert {:ok, ownership} = SourceOwnership.new(proposal, @declaration)

    assert {:ok, ^ownership} =
             SourceOwnership.validate_with_proposal(ownership, proposal, @declaration)

    assert ownership.attributions == [
             %{"owners" => ["sentinel-team"], "path" => "lib/insider/sentinel/example.ex"},
             %{"owners" => ["test-team"], "path" => "test/example_test.exs"}
           ]

    # Identity threading: one candidate through submission, verification, and
    # ownership; one capsule through handoff and dedup.
    assert submission.candidate["id"] == candidate.id
    assert verification.candidate["id"] == candidate.id
    assert ownership.candidate["id"] == candidate.id
    assert proposal.evidence["candidate"]["id"] == candidate.id

    {:ok, capsule_bytes} = Capsule.canonical_binary(capsule)
    {:ok, manifest_bytes} = SentinelManifest.canonical_binary(manifest)
    {:ok, verification_bytes} = VerificationRecord.canonical_binary(verification)
    {:ok, report_bytes} = RepairManifest.canonical_binary(repair_report)
    {:ok, proposal_bytes} = DraftProposal.canonical_binary(proposal)

    assert {:ok, ledger} = Dedup.new()
    assert {:ok, ledger, capsule_receipt} = Dedup.ingest_capsule(ledger, capsule_bytes)
    assert capsule_receipt.outcome == "new_evidence"

    assert {:ok, _ledger, proposal_receipt} =
             Dedup.ingest_proposal(
               ledger,
               proposal_bytes,
               capsule_bytes,
               manifest_bytes,
               verification_bytes,
               report_bytes
             )

    assert proposal_receipt.outcome == "new_evidence"
    assert proposal_receipt.artifacts["capsule"]["id"] == handoff.evidence["capsule"]["id"]
    assert proposal_receipt.artifacts["proposal"]["id"] == proposal.id

    evidence = %{
      capsule: capsule,
      handoff: handoff,
      manifest: manifest,
      proposal: proposal,
      repair_report: repair_report,
      submission: submission,
      verification: verification
    }

    executor = draft_executor!()

    {:ok, other_candidate} = Candidate.new("unbound candidate #{suffix}", "opaque/v1")
    {:ok, other_submission} = CandidateSubmission.new(handoff, other_candidate)

    assert {:error, %Error{code: :draft_creation_input_mismatch}} =
             DraftExecutor.create(
               executor,
               %{evidence | submission: other_submission},
               create_options()
             )

    assert Provider.authority_calls() == []
    assert Provider.provider_calls() == []

    assert {:ok, receipt} = DraftExecutor.create(executor, evidence, create_options())
    assert receipt.outcome == "provider_reported_created"
    assert receipt.controls["merge"] == "prohibited"
    assert receipt.controls["deploy"] == "prohibited"
    assert {:ok, receipt_bytes} = Receipt.canonical_binary(receipt)
    assert {:ok, ^receipt} = Receipt.decode(receipt_bytes)
    assert length(Provider.authority_calls()) == 1
    assert [{:provider, request_wire, _key}] = Provider.provider_calls()
    assert request_wire["proposal"]["id"] == proposal.id
    assert request_wire["submission"]["candidate"]["id"] == candidate.id

    assert verification.executor_counts == %{"active" => 0, "quarantined" => 0}
    assert {:ok, %{active: 0, quarantined: 0}} = SandboxExecutor.counts(sandbox)
  end

  defp sandbox! do
    child =
      Supervisor.child_spec(
        {SandboxExecutor,
         name: nil,
         providers: [VerificationProvider],
         bodies: [ConfirmationBodyMatching, VerificationBodySuccess]},
        id: make_ref()
      )

    start_supervised!(child)
  end

  defp draft_executor! do
    child =
      Supervisor.child_spec(
        {DraftExecutor,
         [
           providers: [Provider],
           effects_enabled: true,
           max_receipts: 4,
           max_pending: 4,
           disclosure_authorities: [Authority]
         ]},
        id: make_ref()
      )

    start_supervised!(child)
  end

  defp create_options,
    do: [provider: Provider.identity(), disclosure_authority: Authority.identity()]

  defp confirm!(sandbox, manifest, capsule, scenario, target, suffix) do
    {request, context} = authority!(target, suffix)

    {:ok, record} =
      Confirmation.run(sandbox, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: ConfirmationBodyMatching,
        observer: @observer,
        repair_oracle: nil
      )

    assert %ConfirmationRecord{confirmed: true, outcome: "matching_failure"} = record
    record
  end

  defp scenario_inputs!(capsule, suffix) do
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: suffix,
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
        limits: %{"cleanup_timeout_ms" => 500, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = SentinelManifest.new(capsule, descriptor)
    {:ok, target} = Target.new(VerificationProvider.identity(), capsule.provenance)
    {scenario, manifest, target}
  end

  defp capsule!(suffix) do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json")
      |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => suffix}},
        configuration: {:available, %{"config" => suffix}},
        dependencies: {:available, %{"lock" => suffix}},
        runtime: {:available, %{"otp" => suffix}},
        target: {:available, %{"class" => "fixture", "name" => suffix}}
      )

    wire =
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> put_in(["integrity", "content_digest"], digest)
    |> Capsule.decode_map()
    |> elem(1)
  end

  defp candidate!(suffix) do
    {:ok, candidate} =
      Candidate.new(
        modify_diff("lib/insider/sentinel/example.ex", suffix) <>
          modify_diff("test/example_test.exs", suffix),
        "unified-diff/v1"
      )

    VerificationBody.reset(candidate.id)

    on_exit(fn ->
      VerificationBody.reset(candidate.id)
      refute VerificationBody.tracked?(candidate.id)
    end)

    candidate
  end

  defp modify_diff(path, suffix),
    do:
      "diff --git a/#{path} b/#{path}\nindex 1111111..2222222 100644\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-#{suffix}\n+fixed-#{suffix}\n"

  defp authority!(target, suffix) do
    timeout_ms = 8_000
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}
    unique = System.unique_integer([:positive])

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 20, max_bytes: 262_144)

    {:ok, request} =
      ProtocolRequest.new("verification.run",
        request_id: "#{suffix}-#{unique}",
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "#{suffix}-grant-#{unique}",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "#{suffix}-grant-#{unique}",
        audit_id: "#{suffix}-audit-#{unique}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "repair-orchestration-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "repair-orchestration-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end
end
