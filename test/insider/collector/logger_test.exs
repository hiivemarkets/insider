defmodule Insider.Collector.LoggerTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Logger.Handler
  alias Insider.Collector.Logger.Shape
  alias Insider.Collector.IngressProfile
  alias Insider.Detectors.RestartRecurrence
  alias Insider.Event
  alias Insider.Event.Value
  alias Insider.Recorder
  alias Insider.Test.Eventually

  @handler :insider_logger_test

  setup do
    _result = :logger.remove_primary_filter(@handler)
    on_exit(fn -> :logger.remove_primary_filter(@handler) end)
    :ok
  end

  test "shape projection bounds hostile scalar, key, width, and UTF-8 inputs" do
    assert Shape.encode(true)
    assert Shape.encode(%URI{}) == %{"type" => "term"}

    projected_keys = Shape.encode(%{<<255>> => :binary, {:tuple} => :other})
    assert projected_keys["$binary_key"] == "binary"

    assert Enum.any?(projected_keys, fn {key, value} ->
             key =~ "$other_key_" and value == "other"
           end)

    assert byte_size(Shape.encode(String.duplicate("x", 300))) == 256
    assert Shape.encode(:binary.copy(<<255>>, 300)) == %{"type" => "binary", "bytes" => 300}
    assert List.last(Shape.encode(Enum.to_list(1..40))) == %{"type" => "truncated"}
  end

  test "captures structured OTP crash and supervisor reports before formatting" do
    {recorder, collector} = start_pipeline()

    config = handler_config(collector)

    Handler.log(
      %{
        level: :error,
        msg:
          {:report,
           %{label: {:proc_lib, :crash}, report: %{reason: :boom, neighbours: [:not_copied]}}},
        meta: %{domain: [:otp], pid: self(), trace_id: "trace-1"}
      },
      config
    )

    Handler.log(
      %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:supervisor, :child_terminated},
             report: %{
               supervisor: {:local, self()},
               errorContext: :child_terminated,
               offender: %{id: :worker, pid: self(), restart_type: :permanent},
               reason: :boom
             }
           }},
        meta: %{domain: [:otp, :sasl], pid: self()}
      },
      config
    )

    assert {:ok, %{recorded: recorded}} = LoggerCollector.flush(collector)
    assert recorded >= 2

    trigger = event("trigger", "invariant_failed")
    assert {:ok, _freeze_id} = Recorder.freeze(recorder, trigger)
    assert {:ok, snapshot} = Recorder.snapshot(recorder)

    logger_events =
      Enum.filter(snapshot.events, fn entry ->
        entry.event.kind in ["process_crashed", "supervisor_child_terminated"]
      end)

    assert Enum.map(logger_events, & &1.event.kind) == [
             "process_crashed",
             "supervisor_child_terminated"
           ]

    assert hd(logger_events).event.causality.trace_id == "trace-1"
    assert Enum.all?(logger_events, &(&1.priority == :protected))
    assert Enum.all?(logger_events, &(&1.event.payload["type"] == "tuple"))

    supervisor_event = List.last(logger_events).event
    assert supervisor_event.attributes["offender_id"] == "atom:worker"

    assert supervisor_event.attributes["offender_pid"] ==
             self() |> :erlang.pid_to_list() |> to_string()

    assert supervisor_event.attributes["restart_type"] == "permanent"
    assert supervisor_event.attributes["reason_class"] == "abnormal"
  end

  test "can omit Logger message payload while retaining semantic attributes" do
    {recorder, collector} = start_pipeline(include_payload: false)
    config = handler_config(collector)

    Handler.log(
      %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:supervisor, :child_terminated},
             report: %{
               supervisor: {:local, self()},
               errorContext: :child_terminated,
               offender: %{id: :worker, pid: self(), restart_type: :permanent},
               reason: {:secret_reason, "must-not-be-retained"}
             }
           }},
        meta: %{domain: [:otp, :sasl], pid: self()}
      },
      config
    )

    assert {:ok, %{recorded: recorded}} = LoggerCollector.flush(collector)
    assert recorded >= 1

    assert {:ok, _freeze_id} =
             Recorder.freeze(recorder, event("trigger-omit", "invariant_failed"))

    assert {:ok, snapshot} = Recorder.snapshot(recorder)

    logger_event =
      Enum.find(snapshot.events, &(&1.event.kind == "supervisor_child_terminated")).event

    assert logger_event.payload == nil
    assert logger_event.attributes["offender_id"] == "atom:worker"
    assert logger_event.attributes["reason_class"] == "abnormal"
  end

  test "production ingress settings derived from the denied profile retain only structural Logger evidence" do
    {_recorder, collector} = start_pipeline()
    config = handler_config(collector)
    assert {:ok, profile} = IngressProfile.new(:production)
    assert {:ok, settings} = LoggerCollector.profile_settings(profile)

    assert settings == %{
             include_message_semantics: false,
             include_payload: false,
             structural_only: true
           }

    isolated_inbox = :ets.new(__MODULE__, [:set])
    isolated_stats = :counters.new(9, [:atomics])
    isolated_sequence = :atomics.new(1, [])

    secret_id = "offender-secret-#{System.unique_integer([:positive])}"
    secret_reason = "reason-secret-#{System.unique_integer([:positive])}"
    secret_causality = "causality-secret-#{System.unique_integer([:positive])}"
    secret_metadata = "metadata-secret-#{System.unique_integer([:positive])}"

    Handler.log(
      %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:supervisor, :child_terminated},
             report: %{
               supervisor: :safe_supervisor,
               offender: %{id: secret_id, pid: self(), restart_type: :permanent},
               reason: {:failure, secret_reason}
             }
           }},
        meta: %{
          domain: [:otp, :sasl],
          logical_operation_id: secret_causality,
          pid: self(),
          time: System.system_time(:microsecond),
          untrusted_metadata: secret_metadata
        }
      },
      %{
        config
        | config:
            config.config
            |> Map.merge(settings)
            |> Map.merge(%{
              inbox: isolated_inbox,
              sequence: isolated_sequence,
              stats: isolated_stats
            })
      }
    )

    assert [{0, 1, logger_event}] = :ets.tab2list(isolated_inbox)

    assert logger_event.payload == nil
    assert logger_event.kind == "logger_structural"
    assert logger_event.attributes["message_semantics"] == "suppressed"

    assert logger_event.attributes == %{
             "ingress_profile" => "logger_structural/v1",
             "message_semantics" => "suppressed"
           }

    assert logger_event.subject == nil
    assert logger_event.wall_time == nil

    assert logger_event.causality == %{
             logical_operation_id: nil,
             parent_event_id: nil,
             process_generation: nil,
             span_id: nil,
             trace_id: nil
           }

    refute Map.has_key?(logger_event.attributes, "offender_id")
    refute Map.has_key?(logger_event.attributes, "reason_fingerprint")
    refute inspect(logger_event) =~ secret_id
    refute inspect(logger_event) =~ secret_reason
    refute inspect(logger_event) =~ secret_causality
    refute inspect(logger_event) =~ secret_metadata

    assert :counters.get(isolated_stats, 7) == 1
    assert :counters.get(isolated_stats, 8) == 1
    assert :counters.get(isolated_stats, 9) == 5

    zero_stats = :counters.new(9, [:atomics])

    Handler.log(
      %{level: :info, msg: {:string, "suppressed"}, meta: %{}},
      %{
        config
        | config:
            config.config
            |> Map.merge(settings)
            |> Map.merge(%{
              inbox: :ets.new(__MODULE__, [:set]),
              sequence: :atomics.new(1, []),
              stats: zero_stats
            })
      }
    )

    assert :counters.get(zero_stats, 9) == 0
  end

  test "normalizes bounded map and keyword supervisor variants without trusting malformed fields" do
    {recorder, collector} = start_pipeline()
    config = handler_config(collector)

    reports = [
      %{
        supervisor: "named-supervisor",
        errorContext: :child_terminated,
        offender: %{id: 42, pid: :not_a_pid, restart_type: "not-an-atom"},
        reason: :normal
      },
      [
        supervisor: {:local, self()},
        errorContext: :child_terminated,
        offender: [id: "worker", pid: self(), restart_type: :transient],
        reason: :shutdown
      ],
      [
        supervisor: {:local, self()},
        errorContext: :child_terminated,
        offender: [id: :worker, pid: self(), restart_type: :permanent],
        reason: {:shutdown, :planned}
      ],
      [:unrelated | :improper],
      %{
        supervisor: :oversized_control,
        errorContext: :child_terminated,
        offender: %{
          id: String.duplicate("é", 129),
          pid: self(),
          restart_type: :permanent
        },
        reason: :boom
      }
    ]

    Enum.each(reports, fn report ->
      Handler.log(
        %{
          level: :error,
          msg: {:report, %{label: {:supervisor, :child_terminated}, report: report}},
          meta: %{domain: [:otp, :sasl], pid: self()}
        },
        config
      )
    end)

    Handler.log(
      %{
        level: :error,
        msg: {:report, %{label: {:supervisor, :child_terminated}, report: hd(reports)}},
        meta: %{domain: [:application], pid: self()}
      },
      config
    )

    assert {:ok, %{recorded: recorded}} = LoggerCollector.flush(collector)
    assert recorded >= 6

    assert {:ok, _freeze_id} =
             Recorder.freeze(recorder, event("shape-trigger", "invariant_failed"))

    assert {:ok, snapshot} = Recorder.snapshot(recorder)

    events =
      Enum.filter(snapshot.events, &(&1.event.kind == "supervisor_child_terminated"))
      |> Enum.map(& &1.event.attributes)

    assert [mapped, keyword, shutdown_tuple, malformed, oversized] = events
    assert mapped["supervisor"] == "binary:named-supervisor"
    assert mapped["offender_id"] == "integer:42"
    assert mapped["reason_class"] == "normal"
    refute Map.has_key?(mapped, "offender_pid")
    refute Map.has_key?(mapped, "restart_type")
    assert keyword["reason_class"] == "shutdown"
    assert keyword["restart_type"] == "transient"
    assert keyword["offender_id"] == "binary:worker"
    assert shutdown_tuple["reason_class"] == "shutdown"
    assert shutdown_tuple["offender_id"] == "atom:worker"
    assert malformed["label"] == "supervisor.child_terminated"
    refute Map.has_key?(malformed, "reason_class")
    refute Map.has_key?(oversized, "offender_id")

    assert Enum.any?(snapshot.events, fn entry ->
             entry.event.kind == "logger_report" and
               entry.event.attributes["label"] == "supervisor.child_terminated" and
               not Map.has_key?(entry.event.attributes, "semantic_projection")
           end)
  end

  test "the installed primary filter captures a native report before downstream translation" do
    {recorder, collector} = start_pipeline()
    {:ok, before} = LoggerCollector.status(collector)

    :logger.log(
      :error,
      %{label: {:insider_test, :structured}, report: %{reason: :boom, worker: self()}},
      %{domain: [:otp], pid: self()}
    )

    assert {:ok, status} = LoggerCollector.flush(collector)
    assert status.recorded > before.recorded

    assert {:ok, _freeze_id} =
             Recorder.freeze(recorder, event("native-trigger", "invariant_failed"))

    assert {:ok, snapshot} = Recorder.snapshot(recorder)

    assert Enum.any?(snapshot.events, fn entry ->
             entry.event.kind == "otp_report" and
               entry.event.attributes["label"] == "insider_test.structured"
           end)
  end

  test "flush replies only after an in-flight Recorder admission completes" do
    {clock, arm_clock, release_clock, gate_ref} = controlled_clock(self())

    {recorder, collector} =
      start_pipeline(drain_interval_ms: 1_000, recorder_options: [clock: clock])

    config = handler_config(collector)
    assert {:ok, %{recorded: recorded_before, inbox_count: 0}} = LoggerCollector.flush(collector)

    assert :ok =
             Handler.log(
               %{level: :info, msg: {:string, "barrier"}, meta: %{domain: [:application]}},
               config
             )

    state = :sys.get_state(collector)
    assert :ets.info(state.inbox, :size) == 1
    arm_clock.()
    on_exit(fn -> release_clock.(collector) end)

    flush_task = Task.async(fn -> LoggerCollector.flush(collector) end)
    task_ref = flush_task.ref
    assert_receive {:recorder_admission_started, ^collector, ^gate_ref}, 1_000
    refute_received {^task_ref, _result}
    assert {:error, :busy} = Recorder.snapshot(recorder)

    release_clock.(collector)

    assert {:ok, %{recorded: recorded_after, inbox_count: 0}} =
             Task.await(flush_task, 1_000)

    assert recorded_after == recorded_before + 1

    assert {:ok, _freeze_id} =
             Recorder.freeze(recorder, event("barrier-trigger", "invariant_failed"))

    assert {:ok, snapshot} = Recorder.snapshot(recorder)
    assert Enum.any?(snapshot.events, &(&1.event.source == "logger"))
  end

  test "structured restart reports yield recurrence evidence while a quiet control stays quiet" do
    {healthy_recorder, healthy_collector} =
      start_pipeline(handler_id: :insider_logger_healthy_test)

    on_exit(fn -> :logger.remove_primary_filter(:insider_logger_healthy_test) end)
    assert {:ok, _status} = LoggerCollector.flush(healthy_collector)

    assert {:ok, _freeze_id} =
             Recorder.freeze(healthy_recorder, event("healthy-trigger", "invariant_failed"))

    assert {:ok, healthy_snapshot} = Recorder.snapshot(healthy_recorder)

    refute Enum.any?(healthy_snapshot.events, fn entry ->
             entry.event.source == "logger" and
               entry.event.kind in ["process_crashed", "supervisor_child_terminated"]
           end)

    {faulty_recorder, faulty_collector} = start_pipeline(handler_id: :insider_logger_faulty_test)
    on_exit(fn -> :logger.remove_primary_filter(:insider_logger_faulty_test) end)
    workers = for _ <- 1..3, do: spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> Enum.each(workers, &send(&1, :stop)) end)

    Handler.log(
      %{
        level: :error,
        msg: {:report, %{label: {:proc_lib, :crash}, report: %{reason: :fixture_crash}}},
        meta: %{domain: [:otp], pid: hd(workers)}
      },
      handler_config(faulty_collector)
    )

    Enum.each(workers, fn worker ->
      Handler.log(
        %{
          level: :error,
          msg:
            {:report,
             %{
               label: {:supervisor, :child_terminated},
               report: %{
                 supervisor: {:local, __MODULE__},
                 errorContext: :child_terminated,
                 offender: %{id: :worker, pid: worker, restart_type: :permanent},
                 reason: :fixture_crash
               }
             }},
          meta: %{domain: [:otp, :sasl], pid: worker}
        },
        handler_config(faulty_collector)
      )
    end)

    assert {:ok, %{recorded: recorded}} = LoggerCollector.flush(faulty_collector)
    assert recorded > 0

    assert {:ok, _freeze_id} =
             Recorder.freeze(faulty_recorder, event("faulty-trigger", "invariant_failed"))

    assert {:ok, faulty_snapshot} = Recorder.snapshot(faulty_recorder)
    kinds = Enum.map(faulty_snapshot.events, & &1.event.kind)
    assert "process_crashed" in kinds
    assert "supervisor_child_terminated" in kinds

    supervisor_events =
      Enum.filter(faulty_snapshot.events, &(&1.event.kind == "supervisor_child_terminated"))

    assert [_, _, _] = supervisor_events

    assert Enum.uniq(Enum.map(supervisor_events, & &1.event.attributes["supervisor"])) |> length() ==
             1

    assert Enum.uniq(Enum.map(supervisor_events, & &1.event.attributes["offender_id"]))
           |> length() == 1

    assert Enum.uniq(Enum.map(supervisor_events, & &1.event.attributes["offender_pid"]))
           |> length() == 3

    assert Enum.all?(supervisor_events, &(&1.event.attributes["restart_type"] == "permanent"))
    assert Enum.all?(supervisor_events, &(&1.event.attributes["reason_class"] == "abnormal"))

    assert Enum.all?(
             supervisor_events,
             &(byte_size(&1.event.attributes["reason_fingerprint"]) == 64)
           )

    {:ok, detector} = RestartRecurrence.new(threshold: 3)

    {_detector, outputs} =
      Enum.reduce(supervisor_events, {detector, []}, fn entry, {detector, outputs} ->
        {detector, emitted} =
          RestartRecurrence.observe(detector, entry.event, entry.received_at)

        {detector, outputs ++ emitted}
      end)

    assert [
             {:incident,
              %Insider.Finding{
                detector: "restart_recurrence",
                details: %{"count" => 3}
              }}
           ] = outputs
  end

  test "a full inbox sheds without queueing work in the logging process" do
    {_recorder, collector} =
      start_pipeline(inbox_size: 1, batch_size: 1, drain_interval_ms: 1_000)

    config = handler_config(collector)
    assert {:ok, %{inbox_count: 0}} = LoggerCollector.flush(collector)

    {:ok, before} = LoggerCollector.status(collector)

    for sequence <- 1..100 do
      Handler.log(
        %{level: :warning, msg: {~c"event ~p", [sequence]}, meta: %{domain: [:application]}},
        config
      )
    end

    assert {:ok, status} = LoggerCollector.status(collector)
    assert status.received - before.received == 100
    assert status.enqueued - before.enqueued == 1
    assert status.shed - before.shed == 99
    assert status.inbox_count == 1
    assert {:message_queue_len, queue_length} = Process.info(collector, :message_queue_len)
    assert queue_length <= 1
  end

  test "hostile report callbacks are never invoked and the primary filter remains installed" do
    {_recorder, collector} = start_pipeline(drain_interval_ms: 1_000)
    parent = self()
    callback = fn _report -> send(parent, :callback_invoked) end
    {:ok, before} = LoggerCollector.status(collector)

    Handler.log(
      %{
        level: :error,
        msg: {:report, %{label: {:proc_lib, :crash}, report: %{reason: :boom}}},
        meta: %{domain: [:otp], report_cb: callback}
      },
      handler_config(collector)
    )

    refute_receive :callback_invoked
    assert %{filters: filters} = :logger.get_primary_config()
    assert Enum.any?(filters, fn {id, _filter} -> id == @handler end)
    assert {:ok, status} = LoggerCollector.status(collector)
    assert status.received - before.received == 1
  end

  test "collector loss leaves Logger and unrelated host processes healthy" do
    {_recorder, collector} = start_pipeline()
    {:ok, host} = Agent.start_link(fn -> :healthy end)
    Process.unlink(host)
    Process.unlink(collector)
    monitor = Process.monitor(collector)

    Process.exit(collector, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :killed}, 1_000

    assert :ok = :logger.log(:error, %{label: :after_loss}, %{domain: [:otp]})
    assert Agent.get(host, & &1) == :healthy

    # start_supervised! restarts the collector, and the new collector replaces
    # the stale filter: it removes it, then adds its own. A read between the
    # two finds no filter, so the test waits for one.
    Eventually.await(
      fn ->
        %{filters: filters} = :logger.get_primary_config()
        Enum.any?(filters, fn {id, _filter} -> id == @handler end)
      end,
      5_000,
      "no #{@handler} filter after the collector restarted"
    )

    Agent.stop(host)
  end

  test "rejects invalid bounded configuration without replacing an existing handler" do
    {:ok, recorder_pid} =
      Recorder.start_link(classification: Insider.TestRecorderClassification.binding())

    {:ok, recorder} = Recorder.handle(recorder_pid)

    assert {:error, :invalid_options} =
             LoggerCollector.start_link(recorder,
               authority: "policy",
               boot_id: "boot",
               clock_id: "clock",
               inbox_size: 1_025,
               handler_id: @handler
             )

    {_recorder, collector} = start_pipeline(drain_interval_ms: 1_000)

    {_pid, monitor} =
      spawn_monitor(fn ->
        LoggerCollector.start_link(recorder,
          authority: "policy",
          boot_id: "boot",
          clock_id: "clock",
          environment: :test,
          handler_id: @handler
        )
      end)

    assert_receive {:DOWN, ^monitor, :process, _pid, {:already_exist, @handler}}, 1_000
    assert Process.alive?(collector)
  end

  test "malformed events and a closed recorder are counted outside the Logger caller" do
    {recorder, collector} = start_pipeline(drain_interval_ms: 1_000)
    config = handler_config(collector)
    {:ok, before} = LoggerCollector.status(collector)

    assert :ok = Handler.log(%{}, config)
    assert :ok = Handler.log(:forged, :forged)

    assert {:ok, _freeze_id} =
             Recorder.freeze(recorder, event("closed-trigger", "invariant_failed"))

    assert :ok =
             Handler.log(
               %{level: :info, msg: {:string, "after close"}, meta: %{}},
               config
             )

    assert {:ok, status} = LoggerCollector.flush(collector)
    assert status.invalid >= before.invalid + 1
    assert status.recorder_dropped + status.shed >= 1
  end

  test "invalid public calls fail closed" do
    assert {:error, :invalid_options} = LoggerCollector.start_link(:not_a_recorder, [])
    assert {:error, :invalid_options} = LoggerCollector.start_link({:not_a_recorder, []})
    assert {:error, :unavailable} = LoggerCollector.status(make_ref())
    assert {:error, :unavailable} = LoggerCollector.flush(make_ref())

    {dead, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}, 1_000
    assert {:error, :unavailable} = LoggerCollector.status(dead)
    assert {:error, :unavailable} = LoggerCollector.flush(dead)

    {:ok, recorder_pid} =
      Recorder.start_link(classification: Insider.TestRecorderClassification.binding())

    {:ok, recorder} = Recorder.handle(recorder_pid)

    assert {:error, :environment_denied} =
             LoggerCollector.start_link(recorder,
               authority: "policy",
               boot_id: "boot",
               clock_id: "clock",
               environment: :production
             )

    tuple_options = [
      authority: "policy",
      boot_id: "boot",
      clock_id: "clock",
      environment: :test,
      handler_id: :insider_logger_tuple_test
    ]

    assert {:ok, tuple_collector} = LoggerCollector.start_link({recorder, tuple_options})
    send(tuple_collector, :ignored_message)
    assert {:ok, _status} = LoggerCollector.status(tuple_collector)
    assert :ok = GenServer.stop(tuple_collector)

    for options <- [
          [],
          [authority: "policy", boot_id: "boot", clock_id: "clock", unknown: true],
          [authority: "policy", boot_id: "boot", clock_id: "clock"],
          [authority: "policy", authority: "again", boot_id: "boot", clock_id: "clock"],
          [authority: "policy", boot_id: "boot", clock_id: "clock", batch_size: 0],
          [authority: "policy", boot_id: "boot", clock_id: "clock", include_payload: :no],
          [authority: "policy", boot_id: "boot", clock_id: "clock", drain_interval_ms: 1_001]
        ] do
      assert {:error, :invalid_options} = LoggerCollector.start_link(recorder, options)
    end

    GenServer.stop(recorder_pid)
  end

  test "hostile nested terms are shaped within fixed portable bounds without creating atoms" do
    input = %{
      String.duplicate("key", 10_000) => String.duplicate("é", 100_000),
      :huge_map => Map.new(1..10_000, &{&1, &1}),
      :improper => [:head | self()],
      :opaque => fn -> :secret end,
      :invalid_utf8 => <<255, 0, 1>>
    }

    shaped = Shape.encode(input)
    _warmup = Jason.encode!(shaped)
    atom_count = :erlang.system_info(:atom_count)
    assert shaped == Shape.encode(input)

    assert Value.valid?(shaped, 8_192)
    assert byte_size(Jason.encode!(shaped)) < 8_192
    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "bounded shapes detach giant binaries and summarize bignums without decimalization" do
    giant_binary = String.duplicate("x", 10_000_000)
    shaped_binary = Shape.encode(giant_binary)
    assert byte_size(shaped_binary) == 256
    assert :binary.referenced_byte_size(shaped_binary) == 256

    giant_integer = 1 <<< 1_000_000

    assert Shape.encode(giant_integer) == %{
             "range" => "outside_int64",
             "sign" => "positive",
             "type" => "integer"
           }
  end

  test "opaque scalar and container shapes remain portable at boundaries" do
    assert Shape.encode(-1 <<< 1_000_000) == %{
             "range" => "outside_int64",
             "sign" => "negative",
             "type" => "integer"
           }

    assert Shape.encode(1.5) == "1.5"
    assert Shape.encode(make_ref()) == %{"type" => "reference"}
    assert Shape.encode(fn -> :ok end) == %{"type" => "function"}
    assert Shape.encode([:head | self()]) == ["head", %{"type" => "improper_tail"}]

    assert Shape.encode(List.duplicate(:item, 20)) |> List.last() == %{
             "type" => "truncated"
           }
  end

  test "collector teardown cannot remove a replacement filter with the same ID" do
    {_recorder, collector} = start_pipeline(drain_interval_ms: 1_000)
    assert :ok = :logger.remove_primary_filter(@handler)
    unrelated = {fn event, _config -> event end, :unrelated}
    assert :ok = :logger.add_primary_filter(@handler, unrelated)

    assert :ok = GenServer.stop(collector)
    assert %{filters: filters} = :logger.get_primary_config()
    assert {@handler, unrelated} in filters
  end

  defp start_pipeline(extra_options \\ []) do
    {recorder_options, collector_options} =
      Keyword.pop(extra_options, :recorder_options, [])

    recorder_child = %{
      id: make_ref(),
      start:
        {Recorder, :start_link,
         [
           Keyword.merge(
             [
               classification: Insider.TestRecorderClassification.binding(),
               post_trigger_ms: 0,
               rate_limit_count: 1_000
             ],
             recorder_options
           )
         ]}
    }

    recorder_pid = start_supervised!(recorder_child)
    {:ok, recorder} = Recorder.handle(recorder_pid)

    options =
      Keyword.merge(
        [
          authority: "test-policy",
          boot_id: "boot-test",
          clock_id: "logger-order",
          environment: :test,
          handler_id: @handler,
          source_instance_id: "logger-test"
        ],
        collector_options
      )

    child = %{id: make_ref(), start: {LoggerCollector, :start_link, [recorder, options]}}
    collector = start_supervised!(child)
    {recorder, collector}
  end

  defp event(id, kind) do
    Event.new!(
      id: id,
      node: "node-test",
      boot_id: "boot-test",
      source: "fixture",
      kind: kind,
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

  defp handler_config(collector) do
    state = :sys.get_state(collector)

    %{
      config:
        Map.take(state, [
          :authority,
          :boot_id,
          :clock_id,
          :include_payload,
          :include_message_semantics,
          :structural_only,
          :inbox,
          :inbox_size,
          :node,
          :sequence,
          :source_instance_id,
          :stats
        ])
    }
  end

  defp controlled_clock(parent) do
    calls = :atomics.new(1, signed: false)
    armed = :atomics.new(1, signed: false)
    gate_ref = make_ref()

    clock = fn ->
      call = :atomics.add_get(calls, 1, 1)

      if :atomics.exchange(armed, 1, 0) == 1 do
        send(parent, {:recorder_admission_started, self(), gate_ref})

        receive do
          {:release_recorder_admission, ^gate_ref} -> call
        end
      else
        call
      end
    end

    arm = fn -> :atomics.put(armed, 1, 1) end
    release = fn recipient -> send(recipient, {:release_recorder_admission, gate_ref}) end

    {clock, arm, release, gate_ref}
  end
end
