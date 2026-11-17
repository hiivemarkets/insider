defmodule Insider.Lab.Live.Chart.Run do
  @moduledoc false

  # Reads a session for `chart` and serves the live form.
  #
  # Every read goes through the ordinary APIs under the chart's own reader
  # name (`chart-…`), so the page shows exactly what those reads disclose
  # under the session's profile, and no other reader's cursor or view moves.
  #
  # The static chart reads as any read command does, and renews the lease
  # once: one digest of the window (`--since`, `--since-mark`, default the
  # last 15 minutes) for its window, anomalies and lead lines; the window's
  # events with `events_since/3`, in pages up to the digest's `upto`,
  # keeping the newest `@max_entries`; the session's marks and status.
  #
  # The live form (`--serve`) renews nothing, from its first read on, so a
  # programmer watching the page never keeps a session alive: it reads
  # `status`, `marks`, and the window's events with `"renew" => false`, then
  # follows the session with a subscription, `status` and `marks`. It
  # re-renders about every second, shows the session's state and lease, and
  # reads the window again when the session's profile changes (the host
  # narrowed it), so a page never keeps what the new profile withholds. It
  # stops at `--for`, or when the session ends, after serving the final page
  # for `@ended_grace_ms` or what is left of `--for`, whichever is shorter.
  #
  # What the chart could not read (entries past the cap, a read that stopped
  # advancing) goes into the page as notes, never as zeroes.

  alias Insider.Lab.Live.Chart
  alias Insider.Lab.Live.Chart.Server
  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Observer
  alias Insider.Lab.Live.Watch
  alias Insider.Lab.Live.Watch.Signals

  @default_since "latest-15m"
  @max_entries 20_000
  @read %{"limit" => 500, "max_bytes" => 1_048_576}
  @tick {:insider_live_chart, :tick}
  @deadline {:insider_live_chart, :deadline}
  @tick_ms 1_000
  @ended_grace_ms 5_000
  @units_ms %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}

  @type arguments :: %{
          session: String.t(),
          since: term(),
          reader: String.t(),
          port: :inet.port_number(),
          for_ms: pos_integer()
        }

  @doc "The window the chart reads when neither `--since` nor `--since-mark` is given."
  @spec default_since() :: String.t()
  def default_since, do: @default_since

  @doc """
  Where a chart goes without `--out`: a new file under the system temp
  directory, its name random past the session and the time.
  """
  @spec default_path(String.t()) :: String.t()
  def default_path(session) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    random = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "insider-chart-#{session}-#{stamp}-#{random}.html")
  end

  @doc """
  Reads the chart's window, the input of `Insider.Lab.Live.Chart.model/1`.
  `:static` reads it as any read command does (one digest, which renews the
  lease); `:live` reads only what renews nothing: `status`, `marks`, and
  `events_since/3` with `"renew" => false`.
  """
  @spec collect(node(), arguments(), pos_integer(), :static | :live) ::
          {:ok, map()} | {:target_error, map()} | Observer.failure()
  def collect(node, args, timeout_ms, :static) do
    digest_options = %{
      "since" => args.since || @default_since,
      "human" => true,
      "reader" => args.reader
    }

    with {:ok, digest} <-
           CLI.live_result(node, :digest, [args.session, digest_options], timeout_ms),
         window = digest["window"] || %{},
         upto = window["upto"] || window["next_cursor"] || window["cursor"],
         {:ok, read} <- read(node, args, {window["cursor"] || 0, upto}, timeout_ms, true),
         {:ok, %{"marks" => marks}} <-
           CLI.live_result(node, :marks, [args.session, %{}], timeout_ms),
         {:ok, status} <- CLI.live_result(node, :status, [args.session], timeout_ms) do
      now = System.os_time(:microsecond)
      mark = window["mark"]
      floor = wall_us(window["from_wall_time"])

      input(args, node, read, %{
        profile: digest["disclosure_profile"] || status["disclosure_profile"],
        marks: marks,
        since_mark: mark,
        digest: digest,
        status: status,
        window: {from(mark, floor, now), wall_us(window["as_of"]) || now},
        now_us: now,
        upto: upto
      })
    end
  end

  def collect(node, args, timeout_ms, :live) do
    with {:ok, status} <- CLI.live_result(node, :status, [args.session], timeout_ms),
         {:ok, %{"marks" => marks}} <-
           CLI.live_result(node, :marks, [args.session, %{}], timeout_ms),
         upto = status["next_receipt"] || 0,
         {cursor, floor} = live_start(args.since || @default_since, upto),
         {:ok, read} <- read(node, args, {cursor, upto}, timeout_ms, false) do
      now = System.os_time(:microsecond)

      input(args, node, read, %{
        profile: status["disclosure_profile"],
        marks: marks,
        since_mark: read.mark,
        digest: nil,
        status: status,
        window: {from(read.mark, floor, now), now},
        now_us: now,
        upto: upto
      })
    end
  end

  defp input(args, node, read, fields) do
    {:ok,
     Map.merge(fields, %{
       session_id: args.session,
       node: Atom.to_string(node),
       profile: fields.profile || "unknown",
       entries: read.entries,
       evicted: read.evicted,
       dropped: read.dropped,
       stalled: read.stalled,
       incomplete: incomplete(read),
       covered_from_us: if(read.dropped > 0, do: first_time(read.entries)),
       fit_start: fields.since_mark == nil,
       live: nil
     })}
  end

  # Where a live chart starts reading, without the digest that resolves the
  # static chart's window: a mark from its cursor (the read resolves it and
  # returns the mark), a count of receipts back from the newest, and a
  # duration from as far back as the chart keeps events, with the window
  # starting the duration back.
  defp live_start(cursor, _upto) when is_integer(cursor), do: {cursor, nil}
  defp live_start("mark" <> _label = since, _upto), do: {since, nil}

  defp live_start("latest-" <> back, upto) do
    case Regex.run(~r/\A([1-9][0-9]{0,8})(ms|s|m|h)?\z/, back) do
      [_match, count] ->
        {max(upto - String.to_integer(count), 0), nil}

      [_match, amount, unit] ->
        ms = String.to_integer(amount) * Map.fetch!(@units_ms, unit)
        {max(upto - @max_entries, 0), System.os_time(:microsecond) - ms * 1_000}
    end
  end

  # Reads [cursor, upto] in pages, keeping the newest `@max_entries`.
  defp read(node, args, {cursor, upto}, timeout_ms, renew?) do
    options = Map.merge(@read, %{"upto" => upto, "reader" => args.reader, "renew" => renew?})
    acc = %{entries: [], evicted: [], dropped: 0, stalled: nil, mark: nil}
    read_pages(node, args.session, {cursor, upto}, options, timeout_ms, acc)
  end

  defp read_pages(_node, _session, {cursor, upto}, _options, _timeout_ms, acc)
       when is_integer(cursor) and cursor >= upto,
       do: {:ok, acc}

  defp read_pages(node, session, {cursor, upto}, options, timeout_ms, acc) do
    case CLI.live_result(node, :events_since, [session, cursor, options], timeout_ms) do
      {:ok, %{"next_cursor" => next} = batch} when not is_integer(cursor) or next > cursor ->
        {entries, dropped} = retain(acc.entries, batch["events"] || [], @max_entries)

        acc = %{
          acc
          | entries: entries,
            dropped: acc.dropped + dropped,
            evicted: acc.evicted ++ evictions(batch),
            mark: acc.mark || batch["mark"]
        }

        read_pages(node, session, {next, upto}, options, timeout_ms, acc)

      {:ok, _no_progress} ->
        {:ok, %{acc | stalled: cursor}}

      failure ->
        failure
    end
  end

  @doc """
  `entries` (oldest first) followed by `new`, keeping the newest `max`, and
  how many it dropped. Entries the chart already holds (a re-read after the
  profile changed overlaps the subscription) are not added twice.
  """
  @spec retain([map()], [map()], pos_integer()) :: {[map()], non_neg_integer()}
  def retain(entries, new, max) do
    last =
      case List.last(entries) do
        %{"receipt" => receipt} -> receipt
        _none -> -1
      end

    all = entries ++ Enum.filter(new, &(&1["receipt"] > last))
    dropped = max(length(all) - max, 0)
    {Enum.drop(all, dropped), dropped}
  end

  defp incomplete(%{dropped: dropped, stalled: stalled}) do
    dropped =
      if dropped > 0,
        do: [
          %{
            "reason" => "max_entries",
            "detail" =>
              "the chart keeps the newest #{@max_entries} events; " <>
                "#{dropped} earlier ones in the window are not drawn"
          }
        ],
        else: []

    stalled =
      if stalled,
        do: [
          %{
            "reason" => "no_progress",
            "detail" =>
              "reading stopped advancing at receipt #{stalled}; later events are not drawn"
          }
        ],
        else: []

    dropped ++ stalled
  end

  # A read's receipt-range evictions, placed at its first event's time.
  defp evictions(batch) do
    count =
      Enum.find_value(batch["gaps"] || [], 0, fn
        %{"reason" => "evicted", "scope" => "receipt_range", "count" => count}
        when is_integer(count) ->
          count

        _gap ->
          nil
      end)

    at =
      case batch["events"] do
        [%{"event" => %{"wall_time" => wall}} | _rest] -> wall_us(wall)
        _none -> System.os_time(:microsecond)
      end

    if count > 0 and is_integer(at), do: [%{"at_us" => at, "count" => count}], else: []
  end

  # A window from a mark starts at the mark; any other at its floor (the
  # digest's start, or the duration back), from which the model starts it
  # at the first thing it plots, so the chart draws no minutes of nothing.
  defp from(%{"at" => at}, _floor, _now), do: wall_us(at)
  defp from(_mark, floor, now), do: floor || now - 15 * 60_000_000

  defp first_time([%{"event" => %{"wall_time" => wall}} | _rest]), do: wall_us(wall)
  defp first_time(_entries), do: nil

  defp wall_us(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :microsecond)
      _error -> nil
    end
  end

  defp wall_us(_text), do: nil

  ## Static

  @doc """
  Writes the chart of `args` to `path`, a new private file (see
  `write_private/2`), and returns a summary of what it drew. A path that
  exists, a symlink included, is refused before anything is read.
  """
  @spec write(node(), arguments(), String.t(), pos_integer()) ::
          {:ok, map()} | {:target_error, map()} | Observer.failure()
  def write(node, args, path, timeout_ms) do
    with :ok <- absent(path),
         {:ok, input} <- collect(node, args, timeout_ms, :static) do
      model = Chart.model(input)

      case write_private(path, Chart.Html.render(model)) do
        :ok ->
          {:ok, summary(model, path, args)}

        {:error, :eexist} ->
          exists(path)

        {:error, reason} ->
          {:error, "observer_failed", %{"reason" => "write_failed", "detail" => inspect(reason)}}
      end
    end
  end

  defp absent(path) do
    case :file.read_link_info(path) do
      {:ok, _info} -> exists(path)
      {:error, _absent} -> :ok
    end
  end

  defp exists(path),
    do:
      {:error, "invalid_options",
       %{
         "option" => "--out",
         "problem" => "exists",
         "path" => path,
         "expected" =>
           "a path that does not exist yet: chart writes a new file and never replaces one"
       }}

  @doc """
  Writes `html` to `path` as a new file, mode 0600: into a temp file in the
  same directory that only this call can have created (exclusive create),
  then hard-linked to `path`, which fails with `{:error, :eexist}` when
  `path` exists, a symlink included, so nothing is followed or replaced.
  """
  @spec write_private(String.t(), iodata()) :: :ok | {:error, term()}
  def write_private(path, html) do
    dir = Path.dirname(path)
    random = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    temp = Path.join(dir, ".insider-chart-#{random}.tmp")

    with :ok <- File.mkdir_p(dir),
         {:ok, io} <- :file.open(temp, [:write, :exclusive, :raw, :binary]) do
      try do
        with :ok <- File.chmod(temp, 0o600),
             :ok <- :file.write(io, html),
             :ok <- :file.close(io) do
          :file.make_link(temp, path)
        end
      after
        _closed = :file.close(io)
        _removed = File.rm(temp)
      end
    end
  end

  defp summary(model, path, args) do
    %{
      "schema" => "insider.live-chart/v1",
      "path" => path,
      "session_id" => model.session_id,
      "reader" => args.reader,
      "headline" => Chart.Html.headline_text(model),
      "series" => Enum.map(model.series, fn {name, _series} -> Atom.to_string(name) end),
      "not_recorded" => model.absent,
      "marks" => length(model.marks),
      "anomalies" => length(model.anomalies),
      "events" => model.events,
      "complete" => model.incomplete == [],
      "incomplete" => model.incomplete
    }
  end

  ## Live

  @doc """
  Serves the chart of `args` on 127.0.0.1 until `--for`, the end of the
  session, SIGTERM, or the loss of the target; see the module comment.
  """
  @spec serve(node(), arguments(), pos_integer(), (String.t(), map() -> :ok | {:error, term()})) ::
          {:stopped, map()}
          | {:exit, non_neg_integer()}
          | {:target_error, map()}
          | Observer.failure()
  def serve(node, args, timeout_ms, emit) do
    deadline_at = System.monotonic_time(:millisecond) + args.for_ms

    with {:ok, input} <- collect(node, args, timeout_ms, :live),
         input = live(input, input.status, input.marks),
         token = Server.token(),
         {:ok, server} <- Server.start(%{port: args.port, token: token, page: page(input, nil)}) do
      true = Node.monitor(node, true)

      try do
        with {:ok, _subscription} <- subscribe(node, args, input.upto, timeout_ms) do
          state = %{
            node: node,
            args: args,
            timeout_ms: timeout_ms,
            server: server,
            input: input,
            deadline_at: deadline_at
          }

          follow(state, emit, "http://127.0.0.1:#{Server.port(server)}/#{token}/")
        end
      after
        unsubscribe(node, args.session, timeout_ms)
        Server.stop(server)
        Node.monitor(node, false)
      end
    end
  end

  defp follow(%{args: args} = state, emit, url) do
    :ok = Signals.install(self())
    tick = Process.send_after(self(), @tick, @tick_ms)
    deadline = Process.send_after(self(), @deadline, remaining_ms(state))

    try do
      serving = %{
        "url" => url,
        "session_id" => args.session,
        "reader" => args.reader,
        "for_ms" => args.for_ms,
        "renews_lease" => false
      }

      case emit.("serving", serving) do
        :ok -> loop(state)
        {:error, _reason} -> {:exit, 70}
      end
    after
      Signals.restore()
      cancel(tick, @tick)
      cancel(deadline, @deadline)
    end
  end

  defp remaining_ms(state), do: max(state.deadline_at - System.monotonic_time(:millisecond), 0)

  defp loop(%{node: node} = state) do
    session = state.args.session

    receive do
      {:insider_live_events, ^session, batch} when is_map(batch) ->
        state = add_batch(state, batch)
        if batch["state"] in [nil, "running"], do: loop(state), else: ended(state, batch["state"])

      @tick ->
        refresh(state)

      @deadline ->
        finish(state, "duration")

      {:insider_live_watch, :stop} ->
        finish(state, "interrupted")

      {:nodedown, ^node} ->
        {:error, "target_down", %{}}
    end
  end

  # A batch the subscription pushed, under the profile in effect when it
  # was read; past `@max_entries` the oldest entries go, and the page says so.
  defp add_batch(%{input: input} = state, batch) do
    {entries, dropped} = retain(input.entries, batch["events"] || [], @max_entries)
    dropped = input.dropped + dropped

    input = %{
      input
      | entries: entries,
        evicted: input.evicted ++ evictions(batch),
        dropped: dropped,
        incomplete: incomplete(%{dropped: dropped, stalled: input.stalled}),
        covered_from_us: if(dropped > 0, do: first_time(entries), else: input.covered_from_us)
    }

    %{state | input: input}
  end

  defp refresh(state) do
    %{args: args, node: node, timeout_ms: timeout_ms} = state

    with {:ok, status} <- CLI.live_result(node, :status, [args.session], timeout_ms),
         {:ok, %{"marks" => marks}} <-
           CLI.live_result(node, :marks, [args.session, %{}], timeout_ms),
         {:ok, state} <- reprofile(state, status) do
      state = %{state | input: live(state.input, status, marks)}

      if status["state"] == "running" do
        render(state, nil)
        Process.send_after(self(), @tick, @tick_ms)
        loop(state)
      else
        ended(state, status["state"])
      end
    else
      {:target_error, %{"code" => code}} when code in ["session_terminal", "unknown_session"] ->
        ended(state, "ended")

      failure ->
        failure
    end
  end

  # When the session's profile changes (the host narrowed it), everything
  # the chart holds was disclosed under the old one: it is dropped and the
  # window read again under the new one, before the next page is drawn.
  defp reprofile(%{input: %{profile: profile}} = state, %{"disclosure_profile" => profile}),
    do: {:ok, state}

  defp reprofile(state, status) when not is_map_key(status, "disclosure_profile"),
    do: {:ok, state}

  defp reprofile(state, _status) do
    with {:ok, input} <- collect(state.node, state.args, state.timeout_ms, :live),
         do: {:ok, %{state | input: input}}
  end

  # The anomalies of the last minute that `status` reports, as the summary.
  defp live(input, status, marks) do
    anomalies = status["anomalies"] || []

    lines =
      %{"anomalies" => anomalies}
      |> Insider.Live.Anomalies.lines()
      |> List.update_at(
        0,
        &String.replace_prefix(&1, "Anomalies", "Anomalies in the last minute")
      )

    now = System.os_time(:microsecond)
    {from, _to} = input.window

    %{
      input
      | status: status,
        marks: marks,
        digest: %{"anomalies" => anomalies, "text" => Enum.join(lines, "\n")},
        window: {from, now},
        now_us: now
    }
  end

  defp page(input, stopped),
    do: Chart.html(%{input | live: %{refresh_s: div(@tick_ms, 1_000), stopped: stopped}})

  defp render(state, stopped), do: Server.put(state.server, page(state.input, stopped))

  # The session ended: the final page, without refresh, stays up for a
  # moment so a browser that reloads finds it, but not past `--for`.
  defp ended(state, session_state) do
    status = Map.put(state.input.status || %{}, "state", session_state || "ended")
    state = %{state | input: %{state.input | status: status}}
    render(state, "session_ended")

    receive do
      {:insider_live_watch, :stop} -> :ok
      @deadline -> :ok
    after
      min(@ended_grace_ms, remaining_ms(state)) -> :ok
    end

    {:stopped, %{"reason" => "session_ended", "state" => session_state}}
  end

  defp finish(state, reason) do
    render(state, reason)
    {:stopped, %{"reason" => reason}}
  end

  defp subscribe(node, args, cursor, timeout_ms) do
    options = %{"cursor" => cursor, "reader" => args.reader}

    case Observer.call(
           node,
           Insider.Live,
           :subscribe,
           [args.session, self(), options],
           timeout_ms
         ) do
      {:ok, {:ok, subscription}} when is_map(subscription) -> {:ok, subscription}
      {:ok, {:error, error}} when is_map(error) -> {:target_error, error}
      {:ok, _other} -> {:error, "unexpected_response", %{"function" => "subscribe"}}
      failure -> failure
    end
  end

  defp unsubscribe(node, session, timeout_ms) do
    if node in Node.list(:connected) do
      _result = Observer.call(node, Insider.Live, :unsubscribe, [session, self()], timeout_ms)
    end

    :ok
  end

  defp cancel(timer, message) do
    _left = Process.cancel_timer(timer)

    receive do
      ^message -> :ok
    after
      0 -> :ok
    end
  end

  # The stop message SIGTERM sends, as for watch.
  @doc false
  @spec stop_message() :: term()
  def stop_message, do: Watch.stop_message()
end
