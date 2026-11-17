defmodule Insider.Discovery.ExUnit.OracleRunner.Oracle do
  @moduledoc false

  # The three fixed oracle artifacts, their report shapes, and how each report
  # status maps to a shared outcome. Both the live run and the v1 record
  # decoder accept a report only when it has exactly the artifact's fields,
  # fixed limits and limitations, and a status consistent with its evidence.

  @fingerprint ~r/\Ahmac-sha256:[0-9a-f]{64}\z/

  @specs %{
    "application_env" => %{
      file: "application_env_test.exs",
      schema: "insider.application-env-oracle/v1",
      prefix: "INSIDER_APPLICATION_ENV_ORACLE=",
      outcomes: %{
        "changed" => "confirmed",
        "unchanged" => "not_reproduced",
        "inconclusive" => "not_observed",
        "operational_failure" => "not_observed"
      },
      limits: %{"context_byte_limit" => 1_024, "key_limit" => 16, "value_byte_limit" => 1_048_576},
      limitations: [
        "caller_must_bind_test_and_revision",
        "context_is_caller_supplied_and_unverified",
        "fingerprints_comparable_within_run_only",
        "state_change_does_not_establish_causality"
      ],
      reasons: ~w(invalid_context invalid_target_name conflicting_key_selectors
                  missing_key_selector too_many_keys duplicate_key application_not_loaded)
    },
    "telemetry_dead_handlers" => %{
      file: "telemetry_dead_handlers_test.exs",
      schema: "insider.telemetry-dead-handlers-oracle/v1",
      prefix: "INSIDER_TELEMETRY_DEAD_HANDLERS_ORACLE=",
      outcomes: %{
        "increased" => "confirmed",
        "unchanged" => "not_reproduced",
        "decreased" => "not_reproduced",
        "inconclusive" => "not_observed",
        "operational_failure" => "not_observed"
      },
      limits: %{
        "capture_heap_words" => 262_144,
        "capture_timeout_ms" => 1_000,
        "context_byte_limit" => 1_024,
        "event_byte_limit" => 2_048,
        "event_segment_byte_limit" => 255,
        "event_segment_limit" => 16,
        "handler_limit" => 1_024
      },
      limitations: [
        "caller_must_bind_test_and_revision",
        "context_is_caller_supplied_and_unverified",
        "only_telemetry_test_dead_destinations_are_counted",
        "prefix_lookup_descendants_affect_bounds",
        "handler_snapshot_is_not_atomic",
        "count_change_does_not_establish_causality"
      ],
      reasons: ~w(invalid_context invalid_event_name)
    },
    "otel_global_state" => %{
      file: "otel_global_state_test.exs",
      schema: "insider.otel-global-state-oracle/v1",
      prefix: "INSIDER_OTEL_GLOBAL_STATE_ORACLE=",
      outcomes: %{
        "changed" => "confirmed",
        "unchanged" => "not_reproduced",
        "inconclusive" => "not_observed",
        "operational_failure" => "not_observed"
      },
      limits: %{
        "api_application" => "opentelemetry_api",
        "context_byte_limit" => 1_024,
        "sdk_application" => "opentelemetry",
        "value_byte_limit" => 1_048_576
      },
      limitations: [
        "caller_must_bind_test_and_revision",
        "context_is_caller_supplied_and_unverified",
        "fingerprints_comparable_within_run_only",
        "global_state_change_does_not_establish_causality",
        "only_default_tracer_and_text_map_propagator_are_observed"
      ],
      reasons: ~w(invalid_context opentelemetry_api_not_loaded)
    }
  }

  @common ["context", "limitations", "schema", "status"]
  @key_fields ~w(final_fingerprint final_observed final_presence initial_fingerprint
                 initial_observed initial_presence status unchanged)
  @global_fields ~w(final_fingerprint final_observed initial_fingerprint initial_observed
                    status unchanged)
  @telemetry_fields ~w(delta event final_dead_handler_count final_observed final_reason
                       final_truncated initial_dead_handler_count initial_observed
                       initial_reason initial_truncated)
  @otel_fields ~w(final_sdk_loaded final_sdk_started initial_sdk_loaded initial_sdk_started
                  targets unchanged)
  @globals ["default_tracer", "text_map_injector", "text_map_extractor"]
  @capture_reasons [nil, "handler_limit_exceeded", "capture_failed", "capture_timeout"]

  @spec ids() :: [String.t()]
  def ids, do: @specs |> Map.keys() |> Enum.sort()

  @spec fetch!(String.t()) :: map()
  def fetch!(id), do: @specs |> Map.fetch!(id) |> Map.put(:id, id)

  @spec outcome(String.t(), String.t()) :: String.t()
  def outcome(id, status),
    do: @specs |> Map.fetch!(id) |> Map.fetch!(:outcomes) |> Map.fetch!(status)

  @doc false
  @spec valid_report?(String.t(), term()) :: boolean()
  def valid_report?(id, %{"schema" => schema, "status" => status} = report)
      when is_map_key(@specs, id) do
    spec = Map.fetch!(@specs, id)

    schema == spec.schema and Map.has_key?(spec.outcomes, status) and
      (is_nil(report["context"]) or is_binary(report["context"])) and
      report["limitations"] == spec.limitations and
      Map.take(report, Map.keys(spec.limits)) == spec.limits and
      shape?(id, status, Map.drop(report, @common ++ Map.keys(spec.limits)), spec)
  rescue
    _error -> false
  end

  def valid_report?(_id, _report), do: false

  defp shape?(_id, "operational_failure", rest, spec),
    do: Map.keys(rest) == ["reason"] and rest["reason"] in spec.reasons

  defp shape?("application_env", status, %{"targets" => targets} = rest, _spec) do
    Enum.sort(Map.keys(rest)) == ["application", "targets", "unchanged"] and
      name?(rest["application"]) and is_list(targets) and length(targets) in 1..16 and
      Enum.all?(targets, &(key_target?(Map.delete(&1, "key")) and name?(&1["key"]))) and
      aggregate?(Enum.map(targets, & &1["unchanged"]), rest["unchanged"], status) and
      Enum.uniq_by(targets, & &1["key"]) == targets
  end

  defp shape?("application_env", status, rest, _spec) do
    # The top-level `status` is the single key's own status.
    {fields, identity} = rest |> Map.put("status", status) |> Map.split(@key_fields)

    Enum.sort(Map.keys(identity)) == ["application", "key"] and name?(identity["application"]) and
      name?(identity["key"]) and key_target?(fields)
  end

  defp shape?("telemetry_dead_handlers", status, rest, _spec) do
    initial = rest["initial_dead_handler_count"]
    final = rest["final_dead_handler_count"]

    Enum.sort(Map.keys(rest)) == @telemetry_fields and event?(rest["event"]) and
      observation?(
        rest["initial_observed"],
        initial,
        rest["initial_reason"],
        rest["initial_truncated"]
      ) and
      observation?(rest["final_observed"], final, rest["final_reason"], rest["final_truncated"]) and
      rest["delta"] == delta(rest) and status == delta_status(rest["delta"])
  end

  defp shape?("otel_global_state", status, rest, _spec) do
    targets = rest["targets"]

    Enum.sort(Map.keys(rest)) == @otel_fields and is_list(targets) and
      Enum.map(targets, & &1["global"]) == @globals and
      Enum.all?(targets, &global_target?(Map.delete(&1, "global"))) and
      Enum.all?(
        ~w(initial_sdk_loaded initial_sdk_started final_sdk_loaded final_sdk_started),
        &is_boolean(rest[&1])
      ) and
      aggregate?(Enum.map(targets, & &1["unchanged"]), rest["unchanged"], status)
  end

  # The application-env artifact's rules (`priv/oracles/application_env_test.exs`):
  # an unobserved capture has presence `unknown` and no fingerprint, a missing
  # key has no fingerprint, and a present key has one unless it was too large.
  defp key_target?(target) do
    Enum.sort(Map.keys(target)) == @key_fields and
      capture?(
        target["initial_observed"],
        target["initial_presence"],
        target["initial_fingerprint"]
      ) and
      capture?(target["final_observed"], target["final_presence"], target["final_fingerprint"]) and
      decided?(target, key_unchanged(target))
  end

  defp capture?(false, "unknown", nil), do: true
  defp capture?(true, "missing", nil), do: true
  defp capture?(true, "present", fingerprint), do: fingerprint?(fingerprint)
  defp capture?(_observed, _presence, _fingerprint), do: false

  defp key_unchanged(target) do
    cond do
      not (target["initial_observed"] and target["final_observed"]) -> nil
      target["initial_presence"] != target["final_presence"] -> false
      target["initial_presence"] == "missing" -> true
      true -> fingerprints_unchanged(target)
    end
  end

  # The OpenTelemetry artifact: an unobserved global has no fingerprint, and
  # only two fingerprints decide a comparison.
  defp global_target?(target) do
    Enum.sort(Map.keys(target)) == @global_fields and
      is_boolean(target["initial_observed"]) and is_boolean(target["final_observed"]) and
      fingerprint?(target["initial_fingerprint"]) and fingerprint?(target["final_fingerprint"]) and
      (target["initial_observed"] or is_nil(target["initial_fingerprint"])) and
      (target["final_observed"] or is_nil(target["final_fingerprint"])) and
      decided?(target, fingerprints_unchanged(target))
  end

  defp fingerprints_unchanged(%{"initial_fingerprint" => initial, "final_fingerprint" => final})
       when is_binary(initial) and is_binary(final),
       do: initial == final

  defp fingerprints_unchanged(_target), do: nil

  defp decided?(target, expected),
    do: target["unchanged"] === expected and target["status"] == unchanged_status(expected)

  @doc """
  Whether a report observed exactly the target the run requested: the
  application and the key or ordered key list, or the event path. An
  operational failure names no target and observed nothing, so it is bound.
  """
  @spec bound?(String.t(), map(), %{String.t() => String.t()}) :: boolean()
  def bound?(_id, %{"status" => "operational_failure"}, _inputs), do: true

  def bound?("application_env", report, inputs) do
    requested_keys =
      case inputs do
        %{"INSIDER_ORACLE_KEY" => key} -> {:single, key}
        %{"INSIDER_ORACLE_KEYS" => keys} -> {:multiple, String.split(keys, ",")}
        _other -> :none
      end

    report["application"] == inputs["INSIDER_ORACLE_APPLICATION"] and
      case {requested_keys, report} do
        {{:single, key}, %{"key" => key} = single} -> not Map.has_key?(single, "targets")
        {{:multiple, keys}, %{"targets" => targets}} -> Enum.map(targets, & &1["key"]) == keys
        _mismatch -> false
      end
  end

  def bound?("telemetry_dead_handlers", report, inputs),
    do:
      is_binary(inputs["INSIDER_ORACLE_TELEMETRY_EVENT"]) and
        report["event"] == String.split(inputs["INSIDER_ORACLE_TELEMETRY_EVENT"], ",")

  def bound?("otel_global_state", _report, _inputs), do: true

  defp aggregate?(values, unchanged, status) do
    expected =
      cond do
        false in values -> false
        nil in values -> nil
        true -> true
      end

    unchanged == expected and status == unchanged_status(expected)
  end

  defp observation?(true, count, nil, truncated), do: non_negative?(count) and truncated == false

  defp observation?(false, nil, reason, truncated),
    do: reason in @capture_reasons and is_boolean(truncated)

  defp observation?(_observed, _count, _reason, _truncated), do: false

  defp delta(%{"initial_observed" => true, "final_observed" => true} = rest),
    do: rest["final_dead_handler_count"] - rest["initial_dead_handler_count"]

  defp delta(_rest), do: nil

  defp delta_status(nil), do: "inconclusive"
  defp delta_status(0), do: "unchanged"
  defp delta_status(delta) when delta > 0, do: "increased"
  defp delta_status(_delta), do: "decreased"

  defp unchanged_status(true), do: "unchanged"
  defp unchanged_status(false), do: "changed"
  defp unchanged_status(nil), do: "inconclusive"

  defp event?(segments),
    do: is_list(segments) and length(segments) in 1..16 and Enum.all?(segments, &name?/1)

  defp name?(value), do: is_binary(value) and byte_size(value) in 1..255 and String.valid?(value)

  defp fingerprint?(value),
    do: is_nil(value) or (is_binary(value) and Regex.match?(@fingerprint, value))

  defp non_negative?(value), do: is_integer(value) and value >= 0
end
