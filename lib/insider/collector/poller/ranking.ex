defmodule Insider.Collector.Poller.Ranking do
  @moduledoc false

  # Bounded top-k rankings for the Poller's whole-node scans, kept while
  # scanning so a scan never holds or sorts the full population, and fitted
  # to the event attribute byte bound before they are recorded.

  @type ranked :: [{integer(), term()}]

  @doc """
  Inserts `row` under `key` into a descending list of at most `k` rows. A
  row whose key ties the smallest kept key is not admitted, so the earliest
  scanned row wins a tie.
  """
  @spec insert(ranked(), integer(), term(), pos_integer()) :: ranked()
  def insert(ranked, key, row, k) do
    if length(ranked) >= k and key <= ranked |> List.last() |> elem(0),
      do: ranked,
      else: ranked |> place(key, row) |> Enum.take(k)
  end

  defp place([], key, row), do: [{key, row}]

  defp place([{other, _row} | _rest] = ranked, key, row) when key > other,
    do: [{key, row} | ranked]

  defp place([head | rest], key, row), do: [head | place(rest, key, row)]

  @doc "The rows of a ranking, highest key first."
  @spec rows(ranked()) :: [term()]
  def rows(ranked), do: Enum.map(ranked, &elem(&1, 1))

  @doc """
  Drops entries from the end of the longest of `lists` (keys of `metrics`;
  on a tie, the list named last) until `metrics` encodes to at most `budget`
  JSON bytes, and records how many were dropped under `"omitted"`.
  """
  @spec fit(map(), [String.t()], pos_integer()) :: map()
  def fit(metrics, lists, budget), do: fit(metrics, Enum.reverse(lists), budget, 0)

  defp fit(metrics, lists, budget, omitted) do
    metrics = Map.put(metrics, "omitted", omitted)
    longest = Enum.max_by(lists, &length(metrics[&1]))

    if json_bytes(metrics) <= budget or metrics[longest] == [] do
      metrics
    else
      metrics
      |> Map.update!(longest, &Enum.drop(&1, -1))
      |> fit(lists, budget, omitted + 1)
    end
  end

  defp json_bytes(metrics), do: metrics |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
