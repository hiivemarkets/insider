defmodule Insider.Sentinel.Sandbox.Runner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Insider.Event.Canonical
  alias Insider.Policy
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Result
  alias Insider.Provenance
  alias Insider.Sentinel.Sandbox.Body
  alias Insider.Sentinel.Sandbox.ProviderCall
  alias Insider.Sentinel.Sandbox.Registry
  alias Insider.Sentinel.Sandbox.Target

  @stop_ack_timeout_ms 50

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    deadline = options.decision.dispatch_deadline_monotonic
    body_stop_timeout_ms = body_stop_timeout_ms(Map.get(options, :body))

    {body_deadline, body_stop_deadline} =
      phase_deadlines(deadline, options.cleanup_timeout_ms, body_stop_timeout_ms)

    owner_id = :crypto.strong_rand_bytes(32)
    caller_monitor = Process.monitor(options.caller)

    case Registry.register(
           options.registry,
           owner_id,
           self(),
           options.provider,
           options.target,
           deadline
         ) do
      :ok ->
        body_timer = Process.send_after(self(), :body_deadline, body_deadline, abs: true)
        send(self(), :begin)

        {:ok,
         Map.merge(options, %{
           acquired: false,
           active: nil,
           body: Map.get(options, :body),
           body_admitted: false,
           body_result: nil,
           body_stop_timeout_ms: body_stop_timeout_ms,
           body_stop_deadline: body_stop_deadline,
           body_deadline: body_deadline,
           body_timer: body_timer,
           cancel_waiters: [],
           caller_monitor: caller_monitor,
           cleanup_reference: nil,
           cleanup_timer: nil,
           completed_provider_pids: MapSet.new(),
           deadline: deadline,
           observed: nil,
           owner_id: owner_id,
           owner_fingerprint: fingerprint(owner_id),
           phase: :starting,
           provider_started: false,
           started_at: System.monotonic_time(:microsecond),
           stop_ack_reference: nil,
           stop_ack_timer: nil,
           terminal: nil
         })}

      :error ->
        {:stop, :lease_registration_failed}
    end
  end

  @impl true
  def handle_call({:cancel, token}, _from, %{token: token, phase: :cleanup} = state),
    do: {:reply, :ok, state}

  def handle_call({:cancel, token}, from, %{token: token} = state) do
    state = stop_body(:cancelled, state)

    if state.active do
      {:noreply, %{state | cancel_waiters: [from | state.cancel_waiters]}}
    else
      state = %{state | cancel_waiters: [from | state.cancel_waiters]}
      {:noreply, begin_cleanup(state)}
    end
  end

  def handle_call({:cancel, _token}, _from, state),
    do: {:reply, {:error, Error.new(:invalid_request, "sandbox handle is invalid")}, state}

  @impl true
  def handle_info(:begin, %{terminal: nil} = state), do: start_acquire(state)
  def handle_info(:begin, state), do: {:noreply, begin_cleanup(state)}

  def handle_info({reference, result}, %{active: %{reference: reference} = active} = state) do
    if Map.get(active, :kind) == :body and Body.valid_result?(result) do
      send(active.pid, {:sandbox_body_receipt_ack, reference})
    end

    {:noreply, %{state | active: Map.put(active, :result, result)}}
  end

  def handle_info(
        {:DOWN, monitor, :process, caller, _reason},
        %{caller_monitor: monitor, caller: caller} = state
      ) do
    {:noreply, stop_body(:cancelled, %{state | caller: nil})}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.active do
      %{monitor: ^monitor, pid: ^pid} = active ->
        disarm_timer(state.stop_ack_timer)

        completed_provider_pids =
          if Map.get(active, :exit_observed, false),
            do: state.completed_provider_pids,
            else: MapSet.put(state.completed_provider_pids, pid)

        state = %{
          state
          | active: nil,
            completed_provider_pids: completed_provider_pids,
            stop_ack_reference: nil,
            stop_ack_timer: nil
        }

        consume_active_down(active, state)

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:body_deadline, state), do: {:noreply, stop_body(:timeout, state)}

  def handle_info(
        {:stop_ack_deadline, reference},
        %{phase: :stopping, stop_ack_reference: reference, active: active} = state
      ) do
    Process.demonitor(active.monitor, [:flush])

    case Registry.quarantine_active(state.registry, state.owner_id, active.pid) do
      {:ok, proof} ->
        state = %{
          state
          | active: nil,
            phase: :cleanup,
            stop_ack_reference: nil,
            stop_ack_timer: nil,
            terminal: stop_ack_terminal(state.terminal)
        }

        state = reply_cancel_waiters(state, {:error, termination_unconfirmed_error()})
        finish(proof, state)

      :error ->
        state = reply_cancel_waiters(state, {:error, termination_unconfirmed_error()})
        {:stop, :stop_ack_transfer_failed, state}
    end
  end

  def handle_info({:sandbox_cleanup, reference, proof}, %{cleanup_reference: reference} = state) do
    disarm_timer(state.cleanup_timer)
    finish(proof, state)
  end

  def handle_info(:cleanup_deadline, %{phase: :cleanup} = state) do
    finish(
      %{
        status: :uncertain,
        release: :failed,
        remaining_count: 0,
        remaining_fingerprint: nil
      },
      state
    )
  end

  def handle_info({:EXIT, pid, _reason}, %{active: %{pid: pid} = active} = state),
    do: {:noreply, %{state | active: Map.put(active, :exit_observed, true)}}

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    if MapSet.member?(state.completed_provider_pids, pid) do
      {:noreply,
       %{state | completed_provider_pids: MapSet.delete(state.completed_provider_pids, pid)}}
    else
      stop_for_linked_exit(state)
    end
  end

  def handle_info({:EXIT, _sender, _reason}, state), do: stop_for_linked_exit(state)

  def handle_info(_message, state), do: {:noreply, state}

  defp stop_for_linked_exit(state) do
    state = stop_body({:error, "sandbox executor stopped"}, state)
    if state.active, do: {:noreply, state}, else: {:noreply, begin_cleanup(state)}
  end

  @impl true
  def terminate(_reason, state) do
    terminate_owned_work(state.active, state)
    :ok
  end

  defp terminate_owned_work(%{kind: :body} = active, state) do
    Process.exit(active.pid, :kill)
    shutdown_deadline = bounded_body_stop_deadline(state)

    receive do
      {:DOWN, monitor, :process, pid, _reason}
      when monitor == active.monitor and pid == active.pid ->
        Registry.clear_active(state.registry, state.owner_id, active.pid)
    after
      max(0, shutdown_deadline - System.monotonic_time(:millisecond)) ->
        Registry.quarantine_active(state.registry, state.owner_id, active.pid)
    end
  end

  defp terminate_owned_work(active, state) do
    terminate_active_process(active)
    confirm_active_termination(active, state)
  end

  defp start_acquire(state) do
    now = System.monotonic_time(:millisecond)

    if Policy.dispatchable?(state.decision) and state.body_deadline > now do
      start_provider(
        :acquire,
        [state.owner_id, state.target, state.body_deadline],
        %{state | phase: :acquiring}
      )
    else
      {:noreply, begin_cleanup(%{state | terminal: :timeout})}
    end
  end

  defp start_observe(state) do
    start_provider(
      :observe,
      [state.owner_id, state.body_deadline],
      %{state | phase: :observing}
    )
  end

  defp start_provider(operation, arguments, state) do
    case ProviderCall.start(
           self(),
           state.provider,
           operation,
           arguments,
           state.body_deadline,
           link: true
         ) do
      {:ok, call} ->
        active = call |> Map.put(:kind, :provider) |> Map.put(:operation, operation)
        {:noreply, %{state | active: active, provider_started: true}}

      {:error, :provider_deadline_expired, :not_started} ->
        {:noreply, begin_cleanup(%{state | terminal: :timeout})}
    end
  end

  defp consume_provider_result(:acquire, :ok, state),
    do: start_observe(%{state | acquired: true})

  defp consume_provider_result(:acquire, _result, state),
    do: {:noreply, begin_cleanup(%{state | terminal: {:error, "sandbox acquisition failed"}})}

  defp consume_provider_result(:observe, {:ok, provenance}, state) do
    case Provenance.decode_map(provenance) do
      {:ok, observed} ->
        observed_wire = Provenance.to_wire_map(observed)

        if observed_wire == state.target.provenance do
          observed_state = %{state | observed: observed_wire}

          if state.body,
            do: start_body(observed_state),
            else: {:noreply, begin_cleanup(%{observed_state | terminal: :ok})}
        else
          {:noreply,
           begin_cleanup(%{
             state
             | observed: observed_wire,
               terminal: {:error, "sandbox target fingerprint mismatched"}
           })}
        end

      {:error, _error} ->
        {:noreply, begin_cleanup(%{state | terminal: {:error, "sandbox observation failed"}})}
    end
  end

  defp consume_provider_result(:observe, _result, state),
    do: {:noreply, begin_cleanup(%{state | terminal: {:error, "sandbox observation failed"}})}

  defp consume_provider_result(_operation, :failed, state),
    do: {:noreply, begin_cleanup(%{state | terminal: {:error, "sandbox provider failed"}})}

  defp start_body(state) do
    if state.body_deadline > System.monotonic_time(:millisecond),
      do: start_live_body(state),
      else: {:noreply, begin_cleanup(%{state | terminal: :timeout})}
  end

  defp start_live_body(state) do
    reference = make_ref()
    cancellation_reference = make_ref()
    gate = make_ref()
    parent = self()
    body = state.body
    receipt_ack_deadline = state.body_stop_deadline

    arguments = %{
      cancellation_reference: cancellation_reference,
      deadline: state.body_deadline,
      input: body.input,
      observed_provenance: state.observed,
      owner_id: state.owner_id,
      stop_deadline: state.body_stop_deadline,
      target: state.target
    }

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:begin_sandbox_body, ^gate} -> :ok
          end

          result = body.module.run(arguments)
          send(parent, {reference, result})

          receive do
            {:sandbox_body_receipt_ack, ^reference} -> :ok
          after
            max(0, receipt_ack_deadline - System.monotonic_time(:millisecond)) ->
              exit(:body_receipt_unacknowledged)
          end
        end,
        [:link, :monitor]
      )

    active = %{
      cancellation_reference: cancellation_reference,
      kind: :body,
      monitor: monitor,
      pid: pid,
      reference: reference
    }

    case Registry.register_active(state.registry, state.owner_id, pid) do
      :ok ->
        if state.body_deadline > System.monotonic_time(:millisecond) do
          send(pid, {:begin_sandbox_body, gate})
          {:noreply, %{state | active: active, body_admitted: true, phase: :running_body}}
        else
          expire_registered_body(active, state)
        end

      :error ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        {:noreply, begin_cleanup(%{state | terminal: {:error, "sandbox body admission failed"}})}
    end
  end

  defp expire_registered_body(active, state) do
    Process.exit(active.pid, :kill)

    receive do
      {:DOWN, monitor, :process, pid, _reason}
      when monitor == active.monitor and pid == active.pid ->
        case Registry.clear_active(state.registry, state.owner_id, active.pid) do
          :ok -> {:noreply, begin_cleanup(%{state | terminal: :timeout})}
          :error -> {:stop, :body_ownership_release_failed, state}
        end
    after
      max(0, bounded_body_stop_deadline(state) - System.monotonic_time(:millisecond)) ->
        case Registry.quarantine_active(state.registry, state.owner_id, active.pid) do
          {:ok, proof} -> finish(proof, %{state | terminal: :timeout})
          :error -> {:stop, :body_quarantine_failed, state}
        end
    end
  end

  defp consume_active_down(%{kind: :provider} = active, state) do
    if state.phase == :stopping,
      do: {:noreply, begin_cleanup(state)},
      else: consume_provider_result(active.operation, Map.get(active, :result, :failed), state)
  end

  defp consume_active_down(%{kind: :body} = active, state) do
    result = Map.get(active, :result)

    cond do
      Body.valid_result?(result) and state.phase == :stopping ->
        body_finished(active, %{state | body_result: result})

      Body.valid_result?(result) ->
        case Registry.clear_active(state.registry, state.owner_id, active.pid) do
          :ok -> consume_body_result(result, state)
          :error -> {:stop, :body_ownership_release_failed, state}
        end

      true ->
        quarantine_body(active, state)
    end
  end

  defp body_finished(active, state) do
    case Registry.clear_active(state.registry, state.owner_id, active.pid) do
      :ok -> {:noreply, begin_cleanup(state)}
      :error -> {:stop, :body_ownership_release_failed, state}
    end
  end

  defp consume_body_result({:ok, _receipt} = result, state),
    do: {:noreply, begin_cleanup(%{state | body_result: result, terminal: :ok})}

  defp consume_body_result({:error, _reason, _receipt} = result, state),
    do:
      {:noreply,
       begin_cleanup(%{
         state
         | body_result: result,
           terminal: {:error, "sandbox body failed"}
       })}

  defp consume_body_result({:cancelled, _receipt} = result, state),
    do:
      {:noreply,
       begin_cleanup(%{
         state
         | body_result: result,
           terminal: {:error, "sandbox body cancelled without a sandbox cancellation"}
       })}

  defp quarantine_body(active, state) do
    case Registry.quarantine_active(state.registry, state.owner_id, active.pid) do
      {:ok, proof} ->
        state = %{state | terminal: {:error, "sandbox body termination was not confirmed"}}
        finish(proof, state)

      :error ->
        {:stop, :body_quarantine_failed, state}
    end
  end

  defp stop_body(_terminal, %{phase: :cleanup} = state), do: state
  defp stop_body(_terminal, %{phase: :stopping} = state), do: state

  defp stop_body(terminal, state) do
    disarm_timer(state.body_timer)
    stop_active_process(state.active)

    {stop_ack_reference, stop_ack_timer} = arm_stop_ack(state.active, state)

    %{
      state
      | phase: :stopping,
        stop_ack_reference: stop_ack_reference,
        stop_ack_timer: stop_ack_timer,
        terminal: terminal
    }
  end

  defp stop_active_process(%{kind: :body} = active) do
    send(active.pid, {:cancel_sandbox_body, active.cancellation_reference})
  end

  defp stop_active_process(active), do: terminate_active_process(active)

  defp begin_cleanup(%{phase: :cleanup} = state), do: state

  defp begin_cleanup(state) do
    disarm_timer(state.body_timer)
    disarm_timer(state.stop_ack_timer)

    if state.provider_started do
      begin_provider_cleanup(state)
    else
      finish_empty_cleanup(state)
    end
  end

  defp begin_provider_cleanup(state) do
    reference = make_ref()

    cleanup_deadline =
      min(state.deadline, System.monotonic_time(:millisecond) + state.cleanup_timeout_ms)

    timer = Process.send_after(self(), :cleanup_deadline, cleanup_deadline, abs: true)

    case Registry.cleanup(state.registry, state.owner_id, cleanup_deadline, self(), reference) do
      :ok ->
        state = %{
          state
          | active: nil,
            cleanup_reference: reference,
            cleanup_timer: timer,
            phase: :cleanup
        }

        reply_cancel_waiters(state)

      :error ->
        send(self(), :cleanup_deadline)

        state = %{
          state
          | active: nil,
            cleanup_reference: reference,
            cleanup_timer: timer,
            phase: :cleanup
        }

        reply_cancel_waiters(state)
    end
  end

  defp finish_empty_cleanup(state) do
    reference = make_ref()
    state = %{state | active: nil, cleanup_reference: reference, phase: :cleanup}

    proof =
      case Registry.cleanup_empty(state.registry, state.owner_id) do
        {:ok, cleanup_proof} ->
          cleanup_proof

        :error ->
          %{
            status: :uncertain,
            release: :failed,
            remaining_count: 0,
            remaining_fingerprint: nil
          }
      end

    send(self(), {:sandbox_cleanup, reference, proof})
    reply_cancel_waiters(state)
  end

  defp finish(proof, state) do
    cleanup_status = proof.status
    terminal = final_terminal(state.terminal, cleanup_status)
    {status, error} = result_status(terminal)

    effects =
      [acquisition_effect(state)] ++ body_effects(state) ++ [cleanup_effect(state, proof)]

    options = [
      effects: effects,
      duration_us: max(0, System.monotonic_time(:microsecond) - state.started_at),
      effective_limits: state.decision.effective_limits,
      target_fingerprint: observed_fingerprint(state),
      code_fingerprint: observed_component(state, "code"),
      dependency_fingerprint: observed_component(state, "dependencies"),
      runtime_fingerprint: observed_component(state, "runtime"),
      policy_fingerprint: state.decision.policy_fingerprint,
      cleanup: cleanup_map(proof),
      confidence: confidence(cleanup_status),
      uncertainty: uncertainty(status, cleanup_status),
      warnings: release_warnings(proof)
    ]

    options = maybe_run_value(options, state, status)
    options = if error, do: Keyword.put(options, :error, error), else: options

    result = Result.new(state.request, status, options)
    if state.caller, do: send(state.caller, {state.token, result})
    {:stop, :normal, state}
  end

  defp final_terminal(:ok, :complete), do: :ok
  defp final_terminal(:ok, _cleanup), do: {:error, "sandbox cleanup was not confirmed"}
  defp final_terminal(nil, _cleanup), do: {:error, "sandbox run ended without an outcome"}
  defp final_terminal(terminal, _cleanup), do: terminal

  defp result_status(:ok), do: {:ok, nil}
  defp result_status(:cancelled), do: {:cancelled, nil}

  defp result_status(:timeout),
    do: {:timeout, Error.new(:deadline_exceeded, "sandbox run timed out")}

  defp result_status({:error, message}),
    do: {:error, Error.new(:operation_failed, message)}

  defp maybe_run_value(options, state, :ok), do: put_run_value(options, state)

  defp maybe_run_value(options, %{body_result: {:ok, _receipt}} = state, _status),
    do: put_run_value(options, state)

  defp maybe_run_value(options, %{body_result: {:error, _reason, _receipt}} = state, _status),
    do: put_run_value(options, state)

  defp maybe_run_value(options, %{body_result: {:cancelled, _receipt}} = state, _status),
    do: put_run_value(options, state)

  defp maybe_run_value(options, _state, _status), do: options

  defp put_run_value(options, state) do
    value = %{
      "owner_fingerprint" => state.owner_fingerprint,
      "provider" => state.target.provider,
      "provenance_fingerprint" => observed_fingerprint(state),
      "schema" => "insider.sandbox-run/v1",
      "target_id" => state.target.id
    }

    value =
      case state.body_result do
        {:ok, receipt} -> Map.put(value, "body_receipt", receipt)
        {:error, _reason, receipt} -> Map.put(value, "body_receipt", receipt)
        {:cancelled, receipt} -> Map.put(value, "body_receipt", receipt)
        _other -> value
      end

    Keyword.put(options, :value, value)
  end

  defp body_effects(%{body: nil}), do: []
  defp body_effects(%{body_admitted: false}), do: []

  defp body_effects(state) do
    {status, details} =
      case state.body_result do
        {:ok, receipt} ->
          {:observed, %{outcome: :ok, receipt_digest: receipt_digest(receipt)}}

        {:error, reason, receipt} ->
          {:observed, %{outcome: :error, reason: reason, receipt_digest: receipt_digest(receipt)}}

        {:cancelled, receipt} ->
          {:observed, %{outcome: :cancelled, receipt_digest: receipt_digest(receipt)}}

        _other ->
          {:unknown, %{outcome: :unconfirmed}}
      end

    details =
      Map.merge(details, %{
        body_id: state.body.identity["id"],
        body_version: state.body.identity["version"]
      })

    [
      Effect.new(:sandbox_body_execution, state.target.id,
        status: status,
        details: details
      )
    ]
  end

  defp receipt_digest(receipt) do
    digest = :crypto.hash(:sha256, Canonical.encode(receipt)) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end

  defp acquisition_effect(state) do
    status =
      if state.observed, do: :observed, else: if(state.acquired, do: :partial, else: :unknown)

    details = %{
      observed_code_fingerprint: observed_component(state, "code"),
      observed_configuration_fingerprint: observed_component(state, "configuration"),
      observed_dependency_fingerprint: observed_component(state, "dependencies"),
      observed_runtime_fingerprint: observed_component(state, "runtime"),
      observed_target_component_fingerprint: observed_component(state, "target"),
      observed_target_fingerprint: observed_fingerprint(state),
      owner_fingerprint: state.owner_fingerprint,
      provider_id: state.target.provider["id"],
      provider_version: state.target.provider["version"],
      requested_target_fingerprint: Target.target_fingerprint(state.target)
    }

    Effect.new(:sandbox_target_acquisition, state.target.id, status: status, details: details)
  end

  defp cleanup_effect(state, proof) do
    status =
      case proof.status do
        :complete -> :observed
        :partial -> :partial
        :uncertain -> :unknown
      end

    Effect.new(:sandbox_resource_cleanup, state.target.id,
      status: status,
      details: %{
        owner_fingerprint: state.owner_fingerprint,
        release: proof.release,
        remaining_count: proof.remaining_count,
        remaining_fingerprint: proof.remaining_fingerprint
      }
    )
  end

  defp cleanup_map(proof),
    do: %{
      status: proof.status,
      release: proof.release,
      remaining_count: proof.remaining_count,
      remaining_fingerprint: proof.remaining_fingerprint
    }

  defp observed_fingerprint(%{observed: %{"fingerprint" => fingerprint}}), do: fingerprint
  defp observed_fingerprint(_state), do: nil

  defp observed_component(%{observed: %{"components" => components}}, name),
    do: components[name]["fingerprint"]

  defp observed_component(_state, _name), do: nil

  defp release_warnings(%{release: :failed, status: :complete}),
    do: ["provider cleanup reported failure but independent inventory was empty"]

  defp release_warnings(_proof), do: []

  defp confidence(:complete), do: :high
  defp confidence(_cleanup), do: :unknown

  defp uncertainty(status, cleanup) do
    cancellation =
      if status in [:cancelled, :timeout],
        do: ["stopping target work is not rollback of external effects"],
        else: []

    if cleanup == :complete,
      do: cancellation,
      else: [
        "provider inventory did not prove that all owned resources were removed" | cancellation
      ]
  end

  defp terminate_active_process(active) do
    case active do
      %{pid: pid} -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      nil -> :ok
    end

    :ok
  end

  defp confirm_active_termination(%{monitor: monitor, pid: pid}, state) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @stop_ack_timeout_ms -> Registry.quarantine_active(state.registry, state.owner_id, pid)
    end
  end

  defp confirm_active_termination(nil, _state), do: :ok

  defp disarm_timer(reference) when is_reference(reference) do
    Process.cancel_timer(reference, async: true, info: false)
  end

  defp disarm_timer(_absent), do: :ok

  defp reply_cancel_waiters(state) do
    reply_cancel_waiters(state, :ok)
  end

  defp reply_cancel_waiters(state, response) do
    Enum.each(state.cancel_waiters, &GenServer.reply(&1, response))
    %{state | cancel_waiters: []}
  end

  defp arm_stop_ack(nil, _state), do: {nil, nil}

  defp arm_stop_ack(active, state) do
    reference = make_ref()
    started_at = System.monotonic_time(:millisecond)
    deadline = stop_ack_deadline(active, state, started_at)
    timer = Process.send_after(self(), {:stop_ack_deadline, reference}, deadline, abs: true)

    {reference, timer}
  end

  defp stop_ack_deadline(%{kind: :body}, state, started_at),
    do: min(state.body_stop_deadline, started_at + state.body_stop_timeout_ms)

  defp stop_ack_deadline(_active, _state, started_at), do: started_at + @stop_ack_timeout_ms

  defp bounded_body_stop_deadline(state),
    do:
      min(
        state.body_stop_deadline,
        System.monotonic_time(:millisecond) + state.body_stop_timeout_ms
      )

  defp body_stop_timeout_ms(%{stop_timeout_ms: timeout}), do: timeout
  defp body_stop_timeout_ms(nil), do: 0
  defp body_stop_timeout_ms(_body), do: @stop_ack_timeout_ms

  defp phase_deadlines(deadline, cleanup_timeout_ms, body_stop_timeout_ms) do
    body_stop_deadline = deadline - cleanup_timeout_ms
    {body_stop_deadline - body_stop_timeout_ms, body_stop_deadline}
  end

  defp termination_unconfirmed_error,
    do: Error.new(:operation_failed, "sandbox worker termination was not confirmed")

  defp stop_ack_terminal(:cancelled),
    do: {:error, "sandbox worker termination was not confirmed"}

  defp stop_ack_terminal(terminal), do: terminal

  defp fingerprint(value) do
    digest = Base.encode16(:crypto.hash(:sha256, value), case: :lower)
    IO.iodata_to_binary(["sha256:", digest])
  end
end
