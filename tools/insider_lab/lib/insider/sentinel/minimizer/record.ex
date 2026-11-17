defmodule Insider.Sentinel.Minimizer.Record do
  @moduledoc """
  Canonical evidence for one bounded whole-step scenario minimization.

  The record describes deterministic orchestration and references exact
  confirmation records by identity. SHA-256 establishes content identity, not
  source authenticity; callers must retain the referenced evidence graph.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Protocol.StrictOptions
  alias Insider.Protocol.Value
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.minimization-record/v1"
  @maximum_bytes 524_288
  @maximum_trials 64
  @option_keys [
    :source,
    :policy,
    :status,
    :reason,
    :minimality,
    :original_scenario,
    :minimized_regression,
    :baseline,
    :trials,
    :usage,
    :cleanup,
    :uncertainty
  ]
  @fields [
    :schema,
    :id,
    :source,
    :policy,
    :status,
    :reason,
    :minimality,
    :original_scenario,
    :minimized_regression,
    :baseline,
    :trials,
    :usage,
    :cleanup,
    :uncertainty,
    :integrity
  ]
  @wire_keys Enum.map(@fields, &Atom.to_string/1)
  @statuses ["completed", "exhausted", "inconclusive"]
  @reasons [
    "baseline_inconclusive",
    "baseline_nondeterministic",
    "candidate_nondeterministic",
    "candidate_inconclusive",
    "executor_not_clean",
    "executor_state_unknown",
    "max_candidates_exhausted",
    "total_deadline_exhausted",
    "one_step_minimal",
    "unchanged_one_step_minimal"
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: StrictOptions.build(options, @option_keys, &build/1, &invalid/1)

  defp build(options) do
    content =
      @option_keys
      |> Map.new(fn key -> {Atom.to_string(key), Keyword.fetch!(options, key)} end)
      |> Map.put("schema", @schema)

    digest = hash(content)

    content
    |> Map.merge(%{
      "id" => "sha256:" <> digest,
      "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
    })
    |> from_wire()
    |> validate()
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = record) do
    wire = to_wire_map(record)

    with true <- exact_struct?(record),
         true <- record.schema == @schema,
         true <- Value.bounded_data?(wire, @maximum_bytes),
         true <- valid_source?(record.source),
         true <- valid_policy?(record.policy),
         true <- record.status in @statuses,
         true <- record.reason in @reasons,
         true <- record.minimality in ["one_step_minimal_under_policy", "not_proven"],
         {:ok, original} <- Scenario.decode_map(record.original_scenario),
         {:ok, minimized} <- Regression.decode_map(record.minimized_regression),
         true <- valid_subsequence?(original, minimized),
         true <- valid_internal_binding?(record, original, minimized),
         true <- valid_baseline?(record.baseline),
         true <- Value.bounded_list?(record.trials, @maximum_trials),
         true <- Enum.all?(record.trials, &valid_trial?/1),
         true <- valid_trial_sequence?(record, original, minimized),
         true <- valid_usage?(record.usage, record.policy, record.baseline, record.trials),
         true <- valid_duration_claim?(record),
         true <- valid_cleanup?(record.cleanup),
         true <- Value.bounded_list?(record.uncertainty, 64),
         true <- Enum.all?(record.uncertainty, &bounded_string?/1),
         true <- coherent?(record),
         true <- valid_integrity?(record.integrity),
         true <- record.id == "sha256:" <> record.integrity["content_digest"],
         true <- record.integrity["content_digest"] == hash(content(record)),
         encoded <- Canonical.encode(wire),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, record}
    else
      _other -> invalid(:invalid_record)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc """
  Recomputes a minimization record from its retained trusted evidence graph.

  Standalone validation proves canonical shape and internal coherence. This
  operation additionally binds the source regression, capsule, initial
  manifest, target, every derived candidate manifest, and every referenced
  confirmation record.
  """
  @spec validate_with_evidence(term(), term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(record, regression, capsule, manifest, target, records) do
    with {:ok, record} <- validate(record),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, target} <- Target.validate(target),
         {:ok, records} <- validate_confirmation_records(records, record.policy),
         true <- source_evidence_bound?(record, regression, capsule, manifest, target),
         true <- referenced_ids(record) == Enum.map(records, & &1.id),
         true <- unique_confirmation_evidence?(records),
         true <- evidence_decisions_valid?(record, regression, capsule, manifest, target, records) do
      {:ok, record}
    else
      _other -> invalid(:evidence_graph_mismatch)
    end
  rescue
    _error -> invalid(:evidence_validation_failed)
  catch
    _kind, _reason -> invalid(:evidence_validation_failed)
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(record) do
    with {:ok, valid} <- validate(record), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value),
    do: value |> Ingress.canonical_decode(@maximum_bytes, &decode_map/1) |> decode_result()

  defp decode_result({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp decode_result({:ingress_error, reason}), do: invalid(reason)
  defp decode_result(result), do: result

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    cond do
      Map.get(wire, "schema") != @schema ->
        unsupported_schema(Map.get(wire, "schema"))

      not exact_keys?(wire, @wire_keys) ->
        invalid(:invalid_envelope)

      true ->
        wire |> from_wire() |> validate()
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp validate_confirmation_records(records, policy) do
    if Value.bounded_list?(records, policy["max_confirmation_runs"]) do
      Enum.reduce_while(records, {:ok, []}, fn value, {:ok, acc} ->
        result =
          case value do
            %ConfirmationRecord{} -> ConfirmationRecord.validate(value)
            map when is_map(map) and not is_struct(map) -> ConfirmationRecord.decode_map(map)
            _other -> :error
          end

        case result do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          _error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        _error -> :error
      end
    else
      :error
    end
  end

  defp source_evidence_bound?(record, regression, capsule, manifest, target) do
    source = record.source
    confirmed = regression.confirmed_record

    source == %{
      "capsule_id" => capsule.id,
      "expected_fingerprint" => regression.expectation["incident_fingerprint"],
      "manifest_id" => manifest.id,
      "observer" => regression.expectation["observer"],
      "regression_id" => regression.id,
      "target_id" => target.id
    } and
      record.original_scenario == regression.scenario and confirmed["capsule_id"] == capsule.id and
      confirmed["manifest_id"] == manifest.id and
      confirmed["requested_target_fingerprint"] == Target.target_fingerprint(target) and
      confirmed["observed_target_fingerprint"] == Target.target_fingerprint(target) and
      manifest.prerequisites["scenario"] == scenario_descriptor(regression.scenario)
  end

  defp referenced_ids(record) do
    record.baseline["record_ids"] ++ Enum.flat_map(record.trials, & &1["record_ids"])
  end

  defp unique_confirmation_evidence?(records) do
    ids = Enum.map(records, & &1.id)
    owners = Enum.map(records, & &1.evidence["observation_run_fingerprint"])
    Enum.uniq(ids) == ids and Enum.uniq(owners) == owners
  end

  defp evidence_decisions_valid?(record, regression, capsule, manifest, target, records) do
    {baseline_records, remaining} = take_summary_records(record.baseline, records)

    with true <-
           summary_evidence_matches?(record.baseline, baseline_records) and
             records_bound?(
               baseline_records,
               capsule,
               manifest,
               regression.scenario,
               target,
               regression.expectation
             ),
         true <-
           baseline_evidence_valid?(
             record.baseline,
             regression,
             baseline_records,
             record.reason
           ),
         {:ok, final_regression, []} <-
           replay_trial_evidence(
             record.trials,
             regression,
             capsule,
             target,
             remaining,
             record.baseline["decision"],
             record.reason
           ) do
      Regression.to_wire_map(final_regression) == record.minimized_regression
    else
      _other -> false
    end
  end

  defp replay_trial_evidence(
         [],
         regression,
         _capsule,
         _target,
         records,
         _baseline_decision,
         _reason
       ),
       do: {:ok, regression, records}

  defp replay_trial_evidence(
         _trials,
         _regression,
         _capsule,
         _target,
         _records,
         baseline_decision,
         _reason
       )
       when baseline_decision != "failed",
       do: :error

  defp replay_trial_evidence(trials, regression, capsule, target, records, "failed", reason) do
    Enum.reduce_while(trials, {:ok, regression, records}, fn trial, {:ok, current, remaining} ->
      {trial_records, remaining} = take_summary_records(trial, remaining)

      with {:ok, scenario} <- Scenario.decode_map(current.scenario),
           {:ok, candidate} <- candidate_for_trial(scenario, trial),
           {:ok, descriptor} <- Scenario.descriptor(candidate),
           {:ok, manifest} <- Manifest.new(capsule, descriptor),
           true <- manifest.id == trial["candidate_manifest_id"],
           true <- summary_evidence_matches?(trial, trial_records),
           true <-
             records_bound?(
               trial_records,
               capsule,
               manifest,
               Scenario.to_wire_map(candidate),
               target,
               current.expectation
             ),
           {:ok, next} <-
             trial_evidence_decision(
               trial["decision"],
               current,
               candidate,
               trial_records,
               reason
             ) do
        {:cont, {:ok, next, remaining}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp candidate_for_trial(scenario, trial) do
    case Enum.find_index(scenario.steps, &(&1["id"] == trial["removed_step_id"])) do
      nil ->
        :error

      index ->
        retained = List.delete_at(scenario.steps, index)
        Scenario.retain_steps(scenario, Enum.map(retained, & &1["id"]))
    end
  end

  defp trial_evidence_decision(
         "preserved",
         _current,
         candidate,
         [source, first, second],
         _reason
       ) do
    with {:ok, regression} <- Regression.materialize(source, candidate),
         {:ok, %{"status" => "failed"}} <- Regression.classify(regression, [first, second]) do
      {:ok, regression}
    else
      _other -> :error
    end
  end

  defp trial_evidence_decision(
         "rejected",
         current,
         _candidate,
         [_, _, _] = records,
         _reason
       ) do
    if Enum.all?(records, &clean_nonreproduction?/1),
      do: {:ok, current},
      else: :error
  end

  defp trial_evidence_decision(
         "nondeterministic",
         current,
         _candidate,
         [_, _, _] = records,
         _reason
       ) do
    outcomes = Enum.map(records, & &1.outcome)

    if Enum.all?(records, &complete_record?/1) and
         Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"],
       do: {:ok, current},
       else: :error
  end

  defp trial_evidence_decision(
         "inconclusive",
         current,
         candidate,
         [_, _, _] = records,
         "candidate_inconclusive"
       ) do
    if derive_trial_decision(candidate, records) == :inconclusive,
      do: {:ok, current},
      else: :error
  end

  defp trial_evidence_decision(
         "inconclusive",
         current,
         _candidate,
         records,
         reason
       )
       when reason in ["executor_not_clean", "executor_state_unknown"] and
              length(records) in 1..3,
       do: {:ok, current}

  defp trial_evidence_decision("exhausted", current, _candidate, records, reason)
       when reason in ["total_deadline_exhausted", "executor_not_clean", "executor_state_unknown"] and
              length(records) in 0..2,
       do: {:ok, current}

  defp trial_evidence_decision(_decision, _current, _candidate, _records, _reason), do: :error

  defp derive_trial_decision(candidate, [source, first, second] = records) do
    outcomes = Enum.map(records, & &1.outcome)

    cond do
      not Enum.all?(records, &complete_record?/1) ->
        :inconclusive

      outcomes == ["nonreproduced", "nonreproduced", "nonreproduced"] ->
        :rejected

      Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"] ->
        :nondeterministic

      true ->
        with {:ok, regression} <- Regression.materialize(source, candidate),
             {:ok, %{"status" => "failed"}} <- Regression.classify(regression, [first, second]) do
          :preserved
        else
          _other -> :inconclusive
        end
    end
  end

  defp baseline_evidence_valid?(%{"decision" => "failed"}, regression, records, _reason),
    do: match?({:ok, %{"status" => "failed"}}, Regression.classify(regression, records))

  defp baseline_evidence_valid?(
         %{"decision" => "nondeterministic"},
         regression,
         records,
         reason
       )
       when reason in [
              "baseline_nondeterministic",
              "executor_not_clean",
              "executor_state_unknown"
            ] do
    outcomes = Enum.map(records, & &1.outcome)

    match?({:ok, %{"status" => "inconclusive"}}, Regression.classify(regression, records)) and
      Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"]
  end

  defp baseline_evidence_valid?(
         %{"decision" => "inconclusive"},
         regression,
         [_, _] = records,
         "baseline_inconclusive"
       ) do
    outcomes = Enum.map(records, & &1.outcome)

    match?({:ok, %{"status" => "inconclusive"}}, Regression.classify(regression, records)) and
      Enum.sort(Enum.uniq(outcomes)) != ["matching_failure", "nonreproduced"]
  end

  defp baseline_evidence_valid?(%{"decision" => "inconclusive"}, _regression, records, reason)
       when reason in ["executor_not_clean", "executor_state_unknown"],
       do: length(records) in 0..2

  defp baseline_evidence_valid?(
         %{"decision" => "exhausted"},
         _regression,
         records,
         reason
       )
       when reason in ["total_deadline_exhausted", "executor_not_clean", "executor_state_unknown"],
       do: length(records) in 0..1

  defp baseline_evidence_valid?(_summary, _regression, _records, _reason), do: false

  defp records_bound?(records, capsule, manifest, scenario, target, expectation) do
    target_fingerprint = Target.target_fingerprint(target)

    Enum.all?(records, fn record ->
      record.capsule_id == capsule.id and record.manifest_id == manifest.id and
        record.scenario_id == scenario["id"] and
        record.expected_fingerprint == expectation["incident_fingerprint"] and
        record.evidence["observer"] == expectation["observer"] and
        record.requested_target_fingerprint == target_fingerprint and
        record.observed_target_fingerprint == target_fingerprint
    end)
  end

  defp summary_evidence_matches?(summary, records),
    do:
      summary["record_ids"] == Enum.map(records, & &1.id) and
        summary["outcomes"] == Enum.map(records, & &1.outcome)

  defp take_summary_records(summary, records),
    do: Enum.split(records, length(summary["record_ids"]))

  defp clean_nonreproduction?(record),
    do: record.outcome == "nonreproduced" and complete_record?(record)

  defp complete_record?(record),
    do:
      record.operational_status == "completed" and record.cleanup["status"] == "complete" and
        record.cleanup["remaining_count"] == 0 and record.evidence["status"] == "complete" and
        record.uncertainty == []

  defp scenario_descriptor(scenario_wire) do
    with {:ok, scenario} <- Scenario.decode_map(scenario_wire),
         {:ok, descriptor} <- Scenario.descriptor(scenario) do
      descriptor
    else
      _other -> nil
    end
  end

  defp valid_source?(source) do
    exact_keys?(
      source,
      ~w(capsule_id expected_fingerprint manifest_id observer regression_id target_id)
    ) and
      Enum.all?(~w(capsule_id manifest_id regression_id target_id), &id?(source[&1])) and
      digest?(source["expected_fingerprint"]) and valid_identity?(source["observer"])
  end

  defp valid_policy?(policy) do
    exact_keys?(
      policy,
      ~w(algorithm duration_scope max_candidates max_confirmation_runs max_duration_ms max_total_bytes max_total_events per_run_max_bytes per_run_max_events required_baseline_runs required_candidate_runs)
    ) and policy["algorithm"] == "greedy_delete_steps_v1" and
      policy["duration_scope"] == "execution_search" and
      is_integer(policy["max_candidates"]) and policy["max_candidates"] in 1..@maximum_trials and
      policy["max_confirmation_runs"] == 2 + 3 * policy["max_candidates"] and
      is_integer(policy["max_duration_ms"]) and policy["max_duration_ms"] in 1..600_000 and
      positive_integer?(policy["per_run_max_bytes"]) and
      positive_integer?(policy["per_run_max_events"]) and
      policy["max_total_bytes"] ==
        policy["per_run_max_bytes"] * policy["max_confirmation_runs"] and
      policy["max_total_events"] ==
        policy["per_run_max_events"] * policy["max_confirmation_runs"] and
      policy["required_baseline_runs"] == 2 and policy["required_candidate_runs"] == 3
  end

  defp valid_subsequence?(original, minimized_regression) do
    with {:ok, minimized} <- Scenario.decode_map(minimized_regression.scenario),
         ids <- Enum.map(minimized.steps, & &1["id"]),
         {:ok, rebuilt} <- Scenario.retain_steps(original, ids) do
      Scenario.to_wire_map(rebuilt) == minimized_regression.scenario
    else
      _other -> false
    end
  end

  defp valid_internal_binding?(record, original, minimized) do
    source = record.source
    confirmed = minimized.confirmed_record
    preserved = Enum.filter(record.trials, &(&1["decision"] == "preserved"))

    common =
      minimized.expectation["incident_fingerprint"] == source["expected_fingerprint"] and
        minimized.expectation["observer"] == source["observer"] and
        confirmed["capsule_id"] == source["capsule_id"]

    common and
      case List.last(preserved) do
        nil ->
          minimized.id == source["regression_id"] and
            minimized.scenario == Scenario.to_wire_map(original) and
            confirmed["manifest_id"] == source["manifest_id"]

        trial ->
          [source_record_id | _other_ids] = trial["record_ids"]

          confirmed["id"] == source_record_id and
            confirmed["manifest_id"] == trial["candidate_manifest_id"] and
            minimized.scenario["id"] == trial["candidate_scenario_id"]
      end
  rescue
    _error -> false
  end

  defp valid_baseline?(baseline) do
    exact_keys?(baseline, ~w(attempt_count decision outcomes record_ids)) and
      baseline["decision"] in ["failed", "inconclusive", "nondeterministic", "exhausted"] and
      is_integer(baseline["attempt_count"]) and baseline["attempt_count"] in 0..2 and
      valid_id_list?(baseline["record_ids"], 2) and
      valid_outcomes?(baseline["outcomes"], 2) and
      length(baseline["record_ids"]) == length(baseline["outcomes"]) and
      length(baseline["record_ids"]) == baseline["attempt_count"] and
      valid_baseline_decision?(baseline)
  end

  defp valid_trial?(trial) do
    exact_keys?(
      trial,
      ~w(attempt_count candidate_manifest_id candidate_scenario_id decision outcomes record_ids removed_step_id)
    ) and id?(trial["candidate_manifest_id"]) and id?(trial["candidate_scenario_id"]) and
      is_integer(trial["attempt_count"]) and trial["attempt_count"] in 0..3 and
      vocabulary?(trial["removed_step_id"]) and
      trial["decision"] in [
        "preserved",
        "rejected",
        "nondeterministic",
        "inconclusive",
        "exhausted"
      ] and
      valid_id_list?(trial["record_ids"], 3) and valid_outcomes?(trial["outcomes"], 3) and
      length(trial["record_ids"]) == length(trial["outcomes"]) and
      length(trial["record_ids"]) == trial["attempt_count"] and valid_trial_decision?(trial)
  end

  defp valid_baseline_decision?(%{
         "attempt_count" => 2,
         "decision" => "failed",
         "outcomes" => ["matching_failure", "matching_failure"],
         "record_ids" => [_, _]
       }),
       do: true

  defp valid_baseline_decision?(%{
         "attempt_count" => 0,
         "decision" => "inconclusive",
         "outcomes" => [],
         "record_ids" => []
       }),
       do: true

  defp valid_baseline_decision?(%{
         "attempt_count" => 1,
         "decision" => "inconclusive",
         "outcomes" => [_],
         "record_ids" => [_]
       }),
       do: true

  defp valid_baseline_decision?(%{
         "attempt_count" => 2,
         "decision" => "inconclusive",
         "outcomes" => [_, _],
         "record_ids" => [_, _]
       }),
       do: true

  defp valid_baseline_decision?(%{
         "attempt_count" => 2,
         "decision" => "nondeterministic",
         "outcomes" => outcomes,
         "record_ids" => [_, _]
       }),
       do: Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"]

  defp valid_baseline_decision?(%{
         "attempt_count" => attempts,
         "decision" => "exhausted",
         "outcomes" => outcomes,
         "record_ids" => record_ids
       }),
       do: attempts in 0..1 and length(outcomes) == attempts and length(record_ids) == attempts

  defp valid_baseline_decision?(_baseline), do: false

  defp valid_trial_decision?(%{
         "attempt_count" => 3,
         "decision" => "preserved",
         "outcomes" => ["matching_failure", "matching_failure", "matching_failure"],
         "record_ids" => [_, _, _]
       }),
       do: true

  defp valid_trial_decision?(%{
         "attempt_count" => 3,
         "decision" => "rejected",
         "outcomes" => ["nonreproduced", "nonreproduced", "nonreproduced"],
         "record_ids" => [_, _, _]
       }),
       do: true

  defp valid_trial_decision?(%{
         "attempt_count" => 3,
         "decision" => "nondeterministic",
         "outcomes" => outcomes,
         "record_ids" => [_, _, _]
       }),
       do: Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"]

  defp valid_trial_decision?(%{
         "decision" => "inconclusive",
         "attempt_count" => attempts,
         "outcomes" => outcomes,
         "record_ids" => record_ids
       }),
       do: attempts in 1..3 and length(outcomes) == attempts and length(record_ids) == attempts

  defp valid_trial_decision?(%{
         "attempt_count" => attempts,
         "decision" => "exhausted",
         "outcomes" => outcomes,
         "record_ids" => record_ids
       }),
       do: attempts in 0..2 and length(outcomes) == attempts and length(record_ids) == attempts

  defp valid_trial_decision?(_trial), do: false

  defp valid_id_list?(values, maximum),
    do:
      Value.bounded_list?(values, maximum) and Enum.all?(values, &id?/1) and
        Enum.uniq(values) == values

  defp valid_outcomes?(values, maximum),
    do:
      Value.bounded_list?(values, maximum) and
        Enum.all?(
          values,
          &(&1 in ~w(infrastructure_failure matching_failure nonreproduced repaired unrelated_failure))
        )

  defp valid_usage?(usage, policy, baseline, trials) do
    exact_keys?(
      usage,
      ~w(accepted_candidates confirmation_runs duration_us evaluated_candidates rejected_candidates)
    ) and
      Enum.all?(
        ~w(accepted_candidates confirmation_runs duration_us evaluated_candidates rejected_candidates),
        &(is_integer(usage[&1]) and usage[&1] >= 0)
      ) and
      usage["evaluated_candidates"] == length(trials) and
      usage["evaluated_candidates"] <= policy["max_candidates"] and
      usage["confirmation_runs"] ==
        baseline["attempt_count"] +
          Enum.reduce(trials, 0, &(&1["attempt_count"] + &2)) and
      usage["confirmation_runs"] <= policy["max_confirmation_runs"] and
      usage["accepted_candidates"] == Enum.count(trials, &(&1["decision"] == "preserved")) and
      usage["rejected_candidates"] == Enum.count(trials, &(&1["decision"] == "rejected"))
  end

  defp valid_duration_claim?(%{status: "completed", usage: usage, policy: policy}),
    do: usage["duration_us"] <= policy["max_duration_ms"] * 1_000

  defp valid_duration_claim?(%{
         reason: "max_candidates_exhausted",
         usage: usage,
         policy: policy
       }),
       do: usage["duration_us"] <= policy["max_duration_ms"] * 1_000

  defp valid_duration_claim?(_record), do: true

  defp valid_trial_sequence?(record, original, minimized_regression) do
    with {:ok, minimized} <- Scenario.decode_map(minimized_regression.scenario),
         {:ok, state} <- replay_trials(original, record.trials),
         true <- Scenario.to_wire_map(state.scenario) == Scenario.to_wire_map(minimized),
         true <- terminal_sequence?(record, state) do
      true
    else
      _other -> false
    end
  end

  defp replay_trials(original, trials) do
    Enum.reduce_while(trials, {:ok, %{cursor: 0, scenario: original}}, fn trial, {:ok, state} ->
      case replay_trial(state, trial) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp replay_trial(state, trial) do
    steps = state.scenario.steps

    with false <- Map.has_key?(state, :terminal),
         true <- state.cursor < length(steps),
         removed when is_map(removed) <- Enum.at(steps, state.cursor),
         true <- removed["id"] == trial["removed_step_id"],
         retained <- List.delete_at(steps, state.cursor),
         true <- retained != [],
         {:ok, candidate} <-
           Scenario.retain_steps(state.scenario, Enum.map(retained, & &1["id"])),
         true <- candidate.id == trial["candidate_scenario_id"] do
      case trial["decision"] do
        "preserved" ->
          {:ok, %{cursor: 0, scenario: candidate}}

        "rejected" ->
          {:ok, %{state | cursor: state.cursor + 1}}

        terminal when terminal in ["nondeterministic", "inconclusive", "exhausted"] ->
          {:ok, Map.put(state, :terminal, terminal)}
      end
    else
      _other -> :error
    end
  end

  defp terminal_sequence?(record, state) do
    terminal = Map.get(state, :terminal)
    last_decision = record.trials |> List.last(%{}) |> Map.get("decision")

    cond do
      terminal && last_decision != terminal ->
        false

      terminal && record.status == "completed" ->
        false

      record.status == "completed" ->
        is_nil(terminal) and
          (match?([_only], state.scenario.steps) or state.cursor >= length(state.scenario.steps))

      record.reason == "max_candidates_exhausted" ->
        is_nil(terminal) and length(record.trials) == record.policy["max_candidates"]

      record.reason == "total_deadline_exhausted" and record.trials != [] ->
        last_decision == "exhausted"

      record.reason in [
        "candidate_nondeterministic",
        "candidate_inconclusive"
      ] and record.trials != [] ->
        last_decision in ["nondeterministic", "inconclusive"]

      record.reason in ["executor_not_clean", "executor_state_unknown"] ->
        last_decision in [
          nil,
          "preserved",
          "rejected",
          "nondeterministic",
          "inconclusive",
          "exhausted"
        ]

      true ->
        record.trials == []
    end
  end

  defp valid_cleanup?(cleanup) do
    exact_keys?(cleanup, ~w(active quarantined status)) and
      cleanup["status"] in ["complete", "incomplete", "unknown"] and
      optional_count?(cleanup["active"]) and optional_count?(cleanup["quarantined"]) and
      cleanup["status"] == cleanup_status(cleanup["active"], cleanup["quarantined"])
  end

  defp cleanup_status(0, 0), do: "complete"

  defp cleanup_status(active, quarantined) when is_integer(active) and is_integer(quarantined),
    do: "incomplete"

  defp cleanup_status(nil, nil), do: "unknown"
  defp cleanup_status(_active, _quarantined), do: "incomplete"

  defp coherent?(record) do
    complete? = record.status == "completed"
    minimal? = record.minimality == "one_step_minimal_under_policy"

    complete? == minimal? and status_reason_coherent?(record) and
      if complete? do
        reason_evidence_coherent?(record) and record.uncertainty == []
      else
        record.reason not in ["one_step_minimal", "unchanged_one_step_minimal"] and
          reason_evidence_coherent?(record) and
          record.uncertainty == [expected_uncertainty(record.reason)]
      end
  end

  defp reason_evidence_coherent?(%{reason: reason} = record)
       when reason in ["one_step_minimal", "unchanged_one_step_minimal"] do
    record.baseline["decision"] == "failed" and
      Enum.all?(record.trials, &(&1["decision"] in ["preserved", "rejected"])) and
      record.cleanup["status"] == "complete"
  end

  defp reason_evidence_coherent?(%{reason: "baseline_nondeterministic"} = record),
    do:
      record.baseline["decision"] == "nondeterministic" and record.trials == [] and
        record.cleanup["status"] == "complete"

  defp reason_evidence_coherent?(%{reason: "baseline_inconclusive"} = record),
    do:
      record.baseline["decision"] == "inconclusive" and
        record.baseline["attempt_count"] == 2 and record.trials == [] and
        record.cleanup["status"] == "complete"

  defp reason_evidence_coherent?(%{reason: "candidate_nondeterministic"} = record),
    do:
      record.baseline["decision"] == "failed" and
        last_trial_decision(record) == "nondeterministic" and
        record.cleanup["status"] == "complete"

  defp reason_evidence_coherent?(%{reason: "candidate_inconclusive"} = record) do
    last = List.last(record.trials, %{})

    record.baseline["decision"] == "failed" and last["decision"] == "inconclusive" and
      last["attempt_count"] == 3 and record.cleanup["status"] == "complete"
  end

  defp reason_evidence_coherent?(%{reason: "max_candidates_exhausted"} = record),
    do:
      record.baseline["decision"] == "failed" and
        length(record.trials) == record.policy["max_candidates"] and
        Enum.all?(record.trials, &(&1["decision"] in ["preserved", "rejected"])) and
        record.cleanup["status"] == "complete"

  defp reason_evidence_coherent?(%{reason: "total_deadline_exhausted"} = record) do
    baseline_exhausted = record.baseline["decision"] == "exhausted" and record.trials == []

    trial_exhausted =
      record.baseline["decision"] == "failed" and last_trial_decision(record) == "exhausted"

    (baseline_exhausted or trial_exhausted) and record.cleanup["status"] == "complete"
  end

  defp reason_evidence_coherent?(%{reason: "executor_not_clean"} = record),
    do: executor_terminal?(record) and record.cleanup["status"] == "incomplete"

  defp reason_evidence_coherent?(%{reason: "executor_state_unknown"} = record),
    do: executor_terminal?(record) and record.cleanup["status"] == "unknown"

  defp reason_evidence_coherent?(_record), do: false

  defp executor_terminal?(record),
    do:
      record.baseline["decision"] in ["failed", "inconclusive", "nondeterministic"] or
        (record.baseline["decision"] == "exhausted" and record.trials == [])

  defp last_trial_decision(record),
    do: record.trials |> List.last(%{}) |> Map.get("decision")

  defp status_reason_coherent?(%{status: "completed", reason: reason}),
    do: reason in ["one_step_minimal", "unchanged_one_step_minimal"]

  defp status_reason_coherent?(%{status: "exhausted", reason: reason}),
    do: reason in ["max_candidates_exhausted", "total_deadline_exhausted"]

  defp status_reason_coherent?(%{status: "inconclusive", reason: reason}),
    do:
      reason in [
        "baseline_inconclusive",
        "baseline_nondeterministic",
        "candidate_nondeterministic",
        "candidate_inconclusive",
        "executor_not_clean",
        "executor_state_unknown"
      ]

  defp expected_uncertainty("baseline_inconclusive"),
    do: "baseline did not reproduce consistently"

  defp expected_uncertainty("baseline_nondeterministic"),
    do: "baseline reproduction was nondeterministic"

  defp expected_uncertainty("candidate_nondeterministic"),
    do: "candidate reproduction was nondeterministic"

  defp expected_uncertainty("candidate_inconclusive"),
    do: "candidate evidence was inconclusive"

  defp expected_uncertainty("executor_not_clean"),
    do: "sandbox executor retained active or quarantined work"

  defp expected_uncertainty("executor_state_unknown"),
    do: "sandbox executor cleanup state could not be established"

  defp expected_uncertainty("max_candidates_exhausted"),
    do: "candidate bound exhausted before minimality"

  defp expected_uncertainty("total_deadline_exhausted"),
    do: "duration bound exhausted before minimality"

  defp exact_keys?(map, keys),
    do:
      is_map(map) and map_size(map) == length(keys) and
        Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_identity?(identity), do: Ingress.identity?(identity)
  defp optional_count?(nil), do: true
  defp optional_count?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp bounded_string?(value), do: is_binary(value) and byte_size(value) <= 256

  defp vocabulary?(value),
    do: is_binary(value) and String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp id?("sha256:" <> value), do: digest?(value)
  defp id?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false

  defp exact_struct?(record),
    do: Enum.sort(Map.keys(Map.from_struct(record))) == Enum.sort(@fields)

  defp content(record), do: Map.drop(to_wire_map(record), ["integrity", "id"])

  defp valid_integrity?(integrity) do
    case integrity do
      %{"algorithm" => "sha256", "content_digest" => digest} ->
        exact_keys?(integrity, ~w(algorithm content_digest)) and digest?(digest)

      _other ->
        false
    end
  end

  defp hash(value),
    do: :sha256 |> :crypto.hash(Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp from_wire(wire) do
    struct!(
      __MODULE__,
      Map.new(wire, fn {key, value} -> {String.to_existing_atom(key), value} end)
    )
  end

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_minimization_record, "minimization record is invalid", %{reason: reason})}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :minimization_record_limit_exceeded,
         "minimization record exceeds its static limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_minimization_record_schema,
         "minimization record schema is unsupported",
         %{schema: Value.summary(schema)}
       )}
end
