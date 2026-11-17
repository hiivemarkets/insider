defmodule Insider.Sentinel.Minimizer do
  @moduledoc """
  Deterministically removes whole scenario steps under fresh failure evidence.

  Version one never invents arguments or executable forms. Every candidate is
  run in three fresh disposable confirmations: one source record materializes a
  candidate regression and two further records must satisfy the existing
  regression classifier before the deletion is accepted. The configured
  duration bounds the effectful search from executor preflight through final
  cleanup; bounded input and final evidence validation are outside that clock.
  """

  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Value
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Minimizer.Record
  alias Insider.Sentinel.Minimizer.Result
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target

  @maximum_candidates 64
  @maximum_duration_ms 600_000
  @default_candidates 16
  @default_duration_ms 60_000
  @baseline_runs 2
  @candidate_runs 3
  @await_slack_ms 1_000
  @option_keys [:request, :context, :body, :observer, :max_candidates, :max_duration_ms]
  @required_options [:request, :context, :body, :observer]

  @spec run(
          Supervisor.supervisor(),
          term(),
          term(),
          term(),
          term(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(executor, regression, manifest, capsule, target, options) do
    with true <- valid_options?(options),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, scenario} <- Scenario.decode_map(regression.scenario),
         {:ok, target} <- Target.validate(target),
         %Request{} = request <- Keyword.fetch!(options, :request),
         true <- Request.valid?(request),
         %Context{} = context <- Keyword.fetch!(options, :context),
         true <- Context.valid?(context),
         body when is_atom(body) <- Keyword.fetch!(options, :body),
         observer when is_map(observer) <- Keyword.fetch!(options, :observer),
         max_candidates when max_candidates in 1..@maximum_candidates <-
           Keyword.get(options, :max_candidates, @default_candidates),
         max_duration_ms when max_duration_ms in 1..@maximum_duration_ms <-
           Keyword.get(options, :max_duration_ms, @default_duration_ms),
         :ok <- bind_inputs(regression, manifest, capsule, scenario, target, observer, request) do
      now = System.monotonic_time(:millisecond)

      state = %{
        baseline: %{
          "attempt_count" => 0,
          "decision" => "inconclusive",
          "outcomes" => [],
          "record_ids" => []
        },
        body: body,
        capsule: capsule,
        context: context,
        current_regression: regression,
        current_scenario: scenario,
        cursor: 0,
        deadline: min(request.deadline_monotonic, now + max_duration_ms),
        evidence_records: [],
        manifest: manifest,
        observer: observer,
        original_regression: regression,
        original_scenario: scenario,
        policy: policy(max_candidates, max_duration_ms, request),
        request: request,
        started_at: now * 1_000,
        target: target,
        trials: [],
        usage: %{
          "accepted_candidates" => 0,
          "confirmation_runs" => 0,
          "duration_us" => 0,
          "evaluated_candidates" => 0,
          "rejected_candidates" => 0
        }
      }

      preflight(state, executor)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> input_mismatch()
    end
  rescue
    _error -> {:error, Error.new(:operation_failed, "scenario minimization failed")}
  catch
    :exit, _reason ->
      {:error, Error.new(:operation_failed, "minimization executor is unavailable")}
  end

  defp preflight(state, executor) do
    case bounded_counts(executor, state.deadline) do
      {:ok, %{active: 0, quarantined: 0}, _completed_at_us} ->
        baseline(state, executor)

      {:ok, counts, completed_at_us} ->
        state = Map.put(state, :cleanup_at_stop, {cleanup(counts), completed_at_us})
        finish(state, executor, "inconclusive", "executor_not_clean")

      _error ->
        state =
          Map.put(
            state,
            :cleanup_at_stop,
            {cleanup(:unknown), System.monotonic_time(:microsecond)}
          )

        finish(state, executor, "inconclusive", "executor_state_unknown")
    end
  end

  defp baseline(state, executor) do
    case confirmations(state, executor, state.manifest, state.original_scenario, @baseline_runs) do
      {:ok, records, state} ->
        evaluation = Regression.classify(state.original_regression, records)
        decision = baseline_decision(evaluation, records)
        baseline = summary(records, decision)
        state = %{state | baseline: baseline}

        case decision do
          "failed" ->
            search(state, executor)

          "nondeterministic" ->
            finish(state, executor, "inconclusive", "baseline_nondeterministic")

          "inconclusive" ->
            finish(state, executor, "inconclusive", "baseline_inconclusive")
        end

      {:stop, reason, records, attempts, state} ->
        state = %{state | baseline: summary(records, stop_decision(reason), attempts)}
        stop_baseline(state, executor, reason)

      {:error, %Error{} = error, state} ->
        confirmation_error(error, state, executor)
    end
  end

  defp search(%{current_scenario: %{steps: [_only]}} = state, executor),
    do: complete(state, executor)

  defp search(state, executor) when state.cursor >= length(state.current_scenario.steps),
    do: complete(state, executor)

  defp search(state, executor) do
    if state.usage["evaluated_candidates"] >= state.policy["max_candidates"] do
      finish(state, executor, "exhausted", "max_candidates_exhausted")
    else
      evaluate_candidate(state, executor)
    end
  end

  defp evaluate_candidate(state, executor) do
    removed = Enum.at(state.current_scenario.steps, state.cursor)
    retained = List.delete_at(state.current_scenario.steps, state.cursor)
    retained_ids = Enum.map(retained, & &1["id"])

    with {:ok, candidate} <- Scenario.retain_steps(state.current_scenario, retained_ids),
         {:ok, descriptor} <- Scenario.descriptor(candidate),
         {:ok, manifest} <- Manifest.new(state.capsule, descriptor) do
      case confirmations(state, executor, manifest, candidate, @candidate_runs) do
        {:ok, records, state} ->
          decide_candidate(state, executor, candidate, manifest, removed["id"], records)

        {:stop, reason, records, attempts, state} ->
          state =
            add_trial(
              state,
              candidate,
              manifest,
              removed["id"],
              records,
              stop_decision(reason),
              attempts
            )

          stop(state, executor, reason)

        {:error, %Error{} = error, state} ->
          confirmation_error(error, state, executor)
      end
    else
      {:error, %Error{}} -> finish(state, executor, "inconclusive", "candidate_inconclusive")
    end
  end

  defp decide_candidate(state, executor, candidate, manifest, removed_step_id, records) do
    case candidate_decision(state, candidate, manifest, records) do
      {:preserved, candidate_regression} ->
        state =
          state
          |> add_trial(candidate, manifest, removed_step_id, records, "preserved")
          |> increment("accepted_candidates")

        search(
          %{
            state
            | current_regression: candidate_regression,
              current_scenario: candidate,
              cursor: 0
          },
          executor
        )

      :rejected ->
        state =
          state
          |> add_trial(candidate, manifest, removed_step_id, records, "rejected")
          |> increment("rejected_candidates")

        search(%{state | cursor: state.cursor + 1}, executor)

      :nondeterministic ->
        state =
          add_trial(state, candidate, manifest, removed_step_id, records, "nondeterministic")

        finish(state, executor, "inconclusive", "candidate_nondeterministic")

      :inconclusive ->
        state = add_trial(state, candidate, manifest, removed_step_id, records, "inconclusive")
        finish(state, executor, "inconclusive", "candidate_inconclusive")
    end
  end

  defp candidate_decision(state, candidate, manifest, [source, first, second] = records) do
    outcomes = Enum.map(records, & &1.outcome)

    cond do
      not isolated_records?(state, candidate, manifest, records) ->
        :inconclusive

      outcomes == List.duplicate("nonreproduced", @candidate_runs) ->
        :rejected

      Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"] ->
        :nondeterministic

      true ->
        with {:ok, regression} <- Regression.materialize(source, candidate),
             {:ok, %{"status" => "failed"}} <- Regression.classify(regression, [first, second]) do
          {:preserved, regression}
        else
          _other -> :inconclusive
        end
    end
  end

  defp isolated_records?(state, candidate, manifest, records) do
    source = state.original_regression.confirmed_record
    ids = Enum.map(records, & &1.id)
    owners = Enum.map(records, & &1.evidence["observation_run_fingerprint"])

    Enum.uniq(ids) == ids and Enum.uniq(owners) == owners and
      Enum.all?(records, fn record ->
        record.capsule_id == source["capsule_id"] and record.scenario_id == candidate.id and
          record.manifest_id == manifest.id and
          record.expected_fingerprint ==
            state.original_regression.expectation["incident_fingerprint"] and
          record.observed_target_fingerprint == source["observed_target_fingerprint"] and
          record.requested_target_fingerprint == source["requested_target_fingerprint"] and
          record.operational_status == "completed" and record.cleanup["status"] == "complete" and
          record.evidence["status"] == "complete" and record.uncertainty == []
      end)
  end

  defp confirmations(state, executor, manifest, scenario, count) do
    if enough_time?(state, scenario, count) do
      Enum.reduce_while(1..count, {:ok, [], 0, state}, fn index,
                                                          {:ok, records, attempts, state} ->
        remaining_runs = count - index + 1

        if enough_time?(state, scenario, remaining_runs) do
          request = run_request(state, scenario)

          result =
            Confirmation.run(executor, manifest, state.capsule, scenario, state.target,
              request: request,
              context: state.context,
              body: state.body,
              observer: state.observer,
              repair_oracle: nil
            )

          state = increment(state, "confirmation_runs")
          attempts = attempts + 1

          case result do
            {:ok, %ConfirmationRecord{} = record} ->
              state = retain_record(state, record)

              case bounded_counts(executor, state.deadline) do
                {:ok, %{active: 0, quarantined: 0}, _completed_at_us} ->
                  {:cont, {:ok, [record | records], attempts, state}}

                {:ok, counts, completed_at_us} ->
                  state = Map.put(state, :cleanup_at_stop, {cleanup(counts), completed_at_us})

                  {:halt,
                   {:stop, :executor_not_clean, Enum.reverse([record | records]), attempts, state}}

                _error ->
                  state =
                    Map.put(
                      state,
                      :cleanup_at_stop,
                      {cleanup(:unknown), System.monotonic_time(:microsecond)}
                    )

                  {:halt,
                   {:stop, :executor_state_unknown, Enum.reverse([record | records]), attempts,
                    state}}
              end

            {:error, %Error{} = error} ->
              {:halt, {:error, error, state}}
          end
        else
          {:halt, {:stop, :total_deadline_exhausted, Enum.reverse(records), attempts, state}}
        end
      end)
      |> reverse_success()
    else
      {:stop, :total_deadline_exhausted, [], 0, state}
    end
  end

  defp reverse_success({:ok, records, _attempts, state}),
    do: {:ok, Enum.reverse(records), state}

  defp reverse_success(other), do: other

  defp bounded_counts(executor, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      {:error, :deadline_exhausted}
    else
      task =
        Task.async(fn ->
          result = Executor.counts(executor)
          {result, System.monotonic_time(:microsecond)}
        end)

      case Task.yield(task, remaining) do
        {:ok, {{:ok, counts}, completed_at_us}} when completed_at_us <= deadline * 1_000 ->
          {:ok, counts, completed_at_us}

        {:ok, {_result, _completed_at_us}} ->
          {:error, :executor_unavailable}

        {:exit, _reason} ->
          {:error, :executor_unavailable}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :deadline_exhausted}
      end
    end
  end

  defp enough_time?(state, scenario, count) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    remaining >= count * (run_timeout(state.request, scenario) + @await_slack_ms)
  end

  defp run_request(state, scenario) do
    timeout = run_timeout(state.request, scenario)
    index = state.usage["confirmation_runs"] + 1
    digest = :crypto.hash(:sha256, "#{state.request.request_id}:#{index}")
    request_id = "min-" <> Base.encode16(digest, case: :lower)

    %{
      state.request
      | request_id: request_id,
        timeout_ms: timeout,
        deadline_monotonic: min(state.deadline, System.monotonic_time(:millisecond) + timeout)
    }
  end

  defp run_timeout(request, scenario) do
    scenario_bound =
      scenario.limits["max_duration_ms"] + scenario.limits["cleanup_timeout_ms"] + 250

    min(request.timeout_ms, scenario_bound)
  end

  defp complete(state, executor) do
    reason =
      if state.current_scenario.id == state.original_scenario.id,
        do: "unchanged_one_step_minimal",
        else: "one_step_minimal"

    finish(state, executor, "completed", reason)
  end

  defp stop(state, executor, :total_deadline_exhausted),
    do: finish(state, executor, "exhausted", "total_deadline_exhausted")

  defp stop(state, executor, :executor_not_clean),
    do: finish(state, executor, "inconclusive", "executor_not_clean")

  defp stop(state, executor, :executor_state_unknown),
    do: finish(state, executor, "inconclusive", "executor_state_unknown")

  defp stop(state, executor, _reason),
    do: finish(state, executor, "inconclusive", "candidate_inconclusive")

  defp stop_baseline(state, executor, :total_deadline_exhausted),
    do: finish(state, executor, "exhausted", "total_deadline_exhausted")

  defp stop_baseline(state, executor, :executor_not_clean),
    do: finish(state, executor, "inconclusive", "executor_not_clean")

  defp stop_baseline(state, executor, :executor_state_unknown),
    do: finish(state, executor, "inconclusive", "executor_state_unknown")

  defp stop_baseline(state, executor, _reason),
    do: finish(state, executor, "inconclusive", "baseline_inconclusive")

  defp finish(state, executor, status, reason) do
    # Preserve the cleanup observation that stopped the search; a later count can differ.
    {cleanup, finished_at_us} =
      Map.get_lazy(state, :cleanup_at_stop, fn -> final_cleanup(state, executor) end)

    {status, reason} = cleanup_terminal(status, reason, cleanup)
    duration_us = max(0, finished_at_us - state.started_at)
    minimality = if status == "completed", do: "one_step_minimal_under_policy", else: "not_proven"
    uncertainty = if status == "completed", do: [], else: [uncertainty(reason)]
    usage = Map.put(state.usage, "duration_us", duration_us)

    with {:ok, record} <-
           Record.new(
             source: source(state),
             policy: state.policy,
             status: status,
             reason: reason,
             minimality: minimality,
             original_scenario: Scenario.to_wire_map(state.original_scenario),
             minimized_regression: Regression.to_wire_map(state.current_regression),
             baseline: state.baseline,
             trials: Enum.reverse(state.trials),
             usage: usage,
             cleanup: cleanup,
             uncertainty: uncertainty
           ) do
      records = Enum.reverse(state.evidence_records)

      with {:ok, valid_record} <-
             Record.validate_with_evidence(
               record,
               state.original_regression,
               state.capsule,
               state.manifest,
               state.target,
               records
             ) do
        {:ok, %Result{record: valid_record, confirmation_records: records}}
      end
    end
  end

  defp final_cleanup(state, executor) do
    case bounded_counts(executor, state.deadline) do
      {:ok, counts, completed_at_us} ->
        {cleanup(counts), completed_at_us}

      _error ->
        {cleanup(:unknown), System.monotonic_time(:microsecond)}
    end
  end

  defp cleanup_terminal(_status, _reason, %{"status" => "incomplete"}),
    do: {"inconclusive", "executor_not_clean"}

  defp cleanup_terminal(_status, _reason, %{"status" => "unknown"}),
    do: {"inconclusive", "executor_state_unknown"}

  defp cleanup_terminal(status, reason, %{"status" => "complete"}), do: {status, reason}

  defp confirmation_error(error, state, executor) do
    {cleanup, _finished_at_us} = final_cleanup(state, executor)

    details =
      Map.merge(error.details, %{
        "minimizer_cleanup" => cleanup,
        "minimizer_confirmation_runs" => state.usage["confirmation_runs"]
      })

    annotated = %{error | details: details}

    if Error.valid?(annotated) do
      {:error, annotated}
    else
      {:error,
       %{
         error
         | details: %{
             "minimizer_cleanup" => cleanup,
             "minimizer_confirmation_runs" => state.usage["confirmation_runs"],
             "original_details_omitted" => true
           }
       }}
    end
  end

  defp add_trial(
         state,
         candidate,
         manifest,
         removed_step_id,
         records,
         decision,
         attempts \\ @candidate_runs
       ) do
    trial =
      summary(records, decision, attempts)
      |> Map.merge(%{
        "candidate_manifest_id" => manifest.id,
        "candidate_scenario_id" => candidate.id,
        "removed_step_id" => removed_step_id
      })

    state
    |> Map.update!(:trials, &[trial | &1])
    |> increment("evaluated_candidates")
  end

  defp summary(records, decision, attempts \\ nil),
    do: %{
      "attempt_count" => attempts || length(records),
      "decision" => decision,
      "outcomes" => Enum.map(records, & &1.outcome),
      "record_ids" => Enum.map(records, & &1.id)
    }

  defp increment(state, key), do: update_in(state, [:usage, key], &(&1 + 1))

  defp retain_record(state, record),
    do: Map.update!(state, :evidence_records, &[record | &1])

  defp cleanup(:unknown), do: %{"active" => nil, "quarantined" => nil, "status" => "unknown"}

  defp cleanup(%{active: active, quarantined: quarantined}) do
    %{
      "active" => active,
      "quarantined" => quarantined,
      "status" => if(active == 0 and quarantined == 0, do: "complete", else: "incomplete")
    }
  end

  defp source(state) do
    source = state.original_regression.confirmed_record

    %{
      "capsule_id" => source["capsule_id"],
      "expected_fingerprint" => state.original_regression.expectation["incident_fingerprint"],
      "manifest_id" => state.manifest.id,
      "observer" => state.observer,
      "regression_id" => state.original_regression.id,
      "target_id" => state.target.id
    }
  end

  defp policy(max_candidates, max_duration_ms, request),
    do: %{
      "algorithm" => "greedy_delete_steps_v1",
      "duration_scope" => "execution_search",
      "max_candidates" => max_candidates,
      "max_confirmation_runs" => @baseline_runs + @candidate_runs * max_candidates,
      "max_duration_ms" => max_duration_ms,
      "max_total_bytes" =>
        request.budget.max_bytes * (@baseline_runs + @candidate_runs * max_candidates),
      "max_total_events" =>
        request.budget.max_events * (@baseline_runs + @candidate_runs * max_candidates),
      "per_run_max_bytes" => request.budget.max_bytes,
      "per_run_max_events" => request.budget.max_events,
      "required_baseline_runs" => @baseline_runs,
      "required_candidate_runs" => @candidate_runs
    }

  defp baseline_decision({:ok, %{"status" => "failed"}}, _records), do: "failed"

  defp baseline_decision(_evaluation, records) do
    outcomes = Enum.map(records, & &1.outcome)

    if Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"],
      do: "nondeterministic",
      else: "inconclusive"
  end

  defp stop_decision(:total_deadline_exhausted), do: "exhausted"
  defp stop_decision(_reason), do: "inconclusive"

  defp uncertainty("baseline_inconclusive"), do: "baseline did not reproduce consistently"

  defp uncertainty("baseline_nondeterministic"),
    do: "baseline reproduction was nondeterministic"

  defp uncertainty("candidate_nondeterministic"),
    do: "candidate reproduction was nondeterministic"

  defp uncertainty("candidate_inconclusive"), do: "candidate evidence was inconclusive"

  defp uncertainty("executor_not_clean"),
    do: "sandbox executor retained active or quarantined work"

  defp uncertainty("executor_state_unknown"),
    do: "sandbox executor cleanup state could not be established"

  defp uncertainty("max_candidates_exhausted"), do: "candidate bound exhausted before minimality"
  defp uncertainty("total_deadline_exhausted"), do: "duration bound exhausted before minimality"

  defp bind_inputs(regression, manifest, capsule, scenario, target, observer, request) do
    source = regression.confirmed_record

    with {:ok, descriptor} <- Scenario.descriptor(scenario),
         true <- manifest.prerequisites["scenario"] == descriptor,
         true <- source["manifest_id"] == manifest.id,
         true <- source["capsule_id"] == capsule.id,
         true <- source["scenario_id"] == scenario.id,
         true <- source["observed_target_fingerprint"] == Target.target_fingerprint(target),
         true <- regression.expectation["observer"] == observer,
         true <- request.operation == "verification.run",
         true <- request.params == %{"sandbox_target_id" => target.id} do
      :ok
    else
      _other -> input_mismatch()
    end
  end

  defp valid_options?(options) do
    with true <- Value.bounded_list?(options, length(@option_keys)),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options) do
      keys -- @option_keys == [] and Enum.uniq(keys) == keys and
        Enum.all?(@required_options, &Keyword.has_key?(options, &1))
    else
      _other -> false
    end
  end

  defp input_mismatch,
    do: {:error, Error.new(:minimization_input_mismatch, "minimization inputs do not agree")}
end
