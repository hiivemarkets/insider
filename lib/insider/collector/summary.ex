defmodule Insider.Collector.Summary do
  @moduledoc false

  # Fixed-memory latency histogram for record-time summaries.
  #
  # Every interval of a slot is one ETS row: count, errors, timed samples,
  # the samples per duration measurement, the maximum, and the histogram
  # buckets. An emitting process adds a sample with a single
  # `:ets.update_counter/3` call on the current interval's row, so all fields
  # of one sample, the maximum included, land in the same interval
  # atomically. The summarising process (the only one that takes) inserts
  # the next interval's row, publishes its generation, and then removes the
  # previous row with `:ets.take/2`. A writer that read the old generation
  # and arrives after the take finds no row and retries on the new one, so a
  # sample is never split or lost at an interval boundary.
  #
  # Durations are microseconds. Values below 32 have their own bucket. Above
  # that, every power of two is split into 16 linear sub-buckets, so a
  # reported percentile is the upper bound of its bucket: never below the true
  # value, at most 1/16 (6.25%) above it, and never above the interval
  # maximum. Values of 2^40 us (about 12.7 days) and more share the last
  # bucket.
  #
  # Exemplars. A sample is an exemplar candidate when it is the interval's
  # first error, or when it is one of the first `@per_bucket` samples of the
  # bucket that holds the interval's running maximum when it arrives. The
  # emitting process learns both from the values its one update returns, so
  # a candidate costs no more than any other sample. The slowest sample of an
  # interval is therefore always a candidate or within one bucket (6.25%) of
  # one, latencies that climb through an interval leave candidates in every
  # bucket they reach, and an interval has at most `@per_bucket` candidates
  # per bucket. The summariser keeps the slowest candidates and the first
  # error.
  #
  # A candidate the emitting process could not hand to its collector (its
  # inbox was full, or it could not be normalised) is counted in the
  # interval's row (`lose/2`), so the summary reports `exemplars_lost`.

  import Bitwise

  @exact 32
  @sub_bits 4
  @sub_buckets 16
  @max_exponent 39
  @buckets @exact + (@max_exponent - 4) * @sub_buckets
  # Row layout (1-based tuple positions).
  @count 2
  @errors 3
  @timed 4
  # The maximum is kept as `@ceiling - max`, so that `update_counter`'s
  # threshold form can lower it to `@ceiling - value` exactly when `value` is
  # larger: `{pos, 1, T, T}` then `{pos, -1}` with `T = @ceiling - value + 1`.
  @maximum 5
  @sources %{duration: 6, total_time: 7}
  @exemplars_lost 8
  @first_bucket 9
  @ceiling 1 <<< 59
  # A writer retries at most this often when the summariser moves on while
  # it writes; it then gives the sample up rather than spin.
  @attempts 8
  @per_bucket 4

  @type slot :: {:ets.tid(), non_neg_integer(), :atomics.atomics_ref()}
  @type sample :: {:duration | :total_time, non_neg_integer()} | nil
  @typedoc """
  An exemplar candidate: the interval's generation, the sample's duration in
  microseconds (`nil` when untimed), and whether it is the interval's first
  error.
  """
  @type exemplar :: {non_neg_integer(), non_neg_integer() | nil, boolean()}

  @doc "The number of histogram buckets."
  @spec buckets() :: pos_integer()
  def buckets, do: @buckets

  @doc """
  A new slot with index `index` in `table`, a public ETS set that outlives
  every emitting process.
  """
  @spec new_slot(:ets.tid(), non_neg_integer()) :: slot()
  def new_slot(table, index) do
    :ets.insert(table, empty_row({index, 0}))
    {table, index, :atomics.new(1, [])}
  end

  @doc """
  Adds one sample. `sample` is the measurement the duration came from and
  the duration in microseconds, or `nil` when the event had no duration.
  Runs in the emitting process. Returns `{:exemplar, exemplar}` when the
  sample is an exemplar candidate.
  """
  @spec add(slot(), boolean(), sample()) :: :ok | {:exemplar, exemplar()} | :lost
  def add(slot, error?, sample) do
    case update(slot, operations(error?, sample), @attempts) do
      {:ok, generation, values} -> candidate(generation, error?, sample, values)
      :lost -> :lost
    end
  end

  @doc """
  The generation `take/1` takes next. Only the one process that takes may
  rely on it, as it is the only one that moves it.
  """
  @spec generation(slot()) :: non_neg_integer()
  def generation({_table, _index, generations}), do: :atomics.get(generations, 1)

  @doc """
  Counts a lost exemplar candidate of interval `generation` in its row.
  `:late` when the interval was already taken (or the table is gone): its
  summary is recorded and cannot count it.
  """
  @spec lose(slot(), non_neg_integer()) :: :counted | :late
  def lose({table, index, _generations}, generation) do
    _lost = :ets.update_counter(table, {index, generation}, {@exemplars_lost, 1})
    :counted
  rescue
    ArgumentError -> :late
  end

  @doc """
  Takes the interval since the last take and starts the next one. Returns
  `nil` when the interval had no sample, or when the table is gone. Only
  one process may take a slot.
  """
  @spec take(slot()) :: map() | nil
  def take({table, index, generations}) do
    generation = :atomics.get(generations, 1)
    :ets.insert(table, empty_row({index, generation + 1}))
    :atomics.put(generations, 1, generation + 1)

    case :ets.take(table, {index, generation}) do
      [row] when elem(row, @count - 1) > 0 -> statistics(row)
      _empty -> nil
    end
  rescue
    # The table went with a gate keeper that crashed; its samples are lost.
    ArgumentError -> nil
  end

  @doc "The percentile `p` (1..100) of a bucket histogram, clamped to `max_us`."
  @spec percentile([non_neg_integer()], non_neg_integer(), 1..100, non_neg_integer()) ::
          non_neg_integer() | nil
  def percentile(_histogram, 0, _p, _max_us), do: nil

  def percentile(histogram, total, p, max_us) do
    rank = max(div(total * p + 99, 100), 1)

    histogram
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {count, index}, seen ->
      if seen + count >= rank, do: {:halt, {:found, index}}, else: {:cont, seen + count}
    end)
    |> case do
      {:found, index} -> min(upper_bound(index), max_us)
      _short -> max_us
    end
  end

  @doc "The bucket index of a duration in microseconds."
  @spec bucket(non_neg_integer()) :: non_neg_integer()
  def bucket(value) when value < @exact, do: value

  def bucket(value) do
    case exponent(value, 0) do
      exponent when exponent > @max_exponent ->
        @buckets - 1

      exponent ->
        sub = Bitwise.band(value >>> (exponent - @sub_bits), @sub_buckets - 1)
        @exact + (exponent - 5) * @sub_buckets + sub
    end
  end

  @doc "The largest duration in microseconds that falls in `index`."
  @spec upper_bound(non_neg_integer()) :: non_neg_integer()
  def upper_bound(index) when index < @exact, do: index

  def upper_bound(index) do
    exponent = 5 + div(index - @exact, @sub_buckets)
    sub = rem(index - @exact, @sub_buckets)
    width = 1 <<< (exponent - @sub_bits)
    (@sub_buckets + sub) * width + width - 1
  end

  defp operations(error?, sample) do
    errors = if error?, do: [{@errors, 1}], else: []

    timed =
      case sample do
        {source, duration} when is_integer(duration) and duration >= 0 ->
          threshold = @ceiling - min(duration, @ceiling - 2) + 1

          [
            {@timed, 1},
            {Map.fetch!(@sources, source), 1},
            {@maximum, 1, threshold, threshold},
            {@maximum, -1},
            {@first_bucket + bucket(duration), 1}
          ]

        nil ->
          []
      end

    [{@count, 1} | errors ++ timed]
  end

  # `values` are the updated fields in `operations/2` order: the count, the
  # errors when the sample is one, then the timed fields.
  defp candidate(generation, error?, sample, values) do
    {first_error?, timed} =
      case {error?, values} do
        {true, [_count, errors | timed]} -> {errors == 1, timed}
        {false, [_count | timed]} -> {false, timed}
      end

    duration = with {_source, duration} <- sample, do: duration

    if first_error? or slow?(duration, timed),
      do: {:exemplar, {generation, duration, first_error?}},
      else: :ok
  end

  defp slow?(nil, _timed), do: false

  defp slow?(duration, [_timed, _source, _threshold, stored_maximum, in_bucket]),
    do: in_bucket <= @per_bucket and bucket(duration) == bucket(@ceiling - stored_maximum)

  defp update(_slot, _operations, 0), do: :lost

  defp update({table, index, generations} = slot, operations, attempts) do
    generation = :atomics.get(generations, 1)
    {:ok, generation, :ets.update_counter(table, {index, generation}, operations)}
  rescue
    ArgumentError -> update(slot, operations, attempts - 1)
  end

  defp empty_row(key),
    do: List.to_tuple([key, 0, 0, 0, @ceiling, 0, 0, 0 | List.duplicate(0, @buckets)])

  defp statistics(row) do
    timed = elem(row, @timed - 1)
    max_us = if timed > 0, do: @ceiling - elem(row, @maximum - 1)

    histogram =
      for position <- @first_bucket..(@first_bucket + @buckets - 1), do: elem(row, position - 1)

    %{
      "count" => elem(row, @count - 1),
      "errors" => elem(row, @errors - 1),
      "timed" => timed,
      "duration_measurements" =>
        for(
          {name, position} <- Enum.sort(@sources),
          elem(row, position - 1) > 0,
          do: Atom.to_string(name)
        ),
      "duration_p50_us" => percentile(histogram, timed, 50, max_us),
      "duration_p95_us" => percentile(histogram, timed, 95, max_us),
      "duration_max_us" => max_us,
      "exemplars_lost" => elem(row, @exemplars_lost - 1)
    }
  end

  defp exponent(value, acc) when value >= 0x10000, do: exponent(value >>> 16, acc + 16)
  defp exponent(value, acc) when value >= 0x100, do: exponent(value >>> 8, acc + 8)
  defp exponent(value, acc) when value >= 0x10, do: exponent(value >>> 4, acc + 4)
  defp exponent(value, acc) when value > 1, do: exponent(value >>> 1, acc + 1)
  defp exponent(_value, acc), do: acc
end
