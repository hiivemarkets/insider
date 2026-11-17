defmodule Insider.Collector.SystemMonitorTest do
  # Both the OTP 27 backend and coexistence tests inspect the node-global
  # system_monitor slot. Parallel execution would test unrelated mutation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.SystemMonitor
  alias Insider.Collector.SystemMonitor.Backend
  alias Insider.Collector.SystemMonitor.Handler
  alias Insider.Collector.SystemMonitor.Policy
  alias Insider.Collector.SystemMonitor.Receiver
  alias Insider.Event
  alias Insider.Policy.Context
  alias Insider.Recorder

  setup do
    original = :erlang.system_monitor()
    on_exit(fn -> restore_system_monitor(original) end)
    :ok
  end

  test "policy canonicalizes six bounded event options and rejects hostile shapes" do
    assert {:ok, policy} =
             Policy.new(
               events: [
                 busy_dist_port: true,
                 long_schedule: 25,
                 long_message_queue: {10, 100},
                 long_gc: 20,
                 busy_port: true,
                 large_heap: 1_000_000
               ]
             )

    assert Policy.valid?(policy)

    assert Enum.map(policy.events, &elem(&1, 0)) == [
             :long_gc,
             :long_message_queue,
             :long_schedule,
             :large_heap,
             :busy_port,
             :busy_dist_port
           ]

    for events <- [
          [],
          [long_gc: 0],
          [long_gc: 60_001],
          [long_message_queue: {10, 10}],
          [long_message_queue: {-1, 10}],
          [busy_port: false],
          [unknown: true],
          [long_gc: 10, long_gc: 20],
          [{:long_gc, 10} | :improper]
        ] do
      assert {:error, :invalid_policy} = Policy.new(events: events)
    end

    assert {:error, :invalid_policy} =
             Policy.new(environment: :ci, events: [long_gc: 10])

    forged = %{policy | events: List.duplicate({:long_gc, 1}, 100_000)}
    refute Policy.valid?(forged)
    refute Policy.valid?(:not_a_policy)
  end

  test "runtime selection is isolated on OTP 28-29 and legacy is explicit on OTP 27" do
    isolated = policy!(legacy_node_global: false)
    legacy = policy!(legacy_node_global: true)
    isolated_context = runtime_context!(:isolated)
    legacy_context = runtime_context!(:legacy)

    assert {:ok, :isolated} = Backend.mode_for("28", isolated, isolated_context)
    assert {:ok, :isolated} = Backend.mode_for("29", isolated, isolated_context)

    assert {:error, :legacy_capability_required} =
             Backend.mode_for("27", isolated, legacy_context)

    assert {:ok, :legacy_node_global} = Backend.mode_for("27", legacy, legacy_context)

    assert {:error, :runtime_context_denied} =
             Backend.mode_for("27", legacy, runtime_context!(:legacy, target_class: :host))

    assert {:error, :unsupported_otp} = Backend.mode_for("26", legacy, legacy_context)
    assert {:error, :unsupported_otp} = Backend.mode_for("30", legacy, legacy_context)
    assert {:error, :unsupported_otp} = Backend.mode_for("hostile", legacy, legacy_context)

    for context <- [
          runtime_context!(:isolated, environment: :production),
          runtime_context!(:legacy, target_class: :host),
          runtime_context!(:isolated, features: %{}),
          runtime_context!(:isolated,
            features: %{
              "events.subscribe" => %{
                available: true,
                provider: "wrong-provider",
                isolation: :session_local
              }
            }
          )
        ] do
      assert {:error, :runtime_context_denied} = Backend.mode_for("29", isolated, context)
    end
  end

  test "captures every allowlisted anomaly through a closed bounded projection" do
    {recorder, collector} = start_pipeline(policy: all_events_policy())
    state = :sys.get_state(collector)
    port = open_test_port()
    on_exit(fn -> close_test_port(port) end)
    sensitive = {:private_payload, make_ref()}

    messages = [
      {:monitor, self(), :long_gc,
       [
         {:unknown, sensitive},
         {:timeout, 27},
         {:heap_size, 101},
         {:heap_block_size, 202},
         {:stack_size, 3},
         {:mbuf_size, 4},
         {:old_heap_size, 5},
         {:old_heap_block_size, 6}
       ]},
      {:monitor, self(), :long_message_queue, true},
      {:monitor, self(), :long_message_queue, false},
      {:monitor, self(), :long_schedule,
       [{:timeout, 55}, {:in, {PrivateModule, :run, [sensitive]}}, {:out, sensitive}]},
      {:monitor, port, :long_schedule, [{:timeout, 66}, {:port_op, :output}]},
      {:monitor, self(), :large_heap, [{:heap_size, 1_001}, {:timeout, 999}]},
      {:monitor, self(), :busy_port, port},
      {:monitor, self(), :busy_dist_port, port}
    ]

    Enum.each(messages, &send(state.receiver, &1))
    assert {:ok, status} = SystemMonitor.flush(collector)
    # The node's own system monitor events (a real long GC or long schedule
    # on a loaded runner) can arrive too, so the count is a lower bound and
    # only this test's events are compared.
    assert status.recorded >= 8
    assert status.invalid == 0
    assert status.shed == 0

    ours = [
      self() |> :erlang.pid_to_list() |> to_string(),
      port |> :erlang.port_to_list() |> to_string()
    ]

    snapshot = frozen_snapshot(recorder, "system-monitor-trigger")

    events =
      Enum.filter(
        snapshot.events,
        &(&1.event.source == "system_monitor" and &1.event.subject["value"] in ours)
      )

    assert Enum.map(events, & &1.event.kind) == [
             "vm_long_gc",
             "vm_long_message_queue",
             "vm_long_message_queue",
             "vm_long_schedule",
             "vm_long_schedule",
             "vm_large_heap",
             "vm_busy_port",
             "vm_busy_dist_port"
           ]

    long_gc = Enum.find(events, &(&1.event.kind == "vm_long_gc")).event
    assert long_gc.attributes["timeout_ms"] == 27
    assert long_gc.attributes["heap_size_words"] == 101
    assert long_gc.attributes["projection"] == "erts.system_monitor/v1"
    assert long_gc.authority == "system-monitor-test-policy"

    schedules = for %{event: %{kind: "vm_long_schedule"} = event} <- events, do: event
    assert Enum.any?(schedules, &(&1.attributes["port_operation"] == "output"))
    assert Enum.all?(schedules, &(not Map.has_key?(&1.attributes, "in")))
    assert Enum.all?(schedules, &(not Map.has_key?(&1.attributes, "out")))

    encoded = inspect(Enum.map(events, &Event.to_wire_map(&1.event)))
    refute encoded =~ inspect(sensitive)
    refute encoded =~ "PrivateModule"
  end

  test "real long-message-queue entry and recovery cross the runtime delivery barrier" do
    if otp_release() in [28, 29] do
      parent = self()

      target =
        spawn(fn ->
          receive do
            :drain ->
              drain_noise()
              send(parent, {:target_drained, self()})
              receive do: (:stop -> :ok)
          end
        end)

      on_exit(fn ->
        send(target, :drain)
        send(target, :stop)
      end)

      {recorder, collector} =
        start_pipeline(
          policy: policy!(events: [long_message_queue: {0, 100}]),
          inbox_size: 256,
          max_mailbox_size: 4_096
        )

      Enum.each(1..120, &send(target, {:noise, &1}))
      assert {:ok, first_status} = SystemMonitor.flush(collector)
      assert first_status.recorded >= 1

      send(target, :drain)
      assert_receive {:target_drained, ^target}, 1_000
      assert {:ok, second_status} = SystemMonitor.flush(collector)
      assert second_status.recorded > first_status.recorded

      snapshot = frozen_snapshot(recorder, "real-system-monitor-trigger")
      target_id = target |> :erlang.pid_to_list() |> to_string()

      states =
        for %{event: event} <- snapshot.events,
            event.kind == "vm_long_message_queue",
            event.subject["value"] == target_id,
            do: event.attributes["state"]

      assert "entered" in states
      assert "recovered" in states
    else
      assert otp_release() == 27
    end
  end

  test "malformed, overlong, disabled, and forged monitor tuples fail closed" do
    {_recorder, collector} = start_pipeline(policy: policy!(events: [long_gc: 10]))
    state = :sys.get_state(collector)
    sensitive = {:private_payload, make_ref()}
    remote_pid = remote_pid()
    remote_port = remote_port()

    messages = [
      {:monitor, self(), :long_gc, List.duplicate({:unknown, sensitive}, 17)},
      {:monitor, self(), :long_gc, [{:timeout, 1} | :improper]},
      {:monitor, self(), :long_gc, [{:timeout, -1}]},
      {:monitor, self(), :busy_port, :not_a_port},
      {:monitor, self(), :large_heap, [{:heap_size, 10}]},
      {:monitor, self(), :future_event, sensitive},
      {:monitor, remote_pid, :long_gc, [{:timeout, 1}]},
      {:monitor, self(), :busy_port, remote_port},
      {:monitor, sensitive, :long_gc, []},
      sensitive
    ]

    Enum.each(messages, &send(state.receiver, &1))
    assert {:ok, status} = SystemMonitor.flush(collector)
    assert status.invalid == length(messages)
    assert status.recorded == 0
    assert status.handler_failures == 0
  end

  test "maximum source identity records successfully and Recorder loss is accounted" do
    {recorder, collector} =
      start_pipeline(
        policy: policy!(events: [long_gc: 10]),
        source_instance_id: String.duplicate("s", 114)
      )

    state = :sys.get_state(collector)
    send(state.receiver, {:monitor, self(), :long_gc, [{:timeout, 11}]})
    assert {:ok, %{recorded: 1}} = SystemMonitor.flush(collector)

    assert :ok = GenServer.stop(recorder.pid)
    send(state.receiver, {:monitor, self(), :long_gc, [{:timeout, 12}]})
    assert {:ok, status} = SystemMonitor.flush(collector)
    assert status.recorded == 1
    assert status.recorder_dropped == 1
    assert Process.alive?(collector)
  end

  test "fixed inbox collision sheds without blocking or disabling the backend" do
    {_recorder, collector} =
      start_pipeline(
        policy: policy!(events: [long_gc: 10]),
        inbox_size: 1,
        batch_size: 1,
        max_mailbox_size: 4_096,
        backlog_check_every: 256,
        drain_interval_ms: 1_000
      )

    state = :sys.get_state(collector)
    assert true = :erlang.suspend_process(state.receiver)

    Enum.each(1..8, fn timeout ->
      send(state.receiver, {:monitor, self(), :long_gc, [{:timeout, timeout}]})
    end)

    assert true = :erlang.resume_process(state.receiver)
    assert {:ok, status} = SystemMonitor.flush(collector)
    assert status.received == 8
    assert status.enqueued == 1
    assert status.shed == 7
    assert status.monitor_disabled_overload == 0
    assert status.enabled
  end

  test "mailbox tripwire self-disables without claiming a hard transient bound" do
    {_recorder, collector} =
      start_pipeline(
        policy: policy!(events: [long_gc: 10]),
        inbox_size: 1,
        batch_size: 1,
        max_mailbox_size: 2,
        backlog_check_every: 1,
        drain_interval_ms: 1_000
      )

    state = :sys.get_state(collector)
    assert true = :erlang.suspend_process(state.receiver)

    Enum.each(1..8, fn timeout ->
      send(state.receiver, {:monitor, self(), :long_gc, [{:timeout, timeout}]})
    end)

    send(state.receiver, {:forged_after_disable, {:private_payload, make_ref()}})

    assert true = :erlang.resume_process(state.receiver)
    assert {:ok, status} = SystemMonitor.flush(collector)
    # A real system monitor event of the node can arrive besides the nine
    # sent here (a CI run saw 10), and is discarded the same way.
    assert status.received >= 9
    assert status.post_disable_discarded == status.received
    assert status.enqueued == 0
    assert status.shed == 0
    assert status.monitor_disabled_overload == 1
    assert status.receiver_mailbox_high_water >= 2
    assert status.transient_mailbox_bound == :not_guaranteed
    refute status.enabled

    assert {:ok, stopped_status} = SystemMonitor.flush(collector)
    assert stopped_status.overload_cleanup.backend in [:destroyed, :released_or_absent]
    assert stopped_status.overload_cleanup.receiver == :stopped
    assert Process.alive?(collector)
    refute Process.alive?(state.receiver)
  end

  test "a healthy empty collector records nothing and cleans up its owned backend" do
    {_recorder, collector} = start_pipeline()
    state = :sys.get_state(collector)
    receiver_monitor = Process.monitor(state.receiver)

    assert {:ok, status} = SystemMonitor.flush(collector)
    assert status.received == 0
    assert status.recorded == 0
    assert status.enabled
    assert status.requested_options == default_policy().events

    if otp_release() in [28, 29] do
      assert {:system, effective} = :trace.info(state.backend.session, :system, :all)
      assert status.effective_options == effective
    end

    assert {:ok, cleanup} = SystemMonitor.stop(collector)
    assert cleanup.receiver == :stopped
    assert cleanup.transient_mailbox_bound == :not_guaranteed
    assert_receive {:DOWN, ^receiver_monitor, :process, _, :normal}, 1_000

    if otp_release() in [28, 29], do: assert(cleanup.backend == :destroyed)
  end

  test "isolated sessions coexist with a foreign legacy monitor; OTP 27 refuses it unchanged" do
    foreign = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(foreign, :stop) end)
    :undefined = :erlang.system_monitor(:undefined)
    _old = :erlang.system_monitor(foreign, [{:long_gc, 50_000}, :busy_port])
    before = :erlang.system_monitor()

    case otp_release() do
      release when release in [28, 29] ->
        {_recorder, collector} = start_pipeline()
        assert :erlang.system_monitor() == before
        assert {:ok, %{backend: :destroyed}} = SystemMonitor.stop(collector)
        assert :erlang.system_monitor() == before

      27 ->
        assert {:error, :system_monitor_conflict} = start_unsupervised(legacy_policy())
        assert :erlang.system_monitor() == before
    end
  end

  test "legacy adapter refuses conflicts and receiver death preserves a takeover" do
    :undefined = :erlang.system_monitor(:undefined)
    policy = legacy_policy()
    context = runtime_context!(:legacy)
    ownership = :ets.new(:legacy_system_monitor_test, [:set, :public])
    foreign = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(foreign, :stop) end)
    receiver = spawn(fn -> receive do: (:stop -> :ok) end)
    receiver_monitor = Process.monitor(receiver)

    assert {:ok, backend} =
             Backend.start_for_release("27", policy, context, receiver, ownership)

    assert {^receiver, effective} = :erlang.system_monitor()
    assert backend.effective_options == effective
    assert :receiver_termination_required = Backend.disable(backend)
    assert :cleanup_unknown = Backend.observe_legacy_release(backend)
    Process.exit(receiver, :kill)
    assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :killed}, 1_000
    assert :undefined = :erlang.system_monitor()
    assert :released_or_absent = Backend.observe_legacy_release(backend)

    _none = :erlang.system_monitor(foreign, [{:long_gc, 50_000}])
    conflict = :erlang.system_monitor()
    conflicting_receiver = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(conflicting_receiver, :stop) end)

    assert {:error, :system_monitor_conflict} =
             Backend.start_for_release("27", policy, context, conflicting_receiver, ownership)

    assert :erlang.system_monitor() == conflict

    _foreign = :erlang.system_monitor(:undefined)
    takeover_receiver = spawn(fn -> receive do: (:stop -> :ok) end)
    takeover_monitor = Process.monitor(takeover_receiver)

    assert {:ok, second_backend} =
             Backend.start_for_release("27", policy, context, takeover_receiver, ownership)

    _ours = :erlang.system_monitor(foreign, [{:long_schedule, 50_000}])
    takeover = :erlang.system_monitor()
    Process.exit(takeover_receiver, :kill)

    assert_receive {:DOWN, ^takeover_monitor, :process, ^takeover_receiver, :killed}, 1_000
    assert :foreign_preserved = Backend.observe_legacy_release(second_backend)
    assert :erlang.system_monitor() == takeover
  end

  test "isolated backend delivery and unsupported-runtime cleanup are explicit" do
    ownership = :ets.new(:isolated_system_monitor_test, [:set, :public])
    receiver = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(receiver, :stop) end)
    sessions_before = insider_trace_sessions()
    assert :unsupported = Backend.delivery_reference(:missing_ownership_table)

    if otp_release() in [28, 29] do
      assert {:ok, backend} =
               Backend.start_for_release(
                 "29",
                 default_policy(),
                 runtime_context!(:isolated),
                 receiver,
                 ownership
               )

      assert {:ok, delivery_reference} = Backend.delivery_reference(ownership)
      assert is_reference(delivery_reference)
      assert :destroyed = Backend.disable(backend)
      assert :already_destroyed = Backend.disable(backend)
    else
      assert {:error, :backend_unavailable} =
               Backend.start_for_release(
                 "29",
                 default_policy(),
                 runtime_context!(:isolated),
                 receiver,
                 ownership
               )

      assert_no_new_insider_trace_sessions(sessions_before)
    end

    assert :cleanup_unknown = Backend.disable(%{mode: :isolated, session: make_ref()})

    assert {:error, :backend_unavailable} =
             Backend.start_for_release(
               "29",
               default_policy(),
               runtime_context!(:isolated),
               receiver,
               :missing_ownership_table
             )

    assert_no_new_insider_trace_sessions(sessions_before)

    assert {:error, :unsupported_otp} =
             Backend.start_for_release(
               "hostile",
               default_policy(),
               runtime_context!(:isolated),
               receiver,
               ownership
             )
  end

  test "trace-session cleanup accounting ignores departures and catches owned leaks" do
    if otp_release() in [28, 29] do
      baseline = :trace.session_create(:insider_system_monitor, self(), [])
      sessions_before = insider_trace_sessions()
      assert true = :trace.session_destroy(baseline)

      ownership = :ets.new(:trace_session_cleanup_accounting_test, [:set, :public])
      receiver = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(receiver, :stop) end)

      assert {:error, :backend_unavailable} =
               Backend.start_for_release(
                 "29",
                 default_policy(),
                 runtime_context!(:isolated),
                 receiver,
                 :missing_ownership_table
               )

      assert_no_new_insider_trace_sessions(sessions_before)

      assert {:ok, backend} =
               Backend.start_for_release(
                 "29",
                 default_policy(),
                 runtime_context!(:isolated),
                 receiver,
                 ownership
               )

      on_exit(fn -> Backend.disable(backend) end)
      {_, {:insider_system_monitor, leaked_session_id}} = backend.session
      assert leaked_session_id in new_insider_trace_sessions(sessions_before)

      assert :destroyed = Backend.disable(backend)
      assert_no_new_insider_trace_sessions(sessions_before)
    else
      assert otp_release() == 27
    end
  end

  test "receiver control is bounded without a backend and stop is exact" do
    config = receiver_config()
    control_ref = make_ref()
    {:ok, receiver} = Receiver.start_link(config, control_ref, self())
    receiver_monitor = Process.monitor(receiver)

    assert :ok = Receiver.barrier(receiver, control_ref, 100)
    assert :stopped = Receiver.stop(receiver, control_ref, 100)
    assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :normal}, 1_000
    assert :already_stopped = Receiver.stop(receiver, control_ref, 100)

    abnormal_receiver =
      spawn(fn ->
        receive do
          _message -> exit(:receiver_fault)
        end
      end)

    assert :forced = Receiver.stop(abnormal_receiver, make_ref(), 100)

    {:ok, blocked_receiver} = Receiver.start_link(config, make_ref(), self())
    Process.unlink(blocked_receiver)
    blocked_monitor = Process.monitor(blocked_receiver)
    assert true = :erlang.suspend_process(blocked_receiver)
    assert :cleanup_unknown = Receiver.stop(blocked_receiver, make_ref(), 0)
    assert_receive {:DOWN, ^blocked_monitor, :process, ^blocked_receiver, :killed}, 1_000
  end

  test "handler failure and post-disable hostile input are cheaply accounted" do
    config = receiver_config()
    broken = %{config | inbox: :missing_system_monitor_inbox}

    assert :ok = Handler.capture({:monitor, self(), :long_gc, []}, broken)
    assert :counters.get(config.stats, 1) == 1
    assert :counters.get(config.stats, 9) == 1

    :atomics.put(config.enabled, 1, 0)
    assert :ok = Handler.capture({:monitor, :forged, :future, {:private, make_ref()}}, config)
    assert :atomics.get(config.enabled, 1) == 0
    assert :counters.get(config.stats, 10) == 1
    assert :counters.get(config.stats, 4) == 0
    assert :ok = Handler.capture(:hostile, %{})
  end

  test "tuple startup, generated identity, and scheduled drain preserve ordering" do
    {recorder, _pid} = start_recorder()
    options = Keyword.delete(collector_options(), :source_instance_id)
    assert {:ok, collector} = SystemMonitor.start_link({recorder, default_policy(), options})
    on_exit(fn -> if Process.alive?(collector), do: SystemMonitor.stop(collector) end)
    state = :sys.get_state(collector)
    assert String.starts_with?(state.source_instance_id, "system-monitor-")

    send(state.receiver, {:monitor, self(), :long_gc, [{:timeout, 21}]})
    assert :ok = Receiver.barrier(state.receiver, state.control_ref, 1_000)
    {_timer_ref, token} = state.drain_token
    send(collector, {:drain, token})
    assert {:ok, %{recorded: 1}} = SystemMonitor.status(collector)
    send(collector, :unknown_control_message)
    assert {:ok, %{recorded: 1}} = SystemMonitor.status(collector)
  end

  test "corrupt retained shapes fail closed in the drainer" do
    {_recorder, collector} = start_pipeline()
    state = :sys.get_state(collector)
    assert true = :ets.insert(state.inbox, {0, 1, %{kind: "forged"}})

    assert {:ok, status} = SystemMonitor.flush(collector)
    assert status.invalid == 1
    assert status.recorded == 0
  end

  test "flush reports a bounded busy receiver instead of blocking indefinitely" do
    {_recorder, collector} = start_pipeline()
    state = :sys.get_state(collector)
    assert true = :erlang.suspend_process(state.receiver)
    assert {:error, :receiver_busy} = SystemMonitor.flush(collector)
    assert true = :erlang.resume_process(state.receiver)
  end

  test "multiple collectors are isolated on OTP 28-29 and conflict on legacy OTP 27" do
    {_recorder_one, collector_one} = start_pipeline(source_instance_id: "system-monitor-one")

    case otp_release() do
      release when release in [28, 29] ->
        {_recorder_two, collector_two} =
          start_pipeline(source_instance_id: "system-monitor-two")

        assert {:ok, %{backend: :isolated}} = SystemMonitor.status(collector_one)
        assert {:ok, %{backend: :isolated}} = SystemMonitor.status(collector_two)

      27 ->
        assert {:error, :system_monitor_conflict} = start_unsupervised(legacy_policy())
    end
  end

  test "simultaneous starts coexist when isolated and choose one owner when legacy" do
    parent = self()
    {recorder_one, _pid_one} = start_recorder()
    {recorder_two, _pid_two} = start_recorder()
    policy = if otp_release() == 27, do: legacy_policy(), else: default_policy()

    starters =
      for {label, recorder, source} <- [
            {:one, recorder_one, "system-monitor-concurrent-one"},
            {:two, recorder_two, "system-monitor-concurrent-two"}
          ] do
        spawn(fn ->
          receive do: (:go -> :ok)

          result =
            SystemMonitor.start_link(
              recorder,
              policy,
              collector_options(source_instance_id: source)
            )

          send(parent, {:concurrent_start, label, result})
          receive do: (:stop -> :ok)
        end)
      end

    on_exit(fn -> Enum.each(starters, &send(&1, :stop)) end)
    Enum.each(starters, &send(&1, :go))

    results =
      for _index <- 1..2 do
        assert_receive {:concurrent_start, label, result}, 1_000
        {label, result}
      end

    case otp_release() do
      release when release in [28, 29] ->
        assert Enum.all?(results, fn {_label, result} -> match?({:ok, _pid}, result) end)

      27 ->
        assert Enum.count(results, fn {_label, result} -> match?({:ok, _pid}, result) end) == 1

        assert Enum.count(results, fn
                 {_label, {:error, reason}}
                 when reason in [:install_contended, :system_monitor_conflict] ->
                   true

                 _other ->
                   false
               end) == 1
    end
  end

  test "an outsider takeover of the legacy slot is never cleared by cleanup" do
    if otp_release() == 27 do
      {_recorder, collector} = start_pipeline(policy: legacy_policy())
      foreign = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(foreign, :stop) end)
      _ours = :erlang.system_monitor(foreign, [{:long_schedule, 50_000}])
      takeover = :erlang.system_monitor()

      assert {:ok, %{backend: :foreign_preserved, cleanup_mechanism: :receiver_termination}} =
               SystemMonitor.stop(collector)

      assert :erlang.system_monitor() == takeover
    else
      assert otp_release() in [28, 29]
    end
  end

  test "caller death takes down collector and receiver and releases the backend" do
    parent = self()
    policy = default_policy()
    {recorder, _recorder_pid} = start_recorder()

    starter =
      spawn(fn ->
        result = SystemMonitor.start_link(recorder, policy, collector_options())
        send(parent, {:starter_result, self(), result})

        receive do
          :shutdown -> exit(:shutdown)
        end
      end)

    assert_receive {:starter_result, ^starter, {:ok, collector}}, 1_000
    state = :sys.get_state(collector)
    collector_monitor = Process.monitor(collector)
    receiver_monitor = Process.monitor(state.receiver)
    send(starter, :shutdown)

    assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :shutdown}, 1_000
    assert_receive {:DOWN, ^receiver_monitor, :process, _, _reason}, 1_000
  end

  test "receiver failure takes down its collector and removes active monitoring" do
    {recorder, _recorder_pid} = start_recorder()
    {:ok, collector} = SystemMonitor.start_link(recorder, default_policy(), collector_options())
    Process.unlink(collector)
    state = :sys.get_state(collector)
    collector_monitor = Process.monitor(collector)

    capture_log(fn ->
      Process.exit(state.receiver, :kill)

      assert_receive {:DOWN, ^collector_monitor, :process, ^collector, {:receiver_exit, :killed}},
                     1_000
    end)

    if otp_release() in [28, 29] do
      assert_raise ArgumentError, fn ->
        :trace.info(state.backend.session, :system, :all)
      end
    else
      assert :undefined = :erlang.system_monitor()
    end
  end

  test "untrappable collector death also takes down its receiver" do
    {recorder, _recorder_pid} = start_recorder()
    {:ok, collector} = SystemMonitor.start_link(recorder, default_policy(), collector_options())
    Process.unlink(collector)
    state = :sys.get_state(collector)
    receiver_monitor = Process.monitor(state.receiver)
    collector_monitor = Process.monitor(collector)

    Process.exit(collector, :kill)

    assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :killed}, 1_000
    assert_receive {:DOWN, ^receiver_monitor, :process, _, :killed}, 1_000

    if otp_release() in [28, 29] do
      # The copied strong handle intentionally keeps the otherwise-orphaned
      # session alive in this test. Direct :kill cannot run collector cleanup;
      # destroy it explicitly rather than claiming synchronous GC cleanup.
      _destroyed = :trace.session_destroy(state.backend.session)
    else
      assert :undefined = :erlang.system_monitor()
    end
  end

  test "public calls and configuration boundaries fail closed" do
    policy = default_policy()
    {recorder, _pid} = start_recorder()

    assert {:error, :invalid_options} =
             SystemMonitor.start_link(:bad, policy, collector_options())

    invalid_policy = %Policy{events: [], legacy_node_global: false}
    assert {:error, :invalid_options} = SystemMonitor.start_link(recorder, invalid_policy, [])
    assert {:error, :invalid_options} = SystemMonitor.start_link(recorder, policy, :bad)
    assert {:error, :invalid_options} = SystemMonitor.start_link(:bad)

    denied_options =
      Keyword.put(
        collector_options(),
        :runtime_context,
        runtime_context!(:isolated, environment: :production)
      )

    assert {:error, :runtime_context_denied} =
             SystemMonitor.start_link(recorder, policy, denied_options)

    forged_context = %{runtime_context!(:isolated) | actor: ""}

    assert {:error, :invalid_options} =
             SystemMonitor.start_link(
               recorder,
               policy,
               Keyword.put(collector_options(), :runtime_context, forged_context)
             )

    assert {:error, :unavailable} = SystemMonitor.status(make_ref())
    assert {:error, :unavailable} = SystemMonitor.flush(make_ref())
    assert {:error, :unavailable} = SystemMonitor.stop(make_ref())

    for override <- [
          [inbox_size: 0],
          [inbox_size: 1_025],
          [batch_size: 0],
          [max_mailbox_size: 0],
          [backlog_check_every: 257],
          [authority: ""],
          [source_instance_id: String.duplicate("x", 115)]
        ] do
      assert {:error, :invalid_options} =
               SystemMonitor.start_link(
                 recorder,
                 policy,
                 Keyword.merge(collector_options(), override)
               )
    end
  end

  defp start_pipeline(overrides \\ []) do
    {policy, options} = Keyword.pop(overrides, :policy, default_policy())
    {recorder, _pid} = start_recorder()

    child = %{
      id: make_ref(),
      start: {SystemMonitor, :start_link, [recorder, policy, collector_options(options)]}
    }

    collector = start_supervised!(child)
    {recorder, collector}
  end

  defp start_unsupervised(policy) do
    {recorder, _pid} = start_recorder()
    SystemMonitor.start_link(recorder, policy, collector_options())
  end

  defp start_recorder do
    child = %{
      id: make_ref(),
      start:
        {Recorder, :start_link,
         [[classification: Insider.TestRecorderClassification.binding(), post_trigger_ms: 0]]}
    }

    pid = start_supervised!(child)
    {:ok, recorder} = Recorder.handle(pid)
    {recorder, pid}
  end

  defp collector_options(overrides \\ []) do
    Keyword.merge(
      [
        authority: "system-monitor-test-policy",
        boot_id: "boot-system-monitor-test",
        clock_id: "system-monitor-order",
        drain_interval_ms: 1_000,
        runtime_context: runtime_context!(if(otp_release() == 27, do: :legacy, else: :isolated)),
        source_instance_id: "system-monitor-test"
      ],
      overrides
    )
  end

  defp receiver_config do
    %{
      allowed_events: %{long_gc: true},
      backlog_check_every: 16,
      enabled: :atomics.new(1, signed: false),
      high_water: :atomics.new(1, signed: false),
      inbox: :ets.new(:system_monitor_receiver_test, [:set, :public]),
      inbox_size: 8,
      max_mailbox_size: 1_024,
      ownership: :ets.new(:system_monitor_receiver_ownership_test, [:set, :public]),
      sequence: :atomics.new(1, signed: false),
      stats: :counters.new(10, [:atomics])
    }
    |> tap(&:atomics.put(&1.enabled, 1, 1))
  end

  defp default_policy, do: policy!(events: [long_gc: 10_000])

  defp all_events_policy do
    policy!(
      events: [
        long_gc: 10_000,
        long_message_queue: {10_000, 20_000},
        long_schedule: 10_000,
        large_heap: 1_000_000_000,
        busy_port: true,
        busy_dist_port: true
      ]
    )
  end

  defp legacy_policy,
    do:
      policy!(
        events: [long_gc: 10_000, busy_port: true],
        legacy_node_global: true
      )

  defp policy!(overrides) do
    options =
      Keyword.merge(
        [events: [long_gc: 10_000], legacy_node_global: otp_release() == 27],
        overrides
      )

    {:ok, policy} = Policy.new(options)
    policy
  end

  defp runtime_context!(backend, overrides \\ []) do
    {provider, isolation, target_class, environment} =
      case backend do
        :isolated -> {"erts.trace.system", :session_local, :host, :test}
        :legacy -> {"erlang.system_monitor", :node_global, :disposable, :ci}
      end

    defaults = [
      environment: environment,
      actor: "system-monitor-test",
      target_class: target_class,
      features: %{
        "events.subscribe" => %{
          available: true,
          provider: provider,
          isolation: isolation
        }
      }
    ]

    {:ok, context} = Context.new(Keyword.merge(defaults, overrides))
    context
  end

  defp frozen_snapshot(recorder, trigger_id) do
    assert {:ok, _freeze_id} = Recorder.freeze(recorder, trigger_event(trigger_id))
    assert {:ok, snapshot} = Recorder.snapshot(recorder)
    snapshot
  end

  defp trigger_event(id) do
    Event.new!(
      id: id,
      node: "node-test",
      boot_id: "boot-system-monitor-test",
      source: "fixture",
      kind: "invariant_failed",
      severity: :error,
      monotonic_time: 1,
      clock_id: "fixture-clock",
      source_instance_id: "fixture-system-monitor",
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
      authority: "system-monitor-test-policy",
      redactions: [],
      extensions: %{}
    )
  end

  defp open_test_port do
    executable = System.find_executable("cat") || raise "cat executable is required"
    Port.open({:spawn_executable, executable}, [:binary])
  end

  defp close_test_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _error -> :ok
  end

  defp restore_system_monitor(:undefined), do: :erlang.system_monitor(:undefined)

  defp restore_system_monitor({pid, options}) do
    if Process.alive?(pid),
      do: :erlang.system_monitor(pid, options),
      else: :erlang.system_monitor(:undefined)
  end

  defp otp_release do
    :erlang.system_info(:otp_release)
    |> to_string()
    |> String.to_integer()
  end

  defp insider_trace_sessions do
    :trace.session_info(:all)
    |> Keyword.get_values(:insider_system_monitor)
    |> Enum.sort()
  end

  defp assert_no_new_insider_trace_sessions(sessions_before) do
    assert new_insider_trace_sessions(sessions_before) == []
  end

  defp new_insider_trace_sessions(sessions_before) do
    insider_trace_sessions() -- sessions_before
  end

  defp drain_noise do
    receive do
      {:noise, _value} -> drain_noise()
    after
      0 -> :ok
    end
  end

  defp remote_pid,
    do: :erlang.binary_to_term(<<131, 88, 118, 0, 11, "remote@host", 0::32, 0::32, 0::32>>)

  defp remote_port,
    do: :erlang.binary_to_term(<<131, 89, 118, 0, 11, "remote@host", 1::32, 0::32>>)
end
