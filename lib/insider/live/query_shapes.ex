defmodule Insider.Live.QueryShapes do
  @moduledoc false

  # The repeated query shapes of one request: its Ecto queries grouped by
  # source table and normalised statement, never by parameters. A trace shows
  # each run of sibling queries apart, so a reader with the spans in hand
  # can still blame the wrong repeated query. A grouped count such as
  # "order_items ×26" names the worst one.
  #
  # Pure, over disclosed entries of one trace (or of a window, per trace):
  #
  # - a query span is an `otel.span` whose name ends in `.query:TABLE`
  #   (OpentelemetryEcto) or that carries `source` or `db.statement`
  #   attributes (rich only); a query event is a Telemetry event of a repo's
  #   `query` kind (`APP.repo.query`), its metadata (rich only) giving
  #   `source`, `query`, and Ecto's `stacktrace`;
  # - a trace's groups count its query spans when it has any, else its query
  #   events, so a query recorded both ways counts once (`counted_from`);
  # - the shape is a hash of the statement with every literal and `$N`
  #   parameter replaced, whitespace folded, and IN lists folded; without a
  #   statement (strict) the table alone is the shape;
  # - the caller is the first application frame of Ecto's stacktrace (the
  #   repo's `stacktrace: true`), from any query event of the same table and
  #   shape in the trace; else the query spans' parent span; else unknown,
  #   and the line says which.

  @min_repeats 2
  @max_groups 5
  @skip_prefixes ~w(Ecto. DBConnection. Postgrex. MyXQL. Exqlite. Absinthe. Dataloader. Task. Stream. Enum. Kernel. Process. Agent. GenServer.)
  @skip_modules ~w(Enum Stream Kernel Task Process Agent GenServer Map List Keyword)

  @doc """
  The query groups of one trace's entries that repeat, the most repeated
  first, at most @max_groups.
  """
  @spec repeated([map()]) :: [map()]
  def repeated(entries), do: entries |> groups() |> repeats(@min_repeats)

  @doc """
  Per trace in `entries`, its groups repeated `threshold` times or more, the
  trace with the most repeated group first.
  """
  @spec per_trace([map()], pos_integer()) :: [map()]
  def per_trace(entries, threshold) do
    entries
    |> Enum.group_by(&trace_id(&1["event"] || %{}))
    |> Enum.reject(fn {trace_id, _entries} -> is_nil(trace_id) end)
    |> Enum.flat_map(fn {trace_id, entries} ->
      # Only a known shape is evidence that one statement repeated.
      case entries |> groups() |> Enum.reject(&is_nil(&1["shape"])) |> repeats(threshold) do
        [] -> []
        groups -> [%{"trace_id" => trace_id, "groups" => groups}]
      end
    end)
    |> Enum.sort_by(fn %{"groups" => [top | _], "trace_id" => trace_id} ->
      {-top["count"], trace_id}
    end)
  end

  defp repeats(groups, threshold) do
    groups
    |> Enum.filter(&(&1["count"] >= threshold))
    |> Enum.sort_by(&{-&1["count"], -&1["total_us"], &1["source"]})
    |> Enum.take(@max_groups)
    |> label()
  end

  # The table alone names a group, unless the table has several shapes.
  defp label(groups) do
    shapes = Enum.frequencies_by(groups, & &1["source"])

    Enum.map(groups, fn group ->
      label =
        cond do
          is_nil(group["shape"]) -> "#{group["source"]} (shape unknown)"
          shapes[group["source"]] > 1 -> "#{group["source"]} (shape #{group["shape"]})"
          true -> group["source"]
        end

      Map.put(group, "label", label)
    end)
  end

  defp groups(entries) do
    events = Enum.map(entries, &(&1["event"] || %{}))
    names = for %{"source" => "otel"} = e <- events, into: %{}, do: {span_id(e), span_name(e)}
    queries = events |> Enum.flat_map(&query/1) |> Enum.reject(&is_nil(&1.source))
    {spans, query_events} = Enum.split_with(queries, &(&1.kind == :span))
    callers = callers(query_events)

    {counted, counted_from} =
      if spans != [], do: {spans, "spans"}, else: {query_events, "repo query events"}

    counted
    |> Enum.group_by(&{&1.source, &1.shape})
    |> Enum.map(fn {{source, shape}, queries} ->
      {from, from_kind} = caller(callers, source, shape, queries, names)

      %{
        "source" => source,
        "shape" => shape,
        "count" => length(queries),
        "total_us" => queries |> Enum.map(& &1.us) |> Enum.sum(),
        "from" => from,
        "from_kind" => from_kind,
        "counted_from" => counted_from
      }
    end)
  end

  # Only a repo query event of the same table and shape names a caller;
  # else the queries' parent span; else none.
  defp caller(callers, source, shape, queries, names) do
    cond do
      from = shape && callers[{source, shape}] ->
        {from, "stacktrace"}

      parent = queries |> Enum.map(&names[&1.parent]) |> Enum.find(&is_binary/1) ->
        {parent, "parent_span"}

      true ->
        {nil, nil}
    end
  end

  # The first application frame of each query event's stacktrace, by table
  # and shape, and by table alone.
  defp callers(query_events) do
    Enum.reduce(query_events, %{}, fn query, acc ->
      case query.from do
        nil ->
          acc

        from ->
          Map.put_new(acc, {query.source, query.shape}, from)
      end
    end)
  end

  defp query(%{"source" => "otel", "kind" => "otel.span", "attributes" => %{} = a} = event) do
    span_attributes = span_attributes(event)
    name = a["name"]

    source =
      text(span_attributes["source"]) || text(span_attributes["db.sql.table"]) || table(name)

    statement = text(span_attributes["db.statement"])

    if source && (table(name) || statement || span_attributes["source"]) do
      [
        %{
          kind: :span,
          source: source,
          shape: shape(statement),
          us: integer(a["duration_us"]),
          parent: a["parent_span_id"],
          from: nil
        }
      ]
    else
      []
    end
  end

  defp query(%{"source" => "telemetry", "kind" => kind} = event) when is_binary(kind) do
    metadata = get_in(event, ["payload", "metadata"])
    metadata = if is_map(metadata), do: metadata, else: %{}

    if String.ends_with?(kind, "repo.query") do
      [
        %{
          kind: :event,
          source: text(metadata["source"]),
          shape: shape(text(metadata["query"])),
          us: event_us(event),
          parent: nil,
          from: frame(metadata["stacktrace"])
        }
      ]
    else
      []
    end
  end

  defp query(_event), do: []

  defp span_attributes(event) do
    case get_in(event, ["payload", "span_attributes"]) do
      %{} = attributes -> attributes
      _none -> %{}
    end
  end

  defp table(name) when is_binary(name) do
    case Regex.run(~r/\.query:([A-Za-z0-9_."]+)\z/, name) do
      [_, table] -> table
      _none -> nil
    end
  end

  defp table(_name), do: nil

  defp event_us(event) do
    durations = get_in(event, ["attributes", "durations_us"]) || %{}

    Enum.find_value(["total_time", "query_time", "duration"], 0, fn key ->
      if is_integer(durations[key]), do: durations[key]
    end)
  end

  @doc """
  A statement's shape: a hash of it with every literal and parameter
  replaced (`normalize/1`), or `nil` when it cannot be read whole.
  """
  @spec shape(String.t() | nil) :: String.t() | nil
  def shape(nil), do: nil

  def shape(statement) do
    case normalize(statement) do
      {:ok, normal} ->
        :crypto.hash(:sha256, normal) |> Base.encode16(case: :lower) |> binary_part(0, 8)

      :error ->
        nil
    end
  end

  @max_statement 16_384

  defguardp is_word(byte)
            when is_integer(byte) and
                   (byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_ or byte == ?$ or
                      byte == ?")

  @doc """
  A statement with every literal replaced by `?`: quoted strings (with `''`
  and, in `E'…'`, backslash escapes), dollar-quoted strings, numbers
  (decimal, exponent, hexadecimal, signed), `TRUE`, `FALSE`, `NULL`, and
  `$N` parameters; comments dropped and whitespace folded; a list of
  literals, an `ARRAY[…]` of them, and a run of `VALUES` rows folded to one.
  An unterminated string, quoted identifier, or comment, a statement cut
  by a renderer (`…`), and one over @max_statement bytes give `:error`, so
  no remaining literal text is ever hashed.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | :error
  def normalize(statement) when is_binary(statement) and byte_size(statement) <= @max_statement do
    if String.contains?(statement, "…") do
      :error
    else
      with {:ok, tokens} <- scan(statement, nil, []) do
        {:ok,
         tokens
         |> Enum.reverse()
         |> IO.iodata_to_binary()
         |> String.replace(
           ~r/((?:^|[=<>(,]|\b(?:THEN|ELSE|AND|OR|WHEN|SELECT|RETURNING|LIMIT|OFFSET))\s*)[-+]\s*\?/i,
           "\\1?"
         )
         |> fold(~r/\(\s*\?(?:\s*,\s*\?)*\s*\)/, "(?)")
         |> fold(~r/\[\s*\?(?:\s*,\s*\?)*\s*\]/, "[?]")
         |> fold(~r/\(\?\)(?:\s*,\s*\(\?\))+/, "(?)")
         |> String.trim()}
      end
    end
  end

  def normalize(_statement), do: :error

  defp fold(text, pattern, replacement), do: String.replace(text, pattern, replacement)

  # One pass over the bytes; `previous` is the last byte emitted, so a word
  # or a number is told from part of an identifier.
  defp scan(<<>>, _previous, acc), do: {:ok, acc}

  defp scan(<<"--", rest::binary>>, previous, acc) do
    case :binary.split(rest, "\n") do
      [_comment, after_comment] -> scan(after_comment, previous, [" " | acc])
      [_comment] -> {:ok, acc}
    end
  end

  defp scan(<<"/*", rest::binary>>, previous, acc) do
    case :binary.split(rest, "*/") do
      [_comment, after_comment] -> scan(after_comment, previous, [" " | acc])
      [_unterminated] -> :error
    end
  end

  defp scan(<<quote, rest::binary>>, _previous, acc) when quote == ?' do
    with {:ok, after_string} <- quoted(rest, false), do: scan(after_string, ??, ["?" | acc])
  end

  defp scan(<<e, ?', rest::binary>>, previous, acc)
       when e in [?E, ?e] and not is_word(previous) do
    with {:ok, after_string} <- quoted(rest, true), do: scan(after_string, ??, ["?" | acc])
  end

  defp scan(<<?$, rest::binary>> = text, _previous, acc) do
    cond do
      match = Regex.run(~r/\A\d+/, rest) ->
        [digits] = match

        scan(binary_part(rest, byte_size(digits), byte_size(rest) - byte_size(digits)), ??, [
          "?" | acc
        ])

      match = Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)?\$/, rest) ->
        [opener | _] = match
        tag = "$" <> opener
        body = binary_part(text, byte_size(tag), byte_size(text) - byte_size(tag))

        case :binary.split(body, tag) do
          [_string, after_string] -> scan(after_string, ??, ["?" | acc])
          [_unterminated] -> :error
        end

      true ->
        scan(rest, ?$, ["$" | acc])
    end
  end

  defp scan(<<?", rest::binary>>, _previous, acc) do
    with {:ok, identifier, after_identifier} <- identifier(rest, []),
         do: scan(after_identifier, ?", [[?", identifier, ?"] | acc])
  end

  defp scan(<<char, _rest::binary>> = text, previous, acc)
       when char in ?0..?9 and not is_word(previous) do
    [number] = Regex.run(~r/\A(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)/, text)

    scan(binary_part(text, byte_size(number), byte_size(text) - byte_size(number)), ??, [
      "?" | acc
    ])
  end

  defp scan(<<?., char, _rest::binary>> = text, previous, acc)
       when char in ?0..?9 and not is_word(previous) do
    [number] = Regex.run(~r/\A\.\d+(?:[eE][-+]?\d+)?/, text)

    scan(binary_part(text, byte_size(number), byte_size(text) - byte_size(number)), ??, [
      "?" | acc
    ])
  end

  defp scan(<<char, _rest::binary>> = text, _previous, acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    [word] = Regex.run(~r/\A[A-Za-z_][A-Za-z0-9_$]*/, text)
    rest = binary_part(text, byte_size(word), byte_size(text) - byte_size(word))

    if String.upcase(word) in ["TRUE", "FALSE", "NULL"],
      do: scan(rest, ??, ["?" | acc]),
      else: scan(rest, ?a, [word | acc])
  end

  defp scan(<<char, rest::binary>>, previous, acc) when char in [?\s, ?\t, ?\n, ?\r] do
    case acc do
      [" " | _] -> scan(rest, previous, acc)
      _other -> scan(rest, ?\s, [" " | acc])
    end
  end

  defp scan(<<char, rest::binary>>, _previous, acc), do: scan(rest, char, [<<char>> | acc])

  # A string's body after its opening quote: `''` is a quote, and with
  # escapes (E'…') a backslash escapes the next byte.
  defp quoted(<<"''", rest::binary>>, escapes?), do: quoted(rest, escapes?)
  defp quoted(<<?', rest::binary>>, _escapes?), do: {:ok, rest}
  defp quoted(<<?\\, _escaped, rest::binary>>, true), do: quoted(rest, true)
  defp quoted(<<_char, rest::binary>>, escapes?), do: quoted(rest, escapes?)
  defp quoted(<<>>, _escapes?), do: :error

  defp identifier(<<"\"\"", rest::binary>>, acc), do: identifier(rest, [~s("") | acc])

  defp identifier(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp identifier(<<char, rest::binary>>, acc), do: identifier(rest, [<<char>> | acc])
  defp identifier(<<>>, _acc), do: :error

  # Ecto's stacktrace as the rich profile renders it: each frame the
  # inspected `{Module, :fun, arity, location}` tuple.
  defp frame(frames) when is_list(frames) do
    Enum.find_value(frames, fn
      frame when is_binary(frame) ->
        case Regex.run(~r/\A\{([A-Z][A-Za-z0-9_.]*), :"?([^",]+?)"?, (\d+),/, frame) do
          [_, module, fun, arity] -> if app?(module, fun), do: "#{module}.#{fun}/#{arity}"
          _other -> nil
        end

      _other ->
        nil
    end)
  end

  defp frame(_frames), do: nil

  defp app?(module, fun) do
    not (module in @skip_modules or String.starts_with?(module, @skip_prefixes) or
           String.ends_with?(module, ".Repo") or String.contains?(module, ".Repo.") or
           String.starts_with?(fun, "-"))
  end

  @doc "Whether `event` is a query span or a repo query event, as `repeated/1` reads them."
  @spec query?(map()) :: boolean()
  def query?(event), do: query(event) != []

  @doc """
  How many query spans and repo query events of `entries` name no table
  (under strict a query event discloses none), so they are not grouped.
  """
  @spec ungrouped([map()]) :: non_neg_integer()
  def ungrouped(entries) do
    entries
    |> Enum.flat_map(&query(&1["event"] || %{}))
    |> Enum.count(&is_nil(&1.source))
  end

  @doc "A group as one line: `TABLE × N from CALLER, T ms total`."
  @spec line(map()) :: String.t()
  def line(group) do
    from =
      case group["from_kind"] do
        "stacktrace" -> " from #{group["from"]}"
        "parent_span" -> " from span #{inspect(group["from"])} (no repo stacktrace recorded)"
        _unknown -> " (caller unknown: no repo stacktrace or parent span recorded)"
      end

    "#{group["label"] || group["source"]} × #{group["count"]}#{from}, #{ms(group["total_us"])} total"
  end

  defp ms(us), do: "#{Float.round(us / 1_000, 1)} ms" |> String.replace(".0 ms", " ms")

  defp trace_id(%{"source" => "otel", "attributes" => %{"trace_id" => id}}), do: id
  defp trace_id(event), do: get_in(event, ["causality", "trace_id"])

  defp span_id(%{"attributes" => %{"span_id" => id}}), do: id
  defp span_id(_event), do: nil

  defp span_name(%{"attributes" => %{"name" => name}}) when is_binary(name), do: name
  defp span_name(_event), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0
end
