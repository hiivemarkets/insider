defmodule Insider.Live.Digest do
  @moduledoc false

  # Folds the disclosed `insider.live-events/v1` batches of one window into
  # `insider.live-digest/v1`: what an agent would otherwise work out with
  # `jq` over every event. It reads only events as `events_since/3` returns
  # them, after the disclosure boundary, so a digest never shows more than a
  # read would.
  #
  # - `counts`: events by kind, severity, source, and supervisor offender.
  # - `crash_loops`: `supervisor_child_terminated` events grouped by offender
  #   and reason fingerprint, at least two, with the period between their
  #   wall times.
  # - `error_signatures`: error and critical events grouped by a signature
  #   built from code identifiers in the event (kind, offender, exception
  #   module, normalised message head), most frequent first.
  # - `latency`: Telemetry summaries per kind (their intervals) and recorded
  #   Telemetry durations per kind, slowest p95 first.
  # - `anomalies`: the findings to read first, ranked, each with the next
  #   command (`Insider.Live.Anomalies`); the text leads with them.
  # - `requests`: each request's wait before Phoenix's endpoint telemetry
  #   began (the slowest), and bursts of request arrivals with their sources
  #   and the requests they overlapped (`Insider.Collector.RequestTiming`).
  # - `processes`: the longest mailboxes the Poller's process evidence saw.
  # - `vm`: the first and last VM sample of the window and their deltas.
  # - `calls`: the traced functions' calls, returns and exceptions, with
  #   result durations, each failure (class and exception module) with the
  #   arguments of its first call as disclosed, and why a trace stopped.
  # - `filtered` and `gaps`: what the window's reads report as not recorded
  #   or lost.

  alias Insider.Collector.GraphqlOutcome
  alias Insider.Collector.RequestTiming
  alias Insider.Live.Anomalies
  alias Insider.Live.Changes
  alias Insider.Live.QueryShapes
  alias Insider.Collector.Logger.Template
  alias Insider.Live.Hints
  alias Insider.Live.Marks
  alias Insider.Live.Trends
  alias Insider.Live.Trends.Series

  @schema "insider.live-digest/v1"
  @top 10
  @intervals 12
  @signature_bytes 160
  @error_severities ["error", "critical"]
  # Request stop events kept for the request waits and bursts.
  @requests_max 8_192
  @changes_max 4_096
  @queries_max 8_192
  @span_names_max 8_192
  # One query shape repeated this many times in one request is an N+1.
  @n_plus_one 10
  @writes_max 1_024
  @timeout_us 4_900_000..5_100_000

  @opaque acc :: map()

  @doc "The digest schema id."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "An empty fold for a window that starts after receipt `since`."
  @spec new(String.t(), non_neg_integer(), Hints.context() | (-> Hints.context() | nil) | nil) ::
          acc()
  def new(session_id, since, context \\ nil) do
    %{
      session_id: session_id,
      since: since,
      upto: nil,
      next_cursor: since,
      reads: 0,
      batch: nil,
      events: 0,
      first_receipt: nil,
      last_receipt: nil,
      first_wall_us: nil,
      last_wall_us: nil,
      by_kind: %{},
      by_severity: %{},
      by_source: %{},
      by_offender: %{},
      terminations: %{},
      signatures: %{},
      summaries: %{},
      bursts: %{},
      durations: %{},
      call_timeouts: %{},
      logged_call_timeouts: 0,
      # The window's first @requests_max request stop events
      # (`Insider.Collector.RequestTiming`), newest first; all are counted.
      requests: [],
      requests_seen: 0,
      # Watched writes (at most @writes_max, all counted) and the events that
      # name their writers (at most @changes_max), newest first
      # (`Insider.Live.Changes`).
      changes: [],
      changes_seen: 0,
      writes: [],
      writes_seen: 0,
      # Ecto query spans and repo query events (at most @queries_max), and
      # the names of spans that may be their parents (at most @span_names_max),
      # for each request's repeated query shapes (`Insider.Live.QueryShapes`).
      queries: [],
      queries_seen: 0,
      span_names: %{},
      span_names_omitted: 0,
      vm: nil,
      mailboxes: %{},
      poller_series: Series.new(),
      calls: %{},
      calls_stopped: [],
      receipt_gaps: %{},
      first_gaps: [],
      unknown_gaps: MapSet.new(),
      filtered: nil,
      evidence: Hints.new(),
      context: context,
      # What the window was asked for; for a time window its start as a
      # wall time, and whether the search narrowed it exactly.
      window: {:cursor, since},
      from_us: nil,
      start_exact: true,
      # The pairing mark a window since a mark starts at.
      mark: nil
    }
  end

  @doc """
  Reads and folds one window through `reader`, the transport's
  `events_since` call: `reader.(cursor, read_options, budget_ms)` returns
  `{:ok, batch}` or `{:error, error}`. `since` is `{:cursor, n}` or
  `{:last, n}`, the newest n receipts. Every call, including the lookup of
  the newest receipt for `{:last, n}`, gets only what is left of the one
  budget that ends at `deadline` (monotonic milliseconds).

  The window ends at the newest receipt when the digest starts: the
  lookup's, or the first read's `next_receipt`. Events that arrive later
  are left for the next digest, even when a read returns them.
  """
  @spec read(
          String.t(),
          Insider.Live.Options.since() | {:mark, map()},
          function(),
          integer(),
          String.t(),
          Hints.context() | (-> Hints.context() | nil) | nil
        ) ::
          {:ok, map()} | {:error, map()}
  def read(session_id, since, reader, deadline, node_name, context \\ nil) do
    with {:ok, digest, _rows} <-
           read_window(session_id, since, reader, deadline, node_name, context),
         do: {:ok, digest}
  end

  @doc """
  Like `read/5`, and also returns the window's summary rows, oldest first:
  `summaries` by Telemetry kind and `bursts` by Logger template fingerprint,
  call site fingerprint, and level, for `Insider.Live.Trends`.
  """
  @spec read_window(
          String.t(),
          Insider.Live.Options.since() | {:mark, map()},
          function(),
          integer(),
          String.t(),
          Hints.context() | (-> Hints.context() | nil) | nil
        ) ::
          {:ok, map(),
           %{
             summaries: [{String.t(), [map()]}],
             bursts: [{tuple(), [map()]}],
             poller: %{series: [map()], untracked: map()}
           }}
          | {:error, map()}
  def read_window(session_id, since, reader, deadline, node_name, context \\ nil) do
    with {:ok, cursor, upto, from} <- start(since, reader, deadline),
         {:ok, acc, ending} <-
           session_id
           |> new(cursor, context)
           |> Map.merge(%{upto: upto, window: since})
           |> Map.merge(from)
           |> reads(reader, deadline) do
      {:ok, finish(acc, ending, node_name), rows(acc)}
    end
  end

  defp rows(acc) do
    %{
      summaries: Enum.map(acc.summaries, fn {kind, rows} -> {kind, Enum.reverse(rows)} end),
      bursts: Enum.map(acc.bursts, fn {key, rows} -> {key, Enum.reverse(rows)} end),
      poller: Series.rows(acc.poller_series)
    }
  end

  @read %{"max_bytes" => 1_048_576, "scan_limit" => 1_000}
  @read_limit 500
  @read_floor_ms 250
  @call_max_ms 5_000

  defp start({:cursor, cursor}, _reader, _deadline), do: {:ok, cursor, nil, %{}}

  # A pairing mark the caller found: the window starts after its receipt.
  defp start({:mark, %{"cursor" => cursor} = mark}, _reader, _deadline),
    do: {:ok, cursor, nil, %{mark: mark}}

  defp start(since, reader, deadline) do
    with {:ok, budget} <- budget(deadline),
         {:ok, %{"next_cursor" => newest}} <- reader.("latest", %{"limit" => 1}, budget) do
      case since do
        {:last, last} ->
          {:ok, max(newest - last, 0), newest, %{}}

        {:recent, ms} ->
          # The cutoff and its wall-time label are taken together, before
          # any probe, so the reported start is the one the search used.
          from_us = System.monotonic_time(:microsecond) - ms * 1_000
          from = System.os_time(:microsecond) - ms * 1_000

          with {:ok, cursor, exact} <- recent_start(reader, deadline, from_us, newest),
               do: {:ok, cursor, newest, %{from_us: from, start_exact: exact}}
      end
    else
      :spent -> {:error, Insider.Live.Error.new("timeout")}
      {:error, _error} = error -> error
    end
  end

  # A time window starts after the last receipt the Recorder admitted
  # before `from_us`. Admission times (the Recorder's monotonic clock, taken
  # with the receipt under its write lock, kept by the archive) follow
  # receipt order, so a binary search over cursors finds it; an event's own
  # wall time does not (a Logger call can pass its own time). Each probe
  # is the first disclosed event after a cursor with its admission time.
  #
  # The search keeps `low`, a cursor every receipt up to which is old (0 at
  # first), and `high`, the largest cursor that can still be the start (the
  # newest receipt at first); the start is `low` once they meet. Whether
  # cursor `m` can be the start is told by receipt `m` onward, so each step
  # probes the first disclosed event after `m - 1`, for `m` above `low`: an
  # old one raises `low` to its receipt, a recent one lowers `high` to
  # `m - 1`. A probe that met no disclosed event before its scan stopped
  # cannot tell, so it is taken as recent: the window may start earlier
  # than needed (`start_exact` false) but never drops a recent event. One
  # that read to the end found only withheld or no receipts, which the
  # window then keeps and reports as losses. A search the budget cannot
  # finish is a timeout, never a narrower window. The first step probes
  # from 0, so an evicted prefix is skipped at once.
  defp recent_start(reader, deadline, from_us, newest),
    do: search(reader, deadline, from_us, {0, newest}, true, 1)

  defp search(_reader, _deadline, _from_us, {low, high}, exact, _middle) when low >= high,
    do: {:ok, low, exact}

  defp search(reader, deadline, from_us, {low, high}, exact, middle) do
    bounds =
      case probe(reader, deadline, middle - 1, from_us) do
        {:old, receipt} -> {:ok, {min(receipt, high), high}, exact}
        {:recent, sure} -> {:ok, {low, middle - 1}, exact and sure}
        {:error, _error} = error -> error
      end

    case bounds do
      {:ok, {low, high}, exact} ->
        search(reader, deadline, from_us, {low, high}, exact, div(low + high + 1, 2))

      error ->
        error
    end
  end

  defp probe(reader, deadline, cursor, from_us) do
    with {:ok, budget} <- budget(deadline),
         {:ok, found} <- reader.(cursor, %{"probe" => true}, budget) do
      case found do
        %{"receipt" => receipt, "received_at_us" => at}
        when is_integer(receipt) and is_integer(at) and at < from_us ->
          {:old, receipt}

        %{"receipt" => receipt, "received_at_us" => at}
        when is_integer(receipt) and is_integer(at) ->
          {:recent, true}

        %{"receipt" => nil, "exhausted" => true} ->
          {:recent, true}

        _undecided ->
          {:recent, false}
      end
    else
      :spent -> {:error, Insider.Live.Error.new("timeout")}
      {:error, _error} = error -> error
    end
  end

  defp budget(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining >= @read_floor_ms -> {:ok, min(remaining, @call_max_ms)}
      _spent -> :spent
    end
  end

  # A failed first read is the result; after it, a failure, the deadline,
  # or a read that made no progress ends the window early and says so.
  # Every read after the window's end is known passes it as `"upto"`, so the
  # read itself stops there and counts its losses from the receipts up to it.
  defp reads(acc, reader, deadline) do
    cursor = acc.next_cursor
    options = read_options(acc.upto, cursor)

    with {:ok, budget} <- budget(deadline),
         {:ok, %{"next_cursor" => next} = batch} <- reader.(cursor, options, budget) do
      upto = acc.upto || batch["next_receipt"] || next

      # A read past the window cannot be split into what belongs to it.
      if next > upto,
        do: {:ok, acc, "read_past_window"},
        else: continue(add(%{acc | upto: upto}, batch), cursor, next, reader, deadline)
    else
      :spent when acc.reads == 0 -> {:error, Insider.Live.Error.new("timeout")}
      :spent -> {:ok, acc, "deadline"}
      {:error, _error} = error when acc.reads == 0 -> error
      {:error, %{"code" => code}} -> {:ok, acc, code}
    end
  end

  defp continue(acc, cursor, next, reader, deadline) do
    cond do
      acc.next_cursor >= acc.upto -> {:ok, acc, nil}
      next <= cursor -> {:ok, acc, "no_progress"}
      true -> reads(acc, reader, deadline)
    end
  end

  defp read_options(nil, _cursor), do: Map.put(@read, "limit", @read_limit)

  defp read_options(upto, cursor),
    do: Map.merge(@read, %{"limit" => max(min(@read_limit, upto - cursor), 1), "upto" => upto})

  @doc "Adds one batch of the window, in read order."
  @spec add(acc(), map()) :: acc()
  def add(acc, batch) do
    # Record-time filter counts are cumulative from the first read's
    # baseline; what the reader's view hid is counted per read, so it adds up.
    acc =
      cond do
        acc.reads == 0 ->
          %{acc | filtered: batch["filtered"], first_gaps: since_cursor(batch["gaps"])}

        is_map(acc.filtered) and is_map(batch["filtered"]) ->
          view = Insider.Live.View.add(acc.filtered["view"], batch["filtered"]["view"])
          %{acc | filtered: Map.put(acc.filtered, "view", view)}

        true ->
          acc
      end

    acc = Enum.reduce(batch["events"] || [], acc, &event/2)
    acc = Enum.reduce(batch["gaps"] || [], acc, &gap/2)
    next = max(batch["next_cursor"] || acc.next_cursor, acc.next_cursor)
    %{acc | reads: acc.reads + 1, batch: batch, next_cursor: next}
  end

  @doc """
  The digest. `ending` is `nil` when the window was read to its end, or
  what stopped it: `"deadline"`, `"no_progress"`, or an error code.
  """
  @spec finish(acc(), String.t() | nil, String.t()) :: map()
  def finish(acc, ending, node_name) do
    batch = acc.batch || %{}
    as_of_us = System.os_time(:microsecond)

    # Hints need the session's configuration; without it there are none. A
    # function is called only now, after the window's reads.
    context = if is_function(acc.context, 0), do: acc.context.(), else: acc.context
    # Writers whose request events were evicted are named by the session's
    # kept mutation records (`Insider.Live.Mutations`).
    kept = (context && context[:mutations]) || []

    digest = %{
      "schema" => @schema,
      "session_id" => acc.session_id,
      "node" => node_name,
      "state" => batch["state"],
      "lease_remaining_ms" => batch["lease_remaining_ms"],
      "disclosure_profile" => batch["disclosure_profile"],
      "window" => %{
        # What the window was asked for, when it starts for a time window
        # (and whether the search found that start exactly), when the
        # digest was made, and how old its newest event is then.
        "since" => since_label(acc.window),
        "from_wall_time" => iso(acc.from_us),
        "mark" => acc.mark && Marks.describe(acc.mark),
        "start_exact" => acc.start_exact,
        "as_of" => iso(as_of_us),
        "age_ms" => acc.last_wall_us && max(div(as_of_us - acc.last_wall_us, 1_000), 0),
        "cursor" => acc.since,
        "next_cursor" => acc.next_cursor,
        "upto" => acc.upto,
        "next_receipt" => batch["next_receipt"],
        "events" => acc.events,
        "reads" => acc.reads,
        "first_receipt" => acc.first_receipt,
        "last_receipt" => acc.last_receipt,
        "first_wall_time" => iso(acc.first_wall_us),
        "last_wall_time" => iso(acc.last_wall_us),
        "span_ms" => span_ms(acc.first_wall_us, acc.last_wall_us),
        "complete" => is_nil(ending),
        "stopped_by" => ending
      },
      "counts" => %{
        "by_kind" => acc.by_kind,
        "by_severity" => acc.by_severity,
        "by_source" => acc.by_source,
        "by_offender" => acc.by_offender
      },
      "crash_loops" => crash_loops(acc.terminations),
      "error_signatures" => signatures(acc.signatures),
      "latency" => latency(acc.summaries, acc.durations, acc.call_timeouts),
      "requests" =>
        acc.requests
        |> Enum.reverse()
        |> RequestTiming.summary()
        |> Map.put("examined", min(acc.requests_seen, @requests_max))
        |> Map.put("events", acc.requests_seen),
      "repeated_queries" =>
        acc.span_names
        |> Enum.map(fn {span_id, {trace_id, name}} ->
          %{
            "event" => %{
              "source" => "otel",
              "kind" => "otel.span",
              "attributes" => %{"trace_id" => trace_id, "span_id" => span_id, "name" => name}
            }
          }
        end)
        |> Kernel.++(Enum.reverse(acc.queries))
        |> QueryShapes.per_trace(@n_plus_one)
        |> Enum.take(@top),
      # What the repeated-query analysis read: past @queries_max query spans
      # and events, the rest are counted, not examined, and an N+1 among
      # them is not shown; past @span_names_max other spans, a query's
      # parent may go unnamed.
      "query_evidence" => %{
        "seen" => acc.queries_seen,
        "examined" => min(acc.queries_seen, @queries_max),
        "omitted" => max(acc.queries_seen - @queries_max, 0),
        "cap" => @queries_max,
        "span_names_omitted" => acc.span_names_omitted,
        "complete" => acc.queries_seen <= @queries_max
      },
      "changes" =>
        (acc.writes ++ acc.changes)
        |> Enum.reverse()
        |> Changes.of(mutations: kept)
        |> Changes.repeated(acc.writes_seen <= @writes_max),
      "trends" => rows(acc).summaries |> Trends.telemetry(@intervals) |> Enum.take(@top),
      "logger_bursts" => Trends.logger(rows(acc).bursts, @intervals),
      "logged_call_timeouts" => acc.logged_call_timeouts,
      "processes" => mailboxes(acc.mailboxes),
      "vm" => vm(acc.vm),
      "calls" => calls_summary(acc.calls, acc.calls_stopped),
      "call_candidates" => Hints.candidates(acc.evidence),
      "filtered" => acc.filtered,
      "gaps" => gaps(acc)
    }

    hints = if context, do: Hints.digest(digest, acc.evidence, context), else: []

    digest
    |> put_hints(hints)
    |> Map.put("anomalies", Anomalies.of(digest))
  end

  @doc """
  Puts `hints` in a digest, each with the window it was worked out over:
  `"window"` is `"since"`, `"first_receipt"`, and `"last_receipt"` of the
  digest's window.
  """
  @spec put_hints(map(), [map()]) :: map()
  def put_hints(digest, hints) do
    window = Map.take(digest["window"], ["since", "first_receipt", "last_receipt"])
    Map.put(digest, "hints", Enum.map(hints, &Map.put(&1, "window", window)))
  end

  # The window as `"since"` takes it: a cursor, `"latest-N"`, or
  # `"latest-DURATION"` in whole hours, else seconds, else milliseconds.
  defp since_label({:cursor, cursor}), do: cursor
  defp since_label({:mark, _mark}), do: "mark"
  defp since_label({:last, last}), do: "latest-#{last}"

  defp since_label({:recent, ms}) when rem(ms, 3_600_000) == 0,
    do: "latest-#{div(ms, 3_600_000)}h"

  defp since_label({:recent, ms}) when rem(ms, 1_000) == 0, do: "latest-#{div(ms, 1_000)}s"
  defp since_label({:recent, ms}), do: "latest-#{ms}ms"

  ## Events

  # A pairing mark is the agent's own note, not the application's activity:
  # the window names the mark it starts at, and no count includes marks.
  defp event(%{"event" => %{"source" => "live", "kind" => "live.mark"}}, acc), do: acc

  defp event(%{"receipt" => receipt, "event" => %{} = event}, acc) do
    wall_us = wall_us(event["wall_time"])
    kind = to_string(event["kind"])
    severity = to_string(event["severity"])

    acc = %{
      acc
      | events: acc.events + 1,
        first_receipt: acc.first_receipt || receipt,
        last_receipt: receipt,
        first_wall_us: earliest(acc.first_wall_us, wall_us),
        last_wall_us: latest(acc.last_wall_us, wall_us),
        by_kind: bump(acc.by_kind, kind),
        by_severity: bump(acc.by_severity, severity),
        by_source: bump(acc.by_source, to_string(event["source"]))
    }

    acc
    |> offender(event, receipt, wall_us)
    |> signature(event, receipt, wall_us)
    |> call_timeout(event)
    |> telemetry(event, wall_us)
    |> poller(event, wall_us)
    |> logger_burst(event, receipt)
    |> calls(event, receipt)
    |> Map.update!(:evidence, &Hints.add(&1, event, receipt))
    |> poller_series(event, wall_us)
    |> request(receipt, event)
    |> change(receipt, event)
    |> query_shape(receipt, event)
  end

  defp event(_entry, acc), do: acc

  # A query span is kept whole; any other span only by its name, as a
  # possible parent.
  defp query_shape(acc, receipt, %{"source" => "otel", "attributes" => %{} = a} = event) do
    cond do
      QueryShapes.query?(event) ->
        keep_query(acc, receipt, event)

      is_binary(a["span_id"]) and is_binary(a["name"]) and
          map_size(acc.span_names) < @span_names_max ->
        %{acc | span_names: Map.put(acc.span_names, a["span_id"], {a["trace_id"], a["name"]})}

      is_binary(a["span_id"]) ->
        %{acc | span_names_omitted: acc.span_names_omitted + 1}

      true ->
        acc
    end
  end

  defp query_shape(acc, receipt, %{"source" => "telemetry"} = event) do
    if QueryShapes.query?(event), do: keep_query(acc, receipt, event), else: acc
  end

  defp query_shape(acc, _receipt, _event), do: acc

  defp keep_query(acc, receipt, event) do
    if acc.queries_seen < @queries_max,
      do: %{
        acc
        | queries: [%{"receipt" => receipt, "event" => event} | acc.queries],
          queries_seen: acc.queries_seen + 1
      },
      else: %{acc | queries_seen: acc.queries_seen + 1}
  end

  defp change(acc, receipt, %{"attributes" => %{"write" => true}} = event) do
    if acc.writes_seen < @writes_max,
      do: %{
        acc
        | writes: [%{"receipt" => receipt, "event" => event} | acc.writes],
          writes_seen: acc.writes_seen + 1
      },
      else: %{acc | writes_seen: acc.writes_seen + 1}
  end

  defp change(acc, receipt, event) do
    if writer_evidence?(event) and acc.changes_seen < @changes_max,
      do: %{
        acc
        | changes: [%{"receipt" => receipt, "event" => event} | acc.changes],
          changes_seen: acc.changes_seen + 1
      },
      else: acc
  end

  defp writer_evidence?(%{"kind" => "absinthe.execute.operation.stop"}), do: true
  defp writer_evidence?(%{"attributes" => %{"request" => %{"role" => "server"}}}), do: true

  defp writer_evidence?(%{"source" => "otel", "payload" => %{"span_attributes" => %{} = a}}),
    do: is_map_key(a, "user.id") or is_map_key(a, "usr.id")

  defp writer_evidence?(_event), do: false

  defp request(acc, receipt, %{"attributes" => %{"request" => %{}}} = event) do
    if acc.requests_seen < @requests_max,
      do: %{
        acc
        | requests: [%{"receipt" => receipt, "event" => event} | acc.requests],
          requests_seen: acc.requests_seen + 1
      },
      else: %{acc | requests_seen: acc.requests_seen + 1}
  end

  defp request(acc, _receipt, _event), do: acc

  # Per-sample Poller series for trends (`Insider.Live.Trends.Series`).
  defp poller_series(acc, event, at),
    do: %{acc | poller_series: Series.add(acc.poller_series, event, at)}

  # Evidence for a `GenServer.call` timeout: a failing event whose disclosed
  # result, reason, error, or Logger message holds the exit
  # `{:timeout, {GenServer, :call, _}}` (or `:gen_server`'s).
  @call_timeout ~r/\{:timeout, \{(?:GenServer|:gen_server), :call\b/

  defp call_timeout(acc, %{"severity" => severity} = event) when severity in @error_severities do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}
    metadata = if is_map(payload["metadata"]), do: payload["metadata"], else: %{}

    texts =
      case event["source"] do
        "telemetry" -> [metadata["result"], metadata["reason"], metadata["error"]]
        _logger -> [payload["message"]]
      end

    cond do
      not Enum.any?(texts, &(is_binary(&1) and Regex.match?(@call_timeout, &1))) ->
        acc

      event["source"] == "telemetry" ->
        %{acc | call_timeouts: bump(acc.call_timeouts, to_string(event["kind"]))}

      true ->
        %{acc | logged_call_timeouts: acc.logged_call_timeouts + 1}
    end
  end

  defp call_timeout(acc, _event), do: acc

  defp offender(acc, %{"kind" => "supervisor_child_terminated", "attributes" => a}, receipt, at)
       when is_map(a) do
    offender = a["offender_id"] || "unknown"
    key = {offender, a["reason_fingerprint"]}

    loop =
      Map.get(acc.terminations, key, %{
        "offender_id" => offender,
        "offender" => short_id(offender),
        "supervisor" => a["supervisor"],
        "restart_type" => a["restart_type"],
        "reason_class" => a["reason_class"],
        "reason_fingerprint" => a["reason_fingerprint"],
        "first_receipt" => receipt,
        times: []
      })

    loop = %{loop | times: if(at, do: [at | loop.times], else: loop.times)}
    loop = loop |> Map.put("last_receipt", receipt) |> Map.update("count", 1, &(&1 + 1))

    %{
      acc
      | by_offender: bump(acc.by_offender, offender),
        terminations: Map.put(acc.terminations, key, loop)
    }
  end

  defp offender(acc, _event, _receipt, _at), do: acc

  # A summary stands for many events and is never one error; its exemplars
  # are recorded events and count as they are.
  defp signature(acc, %{"attributes" => %{"lifecycle_phase" => "summary"}}, _receipt, _at),
    do: acc

  defp signature(acc, event, receipt, at) do
    if signed?(event), do: add_signature(acc, event, receipt, at), else: acc
  end

  # Errors, and a GraphQL payload's validation errors inside an HTTP 200
  # (a warning, which is otherwise left out).
  defp signed?(%{"severity" => severity}) when severity in @error_severities, do: true

  defp signed?(%{"attributes" => %{"graphql" => graphql}}),
    do: GraphqlOutcome.user_errors?(graphql)

  defp signed?(_event), do: false

  defp add_signature(acc, %{"severity" => severity} = event, receipt, at) do
    text = signature(event)

    row =
      Map.get(acc.signatures, text, %{
        "signature" => text,
        "id" => signature_id(text),
        "source" => event["source"],
        "kind" => event["kind"],
        "severity" => severity,
        "count" => 0,
        "first_receipt" => receipt,
        "first_wall_time" => iso(at),
        pids: MapSet.new()
      })

    pid = get_in(event, ["subject", "value"])

    row = %{
      row
      | "count" => row["count"] + 1,
        pids:
          if(is_binary(pid) and MapSet.size(row.pids) < 1_000,
            do: MapSet.put(row.pids, pid),
            else: row.pids
          )
    }

    row = Map.merge(row, %{"last_receipt" => receipt, "last_wall_time" => iso(at)})
    %{acc | signatures: Map.put(acc.signatures, text, row)}
  end

  defp telemetry(acc, %{"source" => "telemetry", "attributes" => %{} = a} = event, at) do
    kind = event["kind"]

    case a do
      %{"lifecycle_phase" => "summary", "summary" => %{} = summary} ->
        row = %{
          "wall_time" => iso(at),
          "count" => summary["count"],
          "errors" => summary["errors"],
          "p50_us" => summary["duration_p50_us"],
          "p95_us" => summary["duration_p95_us"],
          "max_us" => summary["duration_max_us"],
          "interval_ms" => summary["interval_ms"],
          "window_started_at" => summary["window_started_at"],
          "window_ended_at" => summary["window_ended_at"],
          "exemplars" => summary["exemplars"] || [],
          "exemplars_lost" => summary["exemplars_lost"],
          "first_error_retained" => summary["first_error_retained"],
          "duration_scope" => summary["duration_scope"]
        }

        %{acc | summaries: Map.update(acc.summaries, kind, [row], &[row | &1])}

      # An exemplar is one of its summary's slowest events or its first
      # error, not a sample of the kind's durations.
      %{"exemplar_of" => %{}} ->
        acc

      %{"durations_us" => %{} = durations} ->
        case durations["duration"] || durations["total_time"] do
          us when is_integer(us) ->
            error = if event["severity"] in @error_severities, do: 1, else: 0

            durations =
              Map.update(acc.durations, kind, {[us], error}, fn {values, errors} ->
                {[us | values], errors + error}
              end)

            %{acc | durations: durations}

          _none ->
            acc
        end

      _other ->
        acc
    end
  end

  defp telemetry(acc, _event, _at), do: acc

  defp poller(acc, %{"source" => "poller", "kind" => "vm_sample", "attributes" => a}, at)
       when is_map(a) do
    metrics =
      for {name, value} <- a["metrics"] || %{}, is_integer(value), into: %{}, do: {name, value}

    sample = %{metrics: metrics, at: at}

    vm =
      case acc.vm do
        nil -> %{first: sample, last: sample, samples: 1}
        vm -> %{vm | last: sample, samples: vm.samples + 1}
      end

    %{acc | vm: vm}
  end

  # The Poller's per-cycle ranking (`process_top`) lists processes by
  # mailbox length; a `process_sample` or `process_watch` names one.
  defp poller(acc, %{"source" => "poller", "kind" => "process_top", "attributes" => a}, at)
       when is_map(a) do
    case get_in(a, ["metrics", "by_message_queue_len"]) do
      entries when is_list(entries) -> Enum.reduce(entries, acc, &mailbox(&2, &1, at))
      _none -> acc
    end
  end

  defp poller(acc, %{"source" => "poller", "kind" => kind, "attributes" => a} = event, at)
       when kind in ["process_sample", "process_watch"] and is_map(a) do
    metrics = a["metrics"] || %{}
    pid = get_in(event, ["subject", "value"])
    name = a["watch_name"] || display(metrics["registered_name"])
    mailbox(acc, Map.merge(metrics, %{"pid" => pid, "name" => name}), at)
  end

  defp poller(acc, _event, _at), do: acc

  # A row is one process: its pid, or its label when the evidence has no
  # pid. Rankings and watched samples of the same pid share a row, so two
  # processes with one label (two unregistered workers of one initial call)
  # never merge, and a watched process is never listed twice. The label is
  # the registered name once any sample names it (in the form an agent
  # writes it), else the initial call or the pid.
  defp mailbox(acc, %{"message_queue_len" => length} = entry, at) when is_integer(length) do
    label = to_string(entry["name"] || entry["initial_call"] || entry["pid"])
    key = entry["pid"] || {:label, label}

    row =
      Map.get(acc.mailboxes, key, %{
        "process" => label,
        "pid" => entry["pid"],
        "first_message_queue_len" => length,
        "max_message_queue_len" => length
      })

    row =
      Map.merge(row, %{
        "process" => (entry["name"] && to_string(entry["name"])) || row["process"],
        # Only a registered name can be passed to `process --name`.
        "registered_name" =>
          (entry["name"] && to_string(entry["name"])) || row["registered_name"],
        "message_queue_len" => length,
        "max_message_queue_len" => max(row["max_message_queue_len"], length),
        "wall_time" => iso(at)
      })

    %{acc | mailboxes: Map.put(acc.mailboxes, key, row)}
  end

  defp mailbox(acc, _entry, _at), do: acc

  # A registered name as the rankings show it: an Elixir alias without
  # `Elixir.`.
  defp display("Elixir." <> alias), do: alias
  defp display(name), do: name

  # A Logger burst's rows, one per interval, by message template, call site,
  # and level; a level's overflow row is a burst of its own.
  defp logger_burst(
         acc,
         %{
           "source" => "logger",
           "kind" => "logger_summary",
           "attributes" => %{"summary" => %{} = s}
         } = event,
         receipt
       ) do
    row = Map.merge(s, %{"receipt" => receipt, "level" => s["level"] || event["severity"]})
    key = {row["template_fingerprint"], row["call_site_fingerprint"], row["level"]}
    %{acc | bursts: Map.update(acc.bursts, key, [row], &[row | &1])}
  end

  defp logger_burst(acc, _event, _receipt), do: acc

  ## Call traces

  @calls_failures 3
  @p50_sample_max 1_000

  defp calls(acc, %{"source" => "calls", "kind" => "call.stopped", "attributes" => a}, receipt)
       when is_map(a) do
    stop = %{"reason" => a["reason"], "calls" => a["calls"], "receipt" => receipt}
    %{acc | calls_stopped: Enum.take(acc.calls_stopped ++ [stop], @top)}
  end

  defp calls(
         acc,
         %{"source" => "calls", "kind" => kind, "attributes" => %{"function" => function} = a} =
           event,
         receipt
       )
       when kind in ["call", "call.return", "call.exception"] and is_binary(function) do
    row =
      Map.get(acc.calls, function, %{
        "function" => function,
        "calls" => 0,
        "returns" => 0,
        "exceptions" => 0,
        "timed" => 0,
        "max_us" => nil,
        durations: [],
        sampled: 0,
        failures: %{}
      })

    row = call_row(row, kind, a, event, receipt)
    %{acc | calls: Map.put(acc.calls, function, row)}
  end

  defp calls(acc, _event, _receipt), do: acc

  defp call_row(row, "call", _a, _event, _receipt), do: Map.update!(row, "calls", &(&1 + 1))

  defp call_row(row, "call.return", a, _event, _receipt),
    do: row |> Map.update!("returns", &(&1 + 1)) |> duration(a["duration_us"])

  defp call_row(row, "call.exception", a, event, receipt) do
    key = {a["class"], a["exception"]}

    failure =
      Map.get(row.failures, key, %{
        "class" => a["class"],
        "exception" => a["exception"],
        "count" => 0,
        "first_receipt" => receipt,
        "first_call_id" => a["call_id"],
        "arguments" => get_in_map(event, ["payload", "arguments"]),
        "reason" => get_in_map(event, ["payload", "reason"])
      })

    row
    |> Map.update!("exceptions", &(&1 + 1))
    |> duration(a["duration_us"])
    |> Map.put(:failures, Map.put(row.failures, key, Map.update!(failure, "count", &(&1 + 1))))
  end

  # Every result's duration counts in `timed` and the exact `max_us`; the
  # median is taken over the window's first 1,000, and `p50_sample` says
  # how many.
  defp duration(row, us) when is_integer(us) do
    row = %{
      row
      | "timed" => row["timed"] + 1,
        "max_us" => max(row["max_us"] || us, us)
    }

    if row.sampled < @p50_sample_max,
      do: %{row | durations: [us | row.durations], sampled: row.sampled + 1},
      else: row
  end

  defp duration(row, _us), do: row

  defp calls_summary(calls, stopped) when map_size(calls) == 0 and stopped == [], do: nil

  defp calls_summary(calls, stopped) do
    functions =
      calls
      |> Map.values()
      |> Enum.map(fn row ->
        sorted = Enum.sort(row.durations)

        failures =
          row.failures
          |> Map.values()
          |> Enum.sort_by(&{-&1["count"], &1["first_receipt"]})
          |> Enum.take(@calls_failures)

        row
        |> Map.drop([:durations, :sampled, :failures])
        |> Map.merge(%{
          "p50_us" => percentile(sorted, 50),
          "p50_sample" => row.sampled,
          "failures" => failures
        })
      end)
      |> Enum.sort_by(&{-&1["exceptions"], -&1["calls"], &1["function"]})
      |> Enum.take(@top)

    %{"functions" => functions, "stopped" => stopped}
  end

  ## Gaps

  # Receipt-range losses are exact per read, so they add up over the window.
  # Losses without a receipt are deltas since the cursor a read started at,
  # so only the window's first read is taken: it covers the window's start.
  defp gap(%{"scope" => "receipt_range", "reason" => reason, "count" => count}, acc)
       when is_integer(count),
       do: %{acc | receipt_gaps: Map.update(acc.receipt_gaps, reason, count, &(&1 + count))}

  defp gap(%{"scope" => "unknown", "reason" => reason}, acc),
    do: %{acc | unknown_gaps: MapSet.put(acc.unknown_gaps, reason)}

  defp gap(_gap, acc), do: acc

  defp since_cursor(gaps) when is_list(gaps),
    do: Enum.filter(gaps, &(&1["scope"] not in ["receipt_range", "unknown"]))

  defp since_cursor(_gaps), do: []

  defp gaps(acc) do
    receipt =
      acc.receipt_gaps
      |> Enum.sort()
      |> Enum.map(fn {reason, count} ->
        %{"reason" => reason, "count" => count, "scope" => "receipt_range"}
      end)

    unknown =
      acc.unknown_gaps
      |> Enum.sort()
      |> Enum.map(&%{"reason" => &1, "count" => nil, "scope" => "unknown"})

    receipt ++ acc.first_gaps ++ unknown
  end

  ## Results

  defp crash_loops(terminations) do
    terminations
    |> Map.values()
    |> Enum.filter(&(&1["count"] >= 2))
    |> Enum.map(fn loop ->
      times = Enum.sort(loop.times)

      intervals =
        times |> Enum.zip(Enum.drop(times, 1)) |> Enum.map(fn {a, b} -> div(b - a, 1_000) end)

      loop
      |> Map.delete(:times)
      |> Map.merge(%{
        "restarts" => loop["count"],
        "period_ms" => median(intervals),
        "period_min_ms" => if(intervals == [], do: nil, else: Enum.min(intervals)),
        "period_max_ms" => if(intervals == [], do: nil, else: Enum.max(intervals)),
        "first_wall_time" => iso(List.first(times)),
        "last_wall_time" => iso(List.last(times))
      })
      |> Map.delete("count")
    end)
    |> Enum.sort_by(&{-&1["restarts"], &1["offender_id"]})
    |> Enum.take(@top)
  end

  defp signatures(signatures) do
    signatures
    |> Map.values()
    |> Enum.map(fn row ->
      row |> Map.put("processes", MapSet.size(row.pids)) |> Map.delete(:pids)
    end)
    |> Enum.sort_by(&{-&1["count"], &1["first_receipt"]})
    |> Enum.take(@top)
  end

  defp latency(summaries, durations, call_timeouts) do
    summarized =
      Enum.map(summaries, fn {kind, rows} ->
        rows = Enum.reverse(rows)
        latest = List.last(rows)

        %{
          "kind" => kind,
          "from" => "summaries",
          "count" => sum(rows, "count"),
          "errors" => sum(rows, "errors"),
          "p50_us" => latest["p50_us"],
          "p95_us" => latest["p95_us"],
          "max_us" =>
            rows
            |> Enum.map(& &1["max_us"])
            |> Enum.filter(&is_integer/1)
            |> Enum.max(fn -> nil end),
          "intervals" => Enum.take(rows, -@intervals),
          "exemplars" => exemplars(rows),
          "exemplars_lost" => sum(rows, "exemplars_lost"),
          "first_error_lost_intervals" =>
            Enum.count(rows, &(&1["first_error_retained"] == false)),
          "call_timeouts" => Map.get(call_timeouts, kind, 0)
        }
      end)

    recorded =
      Enum.map(durations, fn {kind, {values, errors}} ->
        sorted = Enum.sort(values)

        %{
          "kind" => kind,
          "from" => "events",
          "count" => length(sorted),
          "errors" => errors,
          "p50_us" => percentile(sorted, 50),
          "p95_us" => percentile(sorted, 95),
          "max_us" => List.last(sorted),
          "call_timeouts" => Map.get(call_timeouts, kind, 0)
        }
      end)

    (summarized ++ recorded)
    |> Enum.sort_by(&{-(&1["p95_us"] || -1), &1["kind"], &1["from"]})
    |> Enum.take(@top)
  end

  # The window's slowest exemplars and its first error, each once: the
  # events to open behind a latency row. An exemplar whose duration the
  # boundary withheld is still an event to open; it sorts last.
  defp exemplars(rows) do
    all = Enum.flat_map(rows, &(&1["exemplars"] || []))

    slowest =
      all
      |> Enum.filter(&("slowest" in (&1["roles"] || [])))
      |> Enum.sort_by(&{-(&1["duration_us"] || -1), &1["receipt"]})
      |> Enum.take(3)

    first_error = Enum.filter(all, &("first_error" in (&1["roles"] || []))) |> Enum.take(1)
    Enum.uniq_by(first_error ++ slowest, & &1["receipt"])
  end

  defp mailboxes(mailboxes) do
    mailboxes
    |> Map.values()
    |> Enum.filter(&(&1["max_message_queue_len"] > 0))
    |> Enum.sort_by(&{-&1["message_queue_len"], -&1["max_message_queue_len"], &1["process"]})
    |> Enum.take(5)
  end

  defp vm(nil), do: nil

  defp vm(%{first: first, last: last, samples: samples}) do
    %{
      "samples" => samples,
      "first_wall_time" => iso(first.at),
      "last_wall_time" => iso(last.at),
      "span_ms" => span_ms(first.at, last.at),
      "metrics" => deltas(first.metrics, last.metrics),
      "target" => deltas(target(first.metrics), target(last.metrics))
    }
  end

  # The node's own share of each VM total that Insider's footprint is part
  # of: the total less the `insider_*` field the Poller measured with it.
  @footprint [
    {"process_count", "insider_process_count"},
    {"processes_bytes", "insider_processes_bytes"},
    {"ets_count", "insider_ets_tables"},
    {"ets_bytes", "insider_ets_bytes"}
  ]

  defp target(metrics) do
    for {total, insider} <- @footprint,
        is_integer(metrics[total]) and is_integer(metrics[insider]),
        into: %{},
        do: {total, max(metrics[total] - metrics[insider], 0)}
  end

  defp deltas(first, last) do
    for {name, value} <- last, Map.has_key?(first, name), into: %{} do
      {name, %{"first" => first[name], "last" => value, "delta" => value - first[name]}}
    end
  end

  ## Signatures

  @doc """
  The signature of a disclosed event, as `"error_signatures"` names it. A
  signature names code, never data: the event kind, the supervisor
  offender and reason fingerprint, the exception module, the call site, and
  the message's first line with numbers, pids, references, and long hex
  runs replaced, so one bug with many values is one signature. A reader's
  view hides signatures (`Insider.Live.View`).
  """
  @spec signature(map()) :: String.t()
  def signature(%{"kind" => "supervisor_child_terminated", "attributes" => a})
      when is_map(a) do
    fingerprint = a["reason_fingerprint"] && String.slice(a["reason_fingerprint"], 0, 12)

    ["supervisor_child_terminated", short_id(a["offender_id"]), a["reason_class"], fingerprint]
    |> join()
  end

  def signature(%{"source" => "telemetry", "kind" => kind} = event) do
    metadata = get_in(event, ["payload", "metadata"])
    metadata = if is_map(metadata), do: metadata, else: %{}

    status =
      case metadata["status"] || get_in_map(metadata, ["conn", "status"]) do
        status when is_integer(status) -> "status=#{status}"
        _none -> nil
      end

    [
      kind,
      text_value(metadata["kind"]),
      exception(metadata["reason"]) || exception(metadata["error"]),
      result(metadata["result"]),
      status,
      graphql(event)
    ]
    |> join()
  end

  # A span: its GraphQL outcome when it has one (which names the
  # operation), else its name.
  def signature(%{"source" => "otel", "kind" => kind, "attributes" => a} = event)
      when is_map(a) do
    [kind, graphql(event) || text_value(a["name"]), text_value(a["status"])] |> join()
  end

  # A traced function's failure: the function, then the exception module,
  # or the class (exit, throw) when there is none.
  def signature(%{"source" => "calls", "kind" => kind, "attributes" => a})
      when is_map(a) do
    [kind, text_value(a["function"]), text_value(a["exception"]) || text_value(a["class"])]
    |> join()
  end

  def signature(%{"kind" => kind} = event) do
    payload = event["payload"]
    message = if is_map(payload), do: payload["message"]

    metadata =
      if is_map(payload) and is_map(payload["metadata"]), do: payload["metadata"], else: %{}

    exception = exception(message)

    head =
      case message do
        text when is_binary(text) -> normalise(text)
        _none -> event |> get_in(["attributes", "domain"]) |> domain()
      end

    [kind, text_value(metadata["mfa"]), exception, head] |> join()
  end

  def signature(_event), do: ""

  defp graphql(%{"attributes" => %{"graphql" => %{} = graphql}}),
    do: GraphqlOutcome.signature(graphql)

  defp graphql(_event), do: nil

  @doc "A signature's short id: the first 12 hex digits of its SHA-256."
  @spec signature_id(String.t()) :: String.t()
  def signature_id(text),
    do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, value ->
      if is_map(value), do: {:cont, Map.get(value, key)}, else: {:halt, nil}
    end)
  end

  defp exception(%{"__struct__" => name}) when is_binary(name), do: short_module(name)

  # The exception module, from `** (Name)` in a formatted error, an inspected
  # `%Name{` struct, or a struct rendered field by field with its
  # `"__struct__"` name.
  @exception ~r/\*\* \(([A-Z][\w.]*)\)|%([A-Z][\w.]*(?:Error|Exception))\{|"__struct__" => "(?:Elixir\.)?([A-Z][\w.]*(?:Error|Exception))"/

  defp exception(text) when is_binary(text) do
    case Regex.run(@exception, text) do
      nil -> nil
      [_match | names] -> Enum.find(names, &(&1 != ""))
    end
  end

  defp exception(_value), do: nil

  defp result(text) when is_binary(text) do
    if String.starts_with?(text, "{:error"), do: "result=" <> normalise(text), else: nil
  end

  defp result(_value), do: nil

  defp text_value(value) when is_binary(value), do: value
  defp text_value(_value), do: nil

  defp domain(segments) when is_list(segments) and segments != [], do: Enum.join(segments, ".")
  defp domain(_segments), do: nil

  # An HTML page (such as a Plug debugger page) is named, never quoted.
  defp normalise(text) do
    if String.match?(text, ~r/\A\s*<(!doctype|html|head|body|div|pre|style|script|main|table)\b/i) or
         String.contains?(text, ["</html>", "</body>"]),
       do: "[html]",
       else: Template.normalise(text, @signature_bytes)
  end

  defp join(parts),
    do:
      parts
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> Template.truncate(@signature_bytes * 2)

  # Query evidence past the cap is said, never dropped silently.
  defp query_evidence_line(%{"omitted" => omitted} = evidence) when omitted > 0,
    do:
      "Repeated queries: #{omitted} of #{evidence["seen"]} query spans and events were not examined " <>
        "(cap #{evidence["cap"]}); an N+1 among them is not shown."

  defp query_evidence_line(_evidence), do: nil

  ## Human summary

  @doc """
  A short plain-text summary of a digest for the developer: the window, the
  severities, crash loops with their period, the slowest operation with the
  receipts of its exemplars, trends across summary windows, Logger bursts,
  the top errors, the longest mailbox, VM changes, and what was not
  recorded or lost.
  """
  @spec text(map()) :: String.t()
  def text(digest) do
    window = digest["window"]
    trends = digest["trends"] || []

    [
      header(digest, window),
      Anomalies.lines(Map.put_new(digest, "anomalies", [])),
      window_line(window),
      stale_line(window),
      nothing_since_mark(digest),
      severities(digest["counts"]["by_severity"]),
      Enum.map(digest["crash_loops"], &crash_loop_line/1),
      latency_lines(digest["latency"], digest["logged_call_timeouts"] || 0),
      Trends.lines(Enum.filter(trends, &(&1["windows"] > 1)), digest["logger_bursts"] || [], 3),
      Trends.scope_notes(trends),
      error_lines(digest["error_signatures"]),
      mailbox_line(digest["processes"]),
      vm_line(digest["vm"]),
      calls_lines(digest["calls"]),
      query_evidence_line(digest["query_evidence"]),
      filtered_line(digest["filtered"]),
      gaps_line(digest["gaps"]),
      Hints.lines(digest["hints"] || [], hints_label(window)),
      ending_line(window)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp header(digest, window) do
    receipts =
      case window do
        %{"first_receipt" => nil} ->
          "no events after receipt #{window["cursor"]}"

        %{"first_receipt" => first, "last_receipt" => last} ->
          "receipts #{first}-#{last}, #{window["events"]} events"
      end

    span =
      case {window["first_wall_time"], window["last_wall_time"]} do
        {nil, _last} -> ""
        {first, last} -> ", #{clock(first)}-#{clock(last)} UTC (#{ms_text(window["span_ms"])})"
      end

    profile =
      if digest["disclosure_profile"],
        do: " (#{digest["disclosure_profile"]} disclosure)",
        else: ""

    "Insider digest of #{digest["session_id"]} on #{digest["node"]}#{profile}: #{receipts}#{span}."
  end

  defp severities(counts) when map_size(counts) == 0, do: nil

  defp severities(counts) do
    order = ["critical", "error", "warning", "info", "debug"]

    text =
      order
      |> Enum.filter(&Map.has_key?(counts, &1))
      |> Enum.map_join(", ", &"#{counts[&1]} #{&1}")

    "Severity: #{text}."
  end

  defp crash_loop_line(loop) do
    period = if loop["period_ms"], do: ", every #{ms_text(loop["period_ms"])}", else: ""
    restart = if loop["restart_type"], do: " (#{loop["restart_type"]})", else: ""
    fingerprint = loop["reason_fingerprint"] && String.slice(loop["reason_fingerprint"], 0, 12)
    reason = [loop["reason_class"], fingerprint] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    "Crash loop: #{loop["offender"]}#{restart} terminated #{loop["restarts"]} times#{period}, same reason (#{reason})."
  end

  defp latency_lines([], _logged), do: nil

  defp latency_lines([slowest | rest], logged) do
    ["Slowest: " <> latency_text(slowest) <> timeout_hint(slowest, logged) <> "."] ++
      Enum.map(Enum.take(rest, 2), &("Latency: " <> latency_text(&1) <> "."))
  end

  defp latency_text(row) do
    from = if row["from"] == "summaries", do: " summarised", else: ""

    exemplars =
      case row["exemplars"] do
        [_ | _] = exemplars ->
          "; exemplar receipts " <> Enum.map_join(exemplars, ", ", &to_string(&1["receipt"]))

        _none ->
          ""
      end

    lost =
      case {row["exemplars_lost"] || 0, row["first_error_lost_intervals"] || 0} do
        {0, 0} ->
          ""

        {lost, 0} ->
          "; #{lost} exemplar candidates lost"

        {lost, 1} ->
          "; #{lost} exemplar candidates lost, first error not retained in 1 interval"

        {lost, n} ->
          "; #{lost} exemplar candidates lost, first error not retained in #{n} intervals"
      end

    "#{row["kind"]} p50 #{us_text(row["p50_us"])}, p95 #{us_text(row["p95_us"])}, max #{us_text(row["max_us"])} " <>
      "over #{row["count"]}#{from} events, #{row["errors"]} errors" <> exemplars <> lost
  end

  # A duration near 5 s alone proves nothing; the hint needs a disclosed
  # `{:timeout, {GenServer, :call, _}}` exit from that kind or the logs.
  defp timeout_hint(%{"p95_us" => p95} = row, logged)
       when is_integer(p95) and p95 in @timeout_us do
    case (row["call_timeouts"] || 0) + logged do
      0 ->
        ""

      exits ->
        "; pinned near 5 s, consistent with GenServer.call timeouts " <>
          "(#{exits} {:timeout, {GenServer, :call, _}} exits seen)"
    end
  end

  defp timeout_hint(_row, _logged), do: ""

  defp error_lines([]), do: nil

  defp error_lines(signatures) do
    text =
      signatures
      |> Enum.take(3)
      |> Enum.map_join("; ", &"#{&1["count"]}x #{&1["signature"]}")

    "Top errors: #{text}."
  end

  defp mailbox_line([]), do: nil

  defp mailbox_line([top | _rest]) do
    "Longest mailbox: #{top["process"]} #{top["message_queue_len"]} messages " <>
      "(#{top["first_message_queue_len"]} at the window's first sample, max #{top["max_message_queue_len"]})."
  end

  defp vm_line(nil), do: nil

  # The node's processes, process memory, and ETS are shown without
  # Insider's own (the JSON's `vm.target`), and Insider's own beside them;
  # a total the Poller did not split says it includes Insider's.
  defp vm_line(%{"metrics" => metrics} = vm) do
    target = vm["target"] || %{}

    split = fn key, label, insider_key, insider_label ->
      case target[key] do
        %{} = row -> [{label, row}, {insider_label, metrics[insider_key]}]
        nil -> [{label <> " (including Insider's own)", metrics[key]}]
      end
    end

    changes =
      (split.("process_count", "processes", "insider_process_count", "Insider processes") ++
         [{"run queue", metrics["run_queue_length"]}, {"memory", metrics["total_bytes"]}] ++
         split.(
           "processes_bytes",
           "process memory",
           "insider_processes_bytes",
           "Insider process memory"
         ) ++
         split.("ets_bytes", "ETS", "insider_ets_bytes", "Insider ETS") ++
         [{"ports", metrics["port_count"]}, {"binaries", metrics["binary_bytes"]}])
      |> Enum.flat_map(fn {label, row} -> change(label, row) end)

    if changes == [], do: "VM: no change.", else: "VM: " <> Enum.join(changes, ", ") <> "."
  end

  @counted ["processes", "Insider processes", "run queue", "ports"]

  defp change(label, %{"first" => first, "last" => last, "delta" => delta}) when delta != 0 do
    format =
      if Enum.any?(@counted, &String.starts_with?(label, &1)),
        do: &Integer.to_string/1,
        else: &bytes_text/1

    sign = if delta > 0, do: "+", else: "-"
    ["#{label} #{format.(first)} -> #{format.(last)} (#{sign}#{format.(abs(delta))})"]
  end

  defp change(_label, _unchanged), do: []

  defp calls_lines(nil), do: nil

  defp calls_lines(%{"functions" => functions, "stopped" => stopped}) do
    Enum.map(Enum.take(functions, 3), &call_line/1) ++ Enum.map(stopped, &stopped_line/1)
  end

  defp call_line(row) do
    failure =
      case row["failures"] do
        [first | _rest] ->
          name = first["exception"] || first["class"]
          arguments = arguments_text(first["arguments"])
          "; #{first["count"]}x #{name}, first at receipt #{first["first_receipt"]}#{arguments}"

        [] ->
          ""
      end

    "Calls: #{row["function"]} #{row["calls"]} calls, #{row["returns"]} returns, " <>
      "#{row["exceptions"]} exceptions (max #{us_text(row["max_us"])})#{failure}."
  end

  defp arguments_text(arguments) when is_list(arguments) do
    text = Enum.map_join(arguments, ", ", &argument_text/1)
    " with arguments (#{Template.truncate(text, @signature_bytes)})"
  end

  defp arguments_text(_arguments), do: ""

  defp argument_text(text) when is_binary(text), do: text
  defp argument_text(value), do: inspect(value, limit: 8, printable_limit: 64)

  defp stopped_line(stop) do
    "Call trace stopped (#{stop["reason"]}) after #{stop["calls"]} calls, at receipt #{stop["receipt"]}."
  end

  defp filtered_line(%{} = filtered) do
    logger = filtered |> Map.get("logger") |> total()

    telemetry =
      filtered
      |> Map.get("telemetry", %{})
      |> then(&if(is_map(&1), do: Map.values(&1), else: []))
      |> Enum.map(&total/1)
      |> Enum.sum()

    if logger + telemetry > 0,
      do:
        "Not recorded (filters): #{logger} Logger and #{telemetry} Telemetry events; see filtered.",
      else: nil
  end

  defp filtered_line(_filtered), do: nil

  defp total(%{} = counts), do: counts |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()
  defp total(_counts), do: 0

  defp gaps_line([]), do: nil

  # A loss says why, when it is an eviction, and what prevents it.
  defp gaps_line(gaps) do
    text = Enum.map_join(gaps, ", ", &"#{&1["reason"]} #{&1["count"] || "unknown"}")

    cause =
      if Enum.any?(gaps, &(&1["reason"] == "evicted")),
        do:
          " Evicted: the Recorder was full and dropped its oldest events; read sooner, or record less (the hints say what).",
        else: ""

    "Lost: #{text}.#{cause}"
  end

  # The window as asked for, where it starts and ends, and how old its
  # newest event is: the first thing to check before trusting the rest.
  defp window_line(window) do
    from =
      case window["since"] do
        0 -> "after receipt 0 (the session start)"
        cursor when is_integer(cursor) -> "after receipt #{cursor}"
        "mark" -> Marks.since_text(window["mark"])
        "latest-" <> _rest = since -> latest_text(since, window["from_wall_time"])
      end

    newest =
      case window["age_ms"] do
        nil -> "no events in it"
        age -> "newest event #{age_text(age)} ago"
      end

    inexact =
      if window["start_exact"] == false,
        do: "; its start could not be narrowed exactly, so it may include older events",
        else: ""

    "Window: #{from}, up to receipt #{window["upto"] || window["next_cursor"]}; #{newest}#{inexact}."
  end

  defp latest_text(since, nil),
    do: "the newest #{String.replace_prefix(since, "latest-", "")} receipts"

  defp latest_text(since, from),
    do: "the last #{duration_text(since)} (since #{clock(from) |> String.slice(0, 8)} UTC)"

  # Up to two minutes in seconds (`60 s`), then whole minutes (`5 min`).
  defp duration_text("latest-" <> duration) do
    case Integer.parse(duration) do
      {amount, "h"} -> "#{amount} h"
      {amount, "s"} when amount > 120 and rem(amount, 60) == 0 -> "#{div(amount, 60)} min"
      {amount, "s"} -> "#{amount} s"
      {amount, "ms"} -> "#{amount} ms"
    end
  end

  # A window not limited in time whose newest event is over a minute old
  # may be reading old history; a time window says how to get the last
  # minute.
  defp stale_line(%{"since" => "mark"}), do: nil

  defp stale_line(%{"age_ms" => age, "from_wall_time" => nil})
       when is_integer(age) and age > 60_000,
       do:
         "The newest event in this window is #{age_text(age)} old; digest --since latest-60s covers the last minute."

  defp stale_line(_window), do: nil

  # A window since a pairing mark with no event after it (marks are not
  # counted): what the programmer was to do left no event yet, or none this
  # session records.
  defp nothing_since_mark(%{"window" => %{"since" => "mark", "events" => 0}}),
    do:
      "Nothing recorded since the mark: the action may not have happened yet, " <>
        "or this session does not record it (see filtered)."

  defp nothing_since_mark(_digest), do: nil

  defp hints_label(%{"first_receipt" => nil}), do: nil

  defp hints_label(window) do
    over =
      case {window["since"], window["from_wall_time"]} do
        {"latest-" <> _rest = since, from} when is_binary(from) ->
          ", the last #{duration_text(since)}"

        {"mark", _from} ->
          ", since mark '#{window["mark"]["label"]}'"

        _other ->
          ""
      end

    "receipts #{window["first_receipt"]}-#{window["last_receipt"]}#{over}"
  end

  defp age_text(ms), do: Marks.age_text(ms)

  defp ending_line(%{"complete" => true}), do: nil

  defp ending_line(window) do
    "Incomplete (#{window["stopped_by"]}): read on with --since #{window["next_cursor"]}."
  end

  ## Helpers

  defp bump(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  defp sum(rows, key), do: rows |> Enum.map(& &1[key]) |> Enum.filter(&is_integer/1) |> Enum.sum()

  # The lower median, by nearest rank.
  defp median(values), do: values |> Enum.sort() |> percentile(50)

  # Nearest rank.
  defp percentile([], _p), do: nil

  defp percentile(sorted, p) do
    rank = max(ceil(p * length(sorted) / 100), 1)
    Enum.at(sorted, rank - 1)
  end

  defp wall_us(value), do: RequestTiming.wall_us(value)

  defp earliest(nil, at), do: at
  defp earliest(current, nil), do: current
  defp earliest(current, at), do: min(current, at)

  defp latest(nil, at), do: at
  defp latest(current, nil), do: current
  defp latest(current, at), do: max(current, at)

  defp iso(nil), do: nil

  defp iso(us) do
    us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  # The plain-term contract has no floats, so spans are whole milliseconds.
  defp span_ms(first, last) when is_integer(first) and is_integer(last),
    do: div(last - first, 1_000)

  defp span_ms(_first, _last), do: nil

  defp clock(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} ->
        at |> DateTime.to_time() |> Time.truncate(:millisecond) |> Time.to_iso8601()

      _error ->
        iso
    end
  end

  defp ms_text(nil), do: "?"
  defp ms_text(ms), do: :erlang.float_to_binary(ms / 1_000, decimals: 1) <> " s"

  defp us_text(us), do: Trends.us_text(us)

  defp bytes_text(bytes) when abs(bytes) >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MiB"

  defp bytes_text(bytes) when abs(bytes) >= 1_024, do: "#{div(bytes, 1_024)} KiB"
  defp bytes_text(bytes), do: "#{bytes} B"

  # `atom:Elixir.Shop.Inventory` reads as `Shop.Inventory`.
  defp short_id("atom:" <> name), do: short_module(name)
  defp short_id(nil), do: "unknown"
  defp short_id(id), do: id

  defp short_module("Elixir." <> name), do: name
  defp short_module(name), do: name
end
