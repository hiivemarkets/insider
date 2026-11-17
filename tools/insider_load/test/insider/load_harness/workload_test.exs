defmodule Insider.LoadHarness.WorkloadTest do
  use ExUnit.Case, async: true

  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.Workload

  test "derives scheduled work from the exact declared segment duration" do
    assert Workload.scheduled_operations_for_duration(150, 15) == 2
    assert Workload.scheduled_operations_for_duration(1_001, 11) == 11
    assert Workload.scheduled_operations_for_duration(333, 1) == 0
  end

  test "executes only the declared work for a non-tick-aligned segment" do
    {:ok, profile} = Profile.load("config/load.json")

    profile = %{
      profile
      | warmup_ms: 0,
        steady_ms: 0,
        overload_ms: 15,
        overload_rate_per_second: 150,
        recovery_ms: 0
    }

    clock = start_supervised!({Agent, fn -> 0 end})

    result =
      Workload.run(profile, false, fn _boundary -> %{} end,
        monotonic_time: fn -> Agent.get(clock, & &1) end,
        wait_until: fn deadline -> Agent.update(clock, &max(&1, deadline)) end
      )

    assert result["overload"] == %{
             "scheduled_operations" => 2,
             "completed_operations" => 2,
             "missed_operations" => 0
           }
  end

  test "counts every operation left at the segment deadline as missed" do
    {:ok, profile} = Profile.load("config/load.json")

    profile = %{
      profile
      | warmup_ms: 0,
        steady_ms: 0,
        overload_ms: 1_000,
        overload_rate_per_second: 5_000,
        recovery_ms: 0
    }

    clock = start_supervised!({Agent, fn -> 0 end})

    result =
      Workload.run(profile, false, fn _boundary -> %{} end,
        monotonic_time: fn -> Agent.get(clock, & &1) end,
        wait_until: fn deadline -> Agent.update(clock, &max(&1, deadline)) end,
        after_operation: fn
          50 -> Agent.update(clock, &(&1 + 1_000_000))
          _sequence -> :ok
        end
      )

    assert result["overload"] == %{
             "scheduled_operations" => 5_000,
             "completed_operations" => 50,
             "missed_operations" => 4_950
           }

    assert result["host"]["missed_operations"] == 4_950

    assert result["scheduling"] == %{
             "max_tick_lag_us" => 0,
             "missed_by_cause" => %{"segment_end_remainder" => 4_950, "skipped_tick" => 0},
             "missed_by_segment" => %{
               "overload" => 4_950,
               "recovery" => 0,
               "steady" => 0,
               "warmup" => 0
             }
           }
  end

  test "attributes one overshot tick deadline to skipped work in the steady segment" do
    {:ok, profile} = Profile.load("config/load.json")

    profile = %{
      profile
      | warmup_ms: 0,
        steady_ms: 100,
        rate_per_second: 1_000,
        overload_ms: 0,
        recovery_ms: 0
    }

    clock = start_supervised!({Agent, fn -> 0 end})

    # Operation 50 closes the tick that began at 40 ms. A 20 ms stall inside
    # that batch overshoots the 50 ms deadline by exactly one tick.
    result =
      Workload.run(profile, false, fn _boundary -> %{} end,
        monotonic_time: fn -> Agent.get(clock, & &1) end,
        wait_until: fn deadline -> Agent.update(clock, &max(&1, deadline)) end,
        after_operation: fn
          50 -> Agent.update(clock, &(&1 + 20_000))
          _sequence -> :ok
        end
      )

    assert result["completed"] == 90
    assert result["host"]["missed_operations"] == 10

    assert result["scheduling"] == %{
             "max_tick_lag_us" => 10_000,
             "missed_by_cause" => %{"segment_end_remainder" => 0, "skipped_tick" => 10},
             "missed_by_segment" => %{
               "overload" => 0,
               "recovery" => 0,
               "steady" => 10,
               "warmup" => 0
             }
           }
  end

  test "attributes work left at a segment deadline to that segment as remainder" do
    {:ok, profile} = Profile.load("config/load.json")

    profile = %{
      profile
      | warmup_ms: 50,
        steady_ms: 100,
        rate_per_second: 1_000,
        overload_ms: 20,
        overload_rate_per_second: 2_000,
        recovery_ms: 10
    }

    clock = start_supervised!({Agent, fn -> 0 end})
    operations = start_supervised!({Agent, fn -> 0 end}, id: :operations)

    # Warmup schedules 50 operations; a stall after the 25th leaves 25
    # unexecuted before the measured interval starts. Steady schedules 100 more
    # (sequence restarts at 1, so stalls are keyed by overall operation count);
    # a 12 ms stall after its 95th crosses the 100 ms deadline by 2 ms with 5
    # operations of the final tick unexecuted. Overload then completes.
    result =
      Workload.run(profile, false, fn _boundary -> %{} end,
        monotonic_time: fn -> Agent.get(clock, & &1) end,
        wait_until: fn deadline -> Agent.update(clock, &max(&1, deadline)) end,
        after_operation: fn _sequence ->
          case Agent.get_and_update(operations, &{&1 + 1, &1 + 1}) do
            25 -> Agent.update(clock, &(&1 + 50_000))
            120 -> Agent.update(clock, &(&1 + 12_000))
            _count -> :ok
          end
        end
      )

    assert result["host"]["missed_operations"] == 5

    assert result["overload"] == %{
             "scheduled_operations" => 40,
             "completed_operations" => 40,
             "missed_operations" => 0
           }

    assert result["scheduling"] == %{
             "max_tick_lag_us" => 2_000,
             "missed_by_cause" => %{"segment_end_remainder" => 5, "skipped_tick" => 0},
             "missed_by_segment" => %{
               "overload" => 0,
               "recovery" => 0,
               "steady" => 5,
               "warmup" => 25
             }
           }
  end

  test "captures bounded evidence at both overload boundaries in order" do
    {:ok, profile} = Profile.load("config/load.json")
    profile = %{profile | warmup_ms: 0, steady_ms: 0, overload_ms: 0, recovery_ms: 0}
    parent = self()

    result =
      Workload.run(profile, false, fn boundary ->
        send(parent, {:boundary, boundary})
        %{"point" => Atom.to_string(boundary)}
      end)

    assert_received {:boundary, :before_overload}
    assert_received {:boundary, :after_overload}

    assert result["overload_evidence"] == %{
             "before" => %{"point" => "before_overload"},
             "after" => %{"point" => "after_overload"}
           }
  end

  test "reserves the final bounded sample for the end of recovery" do
    {:ok, profile} = Profile.load("config/load.json")

    profile = %{
      profile
      | warmup_ms: 0,
        steady_ms: 0,
        overload_ms: 0,
        recovery_ms: 2_500,
        sample_interval_ms: 1_000,
        max_samples: 2
    }

    clock = start_supervised!({Agent, fn -> 0 end})

    result =
      Workload.run(profile, false, fn _boundary -> %{} end,
        monotonic_time: fn -> Agent.get(clock, & &1) end,
        wait_until: fn deadline -> Agent.update(clock, &max(&1, deadline)) end
      )

    assert Enum.map(result["samples"], & &1["offset_ms"]) == [1_000, 2_500]
  end
end
