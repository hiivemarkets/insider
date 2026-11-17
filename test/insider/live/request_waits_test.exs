defmodule Insider.Live.RequestWaitsTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Insider.Live

  @server [:bandit, :request, :stop]
  @handler [:phoenix, :endpoint, :stop]
  @trace "7bf92f3577b34da6a3ce929d0e0e4731"
  @ms System.convert_time_unit(1, :millisecond, :native)

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end
    end)
  end

  defp start(extra \\ %{}) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(
               Map.merge(
                 %{
                   "components" => ["telemetry"],
                   "telemetry_events" => [
                     Enum.map(@server, &to_string/1),
                     Enum.map(@handler, &to_string/1)
                   ],
                   "telemetry_min_duration_ms" => 0
                 },
                 extra
               )
             )

    id
  end

  defp conn(agent),
    do: %{
      __struct__: Plug.Conn,
      method: "POST",
      request_path: "/api/graphql",
      status: 200,
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"user-agent", agent}]
    }

  # One request in its own process: Phoenix's endpoint stop (when
  # `handler_ms`), then the web server's stop, `total_ms` after it began.
  defp request(total_ms, handler_ms, agent, trace \\ nil) do
    Task.await(
      Task.async(fn ->
        if trace, do: Logger.metadata(otel_trace_id: trace, otel_span_id: "00f067aa0ba902b7")
        conn = conn(agent)

        if handler_ms,
          do: :telemetry.execute(@handler, %{duration: handler_ms * @ms}, %{conn: conn})

        now = System.monotonic_time()

        :telemetry.execute(
          @server,
          %{monotonic_time: now, duration: total_ms * @ms, resp_start_time: now - @ms},
          %{conn: conn}
        )
      end)
    )
  end

  test "a request's wait before the endpoint is one line in the digest, the trace, and the timeline" do
    id = start()
    request(3_100, 5, "Mozilla/5.0", @trace)
    request(20, 15, "Mozilla/5.0")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})

    assert %{"requests" => 2, "with_handler" => 2, "slowest_waits" => [slowest | _]} =
             digest["requests"]

    assert slowest["wait_us"] in 3_090_000..3_095_000

    # The digest leads with it, so it is read first, not ten minutes late.
    assert [_header, "Anomalies (most important first):", wait, next | _] =
             String.split(digest["text"], "\n")

    assert wait =~
             ~r/^  1\. Pre-handler wait: 1 of 2 requests waited 100 ms or more; slowest 3\.1 s POST \/api\/graphql 200 \(Mozilla\/5\.0\) at \d\d:\d\d:\d\d, before Phoenix's endpoint telemetry/

    assert next =~ "next: mix insider.live process \"${N[@]}\" --name Phoenix.CodeReloader.Server"
    assert [%{"kind" => "pre_handler_wait"}] = digest["anomalies"]

    assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})

    assert trace["text"] =~
             ~r/\nWait: POST \/api\/graphql 200 \(Mozilla\/5\.0\) waited 3\.1 s before Phoenix's endpoint telemetry began, of 3\.1 s in all \(in dev the code reloader and the plugs before Plug\.Telemetry run there\)\.\n/

    assert trace["text"] =~
             ~r/telemetry bandit\.request\.stop 3100\.000ms info waited 3\.1 s before the endpoint/

    [pid] =
      for %{"event" => %{"kind" => "bandit.request.stop"} = event} <- trace["items"],
          do: event["subject"]["value"]

    assert {:ok, timeline} = Live.timeline(id, %{"pid" => pid, "human" => true})
    assert timeline["text"] =~ "\nWait: POST /api/graphql 200 (Mozilla/5.0) waited 3.1 s"
  end

  test "status leads with the last minute's anomalies, without renewing the lease or moving a cursor" do
    id = start()
    request(3_100, 5, "Mozilla/5.0")
    assert {:ok, %{"lease_remaining_ms" => before}} = Live.status(id)
    Process.sleep(30)

    assert {:ok, status} = Live.status(id)
    assert [%{"kind" => "pre_handler_wait", "line" => line, "command" => _}] = status["anomalies"]
    assert line =~ "slowest 3.1 s"
    assert status["anomalies_window"] == "latest-60s"
    assert status["lease_remaining_ms"] < before
  end

  # Status observes. It never ends or revokes a session.
  test "status in a denied environment neither revokes the session nor claims anomalies" do
    id = start()
    request(3_100, 5, "Mozilla/5.0")
    Application.put_env(:insider, :environment, :production)

    assert {:ok, status} = Live.status(id)
    assert status["state"] == "running"
    assert status["anomalies"] == nil
    assert status["anomalies_complete"] == false
    assert status["anomalies_note"] =~ "environment_denied"
    assert %{session: %{id: ^id, revoking: false}} = :sys.get_state(Insider.Live.Owner)

    Application.put_env(:insider, :environment, :test)
    assert {:ok, %{"state" => "running", "anomalies_complete" => true}} = Live.status(id)
  end

  test "a burst of requests from another client is flagged with its source and the waits it overlapped" do
    id = start()
    # A quiet background: one request a second for the last 14 seconds.
    for seconds <- 5..14, do: request(seconds * 1_000, nil, "Mozilla/5.0")
    # A browser request that began 3 s ago and waited behind the burst.
    request(3_000, 40, "Mozilla/5.0")
    # 70 requests from another client at once.
    for _n <- 1..70, do: request(1, nil, "sync-client/1.4")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})
    assert [burst] = digest["requests"]["bursts"]
    assert burst["requests"] >= 60
    assert [%{"source" => "user agent sync-client/1.4"} | _] = burst["sources"]
    assert burst["others_overlapping"] >= 1
    assert burst["others_max_wait_us"] in 2_950_000..2_961_000

    assert digest["text"] =~
             ~r/\nAnomalies \(most important first\):\n  1\. Request burst at \d\d:\d\d:\d\d: \d+ requests in \d s \(usually 1\/s\), \d+ from user agent sync-client\/1\.4; \d+ other requests? waited up to 3(\.0)? s\.\n/
  end

  test "under the strict profile timings and counts pass; path, user agent, and address are withheld" do
    Application.put_env(:insider, :environment, :ci)
    id = start(%{"telemetry_measurements" => ["duration"]})
    request(3_100, 5, "sync-client/1.4")

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 100})
    refute Jason.encode!(batch) =~ "sync-client"

    [server] =
      for %{"event" => %{"kind" => "bandit.request.stop"}} = entry <- batch["events"], do: entry

    request = server["event"]["attributes"]["request"]

    assert %{"role" => "server", "total_us" => 3_100_000, "method" => "POST", "status" => 200} =
             request

    refute Map.has_key?(request, "user_agent")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})
    assert digest["text"] =~ "slowest 3.1 s POST 200 at "
    assert hd(digest["anomalies"])["kind"] == "pre_handler_wait"
  end

  # Request timings follow the measurement policy.
  test "strict without the duration measurement records no timings, and says so" do
    Application.put_env(:insider, :environment, :ci)
    id = start()
    request(3_100, 5, "sync-client/1.4")

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 100})

    requests = for %{"event" => %{"attributes" => %{"request" => r}}} <- batch["events"], do: r
    assert [_, _] = requests

    for request <- requests do
      refute Map.has_key?(request, "total_us")
      refute Map.has_key?(request, "handler_us")
      assert request["timing_withheld"]
    end

    assert {:ok, %{"requests" => %{"with_handler" => 0, "timing_withheld" => 2}}} =
             Live.digest(id, %{"since" => 0})
  end

  test "timings recorded under rich are withheld when the host narrows to strict without duration" do
    id = start()
    request(3_100, 5, "sync-client/1.4")

    Application.put_env(:insider, :environment, :ci)
    Application.put_env(:insider, :live_telemetry_measurements, [])
    on_exit(fn -> Application.delete_env(:insider, :live_telemetry_measurements) end)

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 100})
    refute Jason.encode!(batch) =~ "3100000"

    [server] =
      for %{"event" => %{"kind" => "bandit.request.stop"}} = entry <- batch["events"], do: entry

    paths = Enum.map(server["redactions"], & &1["path"])
    assert ["key:attributes", "key:request", "key:total_us"] in paths

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})
    assert digest["requests"]["slowest_waits"] == []
    refute digest["text"] =~ "Pre-handler waits"
  end
end
