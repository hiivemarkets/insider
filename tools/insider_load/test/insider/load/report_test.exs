defmodule Insider.Load.ReportTest do
  use ExUnit.Case, async: true

  alias Insider.Load.Report
  alias Insider.Protocol.Error

  @comparison_keys ~w(cpu_time_change_basis_points error_delta garbage_collections_delta latency_p99_change_basis_points memory_change_bytes missed_operations_delta port_count_delta process_count_delta scheduler_change_basis_points throughput_change_basis_points)

  test "round-trips a revision-bound paired scalar report" do
    assert {:ok, report} = Report.new(attributes())
    assert report.production_capacity == false
    assert report.budget_evaluation == "not_approved"
    assert report.baseline["seed"] == report.instrumented["seed"]
    assert report.baseline["profile_sha256"] == report.instrumented["profile_sha256"]

    assert report.comparison == %{
             "throughput_change_basis_points" => -200,
             "error_delta" => 0,
             "latency_p99_change_basis_points" => 500,
             "cpu_time_change_basis_points" => 250,
             "scheduler_change_basis_points" => 200,
             "memory_change_bytes" => 1_024,
             "missed_operations_delta" => 0,
             "garbage_collections_delta" => 2,
             "process_count_delta" => 3,
             "port_count_delta" => 0
           }

    assert {:ok, bytes} = Report.canonical_binary(report)
    assert {:ok, ^report} = Report.decode(bytes)
    assert byte_size(bytes) <= Report.maximum_bytes()
    refute bytes =~ "payload"
    refute bytes =~ "credential"
  end

  test "rejects malformed, extra-key, alternate-schema, and noncanonical encodings" do
    assert {:error, %Error{code: :invalid_request}} = Report.decode("not-json")
    assert {:ok, report} = Report.new(attributes())
    wire = Report.to_wire_map(report)

    assert {:error, %Error{code: :invalid_request}} =
             wire |> Map.put("unexpected", true) |> Report.decode_map()

    assert {:error, %Error{code: :invalid_request}} =
             wire |> Map.put("schema", "insider.load-report/v2") |> Report.decode_map()

    assert {:ok, bytes} = Report.canonical_binary(report)
    assert {:error, %Error{code: :invalid_request}} = Report.decode("\n" <> bytes)
  end

  test "rejects substitution without a matching content identity" do
    assert {:ok, report} = Report.new(attributes())

    substituted =
      report
      |> Report.to_wire_map()
      |> put_in(["revision", "git_sha"], String.duplicate("f", 40))

    assert {:error, %Error{code: :invalid_request}} = Report.decode_map(substituted)
  end

  test "rejects a fabricated value in every comparison field" do
    for key <- @comparison_keys do
      fabricated =
        update_in(attributes(), ["comparison", key], fn value ->
          if key == "throughput_change_basis_points", do: 999_999, else: value + 1
        end)

      assert {:error, %Error{code: :invalid_request}} = Report.new(fabricated),
             "accepted fabricated comparison field #{key}"
    end
  end

  test "defines a zero basis-point change when the baseline is zero" do
    zero_baseline =
      attributes()
      |> put_in(["baseline", "summary", "host", "throughput_per_second"], 0)
      |> put_in(["comparison", "throughput_change_basis_points"], 0)

    assert {:ok, report} = Report.new(zero_baseline)
    assert report.comparison["throughput_change_basis_points"] == 0
  end

  test "fails closed for unconserved events and false success" do
    invalid_loss =
      attributes()
      |> put_in(["instrumented", "summary", "collector", "losses", "unavailable"], 1)

    assert {:error, %Error{code: :invalid_request}} = Report.new(invalid_loss)

    invalid_success =
      attributes()
      |> put_in(["instrumented", "summary", "host", "errors"], 1)

    assert {:error, %Error{code: :invalid_request}} = Report.new(invalid_success)
  end

  test "missed host work and every collector conservation equation prevent success" do
    missed = put_in(attributes(), ["instrumented", "summary", "host", "missed_operations"], 1)
    assert {:error, %Error{code: :invalid_request}} = Report.new(missed)

    unconserved_logger =
      attributes()
      |> put_in(["instrumented", "summary", "collector", "logger", "received"], 1)

    assert {:error, %Error{code: :invalid_request}} = Report.new(unconserved_logger)

    for {path, value} <- [
          {["instrumented", "summary", "collector", "telemetry", "received"], 1},
          {["instrumented", "summary", "collector", "poller", "cycles_started"], 2}
        ] do
      assert {:error, %Error{code: :invalid_request}} =
               attributes() |> put_in(path, value) |> Report.new()
    end

    explicit_failure =
      unconserved_logger
      |> put_in(["instrumented", "summary", "collector", "conservation_complete"], false)
      |> put_in(["instrumented", "status"], "failed")
      |> put_in(["instrumented", "failure_reasons"], ["collector_conservation_failed"])
      |> Map.put("outcome", "failed")

    assert {:ok, failed_report} = Report.new(explicit_failure)
    assert failed_report.outcome == "failed"
  end

  test "rejects cross-component Recorder fabrication or loss" do
    fabricated_recorder =
      attributes()
      |> put_in(["instrumented", "summary", "collector", "offered"], 11)
      |> put_in(["instrumented", "summary", "collector", "accepted"], 11)
      |> put_in(["instrumented", "summary", "collector", "retained_count"], 11)

    assert {:error, %Error{code: :invalid_request}} = Report.new(fabricated_recorder)

    lost_source_attempt =
      attributes()
      |> put_in(["instrumented", "summary", "collector", "logger", "received"], 11)
      |> put_in(["instrumented", "summary", "collector", "logger", "enqueued"], 11)
      |> put_in(["instrumented", "summary", "collector", "logger", "recorded"], 11)

    assert {:error, %Error{code: :invalid_request}} = Report.new(lost_source_attempt)
  end

  test "rejects a retained count that cannot be derived from accepted admissions and evictions" do
    retained_mismatch =
      attributes()
      |> put_in(["instrumented", "summary", "collector", "retained_count"], 9)

    assert {:error, %Error{code: :invalid_request}} = Report.new(retained_mismatch)
  end

  test "unavailable required runtime measurements prevent success" do
    unavailable =
      put_in(
        attributes(),
        ["instrumented", "summary", "availability", "scheduler_utilization_permyriad"],
        false
      )

    assert {:error, %Error{code: :invalid_request}} = Report.new(unavailable)
  end

  test "success requires every fixed cleanup inventory predicate" do
    for key <-
          ~w(components_absent monitors_dropped policy_reference_dropped session_timers_absent) do
      incomplete = put_in(attributes(), ["instrumented", "summary", "cleanup", key], false)
      assert {:error, %Error{code: :invalid_request}} = Report.new(incomplete)
    end
  end

  test "overload evidence is role-aware, conserved, and interval-attributed" do
    steady_only_pressure =
      attributes()
      |> put_in(["instrumented", "summary", "overload", "pressure_before"], 1)
      |> put_in(["instrumented", "summary", "overload", "pressure_after"], 1)
      |> put_in(["instrumented", "summary", "overload", "pressure_delta"], 0)
      |> put_in(["instrumented", "summary", "overload", "observed"], false)

    assert {:error, %Error{code: :invalid_request}} = Report.new(steady_only_pressure)

    missed =
      attributes()
      |> put_in(["instrumented", "summary", "overload", "completed_operations"], 0)
      |> put_in(["instrumented", "summary", "overload", "missed_operations"], 1)

    assert {:error, %Error{code: :invalid_request}} = Report.new(missed)

    malformed_delta =
      put_in(attributes(), ["instrumented", "summary", "overload", "pressure_delta"], 2)

    assert {:error, %Error{code: :invalid_request}} = Report.new(malformed_delta)

    caller_authored_baseline_signal =
      attributes()
      |> put_in(["baseline", "summary", "overload", "ingress_received_after"], 1)

    assert {:error, %Error{code: :invalid_request}} = Report.new(caller_authored_baseline_signal)

    fabricated_schedule =
      attributes()
      |> put_in(["instrumented", "summary", "overload", "scheduled_operations"], 2)
      |> put_in(["instrumented", "summary", "overload", "completed_operations"], 2)

    assert {:error, %Error{code: :invalid_request}} = Report.new(fabricated_schedule)
  end

  test "missed work must be localized by cause and segment to the same total" do
    scheduling = ["instrumented", "summary", "scheduling"]

    localized =
      attributes()
      |> put_in(["instrumented", "summary", "host", "missed_operations"], 10)
      |> put_in(scheduling ++ ["max_tick_lag_us"], 10_000)
      |> put_in(scheduling ++ ["missed_by_cause", "skipped_tick"], 10)
      |> put_in(scheduling ++ ["missed_by_segment", "steady"], 10)
      |> put_in(["instrumented", "status"], "failed")
      |> put_in(["instrumented", "failure_reasons"], ["missed_scheduled_operations"])
      |> put_in(["comparison", "missed_operations_delta"], 10)
      |> Map.put("outcome", "failed")

    assert {:ok, report} = Report.new(localized)
    assert report.instrumented["summary"]["scheduling"]["missed_by_cause"]["skipped_tick"] == 10

    for {path, value} <- [
          {scheduling ++ ["missed_by_cause", "skipped_tick"], 9},
          {scheduling ++ ["missed_by_segment", "steady"], 9},
          {scheduling ++ ["missed_by_segment", "steady"], 11},
          {scheduling ++ ["max_tick_lag_us"], -1},
          {scheduling ++ ["missed_by_cause", "stall"], 0}
        ] do
      assert {:error, %Error{code: :invalid_request}} =
               localized |> put_in(path, value) |> Report.new(),
             "accepted unreconciled localization at #{inspect(path)}"
    end

    moved_to_overload =
      localized
      |> put_in(scheduling ++ ["missed_by_segment", "steady"], 0)
      |> put_in(scheduling ++ ["missed_by_segment", "overload"], 10)

    assert {:error, %Error{code: :invalid_request}} = Report.new(moved_to_overload)

    warmup_only = put_in(attributes(), scheduling ++ ["missed_by_segment", "warmup"], 3)
    assert {:ok, warmup_report} = Report.new(warmup_only)
    assert warmup_report.instrumented["summary"]["host"]["missed_operations"] == 0
    assert warmup_report.outcome == "passed"

    assert {:error, %Error{code: :invalid_request}} =
             attributes()
             |> update_in(["instrumented", "summary"], &Map.delete(&1, "scheduling"))
             |> Report.new()
  end

  test "an unexecuted phase reconciles declared overload misses with scheduling" do
    summary = ["instrumented", "summary"]

    unexecuted =
      attributes()
      |> put_in(summary ++ ["host", "errors"], 1)
      |> put_in(summary ++ ["host", "missed_operations"], 3)
      |> put_in(summary ++ ["overload", "completed_operations"], 0)
      |> put_in(summary ++ ["overload", "missed_operations"], 1)
      |> put_in(summary ++ ["overload", "observed"], false)
      |> put_in(summary ++ ["overload", "pressure_after"], 1)
      |> put_in(summary ++ ["overload", "pressure_delta"], 0)
      |> put_in(summary ++ ["overload", "ingress_received_after"], 10)
      |> put_in(summary ++ ["scheduling", "missed_by_cause", "segment_end_remainder"], 3)
      |> put_in(summary ++ ["scheduling", "missed_by_segment", "steady"], 2)
      |> put_in(summary ++ ["scheduling", "missed_by_segment", "overload"], 1)
      |> put_in(["instrumented", "status"], "failed")
      |> put_in(["instrumented", "failure_reasons"], ["phase_execution_failed"])
      |> put_in(["comparison", "error_delta"], 1)
      |> put_in(["comparison", "missed_operations_delta"], 3)
      |> Map.put("outcome", "failed")

    assert {:ok, report} = Report.new(unexecuted)
    assert report.instrumented["failure_reasons"] == ["phase_execution_failed"]

    unlocalized =
      unexecuted
      |> put_in(summary ++ ["host", "missed_operations"], 0)
      |> put_in(summary ++ ["scheduling", "missed_by_cause", "segment_end_remainder"], 0)
      |> put_in(summary ++ ["scheduling", "missed_by_segment", "steady"], 0)
      |> put_in(summary ++ ["scheduling", "missed_by_segment", "overload"], 0)
      |> put_in(["comparison", "missed_operations_delta"], 0)

    assert {:error, %Error{code: :invalid_request}} = Report.new(unlocalized)
  end

  test "rejects non-scalar samples and unknown nested measurement keys" do
    non_scalar =
      attributes()
      |> put_in(["instrumented", "samples", Access.at(0), "memory_bytes"], %{
        "raw_process_state" => "forbidden"
      })

    assert {:error, %Error{code: :invalid_request}} = Report.new(non_scalar)

    unknown =
      attributes()
      |> update_in(
        ["instrumented", "summary", "runtime"],
        &Map.put(&1, "raw_scheduler_dump", "forbidden")
      )

    assert {:error, %Error{code: :invalid_request}} = Report.new(unknown)
  end

  test "cannot encode a production claim or mismatched paired inputs" do
    assert {:error, %Error{code: :invalid_request}} =
             attributes() |> Map.put("production_capacity", true) |> Report.new()

    assert {:error, %Error{code: :invalid_request}} =
             attributes() |> Map.put("budget_evaluation", "approved") |> Report.new()

    mismatch = put_in(attributes(), ["instrumented", "seed"], 43)
    assert {:error, %Error{code: :invalid_request}} = Report.new(mismatch)
  end

  test "enforces sample and total byte bounds" do
    too_many = List.duplicate(sample(0), Report.maximum_samples() + 1)

    assert {:error, %Error{code: :invalid_request}} =
             Report.new(put_in(attributes(), ["baseline", "samples"], too_many))

    oversized = String.duplicate("x", Report.maximum_bytes() + 1)
    assert {:error, %Error{code: :invalid_request}} = Report.decode(oversized)
  end

  defp attributes do
    digest = String.duplicate("a", 64)

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
        "otp" => "28",
        "erts" => "16.0",
        "os" => "unix-darwin-24.6.0",
        "architecture" => "aarch64-apple-darwin",
        "schedulers_online" => 8,
        "schedulers_total" => 8
      },
      "interval" => %{
        "started_at_utc" => "2026-09-12T12:00:00Z",
        "ended_at_utc" => "2026-09-12T12:00:10Z",
        "duration_ms" => 10_000
      },
      "production_capacity" => false,
      "budget_evaluation" => "not_approved",
      "outcome" => "passed",
      "baseline" => phase(digest, 42, 100, false),
      "instrumented" => phase(digest, 42, 98, true),
      "comparison" => %{
        "throughput_change_basis_points" => -200,
        "error_delta" => 0,
        "latency_p99_change_basis_points" => 500,
        "cpu_time_change_basis_points" => 250,
        "scheduler_change_basis_points" => 200,
        "memory_change_bytes" => 1_024,
        "missed_operations_delta" => 0,
        "garbage_collections_delta" => 2,
        "process_count_delta" => 3,
        "port_count_delta" => 0
      },
      "uncertainty" => ["Synthetic workload does not establish production capacity."]
    }
  end

  defp phase(profile, seed, throughput, instrumented?) do
    %{
      "profile_sha256" => profile,
      "seed" => seed,
      "status" => "passed",
      "failure_reasons" => [],
      "summary" => %{
        "host" => %{
          "throughput_per_second" => throughput,
          "errors" => 0,
          "missed_operations" => 0,
          "latency_p99_us" => if(instrumented?, do: 210, else: 200)
        },
        "runtime" => %{
          "cpu_time_us" => if(instrumented?, do: 20_500, else: 20_000),
          "scheduler_utilization_permyriad" => if(instrumented?, do: 3_060, else: 3_000),
          "memory_bytes" => if(instrumented?, do: 4_001_024, else: 4_000_000),
          "garbage_collections" => if(instrumented?, do: 22, else: 20),
          "garbage_words_reclaimed" => 10_000,
          "process_count" => if(instrumented?, do: 83, else: 80),
          "port_count" => 4
        },
        "availability" =>
          Map.new(
            ~w(cpu_time_us garbage_collections garbage_words_reclaimed memory_bytes port_count process_count scheduler_utilization_permyriad),
            &{&1, true}
          ),
        "collector" => %{
          "offered" => 10,
          "accepted" => 10,
          "retained_count" => 10,
          "duplicate" => 0,
          "conservation_complete" => true,
          "losses" =>
            zero_map(
              ~w(classification_failed contended event_id_conflict frozen internal_error invalid_event oversized rate_key_capacity rate_limited unavailable)
            ),
          "shedding" => zero_map(~w(evicted eviction_limit priority_protected)),
          "administrative" =>
            zero_map(~w(already_frozen freeze_idempotent recovered_owner_death)),
          "logger" =>
            zero_logger()
            |> Map.merge(%{"received" => 4, "enqueued" => 4, "recorded" => 4}),
          "telemetry" =>
            zero_telemetry()
            |> Map.merge(%{"received" => 3, "enqueued" => 3, "recorded" => 3}),
          "poller" =>
            zero_poller()
            |> Map.merge(%{
              "cycles_started" => 1,
              "cycles_completed" => 1,
              "probes_started" => 3,
              "probes_complete" => 3,
              "events_recorded" => 3
            })
        },
        "recovery" => %{
          "empty_inboxes" => true,
          "flush_ms" => 2,
          "fresh_session_start" => true,
          "fresh_session_stop" => true,
          "owned_producers_quiesced" => true,
          "workload_emitters_stopped" => true,
          "quiescence_ms" => 4
        },
        "leak" => %{
          "memory_slope_bytes_per_second" => 0,
          "process_slope_per_hour" => 0,
          "port_slope_per_hour" => 0
        },
        "overload" => overload(instrumented?),
        "scheduling" => %{
          "max_tick_lag_us" => 0,
          "missed_by_cause" => %{"segment_end_remainder" => 0, "skipped_tick" => 0},
          "missed_by_segment" => %{"overload" => 0, "recovery" => 0, "steady" => 0, "warmup" => 0}
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
      "samples" => [sample(0), sample(1_000)]
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
      "pressure_after" => 2,
      "pressure_before" => 1,
      "pressure_delta" => 1,
      "ingress_received_after" => 12,
      "ingress_received_before" => 10,
      "scheduled_operations" => 1
    }
  end

  defp sample(offset) do
    %{
      "offset_ms" => offset,
      "throughput_per_second" => 100,
      "errors" => 0,
      "missed_operations" => 0,
      "latency_p99_us" => 150,
      "cpu_time_us" => 2_000,
      "scheduler_utilization_permyriad" => 3_000,
      "memory_bytes" => 4_000_000,
      "garbage_collections" => 2,
      "garbage_words_reclaimed" => 1_000,
      "process_count" => 80,
      "port_count" => 4
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
