defmodule Insider.Live.TraceRetentionTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Owner

  @trace "6bf92f3577b34da6a3ce929d0e0e4731"
  @other "6bf92f3577b34da6a3ce929d0e0e4732"
  @third "6bf92f3577b34da6a3ce929d0e0e4733"
  @fourth "6bf92f3577b34da6a3ce929d0e0e4734"
  @span "00f067aa0ba902b7"
  @stop [:absinthe, :execute, :operation, :stop]

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)
  end

  defp start(extra \\ %{}) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(
               Map.merge(
                 %{
                   "components" => ["logger", "telemetry"],
                   "logger_level" => "info",
                   "telemetry_events" => [Enum.map(@stop, &Atom.to_string/1)],
                   "telemetry_min_duration_ms" => 0,
                   "max_events" => 64
                 },
                 extra
               )
             )

    id
  end

  # Log lines in one request process under a trace context.
  defp in_trace(trace_id, lines, fun \\ fn -> :ok end) do
    Task.await(
      Task.async(fn ->
        Logger.metadata(otel_trace_id: trace_id, otel_span_id: @span)
        for line <- lines, do: Logger.info(line)
        fun.()
      end)
    )
  end

  # Enough Logger lines outside any trace to evict every earlier Logger
  # event, read in chunks so the collector's inbox never sheds.
  defp flood(id) do
    for chunk <- 1..3 do
      for line <- 1..100, do: Logger.info("flood #{chunk}-#{line}")
      assert {:ok, _caught_up} = Live.events_since(id, "latest")
    end
  end

  defp logged(trace) do
    for %{"event" => %{"source" => "logger", "payload" => %{"message" => message}}} <-
          trace["items"],
        do: message
  end

  describe "retention" do
    test "a pinned trace survives eviction, with its later events, and says so" do
      id = start()
      in_trace(@trace, ["step 1", "step 2", "step 3"])

      assert {:ok, pinned} = Live.trace(id, @trace, %{"retain" => true, "human" => true})
      assert logged(pinned) == ["step 1", "step 2", "step 3"]
      assert %{"pinned" => "explicit", "events" => 3, "restored" => 0} = pinned["retention"]
      assert pinned["text"] =~ "\nRetained: pinned with --retain; 3 events kept"

      # A later event of the pinned trace is kept too.
      in_trace(@trace, ["step 4"])
      assert {:ok, _status} = Live.status(id)
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert logged(trace) == ["step 1", "step 2", "step 3", "step 4"]
      assert Enum.any?(trace["gaps"], &(&1["reason"] == "evicted" and &1["count"] > 0))

      assert %{"pinned" => "explicit", "events" => 4, "restored" => 4, "lost" => 0} =
               trace["retention"]

      assert trace["text"] =~
               "\nRetained: pinned with --retain; 4 events kept, 4 of them restored after the Recorder evicted them"

      refute trace["text"] =~ "Hint:"

      assert {:ok, %{"retention" => %{"pinned" => [@trace], "events" => 4}}} = Live.status(id)
    end

    test "an evicted, unpinned trace says once how to pin it" do
      id = start()
      in_trace(@trace, ["step 1"])
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert trace["items"] == []
      assert trace["retention"]["pinned"] == nil

      assert trace["retention"]["hint"] =~
               "pin a trace while the Recorder still holds it: trace --trace-id #{@trace} --retain"

      assert trace["text"] =~ "\nHint: the Recorder evicted"
      assert trace["text"] =~ "--retain-traces"

      assert {:ok, again} = Live.trace(id, @trace, %{"human" => true})
      assert again["retention"]["hint"] == nil
      refute again["text"] =~ "Hint:"
    end

    test "retain_traces keeps the most recently active traces, swept on the owner's tick" do
      id = start(%{"retain_traces" => 2})
      in_trace(@trace, ["a 1"])
      in_trace(@other, ["b 1"])
      in_trace(@third, ["c 1"])
      # The owner's push tick sweeps new events; its state call waits for it.
      send(Process.whereis(Owner), :push)
      :sys.get_state(Owner)
      flood(id)

      assert {:ok, %{"items" => []}} = Live.trace(id, @trace)
      assert {:ok, other} = Live.trace(id, @other)
      assert logged(other) == ["b 1"]
      assert %{"pinned" => "auto", "restored" => 1} = other["retention"]
      assert {:ok, third} = Live.trace(id, @third)
      assert logged(third) == ["c 1"]

      assert {:ok, %{"retention" => retention}} = Live.status(id)
      assert %{"retain_traces" => 2, "traces" => 2, "evicted_traces" => 1} = retention

      # Amending the limit keeps the session's retention.
      assert {:ok, _amended} = Live.amend(id, %{"retain_traces" => 1})
      assert {:ok, %{"retention" => %{"retain_traces" => 1, "traces" => 1}}} = Live.status(id)
      in_trace(@fourth, ["d 1"])
      assert {:ok, %{"retention" => %{"traces" => 1}}} = Live.status(id)
    end

    # A service view keeps a retained trace's correlated
    # Logger events after the Recorder evicted them, as it did before.
    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "a service view keeps a pinned trace's correlated events after eviction" do
      id = start(%{"components" => ["logger", "otel"], "telemetry_events" => nil})

      span = %{
        "trace_id" => @trace,
        "span_id" => @span,
        "parent_span_id" => nil,
        "name" => "GET /marketplace",
        "span_kind" => "server",
        "status" => "ok",
        "status_message" => nil,
        "service" => "shop-a",
        "scope" => "test",
        "start_time_us" => System.os_time(:microsecond),
        "duration_us" => 1_000,
        "attributes" => %{"http.route" => "/marketplace"},
        "pid" => nil
      }

      assert {:ok, %{"accepted" => 1}} = Live.ingest_spans(id, [span])
      in_trace(@trace, ["correlated line"])
      view = %{"view" => %{"services" => ["shop-a"]}}

      assert {:ok, before} = Live.trace(id, @trace, Map.put(view, "retain", true))
      assert logged(before) == ["correlated line"]
      flood(id)

      assert {:ok, after_eviction} = Live.trace(id, @trace, view)
      assert logged(after_eviction) == ["correlated line"]
      assert after_eviction["spans"] == 1

      # A view that scopes to another service keeps none of it.
      assert {:ok, other} = Live.trace(id, @trace, %{"view" => %{"services" => ["shop-b"]}})
      assert other["items"] == []
    end

    test "retain and retain_traces are validated" do
      assert {:error, %{"code" => "invalid_options", "field" => "retain_traces"}} =
               Live.start(%{"components" => ["logger"], "retain_traces" => 65})

      assert {:error, %{"code" => "invalid_options", "field" => "retain"}} =
               Live.trace("live-none", @trace, %{"retain" => "yes"})
    end
  end

  describe "values" do
    defp field(name, selections \\ []),
      do: %{
        __struct__: Absinthe.Blueprint.Document.Field,
        name: name,
        alias: nil,
        selections: selections
      }

    defp buy_order_selections do
      [
        field("buyOrderV2", [
          field(
            "buyOrder",
            Enum.map(~w(displayId totalAmount totalSize password note), &field/1)
          ),
          field("fills", [field("amount")])
        ])
      ]
    end

    defp buy_order(id) do
      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [
          %{name: "buyOrderV2", type: :query, current: true, selections: buy_order_selections()}
        ],
        fragments: [],
        result: %{
          data: %{
            "buyOrderV2" => %{
              "buyOrder" => %{
                "displayId" => "STF-01M34FY34F",
                "totalAmount" => "500000.01",
                "totalSize" => 512_500.01,
                "password" => "hunter2",
                "note" => String.duplicate("é", 900)
              },
              "fills" => [%{"amount" => "100000.00"}, %{"amount" => "14154.60"}]
            }
          }
        }
      }

      in_trace(@trace, ["loading buy order"], fn ->
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)

      id
    end

    test "trace --values shows one trace's GraphQL response values, masked and bounded" do
      id = buy_order(start())

      assert {:ok, trace} = Live.trace(id, @trace, %{"values" => true, "human" => true})

      assert %{
               "operations" => [
                 %{"operation" => "query buyOrderV2", "fields" => fields, "omitted_fields" => 0}
               ]
             } = trace["values"]

      assert %{"path" => "buyOrderV2.buyOrder.totalAmount", "value" => "500000.01"} in fields

      # Each value is at most 160 bytes of JSON, in the
      # result as in the text, cut at a character boundary.
      note = Enum.find(fields, &(&1["path"] == "buyOrderV2.buyOrder.note"))
      assert note["truncated"]
      assert byte_size(Jason.encode!(note["value"])) <= 160
      assert String.valid?(note["value"])
      assert String.ends_with?(note["value"], "…")
      assert %{"path" => "buyOrderV2.fills[1].amount", "value" => "14154.60"} in fields
      refute inspect(fields) =~ "hunter2"

      assert trace["text"] =~ "\nValues (rich profile, credential-masked):\n"
      assert trace["text"] =~ "query buyOrderV2"
      assert trace["text"] =~ ~s(\n    buyOrderV2.buyOrder.totalAmount = "500000.01")
      # Rich rendering keeps a float as its exact text.
      assert trace["text"] =~ ~s(\n    buyOrderV2.buyOrder.totalSize = "512500.01")
      refute trace["text"] =~ "hunter2"

      assert {:ok, only} =
               Live.trace(id, @trace, %{
                 "values" => true,
                 "values_paths" => ["buyOrderV2.buyOrder.total*"],
                 "human" => true
               })

      assert [%{"fields" => only_fields, "omitted_fields" => 0}] = only["values"]["operations"]

      assert Enum.map(only_fields, & &1["path"]) ==
               ["buyOrderV2.buyOrder.totalAmount", "buyOrderV2.buyOrder.totalSize"]

      # A view that hides the operation stop says so. A sticky
      # --view-kind otel.span once hid the values.
      assert {:ok, viewed} =
               Live.trace(id, @trace, %{
                 "values" => true,
                 "human" => true,
                 "view" => %{"sources" => ["logger"]}
               })

      assert viewed["values"]["operations"] == []
      assert viewed["values"]["view_hidden"] == 1

      assert viewed["text"] =~
               "\nValues: none shown: this read's view hid 1 events, and the operation stops may be among them; " <>
                 "read with --view-clear (or a view that keeps absinthe.execute.operation.stop)."

      # A hidden operation stop contributes no values.
      assert {:ok, hidden} =
               Live.trace(id, @trace, %{"values" => true, "human" => true, "hide" => ["absinthe"]})

      assert hidden["values"]["operations"] == []
      refute hidden["text"] =~ "500000.01"

      # Without --values the text shows no values.
      assert {:ok, plain} = Live.trace(id, @trace, %{"human" => true})
      refute Map.has_key?(plain, "values")
      refute plain["text"] =~ "500000.01"
    end

    # A proof that a mutation did what it should also needs what it was sent.
    test "trace --values shows the inputs a mutation received, masked, beside its response" do
      id = start()

      field =
        "placeBuyOrder"
        |> field([field("__typename")])
        |> Map.put(:arguments, [
          %{
            __struct__: Absinthe.Blueprint.Input.Argument,
            name: "input",
            value: %{
              unit_price: %{amount: %{__struct__: Decimal, sign: -1, coef: 1, exp: 0}},
              api_key: "hunter2"
            }
          }
        ])

      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [
          %{name: "placeBuyOrder", type: :mutation, current: true, selections: [field]}
        ],
        fragments: [],
        result: %{data: %{"placeBuyOrder" => %{"__typename" => "ValidationError"}}}
      }

      in_trace(@trace, ["placing"], fn ->
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)

      assert {:ok, trace} = Live.trace(id, @trace, %{"values" => true, "human" => true})
      assert [%{"fields" => fields}] = trace["values"]["operations"]
      paths = Map.new(fields, &{&1["path"], &1["value"]})

      assert paths["arguments.placeBuyOrder.input.unit_price.amount"] == "-1"
      assert paths["arguments.placeBuyOrder.input.api_key"] == "[REDACTED:credential_key]"
      assert paths["placeBuyOrder.__typename"] == "ValidationError"

      assert trace["text"] =~
               ~s(\n    arguments.placeBuyOrder.input.unit_price.amount = "-1")

      refute trace["text"] =~ "hunter2"
    end

    # The client's user agent was only on the request span, so proof took
    # 11 minutes. A ValidationError inside a 200 read as result=ok. Kept
    # records could not be listed on their own.
    test "a mutation's event and kept record name the client, the response types, and the argument ids" do
      id = start(%{"telemetry_events" => [Enum.map(@stop, &Atom.to_string/1)]})

      field =
        "updateSellOrder"
        |> field([field("__typename")])
        |> Map.put(:arguments, [
          %{
            __struct__: Absinthe.Blueprint.Input.Argument,
            name: "input",
            value: %{sell_order_id: "so-123", price: "48.00"}
          }
        ])

      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [
          %{name: "updateSellOrder", type: :mutation, current: true, selections: [field]}
        ],
        fragments: [],
        result: %{data: %{"updateSellOrder" => %{"__typename" => "ValidationError"}}}
      }

      conn = %{
        __struct__: Plug.Conn,
        method: "POST",
        request_path: "/graphql",
        remote_ip: {127, 0, 0, 1},
        req_headers: [{"user-agent", "partner-portfolio-sync/2.3"}]
      }

      in_trace(@trace, [], fn ->
        :telemetry.execute([:phoenix, :endpoint, :start], %{system_time: 0}, %{conn: conn})
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 2_000}, %{conn: conn})
        # A later operation of the same process outside a request names no client.
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)

      assert {:ok, %{"events" => events}} = Live.events_since(id, 0)

      stops =
        for %{"event" => %{"kind" => "absinthe.execute.operation.stop"} = e} <- events, do: e

      assert [%{"user_agent" => "partner-portfolio-sync/2.3", "remote_ip" => "127.0.0.1"}, nil] =
               Enum.map(stops, & &1["attributes"]["graphql"]["client"])

      assert {:ok, listed} = Live.mutations(id, %{"id" => "so-123", "human" => true})
      assert listed["schema"] == "insider.live-mutations/v1"

      assert [%{"typenames" => ["ValidationError"], "user_agent" => "partner-portfolio-sync/2.3"}] =
               Enum.take(listed["records"], 1)

      assert listed["text"] =~
               "Kept mutation: updateSellOrder result=ok types=[ValidationError] at "

      assert listed["text"] =~ "user agent partner-portfolio-sync/2.3"
      assert listed["text"] =~ "ids so-123)"
      assert {:ok, %{"records" => []}} = Live.mutations(id, %{"id" => "so-999"})

      assert {:error, %{"code" => "invalid_options", "field" => "id"}} =
               Live.mutations(id, %{"id" => String.duplicate("i", 65)})
    end

    # Two trace calls found nothing before
    # --retain-traces was set.
    test "a mutation request's trace is kept by default, with the events before its stop" do
      id = start()

      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [%{name: "updateSellOrder", type: :mutation, current: true, selections: []}],
        fragments: [],
        result: %{data: %{}}
      }

      in_trace(@trace, ["before the mutation"], fn ->
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)

      send(Process.whereis(Insider.Live.Owner), :push)
      :sys.get_state(Insider.Live.Owner)
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace)
      kinds = Enum.map(trace["items"], & &1["event"]["kind"])
      assert "absinthe.execute.operation.stop" in kinds
      assert "logger_message" in kinds
      assert %{"pinned" => "mutation"} = trace["retention"]

      assert {:ok, %{"retention" => %{"mutation_traces" => 1, "keep_mutations" => true}}} =
               Live.status(id)
    end

    test "a trace without recorded response data says where values come from" do
      id = start()
      in_trace(@trace, ["no graphql here"])

      assert {:ok, trace} = Live.trace(id, @trace, %{"values" => true, "human" => true})
      assert trace["values"]["operations"] == []

      assert trace["text"] =~
               "\nValues: no GraphQL response data in this trace; it is recorded on absinthe.execute.operation.stop"
    end

    test "the strict profile refuses values and says why, before it changes retention" do
      Application.put_env(:insider, :environment, :ci)
      id = buy_order(start())

      # Eight pins, then a refused ninth with values.
      pins = for n <- 1..8, do: n |> Integer.to_string() |> String.pad_leading(32, "a")
      for pin <- pins, do: assert({:ok, _trace} = Live.trace(id, pin, %{"retain" => true}))
      assert {:ok, %{"retention" => before}} = Live.status(id)

      assert {:error, %{"code" => "disclosure_denied"}} =
               Live.trace(id, @trace, %{"values" => true, "retain" => true})

      assert {:ok, %{"retention" => after_denial}} = Live.status(id)
      assert after_denial["pinned"] == before["pinned"]
      assert after_denial["evicted_traces"] == before["evicted_traces"]
      assert Enum.sort(before["pinned"]) == Enum.sort(pins)

      assert {:error, %{"code" => "disclosure_denied", "field" => "values"} = error} =
               Live.trace(id, @trace, %{"values" => true})

      assert error["disclosure_profile"] == "strict"
      assert error["hint"] =~ "rich"

      assert {:error, %{"code" => "invalid_options", "field" => "values_paths"}} =
               Live.trace(id, @trace, %{"values" => true, "values_paths" => ["has space"]})
    end
  end

  # A failing request's trace came back empty (0 spans, thousands evicted)
  # after a minute of normal traffic, until --retain-traces was set and the
  # request run again. Failed and slow traces are kept by default.
  describe "kept by default" do
    defp sweep_now do
      send(Process.whereis(Owner), :push)
      :sys.get_state(Owner)
    end

    defp query_stop(ms) do
      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [%{name: "listOrders", type: :query, current: true, selections: []}],
        fragments: [],
        result: %{data: %{}}
      }

      duration = System.convert_time_unit(ms, :millisecond, :native)
      :telemetry.execute(@stop, %{duration: duration}, %{blueprint: blueprint, options: []})
    end

    test "a failing request's trace survives eviction and says why it was kept" do
      id = start()

      in_trace(@trace, ["loading order", "charging card"], fn ->
        Logger.error("charge failed")
        Logger.info("rolled back")
      end)

      sweep_now()
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert logged(trace) == ["loading order", "charging card", "charge failed", "rolled back"]
      assert Enum.any?(trace["gaps"], &(&1["reason"] == "evicted" and &1["count"] > 0))

      assert %{"pinned" => "failed", "events" => 4, "restored" => 4, "lost" => 0} =
               trace["retention"]

      assert trace["text"] =~
               "\nRetained: kept because it failed; 4 events kept, 4 of them restored"

      refute trace["text"] =~ "Hint:"

      assert {:ok, %{"retention" => %{"failed_traces" => 1, "keep_failed_and_slow" => true}}} =
               Live.status(id)
    end

    test "a slow request's trace survives eviction and says why it was kept" do
      id = start()
      in_trace(@trace, ["listing orders"], fn -> query_stop(600) end)
      sweep_now()
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      kinds = Enum.map(trace["items"], & &1["event"]["kind"])
      assert "absinthe.execute.operation.stop" in kinds
      # The Logger flood evicted the request's Logger line, which retention
      # restores; the operation stop is within the Telemetry source's share
      # of the Recorder, so it is still held.
      assert logged(trace) == ["listing orders"]
      assert %{"pinned" => "slow", "events" => 2, "restored" => 1} = trace["retention"]
      assert trace["text"] =~ "\nRetained: kept because it was slow (≥ 500 ms); 2 events kept"
    end

    test "a fast, successful request's trace is not kept and still says how to pin it" do
      id = start()
      in_trace(@trace, ["listing orders"], fn -> query_stop(1) end)
      sweep_now()
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert logged(trace) == []
      assert trace["retention"]["pinned"] == nil
      assert trace["retention"]["hint"] =~ "trace --trace-id #{@trace} --retain"

      assert {:ok, %{"retention" => %{"traces" => 0, "failed_traces" => 0, "slow_traces" => 0}}} =
               Live.status(id)
    end

    test "a burst of failing requests never lets a kept mutation trace go" do
      id = start()

      blueprint = %{
        __struct__: Absinthe.Blueprint,
        operations: [%{name: "placeOrder", type: :mutation, current: true, selections: []}],
        fragments: [],
        result: %{data: %{}}
      }

      in_trace(@trace, ["placing"], fn ->
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)

      max = Insider.Live.Retention.bounds()["failed_traces_max"]

      for n <- 1..(max + 4) do
        trace_id = n |> Integer.to_string() |> String.pad_leading(32, "f")
        in_trace(trace_id, [], fn -> Logger.error("background call failed") end)
      end

      sweep_now()
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace)
      assert logged(trace) == ["placing"]
      assert %{"pinned" => "mutation"} = trace["retention"]

      assert {:ok, %{"retention" => %{"mutation_traces" => 1, "failed_traces" => ^max}}} =
               Live.status(id)
    end

    # A scratch app with only the Logger: its request carries the trace id
    # in Logger metadata.
    test "a logger-only session keeps a failed trace" do
      id = start(%{"components" => ["logger"], "telemetry_events" => nil})

      in_trace(@trace, ["step 1"], fn -> Logger.error("step 2 failed") end)
      sweep_now()
      flood(id)

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert logged(trace) == ["step 1", "step 2 failed"]
      assert %{"pinned" => "failed", "restored" => 2} = trace["retention"]
      assert trace["text"] =~ "\nRetained: kept because it failed"

      assert {:ok, %{"retention" => %{"keep_failed_and_slow" => true, "keep_mutations" => false}}} =
               Live.status(id)
    end

    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "an otel-only session keeps a failed span's trace" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{"components" => ["otel"], "max_events" => 64})

      span = fn trace_id, span_id, parent, status ->
        %{
          "trace_id" => trace_id,
          "span_id" => span_id,
          "parent_span_id" => parent,
          "name" => "GET /orders",
          "span_kind" => "server",
          "status" => status,
          "status_message" => nil,
          "service" => "shop-a",
          "scope" => "test",
          "start_time_us" => System.os_time(:microsecond),
          "duration_us" => 1_000,
          "attributes" => %{},
          "pid" => nil
        }
      end

      assert {:ok, %{"accepted" => 2}} =
               Live.ingest_spans(id, [
                 span.(@trace, "00f067aa0ba902b8", @span, "ok"),
                 span.(@trace, @span, nil, "error")
               ])

      sweep_now()

      for chunk <- 1..6 do
        spans =
          for n <- 1..50 do
            trace_id = (chunk * 100 + n) |> Integer.to_string() |> String.pad_leading(32, "e")
            span.(trace_id, @span, nil, "ok")
          end

        assert {:ok, %{"accepted" => 50}} = Live.ingest_spans(id, spans)
        assert {:ok, _caught_up} = Live.events_since(id, "latest")
      end

      assert {:ok, trace} = Live.trace(id, @trace, %{"human" => true})
      assert trace["spans"] == 2
      assert %{"pinned" => "failed", "restored" => 2} = trace["retention"]
      assert trace["text"] =~ "\nRetained: kept because it failed"

      assert {:ok, %{"retention" => %{"keep_failed_and_slow" => true, "keep_mutations" => false}}} =
               Live.status(id)
    end
  end

  defp assert_eventually(predicate, attempts \\ 150)

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
