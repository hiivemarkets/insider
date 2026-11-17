defmodule Insider.LoadHarness.LoadReportFixture do
  @moduledoc false

  def attributes do
    digest = String.duplicate("a", 64)
    baseline = phase(digest, 100, false)
    instrumented = phase(digest, 98, true)

    %{
      "schema" => "insider.load-report/v1",
      "revision" => %{
        "git_sha" => String.duplicate("b", 40),
        "tree_sha" => String.duplicate("c", 40),
        "clean" => true
      },
      "inputs" => %{
        "mix_lock_sha256" => digest,
        "profile_sha256" => digest,
        "seed" => 42,
        "mode" => "load"
      },
      "runtime" => %{
        "elixir" => "1.20.0",
        "otp" => "29",
        "erts" => "17.0",
        "os" => "unix-test-1.0.0",
        "architecture" => "test-architecture",
        "schedulers_online" => 2,
        "schedulers_total" => 2
      },
      "interval" => %{
        "started_at_utc" => "2026-09-12T12:00:00Z",
        "ended_at_utc" => "2026-09-12T12:00:01Z",
        "duration_ms" => 1_000
      },
      "production_capacity" => false,
      "budget_evaluation" => "not_approved",
      "outcome" => "passed",
      "baseline" => baseline,
      "instrumented" => instrumented,
      "comparison" => %{
        "throughput_change_basis_points" => -200,
        "error_delta" => 0,
        "missed_operations_delta" => 0,
        "latency_p99_change_basis_points" => 0,
        "cpu_time_change_basis_points" => 0,
        "scheduler_change_basis_points" => 0,
        "memory_change_bytes" => 0,
        "garbage_collections_delta" => 0,
        "process_count_delta" => 0,
        "port_count_delta" => 0
      },
      "uncertainty" => ["synthetic fixture"]
    }
  end

  defp phase(digest, throughput, instrumented?) do
    %{
      "profile_sha256" => digest,
      "seed" => 42,
      "status" => "passed",
      "failure_reasons" => [],
      "summary" => %{
        "host" => %{
          "throughput_per_second" => throughput,
          "errors" => 0,
          "missed_operations" => 0,
          "latency_p99_us" => 10
        },
        "runtime" => %{
          "cpu_time_us" => 100,
          "scheduler_utilization_permyriad" => 0,
          "memory_bytes" => 1_000,
          "garbage_collections" => 1,
          "garbage_words_reclaimed" => 1,
          "process_count" => 1,
          "port_count" => 1
        },
        "availability" =>
          Map.new(
            ~w(cpu_time_us garbage_collections garbage_words_reclaimed memory_bytes port_count process_count scheduler_utilization_permyriad),
            &{&1, true}
          ),
        "collector" => %{
          "offered" => if(instrumented?, do: 1, else: 0),
          "accepted" => 0,
          "retained_count" => 0,
          "duplicate" => 0,
          "conservation_complete" => true,
          "losses" =>
            zero_map(
              ~w(classification_failed contended event_id_conflict frozen internal_error invalid_event oversized rate_key_capacity rate_limited unavailable)
            )
            |> Map.put("rate_limited", if(instrumented?, do: 1, else: 0)),
          "shedding" => zero_map(~w(evicted eviction_limit priority_protected)),
          "administrative" =>
            zero_map(~w(already_frozen freeze_idempotent recovered_owner_death)),
          "logger" =>
            zero_logger()
            |> Map.merge(%{
              "received" => if(instrumented?, do: 1, else: 0),
              "enqueued" => if(instrumented?, do: 1, else: 0),
              "recorder_dropped" => if(instrumented?, do: 1, else: 0)
            }),
          "telemetry" => zero_telemetry(),
          "poller" => zero_poller()
        },
        "recovery" => %{
          "empty_inboxes" => true,
          "flush_ms" => 0,
          "fresh_session_start" => true,
          "fresh_session_stop" => true,
          "owned_producers_quiesced" => true,
          "workload_emitters_stopped" => true,
          "quiescence_ms" => 1_000
        },
        "leak" => %{
          "memory_slope_bytes_per_second" => 0,
          "process_slope_per_hour" => 0,
          "port_slope_per_hour" => 0
        },
        "overload" => overload(instrumented?),
        "scheduling" => %{
          "max_tick_lag_us" => 0,
          "missed_by_cause" => zero_map(~w(segment_end_remainder skipped_tick)),
          "missed_by_segment" => zero_map(~w(overload recovery steady warmup))
        },
        "cleanup" => %{
          "complete" => true,
          "components_absent" => true,
          "fresh_session_cleanup_complete" => true,
          "logger_filter_absent" => true,
          "default_logger_handler_restored" => true,
          "manager_ownership_absent" => true,
          "monitors_dropped" => true,
          "policy_reference_dropped" => true,
          "recorder_storage_absent" => true,
          "remaining_count" => 0,
          "remaining_fingerprint" => nil,
          "session_timers_absent" => true,
          "synthetic_targets_absent" => true,
          "telemetry_handler_absent" => true
        }
      },
      "samples" => [sample(1_000, throughput)]
    }
  end

  defp overload(false) do
    %{
      "completed_operations" => 1,
      "declared_duration_ms" => 1_000,
      "declared_rate_per_second" => 1,
      "missed_operations" => 0,
      "observed" => false,
      "pressure_after" => 0,
      "pressure_before" => 0,
      "pressure_delta" => 0,
      "ingress_received_after" => 0,
      "ingress_received_before" => 0,
      "scheduled_operations" => 1
    }
  end

  defp overload(true) do
    %{
      "completed_operations" => 1,
      "declared_duration_ms" => 1_000,
      "declared_rate_per_second" => 1,
      "missed_operations" => 0,
      "observed" => true,
      "pressure_after" => 1,
      "pressure_before" => 0,
      "pressure_delta" => 1,
      "ingress_received_after" => 1,
      "ingress_received_before" => 0,
      "scheduled_operations" => 1
    }
  end

  defp sample(offset, throughput) do
    %{
      "offset_ms" => offset,
      "throughput_per_second" => throughput,
      "errors" => 0,
      "missed_operations" => 0,
      "latency_p99_us" => 10,
      "cpu_time_us" => 100,
      "scheduler_utilization_permyriad" => 0,
      "memory_bytes" => 1_000,
      "garbage_collections" => 1,
      "garbage_words_reclaimed" => 1,
      "process_count" => 1,
      "port_count" => 1
    }
  end

  defp zero_map(keys), do: Map.new(keys, &{&1, 0})

  defp zero_logger,
    do: zero_map(~w(enqueued inbox_count invalid received recorded recorder_dropped shed))

  defp zero_telemetry,
    do:
      zero_map(
        ~w(enqueued handler_failures inbox_count invalid received recorded recorder_dropped shed)
      )

  defp zero_poller do
    zero_map(
      ~w(cleanup_uncertain cycles_completed cycles_started cycles_truncated events_invalid events_recorded probes_complete probes_exited probes_failed probes_partial probes_protected probes_started probes_timeout probes_truncated recorder_dropped)
    )
    |> Map.merge(%{
      "cycle_active" => false,
      "probe_active" => false,
      "quiesced" => true,
      "timer_scheduled" => false
    })
  end
end
