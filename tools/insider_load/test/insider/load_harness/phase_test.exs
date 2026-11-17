defmodule Insider.LoadHarness.PhaseTest do
  use ExUnit.Case, async: true

  alias Insider.Load.Report
  alias Insider.LoadHarness.Phase
  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.Runner

  test "fails closed while preserving a nonzero missed-operation count" do
    profile = profile()
    workload = workload(3, nil)

    {phase, _uncertainty} =
      Phase.run(profile, :baseline,
        workload_run: fn ^profile, false, _observer -> workload end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end
      )

    assert phase["status"] == "failed"
    assert "missed_scheduled_operations" in phase["failure_reasons"]
    assert phase["summary"]["host"]["missed_operations"] == 3

    assert phase["summary"]["scheduling"] == %{
             "max_tick_lag_us" => 12_000,
             "missed_by_cause" => %{"segment_end_remainder" => 0, "skipped_tick" => 3},
             "missed_by_segment" => %{
               "overload" => 0,
               "recovery" => 0,
               "steady" => 3,
               "warmup" => 0
             }
           }

    assert Enum.all?(phase["summary"]["availability"], fn {_key, value} -> value end)
  end

  test "attributes declared pressure only to the bounded overload interval" do
    profile = profile()
    parent = self()
    before = ingress_evidence(evidence(0))
    after_overload = ingress_evidence(evidence(1))
    final = evidence(1)

    {:ok, calls} = Agent.start_link(fn -> [before, after_overload] end)

    workload_run = fn ^profile, true, observer ->
      before_snapshot = observer.(:before_overload)
      after_snapshot = observer.(:after_overload)

      workload(0, %{"before" => before_snapshot, "after" => after_snapshot})
    end

    next_evidence = fn :handle, 5_000 ->
      Agent.get_and_update(calls, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    {phase, _uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: workload_run,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_ingress_flush: next_evidence,
        session_flush: fn :handle, 5_000 -> {:ok, final} end,
        session_stop: fn :handle ->
          send(parent, :stopped)
          {:ok, clean_receipt()}
        end,
        session_kill: fn _handle -> flunk("kill must not be needed") end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    assert_received :stopped
    assert phase["status"] == "passed"
    assert phase["summary"]["collector"]["conservation_complete"]
    assert phase["summary"]["collector"]["logger"]["recorder_dropped"] == 1
    assert phase["summary"]["collector"]["poller"]["quiesced"]
  end

  test "fails when pressure existed before overload but did not increase during overload" do
    profile = profile()
    pressured = ingress_evidence(evidence(1))
    final = evidence(1)
    {:ok, calls} = Agent.start_link(fn -> [pressured, pressured] end)

    next_evidence = fn :handle, 5_000 ->
      Agent.get_and_update(calls, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    {phase, _uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: fn ^profile, true, observer ->
          workload(0, %{
            "before" => observer.(:before_overload),
            "after" => observer.(:after_overload)
          })
        end,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_ingress_flush: next_evidence,
        session_flush: fn :handle, 5_000 -> {:ok, final} end,
        session_stop: fn :handle -> {:ok, clean_receipt()} end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    assert phase["status"] == "failed"
    assert "declared_overload_not_visible" in phase["failure_reasons"]
  end

  test "fails cleanup when the exact prior Logger level cannot be restored" do
    profile = profile()
    {:ok, levels} = Agent.start_link(fn -> [] end)

    {phase, _uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: fn ^profile, true, _observer -> raise "phase fault" end,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_stop: fn :handle -> {:ok, clean_receipt()} end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :warning}} end,
        logger_set_handler_config: fn :default, :level, level ->
          Agent.update(levels, &[level | &1])
          if level == :warning, do: {:error, :fault}, else: :ok
        end
      )

    assert Agent.get(levels, &Enum.reverse/1) == [:emergency, :warning]
    assert phase["status"] == "failed"
    refute phase["summary"]["cleanup"]["default_logger_handler_restored"]
    assert "default_logger_handler_restore_failed" in phase["failure_reasons"]
  end

  test "fails cleanup when stop and kill receipts retain residual inventory" do
    profile = profile()
    before = ingress_evidence(evidence(0))
    after_overload = ingress_evidence(evidence(1))
    final = evidence(1)
    incomplete = put_in(clean_receipt(), ["cleanup", "session_timers"], "unavailable")
    {:ok, calls} = Agent.start_link(fn -> [before, after_overload] end)

    next_boundary = fn :handle, 5_000 ->
      Agent.get_and_update(calls, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    {phase, _uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: fn ^profile, true, observer ->
          workload(0, %{
            "before" => observer.(:before_overload),
            "after" => observer.(:after_overload)
          })
        end,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_ingress_flush: next_boundary,
        session_flush: fn :handle, 5_000 -> {:ok, final} end,
        session_stop: fn :handle -> {:ok, incomplete} end,
        session_kill: fn :handle -> {:ok, incomplete} end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    assert phase["status"] == "failed"
    assert "cleanup_incomplete" in phase["failure_reasons"]
    refute phase["summary"]["cleanup"]["session_timers_absent"]
    refute phase["summary"]["cleanup"]["complete"]
  end

  test "persists the Recorder retained count in conserved collector evidence" do
    [before, after_overload, final] = [evidence(0), evidence(1), evidence(1)]

    retained =
      final
      |> put_in(["recorder", "counters", "offered"], 2)
      |> put_in(["recorder", "counters", "accepted"], 1)
      |> put_in(["recorder", "retained_count"], 1)
      |> put_in(["logger", "received"], 2)
      |> put_in(["logger", "enqueued"], 2)
      |> put_in(["logger", "recorded"], 1)

    phase = instrumented_phase([before, after_overload, retained])

    assert phase["status"] == "passed"
    assert phase["summary"]["collector"]["retained_count"] == 1
    assert phase["summary"]["collector"]["conservation_complete"]
  end

  test "fails conservation for cross-component fabrication or loss" do
    [before, after_overload, final] = [evidence(0), evidence(1), evidence(1)]

    fabricated =
      final
      |> put_in(["recorder", "counters", "offered"], 2)
      |> put_in(["recorder", "counters", "rate_limited"], 2)

    phase = instrumented_phase([before, after_overload, fabricated])

    assert phase["status"] == "failed"
    assert "collector_conservation_failed" in phase["failure_reasons"]

    lost_source_attempt =
      final
      |> put_in(["logger", "received"], 2)
      |> put_in(["logger", "enqueued"], 2)
      |> put_in(["logger", "recorder_dropped"], 2)

    phase = instrumented_phase([before, after_overload, lost_source_attempt])

    assert phase["status"] == "failed"
    assert "collector_conservation_failed" in phase["failure_reasons"]
  end

  test "fails conservation when retained count disagrees with admissions and evictions" do
    [before, after_overload, final] = [evidence(0), evidence(1), evidence(1)]
    retained_mismatch = put_in(final, ["recorder", "retained_count"], 1)

    phase = instrumented_phase([before, after_overload, retained_mismatch])

    assert phase["status"] == "failed"
    assert "collector_conservation_failed" in phase["failure_reasons"]
  end

  test "a baseline workload fault still yields a valid report naming the fault" do
    profile = profile()

    {baseline, baseline_uncertainty} =
      Phase.run(profile, :baseline,
        workload_run: fn ^profile, false, _observer -> raise "workload fault" end,
        fresh_cycle: fn ^profile -> flunk("fresh cycle must not run after a fault") end
      )

    assert baseline["status"] == "failed"
    assert baseline["failure_reasons"] == ["phase_execution_failed"]
    assert baseline_uncertainty == ["phase failed before complete measurement"]

    instrumented = instrumented_phase([evidence(0), evidence(1), evidence(1)])
    assert instrumented["status"] == "passed"

    assert {:ok, report} =
             profile
             |> report_attributes(baseline, instrumented, baseline_uncertainty)
             |> Report.new()

    assert report.outcome == "failed"
    assert report.baseline["failure_reasons"] == ["phase_execution_failed"]
    refute report.baseline["summary"]["cleanup"]["complete"]
    assert_unexecuted_scheduling(baseline, profile)
  end

  test "instrumented session or measurement failures still yield a valid report" do
    profile = profile()

    {baseline, _uncertainty} =
      Phase.run(profile, :baseline,
        workload_run: fn ^profile, false, _observer -> workload(0, nil) end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end
      )

    assert baseline["status"] == "passed"

    {session_failed, _uncertainty} =
      Phase.run(profile, :instrumented,
        session_start: fn ^profile, [], _id -> {:error, :fault} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    assert session_failed["failure_reasons"] == ["collector_session_start_failed"]

    {measurement_failed, uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: fn ^profile, true, _observer -> raise "phase fault" end,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_stop: fn :handle -> {:ok, clean_receipt()} end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    assert measurement_failed["failure_reasons"] == ["phase_execution_failed"]
    assert measurement_failed["summary"]["cleanup"]["complete"]

    for instrumented <- [session_failed, measurement_failed] do
      assert {:ok, report} =
               profile
               |> report_attributes(baseline, instrumented, uncertainty)
               |> Report.new()

      assert report.outcome == "failed"
      assert report.instrumented["failure_reasons"] == instrumented["failure_reasons"]
      assert report.comparison["missed_operations_delta"] == 20_000
      assert_unexecuted_scheduling(instrumented, profile)
    end
  end

  defp assert_unexecuted_scheduling(phase, profile) do
    steady = div(profile.rate_per_second * profile.steady_ms, 1_000)
    overload = div(profile.overload_rate_per_second * profile.overload_ms, 1_000)
    warmup = div(profile.rate_per_second * profile.warmup_ms, 1_000)
    summary = phase["summary"]

    assert summary["host"]["missed_operations"] == steady + overload
    assert summary["overload"]["missed_operations"] == overload
    assert summary["overload"]["completed_operations"] == 0
    assert Enum.map(phase["samples"], & &1["missed_operations"]) == [steady + overload]

    assert summary["scheduling"] == %{
             "max_tick_lag_us" => 0,
             "missed_by_cause" => %{
               "segment_end_remainder" => steady + overload,
               "skipped_tick" => 0
             },
             "missed_by_segment" => %{
               "overload" => overload,
               "recovery" => 0,
               "steady" => steady,
               "warmup" => warmup
             }
           }
  end

  defp report_attributes(profile, baseline, instrumented, uncertainty) do
    %{
      "schema" => "insider.load-report/v1",
      "revision" => %{
        "git_sha" => String.duplicate("b", 40),
        "tree_sha" => String.duplicate("c", 40),
        "clean" => true
      },
      "inputs" => %{
        "mix_lock_sha256" => String.duplicate("a", 64),
        "profile_sha256" => profile.canonical_sha256,
        "seed" => profile.seed,
        "mode" => profile.mode
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
      "outcome" => "failed",
      "baseline" => baseline,
      "instrumented" => instrumented,
      "comparison" => Runner.comparison(baseline, instrumented),
      "uncertainty" => Enum.uniq(uncertainty)
    }
  end

  defp profile do
    {:ok, profile} = Profile.load("config/load.json")
    %{profile | target_count: 0}
  end

  defp workload(missed, overload_evidence) do
    sample = %{
      "offset_ms" => 1,
      "throughput_per_second" => 100,
      "errors" => 0,
      "missed_operations" => missed,
      "latency_p99_us" => 1,
      "cpu_time_us" => 1,
      "scheduler_utilization_permyriad" => 1,
      "memory_bytes" => 1,
      "garbage_collections" => 1,
      "garbage_words_reclaimed" => 1,
      "process_count" => 1,
      "port_count" => 1
    }

    %{
      "host" =>
        Map.take(sample, ~w(throughput_per_second errors missed_operations latency_p99_us)),
      "runtime" =>
        Map.take(
          sample,
          ~w(cpu_time_us scheduler_utilization_permyriad memory_bytes garbage_collections garbage_words_reclaimed process_count port_count)
        ),
      "metrics_available" =>
        Map.new(
          ~w(cpu_time_us scheduler_utilization_permyriad memory_bytes garbage_collections garbage_words_reclaimed process_count port_count),
          &{&1, true}
        ),
      "overload_evidence" => overload_evidence,
      "overload" => %{
        "scheduled_operations" => 10_000,
        "completed_operations" => 10_000,
        "missed_operations" => 0
      },
      "scheduling" => %{
        "max_tick_lag_us" => if(missed > 0, do: 12_000, else: 0),
        "missed_by_cause" => %{"segment_end_remainder" => 0, "skipped_tick" => missed},
        "missed_by_segment" => %{
          "overload" => 0,
          "recovery" => 0,
          "steady" => missed,
          "warmup" => 0
        }
      },
      "samples" => [sample]
    }
  end

  defp evidence(logger_shed) do
    loss_keys =
      ~w(classification_failed contended event_id_conflict frozen internal_error invalid_event oversized rate_key_capacity rate_limited unavailable)

    counters =
      Map.merge(
        Map.new(loss_keys ++ ~w(evicted eviction_limit priority_protected), &{&1, 0}),
        %{
          "offered" => logger_shed,
          "accepted" => 0,
          "duplicate" => 0,
          "rate_limited" => logger_shed
        }
      )

    %{
      "logger" => %{
        "evidence" => "bounded_status",
        "received" => logger_shed,
        "enqueued" => logger_shed,
        "shed" => 0,
        "invalid" => 0,
        "recorded" => 0,
        "recorder_dropped" => logger_shed,
        "inbox_count" => 0
      },
      "telemetry" => %{
        "evidence" => "bounded_status",
        "received" => 0,
        "enqueued" => 0,
        "shed" => 0,
        "invalid" => 0,
        "recorded" => 0,
        "recorder_dropped" => 0,
        "handler_failures" => 0,
        "inbox_count" => 0
      },
      "poller" =>
        Map.merge(
          Map.new(
            ~w(cleanup_uncertain cycles_completed cycles_started cycles_truncated events_invalid events_recorded probes_complete probes_exited probes_failed probes_partial probes_protected probes_started probes_timeout probes_truncated recorder_dropped),
            &{&1, 0}
          ),
          %{
            "evidence" => "bounded_quiescence",
            "cycle_active" => false,
            "probe_active" => false,
            "quiesced" => true,
            "timer_scheduled" => false
          }
        ),
      "recorder" => %{
        "evidence" => "bounded_status",
        "retained_count" => 0,
        "counters" => counters
      },
      "visible_inboxes_empty" => true,
      "poller_idle" => true,
      "producer_quiescence" => "proven"
    }
  end

  defp instrumented_phase(evidence_sequence) do
    profile = profile()
    [before, after_overload, final] = evidence_sequence

    {:ok, calls} =
      Agent.start_link(fn -> Enum.map([before, after_overload], &ingress_evidence/1) end)

    next_evidence = fn :handle, 5_000 ->
      Agent.get_and_update(calls, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    {phase, _uncertainty} =
      Phase.run(profile, :instrumented,
        workload_run: fn ^profile, true, observer ->
          workload(0, %{
            "before" => observer.(:before_overload),
            "after" => observer.(:after_overload)
          })
        end,
        session_start: fn ^profile, [], _id -> {:ok, :handle} end,
        session_ingress_flush: next_evidence,
        session_flush: fn :handle, 5_000 -> {:ok, final} end,
        session_stop: fn :handle -> {:ok, clean_receipt()} end,
        fresh_cycle: fn ^profile -> {:ok, clean_receipt()} end,
        logger_get_handler_config: fn :default -> {:ok, %{level: :notice}} end,
        logger_set_handler_config: fn :default, :level, _level -> :ok end
      )

    phase
  end

  defp clean_receipt do
    %{
      "outcome" => "stopped",
      "cleanup" => %{
        "components" => %{
          "logger" => "absent",
          "poller" => "absent",
          "recorder" => "absent",
          "telemetry" => "absent"
        },
        "logger_filter" => "absent",
        "monitors" => "dropped",
        "policy_reference" => "dropped",
        "telemetry_handler" => "absent",
        "recorder_ets" => "absent",
        "manager_ownership" => "absent",
        "session_timers" => "none_owned"
      }
    }
  end

  defp ingress_evidence(evidence) do
    %{
      "schema" => "insider.collector-session-ingress-evidence/v1",
      "session_id" => "fixture",
      "state" => "running",
      "logger" => evidence["logger"],
      "telemetry" => evidence["telemetry"],
      "visible_inboxes_empty" => true,
      "external_emitter_quiescence" => "not_proven",
      "poller_quiescence" => "not_requested",
      "event_content_included" => false
    }
  end
end
