defmodule Insider.Incident.RestartCapture.Owner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Insider.Incident.RestartCapture
  alias Insider.Protocol.Error
  alias Insider.Recorder

  @cleanup_timeout_ms 1_000

  @spec capture(list(), keyword(), map(), integer()) :: RestartCapture.result()
  def capture(observations, options, accounting, started_at) do
    with {:ok, owner, reference} <- start(observations, options, accounting, started_at) do
      await_started(
        owner,
        reference,
        options,
        accounting,
        started_at,
        %{pids: [owner], slots: [:owner]}
      )
    end
  end

  @doc false
  @spec begin(pid(), reference()) :: :ok
  def begin(owner, reference) do
    send(owner, {:capture_begin, reference})
    :ok
  end

  @doc false
  @spec execute(pid(), reference()) :: :ok
  def execute(owner, reference) do
    send(owner, {:capture_execute, reference})
    :ok
  end

  @doc false
  @spec cancel(pid(), reference()) :: :ok
  def cancel(owner, reference) do
    send(owner, {:capture_cancel, reference})
    :ok
  end

  @doc false
  @spec admit(pid(), reference()) :: :ok
  def admit(owner, reference) do
    send(owner, {:capture_admit, reference})
    :ok
  end

  @doc false
  @spec acknowledge(pid(), reference(), :recorder, pid()) :: :ok
  def acknowledge(owner, reference, :recorder, recorder) do
    send(owner, {:capture_resource_ack, reference, :recorder, recorder})
    :ok
  end

  @doc false
  @spec start(list(), keyword(), map(), integer()) ::
          {:ok, pid(), reference()} | RestartCapture.result()
  def start(observations, options, accounting, started_at) do
    reference = make_ref()

    state = %{
      accounting: accounting,
      caller: self(),
      observations: observations,
      options: options,
      reference: reference,
      started_at: started_at
    }

    case GenServer.start(__MODULE__, state) do
      {:ok, owner} -> {:ok, owner, reference}
      {:error, _reason} -> recorder_unavailable(accounting, started_at)
    end
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(state.caller)

    timer =
      Process.send_after(
        self(),
        {:capture_deadline, state.reference},
        Keyword.fetch!(state.options, :deadline_monotonic_ms),
        abs: true
      )

    send(state.caller, {:capture_owner_started, state.reference, self()})

    {:ok,
     Map.merge(state, %{
       caller_monitor: caller_monitor,
       clock: nil,
       handle: nil,
       inventory: %{owner: %{monitor: nil, pid: self(), status: :active}},
       phase: :started,
       timer: timer
     })}
  end

  @impl true
  def handle_info(
        {:capture_admit, reference},
        %{reference: reference, phase: :started} = state
      ) do
    state = reserve_resource(state, :recorder)

    case start_recorder(state.observations, state.options) do
      {:ok, recorder, recorder_monitor, clock} ->
        state = admit_resource(state, :recorder, recorder, recorder_monitor)
        {:noreply, %{state | clock: clock}}

      {:error, reason} ->
        recorder_failed(reason, state)
    end
  end

  def handle_info(
        {:capture_resource_ack, reference, :recorder, recorder},
        %{reference: reference, phase: :recorder_published} = state
      ) do
    if resource_matches?(state, :recorder, recorder) do
      case Recorder.handle(recorder) do
        {:ok, handle} ->
          send(state.caller, {:capture_owner_ready, state.reference, self()})
          {:noreply, %{state | handle: handle, phase: :ready}}

        {:error, reason} ->
          recorder_failed(reason, state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:capture_begin, reference},
        %{reference: reference, phase: :ready} = state
      ) do
    owner = self()
    state = reserve_resource(state, :worker)

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:capture_execute, reference} when reference == state.reference ->
              result =
                RestartCapture.execute(
                  state.handle,
                  state.clock,
                  state.observations,
                  state.options,
                  state.accounting,
                  state.started_at
                )

              send(owner, {:capture_outcome, state.reference, self(), result})
          end
        end,
        [:link, :monitor]
      )

    state = admit_resource(state, :worker, worker, worker_monitor)

    {:noreply, state}
  end

  def handle_info(
        {:capture_execute, reference},
        %{reference: reference, phase: :worker_published} = state
      ) do
    %{pid: worker} = inventory_entry(state, :worker)
    send(worker, {:capture_execute, reference})
    {:noreply, %{state | phase: :executing}}
  end

  def handle_info({:capture_cancel, reference}, %{reference: reference} = state) do
    finalize(terminal_result(:cancelled, state), state)
  end

  def handle_info(
        {:capture_outcome, reference, worker, result},
        %{reference: reference, phase: :executing} = state
      ) do
    if resource_matches?(state, :worker, worker),
      do: finalize(result, state),
      else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, caller, _reason},
        %{caller_monitor: monitor, caller: caller} = state
      ) do
    case cleanup(state) do
      {_cleanup, cleaned_state} -> {:stop, :normal, cleaned_state}
    end
  end

  def handle_info({:capture_deadline, reference}, %{reference: reference} = state) do
    finalize(terminal_result(:timeout, state), state)
  end

  def handle_info({:DOWN, monitor, :process, resource, reason}, state) do
    cond do
      resource_matches?(state, :recorder, resource, monitor) ->
        recorder_failed(reason, mark_down(state, :recorder))

      resource_matches?(state, :worker, resource, monitor) ->
        result =
          RestartCapture.open_failure(state.handle, state.accounting, state.started_at, reason)

        finalize(result, mark_down(state, :worker))

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp await_started(owner, reference, options, accounting, started_at, observed) do
    monitor = Process.monitor(owner)

    receive do
      {:capture_owner_started, ^reference, ^owner} ->
        admit(owner, reference)

        await_ready(owner, monitor, reference, options, accounting, started_at, observed)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        owner_failed(accounting, started_at, observed)
    after
      owner_wait(options) ->
        abandon(owner, monitor, reference, accounting, started_at, observed)
    end
  end

  defp await_ready(owner, monitor, reference, options, accounting, started_at, observed) do
    receive do
      {:capture_resource_reserved, ^reference, kind} ->
        await_ready(
          owner,
          monitor,
          reference,
          options,
          accounting,
          started_at,
          reserve_observed(observed, kind)
        )

      {:capture_resource, ^reference, resource, kind} ->
        if kind == :recorder, do: acknowledge(owner, reference, kind, resource)

        await_ready(
          owner,
          monitor,
          reference,
          options,
          accounting,
          started_at,
          observe_resource(observed, kind, resource)
        )

      {:capture_owner_ready, ^reference, ^owner} ->
        begin(owner, reference)

        await_result(
          owner,
          monitor,
          reference,
          options,
          accounting,
          started_at,
          observed
        )

      {:capture_result, ^reference, result} ->
        await_result_down(owner, monitor, reference, result)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        owner_failed(accounting, started_at, observed)
    after
      owner_wait(options) ->
        abandon(owner, monitor, reference, accounting, started_at, observed)
    end
  end

  defp await_result(owner, monitor, reference, options, accounting, started_at, observed) do
    receive do
      {:capture_resource_reserved, ^reference, kind} ->
        await_result(
          owner,
          monitor,
          reference,
          options,
          accounting,
          started_at,
          reserve_observed(observed, kind)
        )

      {:capture_resource, ^reference, resource, kind} ->
        execute(owner, reference)

        await_result(
          owner,
          monitor,
          reference,
          options,
          accounting,
          started_at,
          observe_resource(observed, kind, resource)
        )

      {:capture_result, ^reference, result} ->
        await_result_down(owner, monitor, reference, result)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        owner_failed(accounting, started_at, observed)
    after
      owner_wait(options) ->
        abandon(owner, monitor, reference, accounting, started_at, observed)
    end
  end

  defp await_result_down(owner, monitor, reference, result) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> result
    after
      @cleanup_timeout_ms ->
        Process.exit(owner, :kill)
        drain_abandoned(owner, monitor, reference, System.monotonic_time(:millisecond) + 100)
        put_cleanup(result, %{status: :uncertain})
    end
  end

  defp owner_wait(options) do
    max(
      @cleanup_timeout_ms,
      Keyword.fetch!(options, :deadline_monotonic_ms) - System.monotonic_time(:millisecond) +
        @cleanup_timeout_ms
    )
  end

  defp abandon(owner, monitor, reference, accounting, started_at, observed) do
    Process.exit(owner, :kill)
    drain_abandoned(owner, monitor, reference, System.monotonic_time(:millisecond) + 100)

    {:timeout,
     accounting
     |> put_in([:consumption, :duration_us], elapsed(started_at))
     |> put_resource_counts(length(observed.pids), length(observed.slots))
     |> Map.put(:cleanup, %{status: :uncertain})}
  end

  defp drain_abandoned(owner, monitor, reference, deadline) do
    receive do
      {:capture_result, ^reference, _result} ->
        drain_abandoned(owner, monitor, reference, deadline)

      {:capture_owner_started, ^reference, ^owner} ->
        drain_abandoned(owner, monitor, reference, deadline)

      {:capture_owner_ready, ^reference, ^owner} ->
        drain_abandoned(owner, monitor, reference, deadline)

      {:capture_resource_reserved, ^reference, _kind} ->
        drain_abandoned(owner, monitor, reference, deadline)

      {:capture_resource, ^reference, _resource, _kind} ->
        drain_abandoned(owner, monitor, reference, deadline)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Process.demonitor(monitor, [:flush])

        receive do
          {:capture_result, ^reference, _result} -> :ok
        after
          0 -> :ok
        end
    end
  end

  defp recorder_failed(reason, state) do
    result = RestartCapture.recorder_failure(state.accounting, state.started_at, reason)
    finalize(result, state)
  end

  defp finalize(result, state) do
    cancel_timer(state.timer)
    {cleanup, state} = cleanup(state)

    result =
      result
      |> put_cleanup(cleanup)
      |> put_resource_accounting(state)
      |> put_duration(state.started_at)

    send(state.caller, {:capture_result, state.reference, result})
    {:stop, :normal, state}
  end

  defp cleanup(state) do
    {worker_cleanup, state} = cleanup_resource(state, :worker)
    {recorder_cleanup, state} = cleanup_resource(state, :recorder)

    status =
      if worker_cleanup == :complete and recorder_cleanup == :complete,
        do: :complete,
        else: :uncertain

    {%{status: status}, state}
  end

  defp cleanup_resource(state, kind) do
    case inventory_entry(state, kind) do
      %{pid: resource, monitor: monitor, status: :active} ->
        if kind == :recorder,
          do: request_recorder_stop(resource),
          else: Process.exit(resource, :kill)

        status = await_process_down(resource, monitor)
        state = if status == :complete, do: mark_down(state, kind), else: state
        {status, state}

      _reserved_absent_or_down ->
        {:complete, state}
    end
  end

  defp start_recorder(observations, options) do
    initial = observations |> List.first() |> then(&if(&1, do: elem(&1, 1), else: 0))
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, initial)
    export_policy = Keyword.fetch!(options, :export_policy)

    recorder_options = [
      classification: {export_policy.sensitivities.event, export_policy.redaction_policy},
      clock: fn -> :atomics.get(clock, 1) end,
      max_bytes: Keyword.fetch!(options, :max_bytes),
      max_events: Keyword.fetch!(options, :max_events),
      post_trigger_ms: 0,
      pre_trigger_ms: 1_000,
      rate_limit_count: Keyword.fetch!(options, :max_events)
    ]

    case Recorder.start_link(recorder_options) do
      {:ok, recorder} -> {:ok, recorder, Process.monitor(recorder), clock}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :recorder_unavailable}
  catch
    _kind, reason -> {:error, reason}
  end

  defp request_recorder_stop(recorder) do
    if Process.alive?(recorder), do: GenServer.stop(recorder, :normal, @cleanup_timeout_ms)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp await_process_down(process, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^process, _reason} -> :complete
    after
      @cleanup_timeout_ms -> :uncertain
    end
  end

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp put_cleanup({:ok, capsules, accounting}, cleanup),
    do: {:ok, capsules, %{accounting | cleanup: cleanup}}

  defp put_cleanup({:error, %Error{} = error, accounting}, cleanup),
    do: {:error, error, %{accounting | cleanup: cleanup}}

  defp put_cleanup({status, accounting}, cleanup) when status in [:timeout, :cancelled],
    do: {status, %{accounting | cleanup: cleanup}}

  defp recorder_unavailable(accounting, started_at) do
    error =
      Error.new(:operation_failed, "restart capture failed", %{reason: "recorder_unavailable"})

    accounting =
      accounting
      |> put_in([:consumption, :duration_us], elapsed(started_at))
      |> put_resource_counts(0, 1)

    {:error, error, accounting}
  end

  defp reserve_resource(state, kind) do
    send(state.caller, {:capture_resource_reserved, state.reference, kind})

    phase = if kind == :recorder, do: :recorder_reserved, else: :worker_reserved
    %{state | inventory: Map.put(state.inventory, kind, :reserved), phase: phase}
  end

  defp admit_resource(state, kind, resource, monitor) do
    send(state.caller, {:capture_resource, state.reference, resource, kind})

    phase = if kind == :recorder, do: :recorder_published, else: :worker_published

    entry = %{monitor: monitor, pid: resource, status: :active}
    %{state | inventory: Map.put(state.inventory, kind, entry), phase: phase}
  end

  defp inventory_entry(state, kind), do: Map.get(state.inventory, kind)

  defp resource_matches?(state, kind, resource),
    do: match?(%{pid: ^resource, status: :active}, inventory_entry(state, kind))

  defp resource_matches?(state, kind, resource, monitor),
    do:
      match?(
        %{pid: ^resource, monitor: ^monitor, status: :active},
        inventory_entry(state, kind)
      )

  defp mark_down(state, kind) do
    inventory =
      Map.update!(state.inventory, kind, fn entry ->
        %{entry | monitor: nil, status: :down}
      end)

    %{state | inventory: inventory}
  end

  defp terminal_result(status, %{handle: nil} = state) when status in [:timeout, :cancelled],
    do: {status, state.accounting}

  defp terminal_result(:timeout, state),
    do: RestartCapture.open_timeout(state.handle, state.accounting, state.started_at)

  defp terminal_result(:cancelled, state),
    do: RestartCapture.open_cancelled(state.handle, state.accounting, state.started_at)

  defp owner_failed(accounting, started_at, observed) do
    accounting =
      accounting
      |> put_in([:consumption, :duration_us], elapsed(started_at))
      |> put_resource_counts(length(observed.pids), length(observed.slots))

    error = Error.new(:operation_failed, "restart capture failed", %{reason: "owner_failed"})
    {:error, error, %{accounting | cleanup: %{status: :uncertain}}}
  end

  defp observe_resource(observed, kind, resource),
    do: %{pids: add_once(observed.pids, resource), slots: add_once(observed.slots, kind)}

  defp reserve_observed(observed, kind),
    do: %{observed | slots: add_once(observed.slots, kind)}

  defp add_once(items, item) do
    if item in items, do: items, else: [item | items]
  end

  defp put_resource_accounting({:ok, capsules, accounting}, state),
    do: {:ok, capsules, resource_accounting(accounting, state)}

  defp put_resource_accounting({:error, %Error{} = error, accounting}, state),
    do: {:error, error, resource_accounting(accounting, state)}

  defp put_resource_accounting({status, accounting}, state)
       when status in [:timeout, :cancelled],
       do: {status, resource_accounting(accounting, state)}

  defp resource_accounting(accounting, state),
    do:
      put_resource_counts(
        accounting,
        Enum.count(state.inventory, fn {_kind, entry} -> is_map(entry) end),
        map_size(state.inventory)
      )

  defp put_resource_counts(accounting, pid_count, slot_count)
       when is_integer(pid_count) and is_integer(slot_count) and pid_count >= 0 and
              slot_count >= pid_count do
    accounting
    |> put_in([:consumption, :resources], slot_count)
    |> put_in([:consumption, :resource_pids], pid_count)
    |> put_in([:consumption, :unmaterialized_resource_slots], slot_count - pid_count)
  end

  defp put_duration({:ok, capsules, accounting}, started_at),
    do: {:ok, capsules, put_in(accounting, [:consumption, :duration_us], elapsed(started_at))}

  defp put_duration({:error, %Error{} = error, accounting}, started_at),
    do: {:error, error, put_in(accounting, [:consumption, :duration_us], elapsed(started_at))}

  defp put_duration({status, accounting}, started_at) when status in [:timeout, :cancelled],
    do: {status, put_in(accounting, [:consumption, :duration_us], elapsed(started_at))}

  defp elapsed(started_at), do: System.monotonic_time(:microsecond) - started_at
end
