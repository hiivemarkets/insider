defmodule Insider.Scenario.Runner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Insider.Contract
  alias Insider.Contract.Invocation
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Result

  @maximum_callback_ms 5_000

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    now = System.monotonic_time(:millisecond)
    scenario = options.scenario

    deadline =
      min(
        options.decision.dispatch_deadline_monotonic,
        now + scenario.limits["max_duration_ms"]
      )

    body_deadline = deadline - scenario.limits["cleanup_timeout_ms"]
    caller_monitor = Process.monitor(options.caller)
    body_timer = Process.send_after(self(), :scenario_body_deadline, body_deadline, abs: true)
    send(self(), :start_scenario)

    {:ok,
     Map.merge(options, %{
       active: nil,
       body_deadline: body_deadline,
       body_timer: body_timer,
       caller_monitor: caller_monitor,
       cleanup_timer: nil,
       completed_step_ids: [],
       deadline: deadline,
       effects: [],
       phase: :starting,
       remaining_steps: scenario.steps,
       started_at: System.monotonic_time(:microsecond),
       terminal: nil,
       wait_attempt: 0
     })}
  end

  @impl true
  def handle_info(:start_scenario, state), do: start_reset(:initial_reset, state)

  def handle_info({:scenario_invocation, worker, %Invocation{} = invocation}, state) do
    case state.active do
      %{pid: ^worker, monitor: monitor, current: current} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | active: nil}

        if state.phase in [:cancelling, :timing_out],
          do: begin_cleanup(state),
          else: consume_invocation(current, invocation, state)

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, caller, _reason},
        %{caller_monitor: monitor, caller: caller} = state
      ) do
    cancel_body(:cancelled, %{state | caller: nil})
  end

  def handle_info({:DOWN, monitor, :process, worker, _reason}, state) do
    case state.active do
      %{pid: ^worker, monitor: ^monitor} ->
        state = %{state | active: nil}

        if state.phase in [:cancelling, :timing_out] do
          begin_cleanup(state)
        else
          fail_and_cleanup(:error, "scenario callback caller terminated", state)
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_wait, step, attempt}, state)
      when state.phase == :waiting and state.wait_attempt == attempt do
    start_step(step, attempt + 1, state)
  end

  def handle_info({:retry_wait, _step, _attempt}, state), do: {:noreply, state}

  def handle_info({:cancel_scenario, token}, %{token: token} = state) do
    cancel_body(:cancelled, state)
  end

  def handle_info(:scenario_body_deadline, state) do
    if state.phase == :cleanup,
      do: {:noreply, state},
      else: cancel_body(:timeout, state)
  end

  def handle_info(:scenario_cleanup_deadline, state) do
    if state.phase == :cleanup do
      stop_active(state.active)
      finish(cleanup_failure_terminal(state.terminal), :uncertain, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_active(state.active)
    :ok
  end

  defp start_reset(phase, state) do
    reset = state.scenario.reset
    start_invocation(:reset, reset["name"], reset["arguments"], %{phase: phase}, state)
  end

  defp advance(%{remaining_steps: []} = state), do: begin_cleanup(%{state | terminal: :ok})

  defp advance(%{remaining_steps: [step | rest]} = state) do
    state = %{state | remaining_steps: rest}
    start_step(step, 1, state)
  end

  defp start_step(%{"type" => "action"} = step, _attempt, state),
    do: start_invocation(:action, step["name"], step["arguments"], %{step: step}, state)

  defp start_step(%{"type" => "observation"} = step, _attempt, state),
    do:
      start_invocation(
        :observation,
        step["name"],
        step["arguments"],
        %{step: step},
        state
      )

  defp start_step(%{"type" => "wait", "kind" => kind} = step, attempt, state) do
    kind = if kind == "observation", do: :observation, else: :invariant

    start_invocation(
      kind,
      step["name"],
      step["arguments"],
      %{attempt: attempt, step: step},
      %{state | wait_attempt: attempt}
    )
  end

  defp start_invocation(kind, name, arguments, current, state) do
    deadline =
      if Map.get(current, :phase) == :cleanup, do: state.deadline, else: state.body_deadline

    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 1 do
      parent = self()

      {worker, monitor} =
        spawn_monitor(fn ->
          invocation =
            Contract.invoke(
              state.contract_executor,
              state.module,
              kind,
              name,
              arguments,
              request: state.request,
              context: state.context,
              timeout_ms: min(@maximum_callback_ms, remaining - 1)
            )

          send(parent, {:scenario_invocation, self(), invocation})
        end)

      effect = mutation_effect(kind, name, current, state)
      effects = if effect, do: [effect | state.effects], else: state.effects
      phase = if Map.get(current, :phase) == :cleanup, do: :cleanup, else: :running

      {:noreply,
       %{
         state
         | active: %{pid: worker, monitor: monitor, current: current},
           effects: effects,
           phase: phase
       }}
    else
      if Map.get(current, :phase) == :cleanup,
        do: finish(cleanup_failure_terminal(state.terminal), :uncertain, state),
        else: fail_and_cleanup(:timeout, "scenario body deadline elapsed", state)
    end
  end

  defp consume_invocation(%{phase: :initial_reset}, %Invocation{status: :ok}, state),
    do: advance(%{state | phase: :body})

  defp consume_invocation(%{phase: :initial_reset}, invocation, state),
    do: invocation_failure(invocation, state)

  defp consume_invocation(%{phase: :cleanup}, %Invocation{status: :ok}, state),
    do: finish(state.terminal || :ok, :complete, state)

  defp consume_invocation(%{phase: :cleanup}, _invocation, state),
    do: finish(cleanup_failure_terminal(state.terminal), :uncertain, state)

  defp consume_invocation(%{step: %{"type" => "action"} = step}, invocation, state) do
    if invocation.status == :ok,
      do: complete_step(step, state),
      else: invocation_failure(invocation, state)
  end

  defp consume_invocation(%{step: %{"type" => "observation"} = step}, invocation, state) do
    state = add_semantic_effect(step, invocation, nil, state)

    if invocation.status == :ok,
      do: complete_step(step, state),
      else: invocation_failure(invocation, state)
  end

  defp consume_invocation(
         %{step: %{"type" => "wait"} = step, attempt: attempt},
         invocation,
         state
       ) do
    cond do
      wait_matched?(step, invocation) ->
        state = add_semantic_effect(step, invocation, attempt, state)
        complete_step(step, state)

      retryable_wait?(step, invocation) and attempt < step["max_attempts"] ->
        Process.send_after(self(), {:retry_wait, step, attempt}, step["interval_ms"])
        {:noreply, %{state | phase: :waiting, wait_attempt: attempt}}

      retryable_wait?(step, invocation) ->
        state = add_semantic_effect(step, invocation, attempt, state)
        fail_and_cleanup(:timeout, "semantic wait exhausted its attempt bound", state)

      true ->
        state = add_semantic_effect(step, invocation, attempt, state)
        invocation_failure(invocation, state)
    end
  end

  defp complete_step(step, state) do
    advance(%{state | completed_step_ids: [step["id"] | state.completed_step_ids], phase: :body})
  end

  defp wait_matched?(%{"kind" => "invariant"}, %Invocation{status: :ok, value: true}),
    do: true

  defp wait_matched?(
         %{"kind" => "observation", "expectation" => %{"value" => expected}},
         %Invocation{status: :ok, value: value}
       ),
       do: value == expected

  defp wait_matched?(_step, _invocation), do: false

  defp retryable_wait?(%{"kind" => "invariant"}, %Invocation{status: :violation}), do: true
  defp retryable_wait?(%{"kind" => "observation"}, %Invocation{status: :ok}), do: true
  defp retryable_wait?(_step, _invocation), do: false

  defp invocation_failure(%Invocation{status: :timeout}, state),
    do: fail_and_cleanup(:timeout, "scenario callback exceeded its deadline", state)

  defp invocation_failure(%Invocation{}, state),
    do: fail_and_cleanup(:error, "scenario callback failed", state)

  defp fail_and_cleanup(status, message, state),
    do: begin_cleanup(%{state | terminal: {status, message}})

  defp cancel_body(status, %{phase: :cleanup} = state) do
    terminal = if state.terminal in [nil, :ok], do: status, else: state.terminal
    {:noreply, %{state | terminal: terminal}}
  end

  defp cancel_body(status, state) do
    cancel_timer(state.body_timer)
    phase = if status == :cancelled, do: :cancelling, else: :timing_out
    state = %{state | phase: phase, terminal: status}

    case state.active do
      nil ->
        begin_cleanup(state)

      _active ->
        # The contract runner owns callback termination confirmation. Leaving
        # this bounded caller alive lets it return that receipt before reset;
        # killing it here would race cleanup against an unconfirmed mutation.
        {:noreply, state}
    end
  end

  defp begin_cleanup(%{phase: :cleanup} = state), do: {:noreply, state}

  defp begin_cleanup(state) do
    cancel_timer(state.body_timer)

    cleanup_deadline =
      min(
        state.deadline,
        System.monotonic_time(:millisecond) + state.scenario.limits["cleanup_timeout_ms"]
      )

    cleanup_timer =
      Process.send_after(self(), :scenario_cleanup_deadline, cleanup_deadline, abs: true)

    state = %{state | cleanup_timer: cleanup_timer, deadline: cleanup_deadline, phase: :cleanup}
    start_reset(:cleanup, state)
  end

  defp finish(terminal, cleanup_status, state) do
    cancel_timer(state.body_timer)
    cancel_timer(state.cleanup_timer)
    {status, message} = terminal_parts(terminal)

    options = [
      effects: Enum.reverse(state.effects),
      duration_us: max(0, System.monotonic_time(:microsecond) - state.started_at),
      effective_limits: state.decision.effective_limits,
      policy_fingerprint: state.decision.policy_fingerprint,
      cleanup: %{status: cleanup_status},
      confidence: confidence(status, cleanup_status),
      uncertainty: uncertainty(status, cleanup_status)
    ]

    options = result_payload(status, message, state, options)
    result = Result.new(state.request, status, options)
    if state.caller, do: send(state.caller, {state.token, result})
    {:stop, :normal, state}
  end

  defp result_payload(:ok, _message, state, options) do
    value = %{
      "completed_step_ids" => Enum.reverse(state.completed_step_ids),
      "expectation_status" => "not_evaluated",
      "expected_incident_fingerprints" => state.scenario.expected_incident_fingerprints,
      "scenario_id" => state.scenario.id,
      "schema" => "insider.scenario-run/v1",
      "seed" => state.scenario.seed
    }

    Keyword.put(options, :value, value)
  end

  defp result_payload(:cancelled, _message, _state, options), do: options

  defp result_payload(:timeout, message, _state, options),
    do: Keyword.put(options, :error, Error.new(:deadline_exceeded, message))

  defp result_payload(:error, message, _state, options),
    do: Keyword.put(options, :error, Error.new(:operation_failed, message))

  defp terminal_parts({status, message}), do: {status, message}
  defp terminal_parts(:ok), do: {:ok, nil}
  defp terminal_parts(:cancelled), do: {:cancelled, nil}
  defp terminal_parts(:timeout), do: {:timeout, "scenario deadline elapsed"}
  defp terminal_parts(:error), do: {:error, "scenario execution failed"}

  defp mutation_effect(kind, name, current, state) when kind in [:action, :reset] do
    phase = Map.get(current, :phase, :body)

    details = %{callback_kind: kind, phase: phase}

    details =
      case Map.get(current, :step) do
        %{"id" => step_id} -> Map.put(details, :scenario_step_id, step_id)
        _other -> details
      end

    Effect.new(:contract_mutation, effect_target(state, name),
      status: :unknown,
      details: details
    )
  end

  defp mutation_effect(_kind, _name, _current, _state), do: nil

  defp add_semantic_effect(step, invocation, attempt, state) do
    status = if invocation.status in [:ok, :violation], do: :observed, else: :partial

    details = %{
      invocation_status: invocation.status,
      scenario_step_id: step["id"],
      sensitivity: invocation.sensitivity
    }

    details = if attempt, do: Map.put(details, :attempts, attempt), else: details

    effect =
      Effect.new(:semantic_observation, effect_target(state, step["name"]),
        status: status,
        details: details
      )

    %{state | effects: [effect | state.effects]}
  end

  defp effect_target(state, name) do
    target = state.scenario.contract["id"] <> "/" <> name

    if byte_size(target) <= 256 do
      target
    else
      digest = :crypto.hash(:sha256, target) |> Base.encode16(case: :lower)
      "contract-callback/sha256:" <> digest
    end
  end

  defp confidence(:ok, :complete), do: :high
  defp confidence(_status, :complete), do: :certain
  defp confidence(_status, _cleanup), do: :unknown

  defp uncertainty(status, cleanup) do
    mutation =
      if status in [:cancelled, :timeout],
        do: ["stopping scenario work is not rollback of external mutation"],
        else: []

    if cleanup == :complete,
      do: mutation,
      else: ["declared scenario cleanup was not confirmed" | mutation]
  end

  defp cleanup_failure_terminal(terminal) when terminal in [nil, :ok],
    do: {:error, "declared scenario cleanup failed"}

  defp cleanup_failure_terminal(terminal), do: terminal

  defp stop_active(nil), do: :ok

  defp stop_active(%{pid: pid}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
