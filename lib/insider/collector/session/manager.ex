defmodule Insider.Collector.Session.Manager do
  @moduledoc false

  use GenServer

  alias Insider.Collector.Admission
  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Session
  alias Insider.Collector.Session.Handle
  alias Insider.Collector.Session.StartupGuard
  alias Insider.Collector.Telemetry

  @history_limit 32
  @maximum_admitted_calls 256
  @start_timeout_ms 1_000
  @control_timeout_ms 1_000
  @evidence_timeout_ms 5_000
  @cleanup_timeout_ms 200
  @control_cleanup_reserve_ms 2 * @cleanup_timeout_ms
  @control_outer_margin_ms 100
  @maximum_read_bytes 16 * 1_024 * 1_024

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec start(term(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def start(host_policy, options) when is_list(options),
    do:
      admitted_call(
        {:start, self(), host_policy, options},
        @start_timeout_ms + 2 * @cleanup_timeout_ms
      )

  def start(_host_policy, _options), do: {:error, :invalid_options}

  @spec health(Handle.t()) :: {:ok, map()} | {:error, term()}
  def health(%Handle{} = handle),
    do: call_handle(handle, :health, @control_timeout_ms + @cleanup_timeout_ms)

  def health(_handle), do: {:error, :invalid_handle}

  @spec flush_evidence(Handle.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def flush_evidence(%Handle{} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@evidence_timeout_ms do
    call_handle(handle, :flush_evidence, timeout_ms, timeout_ms + @control_outer_margin_ms)
  end

  def flush_evidence(%Handle{}, _timeout_ms), do: {:error, :invalid_options}
  def flush_evidence(_handle, _timeout_ms), do: {:error, :invalid_handle}

  @spec flush_ingress_evidence(Handle.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def flush_ingress_evidence(%Handle{} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@evidence_timeout_ms do
    call_handle(
      handle,
      :flush_ingress_evidence,
      timeout_ms,
      timeout_ms + @control_outer_margin_ms
    )
  end

  def flush_ingress_evidence(%Handle{}, _timeout_ms), do: {:error, :invalid_options}
  def flush_ingress_evidence(_handle, _timeout_ms), do: {:error, :invalid_handle}

  @spec seal_ingress(Handle.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def seal_ingress(%Handle{} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@evidence_timeout_ms do
    call_handle(handle, :seal_ingress, timeout_ms, timeout_ms + @control_outer_margin_ms)
  end

  def seal_ingress(%Handle{}, _timeout_ms), do: {:error, :invalid_options}
  def seal_ingress(_handle, _timeout_ms), do: {:error, :invalid_handle}

  @spec record_event(Handle.t(), term(), pos_integer()) ::
          :ok | {:dropped, atom()} | {:error, term()}
  def record_event(%Handle{} = handle, %Insider.Event{} = event, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@evidence_timeout_ms do
    call_handle(
      handle,
      {:record_event, event},
      timeout_ms,
      timeout_ms + @control_outer_margin_ms
    )
  end

  def record_event(%Handle{}, _event, _timeout_ms), do: {:error, :invalid_options}
  def record_event(_handle, _event, _timeout_ms), do: {:error, :invalid_handle}

  # `finalize_summaries: true` records pending summary intervals before the
  # read; the live owner uses it for a subscriber's final read. Cursor
  # `:latest` reads from the newest receipt, so it returns no events.
  @spec read_events(Handle.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def read_events(%Handle{} = handle, cursor, options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- [:limit, :max_bytes, :timeout_ms, :finalize_summaries],
         limit when is_integer(limit) and limit in 1..1_000 <- Keyword.get(options, :limit, 100),
         max_bytes when is_integer(max_bytes) and max_bytes in 1..@maximum_read_bytes <-
           Keyword.get(options, :max_bytes, 1_024 * 1_024),
         timeout_ms when is_integer(timeout_ms) and timeout_ms in 1..@evidence_timeout_ms <-
           Keyword.get(options, :timeout_ms, @evidence_timeout_ms),
         finalize when is_boolean(finalize) <- Keyword.get(options, :finalize_summaries, false) do
      if cursor == :latest or (is_integer(cursor) and cursor >= 0) do
        call_handle(
          handle,
          {:read_events, cursor, limit, max_bytes, timeout_ms, finalize},
          timeout_ms,
          timeout_ms + @control_outer_margin_ms
        )
      else
        {:error, :invalid_cursor}
      end
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  def read_events(%Handle{}, _cursor, _options), do: {:error, :invalid_options}
  def read_events(_handle, _cursor, _options), do: {:error, :invalid_handle}

  @spec stop(Handle.t()) :: {:ok, map()} | {:error, term()}
  def stop(%Handle{} = handle),
    do:
      call_handle(
        handle,
        :stop,
        @control_timeout_ms + @control_cleanup_reserve_ms,
        @control_timeout_ms + @control_cleanup_reserve_ms + @control_outer_margin_ms
      )

  def stop(_handle), do: {:error, :invalid_handle}

  @spec kill(Handle.t()) :: {:ok, map()} | {:error, term()}
  def kill(%Handle{} = handle),
    do:
      call_handle(
        handle,
        :kill,
        @control_timeout_ms + @control_cleanup_reserve_ms,
        @control_timeout_ms + @control_cleanup_reserve_ms + @control_outer_margin_ms
      )

  def kill(_handle), do: {:error, :invalid_handle}

  @impl GenServer
  def init(_options) do
    Process.flag(:message_queue_data, :off_heap)
    _ = LoggerCollector.reclaim_stale_filter(:insider_logger)
    startup_guard = StartupGuard.new()
    admission = Admission.new()
    :persistent_term.put({__MODULE__, self()}, admission)

    {:ok,
     %{
       active: nil,
       admission: admission,
       history: [],
       ownership_fun: &Session.ownership/3,
       start_child_fun: &DynamicSupervisor.start_child/2,
       startup_guard: startup_guard
     }}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, self()})
    _ = state
    :ok
  end

  @impl GenServer
  def handle_call(
        {:admitted, admission, deadline, request},
        from,
        %{admission: admission} = state
      ) do
    release_admission(state.admission)

    if expired?(deadline),
      do: {:reply, {:error, :request_expired}, state},
      else: dispatch(request, deadline, from, state)
  end

  # Direct same-node messages are outside the trusted public API admission
  # boundary. They are deliberately not accepted as lifecycle requests.
  def handle_call(_message, _from, state), do: {:reply, {:error, :invalid_request}, state}

  # A read's events pass through this process; once they are replied they are
  # garbage, so they are collected at once instead of keeping the heap they
  # grew until a later collection.
  @impl GenServer
  def handle_continue(:collect, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:session_terminal, pid, token, receipt},
        %{active: %{pid: pid, token: token} = active} = state
      ) do
    active = %{active | pending_receipt: receipt, phase: :terminal_pending}
    {:noreply, maybe_finalize_terminal(%{state | active: active})}
  end

  def handle_info(
        {:session_start_result, worker, {:ok, pid}},
        %{active: %{worker: worker} = active} = state
      ) do
    Process.demonitor(active.worker_monitor, [:flush])

    active =
      active
      |> Map.put(:pid, pid)
      |> Map.put(:monitor, Process.monitor(pid))
      |> Map.put(:phase, :quarantined)

    {:noreply, reconcile_unadopted(%{state | active: active})}
  end

  def handle_info(
        {:session_start_result, worker, {:error, _reason}},
        %{active: %{worker: worker} = active} = state
      ) do
    Process.demonitor(active.worker_monitor, [:flush])
    receipt = Session.startup_failure_receipt(active.id, active.incarnation, :timeout)
    {:noreply, retain_terminal(%{state | active: nil}, active, receipt)}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{active: %{worker: worker, worker_monitor: monitor} = active} = state
      ) do
    # A vanished worker without its exact start_child result is not proof that
    # DynamicSupervisor will not later materialize a child. Stay fail-closed.
    {:noreply, %{state | active: %{active | phase: :quarantined}}}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{active: %{monitor: monitor, pid: pid} = active} = state
      ) do
    active = %{
      active
      | down_reason: reason,
        down_observed: true,
        pending_receipt: active.pending_receipt || forced_cleanup_receipt(active),
        phase: :terminal_pending
    }

    {:noreply, maybe_finalize_terminal(%{state | active: active})}
  end

  def handle_info({:reconcile_terminal, token}, %{active: %{token: token} = active} = state) do
    {:noreply, reconcile_terminal(%{state | active: active})}
  end

  def handle_info(
        {:terminal_absence_result, token, query, result},
        %{active: %{token: token, absence_query: query} = active} = state
      ) do
    cancel_absence_timer(active.absence_timer)
    active = %{active | absence_query: nil, absence_timer: nil}
    {:noreply, apply_absence_result(%{state | active: active}, result)}
  end

  def handle_info(
        {:terminal_absence_timeout, token, query},
        %{active: %{token: token, absence_query: query} = active} = state
      ) do
    # Keep the one worker marked in-flight. Starting another query here would
    # accumulate blocked workers when DynamicSupervisor is suspended.
    {:noreply, %{state | active: %{active | absence_timer: nil}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch({:start, owner, host_policy, options}, deadline, _from, %{active: nil} = state) do
    case Session.prepare(owner, host_policy, options) do
      {:ok, config} ->
        {reply, state} = start_session(config, state, deadline)
        {:reply, reply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp dispatch({:start, _owner, _host_policy, _options}, _deadline, _from, state),
    do: {:reply, {:error, :session_already_active}, state}

  defp dispatch({:health, handle}, deadline, _from, state) do
    {reply, state} = health_reply(state, handle, deadline)
    {:reply, reply, state}
  end

  defp dispatch({:flush_evidence, handle}, deadline, _from, state) do
    {reply, state} = evidence_reply(state, handle, deadline)
    {:reply, reply, state}
  end

  defp dispatch({:flush_ingress_evidence, handle}, deadline, _from, state) do
    {reply, state} = ingress_evidence_reply(state, handle, deadline)
    {:reply, reply, state}
  end

  defp dispatch({:seal_ingress, handle}, deadline, _from, state) do
    {reply, state} = running_session_reply(state, handle, deadline, &Session.seal_ingress/3)
    {:reply, reply, state}
  end

  defp dispatch({{:record_event, event}, handle}, deadline, _from, state) do
    record = &Session.record_event(&1, &2, event, &3)
    {reply, state} = running_session_reply(state, handle, deadline, record)
    {:reply, reply, state}
  end

  defp dispatch(
         {{:read_events, _cursor, _limit, _max_bytes, _timeout, _finalize} = read, handle},
         deadline,
         _from,
         state
       ) do
    {reply, state} = read_events_reply(state, handle, read, deadline)
    {:reply, reply, state, {:continue, :collect}}
  end

  defp dispatch({action, handle}, deadline, _from, state) when action in [:stop, :kill] do
    {reply, state} = terminate_reply(state, handle, action, deadline)
    {:reply, reply, state}
  end

  defp dispatch(_request, _deadline, _from, state),
    do: {:reply, {:error, :invalid_request}, state}

  defp start_session(config, state, request_deadline) do
    token = make_ref()
    incarnation = "s-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
    started_at = System.monotonic_time(:millisecond)
    deadline = min(request_deadline, deadline_after(@start_timeout_ms))
    # Called when the start ran past its budget, by either side's clock.
    timed_out = fn ->
      Session.start_timeout_receipt(
        config.id,
        incarnation,
        max(deadline - started_at, 0),
        System.monotonic_time(:millisecond) - started_at
      )
    end

    session_admission = Admission.new()
    parent = self()

    config =
      config
      |> Map.put(:startup_guard, state.startup_guard)
      |> Map.put(:session_admission, session_admission)

    :ok = StartupGuard.authorize(state.startup_guard, token, deadline)
    start_child_fun = state.start_child_fun

    worker =
      spawn(fn ->
        result =
          start_child_fun.(
            Insider.Collector.Session.Supervisor,
            {Session, {parent, config, token, incarnation}}
          )

        send(parent, {:session_start_result, self(), result})
      end)

    worker_monitor = Process.monitor(worker)

    receive do
      {:session_start_result, ^worker, {:ok, pid}} ->
        Process.demonitor(worker_monitor, [:flush])
        revoke_start_authorization(state.startup_guard, token)
        monitor = Process.monitor(pid)
        active = active(config, token, incarnation, session_admission, pid, monitor)

        # Reserve the bounded kill + DOWN observation window before asking the
        # child to commit its ownership inventory.  The caller's outer timeout
        # covers this reservation, so no successful handle can be reported
        # after the absolute start deadline.
        ownership_timeout =
          min(
            @cleanup_timeout_ms,
            max(remaining_timeout(deadline) - @control_cleanup_reserve_ms, 0)
          )

        case state.ownership_fun.(pid, session_admission, ownership_timeout) do
          {:ok, %{components: components, telemetry_policy: telemetry_policy}}
          when is_map(components) ->
            if ownership_inventory?(config, components, telemetry_policy) and
                 not expired?(deadline) do
              active = %{active | component_pids: components, telemetry_policy: telemetry_policy}
              {{:ok, handle(active)}, %{state | active: active}}
            else
              fail_start_ownership(state, active, deadline)
            end

          _other ->
            # An ownership response is the adoption commit.  A started child
            # without this exact inventory remains Manager-owned until its
            # monitor has gone DOWN and the DynamicSupervisor confirms it is
            # absent; it can never be returned as a usable handle.
            fail_start_ownership(state, active, deadline)
        end

      # The session found its authorization expired and cancelled its own
      # startup: the start ran past its budget, so it is a timeout, and no
      # child exists.
      {:session_start_result, ^worker, {:error, :startup_cancelled}} ->
        Process.demonitor(worker_monitor, [:flush])
        revoke_start_authorization(state.startup_guard, token)
        {{:error, timed_out.()}, state}

      {:session_start_result, ^worker, {:error, reason}} ->
        Process.demonitor(worker_monitor, [:flush])
        revoke_start_authorization(state.startup_guard, token)
        {{:error, reason}, state}

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        # The child may already have been admitted even though its worker never
        # delivered the result. Without that exact result we cannot identify
        # or safely release its slot; the session root must reset both owners.
        revoke_start_authorization(state.startup_guard, token)

        active =
          pending_start(config, token, incarnation, session_admission, worker, worker_monitor)

        {{:error, Session.startup_failure_receipt(config.id, incarnation, reason)},
         %{state | active: %{active | phase: :quarantined}}}
    after
      remaining_timeout(deadline) ->
        # Revoke before returning. The worker remains alive because only its
        # exact DynamicSupervisor result can prove whether a child exists.
        revoke_start_authorization(state.startup_guard, token)

        active =
          pending_start(config, token, incarnation, session_admission, worker, worker_monitor)

        {{:error, timed_out.()}, %{state | active: active}}
    end
  end

  defp pending_start(config, token, incarnation, session_admission, worker, worker_monitor) do
    %{
      id: config.id,
      incarnation: incarnation,
      phase: :starting,
      session_admission: session_admission,
      token: token,
      worker: worker,
      worker_monitor: worker_monitor
    }
  end

  defp terminate_reply(%{active: active} = state, %Handle{} = handle, action, deadline)
       when active != nil do
    cond do
      not matches?(active, handle) ->
        {terminal_reply(state, handle), state}

      active.phase != :running ->
        {{:error, :cleanup_in_progress}, state}

      true ->
        case remaining_timeout(deadline) - @control_cleanup_reserve_ms do
          remaining when remaining <= 0 ->
            {{:error, :request_expired}, state}

          session_budget ->
            case Session.terminate(
                   active.pid,
                   active.session_admission,
                   action,
                   min(@control_timeout_ms, session_budget)
                 ) do
              {:ok, receipt} ->
                active = %{active | pending_receipt: receipt, phase: :terminal_pending}
                state = %{state | active: active}

                case await_terminal_down(active, deadline) do
                  {:down, reason} ->
                    state = %{
                      state
                      | active: %{active | down_observed: true, down_reason: reason}
                    }

                    state = maybe_finalize_terminal(state)
                    state = await_terminal_absence(state, deadline)

                    finalized_terminal_reply(state, handle, deadline)

                  :pending ->
                    schedule_terminal_reconciliation(active)
                    {{:error, :cleanup_in_progress}, state}
                end

              {:error, _reason} ->
                case terminate_child_bounded(active) do
                  {:down, reason} ->
                    active = %{
                      active
                      | down_observed: true,
                        down_reason: reason,
                        pending_receipt: forced_cleanup_receipt(active),
                        phase: :terminal_pending
                    }

                    state = %{state | active: active} |> maybe_finalize_terminal()
                    state = await_terminal_absence(state, deadline)

                    finalized_terminal_reply(state, handle, deadline)

                  :residual ->
                    {{:error, :cleanup_in_progress},
                     %{state | active: %{active | phase: :terminal_pending}}}
                end
            end
        end
    end
  end

  defp terminate_reply(state, handle, _action, _deadline),
    do: {terminal_reply(state, handle), state}

  defp finalized_terminal_reply(state, handle, deadline) do
    case terminal(state.history, handle) do
      {:ok, receipt} ->
        if expired?(deadline),
          do: {{:error, :request_expired}, state},
          else: {{:ok, receipt}, state}

      :error ->
        {{:error, :cleanup_in_progress}, state}
    end
  end

  defp health_reply(%{active: active, history: history} = state, %Handle{} = handle, deadline)
       when active != nil do
    cond do
      not matches?(active, handle) ->
        {terminal_health(history, handle), state}

      active.phase != :running ->
        {{:error, :cleanup_in_progress}, state}

      true ->
        case remaining_timeout(deadline) do
          0 ->
            {{:error, :request_expired}, state}

          remaining ->
            case Session.health(
                   active.pid,
                   active.session_admission,
                   min(@control_timeout_ms, remaining)
                 ) do
              {:error, :unavailable} ->
                if Process.alive?(active.pid) do
                  # Health is evidence, not authority.  A live but
                  # unresponsive Session must remain controllable by stop/kill.
                  {{:error, :unavailable}, state}
                else
                  # The monitor's DOWN may be queued behind this call.  Do not
                  # infer a terminal receipt or release ownership before it is
                  # observed and the supervisor query subsequently proves
                  # absence.
                  active = %{
                    active
                    | pending_receipt: active.pending_receipt || forced_cleanup_receipt(active),
                      phase: :terminal_pending
                  }

                  {{:error, :cleanup_in_progress}, %{state | active: active}}
                end

              reply ->
                {reply, state}
            end
        end
    end
  end

  defp health_reply(%{history: history} = state, handle, _deadline),
    do: {terminal_health(history, handle), state}

  defp evidence_reply(state, handle, deadline),
    do: running_session_reply(state, handle, deadline, &Session.flush_evidence/3)

  defp ingress_evidence_reply(state, handle, deadline),
    do: running_session_reply(state, handle, deadline, &Session.flush_ingress_evidence/3)

  defp read_events_reply(
         state,
         handle,
         {:read_events, cursor, limit, max_bytes, timeout, finalize},
         deadline
       ) do
    running_session_reply(state, handle, deadline, fn pid, admission, remaining ->
      Session.read_events(
        pid,
        admission,
        {cursor, limit, max_bytes, finalize},
        min(timeout, remaining)
      )
    end)
  end

  # Bounded nonterminal evidence calls share one admission rule: only the exact
  # running incarnation is called, and never past the request deadline.
  defp running_session_reply(%{active: active} = state, %Handle{} = handle, deadline, call)
       when active != nil do
    cond do
      not matches?(active, handle) ->
        {{:error, :expired_or_unknown_session}, state}

      active.phase != :running ->
        {{:error, :cleanup_in_progress}, state}

      true ->
        case remaining_timeout(deadline) do
          0 ->
            {{:error, :request_expired}, state}

          remaining ->
            {call.(active.pid, active.session_admission, min(@evidence_timeout_ms, remaining)),
             state}
        end
    end
  end

  defp running_session_reply(state, _handle, _deadline, _call),
    do: {{:error, :expired_or_unknown_session}, state}

  defp reconcile_unadopted(%{active: %{pid: _pid} = active} = state) do
    case terminate_child_bounded(active) do
      {:down, _reason} -> finish_start_timeout(%{state | active: active})
      :residual -> %{state | active: %{active | phase: :quarantined}}
    end
  end

  defp fail_start_ownership(state, active, deadline) do
    active = %{
      active
      | pending_receipt: Session.startup_cleanup_receipt(active, forced_cleanup(active)),
        phase: :terminal_pending
    }

    state = %{state | active: active}

    state =
      case terminate_child_bounded(active) do
        {:down, reason} ->
          state
          |> put_in([:active, :down_observed], true)
          |> put_in([:active, :down_reason], reason)
          |> maybe_finalize_terminal()

        :residual ->
          # The child is known, but not safely adopted.  Retain this single
          # slot until a future monitor DOWN starts the authoritative absence
          # query; returning a handle here would lose cleanup authority.
          state
      end

    state = await_terminal_absence(state, deadline)

    {{:error,
      Session.startup_failure_receipt(active.id, active.incarnation, :inventory_unavailable)},
     state}
  end

  defp finish_start_timeout(%{active: active} = state) do
    if is_nil(Map.get(active, :pid)) do
      # No result means no proof. Keep this bounded worker/slot quarantined
      # until the exact start_child call returns or the one_for_all root resets.
      %{state | active: %{active | phase: :quarantined}}
    else
      case manager_child_absence(Map.get(active, :pid)) do
        :absent ->
          receipt = Session.startup_failure_receipt(active.id, active.incarnation, :timeout)
          retain_terminal(%{state | active: nil}, active, receipt)

        _other ->
          %{state | active: %{active | phase: :quarantined}}
      end
    end
  end

  defp await_terminal_down(active, deadline) do
    receive do
      {:DOWN, monitor, :process, pid, reason}
      when monitor == active.monitor and pid == active.pid ->
        {:down, reason}
    after
      remaining_timeout(deadline) -> :pending
    end
  end

  defp maybe_finalize_terminal(
         %{active: %{phase: :terminal_pending, down_observed: true} = active} = state
       ),
       do: begin_absence_query(state, active)

  defp maybe_finalize_terminal(state), do: state

  defp begin_absence_query(%{active: %{absence_query: query}} = state, _active)
       when not is_nil(query),
       do: state

  defp begin_absence_query(state, active) do
    query = make_ref()
    parent = self()

    spawn(fn ->
      result = dynamic_child_absence(active.pid)
      send(parent, {:terminal_absence_result, active.token, query, result})
    end)

    timer =
      Process.send_after(
        self(),
        {:terminal_absence_timeout, active.token, query},
        @cleanup_timeout_ms
      )

    %{state | active: %{active | absence_query: query, absence_timer: timer}}
  end

  defp apply_absence_result(%{active: active} = state, :absent) do
    Process.demonitor(active.monitor, [:flush])

    receipt =
      Map.get(active, :pending_receipt) ||
        Session.unexpected_receipt(active, Map.get(active, :down_reason), :absent)

    receipt = Session.manager_ownership_released(receipt)
    retain_terminal(%{state | active: nil}, active, receipt)
  end

  defp apply_absence_result(%{active: active} = state, _result) do
    schedule_terminal_reconciliation(active)
    state
  end

  defp reconcile_terminal(%{active: %{phase: :terminal_pending, down_observed: true}} = state),
    do: maybe_finalize_terminal(state)

  defp reconcile_terminal(state), do: state

  defp schedule_terminal_reconciliation(%{absence_query: query}) when not is_nil(query), do: :ok

  defp schedule_terminal_reconciliation(active) do
    Process.send_after(self(), {:reconcile_terminal, active.token}, @cleanup_timeout_ms)
    :ok
  end

  defp await_terminal_absence(%{active: %{absence_query: query} = active} = state, deadline)
       when not is_nil(query) do
    receive do
      {:terminal_absence_result, token, ^query, result} when token == active.token ->
        cancel_absence_timer(active.absence_timer)
        active = %{active | absence_query: nil, absence_timer: nil}
        apply_absence_result(%{state | active: active}, result)

      {:terminal_absence_timeout, token, ^query} when token == active.token ->
        %{state | active: %{active | absence_timer: nil}}
    after
      remaining_timeout(deadline) -> state
    end
  end

  defp cancel_absence_timer(nil), do: :ok
  defp cancel_absence_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp forced_cleanup_receipt(active),
    do: Session.forced_cleanup_receipt(active, forced_cleanup(active))

  defp forced_cleanup(active) do
    component_statuses =
      [:calls, :poller, :otel, :telemetry, :logger, :recorder]
      # The calls and otel components are listed only when configured, so
      # the receipts of sessions without them keep their shape.
      |> Enum.filter(&(&1 != :calls or :calls in active.configured_components))
      |> Enum.filter(&(&1 != :otel or :otel in active.configured_components))
      |> Map.new(fn component ->
        {Atom.to_string(component), forced_component_status(active, component)}
      end)

    cleanup = %{
      "components" => component_statuses,
      "logger_filter" => forced_logger_filter_status(),
      "manager_ownership" => "pending_manager_removal",
      "monitors" => "absent",
      "policy_reference" => "absent",
      "recorder_ets" => Map.fetch!(component_statuses, "recorder"),
      # The killed Session cannot confirm its timer inventory. Do not convert
      # process death into a claim about outstanding timer messages.
      "session_timers" => "unavailable",
      "telemetry_handler" => forced_telemetry_handler_status(active)
    }

    cleanup
  end

  defp forced_component_status(active, component) do
    case Map.fetch(active.component_pids, component) do
      {:ok, pid} when is_pid(pid) ->
        if(Process.alive?(pid), do: "residual", else: "absent")

      _other ->
        if component == :recorder or component in active.configured_components,
          do: "unavailable",
          else: "absent"
    end
  rescue
    _error -> "unavailable"
  end

  defp forced_logger_filter_status do
    _ = LoggerCollector.reclaim_stale_filter(:insider_logger)
    %{filters: filters} = :logger.get_primary_config()

    if Enum.any?(filters, fn {id, _filter} -> id == :insider_logger end),
      do: "residual",
      else: "absent"
  rescue
    _error -> "unavailable"
  end

  defp forced_telemetry_handler_status(%{telemetry_policy: nil}), do: "absent"

  defp forced_telemetry_handler_status(active) do
    _ = Telemetry.reclaim_stale_handler(active.telemetry_policy, "insider-session-telemetry")

    present? =
      active.telemetry_policy.event_names
      |> Enum.flat_map(&:telemetry.list_handlers/1)
      |> Enum.any?(&(&1.id == "insider-session-telemetry"))

    if present?, do: "residual", else: "absent"
  rescue
    _error -> "unavailable"
  end

  defp terminate_child_bounded(%{pid: pid, monitor: monitor}) when is_pid(pid) do
    parent = self()
    token = make_ref()

    spawn(fn ->
      send(
        parent,
        {:dynamic_terminate_result, token,
         DynamicSupervisor.terminate_child(Insider.Collector.Session.Supervisor, pid)}
      )
    end)

    receive do
      {:dynamic_terminate_result, ^token, _result} -> :ok
    after
      @cleanup_timeout_ms -> :ok
    end

    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} -> {:down, reason}
    after
      @cleanup_timeout_ms -> :residual
    end
  rescue
    _error -> :residual
  end

  defp ownership_inventory?(config, components, telemetry_policy) do
    expected = MapSet.new([:recorder | config.components])

    MapSet.new(Map.keys(components)) == expected and
      Enum.all?(components, fn {component, pid} ->
        component in expected and is_pid(pid)
      end) and telemetry_policy == config.telemetry_policy
  end

  defp active(config, token, incarnation, session_admission, pid, monitor),
    do: %{
      absence_query: nil,
      absence_timer: nil,
      component_pids: %{},
      configured_components: config.components,
      id: config.id,
      incarnation: incarnation,
      down_observed: false,
      down_reason: nil,
      monitor: monitor,
      pending_receipt: nil,
      phase: :running,
      pid: pid,
      session_admission: session_admission,
      telemetry_policy: config.telemetry_policy,
      token: token
    }

  defp terminal_reply(state, %Handle{} = handle) do
    case terminal(state.history, handle),
      do: (
        {:ok, receipt} -> {:ok, receipt}
        :error -> {:error, :expired_or_unknown_session}
      )
  end

  defp terminal_health(history, handle) do
    case terminal(history, handle),
      do: (
        {:ok, receipt} -> {:ok, Session.terminal_health(receipt)}
        :error -> {:error, :expired_or_unknown_session}
      )
  end

  defp retain_terminal(state, active, receipt) do
    entry = Map.take(active, [:id, :incarnation, :token]) |> Map.put(:receipt, receipt)
    %{state | history: Enum.take([entry | state.history], @history_limit)}
  end

  defp terminal(history, handle),
    do:
      case(Enum.find(history, &matches?(&1, handle)),
        do: (
          %{receipt: receipt} -> {:ok, receipt}
          _other -> :error
        )
      )

  defp matches?(entry, %Handle{} = handle),
    do:
      entry.id == handle.id and entry.incarnation == handle.incarnation and
        entry.token == handle.token and handle.manager == self()

  defp handle(active),
    do: %Handle{
      id: active.id,
      incarnation: active.incarnation,
      manager: self(),
      token: active.token
    }

  defp call_handle(handle, action, timeout) do
    case current_manager(handle) do
      {:ok, manager} ->
        admitted_call({action, handle}, timeout - @cleanup_timeout_ms, timeout, manager)

      error ->
        error
    end
  end

  defp call_handle(handle, action, deadline_budget, outer_timeout) do
    case current_manager(handle) do
      {:ok, manager} -> admitted_call({action, handle}, deadline_budget, outer_timeout, manager)
      error -> error
    end
  end

  defp current_manager(%Handle{id: id, incarnation: incarnation, manager: manager, token: token})
       when is_binary(id) and is_binary(incarnation) and is_pid(manager) and is_reference(token) do
    case Process.whereis(__MODULE__) do
      ^manager -> {:ok, manager}
      _other -> {:error, :expired_or_unknown_session}
    end
  end

  defp current_manager(_handle), do: {:error, :invalid_handle}

  defp admitted_call(request, timeout),
    do:
      admitted_call(request, timeout - @cleanup_timeout_ms, timeout, Process.whereis(__MODULE__))

  defp admitted_call(request, deadline_budget, outer_timeout, manager) do
    deadline = deadline_after(deadline_budget)

    with pid when is_pid(pid) <- manager,
         {:ok, admission} <- manager_admission(pid),
         :ok <- Admission.acquire(admission, @maximum_admitted_calls) do
      safe_call(pid, {:admitted, admission, deadline, request}, outer_timeout)
    else
      :overloaded -> {:error, :mailbox_overloaded}
      _other -> {:error, :unavailable}
    end
  end

  @spec manager_admission(pid()) :: {:ok, Admission.t()} | {:error, :unavailable}
  defp manager_admission(pid) do
    case :persistent_term.get({__MODULE__, pid}, :missing) do
      %Admission{} = admission -> {:ok, admission}
      _other -> {:error, :unavailable}
    end
  end

  @spec release_admission(Admission.t()) :: :ok
  defp release_admission(admission), do: Admission.release(admission)

  @spec revoke_start_authorization(StartupGuard.t(), reference()) :: :ok
  defp revoke_start_authorization(guard, token), do: StartupGuard.revoke(guard, token)

  defp manager_child_absence(nil), do: :absent

  defp manager_child_absence(pid) do
    parent = self()
    query = make_ref()

    spawn(fn -> send(parent, {:bounded_child_absence, query, dynamic_child_absence(pid)}) end)

    receive do
      {:bounded_child_absence, ^query, result} -> result
    after
      @cleanup_timeout_ms -> :residual
    end
  end

  defp dynamic_child_absence(pid) do
    children = DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor)

    if Enum.any?(children, fn {_id, child, _type, _modules} -> child == pid end),
      do: :residual,
      else: :absent
  rescue
    _error -> :residual
  end

  defp deadline_after(milliseconds),
    do: System.monotonic_time(:millisecond) + max(milliseconds, 1)

  defp remaining_timeout(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp expired?(deadline),
    do: not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline

  defp safe_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
