defmodule Insider.LoadHarness.Phase do
  @moduledoc false

  alias Insider.Collector.Session
  alias Insider.Event.Canonical
  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.SessionSupport
  alias Insider.LoadHarness.Workload

  @loss_keys ~w(classification_failed contended event_id_conflict frozen internal_error invalid_event oversized rate_key_capacity rate_limited unavailable)
  @shedding_keys ~w(evicted eviction_limit priority_protected)
  @administrative_keys ~w(already_frozen freeze_idempotent recovered_owner_death)
  @logger_keys ~w(enqueued inbox_count invalid received recorded recorder_dropped shed)
  @telemetry_keys ~w(enqueued handler_failures inbox_count invalid received recorded recorder_dropped shed)
  @poller_integer_keys ~w(cleanup_uncertain cycles_completed cycles_started cycles_truncated events_invalid events_recorded probes_complete probes_exited probes_failed probes_partial probes_protected probes_started probes_timeout probes_truncated recorder_dropped)
  @poller_boolean_keys ~w(cycle_active probe_active quiesced timer_scheduled)
  @missed_cause_keys ~w(segment_end_remainder skipped_tick)
  @missed_segment_keys ~w(overload recovery steady warmup)
  @evidence_timeout_ms 5_000

  @spec run(Profile.t(), :baseline | :instrumented) :: {map(), [String.t()]}
  def run(%Profile{} = profile, mode) when mode in [:baseline, :instrumented] do
    run(profile, mode, [])
  end

  @doc false
  @spec run(Profile.t(), :baseline | :instrumented, keyword()) :: {map(), [String.t()]}
  def run(%Profile{} = profile, mode, options)
      when mode in [:baseline, :instrumented] and is_list(options) do
    targets = start_targets(profile.target_count)
    {handler_level, handler_uncertainty} = silence_default_handler(mode, options)

    result =
      try do
        execute(profile, mode, targets, handler_uncertainty, options)
      rescue
        _error -> failed_phase(profile, "phase_execution_failed", targets)
      catch
        _kind, _reason -> failed_phase(profile, "phase_execution_failed", targets)
      after
        stop_targets(targets)
      end

    restoration = restore_default_handler(handler_level, options)
    apply_handler_restoration(result, restoration)
  end

  defp execute(profile, :baseline, targets, uncertainty, options) do
    workload = workload_run(options).(profile, false, fn _boundary -> nil end)
    target_cleanup = target_cleanup(targets)
    fresh = fresh_cycle(profile, options)
    cleanup = cleanup_summary(nil, target_cleanup, fresh, false)

    failures =
      []
      |> maybe_failure(workload["host"]["errors"] > 0, "host_workload_errors")
      |> maybe_failure(workload["host"]["missed_operations"] > 0, "missed_scheduled_operations")
      |> maybe_failure(not overload_complete?(workload), "overload_accounting_incomplete")
      |> maybe_failure(not metrics_available?(workload), "runtime_metrics_unavailable")
      |> maybe_failure(not cleanup["complete"], "cleanup_incomplete")
      |> maybe_failure(not fresh.start, "fresh_session_start_failed")
      |> maybe_failure(not fresh.stop, "fresh_session_stop_failed")
      |> Enum.sort()

    {phase(
       profile,
       workload,
       baseline_collector(),
       recovery(profile, nil, fresh),
       cleanup,
       failures
     ), unavailable_uncertainty(workload) ++ uncertainty}
  end

  defp execute(profile, :instrumented, targets, uncertainty, options) do
    id = "load-main-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    start_fun = fn -> session_start(options).(profile, targets, id) end

    session_options = [stop: session_stop(options), kill: session_kill(options)]

    case SessionSupport.with_session(
           start_fun,
           fn handle -> instrumented_measurement(profile, handle, options) end,
           session_options
         ) do
      {:ok, measurement, receipt} ->
        %{workload: workload, evidence: evidence, flush_ms: flush_ms} = measurement
        target_cleanup = target_cleanup(targets)
        fresh = fresh_cycle(profile, options)
        cleanup = cleanup_summary(receipt, target_cleanup, fresh, true)
        collector = collector_summary(evidence)

        failures =
          []
          |> maybe_failure(workload["host"]["errors"] > 0, "host_workload_errors")
          |> maybe_failure(
            workload["host"]["missed_operations"] > 0,
            "missed_scheduled_operations"
          )
          |> maybe_failure(not overload_complete?(workload), "overload_accounting_incomplete")
          |> maybe_failure(not metrics_available?(workload), "runtime_metrics_unavailable")
          |> maybe_failure(not bounded_evidence?(evidence), "collector_evidence_unavailable")
          |> maybe_failure(
            not collector["conservation_complete"],
            "collector_conservation_failed"
          )
          |> maybe_failure(not empty_inboxes?(evidence), "collector_inboxes_not_empty")
          |> maybe_failure(not poller_idle?(evidence), "poller_not_idle")
          |> maybe_failure(
            not owned_producers_quiesced?(evidence),
            "owned_producers_not_quiesced"
          )
          |> maybe_failure(
            not overload_visible?(workload["overload_evidence"]),
            "declared_overload_not_visible"
          )
          |> maybe_failure(
            not overload_ingress_observed?(workload["overload_evidence"]),
            "declared_overload_ingress_not_observed"
          )
          |> maybe_failure(not cleanup["complete"], "cleanup_incomplete")
          |> maybe_failure(not fresh.start, "fresh_session_start_failed")
          |> maybe_failure(not fresh.stop, "fresh_session_stop_failed")
          |> Enum.sort()

        recovery = recovery(profile, {evidence, flush_ms}, fresh)

        {phase(profile, workload, collector, recovery, cleanup, failures),
         unavailable_uncertainty(workload) ++ uncertainty ++ quiescence_uncertainty(evidence)}

      {:error, :session_start_failed, _receipt} ->
        failed_phase(profile, "collector_session_start_failed", targets)

      {:error, :phase_execution_failed, receipt} ->
        failed_instrumented_phase(profile, targets, receipt, options)
    end
  end

  defp instrumented_measurement(profile, handle, options) do
    observer = fn boundary ->
      # Workload emission is synchronously paused at each boundary. This drains
      # only the two workload-driven ingress queues; Poller remains active so
      # the mixed collector is still measured through overload and recovery.
      case session_ingress_flush(options).(handle, @evidence_timeout_ms) do
        {:ok, evidence} -> evidence
        {:error, _reason} -> raise "#{boundary} evidence unavailable"
      end
    end

    workload = workload_run(options).(profile, true, observer)
    {evidence, flush_ms} = flush(handle, options)
    %{workload: workload, evidence: evidence, flush_ms: flush_ms}
  end

  defp failed_instrumented_phase(profile, targets, receipt, options) do
    target_cleanup = target_cleanup(targets)
    fresh = fresh_cycle(profile, options)
    cleanup = cleanup_summary(receipt, target_cleanup, fresh, true)
    workload = failed_workload(profile)
    failures = ["phase_execution_failed"]

    {phase(
       profile,
       workload,
       zero_collector(),
       failed_recovery(profile, fresh),
       cleanup,
       failures
     ), ["phase failed before complete measurement"]}
  end

  defp phase(profile, workload, collector, recovery, cleanup, failures) do
    %{
      "profile_sha256" => profile.canonical_sha256,
      "seed" => profile.seed,
      "status" => if(failures == [], do: "passed", else: "failed"),
      "failure_reasons" => failures,
      "summary" => %{
        "host" => workload["host"],
        "runtime" => workload["runtime"],
        "availability" => runtime_availability(workload),
        "overload" => overload_summary(workload, profile),
        "scheduling" => scheduling_summary(workload["scheduling"]),
        "collector" => collector,
        "recovery" => recovery,
        "leak" => leak_summary(workload["samples"]),
        "cleanup" => cleanup
      },
      "samples" => workload["samples"]
    }
  end

  defp failed_phase(profile, reason, targets) do
    remaining = Enum.count(targets, &Process.alive?/1)
    cleanup = failed_cleanup(remaining, reason)
    workload = failed_workload(profile)

    {%{
       "profile_sha256" => profile.canonical_sha256,
       "seed" => profile.seed,
       "status" => "failed",
       "failure_reasons" => [reason],
       "summary" => %{
         "host" => workload["host"],
         "runtime" => workload["runtime"],
         "availability" => runtime_availability(workload),
         "overload" => zero_overload(profile),
         "scheduling" => scheduling_summary(workload["scheduling"]),
         "collector" => zero_collector(),
         "recovery" => %{
           "empty_inboxes" => false,
           "flush_ms" => 0,
           "fresh_session_start" => false,
           "fresh_session_stop" => false,
           "quiescence_ms" => profile.recovery_ms,
           "owned_producers_quiesced" => false,
           "workload_emitters_stopped" => false
         },
         "leak" => zero_leak(),
         "cleanup" => cleanup
       },
       "samples" => workload["samples"]
     }, ["phase failed before complete measurement"]}
  end

  defp flush(handle, options) do
    started = System.monotonic_time(:millisecond)

    evidence =
      case session_flush(options).(handle, @evidence_timeout_ms) do
        {:ok, value} -> value
        {:error, _reason} -> nil
      end

    {evidence, max(System.monotonic_time(:millisecond) - started, 0)}
  end

  defp fresh_cycle(profile, options) do
    case fresh_cycle_fun(options).(profile) do
      {:ok, receipt} -> %{start: true, stop: clean_receipt?(receipt), receipt: receipt}
      {:error, _reason} -> %{start: false, stop: false, receipt: nil}
    end
  end

  defp recovery(profile, nil, fresh) do
    %{
      "empty_inboxes" => true,
      "flush_ms" => 0,
      "fresh_session_start" => fresh.start,
      "fresh_session_stop" => fresh.stop,
      "quiescence_ms" => profile.recovery_ms,
      "owned_producers_quiesced" => true,
      "workload_emitters_stopped" => true
    }
  end

  defp recovery(profile, {evidence, flush_ms}, fresh) do
    %{
      "empty_inboxes" => empty_inboxes?(evidence),
      "flush_ms" => flush_ms,
      "fresh_session_start" => fresh.start,
      "fresh_session_stop" => fresh.stop,
      "quiescence_ms" => profile.recovery_ms,
      "owned_producers_quiesced" => owned_producers_quiesced?(evidence),
      "workload_emitters_stopped" => true
    }
  end

  defp failed_recovery(profile, fresh) do
    %{
      "empty_inboxes" => false,
      "flush_ms" => 0,
      "fresh_session_start" => fresh.start,
      "fresh_session_stop" => fresh.stop,
      "quiescence_ms" => profile.recovery_ms,
      "owned_producers_quiesced" => false,
      "workload_emitters_stopped" => false
    }
  end

  defp collector_summary(%{
         "logger" => logger,
         "telemetry" => telemetry,
         "poller" => poller,
         "recorder" => %{
           "evidence" => "bounded_status",
           "retained_count" => retained_count,
           "counters" => counters
         }
       })
       when is_integer(retained_count) and retained_count >= 0 do
    logger = component_integer_summary(logger, @logger_keys)
    telemetry = component_integer_summary(telemetry, @telemetry_keys)
    poller = poller_summary(poller)

    %{
      "offered" => value(counters, "offered"),
      "accepted" => value(counters, "accepted"),
      "retained_count" => retained_count,
      "duplicate" => value(counters, "duplicate"),
      "losses" => Map.new(@loss_keys, &{&1, value(counters, &1)}),
      "shedding" => Map.new(@shedding_keys, &{&1, value(counters, &1)}),
      "administrative" => Map.new(@administrative_keys, &{&1, value(counters, &1)}),
      "logger" => logger,
      "telemetry" => telemetry,
      "poller" => poller,
      "conservation_complete" =>
        conservation_complete?(counters, retained_count, logger, telemetry, poller)
    }
  end

  defp collector_summary(_evidence), do: zero_collector()

  defp zero_collector do
    %{
      "offered" => 0,
      "accepted" => 0,
      "retained_count" => 0,
      "duplicate" => 0,
      "losses" => Map.new(@loss_keys, &{&1, 0}),
      "shedding" => Map.new(@shedding_keys, &{&1, 0}),
      "administrative" => Map.new(@administrative_keys, &{&1, 0}),
      "logger" => Map.new(@logger_keys, &{&1, 0}),
      "telemetry" => Map.new(@telemetry_keys, &{&1, 0}),
      "poller" =>
        Map.merge(
          Map.new(@poller_integer_keys, &{&1, 0}),
          Map.new(@poller_boolean_keys, &{&1, false})
        ),
      "conservation_complete" => false
    }
  end

  defp baseline_collector do
    zero_collector()
    |> put_in(["poller", "quiesced"], true)
    |> Map.put("conservation_complete", true)
  end

  defp cleanup_summary(receipt, target_cleanup, fresh, session_expected?) do
    logger_absent = not session_expected? or cleanup_value(receipt, "logger_filter") == "absent"

    telemetry_absent =
      not session_expected? or cleanup_value(receipt, "telemetry_handler") == "absent"

    recorder_absent =
      not session_expected? or cleanup_value(receipt, "recorder_ets") in ["absent", "not_started"]

    ownership_absent =
      not session_expected? or cleanup_value(receipt, "manager_ownership") == "absent"

    components_absent = not session_expected? or clean_components?(receipt)
    monitors_dropped = not session_expected? or cleanup_value(receipt, "monitors") == "dropped"

    policy_reference_dropped =
      not session_expected? or cleanup_value(receipt, "policy_reference") == "dropped"

    session_timers_absent =
      not session_expected? or cleanup_value(receipt, "session_timers") == "none_owned"

    labels =
      []
      |> maybe_label(not logger_absent, "logger_filter")
      |> maybe_label(not telemetry_absent, "telemetry_handler")
      |> maybe_label(not recorder_absent, "recorder_storage")
      |> maybe_label(not ownership_absent, "manager_ownership")
      |> maybe_label(not components_absent, "components")
      |> maybe_label(not monitors_dropped, "monitors")
      |> maybe_label(not policy_reference_dropped, "policy_reference")
      |> maybe_label(not session_timers_absent, "session_timers")
      |> maybe_label(not target_cleanup.complete, "synthetic_targets")
      |> maybe_label(not fresh.stop, "fresh_session")

    complete = labels == []

    remaining_count =
      Enum.count(
        [
          logger_absent,
          telemetry_absent,
          recorder_absent,
          ownership_absent,
          components_absent,
          monitors_dropped,
          policy_reference_dropped,
          session_timers_absent
        ],
        &(!&1)
      ) +
        target_cleanup.remaining + if(fresh.stop, do: 0, else: 1)

    %{
      "complete" => complete,
      "remaining_count" => if(complete, do: 0, else: max(remaining_count, 1)),
      "remaining_fingerprint" => if(complete, do: nil, else: Canonical.sha256(labels)),
      "logger_filter_absent" => logger_absent,
      "telemetry_handler_absent" => telemetry_absent,
      "recorder_storage_absent" => recorder_absent,
      "manager_ownership_absent" => ownership_absent,
      "components_absent" => components_absent,
      "monitors_dropped" => monitors_dropped,
      "policy_reference_dropped" => policy_reference_dropped,
      "session_timers_absent" => session_timers_absent,
      "synthetic_targets_absent" => target_cleanup.complete,
      "fresh_session_cleanup_complete" => fresh.stop,
      "default_logger_handler_restored" => true
    }
  end

  defp failed_cleanup(remaining, reason) do
    %{
      "complete" => false,
      "remaining_count" => max(remaining, 1),
      "remaining_fingerprint" => Canonical.sha256([reason]),
      "logger_filter_absent" => false,
      "telemetry_handler_absent" => false,
      "recorder_storage_absent" => false,
      "manager_ownership_absent" => false,
      "components_absent" => false,
      "monitors_dropped" => false,
      "policy_reference_dropped" => false,
      "session_timers_absent" => false,
      "synthetic_targets_absent" => remaining == 0,
      "fresh_session_cleanup_complete" => false,
      "default_logger_handler_restored" => false
    }
  end

  defp clean_receipt?(receipt), do: SessionSupport.complete_receipt?(receipt)

  defp clean_components?(%{"cleanup" => %{"components" => components}})
       when is_map(components) do
    Enum.sort(Map.keys(components)) == ~w(logger poller recorder telemetry) and
      Enum.all?(components, fn {_component, status} ->
        status in ["absent", "absent_after_force", "already_absent", "not_started"]
      end)
  end

  defp clean_components?(_receipt), do: false

  defp bounded_evidence?(%{
         "logger" => %{"evidence" => "bounded_status"},
         "telemetry" => %{"evidence" => "bounded_status"},
         "poller" => %{"evidence" => poller_evidence},
         "recorder" => %{"evidence" => "bounded_status"}
       })
       when poller_evidence in ["bounded_status", "bounded_quiescence"],
       do: true

  defp bounded_evidence?(_evidence), do: false
  defp empty_inboxes?(%{"visible_inboxes_empty" => true}), do: true
  defp empty_inboxes?(_evidence), do: false
  defp poller_idle?(%{"poller_idle" => true}), do: true
  defp poller_idle?(_evidence), do: false

  defp owned_producers_quiesced?(%{
         "poller_idle" => true,
         "poller" => %{"quiesced" => true, "timer_scheduled" => false}
       }),
       do: true

  defp owned_producers_quiesced?(_evidence), do: false

  defp overload_visible?(%{"before" => before, "after" => after_evidence}) do
    with true <- bounded_ingress_evidence?(before),
         true <- bounded_ingress_evidence?(after_evidence),
         {:ok, delta} <- pressure_delta(before, after_evidence) do
      delta > 0
    else
      _other -> false
    end
  end

  defp overload_visible?(_evidence), do: false

  defp overload_ingress_observed?(%{"before" => before, "after" => after_evidence}) do
    with true <- bounded_ingress_evidence?(before),
         true <- bounded_ingress_evidence?(after_evidence) do
      ingress_received(after_evidence) > ingress_received(before)
    else
      _other -> false
    end
  end

  defp overload_ingress_observed?(_evidence), do: false

  defp bounded_ingress_evidence?(%{
         "schema" => "insider.collector-session-ingress-evidence/v1",
         "logger" => %{"evidence" => "bounded_status"},
         "telemetry" => %{"evidence" => "bounded_status"},
         "visible_inboxes_empty" => true,
         "poller_quiescence" => "not_requested"
       }),
       do: true

  defp bounded_ingress_evidence?(_evidence), do: false

  defp pressure_delta(before, after_evidence) do
    before_values = pressure_values(before)
    after_values = pressure_values(after_evidence)
    deltas = Enum.zip_with(before_values, after_values, fn earlier, later -> later - earlier end)

    if Enum.all?(deltas, &(&1 >= 0)), do: {:ok, Enum.sum(deltas)}, else: {:error, :reset}
  end

  defp pressure_values(evidence) do
    [
      value(evidence["logger"], "shed"),
      value(evidence["logger"], "recorder_dropped"),
      value(evidence["telemetry"], "shed"),
      value(evidence["telemetry"], "recorder_dropped")
    ]
  end

  defp ingress_received(evidence),
    do: value(evidence["logger"], "received") + value(evidence["telemetry"], "received")

  defp overload_summary(workload, profile) do
    declared = workload["overload"] || %{}

    case workload["overload_evidence"] do
      %{"before" => before, "after" => after_evidence}
      when is_map(before) and is_map(after_evidence) ->
        pressure_before = Enum.sum(pressure_values(before))
        pressure_after = Enum.sum(pressure_values(after_evidence))
        pressure_delta = max(pressure_after - pressure_before, 0)

        %{
          "scheduled_operations" => value(declared, "scheduled_operations"),
          "declared_duration_ms" => profile.overload_ms,
          "declared_rate_per_second" => profile.overload_rate_per_second,
          "completed_operations" => value(declared, "completed_operations"),
          "missed_operations" => value(declared, "missed_operations"),
          "ingress_received_before" => ingress_received(before),
          "ingress_received_after" => ingress_received(after_evidence),
          "pressure_before" => pressure_before,
          "pressure_after" => pressure_after,
          "pressure_delta" => pressure_delta,
          "observed" => pressure_delta > 0
        }

      _other ->
        zero_overload(profile)
        |> Map.merge(
          Map.take(declared, ~w(scheduled_operations completed_operations missed_operations))
        )
    end
  end

  defp zero_overload(profile) do
    scheduled = scheduled_operations(profile.overload_rate_per_second, profile.overload_ms)

    %{
      "scheduled_operations" => scheduled,
      "declared_duration_ms" => profile.overload_ms,
      "declared_rate_per_second" => profile.overload_rate_per_second,
      "completed_operations" => 0,
      "missed_operations" => scheduled,
      "ingress_received_before" => 0,
      "ingress_received_after" => 0,
      "pressure_before" => 0,
      "pressure_after" => 0,
      "pressure_delta" => 0,
      "observed" => false
    }
  end

  defp scheduled_operations(rate_per_second, duration_ms),
    do: Workload.scheduled_operations_for_duration(rate_per_second, duration_ms)

  defp overload_complete?(workload) do
    overload = workload["overload"] || %{}

    keys = ~w(scheduled_operations completed_operations missed_operations)

    Enum.all?(keys, &(is_integer(overload[&1]) and overload[&1] >= 0)) and
      overload["scheduled_operations"] ==
        overload["completed_operations"] + overload["missed_operations"]
  end

  defp scheduling_summary(scheduling) do
    %{
      "max_tick_lag_us" => value(scheduling, "max_tick_lag_us"),
      "missed_by_cause" =>
        component_integer_summary(nested(scheduling, "missed_by_cause"), @missed_cause_keys),
      "missed_by_segment" =>
        component_integer_summary(
          nested(scheduling, "missed_by_segment"),
          @missed_segment_keys
        )
    }
  end

  defp nested(map, key) when is_map(map), do: Map.get(map, key)
  defp nested(_map, _key), do: nil

  defp leak_summary([first | _rest] = samples) do
    last = List.last(samples)
    elapsed_ms = max(last["offset_ms"] - first["offset_ms"], 1)

    %{
      "memory_slope_bytes_per_second" =>
        slope(last["memory_bytes"] - first["memory_bytes"], elapsed_ms, 1_000),
      "process_slope_per_hour" =>
        slope(last["process_count"] - first["process_count"], elapsed_ms, 3_600_000),
      "port_slope_per_hour" =>
        slope(last["port_count"] - first["port_count"], elapsed_ms, 3_600_000)
    }
  end

  defp leak_summary(_samples), do: zero_leak()

  defp zero_leak do
    %{
      "memory_slope_bytes_per_second" => 0,
      "process_slope_per_hour" => 0,
      "port_slope_per_hour" => 0
    }
  end

  defp slope(delta, elapsed_ms, multiplier), do: div(delta * multiplier, elapsed_ms)

  defp unavailable_uncertainty(workload) do
    runtime_availability(workload)
    |> Enum.reject(fn {_key, available?} -> available? end)
    |> Enum.map(fn {key, false} -> "runtime metric unavailable: " <> key end)
    |> Enum.sort()
  end

  defp quiescence_uncertainty(%{"producer_quiescence" => "proven"}), do: []

  defp quiescence_uncertainty(%{
         "producer_quiescence" => "poller_proven_external_emitters_not_proven"
       }),
       do: []

  defp quiescence_uncertainty(%{"producer_quiescence" => "not_proven"}),
    do: ["visible inbox emptiness does not prove producer quiescence"]

  defp quiescence_uncertainty(_evidence), do: ["collector quiescence evidence unavailable"]

  defp start_targets(0), do: []

  defp start_targets(count) do
    Enum.map(1..count, fn _index -> spawn(fn -> target_loop() end) end)
  end

  defp stop_targets(targets) do
    Enum.each(targets, &send(&1, :stop))
    :ok
  end

  defp target_cleanup(targets) do
    monitors =
      Enum.map(targets, fn target ->
        monitor = Process.monitor(target)
        send(target, :stop)
        {target, monitor}
      end)

    Enum.each(monitors, fn {target, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^target, _reason} -> :ok
      after
        200 -> Process.demonitor(monitor, [:flush])
      end
    end)

    remaining = Enum.count(targets, &Process.alive?/1)
    %{complete: remaining == 0, remaining: remaining}
  end

  defp target_loop do
    receive do
      :stop -> :ok
    end
  end

  defp silence_default_handler(:baseline, _options), do: {nil, []}

  defp silence_default_handler(:instrumented, options) do
    case logger_get(options).(:default) do
      {:ok, config} ->
        level = Map.get(config, :level, :all)

        case logger_set(options).(:default, :level, :emergency) do
          :ok -> {{:default, level}, []}
          _other -> {nil, ["default Logger handler could not be silenced"]}
        end

      _other ->
        {nil, ["default Logger handler configuration unavailable"]}
    end
  end

  defp restore_default_handler({:default, level}, options) do
    case logger_set(options).(:default, :level, level) do
      :ok -> :ok
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp restore_default_handler(_handler, _options), do: :ok

  defp apply_handler_restoration(result, :ok), do: result

  defp apply_handler_restoration({phase, uncertainty}, :error) do
    cleanup = phase["summary"]["cleanup"]

    cleanup =
      cleanup
      |> Map.put("complete", false)
      |> Map.put("default_logger_handler_restored", false)
      |> Map.put("remaining_count", cleanup["remaining_count"] + 1)
      |> Map.put(
        "remaining_fingerprint",
        Canonical.sha256([
          "default_logger_handler_restore_failed",
          cleanup["remaining_fingerprint"] || "none"
        ])
      )

    failures =
      ["cleanup_incomplete", "default_logger_handler_restore_failed" | phase["failure_reasons"]]
      |> Enum.uniq()
      |> Enum.sort()

    phase =
      phase
      |> put_in(["summary", "cleanup"], cleanup)
      |> Map.put("failure_reasons", failures)
      |> Map.put("status", "failed")

    {phase, uncertainty}
  end

  defp zero_sample do
    %{
      "offset_ms" => 0,
      "throughput_per_second" => 0,
      "errors" => 1,
      "missed_operations" => 0,
      "latency_p99_us" => 0,
      "cpu_time_us" => 0,
      "scheduler_utilization_permyriad" => 0,
      "memory_bytes" => 0,
      "garbage_collections" => 0,
      "garbage_words_reclaimed" => 0,
      "process_count" => 0,
      "port_count" => 0
    }
  end

  defp runtime_keys,
    do:
      ~w(cpu_time_us scheduler_utilization_permyriad memory_bytes garbage_collections garbage_words_reclaimed process_count port_count)

  defp runtime_availability(workload) do
    availability = workload["metrics_available"] || %{}
    Map.new(runtime_keys(), &{&1, Map.get(availability, &1) == true})
  end

  defp metrics_available?(workload),
    do: Enum.all?(runtime_availability(workload), fn {_key, available?} -> available? end)

  defp component_integer_summary(component, keys),
    do: Map.new(keys, &{&1, value(component, &1)})

  defp poller_summary(poller) do
    Map.merge(
      component_integer_summary(poller, @poller_integer_keys),
      Map.new(@poller_boolean_keys, &{&1, boolean_value(poller, &1)})
    )
  end

  defp conservation_complete?(counters, retained_count, logger, telemetry, poller) do
    recorder_conserved?(counters, retained_count, logger, telemetry, poller) and
      ingress_conserved?(logger, false) and
      ingress_conserved?(telemetry, true) and poller_conserved?(poller)
  end

  defp recorder_conserved?(counters, retained_count, logger, telemetry, poller) do
    source_attempts =
      value(logger, "recorded") + value(logger, "recorder_dropped") +
        value(telemetry, "recorded") + value(telemetry, "recorder_dropped") +
        value(poller, "events_recorded") + value(poller, "recorder_dropped")

    offered_outcomes =
      value(counters, "accepted") + value(counters, "duplicate") +
        Enum.sum(Enum.map(@loss_keys, &value(counters, &1))) +
        value(counters, "eviction_limit") + value(counters, "priority_protected") +
        value(counters, "already_frozen") + value(counters, "freeze_idempotent")

    value(counters, "offered") == source_attempts and
      value(counters, "offered") == offered_outcomes and
      value(counters, "accepted") == retained_count + value(counters, "evicted")
  end

  defp ingress_conserved?(component, handler_failures?) do
    failures = if handler_failures?, do: component["handler_failures"], else: 0

    component["received"] ==
      component["enqueued"] + component["shed"] + component["invalid"] + failures and
      component["enqueued"] ==
        component["recorded"] + component["recorder_dropped"] + component["inbox_count"]
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

    poller["quiesced"] and
      poller["cycles_started"] == poller["cycles_completed"] and
      poller["probes_started"] == completed_probes and
      terminal_events ==
        poller["events_recorded"] + poller["events_invalid"] + poller["recorder_dropped"] and
      poller["cleanup_uncertain"] == 0 and not poller["cycle_active"] and
      not poller["probe_active"] and not poller["timer_scheduled"]
  end

  defp cleanup_value(%{"cleanup" => cleanup}, key) when is_map(cleanup),
    do: Map.get(cleanup, key)

  defp cleanup_value(_receipt, _key), do: nil

  # A phase that failed before its workload completed left every operation the
  # profile scheduled unexecuted at its segment deadline, so the unexecuted
  # work is reported as `segment_end_remainder` misses per segment. Recovery
  # schedules no work; warmup is reported but precedes the measured interval.
  defp failed_workload(profile) do
    steady = scheduled_operations(profile.rate_per_second, profile.steady_ms)
    overload = scheduled_operations(profile.overload_rate_per_second, profile.overload_ms)
    missed = steady + overload
    sample = %{zero_sample() | "missed_operations" => missed}

    %{
      "host" =>
        Map.take(sample, ~w(throughput_per_second errors missed_operations latency_p99_us)),
      "runtime" => Map.take(sample, runtime_keys()),
      "metrics_available" => Map.new(runtime_keys(), &{&1, false}),
      "scheduling" => %{
        "max_tick_lag_us" => 0,
        "missed_by_cause" => %{"segment_end_remainder" => missed, "skipped_tick" => 0},
        "missed_by_segment" => %{
          "overload" => overload,
          "recovery" => 0,
          "steady" => steady,
          "warmup" => scheduled_operations(profile.rate_per_second, profile.warmup_ms)
        }
      },
      "samples" => [sample]
    }
  end

  defp workload_run(options), do: Keyword.get(options, :workload_run, &Workload.run/3)
  defp session_start(options), do: Keyword.get(options, :session_start, &SessionSupport.start/3)
  defp session_flush(options), do: Keyword.get(options, :session_flush, &Session.flush_evidence/2)

  defp session_ingress_flush(options),
    do: Keyword.get(options, :session_ingress_flush, &Session.flush_ingress_evidence/2)

  defp session_stop(options), do: Keyword.get(options, :session_stop, &Session.stop/1)
  defp session_kill(options), do: Keyword.get(options, :session_kill, &Session.kill/1)

  defp fresh_cycle_fun(options),
    do: Keyword.get(options, :fresh_cycle, &SessionSupport.fresh_cycle/1)

  defp logger_get(options),
    do: Keyword.get(options, :logger_get_handler_config, &:logger.get_handler_config/1)

  defp logger_set(options),
    do: Keyword.get(options, :logger_set_handler_config, &:logger.set_handler_config/3)

  defp value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp value(_map, _key), do: 0
  defp boolean_value(map, key) when is_map(map), do: Map.get(map, key) == true
  defp boolean_value(_map, _key), do: false
  defp maybe_failure(reasons, true, reason), do: [reason | reasons]
  defp maybe_failure(reasons, false, _reason), do: reasons
  defp maybe_label(labels, true, label), do: [label | labels]
  defp maybe_label(labels, false, _label), do: labels
end
