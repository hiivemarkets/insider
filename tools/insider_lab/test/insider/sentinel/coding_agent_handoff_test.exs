defmodule Insider.Sentinel.CodingAgentHandoffTest do
  use ExUnit.Case, async: true

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.CodingAgent.CandidateSubmission
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.Confirmation.Record
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.TestSupport.ConfirmationContract

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @target String.duplicate("1", 64)

  test "canonical handoff is a self-contained exact failed-regression request" do
    graph = graph!()

    assert {:ok, handoff} =
             Handoff.new(graph.capsule, graph.manifest, graph.regression, graph.runs)

    assert handoff.kind == "confirmed_regression_repair_request"
    assert handoff.request["candidate_status"] == "unverified"
    assert handoff.request["verification"] == "required"
    assert handoff.controls["model_invocation"] == "none"
    assert handoff.controls["repository_mutation"] == "none"
    assert handoff.controls["merge"] == "prohibited"
    assert handoff.evidence["evaluation"]["status"] == "failed"
    assert handoff.evidence["capsule"] == Capsule.to_wire_map(graph.capsule)

    run_ids = Enum.map(handoff.evidence["confirmation_runs"], & &1["id"])
    assert run_ids == Enum.sort(Enum.map(graph.runs, & &1.id))

    assert {:ok, bytes} = Handoff.canonical_binary(handoff)
    assert {:ok, ^handoff} = Handoff.decode(bytes)

    assert {:ok, ^handoff} =
             Handoff.validate_with_evidence(
               handoff,
               graph.capsule,
               graph.manifest,
               graph.regression,
               Enum.reverse(graph.runs)
             )
  end

  test "candidate submission remains inert and unverified for hostile opaque bytes" do
    graph = graph!()
    {:ok, handoff} = Handoff.new(graph.capsule, graph.manifest, graph.regression, graph.runs)

    hostile = <<0, 255, 10>> <> "$(touch /tmp/never)\n`git push`\nSECRET=value"
    assert {:ok, candidate} = Candidate.new(hostile, "opaque/v1")
    assert {:ok, submission} = CandidateSubmission.new(handoff, candidate)

    assert submission.kind == "inert_candidate_submission"

    assert submission.status == %{
             "candidate" => "declared_unverified",
             "draft_eligible" => false,
             "repair_claim" => "none"
           }

    assert submission.controls["application"] == "none"
    assert submission.controls["provider_creation"] == "blocked"
    assert submission.controls["publication"] == "blocked"
    assert submission.controls["verification"] == "required"

    assert {:ok, ^candidate} = CandidateSubmission.candidate(submission)
    assert {:ok, ^hostile} = Candidate.content(candidate)
    refute File.exists?("/tmp/never")

    assert {:ok, bytes} = CandidateSubmission.canonical_binary(submission)
    assert {:ok, ^submission} = CandidateSubmission.decode(bytes)

    assert {:ok, ^submission} =
             CandidateSubmission.validate_with_evidence(
               submission,
               handoff,
               candidate,
               graph.capsule,
               graph.manifest,
               graph.regression,
               graph.runs
             )
  end

  test "handoff rejects evidence that does not prove two fresh matching failures" do
    graph = graph!()
    [first, second] = graph.runs

    source = Record.decode_map(graph.regression.confirmed_record) |> elem(1)

    cases = [
      [first],
      [first, first],
      [source, second],
      [first, record!(graph, "e", "6", outcome: "nonreproduced", confirmed: false, observed: [])],
      [first, matching_record!(graph, "9", "8", uncertainty: ["not proven"])],
      [
        first,
        record!(graph, "8", "9",
          outcome: "matching_failure",
          confirmed: false,
          cleanup: partial_cleanup(),
          operational_status: "error",
          operational_reason: "sandbox_failed"
        )
      ]
    ]

    for runs <- cases do
      assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
               Handoff.new(graph.capsule, graph.manifest, graph.regression, runs)
    end
  end

  test "handoff rejects cross-graph substitutions and unavailable prerequisites" do
    graph = graph!()
    other = graph!("other")

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.new(other.capsule, graph.manifest, graph.regression, graph.runs)

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.new(graph.capsule, other.manifest, graph.regression, graph.runs)

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.new(graph.capsule, graph.manifest, other.regression, graph.runs)

    blocked = blocked_graph!()

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.new(
               blocked.capsule,
               blocked.manifest,
               blocked.regression,
               blocked.runs
             )
  end

  test "handoff rejects a ready same-capsule manifest for a different scenario" do
    graph = graph!()
    expected = graph.capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, other_scenario} =
      Scenario.new(contract,
        seed: "different-scenario",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: [
          %{
            "id" => "observe",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["different"]
          }
        ],
        expected_incident_fingerprints: [expected],
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 2_000}
      )

    {:ok, other_descriptor} = Scenario.descriptor(other_scenario)
    {:ok, other_manifest} = Manifest.new(graph.capsule, other_descriptor)

    split = %{graph | manifest: other_manifest}
    source = matching_record!(split, "d", "5")
    {:ok, regression} = Regression.materialize(source, graph.scenario)
    runs = [matching_record!(split, "e", "6"), matching_record!(split, "f", "7")]

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.new(graph.capsule, other_manifest, regression, runs)
  end

  test "exact recomputation rejects readdressed handoffs and candidate substitutions" do
    graph = graph!()
    {:ok, handoff} = Handoff.new(graph.capsule, graph.manifest, graph.regression, graph.runs)
    {:ok, candidate} = Candidate.new("repair-a", "opaque/v1")
    {:ok, other_candidate} = Candidate.new("repair-b", "opaque/v1")
    {:ok, submission} = CandidateSubmission.new(handoff, candidate)

    readdressed =
      handoff
      |> Handoff.to_wire_map()
      |> put_in(["request", "objective"], "claim_success")
      |> resign()

    assert {:error, %Error{code: :invalid_coding_agent_handoff}} =
             Handoff.decode_map(readdressed)

    assert {:error, %Error{code: :coding_agent_handoff_ineligible}} =
             Handoff.validate_with_evidence(
               handoff,
               graph.capsule,
               graph.manifest,
               graph.regression,
               graph!("substitute").runs
             )

    assert {:error, %Error{code: :candidate_submission_integrity_failed}} =
             CandidateSubmission.validate_with_evidence(
               submission,
               handoff,
               other_candidate,
               graph.capsule,
               graph.manifest,
               graph.regression,
               graph.runs
             )
  end

  test "strict ingress rejects malformed, noncanonical, oversized, unknown, and atom-bearing data" do
    graph = graph!()
    {:ok, handoff} = Handoff.new(graph.capsule, graph.manifest, graph.regression, graph.runs)
    {:ok, bytes} = Handoff.canonical_binary(handoff)
    unknown = "hostile_handoff_key_that_must_not_become_an_atom"
    refute_existing_atom(unknown)

    assert {:error, %Error{code: :invalid_coding_agent_handoff}} = Handoff.decode(bytes <> "\n")

    assert {:error, %Error{code: :coding_agent_handoff_limit_exceeded}} =
             Handoff.decode(String.duplicate("x", 1_572_865))

    assert {:error, %Error{code: :unsupported_coding_agent_handoff_schema}} =
             Handoff.decode_map(%{"schema" => ["hostile"]})

    assert {:error, %Error{code: :invalid_coding_agent_handoff}} =
             handoff |> Handoff.to_wire_map() |> Map.put(unknown, true) |> Handoff.decode_map()

    refute_existing_atom(unknown)

    atom_bearing = handoff |> Handoff.to_wire_map() |> Map.put(:hostile, true)

    assert {:error, %Error{code: :invalid_coding_agent_handoff}} =
             Handoff.decode_map(atom_bearing)

    {:ok, candidate} = Candidate.new("repair", "opaque/v1")
    {:ok, submission} = CandidateSubmission.new(handoff, candidate)
    {:ok, submission_bytes} = CandidateSubmission.canonical_binary(submission)

    assert {:error, %Error{code: :invalid_candidate_submission}} =
             CandidateSubmission.decode(submission_bytes <> "\n")

    assert {:error, %Error{code: :candidate_submission_limit_exceeded}} =
             CandidateSubmission.decode(String.duplicate("x", 32_769))
  end

  defp graph!(suffix \\ "base") do
    capsule = available_capsule!(suffix)
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "coding-agent-#{suffix}",
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
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)
    base = %{capsule: capsule, manifest: manifest, scenario: scenario}
    source = matching_record!(base, "a", "2")
    {:ok, regression} = Regression.materialize(source, scenario)

    Map.merge(base, %{
      regression: regression,
      runs: [matching_record!(base, "b", "3"), matching_record!(base, "c", "4")]
    })
  end

  defp blocked_graph! do
    bytes = fixture!("legacy_restart_capsule_v1.json") |> String.trim_trailing("\n")
    {:ok, capsule} = Capsule.decode(bytes)
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "blocked",
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
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)
    base = %{capsule: capsule, manifest: manifest, scenario: scenario}
    source = matching_record!(base, "d", "5")
    {:ok, regression} = Regression.materialize(source, scenario)

    Map.merge(base, %{
      regression: regression,
      runs: [matching_record!(base, "e", "6"), matching_record!(base, "f", "7")]
    })
  end

  defp available_capsule!(suffix) do
    bytes = fixture!("legacy_restart_capsule_v1.json") |> String.trim_trailing("\n")
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
      legacy |> Capsule.to_wire_map() |> Map.put("provenance", Provenance.to_wire_map(provenance))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> digest)
      |> put_in(["integrity", "content_digest"], digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp matching_record!(graph, run_character, receipt_character, options \\ []) do
    record!(
      graph,
      run_character,
      receipt_character,
      Keyword.merge([outcome: "matching_failure", confirmed: true], options)
    )
  end

  defp record!(graph, run_character, receipt_character, options) do
    expected = graph.capsule.finding["fingerprint"]
    owner = "sha256:" <> String.duplicate(run_character, 64)
    complete? = Keyword.get(options, :evidence_complete, true)

    {:ok, record} =
      Record.new(
        capsule_id: graph.capsule.id,
        cleanup: Keyword.get(options, :cleanup, complete_cleanup()),
        confirmed: Keyword.fetch!(options, :confirmed),
        evidence: %{
          "armed_before_scenario" => true,
          "complete" => complete?,
          "dropped" => 0,
          "finalized_after_scenario" => true,
          "gaps" => 0,
          "lease_execution" => "confirmed",
          "observation_run_fingerprint" => owner,
          "observer" => @observer,
          "owner_fingerprint" => owner,
          "receipt_digest" => String.duplicate(receipt_character, 64),
          "repair_oracle" => nil,
          "scenario_status" => "completed",
          "status" => if(complete?, do: "complete", else: "incomplete"),
          "truncated" => false
        },
        expected_fingerprint: expected,
        manifest_id: graph.manifest.id,
        observed_fingerprints: Keyword.get(options, :observed, [expected]),
        observed_target_fingerprint: @target,
        operational_reason: Keyword.get(options, :operational_reason),
        operational_status: Keyword.get(options, :operational_status, "completed"),
        outcome: Keyword.fetch!(options, :outcome),
        outcome_reason: Keyword.get(options, :outcome_reason),
        requested_target_fingerprint: @target,
        scenario_id: graph.scenario.id,
        uncertainty: Keyword.get(options, :uncertainty, [])
      )

    record
  end

  defp complete_cleanup,
    do: %{
      "release" => "complete",
      "remaining_count" => 0,
      "remaining_fingerprint" => nil,
      "status" => "complete"
    }

  defp partial_cleanup,
    do: %{
      "release" => "failed",
      "remaining_count" => 1,
      "remaining_fingerprint" => "sha256:" <> String.duplicate("9", 64),
      "status" => "partial"
    }

  defp resign(wire) do
    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp refute_existing_atom(value),
    do: assert_raise(ArgumentError, fn -> String.to_existing_atom(value) end)

  defp fixture!(name), do: Path.join([__DIR__, "..", "..", "fixtures", name]) |> File.read!()
end
