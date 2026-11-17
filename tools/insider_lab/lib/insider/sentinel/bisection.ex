defmodule Insider.Sentinel.Bisection do
  @moduledoc """
  Bounded offline binary search over a host-declared ordered target list.

  The host supplies an ordered list of disposable sandbox targets, oldest to
  newest; Insider never reads a repository, orders revisions, checks anything
  out, or mutates source. Both endpoints must first be proven with two fresh
  confirmations each: the oldest must not reproduce and the newest must. Every
  midpoint then runs two fresh confirmations. Mixed outcomes at one index stop
  as nondeterministic, and any infrastructure, evidence, or cleanup uncertainty
  stops as inconclusive; an index whose first confirmation is not clean is
  already inconclusive and gets no second one. The configured duration bounds
  the effectful search from executor preflight through final cleanup; bounded
  input and final evidence validation are outside that clock.

  A completed record isolates one adjacent nonreproduced/reproduced pair of
  declared targets on the search path. Reading that pair as the earliest
  reproducing target is the host's monotonicity assumption: indices off the
  search path are never probed, and the record's fixed limitations say so. It
  does not claim that the target caused the failure.
  """

  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Value
  alias Insider.Scenario
  alias Insider.Sentinel.Bisection.Record
  alias Insider.Sentinel.Bisection.Result
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target

  @maximum_duration_ms 600_000
  @default_probes 32
  @default_duration_ms 60_000
  @await_slack_ms 1_000
  @component_names ["code", "configuration", "dependencies", "runtime", "target"]
  @option_keys [:request, :context, :body, :observer, :max_probes, :max_duration_ms]
  @required_options [:request, :context, :body, :observer]

  @spec run(Supervisor.supervisor(), term(), term(), term(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def run(executor, regression, manifest, capsule, targets, options) do
    with true <- valid_options?(options),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, scenario} <- Scenario.decode_map(regression.scenario),
         {:ok, targets} <- Record.validate_targets(targets),
         %Request{} = request <- Keyword.fetch!(options, :request),
         true <- Request.valid?(request),
         %Context{} = context <- Keyword.fetch!(options, :context),
         true <- Context.valid?(context),
         body when is_atom(body) <- Keyword.fetch!(options, :body),
         observer when is_map(observer) <- Keyword.fetch!(options, :observer),
         max_probes when is_integer(max_probes) and max_probes >= 1 <-
           Keyword.get(options, :max_probes, @default_probes),
         true <- max_probes <= Record.maximum_probes(),
         max_duration_ms when max_duration_ms in 1..@maximum_duration_ms <-
           Keyword.get(options, :max_duration_ms, @default_duration_ms),
         :ok <- bind_inputs(regression, manifest, capsule, scenario, targets, observer, request) do
      now = System.monotonic_time(:millisecond)

      state = %{
        body: body,
        capsule: capsule,
        context: context,
        deadline: min(request.deadline_monotonic, now + max_duration_ms),
        evidence_records: [],
        high: nil,
        low: nil,
        manifest: manifest,
        observer: observer,
        policy: policy(max_probes, max_duration_ms, request, length(targets)),
        regression: regression,
        request: request,
        scenario: scenario,
        started_at: now * 1_000,
        targets: targets,
        trials: [],
        usage: %{"confirmation_runs" => 0, "duration_us" => 0, "probed_indices" => 0}
      }

      preflight(state, executor)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> input_mismatch()
    end
  rescue
    _error -> {:error, Error.new(:operation_failed, "bisection failed")}
  catch
    :exit, _reason ->
      {:error, Error.new(:operation_failed, "bisection executor is unavailable")}
  end

  defp preflight(state, executor) do
    case bounded_counts(executor, state.deadline) do
      {:ok, %{active: 0, quarantined: 0}, _completed_at_us} ->
        probe(state, executor, 0, "oldest_endpoint")

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

  defp probe(state, executor, index, role) do
    if state.usage["confirmation_runs"] + Record.probes_per_index() > state.policy["max_probes"] do
      finish(state, executor, "exhausted", "max_probes_exhausted")
    else
      target = Enum.at(state.targets, index)

      case confirmations(state, executor, target) do
        {:ok, records, state} ->
          decision = Record.probe_decision(records, binding(state, target))
          state = add_trial(state, index, role, target, records, decision)
          advance(state, executor, index, role, decision)

        {:stop, reason, records, attempts, state} ->
          state = add_trial(state, index, role, target, records, stop_decision(reason), attempts)
          stop(state, executor, reason)

        {:error, %Error{} = error, state} ->
          confirmation_error(error, state, executor)
      end
    end
  end

  defp advance(state, executor, 0, "oldest_endpoint", "nonreproduced"),
    do: probe(%{state | low: 0}, executor, length(state.targets) - 1, "newest_endpoint")

  defp advance(state, executor, _index, "oldest_endpoint", "reproduced"),
    do: finish(state, executor, "inconclusive", "baseline_not_bracketed")

  defp advance(state, executor, index, "newest_endpoint", "reproduced"),
    do: search(%{state | high: index}, executor)

  defp advance(state, executor, _index, "newest_endpoint", "nonreproduced"),
    do: finish(state, executor, "inconclusive", "baseline_not_bracketed")

  defp advance(state, executor, index, "midpoint", "nonreproduced"),
    do: search(%{state | low: index}, executor)

  defp advance(state, executor, index, "midpoint", "reproduced"),
    do: search(%{state | high: index}, executor)

  defp advance(state, executor, _index, _role, "nondeterministic"),
    do: finish(state, executor, "inconclusive", "probe_nondeterministic")

  defp advance(state, executor, _index, _role, "inconclusive"),
    do: finish(state, executor, "inconclusive", "probe_inconclusive")

  defp search(%{low: low, high: high} = state, executor) when high - low == 1,
    do: finish(state, executor, "completed", "adjacent_boundary_isolated")

  defp search(%{low: low, high: high} = state, executor),
    do: probe(state, executor, div(low + high, 2), "midpoint")

  defp confirmations(state, executor, target) do
    count = Record.probes_per_index()
    binding = binding(state, target)

    if enough_time?(state, count) do
      Enum.reduce_while(1..count, {:ok, [], 0, state}, fn index,
                                                          {:ok, records, attempts, state} ->
        remaining_runs = count - index + 1

        if enough_time?(state, remaining_runs) do
          request = run_request(state, target)

          result =
            Confirmation.run(executor, state.manifest, state.capsule, state.scenario, target,
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
                  records = [record | records]

                  if Record.clean_probe?(record, binding),
                    do: {:cont, {:ok, records, attempts, state}},
                    else: {:halt, {:ok, records, attempts, state}}

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

  defp enough_time?(state, count) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    remaining >= count * (run_timeout(state) + @await_slack_ms)
  end

  defp run_request(state, target) do
    timeout = run_timeout(state)
    index = state.usage["confirmation_runs"] + 1
    digest = :crypto.hash(:sha256, "#{state.request.request_id}:#{index}")
    request_id = "bis-" <> Base.encode16(digest, case: :lower)

    %{
      state.request
      | request_id: request_id,
        timeout_ms: timeout,
        deadline_monotonic: min(state.deadline, System.monotonic_time(:millisecond) + timeout),
        params: %{"sandbox_target_id" => target.id}
    }
  end

  defp run_timeout(%{request: request, scenario: scenario}) do
    scenario_bound =
      scenario.limits["max_duration_ms"] + scenario.limits["cleanup_timeout_ms"] + 250

    min(request.timeout_ms, scenario_bound)
  end

  defp stop(state, executor, :total_deadline_exhausted),
    do: finish(state, executor, "exhausted", "total_deadline_exhausted")

  defp stop(state, executor, :executor_not_clean),
    do: finish(state, executor, "inconclusive", "executor_not_clean")

  defp stop(state, executor, :executor_state_unknown),
    do: finish(state, executor, "inconclusive", "executor_state_unknown")

  defp finish(state, executor, status, reason) do
    # Preserve the cleanup observation that stopped the search; a later count can differ.
    {cleanup, finished_at_us} =
      Map.get_lazy(state, :cleanup_at_stop, fn -> final_cleanup(state, executor) end)

    {status, reason} = cleanup_terminal(status, reason, cleanup)
    duration_us = max(0, finished_at_us - state.started_at)
    uncertainty = if status == "completed", do: [], else: [Record.expected_uncertainty(reason)]
    usage = Map.put(state.usage, "duration_us", duration_us)

    with {:ok, record} <-
           Record.new(
             source: source(state),
             targets: Record.declared_targets(state.targets),
             policy: state.policy,
             status: status,
             reason: reason,
             culprit: culprit(state, status),
             trials: Enum.reverse(state.trials),
             usage: usage,
             cleanup: cleanup,
             uncertainty: uncertainty
           ) do
      records = Enum.reverse(state.evidence_records)

      with {:ok, valid_record} <-
             Record.validate_with_evidence(
               record,
               state.regression,
               state.capsule,
               state.manifest,
               state.targets,
               records
             ) do
        {:ok, %Result{record: valid_record, confirmation_records: records}}
      end
    end
  end

  defp culprit(state, "completed") do
    target = Enum.at(state.targets, state.high)

    %{
      "boundary_nonreproduced_index" => state.low,
      "boundary_reproducing_index" => state.high,
      "proof" => "adjacent_boundary_isolated",
      "target_fingerprint" => Target.target_fingerprint(target),
      "target_id" => target.id
    }
  end

  defp culprit(state, _status) do
    %{
      "boundary_nonreproduced_index" => state.low,
      "boundary_reproducing_index" => state.high,
      "proof" => "not_proven",
      "target_fingerprint" => nil,
      "target_id" => nil
    }
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
        "bisection_cleanup" => cleanup,
        "bisection_confirmation_runs" => state.usage["confirmation_runs"]
      })

    annotated = %{error | details: details}

    if Error.valid?(annotated) do
      {:error, annotated}
    else
      {:error,
       %{
         error
         | details: %{
             "bisection_cleanup" => cleanup,
             "bisection_confirmation_runs" => state.usage["confirmation_runs"],
             "original_details_omitted" => true
           }
       }}
    end
  end

  defp add_trial(state, index, role, target, records, decision, attempts \\ nil) do
    trial = %{
      "attempt_count" => attempts || length(records),
      "decision" => decision,
      "index" => index,
      "outcomes" => Enum.map(records, & &1.outcome),
      "record_ids" => Enum.map(records, & &1.id),
      "role" => role,
      "target_fingerprint" => Target.target_fingerprint(target),
      "target_id" => target.id
    }

    state
    |> Map.update!(:trials, &[trial | &1])
    |> increment("probed_indices")
  end

  defp binding(state, target) do
    source = state.regression.confirmed_record

    %{
      "capsule_id" => state.capsule.id,
      "expected_fingerprint" => state.regression.expectation["incident_fingerprint"],
      "manifest_id" => state.manifest.id,
      "observer" => state.observer,
      "scenario_id" => state.scenario.id,
      "source_observation_run" => source["evidence"]["observation_run_fingerprint"],
      "source_record_id" => source["id"],
      "target_fingerprint" => Target.target_fingerprint(target)
    }
  end

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
    %{
      "capsule_id" => state.capsule.id,
      "expected_fingerprint" => state.regression.expectation["incident_fingerprint"],
      "manifest_id" => state.manifest.id,
      "observer" => state.observer,
      "regression_id" => state.regression.id,
      "scenario_id" => state.scenario.id
    }
  end

  defp policy(max_probes, max_duration_ms, request, target_count),
    do: %{
      "algorithm" => Record.algorithm(),
      "duration_scope" => "execution_search",
      "max_duration_ms" => max_duration_ms,
      "max_probes" => max_probes,
      "max_total_bytes" => request.budget.max_bytes * max_probes,
      "max_total_events" => request.budget.max_events * max_probes,
      "per_run_max_bytes" => request.budget.max_bytes,
      "per_run_max_events" => request.budget.max_events,
      "required_probes_per_index" => Record.probes_per_index(),
      "target_count" => target_count
    }

  defp stop_decision(:total_deadline_exhausted), do: "exhausted"
  defp stop_decision(_reason), do: "inconclusive"

  defp bind_inputs(regression, manifest, capsule, scenario, targets, observer, request) do
    source = regression.confirmed_record
    newest = List.last(targets)

    with {:ok, descriptor} <- Scenario.descriptor(scenario),
         true <- manifest.prerequisites["scenario"] == descriptor,
         true <- source["manifest_id"] == manifest.id,
         true <- source["capsule_id"] == capsule.id,
         true <- source["scenario_id"] == scenario.id,
         true <- source["observed_target_fingerprint"] == Target.target_fingerprint(newest),
         true <- Enum.all?(targets, &target_matches_manifest?(&1, manifest)),
         true <- regression.expectation["observer"] == observer,
         true <- request.operation == "verification.run",
         true <- request.params == %{"sandbox_target_id" => newest.id} do
      :ok
    else
      _other -> input_mismatch()
    end
  end

  # The same prerequisite binding Confirmation.run enforces, checked for every
  # declared target before any probe is dispatched.
  defp target_matches_manifest?(target, manifest) do
    components = target.provenance["components"]

    Enum.all?(@component_names, fn name ->
      components[name]["fingerprint"] == manifest.prerequisites[name]["fingerprint"]
    end)
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
    do: {:error, Error.new(:bisection_input_mismatch, "bisection inputs do not agree")}
end
