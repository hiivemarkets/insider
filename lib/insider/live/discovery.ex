defmodule Insider.Live.Discovery do
  @moduledoc false

  # The Telemetry event names this node can emit, for `Insider.Live.discover/1`
  # and for prefix subscription (`"telemetry_events"` entries ending in `"*"`).
  #
  # Two sources, neither of which runs application code:
  # - handlers: the event names `:telemetry.list_handlers/1` reports, except
  #   Insider's own session handlers;
  # - static: literal event lists passed to `:telemetry.execute/2,3` and
  #   `:telemetry.span/3` in loaded application modules, read from each
  #   module's object file. A span name is expanded to its `:start`, `:stop`,
  #   and `:exception` events. A module's debug info is read only when its
  #   import table names one of those functions and the file still holds the
  #   loaded code (the same MD5). The debug info is decoded and walked as a
  #   plain term, never handed to the backend it names: Elixir definitions
  #   (`:elixir_erl`) and Erlang abstract code (`:erl_abstract_code`).
  #
  # Names built at run time (a prefix held in a variable or an option) are
  # found only through an attached handler. Every loaded module with an
  # object file is a candidate except Insider's own and those in the ebin
  # directory of an OTP or Elixir application named below. Only those exact
  # application directories are left out: in a release, OTP, Elixir, and the
  # application share one lib directory under the release root.
  #
  # Every bound that drops evidence is reported in `truncated_by`.
  #
  # The scan runs in a worker process under a deadline and a heap guard, and
  # at most two run at once (`busy` beyond that). The caller receives only
  # the plain result the worker built.

  alias Insider.Live.Error
  alias Insider.Live.Options
  alias Insider.Live.SlotWorker
  alias Insider.Protocol.Value

  @schema "insider.live-telemetry-discovery/v1"
  @deadline_ms 2_000
  @await_margin_ms 500
  @max_modules 20_000
  @max_file_bytes 16_777_216
  @max_debug_info_bytes 2_097_152
  @max_nodes_per_module 2_000_000
  @max_names 4_096
  @max_events 512
  @max_sources 8
  @max_segments 8
  @max_entries 64
  # 128 MiB on a 64-bit VM, for the scan worker (it holds one object file of
  # at most 16 MiB at a time) and for each module's debug-info reader. A
  # reader over it is killed and its module counted as too large.
  @max_worker_heap_words 16_777_216
  @slots [Insider.Live.Discovery.Slot1, Insider.Live.Discovery.Slot2]
  @segment ~r/\A[a-z][a-z0-9_]*\z/
  @telemetry_calls [{:telemetry, :execute, 2}, {:telemetry, :execute, 3}, {:telemetry, :span, 3}]
  @span_suffixes [:start, :stop, :exception]
  @insider_handler Insider.Collector.Telemetry.Handler
  # Applications that never call `:telemetry`: Elixir's own and OTP's. A
  # name missing here only costs its modules an import-table read.
  @system_applications ~w(elixir logger mix iex ex_unit eex kernel stdlib compiler crypto ssl
    public_key asn1 inets sasl runtime_tools tools syntax_tools parsetools xmerl mnesia os_mon
    erts observer wx debugger et edoc eunit common_test dialyzer ssh ftp tftp snmp megaco
    diameter eldap odbc reltool erl_interface jinterface otp_mibs)a

  @type name :: [String.t()]
  @type scan :: %{
          names: %{name() => [map()]},
          stats: map(),
          truncated_by: [String.t()],
          elapsed_ms: non_neg_integer()
        }

  @doc "The fixed bounds of one discovery."
  @spec bounds() :: map()
  def bounds do
    %{
      "deadline_ms" => @deadline_ms,
      "modules_max" => @max_modules,
      "names_max" => @max_names,
      "events_max" => @max_events,
      "sources_max" => @max_sources,
      "walk_nodes_max" => @max_nodes_per_module,
      "concurrent_max" => length(@slots)
    }
  end

  @doc """
  The `insider.live-telemetry-discovery/v1` result: every discovered event
  name under `prefix` (`nil` for all), sorted, with its sources.
  """
  @spec discover([String.t()] | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def discover(prefix, scan_options \\ []) do
    with {:ok, scan} <- scan(scan_options) do
      matching =
        scan.names
        |> Enum.filter(fn {name, _sources} ->
          prefix == nil or List.starts_with?(name, prefix)
        end)
        |> Enum.sort()

      truncated_by =
        if length(matching) > @max_events,
          do: scan.truncated_by ++ ["events"],
          else: scan.truncated_by

      {:ok,
       %{
         "schema" => @schema,
         "prefix" => prefix,
         "events" =>
           matching
           |> Enum.take(@max_events)
           |> Enum.map(fn {name, %{sources: sources, truncated: truncated}} ->
             %{
               "event" => Enum.join(name, "."),
               "sources" => sources,
               "sources_truncated" => truncated
             }
           end),
         "events_total" => length(matching),
         "modules" => scan.stats,
         "truncated" => truncated_by != [],
         "truncated_by" => truncated_by,
         "elapsed_ms" => scan.elapsed_ms,
         "bounds" => bounds()
       }}
    end
  end

  @doc """
  Replaces each prefix entry of `options["telemetry_events"]` (a segment
  list whose last segment is `"*"`, such as `["shop", "*"]`) with the
  discovered event names under that prefix (at any depth below it). Explicit
  names come first in their order, then each prefix's names in sorted
  order, without repeats; each distinct prefix is expanded once. Returns
  the rewritten options and, for the start result, one
  `%{"prefix", "events", "complete"}` per prefix; `"complete"` is false when
  a bound dropped names from the scan (every reason but `"sources"`).
  Options without a prefix entry, or whose `"telemetry_events"` is not a
  proper list of at most 64 proper lists of at most 8 elements, are
  returned unchanged and nothing is scanned: the start validation then
  refuses the malformed ones.

  A prefix that matches no discovered name is `unknown_telemetry_event`; a
  malformed prefix, or more names in total than a session may record, is
  `invalid_options` for `"telemetry_events"`.
  """
  @spec expand_prefixes(term(), keyword()) :: {:ok, term(), [map()]} | {:error, map()}
  def expand_prefixes(options, scan_options \\ []) do
    with {:ok, events} <- prefixed_events(options),
         {:ok, prefixes} <- valid_prefixes(events),
         {:ok, scan} <- scan(scan_options),
         {:ok, expanded} <- expand(prefixes, scan) do
      rewrite(options, events, prefixes, expanded, complete?(scan))
    else
      :none -> {:ok, options, []}
      {:error, _error} = error -> error
    end
  end

  # Caller input is checked for shape and size before it is traversed.
  defp prefixed_events(%{"telemetry_events" => events} = options) when not is_struct(options) do
    if Value.bounded_list?(events, @max_entries) and
         Enum.all?(events, &Value.bounded_list?(&1, @max_segments)) and
         Enum.any?(events, &prefix?/1),
       do: {:ok, events},
       else: :none
  end

  defp prefixed_events(_options), do: :none

  @doc "Whether `options[\"telemetry_events\"]` holds a prefix entry."
  @spec prefixes?(term()) :: boolean()
  def prefixes?(options), do: prefixed_events(options) != :none

  defp prefix?([_ | _] = segments), do: List.last(segments) == "*"
  defp prefix?(_segments), do: false

  defp valid_prefixes(events) do
    prefixes = for segments <- events, prefix?(segments), uniq: true, do: Enum.drop(segments, -1)

    if Enum.all?(prefixes, &valid_prefix?/1),
      do: {:ok, prefixes},
      else: {:error, Error.new("invalid_options", %{"field" => "telemetry_events"})}
  end

  @doc "Whether `prefix` is 1 to 7 event-name segments."
  @spec valid_prefix?(term()) :: boolean()
  def valid_prefix?([_ | _] = prefix),
    do: Value.bounded_list?(prefix, @max_segments - 1) and Enum.all?(prefix, &segment?/1)

  def valid_prefix?(_prefix), do: false

  defp expand(prefixes, scan) do
    Enum.reduce_while(prefixes, {:ok, %{}}, fn prefix, {:ok, expanded} ->
      case scan.names |> Map.keys() |> Enum.filter(&under?(&1, prefix)) |> Enum.sort() do
        [] ->
          {:halt,
           {:error,
            Error.new("unknown_telemetry_event", %{
              "event" => prefix ++ ["*"],
              "discovered" => 0,
              "complete" => complete?(scan)
            })}}

        names ->
          {:cont, {:ok, Map.put(expanded, prefix, names)}}
      end
    end)
  end

  defp under?(name, prefix), do: length(name) > length(prefix) and List.starts_with?(name, prefix)

  # Only a bound that drops names makes an expansion incomplete.
  defp complete?(scan), do: Enum.all?(scan.truncated_by, &(&1 == "sources"))

  # Names are added once each, in order; the total is bounded by the
  # explicit entries plus the scan's names.
  defp rewrite(options, events, prefixes, expanded, complete) do
    max = Options.bounds()["telemetry_events_max"]

    {reversed, _seen} =
      Enum.reduce(
        Enum.reject(events, &prefix?/1) ++ Enum.flat_map(prefixes, &Map.fetch!(expanded, &1)),
        {[], MapSet.new()},
        fn name, {names, seen} ->
          if MapSet.member?(seen, name),
            do: {names, seen},
            else: {[name | names], MapSet.put(seen, name)}
        end
      )

    names = Enum.reverse(reversed)

    if length(names) > max do
      {:error,
       Error.new("invalid_options", %{
         "field" => "telemetry_events",
         "expanded" => length(names),
         "max" => max
       })}
    else
      echo =
        for {prefix, matched} <- Enum.sort(expanded) do
          %{
            "prefix" => Enum.join(prefix ++ ["*"], "."),
            "events" => Enum.map(matched, &Enum.join(&1, ".")),
            "complete" => complete
          }
        end

      {:ok, Map.put(options, "telemetry_events", names), echo}
    end
  end

  defp segment?(value),
    do: is_binary(value) and byte_size(value) in 1..64 and String.match?(value, @segment)

  # The scan, in a worker (`Insider.Live.SlotWorker`). The worker takes one
  # of the slots, so at most two discoveries do the work at once; a third is
  # `busy` at once.
  #
  # `scan_options` exist for tests only and are never taken from a caller:
  # `:deadline_ms`, `:reader_heap_words`, `:modules` (scan only these
  # candidates), and `:hold_readers` (a pid each reader reports to and then
  # waits on, which it never hears from, so the reader meets the deadline).
  defp scan(scan_options) do
    deadline_ms = Keyword.get(scan_options, :deadline_ms, @deadline_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    SlotWorker.run(fn -> {:ok, collect(deadline, scan_options)} end,
      slots: @slots,
      heap_words: @max_worker_heap_words,
      include_shared_binaries: true,
      await_ms: deadline_ms + @await_margin_ms
    )
  end

  @doc """
  The modules a scan reads, sorted: every loaded module with an object
  file, except Insider's own and those whose file lies directly in one of
  `system_ebins` (by default `system_ebins/0`). An application in a release,
  beside OTP's and Elixir's applications under one root, is read.
  """
  @spec candidates([{module(), term()}], [String.t()]) :: [{module(), charlist()}]
  def candidates(loaded, system_ebins \\ system_ebins()) do
    insider = MapSet.new(Application.spec(:insider, :modules) || [])
    system = MapSet.new(system_ebins)

    loaded
    |> Enum.filter(fn {module, file} ->
      is_list(file) and file != [] and not MapSet.member?(insider, module) and
        not MapSet.member?(system, file |> List.to_string() |> Path.expand() |> Path.dirname())
    end)
    |> Enum.sort()
  end

  @doc "The ebin directories of the OTP and Elixir applications on this node."
  @spec system_ebins() :: [String.t()]
  def system_ebins do
    for application <- @system_applications,
        directory = :code.lib_dir(application),
        is_list(directory),
        do: directory |> List.to_string() |> Path.expand() |> Path.join("ebin")
  end

  defp collect(deadline, scan_options) do
    started = System.monotonic_time(:millisecond)
    loaded = :code.all_loaded()

    candidates =
      case Keyword.fetch(scan_options, :modules) do
        {:ok, only} -> Enum.filter(candidates(loaded), &(elem(&1, 0) in only))
        :error -> candidates(loaded)
      end

    reader = %{
      heap_words: Keyword.get(scan_options, :reader_heap_words, @max_worker_heap_words),
      hold: Keyword.get(scan_options, :hold_readers),
      deadline: deadline
    }

    stats = %{
      "loaded" => length(loaded),
      "candidates" => length(candidates),
      "scanned" => 0,
      "calling_telemetry" => 0,
      "without_debug_info" => 0,
      "stale" => 0,
      "unreadable" => 0,
      "too_large" => 0,
      "unsupported_names" => 0,
      "walk_truncated" => 0,
      "sources_dropped" => 0
    }

    acc =
      handlers(%{names: %{}, capped: MapSet.new(), dropped: 0, deadline: false, stats: stats})

    # A reader that met the deadline sets `acc.deadline`, which ends the
    # scan even when it was the last module.
    acc =
      candidates
      |> Enum.take(@max_modules)
      |> Enum.reduce_while(acc, fn {module, file}, acc ->
        cond do
          acc.deadline -> {:halt, acc}
          System.monotonic_time(:millisecond) >= deadline -> {:halt, %{acc | deadline: true}}
          true -> {:cont, read_module(module, file, bump(acc, "scanned"), reader)}
        end
      end)

    truncated_by =
      for {reason, true} <- [
            {"deadline", acc.deadline},
            {"modules", length(candidates) > @max_modules},
            {"names", acc.dropped > 0},
            {"too_large", acc.stats["too_large"] > 0},
            {"walk", acc.stats["walk_truncated"] > 0},
            {"sources", acc.stats["sources_dropped"] > 0}
          ],
          do: reason

    %{
      names:
        Map.new(acc.names, fn {name, sources} ->
          {Enum.map(name, &Atom.to_string/1),
           %{
             sources: Enum.sort_by(sources, &{&1["source"], &1["module"]}),
             truncated: MapSet.member?(acc.capped, name)
           }}
        end),
      stats: acc.stats,
      truncated_by: truncated_by,
      elapsed_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp handlers(acc) do
    if function_exported?(:telemetry, :list_handlers, 1),
      do: Enum.reduce(:telemetry.list_handlers([]), acc, &handler/2),
      else: acc
  catch
    _kind, _reason -> acc
  end

  defp handler(%{event_name: name, function: function}, acc) when is_function(function) do
    case Function.info(function, :module) do
      {:module, @insider_handler} -> acc
      {:module, module} -> add(acc, name, "handler", module)
    end
  end

  defp handler(_handler, acc), do: acc

  defp read_module(module, file, acc, reader) do
    with {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(file),
         :ok <- within(size, @max_file_bytes),
         {:ok, binary} <- File.read(file),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(binary, [:imports]) do
      if Enum.any?(imports, &(&1 in @telemetry_calls)),
        do: read_calls(module, binary, bump(acc, "calling_telemetry"), reader),
        else: acc
    else
      :too_large -> bump(acc, "too_large")
      _unreadable -> bump(acc, "unreadable")
    end
  end

  defp within(size, max) when size <= max, do: :ok
  defp within(_size, _max), do: :too_large

  defp read_calls(module, binary, acc, reader) do
    with true <- same_code?(module, binary),
         {:ok, {_module, [{~c"Dbgi", chunk}]}} when is_binary(chunk) <-
           :beam_lib.chunks(binary, [~c"Dbgi"], [:allow_missing_chunks]),
         :ok <- within(byte_size(chunk), @max_debug_info_bytes) do
      chunk |> read_debug_info(reader) |> merge(module, acc)
    else
      false -> bump(acc, "stale")
      :too_large -> bump(acc, "too_large")
      _missing -> bump(acc, "without_debug_info")
    end
  end

  defp same_code?(module, binary) do
    loaded = :erlang.get_module_info(module, :md5)
    match?({:ok, {_module, ^loaded}}, :beam_lib.md5(binary))
  rescue
    _error -> false
  end

  # Each module's debug info is decoded and walked in its own reader under
  # the heap guard, so a chunk that decodes to a huge term costs that module
  # (`too_large`) and not the scan. The reader replies with the calls it
  # found, at most `@max_names`, and whether a bound cut its walk.
  defp read_debug_info(chunk, reader) do
    reply_to = :erlang.alias([:explicit_unalias])

    {pid, monitor} =
      :erlang.spawn_opt(fn -> answer(reply_to, chunk, reader.hold) end, [
        :monitor,
        {:max_heap_size,
         %{
           size: reader.heap_words,
           kill: true,
           include_shared_binaries: true,
           error_logger: false
         }}
      ])

    receive do
      {^reply_to, result} ->
        Process.demonitor(monitor, [:flush])
        true = :erlang.unalias(reply_to)
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        true = :erlang.unalias(reply_to)
        :too_large
    after
      max(reader.deadline - System.monotonic_time(:millisecond), 0) ->
        true = :erlang.unalias(reply_to)
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :deadline
    end
  end

  defp merge({:ok, calls, truncated}, module, acc) do
    acc = if truncated, do: bump(acc, "walk_truncated"), else: acc

    Enum.reduce(calls, acc, fn
      {:execute, name}, acc ->
        add(acc, name, "execute", module)

      {:span, prefix}, acc ->
        Enum.reduce(@span_suffixes, acc, &add(&2, prefix ++ [&1], "span", module))
    end)
  end

  defp merge(:without_debug_info, _module, acc), do: bump(acc, "without_debug_info")
  defp merge(:too_large, _module, acc), do: bump(acc, "too_large")
  # The module's names were not read; the scan stops here.
  defp merge(:deadline, _module, acc), do: %{acc | deadline: true}

  defp answer(reply_to, chunk, nil), do: send(reply_to, {reply_to, decode_and_walk(chunk)})

  defp answer(reply_to, chunk, hold) do
    send(hold, {:insider_discovery_reader, self()})

    receive do
      :insider_discovery_release -> answer(reply_to, chunk, nil)
    end
  end

  # Only the two known backends' data shapes are read; the backend module
  # named in the chunk is never called.
  defp decode_and_walk(chunk) do
    # Reviewed (scanners flag "binary_to_term can lead to RCE"): the chunk is the
    # debug-info chunk of a module already loaded in this node, read from its
    # own `.beam` only when the file's MD5 matches the loaded code, at most
    # 2 MiB, decoded in a separate process with a heap limit and a deadline,
    # in dev/test/ci only. Writing a `.beam` into the code path already runs
    # code, so this adds no capability. The result is walked as data.
    # nosec
    case :erlang.binary_to_term(chunk) do
      {:debug_info_v1, :elixir_erl, {:elixir_v1, %{definitions: definitions}, _specs}} ->
        walk([definitions], :elixir, [], 0, @max_nodes_per_module)

      {:debug_info_v1, :erl_abstract_code, {forms, _options}} when is_list(forms) ->
        walk([forms], :erlang, [], 0, @max_nodes_per_module)

      _other ->
        :without_debug_info
    end
  rescue
    _error -> :without_debug_info
  end

  # A bounded, iterative walk: every node is matched as a call, and every
  # tuple, list, and map is descended. Running out of node budget, or
  # finding more than `@max_names` calls, is reported as truncated.
  defp walk([], _dialect, calls, _found, _budget), do: {:ok, calls, false}
  defp walk(_stack, _dialect, calls, _found, 0), do: {:ok, calls, true}
  defp walk(_stack, _dialect, calls, @max_names, _budget), do: {:ok, calls, true}

  defp walk([term | stack], dialect, calls, found, budget) do
    {calls, found} =
      case call(term, dialect) do
        {:ok, function, name} -> {[{function, name} | calls], found + 1}
        :error -> {calls, found}
      end

    walk(children(term, stack), dialect, calls, found, budget - 1)
  end

  defp children(term, stack) when is_tuple(term), do: Tuple.to_list(term) ++ stack
  defp children([head | tail], stack), do: [head, tail | stack]
  defp children(term, stack) when is_map(term), do: Map.values(term) ++ stack
  defp children(_term, stack), do: stack

  # Elixir: `{{:., _, [:telemetry, function]}, _, [event | _]}`.
  defp call({{:., _dot, [:telemetry, function]}, _meta, [event | _arguments]}, :elixir)
       when function in [:execute, :span] do
    if atom_list?(event), do: {:ok, function, event}, else: :error
  end

  # Erlang: `{call, _, {remote, _, {atom, _, telemetry}, {atom, _, F}}, [Event | _]}`.
  defp call(
         {:call, _anno, {:remote, _remote, {:atom, _, :telemetry}, {:atom, _, function}},
          [event | _arguments]},
         :erlang
       )
       when function in [:execute, :span] do
    case cons_atoms(event, []) do
      {:ok, name} -> {:ok, function, name}
      :error -> :error
    end
  end

  defp call(_term, _dialect), do: :error

  defp atom_list?([atom]) when is_atom(atom), do: true
  defp atom_list?([atom | rest]) when is_atom(atom), do: atom_list?(rest)
  defp atom_list?(_term), do: false

  defp cons_atoms({nil, _anno}, [_ | _] = atoms), do: {:ok, Enum.reverse(atoms)}

  defp cons_atoms({:cons, _anno, {:atom, _, atom}, tail}, atoms),
    do: cons_atoms(tail, [atom | atoms])

  defp cons_atoms(_term, _atoms), do: :error

  # At most `@max_names` names and `@max_sources` sources per name. A name
  # beyond the bound, or a source beyond a name's bound, is counted. A name
  # that could not be subscribed to (not a list of at most eight
  # lowercase-identifier atoms) is counted as unsupported.
  defp add(%{names: names} = acc, name, source, module) do
    entry = %{"source" => source, "module" => module_name(module)}

    cond do
      not subscribable?(name) ->
        bump(acc, "unsupported_names")

      is_map_key(names, name) ->
        add_source(acc, name, entry)

      map_size(names) < @max_names ->
        %{acc | names: Map.put(names, name, [entry])}

      true ->
        %{acc | dropped: acc.dropped + 1}
    end
  end

  defp add_source(acc, name, entry) do
    sources = Map.fetch!(acc.names, name)

    cond do
      entry in sources ->
        acc

      length(sources) < @max_sources ->
        %{acc | names: Map.put(acc.names, name, sources ++ [entry])}

      true ->
        bump(%{acc | capped: MapSet.put(acc.capped, name)}, "sources_dropped")
    end
  end

  defp subscribable?(name) do
    Value.bounded_list?(name, @max_segments) and name != [] and
      Enum.all?(name, &(is_atom(&1) and segment?(Atom.to_string(&1))))
  end

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  defp bump(acc, key), do: %{acc | stats: Map.update!(acc.stats, key, &(&1 + 1))}
end
