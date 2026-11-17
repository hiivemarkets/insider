defmodule Insider.Load.Report do
  @moduledoc """
  Canonical, revision-bound output for one paired synthetic load measurement.

  The contract deliberately accepts scalar measurements only. It carries no
  event bodies, Logger payloads, process state, credentials, or arbitrary
  metadata. A report is development/CI evidence; its fixed policy fields make
  it impossible to encode a production-capacity claim.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @schema "insider.load-report/v1"
  @maximum_bytes 1_048_576
  @maximum_term_bytes 2_097_152
  @maximum_samples 512
  @maximum_uncertainty 32
  @fields [
    :schema,
    :id,
    :revision,
    :inputs,
    :runtime,
    :interval,
    :production_capacity,
    :budget_evaluation,
    :outcome,
    :baseline,
    :instrumented,
    :comparison,
    :uncertainty,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @revision_keys ~w(clean git_sha tree_sha)
  @input_keys ~w(mix_lock_sha256 mode profile_sha256 seed)
  @runtime_keys ~w(architecture elixir erts os otp schedulers_online schedulers_total)
  @interval_keys ~w(duration_ms ended_at_utc started_at_utc)
  @phase_keys ~w(failure_reasons profile_sha256 samples seed status summary)
  @summary_keys ~w(availability cleanup collector host leak overload recovery runtime scheduling)
  @host_keys ~w(errors latency_p99_us missed_operations throughput_per_second)
  @scheduling_keys ~w(max_tick_lag_us missed_by_cause missed_by_segment)
  @missed_cause_keys ~w(segment_end_remainder skipped_tick)
  @missed_segment_keys ~w(overload recovery steady warmup)
  @runtime_metric_keys ~w(cpu_time_us garbage_collections garbage_words_reclaimed memory_bytes port_count process_count scheduler_utilization_permyriad)
  @collector_keys ~w(accepted administrative conservation_complete duplicate logger losses offered poller retained_count shedding telemetry)
  @logger_keys ~w(enqueued inbox_count invalid received recorded recorder_dropped shed)
  @telemetry_keys ~w(enqueued handler_failures inbox_count invalid received recorded recorder_dropped shed)
  @poller_keys ~w(cleanup_uncertain cycle_active cycles_completed cycles_started cycles_truncated events_invalid events_recorded probe_active probes_complete probes_exited probes_failed probes_partial probes_protected probes_started probes_timeout probes_truncated quiesced recorder_dropped timer_scheduled)
  @loss_keys ~w(classification_failed contended event_id_conflict frozen internal_error invalid_event oversized rate_key_capacity rate_limited unavailable)
  @shedding_keys ~w(evicted eviction_limit priority_protected)
  @administrative_keys ~w(already_frozen freeze_idempotent recovered_owner_death)
  @recovery_keys ~w(empty_inboxes flush_ms fresh_session_start fresh_session_stop owned_producers_quiesced quiescence_ms workload_emitters_stopped)
  @leak_keys ~w(memory_slope_bytes_per_second port_slope_per_hour process_slope_per_hour)
  @overload_keys ~w(completed_operations declared_duration_ms declared_rate_per_second ingress_received_after ingress_received_before missed_operations observed pressure_after pressure_before pressure_delta scheduled_operations)
  @cleanup_keys ~w(complete components_absent default_logger_handler_restored fresh_session_cleanup_complete logger_filter_absent manager_ownership_absent monitors_dropped policy_reference_dropped recorder_storage_absent remaining_count remaining_fingerprint session_timers_absent synthetic_targets_absent telemetry_handler_absent)
  @sample_keys ~w(cpu_time_us errors garbage_collections garbage_words_reclaimed latency_p99_us memory_bytes missed_operations offset_ms port_count process_count scheduler_utilization_permyriad throughput_per_second)
  @comparison_keys ~w(cpu_time_change_basis_points error_delta garbage_collections_delta latency_p99_change_basis_points memory_change_bytes missed_operations_delta port_count_delta process_count_delta scheduler_change_basis_points throughput_change_basis_points)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    wire = stringify_top_level(attributes)

    if exact_keys?(wire, @wire_keys -- ~w(id integrity)) do
      body = Map.take(wire, @wire_keys -- ~w(id integrity))
      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  def new(_attributes), do: invalid(:invalid_value)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = report) do
    wire = to_wire_map(report)

    with true <- report.schema == @schema,
         true <- valid_revision?(report.revision),
         true <- valid_inputs?(report.inputs),
         true <- valid_runtime?(report.runtime),
         true <- valid_interval?(report.interval),
         true <- report.production_capacity == false,
         true <- report.budget_evaluation == "not_approved",
         true <- report.outcome in ["passed", "failed"],
         true <- valid_phase?(report.baseline, report.inputs, :baseline),
         true <- valid_phase?(report.instrumented, report.inputs, :instrumented),
         true <- valid_comparison?(report.comparison, report.baseline, report.instrumented),
         true <- outcome_coherent?(report),
         true <- valid_uncertainty?(report.uncertainty),
         true <- valid_integrity?(report.integrity),
         true <- report.id == "sha256:" <> report.integrity["content_digest"],
         true <- report.integrity["content_digest"] == Canonical.sha256(content(report)),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         encoded <- Canonical.encode(wire),
         true <- byte_size(encoded) <= @maximum_bytes,
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire do
      {:ok, report}
    else
      _other -> invalid(:invalid_report)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(report) do
    with {:ok, valid} <- validate(report), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary,
         {:ok, report} <- decode_map(wire) do
      {:ok, report}
    else
      false -> invalid(:noncanonical_encoding)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:decoding_failed)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded()
  def decode(_value), do: invalid(:invalid_encoding)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema,
    do: invalid(:unsupported_schema, %{schema: bounded(schema)})

  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    if exact_keys?(wire, @wire_keys) do
      report =
        struct!(
          __MODULE__,
          Map.new(wire, fn {key, value} -> {String.to_existing_atom(key), value} end)
        )

      validate(report)
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = report) do
    report
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec maximum_samples() :: pos_integer()
  def maximum_samples, do: @maximum_samples

  defp valid_revision?(revision),
    do:
      exact_keys?(revision, @revision_keys) and git_object?(revision["git_sha"]) and
        git_object?(revision["tree_sha"]) and is_boolean(revision["clean"])

  defp valid_inputs?(inputs),
    do:
      exact_keys?(inputs, @input_keys) and digest?(inputs["mix_lock_sha256"]) and
        digest?(inputs["profile_sha256"]) and bounded_string?(inputs["mode"], 1, 32) and
        scalar_seed?(inputs["seed"])

  defp valid_runtime?(runtime) do
    exact_keys?(runtime, @runtime_keys) and bounded_string?(runtime["elixir"], 1, 64) and
      bounded_string?(runtime["otp"], 1, 64) and bounded_string?(runtime["erts"], 1, 64) and
      bounded_string?(runtime["os"], 1, 256) and
      bounded_string?(runtime["architecture"], 1, 128) and
      positive_integer?(runtime["schedulers_online"]) and
      positive_integer?(runtime["schedulers_total"]) and
      runtime["schedulers_online"] <= runtime["schedulers_total"]
  end

  defp valid_interval?(interval) do
    exact_keys?(interval, @interval_keys) and utc?(interval["started_at_utc"]) and
      utc?(interval["ended_at_utc"]) and positive_integer?(interval["duration_ms"]) and
      ordered_interval?(interval)
  end

  defp valid_phase?(phase, inputs, role) do
    exact_keys?(phase, @phase_keys) and phase["profile_sha256"] == inputs["profile_sha256"] and
      phase["seed"] == inputs["seed"] and phase["status"] in ["passed", "failed"] and
      valid_failure_reasons?(phase["failure_reasons"]) and
      valid_summary?(phase["summary"], role, phase["status"]) and
      valid_samples?(phase["samples"]) and
      phase_status_coherent?(phase, role)
  end

  defp valid_summary?(summary, role, status) do
    exact_keys?(summary, @summary_keys) and valid_nonnegative_map?(summary["host"], @host_keys) and
      valid_nonnegative_map?(summary["runtime"], @runtime_metric_keys) and
      valid_availability?(summary["availability"]) and
      valid_collector?(summary["collector"]) and valid_recovery?(summary["recovery"]) and
      valid_leak?(summary["leak"]) and valid_overload?(summary["overload"], role, status) and
      valid_scheduling?(summary["scheduling"], summary["host"], summary["overload"]) and
      valid_cleanup?(summary["cleanup"])
  end

  # Missed scheduled operations are localized twice: by cause (a tick deadline
  # overshot by at least one tick, or work left at a segment deadline) and by
  # segment. Warmup precedes the measured interval, so its misses are reported
  # but excluded from both sums; the overload segment must agree with the
  # declared overload accounting.
  defp valid_scheduling?(scheduling, host, overload) do
    exact_keys?(scheduling, @scheduling_keys) and
      nonnegative_integer?(scheduling["max_tick_lag_us"]) and
      valid_nonnegative_map?(scheduling["missed_by_cause"], @missed_cause_keys) and
      valid_nonnegative_map?(scheduling["missed_by_segment"], @missed_segment_keys) and
      sum_values(scheduling["missed_by_cause"]) == host["missed_operations"] and
      measured_segment_misses(scheduling["missed_by_segment"]) == host["missed_operations"] and
      scheduling["missed_by_segment"]["overload"] == overload["missed_operations"]
  end

  defp measured_segment_misses(by_segment),
    do: by_segment |> Map.drop(["warmup"]) |> sum_values()

  defp valid_overload?(overload, role, status) do
    numeric_keys = @overload_keys -- ~w(observed)

    exact_keys?(overload, @overload_keys) and
      valid_nonnegative_fields?(overload, numeric_keys) and is_boolean(overload["observed"]) and
      positive_integer?(overload["declared_duration_ms"]) and
      positive_integer?(overload["declared_rate_per_second"]) and
      overload["scheduled_operations"] ==
        div(overload["declared_rate_per_second"] * overload["declared_duration_ms"], 1_000) and
      overload["scheduled_operations"] ==
        overload["completed_operations"] + overload["missed_operations"] and
      overload["ingress_received_after"] >= overload["ingress_received_before"] and
      overload["pressure_after"] >= overload["pressure_before"] and
      overload["pressure_delta"] == overload["pressure_after"] - overload["pressure_before"] and
      overload_role_coherent?(overload, role, status)
  end

  defp overload_role_coherent?(overload, :baseline, status),
    do:
      overload["ingress_received_before"] == 0 and overload["ingress_received_after"] == 0 and
        overload["pressure_before"] == 0 and overload["pressure_after"] == 0 and
        overload["pressure_delta"] == 0 and not overload["observed"] and
        (status == "failed" or positive_integer?(overload["scheduled_operations"]))

  defp overload_role_coherent?(overload, :instrumented, "passed"),
    do:
      positive_integer?(overload["scheduled_operations"]) and
        overload["ingress_received_after"] > overload["ingress_received_before"] and
        overload["observed"] == overload["pressure_delta"] > 0

  defp overload_role_coherent?(overload, :instrumented, "failed"),
    do: overload["observed"] == overload["pressure_delta"] > 0

  defp valid_collector?(collector) do
    exact_keys?(collector, @collector_keys) and nonnegative_integer?(collector["offered"]) and
      nonnegative_integer?(collector["accepted"]) and
      nonnegative_integer?(collector["retained_count"]) and
      nonnegative_integer?(collector["duplicate"]) and
      valid_nonnegative_map?(collector["losses"], @loss_keys) and
      valid_nonnegative_map?(collector["shedding"], @shedding_keys) and
      valid_nonnegative_map?(collector["administrative"], @administrative_keys) and
      valid_nonnegative_map?(collector["logger"], @logger_keys) and
      valid_nonnegative_map?(collector["telemetry"], @telemetry_keys) and
      valid_poller?(collector["poller"]) and is_boolean(collector["conservation_complete"]) and
      collector["conservation_complete"] == collector_conserved?(collector)
  end

  defp valid_availability?(availability),
    do:
      exact_keys?(availability, @runtime_metric_keys) and
        Enum.all?(@runtime_metric_keys, &is_boolean(availability[&1]))

  defp valid_poller?(poller) do
    boolean_keys = ~w(cycle_active probe_active quiesced timer_scheduled)
    integer_keys = @poller_keys -- boolean_keys

    exact_keys?(poller, @poller_keys) and valid_nonnegative_fields?(poller, integer_keys) and
      Enum.all?(boolean_keys, &is_boolean(poller[&1]))
  end

  defp collector_conserved?(collector) do
    recorder_conserved?(collector) and ingress_conserved?(collector["logger"], false) and
      ingress_conserved?(collector["telemetry"], true) and poller_conserved?(collector["poller"])
  end

  defp recorder_conserved?(collector) do
    source_attempts =
      collector["logger"]["recorded"] + collector["logger"]["recorder_dropped"] +
        collector["telemetry"]["recorded"] + collector["telemetry"]["recorder_dropped"] +
        collector["poller"]["events_recorded"] + collector["poller"]["recorder_dropped"]

    offered_outcomes =
      collector["accepted"] + collector["duplicate"] + sum_values(collector["losses"]) +
        collector["shedding"]["eviction_limit"] +
        collector["shedding"]["priority_protected"] +
        collector["administrative"]["already_frozen"] +
        collector["administrative"]["freeze_idempotent"]

    collector["offered"] == source_attempts and collector["offered"] == offered_outcomes and
      collector["accepted"] ==
        collector["retained_count"] + collector["shedding"]["evicted"]
  end

  defp ingress_conserved?(ingress, handler_failures?) do
    failures = if handler_failures?, do: ingress["handler_failures"], else: 0

    ingress["received"] ==
      ingress["enqueued"] + ingress["shed"] + ingress["invalid"] + failures and
      ingress["enqueued"] ==
        ingress["recorded"] + ingress["recorder_dropped"] + ingress["inbox_count"]
  end

  defp poller_conserved?(poller) do
    completed_probes =
      Enum.sum(
        Enum.map(
          ~w(probes_complete probes_partial probes_timeout probes_exited probes_failed),
          &poller[&1]
        )
      )

    terminal_events = completed_probes + poller["probes_protected"] + poller["cycles_truncated"]

    poller["cycles_started"] == poller["cycles_completed"] and
      poller["probes_started"] == completed_probes and
      terminal_events ==
        poller["events_recorded"] + poller["events_invalid"] + poller["recorder_dropped"] and
      poller["cleanup_uncertain"] == 0 and not poller["cycle_active"] and
      not poller["probe_active"] and poller["quiesced"] and not poller["timer_scheduled"]
  end

  defp valid_recovery?(recovery),
    do:
      exact_keys?(recovery, @recovery_keys) and is_boolean(recovery["empty_inboxes"]) and
        is_boolean(recovery["owned_producers_quiesced"]) and
        is_boolean(recovery["workload_emitters_stopped"]) and
        is_boolean(recovery["fresh_session_start"]) and
        is_boolean(recovery["fresh_session_stop"]) and
        nonnegative_integer?(recovery["flush_ms"]) and
        nonnegative_integer?(recovery["quiescence_ms"])

  defp valid_leak?(leak),
    do:
      exact_keys?(leak, @leak_keys) and
        Enum.all?(@leak_keys, &(is_integer(leak[&1]) and abs(leak[&1]) <= 9_007_199_254_740_991))

  defp valid_cleanup?(cleanup),
    do:
      exact_keys?(cleanup, @cleanup_keys) and is_boolean(cleanup["complete"]) and
        Enum.all?(
          ~w(components_absent default_logger_handler_restored fresh_session_cleanup_complete logger_filter_absent manager_ownership_absent monitors_dropped policy_reference_dropped recorder_storage_absent session_timers_absent synthetic_targets_absent telemetry_handler_absent),
          &is_boolean(cleanup[&1])
        ) and
        nonnegative_integer?(cleanup["remaining_count"]) and
        optional_digest?(cleanup["remaining_fingerprint"]) and
        cleanup_coherent?(cleanup)

  defp cleanup_coherent?(
         %{
           "complete" => true,
           "remaining_count" => 0,
           "remaining_fingerprint" => nil
         } = cleanup
       ),
       do:
         Enum.all?(
           ~w(components_absent default_logger_handler_restored fresh_session_cleanup_complete logger_filter_absent manager_ownership_absent monitors_dropped policy_reference_dropped recorder_storage_absent session_timers_absent synthetic_targets_absent telemetry_handler_absent),
           &cleanup[&1]
         )

  defp cleanup_coherent?(%{
         "complete" => false,
         "remaining_count" => count,
         "remaining_fingerprint" => digest
       }),
       do: count > 0 and digest?(digest)

  defp cleanup_coherent?(_cleanup), do: false

  defp valid_samples?(samples) do
    Value.bounded_list?(samples, @maximum_samples + 1) and samples != [] and
      Enum.all?(samples, &valid_sample?/1) and monotonic_offsets?(samples)
  end

  defp valid_sample?(sample), do: valid_nonnegative_map?(sample, @sample_keys)

  defp monotonic_offsets?(samples) do
    offsets = Enum.map(samples, & &1["offset_ms"])
    offsets == Enum.sort(offsets) and offsets == Enum.uniq(offsets)
  end

  defp valid_comparison?(comparison, baseline, instrumented) do
    exact_keys?(comparison, @comparison_keys) and
      Enum.all?(
        @comparison_keys,
        &(is_integer(comparison[&1]) and abs(comparison[&1]) <= 9_007_199_254_740_991)
      ) and comparison == derive_comparison(baseline, instrumented)
  end

  defp derive_comparison(baseline, instrumented) do
    base_host = baseline["summary"]["host"]
    observed_host = instrumented["summary"]["host"]
    base_runtime = baseline["summary"]["runtime"]
    observed_runtime = instrumented["summary"]["runtime"]

    %{
      "throughput_change_basis_points" =>
        basis_points(
          observed_host["throughput_per_second"],
          base_host["throughput_per_second"]
        ),
      "error_delta" => observed_host["errors"] - base_host["errors"],
      "missed_operations_delta" =>
        observed_host["missed_operations"] - base_host["missed_operations"],
      "latency_p99_change_basis_points" =>
        basis_points(observed_host["latency_p99_us"], base_host["latency_p99_us"]),
      "cpu_time_change_basis_points" =>
        basis_points(observed_runtime["cpu_time_us"], base_runtime["cpu_time_us"]),
      "scheduler_change_basis_points" =>
        basis_points(
          observed_runtime["scheduler_utilization_permyriad"],
          base_runtime["scheduler_utilization_permyriad"]
        ),
      "memory_change_bytes" => observed_runtime["memory_bytes"] - base_runtime["memory_bytes"],
      "garbage_collections_delta" =>
        observed_runtime["garbage_collections"] - base_runtime["garbage_collections"],
      "process_count_delta" => observed_runtime["process_count"] - base_runtime["process_count"],
      "port_count_delta" => observed_runtime["port_count"] - base_runtime["port_count"]
    }
  end

  defp basis_points(_observed, 0), do: 0
  defp basis_points(observed, baseline), do: div((observed - baseline) * 10_000, baseline)

  defp valid_failure_reasons?(reasons),
    do:
      Value.bounded_list?(reasons, 33) and Enum.all?(reasons, &bounded_string?(&1, 1, 256)) and
        reasons == Enum.sort(reasons) and reasons == Enum.uniq(reasons)

  defp valid_uncertainty?(uncertainty),
    do:
      Value.bounded_list?(uncertainty, @maximum_uncertainty + 1) and
        Enum.all?(uncertainty, &bounded_string?(&1, 1, 512)) and
        uncertainty == Enum.uniq(uncertainty)

  defp phase_status_coherent?(phase, role) do
    summary = phase["summary"]
    host = summary["host"]
    recovery = summary["recovery"]
    cleanup = summary["cleanup"]

    healthy =
      host["errors"] == 0 and recovery["empty_inboxes"] and recovery["fresh_session_start"] and
        host["missed_operations"] == 0 and recovery["fresh_session_stop"] and
        recovery["owned_producers_quiesced"] and recovery["workload_emitters_stopped"] and
        summary["collector"]["conservation_complete"] and
        Enum.all?(Map.values(summary["availability"]), & &1) and
        overload_healthy?(summary["overload"], role) and cleanup["complete"]

    case phase["status"] do
      "passed" -> healthy and phase["failure_reasons"] == []
      "failed" -> phase["failure_reasons"] != []
    end
  end

  defp overload_healthy?(overload, :baseline), do: overload["missed_operations"] == 0

  defp overload_healthy?(overload, :instrumented),
    do: overload["missed_operations"] == 0 and overload["observed"]

  defp outcome_coherent?(report) do
    expected =
      if report.baseline["status"] == "passed" and report.instrumented["status"] == "passed",
        do: "passed",
        else: "failed"

    report.outcome == expected
  end

  defp valid_nonnegative_map?(map, keys),
    do: exact_keys?(map, keys) and Enum.all?(keys, &nonnegative_integer?(map[&1]))

  defp valid_nonnegative_fields?(map, keys),
    do: is_map(map) and Enum.all?(keys, &nonnegative_integer?(map[&1]))

  defp valid_integrity?(integrity),
    do:
      exact_keys?(integrity, ~w(algorithm content_digest)) and integrity["algorithm"] == "sha256" and
        digest?(integrity["content_digest"])

  defp content(report), do: report |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp ordered_interval?(interval) do
    with {:ok, started, 0} <- DateTime.from_iso8601(interval["started_at_utc"]),
         {:ok, ended, 0} <- DateTime.from_iso8601(interval["ended_at_utc"]) do
      DateTime.compare(started, ended) in [:lt, :eq]
    else
      _other -> false
    end
  end

  defp utc?(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> String.ends_with?(value, "Z")
      _other -> false
    end
  end

  defp utc?(_value), do: false

  defp stringify_top_level(attributes) do
    Map.new(attributes, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp exact_keys?(_value, _keys), do: false

  defp sum_values(map), do: map |> Map.values() |> Enum.sum()

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp scalar_seed?(value), do: nonnegative_integer?(value) and value <= 9_007_199_254_740_991

  defp bounded_string?(value, minimum, maximum) when is_binary(value),
    do: String.valid?(value) and byte_size(value) in minimum..maximum

  defp bounded_string?(_value, _minimum, _maximum), do: false

  defp git_object?(value) when is_binary(value),
    do: byte_size(value) in [40, 64] and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp git_object?(_value), do: false
  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_value), do: false
  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: digest?(value)

  defp invalid(reason, details \\ %{}) do
    {:error,
     Error.new(
       :invalid_request,
       "invalid canonical load report",
       Map.put(details, :reason, reason)
     )}
  end

  defp limit_exceeded do
    {:error,
     Error.new(:invalid_request, "load report exceeds its byte limit", %{
       maximum_bytes: @maximum_bytes
     })}
  end

  defp bounded(value) when is_binary(value), do: binary_part(value, 0, min(byte_size(value), 128))
  defp bounded(_value), do: "invalid"
end
