defmodule Insider.LoadHarness.HistogramTest do
  use ExUnit.Case, async: true

  alias Insider.LoadHarness.Histogram

  test "summarizes empty and observed latency with fixed scalar keys" do
    assert Histogram.new() |> Histogram.summary() == %{
             "count" => 0,
             "sum_us" => 0,
             "max_us" => 0,
             "latency_p50_us" => 0,
             "latency_p95_us" => 0,
             "latency_p99_us" => 0
           }

    summary =
      [0, 1, 2, 3, 4, 100]
      |> Enum.reduce(Histogram.new(), &Histogram.observe(&2, &1))
      |> Histogram.summary()

    assert summary == %{
             "count" => 6,
             "sum_us" => 110,
             "max_us" => 100,
             "latency_p50_us" => 2,
             "latency_p95_us" => 128,
             "latency_p99_us" => 128
           }
  end

  test "saturates oversized observations to a bounded scalar" do
    maximum = 9_007_199_254_740_991

    assert %{
             "count" => 1,
             "sum_us" => ^maximum,
             "max_us" => ^maximum,
             "latency_p99_us" => ^maximum
           } =
             Histogram.new()
             |> Histogram.observe(maximum + 1)
             |> Histogram.summary()
  end
end
