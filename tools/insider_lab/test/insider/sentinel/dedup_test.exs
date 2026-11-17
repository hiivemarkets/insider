defmodule Insider.Sentinel.DedupTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Contract
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Request
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Protocol.Error
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Dedup
  alias Insider.Sentinel.Dedup.Receipt
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.RepairReport.Manifest, as: RepairReportManifest
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.Verification
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Record, as: VerificationRecord
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.VerificationBody
  alias Insider.TestSupport.VerificationBodySuccess
  alias Insider.TestSupport.VerificationProvider

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}

  test "accepts a capsule before proposal eligibility and exact repeats are idempotent" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new()

    assert {:ok, state, receipt} = Dedup.ingest_capsule(state, capsule.bytes)
    assert receipt.outcome == "new_evidence"
    assert receipt.artifacts["proposal"] == nil

    assert receipt.counts["accepted_artifacts"] == 1
    assert receipt.counts["artifacts_in_group"] == 1
    assert receipt.counts["groups"] == 1
    assert receipt.counts["retained_bytes"] == byte_size(capsule.bytes)
    assert receipt.evidence_bytes == byte_size(capsule.bytes)

    assert {:ok, canonical} = Receipt.canonical_binary(receipt)
    assert {:ok, ^receipt} = Receipt.decode(canonical)
    refute canonical =~ "worker-a"
    refute canonical =~ "[REDACTED]"

    assert {:ok, ^state, duplicate} = Dedup.ingest_capsule(state, capsule.bytes)
    assert duplicate.outcome == "duplicate"
    assert duplicate.counts["accepted_artifacts"] == 1
  end

  test "fabricated proposal cannot consume capacity before graph-backed proposal admission" do
    graph = graph!()
    fabricated = proposal!(graph.capsule, "candidate-fabricated")
    {:ok, state} = Dedup.new(max_artifacts_per_group: 2)
    assert {:ok, state, _receipt} = Dedup.ingest_capsule(state, graph.capsule.bytes)

    assert {:error, %Error{code: :invalid_dedup_input}} =
             ingest_graph_proposal(state, fabricated, graph)

    assert {:ok, state, receipt} = ingest_graph_proposal(state, graph.proposal, graph)
    assert receipt.outcome == "new_evidence"
    assert state.receipt_count == 2
    assert {:ok, ^state, duplicate} = ingest_graph_proposal(state, graph.proposal, graph)
    assert duplicate.outcome == "duplicate"
  end

  test "proposal receipts account for the complete admission graph without exposing it" do
    graph = graph!()

    admission_bytes =
      Enum.sum(
        Enum.map(
          [
            graph.capsule.bytes,
            graph.proposal.bytes,
            graph.manifest.bytes,
            graph.verification.bytes,
            graph.report.bytes
          ],
          &byte_size/1
        )
      )

    {:ok, state} = Dedup.new(max_retained_bytes: admission_bytes)
    {:ok, state, _} = Dedup.ingest_capsule(state, graph.capsule.bytes)
    assert {:ok, state, receipt} = ingest_graph_proposal(state, graph.proposal, graph)
    assert receipt.evidence_bytes == admission_bytes
    assert receipt.counts["retained_bytes"] == admission_bytes

    assert {:ok, ^state, duplicate} = ingest_graph_proposal(state, graph.proposal, graph)
    assert duplicate.evidence_bytes == admission_bytes
    assert duplicate.counts["retained_bytes"] == admission_bytes

    {:ok, bounded} = Dedup.new(max_retained_bytes: byte_size(graph.capsule.bytes))
    {:ok, bounded, _} = Dedup.ingest_capsule(bounded, graph.capsule.bytes)

    assert {:ok, ^bounded, refused} = ingest_graph_proposal(bounded, graph.proposal, graph)
    assert refused.capacity == "retained_bytes"
    assert refused.evidence_bytes == admission_bytes
    assert refused.counts["retained_bytes"] == byte_size(graph.capsule.bytes)
  end

  test "new capsule content with the same finding groups as retained new evidence" do
    first = capsule!("worker-a")

    second =
      recanonicalize_capsule(first, fn wire ->
        put_in(wire, ["artifacts", Access.at(0), "sha256"], String.duplicate("b", 64))
      end)

    {:ok, state} = Dedup.new()

    assert {:ok, state, first_receipt} = Dedup.ingest_capsule(state, first.bytes)
    assert {:ok, _state, second_receipt} = Dedup.ingest_capsule(state, second.bytes)
    assert first.bytes != second.bytes
    assert first_receipt.group == second_receipt.group
    assert second_receipt.outcome == "new_evidence"
  end

  test "unrelated finding groups remain distinct and arrival order has the same retained state" do
    left = capsule!("worker-a")
    right = capsule!("worker-b")
    {:ok, initial} = Dedup.new()

    {:ok, left_then_right, left_receipt} = Dedup.ingest_capsule(initial, left.bytes)
    {:ok, left_then_right, right_receipt} = Dedup.ingest_capsule(left_then_right, right.bytes)
    {:ok, right_then_left, _receipt} = Dedup.ingest_capsule(initial, right.bytes)
    {:ok, right_then_left, _receipt} = Dedup.ingest_capsule(right_then_left, left.bytes)

    assert left_receipt.group != right_receipt.group
    assert left_then_right == right_then_left
  end

  test "per-group and group capacity refusals are visible and never evict retained evidence" do
    first = capsule!("worker-a")

    same_group =
      recanonicalize_capsule(first, fn wire ->
        put_in(wire, ["artifacts", Access.at(0), "sha256"], String.duplicate("b", 64))
      end)

    unrelated = capsule!("worker-b")
    {:ok, per_group} = Dedup.new(max_groups: 1, max_artifacts_per_group: 1)

    assert {:ok, per_group, _} = Dedup.ingest_capsule(per_group, first.bytes)
    assert {:ok, ^per_group, refused} = Dedup.ingest_capsule(per_group, same_group.bytes)
    assert refused.outcome == "capacity_refused"
    assert refused.capacity == "artifacts_per_group"

    assert {:ok, ^per_group, group_refused} = Dedup.ingest_capsule(per_group, unrelated.bytes)
    assert group_refused.capacity == "groups"
    assert {:ok, ^per_group} = Dedup.validate(per_group)
  end

  test "accepted-artifact receipt counter is bounded without evicting older evidence" do
    first = capsule!("worker-a")
    second = capsule!("worker-b")
    {:ok, state} = Dedup.new(max_receipts: 1)

    assert {:ok, state, _} = Dedup.ingest_capsule(state, first.bytes)
    assert {:ok, ^state, refused} = Dedup.ingest_capsule(state, second.bytes)
    assert refused.outcome == "capacity_refused"
    assert refused.capacity == "receipts"
    assert refused.counts["accepted_artifacts"] == 1
  end

  test "retained canonical-byte capacity refuses without keeping sensitive evidence" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new(max_retained_bytes: byte_size(capsule.bytes) - 1)

    assert {:ok, ^state, refused} = Dedup.ingest_capsule(state, capsule.bytes)
    assert refused.outcome == "capacity_refused"
    assert refused.capacity == "retained_bytes"
    assert refused.counts["retained_bytes"] == 0
  end

  test "state revalidation applies the configured input limit to retained capsules and proposal graphs" do
    capsule = capsule!("worker-a")
    {:ok, capsule_state} = Dedup.new(max_input_bytes: byte_size(capsule.bytes))
    {:ok, capsule_state, _} = Dedup.ingest_capsule(capsule_state, capsule.bytes)

    lowered_capsule = %{
      capsule_state
      | limits: %{capsule_state.limits | max_input_bytes: byte_size(capsule.bytes) - 1}
    }

    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(lowered_capsule)

    graph = graph!()

    graph_bytes =
      Enum.sum(
        Enum.map(
          [
            graph.proposal.bytes,
            graph.capsule.bytes,
            graph.manifest.bytes,
            graph.verification.bytes,
            graph.report.bytes
          ],
          &byte_size/1
        )
      )

    {:ok, graph_state} = Dedup.new(max_input_bytes: graph_bytes)
    {:ok, graph_state, _} = Dedup.ingest_capsule(graph_state, graph.capsule.bytes)
    {:ok, graph_state, _} = ingest_graph_proposal(graph_state, graph.proposal, graph)

    lowered_graph = %{
      graph_state
      | limits: %{graph_state.limits | max_input_bytes: graph_bytes - 1}
    }

    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(lowered_graph)
  end

  test "retained evidence detaches slices and revalidation rejects hidden binary parents" do
    graph = graph!()
    capsule_bytes = large_backed_slice(graph.capsule.bytes)
    proposal_bytes = large_backed_slice(graph.proposal.bytes)
    manifest_bytes = large_backed_slice(graph.manifest.bytes)
    verification_bytes = large_backed_slice(graph.verification.bytes)
    report_bytes = large_backed_slice(graph.report.bytes)

    assert Enum.all?(
             [capsule_bytes, proposal_bytes, manifest_bytes, verification_bytes, report_bytes],
             &(:binary.referenced_byte_size(&1) > byte_size(&1))
           )

    {:ok, state} = Dedup.new()
    {:ok, state, capsule_receipt} = Dedup.ingest_capsule(state, capsule_bytes)

    assert {:ok, state, proposal_receipt} =
             Dedup.ingest_proposal(
               state,
               proposal_bytes,
               capsule_bytes,
               manifest_bytes,
               verification_bytes,
               report_bytes
             )

    retained_capsule =
      get_in(state.groups, [
        capsule_receipt.group,
        :capsules,
        capsule_receipt.artifacts["capsule"]["canonical_sha256"]
      ])

    retained_proposal =
      get_in(state.groups, [
        proposal_receipt.group,
        :proposals,
        proposal_receipt.artifacts["proposal"]["canonical_sha256"]
      ])

    assert Enum.all?(
             [
               retained_capsule,
               retained_proposal.proposal,
               retained_proposal.manifest,
               retained_proposal.verification,
               retained_proposal.report
             ],
             &(:binary.referenced_byte_size(&1) == byte_size(&1))
           )

    for {path, hidden_bytes} <- [
          {[:capsules, capsule_receipt.artifacts["capsule"]["canonical_sha256"]], capsule_bytes},
          {[:proposals, proposal_receipt.artifacts["proposal"]["canonical_sha256"], :proposal],
           proposal_bytes},
          {[:proposals, proposal_receipt.artifacts["proposal"]["canonical_sha256"], :manifest],
           manifest_bytes},
          {[
             :proposals,
             proposal_receipt.artifacts["proposal"]["canonical_sha256"],
             :verification
           ], verification_bytes},
          {[:proposals, proposal_receipt.artifacts["proposal"]["canonical_sha256"], :report],
           report_bytes}
        ] do
      hidden_parent = %{
        state
        | groups: put_in(state.groups, [proposal_receipt.group | path], hidden_bytes)
      }

      assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(hidden_parent)
    end

    # The group key carries the `sha256:` prefix and is long enough to preserve
    # a parent binary. The 64-byte raw digest keys are copied by this OTP's
    # sub-binary implementation, but validation still checks every such key.
    backed_group = large_backed_slice(proposal_receipt.group)
    assert :binary.referenced_byte_size(backed_group) > byte_size(backed_group)

    hidden_group_key = %{
      state
      | groups: %{backed_group => Map.fetch!(state.groups, proposal_receipt.group)}
    }

    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(hidden_group_key)
  end

  test "forged, noncanonical, oversized, wrong-schema, and unbound ingress never mutates state" do
    capsule = capsule!("worker-a")
    proposal = proposal!(capsule, "candidate-a")
    {:ok, state} = Dedup.new(max_input_bytes: 10_000)

    assert {:error, %Error{code: :dedup_input_limit_exceeded}} =
             Dedup.ingest_capsule(state, String.duplicate("x", 10_001))

    assert {:error, %Error{code: :invalid_dedup_input}} =
             Dedup.ingest_capsule(state, capsule.bytes <> "\n")

    assert {:error, %Error{code: :invalid_dedup_input}} =
             Dedup.ingest_capsule(state, Jason.encode!(%{"schema" => "hostile/v1"}))

    forged =
      capsule.bytes
      |> Jason.decode!()
      |> Map.put("id", "sha256:" <> String.duplicate("0", 64))
      |> Canonical.encode()

    assert {:error, %Error{code: :invalid_dedup_input}} = Dedup.ingest_capsule(state, forged)

    assert {:error, %Error{code: :invalid_dedup_input}} =
             Dedup.ingest_proposal(state, proposal.bytes, capsule.bytes, "{}", "{}", "{}")

    assert {:ok, ^state} = Dedup.validate(state)
  end

  test "receipts reject readdressing, unknown fields, noncanonical encoding, and secret-shaped data" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new()
    {:ok, _state, receipt} = Dedup.ingest_capsule(state, capsule.bytes)
    {:ok, bytes} = Receipt.canonical_binary(receipt)

    assert {:error, %Error{code: :invalid_dedup_receipt}} = Receipt.decode(bytes <> "\n")

    assert {:error, %Error{code: :invalid_dedup_receipt}} =
             bytes
             |> Jason.decode!()
             |> Map.put("secret", "TOP_SECRET")
             |> Canonical.encode()
             |> Receipt.decode()

    assert {:error, %Error{code: :invalid_dedup_receipt}} =
             bytes
             |> Jason.decode!()
             |> Map.put("id", "sha256:" <> String.duplicate("f", 64))
             |> Canonical.encode()
             |> Receipt.decode()
  end

  test "state revalidation rejects moved buckets, hostile bytes, and duplicate references" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new()
    {:ok, state, receipt} = Dedup.ingest_capsule(state, capsule.bytes)
    [{group, contents}] = Map.to_list(state.groups)

    moved = %{state | groups: %{("sha256:" <> String.duplicate("f", 64)) => contents}}
    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(moved)

    hostile = %{
      state
      | groups:
          put_in(
            state.groups,
            [group, :capsules, receipt.artifacts["capsule"]["canonical_sha256"]],
            "{}"
          )
    }

    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(hostile)

    duplicated = %{
      state
      | groups: put_in(state.groups, [group, :capsules, String.duplicate("0", 64)], capsule.bytes)
    }

    assert {:error, %Error{code: :invalid_dedup_state}} = Dedup.validate(duplicated)
  end

  test "receipts reject impossible slot schemas, sizes, and bounded-count lies even when readdressed" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new()
    {:ok, _state, receipt} = Dedup.ingest_capsule(state, capsule.bytes)
    wire = Receipt.to_wire_map(receipt)

    for forged <- [
          put_in(wire, ["artifacts", "capsule", "schema"], "hostile/v1"),
          put_in(wire, ["artifacts", "capsule", "byte_size"], 1_048_577),
          put_in(wire, ["counts", "accepted_artifacts"], 4_097),
          put_in(wire, ["counts", "artifacts_in_group"], 33),
          put_in(wire, ["counts", "groups"], 129),
          put_in(wire, ["counts", "retained_bytes"], 16_777_217),
          put_in(wire, ["evidence_bytes"], 0),
          put_in(wire, ["evidence_bytes"], 2_097_153),
          put_in(wire, ["counts", "retained_bytes"], 0)
        ] do
      assert {:error, %Error{code: :invalid_dedup_receipt}} =
               forged |> readdress_receipt() |> Canonical.encode() |> Receipt.decode()
    end
  end

  test "receipts reject readdressed proposal and capacity relationships that cannot occur" do
    capsule = capsule!("worker-a")
    {:ok, state} = Dedup.new()
    {:ok, _state, receipt} = Dedup.ingest_capsule(state, capsule.bytes)
    wire = Receipt.to_wire_map(receipt)

    proposal_ref =
      wire["artifacts"]["capsule"]
      |> Map.put("schema", "insider.draft-proposal/v1")
      |> Map.put("byte_size", 1)

    impossible_proposal = put_in(wire, ["artifacts", "proposal"], proposal_ref)

    assert {:error, %Error{code: :invalid_dedup_receipt}} =
             impossible_proposal |> readdress_receipt() |> Canonical.encode() |> Receipt.decode()

    impossible_proposal_evidence =
      impossible_proposal
      |> put_in(["counts", "accepted_artifacts"], 2)
      |> put_in(["counts", "artifacts_in_group"], 2)
      |> put_in(["counts", "retained_bytes"], wire["evidence_bytes"] + proposal_ref["byte_size"])
      |> Map.put("evidence_bytes", wire["evidence_bytes"] + proposal_ref["byte_size"] - 1)

    assert {:error, %Error{code: :invalid_dedup_receipt}} =
             impossible_proposal_evidence
             |> readdress_receipt()
             |> Canonical.encode()
             |> Receipt.decode()

    for impossible_evidence_bytes <- [
          wire["evidence_bytes"] + proposal_ref["byte_size"] + 2,
          wire["evidence_bytes"] + proposal_ref["byte_size"] + 589_825
        ] do
      impossible =
        impossible_proposal
        |> put_in(["counts", "accepted_artifacts"], 2)
        |> put_in(["counts", "artifacts_in_group"], 2)
        |> put_in(["counts", "retained_bytes"], impossible_evidence_bytes)
        |> Map.put("evidence_bytes", impossible_evidence_bytes)

      assert {:error, %Error{code: :invalid_dedup_receipt}} =
               impossible |> readdress_receipt() |> Canonical.encode() |> Receipt.decode()
    end

    for impossible <- [
          wire
          |> Map.put("outcome", "capacity_refused")
          |> Map.put("capacity", "groups"),
          wire
          |> Map.put("outcome", "capacity_refused")
          |> Map.put("capacity", "artifacts_per_group")
          |> put_in(["counts", "artifacts_in_group"], 0),
          wire
          |> Map.put("outcome", "capacity_refused")
          |> Map.put("capacity", "receipts")
          |> put_in(["counts", "accepted_artifacts"], 0),
          impossible_proposal
          |> Map.put("outcome", "capacity_refused")
          |> Map.put("capacity", "retained_bytes")
          |> put_in(["counts", "accepted_artifacts"], 0)
          |> put_in(["counts", "groups"], 0)
          |> put_in(["counts", "artifacts_in_group"], 0)
        ] do
      assert {:error, %Error{code: :invalid_dedup_receipt}} =
               impossible |> readdress_receipt() |> Canonical.encode() |> Receipt.decode()
    end
  end

  defp ingest_graph_proposal(state, proposal, graph) do
    Dedup.ingest_proposal(
      state,
      proposal.bytes,
      graph.capsule.bytes,
      graph.manifest.bytes,
      graph.verification.bytes,
      graph.report.bytes
    )
  end

  defp readdress_receipt(wire) do
    content = Map.drop(wire, ["id", "integrity"])
    digest = Canonical.sha256(content)

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp large_backed_slice(bytes) do
    parent = :binary.copy(bytes <> String.duplicate("x", 5_000_000))
    binary_part(parent, 0, byte_size(bytes))
  end

  defp graph! do
    executor = graph_executor!()
    {regression, manifest, capsule, target} = graph_inputs!(executor)

    candidate =
      """
      diff --git a/test/example_test.exs b/test/example_test.exs
      --- a/test/example_test.exs
      +++ b/test/example_test.exs
      -    Application.put_env(:example, :mode, :faulty)
      +    Mimic.stub(ExampleConfig, :mode, fn -> :healthy end)
      """
      |> graph_candidate!()

    {request, context} = graph_authority!(target)

    {:ok, verification} =
      Verification.run(executor, regression, manifest, capsule.capsule, target, candidate,
        request: request,
        context: context,
        confirmation_body: ConfirmationBodyMatching,
        verification_body: VerificationBodySuccess,
        repair_oracle: @oracle
      )

    {:ok, report} = RepairReportManifest.new(capsule.capsule, manifest, verification)
    {:ok, proposal} = DraftProposal.new(capsule.capsule, manifest, verification, report)
    {:ok, manifest_bytes} = SentinelManifest.canonical_binary(manifest)
    {:ok, verification_bytes} = VerificationRecord.canonical_binary(verification)
    {:ok, report_bytes} = RepairReportManifest.canonical_binary(report)
    {:ok, proposal_bytes} = DraftProposal.canonical_binary(proposal)

    %{
      capsule: capsule,
      manifest: %{bytes: manifest_bytes},
      verification: %{bytes: verification_bytes},
      report: %{bytes: report_bytes},
      proposal: %{bytes: proposal_bytes, reference: reference(proposal, proposal_bytes)}
    }
  end

  defp graph_executor! do
    child =
      Supervisor.child_spec(
        {Executor,
         name: nil,
         providers: [VerificationProvider],
         bodies: [ConfirmationBodyMatching, VerificationBodySuccess]},
        id: make_ref()
      )

    start_supervised!(child)
  end

  defp graph_inputs!(executor) do
    capsule = graph_capsule!()
    expected = capsule.capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "dedup-graph-seed",
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
    {:ok, manifest} = SentinelManifest.new(capsule.capsule, descriptor)
    {:ok, target} = Target.new(VerificationProvider.identity(), capsule.capsule.provenance)
    {request, context} = graph_authority!(target)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule.capsule, scenario, target,
        request: request,
        context: context,
        body: ConfirmationBodyMatching,
        observer: @observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)
    {regression, manifest, capsule, target}
  end

  defp graph_capsule! do
    {:ok, legacy} =
      fixture!("legacy_restart_capsule_v1.json") |> String.trim_trailing("\n") |> Capsule.decode()

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

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> digest)
      |> put_in(["integrity", "content_digest"], digest)

    bytes = Canonical.encode(wire)
    {:ok, capsule} = Capsule.decode(bytes)
    %{bytes: bytes, capsule: capsule, reference: reference(capsule, bytes)}
  end

  defp graph_authority!(target) do
    timeout_ms = 8_000
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}
    suffix = System.unique_integer([:positive])
    {:ok, budget} = Budget.new(max_duration_ms: timeout_ms, max_events: 20, max_bytes: 262_144)

    {:ok, request} =
      Request.new("verification.run",
        request_id: "dedup-#{suffix}",
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "dedup-grant-#{suffix}",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "dedup-grant-#{suffix}",
        audit_id: "dedup-audit-#{suffix}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "dedup-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "dedup-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp graph_candidate!(content) do
    {:ok, candidate} = Candidate.new(content, "unified-diff/v1")
    VerificationBody.reset(candidate.id)

    on_exit(fn ->
      VerificationBody.reset(candidate.id)
      refute VerificationBody.tracked?(candidate.id)
    end)

    candidate
  end

  defp capsule!(offender_id) do
    fixture!("legacy_restart_capsule_v1.json")
    |> Jason.decode!()
    |> retarget_offender(offender_id)
    |> recanonicalize_capsule_wire()
    |> then(fn wire ->
      bytes = Canonical.encode(wire)
      {:ok, capsule} = Capsule.decode(bytes)
      %{bytes: bytes, capsule: capsule, reference: reference(capsule, bytes)}
    end)
  end

  defp recanonicalize_capsule(capsule, update) do
    capsule.bytes
    |> Jason.decode!()
    |> update.()
    |> recanonicalize_capsule_wire()
    |> then(fn wire ->
      bytes = Canonical.encode(wire)
      {:ok, decoded} = Capsule.decode(bytes)
      %{bytes: bytes, capsule: decoded, reference: reference(decoded, bytes)}
    end)
  end

  defp retarget_offender(wire, offender_id) do
    identity = Map.put(wire["finding"]["identity"], "offender_id", offender_id)

    finding =
      wire["finding"]
      |> Map.put("identity", identity)
      |> Map.put("fingerprint", finding_fingerprint(identity))

    events =
      Enum.map(wire["snapshot"]["events"], fn entry ->
        put_in(entry, ["event", "attributes", "offender_id"], offender_id)
      end)

    wire
    |> Map.put("finding", finding)
    |> put_in(["snapshot", "events"], events)
  end

  defp recanonicalize_capsule_wire(wire) do
    snapshot = wire["snapshot"] |> Map.update!("events", &rechain(&1, wire["snapshot"]))

    content =
      wire
      |> Map.put("snapshot", snapshot)
      |> Map.drop(["id", "integrity"])

    digest = Canonical.sha256(content)

    content
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{
      "algorithm" => "sha256",
      "content_digest" => digest,
      "event_chain_head" => List.last(snapshot["events"])["chain_digest"]
    })
  end

  defp rechain(events, snapshot) do
    genesis =
      Canonical.sha256(%{
        "freeze_id" => snapshot["freeze_id"],
        "instance_id" => snapshot["instance_id"],
        "schema" => "insider.incident-event-chain/v1"
      })

    {events, _last} =
      Enum.map_reduce(events, genesis, fn entry, previous ->
        entry = Map.delete(entry, "chain_digest")

        digest =
          Canonical.sha256(%{
            "entry" => entry,
            "previous_digest" => previous,
            "schema" => "insider.incident-event-chain-entry/v1"
          })

        {Map.put(entry, "chain_digest", digest), digest}
      end)

    events
  end

  defp finding_fingerprint(identity),
    do:
      Canonical.sha256(%{
        "detector" => "restart_recurrence",
        "identity" => identity,
        "version" => "1"
      })

  defp proposal!(capsule, candidate_seed) do
    digest = Canonical.sha256(%{"candidate" => candidate_seed})
    source_digest = String.duplicate("a", 64)

    sources =
      %{
        "capsule" => capsule.reference,
        "repair_report" => reference_for("test.repair-report/v1", source_digest),
        "sentinel_manifest" => reference_for("test.sentinel-manifest/v1", source_digest),
        "verification_record" => reference_for("test.verification-record/v1", source_digest)
      }

    body = %{
      "schema" => "insider.draft-proposal/v1",
      "kind" => "offline_draft_pr_proposal",
      "controls" => %{
        "draft" => true,
        "merge_prohibited" => true,
        "network_effect" => "none",
        "repository_mutation" => "none",
        "review_required" => true
      },
      "eligibility" => %{
        "evidence" => "eligible",
        "provider_creation" => "blocked",
        "publication" => "blocked",
        "reasons" => ["candidate_disclosure_attestation_missing"]
      },
      "disclosure" => %{
        "attestation_id" => nil,
        "candidate" => "unattested",
        "status" => "missing",
        "verification" => "unattested"
      },
      "sources" => sources,
      "evidence" => %{
        "candidate" => %{"id" => "sha256:" <> digest},
        "finding" => %{"fingerprint" => capsule.capsule.finding["fingerprint"]},
        "verdict" => %{"reasons" => [], "status" => "verified"}
      },
      "matrix" => matrix()
    }

    content_digest = Canonical.sha256(body)

    wire =
      Map.merge(body, %{
        "id" => "sha256:" <> content_digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => content_digest}
      })

    {:ok, proposal} = DraftProposal.decode_map(wire)
    {:ok, bytes} = DraftProposal.canonical_binary(proposal)
    %{bytes: bytes, proposal: proposal, reference: reference(proposal, bytes)}
  end

  defp matrix do
    ["source", "before", "before", "after", "after"]
    |> Enum.with_index()
    |> Enum.map(fn {phase, index} ->
      %{
        "cleanup" => "complete",
        "cleanup_release" => "complete",
        "cleanup_remaining_count" => 0,
        "cleanup_remaining_fingerprint" => nil,
        "evidence" => "complete",
        "finding" => if(index < 3, do: "observed", else: "absent"),
        "gates" => "passed",
        "operational" => "completed",
        "phase" => phase
      }
    end)
  end

  defp reference(artifact, bytes),
    do:
      reference_for(
        artifact.schema,
        Canonical.sha256_binary(bytes),
        artifact.id,
        byte_size(bytes)
      )

  defp reference_for(schema, digest), do: reference_for(schema, digest, "sha256:" <> digest, 1)

  defp reference_for(schema, digest, id, bytes),
    do: %{"byte_size" => bytes, "canonical_sha256" => digest, "id" => id, "schema" => schema}

  defp fixture!(name), do: Path.join([__DIR__, "..", "..", "fixtures", name]) |> File.read!()
end
