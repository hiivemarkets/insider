defmodule Insider.Live.ReaderViewsTest do
  # Readers sharing the node's one session, each through its own view. One
  # collector session is global per node, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.Session.Manager
  alias Insider.Live

  require Logger

  @otel_skip :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
  @warning %{"min_severity" => "warning"}
  @trace_id String.duplicate("7", 32)

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

  # A newcomer read events with --reader hunt --view-min-severity warning.
  # The view silently became hunt's, so a later trace showed one orphan
  # span and its text ended with "View of reader hunt hid 1071 events".
  # A view narrows only the read that gives it.
  test "a view given with a reader narrows only that read" do
    id = start_logged_request()

    assert {:ok, narrowed} = Live.events_since(id, 0, %{"reader" => "hunt", "view" => @warning})
    assert [%{"event" => %{"severity" => "warning"}}] = hunt_events(narrowed)
    assert narrowed["view"] == @warning
    refute Map.has_key?(narrowed, "view_note")
    refute Map.has_key?(narrowed, "stored_view")

    assert {:ok, trace} = Live.trace(id, @trace_id, %{"reader" => "hunt", "human" => true})
    assert [_, _] = trace["items"]
    assert trace["view"] == nil and trace["filtered_view"] == %{}
    refute Map.has_key?(trace, "stored_view")
    refute trace["text"] =~ "View of reader hunt"

    assert {:ok, timeline} =
             Live.timeline(id, %{"request_id" => "req-hunt", "reader" => "hunt", "human" => true})

    assert timeline["view"] == nil and timeline["filtered_view"] == %{}
    refute Map.has_key?(timeline, "stored_view")

    assert {:ok, events} = Live.events_since(id, 0, %{"reader" => "hunt"})
    assert [_, _] = hunt_events(events)
    assert events["view"] == nil
    refute Map.has_key?(events, "stored_view")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "reader" => "hunt"})
    assert digest["view"] == nil
    refute Map.has_key?(digest, "stored_view")

    assert {:ok, %{"readers" => [%{"name" => "hunt", "view" => nil}]}} = Live.status(id)
  end

  test "a view kept with view_keep applies to the reader's later reads, which say so first" do
    id = start_logged_request()

    assert {:ok, kept} =
             Live.events_since(id, 0, %{
               "reader" => "hunt",
               "view" => @warning,
               "view_keep" => true
             })

    assert [_warning] = hunt_events(kept)
    hidden = kept["filtered"]["view"]["min_severity"]

    assert kept["view_note"] ==
             "this view is now reader hunt's stored view for its later reads (events, watch, digest, trends, " <>
               "trace, timeline, changes, mutations) until --view-clear; it hid #{hidden} events here"

    assert {:ok, %{"readers" => [%{"name" => "hunt", "view" => @warning}]}} = Live.status(id)

    # The same view kept again is no news; another reader is not affected.
    assert {:ok, again} =
             Live.events_since(id, 0, %{
               "reader" => "hunt",
               "view" => @warning,
               "view_keep" => true
             })

    refute Map.has_key?(again, "view_note")
    assert {:ok, other} = Live.events_since(id, 0, %{"reader" => "sol"})
    assert [_, _] = hunt_events(other)
    refute Map.has_key?(other, "stored_view")

    # A later read without a view applies it, and says so at the top level.
    assert {:ok, events} = Live.events_since(id, 0, %{"reader" => "hunt"})
    assert [_warning] = hunt_events(events)
    assert events["view"] == @warning

    assert %{"reader" => "hunt", "view" => @warning, "hidden" => ^hidden, "note" => note} =
             events["stored_view"]

    assert note ==
             "reader hunt's stored view (min_severity warning, kept with --view-keep) hid #{hidden} " <>
               "events from this read; --view-clear clears it"

    assert {:ok, trace} = Live.trace(id, @trace_id, %{"reader" => "hunt", "human" => true})
    assert [_warning] = trace["items"]
    assert trace["stored_view"]["hidden"] >= 1
    assert hd(String.split(trace["text"], "\n")) == "Note: " <> trace["stored_view"]["note"]

    assert {:ok, timeline} =
             Live.timeline(id, %{"request_id" => "req-hunt", "reader" => "hunt", "human" => true})

    assert %{"hidden" => hidden_here} = timeline["stored_view"]
    assert hidden_here >= 1
    assert hd(String.split(timeline["text"], "\n")) =~ ~r/\ANote: reader hunt's stored view /

    for read <- [
          fn human -> Live.digest(id, %{"since" => 0, "reader" => "hunt", "human" => human}) end,
          fn human -> Live.trends(id, %{"since" => 0, "reader" => "hunt", "human" => human}) end,
          fn human -> Live.changes(id, %{"reader" => "hunt", "human" => human}) end,
          fn human -> Live.mutations(id, %{"reader" => "hunt", "human" => human}) end
        ] do
      assert {:ok, %{"stored_view" => %{"reader" => "hunt", "view" => @warning}}} = read.(false)
      assert {:ok, %{"text" => text, "stored_view" => %{"note" => note}}} = read.(true)
      assert hd(String.split(text, "\n")) == "Note: " <> note
    end

    # A view given once reads through it instead, and keeps the stored one.
    assert {:ok, once} =
             Live.events_since(id, 0, %{"reader" => "hunt", "view" => %{"sources" => ["logger"]}})

    assert [_, _] = hunt_events(once)
    refute Map.has_key?(once, "stored_view")

    assert {:ok, %{"readers" => [%{"name" => "hunt", "view" => @warning}, _sol]}} =
             Live.status(id)

    # An empty view (--view-clear) clears it, and says so.
    assert {:ok, cleared} = Live.events_since(id, 0, %{"reader" => "hunt", "view" => %{}})
    assert cleared["view_note"] == "reader hunt's stored view is cleared"
    assert [_, _] = hunt_events(cleared)
    assert {:ok, after_clear} = Live.events_since(id, 0, %{"reader" => "hunt"})
    refute Map.has_key?(after_clear, "stored_view")
  end

  test "a read through other operations keeps a view only with view_keep, and clears it" do
    id = start_logged_request()

    assert {:ok, digest} =
             Live.digest(id, %{
               "since" => 0,
               "reader" => "hunt",
               "view" => @warning,
               "human" => true
             })

    refute Map.has_key?(digest, "view_note")
    assert {:ok, %{"readers" => [%{"view" => nil}]}} = Live.status(id)

    assert {:ok, digest} =
             Live.digest(id, %{
               "since" => 0,
               "reader" => "hunt",
               "view" => @warning,
               "view_keep" => true,
               "human" => true
             })

    assert digest["view_note"] =~ "this view is now reader hunt's stored view"
    assert hd(String.split(digest["text"], "\n")) == "Note: " <> digest["view_note"]
    assert {:ok, %{"readers" => [%{"view" => @warning}]}} = Live.status(id)

    # mutations keeps and clears like every other read.
    assert {:ok, cleared} = Live.mutations(id, %{"reader" => "hunt", "view" => %{}})
    assert cleared["view_note"] == "reader hunt's stored view is cleared"
    assert {:ok, %{"readers" => [%{"view" => nil}]}} = Live.status(id)

    assert {:ok, _kept} =
             Live.mutations(id, %{"reader" => "hunt", "view" => @warning, "view_keep" => true})

    assert {:ok, %{"readers" => [%{"view" => @warning}]}} = Live.status(id)
  end

  test "view_keep needs a reader and a view" do
    {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

    for options <- [
          %{"view" => @warning, "view_keep" => true},
          %{"reader" => "hunt", "view_keep" => true},
          %{"reader" => "hunt", "view" => %{}, "view_keep" => true},
          %{"reader" => "hunt", "view" => nil, "view_keep" => true},
          %{"reader" => "hunt", "view" => @warning, "view_keep" => "yes"}
        ],
        read <- [
          &Live.events_since(id, 0, &1),
          &Live.digest(id, &1),
          &Live.trends(id, &1),
          &Live.trace(id, @trace_id, &1),
          &Live.timeline(id, Map.put(&1, "request_id", "req-hunt")),
          &Live.changes(id, &1),
          &Live.mutations(id, &1),
          &Live.baseline(id, &1),
          &Live.subscribe(id, self(), &1)
        ] do
      assert {:error, %{"code" => "invalid_options", "field" => "view_keep"}} = read.(options),
             inspect(options)
    end

    assert {:ok, %{"readers" => []}} = Live.status(id)

    # view_keep false is the default.
    assert {:ok, _batch} =
             Live.events_since(id, 0, %{
               "reader" => "hunt",
               "view" => @warning,
               "view_keep" => false
             })
  end

  test "a subscription's view narrows its pushes and is kept only with view_keep" do
    id = start_logged_request()

    assert {:ok, %{"view" => @warning} = subscription} =
             Live.subscribe(id, self(), %{"reader" => "hunt", "view" => @warning})

    refute Map.has_key?(subscription, "stored_view")
    assert_receive {:insider_live_events, ^id, batch}, 3_000
    assert [_warning] = hunt_events(batch)
    assert {:ok, %{"readers" => [%{"name" => "hunt", "view" => nil}]}} = Live.status(id)

    assert {:ok, _subscription} =
             Live.subscribe(id, self(), %{
               "reader" => "hunt",
               "view" => @warning,
               "view_keep" => true,
               "cursor" => 0
             })

    assert {:ok, %{"readers" => [%{"name" => "hunt", "view" => @warning}]}} = Live.status(id)

    # Subscribing again without a view goes on through the stored one, and says so.
    assert {:ok, %{"view" => @warning, "stored_view" => stored}} =
             Live.subscribe(id, self(), %{"reader" => "hunt", "cursor" => 0})

    assert %{"reader" => "hunt", "view" => @warning, "hidden" => nil} = stored

    assert stored["note"] =~
             "reader hunt's stored view (min_severity warning, kept with --view-keep) narrows this read"

    assert_receive {:insider_live_events, ^id,
                    %{"stored_view" => %{"reader" => "hunt"}} = pushed},
                   3_000

    assert [_warning] = hunt_events(pushed)
  end

  # A read's --view-kind silently became the reader's view and hid 1,266
  # events from the next digest.
  test "a later digest names the stored view on its first line" do
    {:ok, %{"session_id" => id}} = start_supervised_reports()
    crash(Insider.Live.ReaderViewsTest.Jwks, :unsupported_scheme, 2)
    view = %{"exclude_signatures" => ["Insider.Live.ReaderViewsTest.Jwks"]}

    assert {:ok, _kept} =
             Live.events_since(id, 0, %{"reader" => "claude", "view" => view, "view_keep" => true})

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "reader" => "claude", "human" => true})
    [note | _rest] = String.split(digest["text"], "\n")

    assert note ==
             "Note: reader claude's stored view (exclude_signatures Insider.Live.ReaderViewsTest.Jwks, " <>
               "kept with --view-keep) hid 2 events from this read; --view-clear clears it"

    assert digest["stored_view"]["hidden"] == 2
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

      # A reader's digest is scoped the same way, and keeps the view.
      assert {:ok, digest} =
               Live.digest(id, %{
                 "since" => 0,
                 "reader" => "claude",
                 "view" => %{"services" => ["shop-a"]},
                 "view_keep" => true
               })

      # The redirected request was served by shop-a too.
      assert digest["window"]["events"] == 3
      assert digest["filtered"]["view"]["scope"] == 2

      # A trace outside the reader's stored scope shows nothing, and says why.
      assert {:ok, trace} = Live.trace(id, theirs, %{"reader" => "claude"})
      assert trace["items"] == []
      assert trace["filtered_view"]["scope"] == 2
      assert trace["stored_view"]["hidden"] == 2
    end

    test "a named subscriber reads through its own view, and a scoped view follows new traces" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      mine = String.duplicate("c", 32)
      theirs = String.duplicate("d", 32)
      view = %{"routes" => ["/marketplace"]}

      assert {:ok, %{"events" => []}} =
               Live.events_since(id, 0, %{
                 "reader" => "claude",
                 "view" => view,
                 "view_keep" => true
               })

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
      # A named subscriber's batch names its reader and view, and the stored
      # view it was read through.
      assert %{"reader" => "claude", "view" => ^view} = batch
      assert %{"reader" => "claude", "view" => ^view, "hidden" => 2} = batch["stored_view"]
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

    assert {:ok, _batch} =
             Live.events_since(id, 0, %{"reader" => "sol", "view" => view, "view_keep" => true})

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

  # One request's info and warning lines, both in trace `@trace_id`.
  defp start_logged_request do
    {:ok, %{"session_id" => id}} =
      Live.start(%{"components" => ["logger"], "logger_level" => "info"})

    capture_log(fn ->
      Task.await(
        Task.async(fn ->
          Logger.metadata(request_id: "req-hunt", trace_id: @trace_id)
          Logger.info("hunt request started")
          Logger.warning("hunt request slow")
        end)
      )
    end)

    id
  end

  defp hunt_events(batch),
    do: Enum.filter(batch["events"], &(&1["event"]["causality"]["trace_id"] == @trace_id))

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
