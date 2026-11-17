defmodule Insider.Collector.TelemetryTest do
  # Telemetry handler registration and the real fixture event names are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.Telemetry, as: TelemetryCollector
  alias Insider.Collector.Telemetry.Handler
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Event
  alias Insider.Fixtures
  alias Insider.Recorder
  alias Insider.Redaction.Policy, as: RedactionPolicy

  @start [:insider, :fixture, :operation, :start]
  @stop [:insider, :fixture, :operation, :stop]
  @exception [:insider, :fixture, :operation, :exception]
  @handler_failure [:telemetry, :handler, :failure]
  @max_sequence 9_223_372_036_854_775_807

  setup do
    handler_id = "insider-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{handler_id: handler_id}
  end

  test "collects only allowlisted fields and preserves explicit OpenTelemetry correlation",
       context do
    {recorder, collector, redaction_policy} = start_pipeline(context.handler_id)

    :telemetry.execute(
      @start,
      %{duration: 0, secret_measurement: "card-number"},
      %{
        run_id: "operation-1",
        trace_id: <<1::128>>,
        span_id: <<2::64>>,
        component: :checkout,
        password: :must_not_be_recorded
      }
    )

    :telemetry.execute(
      @stop,
      %{duration: 42.5, secret_measurement: "card-number"},
      %{
        run_id: "operation-1",
        trace_id: <<1::128>>,
        span_id: <<2::64>>,
        component: :checkout,
        password: :must_not_be_recorded
      }
    )

    :telemetry.execute(
      [:insider, :fixture, :operation, :not_allowlisted],
      %{duration: 99},
      %{run_id: "ignored", password: :ignored_sensitive_value}
    )

    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.received == 2
    assert status.recorded == 2
    assert status.lifecycle_started == 1
    assert status.lifecycle_completed == 1
    assert status.open_lifecycles == 0

    snapshot = freeze!(recorder, "allowlist-trigger")

    assert [started, stopped] =
             Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))

    assert Enum.map([started, stopped], & &1.event.kind) == [
             "telemetry.operation.start",
             "telemetry.operation.stop"
           ]

    assert started.event.causality.logical_operation_id == "operation-1"

    assert started.event.subject == %{
             "namespace" => "process",
             "scope" => Atom.to_string(node()),
             "value" => self() |> :erlang.pid_to_list() |> to_string()
           }

    assert started.event.causality.trace_id == String.pad_leading("1", 32, "0")
    assert started.event.causality.span_id == String.pad_leading("2", 16, "0")
    assert started.event.attributes["metadata"] == %{"component" => "checkout"}
    assert stopped.event.attributes["measurements"] == %{"duration" => "42.5"}

    refute inspect(started.event.attributes) =~ "password"
    refute inspect(started.event.attributes) =~ "must_not_be_recorded"
    refute inspect(stopped.event.attributes) =~ "secret_measurement"
    refute inspect(stopped.event.attributes) =~ "card-number"
    assert started.event.payload == nil

    assert Enum.all?([started, stopped], fn entry ->
             entry.classification.policy_fingerprint == redaction_policy.fingerprint and
               entry.classification.sensitivity == :internal
           end)
  end

  test "real faulty and healthy fixtures expose incomplete and paired lifecycle evidence",
       context do
    {recorder, collector, _policy} = start_pipeline(context.handler_id)

    faulty = Fixtures.run!(:telemetry_lifecycle, :faulty)
    healthy = Fixtures.run!(:telemetry_lifecycle, :healthy)
    assert faulty.variant == :faulty
    assert healthy.variant == :healthy

    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.lifecycle_started == 2
    assert status.lifecycle_completed == 1
    assert status.lifecycle_terminals == 1
    assert status.open_lifecycles == 1
    assert status.unmatched_completions == 0

    snapshot = freeze!(recorder, "lifecycle-trigger")
    events = Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))
    assert Enum.count(events, &(&1.event.attributes["lifecycle_phase"] == "start")) == 2
    assert Enum.count(events, &(&1.event.attributes["lifecycle_phase"] == "stop")) == 1

    faulty_id = Integer.to_string(faulty.run_id)

    assert Enum.count(events, &(&1.event.causality.logical_operation_id == faulty_id)) == 1
  end

  test "OpenTelemetry IDs require exact nonzero lowercase encodings", context do
    {recorder, collector, _policy} = start_pipeline(context.handler_id)

    :telemetry.execute(
      @start,
      %{},
      %{
        run_id: "invalid-otel",
        trace_id: <<0::128>>,
        span_id: 11
      }
    )

    :telemetry.execute(
      @start,
      %{},
      %{
        run_id: "wrong-width-otel",
        trace_id: "ABCDEF0123456789ABCDEF0123456789",
        span_id: <<1::56>>
      }
    )

    assert {:ok, _status} = TelemetryCollector.flush(collector)
    snapshot = freeze!(recorder, "invalid-otel-trigger")
    entries = Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))

    assert Enum.map(entries, & &1.event.causality.logical_operation_id) == [
             "invalid-otel",
             "wrong-width-otel"
           ]

    assert Enum.all?(entries, &is_nil(&1.event.causality.trace_id))
    assert Enum.all?(entries, &is_nil(&1.event.causality.span_id))
  end

  test "bounded scalar projection preserves Event v1 and exact correlation forms", context do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "scalar-projection",
        events: [
          [
            name: @start,
            kind: "telemetry.scalar.event",
            lifecycle: "scalar",
            phase: :event
          ]
        ],
        measurements: [
          nil_value: "nil_value",
          bool_value: "bool_value",
          atom_value: "atom_value",
          binary_value: "binary_value",
          float_value: "float_value",
          complex_value: "complex_value"
        ],
        correlation: [
          logical_operation_id: :run_id,
          parent_event_id: :parent_id,
          process_generation: :generation,
          trace_id: :trace_id,
          span_id: :span_id
        ]
      )

    {_recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:ok, collector} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               environment: :test,
               handler_id: context.handler_id
             )

    Process.unlink(collector)

    :telemetry.execute(
      @start,
      %{
        nil_value: nil,
        bool_value: true,
        atom_value: :ready,
        binary_value: "bounded",
        float_value: 1.25,
        complex_value: %{not: "portable"}
      },
      %{
        run_id: 7,
        parent_id: "parent",
        generation: 9,
        trace_id: "0000000000000000000000000000000a",
        span_id: <<11::64>>
      }
    )

    assert {:ok, %{recorded: 1}} = TelemetryCollector.flush(collector)
    snapshot = freeze!(recorder, "scalar-trigger")
    [entry] = Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))

    assert entry.event.attributes["measurements"] == %{
             "atom_value" => "ready",
             "binary_value" => "bounded",
             "bool_value" => true,
             "float_value" => "1.25",
             "nil_value" => nil
           }

    assert entry.event.causality == %{
             logical_operation_id: "7",
             parent_event_id: "parent",
             process_generation: "9",
             trace_id: "0000000000000000000000000000000a",
             span_id: "000000000000000b"
           }
  end

  test "fixed inbox sheds synchronously without queueing work in the emitter", context do
    {_recorder, collector, _policy} =
      start_pipeline(context.handler_id,
        inbox_size: 1,
        batch_size: 1,
        drain_interval_ms: 1_000
      )

    for sequence <- 1..100 do
      :telemetry.execute(@start, %{duration: sequence}, %{run_id: "load-#{sequence}"})
    end

    assert {:ok, status} = TelemetryCollector.status(collector)
    assert status.received == 100
    assert status.enqueued == 1
    assert status.shed == 99
    assert status.inbox_count == 1
    assert {:message_queue_len, count} = Process.info(self(), :message_queue_len)
    assert count == 0
  end

  test "handler failures are swallowed counted and do not detach the live handler", context do
    {_recorder, collector, _policy} = start_pipeline(context.handler_id)
    config = collector |> :sys.get_state() |> Map.fetch!(:handler_config)

    assert :ok = Handler.handle_event(@start, %{}, :not_a_map, config)
    assert :ok = Handler.handle_event(@start, %{}, %{}, %{config | events: :hostile})

    assert {:ok, status} = TelemetryCollector.status(collector)
    assert status.invalid == 1
    assert status.handler_failures == 1
    assert owned_handler?(context.handler_id, config)

    assert :ok = :telemetry.execute(@start, %{duration: 1}, %{run_id: "still-alive"})
    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.recorded == 1
  end

  test "upstream handler failure is opt-in evidence without unsafe diagnostic terms", context do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "telemetry-handler-failure",
        events: [
          [
            name: @handler_failure,
            kind: "telemetry.handler.failure",
            lifecycle: "handler_failure",
            phase: :event
          ]
        ],
        metadata: [
          kind: "caller_requested_kind",
          handler_config: "unsafe_config",
          handler_id: "unsafe_handler_id",
          reason: "unsafe_reason",
          stacktrace: "unsafe_stacktrace"
        ],
        correlation: [logical_operation_id: :reason]
      )

    {recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:ok, collector} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               environment: :test,
               handler_id: context.handler_id,
               source_instance_id: "telemetry-failure-test"
             )

    Process.unlink(collector)
    failing_id = context.handler_id <> "-upstream-failure"
    secret = "failure-secret-sentinel"
    on_exit(fn -> :telemetry.detach(failing_id) end)

    assert :ok =
             :telemetry.attach(
               failing_id,
               [:insider, :telemetry_test, :will_fail],
               &__MODULE__.failing_handler/4,
               secret
             )

    log =
      capture_log(fn ->
        :telemetry.execute([:insider, :telemetry_test, :will_fail], %{}, %{secret: secret})
      end)

    refute log =~ secret
    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.recorded == 1

    snapshot = freeze!(recorder, "handler-failure-trigger")
    [entry] = Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))
    assert entry.event.kind == "telemetry.handler.failure"
    assert entry.event.attributes["metadata"] == %{"failure_kind" => "error"}
    refute inspect(entry.event) =~ secret
    refute inspect(entry.event) =~ "handler_config"
    refute inspect(entry.event) =~ "stacktrace"
    refute inspect(entry.event) =~ "reason"

    assert {:ok, _cleanup} = TelemetryCollector.stop(collector)
    if Process.alive?(recorder_pid), do: GenServer.stop(recorder_pid)
  end

  test "live and unrelated handlers are never replaced or detached", context do
    {_recorder, collector, _policy} = start_pipeline(context.handler_id)
    handler_id = context.handler_id
    original = Process.monitor(collector)
    rows_before = Enum.count(:telemetry.list_handlers([]), &(&1.id == handler_id))

    assert {:error, {:already_exists, ^handler_id}} =
             start_pipeline_result(context.handler_id)

    assert Process.alive?(collector)
    refute_receive {:DOWN, ^original, :process, ^collector, _reason}
    assert Enum.count(:telemetry.list_handlers([]), &(&1.id == handler_id)) == rows_before

    assert :ok = :telemetry.detach(context.handler_id)
    unrelated = &__MODULE__.unrelated_handler/4

    assert :ok =
             :telemetry.attach_many(context.handler_id, [@start, @stop], unrelated, :unrelated)

    assert {:ok, cleanup} = TelemetryCollector.stop(collector)
    assert cleanup.handler == :not_owned

    assert Enum.any?(:telemetry.list_handlers([]), fn handler ->
             handler.id == context.handler_id and handler.function == unrelated and
               handler.config == :unrelated
           end)
  end

  test "dead-owner handlers are reclaimed and explicit stop drains and detaches", context do
    {_recorder, collector, _policy} = start_pipeline(context.handler_id)
    Process.unlink(collector)
    monitor = Process.monitor(collector)
    Process.exit(collector, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :killed}, 1_000

    {_replacement_recorder, replacement, _policy} =
      start_pipeline(context.handler_id, drain_interval_ms: 1_000)

    :telemetry.execute(@start, %{duration: 1}, %{run_id: "cleanup-open"})

    assert {:ok, cleanup} = TelemetryCollector.stop(replacement)
    assert cleanup.handler == :removed
    assert cleanup.drained == 1
    assert cleanup.open_lifecycles == 1
    refute Enum.any?(:telemetry.list_handlers([]), &(&1.id == context.handler_id))
  end

  test "atomic start link prevents an orphan when the starting process exits", context do
    policy = telemetry_policy!()
    {_recorder_pid, recorder, _redaction_policy} = recorder!()
    parent = self()

    starter =
      spawn(fn ->
        result =
          TelemetryCollector.start_link(recorder, policy,
            authority: "test-policy",
            boot_id: "boot-test",
            clock_id: "telemetry-order",
            environment: :test,
            handler_id: context.handler_id,
            drain_interval_ms: 1_000
          )

        send(parent, {:starter_result, self(), result})

        receive do
          :exit_shutdown -> exit(:shutdown)
        end
      end)

    starter_monitor = Process.monitor(starter)
    assert_receive {:starter_result, ^starter, {:ok, collector}}, 1_000
    collector_monitor = Process.monitor(collector)
    assert Enum.any?(:telemetry.list_handlers([]), &(&1.id == context.handler_id))
    lock_holder = hold_startup_lock(context.handler_id)
    lock_monitor = Process.monitor(lock_holder)

    send(starter, :exit_shutdown)
    assert_receive {:DOWN, ^starter_monitor, :process, ^starter, :shutdown}, 1_000
    assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :shutdown}, 1_000
    refute Enum.any?(:telemetry.list_handlers([]), &(&1.id == context.handler_id))

    send(lock_holder, :release)
    assert_receive {:DOWN, ^lock_monitor, :process, ^lock_holder, :normal}, 1_000
  end

  test "tuple startup drains scheduled work and treats upstream detachment as normal", context do
    policy = telemetry_policy!()
    {_recorder_pid, recorder, _redaction_policy} = recorder!()

    options = [
      authority: "test-policy",
      boot_id: "boot-test",
      clock_id: "telemetry-order",
      environment: :test,
      handler_id: context.handler_id,
      drain_interval_ms: 1_000
    ]

    assert {:ok, collector} = TelemetryCollector.start_link({recorder, policy, options})
    Process.unlink(collector)
    :telemetry.execute(@start, %{}, %{run_id: "scheduled"})

    {_timer_ref, token} = collector |> :sys.get_state() |> Map.fetch!(:drain_token)
    send(collector, {:drain, token})
    assert {:ok, %{recorded: 1, inbox_count: 0}} = TelemetryCollector.status(collector)

    assert :ok = :telemetry.detach(context.handler_id)
    assert {:ok, %{handler: :already_detached}} = TelemetryCollector.stop(collector)
    assert {:error, :unavailable} = TelemetryCollector.status(collector)
  end

  test "recorder loss is counted without escaping into the emitting process", context do
    policy = telemetry_policy!()
    {recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:ok, collector} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               environment: :test,
               handler_id: context.handler_id,
               drain_interval_ms: 1_000
             )

    Process.unlink(collector)
    GenServer.stop(recorder_pid)

    assert :ok = :telemetry.execute(@start, %{}, %{run_id: "recorder-gone"})
    assert {:ok, %{recorded: 0, recorder_dropped: 1}} = TelemetryCollector.flush(collector)
  end

  test "policy and collector options reject hostile or ambiguous bounds", context do
    long_options = Enum.map(1..10_000, &{:unknown, &1})
    long_events = List.duplicate(event_rule(@start, :start), 10_000)
    improper_options = [{:id, "improper"}, {:events, []} | :improper]
    improper_events = [event_rule(@start, :start) | :improper]

    assert {:error, :invalid_policy} = TelemetryPolicy.new(long_options)
    assert {:error, :invalid_policy} = TelemetryPolicy.new(improper_options)

    assert {:error, :invalid_policy} =
             TelemetryPolicy.new(id: "improper-events", events: improper_events)

    assert {:error, :invalid_policy} = TelemetryPolicy.new(id: "long-events", events: long_events)
    assert {:error, :invalid_policy} = TelemetryPolicy.new(%{id: "not-keyword"})
    refute TelemetryPolicy.valid?(:not_a_policy)
    assert {:error, :invalid_options} = TelemetryCollector.start_link(:not_arguments)
    assert {:error, :invalid_options} = TelemetryCollector.start_link(:bad, :bad, [])
    assert :ok = Handler.handle_event(@start, %{}, %{}, %{})
    assert {:error, :invalid_policy} = TelemetryPolicy.new(id: "empty", events: [])

    assert {:error, :invalid_policy} =
             TelemetryPolicy.new(
               id: "bad-kind",
               events: [
                 [
                   name: @start,
                   kind: "Not Event Vocabulary",
                   lifecycle: "operation",
                   phase: :event
                 ]
               ]
             )

    assert {:error, :invalid_policy} =
             TelemetryPolicy.new(
               id: "missing-lifecycle-correlation",
               events: [event_rule(@start, :start)]
             )

    assert {:error, :invalid_policy} =
             TelemetryPolicy.new(
               id: "failure-wrong-phase",
               events: [
                 [
                   name: @handler_failure,
                   kind: "telemetry.handler.failure",
                   lifecycle: "failure",
                   phase: :start
                 ]
               ],
               correlation: [logical_operation_id: :run_id]
             )

    assert {:error, :invalid_policy} =
             TelemetryPolicy.new(
               id: "duplicate",
               events: [event_rule(@start, :start), event_rule(@start, :stop)]
             )

    policy = telemetry_policy!()
    refute TelemetryPolicy.valid?(%{policy | fingerprint: "forged"})

    large_events = Map.new(1..1_000, &{{&1}, %{}})
    refute TelemetryPolicy.valid?(%{policy | events: large_events})
    refute TelemetryPolicy.valid?(%{policy | event_names: List.duplicate(@start, 1_000)})
    {_recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:error, :invalid_options} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               handler_id: context.handler_id,
               inbox_size: 0
             )

    assert {:error, :invalid_options} = TelemetryCollector.start_link(recorder, policy, [])

    assert {:error, :invalid_options} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               handler_id: context.handler_id,
               source_instance_id: String.duplicate("s", 115)
             )

    assert {:error, :invalid_options} =
             TelemetryCollector.start_link(
               recorder,
               policy,
               List.duplicate({:authority, "duplicate"}, 10_000)
             )

    assert {:error, :invalid_options} =
             TelemetryCollector.start_link(recorder, policy, [{:authority, "improper"} | :tail])
  end

  test "alternate configured lifecycle key pairs and terminal events", context do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "alternate-lifecycle-key",
        events: [event_rule(@start, :start), event_rule(@exception, :exception)],
        correlation: [logical_operation_id: :workflow_ref]
      )

    {_recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:ok, collector} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               environment: :test,
               handler_id: context.handler_id
             )

    Process.unlink(collector)
    :telemetry.execute(@start, %{}, %{workflow_ref: "workflow-1", run_id: "ignored"})
    :telemetry.execute(@exception, %{}, %{workflow_ref: "workflow-1", run_id: "ignored"})

    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.lifecycle_started == 1
    assert status.lifecycle_completed == 1
    assert status.lifecycle_terminals == 1
    assert status.lifecycle_missing_starts == 0
    assert status.lifecycle_missing_terminals == 0
    assert status.open_lifecycles == 0

    snapshot = freeze!(recorder, "alternate-lifecycle-trigger")
    terminal = Enum.find(snapshot.events, &(&1.event.kind == "telemetry.operation.exception"))
    assert terminal.event.causality.logical_operation_id == "workflow-1"
    assert terminal.event.severity == :error
  end

  test "dotted event segments have unambiguous canonical ordering" do
    left = [name: [:a, :b], kind: "telemetry.a_b", lifecycle: "event", phase: :event]
    right = [name: [:"a.b"], kind: "telemetry.a_dot_b", lifecycle: "event", phase: :event]

    assert {:ok, first} = TelemetryPolicy.new(id: "dotted", events: [left, right])
    assert {:ok, second} = TelemetryPolicy.new(id: "dotted", events: [right, left])
    assert first == second
    assert first.fingerprint == second.fingerprint
    assert TelemetryPolicy.valid?(first)
    assert first.event_names == [[:a, :b], [:"a.b"]]
  end

  test "boundary source instance IDs record first and maximum supported sequence", context do
    source_instance_id = String.duplicate("s", 114)

    {first_recorder, first, _policy} =
      start_pipeline(context.handler_id, source_instance_id: source_instance_id)

    :telemetry.execute(@start, %{}, %{run_id: "first"})
    assert {:ok, %{recorded: 1}} = TelemetryCollector.flush(first)
    first_snapshot = freeze!(first_recorder, "first-boundary-trigger")
    first_event = Enum.find(first_snapshot.events, &(&1.event.source == "telemetry"))
    assert first_event.event.source_sequence == 1

    maximum_handler = context.handler_id <> "-maximum"
    on_exit(fn -> :telemetry.detach(maximum_handler) end)

    {maximum_recorder, maximum, _policy} =
      start_pipeline(maximum_handler, source_instance_id: source_instance_id)

    config = maximum |> :sys.get_state() |> Map.fetch!(:handler_config)
    :ok = :atomics.put(config.sequence, 1, @max_sequence - 1)
    :telemetry.execute(@start, %{}, %{run_id: "maximum"})

    assert {:ok, %{recorded: 1}} = TelemetryCollector.flush(maximum)
    maximum_snapshot = freeze!(maximum_recorder, "maximum-boundary-trigger")
    maximum_event = Enum.find(maximum_snapshot.events, &(&1.event.source == "telemetry"))
    assert maximum_event.event.source_sequence == @max_sequence
    assert byte_size(maximum_event.event.id) == 128
  end

  test "lifecycle state has explicit capacity expiry and gap accounting", context do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "bounded-lifecycle",
        events: [event_rule(@start, :start), event_rule(@stop, :stop)],
        correlation: [logical_operation_id: :run_id],
        max_open_lifecycles: 1,
        max_lifecycle_age_events: 2
      )

    {_recorder_pid, recorder, _redaction_policy} = recorder!()

    assert {:ok, collector} =
             TelemetryCollector.start_link(recorder, policy,
               authority: "test-policy",
               boot_id: "boot-test",
               clock_id: "telemetry-order",
               environment: :test,
               handler_id: context.handler_id,
               drain_interval_ms: 1_000
             )

    Process.unlink(collector)
    :telemetry.execute(@start, %{}, %{run_id: "first"})
    :telemetry.execute(@start, %{}, %{run_id: "first"})
    :telemetry.execute(@start, %{}, %{run_id: "second"})
    :telemetry.execute(@stop, %{}, %{run_id: "second"})
    :telemetry.execute(@start, %{}, %{run_id: "third"})
    :telemetry.execute(@start, %{}, %{})

    assert {:ok, status} = TelemetryCollector.flush(collector)
    assert status.lifecycle_started == 2
    assert status.lifecycle_duplicate_starts == 1
    assert status.lifecycle_tracking_shed == 1
    assert status.unmatched_completions == 1
    assert status.lifecycle_missing_starts == 1
    assert status.lifecycle_expired == 1
    assert status.lifecycle_missing_terminals == 1
    assert status.lifecycle_terminals == 1
    assert status.lifecycle_missing_correlation == 1
    assert status.open_lifecycles == 1
  end

  @doc false
  def unrelated_handler(_event_name, _measurements, _metadata, _config), do: :ok

  @doc false
  def failing_handler(_event_name, _measurements, _metadata, _config),
    do: raise("expected telemetry handler failure")

  defp start_pipeline(handler_id, options \\ []) do
    case start_pipeline_result(handler_id, options) do
      {:ok, result} -> result
      {:error, reason} -> flunk("pipeline failed: #{inspect(reason)}")
    end
  end

  defp start_pipeline_result(handler_id, options \\ []) do
    policy = telemetry_policy!()
    {recorder_pid, recorder, redaction_policy} = recorder!()

    collector_options =
      Keyword.merge(
        [
          authority: "test-policy",
          boot_id: "boot-test",
          clock_id: "telemetry-order",
          environment: :test,
          handler_id: handler_id,
          source_instance_id: "telemetry-test"
        ],
        options
      )

    case TelemetryCollector.start_link(recorder, policy, collector_options) do
      {:ok, collector} ->
        Process.unlink(collector)
        on_exit(fn -> if Process.alive?(collector), do: TelemetryCollector.stop(collector) end)
        {:ok, {recorder, collector, redaction_policy}}

      {:error, reason} ->
        GenServer.stop(recorder_pid)
        {:error, reason}
    end
  end

  defp recorder! do
    redaction_policy = redaction_policy!()

    {:ok, recorder_pid} =
      Recorder.start_link(
        classification: {:internal, redaction_policy},
        max_events: 256,
        post_trigger_ms: 0
      )

    Process.unlink(recorder_pid)
    on_exit(fn -> if Process.alive?(recorder_pid), do: GenServer.stop(recorder_pid) end)
    {:ok, recorder} = Recorder.handle(recorder_pid)
    {recorder_pid, recorder, redaction_policy}
  end

  defp redaction_policy! do
    {:ok, policy} =
      RedactionPolicy.new(
        id: "telemetry-redaction",
        maximum_sensitivity: :internal,
        rules: []
      )

    policy
  end

  defp telemetry_policy! do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "fixture-telemetry",
        events: [
          event_rule(@start, :start),
          event_rule(@stop, :stop),
          event_rule(@exception, :exception)
        ],
        metadata: [component: "component"],
        measurements: [duration: "duration"],
        correlation: [
          logical_operation_id: :run_id,
          trace_id: :trace_id,
          span_id: :span_id
        ]
      )

    policy
  end

  defp event_rule(name, phase) do
    [
      name: name,
      kind: "telemetry.operation.#{phase}",
      lifecycle: "operation",
      phase: phase
    ]
  end

  defp freeze!(recorder, id) do
    assert {:ok, _freeze_id} = Recorder.freeze(recorder, trigger(id))
    assert {:ok, snapshot} = Recorder.snapshot(recorder)
    snapshot
  end

  defp trigger(id) do
    Event.new!(
      id: id,
      node: "node-test",
      boot_id: "boot-test",
      source: "fixture",
      kind: "invariant_failed",
      severity: :error,
      monotonic_time: 1,
      clock_id: "clock-test",
      source_instance_id: "fixture-test",
      source_sequence: 1,
      wall_time: nil,
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{},
      payload: nil,
      authority: "test-policy",
      redactions: [],
      extensions: %{}
    )
  end

  defp owned_handler?(handler_id, config) do
    Enum.all?([@start, @stop, @exception], fn event_name ->
      Enum.any?(:telemetry.list_handlers(event_name), fn handler ->
        handler.id == handler_id and handler.function == (&Handler.handle_event/4) and
          handler.config == config
      end)
    end)
  end

  defp hold_startup_lock(handler_id) do
    parent = self()

    holder =
      spawn(fn ->
        lock = {{TelemetryCollector, handler_id, node()}, self()}
        true = :global.set_lock(lock, [node()], 0)
        send(parent, {:startup_lock_held, self()})

        receive do
          :release -> :ok
        end

        true = :global.del_lock(lock, [node()])
      end)

    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)
    assert_receive {:startup_lock_held, ^holder}, 1_000
    holder
  end
end
