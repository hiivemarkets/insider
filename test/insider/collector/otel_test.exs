defmodule Insider.Collector.OtelTest do
  # The capture is one node-wide trace on the SDK's span-end function and the
  # collector has a registered name, so only one may run in this node.
  use ExUnit.Case, async: false

  alias Insider.Collector.Gate
  alias Insider.Collector.Otel
  alias Insider.Collector.Otel.Span
  alias Insider.Collector.Otel.Tracing
  alias Insider.Recorder
  alias Insider.Redaction.Policy, as: RedactionPolicy
  alias Insider.Test.Eventually
  alias Insider.Test.OtelSpans

  @trace 0x0AF7651916CD43DD8448EB211C80319C
  @trace_hex "0af7651916cd43dd8448eb211c80319c"

  describe "Span.event/2" do
    test "builds the otel.span event from a span map, with attributes only in rich" do
      span =
        span_map(%{"attributes" => %{"http.route" => "/graphql", "db.password" => "hunter2"}})

      assert {:ok, rich} = Span.event(span, context(rich: true))
      assert rich.source == "otel"
      assert rich.kind == "otel.span"
      assert rich.severity == :info
      assert rich.causality.trace_id == @trace_hex
      assert rich.causality.span_id == "00f067aa0ba902b7"

      assert rich.subject == %{
               "namespace" => "process",
               "scope" => "node@host",
               "value" => "<0.9.0>"
             }

      assert DateTime.to_unix(rich.wall_time, :microsecond) == 1_761_148_800_000_000 + 2_500

      assert rich.attributes == %{
               "trace_id" => @trace_hex,
               "span_id" => "00f067aa0ba902b7",
               "parent_span_id" => nil,
               "name" => "GET /graphql",
               "span_kind" => "server",
               "status" => "ok",
               "status_message" => nil,
               "service" => "my_app",
               "scope" => "opentelemetry_phoenix",
               "capture" => "sdk",
               "start_wall_time" => "2025-10-22T16:00:00.000000Z",
               "duration_us" => 2_500
             }

      assert rich.payload["span_attributes"]["http.route"] == "/graphql"
      assert rich.payload["span_attributes"]["db.password"] == "[REDACTED:credential_key]"

      assert {:ok, strict} = Span.event(span, context(rich: false))
      assert strict.payload == nil
      assert strict.attributes["name"] == "GET /graphql"
    end

    test "an error status is an error event and keeps its message only in rich" do
      span = span_map(%{"status" => "error", "status_message" => "token=abcdef boom"})

      assert {:ok, rich} = Span.event(span, context(rich: true))
      assert rich.severity == :error
      assert rich.attributes["status_message"] =~ "boom"
      refute rich.attributes["status_message"] =~ "abcdef"

      assert {:ok, strict} = Span.event(span, context(rich: false))
      assert strict.attributes["status_message"] == nil
    end

    test "an Absinthe span carries the operation's value-free outcome; GraphQL errors are errors" do
      errors = Jason.encode!([%{message: "price 0.01 too low", path: ["placeBuyOrder"]}])

      span =
        span_map(%{
          "name" => "mutation placeBuyOrder",
          "scope" => "opentelemetry_absinthe",
          "attributes" => %{
            :"graphql.operation.name" => "placeBuyOrder",
            :"graphql.operation.type" => :mutation,
            :"graphql.response.errors" => errors
          }
        })

      assert {:ok, event} = Span.event(span, context())
      assert event.severity == :error

      assert %{
               "operation_name" => "placeBuyOrder",
               "operation_type" => "mutation",
               "result" => "errors",
               "error_count" => 1,
               "error_paths" => ["placeBuyOrder"]
             } = event.attributes["graphql"]

      refute inspect(event) =~ "0.01"

      # A recorded result's payload is not read (no selections to trust it).
      payload = Jason.encode!(%{data: %{"placeBuyOrder" => %{"errors" => [%{"field" => "x"}]}}})

      assert {:ok, %{severity: :info, attributes: %{"graphql" => %{"result" => nil}}}} =
               Span.event(
                 put_in(span, ["attributes"], %{"graphql.response.result" => payload}),
                 context()
               )

      assert {:ok, plain} = Span.event(span_map(%{}), context())
      refute Map.has_key?(plain.attributes, "graphql")
    end

    test "refuses a span map outside the contract" do
      for {key, value} <- [
            {"trace_id", String.duplicate("0", 32)},
            {"trace_id", String.upcase(@trace_hex)},
            {"span_id", "xyz"},
            {"parent_span_id", "00"},
            {"name", ""},
            {"name", <<0xFF>>},
            {"span_kind", "sideways"},
            {"status", "fine"},
            {"start_time_us", -1},
            {"duration_us", -5},
            {"attributes", [:not_a_map]},
            {"pid", 42}
          ] do
        assert {:error, :invalid_span} ==
                 Span.event(Map.put(span_map(%{}), key, value), context()),
               "#{key} => #{inspect(value)}"
      end

      assert {:error, :invalid_span} == Span.event(:not_a_map, context())
    end

    test "cuts a long name at a character boundary" do
      span = span_map(%{"name" => String.duplicate("é", 200)})
      assert {:ok, event} = Span.event(span, context())
      assert byte_size(event.attributes["name"]) == 256
      assert String.valid?(event.attributes["name"])
    end

    test "decodes the SDK's ended span record" do
      record =
        OtelSpans.open(
          parent_span_id: 0x1234,
          name: :"my_app.repo.query",
          kind: :client,
          attributes: %{"db.statement": "select 1"},
          status: {:status, :error, "timeout"}
        )

      {ended, pid} = OtelSpans.end_in_process(record)

      assert {:ok, map} = Span.decode(ended, "my_app", pid)
      assert map["trace_id"] == @trace_hex
      assert map["parent_span_id"] == "0000000000001234"
      assert map["name"] == :"my_app.repo.query"
      assert map["span_kind"] == "client"
      assert map["status"] == "error"
      assert map["status_message"] == "timeout"
      assert map["scope"] == "opentelemetry_phoenix"
      assert map["attributes"] == %{"db.statement": "select 1"}
      assert map["pid"] == pid |> :erlang.pid_to_list() |> to_string()
      assert map["duration_us"] >= 0
      assert abs(map["start_time_us"] - System.os_time(:microsecond)) < 60_000_000

      assert {:ok, event} = Span.event(map, context())
      assert event.attributes["name"] == "my_app.repo.query"

      assert :error == Span.decode({:span, :not, :a, :span}, nil, nil)
    end

    test "decodes a record with unknown kind, status, scope, and attributes to their defaults" do
      # An end before the start is a zero duration, not a negative one.
      record =
        {:span, @trace, 0x00F067AA0BA902B7, :undefined, :undefined, false, "op", :sideways, 1_000,
         10, :no_attributes, [], [], :undefined, 1, false, :undefined}

      assert {:ok, map} = Span.decode(record, nil, nil)
      assert map["span_kind"] == "internal"
      assert {map["status"], map["status_message"]} == {"unset", nil}
      assert map["scope"] == nil
      assert map["attributes"] == %{}
      assert map["parent_span_id"] == nil
      assert map["duration_us"] == 0
      assert map["pid"] == nil

      # An empty error message is no message.
      assert {:ok, %{"status" => "error", "status_message" => nil}} =
               Span.decode(put_elem(record, 13, {:status, :error, ""}), nil, nil)

      assert {:ok, event} = Span.event(map, context())
      assert event.subject == nil
      assert event.attributes["span_kind"] == "internal"
    end

    test "accepts every kind and status it names, and only text names" do
      for kind <- Span.kinds(), status <- Span.statuses() do
        assert {:ok, event} =
                 Span.event(span_map(%{"span_kind" => kind, "status" => status}), context())

        assert {event.attributes["span_kind"], event.attributes["status"]} == {kind, status}
        assert event.severity == if(status == "error", do: :error, else: :info)
      end

      assert {:error, :invalid_span} == Span.event(span_map(%{"name" => 42}), context())
    end

    test "a context missing a field is an invalid span, not a crash" do
      context = Map.delete(context(), :authority)
      assert {:error, :invalid_span} == Span.event(span_map(%{}), context)
    end
  end

  # The capture needs isolated trace sessions (OTP 28+); OTP 27 refuses it.
  if :erlang.system_info(:otp_release) >= ~c"28" do
    describe "the collector" do
      setup do
        {recorder_pid, recorder} = recorder!()
        %{recorder: recorder, recorder_pid: recorder_pid}
      end

      test "records every span the SDK ends, without the SDK running", %{recorder: recorder} do
        collector = start!(recorder, rich: true)

        root = OtelSpans.open(attributes: %{"http.method" => "GET"})
        child = OtelSpans.open(span_id: 0x22, parent_span_id: 0x00F067AA0BA902B7, name: "query")
        {_ended, child_pid} = OtelSpans.end_in_process(child)
        {_ended, root_pid} = OtelSpans.end_in_process(root)

        assert {:ok, status} = Otel.flush(collector)
        assert status.received == 2
        assert status.recorded == 2
        assert status.installed == 1

        assert [child_event, root_event] = events(recorder)
        assert child_event["attributes"]["parent_span_id"] == "00f067aa0ba902b7"
        assert child_event["subject"]["value"] == pid_text(child_pid)
        assert root_event["subject"]["value"] == pid_text(root_pid)
        assert root_event["payload"]["span_attributes"] == %{"http.method" => "GET"}
        assert root_event["attributes"]["capture"] == "sdk"
      end

      test "stopping removes the capture and leaves the SDK's function untraced",
           %{recorder: recorder} do
        collector = start!(recorder)
        {_ended, _pid} = OtelSpans.end_in_process(OtelSpans.open([]))

        assert {:ok, cleanup} = Otel.stop(collector)
        assert cleanup.trace == "removed"
        refute Process.alive?(collector)

        assert {:traced, false} == :erlang.trace_info(Tracing.traced_function(), :traced)
        {_ended, _pid} = OtelSpans.end_in_process(OtelSpans.open(span_id: 0x99))
        assert [_one] = events(recorder)
      end

      test "a collector that exits removes its capture", %{recorder: recorder} do
        collector = start!(recorder)
        ref = Process.monitor(collector)
        Process.exit(collector, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^collector, _reason}, 5_000

        # A new capture can be installed, so the old one is gone.
        collector = start!(recorder)
        assert {:ok, %{trace: "removed"}} = Otel.stop(collector)
      end

      test "only one collector runs at a time", %{recorder: recorder} do
        _collector = start!(recorder)
        assert {:error, :already_started} = Otel.start_link(recorder, options())
      end

      test "sheds spans above the waiting bound and counts them", %{recorder: recorder} do
        collector = start!(recorder, max_waiting: 1)
        # The valve pauses the capture within a millisecond of more than one
        # span waiting, and spans that end while it is paused are not
        # observed. On a slow runner that cut the count to 3. This test is
        # about the shed count, so the valve is held, and the test resumes
        # the collector only when all five spans are in its queue.
        valve = :sys.get_state(collector).valve
        true = :erlang.suspend_process(valve)
        :ok = :sys.suspend(collector)

        for id <- 1..5, do: OtelSpans.end_in_process(OtelSpans.open(span_id: id))

        Eventually.await(
          fn -> Process.info(collector, :message_queue_len) >= {:message_queue_len, 5} end,
          5_000,
          "five span trace messages did not reach the collector"
        )

        :ok = :sys.resume(collector)
        true = :erlang.resume_process(valve)
        assert {:ok, status} = Otel.flush(collector)
        assert status.received == 5
        assert status.shed >= 3
        assert status.recorded + status.shed == 5
        assert length(events(recorder)) == status.recorded
      end

      test "the gate drops spans below the minimum duration unless they failed",
           %{recorder: recorder} do
        gate = Gate.new(gate_spec(%{min_duration_ms: 50}))
        on_exit(fn -> Gate.delete(gate) end)
        collector = start!(recorder, gate: gate)

        start = :erlang.monotonic_time()
        short = System.convert_time_unit(1, :millisecond, :native)
        long = System.convert_time_unit(80, :millisecond, :native)
        OtelSpans.end_in_process(OtelSpans.open(span_id: 1, start_time: start), start + short)
        OtelSpans.end_in_process(OtelSpans.open(span_id: 2, start_time: start), start + long)

        OtelSpans.end_in_process(
          OtelSpans.open(span_id: 3, start_time: start, status: {:status, :error, ""}),
          start + short
        )

        assert {:ok, %{recorded: 2}} = Otel.flush(collector)

        assert Enum.map(events(recorder), & &1["attributes"]["span_id"]) == [
                 "0000000000000002",
                 "0000000000000003"
               ]

        assert Gate.counts(gate)[{"otel", "min_duration"}] == 1
        assert Gate.counts(gate)[{"otel", "origin"}] == 0
      end

      test "the gate drops spans ended by an excluded origin", %{recorder: recorder} do
        gate =
          Gate.new(
            gate_spec(%{min_duration_ms: 0})
            |> Map.put(:origin, %{oban_conf: false, modules: %{__MODULE__ => true}})
          )

        on_exit(fn -> Gate.delete(gate) end)
        collector = start!(recorder, gate: gate)
        test = self()

        excluded =
          :proc_lib.spawn(fn ->
            receive do
              :end ->
                :otel_span_utils.end_span(OtelSpans.open(span_id: 7), :undefined)
                send(test, :ended)
                receive do: (:exit -> :ok)
            end
          end)

        # proc_lib records a fun's defining module (this test) as the
        # initial call; Task records the helper's.
        send(excluded, :end)
        assert_receive :ended, 5000
        OtelSpans.end_in_process(OtelSpans.open(span_id: 8))

        assert {:ok, %{recorded: 1}} = Otel.flush(collector)
        send(excluded, :exit)
        assert [%{"attributes" => %{"span_id" => "0000000000000008"}}] = events(recorder)
        assert Gate.counts(gate)[{"otel", "origin"}] == 1
      end

      test "ingests span maps with the same build and accounting", %{recorder: recorder} do
        collector = start!(recorder, rich: true)
        valid = span_map(%{"pid" => "<0.1.0>"})

        assert {:ok, counts} = Otel.ingest([valid, %{"trace_id" => "bad"}, :not_a_map])

        assert counts == %{
                 "accepted" => 1,
                 "rejected" => 2,
                 "filtered" => 0,
                 "shed" => 0,
                 "duplicate" => 0
               }

        assert [event] = events(recorder)
        assert event["attributes"]["capture"] == "ingest"
        # An ingested span has no process in this node.
        assert event["subject"] == nil

        assert {:ok, %{ingested: 3, invalid: 2}} = Otel.status(collector)

        assert {:error, :invalid_options} =
                 Otel.ingest(List.duplicate(valid, Otel.ingest_max() + 1))

        assert {:error, :invalid_options} = Otel.ingest(:spans)
      end

      # A caller's timeout must never hide recorded
      # spans, so a call the collector takes after its deadline is refused
      # before any counter or span changes.
      test "a call taken after its deadline records and counts nothing", %{recorder: recorder} do
        collector = start!(recorder, rich: true)
        {:ok, before} = Otel.status(collector)
        past = System.monotonic_time(:millisecond) - 1

        assert {:error, :timeout} = Otel.ingest([span_map(%{})], past)
        assert {:ok, ^before} = Otel.status(collector)
        assert events(recorder) == []

        # Held past its deadline, the call times out for its caller, and the
        # collector refuses it once it catches up.
        :ok = :sys.suspend(collector)
        soon = System.monotonic_time(:millisecond) + 50
        assert {:error, :timeout} = Otel.ingest([span_map(%{})], soon)
        :ok = :sys.resume(collector)

        assert {:ok, ^before} = Otel.status(collector)
        assert events(recorder) == []

        assert {:ok, %{"accepted" => 1}} =
                 Otel.ingest([span_map(%{})], System.monotonic_time(:millisecond) + 1_000)
      end

      test "ingest without a running collector is not_running" do
        assert {:error, :not_running} = Otel.ingest([span_map(%{})])
      end

      test "refuses malformed options and environments", %{recorder: recorder} do
        assert {:error, :invalid_options} = Otel.start_link(recorder, [])
        assert {:error, :invalid_options} = Otel.start_link(recorder, options(rich: :yes))
        assert {:error, :invalid_options} = Otel.start_link(recorder, options(max_waiting: 0))
        assert {:error, :invalid_options} = Otel.start_link(recorder, options(gate: :gate))
        assert {:error, :invalid_options} = Otel.start_link(:recorder, options())

        assert {:error, :environment_denied} =
                 Otel.start_link(recorder, Keyword.put(options(), :environment, :production))
      end

      test "another tracer, even of the span-end function, does not conflict", %{
        recorder: recorder
      } do
        traced = spawn(fn -> receive do: (:stop -> :ok) end)
        tracer = spawn(fn -> receive do: (:stop -> :ok) end)
        on_exit(fn -> Enum.each([traced, tracer], &send(&1, :stop)) end)
        1 = :erlang.trace(traced, true, [:send, {:tracer, tracer}])
        true = Tracing.sdk_present?()
        session = :trace.session_create(:other, tracer, [])
        1 = :trace.function(session, Tracing.traced_function(), true, [:global])

        try do
          assert :ok = Tracing.preflight()
          collector = start!(recorder)
          OtelSpans.end_in_process(OtelSpans.open([]))
          assert {:ok, %{recorded: 1}} = Otel.flush(collector)
          assert {:ok, %{trace: "removed"}} = Otel.stop(collector)
          # The other tracers keep what they set.
          assert {:tracer, ^tracer} = :erlang.trace_info(traced, :tracer)
          assert {:traced, :global} = :trace.info(session, Tracing.traced_function(), :traced)
        after
          :trace.session_destroy(session)
          :erlang.trace(traced, false, [:send])
        end
      end

      test "a flush stops draining at its deadline however many spans wait behind its marker",
           %{recorder: recorder} do
        collector = start!(recorder, max_waiting: 100_000_000, rich: true)
        :ok = :sys.suspend(collector)

        # The flush call is first in the mailbox, then 40,000 rich spans, so
        # its drain (whose delivery marker follows them) has more to process
        # than its one-second budget allows.
        flush = Task.async(fn -> :timer.tc(fn -> Otel.flush(collector) end) end)
        wait_queued(collector, 1)
        attributes = Map.new(1..20, &{"attribute.#{&1}", String.duplicate("v", 100)})

        for id <- 1..40_000,
            do: OtelSpans.end_in_current(OtelSpans.open(span_id: id, attributes: attributes))

        :ok = :sys.resume(collector)
        {elapsed_us, result} = Task.await(flush, 5_000)

        assert {:ok, status} = result
        assert status.pending > 0
        assert status.received < 40_000
        assert elapsed_us < 1_900_000
      end

      test "a stop with a backlog it cannot drain in time counts every span it abandons",
           %{recorder: recorder} do
        collector = start!(recorder, max_waiting: 100_000_000, rich: true)
        :ok = :sys.suspend(collector)

        # The stop call is first in the mailbox, then 40,000 rich spans: more
        # than its drain builds within its deadline.
        stop = Task.async(fn -> :timer.tc(fn -> Otel.stop(collector) end) end)
        wait_queued(collector, 1)
        attributes = Map.new(1..20, &{"attribute.#{&1}", String.duplicate("v", 100)})

        for id <- 1..40_000,
            do: OtelSpans.end_in_current(OtelSpans.open(span_id: id, attributes: attributes))

        :ok = :sys.resume(collector)
        {elapsed_us, result} = Task.await(stop, 10_000)

        assert {:ok, %{trace: "removed", status: status}} = result
        assert status.abandoned > 0
        assert status.drain_incomplete == 0
        # Every span that ended is received (built or shed) or abandoned.
        assert status.received + status.abandoned == 40_000
        assert elapsed_us < 3_400_000
      end

      test "a seal whose drain runs out of time reports the abandoned spans in the public batch" do
        {:ok, host_policy} = Insider.Runtime.HostPolicy.new(host_protected_targets: [self()])

        {:ok, handle} =
          Insider.Collector.Session.start(host_policy,
            id: "otel-seal-backlog",
            environment: :test,
            authority: "otel-test",
            boot_id: "boot-test",
            clock_id: "otel-clock",
            recorder_options: [classification: Insider.TestRecorderClassification.binding()],
            components: [:otel],
            otel_options: [max_waiting: 100_000_000, rich: true]
          )

        on_exit(fn -> Insider.Collector.Session.stop(handle) end)
        :ok = :sys.suspend(Otel)

        # The seal's stop call reaches the collector first, then the backlog.
        seal = Task.async(fn -> Insider.Collector.Session.seal_ingress(handle, 5_000) end)
        wait_queued(Process.whereis(Otel), 1)
        attributes = Map.new(1..20, &{"attribute.#{&1}", String.duplicate("v", 100)})

        for id <- 1..40_000,
            do: OtelSpans.end_in_current(OtelSpans.open(span_id: id, attributes: attributes))

        :ok = :sys.resume(Otel)
        assert {:ok, %{"components" => %{"otel" => "absent"}}} = Task.await(seal, 10_000)

        assert {:ok, read} = Insider.Collector.Session.read_events(handle, 0, limit: 100)

        assert %{"evidence" => "bounded_status", "abandoned" => abandoned, "received" => received} =
                 read["otel"]

        assert abandoned > 0
        assert received + abandoned == 40_000

        {batch, _counters} = Insider.Live.Batch.build("live-x", read, nil, %{})

        assert %{"reason" => "otel_abandoned", "count" => ^abandoned} =
                 Enum.find(batch["gaps"], &(&1["reason"] == "otel_abandoned"))
      end

      test "a terminal count that reaches its deadline stops and reports accounting unavailable" do
        {:ok, host_policy} = Insider.Runtime.HostPolicy.new(host_protected_targets: [self()])

        {:ok, handle} =
          Insider.Collector.Session.start(host_policy,
            id: "otel-seal-count-deadline",
            environment: :test,
            authority: "otel-test",
            boot_id: "boot-test",
            clock_id: "otel-clock",
            recorder_options: [classification: Insider.TestRecorderClassification.binding()],
            components: [:otel],
            otel_options: [max_waiting: 100_000_000, rich: true]
          )

        on_exit(fn -> Insider.Collector.Session.stop(handle) end)
        collector = Process.whereis(Otel)
        :ok = :sys.suspend(collector)

        seal = Task.async(fn -> Insider.Collector.Session.seal_ingress(handle, 5_000) end)
        wait_queued(collector, 1)
        attributes = Map.new(1..20, &{"attribute.#{&1}", String.duplicate("v", 100)})

        for id <- 1..40_000,
            do: OtelSpans.end_in_current(OtelSpans.open(span_id: id, attributes: attributes))

        # When the count starts, hold the collector past the count's
        # half-second deadline while spans are still queued.
        1 = :erlang.trace_pattern({Otel, :abandon_until, 3}, true, [:local])
        1 = :erlang.trace(collector, true, [:call, {:tracer, self()}])

        on_exit(fn ->
          :erlang.trace_pattern({Otel, :abandon_until, 3}, false, [:local])
        end)

        :ok = :sys.resume(collector)
        assert_receive {:trace, ^collector, :call, {Otel, :abandon_until, _}}, 5_000
        true = :erlang.suspend_process(collector)
        {:message_queue_len, held} = Process.info(collector, :message_queue_len)
        :erlang.trace(collector, false, [:call])
        Process.sleep(700)
        true = :erlang.resume_process(collector)

        assert {:ok, %{"components" => %{"otel" => "absent"}}} = Task.await(seal, 10_000)
        refute Process.alive?(collector)
        assert held > 1_000

        # The rest was neither counted nor built, so the sealed accounting
        # is unavailable rather than an exact abandoned count.
        assert {:ok, read} = Insider.Collector.Session.read_events(handle, 0, limit: 100)
        {batch, _counters} = Insider.Live.Batch.build("live-x", read, nil, %{})

        assert %{"reason" => "otel_accounting_unavailable", "count" => nil} =
                 Enum.find(batch["gaps"], &(&1["reason"] == "otel_accounting_unavailable"))

        refute Enum.any?(batch["gaps"], &(&1["reason"] == "otel_abandoned"))
      end

      test "without a pause every span that ended is received, and no loss is reported", %{
        recorder: recorder
      } do
        collector = start!(recorder, max_waiting: 100_000_000)

        workers =
          for worker <- 1..8 do
            Task.async(fn ->
              for id <- 1..1_000,
                  do: OtelSpans.end_in_current(OtelSpans.open(span_id: worker * 10_000 + id))
            end)
          end

        # Flushes while spans are still ending. The capture is unbounded
        # here (no pause), so a flush call can wait behind more spans than
        # the collector processes within the call's bound; it then returns
        # `{:error, :unavailable}` after that bound (a timeout), never sooner.
        flushes = for _ <- 1..20, do: :timer.tc(fn -> Otel.flush(collector) end)
        Enum.each(workers, &Task.await(&1, 30_000))

        for {elapsed_us, flush} <- flushes do
          case flush do
            {:ok, info} -> assert info.pauses == 0
            {:error, :unavailable} -> assert elapsed_us >= 1_900_000
          end
        end

        assert Process.alive?(collector)

        status = settled(collector)
        assert status.received == 8_000
        assert status.pauses == 0
        assert status.recorded + status.recorder_dropped + status.shed == 8_000
      end

      test "unpaced concurrent overload is paused, reported, and shed at receipt",
           %{recorder: recorder} do
        collector = start!(recorder, max_waiting: 100)
        :ok = :sys.suspend(collector)

        workers =
          for worker <- 1..8 do
            Task.async(fn ->
              for id <- 1..10_000,
                  do: OtelSpans.end_in_current(OtelSpans.open(span_id: worker * 100_000 + id))
            end)
          end

        Enum.each(workers, &Task.await(&1, 30_000))
        {:message_queue_len, waiting} = Process.info(collector, :message_queue_len)
        :ok = :sys.resume(collector)
        status = settled(collector)

        # The valve paused delivery at some point (how many spans queued
        # first is a measurement of the soft bound, not a contract), fewer
        # than the 80,000 that ended were received, and the pause is
        # reported.
        assert status.pauses > 0, "#{waiting} spans queued before the first pause"
        assert status.received < 80_000
        # Once the queue is drained the valve resumes at one of its next
        # ticks (later under load).
        assert resumed?(collector, 5_000)
        assert status.recorded + status.recorder_dropped + status.shed == status.received
        assert status.shed > 0
      end

      test "every read and batch overlapping one long pause reports it, ongoing while it lasts" do
        on_exit(fn ->
          case Insider.Live.capabilities()["active_session_id"] do
            nil -> :ok
            active -> Insider.Live.stop(active)
          end
        end)

        assert {:ok, %{"session_id" => id}} = Insider.Live.start(%{"components" => ["otel"]})
        assert {:ok, _subscription} = Insider.Live.subscribe(id, self(), %{"cursor" => "latest"})

        # Overload pauses the capture; holding the valve keeps it paused
        # while the collector drains and several reads happen.
        :ok = :sys.suspend(Otel)
        for span <- 1..2_000, do: OtelSpans.end_in_current(OtelSpans.open(span_id: span))
        wait_paused()
        valve = :sys.get_state(Otel).valve
        true = :erlang.suspend_process(valve)
        :ok = :sys.resume(Otel)

        paused = fn batch ->
          Enum.filter(batch["gaps"], &(&1["reason"] in ["otel_paused", "otel_paused_ongoing"]))
        end

        assert {:ok, first} = Insider.Live.events_since(id, 0, %{"limit" => 500})
        assert [%{"reason" => "otel_paused_ongoing", "count" => nil}] = paused.(first)

        # Spans ending now are not observed; the next read still says so,
        # with no new pause start.
        for span <- 1..10, do: OtelSpans.end_in_current(OtelSpans.open(span_id: 10_000 + span))

        assert {:ok, second} =
                 Insider.Live.events_since(id, first["next_cursor"], %{"limit" => 500})

        assert [%{"reason" => "otel_paused_ongoing", "count" => nil}] = paused.(second)
        assert {:ok, %{pauses: 1, paused: 1}} = Otel.status(Otel)

        # A subscriber's batch during the pause says so too.
        assert_receive {:insider_live_events, ^id, pushed}, 2_000
        assert [%{"reason" => "otel_paused_ongoing"}] = paused.(pushed)

        # The read whose interval contains the resumption reports the pause.
        true = :erlang.resume_process(valve)
        wait_resumed()

        assert {:ok, third} =
                 Insider.Live.events_since(id, second["next_cursor"], %{"limit" => 500})

        assert [%{"reason" => "otel_paused", "count" => nil}] = paused.(third)

        # A read entirely after the pause reports nothing.
        assert {:ok, fourth} =
                 Insider.Live.events_since(id, third["next_cursor"], %{"limit" => 500})

        assert paused.(fourth) == []
        assert {:ok, _record} = Insider.Live.stop(id)
      end

      # `paused` is a state, not a count.
      # A pause ongoing at an amendment's seal ends with that collector; the
      # next segment's own pause is reported as ongoing on every read while it
      # lasts, and a stopped session reports the past pauses, never an ongoing
      # one.
      test "a pause across an amendment is reported as the current segment's state" do
        on_exit(fn ->
          case Insider.Live.capabilities()["active_session_id"] do
            nil -> :ok
            active -> Insider.Live.stop(active, %{"force" => true})
          end
        end)

        paused = fn batch ->
          for %{"reason" => reason} <- batch["gaps"],
              reason in ["otel_paused", "otel_paused_ongoing"],
              do: reason
        end

        hold_paused = fn first_span ->
          :ok = :sys.suspend(Otel)

          for span <- first_span..(first_span + 1_999),
              do: OtelSpans.end_in_current(OtelSpans.open(span_id: span))

          wait_paused()
          valve = :sys.get_state(Otel).valve
          true = :erlang.suspend_process(valve)
          :ok = :sys.resume(Otel)
          valve
        end

        assert {:ok, %{"session_id" => id}} = Insider.Live.start(%{"components" => ["otel"]})
        _first_valve = hold_paused.(1)

        # Amended while paused: the seal removes that capture, ending its pause.
        assert {:ok, %{"amendment" => %{"applied" => true}}} =
                 Insider.Live.amend(id, %{"max_events" => 4_096})

        assert {:ok, %{paused: 0}} = Otel.status(Otel)
        valve = hold_paused.(100_000)
        assert {:ok, %{paused: 1}} = Otel.status(Otel)

        all = %{"limit" => 500, "max_bytes" => 1_048_576}
        assert {:ok, first} = Insider.Live.events_since(id, 0, all)
        assert paused.(first) == ["otel_paused_ongoing"]

        # Every later read while the new pause lasts says so, not only the first.
        assert {:ok, second} = Insider.Live.events_since(id, first["next_cursor"], all)
        assert paused.(second) == ["otel_paused_ongoing"]
        assert {:ok, third} = Insider.Live.events_since(id, second["next_cursor"], all)
        assert paused.(third) == ["otel_paused_ongoing"]

        true = :erlang.resume_process(valve)
        wait_resumed()
        assert {:ok, fourth} = Insider.Live.events_since(id, third["next_cursor"], all)
        assert paused.(fourth) == ["otel_paused"]
        assert {:ok, fifth} = Insider.Live.events_since(id, fourth["next_cursor"], all)
        assert paused.(fifth) == []

        # A stopped session's capture is gone: its pauses are past, none
        # ongoing. A cursor issued after both pauses ended reports neither.
        assert {:ok, %{"state" => "stopped"}} = Insider.Live.stop(id, %{"force" => true})
        assert {:ok, stopped} = Insider.Live.events_since(id, 0, all)
        assert paused.(stopped) == ["otel_paused"]
        assert {:ok, after_pauses} = Insider.Live.events_since(id, fifth["next_cursor"], all)
        assert paused.(after_pauses) == []
      end

      test "a session without pauses reports no paused loss, and one with a pause does" do
        on_exit(fn ->
          case Insider.Live.capabilities()["active_session_id"] do
            nil -> :ok
            active -> Insider.Live.stop(active)
          end
        end)

        assert {:ok, %{"session_id" => id}} = Insider.Live.start(%{"components" => ["otel"]})

        workers =
          for worker <- 1..4 do
            Task.async(fn ->
              # 800 spans in all: fewer than the 1,024 that pause it.
              for id <- 1..200,
                  do: OtelSpans.end_in_current(OtelSpans.open(span_id: worker * 10_000 + id))
            end)
          end

        Enum.each(workers, &Task.await(&1, 30_000))
        assert {:ok, first} = Insider.Live.events_since(id, 0, %{"limit" => 1})
        assert {:ok, again} = Insider.Live.events_since(id, first["next_cursor"], %{"limit" => 1})

        paused = fn batch -> Enum.filter(batch["gaps"], &(&1["reason"] == "otel_paused")) end

        # Nothing paused: no paused gap now or after the rest arrived.
        assert paused.(first) == []
        assert paused.(again) == []
        assert {:ok, _record} = Insider.Live.stop(id)

        # The Live session's collector pauses above 1,024 waiting spans.
        assert {:ok, %{"session_id" => id}} = Insider.Live.start(%{"components" => ["otel"]})
        :ok = :sys.suspend(Otel)

        for id <- 1..5_000, do: OtelSpans.end_in_current(OtelSpans.open(span_id: id))

        wait_paused()
        :ok = :sys.resume(Otel)
        assert {:ok, batch} = Insider.Live.events_since(id, 0, %{"limit" => 1})
        assert {:ok, _record} = Insider.Live.stop(id)

        # Under load the valve may not have resumed yet: the pause is then
        # reported as ongoing.
        assert [%{"reason" => reason, "count" => nil, "scope" => "since_session_start"}] =
                 Enum.filter(
                   batch["gaps"],
                   &(&1["reason"] in ["otel_paused", "otel_paused_ongoing"])
                 )

        assert reason in ["otel_paused", "otel_paused_ongoing"]
      end

      test "stopping leaves no process traced and ignores other traced calls", %{
        recorder: recorder
      } do
        collector = start!(recorder)
        # A trace message for another function never becomes an event.
        send(collector, {:trace, self(), :return_from, {:lists, :reverse, 1}, [1]})
        OtelSpans.end_in_process(OtelSpans.open([]))
        assert {:ok, %{received: 1, invalid: 0, recorded: 1}} = Otel.flush(collector)
        assert {:ok, %{trace: "removed"}} = Otel.stop(collector)

        assert {:tracer, []} = :erlang.trace_info(:new, :tracer)
        assert {:flags, []} = :erlang.trace_info(self(), :flags)
      end
    end
  else
    describe "on OTP 27" do
      test "the capture and the otel component are refused" do
        {:ok, policy} =
          RedactionPolicy.new(id: "otel-redaction", maximum_sensitivity: :internal, rules: [])

        {:ok, pid} = Recorder.start_link(classification: {:internal, policy}, max_events: 64)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        {:ok, recorder} = Recorder.handle(pid)

        assert {:error, :requires_otp_28} = Tracing.preflight()
        assert {:error, :requires_otp_28} = Otel.start_link(recorder, options())

        assert {:error,
                %{
                  "code" => "component_unavailable",
                  "component" => "otel",
                  "reason" => "requires_otp_28"
                }} =
                 Insider.Live.start(%{"components" => ["otel"]})
      end
    end
  end

  test "reports the SDK's presence and service name" do
    assert Tracing.sdk_present?()
    refute Tracing.sdk_running?()
    # Without a running tracer provider there is no resource.
    assert Tracing.service_name() == nil
    assert Tracing.remove(nil) == "not_installed"
    refute Tracing.installed?(nil)
  end

  defp span_map(overrides) do
    Map.merge(
      %{
        "trace_id" => @trace_hex,
        "span_id" => "00f067aa0ba902b7",
        "parent_span_id" => nil,
        "name" => "GET /graphql",
        "span_kind" => "server",
        "status" => "ok",
        "status_message" => nil,
        "service" => "my_app",
        "scope" => "opentelemetry_phoenix",
        "start_time_us" => 1_761_148_800_000_000,
        "duration_us" => 2_500,
        "attributes" => %{},
        "pid" => "<0.9.0>"
      },
      overrides
    )
  end

  defp context(overrides \\ []) do
    Map.merge(
      %{
        node: "node@host",
        boot_id: "boot-test",
        clock_id: "clock-test",
        authority: "test-policy",
        source_instance_id: "otel-test",
        sequence: 1,
        rich: false,
        capture: "sdk"
      },
      Map.new(overrides)
    )
  end

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        authority: "test-policy",
        boot_id: "boot-test",
        clock_id: "clock-test",
        environment: :test,
        source_instance_id: "otel-test"
      ],
      overrides
    )
  end

  defp start!(recorder, overrides \\ []) do
    assert {:ok, collector} = Otel.start_link(recorder, options(overrides))
    Process.unlink(collector)

    on_exit(fn -> stop_collector(collector) end)

    collector
  end

  defp gate_spec(otel) do
    %{logger: nil, origin: nil, telemetry: [], summary_interval_ms: 10_000, otel: otel}
  end

  defp recorder! do
    {:ok, policy} =
      RedactionPolicy.new(id: "otel-redaction", maximum_sensitivity: :internal, rules: [])

    {:ok, pid} =
      Recorder.start_link(classification: {:internal, policy}, max_events: 64, post_trigger_ms: 0)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, handle} = Recorder.handle(pid)
    {pid, handle}
  end

  defp events(recorder) do
    {:ok, read} = Recorder.read_since(recorder, 0)
    Enum.map(read.entries, & &1.event)
  end

  defp pid_text(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  # Silences an unused-variable warning for @trace in the record helper.
  _ = @trace

  # Flushes until a flush finds nothing more: one drains for at most a
  # second, and trace messages reach the mailbox after their span ended.
  # A flush that waited behind a backlog longer than its bound is
  # `:unavailable`; the backlog is drained by then, so the next one answers.
  defp settled(collector, previous \\ nil, timeouts \\ 0) do
    case Otel.flush(collector) do
      {:ok, status} ->
        counts = {status.received, status.pauses}

        if status.pending == 0 and counts == previous,
          do: status,
          else: settled(collector, counts, timeouts)

      {:error, :unavailable} when timeouts < 5 ->
        settled(collector, previous, timeouts + 1)
    end
  end

  defp wait_paused do
    st = :sys.get_state(Otel)

    if :atomics.get(st.valve_state, 2) == 1 do
      :ok
    else
      Process.sleep(1)
      wait_paused()
    end
  end

  defp wait_resumed(tries \\ 3_000) do
    st = :sys.get_state(Otel)

    cond do
      :atomics.get(st.valve_state, 2) == 0 ->
        :ok

      tries == 0 ->
        flunk(
          inspect(
            {Process.info(Process.whereis(Otel), :message_queue_len),
             Process.info(st.valve, [:status, :current_stacktrace, :message_queue_len]),
             Insider.Collector.Otel.Tracing.resume(st.backend)}
          )
        )

      true ->
        Process.sleep(1)
        wait_resumed(tries - 1)
    end
  end

  defp wait_queued(pid, count) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queued} when queued >= count ->
        :ok

      _fewer ->
        Process.sleep(1)
        wait_queued(pid, count)
    end
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

  defp resumed?(collector, budget_ms) do
    case Otel.status(collector) do
      {:ok, %{paused: 0}} ->
        true

      _paused when budget_ms > 0 ->
        Process.sleep(10)
        resumed?(collector, budget_ms - 10)

      _paused ->
        false
    end
  end
end
