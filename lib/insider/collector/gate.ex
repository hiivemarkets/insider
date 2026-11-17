defmodule Insider.Collector.Gate do
  @moduledoc false

  # Record-time filtering in the emitting process.
  #
  # The Logger and Telemetry handlers run in the process that logs or emits.
  # A gate decides there, before the handler does any other work, whether the
  # event is recorded. A dropped event costs the decision and one counter
  # increment: no sequence number, no handler statistics, no normalisation,
  # no inbox write. A summarised event adds its sample to a fixed-size
  # histogram instead (`Insider.Collector.Summary`); a summarised Logger
  # message adds one to its burst's count for the interval: its level,
  # message template (`Insider.Collector.Logger.Template`) and call site.
  #
  # Bursts are bounded at ingress. A burst key not yet seen this interval
  # takes an admission ticket (one `update_counter` on the interval's
  # admission row); at most `@max_bursts` keys are admitted, so the table
  # holds at most that many burst rows per interval whatever the messages
  # carry. A message of a key that is not admitted is counted in its level's
  # overflow row, and a fixed bitmap per interval parity counts the folded
  # distinctions (to within hash collisions, never more than there were).
  #
  # A decision is `:record`, `:drop`, or `{:exemplar, tag}`: a summarised
  # event that may stand for its summary. The handler then normalises it as
  # usual and hands it to its collector marked with `tag`, and the collector
  # decides whether to record it; it stays counted as summarised.
  #
  # The compiled gate lives in `:persistent_term` under the key returned by
  # `new/1`. Handler configurations, which `:logger` and `:telemetry` copy to
  # the emitting process on every event, carry only that key. Origin rules
  # can expand to thousands of modules, and a `:persistent_term` read does
  # not copy them. The creator deletes the gate when collection has stopped;
  # a handler that finds no gate records the event.
  #
  # Each dropped event is counted once, under the first filter that drops it:
  # Logger events in the order level, include, exclude, origin, summarised;
  # Telemetry events in the order origin, summarised, minimum duration;
  # OpenTelemetry spans in the order origin, minimum duration. A span is
  # decided in the otel collector, which reads the initial call of the
  # process that ended it, not in that process.
  #
  # Origin information (the emitting process's initial call, Logger
  # metadata, Ecto telemetry options) is read only to decide. It is never
  # recorded or returned, except a summarised Logger message's template and
  # call site (module, function, arity, line), which name its burst.
  #
  # Exemplar losses are counted here too, cumulatively, for the read gaps
  # `telemetry_exemplar_lost` and `logger_exemplar_lost`; folded Logger
  # distinctions for `logger_summary_overflow`.

  import Bitwise

  alias Insider.Collector.Logger.Template
  alias Insider.Collector.Summary
  alias Insider.Collector.Telemetry.Outcome

  @levels %{
    emergency: 0,
    alert: 1,
    critical: 2,
    error: 3,
    warning: 4,
    notice: 5,
    info: 6,
    debug: 7
  }
  @logger_filters ["level", "include", "exclude", "origin", "summarized"]
  @telemetry_filters ["origin", "summarized", "min_duration"]
  # Each Telemetry event has one counter per filter and, after them, one for
  # the events no filter dropped, so `seen/1` can count every emission.
  @telemetry_slots length(@telemetry_filters) + 1
  @otel_filters ["origin", "min_duration"]
  # The burst keys one interval admits; a message of any other key is
  # folded into its level's overflow row.
  @max_bursts 64
  # The folded-distinction bitmap of one interval parity: 4,096 words of 64
  # bits.
  @seen_words 4_096
  @seen_bits @seen_words * 64
  @cas_attempts 8

  @type key :: {module(), pos_integer()}
  @type decision :: :record | :drop | {:exemplar, term()}
  @type matcher :: %{
          domains: [[atom()]],
          applications: %{optional(atom()) => true},
          modules: %{optional(module()) => true}
        }
  @type origin :: %{oban_conf: boolean(), modules: %{optional(module()) => true}}
  @type telemetry_rule :: %{
          required(:name) => [atom()],
          required(:kind) => String.t(),
          required(:min_duration_ms) => non_neg_integer(),
          required(:summary) => boolean(),
          optional(:duration_scope) => String.t() | nil
        }
  @type logger_rules :: %{
          level: atom(),
          include: matcher() | nil,
          exclude: matcher() | nil,
          summary: matcher() | nil,
          summary_interval_ms: pos_integer()
        }
  @type spec :: %{
          required(:logger) => logger_rules() | nil,
          required(:origin) => origin() | nil,
          required(:telemetry) => [telemetry_rule()],
          required(:summary_interval_ms) => pos_integer(),
          optional(:otel) => %{min_duration_ms: non_neg_integer()} | nil
        }
  @typedoc """
  A burst row's key: `{:burst, generation, template, module, function,
  arity, line, level}`; the template is `nil` for a message without text,
  the call site fields `nil` when the message's metadata has none.
  """
  @type burst_key ::
          {:burst, non_neg_integer(), String.t() | nil, module() | nil, atom() | nil,
           non_neg_integer() | nil, non_neg_integer() | nil, atom()}

  @doc "The most burst keys one interval admits."
  @spec max_bursts() :: pos_integer()
  def max_bursts, do: @max_bursts

  @doc "Each Logger level's rank, most severe 0."
  @spec level_ranks() :: %{atom() => non_neg_integer()}
  def level_ranks, do: @levels

  @doc "The Logger levels, most severe first."
  @spec levels() :: [String.t()]
  def levels,
    do: @levels |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&Atom.to_string(elem(&1, 0)))

  @doc "The filter names counted for Logger events, each Telemetry event, and spans."
  @spec filter_names() :: %{String.t() => [String.t()]}
  def filter_names,
    do: %{"logger" => @logger_filters, "otel" => @otel_filters, "telemetry" => @telemetry_filters}

  @doc """
  Compiles `spec` and stores it for `owner`, the process whose session uses
  it. Returns the key handlers carry. Summary rows (Telemetry histograms and
  Logger bursts) live in one ETS table owned by the calling process
  (`Insider.Live.Gates`) with `owner` as its heir: if the caller dies, the
  table passes to the session's owner, so summaries keep working; if the
  owner dies too, the session has ended.
  """
  @spec new(spec(), pid()) :: key()
  def new(spec, owner \\ self()) do
    key = {__MODULE__, System.unique_integer([:positive, :monotonic])}
    bursts? = match?(%{summary: %{}}, spec.logger)

    # The heir message carries the key, so an heir can tell whether it still
    # holds the gate the table belongs to.
    table =
      if bursts? or Enum.any?(spec.telemetry, & &1.summary),
        do: :ets.new(Summary, [:set, :public, write_concurrency: true] ++ heir(owner, key))

    events =
      spec.telemetry
      |> Enum.with_index()
      |> Map.new(fn {rule, index} ->
        {List.to_tuple(rule.name),
         %{
           base: length(@logger_filters) + 1 + index * @telemetry_slots,
           kind: rule.kind,
           exception: List.last(rule.name) == :exception,
           min_native: System.convert_time_unit(rule.min_duration_ms, :millisecond, :native),
           summary: if(rule.summary, do: Summary.new_slot(table, index)),
           duration_scope: Map.get(rule, :duration_scope)
         }}
      end)

    # The otel counters follow the Telemetry ones; after them come summary
    # samples that could not be stored, then lost Telemetry and Logger
    # exemplars, then folded Logger distinctions.
    otel_base = length(@logger_filters) + length(spec.telemetry) * @telemetry_slots + 1
    lost = otel_base + length(@otel_filters)

    gate = %{
      bursts:
        if(bursts?,
          do: %{
            table: table,
            generations: :atomics.new(1, []),
            interval_ms: spec.logger.summary_interval_ms,
            seen: {seen_bitmap(), seen_bitmap()},
            dirty: :atomics.new(2, [])
          }
        ),
      counters: :counters.new(lost + 3, [:write_concurrency]),
      events: events,
      logger: logger(spec.logger),
      lost: lost,
      origin: spec.origin,
      otel: otel(Map.get(spec, :otel), otel_base),
      owner: owner,
      summary_interval_ms: spec.summary_interval_ms,
      table: table
    }

    :persistent_term.put(key, gate)
    key
  end

  defp heir(owner, _key) when owner == self(), do: []
  defp heir(owner, key), do: [{:heir, owner, key}]

  defp seen_bitmap, do: :atomics.new(@seen_words, signed: false)

  @doc "Whether `key` names a gate shape. The gate itself may be gone."
  @spec key?(term()) :: boolean()
  def key?({__MODULE__, id}) when is_integer(id) and id > 0, do: true
  def key?(_key), do: false

  @doc "Every stored gate with its owner."
  @spec all() :: [{key(), pid()}]
  def all,
    do:
      for({{__MODULE__, _id} = key, %{owner: owner}} <- :persistent_term.get(), do: {key, owner})

  @doc """
  Removes the gate and, when the caller owns it, its summary table.
  Handlers that still hold the key record every event.
  """
  @spec delete(key() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(key) do
    case :persistent_term.get(key, nil) do
      %{table: table} ->
        _erased = :persistent_term.erase(key)
        delete_table(table)

      nil ->
        :ok
    end
  end

  @doc "The gate's summary table, or `nil`."
  @spec table(key() | nil) :: :ets.tid() | nil
  def table(nil), do: nil

  def table(key) do
    case :persistent_term.get(key, nil) do
      %{table: table} -> table
      nil -> nil
    end
  end

  @doc "Deletes a summary table if the caller owns it; anything else is a no-op."
  @spec delete_table(:ets.tid() | nil) :: :ok
  def delete_table(nil), do: :ok

  def delete_table(table) do
    if :ets.info(table, :owner) == self(), do: :ets.delete(table)
    :ok
  end

  @doc """
  Logger decision, in the logging process. A summarised message is counted
  in its burst (level, template, call site); the interval's first message of
  an admitted burst is `{:exemplar, burst_key}`, the rest `:drop`.
  """
  @spec logger(key() | nil, term()) :: decision()
  def logger(nil, _log_event), do: :record

  def logger(key, %{level: level, meta: metadata} = log_event) when is_map(metadata) do
    case :persistent_term.get(key, nil) do
      %{logger: %{} = rules} = gate ->
        logger_decision(gate, rules, level, Map.get(log_event, :msg), metadata)

      _absent ->
        :record
    end
  end

  def logger(_key, _log_event), do: :record

  @doc """
  Telemetry decision, in the emitting process. A summarised event is added
  to its histogram and is not recorded, unless it is an exemplar candidate
  (`Insider.Collector.Summary`): then `{:exemplar, exemplar}`.
  """
  @spec telemetry(key() | nil, term(), term(), term()) :: decision()
  def telemetry(nil, _name, _measurements, _metadata), do: :record

  def telemetry(key, name, measurements, metadata)
      when is_list(name) and is_map(measurements) and is_map(metadata) do
    with %{events: events} = gate <- :persistent_term.get(key, nil),
         {:ok, rule} <- Map.fetch(events, List.to_tuple(name)) do
      telemetry_decision(gate, rule, measurements, metadata)
    else
      _absent -> :record
    end
  end

  def telemetry(_key, _name, _measurements, _metadata), do: :record

  @doc """
  Span decision, in the otel collector: `true` records the span. `pid` is
  the process that ended it (`nil` for an ingested span), `duration_us` its
  duration, and `error?` whether its status is error. An error bypasses the
  minimum duration. Origin is the initial call of `pid`, read as one
  dictionary entry.
  """
  @spec otel?(key() | nil, pid() | nil, term(), boolean()) :: boolean()
  def otel?(nil, _pid, _duration_us, _error?), do: true

  def otel?(key, pid, duration_us, error?) do
    case :persistent_term.get(key, nil) do
      %{otel: %{} = rule} = gate -> otel_decision(gate, rule, pid, duration_us, error?)
      _absent -> true
    end
  end

  @doc """
  The cumulative filtered counts: `{"logger", filter}`,
  `{"telemetry", kind, filter}`, and `{"otel", filter}` keys, and the losses:
  `{"summary_lost"}`, `{"exemplar_lost", "telemetry"}`,
  `{"exemplar_lost", "logger"}` and `{"summary_overflow", "logger"}` (folded
  Logger distinctions). Empty when the gate is gone.
  """
  @spec counts(key() | nil) :: %{tuple() => non_neg_integer()}
  def counts(nil), do: %{}

  def counts(key) do
    case :persistent_term.get(key, nil) do
      %{counters: counters, lost: lost} = gate ->
        logger =
          if gate.logger,
            do:
              @logger_filters
              |> Enum.with_index(1)
              |> Map.new(fn {filter, index} ->
                {{"logger", filter}, :counters.get(counters, index)}
              end),
            else: %{}

        logger =
          Map.merge(logger, %{
            {"summary_lost"} => :counters.get(counters, lost),
            {"exemplar_lost", "telemetry"} => :counters.get(counters, lost + 1),
            {"exemplar_lost", "logger"} => :counters.get(counters, lost + 2),
            {"summary_overflow", "logger"} => :counters.get(counters, lost + 3)
          })

        logger =
          if gate.otel,
            do:
              @otel_filters
              |> Enum.with_index()
              |> Enum.reduce(logger, fn {filter, offset}, counts ->
                Map.put(
                  counts,
                  {"otel", filter},
                  :counters.get(counters, gate.otel.base + offset)
                )
              end),
            else: logger

        Enum.reduce(gate.events, logger, fn {_name, rule}, counts ->
          @telemetry_filters
          |> Enum.with_index()
          |> Enum.reduce(counts, fn {filter, offset}, counts ->
            Map.put(
              counts,
              {"telemetry", rule.kind, filter},
              :counters.get(counters, rule.base + offset)
            )
          end)
        end)

      _absent ->
        %{}
    end
  end

  @doc """
  Counts a Telemetry exemplar candidate `exemplar` of event `name` that
  never reached its collector: in its interval's summary when that is not
  yet recorded (`:counted`), and always in the gate's cumulative count.
  `:late` when the summary was already recorded.
  """
  @spec telemetry_exemplar_lost(key() | nil, [atom()], Summary.exemplar()) :: :counted | :late
  def telemetry_exemplar_lost(key, name, {generation, _duration, _first_error}) do
    with %{events: events} = gate <- :persistent_term.get(key, nil),
         {:ok, %{summary: {_table, _index, _generations} = slot}} <-
           Map.fetch(events, List.to_tuple(name)) do
      :counters.add(gate.counters, gate.lost + 1, 1)
      Summary.lose(slot, generation)
    else
      _absent -> :late
    end
  end

  @doc """
  Marks burst `burst_key`'s exemplar as lost before it reached the
  collector, and counts the loss: `:marked`. `:taken` when the burst was
  already taken: the collector recorded it without an exemplar and counted
  that loss itself (`count_exemplar_lost/2`), so nothing is counted twice.
  """
  @spec logger_exemplar_lost(key() | nil, burst_key()) :: :marked | :taken
  def logger_exemplar_lost(key, burst_key) do
    case :persistent_term.get(key, nil) do
      %{bursts: %{table: table}} = gate ->
        _lost = :ets.update_counter(table, burst_key, {3, 1})
        :counters.add(gate.counters, gate.lost + 2, 1)
        :marked

      _absent ->
        :taken
    end
  rescue
    ArgumentError -> :taken
  end

  @doc """
  Counts one exemplar the collector lost (`:telemetry` or `:logger`) in
  the gate's cumulative count.
  """
  @spec count_exemplar_lost(key() | nil, :telemetry | :logger) :: :ok
  def count_exemplar_lost(key, source) do
    case :persistent_term.get(key, nil) do
      %{counters: counters, lost: lost} ->
        :counters.add(counters, if(source == :telemetry, do: lost + 1, else: lost + 2), 1)

      _absent ->
        :ok
    end
  end

  @doc "Counts `count` Logger burst distinctions the collector folded into overflow rows."
  @spec count_overflow(key() | nil, non_neg_integer()) :: :ok
  def count_overflow(key, count) do
    case :persistent_term.get(key, nil) do
      %{counters: counters, lost: lost} -> :counters.add(counters, lost + 3, count)
      _absent -> :ok
    end
  end

  @doc """
  Every emission of each Telemetry event the gate decided since it was
  created, recorded or filtered, by kind. Empty when the gate is gone.
  """
  @spec seen(key() | nil) :: %{String.t() => non_neg_integer()}
  def seen(nil), do: %{}

  def seen(key) do
    case :persistent_term.get(key, nil) do
      %{counters: counters, events: events} ->
        Map.new(events, fn {_name, rule} ->
          seen =
            Enum.reduce(
              0..(@telemetry_slots - 1),
              0,
              &(&2 + :counters.get(counters, rule.base + &1))
            )

          {rule.kind, seen}
        end)

      _absent ->
        %{}
    end
  end

  @doc """
  The summarised events: `{kind, name, slot, duration_scope}` for each,
  `duration_scope` the declared `"handler"` or `"caller"` or `nil`, and the
  interval.
  """
  @spec summaries(key() | nil) ::
          {[{String.t(), [atom()], Summary.slot(), String.t() | nil}], pos_integer()} | nil
  def summaries(nil), do: nil

  def summaries(key) do
    case :persistent_term.get(key, nil) do
      %{events: events, summary_interval_ms: interval} ->
        slots =
          for {name, %{summary: {_table, _index, _generations} = slot} = rule} <- events,
              do: {rule.kind, Tuple.to_list(name), slot, rule.duration_scope}

        if slots == [], do: nil, else: {Enum.sort(slots), interval}

      _absent ->
        nil
    end
  end

  defp otel(nil, _base), do: nil

  defp otel(%{min_duration_ms: minimum}, base),
    do: %{base: base, min_us: System.convert_time_unit(minimum, :millisecond, :microsecond)}

  # A span decision stays a boolean: `drop/2` counts the filter (its result
  # is the Logger and Telemetry decision `:drop`) and the span is not recorded.
  defp otel_decision(gate, rule, pid, duration_us, error?) do
    cond do
      gate.origin != nil and pid_origin?(gate.origin, pid) ->
        :drop = drop(gate, rule.base)
        false

      rule.min_us > 0 and is_integer(duration_us) and duration_us < rule.min_us and not error? ->
        :drop = drop(gate, rule.base + 1)
        false

      true ->
        true
    end
  end

  # The initial call of the process that ended a span; a process that has
  # exited has no origin and is recorded.
  defp pid_origin?(%{modules: modules}, _pid) when map_size(modules) == 0, do: false

  defp pid_origin?(%{modules: modules}, pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, {:dictionary, :"$initial_call"}) do
      {{:dictionary, :"$initial_call"}, {module, _function, _arity}} ->
        is_map_key(modules, module)

      _none ->
        false
    end
  end

  defp pid_origin?(_origin, _pid), do: false

  @doc """
  The Logger burst summary of the gate: its table, its generation counter,
  the interval, and the folded-distinction bitmaps; `nil` without one.
  """
  @spec bursts(key() | nil) :: map() | nil
  def bursts(nil), do: nil

  def bursts(key) do
    case :persistent_term.get(key, nil) do
      %{bursts: bursts} -> bursts
      _absent -> nil
    end
  end

  @doc """
  Ends the current burst interval and takes its rows, and any row a late
  writer added to an earlier one: `{generation, bursts, overflows}`, each
  burst `{burst_key, count, lost}` (`lost` > 0 when its exemplar never
  reached the collector), each overflow `{level, count, distinct}`. Only one
  process may take. Rows written after the take belong to the next
  interval's take, so a message is counted exactly once. The work is
  bounded by the table, which admission bounds.
  """
  @spec take_bursts(map()) ::
          {non_neg_integer(), [{burst_key(), pos_integer(), non_neg_integer()}],
           [{atom(), pos_integer(), non_neg_integer()}]}
  def take_bursts(%{table: table, generations: generations} = bursts) do
    generation = :atomics.get(generations, 1)
    # The next interval's bitmap is the one two intervals back: cleared
    # before the next interval opens.
    clear_seen(bursts, rem(generation + 1, 2))
    :atomics.put(generations, 1, generation + 1)

    burst_rows = take_rows(table, {{:burst, :"$1", :_, :_, :_, :_, :_, :_}, :_, :_}, generation)
    overflow_rows = take_rows(table, {{:overflow, :"$1", :_}, :_, :_}, generation)

    # A late writer of the interval before still counts on its admission
    # row; older ones go.
    _deleted =
      :ets.select_delete(table, [{{{:admitted, :"$1"}, :_}, [{:<, :"$1", generation}], [true]}])

    overflows =
      overflow_rows
      |> Enum.group_by(fn {{:overflow, _g, level}, _count, _distinct} -> level end)
      |> Enum.map(fn {level, rows} ->
        {level, rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
         rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()}
      end)

    {generation, burst_rows, overflows}
  rescue
    # The table went with a gate keeper that crashed.
    ArgumentError -> {0, [], []}
  end

  defp take_rows(table, pattern, generation) do
    table
    |> :ets.select([{pattern, [{:"=<", :"$1", generation}], [{:element, 1, :"$_"}]}])
    |> Enum.flat_map(&:ets.take(table, &1))
  end

  defp clear_seen(%{seen: seen, dirty: dirty}, parity) do
    if :atomics.exchange(dirty, parity + 1, 0) == 1 do
      bitmap = elem(seen, parity)
      for word <- 1..@seen_words, do: :atomics.put(bitmap, word, 0)
    end

    :ok
  end

  defp logger(nil), do: nil

  defp logger(%{level: level} = rules),
    do: %{
      level: Map.fetch!(@levels, level),
      include: rules.include,
      exclude: rules.exclude,
      summary: Map.get(rules, :summary)
    }

  # OTP SASL-domain reports (crash, supervisor, and progress reports) at
  # `info` or more severe pass the level floor; an explicit exclude still
  # drops them. Debug-level progress reports (every child start on recent
  # OTP releases) do not.
  defp logger_decision(gate, rules, level, message, metadata) do
    rank = Map.get(@levels, level, 7)

    cond do
      rank > rules.level and not (rank <= @levels.info and sasl?(metadata)) -> drop(gate, 1)
      rules.include != nil and not matches?(rules.include, metadata) -> drop(gate, 2)
      rules.exclude != nil and matches?(rules.exclude, metadata) -> drop(gate, 3)
      gate.origin != nil and process_origin?(gate.origin) -> drop(gate, 4)
      burst?(rules.summary, message, metadata) -> burst(gate, level, message, metadata)
      true -> :record
    end
  end

  # Only messages are summarised (a string or a format with its arguments);
  # reports, which carry OTP crash and supervisor evidence, are recorded.
  defp burst?(nil, _message, _metadata), do: false
  defp burst?(_summary, {:report, _report}, _metadata), do: false
  defp burst?(summary, _message, metadata), do: matches?(summary, metadata)

  # A burst that exists this interval costs one counter update. A key not
  # seen yet takes an admission ticket first; past `@max_bursts` tickets the
  # message is folded into its level's overflow row. A table that is gone
  # records the message instead: nothing is lost.
  defp burst(%{bursts: bursts} = gate, level, message, metadata) do
    {module, function, arity} =
      case Map.get(metadata, :mfa) do
        {m, f, a} when is_atom(m) and is_atom(f) and is_integer(a) -> {m, f, a}
        _none -> {nil, nil, nil}
      end

    line =
      case Map.get(metadata, :line) do
        line when is_integer(line) -> line
        _none -> nil
      end

    generation = :atomics.get(bursts.generations, 1)
    template = Template.of_message(message)
    key = {:burst, generation, template, module, function, arity, line, level}

    case bump(bursts.table, key) do
      :missing -> admit(gate, bursts, key, generation)
      _count -> drop(gate, 5)
    end
  rescue
    ArgumentError -> :record
  end

  defp bump(table, key) do
    :ets.update_counter(table, key, {2, 1})
  rescue
    ArgumentError -> :missing
  end

  defp admit(gate, %{table: table} = bursts, key, generation) do
    admission = {:admitted, generation}

    if :ets.update_counter(table, admission, {2, 1}, {admission, 0}) <= @max_bursts do
      case :ets.update_counter(table, key, {2, 1}, {key, 0, 0}) do
        1 -> summarized(gate, 5, {:exemplar, key})
        _count -> drop(gate, 5)
      end
    else
      overflow(gate, bursts, key, generation)
    end
  end

  defp overflow(gate, bursts, {:burst, _g, template, m, f, a, line, level}, generation) do
    parity = rem(generation, 2)
    bit = :erlang.phash2({template, m, f, a, line, level}, @seen_bits)
    bitmap = elem(bursts.seen, parity)
    new = if set_bit(bitmap, div(bit, 64) + 1, 1 <<< rem(bit, 64), @cas_attempts), do: 1, else: 0
    row = {:overflow, generation, level}
    _counts = :ets.update_counter(bursts.table, row, [{2, 1}, {3, new}], {row, 0, 0})

    if new == 1 do
      :atomics.put(bursts.dirty, parity + 1, 1)
      :counters.add(gate.counters, gate.lost + 3, 1)
    end

    drop(gate, 5)
  end

  # Sets one bit; true when this call set it. A writer that keeps losing the
  # race gives up and counts nothing, so distinctions are never overcounted.
  defp set_bit(_bitmap, _word, _mask, 0), do: false

  defp set_bit(bitmap, word, mask, attempts) do
    old = :atomics.get(bitmap, word)

    cond do
      band(old, mask) != 0 -> false
      :atomics.compare_exchange(bitmap, word, old, bor(old, mask)) == :ok -> true
      true -> set_bit(bitmap, word, mask, attempts - 1)
    end
  end

  defp telemetry_decision(gate, rule, measurements, metadata) do
    cond do
      gate.origin != nil and telemetry_origin?(gate.origin, metadata) ->
        drop(gate, rule.base)

      rule.summary != nil ->
        # A sample that could not be stored is a loss, never `summarized`.
        case Summary.add(rule.summary, error?(rule, metadata), sample(measurements)) do
          :ok -> drop(gate, rule.base + 1)
          {:exemplar, _exemplar} = exemplar -> summarized(gate, rule.base + 1, exemplar)
          :lost -> lost(gate, rule)
        end

      rule.min_native > 0 and below?(rule, measurements, metadata) ->
        drop(gate, rule.base + 2)

      true ->
        :counters.add(gate.counters, rule.base + @telemetry_slots - 1, 1)
        :record
    end
  end

  # A lost summary sample is not recorded and was not filtered.
  defp lost(gate, rule) do
    :counters.add(gate.counters, rule.base + @telemetry_slots - 1, 1)
    drop(gate, gate.lost)
  end

  defp drop(gate, index) do
    :counters.add(gate.counters, index, 1)
    :drop
  end

  # An exemplar is summarised like any other sample.
  defp summarized(gate, index, exemplar) do
    :counters.add(gate.counters, index, 1)
    exemplar
  end

  defp sasl?(%{domain: [:otp, :sasl | _rest]}), do: true
  defp sasl?(_metadata), do: false

  defp matches?(matcher, metadata) do
    domain_match?(matcher.domains, Map.get(metadata, :domain)) or
      is_map_key(matcher.applications, Map.get(metadata, :application)) or
      mfa_match?(matcher.modules, Map.get(metadata, :mfa))
  end

  defp domain_match?([], _domain), do: false

  defp domain_match?(domains, domain) when is_list(domain),
    do: Enum.any?(domains, &:lists.prefix(&1, domain))

  defp domain_match?(_domains, _domain), do: false

  defp mfa_match?(modules, {module, _function, _arity}), do: is_map_key(modules, module)
  defp mfa_match?(_modules, _mfa), do: false

  defp telemetry_origin?(origin, metadata) do
    (origin.oban_conf and oban_query?(metadata)) or process_origin?(origin)
  end

  # `Oban.Repo` runs every query of Oban's own (polling, staging, fetching,
  # acknowledging, pruning, leadership) with `telemetry_options: [oban_conf:
  # conf]`, which Ecto passes on as the `:options` metadata of the query event.
  defp oban_query?(%{options: options}) when is_list(options),
    do: List.keymember?(options, :oban_conf, 0)

  defp oban_query?(_metadata), do: false

  defp process_origin?(%{modules: modules}) when map_size(modules) == 0, do: false

  defp process_origin?(%{modules: modules}) do
    case Process.get(:"$initial_call") do
      {module, _function, _arity} -> is_map_key(modules, module)
      _none -> false
    end
  end

  defp below?(rule, measurements, metadata) do
    case duration_native(measurements) do
      duration when is_integer(duration) ->
        duration < rule.min_native and not error?(rule, metadata)

      _none ->
        false
    end
  end

  # An error bypasses the minimum duration and is counted as an error in a
  # summary: an `:exception` event or metadata of a failure shape
  # (`Insider.Collector.Telemetry.Outcome`).
  defp error?(%{exception: exception}, metadata),
    do: exception or Outcome.failed?(metadata)

  # Telemetry durations are native time units by convention: `duration` for
  # spans, `total_time` for Ecto queries.
  defp duration_native(%{duration: duration}) when is_integer(duration), do: duration
  defp duration_native(%{total_time: duration}) when is_integer(duration), do: duration
  defp duration_native(_measurements), do: nil

  # The summary sample keeps the measurement name, so the export boundary
  # can decide whether that measurement may be disclosed.
  defp sample(%{duration: duration}) when is_integer(duration), do: {:duration, micros(duration)}

  defp sample(%{total_time: duration}) when is_integer(duration),
    do: {:total_time, micros(duration)}

  defp sample(_measurements), do: nil

  defp micros(duration), do: System.convert_time_unit(max(duration, 0), :native, :microsecond)
end
