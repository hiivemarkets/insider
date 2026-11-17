defmodule Insider.Sentinel.RepairReportTest do
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
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.RepairReport
  alias Insider.Sentinel.RepairReport.Manifest
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

  test "derives a canonical evidence-rich report from a five-run proof" do
    {capsule, sentinel_manifest, verification} = evidence!()

    assert {:ok, %Manifest{} = report} =
             Manifest.new(capsule, sentinel_manifest, verification)

    assert report.verdict == %{"reasons" => [], "status" => "verified"}

    assert report.causal_summary["finding"]["fingerprint"] == capsule.finding["fingerprint"]

    assert report.causal_summary["finding"]["semantic_identity"] ==
             capsule.finding["details"]["identity"]

    assert Enum.map(report.causal_summary["events"], & &1["id"]) ==
             capsule.finding["evidence_event_ids"]

    assert report.reproduction["scenario"]["id"] ==
             verification.regression["scenario"]["id"]

    assert [source] = report.proof["source"]
    assert [_, _] = report.proof["before"]
    assert [_, _] = report.proof["after"]
    assert Enum.all?(report.proof["after"], &(&1["receipt_status"] == "bound"))
    assert source["outcome"] == "matching_failure"

    assert report.diffs["candidate"] == verification.candidate

    assert report.diffs["code_transition"]["before_fingerprint"] !=
             report.diffs["code_transition"]["after_fingerprint"]

    assert report.diffs["code_transition"]["unchanged_components"] ==
             ["configuration", "dependencies", "runtime", "target"]

    assert report.diffs["code_transition"]["changed_components"] == ["code"]
    assert report.diffs["code_transition"]["unknown_components"] == []

    assert [_, _, _, _, _] = report.matrix

    assert Enum.map(report.matrix, & &1["phase"]) == [
             "source",
             "before",
             "before",
             "after",
             "after"
           ]

    assert Enum.all?(Enum.take(report.matrix, 3), &(&1["finding"] == "observed"))
    assert Enum.all?(Enum.drop(report.matrix, 3), &(&1["finding"] == "absent"))
    assert Enum.all?(Enum.drop(report.matrix, 3), &(&1["gates"] == "passed"))

    uncertainty_codes = Enum.map(report.uncertainty, & &1["code"])
    assert "source_snapshot_incomplete" in uncertainty_codes
    assert "prehistory_unavailable" in uncertainty_codes
    refute "evicted_evidence" in uncertainty_codes
    refute "dropped_evidence" in uncertainty_codes
    assert "candidate_redaction_unattested" in uncertainty_codes
    assert "sha256_not_authenticity" in uncertainty_codes
    assert "scenario_scope_only" in uncertainty_codes

    assert report.redactions["candidate"]["coverage"] == "not_covered_by_capsule_policy"
    assert report.redactions["candidate"]["bytes_included"]

    assert {:ok, canonical} = Manifest.canonical_binary(report)
    assert {:ok, ^report} = Manifest.decode(canonical)

    assert {:ok, ^report} =
             Manifest.validate_with_evidence(report, capsule, sentinel_manifest, verification)

    assert {:ok, markdown} =
             RepairReport.render_markdown(report, capsule, sentinel_manifest, verification)

    assert markdown =~ "# Insider repair report"
    assert markdown =~ "Verdict: **verified**"
    assert markdown =~ "## Causal summary"
    assert markdown =~ "## Reproduction"
    assert markdown =~ "## Before/after proof"
    assert markdown =~ "## Candidate diff"
    assert markdown =~ "Application.put_env"
    assert markdown =~ "Mimic.stub"
    assert markdown =~ "## Provenance"
    assert markdown =~ "## Redaction boundary"
    assert markdown =~ "## Verification matrix"
    assert markdown =~ "## Uncertainty and limits"
    assert markdown =~ "source_snapshot_incomplete"
    assert markdown =~ "candidate_redaction_unattested"

    for event_id <- capsule.finding["evidence_event_ids"] do
      assert markdown =~ "`#{event_id}`"
    end

    refute markdown =~ "/Users/"
    refute markdown =~ "/private/tmp/"

    assert {:ok, ^markdown} =
             RepairReport.render_markdown(report, capsule, sentinel_manifest, verification)
  end

  test "reports retained event loss as explicit uncertainty" do
    {capsule, sentinel_manifest, verification} = evidence!(lossy: true)
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)
    uncertainty_codes = Enum.map(report.uncertainty, & &1["code"])

    assert "evicted_evidence" in uncertainty_codes
    assert "dropped_evidence" in uncertainty_codes

    assert {:ok, markdown} =
             RepairReport.render_markdown(report, capsule, sentinel_manifest, verification)

    assert markdown =~ "evicted_evidence"
    assert markdown =~ "dropped_evidence"
  end

  test "full validation rejects a self-consistent report bound to different evidence" do
    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)

    assert {:ok, other_manifest} =
             SentinelManifest.new(capsule, %{
               "fingerprint" => String.duplicate("f", 64),
               "status" => "available"
             })

    assert {:error, %Error{code: :repair_report_integrity_failed}} =
             Manifest.new(capsule, other_manifest, verification)

    assert {:error, %Error{code: :repair_report_integrity_failed}} =
             Manifest.validate_with_evidence(report, capsule, other_manifest, verification)

    assert {:error, %Error{code: :repair_report_integrity_failed}} =
             RepairReport.render_markdown(report, capsule, other_manifest, verification)
  end

  test "invalid verification renders invalid without hiding incomplete proof" do
    {capsule, sentinel_manifest, verification} = evidence!()
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)

    before =
      Enum.map(verification.before_records, fn wire ->
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    [first, second] = verification.after_attempts
    uncertain = Map.put(first, "uncertainty", ["post observation uncertain"])

    assert {:ok, %VerificationRecord{status: "invalid"} = invalid_verification} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               before,
               [uncertain, second],
               %{active: 0, quarantined: 0}
             )

    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, invalid_verification)
    assert report.verdict["status"] == "invalid"
    assert "after_uncertain" in report.verdict["reasons"]

    assert {:ok, markdown} =
             RepairReport.render_markdown(
               report,
               capsule,
               sentinel_manifest,
               invalid_verification
             )

    assert markdown =~ "Verdict: **invalid**"
    assert markdown =~ "after_uncertain"
    refute markdown =~ "repair is verified"

    assert {:ok, %VerificationRecord{status: "invalid"} = missing_before} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               [nil, Enum.at(before, 1)],
               verification.after_attempts,
               %{active: 0, quarantined: 0}
             )

    assert {:ok, missing_report} = Manifest.new(capsule, sentinel_manifest, missing_before)
    assert Enum.at(missing_report.matrix, 1)["operational"] == "missing"

    assert {:ok, missing_markdown} =
             RepairReport.render_markdown(
               missing_report,
               capsule,
               sentinel_manifest,
               missing_before
             )

    assert missing_markdown =~ "before_run_failed"
  end

  test "renders cleanup coherence and executor leaks instead of the coarse status" do
    {capsule, sentinel_manifest, verification} = evidence!()
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)

    before =
      Enum.map(verification.before_records, fn wire ->
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    [first, second] = verification.after_attempts

    leaking_cleanup = %{
      "status" => "complete",
      "release" => "not_attempted",
      "remaining_count" => 1,
      "remaining_fingerprint" => nil
    }

    first = Map.put(first, "cleanup", leaking_cleanup)

    assert {:ok, %VerificationRecord{status: "invalid"} = invalid_verification} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               before,
               [first, second],
               %{active: 1, quarantined: 1}
             )

    assert "resource_leak" in invalid_verification.reasons
    assert "executor_leak" in invalid_verification.reasons
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, invalid_verification)
    assert report.proof["executor_counts"] == %{"active" => 1, "quarantined" => 1}

    first_after = Enum.at(report.matrix, 3)
    assert first_after["cleanup"] == "not_complete"
    assert first_after["cleanup_release"] == "not_attempted"
    assert first_after["cleanup_remaining_count"] == 1

    assert {:ok, markdown} =
             RepairReport.render_markdown(
               report,
               capsule,
               sentinel_manifest,
               invalid_verification
             )

    assert markdown =~ "Executor counts: active `1`; quarantined `1`"
    assert markdown =~ "| not_complete | not_attempted | 1 |"
    refute markdown =~ "| after | 1 | complete | not_attempted | 1 |"
  end

  test "candidate rendering cannot inject HTML or terminate its code fence" do
    {capsule, sentinel_manifest, verification} = evidence!()
    {:ok, regression} = Regression.decode_map(verification.regression)

    before =
      Enum.map(verification.before_records, fn wire ->
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    hostile = "```\n<img src=x onerror=alert(1)>\n[click](https://example.invalid)\n"
    assert {:ok, candidate} = Candidate.new(hostile, "unified-diff/v1")

    assert {:ok, invalid_verification} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               before,
               verification.after_attempts,
               %{active: 0, quarantined: 0}
             )

    assert invalid_verification.status == "invalid"
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, invalid_verification)
    assert Enum.all?(report.proof["after"], &(&1["receipt_status"] == "unbound"))
    assert report.diffs["code_transition"]["changed_components"] == []

    assert report.diffs["code_transition"]["unknown_components"] ==
             ~w(code configuration dependencies runtime target)

    assert {:ok, markdown} =
             RepairReport.render_markdown(
               report,
               capsule,
               sentinel_manifest,
               invalid_verification
             )

    assert markdown =~ "````diff"
    assert markdown =~ hostile
    assert markdown =~ "unbound_receipt"
  end

  test "valid invalid records render even when a receipt has malformed provenance" do
    {capsule, sentinel_manifest, verification} = evidence!()
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)
    [first_after, second_after] = verification.after_attempts

    malformed_receipt = %{"pre_provenance" => "hostile"}
    first_after = Map.put(first_after, "receipt", malformed_receipt)

    assert {:ok, %VerificationRecord{status: "invalid"} = invalid_verification} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               [nil, nil],
               [first_after, second_after],
               %{active: 0, quarantined: 0}
             )

    assert "before_run_failed" in invalid_verification.reasons
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, invalid_verification)
    assert Enum.at(report.proof["after"], 0)["receipt_status"] == "invalid"
    assert get_in(report.provenance, ["comparison", "code", "status"]) == "changed"

    assert {:ok, markdown} =
             RepairReport.render_markdown(
               report,
               capsule,
               sentinel_manifest,
               invalid_verification
             )

    assert markdown =~ "Verdict: **invalid**"
    assert markdown =~ "invalid_receipt"

    second_after = Map.put(second_after, "receipt", %{"post_provenance" => ["hostile"]})

    assert {:ok, both_malformed} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               [nil, nil],
               [first_after, second_after],
               %{active: 0, quarantined: 0}
             )

    assert {:ok, unknown_report} = Manifest.new(capsule, sentinel_manifest, both_malformed)
    transition = unknown_report.diffs["code_transition"]
    assert transition["changed_components"] == []
    assert transition["unchanged_components"] == []
    assert transition["unknown_components"] == ~w(code configuration dependencies runtime target)
  end

  test "bounded source uncertainty cannot make a valid invalid verification unreportable" do
    {capsule, sentinel_manifest, verification} = evidence!()
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)
    uncertainty = Enum.map(1..16, &"bounded uncertainty #{&1}")

    before =
      Enum.map(verification.before_records, fn wire ->
        wire = wire |> Map.put("uncertainty", uncertainty) |> readdress()
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    after_attempts =
      Enum.map(verification.after_attempts, &Map.put(&1, "uncertainty", uncertainty))

    assert {:ok, %VerificationRecord{status: "invalid"} = invalid_verification} =
             VerificationRecord.new(
               regression,
               candidate,
               verification.oracle,
               before,
               after_attempts,
               %{active: 0, quarantined: 0}
             )

    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, invalid_verification)
    assert Enum.count_until(report.uncertainty, 65) == 65

    assert {:ok, markdown} =
             RepairReport.render_markdown(
               report,
               capsule,
               sentinel_manifest,
               invalid_verification
             )

    assert markdown =~ "bounded uncertainty 16"
  end

  test "rejects noncanonical, unsupported, oversized, and readdressed lies" do
    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)
    assert {:ok, canonical} = Manifest.canonical_binary(report)

    assert {:error, %Error{code: :invalid_repair_report_manifest}} =
             Manifest.decode(canonical <> "\n")

    assert {:error, %Error{code: :unsupported_repair_report_manifest_schema}} =
             report
             |> Manifest.to_wire_map()
             |> Map.put("schema", "insider.repair-report-manifest/v999")
             |> Manifest.decode_map()

    assert {:error, %Error{code: :repair_report_manifest_limit_exceeded}} =
             Manifest.decode(String.duplicate("x", 262_145))

    forged =
      report
      |> Manifest.to_wire_map()
      |> put_in(["verdict", "status"], "invalid")
      |> readdress()

    assert {:ok, forged_report} = Manifest.decode_map(forged)

    assert {:error, %Error{code: :repair_report_integrity_failed}} =
             Manifest.validate_with_evidence(
               forged_report,
               capsule,
               sentinel_manifest,
               verification
             )

    atom_forgery =
      report
      |> Manifest.to_wire_map()
      |> Map.put("causal_summary", %{"hostile" => :hostile})
      |> readdress()

    assert {:error, %Error{code: :invalid_repair_report_manifest}} =
             Manifest.decode_map(atom_forgery)
  end

  test "derives a deterministic offline draft proposal from exact verified evidence" do
    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)

    assert {:ok, %DraftProposal{} = proposal} =
             DraftProposal.new(capsule, sentinel_manifest, verification, report)

    assert proposal.kind == "offline_draft_pr_proposal"

    assert proposal.controls == %{
             "draft" => true,
             "merge_prohibited" => true,
             "network_effect" => "none",
             "repository_mutation" => "none",
             "review_required" => true
           }

    assert proposal.eligibility == %{
             "evidence" => "eligible",
             "provider_creation" => "blocked",
             "publication" => "blocked",
             "reasons" => ["candidate_disclosure_attestation_missing"]
           }

    assert proposal.disclosure == %{
             "attestation_id" => nil,
             "candidate" => "unattested",
             "status" => "missing",
             "verification" => "unattested"
           }

    assert proposal.matrix == report.matrix
    assert proposal.evidence["candidate"] == verification.candidate
    assert proposal.evidence["verdict"] == %{"reasons" => [], "status" => "verified"}

    assert Enum.sort(Map.keys(proposal.sources)) ==
             ~w(capsule repair_report sentinel_manifest verification_record)

    proposal_wire = DraftProposal.to_wire_map(proposal)
    refute Map.has_key?(proposal_wire, "repository")
    refute Map.has_key?(proposal_wire, "provider")
    refute Map.has_key?(proposal_wire, "branch")
    refute Map.has_key?(proposal_wire, "operation")

    assert {:ok, canonical} = DraftProposal.canonical_binary(proposal)
    assert {:ok, ^proposal} = DraftProposal.decode(canonical)

    assert {:ok, ^proposal} =
             DraftProposal.validate_with_evidence(
               proposal,
               capsule,
               sentinel_manifest,
               verification,
               report
             )

    assert {:ok, same} = DraftProposal.new(capsule, sentinel_manifest, verification, report)
    assert same == proposal
  end

  test "draft proposal rejects unverified, incomplete-cleanup, and drifted evidence" do
    {capsule, sentinel_manifest, verification} = evidence!()

    unverified =
      rebuild_verification!(verification, fn [first, second] ->
        [Map.put(first, "uncertainty", ["bounded uncertainty"]), second]
      end)

    assert {:ok, unverified_report} = Manifest.new(capsule, sentinel_manifest, unverified)

    assert {:error,
            %Error{
              code: :draft_proposal_ineligible,
              details: %{reasons: reasons}
            }} = DraftProposal.new(capsule, sentinel_manifest, unverified, unverified_report)

    assert "verification_not_verified" in reasons

    incomplete_cleanup =
      rebuild_verification!(verification, fn [first, second] ->
        cleanup = Map.put(first["cleanup"], "remaining_count", 1)
        [Map.put(first, "cleanup", cleanup), second]
      end)

    assert {:ok, cleanup_report} =
             Manifest.new(capsule, sentinel_manifest, incomplete_cleanup)

    assert {:error, %Error{code: :draft_proposal_ineligible, details: %{reasons: reasons}}} =
             DraftProposal.new(
               capsule,
               sentinel_manifest,
               incomplete_cleanup,
               cleanup_report
             )

    assert "cleanup_incomplete" in reasons

    drifted =
      rebuild_verification!(verification, fn [first, second] ->
        [Map.put(first, "target_fingerprint", String.duplicate("f", 64)), second]
      end)

    assert {:ok, drifted_report} = Manifest.new(capsule, sentinel_manifest, drifted)

    assert {:error, %Error{code: :draft_proposal_ineligible, details: %{reasons: reasons}}} =
             DraftProposal.new(capsule, sentinel_manifest, drifted, drifted_report)

    assert "verification_not_verified" in reasons
  end

  test "draft proposal uses the canonical cleanup release and inventory predicate" do
    {capsule, sentinel_manifest, verification} = evidence!()

    release_failed_but_empty =
      rebuild_verification!(verification, fn [first, second] ->
        cleanup = Map.put(first["cleanup"], "release", "failed")
        [Map.put(first, "cleanup", cleanup), second]
      end)

    assert release_failed_but_empty.status == "verified"

    assert {:ok, report} =
             Manifest.new(capsule, sentinel_manifest, release_failed_but_empty)

    assert {:ok, proposal} =
             DraftProposal.new(
               capsule,
               sentinel_manifest,
               release_failed_but_empty,
               report
             )

    forged_inventory =
      proposal
      |> DraftProposal.to_wire_map()
      |> put_in(
        ["matrix", Access.at(3), "cleanup_remaining_fingerprint"],
        "sha256:" <> String.duplicate("f", 64)
      )
      |> readdress()

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(forged_inventory)
  end

  test "draft proposal rejects forged evidence and bounded ingress failures" do
    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)
    assert {:ok, proposal} = DraftProposal.new(capsule, sentinel_manifest, verification, report)

    forged_report =
      report
      |> Manifest.to_wire_map()
      |> put_in(["matrix", Access.at(4), "finding"], "observed")
      |> readdress()

    assert {:ok, forged_report} = Manifest.decode_map(forged_report)

    assert {:error, %Error{code: :repair_report_integrity_failed}} =
             DraftProposal.new(capsule, sentinel_manifest, verification, forged_report)

    forged_proposal =
      proposal
      |> DraftProposal.to_wire_map()
      |> put_in(["controls", "repository_mutation"], "allowed")
      |> readdress()

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(forged_proposal)

    readdressed_proposal =
      proposal
      |> DraftProposal.to_wire_map()
      |> put_in(["sources", "capsule", "id"], "sha256:" <> String.duplicate("f", 64))
      |> readdress()

    assert {:ok, readdressed_proposal} = DraftProposal.decode_map(readdressed_proposal)

    assert {:error, %Error{code: :draft_proposal_integrity_failed}} =
             DraftProposal.validate_with_evidence(
               readdressed_proposal,
               capsule,
               sentinel_manifest,
               verification,
               report
             )

    assert {:ok, canonical} = DraftProposal.canonical_binary(proposal)

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode(canonical <> "\n")

    assert {:error, %Error{code: :draft_proposal_limit_exceeded}} =
             DraftProposal.decode(String.duplicate("x", 131_073))
  end

  test "draft proposal schema rejects unsupported, atom-bearing, deep, and oversized maps" do
    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)
    assert {:ok, proposal} = DraftProposal.new(capsule, sentinel_manifest, verification, report)
    wire = DraftProposal.to_wire_map(proposal)

    assert {:error, %Error{code: :unsupported_draft_proposal_schema}} =
             wire
             |> Map.put("schema", "insider.draft-proposal/v999")
             |> DraftProposal.decode_map()

    unknown_key = "draft_proposal_unknown_atom_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             wire |> Map.put(unknown_key, "hostile") |> DraftProposal.decode_map()

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    atom_bearing =
      wire
      |> update_in(["evidence", "candidate"], &Map.put(&1, "hostile", :atom))
      |> readdress()

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(atom_bearing)

    deeply_nested =
      wire
      |> update_in(
        ["evidence", "candidate"],
        &Map.put(
          &1,
          "hostile",
          %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => %{"f" => %{"g" => %{}}}}}}}}
        )
      )
      |> readdress()

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(deeply_nested)

    oversized_map =
      wire
      |> put_in(["evidence", "candidate", "content_base64"], String.duplicate("x", 262_145))
      |> readdress()

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(oversized_map)
  end

  test "draft proposal schema fails closed across malformed ingress paths" do
    assert {:error, %Error{code: :invalid_draft_proposal}} = DraftProposal.validate(:invalid)

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.canonical_binary(:invalid)

    assert {:error, %Error{code: :invalid_draft_proposal}} = DraftProposal.decode(:invalid)
    assert {:error, %Error{code: :invalid_draft_proposal}} = DraftProposal.decode("{")

    assert {:error, %Error{code: :unsupported_draft_proposal_schema}} =
             DraftProposal.decode_map(%{})

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(%{"schema" => "insider.draft-proposal/v1"})

    assert {:error, %Error{code: :invalid_draft_proposal}} =
             DraftProposal.decode_map(struct(DraftProposal))

    assert {:error, %Error{code: :invalid_capsule}} =
             DraftProposal.new(:invalid, :invalid, :invalid, :invalid)

    assert {:error, %Error{code: :draft_proposal_integrity_failed}} =
             DraftProposal.validate_with_evidence(
               :invalid,
               :invalid,
               :invalid,
               :invalid,
               :invalid
             )

    {capsule, sentinel_manifest, verification} = evidence!()
    assert {:ok, report} = Manifest.new(capsule, sentinel_manifest, verification)
    assert {:ok, proposal} = DraftProposal.new(capsule, sentinel_manifest, verification, report)

    for invalid <- [
          %{proposal | sources: nil},
          %{proposal | sources: Map.put(proposal.sources, "capsule", nil)},
          %{proposal | evidence: nil},
          %{proposal | matrix: nil},
          %{proposal | integrity: nil}
        ] do
      assert {:error, %Error{code: :invalid_draft_proposal}} =
               DraftProposal.validate(invalid)
    end
  end

  defp evidence!(options \\ []) do
    executor = executor!()
    {regression, sentinel_manifest, capsule, target} = inputs!(executor, options)

    candidate =
      """
      diff --git a/test/example_test.exs b/test/example_test.exs
      --- a/test/example_test.exs
      +++ b/test/example_test.exs
      -    Application.put_env(:example, :mode, :faulty)
      +    Mimic.stub(ExampleConfig, :mode, fn -> :healthy end)
      +    # run=#{System.unique_integer([:positive])}
      """
      |> candidate!()

    {request, context} = authority!(target)

    {:ok, verification} =
      Verification.run(executor, regression, sentinel_manifest, capsule, target, candidate,
        request: request,
        context: context,
        confirmation_body: ConfirmationBodyMatching,
        verification_body: VerificationBodySuccess,
        repair_oracle: @oracle
      )

    {capsule, sentinel_manifest, verification}
  end

  defp rebuild_verification!(verification, update_after) do
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)

    before =
      Enum.map(verification.before_records, fn wire ->
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    {:ok, rebuilt} =
      VerificationRecord.new(
        regression,
        candidate,
        verification.oracle,
        before,
        update_after.(verification.after_attempts),
        %{active: 0, quarantined: 0}
      )

    rebuilt
  end

  defp executor! do
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

  defp inputs!(executor, options) do
    capsule = capsule!(options)
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "repair-report-seed",
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
    {request, context} = authority!(target)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: ConfirmationBodyMatching,
        observer: @observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)
    {regression, manifest, capsule, target}
  end

  defp capsule!(options) do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json")
      |> String.trim_trailing("\n")

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
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))
      |> maybe_add_loss(Keyword.get(options, :lossy, false))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> digest)
      |> put_in(["integrity", "content_digest"], digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp maybe_add_loss(wire, false), do: wire

  defp maybe_add_loss(wire, true) do
    counters = wire["snapshot"]["counters"]

    counters =
      counters
      |> Map.put("evicted", 1)
      |> Map.put("rate_limited", 1)
      |> Map.update!("offered", &(&1 + 1))

    wire
    |> put_in(["snapshot", "counters"], counters)
    |> put_in(
      ["snapshot", "gaps"],
      ["prehistory_unavailable", "evicted_evidence", "dropped_evidence"]
    )
  end

  defp authority!(target) do
    timeout_ms = 8_000
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}
    suffix = System.unique_integer([:positive])

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 20, max_bytes: 262_144)

    {:ok, request} =
      Request.new("verification.run",
        request_id: "repair-report-#{suffix}",
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "repair-report-grant-#{suffix}",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "repair-report-grant-#{suffix}",
        audit_id: "repair-report-audit-#{suffix}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "repair-report-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "repair-report-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp candidate!(content) do
    {:ok, candidate} = Candidate.new(content, "unified-diff/v1")
    VerificationBody.reset(candidate.id)

    on_exit(fn ->
      VerificationBody.reset(candidate.id)
      refute VerificationBody.tracked?(candidate.id)
    end)

    candidate
  end

  defp readdress(wire) do
    content = Map.drop(wire, ["id", "integrity"])

    digest =
      content
      |> Insider.Event.Canonical.encode()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
