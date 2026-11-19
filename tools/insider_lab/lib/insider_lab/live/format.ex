defmodule Insider.Lab.Live.Format do
  @moduledoc false

  # The observer's output formats for event reads (`events`, `watch`) and the
  # digest:
  #
  # - `json` (default): the canonical JSON document, with each event's
  #   envelope cut to what varies (`lean_entry/1`).
  # - `full`: the document exactly as the target returned it.
  # - `compact`: one line per event (`event_line/1`) and one `#` line per
  #   batch with its cursor, truncation, gaps, and filtered counts.
  #
  # `digest --human`, `trends --human`, `marks --human` and `bin_leak --human` print the
  # result's `"text"`. Errors
  # are always JSON.

  alias Insider.Lab.Live.Invocation

  @formats ["json", "compact", "full"]

  # Event fields that are the same for every event of a session, or only
  # order events within one source: the full format keeps them.
  @constant_event_fields [
    "schema",
    "node",
    "boot_id",
    "clock_id",
    "source_instance_id",
    "source_sequence",
    "monotonic_time",
    "authority"
  ]
  @optional_event_fields [
    "causality",
    "extensions",
    "payload",
    "redactions",
    "subject",
    "wall_time"
  ]
  @vm_metrics [
    "process_count",
    "run_queue_length",
    "total_bytes",
    "processes_bytes",
    "ets_bytes",
    "port_count",
    "binary_bytes"
  ]
  @ranked 3
  @args_max 5
  @oban_args_chars 200
  @arg_chars 48
  @text_bytes 120

  @doc "The accepted `--format` values; the first is the default."
  @spec formats() :: [String.t()]
  def formats, do: @formats

  @doc """
  The document to print as JSON for `operation`, or `{:text, iodata}` when
  the format prints text. `arguments` may hold the `:invocation` the
  compact welcome line names (default `Insider.Lab.Live.Invocation.default/0`).
  """
  @spec render(String.t(), map(), map()) :: {:json, map()} | {:text, iodata()}
  def render("events", %{format: "compact"} = arguments, document),
    do: {:text, [welcome_line(document, arguments), batch_lines(document["result"])]}

  def render("events", %{format: "json"}, document),
    do: {:json, Map.update!(document, "result", &lean_batch/1)}

  def render(operation, %{human?: true}, %{"result" => %{"text" => text}})
      when operation in [
             "digest",
             "trends",
             "bin_leak",
             "trace",
             "timeline",
             "changes",
             "mutations",
             "marks",
             "baseline"
           ],
      do: {:text, if(String.ends_with?(text, "\n"), do: text, else: text <> "\n")}

  def render("watch", %{format: "compact"} = arguments, line),
    do: {:text, watch_lines(line, arguments)}

  def render("watch", %{format: "json"}, %{"kind" => "batch"} = line),
    do: {:json, Map.update!(line, "result", &lean_batch/1)}

  def render(_operation, _arguments, document), do: {:json, document}

  @doc "A batch with every event's envelope cut to what varies."
  @spec lean_batch(map()) :: map()
  def lean_batch(%{"events" => events} = batch) when is_list(events),
    do: %{batch | "events" => Enum.map(events, &lean_entry/1)}

  def lean_batch(batch), do: batch

  @doc """
  One returned event without its constant envelope: the entry keeps its
  `receipt`, `event`, and non-empty `redactions`; the event drops the fields
  that are the same for every event and those that are null or empty, and
  its causality keeps only the identifiers that are set.
  """
  @spec lean_entry(map()) :: map()
  def lean_entry(%{"event" => %{} = event} = entry) do
    event =
      event
      |> Map.drop(@constant_event_fields)
      |> Map.update("causality", nil, &set_values/1)
      |> drop_empty(@optional_event_fields)

    %{"receipt" => entry["receipt"], "event" => event}
    |> Map.put("redactions", entry["redactions"])
    |> drop_empty(["redactions"])
  end

  def lean_entry(entry), do: entry

  defp set_values(%{} = map),
    do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp set_values(value), do: value

  defp drop_empty(map, keys) do
    Enum.reduce(keys, map, fn key, map ->
      if Map.get(map, key) in [nil, [], %{}], do: Map.delete(map, key), else: map
    end)
  end

  ## Compact

  defp welcome_line(
         %{"welcome" => %{"schema" => _schema, "quick_start" => _quick_start}},
         arguments
       ) do
    invocation = Map.get(arguments, :invocation, Invocation.default())

    "# welcome: this target's quick start has not been read; run: #{invocation} welcome \"${N[@]}\"\n"
  end

  defp welcome_line(_document, _arguments), do: []

  # A watch that goes on through its reader's stored view, or that kept or
  # cleared it, says so once, before it subscribes, rather than on every
  # pushed batch.
  defp watch_lines(%{"kind" => "subscribed"} = line, arguments) do
    subscription = line["subscription"] || %{}

    [
      welcome_line(line, arguments),
      note_lines([get_in(subscription, ["stored_view", "note"]), subscription["view_note"]]),
      hash_line([
        "subscribed",
        {"session", get_in(line, ["result", "session_id"])},
        {"target", line["target"]},
        {"disclosure", get_in(line, ["result", "disclosure_profile"])},
        {"cursor", subscription["cursor"]},
        {"max_events", subscription["max_events"]}
      ])
    ]
  end

  # A pushed batch is cut by the fixed push bounds and the stream goes on,
  # so it prints no next step (`--cursor` and `--limit`
  # are events flags).
  defp watch_lines(%{"kind" => "batch", "result" => batch}, _arguments),
    do: batch_lines(batch, :watch)

  defp watch_lines(%{"kind" => kind} = line, _arguments) do
    fields =
      line
      |> Map.drop(["kind"])
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, value} end)

    [hash_line([kind | fields]), watch_more(line)]
  end

  # A watch that stopped before the session ended continues from where it
  # stopped, with watch's own flags, or reads on with events. A larger
  # --max-events is suggested only below its most.
  @watch_stops %{
    "max_events" => "at its --max-events",
    "duration" => "at its --for",
    "interrupted" => "when it was interrupted"
  }

  defp watch_more(%{"kind" => "stopped", "reason" => reason, "next_cursor" => next} = line)
       when is_map_key(@watch_stops, reason) and is_integer(next) do
    most = Insider.Live.Options.subscription_events_max()

    larger =
      if reason == "max_events" and is_integer(line["events"]) and line["events"] < most,
        do: " (and a larger --max-events, up to #{most})",
        else: ""

    "# more: watch stopped #{Map.fetch!(@watch_stops, reason)}; " <>
      "continue with watch --from-cursor #{next}#{larger}, or events --cursor #{next}\n"
  end

  defp watch_more(_line), do: []

  @doc """
  One line per event of `batch`, then its `#` line. Read by `events`
  (the default), it also says how to continue a cut read; pushed to `watch`,
  whose stream goes on by itself, it does not. A read through the reader's
  stored view, or one that kept or cleared it, says so first.
  """
  @spec batch_lines(map(), :events | :watch) :: iodata()
  def batch_lines(batch, operation \\ :events) do
    events = Enum.map(batch["events"] || [], &[event_line(&1), "\n"])

    trailer =
      hash_line([
        "batch",
        {"cursor", batch["cursor"]},
        {"next_cursor", batch["next_cursor"]},
        {"next_receipt", batch["next_receipt"]},
        {"events", length(batch["events"] || [])},
        {"truncated_by", batch["truncated_by"]},
        {"state", batch["state"]},
        {"disclosure", batch["disclosure_profile"]},
        {"gaps", gaps(batch["gaps"])},
        {"filtered", filtered(batch["filtered"])}
      ])

    stored = if operation == :events, do: get_in(batch, ["stored_view", "note"])

    [
      note_lines([stored, batch["view_note"]]),
      events,
      trailer,
      lost_line(batch),
      if(operation == :events, do: more_line(batch), else: []),
      Enum.map(batch["hints"] || [], &hint_line/1)
    ]
  end

  defp note_lines(notes), do: for(note <- notes, is_binary(note), do: ["# note: ", note, "\n"])

  # A cursor read after an eviction can look like it returned unrelated
  # events. The range's evicted events, why, and
  # whether the first event shown is not the one after the cursor.
  defp lost_line(batch) do
    evicted =
      Enum.find_value(batch["gaps"] || [], 0, fn
        %{"reason" => "evicted", "scope" => "receipt_range", "count" => count}
        when is_integer(count) ->
          count

        _gap ->
          nil
      end)

    first =
      case batch["events"] do
        [%{"receipt" => receipt} | _rest] when is_integer(receipt) -> receipt
        _none -> nil
      end

    expected = if is_integer(batch["cursor"]), do: batch["cursor"] + 1

    shown =
      if first && expected && first > expected,
        do: " the first event shown is receipt #{first}, not #{expected}.",
        else: ""

    if evicted > 0,
      do: [
        "# lost: #{evicted} events evicted in this range (the Recorder was full and dropped its oldest);",
        shown,
        " Read sooner, or record less: digest hints say what\n"
      ],
      else: []
  end

  # "26 events cut by max_bytes" alone does not say what to do next. A cut
  # read names the bound, how to continue, and how far it goes.
  @read_bounds %{
    "limit" => {"--limit", "limit"},
    "max_bytes" => {"--max-bytes", "max_bytes"},
    "scan_limit" => {"--scan-limit", "scan_limit"}
  }

  defp more_line(%{"truncated_by" => bound, "next_cursor" => next})
       when is_map_key(@read_bounds, bound) and is_integer(next) do
    {flag, key} = Map.fetch!(@read_bounds, bound)
    max = Insider.Live.Options.describe()["read"][key]["max"]

    "# more: this read stopped at its #{flag}; continue with --cursor #{next}, or raise #{flag} (up to #{max})\n"
  end

  defp more_line(_batch), do: []

  # A batch's next command, after its trailer: the command to run, else
  # the manual one, and why.
  defp hint_line(%{"reason" => reason} = hint) do
    case hint["command"] || hint["manual"] do
      nil -> ["# hint: ", reason, "\n"]
      command -> ["# hint: ", command, "  # ", reason, "\n"]
    end
  end

  @doc """
  One event as `RECEIPT TIME SOURCE KIND SEVERITY SUBJECT key=value…`. TIME
  is the wall clock in UTC to the millisecond (`-` when unknown), SUBJECT the
  emitting pid (`-` when none), and the attributes the ones that identify
  what happened for that kind.
  """
  @spec event_line(map()) :: String.t()
  def event_line(%{"event" => %{} = event} = entry) do
    subject =
      case event["subject"] do
        %{"value" => value} when is_binary(value) -> value
        _none -> "-"
      end

    redactions =
      case entry["redactions"] do
        [_ | _] = records -> [{"redactions", length(records)}]
        _none -> []
      end

    head = [
      entry["receipt"],
      clock(event["wall_time"]),
      event["source"],
      event["kind"],
      event["severity"],
      subject
    ]

    pairs = (attributes(event) ++ redactions) |> Enum.map(&pair/1) |> Enum.reject(&(&1 == ""))
    Enum.join(Enum.map(head, &to_string/1) ++ pairs, " ")
  end

  def event_line(entry), do: "? " <> inspect(entry)

  # A pairing mark: which one, what was about to happen, and who marked.
  defp attributes(%{"source" => "live", "kind" => "live.mark", "attributes" => %{} = a}),
    do: [{"mark", a["index"]}, {"label", a["label"]}, {"reader", a["reader"]}]

  defp attributes(%{
         "source" => "logger",
         "kind" => "supervisor_child_terminated",
         "attributes" => a
       }) do
    fingerprint = a["reason_fingerprint"] && String.slice(a["reason_fingerprint"], 0, 12)

    [
      {"offender", short_id(a["offender_id"])},
      {"restart", a["restart_type"]},
      {"reason", a["reason_class"]},
      {"fingerprint", fingerprint}
    ]
  end

  defp attributes(%{"source" => "logger"} = event) do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}
    metadata = if is_map(payload["metadata"]), do: payload["metadata"], else: %{}
    domain = get_in(event, ["attributes", "domain"])

    [
      {"domain", if(is_list(domain) and domain != [], do: Enum.join(domain, "."))},
      {"mfa", metadata["mfa"]},
      {"message", first_line(payload["message"])}
    ]
  end

  defp attributes(%{"source" => "telemetry", "attributes" => %{"summary" => %{} = summary}}) do
    [
      {"count", summary["count"]},
      {"errors", summary["errors"]},
      {"p50_us", summary["duration_p50_us"]},
      {"p95_us", summary["duration_p95_us"]},
      {"max_us", summary["duration_max_us"]},
      {"interval_ms", summary["interval_ms"]}
    ]
  end

  # An Absinthe operation: what decides a GraphQL question without
  # `--format full | jq`: the
  # operation (an anonymous one by its top-level fields), its outcome and
  # response types, its arguments (rich only, at most @args_max leaves of
  # @arg_bytes each, already masked at capture), the actor of its context,
  # the client, its duration, and its trace.
  defp attributes(
         %{
           "source" => "telemetry",
           "kind" => "absinthe.execute.operation.stop",
           "attributes" => %{"graphql" => %{} = outcome} = a
         } = event
       ) do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}
    durations = a["durations_us"] || %{}
    name = outcome["operation_name"] || top_fields(payload)
    operation = [outcome["operation_type"], name] |> Enum.reject(&is_nil/1) |> Enum.join(":")

    [{"graphql", if(operation != "", do: operation)}] ++
      graphql(outcome, false) ++
      [
        {"types", names(outcome["typenames"])},
        {"args", arguments(payload["graphql_arguments"])},
        {"actor", actor(payload)},
        {"client", get_in(outcome, ["client", "user_agent"])}
      ] ++
      Enum.map(Enum.sort(durations), fn {name, us} -> {name <> "_us", us} end) ++
      [{"trace", get_in(event, ["causality", "trace_id"])}]
  end

  # An Oban job event (`Insider.Collector.ObanJob`): the worker, queue,
  # attempt, state, and the args as JSON, printed as is (decoded and masked
  # at capture, rich only, at most @oban_args_chars), else their keys, then
  # its durations.
  defp attributes(%{"source" => "telemetry", "attributes" => %{"oban" => %{} = job} = a} = event) do
    args =
      case get_in(event, ["payload", "oban_args"]) do
        nil -> {"args_keys", names(job["args_keys"])}
        args -> {"args", {:json, cut_chars(Jason.encode!(args), @oban_args_chars)}}
      end

    [
      {"worker", job["worker"]},
      {"queue", job["queue"]},
      {"attempt", attempt(job["attempt"], job["max_attempts"])},
      {"state", job["state"]},
      args
    ] ++ Enum.map(Enum.sort(a["durations_us"] || %{}), fn {name, us} -> {name <> "_us", us} end)
  end

  defp attributes(%{"source" => "telemetry", "attributes" => %{} = a} = event) do
    durations = a["durations_us"] || %{}
    measurements = a["measurements"] || %{}
    metadata = get_in(event, ["payload", "metadata"])
    metadata = if is_map(metadata), do: metadata, else: %{}

    timed = Enum.map(Enum.sort(durations), fn {name, us} -> {name <> "_us", us} end)

    untimed =
      for {name, value} <- Enum.sort(measurements),
          not Map.has_key?(durations, name),
          is_integer(value) or is_binary(value),
          do: {name, value}

    # Of a rendered `Plug.Conn` only the request line and status are
    # shown: its body (a debugger page), headers, assigns, and private
    # fields are left to the json and full formats.
    conn = if is_map(metadata["conn"]), do: metadata["conn"], else: %{}

    timed ++
      untimed ++
      [
        {"method", conn["method"]},
        {"path", first_line(conn["request_path"])},
        {"route", first_line(metadata["route"])},
        {"status", metadata["status"] || conn["status"]},
        {"kind", metadata["kind"]},
        {"reason", reason(metadata["reason"])},
        {"reason_message", reason_message(metadata["reason"])},
        {"result", first_line(metadata["result"])}
      ] ++ graphql(a["graphql"], true)
  end

  # A span: its name, kind, duration, status, GraphQL outcome (its name
  # already names the operation), and trace id, to follow with `trace`.
  defp attributes(%{"source" => "otel", "attributes" => %{} = a} = event) do
    [
      {"name", a["name"]},
      {"span_kind", a["span_kind"]},
      {"duration_us", a["duration_us"]},
      {"status", a["status"]}
    ] ++ oban_span(event) ++ graphql(a["graphql"], false) ++ [{"trace", a["trace_id"]}]
  end

  defp attributes(%{"source" => "poller", "kind" => "vm_sample", "attributes" => a}) do
    metrics = a["metrics"] || %{}
    Enum.map(@vm_metrics, &{&1, metrics[&1]}) ++ unavailable(a)
  end

  # Each ranking as `name:value` entries, at most `@ranked` of them, so the
  # line shows what a JSON read would without its envelope.
  defp attributes(%{"source" => "poller", "kind" => "ets_top", "attributes" => a}) do
    metrics = a["metrics"] || %{}
    insider = metrics["insider"] || %{}

    [
      {"tables", metrics["table_count"]},
      {"by_memory", ranked(metrics["by_memory"], &table/1, "memory_bytes")},
      {"by_size", ranked(metrics["by_size"], &table/1, "size")},
      {"insider_tables", insider["table_count"]},
      {"insider_bytes", insider["memory_bytes"]}
    ] ++ omitted(metrics) ++ unavailable(a)
  end

  defp attributes(%{"source" => "poller", "kind" => "port_top", "attributes" => a}) do
    metrics = a["metrics"] || %{}

    [
      {"ports", metrics["port_count"]},
      {"delta", metrics["port_count_delta"]},
      {"os_processes", metrics["os_process_count"]},
      {"by_type", ranked(metrics["by_type"], &port_type/1)},
      {"by_owner", ranked(metrics["by_owner"], & &1["owner"], "count")}
    ] ++ omitted(metrics) ++ unavailable(a)
  end

  defp attributes(%{"source" => "poller", "kind" => "process_top", "attributes" => a}) do
    metrics = a["metrics"] || %{}

    top =
      case metrics["by_message_queue_len"] do
        [%{} = top | _rest] ->
          [{"top_mailbox", process(top)}, {"message_queue_len", top["message_queue_len"]}]

        _none ->
          []
      end

    top ++
      [
        {"processes", metrics["process_count"]},
        {"by_message_queue_len",
         ranked(metrics["by_message_queue_len"], &process/1, "message_queue_len")},
        {"by_memory", ranked(metrics["by_memory"], &process/1, "memory_bytes")},
        {"by_reductions_delta",
         ranked(metrics["by_reductions_delta"], &process/1, "reductions_delta")}
      ] ++ omitted(metrics) ++ unavailable(a)
  end

  defp attributes(%{"source" => "poller", "kind" => "poll_cycle", "attributes" => a}) do
    metrics = a["metrics"] || %{}

    [{"status", a["probe_status"]}, {"skipped_probes", metrics["skipped_probes"]}] ++
      unavailable(a)
  end

  # `process_sample` and `process_watch`: one process each.
  defp attributes(%{"source" => "poller", "attributes" => a}) do
    metrics = a["metrics"] || %{}

    [
      {"name", a["watch_name"] || short_module(metrics["registered_name"])},
      {"message_queue_len", metrics["message_queue_len"]},
      {"memory_bytes", metrics["memory_bytes"]},
      {"status", metrics["status"]},
      {"current_function", mfa(metrics["current_function"])}
    ] ++ unavailable(a)
  end

  # A call trace: the function and call, and for a failure the exception and
  # the first line of the arguments that failed.
  defp attributes(%{"source" => "calls", "attributes" => a} = event) do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}

    [
      {"function", a["function"]},
      {"call_id", a["call_id"]},
      {"duration_us", a["duration_us"]},
      {"class", a["class"]},
      {"exception", a["exception"]},
      {"reason", a["reason"]},
      {"arguments",
       payload["arguments"] &&
         first_line(inspect(payload["arguments"], limit: 16, printable_limit: 256))}
    ]
  end

  defp attributes(_event), do: []

  # An Oban job's span (OpentelemetryOban, rich only): its worker, queue, and
  # attempt; its args are on the job's `oban.job.*` events.
  defp oban_span(event) do
    case get_in(event, ["payload", "span_attributes"]) do
      %{"oban.job.worker" => worker} = attributes ->
        [
          {"worker", worker},
          {"queue", attributes["messaging.destination.name"]},
          {"attempt",
           attempt(attributes["oban.job.attempt"], attributes["oban.job.max_attempts"])}
        ]

      _none ->
        []
    end
  end

  defp attempt(nil, _max), do: nil
  defp attempt(attempt, nil), do: "#{attempt}"
  defp attempt(attempt, max), do: "#{attempt}/#{max}"

  defp cut_chars(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # A GraphQL operation's value-free outcome
  # (`Insider.Collector.GraphqlOutcome`); counts of 0 and empty lists are
  # left out.
  defp graphql(%{} = outcome, operation?) do
    operation =
      if operation? do
        case Enum.reject([outcome["operation_type"], outcome["operation_name"]], &is_nil/1) do
          [] -> []
          parts -> [{"graphql", Enum.join(parts, ":")}]
        end
      else
        []
      end

    operation ++
      [
        {"result", outcome["result"]},
        {"errors", positive(outcome["error_count"])},
        {"codes", names(outcome["error_codes"])},
        {"paths", names(outcome["error_paths"])},
        {"user_errors", positive(outcome["user_error_count"])},
        {"fields", names(outcome["user_error_fields"])}
      ]
  end

  defp graphql(_outcome, _operation?), do: []

  defp top_fields(payload) do
    case payload["graphql_arguments"] || payload["graphql_data"] do
      %{} = fields when map_size(fields) > 0 ->
        fields |> Map.keys() |> Enum.sort() |> Enum.join(",")

      _none ->
        nil
    end
  end

  # The arguments of the operation's top-level fields, flattened to
  # `path:value` leaves under each field (a leading `input` left out).
  defp arguments(%{} = fields) when map_size(fields) > 0 do
    leaves =
      fields
      |> Enum.sort()
      |> Enum.flat_map(fn {_field, arguments} -> leaves(drop_input(arguments), []) end)

    shown = Enum.take(leaves, @args_max)
    more = if length(leaves) > @args_max, do: ["+#{length(leaves) - @args_max} more"], else: []
    Enum.join(Enum.map(shown, fn {path, value} -> path <> ":" <> value end) ++ more, ",")
  end

  defp arguments(_fields), do: nil

  defp drop_input(%{"input" => input} = arguments) when map_size(arguments) == 1, do: input
  defp drop_input(arguments), do: arguments

  defp leaves(%{} = map, path) when map_size(map) > 0,
    do:
      map
      |> Enum.sort()
      |> Enum.flat_map(fn {key, value} -> leaves(value, path ++ [to_string(key)]) end)

  defp leaves(list, path) when is_list(list),
    do: [{Enum.join(path, "."), "[#{length(list)} items]"}]

  defp leaves(value, path), do: [{Enum.join(path, "."), cut(scalar(value))}]

  defp scalar(value) when is_binary(value), do: value

  defp scalar(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: inspect(value)

  defp scalar(value), do: Jason.encode!(value)

  defp cut(text) do
    if String.length(text) > @arg_chars,
      do: String.slice(text, 0, @arg_chars - 1) <> "…",
      else: text
  end

  # The id of the context's actor, as an app's GraphQL context names it.
  defp actor(payload) do
    context = get_in(payload, ["metadata", "options", "context"])

    if is_map(context) do
      Enum.find_value(~w(actor current_user user viewer), fn key ->
        case context[key] do
          %{"id" => id} when is_binary(id) or is_integer(id) -> to_string(id)
          _none -> nil
        end
      end)
    end
  end

  defp positive(count) when is_integer(count) and count > 0, do: count
  defp positive(_count), do: nil

  defp names([_ | _] = names), do: "[" <> Enum.join(names, ",") <> "]"
  defp names(_names), do: nil

  defp ranked(entries, label, value_key \\ nil)

  defp ranked([_ | _] = entries, label, value_key) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.take(@ranked)
    |> Enum.map_join(",", fn entry ->
      if value_key,
        do: "#{label.(entry)}:#{entry[value_key]}",
        else: label.(entry)
    end)
  end

  defp ranked(_entries, _label, _value_key), do: nil

  defp table(entry), do: to_string(entry["table"] || "?")

  # `cat:39(+3)`: count and change since the previous scan, when known.
  defp port_type(entry) do
    delta =
      case entry["delta"] do
        delta when is_integer(delta) and delta >= 0 -> "(+#{delta})"
        delta when is_integer(delta) -> "(#{delta})"
        _unknown -> ""
      end

    "#{entry["type"]}:#{entry["count"]}#{delta}"
  end

  defp process(entry),
    do: to_string(short_module(entry["name"]) || entry["initial_call"] || entry["pid"] || "?")

  defp mfa(%{"module" => module, "function" => function, "arity" => arity}),
    do: "#{short_module(module)}.#{function}/#{arity}"

  defp mfa(value), do: value

  defp short_module("Elixir." <> name), do: name
  defp short_module(name), do: name

  defp omitted(%{"omitted" => omitted}) when is_integer(omitted) and omitted > 0,
    do: [{"omitted", omitted}]

  defp omitted(_metrics), do: []

  defp unavailable(%{"unavailable" => [_ | _] = names}),
    do: [{"unavailable", Enum.join(names, ",")}]

  defp unavailable(_attributes), do: []

  defp reason(%{"__struct__" => name}) when is_binary(name),
    do: String.replace_prefix(name, "Elixir.", "")

  defp reason(value), do: first_line(value)

  defp reason_message(%{"__struct__" => _name, "message" => message}), do: first_line(message)
  defp reason_message(_reason), do: nil

  # The first line of a text, cut to a bound; an HTML document (such as a
  # Plug debugger page) is named, never printed.
  defp first_line(text) when is_binary(text) do
    if html?(text) do
      "[html #{byte_size(text)} bytes]"
    else
      line = text |> String.split("\n", parts: 2) |> hd()

      if byte_size(line) > @text_bytes,
        do:
          (line |> binary_part(0, @text_bytes) |> String.chunk(:valid) |> List.first("")) <> "…",
        else: line
    end
  end

  defp first_line(_value), do: nil

  @doc "Whether a text is an HTML document or fragment rather than a message."
  @spec html?(String.t()) :: boolean()
  def html?(text),
    do:
      String.match?(text, ~r/\A\s*<(!doctype|html|head|body|div|pre|style|script|main|table)\b/i) or
        String.contains?(text, ["</html>", "</body>"])

  defp short_id("atom:Elixir." <> name), do: name
  defp short_id("atom:" <> name), do: name
  defp short_id(id), do: id

  defp gaps([]), do: "none"

  defp gaps(gaps) when is_list(gaps),
    do: Enum.map_join(gaps, ",", &"#{&1["reason"]}:#{&1["count"] || "unknown"}")

  defp gaps(_gaps), do: nil

  # Every non-zero filtered count as `group.name.filter:count`.
  defp filtered(%{} = filtered) do
    counts =
      for {group, value} <- Enum.sort(filtered),
          group != "scope",
          {path, count} <- flatten(value, [group]),
          is_integer(count) and count > 0,
          do: Enum.join(path, ".") <> ":" <> Integer.to_string(count)

    if counts == [], do: "none", else: Enum.join(counts, ",")
  end

  defp filtered(_filtered), do: nil

  defp flatten(%{} = map, path),
    do: map |> Enum.sort() |> Enum.flat_map(fn {key, value} -> flatten(value, path ++ [key]) end)

  defp flatten(value, path), do: [{path, value}]

  defp clock(wall_time) when is_binary(wall_time) do
    case DateTime.from_iso8601(wall_time) do
      {:ok, at, _offset} ->
        at |> DateTime.to_time() |> Time.truncate(:millisecond) |> Time.to_iso8601()

      _error ->
        "-"
    end
  end

  defp clock(_wall_time), do: "-"

  defp hash_line([label | fields]) do
    pairs = fields |> Enum.map(&pair/1) |> Enum.reject(&(&1 == ""))
    ["# ", Enum.join([label | pairs], " "), "\n"]
  end

  defp pair({_key, nil}), do: ""
  # JSON delimits itself: printed as is, readable.
  defp pair({key, {:json, json}}), do: "#{key}=#{json}"
  defp pair({key, value}) when is_integer(value) or is_boolean(value), do: "#{key}=#{value}"

  defp pair({key, value}) when is_binary(value) do
    if value != "" and String.match?(value, ~r/\A[^\s"=]+\z/u),
      do: "#{key}=#{value}",
      else: "#{key}=#{Jason.encode!(value)}"
  end

  defp pair({key, value}), do: "#{key}=#{Jason.encode!(value)}"
end
