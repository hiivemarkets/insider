defmodule Insider.Collector.SystemMonitor do
  @moduledoc """
  Supervised, bounded collection of selected ERTS system anomalies.

  OTP 28 and 29 use an isolated `trace:system/3` session. OTP 27 requires an
  explicit disposable-node legacy capability and refuses any existing global
  system monitor. Raw monitor tuples are ordinary, forgeable mailbox messages;
  they are treated as hostile input and projected through a closed schema.
  """

  use GenServer

  alias Insider.Collector.SystemMonitor.Backend
  alias Insider.Collector.SystemMonitor.Policy
  alias Insider.Collector.SystemMonitor.Receiver
  alias Insider.Event
  alias Insider.Policy.Context
  alias Insider.Protocol.Value
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle

  @required [:authority, :boot_id, :clock_id, :runtime_context]
  @optional [
    :backlog_check_every,
    :batch_size,
    :drain_interval_ms,
    :inbox_size,
    :max_mailbox_size,
    :node,
    :source_instance_id
  ]
  @barrier_timeout_ms 1_000
  @max_source_instance_id_bytes 114

  @spec start_link(RecorderHandle.t(), Policy.t(), keyword()) :: GenServer.on_start()
  def start_link(%RecorderHandle{} = recorder, %Policy{} = policy, options) do
    with true <- Policy.valid?(policy),
         true <- valid_options?(options),
         {:ok, pid} <- GenServer.start_link(__MODULE__, {self(), recorder, policy, options}),
         :ok <- GenServer.call(pid, :startup_result) do
      {:ok, pid}
    else
      false -> {:error, :invalid_options}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def start_link(_recorder, _policy, _options), do: {:error, :invalid_options}

  @spec start_link({RecorderHandle.t(), Policy.t(), keyword()}) :: GenServer.on_start()
  def start_link({%RecorderHandle{} = recorder, %Policy{} = policy, options}) do
    apply(__MODULE__, :start_link, [recorder, policy, options])
  end

  def start_link(_arguments), do: {:error, :invalid_options}

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server), do: safe_call(server, :status)

  @doc """
  Waits for the receiver's current mailbox prefix, then drains visible evidence.

  Concurrent VM delivery after the receiver barrier is outside this guarantee.
  """
  @spec flush(GenServer.server()) ::
          {:ok, map()} | {:error, :receiver_busy | :unavailable}
  def flush(server), do: safe_call(server, :flush)

  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stop(server), do: safe_call(server, :stop)

  @impl GenServer
  def init({owner, recorder, policy, options}) do
    Process.flag(:trap_exit, true)

    case config(owner, recorder, policy, options) do
      {:ok, state} ->
        case start_backend(state, policy) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:ok, %{owner: owner, startup_result: {:error, reason}}}
        end

      {:error, reason} ->
        {:ok, %{owner: owner, startup_result: {:error, reason}}}
    end
  end

  @impl GenServer
  def handle_call(:startup_result, _from, %{startup_result: :ok} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, %{startup_result: {:error, reason}} = state),
    do: {:stop, :normal, {:error, reason}, state}

  def handle_call(:status, _from, state), do: {:reply, {:ok, status_map(state)}, state}

  def handle_call(:flush, _from, %{receiver: nil} = state) do
    state = drain_batch(state, state.inbox_size)
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:flush, _from, state) do
    case Receiver.barrier(state.receiver, state.control_ref, @barrier_timeout_ms) do
      :ok ->
        state = drain_batch(state, state.inbox_size)
        {:reply, {:ok, status_map(state)}, state}

      {:error, :receiver_busy} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stop, _from, state) do
    cancel_timer(state.drain_token)
    {backend, receiver} = shutdown_components(state)
    before = read(state.stats, 5) + read(state.stats, 6)
    state = drain_batch(state, state.inbox_size)
    drained = read(state.stats, 5) + read(state.stats, 6) - before

    cleanup = %{
      backend: backend,
      receiver: receiver,
      cleanup_mechanism: cleanup_mechanism(state.backend),
      concurrent_delivery: :not_quiesced,
      transient_mailbox_bound: :not_guaranteed,
      drained_visible: drained
    }

    {:stop, :normal, {:ok, cleanup}, %{state | backend: nil, drain_token: nil, receiver: nil}}
  end

  @impl GenServer
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}

  def handle_info(
        {:insider_system_monitor, control_ref, :overload, receiver},
        %{control_ref: control_ref, receiver: receiver} = state
      ) do
    {backend, receiver_result} = shutdown_components(state)
    state = drain_batch(state, state.inbox_size)

    cleanup = %{
      backend: backend,
      receiver: receiver_result,
      cleanup_mechanism: cleanup_mechanism(state.backend),
      concurrent_delivery: :not_quiesced,
      transient_mailbox_bound: :not_guaranteed
    }

    {:noreply, %{state | receiver: nil, overload_cleanup: cleanup}}
  end

  def handle_info({:EXIT, receiver, reason}, %{receiver: receiver} = state),
    do: {:stop, {:receiver_exit, reason}, state}

  def handle_info({:drain, token}, %{drain_token: {timer_ref, token}} = state) do
    _cancelled = Process.cancel_timer(timer_ref, async: false, info: false)
    state = drain_batch(state, state.batch_size)
    {:noreply, %{state | drain_token: schedule(state.drain_interval_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_exit_reason, %{startup_result: {:error, _startup_reason}}), do: :ok

  def terminate(_reason, state) do
    cancel_timer(state.drain_token)
    _cleanup = shutdown_components(state)
    :ok
  end

  defp config(owner, recorder, policy, options) do
    config = %{
      allowed_events: Map.new(policy.events, fn {event, _value} -> {event, true} end),
      authority: copy(Keyword.fetch!(options, :authority)),
      backlog_check_every: Keyword.get(options, :backlog_check_every, 16),
      backend: nil,
      batch_size: Keyword.get(options, :batch_size, 64),
      boot_id: copy(Keyword.fetch!(options, :boot_id)),
      clock_id: copy(Keyword.fetch!(options, :clock_id)),
      control_ref: make_ref(),
      drain_interval_ms: Keyword.get(options, :drain_interval_ms, 10),
      drain_token: nil,
      enabled: :atomics.new(1, signed: false),
      high_water: :atomics.new(1, signed: false),
      inbox: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
      inbox_size: Keyword.get(options, :inbox_size, 256),
      max_mailbox_size: Keyword.get(options, :max_mailbox_size, 1_024),
      node: copy(Keyword.get(options, :node, Atom.to_string(node()))),
      owner: owner,
      ownership: :ets.new(Backend, [:set, :public]),
      overload_cleanup: nil,
      receiver: nil,
      recorder: recorder,
      runtime_context: Keyword.fetch!(options, :runtime_context),
      sequence: :atomics.new(1, signed: false),
      source_instance_id:
        options
        |> Keyword.get_lazy(:source_instance_id, fn ->
          "system-monitor-" <>
            Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
        end)
        |> copy(),
      startup_result: :pending,
      stats: :counters.new(10, [:atomics])
    }

    receiver_config =
      Map.take(config, [
        :allowed_events,
        :backlog_check_every,
        :enabled,
        :high_water,
        :inbox,
        :inbox_size,
        :max_mailbox_size,
        :ownership,
        :sequence,
        :stats
      ])

    {:ok, Map.put(config, :receiver_config, receiver_config)}
  rescue
    _error -> {:error, :invalid_options}
  end

  defp start_backend(state, policy) do
    {:ok, receiver} = Receiver.start_link(state.receiver_config, state.control_ref, self())

    case Backend.start(policy, state.runtime_context, receiver, state.ownership) do
      {:ok, backend} ->
        :atomics.put(state.enabled, 1, 1)

        {:ok,
         %{
           state
           | backend: backend,
             drain_token: schedule(state.drain_interval_ms),
             receiver: receiver,
             startup_result: :ok
         }}

      {:error, reason} ->
        _stopped = Receiver.stop(receiver, state.control_ref, @barrier_timeout_ms)
        {:error, reason}
    end
  end

  defp valid_options?(options) do
    with true <- Value.bounded_list?(options, length(@required) + length(@optional)),
         true <- Keyword.keyword?(options),
         keys = Keyword.keys(options),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.all?(keys, &(&1 in (@required ++ @optional))),
         true <- Enum.all?(@required, &(&1 in keys)) do
      inbox_size = Keyword.get(options, :inbox_size, 256)

      bounded?(Keyword.get(options, :authority), 128) and
        Context.valid?(Keyword.get(options, :runtime_context)) and
        bounded?(Keyword.get(options, :boot_id), 128) and
        bounded?(Keyword.get(options, :clock_id), 128) and
        bounded?(Keyword.get(options, :node, Atom.to_string(node())), 256) and
        valid_optional_source_id?(Keyword.get(options, :source_instance_id)) and
        bounded_integer?(inbox_size, 1, 1_024) and
        bounded_integer?(Keyword.get(options, :batch_size, 64), 1, min(inbox_size, 256)) and
        bounded_integer?(Keyword.get(options, :drain_interval_ms, 10), 1, 1_000) and
        bounded_integer?(Keyword.get(options, :max_mailbox_size, 1_024), 1, 4_096) and
        bounded_integer?(Keyword.get(options, :backlog_check_every, 16), 1, 256)
    else
      _failure -> false
    end
  rescue
    _error -> false
  end

  defp drain_batch(state, limit) do
    rows = :ets.tab2list(state.inbox)
    ordered = Enum.sort_by(rows, &elem(&1, 1))

    ordered
    |> Enum.take(limit)
    |> Enum.each(fn row -> drain(row, state) end)

    state
  end

  defp drain({slot, sequence, _shape}, state) do
    case :ets.take(state.inbox, slot) do
      [{^slot, ^sequence, shape}] ->
        case event(state, sequence, shape) do
          {:ok, event} ->
            case Recorder.record(state.recorder, event) do
              :ok -> bump(state.stats, 5)
              {:dropped, _reason} -> bump(state.stats, 6)
            end

          {:error, _reason} ->
            bump(state.stats, 4)
        end

      _rows ->
        :ok
    end
  end

  defp event(state, sequence, shape) do
    Event.new(
      id: state.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: state.node,
      boot_id: state.boot_id,
      source: "system_monitor",
      kind: shape.kind,
      severity: :warning,
      monotonic_time: sequence,
      clock_id: state.clock_id,
      source_instance_id: state.source_instance_id,
      source_sequence: sequence,
      wall_time: nil,
      subject: shape.subject,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes:
        Map.merge(
          %{
            "projection" => "erts.system_monitor/v1",
            "backend" => Atom.to_string(state.backend.mode)
          },
          shape.attributes
        ),
      payload: nil,
      authority: state.authority,
      redactions: [],
      extensions: %{}
    )
  rescue
    _error -> {:error, :invalid_shape}
  catch
    _kind, _reason -> {:error, :invalid_shape}
  end

  defp status_map(state) do
    mailbox_length = mailbox_length(state.receiver)

    %{
      backend: state.backend.mode,
      requested_options: state.backend.requested_options,
      effective_options: state.backend.effective_options,
      enabled: :atomics.get(state.enabled, 1) == 1,
      received: read(state.stats, 1),
      enqueued: read(state.stats, 2),
      shed: read(state.stats, 3),
      invalid: read(state.stats, 4),
      recorded: read(state.stats, 5),
      recorder_dropped: read(state.stats, 6),
      monitor_disabled_overload: read(state.stats, 7),
      cleanup_unknown: read(state.stats, 8),
      handler_failures: read(state.stats, 9),
      post_disable_discarded: read(state.stats, 10),
      overload_cleanup: state.overload_cleanup,
      inbox_count: :ets.info(state.inbox, :size),
      inbox_capacity: state.inbox_size,
      receiver_mailbox_length: mailbox_length,
      receiver_mailbox_high_water: max(mailbox_length, :atomics.get(state.high_water, 1)),
      transient_mailbox_bound: :not_guaranteed
    }
  end

  defp shutdown_components(%{backend: nil}), do: {:not_started, :already_stopped}

  defp shutdown_components(%{backend: %{mode: :isolated}} = state) do
    :atomics.put(state.enabled, 1, 0)
    backend = Backend.disable(state.backend)
    count_cleanup_unknown(state, backend)
    receiver = stop_receiver(state)
    count_cleanup_unknown(state, receiver)
    {backend, receiver}
  end

  defp shutdown_components(%{backend: %{mode: :legacy_node_global}} = state) do
    :atomics.put(state.enabled, 1, 0)
    receiver = stop_receiver(state)
    count_cleanup_unknown(state, receiver)
    backend = Backend.observe_legacy_release(state.backend)
    count_cleanup_unknown(state, backend)
    {backend, receiver}
  end

  defp stop_receiver(%{receiver: receiver, control_ref: control_ref}) when is_pid(receiver),
    do: Receiver.stop(receiver, control_ref, @barrier_timeout_ms)

  defp stop_receiver(_state), do: :already_stopped

  defp cleanup_mechanism(%{mode: :isolated}), do: :trace_session_destroy
  defp cleanup_mechanism(%{mode: :legacy_node_global}), do: :receiver_termination

  defp count_cleanup_unknown(state, :cleanup_unknown), do: bump(state.stats, 8)
  defp count_cleanup_unknown(_state, _result), do: :ok

  defp mailbox_length(receiver) when is_pid(receiver) do
    case Process.info(receiver, :message_queue_len) do
      {:message_queue_len, length} -> length
      _other -> 0
    end
  end

  defp mailbox_length(_receiver), do: 0

  defp schedule(interval) do
    message_token = make_ref()
    {Process.send_after(self(), {:drain, message_token}, interval), message_token}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    {timer_ref, _message_token} = timer
    Process.cancel_timer(timer_ref, async: false, info: false)
  end

  defp safe_call(server, message) do
    GenServer.call(server, message)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp valid_optional_source_id?(nil), do: true
  defp valid_optional_source_id?(value), do: bounded?(value, @max_source_instance_id_bytes)

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp read(stats, index), do: :counters.get(stats, index)
  defp bump(stats, index), do: :counters.add(stats, index, 1)
  defp copy(value), do: :binary.copy(value)
end
