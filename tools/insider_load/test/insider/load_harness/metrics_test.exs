defmodule Insider.LoadHarness.MetricsTest do
  use ExUnit.Case, async: true

  alias Insider.LoadHarness.Metrics

  test "calculates deterministic counter deltas, final gauges, and scheduler utilization" do
    earlier = snapshot(100, 20, 1_000, 2_000)
    later = snapshot(350, 70, 1_400, 3_000)

    assert %{values: values, available: available} = Metrics.delta(earlier, later)
    assert values["wall_time_us"] == 250
    assert values["cpu_time_us"] == 50
    assert values["reductions"] == 50
    assert values["context_switches"] == 50
    assert values["garbage_collections"] == 50
    assert values["garbage_words_reclaimed"] == 50
    assert values["memory_bytes"] == 70
    assert values["process_count"] == 70
    assert values["port_count"] == 70
    assert values["ets_count"] == 70
    assert values["scheduler_utilization_permyriad"] == 4_000
    assert Enum.all?(available, fn {_key, value} -> value end)
  end

  test "makes unavailable measurements explicit and projects exact Report runtime keys" do
    earlier = snapshot(100, 20, 1_000, 2_000)
    later = snapshot(350, 70, 1_400, 3_000)
    later = put_in(later.available["scheduler_utilization_permyriad"], false)

    measurement = Metrics.delta(earlier, later)

    refute measurement.available["scheduler_utilization_permyriad"]
    assert measurement.values["scheduler_utilization_permyriad"] == 0

    report = Metrics.report_runtime(measurement)

    assert Map.keys(report) |> Enum.sort() ==
             ~w(cpu_time_us garbage_collections garbage_words_reclaimed memory_bytes port_count process_count scheduler_utilization_permyriad)

    assert report["scheduler_utilization_permyriad"] == 0
    refute Map.has_key?(report, "reductions")
    refute Map.has_key?(report, "ets_count")
  end

  test "marks reset counters unavailable instead of silently treating them as zero deltas" do
    earlier = snapshot(350, 70, 1_400, 3_000)
    later = snapshot(100, 20, 1_000, 2_000)

    measurement = Metrics.delta(earlier, later)

    for key <-
          ~w(wall_time_us cpu_time_us reductions context_switches garbage_collections garbage_words_reclaimed scheduler_utilization_permyriad) do
      refute measurement.available[key]
      assert measurement.values[key] == 0
    end
  end

  test "runtime snapshot contains only fixed bounded scalar values and availability flags" do
    snapshot = Metrics.snapshot()

    assert Enum.all?(snapshot.values, fn {_key, value} ->
             is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
           end)

    assert Enum.sort(Map.keys(snapshot.available)) == Enum.sort(Metrics.measurement_keys())
    assert Enum.all?(snapshot.available, fn {_key, value} -> is_boolean(value) end)
  end

  defp snapshot(wall, value, scheduler_active, scheduler_total) do
    measurement_values = Map.new(Metrics.measurement_keys(), &{&1, value})
    availability = Map.new(Metrics.measurement_keys(), &{&1, true})

    struct!(Metrics,
      values:
        measurement_values
        |> Map.put("wall_time_us", wall)
        |> Map.put("scheduler_active", scheduler_active)
        |> Map.put("scheduler_total", scheduler_total),
      available: availability
    )
  end
end
