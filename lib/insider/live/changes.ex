defmodule Insider.Live.Changes do
  @moduledoc false

  # Who changed an in-memory value. Another user's
  # setFeatureToggle can flip a process-global flag in local dev; the
  # flag's store holds only its current value, so who flipped it, and when,
  # is gone afterwards.
  #
  # A watched write (`watch_writes`, `Insider.Collector.Calls.Trace`) is a
  # `call` event with `"write"` and `"key"`. Pure functions over disclosed
  # events pair each write with the request of the process that made it:
  # the events of the same process whose time covers the write (a span, a
  # request stop, an Absinthe operation stop), else the next one within
  # @follow_us. From them: the GraphQL operation, the route, the user agent,
  # the trace id, and, in the rich profile, the user id a span's
  # `user.id`/`usr.id` attribute or a Logger event's `usr.id` metadata names.
  # When the operation's events were evicted, the session's kept mutation
  # record (`Insider.Live.Mutations`) of the same process fills it in. The
  # written value is the write's rendered arguments after the key, shown
  # only under rich (strict records no arguments).

  @follow_us 60_000_000
  @pair_keys [
    "Application.put_env/3",
    "Application.put_env/4",
    ":application.set_env/3",
    ":application.set_env/4"
  ]

  @doc """
  The writes in `entries`, oldest first, each with its writer. Options:
  `:key` keeps one key's writes; `:mutations` are kept mutation records.
  """
  @spec of([map()], keyword()) :: [map()]
  def of(entries, options \\ []) do
    key = Keyword.get(options, :key)
    kept = Keyword.get(options, :mutations, [])
    context = entries |> Enum.flat_map(&context/1) |> Enum.group_by(& &1.pid)

    entries
    |> Enum.flat_map(&write/1)
    |> Enum.filter(&(is_nil(key) or &1["key"] == key))
    |> Enum.sort_by(&{&1.at_us, &1["receipt"]})
    |> Enum.map(fn write ->
      writer = writer(write, Map.get(context, write["writer"]["pid"], []), kept)
      write |> Map.delete(:at_us) |> Map.put("writer", writer)
    end)
  end

  defp write(%{
         "receipt" => receipt,
         "event" => %{"attributes" => %{"write" => true} = a} = event
       }) do
    pid = get_in(event, ["subject", "value"])
    at = wall_us(event["wall_time"])

    if is_integer(at) do
      [
        %{
          :at_us => at,
          "receipt" => receipt,
          "at" => event["wall_time"],
          "key" => a["key"],
          "function" => a["function"],
          "value" => value(a["function"], get_in(event, ["payload", "arguments"])),
          "writer" => %{"pid" => pid}
        }
      ]
    else
      []
    end
  end

  defp write(_entry), do: []

  # The arguments after the key: one value, else the rest as a list.
  defp value(function, [_app, _key, value | _rest]) when function in @pair_keys, do: value
  defp value(_function, [_key, value]), do: value
  defp value(_function, [_key | [_ | _] = rest]), do: rest
  defp value(_function, _arguments), do: nil

  # The request evidence of one event: its process, the interval it covers,
  # and what it says of the request.
  defp context(%{"event" => %{} = event}) do
    pid = get_in(event, ["subject", "value"])
    end_us = wall_us(event["wall_time"])

    if is_binary(pid) and is_integer(end_us) do
      facts = facts(event)

      if facts == %{},
        do: [],
        else: [%{pid: pid, end_us: end_us, start_us: end_us - span_us(event), facts: facts}]
    else
      []
    end
  end

  defp context(_entry), do: []

  defp span_us(%{"attributes" => %{"request" => %{"total_us" => us}}}) when is_integer(us), do: us

  defp span_us(%{"attributes" => %{"request" => %{"handler_us" => us}}}) when is_integer(us),
    do: us

  defp span_us(%{"source" => "otel", "attributes" => %{"duration_us" => us}}) when is_integer(us),
    do: us

  defp span_us(%{"attributes" => %{"durations_us" => %{"duration" => us}}}) when is_integer(us),
    do: us

  defp span_us(_event), do: 0

  defp facts(
         %{"kind" => "absinthe.execute.operation.stop", "attributes" => %{"graphql" => graphql}} =
           event
       ) do
    operation =
      [graphql["operation_type"], operation_name(graphql, event["payload"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    %{operation: if(operation == "", do: nil, else: operation), trace_id: trace_id(event)}
  end

  defp facts(%{"attributes" => %{"request" => %{"role" => "server"} = request}} = event) do
    route = [request["method"], request["path"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    %{
      route: if(route == "", do: nil, else: route),
      user_agent: request["user_agent"],
      trace_id: trace_id(event)
    }
  end

  defp facts(%{"source" => "otel"} = event) do
    attributes = get_in(event, ["payload", "span_attributes"]) || %{}
    %{trace_id: trace_id(event), user_id: user_id(attributes)}
  end

  defp facts(%{"source" => "logger"} = event) do
    metadata = get_in(event, ["payload", "metadata"]) || %{}
    %{trace_id: trace_id(event), user_id: user_id(metadata)}
  end

  defp facts(_event), do: %{}

  @doc """
  An operation's name, or for an anonymous mutation in the rich profile its
  top-level fields (schema names, from `payload.graphql_arguments`).
  """
  @spec operation_name(map(), map() | nil) :: String.t() | nil
  def operation_name(%{"operation_name" => name}, _payload) when is_binary(name), do: name

  def operation_name(_graphql, %{"graphql_arguments" => %{} = fields}) when map_size(fields) > 0,
    do: fields |> Map.keys() |> Enum.sort() |> Enum.join(",")

  def operation_name(_graphql, _payload), do: nil

  defp user_id(%{} = map) do
    Enum.find_value(["user.id", "usr.id"], fn key ->
      case Map.get(map, key) do
        id when is_binary(id) or is_integer(id) -> to_string(id)
        _none -> nil
      end
    end)
  end

  defp trace_id(event) do
    case get_in(event, ["causality", "trace_id"]) || get_in(event, ["attributes", "trace_id"]) do
      id when is_binary(id) -> id
      _none -> nil
    end
  end

  # One request names a write's writer, never several. The events of the
  # process whose time covers the write come first: a process runs one
  # request at a time, so they are its request, unless they name two traces
  # (then the write is unattributed). Without them, the nearest event of the
  # process that ended after the write, within @follow_us, and only the
  # events of its trace. A later event of another trace (the connection's
  # next request) never adds a fact. When no event names an operation, the
  # nearest kept mutation record of the process fills it in, if its trace
  # agrees.
  defp writer(write, context, kept) do
    at = write.at_us
    pid = write["writer"]["pid"]
    covering = Enum.filter(context, &(&1.start_us <= at and &1.end_us >= at))

    following =
      context
      |> Enum.filter(&(&1.end_us >= at and &1.end_us - at <= @follow_us))
      |> Enum.sort_by(& &1.end_us)

    case request(covering, following) do
      {:ok, attribution, events} ->
        facts = merge_facts(events)

        writer =
          Map.merge(unattributed(pid, nil), %{
            "operation" => facts[:operation],
            "route" => facts[:route],
            "user_agent" => facts[:user_agent],
            "user_id" => facts[:user_id],
            "trace_id" => facts[:trace_id],
            "attribution" => attribution
          })

        if is_nil(writer["operation"]), do: from_kept(writer, at, kept), else: writer

      {:conflict, traces} ->
        unattributed(pid, "requests of #{traces} traces around the write")

      :none ->
        from_kept(unattributed(pid, "no request of its process around the write"), at, kept)
    end
  end

  defp request([_ | _] = covering, following) do
    case covering |> Enum.map(& &1.facts[:trace_id]) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        {:ok, "covering", covering}

      [trace] ->
        {:ok, "covering", covering ++ Enum.filter(following, &(&1.facts[:trace_id] == trace))}

      traces ->
        {:conflict, length(traces)}
    end
  end

  defp request([], [nearest | _] = following) do
    case nearest.facts[:trace_id] do
      nil -> {:ok, "following", [nearest]}
      trace -> {:ok, "following", Enum.filter(following, &(&1.facts[:trace_id] == trace))}
    end
  end

  defp request([], []), do: :none

  defp merge_facts(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      event.facts
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(acc)
    end)
  end

  defp unattributed(pid, why) do
    %{
      "pid" => pid,
      "operation" => nil,
      "route" => nil,
      "user_agent" => nil,
      "user_id" => nil,
      "trace_id" => nil,
      "attribution" => "unattributed",
      "unattributed" => why
    }
  end

  # The operation from the kept mutation record of the same process that
  # ended at or after the write, within @follow_us, whose trace agrees.
  defp from_kept(writer, at, kept) do
    record =
      kept
      |> Enum.filter(fn record ->
        end_us = wall_us(record["at"])

        record["pid"] == writer["pid"] and is_integer(end_us) and end_us >= at and
          end_us - at <= @follow_us and
          (is_nil(writer["trace_id"]) or record["trace_id"] == writer["trace_id"])
      end)
      |> Enum.min_by(&wall_us(&1["at"]), fn -> nil end)

    case record do
      nil ->
        writer

      record ->
        Map.merge(writer, %{
          "operation" =>
            Enum.join(Enum.reject(["mutation", record["operation"]], &is_nil/1), " "),
          "trace_id" => writer["trace_id"] || record["trace_id"],
          "kept" => true,
          "attribution" =>
            if(writer["attribution"] == "unattributed",
              do: "kept_record",
              else: writer["attribution"]
            ),
          "unattributed" => nil
        })
    end
  end

  @doc """
  The keys written more than once, each with its distinct values and
  writers, over every write given. `complete` is false when the writes are
  known to be a part of the window's (a capped or incomplete read): the
  counts are then lower bounds.
  """
  @spec repeated([map()], boolean()) :: [map()]
  def repeated(changes, complete \\ true) do
    changes
    |> Enum.group_by(& &1["key"])
    |> Enum.filter(fn {key, writes} -> is_binary(key) and match?([_, _ | _], writes) end)
    |> Enum.map(fn {key, writes} ->
      values =
        writes |> Enum.map(& &1["value"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

      writers =
        writes
        |> Enum.frequencies_by(&describe(&1["writer"]))
        |> Enum.sort_by(fn {writer, n} -> {-n, writer} end)
        |> Enum.take(3)
        |> Enum.map(fn {writer, n} -> %{"writer" => writer, "writes" => n} end)

      %{
        "key" => key,
        "writes" => length(writes),
        "values" => values,
        "writers" => writers,
        "complete" => complete
      }
    end)
    |> Enum.sort_by(&{-&1["writes"], &1["key"]})
  end

  @doc "A writer in a few words: its operation and user, else its route, else its process."
  @spec describe(map()) :: String.t()
  def describe(writer) do
    user = if writer["user_id"], do: " by user #{writer["user_id"]}", else: ""

    cond do
      writer["operation"] -> writer["operation"] <> user
      writer["route"] -> writer["route"] <> user
      true -> "pid #{writer["pid"]}"
    end
  end

  @doc """
  The text of `changes`: a header and one line per write shown. `total` is
  the number of writes the shown ones were taken from.
  """
  @spec lines([map()], String.t() | nil, non_neg_integer() | nil) :: [String.t()]
  def lines(changes, key, total \\ nil) do
    what = if key, do: "Changes of #{key}", else: "Changes"
    total = total || length(changes)
    noun = if total == 1, do: "write", else: "writes"

    shown =
      if total > length(changes), do: " (the newest #{length(changes)} shown)", else: ""

    header = "#{what}: #{total} #{noun}#{shown}"

    [header | Enum.map(changes, &line/1)]
  end

  defp line(change) do
    writer = change["writer"]

    value =
      if is_nil(change["value"]), do: "", else: " = #{Jason.encode!(change["value"]) |> cut()}"

    by =
      if writer["operation"] || writer["route"] do
        details =
          [
            writer["operation"] && writer["route"],
            writer["user_id"] && "user #{writer["user_id"]}",
            writer["user_agent"]
          ]
          |> Enum.filter(&is_binary/1)

        details = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"
        kept = if writer["kept"], do: " [kept mutation record]", else: ""
        trace = if writer["trace_id"], do: ", trace #{writer["trace_id"]}", else: ""

        "by #{writer["operation"] || writer["route"]}#{details}#{kept}#{trace}, pid #{writer["pid"]}"
      else
        "by pid #{writer["pid"]} (unattributed: #{writer["unattributed"] || "no request of its process around the write"})"
      end

    "  #{clock(change["at"])} #{change["key"] || "?"}#{value} #{by}"
  end

  defp cut(text) when byte_size(text) > 80, do: String.slice(text, 0, 77) <> "…"
  defp cut(text), do: text

  defp clock(at) when is_binary(at), do: String.slice(at, 11, 12)
  defp clock(_at), do: "?"

  defp wall_us(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :microsecond)
      _error -> nil
    end
  end

  defp wall_us(_text), do: nil
end
