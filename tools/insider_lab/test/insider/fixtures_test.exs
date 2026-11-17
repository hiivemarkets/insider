defmodule Insider.FixturesTest do
  use ExUnit.Case, async: true

  alias Insider.Fixtures
  alias Insider.Fixtures.Observation
  alias Insider.Fixtures.RestartStorm
  alias Insider.Fixtures.RestartStorm.Owner, as: RestartStormOwner

  @moduletag capture_log: true

  test "restart storm has a stable recurrence while its control stays up" do
    faulty = Fixtures.run!(:restart_storm, :faulty)
    healthy = Fixtures.run!(:restart_storm, :healthy)

    assert event_count(faulty, :worker_started) == 4
    assert event_count(faulty, :worker_crashed) == 3
    assert event_count(healthy, :worker_started) == 1
    assert event_count(healthy, :worker_crashed) == 0
    assert faulty.resources |> Enum.drop(2) |> Enum.uniq() |> length() == 4
    assert_clean(faulty)
    assert_clean(healthy)
    refute_received {:EXIT, _pid, _reason}
  end

  test "restart storm owner rejects forged lifecycle tokens and cleans every resource" do
    {:ok, owner, token} =
      RestartStormOwner.start(System.unique_integer([:positive]), :faulty, observer: self())

    assert_receive {:restart_storm_ready, ^token, ^owner, [supervisor, counter]}
    assert_receive {:restart_storm_resource, ^token, worker, :worker}

    resources = [owner, supervisor, counter, worker]
    monitors = Enum.map(resources, &{Process.monitor(&1), &1})

    send(owner, {:begin, make_ref()})
    send(owner, {:cancel, make_ref()})
    :sys.get_state(owner)

    assert Enum.all?(resources, &Process.alive?/1)
    refute_received {:restart_storm_stopped, ^token, _, _, _}

    send(owner, {:cancel, token})

    assert_receive {:restart_storm_stopped, ^token, :cancelled, stopped, %{status: :complete}}
    assert Enum.sort(stopped) == Enum.sort([supervisor, counter, worker])
    assert_down(monitors)
  end

  test "restart storm owner deadline cleans every resource before reporting timeout" do
    {:ok, owner, token} =
      RestartStormOwner.start(System.unique_integer([:positive]), :healthy, observer: self())

    assert_receive {:restart_storm_ready, ^token, ^owner, [supervisor, counter]}
    assert_receive {:restart_storm_resource, ^token, worker, :worker}

    resources = [owner, supervisor, counter, worker]
    monitors = Enum.map(resources, &{Process.monitor(&1), &1})

    assert_receive {:restart_storm_stopped, ^token, :timeout, stopped, %{status: :complete}},
                   1_500

    assert Enum.sort(stopped) == Enum.sort([supervisor, counter, worker])
    assert_down(monitors)
  end

  test "restart worker ignores stale tokens and arbitrary messages" do
    run_id = System.unique_integer([:positive])
    token = make_ref()
    counter = start_supervised!({Agent, fn -> %{begun: false, generation: 0} end})

    {:ok, worker} =
      GenServer.start(RestartStorm.Worker, {self(), run_id, :faulty, counter, token})

    worker_monitor = Process.monitor(worker)

    assert_receive {:fixture_worker, ^run_id, :worker_started, ^worker, 1, _monotonic_time}
    send(worker, {:fixture_begin, make_ref()})
    send(worker, {:fixture_worker, run_id, :worker_crashed, self(), 99, 0})
    send(worker, :arbitrary)
    :sys.get_state(worker)
    assert Process.alive?(worker)
    refute_received {:fixture_worker, ^run_id, :worker_crashed, ^worker, 1, _monotonic_time}

    send(worker, {:fixture_begin, token})

    # The crash event is pre-terminal; the monitor is the causal completion boundary.
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :fixture_crash}, 1_000

    assert_received {:fixture_worker, ^run_id, :worker_crashed, ^worker, 1, _monotonic_time}
  end

  test "minimum and odd mailbox batches remain bounded" do
    minimum = Fixtures.run!(:mailbox_growth, :faulty, work_items: 1)
    odd = Fixtures.run!(:mailbox_growth, :healthy, work_items: 9)

    assert minimum.samples.queue_growth == [0, 1]
    assert minimum.settled.progress == 1
    assert odd.samples.progress_samples == [4, 9]
    assert_clean(minimum)
    assert_clean(odd)
  end

  test "mailbox growth separates queued work from completed progress" do
    faulty = Fixtures.run!(:mailbox_growth, :faulty, work_items: 20)
    healthy = Fixtures.run!(:mailbox_growth, :healthy, work_items: 20)

    assert faulty.samples.queued >= 20
    assert faulty.samples.queue_growth == [10, 20]
    assert faulty.samples.progress == 0
    assert faulty.settled.queued == 0
    assert healthy.samples.progress == 20
    assert healthy.samples.queued == 0
    assert healthy.samples.progress_samples == [10, 20]
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "leaked task is observable before deterministic cleanup" do
    faulty = Fixtures.run!(:leaked_task, :faulty)
    healthy = Fixtures.run!(:leaked_task, :healthy)

    assert faulty.samples.live_tasks == 1
    assert healthy.samples.live_tasks == 0
    assert hd(faulty.events).metadata.live_tasks == 1
    assert hd(healthy.events).metadata.live_tasks == 0
    assert faulty.settled.live_tasks == 0
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "late effect is ordered after timeout only in the faulty fixture" do
    faulty = Fixtures.run!(:late_effect, :faulty)
    healthy = Fixtures.run!(:late_effect, :healthy)

    assert event_index(faulty, :operation_timed_out) < event_index(faulty, :effect_observed)
    assert event_count(faulty, :operation_timed_out) == 1
    assert event_count(faulty, :effect_observed) == 1
    assert event_index(healthy, :effect_observed) < event_index(healthy, :operation_completed)
    refute Enum.any?(healthy.events, &(&1.kind == :operation_timed_out))
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "Telemetry fixture emits an incomplete or paired lifecycle" do
    faulty = Fixtures.run!(:telemetry_lifecycle, :faulty)
    healthy = Fixtures.run!(:telemetry_lifecycle, :healthy)

    assert event_count(faulty, :telemetry_start) == 1
    assert event_count(faulty, :telemetry_stop) == 0
    assert event_count(healthy, :telemetry_start) == 1
    assert event_count(healthy, :telemetry_stop) == 1
    assert Enum.all?(faulty.events, &(&1.metadata.run_id == faulty.run_id))
    assert Enum.all?(healthy.events, &(&1.metadata.run_id == healthy.run_id))
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "semantic fixture exposes values without declaring the detector outcome" do
    faulty = Fixtures.run!(:semantic_invariant, :faulty)
    healthy = Fixtures.run!(:semantic_invariant, :healthy)

    assert faulty.samples.total == 10
    assert Enum.sum(faulty.samples.items) == 9
    assert healthy.samples.total == Enum.sum(healthy.samples.items)
    refute Map.has_key?(faulty.samples, :violation)
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "overload fixture produces bounded deterministic pressure inputs" do
    faulty = Fixtures.run!(:recorder_overload, :faulty, capacity: 10)
    healthy = Fixtures.run!(:recorder_overload, :healthy, capacity: 10)

    assert faulty.samples.queued == 11
    assert healthy.samples.queued == 10
    assert faulty.samples.offered == 11
    assert faulty.samples.accepted == 10
    assert healthy.samples.offered == healthy.samples.accepted
    assert Enum.map(faulty.events, & &1.sequence) == Enum.to_list(1..10)
    assert Enum.map(healthy.events, & &1.sequence) == Enum.to_list(1..10)
    assert_clean(faulty)
    assert_clean(healthy)
  end

  test "parallel runs use isolated identities and leave no live fixture processes" do
    observations =
      1..12
      |> Task.async_stream(
        fn _index -> Fixtures.run!(:leaked_task, :faulty) end,
        ordered: false,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, observation} -> observation end)

    assert observations |> Enum.map(& &1.run_id) |> Enum.uniq() |> length() == 12
    assert Enum.all?(observations, &(&1.cleanup.status == :complete))

    assert Enum.all?(
             observations,
             &Enum.all?(&1.resources, fn pid -> not Process.alive?(pid) end)
           )
  end

  test "concurrent restart and Telemetry runs do not cross-contaminate callers" do
    results =
      1..8
      |> Task.async_stream(
        fn index ->
          scenario = if rem(index, 2) == 0, do: :restart_storm, else: :telemetry_lifecycle
          observation = Fixtures.run!(scenario, :faulty)
          {observation, fixture_messages()}
        end,
        ordered: false,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    observations = Enum.map(results, &elem(&1, 0))

    assert observations |> Enum.map(& &1.run_id) |> Enum.uniq() |> length() == 8
    assert Enum.all?(observations, &(&1.cleanup.status == :complete))
    assert Enum.all?(results, fn {_observation, messages} -> messages == [] end)
  end

  test "rejects unknown scenarios, variants, and unbounded options" do
    assert {:error, :unknown_scenario} = Fixtures.run(:unknown, :faulty)
    assert {:error, :unknown_variant} = Fixtures.run(:restart_storm, :maybe)

    assert {:error, :invalid_options} =
             Fixtures.run(:mailbox_growth, :faulty, work_items: 100_000)

    assert {:error, :invalid_options} =
             Fixtures.run(:mailbox_growth, :faulty, capacity: 10)

    assert {:error, :invalid_options} = Fixtures.run(:recorder_overload, :faulty, capacity: 0)
  end

  defp event_count(%Observation{} = observation, kind),
    do: Enum.count(observation.events, &(&1.kind == kind))

  defp event_index(%Observation{} = observation, kind),
    do: Enum.find_index(observation.events, &(&1.kind == kind))

  defp assert_clean(%Observation{} = observation) do
    assert observation.cleanup.status == :complete
    assert Enum.all?(observation.resources, fn pid -> not Process.alive?(pid) end)
  end

  defp assert_down(monitors) do
    Enum.each(monitors, fn {monitor, pid} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    end)
  end

  defp fixture_messages do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.filter(messages, &fixture_message?/1)
  end

  defp fixture_message?({:fixture_telemetry, _run_id, _event_name, _measurements}), do: true

  defp fixture_message?({:fixture_worker, _run_id, _kind, _pid, _generation, _monotonic_time}),
    do: true

  defp fixture_message?({:restart_storm_ready, _token, _owner, _resources}), do: true
  defp fixture_message?({:restart_storm_resource, _token, _resource, _kind}), do: true
  defp fixture_message?({:restart_storm_complete, _token, _observation, _cleanup}), do: true

  defp fixture_message?({:restart_storm_stopped, _token, _status, _resources, _cleanup}),
    do: true

  defp fixture_message?({:EXIT, _pid, _reason}), do: true
  defp fixture_message?(_message), do: false
end
