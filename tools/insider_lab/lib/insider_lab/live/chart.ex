defmodule Insider.Lab.Live.Chart do
  @moduledoc false

  # `chart`: a picture of a session for the programmer an agent pairs with.
  # The idea is credited to Orion (https://github.com/LivewareProblems/Orion),
  # Thomas Depierre's distributed dynamic profiler for the BEAM, whose live
  # latency chart inspired it. No Orion code is used.
  # The observer reads the session through the ordinary read APIs, with its
  # own reader, so the page shows exactly what those reads disclosed under
  # the session's profile, and this module turns the disclosed entries into
  # time series:
  #
  # - requests per second, from server request stops (`bandit`, `cowboy`),
  #   else the endpoint's stops;
  # - request latency p50 and p95, from the requests' recorded durations
  #   (`total_us`, else the endpoint's `handler_us`);
  # - the wait before the endpoint, paired as `Insider.Collector.RequestTiming`
  #   pairs it for the digest;
  # - errors by signature (`Insider.Live.Digest.signature/1`), the top three
  #   and the rest;
  # - the longest mailbox of each Poller sample;
  # - total and binary memory from each `vm_sample`;
  # - events the Recorder evicted, from the reads' gaps.
  #
  # A series the window has no data for is left out and named in the legend,
  # with why when the profile withheld it. Marks are vertical lines, the
  # window since a mark is shaded, and the digest's anomalies are numbered
  # markers at the peak of the series they are about, with their lines as
  # captions. The headline is the most notable peak, and how long after the
  # mark before it.
  #
  # `Insider.Lab.Live.Chart.Html` renders the model; `Insider.Lab.Live.Chart.Run`
  # reads the session and serves the live form.

  alias Insider.Collector.RequestTiming
  alias Insider.Lab.Live.Chart.Html
  alias Insider.Live.Digest

  @buckets 60
  @steps_s [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
  @top_signatures 3
  @wait_shown_us 1_000_000
  @error_severities ["error", "critical", "alert", "emergency"]

  @series_names %{
    requests: "requests",
    latency: "request latency",
    waits: "waits before the endpoint",
    errors: "errors",
    mailbox: "mailbox lengths",
    memory: "memory",
    evictions: "evictions"
  }

  @order [:requests, :latency, :waits, :errors, :mailbox, :memory, :evictions]

  @doc "The page for `input` (see `model/1`)."
  @spec html(map()) :: iodata()
  def html(input), do: input |> model() |> Html.render()

  @doc """
  The chart of one read of a session. `input` has `:session_id`, `:node`,
  `:profile`, `:entries` (disclosed `%{"receipt", "event"}`), `:evicted`
  (`%{"at_us", "count"}` per read), `:marks`, `:since_mark` (the mark the
  window starts at, or nil), `:digest` (nil, or one with `"anomalies"` and
  `"text"`, and the `"window"` it read), `:status`, `:window`
  (`{from_us, to_us}`), `:now_us`, and `:live` (nil for the static page,
  else `%{refresh_s, stopped}`); optionally `:fit_start` (start the window
  at the first thing it plots, when that is later), `:incomplete` (the
  reader's notes of what it could not read) and `:covered_from_us` (the
  oldest time the kept entries cover, when older ones were dropped).
  """
  @spec model(map()) :: map()
  def model(input) do
    entries = input.entries
    requests = requests(entries)
    paired = RequestTiming.pair(entries)
    {from, to} = input |> window() |> fit(input, requests, entries)
    step = step_s(to - from)
    within? = &(is_integer(&1) and &1 >= from and &1 <= to)
    requests = Enum.filter(requests, &within?.(&1.at_us))
    paired = Enum.filter(paired, &within?.(&1["arrival_us"]))
    withheld? = Enum.any?(entries, &timing_withheld?/1)

    series =
      %{
        requests: requests_series(requests, from, to, step),
        latency: latency_series(requests, from, to, step),
        waits: waits_series(paired, from, to, step),
        errors: errors_series(entries, within?, from, to, step),
        mailbox: mailbox_series(entries),
        memory: memory_series(entries),
        evictions: evictions_series(input.evicted, from, to, step)
      }

    present = for name <- @order, series[name] != nil, do: {name, series[name]}

    absent =
      for name <- @order, series[name] == nil do
        if withheld? and name in [:latency, :waits],
          do: @series_names[name] <> " (timing withheld under strict)",
          else: @series_names[name]
      end

    repeated = repeated_labels(input.marks)

    marks =
      input.marks
      |> Enum.map(&mark(&1, repeated))
      |> Enum.filter(&(&1.at_us >= from and &1.at_us <= to))

    anomalies = anomalies(input.digest, series)

    %{
      session_id: input.session_id,
      node: input.node,
      profile: input.profile,
      from_us: from,
      to_us: to,
      step_s: step,
      series: present,
      absent: absent,
      marks: marks,
      since_mark: input.since_mark && mark(input.since_mark, repeated),
      anomalies: anomalies,
      headline: headline(series, marks, anomalies),
      summary: summary(input.digest),
      incomplete: incomplete(input),
      covered_from_us: covered_from(input[:covered_from_us], from, to),
      status: input.status || %{},
      live: input.live,
      now_us: input.now_us,
      events: length(entries)
    }
  end

  ## Window and buckets

  defp window(%{window: {from, to}}) when is_integer(from) and is_integer(to) and to > from,
    do: {from, to}

  defp window(%{window: {from, _to}, now_us: now}) when is_integer(from),
    do: {from, max(now, from + 1_000_000)}

  defp window(%{now_us: now}), do: {now - 60_000_000, now}

  # A window that began before anything in it starts at the first thing it
  # plots (a request at its arrival, a mark), so the chart draws no minutes
  # of nothing.
  defp fit({from, to}, %{fit_start: true} = input, requests, entries) do
    times =
      Enum.map(requests, & &1.at_us) ++
        Enum.map(entries, &RequestTiming.wall_us(get_in(&1, ["event", "wall_time"]))) ++
        Enum.map(input.marks, &RequestTiming.wall_us(&1["at"])) ++
        Enum.map(input.evicted || [], & &1["at_us"])

    case times
         |> Enum.filter(&(is_integer(&1) and &1 >= from and &1 < to))
         |> Enum.min(fn -> nil end) do
      nil -> {from, to}
      first -> {first, to}
    end
  end

  defp fit(window, _input, _requests, _entries), do: window

  # A step of a whole number of seconds that gives about @buckets buckets.
  defp step_s(span_us) do
    wanted = span_us / (@buckets * 1_000_000)
    Enum.find(@steps_s, List.last(@steps_s), &(&1 >= wanted))
  end

  defp bucket_starts(from, to, step) do
    step_us = step * 1_000_000
    first = from - rem(from, step_us)
    Stream.iterate(first, &(&1 + step_us)) |> Enum.take_while(&(&1 <= to))
  end

  defp bucket(at, step), do: at - rem(at, step * 1_000_000)

  defp counts_per_bucket(times, from, to, step) do
    counts = Enum.frequencies_by(times, &bucket(&1, step))
    for start <- bucket_starts(from, to, step), do: {start, Map.get(counts, start, 0)}
  end

  ## Requests

  # Every server request stop, timed or not; the endpoint's stops when the
  # node records no server stops.
  defp requests(entries) do
    found = for entry <- entries, request = request(entry), request != nil, do: request
    servers = Enum.filter(found, &(&1.role == "server"))
    if servers == [], do: Enum.filter(found, &(&1.role == "handler")), else: servers
  end

  defp request(%{"event" => %{"attributes" => %{"request" => %{"role" => role} = r}} = event})
       when role in ["server", "handler"] do
    with end_us when is_integer(end_us) <- RequestTiming.wall_us(event["wall_time"]) do
      duration = r["total_us"] || r["handler_us"]
      arrival = if is_integer(duration), do: end_us - duration, else: end_us
      %{role: role, at_us: arrival, duration_us: duration}
    end
  end

  defp request(_entry), do: nil

  defp timing_withheld?(%{
         "event" => %{"attributes" => %{"request" => %{"timing_withheld" => true}}}
       }),
       do: true

  defp timing_withheld?(_entry), do: false

  defp requests_series([], _from, _to, _step), do: nil

  defp requests_series(requests, from, to, step) do
    points =
      requests
      |> Enum.map(& &1.at_us)
      |> counts_per_bucket(from, to, step)
      |> Enum.map(fn {at, count} -> {at, count / step} end)

    %{title: "Requests", unit: "req/s", kind: :bars, lines: [%{name: "requests", points: points}]}
    |> with_peak()
  end

  # Requests are placed at their arrival; the caller keeps only those that
  # arrived in the window.
  defp latency_series(requests, from, to, step) do
    by_bucket =
      requests
      |> Enum.filter(&is_integer(&1.duration_us))
      |> Enum.group_by(&bucket(&1.at_us, step), & &1.duration_us)

    {p50, p95} =
      bucket_starts(from, to, step)
      |> Enum.flat_map(fn start ->
        case by_bucket[start] do
          nil -> []
          durations -> [{{start, percentile(durations, 50)}, {start, percentile(durations, 95)}}]
        end
      end)
      |> Enum.unzip()

    if p95 == [] do
      nil
    else
      {unit, scale} = time_unit(Enum.max(Enum.map(p95, &elem(&1, 1))))

      %{
        title: "Request latency p50 / p95",
        unit: unit,
        kind: :lines,
        lines: [
          %{name: "p95", points: scale(p95, scale)},
          %{name: "p50", points: scale(p50, scale)}
        ]
      }
      |> with_peak()
    end
  end

  defp waits_series(paired, from, to, step) do
    waits =
      for %{"wait_us" => wait, "arrival_us" => at} <- paired, is_integer(wait), do: {at, wait}

    if waits == [] do
      nil
    else
      max_by_bucket =
        waits
        |> Enum.group_by(&bucket(elem(&1, 0), step))
        |> Map.new(fn {start, list} -> {start, Enum.max_by(list, &elem(&1, 1))} end)

      points =
        for start <- bucket_starts(from, to, step),
            do: {start, elem(Map.get(max_by_bucket, start, {start, 0}), 1)}

      {unit, scale} = time_unit(Enum.max(Enum.map(points, &elem(&1, 1))))
      peak = Enum.max_by(waits, &elem(&1, 1))

      %{
        title: "Wait before the endpoint",
        unit: unit,
        kind: :bars,
        lines: [%{name: "slowest wait", points: scale(points, scale)}],
        peak: %{at_us: elem(peak, 0), value_us: elem(peak, 1)}
      }
    end
  end

  ## Errors

  defp errors_series(entries, within?, from, to, step) do
    errors =
      for %{"event" => %{"severity" => severity} = event} <- entries,
          severity in @error_severities,
          at = RequestTiming.wall_us(event["wall_time"]),
          within?.(at),
          do: {at, Digest.signature(event)}

    if errors == [] do
      nil
    else
      top =
        errors
        |> Enum.frequencies_by(&elem(&1, 1))
        |> Enum.sort_by(fn {signature, count} -> {-count, signature} end)
        |> Enum.take(@top_signatures)
        |> Enum.map(&elem(&1, 0))

      groups =
        Enum.group_by(errors, fn {_at, signature} ->
          if signature in top, do: signature, else: :other
        end)

      lines =
        for name <- top ++ [:other], Map.has_key?(groups, name) do
          points = groups[name] |> Enum.map(&elem(&1, 0)) |> counts_per_bucket(from, to, step)
          %{name: if(name == :other, do: "other errors", else: name), points: points}
        end

      %{title: "Errors by signature", unit: "events", kind: :stacked, lines: lines}
      |> with_peak()
    end
  end

  ## Poller

  defp mailbox_series(entries) do
    points =
      for %{"event" => %{"source" => "poller", "kind" => kind} = event} <- entries,
          kind in ["process_top", "process_sample", "process_watch"],
          at = RequestTiming.wall_us(event["wall_time"]),
          is_integer(at),
          length = longest(kind, event["attributes"]),
          is_integer(length),
          do: {at, length}

    if points == [],
      do: nil,
      else:
        with_peak(%{
          title: "Longest mailbox",
          unit: "messages",
          kind: :lines,
          lines: [%{name: "longest mailbox", points: Enum.sort(points)}]
        })
  end

  defp longest("process_top", %{"metrics" => %{"by_message_queue_len" => rows}})
       when is_list(rows),
       do:
         rows
         |> Enum.map(& &1["message_queue_len"])
         |> Enum.filter(&is_integer/1)
         |> Enum.max(fn -> nil end)

  defp longest(_kind, %{"metrics" => %{"message_queue_len" => length}}), do: length
  defp longest(_kind, _attributes), do: nil

  defp memory_series(entries) do
    samples =
      for %{"event" => %{"source" => "poller", "kind" => "vm_sample"} = event} <- entries,
          at = RequestTiming.wall_us(event["wall_time"]),
          is_integer(at),
          metrics = get_in(event, ["attributes", "metrics"]) || %{},
          do: {at, metrics["total_bytes"], metrics["binary_bytes"]}

    lines =
      for {name, index} <- [{"total", 1}, {"binary", 2}],
          points =
            for(
              s <- samples,
              is_integer(elem(s, index)),
              do: {elem(s, 0), elem(s, index) / 1_048_576}
            ),
          points != [],
          do: %{name: name, points: Enum.sort(points)}

    if lines == [],
      do: nil,
      else:
        with_peak(%{title: "Memory and binary memory", unit: "MiB", kind: :lines, lines: lines})
  end

  defp evictions_series(evicted, from, to, step) do
    evicted =
      for %{"at_us" => at, "count" => count} <- evicted || [],
          is_integer(at) and is_integer(count) and count > 0,
          do: {at, count}

    if evicted == [] do
      nil
    else
      sums =
        Enum.reduce(evicted, %{}, fn {at, count}, acc ->
          Map.update(acc, bucket(at, step), count, &(&1 + count))
        end)

      points = for start <- bucket_starts(from, to, step), do: {start, Map.get(sums, start, 0)}

      with_peak(%{
        title: "Evicted events",
        unit: "events",
        kind: :bars,
        lines: [%{name: "evicted", points: points}]
      })
    end
  end

  ## Helpers

  defp with_peak(%{lines: lines} = series) do
    {at, value} =
      lines
      |> Enum.flat_map(& &1.points)
      |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

    Map.put(series, :peak, %{at_us: at, value: value})
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(length(sorted) * p / 100) - 1, 0))
  end

  # Microseconds as ms up to two seconds, else s.
  defp time_unit(max_us) when max_us >= 2_000_000, do: {"s", 1_000_000}
  defp time_unit(_max_us), do: {"ms", 1_000}

  defp scale(points, divisor), do: Enum.map(points, fn {at, us} -> {at, us / divisor} end)

  # A label more than one mark carries is shown with the mark's number.
  defp mark(%{"at" => at} = mark, repeated) do
    {:ok, time, _offset} = DateTime.from_iso8601(at)
    label = mark["label"] || ""

    %{
      index: mark["index"],
      label: label,
      shown: if(label in repeated, do: "#{label} (##{mark["index"]})", else: label),
      at_us: DateTime.to_unix(time, :microsecond)
    }
  end

  defp repeated_labels(marks) do
    marks
    |> Enum.frequencies_by(&(&1["label"] || ""))
    |> Enum.flat_map(fn {label, count} -> if count > 1, do: [label], else: [] end)
  end

  ## Anomalies, headline, summary

  # Each anomaly is placed at the peak of the series it is about; one the
  # chart has no series for is a caption only.
  @anomaly_series %{
    "request_burst" => :requests,
    "pre_handler_wait" => :waits,
    "error_spike" => :errors,
    "crash_loop" => :errors,
    "mailbox" => :mailbox,
    "run_queue" => :mailbox,
    "evicted" => :evictions,
    "n_plus_one" => :latency
  }

  defp anomalies(nil, _series), do: []

  defp anomalies(digest, series) do
    for {anomaly, number} <- Enum.with_index(digest["anomalies"] || [], 1) do
      name = @anomaly_series[anomaly["kind"]]
      peak = name && series[name] && series[name].peak

      %{
        number: number,
        line: anomaly["line"] || anomaly["kind"],
        series: if(peak && peak.at_us, do: name),
        at_us: peak && peak.at_us
      }
    end
  end

  defp headline(series, marks, anomalies) do
    {text, at} =
      cond do
        series.waits && series.waits.peak.value_us >= @wait_shown_us ->
          {"Request waits rose to #{seconds(series.waits.peak.value_us)}",
           series.waits.peak.at_us}

        series.errors ->
          {"#{error_total(series.errors)} errors, peaking", series.errors.peak.at_us}

        series.latency && series.latency.peak.value > 0 ->
          {"Request latency p95 reached #{number(series.latency.peak.value)} #{series.latency.unit}",
           series.latency.peak.at_us}

        anomalies != [] ->
          {hd(anomalies).line, nil}

        series.requests ->
          {"No errors and no slow waits", nil}

        true ->
          {"Nothing recorded yet in this window", nil}
      end

    if at, do: {text, at, mark_before(marks, at)}, else: {text, nil, nil}
  end

  defp error_total(%{lines: lines}),
    do: lines |> Enum.flat_map(& &1.points) |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp mark_before(marks, at) do
    marks |> Enum.filter(&(&1.at_us <= at)) |> Enum.max_by(& &1.at_us, fn -> nil end)
  end

  defp seconds(us), do: :erlang.float_to_binary(us / 1_000_000, decimals: 1) <> " s"

  defp number(value) when value >= 100, do: Integer.to_string(round(value))
  defp number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  # The digest's lead lines: its first line, the anomalies, and the window.
  defp summary(nil), do: []

  defp summary(%{"text" => text}) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.take_while(&(not String.starts_with?(&1, "Severity:")))
    |> Enum.take(14)
  end

  defp summary(_digest), do: []

  # What the chart could not show, and why: the reader's notes (entries
  # dropped past the cap, a read that stopped advancing), a digest that
  # stopped early, and events evicted before they were read. Missing
  # coverage is said, never drawn as zero.
  defp incomplete(input) do
    digest =
      case input.digest do
        %{"window" => %{"complete" => false} = window} ->
          [
            %{
              "reason" => "digest_incomplete",
              "detail" =>
                "the digest stopped early (#{window["stopped_by"] || "unknown"}); " <>
                  "its anomalies and lead lines cover only part of the window"
            }
          ]

        _complete ->
          []
      end

    evicted = (input.evicted || []) |> Enum.map(&(&1["count"] || 0)) |> Enum.sum()

    evicted =
      if evicted > 0,
        do: [
          %{
            "reason" => "evicted",
            "detail" => "#{evicted} events were evicted before the chart read them"
          }
        ],
        else: []

    (input[:incomplete] || []) ++ digest ++ evicted
  end

  defp covered_from(at, from, to) when is_integer(at) and at > from and at <= to, do: at
  defp covered_from(_at, _from, _to), do: nil
end
