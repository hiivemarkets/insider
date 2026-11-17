defmodule Insider.Sentinel.Confirmation do
  @moduledoc """
  Validates and confirms one incident on an exact disposable sandbox target.

  The selected body is trusted host configuration. It owns the concrete
  scenario executor, contract allowlist, and detector observer allowlist; the
  portable input only supplies already-validated canonical data.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Protocol.Result
  alias Insider.Protocol.StrictOptions
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation.Receipt
  alias Insider.Sentinel.Confirmation.Record
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Sandbox
  alias Insider.Sentinel.Sandbox.Target

  @option_keys [:request, :context, :body, :observer, :repair_oracle]
  @component_names ["code", "configuration", "dependencies", "runtime", "target"]

  @spec run(Supervisor.supervisor(), term(), term(), term(), term(), keyword()) ::
          {:ok, Record.t()} | {:error, Error.t()}
  def run(sandbox_executor, manifest, capsule, scenario, target, options) do
    with true <- valid_options?(options),
         {:ok, valid_capsule} <- Capsule.validate(capsule),
         {:ok, valid_manifest} <- Manifest.validate_with_capsule(manifest, valid_capsule),
         {:ok, %{"status" => "ready"}} <- Manifest.readiness(valid_manifest, valid_capsule),
         {:ok, valid_scenario} <- Scenario.validate(scenario),
         {:ok, descriptor} <- Scenario.descriptor(valid_scenario),
         true <- descriptor == valid_manifest.prerequisites["scenario"],
         {:ok, valid_target} <- Target.validate(target),
         true <- target_matches_manifest?(valid_target, valid_manifest),
         {:ok, expected} <- primary_expected(valid_capsule, valid_scenario),
         body when is_atom(body) <- Keyword.get(options, :body),
         observer when is_map(observer) <- Keyword.get(options, :observer),
         repair_oracle <- Keyword.get(options, :repair_oracle),
         true <- valid_identity?(observer),
         true <- is_nil(repair_oracle) or valid_identity?(repair_oracle),
         input <-
           body_input(
             valid_manifest,
             valid_capsule,
             valid_scenario,
             expected,
             observer,
             repair_oracle
           ),
         %Result{} = sandbox_result <-
           Sandbox.run(
             sandbox_executor,
             valid_target,
             request: Keyword.get(options, :request),
             context: Keyword.get(options, :context),
             cleanup_timeout_ms: valid_scenario.limits["cleanup_timeout_ms"],
             body: {body, input, valid_scenario.limits["cleanup_timeout_ms"]}
           ) do
      build_record(
        valid_manifest,
        valid_capsule,
        valid_scenario,
        valid_target,
        expected,
        observer,
        repair_oracle,
        sandbox_result
      )
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> mismatch()
    end
  rescue
    _error -> {:error, Error.new(:operation_failed, "confirmation execution failed")}
  catch
    :exit, _reason ->
      {:error, Error.new(:operation_failed, "confirmation executor is unavailable")}
  end

  defp build_record(
         manifest,
         capsule,
         scenario,
         target,
         expected,
         observer,
         repair_oracle,
         sandbox_result
       ) do
    {operational_status, outcome, outcome_reason, evidence_status, observed, receipt_digest,
     receipt_summary} =
      classify(
        sandbox_result,
        manifest,
        capsule,
        scenario,
        target,
        expected,
        observer,
        repair_oracle
      )

    cleanup_status = sandbox_result.cleanup |> Map.get(:status, :unknown) |> Atom.to_string()

    confirmed =
      outcome == "matching_failure" and operational_status == "completed" and
        evidence_status == "complete" and cleanup_status == "complete" and
        expected in observed

    Record.new(
      manifest_id: manifest.id,
      capsule_id: capsule.id,
      scenario_id: scenario.id,
      requested_target_fingerprint: Target.target_fingerprint(target),
      observed_target_fingerprint: sandbox_result.target_fingerprint,
      operational_status: operational_status,
      operational_reason: operational_reason(sandbox_result.status),
      outcome: outcome,
      confirmed: confirmed,
      expected_fingerprint: expected,
      observed_fingerprints: observed,
      evidence:
        Map.merge(receipt_summary, %{
          "status" => evidence_status,
          "receipt_digest" => receipt_digest
        }),
      cleanup: cleanup_summary(sandbox_result.cleanup),
      outcome_reason: outcome_reason,
      uncertainty: bounded_uncertainty(sandbox_result.uncertainty)
    )
  end

  defp classify(
         %Result{value: %{"body_receipt" => receipt}} = sandbox_result,
         manifest,
         capsule,
         scenario,
         target,
         expected,
         observer,
         repair_oracle
       ) do
    receipt_digest = digest(receipt)

    case Receipt.validate(receipt) do
      {:ok,
       %{
         "manifest_id" => manifest_id,
         "capsule_id" => capsule_id,
         "scenario_id" => scenario_id,
         "target_id" => target_id,
         "expected_fingerprint" => receipt_expected,
         "observed_target_fingerprint" => observed_target_fingerprint,
         "observation_run_fingerprint" => observation_run_fingerprint
       } = valid} ->
        if manifest_id == manifest.id and capsule_id == capsule.id and scenario_id == scenario.id and
             target_id == target.id and receipt_expected == expected and
             observed_target_fingerprint == sandbox_result.target_fingerprint and
             observation_run_fingerprint == result_owner_fingerprint(sandbox_result) and
             valid["owner_fingerprint"] == result_owner_fingerprint(sandbox_result) and
             valid["observer"] == observer and
             oracle_matches?(valid["repair_oracle"], repair_oracle),
           do:
             classify_receipt(
               valid,
               expected,
               receipt_digest,
               repair_oracle,
               operational_status(sandbox_result.status)
             ),
           else:
             invalid_receipt_classification(
               receipt_digest,
               operational_status(sandbox_result.status)
             )

      _error ->
        invalid_receipt_classification(receipt_digest, operational_status(sandbox_result.status))
    end
  end

  defp classify(
         %Result{status: status},
         _manifest,
         _capsule,
         _scenario,
         _target,
         _expected,
         _observer,
         _oracle
       ) do
    operational_status = operational_status(status)

    {operational_status, "infrastructure_failure", "evidence_unavailable", "incomplete", [],
     digest(%{}), empty_receipt_summary()}
  end

  defp classify_receipt(receipt, expected, receipt_digest, repair_oracle, operational_status) do
    observed = receipt["observed_incident_fingerprints"]

    evidence_status =
      if complete_evidence?(receipt["evidence"]), do: "complete", else: "incomplete"

    cond do
      evidence_status != "complete" ->
        classification(
          operational_status,
          "infrastructure_failure",
          "observer_failed",
          "incomplete",
          observed,
          receipt_digest,
          receipt
        )

      expected in observed ->
        classification(
          operational_status,
          "matching_failure",
          nil,
          "complete",
          observed,
          receipt_digest,
          receipt
        )

      receipt["scenario_status"] != "completed" ->
        classification(
          operational_status,
          "infrastructure_failure",
          "scenario_failed",
          "complete",
          observed,
          receipt_digest,
          receipt
        )

      observed != [] ->
        classification(
          operational_status,
          "unrelated_failure",
          nil,
          "complete",
          observed,
          receipt_digest,
          receipt
        )

      repair_oracle != nil and receipt["repair_oracle"]["status"] == "passed" ->
        classification(
          operational_status,
          "repaired",
          nil,
          "complete",
          [],
          receipt_digest,
          receipt
        )

      true ->
        classification(
          operational_status,
          "nonreproduced",
          nil,
          "complete",
          [],
          receipt_digest,
          receipt
        )
    end
  end

  defp complete_evidence?(evidence),
    do:
      evidence["armed_before_scenario"] and evidence["finalized_after_scenario"] and
        evidence["complete"] and evidence["dropped"] == 0 and evidence["gaps"] == 0 and
        not evidence["truncated"]

  defp oracle_matches?(nil, nil), do: true
  defp oracle_matches?(%{"identity" => identity}, identity), do: true
  defp oracle_matches?(_receipt, _configured), do: false

  defp classification(operational_status, outcome, reason, status, observed, digest, receipt),
    do: {operational_status, outcome, reason, status, observed, digest, receipt_summary(receipt)}

  defp receipt_summary(receipt) do
    summary =
      Map.merge(receipt["evidence"], %{
        "lease_execution" => receipt["lease_execution"],
        "observation_run_fingerprint" => receipt["observation_run_fingerprint"],
        "observer" => receipt["observer"],
        "owner_fingerprint" => receipt["owner_fingerprint"],
        "repair_oracle" => receipt["repair_oracle"],
        "scenario_status" => receipt["scenario_status"]
      })

    case receipt do
      %{"schema" => "insider.confirmation-body-receipt/v2", "external_execution" => external} ->
        Map.put(summary, "external_execution", external)

      _v1 ->
        summary
    end
  end

  defp empty_receipt_summary do
    %{
      "armed_before_scenario" => false,
      "complete" => false,
      "dropped" => 0,
      "finalized_after_scenario" => false,
      "gaps" => 0,
      "lease_execution" => nil,
      "observation_run_fingerprint" => nil,
      "observer" => nil,
      "owner_fingerprint" => nil,
      "repair_oracle" => nil,
      "scenario_status" => nil,
      "truncated" => false
    }
  end

  defp target_matches_manifest?(target, manifest) do
    components = target.provenance["components"]

    Enum.all?(@component_names, fn name ->
      components[name]["fingerprint"] == manifest.prerequisites[name]["fingerprint"]
    end)
  end

  defp primary_expected(capsule, scenario) do
    expected = capsule.finding["fingerprint"]

    if is_binary(expected) and expected in scenario.expected_incident_fingerprints,
      do: {:ok, expected},
      else: mismatch()
  end

  defp body_input(manifest, capsule, scenario, expected, observer, repair_oracle) do
    %{
      "capsule_id" => capsule.id,
      "expected_fingerprint" => expected,
      "manifest_id" => manifest.id,
      "observer" => observer,
      "repair_oracle" => repair_oracle,
      "scenario" => Scenario.to_wire_map(scenario)
    }
  end

  defp result_owner_fingerprint(%Result{value: value}), do: value["owner_fingerprint"]

  defp invalid_receipt_classification(receipt_digest, operational_status),
    do:
      {operational_status, "infrastructure_failure", "invalid_body_receipt", "incomplete", [],
       receipt_digest, empty_receipt_summary()}

  defp operational_reason(:ok), do: nil
  defp operational_reason(:cancelled), do: "sandbox_cancelled"
  defp operational_reason(:timeout), do: "sandbox_timeout"
  defp operational_reason(_status), do: "sandbox_failed"

  defp operational_status(:ok), do: "completed"
  defp operational_status(status), do: Atom.to_string(status)

  defp valid_options?(options) do
    StrictOptions.exact?(options, @option_keys)
  end

  defp valid_identity?(%{"id" => id, "version" => version} = identity),
    do:
      map_size(identity) == 2 and is_binary(id) and byte_size(id) in 1..128 and
        String.match?(id, ~r/\A[a-z][a-z0-9_.-]*\z/) and is_integer(version) and
        version in 1..1_000_000

  defp valid_identity?(_identity), do: false

  defp bounded_uncertainty(uncertainty), do: Enum.take(uncertainty, 16)

  defp cleanup_summary(cleanup) do
    %{
      "status" => cleanup.status |> Atom.to_string(),
      "release" => cleanup.release |> Atom.to_string(),
      "remaining_count" => cleanup.remaining_count,
      "remaining_fingerprint" => cleanup.remaining_fingerprint
    }
  end

  defp digest(value),
    do:
      value
      |> Canonical.encode()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp mismatch,
    do:
      {:error,
       Error.new(
         :confirmation_input_mismatch,
         "confirmation inputs do not identify one exact run"
       )}
end
