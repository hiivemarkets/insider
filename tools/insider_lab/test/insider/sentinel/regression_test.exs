defmodule Insider.Sentinel.RegressionTest do
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
  alias Insider.Sentinel.Confirmation.Record
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.ConfirmationProvider

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @other_observer %{"id" => "test.other-observer", "version" => 1}
  @baseline String.duplicate("1", 64)

  test "materializes exact source data and round trips a stable canonical fixture" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2")

    assert {:ok, regression} = Regression.materialize(source, scenario)
    assert regression.confirmed_record == Record.to_wire_map(source)
    assert regression.scenario == Scenario.to_wire_map(scenario)

    assert regression.expectation == %{
             "incident_fingerprint" => source.expected_fingerprint,
             "observer" => @observer
           }

    assert regression.execution_policy == %{
             "cleanup" => "required",
             "purpose" => "regression",
             "required_runs" => 2,
             "source_mutation" => "prohibited",
             "target_class" => "disposable"
           }

    assert {:ok, bytes} = Regression.canonical_binary(regression)

    assert bytes ==
             "test/fixtures/regression_v1.json"
             |> File.read!()
             |> String.trim_trailing("\n")

    assert {:ok, ^regression} = Regression.decode(bytes)
    assert {:ok, ^regression} = Regression.decode_map(Jason.decode!(bytes))
  end

  test "materialization fails closed for sources that do not prove the exact recipe" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2")
    other_scenario = %{scenario | id: "sha256:" <> String.duplicate("f", 64)}

    assert {:error, %Error{code: :regression_ineligible}} =
             Regression.materialize(source, other_scenario)

    incomplete =
      record!(scenario, "b", "3",
        outcome: "infrastructure_failure",
        confirmed: false,
        evidence_complete: false,
        outcome_reason: "observer_failed"
      )

    assert {:error, %Error{code: :regression_ineligible}} =
             Regression.materialize(incomplete, scenario)

    uncertain = %{source | uncertainty: ["not proven"]} |> resign_record!()

    assert {:error, %Error{code: :regression_ineligible}} =
             Regression.materialize(uncertain, scenario)

    with_oracle = put_in(source.evidence["repair_oracle"], repair_oracle()) |> resign_record!()

    assert {:error, %Error{code: :regression_ineligible}} =
             Regression.materialize(with_oracle, scenario)
  end

  test "two distinct fresh exact confirmations classify as consistently failed" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2")
    {:ok, regression} = Regression.materialize(source, scenario)
    first = matching_record!(scenario, "b", "3")
    second = matching_record!(scenario, "c", "4")

    assert {:ok,
            %{
              "schema" => "insider.regression-evaluation/v1",
              "status" => "failed",
              "reason" => "consistent_failure",
              "regression_id" => regression_id,
              "run_record_ids" => run_ids
            }} = Regression.classify(regression, [second, first])

    assert regression_id == regression.id
    assert run_ids == Enum.sort([first.id, second.id])
  end

  test "one live source and two fresh live confirmations prove the unchanged baseline fails" do
    executor =
      start_supervised!(
        {Executor,
         name: nil, providers: [ConfirmationProvider], bodies: [ConfirmationBodyMatching]}
      )

    {manifest, capsule, scenario, target} = live_inputs!()

    source = live_confirmation!(executor, manifest, capsule, scenario, target, "source")
    assert {:ok, regression} = Regression.materialize(source, scenario)

    first = live_confirmation!(executor, manifest, capsule, scenario, target, "fresh-1")
    second = live_confirmation!(executor, manifest, capsule, scenario, target, "fresh-2")

    assert Enum.all?([source, first, second], fn record ->
             record.outcome == "matching_failure" and record.confirmed and
               record.evidence["scenario_status"] == "completed" and
               record.evidence["observer"] == @observer and
               record.evidence["armed_before_scenario"] and
               record.evidence["finalized_after_scenario"] and
               record.evidence["lease_execution"] == "confirmed"
           end)

    assert Enum.uniq(
             Enum.map(
               [source, first, second],
               & &1.evidence["observation_run_fingerprint"]
             )
           )
           |> length() == 3

    assert {:ok, %{"status" => "failed", "reason" => "consistent_failure"}} =
             Regression.classify(regression, [first, second])

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "inventory-proved cleanup remains complete when the release callback failed" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2", cleanup_release: "failed")
    assert {:ok, regression} = Regression.materialize(source, scenario)

    first = matching_record!(scenario, "b", "3", cleanup_release: "failed")
    second = matching_record!(scenario, "c", "4")
    assert {:ok, %{"status" => "failed"}} = Regression.classify(regression, [first, second])
  end

  test "source replay and duplicate fresh runs are explicitly inconclusive" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2")
    {:ok, regression} = Regression.materialize(source, scenario)
    fresh = matching_record!(scenario, "b", "3")

    assert_inconclusive(regression, [source, fresh], "source_record_reuse")
    assert_inconclusive(regression, [fresh, fresh], "duplicate_run")

    replayed_observation = matching_record!(scenario, "a", "5")
    assert_inconclusive(regression, [replayed_observation, fresh], "source_record_reuse")
  end

  test "nonqualifying but valid run pairs never classify as failed" do
    scenario = scenario!()
    source = matching_record!(scenario, "a", "2")
    {:ok, regression} = Regression.materialize(source, scenario)
    fresh = matching_record!(scenario, "b", "3")

    cases = [
      {record!(scenario, "c", "4",
         outcome: "infrastructure_failure",
         confirmed: false,
         evidence_complete: false,
         outcome_reason: "observer_failed"
       ), "incomplete_run"},
      {record!(scenario, "d", "5",
         outcome: "unrelated_failure",
         confirmed: false,
         observed: [String.duplicate("e", 64)]
       ), "unrelated_failure"},
      {record!(scenario, "e", "6", outcome: "nonreproduced", confirmed: false, observed: []),
       "nonreproduced"},
      {record!(scenario, "f", "7",
         outcome: "repaired",
         confirmed: false,
         observed: [],
         repair_oracle: repair_oracle()
       ), "repair_evidence_present"},
      {matching_record!(scenario, "1", "8", target: String.duplicate("9", 64)), "wrong_target"},
      {matching_record!(scenario, "2", "9", observer: @other_observer), "wrong_observer"},
      {matching_record!(scenario, "6", "d", capsule_id: "sha256:" <> String.duplicate("8", 64)),
       "wrong_capsule"},
      {matching_record!(scenario, "7", "e", manifest_id: "sha256:" <> String.duplicate("8", 64)),
       "wrong_manifest"},
      {matching_record!(scenario, "3", "a", scenario_id: "sha256:" <> String.duplicate("9", 64)),
       "wrong_scenario"},
      {matching_record!(scenario, "4", "b", expected: String.duplicate("9", 64)),
       "wrong_expected_fingerprint"},
      {matching_record!(scenario, "5", "c", uncertainty: ["run remains uncertain"]),
       "uncertainty_present"}
    ]

    for {run, reason} <- cases do
      assert_inconclusive(regression, [fresh, run], reason)
    end
  end

  test "strict ingress rejects malformed, noncanonical, oversized, and unknown data atom-safely" do
    regression = regression!()
    {:ok, bytes} = Regression.canonical_binary(regression)
    unknown_key = "hostile_regression_key_that_must_never_become_an_atom"
    refute_existing_atom(unknown_key)

    assert {:error, %Error{code: :invalid_regression}} = Regression.decode(bytes <> "\n")

    assert {:error, %Error{code: :regression_limit_exceeded}} =
             Regression.decode(String.duplicate("x", 131_073))

    assert {:error, %Error{code: :unsupported_regression_schema}} =
             Regression.decode_map(%{"schema" => %{"hostile" => true}})

    assert {:error, %Error{code: :invalid_regression}} =
             regression
             |> Regression.to_wire_map()
             |> Map.put(unknown_key, true)
             |> Regression.decode_map()

    refute_existing_atom(unknown_key)

    assert {:error, %Error{code: :invalid_regression_runs}} =
             Regression.classify(regression, [regression.confirmed_record])

    assert {:error, %Error{code: :invalid_regression_runs}} =
             Regression.classify(regression, List.duplicate(regression, 100_000))

    assert {:error, %Error{code: :invalid_regression_runs}} =
             Regression.classify(regression, [regression | :improper])
  end

  test "offline validation rejects semantic forgeries with a recomputed outer digest" do
    regression = regression!()
    wire = Regression.to_wire_map(regression)

    forged_record = put_in(wire, ["confirmed_record", "confirmed"], false)
    forged_expectation = put_in(wire, ["expectation", "observer"], @other_observer)
    forged_policy = put_in(wire, ["execution_policy", "source_mutation"], "permitted")
    forged_scenario = put_in(wire, ["scenario", "expected_incident_fingerprints"], [])

    for forged <- [forged_record, forged_expectation, forged_policy, forged_scenario] do
      assert {:error, %Error{code: :invalid_regression}} =
               forged |> resign_wire() |> Regression.decode_map()
    end
  end

  defp regression! do
    scenario = scenario!()
    {:ok, regression} = Regression.materialize(matching_record!(scenario, "a", "2"), scenario)
    regression
  end

  defp scenario! do
    bytes = File.read!("test/fixtures/scenario_v1.json") |> String.trim_trailing("\n")
    {:ok, scenario} = Scenario.decode(bytes)
    scenario
  end

  defp live_inputs! do
    capsule = live_capsule!()
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "regression-live-seed",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: [
          %{
            "id" => "observe",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["unchanged-baseline"]
          }
        ],
        expected_incident_fingerprints: [expected],
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)

    {:ok, target} =
      Target.new(%{"id" => "test.confirmation-sandbox", "version" => 1}, capsule.provenance)

    {manifest, capsule, scenario, target}
  end

  defp live_capsule! do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json")
      |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => "unchanged", "unique" => 1}},
        configuration: {:available, %{"config" => "regression-live"}},
        dependencies: {:available, %{"lock" => "regression-live"}},
        runtime: {:available, %{"otp" => "regression-live"}},
        target: {:available, %{"class" => "fixture"}}
      )

    wire =
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))

    content_digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> content_digest)
      |> put_in(["integrity", "content_digest"], content_digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp live_confirmation!(executor, manifest, capsule, scenario, target, request_id) do
    {request, context} = live_authority!(target, request_id)

    {:ok, record} =
      Confirmation.run(executor, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: ConfirmationBodyMatching,
        observer: @observer,
        repair_oracle: nil
      )

    record
  end

  defp live_authority!(target, request_id) do
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}

    {:ok, budget} = Budget.new(max_duration_ms: 5_000, max_events: 10, max_bytes: 65_536)

    {:ok, request} =
      Request.new("verification.run",
        request_id: "regression-#{request_id}",
        environment: :test,
        target: runtime_target,
        timeout_ms: 5_000,
        budget: Map.from_struct(budget),
        capability: "regression-verification-grant",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "regression-verification-grant",
        audit_id: "regression-verification-audit-#{request_id}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + 5_000
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "regression-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "regression-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp matching_record!(scenario, run_character, receipt_character, options \\ []) do
    record!(
      scenario,
      run_character,
      receipt_character,
      Keyword.merge([outcome: "matching_failure", confirmed: true], options)
    )
  end

  defp record!(scenario, run_character, receipt_character, options) do
    expected = Keyword.get(options, :expected, hd(scenario.expected_incident_fingerprints))
    owner = "sha256:" <> String.duplicate(run_character, 64)
    complete? = Keyword.get(options, :evidence_complete, true)
    observed = Keyword.get(options, :observed, [expected])
    target = Keyword.get(options, :target, @baseline)
    repair_oracle = Keyword.get(options, :repair_oracle)

    {:ok, record} =
      Record.new(
        capsule_id: Keyword.get(options, :capsule_id, "sha256:" <> String.duplicate("c", 64)),
        cleanup: complete_cleanup(Keyword.get(options, :cleanup_release, "complete")),
        confirmed: Keyword.fetch!(options, :confirmed),
        evidence: %{
          "armed_before_scenario" => true,
          "complete" => complete?,
          "dropped" => 0,
          "finalized_after_scenario" => true,
          "gaps" => 0,
          "lease_execution" => "confirmed",
          "observation_run_fingerprint" => owner,
          "observer" => Keyword.get(options, :observer, @observer),
          "owner_fingerprint" => owner,
          "receipt_digest" => String.duplicate(receipt_character, 64),
          "repair_oracle" => repair_oracle,
          "scenario_status" => "completed",
          "status" => if(complete?, do: "complete", else: "incomplete"),
          "truncated" => false
        },
        expected_fingerprint: expected,
        manifest_id: Keyword.get(options, :manifest_id, "sha256:" <> String.duplicate("b", 64)),
        observed_fingerprints: observed,
        observed_target_fingerprint: target,
        operational_reason: nil,
        operational_status: "completed",
        outcome: Keyword.fetch!(options, :outcome),
        outcome_reason: Keyword.get(options, :outcome_reason),
        requested_target_fingerprint: target,
        scenario_id: Keyword.get(options, :scenario_id, scenario.id),
        uncertainty: Keyword.get(options, :uncertainty, [])
      )

    record
  end

  defp complete_cleanup(release) do
    %{
      "release" => release,
      "remaining_count" => 0,
      "remaining_fingerprint" => nil,
      "status" => "complete"
    }
  end

  defp repair_oracle do
    %{
      "identity" => %{"id" => "test.repair-oracle", "version" => 1},
      "receipt_digest" => String.duplicate("7", 64),
      "status" => "passed"
    }
  end

  defp assert_inconclusive(regression, records, reason) do
    assert {:ok, %{"status" => "inconclusive", "reason" => ^reason}} =
             Regression.classify(regression, records)
  end

  defp resign_record!(record) do
    wire = record |> Record.to_wire_map() |> resign_content()
    {:ok, resigned} = Record.decode_map(wire)
    resigned
  end

  defp resign_wire(wire), do: resign_content(wire)

  defp resign_content(wire) do
    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp refute_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
