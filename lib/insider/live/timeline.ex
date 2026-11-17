defmodule Insider.Live.Timeline do
  @moduledoc false

  # Correlated timelines over a session's retained events, after they have
  # crossed the session's disclosure boundary (`Insider.Live.events_since/3`
  # reads them). Pure functions over the read result:
  #
  # - `trace/2`: the span tree of one trace id merged in time order with the
  #   Logger and Telemetry events of the same trace. An event without a trace
  #   id joins when the process that emitted it ended one of the trace's
  #   spans and its time falls inside that span (plus `@slack_us`, for an
  #   event emitted as the span ends); it is placed under the shortest such
  #   span.
  # - `pid/2` and `request/2`: every source's events for one process, or for
  #   one request (its request id, then its processes within the request's
  #   time window, then the traces it belongs to).
  #
  # Every result says what it could not join, how much it scanned, and the
  # gaps of the reads, and it is bounded by `"limit"` items and `"max_bytes"`
  # canonical JSON bytes.

  alias Insider.Collector.GraphqlOutcome
  alias Insider.Collector.RequestTiming
  alias Insider.Event.Canonical
  alias Insider.Live.Marks
  alias Insider.Live.Options
  alias Insider.Live.QueryShapes

  @slack_us 1_000
  @wait_shown_us 100_000
  @missing_max 16

  @doc "The slack after a span's end within which an event still joins it."
  @spec slack_us() :: pos_integer()
  def slack_us, do: @slack_us

  @doc """
  A new scan accumulator. `add/2` folds in one `events_since/3` batch.
  """
  @spec scan(String.t()) :: map()
  def scan(session_id),
    do: %{
      session_id: session_id,
      entries: [],
      gaps: %{},
      first: nil,
      last: nil,
      reads: 0,
      upper: nil,
      unread: 0,
      retention: nil
    }

  @values_max 200
  @value_bytes 160

  @doc """
  Adds the events per-trace retention kept (`Insider.Live.Retention`),
  already through the disclosure boundary, that the scan did not read:
  the Recorder evicted them. `info` is what retention says of the trace,
  or `nil` when it keeps nothing.
  """
  @spec retained(map(), [map()], map() | nil) :: map()
  def retained(scan, entries, info) do
    seen = MapSet.new(scan.entries, & &1["receipt"])
    restored = Enum.reject(entries, &MapSet.member?(seen, &1["receipt"]))
    retention = info && Map.put(info, "restored", length(restored))
    %{scan | entries: Enum.reverse(restored, scan.entries), retention: retention}
  end

  @doc "The events the Recorder evicted within the receipts the scan read."
  @spec evicted(map()) :: non_neg_integer()
  def evicted(scan), do: Map.get(scan.gaps, {"evicted", "receipt_range"}) || 0

  # A scan's reads (`Insider.Live.TimelineScan.request/3`) report
  # cumulative losses as totals since the session started, whatever cursor
  # they start at, so the scan keeps the largest total it observed (counts
  # only grow). Receipt-range losses of different reads cover different
  # receipts and add up. A `since_cursor_issued` count is a delta against a
  # reader's baseline, not a total; it is never compared with one, and makes
  # that loss's count unknown.
  @spec add(map(), map()) :: map()
  def add(scan, batch) do
    gaps =
      Enum.reduce(batch["gaps"], scan.gaps, fn gap, gaps ->
        case gap["scope"] do
          "receipt_range" ->
            merge(gaps, {gap["reason"], "receipt_range"}, gap["count"], &(&1 + &2))

          "since_cursor_issued" ->
            Map.put(gaps, {gap["reason"], "since_session_start"}, nil)

          scope ->
            merge(gaps, {gap["reason"], scope}, gap["count"], &max/2)
        end
      end)

    %{
      scan
      | entries: Enum.reverse(batch["events"], scan.entries),
        gaps: gaps,
        first: min(scan.first || batch["cursor"], batch["cursor"]),
        last: max(scan.last || 0, batch["next_cursor"]),
        reads: scan.reads + 1
    }
  end

  @oban_args_chars 400

  @doc """
  The trace result (`insider.live-trace/v1`) for `trace_id` in `scan`.
  `ending` is `nil` when the scan reached the newest receipt, else what
  ended it early.
  """
  @spec trace(map(), map()) :: map()
  def trace(scan, %{trace_id: trace_id} = options) do
    entries = scan.entries |> Enum.reverse() |> RequestTiming.annotate() |> Enum.map(&describe/1)

    spans =
      for entry <- entries,
          entry.span,
          entry.trace_id == trace_id,
          into: %{},
          do: {entry.span.span_id, entry}

    {joined, unplaced} =
      entries
      |> Enum.reject(& &1.span)
      |> Enum.flat_map(&join_trace(&1, trace_id, spans))
      |> Enum.split_with(&(elem(&1, 0).at_us != nil))

    hide = Map.get(options, :hide, [])

    hidden =
      for {span_id, entry} <- spans, category(entry.event, hide), into: MapSet.new(), do: span_id

    # A hidden span's children and events hang from its nearest shown
    # ancestor; depths count shown ancestors only.
    span_nodes =
      Enum.map(spans, fn {span_id, entry} ->
        {item(entry, "trace_id", span_id, 0), anchor(entry.span.parent_span_id, spans, hidden)}
      end)

    event_nodes =
      Enum.map(joined ++ unplaced, fn {entry, joined_by, span_id} ->
        {item(entry, joined_by, span_id, 0), anchor(span_id, spans, hidden)}
      end)

    {omitted_nodes, nodes} =
      Enum.split_with(span_nodes ++ event_nodes, fn {item, _parent} ->
        category(item["event"], hide) != nil
      end)

    nodes =
      Enum.map(nodes, fn {item, parent} ->
        depth = if parent, do: min(shown_depth(parent, spans, hidden, 0) + 1, 64), else: 0
        {%{item | "depth" => depth}, parent}
      end)

    {items, truncation} = bound(order(Enum.map(nodes, &elem(&1, 0))), options)
    {tree, collapsed} = tree(nodes, Map.get(options, :collapse, []))

    missing =
      spans
      |> Map.values()
      |> Enum.map(& &1.span.parent_span_id)
      |> Enum.filter(&(&1 != nil and not Map.has_key?(spans, &1)))
      |> Enum.uniq()
      |> Enum.sort()

    roots =
      for {span_id, entry} <- spans,
          is_nil(entry.span.parent_span_id) or not Map.has_key?(spans, entry.span.parent_span_id),
          do: span_id

    result =
      %{
        "schema" => "insider.live-trace/v1",
        "session_id" => scan.session_id,
        "trace_id" => trace_id,
        "spans" => map_size(spans),
        "root_span_ids" => Enum.sort(roots),
        "joined" => %{
          "trace_id" => Enum.count(joined ++ unplaced, &(elem(&1, 1) == "trace_id")),
          "pid_window" => Enum.count(joined ++ unplaced, &(elem(&1, 1) == "pid_window"))
        },
        "items" => items,
        # Its Ecto queries repeated by table and statement shape, over the
        # whole request (`Insider.Live.QueryShapes`), what `hide` removed
        # left out.
        "repeated_queries" =>
          spans
          |> Map.values()
          |> Kernel.++(Enum.map(joined ++ unplaced, &elem(&1, 0)))
          |> Enum.reject(&category(&1.event, hide))
          |> Enum.map(& &1.entry)
          |> QueryShapes.repeated(),
        # Query events that name no table (strict) cannot be grouped.
        "repeated_queries_ungrouped" =>
          (joined ++ unplaced) |> Enum.map(&elem(&1, 0).entry) |> QueryShapes.ungrouped(),
        "unjoined" => %{
          "missing_parent_span_ids" => Enum.take(missing, @missing_max),
          "missing_parents" => length(missing),
          "events_without_time" => length(unplaced),
          "spans_without_process" => Enum.count(Map.values(spans), &is_nil(&1.pid)),
          "note" =>
            "a missing parent was not captured (another service, before the session, evicted, or filtered); " <>
              "an event without a time is listed last; an event without a process or trace id cannot join by window"
        },
        "window_slack_us" => @slack_us,
        "omitted" => %{
          "hidden" => counts(Enum.map(omitted_nodes, &category(elem(&1, 0)["event"], hide))),
          "collapsed" => collapsed
        },
        "retention" =>
          Map.put(
            scan.retention ||
              %{
                "pinned" => nil,
                "events" => 0,
                "restored" => 0,
                "lost" => 0,
                "missed_receipts" => 0
              },
            "hint",
            Map.get(options, :hint)
          )
      }
      |> Map.merge(truncation)
      |> Map.merge(scan_report(scan, options))
      |> then(fn result ->
        if Map.get(options, :values),
          do:
            Map.put(
              result,
              "values",
              joined
              |> Kernel.++(unplaced)
              # What `hide` removed from the items gives no values either.
              |> Enum.reject(&category(elem(&1, 0).event, hide))
              |> values(options)
              |> Map.put(
                "view_hidden",
                scan |> Map.get(:view_hidden, %{}) |> Map.values() |> Enum.sum()
              )
            ),
          else: result
      end)

    if Map.get(options, :human),
      do: Map.put(result, "text", tree_text(result, tree, options)),
      else: result
  end

  @doc """
  The timeline (`insider.live-timeline/v1`) of one process (`pid`) or one
  request (`request_id`).
  """
  @spec timeline(map(), map()) :: map()
  def timeline(scan, options) do
    entries = scan.entries |> Enum.reverse() |> RequestTiming.annotate() |> Enum.map(&describe/1)

    {subject, joined, details} =
      case options do
        %{pid: pid} -> {%{"pid" => pid}, by_pid(entries, pid), %{}}
        %{request_id: request_id} -> by_request(entries, request_id)
      end

    items = Enum.map(joined, fn {entry, joined_by} -> item(entry, joined_by, nil, 0) end)
    {placed, unplaced} = Enum.split_with(items, &(&1["at_us"] != nil))
    {items, truncation} = bound(order(placed) ++ unplaced, options)

    trace_ids =
      joined
      |> Enum.map(fn {entry, _joined_by} -> entry.trace_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    pids =
      joined
      |> Enum.map(fn {entry, _joined_by} -> entry.pid end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    result =
      %{
        "schema" => "insider.live-timeline/v1",
        "session_id" => scan.session_id,
        "subject" => subject,
        "items" => items,
        "pids" => pids,
        "trace_ids" => Enum.take(trace_ids, @missing_max),
        "unjoined" => %{
          "events_without_time" => length(unplaced),
          "note" =>
            "events without a process subject (strict Logger events) join only by request or trace id; " <>
              "follow a listed trace id with trace"
        }
      }
      |> Map.merge(details)
      |> Map.merge(truncation)
      |> Map.merge(scan_report(scan, options))
      |> put_mark(Map.get(options, :mark))

    if Map.get(options, :human), do: Map.put(result, "text", text(result)), else: result
  end

  # --- joining ----------------------------------------------------------

  defp join_trace(entry, trace_id, spans) do
    cond do
      entry.trace_id == trace_id ->
        span_id =
          if Map.has_key?(spans, entry.span_id),
            do: entry.span_id,
            else: enclosing(entry, spans)

        [{entry, "trace_id", span_id}]

      is_nil(entry.trace_id) and entry.pid != nil and entry.at_us != nil ->
        case enclosing(entry, spans) do
          nil -> []
          span_id -> [{entry, "pid_window", span_id}]
        end

      true ->
        []
    end
  end

  # The shortest span ended by the entry's process whose time covers it;
  # the slack after a span's end applies only when no span covers it.
  defp enclosing(%{pid: nil}, _spans), do: nil
  defp enclosing(%{at_us: nil}, _spans), do: nil

  defp enclosing(entry, spans) do
    own = spans |> Map.values() |> Enum.filter(&(&1.pid == entry.pid and &1.span.start_us != nil))

    (shortest_cover(own, entry.at_us, 0) || shortest_cover(own, entry.at_us, @slack_us))
    |> case do
      nil -> nil
      span -> span.span.span_id
    end
  end

  defp shortest_cover(spans, at_us, slack) do
    spans
    |> Enum.filter(fn %{span: span} ->
      at_us >= span.start_us and at_us <= span.start_us + span.duration_us + slack
    end)
    |> Enum.min_by(& &1.span.duration_us, fn -> nil end)
  end

  # The nearest shown span at or above `span_id`, bounded against a
  # malformed cycle.
  defp anchor(span_id, spans, hidden, steps \\ 0)
  defp anchor(nil, _spans, _hidden, _steps), do: nil
  defp anchor(_span_id, _spans, _hidden, 64), do: nil

  defp anchor(span_id, spans, hidden, steps) do
    case Map.get(spans, span_id) do
      nil ->
        nil

      entry ->
        if MapSet.member?(hidden, span_id),
          do: anchor(entry.span.parent_span_id, spans, hidden, steps + 1),
          else: span_id
    end
  end

  # How many shown spans are above the shown span `span_id`, bounded at 64
  # against a malformed cycle.
  defp shown_depth(_span_id, _spans, _hidden, 64), do: 64

  defp shown_depth(span_id, spans, hidden, depth) do
    case anchor(Map.fetch!(spans, span_id).span.parent_span_id, spans, hidden) do
      nil -> depth
      parent -> shown_depth(parent, spans, hidden, depth + 1)
    end
  end

  # --- collapse and hide --------------------------------------------------

  # The first rule an item matches: `sql` (a database span or query event),
  # `auth` (authorization or authentication), or any other text as a prefix
  # of the span name or event kind.
  defp category(_event, []), do: nil

  defp category(event, rules) do
    name = name(event)
    Enum.find(rules, &matches?(&1, event, name))
  end

  defp name(%{"source" => "otel", "attributes" => %{"name" => name}}) when is_binary(name),
    do: name

  defp name(%{"source" => "logger"}), do: nil
  defp name(%{"kind" => kind}) when is_binary(kind), do: kind
  defp name(_event), do: nil

  defp matches?(_rule, _event, nil), do: false

  defp matches?("sql", event, name) do
    String.contains?(name, "repo.query") or
      String.match?(name, ~r/\A(SELECT|INSERT|UPDATE|DELETE|WITH|BEGIN|COMMIT)\b/i) or
      Enum.any?(["db.system", "db.statement"], &is_map_key(span_attributes(event), &1))
  end

  defp matches?("auth", _event, name) do
    name = String.downcase(name)

    String.contains?(name, ["authoriz", "authenticat"]) or String.starts_with?(name, "auth.") or
      String.starts_with?(name, "auth ")
  end

  defp matches?(prefix, _event, name), do: String.starts_with?(name, prefix)

  defp span_attributes(%{"payload" => %{"span_attributes" => %{} = attributes}}), do: attributes
  defp span_attributes(_event), do: %{}

  defp counts(categories) do
    categories |> Enum.reject(&is_nil/1) |> Enum.frequencies()
  end

  defp by_pid(entries, pid) do
    for entry <- entries, entry.pid == pid, do: {entry, "pid"}
  end

  # A request's seeds carry its id. Its processes, within the seeds' time
  # window, add every source's events; its traces add their spans and
  # events.
  defp by_request(entries, request_id) do
    seeds = Enum.filter(entries, &request?(&1, request_id))
    pids = seeds |> Enum.map(& &1.pid) |> Enum.reject(&is_nil/1) |> MapSet.new()
    traces = seeds |> Enum.map(& &1.trace_id) |> Enum.reject(&is_nil/1) |> MapSet.new()
    times = Enum.flat_map(seeds, &span_of/1)

    window =
      if times == [],
        do: nil,
        else: {Enum.min(Enum.map(times, &elem(&1, 0))), Enum.max(Enum.map(times, &elem(&1, 1)))}

    joined =
      Enum.flat_map(entries, fn entry ->
        cond do
          request?(entry, request_id) ->
            [{entry, "request_id"}]

          entry.trace_id != nil and MapSet.member?(traces, entry.trace_id) ->
            [{entry, "trace_id"}]

          in_window?(entry, pids, window) ->
            [{entry, "pid_window"}]

          true ->
            []
        end
      end)

    details = %{
      "window" =>
        case window do
          nil -> nil
          {from, to} -> %{"from" => iso(from), "to" => iso(to), "slack_us" => @slack_us}
        end,
      "seeds" => length(seeds)
    }

    {%{"request_id" => request_id}, joined, details}
  end

  defp in_window?(_entry, _pids, nil), do: false

  defp in_window?(entry, pids, {from, to}) do
    entry.pid != nil and MapSet.member?(pids, entry.pid) and entry.at_us != nil and
      entry.at_us >= from - @slack_us and entry.at_us <= to + @slack_us
  end

  # The time an entry covers: a span or a timed Telemetry event covers its
  # duration up to its time.
  defp span_of(%{at_us: nil}), do: []

  defp span_of(%{span: %{start_us: start, duration_us: duration}}),
    do: [{start, start + duration}]

  defp span_of(%{at_us: at, duration_us: duration}) when is_integer(duration),
    do: [{at - duration, at}]

  defp span_of(%{at_us: at}), do: [{at, at}]

  # Plug's request id: Logger metadata `request_id`, or the `x-request-id`
  # header of a rendered conn in Telemetry metadata.
  defp request?(%{event: event}, request_id) do
    metadata = get_in(event, ["payload", "metadata"]) || %{}

    metadata["request_id"] == request_id or
      header?(get_in(metadata, ["conn", "resp_headers"]), request_id) or
      header?(get_in(metadata, ["conn", "req_headers"]), request_id)
  rescue
    _error -> false
  end

  defp header?(headers, request_id) when is_list(headers) do
    Enum.any?(headers, fn
      [name, value] -> name == "x-request-id" and value == request_id
      # The rich renderer writes a header tuple as its inspect text; only
      # that exact text for this name and value matches.
      text when is_binary(text) -> text == inspect({"x-request-id", request_id})
      _other -> false
    end)
  end

  defp header?(_headers, _request_id), do: false

  # --- items ------------------------------------------------------------

  defp describe(entry) do
    event = entry["event"] || %{}
    attributes = event["attributes"] || %{}
    causality = event["causality"] || %{}
    span? = event["source"] == "otel" and event["kind"] == "otel.span"
    wall = micros(event["wall_time"])

    span =
      if span? do
        duration = attributes["duration_us"]
        start = micros(attributes["start_wall_time"])

        %{
          span_id: attributes["span_id"],
          parent_span_id: attributes["parent_span_id"],
          start_us: start,
          duration_us: if(is_integer(duration), do: duration, else: 0)
        }
      end

    %{
      entry: entry,
      event: event,
      span: span,
      trace_id: if(span?, do: attributes["trace_id"], else: causality["trace_id"]),
      span_id: causality["span_id"],
      pid: process(event["subject"]),
      at_us: if(span?, do: span.start_us, else: wall),
      duration_us: duration_us(event)
    }
  end

  defp process(%{"namespace" => "process", "value" => value}) when is_binary(value), do: value
  defp process(_subject), do: nil

  # A Telemetry event's own duration (native units), when disclosed.
  defp duration_us(%{"source" => "telemetry", "attributes" => %{"measurements" => measurements}})
       when is_map(measurements) do
    case measurements["duration"] || measurements["total_time"] do
      native when is_integer(native) and native >= 0 ->
        System.convert_time_unit(native, :native, :microsecond)

      _other ->
        nil
    end
  end

  defp duration_us(_event), do: nil

  defp item(described, joined_by, span_id, depth) do
    %{
      "at" => described.at_us && iso(described.at_us),
      "at_us" => described.at_us,
      "receipt" => described.entry["receipt"],
      "joined_by" => joined_by,
      "span_id" => span_id,
      "depth" => depth,
      "event" => described.event,
      "redactions" => described.entry["redactions"] || []
    }
  end

  # Time order; a parent span before an event or child at the same time.
  defp order(items) do
    {timed, untimed} = Enum.split_with(items, &(&1["at_us"] != nil))
    Enum.sort_by(timed, &{&1["at_us"], &1["depth"], &1["receipt"]}) ++ untimed
  end

  defp bound(items, options) do
    {kept, bytes, reason} =
      Enum.reduce_while(items, {[], 0, nil}, fn item, {kept, bytes, _reason} ->
        size = byte_size(Canonical.encode(item))

        cond do
          length(kept) >= options.limit -> {:halt, {kept, bytes, "limit"}}
          kept != [] and bytes + size > options.max_bytes -> {:halt, {kept, bytes, "max_bytes"}}
          true -> {:cont, {[item | kept], bytes + size, nil}}
        end
      end)

    _bytes = bytes

    {Enum.reverse(kept),
     %{
       "truncated" => reason != nil,
       "truncated_by" => reason,
       "omitted_items" => length(items) - length(kept)
     }}
  end

  @doc "What a scan read, and its gaps (`scan_truncated` for receipts its budget left unread)."
  @spec scan_report(map(), map()) :: map()
  def scan_report(scan, options) do
    unread = Map.get(scan, :unread, 0)

    %{
      "scan" => %{
        "cursor" => scan.first || 0,
        "next_cursor" => scan.last || 0,
        "direction" => "newest_first",
        "reads" => scan.reads,
        "examined" => length(scan.entries),
        "unread" => unread,
        "complete" => is_nil(Map.get(options, :ending)),
        "ended_by" => Map.get(options, :ending)
      },
      "gaps" => gaps(scan.gaps) ++ truncated(unread)
    }
  end

  # Per-page cumulative counts collapse to their largest; an unknown count
  # stays unknown.
  defp gaps(gaps) do
    gaps
    |> Enum.map(fn {{reason, scope}, count} ->
      %{"reason" => reason, "scope" => scope, "count" => count}
    end)
    |> Enum.sort_by(&{&1["reason"], &1["scope"]})
  end

  # An unknown count stays unknown.
  defp merge(gaps, key, count, combine) do
    Map.update(gaps, key, count, fn
      nil -> nil
      previous -> if is_nil(count), do: nil, else: combine.(previous, count)
    end)
  end

  # Receipts the scan did not read: what it found is not all there is.
  defp truncated(0), do: []

  defp truncated(unread),
    do: [%{"reason" => "scan_truncated", "scope" => "receipt_range", "count" => unread}]

  # --- tree -------------------------------------------------------------

  # The rows of a trace's tree from `{item, parent span id}` nodes: roots
  # (no shown parent) first, each span followed by its children. A run of
  # siblings in one `collapse` category is one row that counts the run and
  # everything under it. Nodes no root reaches (a malformed parent cycle)
  # follow in time order.
  defp tree(nodes, collapse) do
    indexed = Enum.with_index(nodes, fn {item, parent}, index -> {item, parent, index} end)

    children =
      indexed
      |> Enum.group_by(&elem(&1, 1), fn {item, _parent, index} -> {item, index} end)
      |> Map.new(fn {parent, members} -> {parent, sorted(members)} end)

    {rows, seen, collapsed} =
      walk(Map.get(children, nil, []), children, collapse, 0, {[], %{}, %{}})

    rest =
      for {item, _parent, index} <- indexed, not is_map_key(seen, index), do: {item, index}

    rows =
      Enum.reverse(rows) ++
        Enum.map(sorted(rest), fn {item, _i} -> {:item, item["depth"], item} end)

    {rows, collapsed}
  end

  defp walk(siblings, children, collapse, level, acc) do
    siblings
    |> Enum.chunk_by(fn {item, index} -> category(item["event"], collapse) || {:own, index} end)
    |> Enum.reduce(acc, fn chunk, {rows, seen, collapsed} ->
      [{first, _index} | _rest] = chunk

      case category(first["event"], collapse) do
        nil ->
          seen = Map.put(seen, elem(hd(chunk), 1), true)
          rows = [{:item, level, first} | rows]

          if span_item?(first) and level < 64,
            do:
              walk(
                Map.get(children, first["span_id"], []),
                children,
                collapse,
                level + 1,
                {rows, seen, collapsed}
              ),
            else: {rows, seen, collapsed}

        category ->
          folded = Enum.flat_map(chunk, &subtree(&1, children, 0))
          seen = Enum.reduce(folded, seen, &Map.put(&2, &1, true))
          run = Enum.map(chunk, &elem(&1, 0))
          count = length(folded)

          {[{:collapsed, level, category, run, count} | rows], seen,
           Map.update(collapsed, category, count, &(&1 + count))}
      end
    end)
  end

  # The indexes of a node and every node under it.
  defp subtree({item, index}, children, depth) do
    below =
      if span_item?(item) and depth < 64,
        do:
          Enum.flat_map(Map.get(children, item["span_id"], []), &subtree(&1, children, depth + 1)),
        else: []

    [index | below]
  end

  defp span_item?(%{
         "joined_by" => "trace_id",
         "event" => %{"source" => "otel", "kind" => "otel.span"}
       }),
       do: true

  defp span_item?(_item), do: false

  defp sorted(members) do
    {timed, untimed} = Enum.split_with(members, &(elem(&1, 0)["at_us"] != nil))

    Enum.sort_by(timed, fn {item, index} -> {item["at_us"], item["receipt"], index} end) ++
      untimed
  end

  # --- text -------------------------------------------------------------

  defp text(%{"subject" => subject} = result) do
    start = Enum.find_value(result["items"], & &1["at_us"])
    [{key, value}] = Map.to_list(subject)

    header =
      "#{key} #{value}: #{length(result["items"])} items, pids #{Enum.join(result["pids"], " ")}"

    lines =
      Enum.map(result["items"], fn item ->
        offset =
          if item["at_us"] && start,
            do: :io_lib.format("+~.3fms", [(item["at_us"] - start) / 1_000]) |> to_string(),
            else: "?"

        String.duplicate("  ", min(item["depth"], 16)) <> offset <> " " <> line(item["event"])
      end)

    footer =
      if result["truncated"],
        do: [more_line(result["omitted_items"], result["truncated_by"])],
        else: []

    since =
      if result["mark"],
        do: [
          "Since " <>
            String.replace_prefix(Marks.since_text(result["mark"]), "since ", "") <>
            ": only what came after it"
        ],
        else: []

    Enum.join([header | since] ++ status_lines(result) ++ lines ++ footer, "\n")
  end

  # A timeline since a pairing mark names it (`Insider.Live.Marks`).
  defp put_mark(result, nil), do: result
  defp put_mark(result, mark), do: Map.put(result, "mark", Marks.describe(mark))

  # A trace's text is its span tree: each span's children and events under
  # it in time order, a run of siblings in one `collapse` category folded
  # into one counted line, and at most `limit` lines and `max_bytes` bytes.
  defp tree_text(result, rows, options) do
    start =
      rows
      |> Enum.flat_map(fn
        {:item, _level, item} -> [item["at_us"]]
        {:collapsed, _level, _category, run, _count} -> Enum.map(run, & &1["at_us"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    header =
      Enum.join(
        [
          "trace #{result["trace_id"]}: #{result["spans"]} spans, #{length(result["items"])} items" <>
            missing_text(result["unjoined"]) <> omitted_text(result["omitted"])
          | status_lines(result)
        ],
        "\n"
      )

    # The repeated-queries block comes first and counts toward max_bytes.
    {repeated, used} =
      repeated_lines(result["repeated_queries"], options.max_bytes - byte_size(header))

    {lines, _bytes} =
      Enum.reduce_while(rows, {[], byte_size(header) + used}, fn row, {lines, bytes} ->
        line = row_line(row, start)
        size = byte_size(line) + 1

        if length(lines) >= options.limit or bytes + size > options.max_bytes,
          do: {:halt, {lines, bytes}},
          else: {:cont, {[line | lines], bytes + size}}
      end)

    more = length(rows) - length(lines)

    footer =
      cond do
        more == 0 -> []
        length(lines) >= options.limit -> [more_line(more, "limit")]
        true -> [more_line(more, "max_bytes")]
      end

    Enum.join(
      [header | retention_lines(result["retention"], evicted_count(result))] ++
        repeated ++
        Enum.reverse(lines) ++ footer ++ values_lines(result["values"], start),
      "\n"
    )
  end

  # Within `budget` bytes, a line saying how many groups it left out.
  defp repeated_lines([_ | _] = groups, budget) do
    head = "Repeated queries in this request (by table and statement shape, never parameters):"
    lines = Enum.map(groups, &("  " <> QueryShapes.line(&1)))

    {kept, used} =
      Enum.reduce_while(lines, {[], byte_size(head) + 1}, fn line, {kept, used} ->
        size = byte_size(line) + 1

        if used + size > budget - 48,
          do: {:halt, {kept, used}},
          else: {:cont, {[line | kept], used + size}}
      end)

    left = length(lines) - length(kept)

    cond do
      kept == [] and byte_size(head) + 1 > budget ->
        {[], 0}

      left > 0 ->
        more =
          "  … #{left} more repeated #{if left == 1, do: "group", else: "groups"} (max_bytes)"

        {[head | Enum.reverse(kept)] ++ [more], used + byte_size(more) + 1}

      true ->
        {[head | Enum.reverse(kept)], used}
    end
  end

  defp repeated_lines(_groups, _budget), do: {[], 0}

  defp evicted_count(result) do
    case Enum.find(result["gaps"] || [], &(&1["reason"] == "evicted")) do
      %{"count" => count} when is_integer(count) -> count
      _none -> 0
    end
  end

  # What retention kept of the trace, or, the first time a trace it does
  # not keep is read after an eviction, how to keep one.
  defp retention_lines(%{"pinned" => nil, "hint" => hint}, evicted) when is_binary(hint) do
    [
      "Hint: the Recorder evicted #{evicted} events in the receipts read, so this trace may have lost some; " <>
        hint <> "."
    ]
  end

  defp retention_lines(%{"pinned" => pinned} = retention, _evicted) when is_binary(pinned) do
    how =
      case pinned do
        "explicit" -> "pinned with --retain"
        "mutation" -> "kept because it ran a GraphQL mutation"
        _auto -> "kept by --retain-traces"
      end

    kept =
      case retention do
        %{"events" => 0} ->
          "no events kept yet (the Recorder held none of them); later ones are kept"

        %{"events" => events, "restored" => 0} ->
          "#{events} events kept"

        %{"events" => events, "restored" => restored} ->
          "#{events} events kept, #{restored} of them restored after the Recorder evicted them"
      end

    losses =
      [
        retention["lost"] > 0 && "#{retention["lost"]} dropped by the retention bound",
        retention["missed_receipts"] > 0 &&
          "#{retention["missed_receipts"]} receipts were evicted before retention could copy them, " <>
            "and some may have been this trace's"
      ]
      |> Enum.filter(&is_binary/1)

    ["Retained: #{how}; #{kept}" <> Enum.map_join(losses, "", &("; " <> &1)) <> "."]
  end

  defp retention_lines(_retention, _evicted), do: []

  # --- values ---------------------------------------------------------

  # The response data of the trace's GraphQL operations: each Absinthe
  # operation stop the trace joined that carries `graphql_data` (recorded
  # only under the rich profile, credential-masked and bounded by
  # `Insider.Collector.Rich`), flattened to path = value fields, at most
  # @values_max in all, each value at most @value_bytes when encoded.
  defp values(joined, options) do
    patterns = Enum.map(Map.get(options, :values_paths, []), &glob/1)

    # The response data, and a mutation's inputs under `arguments.`.
    operations =
      for {entry, _joined_by, _span_id} <- joined,
          %{"graphql_data" => data} = payload <- [get_in(entry.event, ["payload"])],
          not is_nil(data) or is_map(payload["graphql_arguments"]),
          do:
            {entry,
             %{"arguments" => payload["graphql_arguments"]}
             |> Map.reject(fn {_key, value} -> is_nil(value) end)
             |> Map.merge(if(is_map(data), do: data, else: %{}))}

    {operations, _left} =
      operations
      |> Enum.sort_by(fn {entry, _data} -> {entry.at_us || 0, entry.entry["receipt"]} end)
      |> Enum.map_reduce(@values_max, fn {entry, data}, left ->
        fields =
          data
          |> flatten("", [])
          |> Enum.reverse()
          |> Enum.filter(fn {path, _value} ->
            patterns == [] or Enum.any?(patterns, &Regex.match?(&1, path))
          end)

        {shown, omitted} = Enum.split(fields, left)
        graphql = get_in(entry.event, ["attributes", "graphql"]) || %{}

        operation =
          [graphql["operation_type"], graphql["operation_name"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        {%{
           "receipt" => entry.entry["receipt"],
           "at_us" => entry.at_us,
           "operation" => if(operation == "", do: entry.event["kind"], else: operation),
           "fields" => Enum.map(shown, fn {path, value} -> bounded_field(path, value) end),
           "omitted_fields" => length(omitted)
         }, left - length(shown)}
      end)

    %{
      "operations" => operations,
      "fields_max" => @values_max,
      "paths" => Map.get(options, :values_paths, []),
      "note" =>
        "rich profile only: response data as recorded, credential-masked, at most 32 entries per map or " <>
          "list and 5 levels deep (Insider.Collector.Rich); paths use the response's keys; a mutation's inputs " <>
          "are under arguments.FIELD.ARGUMENT, by schema names"
    }
  end

  defp flatten(%{} = map, prefix, acc) when map_size(map) > 0 do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(acc, fn {key, value}, acc -> flatten(value, join_path(prefix, key), acc) end)
  end

  defp flatten([_ | _] = list, prefix, acc) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, acc -> flatten(value, "#{prefix}[#{index}]", acc) end)
  end

  defp flatten(value, prefix, acc), do: [{prefix, value} | acc]

  defp join_path("", key), do: to_string(key)
  defp join_path(prefix, key), do: prefix <> "." <> to_string(key)

  defp glob(pattern) do
    pattern
    |> String.split("*")
    |> Enum.map_join(".*", &Regex.escape/1)
    |> then(&Regex.compile!("\\A" <> &1 <> "\\z"))
  end

  defp values_lines(nil, _start), do: []

  defp values_lines(%{"operations" => [], "view_hidden" => hidden}, _start) when hidden > 0 do
    [
      "Values: none shown: this read's view hid #{hidden} events, and the operation stops may be among them; " <>
        "read with --view-clear (or a view that keeps absinthe.execute.operation.stop)."
    ]
  end

  defp values_lines(%{"operations" => []} = values, _start) do
    filtered = if values["paths"] == [], do: "", else: " matching the paths given"

    [
      "Values: no GraphQL response data#{filtered} in this trace; it is recorded on " <>
        "absinthe.execute.operation.stop events (the telemetry component, a quiet default when Absinthe is " <>
        "loaded) under the rich profile."
    ]
  end

  defp values_lines(%{"operations" => operations}, start) do
    lines =
      Enum.flat_map(operations, fn operation ->
        head =
          "  #{offset(operation["at_us"], start)} #{operation["operation"]} (receipt #{operation["receipt"]})"

        fields =
          Enum.map(operation["fields"], fn %{"path" => path, "value" => value} ->
            "    #{path} = #{value_text(value)}"
          end)

        more =
          if operation["omitted_fields"] > 0,
            do: ["    … #{operation["omitted_fields"]} more fields (values limit #{@values_max})"],
            else: []

        [head | fields] ++ more
      end)

    ["Values (rich profile, credential-masked):" | lines]
  end

  defp value_text(value), do: Jason.encode!(value)

  # A value is at most @value_bytes of JSON, in the result as in the text: a
  # longer string is cut at a character boundary and ends in `…`, any other
  # longer value is replaced by a marker, and the field says it was cut.
  defp bounded_field(path, value) do
    if byte_size(Jason.encode!(value)) <= @value_bytes do
      %{"path" => path, "value" => value}
    else
      %{"path" => path, "value" => cut_value(value), "truncated" => true}
    end
  end

  defp cut_value(text) when is_binary(text) do
    # Two quotes and the three bytes of `…`.
    budget = @value_bytes - 5

    text
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn codepoint, {kept, bytes} ->
      size = byte_size(Jason.encode!(codepoint)) - 2

      if bytes + size <= budget,
        do: {:cont, {[codepoint | kept], bytes + size}},
        else: {:halt, {kept, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
    |> Kernel.<>("…")
  end

  defp cut_value(_value), do: "[WITHHELD:value_bytes]"

  defp row_line({:item, level, item}, start),
    do: indent(level) <> offset(item["at_us"], start) <> " " <> line(item["event"])

  defp row_line({:collapsed, level, category, run, count}, start) do
    spans = Enum.filter(run, &span_item?/1)
    total = spans |> Enum.map(&(&1["event"]["attributes"]["duration_us"] || 0)) |> Enum.sum()

    names =
      run
      |> Enum.map(&(name(&1["event"]) || "?"))
      |> Enum.with_index()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {_name, at} -> {-length(at), hd(at)} end)

    shown =
      names
      |> Enum.take(3)
      |> Enum.map_join(", ", fn
        {name, [_one]} -> name
        {name, at} -> "#{name} ×#{length(at)}"
      end)

    shown = if match?([_, _, _, _ | _], names), do: shown <> ", …", else: shown

    indent(level) <>
      offset(hd(run)["at_us"], start) <>
      " … #{count} #{category} (#{count_spans(count, run, spans)}, #{ms(total)}): #{shown}"
  end

  defp count_spans(count, run, spans) when count == length(run), do: plural(length(spans), "span")

  defp count_spans(count, run, spans),
    do: "#{plural(length(spans), "span")}, #{count - length(run)} under them"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp indent(level), do: String.duplicate("  ", min(level, 16))

  defp offset(at_us, start) when is_integer(at_us) and is_integer(start),
    do: :io_lib.format("+~.3fms", [(at_us - start) / 1_000]) |> to_string()

  defp offset(_at_us, _start), do: "?"

  defp omitted_text(%{"hidden" => hidden, "collapsed" => collapsed}),
    do: omitted_text("hidden", hidden) <> omitted_text("collapsed", collapsed)

  defp omitted_text(_label, counts) when counts == %{}, do: ""

  defp omitted_text(label, counts),
    do: "; #{label} " <> Enum.map_join(Enum.sort(counts), ", ", fn {c, n} -> "#{c} #{n}" end)

  # An eviction says why and what keeps a trace. A bare
  # `Lost: evicted 2102` does not say either.
  defp evicted_cause(gaps) do
    if Enum.any?(gaps, &(&1["reason"] == "evicted" and &1["count"] != 0)),
      do:
        ". Evicted: the Recorder was full and dropped its oldest events; trace --retain keeps a trace from now on",
      else: ""
  end

  # What a bound cut, and the flag that raises it, so output cut
  # at a default bound says how to get the rest.
  defp more_line(more, "limit"),
    do: "… #{more} more: cut at --limit; raise it (up to #{Options.correlated_bounds().limit})"

  defp more_line(more, "max_bytes"),
    do:
      "… #{more} more: cut at --max-bytes; raise it (up to #{Options.correlated_bounds().max_bytes})"

  defp more_line(more, bound), do: "… #{more} more (#{bound})"

  # The read's losses and an unfinished scan, which `--human` would
  # otherwise hide: they come before any item and outside the line bound.
  defp status_lines(result) do
    lost =
      case result["gaps"] do
        [_ | _] = gaps ->
          [
            "Lost: " <>
              Enum.map_join(gaps, ", ", fn gap ->
                "#{gap["reason"]} #{gap["count"] || "unknown"} (#{gap["scope"]})"
              end) <> evicted_cause(gaps)
          ]

        _none ->
          []
      end

    incomplete =
      case result["scan"] do
        %{"complete" => false} = scan ->
          unread =
            case scan["unread"] do
              count when is_integer(count) and count > 0 ->
                "; #{count} older receipts unread (the scan reads newest first)"

              _none ->
                ""
            end

          ["Incomplete scan: ended by #{scan["ended_by"]}" <> unread]

        _complete ->
          []
      end

    lost ++ incomplete ++ wait_lines(result["items"])
  end

  defp missing_text(%{"missing_parents" => 0}), do: ""
  defp missing_text(%{"missing_parents" => count}), do: ", #{count} missing parent spans"

  defp line(%{"source" => "otel", "attributes" => attributes} = event) do
    status = if attributes["status"] == "error", do: " ERROR", else: ""
    service = if attributes["service"], do: " (#{attributes["service"]})", else: ""

    # The span's name already names the operation.
    outcome =
      case attributes["graphql"] do
        %{} = graphql -> outcome(Map.drop(graphql, ["operation_type", "operation_name"]))
        _none -> ""
      end

    "span #{attributes["name"]} #{attributes["span_kind"]} " <>
      "#{ms(attributes["duration_us"])}#{status}#{service}#{outcome}#{oban_span(event)}"
  end

  defp line(%{"source" => "logger"} = event) do
    message = get_in(event, ["payload", "message"]) || event["kind"]
    "log #{event["severity"]} #{cut(message)}"
  end

  defp line(%{"source" => source} = event) do
    duration =
      case duration_us(event) do
        nil -> ""
        us -> " " <> ms(us)
      end

    outcome =
      case get_in(event, ["attributes", "graphql"]) do
        %{} = graphql -> outcome(graphql)
        _none -> ""
      end

    "#{source} #{event["kind"]}#{duration} #{event["severity"]}#{request_wait(event)}#{outcome}" <>
      oban_job(event)
  end

  defp line(_event), do: "event"

  # An Oban job's span (OpentelemetryOban, rich only): its worker, queue, and
  # attempt; the args are on the job's `oban.job.*` events.
  defp oban_span(event) do
    case get_in(event, ["payload", "span_attributes"]) do
      %{"oban.job.worker" => worker} = attributes ->
        attempt =
          [attributes["oban.job.attempt"], attributes["oban.job.max_attempts"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("/")

        [
          "worker=#{worker}",
          attributes["messaging.destination.name"] &&
            "queue=#{attributes["messaging.destination.name"]}",
          attempt != "" && "attempt=#{attempt}"
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.map_join(&(" " <> &1))

      _none ->
        ""
    end
  end

  # An Oban job event's job (`Insider.Collector.ObanJob`): its worker,
  # queue, attempt, state, and its args as JSON (decoded and masked, rich
  # only, at most @oban_args_chars characters), else their keys.
  defp oban_job(%{"attributes" => %{"oban" => %{} = job}} = event) do
    attempt =
      case {job["attempt"], job["max_attempts"]} do
        {nil, _max} -> nil
        {attempt, nil} -> "#{attempt}"
        {attempt, max} -> "#{attempt}/#{max}"
      end

    args =
      case get_in(event, ["payload", "oban_args"]) do
        nil ->
          if job["args_keys"] in [nil, []],
            do: nil,
            else: "args_keys=[#{Enum.join(job["args_keys"], ",")}]"

        args ->
          "args=" <> cut_chars(Jason.encode!(args), @oban_args_chars)
      end

    [
      job["worker"] && "worker=#{job["worker"]}",
      job["queue"] && "queue=#{job["queue"]}",
      attempt && "attempt=#{attempt}",
      job["state"] && "state=#{job["state"]}",
      args
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join(&(" " <> &1))
  end

  defp oban_job(_event), do: ""

  defp cut_chars(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # The requests in the result that waited @wait_shown_us or more before
  # Phoenix's endpoint telemetry began (`Insider.Collector.RequestTiming`),
  # the longest first, at most three lines.
  defp wait_lines(items) do
    waits =
      for %{"event" => %{"attributes" => %{"request" => %{"wait_us" => wait} = request}}} <-
            items || [],
          is_integer(wait) and wait >= @wait_shown_us,
          do: request

    {shown, rest} = waits |> Enum.sort_by(&(-&1["wait_us"])) |> Enum.split(3)

    Enum.map(shown, fn request ->
      "Wait: #{RequestTiming.describe(request)} waited #{RequestTiming.duration(request["wait_us"])} " <>
        "before Phoenix's endpoint telemetry began, of #{RequestTiming.duration(request["total_us"])} in all " <>
        "(in dev the code reloader and the plugs before Plug.Telemetry run there)."
    end) ++
      if(rest == [], do: [], else: ["Wait: #{length(rest)} more requests waited 100 ms or more."])
  end

  defp request_wait(%{"attributes" => %{"request" => %{"wait_us" => wait}}})
       when is_integer(wait),
       do: " waited #{RequestTiming.duration(wait)} before the endpoint"

  defp request_wait(_event), do: ""

  defp outcome(graphql) do
    case GraphqlOutcome.text(graphql) do
      "" -> ""
      text -> " " <> text
    end
  end

  defp ms(us) when is_integer(us), do: :io_lib.format("~.3fms", [us / 1_000]) |> to_string()
  defp ms(_us), do: "?"

  defp cut(text) when is_binary(text) and byte_size(text) > 160,
    do: String.slice(text, 0, 160) <> "…"

  defp cut(text) when is_binary(text), do: text
  defp cut(_text), do: ""

  defp micros(nil), do: nil

  defp micros(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, value, _offset} -> DateTime.to_unix(value, :microsecond)
      _error -> nil
    end
  end

  defp micros(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp micros(_value), do: nil

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
end
