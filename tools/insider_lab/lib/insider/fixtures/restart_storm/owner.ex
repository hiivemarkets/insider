defmodule Insider.Fixtures.RestartStorm.Owner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Insider.Fixtures.Observation
  alias Insider.Fixtures.RestartStorm

  @timeout_ms 1_000

  @spec run(pos_integer(), :faulty | :healthy) :: Observation.t()
  def run(run_id, variant) do
    {:ok, owner, token} = start(run_id, variant)
    monitor = Process.monitor(owner)

    receive do
      {:restart_storm_ready, ^token, ^owner, _resources} -> send(owner, {:begin, token})
    after
      @timeout_ms -> raise "fixture restart storm did not start"
    end

    receive do
      {:restart_storm_complete, ^token, observation, %{status: :complete}} ->
        Process.demonitor(monitor, [:flush])
        observation

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        raise "fixture restart storm owner failed: #{inspect(reason)}"
    after
      @timeout_ms * 2 -> raise "fixture restart storm did not converge"
    end
  end

  @spec start(pos_integer(), :faulty | :healthy, keyword()) :: {:ok, pid(), reference()}
  def start(run_id, variant, options \\ []) do
    token = make_ref()

    case GenServer.start(__MODULE__, %{
           caller: self(),
           observer: Keyword.get(options, :observer),
           run_id: run_id,
           token: token,
           variant: variant
         }) do
      {:ok, owner} -> {:ok, owner, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(state.caller)
    {:ok, counter} = Agent.start_link(fn -> %{begun: false, generation: 0} end)

    {:ok, supervisor} =
      Supervisor.start_link(
        RestartStorm,
        {self(), state.run_id, state.variant, counter, state.token}
      )

    monitors = monitor_resource(counter, %{})
    monitors = monitor_resource(supervisor, monitors)
    resources = [supervisor, counter]

    send(state.caller, {:restart_storm_ready, state.token, self(), resources})

    timer = Process.send_after(self(), {:deadline, state.token}, @timeout_ms)
    expected_starts = if state.variant == :faulty, do: 4, else: 1
    expected = expected_starts + if(state.variant == :faulty, do: 3, else: 0)

    {:ok,
     Map.merge(state, %{
       begun: false,
       caller_monitor: caller_monitor,
       counter: counter,
       events: [],
       monitors: monitors,
       remaining: expected,
       resources: resources,
       supervisor: supervisor,
       timer: timer,
       workers: []
     })}
  end

  @impl true
  def handle_info({:begin, token}, %{token: token, begun: false} = state) do
    Agent.update(state.counter, &%{&1 | begun: true})
    Enum.each(state.workers, &send(&1, {:fixture_begin, token}))
    maybe_complete(%{state | begun: true})
  end

  def handle_info({:cancel, token}, %{token: token} = state),
    do: finish(:cancelled, state)

  def handle_info({:deadline, token}, %{token: token} = state),
    do: finish(:timeout, state)

  def handle_info(
        {:DOWN, monitor, :process, caller, _reason},
        %{caller_monitor: monitor, caller: caller} = state
      ) do
    {_cleanup, state} = cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:fixture_worker, run_id, :worker_started, worker, generation, monotonic_time},
        %{run_id: run_id} = state
      ) do
    monitors = monitor_resource(worker, state.monitors)
    notify(state.observer, {:restart_storm_resource, state.token, worker, :worker})
    if state.begun, do: send(worker, {:fixture_begin, state.token})

    state = %{
      state
      | events: [{:worker_started, monotonic_time, %{generation: generation}} | state.events],
        monitors: monitors,
        remaining: state.remaining - 1,
        resources: [worker | state.resources],
        workers: [worker | state.workers]
    }

    maybe_complete(state)
  end

  def handle_info(
        {:fixture_worker, run_id, :worker_crashed, _worker, generation, monotonic_time},
        %{run_id: run_id} = state
      ) do
    state = %{
      state
      | events: [{:worker_crashed, monotonic_time, %{generation: generation}} | state.events],
        remaining: state.remaining - 1
    }

    maybe_complete(state)
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, %{state | monitors: Map.delete(state.monitors, monitor)}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp maybe_complete(%{begun: true, remaining: 0} = state), do: finish(:complete, state)
  defp maybe_complete(state), do: {:noreply, state}

  defp finish(outcome, state) do
    Process.cancel_timer(state.timer)
    observation = if outcome == :complete, do: observation(state)
    resources = state.resources
    {cleanup, state} = cleanup(state)

    message =
      case outcome do
        :complete -> {:restart_storm_complete, state.token, observation, cleanup}
        terminal -> {:restart_storm_stopped, state.token, terminal, resources, cleanup}
      end

    send(state.caller, message)
    {:stop, :normal, state}
  end

  defp cleanup(%{resources: []} = state), do: {%{status: :complete}, state}

  defp cleanup(state) do
    Enum.each([state.supervisor, state.counter], fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    remaining = await_down(state.monitors, deadline)

    Enum.each(remaining, fn {_monitor, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    remaining = await_down(remaining, System.monotonic_time(:millisecond) + 100)
    cleanup = if map_size(remaining) == 0, do: %{status: :complete}, else: %{status: :uncertain}
    {cleanup, %{state | monitors: remaining, resources: []}}
  end

  defp await_down(monitors, _deadline) when map_size(monitors) == 0, do: monitors

  defp await_down(monitors, deadline) do
    receive do
      {:DOWN, monitor, :process, _pid, _reason} ->
        await_down(Map.delete(monitors, monitor), deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> monitors
    end
  end

  defp monitor_resource(pid, monitors) do
    monitor = Process.monitor(pid)
    Map.put(monitors, monitor, pid)
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok

  defp observation(state) do
    events =
      state.events
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {{kind, monotonic_time, metadata}, index} ->
        %{sequence: index, kind: kind, monotonic_time: monotonic_time, metadata: metadata}
      end)

    %Observation{
      run_id: state.run_id,
      scenario: :restart_storm,
      variant: state.variant,
      events: events,
      resources: Enum.reverse(state.resources)
    }
  end
end
