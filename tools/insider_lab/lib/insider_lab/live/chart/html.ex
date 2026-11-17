defmodule Insider.Lab.Live.Chart.Html do
  @moduledoc false

  # One self-contained page: inline SVG and one inline style block, no
  # script, no font, no image, no link to anywhere. Every string the page
  # shows is HTML-escaped, so a mark label or an error signature can never
  # become markup. The Content-Security-Policy meta tag allows no script and
  # only the page's own style block (by its SHA-256), so even an escaping
  # mistake could run nothing. The live form adds a one-second refresh.
  #
  # Times are the observer machine's local wall clock. The page is for a busy
  # developer: the headline says what changed and when, each panel's title
  # names its unit, and the digest's lead lines stand under the chart so a
  # pasted page reads on its own.

  @width 1200
  @left 96
  @right 32
  @top 112
  @panel 112
  @gap 44
  @axis 34
  @label_chars 48
  @label_rows [24, 42, 60]
  @label_char_px 8
  @key_char_px 7
  @marker_r 11

  @style """
  body{font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;margin:24px 32px;color:#1d2330;background:#fff}
  h1{font-size:26px;line-height:1.25;margin:0 0 6px}
  .meta{color:#4a5368;margin:0 0 4px}
  .ended{background:#fff3cd;border:1px solid #e0b100;padding:8px 12px;font-weight:600;margin:10px 0}
  svg{display:block;max-width:100%;height:auto;margin:12px 0}
  .title{font-size:15px;font-weight:600;fill:#1d2330}
  .key{font-size:13px;fill:#4a5368}
  .tick{font-size:12px;fill:#4a5368}
  .grid{stroke:#e3e6ec;stroke-width:1}
  .axis{stroke:#9aa3b5;stroke-width:1}
  .s0{fill:#2f6fd6;stroke:#2f6fd6}
  .s1{fill:#e07a1f;stroke:#e07a1f}
  .s2{fill:#8e44ad;stroke:#8e44ad}
  .s3{fill:#7b8496;stroke:#7b8496}
  .l0{stroke:#2f6fd6}
  .l1{stroke:#e07a1f}
  .l2{stroke:#8e44ad}
  .l3{stroke:#7b8496}
  polyline{fill:none;stroke-width:2.5}
  .since-mark{fill:#2f6fd6;fill-opacity:.07;stroke:none}
  .uncovered{fill:#9aa3b5;fill-opacity:.18;stroke:none}
  .uncovered-label{font-size:12px;fill:#4a5368}
  .mark{stroke:#c0392b;stroke-width:2;stroke-dasharray:6 4}
  .incomplete{background:#fdecea;border:1px solid #c0392b;padding:8px 12px;margin:10px 0}
  .mark-label{font-size:14px;font-weight:600;fill:#c0392b}
  .anomaly{fill:#c0392b;stroke:#fff;stroke-width:2}
  .anomaly-number{font-size:12px;font-weight:700;fill:#fff}
  .absent{color:#4a5368}
  ol.captions,ol.marks{padding-left:28px;margin:8px 0}
  ol.captions li,ol.marks li{margin:2px 0}
  .marks-title{font-weight:600;margin:12px 0 0}
  pre.summary{font:14px/1.45 ui-monospace,Menlo,Consolas,monospace;background:#f5f6f8;padding:12px;white-space:pre-wrap;overflow-wrap:anywhere}
  """

  @csp "default-src 'none'; script-src 'none'; style-src 'sha256-#{:crypto.hash(:sha256, @style) |> Base.encode64()}'; " <>
         "img-src 'none'; base-uri 'none'; form-action 'none'"

  @doc "The page's Content-Security-Policy: no script, only its own style block."
  @spec csp() :: String.t()
  def csp, do: @csp

  @doc "The page of a chart model (`Insider.Lab.Live.Chart.model/1`)."
  @spec render(map()) :: iodata()
  def render(model) do
    refresh =
      case model.live do
        %{refresh_s: seconds, stopped: nil} ->
          [~s(<meta http-equiv="refresh" content="), Integer.to_string(seconds), ~s(">\n)]

        _static ->
          []
      end

    [
      "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n",
      ~s(<meta http-equiv="Content-Security-Policy" content="),
      @csp,
      ~s(">\n),
      ~s(<meta name="referrer" content="no-referrer">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      refresh,
      "<title>",
      escape("Insider chart: " <> model.session_id),
      "</title><style>",
      @style,
      "</style></head>\n<body>\n",
      "<h1>",
      escape(headline_text(model)),
      "</h1>\n",
      ~s(<p class="meta">),
      escape(meta(model)),
      "</p>\n",
      ended(model),
      incomplete(model),
      svg(model),
      absent(model),
      marks_list(model),
      captions(model),
      summary(model),
      "</body></html>\n"
    ]
  end

  ## Header

  @doc "The headline of a chart model, as the page and the command print it."
  @spec headline_text(map()) :: String.t()
  def headline_text(%{headline: {text, nil, _mark}}), do: text

  def headline_text(%{headline: {text, at, nil}}), do: "#{text} at #{clock(at)}"

  def headline_text(%{headline: {text, at, mark}}),
    do:
      "#{text} at #{clock(at)}, #{gap(at - mark.at_us)} after '#{mark.label}' " <>
        "(mark #{mark.index}, #{clock(mark.at_us)})"

  defp gap(us) when us < 60_000_000, do: "#{round(us / 1_000_000)} s"
  defp gap(us), do: :erlang.float_to_binary(us / 60_000_000, decimals: 1) <> " min"

  defp meta(model) do
    status = model.status
    state = status["state"] || "unknown"

    lease =
      case {state, status["lease_remaining_ms"]} do
        {"running", ms} when is_integer(ms) ->
          "lease #{lease_text(ms)} left (the agent's reads renew it; this page does not renew it)"

        _other ->
          nil
      end

    updated = if model.live, do: "updated", else: "written"

    [
      "Session #{model.session_id} on #{model.node}",
      "#{model.profile} disclosure",
      state,
      lease,
      "#{model.events} events",
      "#{clock(model.from_us)}–#{clock(model.to_us)} local time (#{offset()})",
      "#{updated} #{clock(model.now_us)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp lease_text(ms) do
    seconds = div(ms, 1_000)
    if seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s", else: "#{seconds}s"
  end

  defp ended(%{live: %{stopped: "session_ended"}, status: status}),
    do: [
      ~s(<p class="ended">),
      escape("The session ended (#{status["state"] || "ended"}). This chart stopped updating."),
      "</p>\n"
    ]

  defp ended(%{live: %{stopped: "duration"}}),
    do: [
      ~s(<p class="ended">),
      "This chart reached its --for limit and stopped updating.",
      "</p>\n"
    ]

  defp ended(%{live: %{stopped: stopped}}) when is_binary(stopped),
    do: [~s(<p class="ended">), escape("This chart stopped updating (#{stopped})."), "</p>\n"]

  defp ended(_model), do: []

  ## Chart

  # With nothing to draw yet, the time axis and the marks still show, so the
  # programmer sees their marks arrive before the first request does.
  #
  # From the top: up to three rows of mark labels, then each panel with its
  # title and keys in a band above its plot. Marks, the since-mark shading,
  # and the stretch the chart could not read are drawn over the plots only,
  # never over a title.
  defp svg(model) do
    panels = Enum.with_index(model.series)

    plots =
      if panels == [],
        do: [{@top, @top + 24}],
        else: for({_series, index} <- panels, do: plot(index))

    {_top, bottom} = List.last(plots)

    nothing =
      if panels == [],
        do: [
          ~s(<p class="absent">),
          escape("Nothing to chart yet: #{model.events} events in this window."),
          "</p>\n"
        ],
        else: []

    height = bottom + @axis + 8
    x = &x(&1, model)

    [
      # Inline in HTML, the SVG namespace is implied: the page names no URL.
      ~s(<svg viewBox="0 0 #{@width} #{height}" role="img" aria-label="),
      escape(headline_text(model)),
      "\">\n",
      since_mark(model, x, plots),
      uncovered(model, x, plots),
      Enum.map(panels, fn {{name, series}, index} ->
        {top, _bottom} = plot(index)
        panel(name, series, top, model)
      end),
      time_axis(model, plots),
      marks(model, x, plots),
      anomaly_markers(model, x),
      "</svg>\n",
      nothing
    ]
  end

  defp plot(index) do
    top = @top + index * (@panel + @gap)
    {top, top + @panel}
  end

  defp x(at, model) do
    span = max(model.to_us - model.from_us, 1)
    @left + (at - model.from_us) / span * (@width - @left - @right)
  end

  defp since_mark(%{since_mark: %{at_us: at}} = model, x, plots) when at <= model.to_us do
    from = max(x.(max(at, model.from_us)), @left)

    for {top, bottom} <- plots,
        do:
          ~s(<rect class="since-mark" x="#{fmt(from)}" y="#{top}" width="#{fmt(@width - @right - from)}" height="#{bottom - top}"/>\n)
  end

  defp since_mark(_model, _x, _plots), do: []

  # Where the chart dropped older entries, the plots are greyed and say so:
  # no data there is not zero.
  defp uncovered(%{covered_from_us: at}, x, plots) when is_integer(at) do
    until = x.(at)

    for {{top, bottom}, index} <- Enum.with_index(plots) do
      [
        ~s(<rect class="uncovered" x="#{@left}" y="#{top}" width="#{fmt(until - @left)}" height="#{bottom - top}"><title>),
        escape("Not read: the chart kept only events from #{clock(at)} on."),
        "</title></rect>\n",
        if(index == 0,
          do: [
            ~s(<text class="uncovered-label" x="#{@left + 6}" y="#{bottom - 6}">),
            "not read",
            "</text>\n"
          ],
          else: []
        )
      ]
    end
  end

  defp uncovered(_model, _x, _plots), do: []

  defp panel(name, series, top, model) do
    values =
      case series.kind do
        :stacked -> stacked_totals(series)
        _single -> series.lines |> Enum.flat_map(& &1.points) |> Enum.map(&elem(&1, 1))
      end

    max = nice(Enum.max([0 | values]))
    y = fn value -> top + @panel - value / max * @panel end

    [
      ~s(<g data-series="),
      Atom.to_string(name),
      ~s(">\n),
      ~s(<text class="title" x="#{@left}" y="#{top - 14}">),
      escape("#{series.title} (#{series.unit})"),
      "</text>\n",
      key(series, top),
      for fraction <- [0, 0.5, 1] do
        value = max * fraction
        line_y = fmt(y.(value))

        [
          ~s(<line class="grid" x1="#{@left}" x2="#{@width - @right}" y1="#{line_y}" y2="#{line_y}"/>),
          ~s(<text class="tick" x="#{@left - 8}" y="#{fmt(y.(value) + 4)}" text-anchor="end">),
          escape(number(value)),
          "</text>\n"
        ]
      end,
      draw(series, model, y),
      ~s(<line class="axis" x1="#{@left}" x2="#{@left}" y1="#{top}" y2="#{top + @panel}"/>\n),
      "</g>\n"
    ]
  end

  # The series' names, when it draws more than one, and always the error
  # signatures, so the page says which error it counts.
  defp key(%{kind: kind, lines: [_one]}, _top) when kind != :stacked, do: []

  # The keys follow the title, left to right, each cut to its share of the
  # room after it, so none overlaps the title or the edge. Names that share
  # a long beginning (error signatures) drop it, so the part that tells
  # them apart shows; the full name is the key's tooltip.
  defp key(%{lines: lines} = series, top) do
    start = @left + String.length("#{series.title} (#{series.unit})") * 9 + 24
    share = div(@width - @right - start, length(lines))
    chars = max(div(share - 24, @key_char_px), 6)
    shown = distinct_names(Enum.map(lines, & &1.name))

    for {{line, name}, index} <- Enum.with_index(Enum.zip(lines, shown)) do
      left = start + index * share

      [
        ~s(<rect class="s#{min(index, 3)}" x="#{left}" y="#{top - 25}" width="10" height="10"/>),
        ~s(<text class="key" x="#{left + 14}" y="#{top - 15}"><title>),
        escape(line.name),
        "</title>",
        escape(truncate(name, chars)),
        "</text>\n"
      ]
    end
  end

  @shared_min 12

  # Each name drops the longest beginning it shares with another (cut back
  # to the start of a word, so it never starts mid-token), when that is long
  # enough to matter.
  defp distinct_names(names) do
    for name <- names do
      shared =
        names
        |> Enum.reject(&(&1 == name or &1 == "other errors"))
        |> Enum.map(&common_prefix(name, &1))
        |> Enum.max_by(&String.length/1, fn -> "" end)

      cut =
        case Regex.run(~r/\A.*[\s.=:\/,]/su, shared) do
          [cut] -> cut
          nil -> ""
        end

      if name != "other errors" and String.length(cut) >= @shared_min,
        do: "…" <> String.replace_prefix(name, cut, ""),
        else: name
    end
  end

  defp common_prefix(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join(&elem(&1, 0))
  end

  # A line with only a few points also marks each point, so a lone sample
  # (one slow request) is not an invisible line of length zero.
  defp draw(%{kind: :lines} = series, model, y) do
    for {line, index} <- Enum.with_index(series.lines) do
      shown =
        line.points
        |> Enum.filter(fn {at, _value} -> at >= model.from_us and at <= model.to_us end)
        |> Enum.map(fn {at, value} -> {fmt(x(at, model)), fmt(y.(value))} end)

      dots =
        if length(shown) < 3,
          do:
            for(
              {px, py} <- shown,
              do: ~s(<circle class="s#{min(index, 3)}" cx="#{px}" cy="#{py}" r="4"/>\n)
            ),
          else: []

      [
        ~s(<polyline class="l#{min(index, 3)}" points="),
        Enum.map_join(shown, " ", fn {px, py} -> "#{px},#{py}" end),
        ~s("/>\n),
        dots
      ]
    end
  end

  defp draw(%{kind: :bars, lines: [line]}, model, y), do: bars([{line, 0}], model, y)

  defp draw(%{kind: :stacked} = series, model, y),
    do: bars(Enum.with_index(series.lines), model, y)

  # Bars per bucket, stacked in line order.
  defp bars(lines, model, y) do
    width = max(x(model.from_us + model.step_s * 1_000_000, model) - @left - 1, 1)
    base = y.(0)

    lines
    |> Enum.reduce({[], %{}}, fn {line, index}, {drawn, below} ->
      bars =
        for {at, value} <- line.points,
            value > 0,
            at >= model.from_us - model.step_s * 1_000_000 do
          offset = Map.get(below, at, 0)
          top = y.(offset + value)
          height = base - y.(value)
          left = max(x(at, model), @left)
          # The newest bucket is cut at the plot's right edge.
          shown = max(min(width, @width - @right - left), 0.5)

          ~s(<rect class="s#{min(index, 3)}" x="#{fmt(left)}" y="#{fmt(top)}" width="#{fmt(shown)}" height="#{fmt(max(height, 0.5))}"/>\n)
        end

      below =
        Enum.reduce(line.points, below, fn {at, value}, acc ->
          Map.update(acc, at, value, &(&1 + value))
        end)

      {[drawn, bars], below}
    end)
    |> elem(0)
  end

  defp stacked_totals(%{lines: lines}) do
    lines
    |> Enum.flat_map(& &1.points)
    |> Enum.reduce(%{}, fn {at, value}, acc -> Map.update(acc, at, value, &(&1 + value)) end)
    |> Map.values()
  end

  defp time_axis(model, plots) do
    {_top, bottom} = List.last(plots)
    span = model.to_us - model.from_us
    ticks = for n <- 0..5, do: model.from_us + div(span * n, 5)

    [
      ~s(<line class="axis" x1="#{@left}" x2="#{@width - @right}" y1="#{bottom}" y2="#{bottom}"/>\n),
      for at <- ticks do
        tick_x = fmt(x(at, model))

        [
          for(
            {top, plot_bottom} <- plots,
            do:
              ~s(<line class="grid" x1="#{tick_x}" x2="#{tick_x}" y1="#{top}" y2="#{plot_bottom}"/>)
          ),
          ~s(<text class="tick" x="#{tick_x}" y="#{bottom + 20}" text-anchor="middle">),
          clock(at),
          "</text>\n"
        ]
      end,
      ~s(<text class="tick" x="#{@width - @right}" y="#{bottom + 20 + 14}" text-anchor="end">),
      escape("local time (#{offset()})"),
      "</text>\n"
    ]
  end

  # Each mark is a dashed line over each plot, joined to its label above the
  # first panel's title. Labels take the first of three rows where they do
  # not overlap another; a label with no room is its number alone, and the
  # list under the chart has every mark in full.
  defp marks(model, x, plots) do
    {first_top, _bottom} = hd(plots)

    model.marks
    |> Enum.sort_by(& &1.at_us)
    |> Enum.map_reduce(Map.new(@label_rows, &{&1, []}), fn mark, taken ->
      at_x = x.(mark.at_us)
      {row, text, span} = place_label(mark, at_x, taken)
      mark_x = fmt(at_x)

      drawn = [
        ~s(<line class="mark" x1="#{mark_x}" x2="#{mark_x}" y1="#{fmt(row + 4)}" y2="#{fmt(first_top - 32)}"/>\n),
        for {top, bottom} <- plots do
          [
            ~s(<line class="mark" x1="#{mark_x}" x2="#{mark_x}" y1="#{fmt(top)}" y2="#{fmt(bottom)}"><title>),
            escape("mark #{mark.index}: #{mark.label} (#{clock(mark.at_us)})"),
            "</title></line>\n"
          ]
        end,
        mark_label(row, span),
        escape(text),
        "</text>\n"
      ]

      {drawn, Map.update!(taken, row, &[span | &1])}
    end)
    |> elem(0)
  end

  defp place_label(mark, at_x, taken) do
    full = truncate(mark.shown, @label_chars)
    number = "##{mark.index}"

    Enum.find_value(@label_rows, fn row ->
      span = label_span(at_x, full)
      if free?(taken[row], span), do: {row, full, span}
    end) ||
      Enum.find_value(@label_rows, fn row ->
        span = label_span(at_x, number)
        if free?(taken[row], span), do: {row, number, span}
      end) ||
      {List.last(@label_rows), number, label_span(at_x, number)}
  end

  # A label starts just right of its line, or ends just left of it when it
  # would run off the right edge.
  defp label_span(at_x, text) do
    width = String.length(text) * @label_char_px

    if at_x + 6 + width > @width - 4,
      do: {:end, at_x - 6 - width, at_x - 6},
      else: {:start, at_x + 6, at_x + 6 + width}
  end

  defp free?(spans, {_anchor, from, to}),
    do: Enum.all?(spans, fn {_other, a, b} -> to + 8 <= a or from >= b + 8 end)

  defp mark_label(y, {:end, _from, to}),
    do: ~s(<text class="mark-label" x="#{fmt(to)}" y="#{y}" text-anchor="end">)

  defp mark_label(y, {:start, from, _to}),
    do: ~s(<text class="mark-label" x="#{fmt(from)}" y="#{y}">)

  # Markers that would sit on one another in a panel move right, one
  # marker's width each, and stay inside the plot.
  defp anomaly_markers(model, x) do
    positions =
      model.series
      |> Enum.with_index()
      |> Map.new(fn {{name, _series}, index} -> {name, elem(plot(index), 0)} end)

    model.anomalies
    |> Enum.filter(&positions[&1.series])
    |> Enum.map_reduce(%{}, fn %{series: name, at_us: at} = anomaly, taken ->
      top = positions[name]
      base = x.(at)
      shift = Enum.count(Map.get(taken, name, []), &(abs(&1 - base) < 2 * @marker_r + 2))

      cx =
        (base + shift * (2 * @marker_r + 2))
        |> max(@left + @marker_r + 3)
        |> min(@width - @right - @marker_r - 1)

      {marker(anomaly, fmt(cx), top + @marker_r + 1),
       Map.update(taken, name, [base], &[base | &1])}
    end)
    |> elem(0)
  end

  defp marker(anomaly, cx, cy) do
    [
      ~s(<circle class="anomaly" cx="#{cx}" cy="#{cy}" r="#{@marker_r}"><title>),
      escape(anomaly.line),
      "</title></circle>",
      ~s(<text class="anomaly-number" x="#{cx}" y="#{cy + 4}" text-anchor="middle">),
      Integer.to_string(anomaly.number),
      "</text>\n"
    ]
  end

  ## Under the chart

  defp absent(%{absent: []}), do: []

  defp absent(%{absent: names}),
    do: [
      ~s(<p class="absent">),
      escape("Not recorded in this window: #{Enum.join(names, ", ")}."),
      "</p>\n"
    ]

  # What the chart could not read, and why, above it: missing coverage is
  # said, never left to look like quiet.
  defp incomplete(%{incomplete: []}), do: []

  defp incomplete(%{incomplete: notes}),
    do: [
      ~s(<p class="incomplete">),
      escape("Incomplete: " <> Enum.map_join(notes, "; ", & &1["detail"]) <> "."),
      "</p>\n"
    ]

  defp marks_list(%{marks: []}), do: []

  defp marks_list(%{marks: marks}) do
    [
      ~s(<p class="marks-title">Marks</p><ol class="marks">),
      marks
      |> Enum.sort_by(& &1.at_us)
      |> Enum.map(fn mark ->
        [~s(<li value="#{mark.index}">), escape("#{clock(mark.at_us)} #{mark.label}"), "</li>"]
      end),
      "</ol>\n"
    ]
  end

  defp captions(%{anomalies: []}), do: []

  defp captions(%{anomalies: anomalies}) do
    [
      ~s(<p class="marks-title">Anomalies</p><ol class="captions">),
      Enum.map(anomalies, fn anomaly ->
        [~s(<li value="#{anomaly.number}">), escape(anomaly.line), "</li>"]
      end),
      "</ol>\n"
    ]
  end

  defp summary(%{summary: []}), do: []

  defp summary(%{summary: lines}),
    do: [~s(<pre class="summary">), escape(Enum.join(lines, "\n")), "</pre>\n"]

  ## Text

  @doc "Escapes text for HTML element content and attribute values."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp truncate(text, chars) do
    if String.length(text) > chars, do: String.slice(text, 0, chars - 1) <> "…", else: text
  end

  defp clock(nil), do: "?"

  defp clock(us) do
    {_date, {h, m, s}} = :calendar.system_time_to_local_time(div(us, 1_000_000), :second)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  defp offset do
    utc = :calendar.universal_time()
    local = :calendar.universal_time_to_local_time(utc)

    minutes =
      div(
        :calendar.datetime_to_gregorian_seconds(local) -
          :calendar.datetime_to_gregorian_seconds(utc),
        60
      )

    sign = if minutes < 0, do: "−", else: "+"
    abs = abs(minutes)

    "UTC#{sign}#{pad(div(abs, 60))}:#{pad(rem(abs, 60))}"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp number(value) when value == 0, do: "0"
  defp number(value) when value >= 100, do: Integer.to_string(round(value))
  defp number(value) when value >= 10, do: :erlang.float_to_binary(value * 1.0, decimals: 0)
  defp number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  # A round axis maximum at or above `value`.
  defp nice(value) when value <= 0, do: 1

  defp nice(value) do
    magnitude = :math.pow(10, Float.floor(:math.log10(value)))
    Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= value)) * magnitude
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end
