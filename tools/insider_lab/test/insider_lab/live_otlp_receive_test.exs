defmodule Insider.Lab.LiveOtlpReceiveTest do
  # The receiver turns this VM into a hidden distributed node, as every
  # observer command does, so these tests cannot overlap with each other or
  # with the other observer tests.
  use ExUnit.Case, async: false

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Watch
  alias Insider.Lab.LivePeer

  @moduletag timeout: 120_000
  # Every case runs against a session with the otel component, which needs
  # OTP 28's isolated trace sessions.
  if :erlang.system_info(:otp_release) < ~c"28",
    do: @moduletag(skip: "the otel component requires OTP 28")

  @fixtures Path.expand("../fixtures/otlp", __DIR__)
  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-live-otlp-" <> suffix)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    cookie = :"otlp_test_#{System.unique_integer([:positive])}"

    {peer, node} =
      LivePeer.start(cookie, insider: :started, environment: :development, otel: true)

    on_exit(fn -> LivePeer.stop(peer) end)
    on_exit(fn -> assert LivePeer.observers_left(peer) == [] end)

    {:ok, peer: peer, node: node, cookie_file: LivePeer.cookie_file(directory, cookie)}
  end

  defp target(context, extra),
    do: ["--node", context.node, "--cookie-file", context.cookie_file] ++ extra

  defp start_session(context, extra \\ []) do
    {:ok, started} =
      :peer.call(context.peer, Insider.Live, :start, [
        Map.merge(%{"components" => ["logger", "otel"]}, Map.new(extra))
      ])

    started["session_id"]
  end

  # Runs `otlp-receive` in an unlinked process: each output line, decoded,
  # then as written (`{:raw, bytes}`), then `{:exit, status}`, arrives as a
  # message. With `hold: true`, writing an `export` line first reports
  # `{:holding, pid}` and blocks until that pid receives `:release`, as a
  # stalled stdout consumer would. If a test fails first, the receiver is
  # stopped the way SIGTERM stops it.
  defp start_receiver(context, session, extra \\ [], controls \\ []) do
    owner = self()
    reference = make_ref()
    hold? = Keyword.get(controls, :hold, false)

    arguments =
      ["otlp-receive" | target(context, ["--session", session, "--port", "0"] ++ extra)]

    receiver =
      spawn(fn ->
        status =
          CLI.run(arguments, fn bytes ->
            bytes = IO.iodata_to_binary(bytes)
            line = Jason.decode!(bytes)

            if hold? and line["kind"] == "export" do
              send(owner, {reference, {:holding, self()}})

              receive do
                :release -> :ok
              end
            end

            send(owner, {reference, line})
            send(owner, {reference, {:raw, bytes}})
            :ok
          end)

        send(owner, {reference, {:exit, status}})
      end)

    on_exit(fn ->
      monitor = Process.monitor(receiver)
      send(receiver, Watch.stop_message())

      receive do
        {:DOWN, ^monitor, :process, ^receiver, _reason} -> :ok
      after
        15_000 -> Process.exit(receiver, :kill)
      end
    end)

    assert_receive {^reference, %{"kind" => "listening"} = listening}, 15_000
    {receiver, reference, listening}
  end

  defp post(port, content_type, body, extra_headers \\ []) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    headers =
      Enum.map(
        [{"content-type", content_type}, {"content-length", byte_size(body)}] ++ extra_headers,
        fn {name, value} -> "#{name}: #{value}\r\n" end
      )

    :ok =
      :gen_tcp.send(socket, [
        "POST /v1/traces HTTP/1.1\r\nhost: 127.0.0.1\r\n",
        headers,
        "\r\n",
        body
      ])

    {:ok, response} = recv_all(socket, "")
    :gen_tcp.close(socket)

    [head, response_body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1", status | _reason] = head |> String.split("\r\n") |> hd() |> String.split(" ")
    {String.to_integer(status), response_body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, bytes} -> recv_all(socket, acc <> bytes)
      {:error, :closed} -> {:ok, acc}
    end
  end

  # The session's otel.span events, unwrapped from their read records.
  defp spans(peer, session) do
    {:ok, read} = :peer.call(peer, Insider.Live, :events_since, [session, 0])

    for %{"event" => %{"kind" => "otel.span"} = event} <- read["events"], do: event
  end

  test "forwards a recorded frontend export into the session as otel.span events", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)

    assert listening["schema"] == "insider.live-observer/v1"
    assert listening["operation"] == "otlp-receive"
    assert listening["target"] == context.node
    assert listening["result"]["session_id"] == session
    port = listening["port"]
    assert listening["endpoint"] == "http://127.0.0.1:#{port}/v1/traces"

    body = File.read!(Path.join(@fixtures, "next_vercel_otel_export_v1.pb"))
    assert post(port, "application/x-protobuf", body) == {200, ""}

    assert_receive {^reference, %{"kind" => "export"} = export}, 10_000
    assert %{"accepted" => 2, "rejected" => 0} = export

    # Only validated trace ids and counts leave the observer; resource
    # values such as service.name reach output only through the target.
    assert export["traces"] == [%{"trace_id" => @trace_id, "spans" => 2}]

    events = spans(context.peer, session)
    assert length(events) == 2
    assert Enum.all?(events, &(&1["source"] == "otel"))
    assert Enum.all?(events, &(&1["attributes"]["service"] == "example-marketplace"))
    assert Enum.all?(events, &(&1["attributes"]["trace_id"] == @trace_id))
    assert Enum.all?(events, &(&1["attributes"]["capture"] == "ingest"))

    root = Enum.find(events, &(&1["attributes"]["span_kind"] == "server"))
    child = Enum.find(events, &(&1["attributes"]["span_kind"] == "client"))
    assert root["attributes"]["parent_span_id"] == "00f067aa0ba902b7"
    assert child["attributes"]["parent_span_id"] == root["attributes"]["span_id"]
    assert child["attributes"]["status"] == "error"
    assert child["severity"] == "error"
    assert root["attributes"]["name"] == "GET /order-invitation/[token]"
  end

  test "forwards a JSON export", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)

    body = File.read!(Path.join(@fixtures, "next_otlp_json_export_v1.json"))
    assert post(listening["port"], "application/json", body) == {200, "{}"}

    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000
    assert [%{"attributes" => %{"span_id" => "30039b77fb13f902"}}] = spans(context.peer, session)
  end

  test "masks credentials in span attributes as the session masks backend spans", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    secret = "Bearer s3cr3t-0123456789abcdef"

    body =
      Jason.encode!(%{
        "resourceSpans" => [
          %{
            "scopeSpans" => [
              %{
                "spans" => [
                  %{
                    "traceId" => @trace_id,
                    "spanId" => "0102030405060708",
                    "name" => "GET /x",
                    "startTimeUnixNano" => "1000",
                    "endTimeUnixNano" => "2000",
                    "attributes" => [
                      %{
                        "key" => "http.request.header.authorization",
                        "value" => %{"stringValue" => secret}
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      })

    assert {200, _body} = post(listening["port"], "application/json", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000

    [event] = spans(context.peer, session)
    refute Jason.encode!(event) =~ "s3cr3t"
  end

  test "partially rejects spans outside the contract and says so", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)

    body =
      Jason.encode!(%{
        "resourceSpans" => [
          %{
            "scopeSpans" => [
              %{
                "spans" => [
                  %{"traceId" => @trace_id, "spanId" => "0102030405060708", "name" => "ok"},
                  %{"traceId" => String.duplicate("0", 32), "spanId" => "0102030405060709"}
                ]
              }
            ]
          }
        ]
      })

    assert {200, response} = post(listening["port"], "application/json", body)
    assert %{"partialSuccess" => %{"rejectedSpans" => 1}} = Jason.decode!(response)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1, "rejected" => 1}}, 10_000
  end

  test "refuses a malformed request, reports it, and keeps receiving", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)

    assert post(listening["port"], "text/plain", "hello") == {415, "unsupported_media_type"}
    assert_receive {^reference, %{"kind" => "refused", "status" => 415}}, 10_000

    assert post(listening["port"], "application/x-protobuf", <<0xFF>>) == {400, "truncated"}

    assert_receive {^reference, %{"kind" => "refused", "status" => 400, "reason" => "truncated"}},
                   10_000

    assert post(listening["port"], "application/json", "{}") == {200, "{}"}
    assert_receive {^reference, %{"kind" => "export", "accepted" => 0}}, 10_000
  end

  test "stops cleanly when interrupted: reports totals and frees the port", context do
    session = start_session(context)
    {receiver, reference, listening} = start_receiver(context, session)
    body = File.read!(Path.join(@fixtures, "next_vercel_otel_export_v1.pb"))
    assert {200, _body} = post(listening["port"], "application/x-protobuf", body)
    assert_receive {^reference, %{"kind" => "export"}}, 10_000

    send(receiver, Watch.stop_message())

    assert_receive {^reference, %{"kind" => "stopped", "reason" => "interrupted"} = stopped},
                   15_000

    assert %{"exports" => 1, "accepted" => 2, "rejected" => 0, "refused" => 0} = stopped
    assert_receive {^reference, {:exit, 0}}, 1_000

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, listening["port"], [:binary], 1_000)

    # The session is untouched.
    assert {:ok, %{"state" => "running"}} =
             :peer.call(context.peer, Insider.Live, :status, [session])
  end

  test "ends with the session, keeping a short lease alive until then", context do
    session = start_session(context, [{"lease_ms", 1_000}])
    {_receiver, reference, _listening} = start_receiver(context, session)

    # Three lease lengths later the session runs only because the receiver
    # renewed it.
    Process.sleep(3_000)

    assert {:ok, %{"state" => "running"}} =
             :peer.call(context.peer, Insider.Live, :status, [session])

    {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])

    assert_receive {^reference, %{"kind" => "stopped", "reason" => "session_ended"} = stopped},
                   15_000

    assert stopped["state"] == "stopped"
    assert_receive {^reference, {:exit, 0}}, 1_000
  end

  test "--for ends at the deadline", context do
    session = start_session(context)
    {_receiver, reference, _listening} = start_receiver(context, session, ["--for", "300ms"])

    assert_receive {^reference, %{"kind" => "stopped", "reason" => "duration", "exports" => 0}},
                   15_000

    assert_receive {^reference, {:exit, 0}}, 1_000
  end

  test "a session without the otel component is refused before listening", context do
    {:ok, started} =
      :peer.call(context.peer, Insider.Live, :start, [%{"components" => ["logger"]}])

    session = started["session_id"]

    {status, [document]} =
      run(["otlp-receive" | target(context, ["--session", session, "--port", "0"])])

    assert status == 1
    assert document["error"]["source"] == "target"
    assert %{"code" => "component_unavailable", "component" => "otel"} = document["error"]
    assert document["error"]["reason"] == "component_not_running"
  end

  test "an unknown session is refused before listening", context do
    {1, [document]} =
      run(["otlp-receive" | target(context, ["--session", "live-999", "--port", "0"])])

    assert document["error"]["code"] == "unknown_session"
  end

  test "a port in use is reported", context do
    session = start_session(context)
    {:ok, busy} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(busy)

    {1, [document]} =
      run([
        "otlp-receive"
        | target(context, ["--session", session, "--port", Integer.to_string(port)])
      ])

    assert document["error"]["code"] == "port_unavailable"
    :gen_tcp.close(busy)
  end

  test "listens on the IPv6 loopback with --bind ::1", context do
    session = start_session(context)
    {_receiver, _reference, listening} = start_receiver(context, session, ["--bind", "::1"])
    assert listening["endpoint"] == "http://[::1]:#{listening["port"]}/v1/traces"
  end

  defp json_export(resource_attributes, span) do
    Jason.encode!(%{
      "resourceSpans" => [
        %{
          "resource" => %{"attributes" => resource_attributes},
          "scopeSpans" => [
            %{
              "spans" => [
                Map.merge(
                  %{
                    "traceId" => @trace_id,
                    "spanId" => "0102030405060708",
                    "name" => "GET /x",
                    "startTimeUnixNano" => "1000",
                    "endTimeUnixNano" => "2000"
                  },
                  span
                )
              ]
            }
          ]
        }
      ]
    })
  end

  # The export line copied service.name from the request, past
  # the target's credential masking.
  test "no export line carries a value from the request that the target did not mask",
       context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    service = "https://user:probe-password@localhost"

    body =
      json_export([%{"key" => "service.name", "value" => %{"stringValue" => service}}], %{})

    assert {200, _body} = post(listening["port"], "application/json", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000
    assert_receive {^reference, {:raw, line}}, 1_000

    refute line =~ "probe-password"
    [event] = spans(context.peer, session)
    refute Jason.encode!(event) =~ "probe-password"
  end

  # A 401-digit doubleValue killed the receiver.
  test "refuses an out-of-range number and keeps receiving", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    huge = String.to_integer("1" <> String.duplicate("0", 400))

    body =
      json_export([], %{
        "attributes" => [%{"key" => "d", "value" => %{"doubleValue" => huge}}]
      })

    assert post(listening["port"], "application/json", body) == {400, "malformed_request"}

    assert_receive {^reference,
                    %{"kind" => "refused", "status" => 400, "reason" => "malformed_request"}},
                   10_000

    assert {200, _body} = post(listening["port"], "application/json", json_export([], %{}))
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000
  end

  # With stdout blocked, 64 more requests were answered and 64
  # reports queued in the receiver's mailbox.
  test "a blocked output holds back further requests instead of queueing reports", context do
    session = start_session(context)
    {receiver, reference, listening} = start_receiver(context, session, [], hold: true)
    body = json_export([], %{})
    first = Task.async(fn -> post(listening["port"], "application/json", body) end)
    assert_receive {^reference, {:holding, writer}}, 10_000
    assert Task.await(first) == {200, "{}"}

    pending =
      for _index <- 1..4,
          do: Task.async(fn -> post(listening["port"], "application/json", body) end)

    # While the first report is being written nothing more is accepted:
    # the others wait unanswered, and no report waits in the mailbox.
    assert Enum.all?(pending, &(Task.yield(&1, 300) == nil))
    assert {:message_queue_len, 0} = Process.info(receiver, :message_queue_len)

    send(writer, :release)

    for _index <- 1..4 do
      assert_receive {^reference, {:holding, writer}}, 10_000
      send(writer, :release)
    end

    assert Enum.map(pending, &Task.await(&1, 15_000)) == List.duplicate({200, "{}"}, 4)

    send(receiver, Watch.stop_message())
    assert_receive {^reference, %{"kind" => "stopped", "exports" => 5}}, 15_000
    assert_receive {^reference, {:exit, 0}}, 1_000
  end

  # A stop and a start between ingest calls put spans into the
  # next session. The receiver is bound to its session id: after that
  # session ends, the next session never receives its spans.
  test "after its session ends, a new session never receives its spans", context do
    session = start_session(context)
    before = lease_deadline(context.peer)
    {_receiver, reference, listening} = start_receiver(context, session)

    # The receiver renews once at start; stop only after that renewal, so
    # the session's end reaches the receiver through an export, not a
    # renewal. The owner's monotonic lease deadline moves only on renewal
    # (`status/1`'s lease_expires_at is rebuilt from wall time on each call).
    await(fn -> lease_deadline(context.peer) > before end)

    {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])
    next = start_session(context)

    assert {200, response} = post(listening["port"], "application/json", json_export([], %{}))
    assert %{"partialSuccess" => %{"rejectedSpans" => 1}} = Jason.decode!(response)

    assert_receive {^reference, %{"kind" => "stopped", "reason" => "session_ended"}}, 15_000
    assert spans(context.peer, next) == []
  end

  # A `timeout` is outcome unknown; ingest is idempotent, so the
  # exporter's own retry of an export never duplicates.
  test "an export sent twice is recorded once, the second counted as duplicates", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    body = File.read!(Path.join(@fixtures, "next_vercel_otel_export_v1.pb"))

    assert {200, ""} = post(listening["port"], "application/x-protobuf", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 2, "duplicate" => 0}}, 10_000
    assert {200, ""} = post(listening["port"], "application/x-protobuf", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 0, "duplicate" => 2}}, 10_000

    assert length(spans(context.peer, session)) == 2
  end

  # With the target's collector held, ingest times out (outcome
  # unknown). The receiver retries once, then answers 503 so the exporter
  # retries later, reports it, and keeps receiving.
  test "a timeout is retried once, then reported, and the receiver keeps running", context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    body = json_export([], %{})
    :ok = :peer.call(context.peer, :sys, :suspend, [Insider.Collector.Otel])

    assert post(listening["port"], "application/json", body) == {503, "target_timeout"}

    assert_receive {^reference,
                    %{"kind" => "refused", "status" => 503, "reason" => "target_timeout"}},
                   1_000

    :ok = :peer.call(context.peer, :sys, :resume, [Insider.Collector.Otel])

    # Both held calls reached the collector after their deadline and were
    # refused; the exporter's retry is recorded once.
    assert {200, _body} = post(listening["port"], "application/json", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000
    assert [_one] = spans(context.peer, session)
  end

  # A `busy` ingest (the owner's admission
  # slots full) was a terminal target error: 200 with every span rejected,
  # and the receiver stopped. It is transient: the receiver answers 503 so
  # the exporter retries, reports the refusal, and keeps receiving; the
  # exporter's retry after capacity recovers is recorded.
  test "a busy owner refuses an export with 503, and the retry after recovery is recorded",
       context do
    session = start_session(context)
    {_receiver, reference, listening} = start_receiver(context, session)
    body = json_export([], %{})

    {:ok, admission} =
      :peer.call(context.peer, Insider.Live.Owner, :admission, [owner_pid(context.peer)])

    held = hold_admission(context.peer, admission)

    assert post(listening["port"], "application/json", body) == {503, "target_busy"}

    assert_receive {^reference,
                    %{"kind" => "refused", "status" => 503, "reason" => "target_busy"}},
                   5_000

    refute_received {^reference, %{"kind" => "target_error"}}
    release_admission(context.peer, admission, held)

    assert {200, _body} = post(listening["port"], "application/json", body)
    assert_receive {^reference, %{"kind" => "export", "accepted" => 1}}, 10_000
    assert [_one] = spans(context.peer, session)

    assert {:ok, %{"state" => "running"}} =
             :peer.call(context.peer, Insider.Live, :status, [session])
  end

  # A `busy` renewal was retried at once, forever: 2,333 renewal
  # calls in 250 ms against a saturated owner. A failed renewal is retried
  # once, after a jittered backoff, then waits for the next scheduled one;
  # the receiver recovers once the owner has capacity again.
  test "a saturated owner gets a bounded number of renewals, and the lease recovers", context do
    session = start_session(context, [{"lease_ms", 6_000}])
    {_receiver, reference, _listening} = start_receiver(context, session)
    # The receiver renews at once on start; count only later renewals.
    before = lease_deadline(context.peer)
    await(fn -> lease_deadline(context.peer) > before end)

    1 =
      :peer.call(context.peer, :erlang, :trace_pattern, [
        {Insider.Live, :renew, 1},
        true,
        [:call_count]
      ])

    {:ok, admission} =
      :peer.call(context.peer, Insider.Live.Owner, :admission, [owner_pid(context.peer)])

    held = hold_admission(context.peer, admission)

    # Renewals run every 2 s; across 3 s of saturation the receiver makes
    # one scheduled renewal and one retry, never a storm.
    Process.sleep(3_000)

    {:call_count, attempts} =
      :peer.call(context.peer, :erlang, :trace_info, [{Insider.Live, :renew, 1}, :call_count])

    assert attempts in 1..3, "#{attempts} renewal calls during saturation"

    release_admission(context.peer, admission, held)

    # Past the lease the receiver started with, the session still runs:
    # a later renewal succeeded.
    Process.sleep(4_000)

    assert {:ok, %{"state" => "running"}} =
             :peer.call(context.peer, Insider.Live, :status, [session])

    refute_received {^reference, %{"kind" => "stopped"}}

    :peer.call(context.peer, :erlang, :trace_pattern, [
      {Insider.Live, :renew, 1},
      false,
      [:call_count]
    ])
  end

  # The owner was held until 174 ms before lease expiry; the
  # renewal queued meanwhile timed out, and the retry's 500-1,000 ms backoff
  # landed after expiry, though a fresh renewal would have succeeded. The
  # retry is now capped to land before the receiver's own conservative
  # estimate of the lease deadline.
  test "a renewal that times out near the lease boundary is retried before the lease expires",
       context do
    session = start_session(context, [{"lease_ms", 6_000}])
    {_receiver, reference, _listening} = start_receiver(context, session)
    before = lease_deadline(context.peer)
    await(fn -> lease_deadline(context.peer) > before end)
    renewed = lease_deadline(context.peer)

    owner = owner_pid(context.peer)
    :ok = :peer.call(context.peer, :sys, :suspend, [owner])

    # Restore the owner 174 ms before the lease it holds would expire, on
    # the peer's own monotonic clock.
    remaining = renewed - :peer.call(context.peer, :erlang, :monotonic_time, [:millisecond])
    Process.sleep(max(remaining - 174, 0))
    :ok = :peer.call(context.peer, :sys, :resume, [owner])

    # Past the original deadline, the session runs: the capped retry renewed it.
    Process.sleep(1_000)

    assert {:ok, %{"state" => "running"}} =
             :peer.call(context.peer, Insider.Live, :status, [session])

    assert lease_deadline(context.peer) > renewed
    refute_received {^reference, %{"kind" => "stopped"}}
  end

  defp owner_pid(peer), do: :peer.call(peer, Process, :whereis, [Insider.Live.Owner])

  # Takes every owner admission slot on the peer, as concurrent callers
  # would, so every admitted call is refused as `busy`.
  defp hold_admission(peer, admission) do
    limit = :peer.call(peer, Insider.Live.Owner, :admitted_calls_max, [])

    for _slot <- 1..limit do
      :ok = :peer.call(peer, Insider.Collector.Admission, :acquire, [admission, limit])
    end

    limit
  end

  defp release_admission(peer, admission, held) do
    for _slot <- 1..held,
        do: :ok = :peer.call(peer, Insider.Collector.Admission, :release, [admission])
  end

  defp lease_deadline(peer),
    do: :peer.call(peer, :sys, :get_state, [Insider.Live.Owner]).session.lease_deadline

  defp await(predicate, attempts \\ 250) do
    cond do
      predicate.() -> :ok
      attempts == 0 -> flunk("expected state was not reached")
      true -> Process.sleep(20) && await(predicate, attempts - 1)
    end
  end

  defp run(arguments) do
    owner = self()
    reference = make_ref()

    status =
      CLI.run(arguments, fn bytes ->
        send(owner, {reference, bytes |> IO.iodata_to_binary() |> Jason.decode!()})
        :ok
      end)

    {status, collect(reference, [])}
  end

  defp collect(reference, documents) do
    receive do
      {^reference, document} -> collect(reference, [document | documents])
    after
      0 -> Enum.reverse(documents)
    end
  end
end
