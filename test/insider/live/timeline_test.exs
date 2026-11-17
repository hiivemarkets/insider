defmodule Insider.Live.TimelineTest do
  # The live session and the span capture are one per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Live
  alias Insider.Live.Timeline
  alias Insider.Test.OtelSpans

  @tick [:insider_timeline, :tick]
  @trace 0x4BF92F3577B34DA6A3CE929D0E0E4736
  @trace_hex "4bf92f3577b34da6a3ce929d0e0e4736"
  @root 0x00F067AA0BA902B7
  @root_hex "00f067aa0ba902b7"
  @child 0x00000000000000C1

  describe "in this node" do
    setup do
      on_exit(fn ->
        case Live.capabilities()["active_session_id"] do
          nil -> :ok
          id -> Live.stop(id)
        end
      end)
    end

    # Spans need the otel capture (OTP 28+); without it a trace still joins
    # the Logger and Telemetry events of the same trace id.
    if :erlang.system_info(:otp_release) >= ~c"28" do
      test "trace and timeline join a request's spans, logs, and Telemetry" do
        {id, request, trace} = traced_request(3)

        assert trace["schema"] == "insider.live-trace/v1"
        assert trace["spans"] == 2, inspect(trace, pretty: true)
        assert trace["root_span_ids"] == [@root_hex]

        by_label = Map.new(trace["items"], &{label(&1), &1})
        assert by_label["span GET /graphql"]["depth"] == 0
        assert by_label["span repo.query"]["depth"] == 1
        assert by_label["log in trace"]["joined_by"] == "trace_id"
        assert by_label["log in trace"]["span_id"] == @root_hex
        assert by_label["telemetry insider_timeline.tick"]["joined_by"] == "trace_id"

        assert by_label["log after context"]["joined_by"] == "pid_window",
               join_diagnostics(id, trace, "after context")

        assert trace["text"] =~ "trace #{@trace_hex}: 2 spans"
        assert trace["scan"]["complete"]

        assert {:ok, by_pid} = Live.timeline(id, %{"pid" => request.pid, "human" => true})
        assert by_pid["subject"] == %{"pid" => request.pid}
        assert by_pid["trace_ids"] == [@trace_hex]
        assert by_pid["text"] =~ "pid #{request.pid}"
        assert length(by_pid["items"]) == length(trace["items"])

        assert {:ok, by_request} = Live.timeline(id, %{"request_id" => "req-9"})
        assert by_request["seeds"] >= 1
        assert by_request["window"]["slack_us"] == Timeline.slack_us()
        assert "span GET /graphql" in Enum.map(by_request["items"], &label/1)

        assert {:ok, other} = Live.timeline(id, %{"request_id" => "no-such-request"})
        assert other["items"] == []
        assert other["window"] == nil

        assert %{"ok" => %{"spans" => 2}} = Jason.decode!(Live.JSON.trace(id, @trace_hex))

        assert %{"ok" => %{"items" => [_ | _]}} =
                 Jason.decode!(Live.JSON.timeline(id, %{"pid" => request.pid}))
      end
    else
      test "without spans, trace joins the Logger and Telemetry events of one trace id" do
        assert {:ok, %{"session_id" => id}} =
                 Live.start(%{
                   "components" => ["logger", "telemetry"],
                   "telemetry_events" => [Enum.map(@tick, &Atom.to_string/1)],
                   "telemetry_min_duration_ms" => 0,
                   "logger_level" => "info"
                 })

        task =
          Task.async(fn ->
            Logger.metadata(
              request_id: "req-9",
              otel_trace_id: @trace_hex,
              otel_span_id: @root_hex
            )

            Logger.warning("in trace")
            :telemetry.execute(@tick, %{duration: 1}, %{})
            self() |> :erlang.pid_to_list() |> to_string()
          end)

        pid = Task.await(task)
        assert {:ok, trace} = Live.trace(id, @trace_hex, %{"human" => true})
        assert trace["spans"] == 0

        if trace["gaps"] == [] do
          labels = Enum.map(trace["items"], &label/1)
          assert "log in trace" in labels
          assert "telemetry insider_timeline.tick" in labels
          assert Enum.all?(trace["items"], &(&1["joined_by"] == "trace_id"))
        end

        assert {:ok, by_pid} = Live.timeline(id, %{"pid" => pid, "human" => true})
        assert by_pid["trace_ids"] == [@trace_hex]
        assert {:ok, by_request} = Live.timeline(id, %{"request_id" => "req-9"})
        assert by_request["seeds"] >= 1
      end
    end

    test "trace and timeline refuse bad arguments and unknown sessions" do
      assert {:error, %{"code" => "invalid_options", "field" => "trace_id"}} =
               Live.trace("live-none", "nope")

      assert {:error, %{"code" => "invalid_options", "field" => "pid"}} =
               Live.timeline("live-none", %{})

      for bad <- [
            "sql",
            [""],
            ["has space"],
            List.duplicate("sql", 9),
            [String.duplicate("a", 65)]
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "collapse"}} =
                 Live.trace("live-none", @trace_hex, %{"collapse" => bad})
      end

      assert {:error, %{"code" => "invalid_options", "field" => "hide"}} =
               Live.trace("live-none", @trace_hex, %{"hide" => [1]})

      assert {:error, %{"code" => "unknown_session"}} = Live.trace("live-none", @trace_hex)

      assert {:error, %{"code" => "unknown_session"}} =
               Live.timeline("live-none", %{"pid" => "<0.1.0>"})
    end
  end

  describe "joining" do
    test "reports missing parents, events without time, and truncation" do
      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 4, [
            entry(1, span_event("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", 1_000, 500, "<0.5.0>")),
            entry(2, span_event("cccccccccccccccc", "aaaaaaaaaaaaaaaa", 1_100, 100, "<0.5.0>")),
            entry(3, log_event(nil, "<0.5.0>", 1_150)),
            entry(4, log_event(@trace_hex, nil, nil))
          ])
        )

      result = Timeline.trace(scan, options(%{human: true}))
      assert result["spans"] == 2
      assert result["root_span_ids"] == ["aaaaaaaaaaaaaaaa"]
      assert result["unjoined"]["missing_parent_span_ids"] == ["bbbbbbbbbbbbbbbb"]
      assert result["unjoined"]["events_without_time"] == 1
      assert result["text"] =~ "1 missing parent spans"
      # The window event sits under the shorter covering span.
      assert Enum.find(result["items"], &(&1["joined_by"] == "pid_window"))["span_id"] ==
               "cccccccccccccccc"

      # The untimed event is listed last.
      assert List.last(result["items"])["at"] == nil

      cut = Timeline.trace(scan, options(%{limit: 2}))
      assert [_first, _second] = cut["items"]
      assert cut["truncated_by"] == "limit"
      assert cut["omitted_items"] == 2

      small = Timeline.trace(scan, options(%{max_bytes: 1_024}))
      assert small["truncated_by"] == "max_bytes"
      assert [_first | _rest] = small["items"]

      assert Timeline.trace(scan, options(%{ending: "deadline"}))["scan"]["ended_by"] ==
               "deadline"
    end

    test "receipt-range losses add up; cumulative totals keep the largest; deltas are unknown" do
      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(900, 1_000, [], [
            %{"reason" => "evicted", "count" => 1, "scope" => "receipt_range"},
            %{"reason" => "otel_shed", "count" => 6, "scope" => "since_session_start"},
            %{"reason" => "logger_shed", "count" => 2, "scope" => "since_session_start"}
          ])
        )
        |> Timeline.add(
          batch(800, 900, [], [
            %{"reason" => "evicted", "count" => 2, "scope" => "receipt_range"},
            %{"reason" => "otel_shed", "count" => 7, "scope" => "since_session_start"},
            %{"reason" => "otel_accounting_unavailable", "count" => nil, "scope" => "unknown"},
            # A delta against some reader's baseline is not a total: the
            # scan cannot know the total, so it says so.
            %{"reason" => "logger_shed", "count" => 1, "scope" => "since_cursor_issued"}
          ])
        )

      assert Timeline.trace(scan, options())["gaps"] == [
               %{"reason" => "evicted", "scope" => "receipt_range", "count" => 3},
               %{"reason" => "logger_shed", "scope" => "since_session_start", "count" => nil},
               %{"reason" => "otel_accounting_unavailable", "scope" => "unknown", "count" => nil},
               %{"reason" => "otel_shed", "scope" => "since_session_start", "count" => 7}
             ]
    end

    test "rendered header text matches only the complete request id" do
      headers = [
        ~s|{"x-request-id", "req-123"}|,
        ~s|{"x-forwarded-for", "x-request-id req-12"}|,
        ~s|{"x-request-id-original", "req-1"}|
      ]

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 1, [
            entry(
              1,
              telemetry_event("<0.7.0>", 20_000, %{"conn" => %{"resp_headers" => headers}})
            )
          ])
        )

      assert Timeline.timeline(scan, options(%{request_id: "req-123"}))["seeds"] == 1

      # The same through the rich renderer a live session uses.
      rendered =
        Insider.Collector.Rich.telemetry_payload(%{
          conn: %{resp_headers: [{"x-request-id", "req-123"}, {"x-other", "x-request-id req-12"}]}
        })

      rendered_scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 1, [
            entry(1, Map.put(telemetry_event("<0.7.0>", 20_000, %{}), "payload", rendered))
          ])
        )

      assert Timeline.timeline(rendered_scan, options(%{request_id: "req-123"}))["seeds"] == 1
      assert Timeline.timeline(rendered_scan, options(%{request_id: "req-12"}))["seeds"] == 0
      assert Timeline.timeline(rendered_scan, options(%{request_id: "req-1"}))["seeds"] == 0

      for request_id <- ["req-12", "req-1", "req", "unrelated"] do
        assert Timeline.timeline(scan, options(%{request_id: request_id}))["seeds"] == 0,
               request_id
      end
    end

    test "a request is found by its x-request-id header and spans its duration window" do
      native = System.convert_time_unit(10, :millisecond, :native)

      stop =
        telemetry_event("<0.7.0>", 20_000, %{
          "duration" => native,
          "conn" => %{"resp_headers" => [["x-request-id", "r-1"]]}
        })

      inspected =
        telemetry_event("<0.8.0>", 30_000, %{
          "conn" => %{"req_headers" => [~s|{"x-request-id", "r-2"}|]}
        })

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 4, [
            entry(1, log_event(nil, "<0.7.0>", 12_000)),
            entry(2, stop),
            entry(3, log_event(nil, "<0.7.0>", 40_000)),
            entry(4, inspected)
          ])
        )

      result = Timeline.timeline(scan, options(%{request_id: "r-1", human: true}))
      assert result["seeds"] == 1
      assert Enum.map(result["items"], & &1["joined_by"]) == ["pid_window", "request_id"]
      assert result["text"] =~ "telemetry phoenix.endpoint.stop 10.000ms"

      assert Timeline.timeline(scan, options(%{request_id: "r-2"}))["seeds"] == 1

      # Only the exact id of the exact header matches: never a prefix, a
      # substring, or another header that mentions x-request-id.
      for request_id <- ["r", "r-", "-1", "x-request-id"] do
        result = Timeline.timeline(scan, options(%{request_id: request_id}))
        assert result["seeds"] == 0, request_id
        assert result["items"] == [], request_id
      end

      assert Timeline.timeline(scan, options(%{pid: "<0.7.0>"}))["pids"] == ["<0.7.0>"]
    end

    test "an unknown gap count stays unknown however many reads report it" do
      unknown = %{"reason" => "otel_accounting_unavailable", "count" => nil, "scope" => "unknown"}

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(batch(0, 1, [], [unknown]))
        |> Timeline.add(batch(1, 2, [], [unknown]))

      assert Timeline.trace(scan, options())["gaps"] == [
               %{"reason" => "otel_accounting_unavailable", "scope" => "unknown", "count" => nil}
             ]
    end

    test "an event joins a span by its process only up to the span's end plus the slack" do
      slack = Timeline.slack_us()
      assert slack == 1_000

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 4, [
            entry(1, span_event("aaaaaaaaaaaaaaaa", nil, 10_000, 1_000, "<0.5.0>")),
            entry(2, log_event(nil, "<0.5.0>", 11_000 + slack)),
            entry(3, log_event(nil, "<0.5.0>", 11_000 + slack + 1)),
            entry(4, log_event("ffffffffffffffffffffffffffffffff", "<0.5.0>", 10_500))
          ])
        )

      result = Timeline.trace(scan, options())
      assert result["joined"] == %{"trace_id" => 0, "pid_window" => 1}
      assert Enum.map(result["items"], & &1["receipt"]) == [1, 2]
    end

    test "a trace event keeps its own span, else the one enclosing it in its process and time" do
      traced = fn receipt, span_id, pid, at_us ->
        entry(
          receipt,
          Map.put(log_event(@trace_hex, pid, at_us), "causality", %{
            "trace_id" => @trace_hex,
            "span_id" => span_id
          })
        )
      end

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 5, [
            entry(1, span_event("aaaaaaaaaaaaaaaa", nil, 10_000, 1_000, "<0.5.0>")),
            traced.(2, "aaaaaaaaaaaaaaaa", nil, 10_500),
            traced.(3, "0000000000000bad", nil, 10_500),
            traced.(4, "0000000000000bad", "<0.5.0>", nil),
            traced.(5, "0000000000000bad", "<0.5.0>", 10_600)
          ])
        )

      spans = Map.new(Timeline.trace(scan, options())["items"], &{&1["receipt"], &1["span_id"]})

      assert spans == %{
               1 => "aaaaaaaaaaaaaaaa",
               2 => "aaaaaaaaaaaaaaaa",
               3 => nil,
               4 => nil,
               5 => "aaaaaaaaaaaaaaaa"
             }
    end

    test "a cycle of parent spans is bounded and has no root" do
      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 2, [
            entry(1, span_event("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", 1_000, 10, "<0.5.0>")),
            entry(2, span_event("bbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa", 1_000, 10, "<0.5.0>"))
          ])
        )

      result = Timeline.trace(scan, options(%{human: true}))
      assert result["root_span_ids"] == []
      assert result["unjoined"]["missing_parents"] == 0
      assert Enum.map(result["items"], & &1["depth"]) == [64, 64]
      assert result["text"] =~ "trace #{@trace_hex}: 2 spans, 2 items\n"
    end

    test "a request's window spans its seeds' spans; unreadable metadata and header tuples never match" do
      request = %{"metadata" => %{"request_id" => "r-9"}}

      seed_span =
        "aaaaaaaaaaaaaaaa"
        |> span_event(nil, 50_000, 2_000, "<0.5.0>")
        |> Map.put("payload", request)

      untimed_seed = Map.put(log_event(nil, "<0.6.0>", nil), "payload", request)

      unrelated = fn payload -> Map.put(log_event(nil, "<0.9.0>", 51_000), "payload", payload) end

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 7, [
            entry(1, seed_span),
            entry(2, untimed_seed),
            entry(3, log_event(nil, "<0.5.0>", 52_500)),
            entry(4, log_event(nil, "<0.6.0>", 51_000)),
            entry(5, unrelated.("a rendered payload")),
            entry(
              6,
              unrelated.(%{
                "metadata" => %{"conn" => %{"req_headers" => [{"x-request-id", "r-9"}]}}
              })
            ),
            entry(7, log_event(nil, "<0.5.0>", 53_001))
          ])
        )

      result = Timeline.timeline(scan, options(%{request_id: "r-9"}))
      assert result["seeds"] == 2

      assert result["window"] == %{
               "from" => iso(50_000),
               "to" => iso(52_000),
               "slack_us" => 1_000
             }

      assert Enum.map(result["items"], &{&1["receipt"], &1["joined_by"]}) == [
               {1, "request_id"},
               {4, "pid_window"},
               {3, "pid_window"},
               {2, "request_id"}
             ]

      assert result["pids"] == ["<0.5.0>", "<0.6.0>"]
      assert result["trace_ids"] == [@trace_hex]
    end

    test "trace text is a tree with outcomes; collapse folds SQL runs and hide drops auth, counted" do
      pid = "<0.5.0>"
      named = fn event, name -> put_in(event, ["attributes", "name"], name) end

      outcome = %{
        "operation_type" => "mutation",
        "operation_name" => "placeBuyOrder",
        "result" => "user_errors",
        "user_error_count" => 1,
        "user_error_fields" => ["unitPrice"]
      }

      root = named.(span_event("1000000000000000", nil, 1_000, 10_000, pid), "POST /graphql")

      mutation =
        "2000000000000000"
        |> span_event("1000000000000000", 2_000, 5_000, pid)
        |> named.("mutation placeBuyOrder")
        |> put_in(["attributes", "graphql"], outcome)
        |> Map.put("severity", "warning")

      auth =
        "3000000000000000"
        |> span_event("2000000000000000", 2_100, 50, pid)
        |> named.("my_app.authorization.decision")

      # A query under the hidden authorization span moves up to the mutation.
      under_auth =
        "3100000000000000"
        |> span_event("3000000000000000", 2_110, 10, pid)
        |> named.("my_app.repo.query:permissions")

      queries =
        for {n, table} <- [{4, "users"}, {5, "users"}, {6, "bids"}] do
          "#{n}000000000000000"
          |> span_event("2000000000000000", 2_200 + n * 100, 100, pid)
          |> named.("my_app.repo.query:#{table}")
        end

      # A span whose outcome says nothing past its name adds nothing to its line.
      later =
        "7000000000000000"
        |> span_event("1000000000000000", 8_000, 1_000, pid)
        |> named.("B")
        |> put_in(["attributes", "graphql"], %{"operation_type" => "query", "result" => nil})

      log = log_event(@trace_hex, pid, 3_000)

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(
            0,
            9,
            Enum.with_index(
              [later, root, mutation, auth, under_auth, log] ++ queries,
              &entry(&2 + 1, &1)
            )
          )
        )

      full = Timeline.trace(scan, options(%{human: true}))
      assert full["omitted"] == %{"hidden" => %{}, "collapsed" => %{}}

      # A request's repeated query shapes lead, across
      # the whole tree, with their caller and total time.
      assert [
               %{
                 "source" => "users",
                 "count" => 2,
                 "total_us" => 200,
                 "from_kind" => "parent_span"
               }
             ] =
               full["repeated_queries"]

      repeated = [
        "Repeated queries in this request (by table and statement shape, never parameters):",
        "  users (shape unknown) × 2 from span \"mutation placeBuyOrder\" (no repo stacktrace recorded), 0.2 ms total"
      ]

      assert String.split(full["text"], "\n") ==
               [
                 "trace #{@trace_hex}: 8 spans, 9 items" | repeated
               ] ++
                 [
                   "+0.000ms span POST /graphql internal 10.000ms",
                   "  +1.000ms span mutation placeBuyOrder internal 5.000ms result=user_errors user_errors=1 fields=[unitPrice]",
                   "    +1.100ms span my_app.authorization.decision internal 0.050ms",
                   "      +1.110ms span my_app.repo.query:permissions internal 0.010ms",
                   "    +1.600ms span my_app.repo.query:users internal 0.100ms",
                   "    +1.700ms span my_app.repo.query:users internal 0.100ms",
                   "    +1.800ms span my_app.repo.query:bids internal 0.100ms",
                   "    +2.000ms log warning line at 3000",
                   "  +7.000ms span B internal 1.000ms"
                 ]

      folded = Timeline.trace(scan, options(%{human: true, collapse: ["sql"], hide: ["auth"]}))
      assert folded["omitted"] == %{"hidden" => %{"auth" => 1}, "collapsed" => %{"sql" => 4}}
      # Hidden spans leave the items; what was under them moves up.
      assert folded["spans"] == 8
      assert Enum.count(folded["items"]) == 8

      refute Enum.any?(
               folded["items"],
               &(to_string(&1["event"]["attributes"]["name"]) =~ "authorization")
             )

      assert Enum.find(folded["items"], &(&1["receipt"] == 5))["depth"] == 2

      assert String.split(folded["text"], "\n") ==
               [
                 "trace #{@trace_hex}: 8 spans, 8 items; hidden auth 1; collapsed sql 4"
                 | repeated
               ] ++
                 [
                   "+0.000ms span POST /graphql internal 10.000ms",
                   "  +1.000ms span mutation placeBuyOrder internal 5.000ms result=user_errors user_errors=1 fields=[unitPrice]",
                   "    +1.110ms … 4 sql (4 spans, 0.310ms): my_app.repo.query:users ×2, my_app.repo.query:permissions, my_app.repo.query:bids",
                   "    +2.000ms log warning line at 3000",
                   "  +7.000ms span B internal 1.000ms"
                 ]

      # One matching span is folded too; what is under a folded span is counted.
      single = Timeline.trace(scan, options(%{human: true, collapse: ["auth"]}))
      assert single["omitted"]["collapsed"] == %{"auth" => 2}

      assert single["text"] =~
               "\n    +1.100ms … 2 auth (1 span, 1 under them, 0.050ms): my_app.authorization.decision\n"

      # A name prefix works as a category too, and lines stop at the limit.
      prefix = Timeline.trace(scan, options(%{human: true, hide: ["my_app."], limit: 3}))
      assert prefix["omitted"]["hidden"] == %{"my_app." => 5}

      assert String.split(prefix["text"], "\n") == [
               "trace #{@trace_hex}: 8 spans, 3 items; hidden my_app. 5",
               "+0.000ms span POST /graphql internal 10.000ms",
               "  +1.000ms span mutation placeBuyOrder internal 5.000ms result=user_errors user_errors=1 fields=[unitPrice]",
               "    +2.000ms log warning line at 3000",
               "… 1 more: cut at --limit; raise it (up to 1000)"
             ]
    end

    # --human prints only the text, so the text carries
    # the losses and an incomplete scan, whatever the line bound.
    test "trace and timeline text name losses and an incomplete scan before any item" do
      pid = "<0.5.0>"

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(
            100,
            101,
            [entry(101, span_event("aaaaaaaaaaaaaaaa", nil, 1_000, 10, pid))],
            [
              %{"reason" => "evicted", "scope" => "receipt_range", "count" => 659},
              %{"reason" => "logger_shed", "scope" => "since_session_start", "count" => nil}
            ]
          )
        )
        |> Map.put(:unread, 100)

      trace = Timeline.trace(scan, options(%{human: true, limit: 1, ending: "deadline"}))

      assert [_header, lost, incomplete, _span] = String.split(trace["text"], "\n")

      assert lost ==
               "Lost: evicted 659 (receipt_range), logger_shed unknown (since_session_start), " <>
                 "scan_truncated 100 (receipt_range). Evicted: the Recorder was full and dropped its oldest events; " <>
                 "trace --retain keeps a trace from now on"

      assert incomplete ==
               "Incomplete scan: ended by deadline; 100 older receipts unread (the scan reads newest first)"

      timeline = Timeline.timeline(scan, options(%{pid: pid, human: true, ending: "deadline"}))
      assert timeline["text"] =~ "\nLost: evicted 659 (receipt_range)"
      assert timeline["text"] =~ "\nIncomplete scan: ended by deadline"

      complete = "live-1" |> Timeline.scan() |> Timeline.add(batch(0, 1, [], []))
      refute Timeline.trace(complete, options(%{human: true}))["text"] =~ ~r/Lost|Incomplete/
    end

    test "the text of a timeline renders partial events and says what a limit left out" do
      pid = "<0.5.0>"
      subject = %{"namespace" => "process", "scope" => "n@h", "value" => pid}

      span =
        "aaaaaaaaaaaaaaaa"
        |> span_event(nil, 10_000, 0, pid)
        |> update_in(
          ["attributes"],
          &Map.merge(&1, %{"duration_us" => "slow", "status" => "error", "service" => "shop"})
        )

      long =
        Map.put(log_event(nil, pid, 10_500), "payload", %{"message" => String.duplicate("x", 200)})

      bare_log = %{
        "source" => "logger",
        "severity" => "info",
        "wall_time" => "not a time",
        "subject" => subject
      }

      sourceless = %{"subject" => subject, "wall_time" => 12_000}

      scan =
        "live-1"
        |> Timeline.scan()
        |> Timeline.add(
          batch(0, 5, [
            entry(1, span),
            entry(2, long),
            entry(3, bare_log),
            entry(4, telemetry_event(pid, 11_000, %{})),
            entry(5, sourceless)
          ])
        )

      result = Timeline.timeline(scan, options(%{pid: pid, human: true}))

      assert String.split(result["text"], "\n") == [
               "pid <0.5.0>: 5 items, pids <0.5.0>",
               "+0.000ms span s-aaaaaaaaaaaaaaaa internal ? ERROR (shop)",
               "+0.500ms log warning " <> String.duplicate("x", 160) <> "…",
               "+1.000ms telemetry phoenix.endpoint.stop info",
               "? log info ",
               "? event"
             ]

      assert result["unjoined"]["events_without_time"] == 2

      cut = Timeline.timeline(scan, options(%{pid: pid, human: true, limit: 2}))
      assert cut["text"] =~ ~r/\n… 3 more: cut at --limit; raise it \(up to 1000\)\z/
    end
  end

  # On this base the Recorder drops a write that meets another at its lock
  # (`recorder_contended`); the otel, Logger, and Telemetry collectors write
  # concurrently, so an event is occasionally lost and the trace reports the
  # gap. Contended writers do not wait yet. Until then a run whose trace
  # reports that gap is repeated in a fresh session, at most `attempts`
  # times; any other loss fails the test.
  defp traced_request(attempts) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger", "otel", "telemetry"],
               "telemetry_events" => [Enum.map(@tick, &Atom.to_string/1)],
               "telemetry_min_duration_ms" => 0,
               "logger_level" => "info"
             })

    request = request("req-9")
    assert {:ok, trace} = Live.trace(id, @trace_hex, %{"human" => true})

    if attempts > 1 and Enum.any?(trace["gaps"], &(&1["reason"] == "recorder_contended")) do
      assert {:ok, _record} = Live.stop(id)
      traced_request(attempts - 1)
    else
      assert trace["gaps"] == []
      {id, request, trace}
    end
  end

  # Why a log line did not join: the raw recorded entry (its receipt,
  # process, causality, and wall time, read without the trace's join) and
  # the spans it could have joined by process and time.
  defp join_diagnostics(id, trace, message) do
    {:ok, read} = Live.events_since(id, 0, %{"limit" => 500, "max_bytes" => 1_048_576})

    logs =
      for entry <- read["events"],
          entry["event"]["source"] == "logger",
          get_in(entry, ["event", "payload", "message"]) == message,
          do:
            Map.take(entry["event"], ["subject", "causality", "wall_time"])
            |> Map.put("receipt", entry["receipt"])

    spans =
      for item <- trace["items"],
          item["event"]["source"] == "otel",
          do: %{
            "span_id" => item["span_id"],
            "process" => get_in(item, ["event", "subject", "value"]),
            "start" => get_in(item, ["event", "attributes", "start_wall_time"]),
            "duration_us" => get_in(item, ["event", "attributes", "duration_us"]),
            "window_slack_us" => trace["window_slack_us"]
          }

    inspect(
      %{
        "recorded_log" => logs,
        "spans" => spans,
        "scan" => trace["scan"],
        "gaps" => trace["gaps"],
        "joined" => trace["joined"]
      },
      pretty: true,
      limit: :infinity
    )
  end

  # One request in a new process: a root span and a child span ended through
  # the SDK's span-end function, a log line and a Telemetry event inside the
  # root span's context, and a log line after the context is cleared.
  defp request(request_id) do
    task =
      Task.async(fn ->
        start = :erlang.monotonic_time()

        Logger.metadata(
          request_id: request_id,
          otel_trace_id: @trace_hex,
          otel_span_id: @root_hex
        )

        Logger.warning("in trace")
        :telemetry.execute(@tick, %{duration: 1}, %{})

        OtelSpans.end_in_current(
          OtelSpans.open(
            trace_id: @trace,
            span_id: @child,
            parent_span_id: @root,
            name: "repo.query",
            start_time: start
          )
        )

        Logger.metadata(otel_trace_id: nil, otel_span_id: nil)
        Logger.warning("after context")

        OtelSpans.end_in_current(
          OtelSpans.open(trace_id: @trace, span_id: @root, start_time: start)
        )

        self() |> :erlang.pid_to_list() |> to_string()
      end)

    %{pid: Task.await(task)}
  end

  defp label(%{"event" => %{"source" => "otel", "attributes" => %{"name" => name}}}),
    do: "span " <> name

  defp label(%{"event" => %{"source" => "logger", "payload" => %{"message" => message}}}),
    do: "log " <> message

  defp label(%{"event" => %{"source" => source, "kind" => kind}}), do: source <> " " <> kind

  # The repeated-queries block is inside max_bytes.
  test "the repeated-queries block counts toward max_bytes" do
    queries =
      for n <- 1..24 do
        "#{String.pad_leading(Integer.to_string(n), 3, "0")}0000000000000"
        |> span_event(nil, n * 10, 5, "<0.1.0>")
        |> put_in(
          ["attributes", "name"],
          "app.repo.query:table_with_a_rather_long_name_#{rem(n, 8)}"
        )
      end

    scan =
      "live-1"
      |> Timeline.scan()
      |> Timeline.add(batch(0, 24, Enum.with_index(queries, &entry(&2 + 1, &1))))

    text = Timeline.trace(scan, options(%{human: true, max_bytes: 1_024}))["text"]
    [footer | _] = text |> String.split("\n") |> Enum.reverse()
    assert byte_size(text) - byte_size(footer) - 1 <= 1_024
    assert text =~ "Repeated queries in this request"
  end

  # An Oban job's span names its worker, queue, and attempt.
  test "a trace's Oban job span names its worker, queue, and attempt" do
    job =
      "1000000000000000"
      |> span_event(nil, 0, 3_100, "<0.1.0>")
      |> put_in(["attributes", "name"], "Oban.Pro.Decorator process")
      |> Map.put("payload", %{
        "span_attributes" => %{
          "oban.job.worker" => "Oban.Pro.Decorator",
          "messaging.destination.name" => "notifications",
          "oban.job.attempt" => 2,
          "oban.job.max_attempts" => 20
        }
      })

    scan = "live-1" |> Timeline.scan() |> Timeline.add(batch(0, 1, [entry(1, job)]))

    assert Timeline.trace(scan, options(%{human: true}))["text"] =~
             "span Oban.Pro.Decorator process internal 3.100ms worker=Oban.Pro.Decorator queue=notifications attempt=2/20"
  end

  defp options(overrides \\ %{}),
    do:
      Map.merge(%{trace_id: @trace_hex, limit: 200, max_bytes: 262_144, human: false}, overrides)

  defp batch(cursor, next, events, gaps \\ []),
    do: %{"cursor" => cursor, "next_cursor" => next, "events" => events, "gaps" => gaps}

  defp entry(receipt, event), do: %{"receipt" => receipt, "event" => event, "redactions" => []}

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp span_event(span_id, parent, start_us, duration_us, pid) do
    %{
      "source" => "otel",
      "kind" => "otel.span",
      "severity" => "info",
      "wall_time" => iso(start_us + duration_us),
      "subject" => pid && %{"namespace" => "process", "scope" => "n@h", "value" => pid},
      "causality" => %{"trace_id" => @trace_hex, "span_id" => span_id},
      "attributes" => %{
        "trace_id" => @trace_hex,
        "span_id" => span_id,
        "parent_span_id" => parent,
        "name" => "s-" <> span_id,
        "span_kind" => "internal",
        "status" => "ok",
        "start_wall_time" => iso(start_us),
        "duration_us" => duration_us
      }
    }
  end

  defp log_event(trace_id, pid, at_us) do
    %{
      "source" => "logger",
      "kind" => "logger_message",
      "severity" => "warning",
      "wall_time" => at_us && iso(at_us),
      "subject" => pid && %{"namespace" => "process", "scope" => "n@h", "value" => pid},
      "causality" => %{"trace_id" => trace_id, "span_id" => nil},
      "attributes" => %{},
      "payload" => %{"message" => "line at #{inspect(at_us)}"}
    }
  end

  defp telemetry_event(pid, at_us, metadata) do
    {duration, metadata} = Map.pop(metadata, "duration")

    %{
      "source" => "telemetry",
      "kind" => "phoenix.endpoint.stop",
      "severity" => "info",
      "wall_time" => iso(at_us),
      "subject" => %{"namespace" => "process", "scope" => "n@h", "value" => pid},
      "causality" => %{"trace_id" => nil, "span_id" => nil},
      "attributes" => %{"measurements" => if(duration, do: %{"duration" => duration}, else: %{})},
      "payload" => %{"metadata" => metadata}
    }
  end
end
