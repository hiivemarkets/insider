defmodule Insider.LoadHarness.Histogram do
  @moduledoc """
  Fixed-memory latency histogram for the synthetic load harness.

  Values are non-negative integer microseconds. Quantiles are reported as the
  inclusive upper bound of a power-of-two bucket, so they are deliberately
  approximate. All counters saturate at the largest exactly representable JSON
  integer rather than allowing adversarial input to grow arbitrary-size terms.
  """

  import Bitwise

  @maximum_scalar 9_007_199_254_740_991
  @boundaries [0 | Enum.map(0..52, &(1 <<< &1))] ++ [@maximum_scalar]
  @bucket_count length(@boundaries)

  defstruct buckets: List.to_tuple(List.duplicate(0, @bucket_count)),
            count: 0,
            sum_us: 0,
            max_us: 0

  @opaque t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec observe(t(), non_neg_integer()) :: t()
  def observe(%__MODULE__{} = histogram, latency_us)
      when is_integer(latency_us) and latency_us >= 0 do
    value = min(latency_us, @maximum_scalar)

    if histogram.count == @maximum_scalar do
      histogram
    else
      index = bucket_index(value)

      %__MODULE__{
        histogram
        | buckets: put_elem(histogram.buckets, index, elem(histogram.buckets, index) + 1),
          count: histogram.count + 1,
          sum_us: saturating_add(histogram.sum_us, value),
          max_us: max(histogram.max_us, value)
      }
    end
  end

  @spec summary(t()) :: %{String.t() => non_neg_integer()}
  def summary(%__MODULE__{} = histogram) do
    %{
      "count" => histogram.count,
      "sum_us" => histogram.sum_us,
      "max_us" => histogram.max_us,
      "latency_p50_us" => quantile(histogram, 50, 100),
      "latency_p95_us" => quantile(histogram, 95, 100),
      "latency_p99_us" => quantile(histogram, 99, 100)
    }
  end

  defp bucket_index(0), do: 0

  defp bucket_index(value) do
    bit_length = value |> :erlang.integer_to_list(2) |> length()
    if Bitwise.band(value, value - 1) == 0, do: bit_length, else: bit_length + 1
  end

  defp quantile(%__MODULE__{count: 0}, _numerator, _denominator), do: 0

  defp quantile(histogram, numerator, denominator) do
    rank = div(histogram.count * numerator + denominator - 1, denominator)

    histogram.buckets
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {bucket_count, index}, cumulative ->
      next = cumulative + bucket_count

      if next >= rank,
        do: {:halt, Enum.at(@boundaries, index)},
        else: {:cont, next}
    end)
  end

  defp saturating_add(left, right), do: min(left + right, @maximum_scalar)
end
