defmodule Insider.Collector.PollerTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Poller
  alias Insider.Collector.Poller.Config
  alias Insider.Collector.Poller.Erlang, as: ErlangProvider
  alias Insider.Event
  alias Insider.Recorder

  defmodule ProcessBlockingProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: {:ok, :complete, %{"process_count" => 1}, []}

    @impl true
    def process_sample(_pid) do
      receive do
        :never -> {:error, :failed}
      end
    end
  end

  defmodule VmBlockingProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample do
      receive do
        :never -> {:error, :failed}
      end
    end

    @impl true
    def process_sample(_pid), do: {:ok, :complete, %{"message_queue_len" => 0}, []}
  end

  defmodule CoordinatedProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: {:ok, :complete, %{"process_count" => 1}, []}

    @impl true
    def process_sample(pid) do
      send(pid, {:coordinated_probe_started, self()})

      receive do
        :complete_probe -> {:ok, :complete, %{"message_queue_len" => 0}, []}
      end
    end
  end

  defmodule FailingProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: raise("probe failure")

    @impl true
    def process_sample(_pid), do: exit(:probe_failure)
  end

  defmodule OversizedProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample,
      do: {:ok, :complete, %{"oversized" => String.duplicate("x", 8_192)}, []}

    @impl true
    def process_sample(_pid), do: {:unexpected, :value}
  end

  defmodule PartialProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample,
      do: {:ok, :partial, %{"process_count" => 1}, ["memory"]}

    @impl true
    def process_sample(_pid), do: {:ok, :complete, %{"message_queue_len" => 0}, []}
  end

  defmodule KilledProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: Process.exit(self(), :kill)

    @impl true
    def process_sample(_pid), do: Process.exit(self(), :kill)
  end

  defmodule InvalidEventProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample,
      do: {:ok, :complete, %{"counter" => 9_223_372_036_854_775_808}, []}

    @impl true
    def process_sample(_pid), do: {:error, :failed}
  end

  test "records bounded VM and scalar process samples without copying private state" do
    secret = "private-secret-#{System.unique_integer([:positive])}"
    target = spawn(fn -> secret_process(secret) end)
    handle = start_recorder()
    poller = start_poller(handle, targets: [target])

    assert_cycle_completed(poller)

    events = recorded_events(handle)
    assert Enum.map(events, & &1.kind) == ["vm_sample", "process_sample"]
    assert Enum.all?(events, &match?({:ok, %Event{}}, Event.validate(&1)))

    vm = hd(events)
    assert vm.attributes["field_set"] == "otp_vm_scalar/v1"
    assert vm.attributes["probe_status"] in ["complete", "partial"]
    assert is_integer(vm.attributes["metrics"]["process_count"])

    process = List.last(events)
    assert process.subject["value"] == pid_string(target)
    assert process.attributes["field_set"] == "otp_process_scalar/v1"
    assert process.attributes["probe_status"] == "complete"
    assert is_integer(process.attributes["metrics"]["message_queue_len"])
    assert is_integer(process.attributes["metrics"]["reductions_total"])

    canonical = Enum.map_join(events, &(&1 |> Event.to_wire_map() |> Jason.encode!()))
    refute canonical =~ secret
    refute canonical =~ "dictionary-secret"
    refute canonical =~ "mailbox-secret"

    send(target, :stop)
  end

  test "times out a blocking process probe, observes cleanup, and remains usable" do
    target = spawn(fn -> receive(do: (:stop -> :ok)) end)
    handle = start_recorder()

    poller =
      start_poller(handle,
        targets: [target],
        provider: ProcessBlockingProvider,
        probe_timeout_ms: 10,
        cycle_timeout_ms: 100
      )

    assert_cycle_completed(poller)
    assert Process.alive?(poller)

    assert {:ok, status} = Poller.status(poller)
    assert status.probes_timeout == 1
    assert status.probe_active == false

    process_event = recorded_events(handle) |> Enum.find(&(&1.kind == "process_sample"))
    assert process_event.attributes["probe_status"] == "timeout"
    assert process_event.attributes["timeout_cancellation"] == "not_guaranteed"
    assert process_event.attributes["cleanup"] in ["observed", "uncertain"]

    send(target, :stop)
  end

  test "protects recorder and configured targets without invoking the provider" do
    protected = spawn(fn -> receive(do: (:stop -> :ok)) end)
    handle = start_recorder()

    poller =
      start_poller(handle,
        targets: [handle.pid, protected],
        host_protected_targets: [protected],
        provider: FailingProvider
      )

    assert_cycle_completed(poller)
    assert {:ok, status} = Poller.status(poller)
    assert status.probes_failed == 1
    assert status.probes_protected == 2

    process_events = Enum.filter(recorded_events(handle), &(&1.kind == "process_sample"))
    assert [_, _] = process_events
    assert Enum.all?(process_events, &(&1.attributes["probe_status"] == "protected"))

    assert Enum.all?(
             process_events,
             &(&1.attributes["target_protection"]["class"] in [
                 "host_declared",
                 "insider_control_plane"
               ])
           )

    send(protected, :stop)
  end

  test "protects fixed OTP targets even when a caller omits every host declaration" do
    logger = Process.whereis(:logger)
    assert is_pid(logger)
    handle = start_recorder()
    poller = start_poller(handle, targets: [logger], provider: FailingProvider)

    assert_cycle_completed(poller)
    assert {:ok, %{probes_protected: 1, probes_failed: 1}} = Poller.status(poller)

    process_event = recorded_events(handle) |> Enum.find(&(&1.kind == "process_sample"))
    assert process_event.attributes["probe_status"] == "protected"
    assert process_event.attributes["target_protection"]["class"] == "beam_otp"
  end

  test "reports exited targets and provider failures without crashing" do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, reason}, 5000
    assert reason in [:normal, :noproc]

    handle = start_recorder()
    default_poller = start_poller(handle, targets: [dead])
    assert_cycle_completed(default_poller)
    assert {:ok, %{probes_exited: 1}} = Poller.status(default_poller)

    failing_handle = start_recorder()

    failing_poller =
      start_poller(failing_handle,
        targets: [self()],
        provider: FailingProvider,
        cycle_timeout_ms: 5_000
      )

    assert_cycle_completed(failing_poller)
    assert {:ok, status} = Poller.status(failing_poller)
    assert status.probes_failed == 2
    assert Process.alive?(failing_poller)
  end

  test "an absolute cycle deadline truncates remaining probes and ticks do not queue" do
    blocked_targets =
      Enum.map(1..15, fn _index -> spawn(fn -> receive(do: (:stop -> :ok)) end) end)

    on_exit(fn -> Enum.each(blocked_targets, &send(&1, :stop)) end)

    targets = [self() | blocked_targets]
    handle = start_recorder()

    poller =
      start_poller(handle,
        targets: targets,
        provider: CoordinatedProvider,
        interval_ms: 10,
        probe_timeout_ms: 1_000,
        cleanup_timeout_ms: 100,
        cycle_timeout_ms: 1_100
      )

    assert_receive {:coordinated_probe_started, worker}, 5000
    assert {:ok, %{probe_active: true}} = Poller.status(poller)
    assert {:ok, %{timer_scheduled: false}} = Poller.status(poller)
    assert {:messages, messages} = Process.info(poller, :messages)
    refute Enum.any?(messages, &match?({:scheduled_poll, _token}, &1))

    :sys.replace_state(poller, fn state ->
      %{
        state
        | config: %{state.config | interval_ms: 60_000},
          cycle: %{state.cycle | deadline_us: System.monotonic_time(:microsecond) - 1}
      }
    end)

    send(worker, :complete_probe)
    assert_cycle_completed(poller)
    assert {:ok, status} = Poller.status(poller)
    assert status.cycles_truncated == 1
    assert status.probes_started == 2
    assert status.probes_truncated == 15

    cycle_event = recorded_events(handle) |> Enum.find(&(&1.kind == "poll_cycle"))
    assert cycle_event.attributes["probe_status"] == "truncated"
    assert cycle_event.attributes["metrics"]["skipped_probes"] == status.probes_truncated
  end

  test "a later probe does not start without its cleanup reserve" do
    unstarted_target = spawn(fn -> receive(do: (:stop -> :ok)) end)
    handle = start_recorder()

    poller =
      start_poller(handle,
        targets: [self(), unstarted_target],
        provider: CoordinatedProvider,
        probe_timeout_ms: 1_000,
        cleanup_timeout_ms: 100,
        cycle_timeout_ms: 1_100
      )

    assert_receive {:coordinated_probe_started, worker}, 5000

    :sys.replace_state(poller, fn state ->
      put_in(state, [:cycle, :deadline_us], System.monotonic_time(:microsecond) + 50_000)
    end)

    send(worker, :complete_probe)
    assert_cycle_completed(poller)

    assert {:ok, status} = Poller.status(poller)
    assert status.probes_started == 2
    assert status.probes_truncated == 1
    assert status.cycles_truncated == 1

    send(unstarted_target, :stop)
  end

  test "recorder loss is visible and never takes down the collector" do
    {:ok, recorder} =
      Recorder.start_link(
        classification: Insider.TestRecorderClassification.binding(),
        max_events: 8
      )

    {:ok, handle} = Recorder.handle(recorder)
    GenServer.stop(recorder)

    poller = start_poller(handle)
    assert_cycle_completed(poller)
    assert {:ok, %{recorder_dropped: 1, events_recorded: 0}} = Poller.status(poller)
    assert Process.alive?(poller)
  end

  test "malformed and oversized provider results fail inside the worker boundary" do
    handle = start_recorder()
    poller = start_poller(handle, targets: [self()], provider: OversizedProvider)

    assert_cycle_completed(poller)
    assert {:ok, %{probes_failed: 2, events_invalid: 0}} = Poller.status(poller)

    assert Enum.all?(recorded_events(handle), fn event ->
             event.attributes["probe_status"] == "failed" and
               event.attributes["metrics"] == %{}
           end)
  end

  test "an abnormal collector exit takes its active probe worker down" do
    handle = start_recorder()

    poller =
      start_poller(handle,
        provider: VmBlockingProvider,
        probe_timeout_ms: 1_000,
        cycle_timeout_ms: 1_010
      )

    assert_eventually(fn -> match?({:ok, %{probe_active: true}}, Poller.status(poller)) end)
    worker = :sys.get_state(poller).inflight.worker
    worker_monitor = Process.monitor(worker)
    Process.unlink(poller)
    Process.exit(poller, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, reason}, 5000
    assert reason in [:killed, :noproc]
  end

  test "automatic cadence, partial probes, and unknown messages remain bounded" do
    handle = start_recorder()

    {:ok, poller} =
      Poller.start_link(
        handle,
        base_options()
        |> Keyword.put(:provider, PartialProvider)
      )

    send(poller, {:unrelated, String.duplicate("ignored", 10)})
    assert_cycle_completed(poller)
    assert {:ok, %{probes_partial: 1, cycles_completed: 1}} = Poller.status(poller)

    assert [event] = recorded_events(handle)
    assert event.attributes["probe_status"] == "partial"
    assert event.attributes["unavailable"] == ["memory"]
  end

  test "quiesce accounts for an in-flight probe and permanently rejects timer races" do
    handle = start_recorder()

    poller =
      start_poller(handle,
        initial_delay_ms: 60_000,
        targets: [self()],
        provider: CoordinatedProvider,
        probe_timeout_ms: 1_000,
        cleanup_timeout_ms: 100,
        cycle_timeout_ms: 1_100
      )

    %{timer: {_timer, scheduled_token}} = :sys.get_state(poller)
    send(poller, {:scheduled_poll, scheduled_token})
    assert_receive {:coordinated_probe_started, worker}, 5000

    deadline = System.monotonic_time(:millisecond) + 500
    task = Task.async(fn -> Poller.quiesce(poller, deadline, 500) end)
    assert_eventually(fn -> :sys.get_state(poller).mode == :quiescing end)
    send(worker, :complete_probe)

    assert {:ok,
            %{
              quiesced: true,
              cycle_active: false,
              probe_active: false,
              timer_scheduled: false
            } = status} = Task.await(task)

    assert status.cycles_completed == 1
    assert status.probes_started == 2
    {:ok, recorder_before} = Recorder.status(handle)

    send(poller, {:scheduled_poll, scheduled_token})
    assert {:ok, ^status} = Poller.status(poller)
    assert {:ok, ^recorder_before} = Recorder.status(handle)
    assert {:ok, ^status} = Poller.quiesce(poller, deadline, 50)
  end

  test "quiesce timeout is responsive and never proves an active worker quiescent" do
    handle = start_recorder()

    poller =
      start_poller(handle,
        provider: VmBlockingProvider,
        probe_timeout_ms: 1_000,
        cleanup_timeout_ms: 100,
        cycle_timeout_ms: 1_100
      )

    assert_eventually(fn -> match?({:ok, %{probe_active: true}}, Poller.status(poller)) end)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :request_expired} =
             Poller.quiesce(poller, started_at + 20, 100)

    assert System.monotonic_time(:millisecond) - started_at < 150

    assert_eventually(fn ->
      match?({:ok, %{quiesced: true, probe_active: false}}, Poller.status(poller))
    end)

    assert {:ok,
            %{
              quiesced: true,
              cycle_active: false,
              probe_active: false,
              timer_scheduled: false,
              probes_started: 1,
              probes_timeout: 1
            }} = Poller.status(poller)
  end

  test "tuple child arguments generate an instance id and stopped APIs fail closed" do
    handle = start_recorder()
    options = Keyword.delete(base_options(), :source_instance_id)
    assert {:ok, poller} = Poller.start_link({handle, options})
    assert String.starts_with?(:sys.get_state(poller).config.source_instance_id, "poller-")
    GenServer.stop(poller)

    assert {:error, :unavailable} = Poller.status(poller)
    assert {:error, :unavailable} = Poller.status(%{})
  end

  test "an untrappable provider exit becomes a failed sample and collector survives" do
    handle = start_recorder()
    poller = start_poller(handle, provider: KilledProvider)

    assert_cycle_completed(poller)
    assert {:ok, %{probes_failed: 1}} = Poller.status(poller)
    assert Process.alive?(poller)
  end

  test "a bounded but non-portable provider counter is rejected by Event v1" do
    handle = start_recorder()
    poller = start_poller(handle, provider: InvalidEventProvider)

    assert_cycle_completed(poller)
    assert {:ok, %{events_invalid: 1, events_recorded: 0}} = Poller.status(poller)
  end

  test "graceful collector shutdown kills and demonitor its active worker" do
    handle = start_recorder()

    poller =
      start_poller(handle,
        provider: VmBlockingProvider,
        probe_timeout_ms: 1_000,
        cycle_timeout_ms: 1_010
      )

    assert_eventually(fn -> match?({:ok, %{probe_active: true}}, Poller.status(poller)) end)
    worker = :sys.get_state(poller).inflight.worker
    monitor = Process.monitor(worker)
    GenServer.stop(poller)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 5000
    assert reason in [:killed, :noproc]
  end

  test "unconfirmed cleanup quarantines the same worker without advancing" do
    handle = start_recorder()

    poller =
      start_poller(handle,
        provider: VmBlockingProvider,
        probe_timeout_ms: 1_000,
        cycle_timeout_ms: 1_010
      )

    assert_eventually(fn -> match?({:ok, %{probe_active: true}}, Poller.status(poller)) end)
    running = :sys.get_state(poller)
    token = running.inflight.token

    assert {:noreply, awaiting} = Poller.handle_info({:probe_timeout, token}, running)
    Process.cancel_timer(awaiting.inflight.cleanup_timer, async: false, info: false)
    cleanup_token = awaiting.inflight.cleanup_token

    assert {:noreply, quarantined} =
             Poller.handle_info({:cleanup_timeout, cleanup_token}, awaiting)

    assert quarantined.inflight.phase == :quarantined
    assert quarantined.inflight.worker == running.inflight.worker
    assert quarantined.inflight.monitor == running.inflight.monitor
    assert quarantined.cycle.probes == running.cycle.probes
    assert quarantined.stats.cleanup_uncertain == running.stats.cleanup_uncertain + 1
  end

  test "the Erlang provider rejects non-process targets without introspection" do
    assert {:error, :protected} = ErlangProvider.process_sample(:not_a_pid)
  end

  test "the Erlang provider normalizes a registered process name" do
    name = Insider.Collector.PollerTest.RegisteredTarget
    target = spawn(fn -> receive(do: (:stop -> :ok)) end)
    Process.register(target, name)

    assert {:ok, :complete, metrics, []} = ErlangProvider.process_sample(target)
    assert metrics["registered_name"] == Atom.to_string(name)
    monitor = Process.monitor(target)
    send(target, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^target, :normal}, 5000
  end

  test "rejects malformed, duplicate, remote, and excessive target configuration" do
    handle = start_recorder()
    targets = Enum.map(1..33, fn _index -> spawn(fn -> receive(do: (:stop -> :ok)) end) end)

    assert {:error, :invalid_options} = Poller.start_link(handle, authority: "test")

    assert {:error, :invalid_options} =
             Poller.start_link(handle, Keyword.put(base_options(), :authority, :not_a_binary))

    assert {:error, :invalid_options} =
             Poller.start_link(handle, base_options() ++ [unknown: true])

    assert {:error, :invalid_options} =
             Poller.start_link(handle, base_options() ++ [targets: [self(), self()]])

    assert {:error, :invalid_options} =
             Poller.start_link(handle, base_options() ++ [targets: targets])

    assert {:error, :invalid_options} =
             Poller.start_link(
               handle,
               Keyword.merge(base_options(),
                 probe_timeout_ms: 15,
                 cleanup_timeout_ms: 10,
                 cycle_timeout_ms: 20
               )
             )

    assert {:error, :invalid_options} = Poller.start_link(:invalid, [])
    assert {:error, :invalid_options} = Poller.start_link(:invalid)
    assert {:error, :invalid_options} = Config.new(:invalid, base_options())

    assert {:error, :invalid_options} =
             Config.new(
               start_recorder(),
               Keyword.put(base_options(), :protected_target_policy, %{})
             )

    assert {:error, :invalid_options} =
             Config.new(start_recorder(), Keyword.put(base_options(), :protected_targets, []))

    Enum.each(targets, &send(&1, :stop))
  end

  defp start_recorder do
    {:ok, recorder} =
      Recorder.start_link(
        classification: Insider.TestRecorderClassification.binding(),
        max_events: 64,
        max_bytes: 1_048_576,
        post_trigger_ms: 0
      )

    {:ok, handle} = Recorder.handle(recorder)
    handle
  end

  defp start_poller(handle, overrides \\ []) do
    options = Keyword.merge(base_options(), overrides)
    {:ok, poller} = Poller.start_link(handle, options)
    poller
  end

  defp base_options do
    [
      authority: "poller-test",
      boot_id: "boot-test",
      clock_id: "monotonic-us",
      initial_delay_ms: 0,
      interval_ms: 60_000,
      source_instance_id: "poller-test"
    ]
  end

  defp recorded_events(handle) do
    trigger = trigger_event()
    assert {:ok, _freeze_id} = Recorder.freeze(handle, trigger)
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    snapshot.events
    |> Enum.map(& &1.event)
    |> Enum.reject(&(&1.id == trigger.id))
  end

  defp trigger_event do
    Event.new!(
      id: "poller-test-trigger",
      node: "test@local",
      boot_id: "boot-test",
      source: "agent",
      kind: "invariant_failed",
      severity: :error,
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: "monotonic-us",
      source_instance_id: "poller-test-suite",
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
      authority: "poller-test",
      redactions: [],
      extensions: %{}
    )
  end

  defp assert_cycle_completed(poller) do
    assert_eventually(fn ->
      match?({:ok, %{cycles_completed: 1, cycle_active: false}}, Poller.status(poller))
    end)
  end

  # The bound was 100 polls of 1 ms, too short on a loaded 2-vCPU runner.
  defp assert_eventually(assertion),
    do: Insider.Test.Eventually.await(assertion, 5_000, "expected poller state was not reached")

  defp secret_process(secret) do
    Process.flag(:sensitive, true)
    Process.put(:dictionary_secret, {secret, "dictionary-secret"})
    send(self(), {:mailbox_secret, secret, "mailbox-secret"})

    receive do
      :stop -> :ok
    end
  end

  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> to_string()
end
