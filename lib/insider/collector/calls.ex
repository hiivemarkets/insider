defmodule Insider.Collector.Calls do
  @moduledoc """
  Bounded call tracing of selected functions as `call`, `call.return`,
  `call.exception`, and `call.stopped` events.

  It runs only in a collector session that names the `:calls` component, so
  the trace belongs to the session and its owner, never to the process that
  asked for it: it ends when the session stops, its lease expires, or an
  amendment replaces the segment, and the session's cleanup receipt proves
  the trace session and each of its function patterns are gone.

  Tracing uses an isolated OTP trace session (`Insider.Collector.Calls.Tracing`,
  OTP 28 and later), so it never touches trace state it did not set. The
  bookkeeping, limits, and rendering are `Insider.Collector.Calls.Trace`.
  Ingress has a soft byte bound, for development and test nodes only: the
  runtime delivers a trace message before any code here can refuse it, so
  the bound limits what reaches this process and stops the trace quickly,
  not what the runtime may copy first (see
  [Call traces](docs/live/live-runtime-evidence.md#call-traces) for the
  measured worst cases).

  - In the strict profile (`rich: false`, the safe default) a call message
    carries only the arity: no argument is copied out of the calling
    process. Results still carry their value.
  - Trace messages go to an inlet process that measures each one as it
    reads it, its external size plus, for a top-level binary argument or
    result that is a sub-binary, the larger binary it keeps alive, and
    forwards it here. The bytes forwarded and not yet handled here are
    counted; a message that would take them above `:max_ingress_bytes`
    (default 8 MiB) is dropped, the inlet removes the trace's patterns and
    process flags itself, and the trace records `call.stopped` with reason
    `ingress_bytes`. Neither this process nor the inlet is ever traced.
  - While more than `:max_waiting` messages wait here, the trace stops
    (`overload`).
  - As a last resort this process's heap, shared binaries included, is
    limited to eight times the byte budget, at least 64 MiB: above it the
    runtime kills it, which destroys the trace session, and the collector
    session ends as `cleanup_incomplete`.

  Not bounded: the inlet's mailbox before it reads a message (measured
  peaks reach hundreds of thousands of messages under a tight-loop burst);
  a sub-binary nested inside an argument or result, charged only its own
  bytes; and one message larger than the budget, copied once before the
  inlet drops it.

  `flush/1` and `stop/1` drain through the inlet. A stop whose drain does
  not finish counts what the inlet still held, or had taken and not yet
  forwarded, as `undrained`; when it cannot prove that count exact,
  `undrained_unknown` says so.

  Messages that arrive after a stop are counted as `shed`. Every received trace
  message is counted once: as recorded, `recorder_dropped`, `invalid`, `shed`,
  or as a result that pairs with its call without an event of its own.
  """

  use GenServer

  import Insider.Collector.Options, only: [bounded?: 2, positive?: 1]

  alias Insider.Collector.Calls.Trace
  alias Insider.Collector.Calls.Tracing
  alias Insider.Collector.IngressProfile
  alias Insider.Collector.Options
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle

  @required [:authority, :boot_id, :clock_id, :environment, :functions]
  @optional [
    :max_bytes,
    :max_calls,
    :max_ingress_bytes,
    :max_waiting,
    :node,
    :rate,
    :results,
    :rich,
    # Functions of `functions` whose calls are watched writes
    # (`Insider.Collector.Calls.Trace`).
    :writes
  ]
  @default_max_waiting 1_024
  @default_max_ingress_bytes 8 * 1_024 * 1_024
  # The heap backstop is at least this, so collecting one message within a
  # small budget is never the reason the collector is killed.
  @heap_floor_bytes 64 * 1_024 * 1_024
  @flush_timeout_ms 1_000

  @spec start_link(RecorderHandle.t(), keyword()) :: GenServer.on_start() | {:error, atom()}
  def start_link(%RecorderHandle{} = recorder, options) when is_list(options) do
    with true <- valid_options?(options),
         {:ok, profile} <- IngressProfile.new(Keyword.fetch!(options, :environment)),
         true <- profile.observation_enabled,
         :ok <- Tracing.preflight() do
      {:ok, pid} = GenServer.start_link(__MODULE__, {self(), recorder, options})

      case GenServer.call(pid, :startup_result) do
        :ok -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    else
      false ->
        {:error, if(valid_options?(options), do: :environment_denied, else: :invalid_options)}

      {:error, :requires_otp_28} ->
        {:error, :requires_otp_28}

      {:error, _reason} ->
        {:error, :invalid_options}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def start_link(_recorder, _options), do: {:error, :invalid_options}

  @doc """
  The trace's inventory: its session's weak reference and the traced
  functions, which the collector session checks independently at cleanup.
  """
  @spec inventory(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def inventory(server), do: safe_call(server, :inventory, 1_000)

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server), do: safe_call(server, :status, 5_000)

  @doc "Processes every trace message sent before the call, then returns the status."
  @spec flush(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def flush(server), do: safe_call(server, :flush, @flush_timeout_ms + 1_000)

  @doc """
  Removes the trace, records what was sent before the removal, and stops.
  Returns the final status and the removal observation (`Tracing.remove/1`).
  """
  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stop(server), do: safe_call(server, :stop, @flush_timeout_ms + 1_000)

  @impl GenServer
  def init({owner, recorder, options}) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)
    functions = Keyword.fetch!(options, :functions)
    results = Keyword.get(options, :results, :exceptions)
    rich = Keyword.get(options, :rich, false)
    max_ingress_bytes = Keyword.get(options, :max_ingress_bytes, @default_max_ingress_bytes)

    Process.flag(:max_heap_size, %{
      size: div(max(8 * max_ingress_bytes, @heap_floor_bytes), :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    state = %{
      backend: nil,
      owner: owner,
      recorder: recorder,
      max_waiting: Keyword.get(options, :max_waiting, @default_max_waiting),
      max_ingress_bytes: max_ingress_bytes,
      # 1: bytes forwarded by the inlet and not yet handled; 2: messages the
      # inlet dropped; 3: whether the inlet stopped the trace; 4: messages
      # it took from its mailbox.
      ingress: :atomics.new(4, signed: false),
      # Messages the inlet forwarded that were handled here.
      handled: 0,
      inlet: nil,
      trace:
        Trace.new(
          functions: functions,
          writes: Keyword.get(options, :writes, []),
          results: results,
          max_calls: Keyword.get(options, :max_calls, 100),
          rate: Keyword.get(options, :rate, {50, 1_000}),
          max_bytes: Keyword.get(options, :max_bytes, 1_024),
          rich: rich
        ),
      recorded: 0,
      recorder_dropped: 0,
      undrained: 0,
      undrained_unknown: 0,
      # Drain requests sent to the inlet and not yet answered.
      barriers: 0,
      sequence: 0,
      startup_result: :ok,
      context: %{
        authority: Keyword.fetch!(options, :authority),
        boot_id: Keyword.fetch!(options, :boot_id),
        clock_id: Keyword.fetch!(options, :clock_id),
        node: Keyword.get(options, :node, Atom.to_string(node())),
        source_instance_id:
          "calls-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
      }
    }

    # The inlet exists before the trace does, so it is excluded from it
    # before any function is traced.
    collector = self()
    ingress = state.ingress
    inlet = spawn_link(fn -> inlet(collector, {max_ingress_bytes, ingress}, nil) end)
    state = %{state | inlet: inlet}
    mfas = Enum.map(functions, &elem(&1, 0))

    writes = Keyword.get(options, :writes, [])

    case Tracing.install(inlet, [collector, inlet], mfas, results, rich, writes) do
      {:ok, backend} ->
        send(inlet, {:backend, backend})
        {:ok, %{state | backend: backend}}

      {:error, reason} ->
        {:ok, %{state | startup_result: {:error, reason}}}
    end
  end

  @impl GenServer
  def handle_call(:startup_result, _from, %{startup_result: :ok} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, %{startup_result: {:error, reason}} = state),
    do: {:stop, :normal, {:error, reason}, state}

  def handle_call(:inventory, _from, %{backend: backend} = state),
    do:
      {:reply, {:ok, %{weak: backend.weak, functions: backend.functions, inlet: state.inlet}},
       state}

  def handle_call(:status, _from, state), do: {:reply, {:ok, status_map(state)}, state}

  def handle_call(:flush, _from, state) do
    {_drained, state} = drain_delivered(state)
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:stop, _from, state) do
    _stopped = Tracing.stop_all(state.backend)
    # Messages sent before the patterns went are still recorded.
    # What a drain that did not finish leaves in the inlet is lost.
    {drained, state} = drain_delivered(state)
    removal = Tracing.remove(state.backend)
    state = if drained == :incomplete, do: settle(state), else: state
    :ok = stop_inlet(state.inlet)

    {:stop, :normal, {:ok, %{status: status_map(state), trace: removal}},
     %{state | backend: nil, inlet: nil}}
  end

  @impl GenServer
  def handle_info({:ingress, bytes, message}, state),
    do: {:noreply, ingress(bytes, message, state)}

  def handle_info(:ingress_stopped, state), do: {:noreply, ingress_stopped(state)}

  def handle_info({:barrier_done, _reference}, state),
    do: {:noreply, %{state | barriers: state.barriers - 1}}

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, inlet, reason}, %{inlet: inlet} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _removed = Tracing.remove(Map.get(state, :backend))
    _inlet = stop_inlet(Map.get(state, :inlet))
    :ok
  end

  defp ingress_stopped(state) do
    ns = System.monotonic_time(:nanosecond)
    apply_result(Trace.overload(state.trace, ns, "ingress_bytes"), state)
  end

  # One message the inlet forwarded, measured at `bytes`; they are released
  # once it is handled.
  defp ingress(bytes, message, state) do
    state = traced(message, %{state | handled: state.handled + 1})
    _left = :atomics.sub_get(state.ingress, 1, bytes)
    state
  end

  defp traced(message, state) do
    state =
      if overloaded?(state),
        do: apply_result(Trace.overload(state.trace, timestamp(message)), state),
        else: state

    apply_result(Trace.handle(state.trace, message), state)
  end

  defp apply_result({trace, records, action}, state) do
    act(action, state.backend)
    Enum.reduce(records, %{state | trace: trace}, &record/2)
  end

  defp act(nil, _backend), do: :ok
  defp act(:stop_calls, backend), do: Tracing.stop_calls(backend)
  defp act(:stop_all, backend), do: Tracing.stop_all(backend)

  defp record(record, state) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    context = Map.merge(state.context, %{sequence: sequence, offset_ns: wall_offset_ns()})

    with {:ok, event} <- Trace.event(record, context),
         :ok <- Recorder.record(state.recorder, event) do
      %{state | recorded: state.recorded + 1}
    else
      {:dropped, _reason} -> %{state | recorder_dropped: state.recorder_dropped + 1}
      {:error, _reason} -> %{state | trace: %{state.trace | invalid: state.trace.invalid + 1}}
    end
  end

  defp overloaded?(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, waiting} -> waiting > state.max_waiting
      _other -> true
    end
  end

  defp timestamp(message), do: elem(message, tuple_size(message) - 1)

  # Trace timestamps are monotonic. The events a write is paired with
  # (Telemetry, Logger, Poller) take their wall time from the OS clock, and
  # Erlang system time (monotonic + time offset) can differ from it while
  # the VM's time correction catches up. So a write's wall time is on the
  # OS clock too: its monotonic time plus the OS clock's current offset.
  defp wall_offset_ns, do: System.os_time(:nanosecond) - System.monotonic_time(:nanosecond)

  # Reads each trace message, measures it, and forwards it to the collector
  # while the bytes forwarded and not yet handled stay within the budget.
  # Above it, it drops the message and every later one, removes the trace
  # (once it knows the backend), and tells the collector why. Its mailbox
  # is not bounded.
  # A drain barrier: the inlet asks the runtime to mark the point after every
  # trace message already sent to it, and answers the collector once it has
  # forwarded (or dropped) everything before that mark, so the answer follows
  # them in the collector's mailbox.
  defp inlet(collector, {_budget, ingress} = config, backend, barriers \\ %{}) do
    receive do
      {:backend, backend} ->
        if :atomics.get(ingress, 3) == 1, do: Tracing.stop_all(backend)
        inlet(collector, config, backend, barriers)

      {:barrier, reference} ->
        case Tracing.delivered(backend) do
          {:ok, marker} ->
            inlet(collector, config, backend, Map.put(barriers, marker, reference))

          :error ->
            send(collector, {:barrier_done, reference})
            inlet(collector, config, backend, barriers)
        end

      {:trace_delivered, :all, marker} when is_map_key(barriers, marker) ->
        {reference, barriers} = Map.pop(barriers, marker)
        send(collector, {:barrier_done, reference})
        inlet(collector, config, backend, barriers)

      message ->
        # Taken: from here until it is forwarded or dropped, the message is
        # in flight (`settle/1`).
        :atomics.add(ingress, 4, 1)

        if :atomics.get(ingress, 3) == 1 do
          :atomics.add(ingress, 2, 1)
        else
          admit(collector, config, backend, message)
        end

        inlet(collector, config, backend, barriers)
    end
  end

  defp admit(collector, {budget, ingress}, backend, message) do
    bytes = :erlang.external_size(message) + retained(message)

    if :atomics.add_get(ingress, 1, bytes) > budget do
      :atomics.sub(ingress, 1, bytes)
      :atomics.add(ingress, 2, 1)
      :atomics.put(ingress, 3, 1)
      if backend, do: Tracing.stop_all(backend)
      send(collector, :ingress_stopped)
    else
      send(collector, {:ingress, bytes, message})
    end
  end

  # After a drain that did not finish, with the trace session destroyed so
  # nothing more arrives: the inlet is suspended, so its counters and
  # mailbox stand still. What it forwarded is handled here; what waits in
  # its mailbox, and a message it took and has neither forwarded nor
  # dropped, are `undrained`. An inlet seen blocked in its receive holds
  # nothing in flight, and one stopped outside its loop function has
  # counted the message it holds. Otherwise, with no message counted in
  # flight, it may have taken one between its receive and its count: the
  # loss count is then a lower bound, and `undrained_unknown` says so.
  defp settle(%{inlet: inlet, ingress: ingress} = state) when is_pid(inlet) do
    status = Process.info(inlet, :status)
    suspended = suspend(inlet)
    location = Process.info(inlet, :current_function)
    pending = inlet_pending(state)
    state = handle_forwarded(state)

    # A forwarded message is in this process's mailbox as soon as the inlet
    # sent it, so everything forwarded has now been handled here.
    in_flight = :atomics.get(ingress, 4) - :atomics.get(ingress, 2) - state.handled

    # Outside its loop function the inlet is measuring or forwarding a
    # message it has already counted as taken.
    proven =
      status == {:status, :waiting} or in_flight > 0 or
        location != {:current_function, {__MODULE__, :inlet, 4}}

    %{
      state
      | undrained: state.undrained + pending + max(in_flight, 0),
        undrained_unknown: state.undrained_unknown + if(suspended and proven, do: 0, else: 1)
    }
  end

  defp settle(state), do: %{state | undrained_unknown: state.undrained_unknown + 1}

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    _error -> false
  end

  defp handle_forwarded(state) do
    receive do
      {:ingress, bytes, message} -> handle_forwarded(ingress(bytes, message, state))
      :ingress_stopped -> handle_forwarded(ingress_stopped(state))
    after
      0 -> state
    end
  end

  # A top-level binary argument or result that is a sub-binary keeps its
  # whole backing binary alive; it is charged the difference. Binaries
  # nested deeper are charged only their own size.
  defp retained({:trace_ts, _pid, :call, {_m, _f, args}, _ns}) when is_list(args),
    do: Enum.reduce(args, 0, &(retained_binary(&1) + &2))

  defp retained({:trace_ts, _pid, _port, _mfa, value, _ns}), do: retained_binary(value)
  defp retained(_message), do: 0

  defp retained_binary(value) when is_binary(value),
    do: max(:binary.referenced_byte_size(value) - byte_size(value), 0)

  defp retained_binary(_value), do: 0

  defp stop_inlet(inlet) when is_pid(inlet) do
    Process.unlink(inlet)
    Process.exit(inlet, :kill)
    :ok
  end

  defp stop_inlet(_inlet), do: :ok

  # Processes the messages sent before this call: the runtime's delivery
  # marker follows them.
  # Drains through the inlet: the messages sent to it before this call, in
  # order, then the barrier's answer. Without an answer within the bound,
  # the inlet's waiting messages are reported (`inlet_pending`).
  defp drain_delivered(%{inlet: inlet} = state) when is_pid(inlet) do
    reference = make_ref()
    send(inlet, {:barrier, reference})
    state = %{state | barriers: state.barriers + 1}
    deadline = System.monotonic_time(:millisecond) + @flush_timeout_ms
    drain_until(reference, deadline, state)
  end

  defp drain_delivered(state), do: {:drained, state}

  defp drain_until(reference, deadline, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:barrier_done, ^reference} ->
        {:drained, %{state | barriers: state.barriers - 1}}

      # The answer to an earlier drain that timed out.
      {:barrier_done, _earlier} ->
        drain_until(reference, deadline, %{state | barriers: state.barriers - 1})

      {:ingress, bytes, message} ->
        drain_until(reference, deadline, ingress(bytes, message, state))

      :ingress_stopped ->
        drain_until(reference, deadline, ingress_stopped(state))
    after
      remaining -> {:incomplete, state}
    end
  end

  # The inlet's waiting messages, less the drain requests it has not read.
  defp inlet_pending(%{inlet: inlet} = state) when is_pid(inlet) do
    case Process.info(inlet, :message_queue_len) do
      {:message_queue_len, waiting} -> max(waiting - state.barriers, 0)
      nil -> 0
    end
  end

  defp inlet_pending(_state), do: 0

  defp status_map(state) do
    {:message_queue_len, pending} = Process.info(self(), :message_queue_len)

    counts = Trace.counts(state.trace)

    counts
    |> Map.merge(%{
      # Messages the inlet received and dropped for the byte budget.
      received: counts.received + :atomics.get(state.ingress, 2),
      shed: counts.shed + :atomics.get(state.ingress, 2),
      recorded: state.recorded,
      recorder_dropped: state.recorder_dropped,
      undrained: state.undrained,
      undrained_unknown: state.undrained_unknown,
      inlet_pending: inlet_pending(state),
      pending: pending,
      max_waiting: state.max_waiting,
      functions: map_size(state.trace.functions),
      traced: Tracing.patterns(state.backend)
    })
  end

  defp valid_options?(options) do
    Options.common?(options, @required ++ @optional, @required) and
      functions?(Keyword.get(options, :functions)) and
      Keyword.get(options, :results, :exceptions) in [:none, :exceptions, :all] and
      positive?(Keyword.get(options, :max_calls, 1)) and
      positive?(Keyword.get(options, :max_bytes, 1)) and
      positive?(Keyword.get(options, :max_waiting, 1)) and
      positive?(Keyword.get(options, :max_ingress_bytes, 1)) and
      rate?(Keyword.get(options, :rate, {1, 1})) and
      is_boolean(Keyword.get(options, :rich, false)) and
      writes?(Keyword.get(options, :writes, []), Keyword.get(options, :functions))
  end

  defp writes?(writes, functions) when is_list(writes) and is_list(functions) do
    traced = Enum.map(functions, &elem(&1, 0))
    Enum.all?(writes, &(&1 in traced))
  end

  defp writes?(_writes, _functions), do: false

  defp functions?(functions) when is_list(functions) and functions != [] do
    Enum.all?(functions, fn
      {{module, function, arity}, label} ->
        is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..255 and
          bounded?(label, 256)

      _other ->
        false
    end)
  end

  defp functions?(_functions), do: false

  defp rate?({max, per_ms}), do: positive?(max) and positive?(per_ms)
  defp rate?(_rate), do: false

  defp safe_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
