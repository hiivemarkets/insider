defmodule Insider.Live.Trends do
  @moduledoc false

  # Trends across summary windows, for the digest's `"trends"` and
  # `"logger_bursts"` and for `Insider.Live.trends/2`
  # (`insider.live-trends/v1`).
  #
  # The input is the summary rows a digest window folded, oldest first: per
  # Telemetry kind, each interval's summary (`"telemetry.summary/v1"`), and
  # per Logger burst (template fingerprint, call site fingerprint, and
  # level), each interval's `logger_summary`. Every value has a fixed unit
  # (`units/0`): durations in microseconds, rates in events per minute (the
  # plain-term contract has no floats), error shares in whole percent of the
  # count, intervals in milliseconds, and window bounds as ISO 8601 UTC wall
  # times.
  #
  # A change compares a series' first and last window. Its direction is
  # `"flat"` within `@flat_pct` percent of the first value, so the 6.25%
  # histogram bucket precision of a percentile never reads as a trend.
  #
  # A duration's scope (handler time or caller-observed latency) is only
  # what the session declared (`"telemetry_duration_scopes"`). The process
  # that emitted an exemplar is evidence of where the event was emitted,
  # never of what its duration measured, so an undeclared scope makes no
  # claim, and two declared scopes only make a conditional one.

  @schema "insider.live-trends/v1"
  @flat_pct 10
  @top 10
  @error_levels ["error", "critical", "alert", "emergency"]

  @units %{
    "bytes" => "bytes",
    "ports" => "ports",
    "messages" => "messages",
    "per_min" => "change per minute",
    "duration" => "us",
    "rate" => "events per minute",
    "error_pct" => "percent of count",
    "interval" => "ms",
    "window_bounds" => "ISO 8601 UTC"
  }

  @doc "The trends schema id."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The fixed unit of each kind of value."
  @spec units() :: map()
  def units, do: @units

  @doc """
  The trends document of a digest window: `digest` is `Insider.Live.Digest`'s
  result for it, `rows` the window's summary rows (`Insider.Live.Digest.read_window/5`),
  `kinds` the Telemetry kinds to keep (`[]` keeps all; `"logger_summary"`
  keeps the Logger bursts), and `windows` the most recent windows per series.
  """
  @spec document(map(), map(), [String.t()], pos_integer()) :: map()
  def document(digest, rows, kinds, windows) do
    telemetry =
      rows.summaries
      |> Enum.filter(fn {kind, _rows} -> kinds == [] or kind in kinds end)
      |> telemetry(windows)

    logger =
      if kinds == [] or "logger_summary" in kinds, do: logger(rows.bursts, windows), else: []

    {poller, omitted} = poller(Map.get(rows, :poller, %{series: []}), kinds, windows)

    %{
      "schema" => @schema,
      "session_id" => digest["session_id"],
      "node" => digest["node"],
      "state" => digest["state"],
      "disclosure_profile" => digest["disclosure_profile"],
      "window" => digest["window"],
      "units" => @units,
      "telemetry" => telemetry,
      "logger" => logger,
      "poller" => poller,
      "poller_omitted" => omitted,
      "poller_untracked" => get_in(rows, [:poller, :untracked]) || %{},
      "notes" => notes(telemetry, logger),
      "filtered" => digest["filtered"],
      "gaps" => digest["gaps"]
    }
  end

  @doc """
  Telemetry series, one per summarised kind: the most recent `windows`
  windows, the change from the first to the last window read, and the
  exemplar losses of every window read, slowest last p95 first.
  """
  @spec telemetry(%{String.t() => [map()]} | [{String.t(), [map()]}], pos_integer()) :: [map()]
  def telemetry(summaries, windows) do
    summaries
    |> Enum.map(fn {kind, rows} ->
      series = Enum.map(rows, &telemetry_window/1)
      first = List.first(series)
      last = List.last(series)

      %{
        "kind" => kind,
        "windows" => length(series),
        "duration_scope" =>
          rows |> Enum.map(& &1["duration_scope"]) |> Enum.reject(&is_nil/1) |> List.last(),
        "exemplars_lost" => series |> Enum.map(&(&1["exemplars_lost"] || 0)) |> Enum.sum(),
        "first_error_lost_windows" => Enum.count(series, &(&1["first_error_retained"] == false)),
        "change" => %{
          "rate_per_min" => change(first["rate_per_min"], last["rate_per_min"]),
          "p95_us" => change(first["p95_us"], last["p95_us"]),
          "max_us" => change(first["max_us"], last["max_us"]),
          "errors" => change(first["errors"], last["errors"]),
          "error_pct" => change(first["error_pct"], last["error_pct"])
        },
        "series" => Enum.take(series, -windows)
      }
    end)
    |> Enum.sort_by(&{-(get_in(&1, ["change", "p95_us", "last"]) || -1), &1["kind"]})
  end

  defp telemetry_window(row) do
    %{
      "started_at" => row["window_started_at"],
      "ended_at" => row["window_ended_at"] || row["wall_time"],
      "interval_ms" => row["interval_ms"],
      "count" => row["count"],
      "rate_per_min" => rate(row["count"], row["interval_ms"]),
      "errors" => row["errors"],
      "error_pct" => pct(row["errors"], row["count"]),
      "p50_us" => row["p50_us"],
      "p95_us" => row["p95_us"],
      "max_us" => row["max_us"],
      "exemplars" => Enum.map(row["exemplars"] || [], & &1["receipt"]),
      "exemplars_lost" => row["exemplars_lost"],
      "first_error_retained" => row["first_error_retained"]
    }
  end

  @doc """
  Logger burst series, one per message template, call site, and level (the
  overflow row of a level is its own series): each window's count and rate,
  the exemplar receipts and losses, most messages first. `bursts` holds each
  burst's `logger_summary` rows, oldest first.
  """
  @spec logger(%{term() => [map()]} | [{term(), [map()]}], pos_integer()) :: [map()]
  def logger(bursts, windows) do
    bursts
    |> Enum.map(fn {_key, rows} ->
      series =
        Enum.map(rows, fn row ->
          %{
            "started_at" => row["window_started_at"],
            "ended_at" => row["window_ended_at"],
            "interval_ms" => row["interval_ms"],
            "count" => row["count"],
            "rate_per_min" => rate(row["count"], row["interval_ms"]),
            "exemplar_receipt" => row["exemplar_receipt"],
            "exemplar_lost" => row["exemplar_lost"],
            "distinct_lost" => row["distinct_lost"]
          }
        end)

      first = List.first(series)
      last = List.last(series)
      latest = List.last(rows)

      %{
        "level" => latest["level"],
        "overflow" => latest["overflow"] == true,
        "template" => latest_value(rows, "template"),
        "template_fingerprint" => latest["template_fingerprint"],
        "call_site" => latest_value(rows, "call_site"),
        "call_site_fingerprint" => latest["call_site_fingerprint"],
        "count" => sum(series, "count"),
        "windows" => length(series),
        "peak_count" => series |> Enum.map(&(&1["count"] || 0)) |> Enum.max(fn -> 0 end),
        "exemplar_receipts" =>
          series |> Enum.map(& &1["exemplar_receipt"]) |> Enum.reject(&is_nil/1) |> Enum.take(3),
        "exemplars_lost" => Enum.count(series, &(&1["exemplar_lost"] == true)),
        "distinct_lost" => sum(series, "distinct_lost"),
        "change" => %{"rate_per_min" => change(first["rate_per_min"], last["rate_per_min"])},
        "series" => Enum.take(series, -windows)
      }
    end)
    |> Enum.sort_by(
      &{-&1["count"], &1["level"], &1["template_fingerprint"] || "",
       &1["call_site_fingerprint"] || ""}
    )
    |> Enum.take(@top)
  end

  defp latest_value(rows, key),
    do: rows |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1) |> List.last()

  defp sum(series, key), do: series |> Enum.map(&(&1[key] || 0)) |> Enum.sum()

  # Each metric's unit, and how many of its series are shown.
  @poller_units %{
    "binary_bytes" => "bytes",
    "port_count" => "ports",
    "port_type" => "ports",
    "message_queue_len" => "messages"
  }
  @poller_order ["binary_bytes", "port_count", "port_type", "message_queue_len"]

  @doc """
  Poller series (`Insider.Live.Trends.Series`): binary bytes and the port
  count per VM sample, ports per type per port scan, and mailbox lengths
  per ranked or watched process, each with its unit, the change from the
  first sample read to the last with its direction, the growth per minute
  over that span (`per_min`, nil for one sample), its maximum, and the most
  recent `windows` points. At most #{@top} series of each metric are shown,
  largest last value first; `omitted` counts the rest per metric.
  """
  @spec poller(%{series: [map()]}, [String.t()], pos_integer()) ::
          {[map()], %{String.t() => non_neg_integer()}}
  def poller(%{series: series}, kinds, windows) do
    grouped =
      series
      |> Enum.filter(fn s -> kinds == [] or Enum.any?(s.kinds, &(&1 in kinds)) end)
      |> Enum.map(&poller_series(&1, windows))
      |> Enum.group_by(& &1["metric"])

    shown =
      Enum.flat_map(@poller_order, fn metric ->
        grouped
        |> Map.get(metric, [])
        |> Enum.sort_by(&{-(get_in(&1, ["change", "last"]) || 0), to_string(&1["subject"])})
        |> Enum.take(@top)
      end)

    omitted =
      for {metric, all} <- grouped,
          length(all) > @top,
          into: %{},
          do: {metric, length(all) - @top}

    {shown, omitted}
  end

  defp poller_series(s, windows) do
    {first_at, first} = s.first
    {last_at, last} = List.last(s.points)

    points =
      s.points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_at, previous}, {at, value}] -> point(at, value, value - previous) end)
      |> then(&[point(elem(hd(s.points), 0), elem(hd(s.points), 1), nil) | &1])

    %{
      "metric" => s.metric,
      "subject" => s.subject,
      "pid" => s.pid,
      "unit" => Map.fetch!(@poller_units, s.metric),
      "source_kinds" => s.kinds,
      "coverage" => coverage(s),
      "windows" => s.total,
      "first_at" => iso_us(first_at),
      "last_at" => iso_us(last_at),
      "change" => change(first, last),
      "per_min" => per_min(last - first, last_at - first_at),
      "max" => s.max,
      "series" => Enum.take(points, -windows)
    }
  end

  defp point(at, value, delta), do: %{"at" => iso_us(at), "value" => value, "delta" => delta}

  # How a mailbox series was observed: `ranked` (only from rankings, no
  # point where the process was not ranked), `watched` (every point a
  # direct sample of the process), or `mixed`. A ranked stretch keeps its
  # gaps whatever is watched later.
  defp coverage(%{metric: "message_queue_len", direct: 0}), do: "ranked"
  defp coverage(%{metric: "message_queue_len", direct: n, total: n}), do: "watched"
  defp coverage(%{metric: "message_queue_len"}), do: "mixed"

  defp coverage(_series), do: nil

  defp per_min(_delta, span_us) when span_us <= 0, do: nil
  defp per_min(delta, span_us), do: round(delta * 60_000_000 / span_us)

  defp iso_us(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  @doc """
  What the series say together that one alone does not: two declared
  duration scopes side by side, and the bursts at error level.
  """
  @spec notes([map()], [map()]) :: [String.t()]
  def notes(telemetry, logger) do
    errors =
      for burst <- logger, burst["level"] in @error_levels and not burst["overflow"] do
        "Error burst: #{burst["count"]} #{burst["level"]} messages#{template_text(burst)} from #{site_text(burst)} " <>
          "in #{burst["windows"]} windows" <> exemplar_text(burst["exemplar_receipts"]) <> "."
      end

    scope_notes(telemetry) ++ errors
  end

  @doc """
  The handler-time and caller-latency note, when the session declared one
  series' durations handler time and another's caller-observed latency;
  else none. It never says the series describe the same operation.
  """
  @spec scope_notes([map()]) :: [String.t()]
  def scope_notes(telemetry) do
    handlers = Enum.filter(telemetry, &declared?(&1, "handler"))
    callers = Enum.filter(telemetry, &declared?(&1, "caller"))

    if handlers != [] and callers != [] do
      [
        "Declared duration scopes: " <>
          Enum.map_join(handlers, ", ", &"#{&1["kind"]} (p95 #{last_p95(&1)})") <>
          " is declared handler time; " <>
          Enum.map_join(callers, ", ", &"#{&1["kind"]} (p95 #{last_p95(&1)})") <>
          " is declared caller-observed latency. If both describe the same operation, the difference is time " <>
          "outside the handler, such as queueing; the declarations do not establish that they do."
      ]
    else
      []
    end
  end

  defp declared?(series, scope),
    do:
      match?(
        %{"measured_in" => ^scope, "declared" => true},
        series["duration_scope"]
      )

  defp last_p95(series), do: us_text(get_in(series, ["change", "p95_us", "last"]))

  @doc "Plain-text lines for the developer, at most `max` series of each source."
  @spec lines([map()], [map()], non_neg_integer()) :: [String.t()]
  def lines(telemetry, logger, max) do
    Enum.map(Enum.take(telemetry, max), &trend_line/1) ++
      Enum.map(Enum.take(logger, max), &burst_line/1)
  end

  @doc "The plain-text trends document for the developer."
  @spec text(map()) :: String.t()
  def text(document) do
    window = document["window"] || %{}

    poller = document["poller"] || []

    header =
      "Insider trends of #{document["session_id"]} on #{document["node"]}: " <>
        "#{length(document["telemetry"])} summarised kinds, #{length(document["logger"])} Logger bursts " <>
        "and #{length(poller)} Poller series after receipt #{window["cursor"]}."

    empty =
      if document["telemetry"] == [] and document["logger"] == [] and poller == [],
        do: [
          "No summaries in this window, and no Poller samples: start or amend with --telemetry-summary KIND, " <>
            "--logger-summary RULE, or --component poller."
        ],
        else: []

    telemetry = document["telemetry"]
    logger = document["logger"]

    ([header] ++
       empty ++
       lines(telemetry, logger, max(length(telemetry), length(logger))) ++
       Enum.map(poller, &poller_line/1) ++
       scope_notes(telemetry))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp poller_line(series) do
    label =
      case series["metric"] do
        "port_type" -> "Port trend: #{series["subject"]}"
        "message_queue_len" -> "Mailbox trend: #{series["subject"]}"
        metric -> "VM trend: #{metric}"
      end

    format = if series["unit"] == "bytes", do: &bytes_text/1, else: &Integer.to_string/1
    change = series["change"]

    growth =
      case series["per_min"] do
        nil -> ""
        per_min -> ", #{signed(per_min, format)}/min"
      end

    ranked =
      case series["coverage"] do
        "ranked" -> " (when ranked)"
        "mixed" -> " (partly ranked)"
        _direct -> ""
      end

    "#{label} #{format.(change["first"])} -> #{format.(change["last"])} " <>
      "(#{change["direction"]}#{growth}) over #{series["windows"]} samples#{ranked}."
  end

  defp signed(value, format) when value < 0, do: "-" <> format.(-value)
  defp signed(value, format), do: "+" <> format.(value)

  defp bytes_text(bytes) when bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MiB"

  defp bytes_text(bytes) when bytes >= 1_024, do: "#{div(bytes, 1_024)} KiB"
  defp bytes_text(bytes), do: "#{bytes} B"

  defp trend_line(series) do
    change = series["change"]
    scope = scope_text(series["duration_scope"])

    "Trend: #{series["kind"]} p95 #{arrow(change["p95_us"], &us_text/1)}, " <>
      "rate #{arrow(change["rate_per_min"], &rate_text/1)}, errors #{arrow(change["errors"], &Integer.to_string/1)} " <>
      "over #{series["windows"]} windows#{scope}" <>
      last_exemplars(series["series"]) <> loss_text(series) <> "."
  end

  defp loss_text(series) do
    lost =
      case series["exemplars_lost"] do
        lost when is_integer(lost) and lost > 0 -> ["#{lost} exemplar candidates lost"]
        _none -> []
      end

    first_error =
      case series["first_error_lost_windows"] do
        1 -> ["first error not retained in 1 window"]
        n when is_integer(n) and n > 1 -> ["first error not retained in #{n} windows"]
        _none -> []
      end

    case lost ++ first_error do
      [] -> ""
      parts -> "; " <> Enum.join(parts, ", ")
    end
  end

  defp burst_line(%{"overflow" => true} = burst) do
    "Burst overflow: #{burst["count"]} #{burst["level"]} messages beyond the per-interval burst key cap, " <>
      "#{burst["distinct_lost"]} distinct template and call-site keys folded over #{burst["windows"]} windows."
  end

  defp burst_line(burst) do
    lost =
      case burst["exemplars_lost"] do
        lost when is_integer(lost) and lost > 0 -> "; #{lost} exemplar lost"
        _none -> ""
      end

    "Burst: #{burst["count"]} #{burst["level"]}#{template_text(burst)} from #{site_text(burst)} " <>
      "over #{burst["windows"]} windows (peak #{burst["peak_count"]} per window, rate " <>
      "#{arrow(burst["change"]["rate_per_min"], &rate_text/1)})" <>
      exemplar_text(burst["exemplar_receipts"]) <> lost <> "."
  end

  defp template_text(%{"template" => template}) when is_binary(template), do: " \"#{template}\""

  defp template_text(%{"template_fingerprint" => fingerprint}) when is_binary(fingerprint),
    do: " template #{fingerprint}"

  defp template_text(_burst), do: ""

  defp last_exemplars(series) do
    case series |> List.last() |> then(&((&1 && &1["exemplars"]) || [])) do
      [] -> ""
      receipts -> "; exemplar receipts " <> Enum.map_join(receipts, ", ", &to_string/1)
    end
  end

  defp exemplar_text([]), do: ""
  defp exemplar_text(nil), do: ""

  defp exemplar_text(receipts),
    do: "; exemplar receipts " <> Enum.map_join(receipts, ", ", &to_string/1)

  defp site_text(%{"call_site" => %{"module" => module, "function" => function, "line" => line}}),
    do: "#{module}.#{function}#{if line, do: ":#{line}", else: ""}"

  defp site_text(%{"call_site_fingerprint" => fingerprint}) when is_binary(fingerprint),
    do: "call site #{fingerprint}"

  defp site_text(_burst), do: "an unknown call site"

  defp scope_text(%{"measured_in" => "handler", "declared" => true}),
    do: "; declared handler time"

  defp scope_text(%{"measured_in" => "caller", "declared" => true}),
    do: "; declared caller-observed latency"

  defp scope_text(%{"emitter" => %{"context" => "otp_server", "module" => module}})
       when is_binary(module),
       do: "; emitted inside OTP server #{module}; scope not declared"

  defp scope_text(_scope), do: ""

  defp arrow(%{"first" => first, "last" => last, "direction" => direction}, format)
       when not is_nil(first) and not is_nil(last),
       do: "#{format.(first)} -> #{format.(last)} (#{direction})"

  defp arrow(_change, _format), do: "?"

  # The first and last value of a series and how it moved.
  defp change(first, last) when is_integer(first) and is_integer(last) do
    %{
      "first" => first,
      "last" => last,
      "delta" => last - first,
      "direction" => direction(first, last)
    }
  end

  defp change(first, last),
    do: %{"first" => first, "last" => last, "delta" => nil, "direction" => nil}

  defp direction(first, last) do
    cond do
      abs(last - first) * 100 <= @flat_pct * abs(first) -> "flat"
      last > first -> "rising"
      true -> "falling"
    end
  end

  defp rate(count, interval_ms)
       when is_integer(count) and is_integer(interval_ms) and interval_ms > 0,
       do: div(count * 60_000 + div(interval_ms, 2), interval_ms)

  defp rate(_count, _interval_ms), do: nil

  defp pct(errors, count) when is_integer(errors) and is_integer(count) and count > 0,
    do: div(errors * 100 + div(count, 2), count)

  defp pct(_errors, _count), do: nil

  defp rate_text(per_min), do: :erlang.float_to_binary(per_min / 60, decimals: 1) <> "/s"

  @doc "A duration in microseconds as a person reads it: us, whole ms, or s."
  @spec us_text(non_neg_integer() | nil) :: String.t()
  def us_text(nil), do: "?"

  def us_text(us) when us >= 1_000_000,
    do: :erlang.float_to_binary(us / 1_000_000, decimals: 2) <> " s"

  def us_text(us) when us >= 1_000, do: "#{div(us, 1_000)} ms"
  def us_text(us), do: "#{us} us"
end
