defmodule Insider.Live.Retention do
  @moduledoc false

  # Per-trace retention: the events of chosen traces kept apart from the
  # Recorder, so a trace a reader is working on survives eviction. Without it, a
  # trace read after a crawl can come back empty.
  #
  # A trace is kept by an explicit pin (`trace --retain`, at most
  # @max_pins), or automatically: with `retain_traces` N, the N most
  # recently active traces. The owner copies events here from raw,
  # redaction-checked Recorder reads with live-session receipts, as the
  # archive does (`Insider.Live.Archive`): a pin is backfilled from what the
  # Recorder still holds, and a sweep on the owner's push tick copies each
  # new event of a kept trace. Disclosure is applied when a trace is read,
  # so a narrowed profile applies to kept events too.
  #
  # Traces kept by default, each for a reason and in its own pool of at
  # most @max_default_traces, the least recently active let go first, so a
  # burst of one kind (failing background calls) never costs another:
  #
  # - `mutation` (`keep_mutations`, on for a session with the telemetry
  #   component): an `absinthe.execute.operation.stop` whose GraphQL
  #   outcome is a mutation;
  # - `failed` (`keep_notable`, on for a session with the logger,
  #   telemetry or otel component): a traced event with severity `error`
  #   or `critical` (an exception, a 5xx, a failed span, GraphQL errors, a
  #   Logger error);
  # - `slow` (`keep_notable`): a traced Telemetry event whose `duration`
  #   or `total_time` measurement, or an OpenTelemetry span whose
  #   `duration_us`, is at least @slow_us.
  #
  # So `trace` finds the request a reader just reproduced without
  # `--retain-traces`. A kept trace takes the strongest reason it has seen
  # (mutation, then failed, then slow) and moves to that pool. Its events
  # before the one that made it notable come from a lookback of the last
  # @max_lookback traced events (and @max_lookback_bytes, the store's own
  # bounds, so a large request survives until its stop or error arrives)
  # the sweep saw, and of the automatic traces `retain_traces` let go;
  # those that fell out of it count as the trace's `lost`. Those counters
  # are kept for the @max_rolled traces updated last; past that the least
  # recently updated goes, counted as `loss_counters_evicted` (that
  # trace's later loss is then unknown). Default retention never costs
  # what `--retain` and `retain_traces` keep: an automatic trace that turns
  # notable stays automatic until the pool lets it go, and only then takes
  # its reason; past the store's bounds default traces go first.
  #
  # Bounded at @max_entries events and @max_bytes of external term size in
  # all, plus the lookback's own bounds. Past a bound the least recently
  # active slow trace goes first, then failed, then mutation traces, then
  # the least recently active automatic trace, then the oldest events of
  # the oldest explicit pin. Every loss is counted:
  # `evicted_traces` and `dropped_events` in all, and per kept trace `lost`
  # (its events dropped here) and `missed_receipts` (receipts the Recorder
  # evicted before a sweep read them while the trace was kept, which may or
  # may not have been its events).

  alias Insider.Live.View

  @max_traces 64
  @max_pins 8
  @max_entries 4_096
  @max_bytes 4 * 1_024 * 1_024
  @max_hinted 256
  @max_default_traces 16
  @max_lookback 4_096
  @max_lookback_bytes 4 * 1_024 * 1_024
  @max_rolled 2_048
  @slow_us 500_000

  # Default reasons, weakest first: the order past the store's bounds, and
  # a kept trace moves only to a stronger one.
  @defaults [:slow, :failed, :mutation]
  @failed_severities ["error", "critical"]

  defstruct limit: 0,
            traces: %{},
            order: [],
            cursor: nil,
            count: 0,
            bytes: 0,
            evicted_traces: 0,
            dropped_events: 0,
            missed: 0,
            hinted: MapSet.new(),
            keep_mutations: false,
            keep_notable: false,
            lookback: :queue.new(),
            lookback_count: 0,
            lookback_bytes: 0,
            rolled: %{},
            rolled_order: :queue.new(),
            rolled_sequence: 0,
            loss_counters_evicted: 0

  @type t :: %__MODULE__{}

  @doc "The bounds, for the welcome document and status."
  @spec bounds() :: map()
  def bounds,
    do: %{
      "retain_traces_max" => @max_traces,
      "retained_pins_max" => @max_pins,
      "retained_events_max" => @max_entries,
      "retained_bytes_max" => @max_bytes,
      "mutation_traces_max" => @max_default_traces,
      "failed_traces_max" => @max_default_traces,
      "slow_traces_max" => @max_default_traces,
      "slow_trace_ms" => div(@slow_us, 1_000),
      "mutation_lookback_max" => @max_lookback,
      "lookback_bytes_max" => @max_lookback_bytes
    }

  @doc "The most traces `retain_traces` keeps."
  @spec max_traces() :: pos_integer()
  def max_traces, do: @max_traces

  @doc "Retention keeping the `limit` most recently active traces, not yet sweeping."
  @spec new(non_neg_integer()) :: t()
  def new(limit), do: %__MODULE__{limit: limit}

  @doc "Starts sweeping after receipt `cursor`, unless it already sweeps."
  @spec start(t(), non_neg_integer()) :: t()
  def start(%__MODULE__{cursor: nil} = retention, cursor), do: %{retention | cursor: cursor}
  def start(retention, _cursor), do: retention

  @doc "Whether the traces of mutation requests are kept; with neither default on, the lookback goes."
  @spec keep_mutations(t(), boolean()) :: t()
  def keep_mutations(retention, on?), do: forget_lookback(%{retention | keep_mutations: on?})

  @doc "Whether failed and slow traces are kept; with neither default on, the lookback goes."
  @spec keep_notable(t(), boolean()) :: t()
  def keep_notable(retention, on?), do: forget_lookback(%{retention | keep_notable: on?})

  defp forget_lookback(retention) do
    if defaults?(retention),
      do: retention,
      else: %{
        retention
        | lookback: :queue.new(),
          lookback_count: 0,
          lookback_bytes: 0,
          rolled: %{},
          rolled_order: :queue.new()
      }
  end

  defp defaults?(retention), do: retention.keep_mutations or retention.keep_notable

  @doc "Whether the owner should sweep: it keeps traces or retains new ones."
  @spec active?(t() | nil) :: boolean()
  def active?(%__MODULE__{cursor: cursor} = retention) when is_integer(cursor),
    do: retention.limit > 0 or retention.traces != %{} or defaults?(retention)

  def active?(_retention), do: false

  @doc "The receipt the sweep has copied through, or `nil`."
  @spec cursor(t()) :: non_neg_integer() | nil
  def cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc "A new `retain_traces`: automatic traces past it are let go, counted."
  @spec set_limit(t(), non_neg_integer()) :: t()
  def set_limit(retention, limit), do: trim(%{retention | limit: limit})

  @doc """
  Copies a raw Recorder `read` after the sweep's cursor: each event of a
  kept trace, and, with a `limit`, each event of a new trace, which becomes
  kept. The read's `"evicted"` receipts count against every kept trace.
  """
  @spec sweep(t(), map()) :: t()
  def sweep(%__MODULE__{} = retention, read) do
    missed = Map.get(read, "evicted", 0)

    retention =
      if missed > 0,
        do: %{
          retention
          | missed: retention.missed + missed,
            traces:
              Map.new(retention.traces, fn {id, t} -> {id, %{t | missed: t.missed + missed}} end)
        },
        else: retention

    advance(retention, read, &copy/2)
  end

  @doc """
  Folds `keep` over the entries of a raw Recorder `read` after `state`'s
  cursor, then moves the cursor to the read's next one. The owner's sweeps
  (retention, `Insider.Live.Mutations`) share it.
  """
  @spec advance(map(), map(), (map(), map() -> map())) :: map()
  def advance(state, read, keep) do
    read["events"]
    |> Enum.filter(&(&1["receipt"] > (state.cursor || 0)))
    |> Enum.reduce(state, keep)
    |> Map.put(:cursor, max(state.cursor || 0, read["next_cursor"]))
  end

  defp copy(entry, retention) do
    case View.trace_id(entry["event"] || %{}) do
      nil ->
        retention

      trace_id ->
        reason = reason(retention, entry["event"])

        cond do
          Map.has_key?(retention.traces, trace_id) ->
            retention
            |> append(trace_id, [entry])
            |> touch(trace_id)
            |> mark(trace_id, reason)
            |> bound()

          reason != nil ->
            {earlier, retention} = take_lookback(retention, trace_id)
            {{lost, _sequence}, rolled} = Map.pop(retention.rolled, trace_id, {0, nil})

            %{retention | rolled: rolled}
            |> add(trace_id, reason)
            |> update_in([Access.key(:traces), trace_id, :lost], &(&1 + lost))
            |> append(trace_id, earlier ++ [entry])
            |> trim_pool(reason)
            |> bound()

          retention.limit > 0 ->
            retention |> add(trace_id, :auto) |> append(trace_id, [entry]) |> trim() |> bound()

          defaults?(retention) ->
            remember(retention, trace_id, entry)

          true ->
            retention
        end
    end
  end

  # The strongest default reason `event` gives to keep its trace, or `nil`.
  defp reason(retention, event) do
    cond do
      retention.keep_mutations and mutation_stop?(event) -> :mutation
      retention.keep_notable and event["severity"] in @failed_severities -> :failed
      retention.keep_notable and slow?(event) -> :slow
      true -> nil
    end
  end

  defp enabled?(retention, :mutation), do: retention.keep_mutations
  defp enabled?(retention, _notable), do: retention.keep_notable

  defp mutation_stop?(%{
         "source" => "telemetry",
         "kind" => "absinthe.execute.operation.stop",
         "attributes" => %{"graphql" => %{"operation_type" => "mutation"}}
       }),
       do: true

  defp mutation_stop?(_event), do: false

  # A span's duration is in microseconds; a Telemetry time measurement is
  # in native units, and retention runs on the node that recorded it.
  defp slow?(%{"source" => "otel", "attributes" => %{"duration_us" => us}}) when is_integer(us),
    do: us >= @slow_us

  defp slow?(%{"source" => "telemetry", "attributes" => %{"measurements" => %{} = measurements}}) do
    Enum.any?(["duration", "total_time"], fn name ->
      case measurements[name] do
        native when is_integer(native) ->
          System.convert_time_unit(native, :native, :microsecond) >= @slow_us

        _other ->
          false
      end
    end)
  end

  defp slow?(_event), do: false

  defp rank(reason), do: Enum.find_index(@defaults, &(&1 == reason))

  defp stronger(nil, reason), do: reason
  defp stronger(a, b), do: if(rank(b) > rank(a), do: b, else: a)

  # A kept trace remembers the strongest reason it has seen. An automatic
  # or explicit one keeps its pin, and takes that reason when the pool lets
  # it go (`trim/1`); a default one moves to the stronger reason's pool.
  defp mark(retention, _trace_id, nil), do: retention

  defp mark(retention, trace_id, reason) do
    trace = retention.traces[trace_id]
    notable = stronger(trace.notable, reason)
    retention = put_in(retention, [Access.key(:traces), trace_id, :notable], notable)

    if trace.pin in @defaults and trace.pin != notable,
      do:
        retention |> put_in([Access.key(:traces), trace_id, :pin], notable) |> trim_pool(notable),
      else: retention
  end

  # The lookback: the last traced events of traces not (yet) kept.
  defp remember(retention, trace_id, entry) do
    bytes = :erlang.external_size(entry)

    %{
      retention
      | lookback: :queue.in({trace_id, bytes, entry}, retention.lookback),
        lookback_count: retention.lookback_count + 1,
        lookback_bytes: retention.lookback_bytes + bytes
    }
    |> roll()
  end

  defp roll(%{lookback_count: count, lookback_bytes: bytes} = retention)
       when count <= @max_lookback and bytes <= @max_lookback_bytes,
       do: retention

  defp roll(retention) do
    {{:value, {trace_id, bytes, _entry}}, lookback} = :queue.out(retention.lookback)

    %{
      retention
      | lookback: lookback,
        lookback_count: retention.lookback_count - 1,
        lookback_bytes: retention.lookback_bytes - bytes
    }
    |> count_rolled(trace_id)
    |> roll()
  end

  # One more event of `trace_id` fell out of the lookback. Each update is
  # queued with a sequence number, so the least recently updated counter
  # is found by skipping queued updates a later one superseded.
  defp count_rolled(retention, trace_id) do
    sequence = retention.rolled_sequence + 1
    {count, _old} = Map.get(retention.rolled, trace_id, {0, nil})

    %{
      retention
      | rolled: Map.put(retention.rolled, trace_id, {count + 1, sequence}),
        rolled_order: :queue.in({trace_id, sequence}, retention.rolled_order),
        rolled_sequence: sequence
    }
    |> evict_counters()
    |> compact_counters()
  end

  defp evict_counters(%{rolled: rolled} = retention) when map_size(rolled) <= @max_rolled,
    do: retention

  defp evict_counters(retention) do
    {{:value, {trace_id, sequence}}, order} = :queue.out(retention.rolled_order)
    retention = %{retention | rolled_order: order}

    case retention.rolled do
      %{^trace_id => {_count, ^sequence}} ->
        %{
          retention
          | rolled: Map.delete(retention.rolled, trace_id),
            loss_counters_evicted: retention.loss_counters_evicted + 1
        }

      _superseded ->
        evict_counters(retention)
    end
  end

  # Superseded updates are dropped once they outnumber the counters.
  defp compact_counters(retention) do
    if :queue.len(retention.rolled_order) > 2 * @max_rolled do
      order =
        retention.rolled
        |> Enum.map(fn {trace_id, {_count, sequence}} -> {trace_id, sequence} end)
        |> Enum.sort_by(&elem(&1, 1))
        |> :queue.from_list()

      %{retention | rolled_order: order}
    else
      retention
    end
  end

  defp take_lookback(retention, trace_id) do
    {mine, rest} =
      retention.lookback |> :queue.to_list() |> Enum.split_with(&(elem(&1, 0) == trace_id))

    {Enum.map(mine, &elem(&1, 2)),
     %{
       retention
       | lookback: :queue.from_list(rest),
         lookback_count: retention.lookback_count - length(mine),
         # Enum.sum_by/2 is Elixir 1.18+, and Insider supports 1.17.
         lookback_bytes: retention.lookback_bytes - Enum.reduce(mine, 0, &(elem(&1, 1) + &2))
     }}
  end

  # A default reason's traces beyond @max_default_traces go, least recently
  # active first; each reason has its own pool.
  defp trim_pool(retention, reason) do
    kept = Enum.filter(retention.order, &(retention.traces[&1].pin == reason))
    excess = length(kept) - @max_default_traces
    kept |> Enum.take(max(excess, 0)) |> Enum.reduce(retention, &drop_trace(&2, &1))
  end

  @doc """
  Pins `trace_id` explicitly, with the `entries` the Recorder still holds
  for it (receipts up to `top`); the sweep starts after `top` if it was not
  running. Returns the retention and the explicit pin let go to make room
  (beyond @max_pins), or `nil`.
  """
  @spec pin(t(), String.t(), [map()], non_neg_integer()) :: {t(), String.t() | nil}
  def pin(%__MODULE__{} = retention, trace_id, entries, top) do
    retention = start(retention, top)

    retention =
      case retention.traces do
        %{^trace_id => trace} -> put_in(retention.traces[trace_id], %{trace | pin: :explicit})
        _new -> add(retention, trace_id, :explicit)
      end

    known = MapSet.new(retention.traces[trace_id].entries, & &1["receipt"])
    fresh = Enum.reject(entries, &MapSet.member?(known, &1["receipt"]))

    {retention, released} =
      retention |> append(trace_id, fresh) |> touch(trace_id) |> release_pins()

    {retention |> trim() |> bound(), released}
  end

  @doc "The kept events of `trace_id`, oldest receipt first."
  @spec entries(t() | nil, String.t()) :: [map()]
  def entries(%__MODULE__{traces: traces}, trace_id) do
    case traces do
      %{^trace_id => trace} -> Enum.sort_by(trace.entries, & &1["receipt"])
      _none -> []
    end
  end

  def entries(nil, _trace_id), do: []

  @doc "What retention keeps of `trace_id`, or `nil` when it keeps nothing."
  @spec info(t() | nil, String.t()) :: map() | nil
  def info(%__MODULE__{traces: traces}, trace_id) do
    case traces do
      %{^trace_id => trace} ->
        %{
          "pinned" => Atom.to_string(trace.pin),
          "events" => length(trace.entries),
          "lost" => trace.lost,
          "missed_receipts" => trace.missed,
          "since_receipt" => trace.since
        }

      _none ->
        nil
    end
  end

  def info(nil, _trace_id), do: nil

  @doc "The retention summary for `status`."
  @spec describe(t() | nil) :: map()
  def describe(nil), do: describe(new(0))

  def describe(%__MODULE__{} = retention) do
    Map.merge(bounds(), %{
      "retain_traces" => retention.limit,
      "traces" => map_size(retention.traces),
      "pinned" => for({id, %{pin: :explicit}} <- retention.traces, do: id) |> Enum.sort(),
      "keep_mutations" => retention.keep_mutations,
      "keep_failed_and_slow" => retention.keep_notable,
      "mutation_traces" => kept(retention, :mutation),
      "failed_traces" => kept(retention, :failed),
      "slow_traces" => kept(retention, :slow),
      "loss_counters_evicted" => retention.loss_counters_evicted,
      "events" => retention.count,
      "bytes" => retention.bytes,
      "evicted_traces" => retention.evicted_traces,
      "dropped_events" => retention.dropped_events,
      "missed_receipts" => retention.missed,
      "swept_through" => retention.cursor
    })
  end

  defp kept(retention, pin), do: Enum.count(retention.traces, fn {_id, t} -> t.pin == pin end)

  @doc "Whether this is the first eviction hint for `trace_id`, and marks it."
  @spec hint(t(), String.t()) :: {boolean(), t()}
  def hint(%__MODULE__{hinted: hinted} = retention, trace_id) do
    cond do
      MapSet.member?(hinted, trace_id) ->
        {false, retention}

      MapSet.size(hinted) >= @max_hinted ->
        {true, %{retention | hinted: MapSet.new([trace_id])}}

      true ->
        {true, %{retention | hinted: MapSet.put(hinted, trace_id)}}
    end
  end

  ## Bookkeeping

  defp add(retention, trace_id, pin) do
    trace = %{
      entries: [],
      bytes: 0,
      pin: pin,
      lost: 0,
      missed: 0,
      since: retention.cursor,
      notable: if(pin in @defaults, do: pin)
    }

    %{
      retention
      | traces: Map.put(retention.traces, trace_id, trace),
        order: retention.order ++ [trace_id]
    }
  end

  defp append(retention, _trace_id, []), do: retention

  defp append(retention, trace_id, entries) do
    bytes = Enum.reduce(entries, 0, &(:erlang.external_size(&1) + &2))
    trace = retention.traces[trace_id]

    %{
      retention
      | traces:
          Map.put(retention.traces, trace_id, %{
            trace
            | entries: trace.entries ++ entries,
              bytes: trace.bytes + bytes
          }),
        count: retention.count + length(entries),
        bytes: retention.bytes + bytes
    }
  end

  # Most recently active last.
  defp touch(retention, trace_id),
    do: %{retention | order: List.delete(retention.order, trace_id) ++ [trace_id]}

  # Explicit pins past @max_pins are let go, oldest active first: they
  # join the automatic traces, so `retain_traces` decides whether to keep
  # them.
  defp release_pins(retention) do
    pins = Enum.filter(retention.order, &(retention.traces[&1].pin == :explicit))

    if length(pins) > @max_pins do
      [oldest | _rest] = pins
      {put_in(retention.traces[oldest].pin, :auto), oldest}
    else
      {retention, nil}
    end
  end

  # Automatic traces beyond the limit go, least recently active first. One
  # that turned notable (ran a mutation, failed, or was slow) becomes a
  # trace kept by default for its strongest reason; while a default is on,
  # another's events go to the lookback, where a later notable event of
  # its trace finds them.
  defp trim(retention) do
    autos = Enum.filter(retention.order, &(retention.traces[&1].pin == :auto))
    excess = length(autos) - retention.limit
    retention = autos |> Enum.take(max(excess, 0)) |> Enum.reduce(retention, &let_go/2)
    Enum.reduce(@defaults, retention, &trim_pool(&2, &1))
  end

  defp let_go(trace_id, retention) do
    trace = retention.traces[trace_id]

    cond do
      trace.notable != nil and enabled?(retention, trace.notable) ->
        put_in(retention, [Access.key(:traces), trace_id, :pin], trace.notable)

      defaults?(retention) ->
        retention = drop_trace(retention, trace_id)

        trace.entries
        |> Enum.sort_by(& &1["receipt"])
        |> Enum.reduce(retention, &remember(&2, trace_id, &1))

      true ->
        drop_trace(retention, trace_id)
    end
  end

  defp bound(%{count: count, bytes: bytes} = retention)
       when count <= @max_entries and bytes <= @max_bytes,
       do: retention

  # Default traces go first, weakest reason first (slow, failed, then
  # mutation), so they never cost what `--retain-traces` and `--retain`
  # keep; then automatic traces.
  defp bound(retention) do
    victim =
      Enum.find_value(@defaults ++ [:auto], fn pin ->
        Enum.find(retention.order, &(retention.traces[&1].pin == pin))
      end)

    case victim do
      nil -> retention |> drop_oldest_event() |> bound()
      trace_id -> retention |> drop_trace(trace_id) |> bound()
    end
  end

  defp drop_trace(retention, trace_id) do
    trace = retention.traces[trace_id]
    events = length(trace.entries)

    %{
      retention
      | traces: Map.delete(retention.traces, trace_id),
        order: List.delete(retention.order, trace_id),
        count: retention.count - events,
        bytes: retention.bytes - trace.bytes,
        evicted_traces: retention.evicted_traces + 1,
        dropped_events: retention.dropped_events + events
    }
  end

  # The oldest event of the least recently active explicit pin that has one.
  defp drop_oldest_event(retention) do
    trace_id = Enum.find(retention.order, &(retention.traces[&1].entries != []))
    trace = retention.traces[trace_id]
    [oldest | rest] = Enum.sort_by(trace.entries, & &1["receipt"])
    bytes = :erlang.external_size(oldest)

    %{
      retention
      | traces:
          Map.put(retention.traces, trace_id, %{
            trace
            | entries: rest,
              bytes: trace.bytes - bytes,
              lost: trace.lost + 1
          }),
        count: retention.count - 1,
        bytes: retention.bytes - bytes,
        dropped_events: retention.dropped_events + 1
    }
  end
end
