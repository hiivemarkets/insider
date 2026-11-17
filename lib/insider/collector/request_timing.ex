defmodule Insider.Collector.RequestTiming do
  @moduledoc false

  # How long each HTTP request waited before the application's own request
  # handling began, and bursts of request arrivals. Pages can hang
  # for seconds while another client's bursts queue in the dev code
  # reloader, which runs before Phoenix's endpoint telemetry
  # (`Plug.Telemetry`). Every request then looks fast in that telemetry,
  # the wait is slow to place, and nothing links it to the bursts.
  #
  # At record time (in the emitting process, bounded), a Telemetry event of
  # the web server's request stop (`bandit.request.stop`, or Cowboy's with
  # cowboy_telemetry) carries `attributes.request` with role `"server"`:
  # its total time, time to the response's start, method, status, and
  # whether it carried a `traceparent`; in the rich profile also its path,
  # user agent, and remote address (credential-masked, at most 128 bytes).
  # Phoenix's endpoint stop carries role `"handler"` with the endpoint's own
  # time. Nothing else is read.
  #
  # At read time, `pair/1` matches each server request with the endpoint
  # stop its process emitted inside it: the wait before the handler is the
  # time to the response's start (else the total) less the endpoint's time.
  # In dev that is the code reloader and every plug before `Plug.Telemetry`.
  # `summary/1` adds the slowest waits and the bursts: seconds whose arrivals
  # reach @burst_min and @burst_factor times the usual busy-second rate (the
  # median of the window's seconds with any arrival), together with the
  # seconds next to them at @burst_factor times that rate, with their top
  # sources and the requests that overlapped them.

  alias Insider.Collector.Rich

  @server_events [[:bandit, :request, :stop], [:cowboy, :request, :stop]]
  @handler_event [:phoenix, :endpoint, :stop]
  @text_bytes 128
  @headers_max 64
  @burst_min 30
  @burst_factor 5
  @wait_shown_us 100_000
  @slowest 5
  @bursts_max 3
  @sources_max 3

  @doc "The Telemetry events that carry request timing."
  @spec events() :: [[atom()]]
  def events, do: [@handler_event | @server_events]

  @doc "Whether the event named `name` carries request timing."
  @spec event?([atom()]) :: boolean()
  def event?(name), do: name == @handler_event or name in @server_events

  @doc """
  The `attributes.request` of one request stop event, or `nil`.
  `collection` says what the session collects: `rich` adds the path, user
  agent, and remote address; `timed` (the `duration` measurement is
  selected, or rich collects every measurement) adds the timings, which are
  otherwise left out, and the request says `"timing_withheld"`.
  """
  @spec from([atom()], map(), term(), %{rich: boolean(), timed: boolean()}) :: map() | nil
  def from([:bandit, :request, :stop], measurements, %{} = metadata, collection) do
    conn = map(Map.get(metadata, :conn))
    {agent, traced?} = headers(Map.get(conn, :req_headers))
    start = start_time(measurements)

    %{
      "role" => "server",
      "server" => "bandit",
      "method" => method(Map.get(conn, :method)),
      "status" => integer(Map.get(conn, :status)),
      "traced" => traced?
    }
    |> timings(collection, %{
      "total_us" => native_us(measurements[:duration]),
      "response_us" => since(measurements[:resp_start_time], start),
      "headers_us" => since(measurements[:req_header_end_time], start)
    })
    |> source(collection, fn ->
      {Map.get(conn, :request_path), agent, Map.get(conn, :remote_ip)}
    end)
  rescue
    _error -> nil
  end

  # cowboy_telemetry emits the stop from the connection's stream handler,
  # not the request process Phoenix runs in, so the request is identified
  # by its connection and stream (`"stream"`), as the endpoint's is.
  def from([:cowboy, :request, :stop], measurements, %{} = metadata, collection) do
    req = map(Map.get(metadata, :req))
    {agent, traced?} = headers(Map.get(req, :headers))

    stream =
      stream(
        Map.get(metadata, :pid) || Map.get(req, :pid),
        Map.get(metadata, :streamid) || Map.get(req, :streamid)
      )

    %{
      "role" => "server",
      "server" => "cowboy",
      "method" => method(Map.get(req, :method)),
      "status" => integer(Map.get(metadata, :resp_status)),
      "traced" => traced?,
      "stream" => stream
    }
    |> timings(collection, %{"total_us" => native_us(measurements[:duration])})
    |> source(collection, fn ->
      ip =
        case Map.get(req, :peer) do
          {ip, _port} -> ip
          _none -> nil
        end

      {Map.get(req, :path), agent, ip}
    end)
  rescue
    _error -> nil
  end

  def from([:phoenix, :endpoint, :stop], measurements, %{} = metadata, collection) do
    conn = map(Map.get(metadata, :conn))

    stream =
      case Map.get(conn, :adapter) do
        {Plug.Cowboy.Conn, %{} = req} -> stream(Map.get(req, :pid), Map.get(req, :streamid))
        _other -> nil
      end

    %{
      "role" => "handler",
      "method" => method(Map.get(conn, :method)),
      "status" => integer(Map.get(conn, :status)),
      "stream" => stream
    }
    |> timings(collection, %{"handler_us" => native_us(measurements[:duration])})
  rescue
    _error -> nil
  end

  def from(_name, _measurements, _metadata, _collection), do: nil

  defp map(%{} = map), do: map
  defp map(_value), do: %{}

  defp timings(request, %{timed: true}, timings), do: Map.merge(request, timings)
  defp timings(request, _collection, _timings), do: Map.put(request, "timing_withheld", true)

  defp stream(pid, stream) when is_pid(pid) and is_integer(stream),
    do: (pid |> :erlang.pid_to_list() |> to_string()) <> "/" <> Integer.to_string(stream)

  defp stream(_pid, _stream), do: nil

  @doc """
  A request's client (`"user_agent"`, `"remote_ip"`), as a rich request
  stop records it: the user agent bounded and credential-masked
  (`Insider.Collector.Rich.text_field/2`), the address as text.
  """
  @spec client(term(), term()) :: map()
  def client(agent, ip),
    do: %{"user_agent" => Rich.text_field(agent, @text_bytes), "remote_ip" => ip_text(ip)}

  # A source field that cannot be read leaves the request's timing intact.
  # Each text is bounded before it is read and masked before it is cut
  # (`Insider.Collector.Rich.text_field/2`).
  defp source(request, %{rich: true}, fields) do
    {path, agent, ip} = fields.()

    Map.merge(request, %{
      "path" => Rich.text_field(path, @text_bytes),
      "user_agent" => Rich.text_field(agent, @text_bytes),
      "remote_ip" => ip_text(ip)
    })
  rescue
    _error -> request
  end

  defp source(request, _collection, _fields), do: request

  # The user agent and whether a `traceparent` was sent, from at most
  # @headers_max headers compared by exact name (Plug and Cowboy keep
  # header names lowercase), so no name is copied or converted.
  defp headers(headers) when is_list(headers) do
    headers
    |> Enum.take(@headers_max)
    |> Enum.reduce({nil, false}, fn
      {"user-agent", value}, {nil, traced?} -> {value, traced?}
      {"traceparent", _value}, {agent, _traced?} -> {agent, true}
      _other, acc -> acc
    end)
  end

  defp headers(%{} = headers),
    do: {Map.get(headers, "user-agent"), Map.has_key?(headers, "traceparent")}

  defp headers(_headers), do: {nil, false}

  # Plug's and Cowboy's methods are short upper-case tokens.
  defp method(method) when is_binary(method) and byte_size(method) <= 16 do
    if String.match?(method, ~r/\A[A-Z]+\z/), do: method
  end

  defp method(_method), do: nil

  # The address as Erlang's `inet:ntoa/1` writes it. Production code calls no
  # network module (`scripts/verify-production-artifact`), so the text is
  # built here. A malformed address gives no text.
  defguardp byte(value) when is_integer(value) and value >= 0 and value <= 255
  defguardp word(value) when is_integer(value) and value >= 0 and value <= 0xFFFF

  defp ip_text({a, b, c, d}) when byte(a) and byte(b) and byte(c) and byte(d),
    do: Enum.join([a, b, c, d], ".")

  defp ip_text({0, 0, 0, 0, 0, 0, 0, 0}), do: "::"
  defp ip_text({0, 0, 0, 0, 0, 0, 0, 1}), do: "::1"

  # IPv4-compatible and IPv4-mapped addresses end in dotted decimal.
  defp ip_text({0, 0, 0, 0, 0, 0, g, h}) when word(g) and word(h),
    do: "::" <> embedded_ipv4(g, h)

  defp ip_text({0, 0, 0, 0, 0, 0xFFFF, g, h}) when word(g) and word(h),
    do: "::ffff:" <> embedded_ipv4(g, h)

  defp ip_text({_, _, _, _, _, _, _, _} = ip) do
    words = Tuple.to_list(ip)
    if Enum.all?(words, fn value -> word(value) end), do: ipv6_text(words)
  end

  defp ip_text(_ip), do: nil

  defp embedded_ipv4(g, h),
    do: Enum.join([div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)], ".")

  # The longest run of two or more zero words (the first on a tie) becomes "::".
  defp ipv6_text(words) do
    hex = Enum.map(words, &String.downcase(Integer.to_string(&1, 16)))

    case longest_zero_run(words) do
      nil ->
        Enum.join(hex, ":")

      {start, length} ->
        {left, rest} = Enum.split(hex, start)
        Enum.join(left, ":") <> "::" <> Enum.join(Enum.drop(rest, length), ":")
    end
  end

  defp longest_zero_run(words) do
    words
    |> Enum.with_index()
    |> Enum.chunk_by(fn {value, _index} -> value == 0 end)
    |> Enum.filter(&match?([{0, _index}, _next | _rest], &1))
    |> Enum.max_by(&length/1, fn -> nil end)
    |> zero_run()
  end

  defp zero_run(nil), do: nil
  defp zero_run([{0, start} | _rest] = run), do: {start, length(run)}

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp native_us(value) when is_integer(value) and value >= 0,
    do: System.convert_time_unit(value, :native, :microsecond)

  defp native_us(_value), do: nil

  defp start_time(%{monotonic_time: stop, duration: duration})
       when is_integer(stop) and is_integer(duration),
       do: stop - duration

  defp start_time(_measurements), do: nil

  defp since(time, start) when is_integer(time) and is_integer(start) and time >= start,
    do: native_us(time - start)

  defp since(_time, _start), do: nil

  ## Read time

  @doc """
  The server requests of disclosed `entries` (`%{"receipt", "event"}`), each
  paired with the endpoint stop its process emitted inside it, oldest
  arrival first: `"receipt"`, `"pid"`, `"arrival_us"`, `"end_us"`, the
  request's attributes, `"handler_us"` and `"wait_us"` (`nil` without an
  endpoint stop: served before `Plug.Telemetry`, or not recorded).
  """
  @spec pair([map()]) :: [map()]
  def pair(entries) do
    {servers, handlers} =
      entries
      |> Enum.flat_map(&request/1)
      |> Enum.split_with(&(&1["role"] == "server"))

    handlers = Enum.group_by(handlers, &key/1)

    servers
    |> Enum.sort_by(&{&1["end_us"], &1["receipt"]})
    |> Enum.map_reduce(handlers, fn server, handlers ->
      own = Map.get(handlers, key(server), [])

      case Enum.filter(
             own,
             &(&1["end_us"] >= server["arrival_us"] and &1["end_us"] <= server["end_us"])
           ) do
        [] ->
          {Map.merge(server, %{"handler_us" => nil, "wait_us" => nil}), handlers}

        inside ->
          handler = Enum.max_by(inside, & &1["end_us"])
          until = server["response_us"] || server["total_us"]
          wait = if handler["handler_us"], do: max(until - handler["handler_us"], 0)

          {Map.merge(server, %{"handler_us" => handler["handler_us"], "wait_us" => wait}),
           Map.put(handlers, key(server), List.delete(own, handler))}
      end
    end)
    |> elem(0)
    |> Enum.sort_by(&{&1["arrival_us"], &1["receipt"]})
  end

  # A Cowboy request is its connection and stream; any other its process.
  defp key(%{"stream" => stream}) when is_binary(stream), do: {:stream, stream}
  defp key(request), do: {:pid, request["pid"]}

  defp request(%{
         "receipt" => receipt,
         "event" => %{"attributes" => %{"request" => %{} = request}} = event
       }) do
    pid = get_in(event, ["subject", "value"])
    end_us = wall_us(event["wall_time"])

    cond do
      not is_binary(pid) or is_nil(end_us) ->
        []

      request["role"] == "server" and is_integer(request["total_us"]) ->
        [
          Map.merge(request, %{
            "receipt" => receipt,
            "pid" => pid,
            "end_us" => end_us,
            "arrival_us" => end_us - request["total_us"]
          })
        ]

      request["role"] == "handler" ->
        [Map.merge(request, %{"receipt" => receipt, "pid" => pid, "end_us" => end_us})]

      true ->
        []
    end
  end

  defp request(_entry), do: []

  @doc "Adds `wait_us` and `handler_us` to each paired server request's attributes."
  @spec annotate([map()]) :: [map()]
  def annotate(entries) do
    waits =
      for %{"wait_us" => wait} = pair <- pair(entries),
          not is_nil(wait),
          into: %{},
          do: {pair["receipt"], Map.take(pair, ["wait_us", "handler_us"])}

    if waits == %{} do
      entries
    else
      Enum.map(entries, fn entry ->
        case Map.fetch(waits, entry["receipt"]) do
          {:ok, wait} ->
            update_in(entry, ["event", "attributes", "request"], &Map.merge(&1, wait))

          :error ->
            entry
        end
      end)
    end
  end

  @doc "The requests, the slowest waits, and the bursts of disclosed `entries`."
  @spec summary([map()]) :: map()
  def summary(entries) do
    {observer, requests} = Enum.split_with(pair(entries), &observer?/1)
    waits = requests |> Enum.map(& &1["wait_us"]) |> Enum.reject(&is_nil/1)

    %{
      "requests" => length(requests),
      "timing_withheld" => Enum.count(entries, &timing_withheld?/1),
      "with_handler" => length(waits),
      "waited_100ms" => Enum.count(waits, &(&1 >= @wait_shown_us)),
      "wait_p95_us" => percentile(waits, 95),
      "slowest_waits" =>
        requests
        |> Enum.filter(&(&1["wait_us"] != nil))
        |> Enum.sort_by(&{-&1["wait_us"], &1["receipt"]})
        |> Enum.take(@slowest)
        |> Enum.map(&row/1),
      "bursts" => bursts(requests),
      "observer" => %{
        "requests" => length(observer),
        "paths" =>
          observer |> Enum.map(&observer_prefix(&1["path"])) |> Enum.uniq() |> Enum.sort()
      }
    }
  end

  # An observer's own requests (Tidewave's MCP endpoint) are the agent's
  # tools, not the app's traffic: they are counted apart and left out of
  # the waits and bursts. Only a rich request has a path, so under strict
  # they are counted with the rest.
  @observer_prefixes ["/tidewave"]

  defp observer?(%{"path" => path}) when is_binary(path), do: observer_prefix(path) != nil
  defp observer?(_request), do: false

  defp observer_prefix(path) when is_binary(path) do
    Enum.find(@observer_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp observer_prefix(_path), do: nil

  defp timing_withheld?(%{"event" => %{"attributes" => %{"request" => %{} = request}}}),
    do: request["timing_withheld"] == true

  defp timing_withheld?(_entry), do: false

  defp row(request) do
    request
    |> Map.take([
      "receipt",
      "method",
      "path",
      "status",
      "user_agent",
      "remote_ip",
      "traced",
      "wait_us",
      "total_us"
    ])
    |> Map.put("at", iso(request["arrival_us"]))
  end

  defp bursts([]), do: []

  defp bursts(requests) do
    by_second = Enum.group_by(requests, &div(&1["arrival_us"], 1_000_000))
    busy = by_second |> Map.values() |> Enum.map(&length/1) |> Enum.sort()
    baseline = Enum.at(busy, div(length(busy) - 1, 2))
    threshold = max(@burst_min, @burst_factor * baseline)
    count = fn second -> length(Map.get(by_second, second, [])) end

    # A burst is a run of seconds at @burst_factor times the usual rate
    # that reaches the threshold in at least one: a burst that straddles a
    # second boundary keeps its stragglers.
    by_second
    |> Enum.filter(fn {_second, arrivals} -> length(arrivals) >= @burst_factor * baseline end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn second, run ->
        case run do
          [previous | _] when second == previous + 1 -> {:cont, [second | run]}
          [] -> {:cont, [second]}
          run -> {:cont, Enum.reverse(run), [second]}
        end
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.filter(fn run -> Enum.any?(run, &(count.(&1) >= threshold)) end)
    |> Enum.map(&burst(&1, by_second, requests, baseline))
    |> Enum.sort_by(&{-&1["requests"], &1["at"]})
    |> Enum.take(@bursts_max)
  end

  defp burst(seconds, by_second, requests, baseline) do
    members = Enum.flat_map(seconds, &Map.fetch!(by_second, &1))
    receipts = MapSet.new(members, & &1["receipt"])
    from = members |> Enum.map(& &1["arrival_us"]) |> Enum.min()
    until = members |> Enum.map(& &1["end_us"]) |> Enum.max()

    others =
      Enum.filter(requests, fn request ->
        not MapSet.member?(receipts, request["receipt"]) and request["arrival_us"] <= until and
          request["end_us"] >= from
      end)

    %{
      "at" => iso(from),
      "seconds" => length(seconds),
      "requests" => length(members),
      "peak_per_s" => seconds |> Enum.map(&length(Map.fetch!(by_second, &1))) |> Enum.max(),
      "baseline_per_s" => baseline,
      "sources" => sources(members),
      "max_wait_us" => max_wait(members),
      "others_overlapping" => length(others),
      "others_max_wait_us" => max_wait(others)
    }
  end

  defp sources(members) do
    members
    |> Enum.group_by(&source_name/1)
    |> Enum.map(fn {source, group} ->
      %{
        "source" => source,
        "requests" => length(group),
        "traced" => Enum.count(group, & &1["traced"])
      }
    end)
    |> Enum.sort_by(&{-&1["requests"], &1["source"]})
    |> Enum.take(@sources_max)
  end

  defp source_name(%{"user_agent" => agent}) when is_binary(agent), do: "user agent " <> agent
  defp source_name(%{"remote_ip" => ip}) when is_binary(ip), do: "address " <> ip
  defp source_name(%{"traced" => true}), do: "traced"
  defp source_name(_request), do: "untraced"

  defp max_wait(requests) do
    requests |> Enum.map(& &1["wait_us"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
  end

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * p, 100)))
  end

  ## Text

  @doc "A request as one phrase: method, path, status, and user agent when disclosed."
  @spec describe(map()) :: String.t()
  def describe(request) do
    agent = if is_binary(request["user_agent"]), do: " (#{request["user_agent"]})", else: ""

    [request["method"], request["path"], request["status"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> Kernel.<>(agent)
  end

  @doc "A duration in microseconds as text: seconds to one decimal from 1 s, else milliseconds."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(us) when us >= 1_000_000,
    do: :io_lib.format("~.1f s", [us / 1_000_000]) |> to_string()

  def duration(us), do: "#{div(us, 1_000)} ms"

  defp iso(nil), do: nil
  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  @doc "An event's ISO 8601 `wall_time` in Unix microseconds, or `nil`."
  @spec wall_us(term()) :: integer() | nil
  def wall_us(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, value, _offset} -> DateTime.to_unix(value, :microsecond)
      _error -> nil
    end
  end

  def wall_us(_text), do: nil
end
