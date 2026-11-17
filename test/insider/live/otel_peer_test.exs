# Runs inside the peer nodes. It is defined here rather than in
# test/support so that its object code, pushed to each peer, is the only
# copy: cover instruments this node's modules, never a peer's.
{:module, _name, otel_peer_beam, _exports} =
  defmodule Insider.Test.OtelPeer do
    @moduledoc false

    # Runs inside a peer node with the OpenTelemetry SDK: a fake Phoenix-style
    # request (a server span, an Absinthe operation, an Ecto query) that logs
    # and emits Telemetry inside its spans, and a pid exporter sink that shows
    # the node's own span processor still receives every span.

    require Logger

    @repo_query [:my_app, :repo, :query]

    @doc "Starts Logger and Insider in the peer (without the SDK)."
    @spec boot() :: :ok
    def boot do
      {:ok, _apps} = Application.ensure_all_started(:logger)
      # The peer's standard output is its control channel: no console handler.
      _removed = :logger.remove_handler(:default)
      :ok = :logger.set_primary_config(:level, :all)
      Application.put_env(:insider, :environment, :test)
      {:ok, _apps} = Application.ensure_all_started(:insider)
      # Make the Telemetry event's atoms exist for the session options.
      _atoms = @repo_query
      :ok
    end

    @doc """
    Starts the SDK with one simple processor whose exporter sends every
    finished span to a sink process.
    """
    @spec start_sdk() :: :ok
    def start_sdk do
      sink = spawn(fn -> sink([]) end)
      Process.register(sink, :insider_test_span_sink)

      Application.put_env(:opentelemetry, :processors, [
        {:otel_simple_processor, %{exporter: {:otel_exporter_pid, sink}}}
      ])

      Application.put_env(:opentelemetry, :resource, %{"service.name" => "my_app-test"})
      {:ok, _apps} = Application.ensure_all_started(:opentelemetry)
      :ok
    end

    @doc "The names of the spans the node's own exporter received."
    @spec exported() :: [String.t()]
    def exported do
      send(:insider_test_span_sink, {:list, self()})

      receive do
        {:spans, names} -> names
      after
        2_000 -> :timeout
      end
    end

    defp sink(names) do
      receive do
        {:span, span} ->
          sink([to_string(elem(span, 6)) | names])

        {:list, from} ->
          send(from, {:spans, Enum.reverse(names)})
          sink(names)
      end
    end

    @doc """
    One request in a new process, like a Bandit connection process. Returns
    the trace id, the request process, and the request id.
    """
    @spec request(String.t()) :: %{String.t() => String.t()}
    def request(request_id) do
      task =
        Task.async(fn ->
          Logger.metadata(request_id: request_id)
          tracer = :opentelemetry.get_tracer(:insider_test)

          root =
            :otel_tracer.start_span(tracer, "GET /graphql", %{
              kind: :server,
              attributes: %{
                "http.route": "/graphql",
                "http.request.header.authorization": "Bearer abc.def"
              }
            })

          _token = :otel_tracer.set_current_span(root)
          operation = :otel_tracer.start_span(tracer, "absinthe.execute.operation", %{})
          _token = :otel_tracer.set_current_span(operation)
          Logger.warning("resolving viewer")

          query =
            :otel_tracer.start_span(tracer, "my_app.repo.query:users", %{
              kind: :client,
              attributes: %{"db.statement": "SELECT u0.id FROM users u0"}
            })

          :telemetry.execute(
            @repo_query,
            %{total_time: System.convert_time_unit(3, :millisecond, :native)},
            %{
              source: "users"
            }
          )

          :otel_span.end_span(query)
          :otel_span.end_span(operation)
          _token = :otel_tracer.set_current_span(root)

          # A log line without trace context joins by its process and time.
          Logger.metadata(otel_trace_id: nil, otel_span_id: nil)
          Logger.warning("rendering response")

          :otel_span.set_status(root, :opentelemetry.status(:error, "boom"))
          :otel_span.end_span(root)

          %{
            "trace_id" => root |> :otel_span.hex_trace_id() |> to_string(),
            "pid" => self() |> :erlang.pid_to_list() |> to_string(),
            "request_id" => request_id
          }
        end)

      Task.await(task)
    end
  end

:persistent_term.put({Insider.Live.OtelPeerTest, :helper}, otel_peer_beam)

defmodule Insider.Live.OtelPeerTest do
  # Each test boots its own peer node; the peer, not this node, runs the
  # OpenTelemetry SDK, so this node's global SDK state is never touched.
  use ExUnit.Case, async: true

  alias Insider.Test.OtelPeer

  @moduletag timeout: 60_000

  setup do
    {otel, others} =
      :code.get_path()
      |> Enum.split_with(&(to_string(&1) =~ ~r{/opentelemetry(_api)?/ebin}))

    args = Enum.flat_map(others, &[~c"-pa", &1])
    # Not linked: a linked peer is shut down by this test process's exit,
    # concurrently with on_exit. on_exit then sometimes found it still
    # stopping, :peer.stop/1 returned normally, and `catch_exit` failed the
    # test with "Expected to catch exit, got nothing" (CI: :158 and :277).
    # The peer is stopped here, once, and on_exit waits until it is down.
    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, args: args, wait_boot: 30_000})

    on_exit(fn -> stop_peer(peer) end)
    beam = :persistent_term.get({__MODULE__, :helper})
    {:module, OtelPeer} = call(peer, :code, :load_binary, [OtelPeer, ~c"otel_peer", beam])
    :ok = call(peer, OtelPeer, :boot, [])
    %{peer: peer, otel_paths: otel}
  end

  test "without the SDK the otel component is unavailable", %{peer: peer} do
    assert %{"otel" => %{"sdk_present" => false}} = call(peer, Insider.Live, :capabilities, [])

    assert {:error, %{"code" => "component_unavailable", "component" => "otel"}} =
             call(peer, Insider.Live, :start, [%{"components" => ["otel"]}])
  end

  # The capture needs isolated trace sessions (OTP 28+).
  if :erlang.system_info(:otp_release) >= ~c"28" do
    test "a session captures a request's span tree and trace joins its logs and Telemetry",
         %{peer: peer} = context do
      sdk!(context)

      {id, request, trace} = captured_request(peer, 3)

      assert trace["spans"] == 3
      assert trace["unjoined"]["missing_parents"] == 0
      assert trace["scan"]["complete"]

      [root | _rest] = trace["items"]
      assert root["event"]["attributes"]["name"] == "GET /graphql"
      assert root["event"]["severity"] == "error"
      assert root["event"]["attributes"]["service"] == "my_app-test"
      assert root["depth"] == 0
      assert root["event"]["payload"]["span_attributes"]["http.route"] == "/graphql"

      assert root["event"]["payload"]["span_attributes"]["http.request.header.authorization"] ==
               "[REDACTED:credential_key]"

      by_name = Map.new(trace["items"], &{label(&1), &1})
      assert by_name["span absinthe.execute.operation"]["depth"] == 1
      assert by_name["span my_app.repo.query:users"]["depth"] == 2

      resolving = by_name["log resolving viewer"]
      assert resolving["joined_by"] == "trace_id"
      assert resolving["span_id"] == by_name["span absinthe.execute.operation"]["span_id"]

      assert by_name["telemetry my_app.repo.query"]["joined_by"] == "trace_id"
      assert by_name["log rendering response"]["joined_by"] == "pid_window"
      assert by_name["log rendering response"]["span_id"] == root["span_id"]

      # Time order: the operation's log line before the response's.
      labels = Enum.map(trace["items"], &label/1)
      assert index(labels, "log resolving viewer") < index(labels, "log rendering response")

      assert trace["text"] =~ "span GET /graphql server"
      assert trace["text"] =~ "  +"

      # Nothing from the other request.
      assert Enum.all?(
               trace["items"],
               &(&1["event"]["source"] != "otel" or
                   &1["event"]["attributes"]["trace_id"] == request["trace_id"])
             )

      assert {:ok, timeline} =
               call(peer, Insider.Live, :timeline, [id, %{"request_id" => "req-1"}])

      assert request["trace_id"] in timeline["trace_ids"]
      timeline_labels = Enum.map(timeline["items"], &label/1)
      assert "span GET /graphql" in timeline_labels
      assert "log rendering response" in timeline_labels
      assert "telemetry my_app.repo.query" in timeline_labels
      assert timeline["pids"] == [request["pid"]]

      assert {:ok, by_pid} = call(peer, Insider.Live, :timeline, [id, %{"pid" => request["pid"]}])
      assert length(by_pid["items"]) == length(timeline["items"])

      # The node's own processor exported every span during the session: three
      # per request, whichever attempt.
      exported = length(call(peer, OtelPeer, :exported, []))
      assert exported >= 6 and rem(exported, 6) == 0

      assert {:ok, %{"receipt" => %{"cleanup" => %{"components" => %{"otel" => "absent"}}}}} =
               call(peer, Insider.Live, :stop, [id])

      assert {:traced, false} ==
               call(peer, :erlang, :trace_info, [{:otel_span_utils, :end_span, 2}, :traced])

      _after = call(peer, OtelPeer, :request, ["req-3"])
      assert length(call(peer, OtelPeer, :exported, [])) == exported + 3
    end

    # On this base the Recorder drops a write that meets another at its lock
    # (`recorder_contended`); the otel, Logger, and Telemetry collectors write
    # concurrently, so a span or log line is occasionally lost, and the trace
    # reports it as a gap. Contended writers do not wait yet. Until then a
    # run whose trace reports that gap is repeated in a fresh session, at most
    # `attempts` times; any other loss fails the test.
    defp captured_request(peer, attempts) do
      assert {:ok, %{"session_id" => id, "components" => ["logger", "otel", "telemetry"]}} =
               start(peer, %{
                 "components" => ["logger", "otel", "telemetry"],
                 "telemetry_events" => [["my_app", "repo", "query"]],
                 "telemetry_min_duration_ms" => 0,
                 "logger_level" => "info"
               })

      request = call(peer, OtelPeer, :request, ["req-1"])
      _other = call(peer, OtelPeer, :request, ["req-2"])

      assert {:ok, trace} =
               call(peer, Insider.Live, :trace, [id, request["trace_id"], %{"human" => true}])

      contended? = Enum.any?(trace["gaps"], &(&1["reason"] == "recorder_contended"))

      cond do
        contended? and attempts > 1 ->
          assert {:ok, _record} = call(peer, Insider.Live, :stop, [id])
          captured_request(peer, attempts - 1)

        true ->
          assert trace["gaps"] == []
          {id, request, trace}
      end
    end

    test "spans recorded in strict carry no attributes or status message",
         %{peer: peer} = context do
      sdk!(context)

      assert {:ok, %{"session_id" => id}} =
               start(peer, %{"components" => ["otel"], "disclosure" => "strict"})

      request = call(peer, OtelPeer, :request, ["req-1"])
      assert {:ok, trace} = call(peer, Insider.Live, :trace, [id, request["trace_id"]])
      assert trace["spans"] == 3

      for item <- trace["items"] do
        assert item["event"]["payload"] == nil
        assert item["event"]["attributes"]["status_message"] == nil
      end

      assert {:ok, _record} = call(peer, Insider.Live, :stop, [id])
    end
  else
    test "on OTP 27 the otel component is refused even with the SDK", %{peer: peer} = context do
      sdk!(context)

      assert {:error, %{"code" => "component_unavailable", "reason" => "requires_otp_28"}} =
               call(peer, Insider.Live, :start, [%{"components" => ["otel"]}])
    end
  end

  defp sdk!(%{peer: peer, otel_paths: paths}) do
    Enum.each(paths, &call(peer, :code, :add_patha, [&1]))
    :ok = call(peer, OtelPeer, :start_sdk, [])
  end

  defp label(%{"event" => %{"source" => "otel", "attributes" => %{"name" => name}}}),
    do: "span " <> name

  defp label(%{"event" => %{"source" => "logger", "payload" => %{"message" => message}}}),
    do: "log " <> message

  defp label(%{"event" => %{"source" => source, "kind" => kind}}), do: source <> " " <> kind

  defp index(list, value), do: Enum.find_index(list, &(&1 == value))

  defp stop_peer(peer) do
    monitor = Process.monitor(peer)

    try do
      :peer.stop(peer)
    catch
      :exit, _reason -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^peer, _reason} -> :ok
    after
      10_000 -> flunk("the peer node did not stop")
    end
  end

  # A session start has a 1 s budget. In a peer that starts its components
  # (and, with otel, a call trace over every process) under coverage on a
  # loaded runner, the start can run past it (seen in CI with seed
  # 855702). That start reports startup "timeout" and leaves no session, so
  # it is tried again, at most 3 times. Any other result, an unclassified
  # startup failure included, is returned as it is.
  defp start(peer, options, attempts \\ 3) do
    case call(peer, Insider.Live, :start, [options]) do
      {:error,
       %{"code" => "start_failed", "receipt" => %{"cleanup" => %{"startup" => "timeout"}}}}
      when attempts > 1 ->
        start(peer, options, attempts - 1)

      result ->
        result
    end
  end

  defp call(peer, module, function, args), do: :peer.call(peer, module, function, args, 15_000)
end
