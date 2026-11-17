defmodule Insider.Contract.Runner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Insider.Contract.Invocation
  alias Insider.Event.Value
  alias Insider.Identity.Subject
  alias Insider.Protocol.Error

  @cleanup_reserve_ms 50
  @max_output_bytes 16_384
  @max_heap_words 262_144

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(invocation), do: GenServer.start_link(__MODULE__, invocation)

  @impl true
  def init(invocation) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(invocation.caller)
    send(self(), :start_callback)

    {:ok,
     Map.merge(invocation, %{
       caller_monitor: caller_monitor,
       worker: nil,
       worker_monitor: nil,
       outcome: nil,
       timeout_timer: nil,
       cleanup_timer: nil,
       phase: :starting
     })}
  end

  @impl true
  def handle_info(:start_callback, state) do
    now = System.monotonic_time(:millisecond)

    cutoff =
      min(
        now + state.timeout_ms,
        state.dispatch_deadline_monotonic - @cleanup_reserve_ms
      )

    if cutoff > now do
      runner = self()
      token = state.token

      {worker, worker_monitor} =
        :erlang.spawn_opt(
          fn -> await_callback_start(runner, token, state) end,
          [
            :link,
            :monitor,
            {:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false}}
          ]
        )

      timeout_timer =
        Process.send_after(self(), {:callback_timeout, token}, cutoff, abs: true)

      send(worker, {:run_contract_callback, token, cutoff})

      {:noreply,
       %{
         state
         | worker: worker,
           worker_monitor: worker_monitor,
           timeout_timer: timeout_timer,
           phase: :running
       }}
    else
      reply_and_stop(state, timeout_result(state, :not_required, []))
    end
  end

  def handle_info({:callback_outcome, token, outcome}, %{token: token, phase: :running} = state) do
    {:noreply, %{state | outcome: outcome}}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, reason},
        %{worker_monitor: monitor, worker: worker} = state
      ) do
    cancel_timer(state.timeout_timer)
    cancel_timer(state.cleanup_timer)

    case state.phase do
      :caller_gone ->
        {:stop, :normal, state}

      :timing_out ->
        reply_and_stop(state, timeout_result(state, :complete, []))

      :quarantined ->
        {:stop, :normal, state}

      :running ->
        result = outcome_result(state, state.outcome, reason)
        reply_and_stop(state, result)
    end
  end

  def handle_info({:callback_timeout, token}, %{token: token, phase: :running} = state) do
    Process.exit(state.worker, :kill)
    cleanup_timer = Process.send_after(self(), {:cleanup_timeout, token}, @cleanup_reserve_ms)
    {:noreply, %{state | phase: :timing_out, cleanup_timer: cleanup_timer}}
  end

  def handle_info({:cleanup_timeout, token}, %{token: token, phase: :timing_out} = state) do
    result = timeout_result(state, :uncertain, ["callback termination is not yet confirmed"])
    send_result(state, result)
    {:noreply, %{state | phase: :quarantined}}
  end

  def handle_info(
        {:DOWN, monitor, :process, caller, _reason},
        %{caller_monitor: monitor, caller: caller} = state
      ) do
    cancel_timer(state.timeout_timer)
    cancel_timer(state.cleanup_timer)

    if is_pid(state.worker) and Process.alive?(state.worker),
      do: Process.exit(state.worker, :kill)

    if state.worker_monitor do
      {:noreply, %{state | phase: :caller_gone}}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp await_callback_start(runner, token, state) do
    receive do
      {:run_contract_callback, ^token, cutoff} ->
        if System.monotonic_time(:millisecond) < cutoff do
          run_callback(runner, token, state)
        else
          send(runner, {:callback_outcome, token, :deadline_exceeded})
        end
    end
  end

  defp run_callback(runner, token, state) do
    outcome =
      try do
        value =
          apply(state.module, :__insider_contract_dispatch__, [state.kind, state.name, state.args])

        normalize_output(state, value)
      catch
        _class, _reason -> {:error, :callback_exception, fixed_error("contract callback failed")}
      end

    send(runner, {:callback_outcome, token, outcome})
  end

  defp normalize_output(%{kind: :identity} = state, value) do
    with {:ok, identity_value, scope} <- identity_parts(value),
         {:ok, subject} <- Subject.new(identity_namespace(state), identity_value, scope) do
      {:ok, subject}
    else
      _error ->
        {:error, :invalid_callback_output,
         fixed_error("contract identity returned an invalid value")}
    end
  end

  defp normalize_output(%{kind: :invariant}, value) when is_boolean(value), do: {:ok, value}

  defp normalize_output(%{kind: :invariant}, _value),
    do:
      {:error, :invalid_callback_output, fixed_error("contract invariant must return a boolean")}

  defp normalize_output(_state, value) do
    if Value.valid?(value, @max_output_bytes),
      do: {:ok, value},
      else:
        {:error, :invalid_callback_output,
         fixed_error("contract callback returned an invalid or oversized value")}
  end

  defp identity_parts(value) when is_binary(value), do: {:ok, value, nil}

  defp identity_parts(%{"value" => value, "scope" => scope} = identity)
       when map_size(identity) == 2,
       do: {:ok, value, scope}

  defp identity_parts(_value), do: :error

  defp identity_namespace(state),
    do: "#{state.contract.id}.#{state.name}.v#{state.contract.version}"

  defp outcome_result(state, {:ok, value}, :normal) do
    status = if state.kind == :invariant and value == false, do: :violation, else: :ok
    result(state, status, value: value)
  end

  defp outcome_result(state, {:error, reason, error}, :normal),
    do: result(state, :error, reason: reason, error: error)

  defp outcome_result(state, :deadline_exceeded, :normal),
    do: timeout_result(state, :complete, [])

  defp outcome_result(state, _outcome, _reason),
    do:
      result(state, :error,
        reason: :callback_exception,
        error: fixed_error("contract callback failed")
      )

  defp timeout_result(state, cleanup_status, uncertainty) do
    result(state, :timeout,
      reason: :deadline_exceeded,
      error: Error.new(:deadline_exceeded, "contract callback exceeded its deadline"),
      cleanup: %{status: cleanup_status},
      uncertainty: uncertainty
    )
  end

  defp result(state, status, options) do
    %Invocation{
      schema: "insider.contract-invocation/v1",
      contract: %{
        "id" => state.contract.id,
        "version" => state.contract.version,
        "fingerprint" => state.contract.fingerprint
      },
      kind: state.kind,
      name: state.name,
      status: status,
      reason: Keyword.get(options, :reason, success_reason(status)),
      value: Keyword.get(options, :value),
      sensitivity: state.declaration.sensitivity,
      error: Keyword.get(options, :error),
      duration_us: elapsed_us(state.started_at),
      cleanup: Keyword.get(options, :cleanup, %{status: :complete}),
      warnings: [],
      uncertainty: Keyword.get(options, :uncertainty, []) ++ mutation_uncertainty(state)
    }
  end

  defp reply_and_stop(state, result) do
    send_result(state, result)
    {:stop, :normal, state}
  end

  defp send_result(state, result), do: send(state.caller, {state.token, result})

  defp elapsed_us(started_at),
    do: max(0, System.monotonic_time(:microsecond) - started_at)

  defp fixed_error(message), do: Error.new(:operation_failed, message)

  defp success_reason(:ok), do: :completed
  defp success_reason(:violation), do: :invariant_violated
  defp success_reason(_status), do: :callback_exception

  defp mutation_uncertainty(%{kind: kind, worker: worker})
       when kind in [:action, :reset] and is_pid(worker),
       do: ["contract mutation may have produced external effects; termination is not rollback"]

  defp mutation_uncertainty(_state), do: []

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
