defmodule Insider.Live.Anomalies do
  @moduledoc false

  # The digest's findings that deserve to be read first, ranked, one line
  # each with the next command to run. A finding on a line
  # below the latency table (such as a request burst that caused the
  # slowness) is read late, so the findings come first.
  #
  # Pure: it reads only fields the digest already computed. In order:
  #
  # 1. `request_burst`: each request burst, then `value_changes`: a
  #    watched key (`watch_writes`) written more than once, by whom (`Insider.Collector.RequestTiming`);
  #    when the Recorder evicted events in the window, it says other bursts
  #    may be missing;
  # 2. `pre_handler_wait`: the slowest wait before the endpoint, from @wait_us;
  # 3. `error_spike`: the most frequent error signature, from @errors events;
  # 4. `crash_loop`: each child terminated repeatedly for one reason;
  # 5. `mailbox`: the longest mailbox from @mailbox messages, and `run_queue`
  #    when the run queue reached @run_queue;
  # 6. `evicted`: events the Recorder evicted in the window.
  #
  # Each anomaly has an `identity`: a hash of its kind and what it is about
  # (an offender and its reason fingerprint, a key, an error signature, a
  # route, a process), so a stored baseline holds no name or value; and its
  # `count` with its `unit` (`rate`: a count over the window's `span_ms`, at
  # least a minute; or `level`). A reader can mark the current candidates
  # normal for the session (`baseline/4`, kept by the owner); later digests
  # and `status` fold each candidate against it (`fold/2`) before the top
  # one of a kind is chosen, so a known maximum never hides a new one below
  # it, and one at @resurface times its baselined rate (compared unrounded)
  # comes back, saying so. In dev, known noise (a restart loop, the
  # observer's own traffic) would otherwise lead every digest and hide
  # what is new.

  @wait_us 1_000_000
  @errors 5
  @mailbox 100
  @run_queue 50
  @observer "mix insider.live"

  alias Insider.Live.QueryShapes
  @resurface 10
  @max_baseline 64

  @doc "The anomalies of a digest, most important first."
  @spec of(map()) :: [map()]
  def of(digest), do: digest |> candidates() |> select()

  @doc """
  Every candidate anomaly of a digest, in rank order: of the kinds a digest
  shows one of (`pre_handler_wait`, `error_spike`, `mailbox`), each that
  qualifies, the leading one first.
  """
  @spec candidates(map()) :: [map()]
  def candidates(digest) do
    session = digest["session_id"] || "SESSION_ID"
    evicted = evicted(digest["gaps"] || [])
    requests = digest["requests"] || %{}
    span_ms = max(get_in(digest, ["window", "span_ms"]) || 0, 60_000)

    [
      Enum.map(requests["bursts"] || [], &burst(&1, evicted, session)),
      Enum.map(Enum.take(digest["changes"] || [], 3), &value_changes(&1, evicted, session)),
      waits(requests),
      n_plus_one(digest["repeated_queries"] || [], session),
      errors(digest["error_signatures"] || [], session),
      Enum.map(digest["crash_loops"] || [], &loop(&1, session)),
      mailboxes(digest["processes"] || [], session),
      run_queue(digest["vm"], session),
      eviction(evicted, requests, session)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&if(&1["unit"] == "rate", do: Map.put(&1, "span_ms", span_ms), else: &1))
  end

  @single ~w(pre_handler_wait error_spike mailbox)

  # The first of each kind the digest shows one of; every other candidate.
  defp select(candidates) do
    {_seen, kept} =
      Enum.reduce(candidates, {MapSet.new(), []}, fn anomaly, {seen, kept} ->
        kind = anomaly["kind"]

        if kind in @single and MapSet.member?(seen, kind),
          do: {seen, kept},
          else: {MapSet.put(seen, kind), [anomaly | kept]}
      end)

    Enum.reverse(kept)
  end

  @doc """
  A baseline of a digest's candidates, marked normal at `set_at` over the
  window `since`: each one's kind, identity, count, and window (never its
  line or anything it names), then the entries of `previous` the digest
  does not have, at most @max_baseline in all.
  """
  @spec baseline(map(), String.t(), term(), map() | nil) :: map()
  def baseline(digest, set_at, since, previous) do
    current =
      digest
      |> candidates()
      |> Enum.uniq_by(& &1["identity"])
      |> Enum.map(&Map.take(&1, ["kind", "identity", "count", "span_ms", "unit"]))

    ids = MapSet.new(current, & &1["identity"])
    kept = Enum.reject((previous || %{})["entries"] || [], &MapSet.member?(ids, &1["identity"]))

    %{
      "set_at" => set_at,
      "since" => since,
      "entries" => Enum.take(current ++ kept, @max_baseline)
    }
  end

  @doc "The most entries one baseline keeps."
  @spec max_baseline() :: pos_integer()
  def max_baseline, do: @max_baseline

  @doc """
  Folds a digest's candidates through `baseline`, each on its own, then
  chooses the top new one of each kind: `"anomalies"` keeps the new ones
  (and baselined ones at @resurface times their baselined rate or level,
  saying so), `"anomalies_known"` the baselined ones, and `"baseline"`
  says when it was set and how many it hid. Without a baseline nothing is
  folded.
  """
  @spec fold(map(), map() | nil) :: map()
  def fold(digest, nil),
    do:
      Map.merge(digest, %{
        "anomalies" => digest["anomalies"] || of(digest),
        "anomalies_known" => [],
        "baseline" => nil
      })

  def fold(digest, %{"entries" => entries} = baseline) do
    known = Map.new(entries, &{&1["identity"], &1})

    {shown, hidden} =
      digest
      |> candidates()
      |> Enum.map(&compare(&1, known[&1["identity"]], baseline["set_at"]))
      |> Enum.split_with(&(&1["baselined"] != true))

    hidden = Enum.uniq_by(hidden, & &1["identity"])

    Map.merge(digest, %{
      "anomalies" => select(shown),
      "anomalies_known" => hidden,
      "baseline" => %{
        "set_at" => baseline["set_at"],
        "since" => baseline["since"],
        "entries" => length(entries),
        "hidden" => length(hidden)
      }
    })
  end

  defp compare(anomaly, nil, _set_at), do: anomaly

  defp compare(anomaly, entry, set_at) do
    if resurfaced?(anomaly, entry) do
      factor = round(ratio(anomaly, entry))

      Map.merge(anomaly, %{
        "line" =>
          anomaly["line"] <>
            " Back above its baseline: #{factor}x (#{measure(entry)} when marked normal at #{hour(set_at)}).",
        "resurfaced" => %{"factor" => factor}
      })
    else
      Map.put(anomaly, "baselined", true)
    end
  end

  # Rates compare as count / span, cross-multiplied, so nothing is rounded.
  defp resurfaced?(%{"unit" => "rate", "count" => now, "span_ms" => now_ms}, %{
         "unit" => "rate",
         "count" => was,
         "span_ms" => was_ms
       })
       when is_integer(now) and is_integer(was) and is_integer(now_ms) and is_integer(was_ms),
       do: now * was_ms >= @resurface * max(was, 1) * now_ms

  defp resurfaced?(%{"count" => now}, %{"count" => was})
       when is_integer(now) and is_integer(was),
       do: now >= @resurface * max(was, 1)

  defp resurfaced?(_anomaly, _entry), do: false

  defp ratio(%{"unit" => "rate"} = now, %{"unit" => "rate"} = was),
    do: now["count"] * was["span_ms"] / (max(was["count"], 1) * now["span_ms"])

  defp ratio(now, was), do: now["count"] / max(was["count"], 1)

  # A rate as a reader reads it: per minute, else per hour, else per day.
  defp measure(%{"unit" => "rate", "count" => count, "span_ms" => span_ms}) do
    per_minute = count * 60_000 / span_ms

    cond do
      per_minute >= 1 -> "#{decimal(per_minute)}/min"
      per_minute * 60 >= 1 -> "#{decimal(per_minute * 60)}/h"
      true -> "#{decimal(per_minute * 1_440)}/day"
    end
  end

  defp measure(%{"count" => count}), do: "level #{count}"

  defp decimal(value) do
    rounded = Float.round(value * 1.0, 1)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  @status_window "latest-60s"

  @doc """
  The anomaly fields of `status` from its digest read: the anomalies, and
  whether the window was read whole; when it was not, `"anomalies_note"`
  says why (the read stopped, or failed), so no anomaly is never mistaken
  for none.
  """
  @spec status({:ok, map()} | {:error, term()}) :: map()
  def status({:ok, %{"window" => %{"complete" => true}} = digest}),
    do:
      Map.merge(known(digest), %{
        "anomalies" => digest["anomalies"],
        "anomalies_window" => @status_window,
        "anomalies_complete" => true
      })

  def status({:ok, digest}) do
    window = digest["window"] || %{}

    digest
    |> known()
    |> Map.merge(%{
      "anomalies" => digest["anomalies"],
      "anomalies_window" => @status_window,
      "anomalies_complete" => false,
      "anomalies_note" =>
        "incomplete: the read stopped (#{window["stopped_by"]}) after #{window["events"]} events of the last 60 s, " <>
          "so an anomaly in the rest is not shown; run digest for the whole window"
    })
  end

  def status({:error, error}) do
    code = if is_map(error), do: error["code"], else: inspect(error)

    %{
      "anomalies" => nil,
      "anomalies_window" => @status_window,
      "anomalies_complete" => false,
      "anomalies_note" => "incomplete: the anomalies could not be read (#{code})"
    }
  end

  # How many known-normal anomalies a folded status read hid, and when the
  # baseline was set.
  defp known(digest),
    do: %{
      "anomalies_known" => length(digest["anomalies_known"] || []),
      "baseline_set_at" => get_in(digest, ["baseline", "set_at"])
    }

  @doc """
  A baseline as text: when it was set, and each entry's kind, identity,
  and rate. Identities are hashes, so the text names nothing the session
  recorded.
  """
  @spec baseline_lines(map() | nil) :: String.t()
  def baseline_lines(nil), do: "No baseline set; digests and status show every anomaly."

  def baseline_lines(baseline) do
    entries = baseline["entries"]

    Enum.join(
      [
        "Baseline set #{hour(baseline["set_at"])} (#{length(entries)} known-normal " <>
          "#{plural(length(entries), "identity", "identities")}; one at #{@resurface}x its rate comes back):"
        | Enum.map(entries, &"  - #{&1["kind"]} #{&1["identity"]} (#{measure(&1)})")
      ] ++
        [
          "Identities are hashes, never names or values; digest --show-baseline lists the anomalies they hide."
        ],
      "\n"
    )
  end

  @doc "The window `status` reads its anomalies over."
  @spec status_window() :: String.t()
  def status_window, do: @status_window

  @doc """
  The digest's text block: a heading and one numbered line per anomaly. Of
  a folded digest (`fold/2`), the new ones lead and the baselined ones are
  one count, listed after them when `"show_baseline"` is set.
  """
  @spec lines([map()] | map()) :: [String.t()]
  def lines(anomalies) when is_list(anomalies), do: lines(%{"anomalies" => anomalies})

  def lines(%{"anomalies" => anomalies} = digest) do
    known = digest["anomalies_known"] || []
    set = digest["baseline"] && hour(digest["baseline"]["set_at"])

    hidden =
      "#{length(known)} known-normal #{plural(length(known), "anomaly", "anomalies")} hidden"

    numbered =
      anomalies
      |> Enum.with_index(1)
      |> Enum.map(fn {anomaly, n} ->
        "  #{n}. #{anomaly["line"]}\n     next: #{anomaly["command"]}"
      end)

    head =
      cond do
        anomalies == [] and known == [] ->
          ["Anomalies: none in this window."]

        anomalies == [] ->
          ["Anomalies: none new; #{hidden} (baseline set #{set}; --show-baseline)."]

        known == [] ->
          ["Anomalies (most important first):" | numbered]

        true ->
          ["Anomalies (new first; #{hidden}, baseline set #{set}; --show-baseline):" | numbered]
      end

    known_lines =
      if digest["show_baseline"] == true and known != [],
        do: ["Known-normal (baseline set #{set}):" | Enum.map(known, &"  - #{&1["line"]}")],
        else: []

    head ++ known_lines ++ observer_lines(get_in(digest, ["requests", "observer"]))
  end

  defp observer_lines(%{"requests" => n, "paths" => paths}) when n > 0,
    do: [
      "Observer traffic: #{n} #{plural(n, "request")} to #{Enum.join(paths, ", ")} " <>
        "(the observer's own calls) #{if n == 1, do: "is", else: "are"} left out of the anomalies."
    ]

  defp observer_lines(_observer), do: []

  defp anomaly(kind, line, command, {identity, count, unit}),
    do: %{
      "kind" => kind,
      "line" => line,
      "command" => command,
      "identity" => identity(kind, identity),
      "count" => count,
      "unit" => unit
    }

  # A hash of the kind and what the anomaly is about: opaque, so a stored
  # baseline holds no name, path, message, or value.
  defp identity(kind, about) do
    :crypto.hash(:sha256, [kind, 0, :erlang.term_to_binary(about)])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp burst(burst, evicted, session) do
    sources =
      burst["sources"]
      |> Enum.take(2)
      |> Enum.map_join(", ", fn
        %{"source" => source, "requests" => n} when source in ["traced", "untraced"] ->
          "#{n} #{source}"

        %{"source" => source, "requests" => n} ->
          "#{n} from #{source}"
      end)

    waits =
      [
        burst["max_wait_us"] && "waits up to #{duration(burst["max_wait_us"])}",
        overlap(burst)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    waits = if waits == "", do: "", else: "; " <> waits

    lost =
      if evicted > 0,
        do: " #{evicted} events of this window were evicted, so other bursts may be missing.",
        else: ""

    {where, command} =
      if burst["max_wait_us"],
        do:
          {" Inspect the code reloader during the next burst to see where requests queue.",
           "#{@observer} process \"${N[@]}\" --name Phoenix.CodeReloader.Server"},
        else:
          {"",
           "#{@observer} events \"${N[@]}\" --session #{session} --cursor 0 --view-kind bandit.request.stop --format compact"}

    anomaly(
      "request_burst",
      "Request burst at #{clock(burst["at"])}: #{burst["requests"]} requests in #{burst["seconds"]} s " <>
        "(usually #{burst["baseline_per_s"]}/s), #{sources}#{waits}.#{lost}#{where}",
      command,
      {get_in(burst, ["sources", Access.at(0), "source"]), burst["requests"], "level"}
    )
  end

  # A watched key written more than once (`Insider.Live.Changes`).
  # The counts are lower bounds when the digest capped its writes or the
  # window lost events: "at least", and why.
  defp value_changes(row, evicted, session) do
    values = if row["values"] > 0, do: " (#{row["values"]} values)", else: ""
    complete? = row["complete"] != false and evicted == 0
    times = if complete?, do: "#{row["writes"]} times", else: "at least #{row["writes"]} times"
    note = if complete?, do: "", else: "; some writes were evicted or not examined"

    writers =
      Enum.map_join(row["writers"], ", ", fn %{"writer" => writer, "writes" => n} ->
        "#{writer} ×#{n}"
      end)

    anomaly(
      "value_changes",
      "Value changed: #{row["key"]} written #{times} in this window#{values} by #{writers}#{note}.",
      "#{@observer} changes \"${N[@]}\" --session #{session} --key #{shell_quote(row["key"])}",
      {row["key"], row["writes"], "rate"}
    )
  end

  # A shell single-quoted word.
  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp overlap(%{"others_overlapping" => n, "others_max_wait_us" => wait})
       when is_integer(n) and n > 0 and is_integer(wait),
       do: "#{n} other #{plural(n, "request")} waited up to #{duration(wait)}"

  defp overlap(_burst), do: nil

  defp waits(requests) do
    for %{"wait_us" => wait} = row <- requests["slowest_waits"] || [],
        is_integer(wait) and wait >= @wait_us,
        do: wait(row, wait, requests)
  end

  defp wait(top, wait, requests) do
    request =
      [top["method"], top["path"], top["status"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    agent = if is_binary(top["user_agent"]), do: " (#{top["user_agent"]})", else: ""

    anomaly(
      "pre_handler_wait",
      "Pre-handler wait: #{requests["waited_100ms"]} of #{requests["requests"]} requests waited 100 ms or more; " <>
        "slowest #{duration(wait)} #{request}#{agent} at #{clock(top["at"])}, before Phoenix's endpoint telemetry " <>
        "(in dev the code reloader and the plugs before Plug.Telemetry).",
      "#{@observer} process \"${N[@]}\" --name Phoenix.CodeReloader.Server",
      {{top["method"], top["path"]}, wait, "level"}
    )
  end

  defp errors(signatures, session) do
    for top <- signatures, top["count"] >= @errors and not supervisor?(top) do
      processes = if top["processes"], do: " (#{top["processes"]} processes)", else: ""

      anomaly(
        "error_spike",
        "Error spike: #{top["count"]}x #{top["signature"]}#{processes}.",
        "#{@observer} events \"${N[@]}\" --session #{session} --cursor 0 --view-min-severity error --format compact",
        {top["signature"], top["count"], "rate"}
      )
    end
  end

  # One query shape repeated @n_plus_one times or more in one request
  # (`Insider.Live.QueryShapes`), the worst request of each pattern, at most
  # three.
  defp n_plus_one(rows, session) do
    rows
    |> Enum.map(fn %{"trace_id" => trace_id, "groups" => groups} ->
      anomaly(
        "n_plus_one",
        "N+1 queries in one request: #{Enum.map_join(groups, "; ", &QueryShapes.line/1)} (trace #{trace_id}).",
        "#{@observer} trace \"${N[@]}\" --session #{session} --trace-id #{trace_id} --human",
        {Enum.map(groups, &{&1["source"], &1["shape"], &1["from"]}),
         groups |> hd() |> Map.fetch!("count"), "level"}
      )
    end)
    |> Enum.uniq_by(& &1["identity"])
    |> Enum.take(3)
  end

  defp supervisor?(%{"signature" => "supervisor_child_terminated" <> _rest}), do: true
  defp supervisor?(_signature), do: false

  defp loop(loop, session) do
    period = if loop["period_ms"], do: ", every #{duration(loop["period_ms"] * 1_000)}", else: ""

    anomaly(
      "crash_loop",
      "Restart loop: #{loop["offender"]} restarted #{loop["restarts"]} times#{period}, same reason.",
      "#{@observer} events \"${N[@]}\" --session #{session} --cursor 0 --view-kind supervisor_child_terminated --format compact",
      {{loop["offender_id"] || loop["offender"], loop["reason_fingerprint"]}, loop["restarts"],
       "rate"}
    )
  end

  # A process is named only by a registered name the Poller saw; a label
  # that is an initial call (erlang.apply/2) is not one, so its pid is used.
  defp mailboxes(processes, session) do
    for %{"message_queue_len" => length} = top <- processes,
        is_integer(length) and length >= @mailbox,
        do: mailbox(top, length, session)
  end

  defp mailbox(top, length, session) do
    command =
      cond do
        is_binary(top["registered_name"]) ->
          "#{@observer} process \"${N[@]}\" --name #{top["registered_name"]}"

        is_binary(top["pid"]) ->
          "#{@observer} process \"${N[@]}\" --pid '#{top["pid"]}'"

        true ->
          "#{@observer} events \"${N[@]}\" --session #{session} --cursor 0 --view-source poller --format compact"
      end

    anomaly(
      "mailbox",
      "Mailbox: #{top["process"]} holds #{length} messages (max #{top["max_message_queue_len"]}).",
      command,
      {top["registered_name"] || top["process"], length, "level"}
    )
  end

  defp run_queue(%{"metrics" => %{"run_queue_length" => %{"last" => last}}}, session)
       when is_integer(last) and last >= @run_queue do
    anomaly(
      "run_queue",
      "Run queue: #{last} processes waiting for a scheduler at the window's last sample; " <>
        "the Poller's process_top ranks who runs most.",
      "#{@observer} events \"${N[@]}\" --session #{session} --cursor 0 --view-kind process_top --format compact",
      {nil, last, "level"}
    )
  end

  defp run_queue(_vm, _session), do: nil

  defp eviction(0, _requests, _session), do: nil

  defp eviction(evicted, requests, session) do
    note =
      if (requests["bursts"] || []) == [],
        do: "; a request burst or error spike among them is not counted",
        else: ""

    anomaly(
      "evicted",
      "Evicted: the Recorder evicted #{evicted} events in this window#{note}. A larger Recorder, and " <>
        "reading digest --since latest-60s more often, keep more.",
      "#{@observer} amend \"${N[@]}\" --session #{session} --max-events 4096",
      {nil, evicted, "rate"}
    )
  end

  defp evicted(gaps) do
    gaps
    |> Enum.filter(&(&1["reason"] == "evicted" and is_integer(&1["count"])))
    |> Enum.map(& &1["count"])
    |> Enum.sum()
  end

  defp duration(us) when us >= 1_000_000,
    do: :io_lib.format("~.1f s", [us / 1_000_000]) |> to_string() |> String.replace(".0 s", " s")

  defp duration(us), do: "#{div(us, 1_000)} ms"

  defp plural(n, noun), do: plural(n, noun, noun <> "s")
  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  defp clock(nil), do: "?"
  defp clock(iso), do: String.slice(iso, 11, 8)

  defp hour(iso) when is_binary(iso), do: String.slice(iso, 11, 5)
  defp hour(_iso), do: "?"
end
