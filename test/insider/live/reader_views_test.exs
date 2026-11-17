defmodule Insider.Live.ReaderViewsTest do
  # Readers sharing the node's one session, each through its own view. One
  # collector session is global per node, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.Session.Manager
  alias Insider.Live

  @otel_skip :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  # `digest --reader sol` was refused, although every read is to be named.
  test "every read operation takes a reader, and status lists it" do
    {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

    assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "events-reader"})
    assert {:ok, %{"reader" => "digest-reader"}} = Live.digest(id, %{"reader" => "digest-reader"})
    assert {:ok, %{"reader" => "trends-reader"}} = Live.trends(id, %{"reader" => "trends-reader"})

    assert {:ok, %{"reader" => "trace-reader"}} =
             Live.trace(id, String.duplicate("a", 32), %{"reader" => "trace-reader"})

    assert {:ok, %{"reader" => "timeline-reader"}} =
             Live.timeline(id, %{"pid" => "<0.1.0>", "reader" => "timeline-reader"})

    assert {:ok, %{"readers" => readers}} = Live.status(id)

    assert Enum.map(readers, & &1["name"]) ==
             ~w(digest-reader events-reader timeline-reader trace-reader trends-reader)

    for read <- [
          fn -> Live.digest(id, %{"reader" => "bad name"}) end,
          fn -> Live.trends(id, %{"reader" => 7}) end,
          fn -> Live.trace(id, String.duplicate("a", 32), %{"reader" => ""}) end,
          fn -> Live.timeline(id, %{"pid" => "<0.1.0>", "reader" => "-x"}) end
        ],
        do: assert({:error, %{"code" => "invalid_options", "field" => "reader"}} = read.())
  end

  # A known crash loop
  # (the environment's JWKS strategy) led every digest. A reader hides it in
  # its own view; another reader, and the recording, are unchanged.
  test "a reader hides a known signature by reason fingerprint or module, in every read" do
    {:ok, %{"session_id" => id}} = start_supervised_reports()
    crash(Insider.Live.ReaderViewsTest.Jwks, :unsupported_scheme, 3)
    crash(Insider.Live.ReaderViewsTest.Pricing, :timeout, 2)

    assert {:ok, everything} = Live.digest(id, %{"since" => 0})
    assert [_, _] = everything["crash_loops"]
    jwks = Enum.find(everything["crash_loops"], &(&1["offender"] =~ "Jwks"))
    fingerprint = String.slice(jwks["reason_fingerprint"], 0, 12)

    # Each error signature carries a short id a view can name.
    assert Enum.all?(
             everything["error_signatures"],
             &Regex.match?(~r/\A[0-9a-f]{12}\z/, &1["id"])
           )

    for pattern <- [fingerprint, "Insider.Live.ReaderViewsTest.Jwks"] do
      view = %{"exclude_signatures" => [pattern]}

      assert {:ok, digest} =
               Live.digest(id, %{"since" => 0, "reader" => "sol", "view" => view, "human" => true})

      assert [%{"offender" => "Insider.Live.ReaderViewsTest.Pricing"}] = digest["crash_loops"]
      assert digest["filtered"]["view"]["exclude_signatures"] == 3
      assert digest["view"] == view
      assert digest["text"] =~ "View of reader sol hid 3 events"
      assert digest["text"] =~ "recording unchanged"

      assert {:ok, %{"events" => events}} = Live.events_since(id, 0, %{"view" => view})
      assert Enum.count(events, &(&1["event"]["kind"] == "supervisor_child_terminated")) == 2
    end

    # A signature id hides that signature only.
    pricing = Enum.find(everything["error_signatures"], &(&1["signature"] =~ "Pricing"))

    assert {:ok, digest} =
             Live.digest(id, %{"since" => 0, "view" => %{"exclude_signatures" => [pricing["id"]]}})

    assert digest["filtered"]["view"]["exclude_signatures"] == 2

    # The recording and an unnamed reader's digest are unchanged.
    assert {:ok, again} = Live.digest(id, %{"since" => 0})
    assert again["counts"] == everything["counts"]
  end

  test "a named reader's view is kept for its later reads until it changes it" do
    {:ok, %{"session_id" => id}} = start_supervised_reports()
    crash(Insider.Live.ReaderViewsTest.Jwks, :unsupported_scheme, 2)
    view = %{"exclude_signatures" => ["Insider.Live.ReaderViewsTest.Jwks"]}

    assert {:ok, %{"events" => []}} =
             Live.events_since(id, 0, %{"reader" => "sol", "view" => view})

    assert {:ok, %{"readers" => [%{"name" => "sol", "view" => ^view}]}} = Live.status(id)

    # Without a view, the reader's own view applies, to every read.
    assert {:ok, %{"events" => [], "view" => ^view}} =
             Live.events_since(id, 0, %{"reader" => "sol"})

    assert {:ok, %{"crash_loops" => [], "view" => ^view}} =
             Live.digest(id, %{"since" => 0, "reader" => "sol"})

    # Another reader is not affected.
    assert {:ok, %{"events" => [_, _]}} = Live.events_since(id, 0, %{"reader" => "claude"})

    # An empty view clears it.
    assert {:ok, %{"events" => [_, _], "view" => nil}} =
             Live.events_since(id, 0, %{"reader" => "sol", "view" => %{}})

    assert {:ok, %{"readers" => readers}} = Live.status(id)
    assert %{"view" => nil} = Enum.find(readers, &(&1["name"] == "sol"))
  end

  # A read's --view-kind silently became the reader's view and hid 1,266
  # events from the next digest.
  test "a read that sets a reader's view says so, and a later digest names the stored view first" do
    {:ok, %{"session_id" => id}} = start_supervised_reports()
    crash(Insider.Live.ReaderViewsTest.Jwks, :unsupported_scheme, 2)
    view = %{"exclude_signatures" => ["Insider.Live.ReaderViewsTest.Jwks"]}

    assert {:ok, set} = Live.events_since(id, 0, %{"reader" => "claude", "view" => view})

    assert set["view_note"] ==
             "this view is now reader claude's view for its later reads (events, digest, trace, " <>
               "timeline) until --view-clear; it hid 2 events here"

    # The same view again is no news; nor is a read without a reader.
    assert {:ok, again} = Live.events_since(id, 0, %{"reader" => "claude", "view" => view})
    refute Map.has_key?(again, "view_note")
    assert {:ok, anonymous} = Live.events_since(id, 0, %{"view" => view})
    refute Map.has_key?(anonymous, "view_note")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "reader" => "claude", "human" => true})
    [_header, note | _rest] = String.split(digest["text"], "\n")

    assert note ==
             "Note: reader claude's stored view (set by an earlier read: exclude_signatures " <>
               "Insider.Live.ReaderViewsTest.Jwks) hid 2 events from this digest; add --view-clear to read everything."

    # Clearing it says so too.
    assert {:ok, cleared} = Live.events_since(id, 0, %{"reader" => "claude", "view" => %{}})
    assert cleared["view_note"] == "reader claude's view is cleared"
  end

  test "views are validated and bounded before any read" do
    {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

    for view <- [
          %{"exclude_signatures" => ["abc"]},
          %{"exclude_signatures" => ["not a module"]},
          %{"exclude_signatures" => List.duplicate("Some.Module", 17)},
          %{"services" => [""]},
          %{"services" => List.duplicate("svc", 9)},
          %{"routes" => ["no-leading-slash"]},
          %{"routes" => ["/" <> String.duplicate("a", 200)]},
          %{"traces" => ["XYZ"]},
          %{"traces" => List.duplicate(String.duplicate("a", 32), 33)},
          %{"other" => 1}
        ] do
      assert {:error, %{"code" => "invalid_options", "field" => "view"}} =
               Live.events_since(id, 0, %{"view" => view}),
             inspect(view)
    end
  end

  describe "trace scope" do
    @describetag skip: @otel_skip

    # Each of two readers saw the
    # other's spans on the shared session. A reader scopes its view to a
    # service, a route, or its own traces: an event belongs when it names
    # the service or route itself or is part of a trace that does.
    test "services, routes, and traces keep whole traces, across services" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      mine = String.duplicate("a", 32)
      theirs = String.duplicate("b", 32)

      # A request a middleware redirected names only its path, with a query.
      redirected = String.duplicate("e", 32)

      assert {:ok, %{"accepted" => 1}} =
               Live.ingest_spans(id, [
                 %{
                   span(redirected, "9", nil, "shop-a", "/x")
                   | "attributes" => %{"http.target" => "/portfolio/7?tab=a"}
                 }
               ])

      assert {:ok, %{"events" => [%{"event" => %{"causality" => %{"trace_id" => ^redirected}}}]}} =
               Live.events_since(id, 0, %{"view" => %{"routes" => ["/portfolio"]}})

      assert {:ok, %{"events" => []}} =
               Live.events_since(id, 0, %{"view" => %{"routes" => ["/portfolio/7?tab=a"]}})

      assert {:ok, %{"accepted" => 4}} =
               Live.ingest_spans(id, [
                 span(mine, "1", nil, "shop-a", "/marketplace"),
                 span(mine, "2", "1", "Erlang/OTP", "/api/graphql"),
                 span(theirs, "3", nil, "shop-b", "/portfolio"),
                 span(theirs, "4", "3", "Erlang/OTP", "/api/graphql")
               ])

      for {view, shown} <- [
            {%{"services" => ["shop-a"]}, [mine, mine]},
            {%{"routes" => ["/marketplace"]}, [mine, mine]},
            {%{"routes" => ["/portfolio"]}, [theirs, theirs]},
            {%{"traces" => [theirs]}, [theirs, theirs]},
            # The backend's spans are in both traces, so both whole traces are kept.
            {%{"services" => ["Erlang/OTP"]}, [mine, mine, theirs, theirs]},
            {%{"services" => ["shop-a"], "traces" => [theirs]}, [mine, mine, theirs, theirs]}
          ] do
        # From after the redirected request's span.
        assert {:ok, batch} = Live.events_since(id, 1, %{"view" => view})

        assert Enum.map(batch["events"], & &1["event"]["causality"]["trace_id"]) == shown,
               inspect(view)

        assert batch["filtered"]["view"]["scope"] == 4 - length(shown)
      end

      # A reader's digest is scoped the same way.
      assert {:ok, digest} =
               Live.digest(id, %{
                 "since" => 0,
                 "reader" => "claude",
                 "view" => %{"services" => ["shop-a"]}
               })

      # The redirected request was served by shop-a too.
      assert digest["window"]["events"] == 3
      assert digest["filtered"]["view"]["scope"] == 2

      # A trace outside the reader's scope shows nothing, and says why.
      assert {:ok, trace} = Live.trace(id, theirs, %{"reader" => "claude"})
      assert trace["items"] == []
      assert trace["filtered_view"]["scope"] == 2
    end

    test "a named subscriber reads through its own view, and a scoped view follows new traces" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      mine = String.duplicate("c", 32)
      theirs = String.duplicate("d", 32)
      view = %{"routes" => ["/marketplace"]}

      assert {:ok, %{"events" => []}} =
               Live.events_since(id, 0, %{"reader" => "claude", "view" => view})

      assert {:ok, %{"subscribed" => true}} = Live.subscribe(id, self(), %{"reader" => "claude"})

      assert {:ok, %{"accepted" => 4}} =
               Live.ingest_spans(id, [
                 span(mine, "5", "6", "Erlang/OTP", "/api/graphql"),
                 span(mine, "6", nil, "shop-a", "/marketplace"),
                 span(theirs, "7", "8", "Erlang/OTP", "/api/graphql"),
                 span(theirs, "8", nil, "shop-b", "/portfolio")
               ])

      assert_receive {:insider_live_events, ^id, batch}, 3_000
      assert Enum.map(batch["events"], & &1["event"]["causality"]["trace_id"]) == [mine, mine]
      assert batch["filtered"]["view"]["scope"] == 2
      # A named subscriber's batch names its reader and view.
      assert %{"reader" => "claude", "view" => ^view} = batch
    end

    # A route learned under the rich profile kept
    # matching after the host narrowed to strict, where routes are withheld.
    test "routes resolve traces only while the effective profile is rich" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      trace = String.duplicate("f", 32)

      assert {:ok, %{"accepted" => 2}} =
               Live.ingest_spans(id, [
                 span(trace, "1", nil, "shop-a", "/private"),
                 %{span(trace, "2", "1", "Erlang/OTP", "/x") | "attributes" => %{}}
               ])

      assert {:ok, %{"events" => [_, _]}} =
               Live.events_since(id, 0, %{"view" => %{"routes" => ["/private"]}})

      Application.put_env(:insider, :live_disclosure, :strict)
      on_exit(fn -> Application.delete_env(:insider, :live_disclosure) end)

      assert {:ok, %{"events" => [], "filtered" => %{"view" => %{"scope" => 2}}}} =
               Live.events_since(id, 0, %{"view" => %{"routes" => ["/private"]}})

      # Services are disclosed in both profiles.
      assert {:ok, %{"events" => [_, _]}} =
               Live.events_since(id, 0, %{"view" => %{"services" => ["shop-a"]}})
    end

    # A secret-shaped route matched by its raw
    # value, and a view holding one was echoed and stored unmasked.
    test "secret-shaped labels are refused, and an index only holds masked values" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      trace = String.duplicate("1", 32)
      secret = "sk_live_" <> String.duplicate("aB3dE5", 4)

      assert {:ok, %{"accepted" => 1}} =
               Live.ingest_spans(id, [span(trace, "1", nil, "shop-a", "/pay/" <> secret)])

      for view <- [
            %{"routes" => ["/pay/" <> secret]},
            %{"services" => [secret]},
            %{"routes" => ["/pay"], "services" => ["svc-" <> secret]}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "view"}} =
                 Live.events_since(id, 0, %{"reader" => "sol", "view" => view})

        refute Live.JSON.events_since(id, 0, %{"reader" => "sol", "view" => view}) =~ secret
      end

      # The path prefix matches the masked route; nothing secret is stored or echoed.
      assert {:ok, %{"events" => [event]} = batch} =
               Live.events_since(id, 0, %{"reader" => "sol", "view" => %{"routes" => ["/pay"]}})

      refute Jason.encode!(batch) =~ secret
      assert Jason.encode!(event) =~ "[REDACTED:"
      assert {:ok, status} = Live.status(id)
      refute Jason.encode!(status) =~ secret
    end

    # Rejected and duplicate spans changed which
    # traces a view kept.
    test "only recorded spans add to a trace's services and routes" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      trace = String.duplicate("2", 32)
      recorded = span(trace, "1", nil, "shop-a", "/private")

      assert {:ok, %{"accepted" => 1}} = Live.ingest_spans(id, [recorded])

      assert {:ok, %{"accepted" => 0, "duplicate" => 1}} =
               Live.ingest_spans(id, [
                 put_in(recorded, ["attributes", "http.route"], "/never-recorded")
               ])

      assert {:ok, %{"accepted" => 0, "rejected" => 1}} =
               Live.ingest_spans(id, [
                 Map.delete(span(trace, "3", "1", "svc-rejected", "/r"), "name")
               ])

      for view <- [%{"routes" => ["/never-recorded"]}, %{"services" => ["svc-rejected"]}] do
        assert {:ok, %{"events" => []}} = Live.events_since(id, 0, %{"view" => view}),
               inspect(view)
      end
    end

    # Spans the node's own SDK captured did not
    # populate the index, so a route view split their traces.
    test "a route view keeps a whole SDK-captured trace" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      trace_id = 0x3333333333333333333333333333333A

      Insider.Test.OtelSpans.end_in_process(
        Insider.Test.OtelSpans.open(
          trace_id: trace_id,
          span_id: 0x11,
          attributes: %{"http.route": "/sdk-route"}
        )
      )

      Insider.Test.OtelSpans.end_in_process(
        Insider.Test.OtelSpans.open(
          trace_id: trace_id,
          span_id: 0x12,
          parent_span_id: 0x11,
          name: "child"
        )
      )

      assert {:ok, %{"events" => [_root, _child]}} = Live.events_since(id, 0)

      assert {:ok, %{"events" => [_, _], "filtered" => %{"view" => %{"scope" => 0}}}} =
               Live.events_since(id, 0, %{"view" => %{"routes" => ["/sdk-route"]}})
    end
  end

  # A failed view lookup read on with no view and
  # cleared the reader's stored one.
  test "a reader-view lookup that fails fails the read and keeps the stored view" do
    {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
    view = %{"min_severity" => "error"}
    assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "sol", "view" => view})

    owner = Process.whereis(Insider.Live.Owner)
    :ok = :sys.suspend(owner)

    try do
      assert {:error, %{"code" => "timeout"}} =
               Live.trace(id, String.duplicate("a", 32), %{"reader" => "sol"})
    after
      :sys.resume(owner)
    end

    assert {:ok, %{"readers" => [%{"name" => "sol", "view" => ^view}]}} = Live.status(id)
  end

  defp start_supervised_reports do
    Live.start(%{
      "components" => ["logger"],
      "logger_include" => [%{"domain" => ["otp", "sasl"]}]
    })
  end

  defp crash(offender, reason, times) do
    capture_log(fn ->
      for _time <- 1..times do
        :logger.error(
          %{
            label: {:supervisor, :child_terminated},
            report: [
              supervisor: {:local, :insider_reader_views_sup},
              errorContext: :child_terminated,
              reason: reason,
              offender: [pid: self(), id: offender, restart_type: :transient]
            ]
          },
          %{domain: [:otp, :sasl]}
        )
      end
    end)
  end

  defp span(trace_id, span_id, parent, service, route) do
    %{
      "trace_id" => trace_id,
      "span_id" => String.pad_leading(span_id, 16, "0"),
      "parent_span_id" => parent && String.pad_leading(parent, 16, "0"),
      "name" => "POST " <> route,
      "span_kind" => "server",
      "status" => "ok",
      "status_message" => nil,
      "service" => service,
      "scope" => "test",
      "start_time_us" => System.os_time(:microsecond),
      "duration_us" => 1_000,
      "attributes" => %{"http.route" => route},
      "pid" => nil
    }
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("expected state was not reached")
end
