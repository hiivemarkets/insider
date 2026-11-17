defmodule Insider.Sentinel.Bisection.Record do
  @moduledoc """
  Canonical evidence for one bounded offline bisection over declared targets.

  The record describes a deterministic binary search over a host-supplied
  ordered target list and references exact confirmation records by identity.
  SHA-256 establishes content identity, not source authenticity; callers must
  retain the referenced evidence graph. The record never names a repository,
  revision order, checkout, or Git operation: every target is declared input.

  A completed record isolates one adjacent nonreproduced/reproduced pair on the
  search path. Its fixed `limitations` state that reading that pair as the
  earliest reproducing target is a host assumption of monotonic outcomes and
  that indices off the search path are never probed.
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

  @schema "insider.bisection-record/v1"
  @algorithm "binary_search_declared_targets_v1"
  @maximum_bytes 262_144
  @maximum_targets 64
  @maximum_probes 128
  @maximum_trials 8
  @probes_per_index 2
  @controls %{
    "checkout" => "none",
    "git_authority" => "none",
    "network_effect" => "none",
    "repository_read" => "none",
    "source_mutation" => "prohibited"
  }
  @limitations [
    "indices_off_the_search_path_are_not_probed",
    "outcome_monotonicity_is_a_host_assumption",
    "target_causality_is_not_claimed"
  ]
  @option_keys [
    :source,
    :targets,
    :policy,
    :status,
    :reason,
    :culprit,
    :trials,
    :usage,
    :cleanup,
    :uncertainty
  ]
  @fields [
    :schema,
    :id,
    :source,
    :targets,
    :policy,
    :controls,
    :limitations,
    :status,
    :reason,
    :culprit,
    :trials,
    :usage,
    :cleanup,
    :uncertainty,
    :integrity
  ]
  @wire_keys Enum.map(@fields, &Atom.to_string/1)
  @statuses ["completed", "exhausted", "inconclusive"]
  @completed_reason "adjacent_boundary_isolated"
  @exhausted_reasons ["max_probes_exhausted", "total_deadline_exhausted"]
  @executor_reasons ["executor_not_clean", "executor_state_unknown"]
  @inconclusive_reasons [
    "baseline_not_bracketed",
    "probe_nondeterministic",
    "probe_inconclusive" | @executor_reasons
  ]
  @reasons [@completed_reason | @exhausted_reasons ++ @inconclusive_reasons]
  @decisions ["nonreproduced", "reproduced", "nondeterministic", "inconclusive", "exhausted"]
  @roles ["oldest_endpoint", "newest_endpoint", "midpoint"]
  @outcomes ~w(infrastructure_failure matching_failure nonreproduced repaired unrelated_failure)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec controls() :: map()
  def controls, do: @controls

  @spec limitations() :: [String.t()]
  def limitations, do: @limitations

  @spec algorithm() :: String.t()
  def algorithm, do: @algorithm

  @spec probes_per_index() :: pos_integer()
  def probes_per_index, do: @probes_per_index

  @spec maximum_probes() :: pos_integer()
  def maximum_probes, do: @maximum_probes

  @spec maximum_targets() :: pos_integer()
  def maximum_targets, do: @maximum_targets

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: StrictOptions.build(options, @option_keys, &build/1, &invalid/1)

  defp build(options) do
    content =
      @option_keys
      |> Map.new(fn key -> {Atom.to_string(key), Keyword.fetch!(options, key)} end)
      |> Map.merge(%{"controls" => @controls, "limitations" => @limitations, "schema" => @schema})

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
         true <- valid_targets?(record.targets),
         true <- valid_policy?(record.policy, length(record.targets)),
         true <- record.controls == @controls,
         true <- record.limitations == @limitations,
         true <- record.status in @statuses,
         true <- record.reason in @reasons,
         true <- Value.bounded_list?(record.trials, @maximum_trials),
         true <- Enum.all?(record.trials, &valid_trial?(&1, record.targets)),
         {:ok, search} <- replay_trials(record.trials, length(record.targets)),
         true <- terminal_sequence?(record, search),
         true <- valid_culprit?(record, search),
         true <- valid_usage?(record.usage, record.policy, record.trials),
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
  Recomputes a bisection record from its retained trusted evidence graph.

  Standalone validation proves canonical shape and that the recorded trials
  form one deterministic search path. This operation additionally binds the
  source regression, capsule, manifest, the exact ordered declared targets, and
  every referenced confirmation record, and rederives each trial decision from
  the records it references.
  """
  @spec validate_with_evidence(term(), term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(record, regression, capsule, manifest, targets, records) do
    with {:ok, record} <- validate(record),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, targets} <- validate_targets(targets),
         true <- record.targets == declared_targets(targets),
         {:ok, records} <- validate_confirmation_records(records, record.policy),
         true <- source_evidence_bound?(record, regression, capsule, manifest, targets),
         true <- referenced_ids(record) == Enum.map(records, & &1.id),
         true <- unique_confirmation_evidence?(regression, records),
         true <- evidence_decisions_valid?(record, regression, capsule, manifest, records) do
      {:ok, record}
    else
      _other -> invalid(:evidence_graph_mismatch)
    end
  rescue
    _error -> invalid(:evidence_validation_failed)
  catch
    _kind, _reason -> invalid(:evidence_validation_failed)
  end

  @doc false
  @spec validate_targets(term()) :: {:ok, [Target.t()]} | :error
  def validate_targets(targets) do
    with true <- is_list(targets),
         true <- Value.bounded_list?(targets, @maximum_targets),
         true <- length(targets) >= 2,
         {:ok, valid} <- validate_each_target(targets),
         ids <- Enum.map(valid, & &1.id),
         true <- Enum.uniq(ids) == ids do
      {:ok, valid}
    else
      _other -> :error
    end
  end

  @doc false
  @spec declared_targets([Target.t()]) :: [map()]
  def declared_targets(targets) do
    targets
    |> Enum.with_index()
    |> Enum.map(fn {target, index} ->
      %{
        "index" => index,
        "target_fingerprint" => Target.target_fingerprint(target),
        "target_id" => target.id
      }
    end)
  end

  @doc """
  Derives one index decision from exactly the probes run for that index.

  Every probe must be a complete, clean, distinct confirmation bound to the
  declared binding; the declared target fingerprint must equal both the
  requested and observed target fingerprint of that probe. Anything else is
  inconclusive rather than a weaker verdict. One probe that is not clean is
  already inconclusive, so the search records it alone; see `clean_probe?/2`.
  """
  @spec probe_decision([ConfirmationRecord.t()], map()) :: String.t()
  def probe_decision(records, binding) when length(records) == @probes_per_index do
    outcomes = Enum.map(records, & &1.outcome)

    cond do
      not Enum.all?(records, &clean_probe?(&1, binding)) or not distinct_probes?(records, binding) ->
        "inconclusive"

      outcomes == List.duplicate("matching_failure", @probes_per_index) ->
        "reproduced"

      outcomes == List.duplicate("nonreproduced", @probes_per_index) ->
        "nonreproduced"

      Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"] ->
        "nondeterministic"

      true ->
        "inconclusive"
    end
  end

  def probe_decision(_records, _binding), do: "inconclusive"

  @doc """
  Whether one probe is a complete, clean confirmation bound to the declared
  binding.

  An index whose first probe is not clean is inconclusive whatever a second
  probe would return, so the search stops there. Probes that fail before
  observation carry no run identity and would otherwise repeat one
  content-addressed record, which no trial may reference twice.
  """
  @spec clean_probe?(ConfirmationRecord.t(), map()) :: boolean()
  def clean_probe?(record, binding) do
    evidence = record.evidence

    requested_target_bound?(record, binding) and
      record.observed_target_fingerprint == binding["target_fingerprint"] and
      evidence["observer"] == binding["observer"] and
      record.operational_status == "completed" and is_nil(record.operational_reason) and
      record.cleanup["status"] == "complete" and record.cleanup["remaining_count"] == 0 and
      is_nil(record.cleanup["remaining_fingerprint"]) and
      record.cleanup["release"] in ["complete", "failed"] and evidence["status"] == "complete" and
      evidence["lease_execution"] == "confirmed" and
      evidence["owner_fingerprint"] == evidence["observation_run_fingerprint"] and
      is_nil(evidence["repair_oracle"]) and record.uncertainty == []
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

  defp validate_each_target(targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case Target.validate(target) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp validate_confirmation_records(records, policy) do
    if Value.bounded_list?(records, policy["max_probes"]) do
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

  defp source_evidence_bound?(record, regression, capsule, manifest, targets) do
    confirmed = regression.confirmed_record
    newest = List.last(targets)

    record.source == %{
      "capsule_id" => capsule.id,
      "expected_fingerprint" => regression.expectation["incident_fingerprint"],
      "manifest_id" => manifest.id,
      "observer" => regression.expectation["observer"],
      "regression_id" => regression.id,
      "scenario_id" => regression.scenario["id"]
    } and confirmed["capsule_id"] == capsule.id and confirmed["manifest_id"] == manifest.id and
      confirmed["scenario_id"] == regression.scenario["id"] and
      confirmed["observed_target_fingerprint"] == Target.target_fingerprint(newest) and
      manifest.prerequisites["scenario"] == scenario_descriptor(regression.scenario)
  end

  defp referenced_ids(record), do: Enum.flat_map(record.trials, & &1["record_ids"])

  defp unique_confirmation_evidence?(regression, records) do
    source = regression.confirmed_record
    ids = Enum.map(records, & &1.id)
    owners = Enum.map(records, & &1.evidence["observation_run_fingerprint"])

    Enum.uniq(ids) == ids and Enum.uniq(owners) == owners and source["id"] not in ids and
      source["evidence"]["observation_run_fingerprint"] not in owners
  end

  defp evidence_decisions_valid?(record, regression, capsule, manifest, records) do
    replay =
      Enum.reduce_while(record.trials, {:ok, records}, fn trial, {:ok, remaining} ->
        {trial_records, remaining} = Enum.split(remaining, length(trial["record_ids"]))
        binding = binding(regression, capsule, manifest, trial["target_fingerprint"])

        with true <- summary_evidence_matches?(trial, trial_records),
             true <- Enum.all?(trial_records, &requested_target_bound?(&1, binding)),
             true <-
               trial_evidence_decision_valid?(trial, trial_records, binding, record.reason) do
          {:cont, {:ok, remaining}}
        else
          _other -> {:halt, :error}
        end
      end)

    match?({:ok, []}, replay)
  end

  defp binding(regression, capsule, manifest, target_fingerprint) do
    source = regression.confirmed_record

    %{
      "capsule_id" => capsule.id,
      "expected_fingerprint" => regression.expectation["incident_fingerprint"],
      "manifest_id" => manifest.id,
      "observer" => regression.expectation["observer"],
      "scenario_id" => regression.scenario["id"],
      "source_observation_run" => source["evidence"]["observation_run_fingerprint"],
      "source_record_id" => source["id"],
      "target_fingerprint" => target_fingerprint
    }
  end

  defp trial_evidence_decision_valid?(%{"decision" => decision}, records, binding, _reason)
       when decision in ["reproduced", "nonreproduced", "nondeterministic"],
       do: probe_decision(records, binding) == decision

  defp trial_evidence_decision_valid?(
         %{"decision" => "inconclusive"},
         [record],
         binding,
         "probe_inconclusive"
       ),
       do: not clean_probe?(record, binding)

  defp trial_evidence_decision_valid?(
         %{"decision" => "inconclusive"},
         records,
         binding,
         "probe_inconclusive"
       ),
       do: probe_decision(records, binding) == "inconclusive"

  defp trial_evidence_decision_valid?(%{"decision" => "inconclusive"}, records, _binding, reason)
       when reason in @executor_reasons,
       do: length(records) in 1..@probes_per_index

  defp trial_evidence_decision_valid?(%{"decision" => "exhausted"}, records, _binding, reason)
       when reason in ["total_deadline_exhausted" | @executor_reasons],
       do: length(records) in 0..(@probes_per_index - 1)

  defp trial_evidence_decision_valid?(_trial, _records, _binding, _reason), do: false

  defp requested_target_bound?(record, binding) do
    record.capsule_id == binding["capsule_id"] and record.manifest_id == binding["manifest_id"] and
      record.scenario_id == binding["scenario_id"] and
      record.expected_fingerprint == binding["expected_fingerprint"] and
      record.requested_target_fingerprint == binding["target_fingerprint"]
  end

  defp distinct_probes?(records, binding) do
    ids = Enum.map(records, & &1.id)
    owners = Enum.map(records, & &1.evidence["observation_run_fingerprint"])

    Enum.uniq(ids) == ids and Enum.uniq(owners) == owners and
      binding["source_record_id"] not in ids and
      binding["source_observation_run"] not in owners
  end

  defp summary_evidence_matches?(trial, records),
    do:
      trial["record_ids"] == Enum.map(records, & &1.id) and
        trial["outcomes"] == Enum.map(records, & &1.outcome)

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
      ~w(capsule_id expected_fingerprint manifest_id observer regression_id scenario_id)
    ) and
      Enum.all?(~w(capsule_id manifest_id regression_id scenario_id), &id?(source[&1])) and
      digest?(source["expected_fingerprint"]) and Ingress.identity?(source["observer"])
  end

  defp valid_targets?(targets) do
    with true <- is_list(targets),
         true <- Value.bounded_list?(targets, @maximum_targets),
         true <- length(targets) >= 2,
         true <- Enum.all?(targets, &valid_declared_target?/1),
         true <- Enum.map(targets, & &1["index"]) == Enum.to_list(0..(length(targets) - 1)),
         ids <- Enum.map(targets, & &1["target_id"]) do
      Enum.uniq(ids) == ids
    else
      _other -> false
    end
  end

  defp valid_declared_target?(target),
    do:
      exact_keys?(target, ~w(index target_fingerprint target_id)) and
        is_integer(target["index"]) and target["index"] >= 0 and
        digest?(target["target_fingerprint"]) and id?(target["target_id"])

  defp valid_policy?(policy, target_count) do
    exact_keys?(
      policy,
      ~w(algorithm duration_scope max_duration_ms max_probes max_total_bytes max_total_events per_run_max_bytes per_run_max_events required_probes_per_index target_count)
    ) and policy["algorithm"] == @algorithm and
      policy["duration_scope"] == "execution_search" and
      is_integer(policy["max_probes"]) and policy["max_probes"] in 1..@maximum_probes and
      is_integer(policy["max_duration_ms"]) and policy["max_duration_ms"] in 1..600_000 and
      positive_integer?(policy["per_run_max_bytes"]) and
      positive_integer?(policy["per_run_max_events"]) and
      policy["max_total_bytes"] == policy["per_run_max_bytes"] * policy["max_probes"] and
      policy["max_total_events"] == policy["per_run_max_events"] * policy["max_probes"] and
      policy["required_probes_per_index"] == @probes_per_index and
      policy["target_count"] == target_count
  end

  defp valid_trial?(trial, targets) do
    exact_keys?(
      trial,
      ~w(attempt_count decision index outcomes record_ids role target_fingerprint target_id)
    ) and is_integer(trial["index"]) and trial["index"] in 0..(length(targets) - 1) and
      Enum.at(targets, trial["index"]) == %{
        "index" => trial["index"],
        "target_fingerprint" => trial["target_fingerprint"],
        "target_id" => trial["target_id"]
      } and trial["role"] in @roles and trial["decision"] in @decisions and
      is_integer(trial["attempt_count"]) and trial["attempt_count"] in 0..@probes_per_index and
      valid_id_list?(trial["record_ids"], @probes_per_index) and
      valid_outcomes?(trial["outcomes"], @probes_per_index) and
      length(trial["record_ids"]) == length(trial["outcomes"]) and
      length(trial["record_ids"]) == trial["attempt_count"] and valid_trial_decision?(trial)
  end

  defp valid_trial_decision?(%{
         "attempt_count" => @probes_per_index,
         "decision" => "reproduced",
         "outcomes" => ["matching_failure", "matching_failure"]
       }),
       do: true

  defp valid_trial_decision?(%{
         "attempt_count" => @probes_per_index,
         "decision" => "nonreproduced",
         "outcomes" => ["nonreproduced", "nonreproduced"]
       }),
       do: true

  defp valid_trial_decision?(%{
         "attempt_count" => @probes_per_index,
         "decision" => "nondeterministic",
         "outcomes" => outcomes
       }),
       do: Enum.sort(Enum.uniq(outcomes)) == ["matching_failure", "nonreproduced"]

  defp valid_trial_decision?(%{"attempt_count" => attempts, "decision" => "inconclusive"}),
    do: attempts in 1..@probes_per_index

  defp valid_trial_decision?(%{"attempt_count" => attempts, "decision" => "exhausted"}),
    do: attempts in 0..(@probes_per_index - 1)

  defp valid_trial_decision?(_trial), do: false

  # Replays the recorded trials as the deterministic search path. Every trial
  # must probe exactly the index the algorithm would select next; the first
  # terminal decision ends the path.
  defp replay_trials(trials, target_count) do
    initial = %{high: nil, low: nil, step: 0, terminal: nil}

    Enum.reduce_while(trials, {:ok, initial}, fn trial, {:ok, search} ->
      case replay_trial(search, trial, target_count) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp replay_trial(%{terminal: terminal}, _trial, _target_count) when not is_nil(terminal),
    do: :error

  defp replay_trial(%{step: 0} = search, trial, _target_count) do
    if trial["index"] == 0 and trial["role"] == "oldest_endpoint",
      do: {:ok, decide(search, trial, "nonreproduced", %{low: 0})},
      else: :error
  end

  defp replay_trial(%{step: 1} = search, trial, target_count) do
    newest = target_count - 1

    if trial["index"] == newest and trial["role"] == "newest_endpoint",
      do: {:ok, decide(search, trial, "reproduced", %{high: newest})},
      else: :error
  end

  defp replay_trial(%{low: low, high: high} = search, trial, _target_count)
       when is_integer(low) and is_integer(high) and high - low > 1 do
    midpoint = div(low + high, 2)

    if trial["index"] == midpoint and trial["role"] == "midpoint" do
      case trial["decision"] do
        "nonreproduced" -> {:ok, advance(search, %{low: midpoint})}
        "reproduced" -> {:ok, advance(search, %{high: midpoint})}
        other -> {:ok, advance(search, %{terminal: terminal_for(other)})}
      end
    else
      :error
    end
  end

  defp replay_trial(_search, _trial, _target_count), do: :error

  defp decide(search, trial, expected, update) do
    decision = trial["decision"]

    cond do
      decision == expected -> advance(search, update)
      decision in ["nonreproduced", "reproduced"] -> advance(search, %{terminal: :not_bracketed})
      true -> advance(search, %{terminal: terminal_for(decision)})
    end
  end

  defp advance(search, update), do: search |> Map.merge(update) |> Map.update!(:step, &(&1 + 1))

  defp terminal_for("nondeterministic"), do: :nondeterministic
  defp terminal_for("inconclusive"), do: :inconclusive
  defp terminal_for("exhausted"), do: :exhausted

  defp isolated?(%{low: low, high: high}),
    do: is_integer(low) and is_integer(high) and high - low == 1

  defp terminal_sequence?(record, search) do
    case record.reason do
      @completed_reason ->
        is_nil(search.terminal) and isolated?(search)

      "max_probes_exhausted" ->
        is_nil(search.terminal) and not isolated?(search) and
          record.usage["confirmation_runs"] + @probes_per_index > record.policy["max_probes"]

      "total_deadline_exhausted" ->
        search.terminal == :exhausted

      "baseline_not_bracketed" ->
        search.terminal == :not_bracketed

      "probe_nondeterministic" ->
        search.terminal == :nondeterministic

      "probe_inconclusive" ->
        search.terminal == :inconclusive and
          List.last(record.trials)["attempt_count"] in 1..@probes_per_index

      # A late unclean or unknown cleanup overrides any search state, so the
      # path itself is unconstrained; cleanup coherence is checked separately.
      reason when reason in @executor_reasons ->
        true
    end
  end

  defp valid_culprit?(record, search) do
    expected =
      if record.status == "completed" do
        culprit = Enum.at(record.targets, search.high)

        %{
          "boundary_nonreproduced_index" => search.low,
          "boundary_reproducing_index" => search.high,
          "proof" => "adjacent_boundary_isolated",
          "target_fingerprint" => culprit["target_fingerprint"],
          "target_id" => culprit["target_id"]
        }
      else
        %{
          "boundary_nonreproduced_index" => search.low,
          "boundary_reproducing_index" => search.high,
          "proof" => "not_proven",
          "target_fingerprint" => nil,
          "target_id" => nil
        }
      end

    record.culprit == expected
  end

  defp valid_usage?(usage, policy, trials) do
    exact_keys?(usage, ~w(confirmation_runs duration_us probed_indices)) and
      Enum.all?(
        ~w(confirmation_runs duration_us probed_indices),
        &(is_integer(usage[&1]) and usage[&1] >= 0)
      ) and
      usage["probed_indices"] == length(trials) and
      usage["confirmation_runs"] == Enum.reduce(trials, 0, &(&1["attempt_count"] + &2)) and
      usage["confirmation_runs"] <= policy["max_probes"]
  end

  defp valid_duration_claim?(%{status: "completed", usage: usage, policy: policy}),
    do: usage["duration_us"] <= policy["max_duration_ms"] * 1_000

  defp valid_duration_claim?(%{reason: "max_probes_exhausted", usage: usage, policy: policy}),
    do: usage["duration_us"] <= policy["max_duration_ms"] * 1_000

  defp valid_duration_claim?(_record), do: true

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
    status_reason_coherent?(record) and cleanup_reason_coherent?(record) and
      if record.status == "completed",
        do: record.uncertainty == [],
        else: record.uncertainty == [expected_uncertainty(record.reason)]
  end

  defp status_reason_coherent?(%{status: "completed", reason: @completed_reason}), do: true

  defp status_reason_coherent?(%{status: "exhausted", reason: reason}),
    do: reason in @exhausted_reasons

  defp status_reason_coherent?(%{status: "inconclusive", reason: reason}),
    do: reason in @inconclusive_reasons

  defp status_reason_coherent?(_record), do: false

  defp cleanup_reason_coherent?(%{reason: "executor_not_clean"} = record),
    do: record.cleanup["status"] == "incomplete"

  defp cleanup_reason_coherent?(%{reason: "executor_state_unknown"} = record),
    do: record.cleanup["status"] == "unknown"

  defp cleanup_reason_coherent?(record), do: record.cleanup["status"] == "complete"

  @doc false
  @spec expected_uncertainty(String.t()) :: String.t()
  def expected_uncertainty("baseline_not_bracketed"),
    do: "oldest and newest declared targets did not bracket the failure"

  def expected_uncertainty("probe_nondeterministic"),
    do: "one declared target reproduced nondeterministically"

  def expected_uncertainty("probe_inconclusive"), do: "probe evidence was inconclusive"

  def expected_uncertainty("executor_not_clean"),
    do: "sandbox executor retained active or quarantined work"

  def expected_uncertainty("executor_state_unknown"),
    do: "sandbox executor cleanup state could not be established"

  def expected_uncertainty("max_probes_exhausted"),
    do: "probe bound exhausted before isolating one declared target"

  def expected_uncertainty("total_deadline_exhausted"),
    do: "duration bound exhausted before isolating one declared target"

  defp valid_id_list?(values, maximum),
    do:
      Value.bounded_list?(values, maximum) and Enum.all?(values, &id?/1) and
        Enum.uniq(values) == values

  defp valid_outcomes?(values, maximum),
    do: Value.bounded_list?(values, maximum) and Enum.all?(values, &(&1 in @outcomes))

  defp exact_keys?(map, keys),
    do:
      is_map(map) and map_size(map) == length(keys) and
        Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp optional_count?(nil), do: true
  defp optional_count?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp bounded_string?(value), do: is_binary(value) and byte_size(value) <= 256

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
       Error.new(:invalid_bisection_record, "bisection record is invalid", %{reason: reason})}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:bisection_record_limit_exceeded, "bisection record exceeds its static limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_bisection_record_schema,
         "bisection record schema is unsupported",
         %{schema: Value.summary(schema)}
       )}
end
