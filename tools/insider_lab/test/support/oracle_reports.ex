defmodule Insider.Test.OracleReports do
  @moduledoc false

  # Valid reports in the exact shape each fixed oracle artifact emits, for
  # classification and schema tests. Each builder takes the report status.

  @fingerprint_a "hmac-sha256:" <> String.duplicate("a", 64)
  @fingerprint_b "hmac-sha256:" <> String.duplicate("b", 64)

  def report("application_env", "operational_failure", context) do
    %{
      "schema" => "insider.application-env-oracle/v1",
      "status" => "operational_failure",
      "reason" => "application_not_loaded",
      "context" => context,
      "limitations" => application_limitations(),
      "context_byte_limit" => 1_024,
      "key_limit" => 16,
      "value_byte_limit" => 1_048_576
    }
  end

  def report("application_env", status, context) do
    "application_env"
    |> report("operational_failure", context)
    |> Map.drop(["reason"])
    |> Map.merge(%{"application" => "logger", "key" => "default_handler"})
    |> Map.merge(key_fields(status))
  end

  def report("telemetry_dead_handlers", "operational_failure", context) do
    %{
      "schema" => "insider.telemetry-dead-handlers-oracle/v1",
      "status" => "operational_failure",
      "reason" => "invalid_event_name",
      "context" => context,
      "limitations" => [
        "caller_must_bind_test_and_revision",
        "context_is_caller_supplied_and_unverified",
        "only_telemetry_test_dead_destinations_are_counted",
        "prefix_lookup_descendants_affect_bounds",
        "handler_snapshot_is_not_atomic",
        "count_change_does_not_establish_causality"
      ],
      "capture_heap_words" => 262_144,
      "capture_timeout_ms" => 1_000,
      "context_byte_limit" => 1_024,
      "event_byte_limit" => 2_048,
      "event_segment_byte_limit" => 255,
      "event_segment_limit" => 16,
      "handler_limit" => 1_024
    }
  end

  def report("telemetry_dead_handlers", status, context) do
    {initial, final} =
      case status do
        "increased" -> {0, 2}
        "unchanged" -> {1, 1}
        "decreased" -> {2, 0}
        "inconclusive" -> {0, nil}
      end

    "telemetry_dead_handlers"
    |> report("operational_failure", context)
    |> Map.drop(["reason"])
    |> Map.merge(%{
      "status" => status,
      "event" => ["insider", "example"],
      "initial_dead_handler_count" => initial,
      "final_dead_handler_count" => final,
      "delta" => if(final, do: final - initial),
      "initial_observed" => true,
      "final_observed" => not is_nil(final),
      "initial_truncated" => false,
      "final_truncated" => false,
      "initial_reason" => nil,
      "final_reason" => if(final, do: nil, else: "capture_timeout")
    })
  end

  def report("otel_global_state", "operational_failure", context) do
    %{
      "schema" => "insider.otel-global-state-oracle/v1",
      "status" => "operational_failure",
      "reason" => "opentelemetry_api_not_loaded",
      "context" => context,
      "limitations" => [
        "caller_must_bind_test_and_revision",
        "context_is_caller_supplied_and_unverified",
        "fingerprints_comparable_within_run_only",
        "global_state_change_does_not_establish_causality",
        "only_default_tracer_and_text_map_propagator_are_observed"
      ],
      "api_application" => "opentelemetry_api",
      "sdk_application" => "opentelemetry",
      "context_byte_limit" => 1_024,
      "value_byte_limit" => 1_048_576
    }
  end

  def report("otel_global_state", status, context) do
    first = global_fields(status)
    rest = global_fields("unchanged")

    targets =
      Enum.zip_with(
        ["default_tracer", "text_map_injector", "text_map_extractor"],
        [first, rest, rest],
        &Map.put(&2, "global", &1)
      )

    "otel_global_state"
    |> report("operational_failure", context)
    |> Map.drop(["reason"])
    |> Map.merge(%{
      "status" => status,
      "unchanged" => first["unchanged"],
      "targets" => targets,
      "initial_sdk_loaded" => true,
      "initial_sdk_started" => true,
      "final_sdk_loaded" => true,
      "final_sdk_started" => true
    })
  end

  # An unobserved application-env capture has presence `unknown`.
  defp key_fields(status) do
    fields = global_fields(status)

    Map.merge(fields, %{
      "initial_presence" => "present",
      "final_presence" => if(fields["final_observed"], do: "present", else: "unknown")
    })
  end

  defp global_fields("changed"), do: comparison("changed", false, @fingerprint_a, @fingerprint_b)

  defp global_fields("unchanged"),
    do: comparison("unchanged", true, @fingerprint_a, @fingerprint_a)

  defp global_fields("inconclusive"),
    do: %{comparison("inconclusive", nil, @fingerprint_a, nil) | "final_observed" => false}

  defp comparison(status, unchanged, initial, final) do
    %{
      "status" => status,
      "unchanged" => unchanged,
      "initial_observed" => true,
      "final_observed" => true,
      "initial_fingerprint" => initial,
      "final_fingerprint" => final
    }
  end

  defp application_limitations,
    do: [
      "caller_must_bind_test_and_revision",
      "context_is_caller_supplied_and_unverified",
      "fingerprints_comparable_within_run_only",
      "state_change_does_not_establish_causality"
    ]
end
