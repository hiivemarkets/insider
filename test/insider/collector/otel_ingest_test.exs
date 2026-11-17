defmodule Insider.Collector.OtelIngestTest do
  # The collector has a registered name and Live sessions are one per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Collector.Gate
  alias Insider.Collector.Otel
  alias Insider.Collector.Otel.Tracing
  alias Insider.Live
  alias Insider.Live.Disclosure
  alias Insider.Recorder
  alias Insider.Redaction.Policy, as: RedactionPolicy

  @trace_hex "0af7651916cd43dd8448eb211c80319c"

  describe "an ingest-only collector (every OTP release)" do
    setup do
      {:ok, policy} =
        RedactionPolicy.new(id: "otel-ingest", maximum_sensitivity: :internal, rules: [])

      {:ok, pid} =
        Recorder.start_link(
          classification: {:internal, policy},
          max_events: 64,
          post_trigger_ms: 0
        )

      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, recorder} = Recorder.handle(pid)
      %{recorder: recorder}
    end

    test "records ingested spans under the gate and stops without a capture", %{
      recorder: recorder
    } do
      gate =
        Gate.new(%{
          logger: nil,
          origin: nil,
          telemetry: [],
          summary_interval_ms: 10_000,
          otel: %{min_duration_ms: 5}
        })

      on_exit(fn -> Gate.delete(gate) end)
      collector = start!(recorder, gate: gate, rich: true)

      spans = [
        span(%{"span_id" => "0000000000000001", "duration_us" => 9_000}),
        span(%{"span_id" => "0000000000000002", "duration_us" => 1_000}),
        span(%{"span_id" => "0000000000000003", "duration_us" => 1_000, "status" => "error"}),
        %{"span_id" => "bad"}
      ]

      assert {:ok, %{"accepted" => 2, "filtered" => 1, "rejected" => 1, "shed" => 0}} =
               Otel.ingest(spans)

      assert {:ok, status} = Otel.status(collector)
      assert status.installed == 0
      assert status.ingested == 4
      assert status.recorded == 2
      assert status.pauses == 0
      assert Gate.counts(gate)[{"otel", "min_duration"}] == 1

      {:ok, read} = Recorder.read_since(recorder, 0)
      [ok, error] = Enum.map(read.entries, & &1.event)
      assert ok["severity"] == "info"
      assert error["severity"] == "error"
      assert ok["payload"]["span_attributes"] == %{"http.route" => "/graphql"}

      assert {:ok, _status} = Otel.flush(collector)
      assert {:ok, %{trace: "not_installed"}} = Otel.stop(collector)

      assert {:error, :not_running} = Otel.ingest([span(%{})])
    end

    test "refuses a malformed capture option", %{recorder: recorder} do
      assert {:error, :invalid_options} = Otel.start_link(recorder, options(capture: :maybe))
    end

    # A `timeout` is outcome unknown, so ingest is
    # idempotent and a retry never duplicates.
    test "a duplicate ingest records nothing and is counted", %{recorder: recorder} do
      collector = start!(recorder, rich: true)
      spans = [span(%{"span_id" => "0000000000000001"}), span(%{"span_id" => "0000000000000002"})]

      assert {:ok, %{"accepted" => 2, "duplicate" => 0}} = Otel.ingest(spans)
      assert {:ok, %{"accepted" => 0, "duplicate" => 2}} = Otel.ingest(spans)

      # Same span id in another trace is another span.
      other = span(%{"span_id" => "0000000000000001", "trace_id" => String.duplicate("1", 32)})
      assert {:ok, %{"accepted" => 1, "duplicate" => 0}} = Otel.ingest([other])

      assert {:ok, %{recorded: 3, duplicate: 2, ingested: 5}} = Otel.status(collector)
      {:ok, read} = Recorder.read_since(recorder, 0)
      assert [_one, _two, _three] = read.entries
    end

    test "a call taken after its deadline records and counts nothing", %{recorder: recorder} do
      collector = start!(recorder, [])
      {:ok, before} = Otel.status(collector)
      past = System.monotonic_time(:millisecond) - 1

      assert {:error, :timeout} = Otel.ingest([span(%{})], past)
      assert {:ok, ^before} = Otel.status(collector)
      assert {:ok, %{entries: []}} = Recorder.read_since(recorder, 0)

      assert {:error, :invalid_options} = Otel.ingest(:spans, past)
      assert {:error, :invalid_options} = Otel.ingest([span(%{})], :later)
    end

    test "the seen set is bounded and counts what it forgets", %{recorder: recorder} do
      collector = start!(recorder, ingest_seen_max: 2)
      ids = for index <- 1..3, do: "000000000000000#{index}"

      assert {:ok, %{"accepted" => 3}} = Otel.ingest(Enum.map(ids, &span(%{"span_id" => &1})))
      assert {:ok, %{seen_evicted: 1}} = Otel.status(collector)

      # The newest ids are still known; the oldest was forgotten, so its
      # retry is recorded again.
      [oldest | known] = ids

      assert {:ok, %{"accepted" => 0, "duplicate" => 2}} =
               Otel.ingest(Enum.map(known, &span(%{"span_id" => &1})))

      assert {:ok, %{"accepted" => 1, "duplicate" => 0}} =
               Otel.ingest([span(%{"span_id" => oldest})])

      assert {:error, :invalid_options} =
               Otel.start_link(recorder, options(ingest_seen_max: 0))
    end

    # The collector was paused after taking a call, the caller
    # got `timeout`, and the spans were recorded afterwards. That outcome is
    # unknown by contract; a retry of the same spans yields exactly one copy.
    test "a timeout followed by a retry yields exactly one copy of each span" do
      {:ok, policy} =
        RedactionPolicy.new(id: "otel-ingest-retry", maximum_sensitivity: :internal, rules: [])

      {:ok, pid} =
        Recorder.start_link(
          classification: {:internal, policy},
          max_events: 1_024,
          post_trigger_ms: 0
        )

      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, recorder} = Recorder.handle(pid)
      collector = start!(recorder, [])
      spans = for index <- 1..512, do: span(%{"span_id" => span_id(index)})

      # Suspend the collector once it has taken the call and started
      # recording: its first span build is traced, and the tracer suspends it
      # until told to resume (a suspension ends with the process that made it).
      test = self()

      tracer =
        spawn(fn ->
          receive do
            {:trace, ^collector, :call, _mfa} ->
              true = :erlang.suspend_process(collector)
              send(test, :suspended)

              receive do
                :resume -> true = :erlang.resume_process(collector)
              end
          end
        end)

      Code.ensure_loaded!(Insider.Collector.Otel.Span)
      1 = :erlang.trace(collector, true, [:call, {:tracer, tracer}])
      1 = :erlang.trace_pattern({Insider.Collector.Otel.Span, :event, 2}, true, [:local])

      assert {:error, :timeout} = Otel.ingest(spans, System.monotonic_time(:millisecond) + 50)

      assert_receive :suspended, 5000
      :erlang.trace(collector, false, [:call])
      :erlang.trace_pattern({Insider.Collector.Otel.Span, :event, 2}, false, [:local])
      send(tracer, :resume)

      assert {:ok, counts} = Otel.ingest(spans)
      assert counts["accepted"] + counts["duplicate"] == 512

      recorded = recorded_span_ids(recorder, 0, [])
      assert Enum.count(recorded) == 512
      assert Enum.uniq(recorded) == recorded
    end
  end

  describe "the tracing backend" do
    test "reports a capture that is not, or no longer, installed" do
      gone = %{session: make_ref(), counter: make_ref()}
      assert Tracing.delivered(nil) == :error
      assert Tracing.pause(gone) == :error
      assert Tracing.resume(gone) == :error
      refute Tracing.installed?(gone)
      refute Tracing.installed?(nil)
      assert Tracing.remove(nil) == "not_installed"
      assert Tracing.remove(gone) in ["already_removed", "unavailable"]
      assert Tracing.traced_function() == {:otel_span_utils, :end_span, 2}
    end
  end

  describe "the span gate" do
    test "drops spans ended by an excluded origin, never an exited or remote process" do
      gate =
        Gate.new(%{
          logger: nil,
          origin: %{oban_conf: false, modules: %{__MODULE__ => true}},
          telemetry: [],
          summary_interval_ms: 10_000,
          otel: %{min_duration_ms: 0}
        })

      on_exit(fn -> Gate.delete(gate) end)
      test = self()

      excluded =
        :proc_lib.spawn(fn ->
          send(test, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 5000
      refute Gate.otel?(gate, excluded, 10, false)
      assert Gate.otel?(gate, self(), 10, false)
      assert Gate.otel?(gate, nil, 10, false)

      send(excluded, :stop)
      ref = Process.monitor(excluded)
      assert_receive {:DOWN, ^ref, :process, ^excluded, _reason}, 5000
      assert Gate.otel?(gate, excluded, 10, false)
      assert Gate.counts(gate)[{"otel", "origin"}] == 1

      assert Gate.otel?(nil, self(), 0, false)
      plain = Gate.new(%{logger: nil, origin: nil, telemetry: [], summary_interval_ms: 10_000})
      on_exit(fn -> Gate.delete(plain) end)
      assert Gate.otel?(plain, self(), 0, false)
      refute Map.has_key?(Gate.counts(plain), {"otel", "origin"})
    end
  end

  describe "the strict boundary" do
    test "withholds a span's status message and malformed ids, and its payload" do
      event = %{
        "source" => "otel",
        "kind" => "otel.span",
        "causality" => %{"trace_id" => @trace_hex, "span_id" => "00f067aa0ba902b7"},
        "attributes" => %{
          "trace_id" => @trace_hex,
          "span_id" => "00f067aa0ba902b7",
          "parent_span_id" => "not-hex",
          "name" => "GET /graphql",
          "status" => "error",
          "status_message" => "boom"
        },
        "payload" => %{"span_attributes" => %{"http.route" => "/graphql"}}
      }

      projected = Disclosure.project(%{"event" => event, "redactions" => []}, %{}, :strict)
      attributes = projected["event"]["attributes"]
      assert attributes["status_message"] == nil
      assert attributes["parent_span_id"] == nil
      assert attributes["trace_id"] == @trace_hex
      assert attributes["name"] == "GET /graphql"
      assert projected["event"]["payload"] == nil

      paths = Enum.map(projected["redactions"], & &1["path"])
      assert ["key:attributes", "key:status_message"] in paths
      assert ["key:attributes", "key:parent_span_id"] in paths
      assert ["key:payload"] in paths

      rich = Disclosure.project(%{"event" => event, "redactions" => []}, %{}, :rich)
      assert rich["event"]["attributes"]["status_message"] == "boom"
    end
  end

  describe "Logger causality" do
    test "takes the SDK's otel ids when no trace_id metadata is set, and names the node" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{"components" => ["logger"], "logger_level" => "info"})

      on_exit(fn -> Live.stop(id) end)

      Task.await(
        Task.async(fn ->
          Logger.metadata(otel_trace_id: @trace_hex, otel_span_id: "00f067aa0ba902b7")
          Logger.warning("with otel context")
          Logger.metadata(otel_trace_id: "NOT-HEX", otel_span_id: "0000000000000000")
          Logger.warning("with malformed otel context")
          Logger.metadata(trace_id: "explicit", otel_trace_id: @trace_hex)
          Logger.warning("with explicit trace id")
        end)
      )

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})

      by_message =
        Map.new(batch["events"], &{&1["event"]["payload"]["message"], &1["event"]})

      assert by_message["with otel context"]["causality"]["trace_id"] == @trace_hex
      assert by_message["with otel context"]["causality"]["span_id"] == "00f067aa0ba902b7"
      assert by_message["with otel context"]["subject"]["scope"] == Atom.to_string(node())
      assert by_message["with malformed otel context"]["causality"]["trace_id"] == nil
      assert by_message["with malformed otel context"]["causality"]["span_id"] == nil
      assert by_message["with explicit trace id"]["causality"]["trace_id"] == "explicit"
    end
  end

  defp recorded_span_ids(recorder, cursor, acc) do
    {:ok, read} = Recorder.read_since(recorder, cursor, limit: 1_000, max_bytes: 16 * 1024 * 1024)
    ids = Enum.map(read.entries, & &1.event["attributes"]["span_id"])

    case read.entries do
      [] -> acc
      entries -> recorded_span_ids(recorder, List.last(entries).receipt, acc ++ ids)
    end
  end

  defp span_id(index),
    do: index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")

  defp span(overrides) do
    Map.merge(
      %{
        "trace_id" => @trace_hex,
        "span_id" => "00f067aa0ba902b7",
        "parent_span_id" => nil,
        "name" => "GET /graphql",
        "span_kind" => "server",
        "status" => "ok",
        "status_message" => nil,
        "service" => "frontend",
        "scope" => "next",
        "start_time_us" => 1_761_148_800_000_000,
        "duration_us" => 2_500,
        "attributes" => %{"http.route" => "/graphql"}
      },
      overrides
    )
  end

  defp options(overrides) do
    Keyword.merge(
      [
        authority: "test-policy",
        boot_id: "boot-test",
        clock_id: "clock-test",
        environment: :test,
        capture: false
      ],
      overrides
    )
  end

  defp start!(recorder, overrides) do
    assert {:ok, collector} = Otel.start_link(recorder, options(overrides))
    Process.unlink(collector)
    on_exit(fn -> stop_collector(collector) end)
    collector
  end

  # A collector with a backlog may not answer `stop/1` within its bound;
  # it is then killed, so the next test can register the name. Its trace
  # session goes with it.
  defp stop_collector(collector) do
    if Process.alive?(collector) do
      ref = Process.monitor(collector)

      case Otel.stop(collector) do
        {:ok, _cleanup} -> :ok
        {:error, _reason} -> Process.exit(collector, :kill)
      end

      receive do
        {:DOWN, ^ref, :process, ^collector, _reason} -> :ok
      after
        10_000 -> raise "the otel collector did not exit"
      end
    end
  end
end
