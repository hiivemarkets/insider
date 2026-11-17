defmodule Insider.Collector.Otel do
  @moduledoc """
  Bounded capture of finished OpenTelemetry spans as `otel.span` events.

  It runs only in a collector session that names the `:otel` component, and
  only where the OpenTelemetry SDK is present. It never adds, replaces, or
  reconfigures a span processor, exporter, tracer, or sampler: it observes
  the SDK's span end (`Insider.Collector.Otel.Tracing`), so the node's own
  processors and exporters, including `traces_exporter: :none`, behave
  exactly as before, and removing the capture leaves nothing behind.

  Each finished span reaches this process as one trace message. The
  record-time gate decides first (origin and minimum duration); the span is
  then built into an event (`Insider.Collector.Otel.Span`) and offered to
  the Recorder.

  The capture is throttled by count, not admission-controlled: a trace
  message is in this process's queue before anything here can refuse it. A
  valve process checks the queue every millisecond and pauses the trace
  while more than `:max_waiting` messages wait, resuming at a quarter of
  that; spans that end while paused are not observed. `pauses` counts
  pause starts and `paused` says whether one is ongoing, so every read that
  overlaps a pause can report a loss of unknown size. A span received while more than
  `:max_waiting` wait is counted as `shed` without being built, so memory
  is released as soon as a span is received. Each span's size is bounded
  when its event is built (`Insider.Collector.Otel.Span`). Every received
  span is counted once: `recorded`, `recorder_dropped`, `invalid`, `shed`,
  or filtered by the gate.

  `ingest/1` adds spans from outside the node's SDK, such as a frontend's
  spans, through the same build, profile, and accounting. With
  `capture: false` the collector observes nothing and records only those;
  it then needs neither the SDK nor OTP 28.
  """

  use GenServer

  import Insider.Collector.Options, only: [bounded?: 2, positive?: 1]

  alias Insider.Collector.Gate
  alias Insider.Collector.IngressProfile
  alias Insider.Collector.Options
  alias Insider.Collector.Otel.Span
  alias Insider.Collector.Otel.Tracing
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle

  @required [:authority, :boot_id, :clock_id, :environment]
  @optional [:capture, :gate, :ingest_seen_max, :max_waiting, :node, :rich, :source_instance_id]
  # Span ids of ingested spans already recorded, so a retried ingest (after
  # a `timeout`, whose outcome is unknown) records each span once. Bounded:
  # the oldest id is forgotten past this many, counted as `seen_evicted`.
  @default_ingest_seen_max 16_384
  @default_max_waiting 1_024
  @valve_interval_ms 1
  @flush_timeout_ms 1_000
  # A terminal drain that reaches its deadline counts the spans still
  # waiting, without building them, for at most this long more.
  @abandon_timeout_ms 500
  # The valve's exit, the drain, and the count of what it abandons.
  @stop_timeout_ms 3_500
  @ingest_max 512
  @ingest_timeout_ms 2_000
  # Recording 512 span maps takes milliseconds; this bounds the reply wait
  # once the collector has taken a call before its deadline.
  @ingest_reply_ms 500
  @counters [
    :received,
    :recorded,
    :recorder_dropped,
    :invalid,
    :shed,
    :ingested,
    :duplicate,
    :seen_evicted,
    :abandoned
  ]

  @doc "The most spans one `ingest/1` call takes."
  @spec ingest_max() :: pos_integer()
  def ingest_max, do: @ingest_max

  @spec start_link(RecorderHandle.t(), keyword()) :: GenServer.on_start() | {:error, atom()}
  def start_link(%RecorderHandle{} = recorder, options) when is_list(options) do
    with true <- valid_options?(options),
         {:ok, profile} <- IngressProfile.new(Keyword.fetch!(options, :environment)),
         true <- profile.observation_enabled,
         true <- not Keyword.get(options, :capture, true) or Tracing.sdk_present?() do
      case GenServer.start_link(__MODULE__, {self(), recorder, options}, name: __MODULE__) do
        {:ok, pid} ->
          case GenServer.call(pid, :startup_result) do
            :ok -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end

        {:error, {:already_started, _pid}} ->
          {:error, :already_started}

        other ->
          other
      end
    else
      false ->
        cond do
          not valid_options?(options) -> {:error, :invalid_options}
          not Tracing.sdk_present?() -> {:error, :sdk_absent}
          true -> {:error, :environment_denied}
        end

      {:error, _reason} ->
        {:error, :invalid_options}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def start_link(_recorder, _options), do: {:error, :invalid_options}

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server), do: safe_call(server, :status, 5_000)

  @doc """
  Processes the spans that ended before the call, for at most one second,
  then returns the status; `pending` counts the span messages still waiting.
  The call waits behind span messages already queued, so a collector with
  more queued than it can process within the two-second call bound returns
  `{:error, :unavailable}` (a live session then reports
  `otel_accounting_unavailable`). With the default `:max_waiting`, spans
  received above it are shed cheaply, which keeps that wait short.
  """
  @spec flush(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def flush(server), do: safe_call(server, :flush, @flush_timeout_ms + 1_000)

  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stop(server), do: safe_call(server, :stop, @stop_timeout_ms)

  @doc """
  The services and routes each recorded trace's spans named, newest
  `#{4_096}` traces: `%{trace_id => %{services: MapSet, routes: MapSet}}`.
  Only spans this collector recorded count, from the SDK and from
  `ingest/1` alike, each credential-masked as `Insider.Redaction.Credentials`
  masks event text; a trace keeps at most eight of each. A live view scoped
  to services or routes resolves its traces from it (`Insider.Live.View`).
  """
  @spec trace_index(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def trace_index(server), do: safe_call(server, :trace_index, 2_000)

  @doc """
  Records spans built outside this node's SDK (span maps, see
  `Insider.Collector.Otel.Span`) in the running session, under its profile,
  gate, and accounting. At most `ingest_max/0` spans per call. Returns the
  `"accepted"`, `"rejected"` (invalid or refused by the Recorder),
  `"filtered"`, `"shed"`, and `"duplicate"` counts, or `{:error,
  :not_running}` when no session runs the otel component.

  Ingest is idempotent per `{trace_id, span_id}`: a span this collector
  already recorded from an ingest is counted as `"duplicate"` and not
  recorded again (within the last `:ingest_seen_max` recorded ids, default
  16,384; older ids are forgotten and counted as `seen_evicted`).
  """
  @spec ingest([map()]) :: {:ok, map()} | {:error, :not_running | :invalid_options | :timeout}
  def ingest(spans),
    do: ingest(spans, System.monotonic_time(:millisecond) + @ingest_timeout_ms)

  @doc """
  `ingest/1` with a `deadline` (monotonic milliseconds). A call the
  collector takes after its deadline is refused before any span or counter
  is touched; the caller waits up to `ingest_reply_ms/0` past the deadline.

  `{:error, :timeout}` means **outcome unknown**: a call taken before the
  deadline may still be recording when the caller stops waiting, so some,
  all, or none of its spans may be recorded. Retrying the same spans does
  not duplicate a span while its id is among the last `:ingest_seen_max`
  ingested ids this collector recorded; a forgotten id (counted as
  `seen_evicted`) is recorded again.
  """
  @spec ingest([map()], integer()) ::
          {:ok, map()} | {:error, :not_running | :invalid_options | :timeout}
  def ingest(spans, deadline) when is_list(spans) and is_integer(deadline) do
    if length(Enum.take(spans, @ingest_max + 1)) > @ingest_max do
      {:error, :invalid_options}
    else
      wait = max(deadline - System.monotonic_time(:millisecond), 0) + @ingest_reply_ms
      GenServer.call(__MODULE__, {:ingest, spans, deadline}, wait)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :not_running}
  end

  def ingest(_spans, _deadline), do: {:error, :invalid_options}

  @doc "How long a taken `ingest/2` call may still take to record its spans."
  @spec ingest_reply_ms() :: pos_integer()
  def ingest_reply_ms, do: @ingest_reply_ms

  @impl GenServer
  def init({owner, recorder, options}) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    state = %{
      backend: nil,
      gate: Keyword.get(options, :gate),
      node: Keyword.get(options, :node, Atom.to_string(node())),
      owner: owner,
      recorder: recorder,
      rich: Keyword.get(options, :rich, false),
      sequence: 0,
      service: Tracing.service_name(),
      max_waiting: Keyword.get(options, :max_waiting, @default_max_waiting),
      # Pauses so far, and whether delivery is paused now.
      valve_state: :atomics.new(2, signed: false),
      valve: nil,
      startup_result: :pending,
      stats: Map.new(@counters, &{&1, 0}),
      drain_incomplete: 0,
      seen: %{},
      seen_order: :queue.new(),
      traces: %{},
      trace_order: :queue.new(),
      seen_max: Keyword.get(options, :ingest_seen_max, @default_ingest_seen_max),
      context: %{
        authority: Keyword.fetch!(options, :authority),
        boot_id: Keyword.fetch!(options, :boot_id),
        clock_id: Keyword.fetch!(options, :clock_id),
        source_instance_id:
          Keyword.get_lazy(options, :source_instance_id, fn ->
            "otel-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
          end)
      }
    }

    case install(Keyword.get(options, :capture, true)) do
      :ingest_only ->
        {:ok, %{state | startup_result: :ok}}

      {:ok, backend} ->
        collector = self()
        max_waiting = state.max_waiting
        valve_state = state.valve_state

        valve =
          spawn_link(fn ->
            valve(
              collector,
              backend,
              %{max: max_waiting, state: valve_state},
              false
            )
          end)

        {:ok, %{state | backend: backend, valve: valve, startup_result: :ok}}

      {:error, reason} ->
        {:ok, %{state | startup_result: {:error, reason}}}
    end
  end

  # With `capture: false` the collector records only spans handed to
  # `ingest/1`: a host that receives spans from elsewhere, or a node without
  # isolated trace sessions, uses it without observing the node's SDK.
  defp install(false), do: :ingest_only
  defp install(true), do: Tracing.install(self())

  @impl GenServer
  def handle_call(:startup_result, _from, %{startup_result: :ok} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, %{startup_result: {:error, reason}} = state),
    do: {:stop, :normal, {:error, reason}, state}

  def handle_call(:status, _from, state), do: {:reply, {:ok, status_map(state)}, state}
  def handle_call(:trace_index, _from, state), do: {:reply, {:ok, state.traces}, state}

  def handle_call(:flush, _from, state) do
    state = drain_delivered(state)
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:stop, _from, state) do
    before = state.stats.received
    :ok = finish_valve(state)
    trace = Tracing.remove(state.backend)
    # Spans that ended before the removal are still delivered after it. A
    # drain that runs out of time counts the rest as `abandoned`, so the
    # final status accounts for every span that ended.
    state = drain_delivered(state, :terminal)

    # `status` is the final status, after the drain: a seal keeps it as the
    # component's evidence.
    cleanup = %{
      trace: trace,
      drained: state.stats.received - before,
      recorder_dropped: state.stats.recorder_dropped,
      shed: state.stats.shed,
      status: status_map(state)
    }

    {:stop, :normal, {:ok, cleanup}, %{state | backend: nil}}
  end

  # The deadline is checked before any counter or span is touched, so a
  # refused call changes nothing.
  def handle_call({:ingest, spans, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, :timeout}, state}
    else
      {counts, state} = ingest_spans(spans, state)
      {:reply, {:ok, counts}, state}
    end
  end

  @impl GenServer
  # Only the span end's return is a span; any other trace message is
  # ignored.
  def handle_info({:trace, pid, :return_from, {:otel_span_utils, :end_span, 2}, span}, state),
    do: {:noreply, captured(pid, span, state)}

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _removed = Tracing.remove(Map.get(state, :backend))
    :ok
  end

  # One finished span from the node's SDK. Above the shed threshold it is
  # only counted.
  defp captured(pid, span, state) do
    state = bump(state, :received)

    if shedding?(state) do
      bump(state, :shed)
    else
      case Span.decode(span, state.service, pid) do
        {:ok, map} -> admit(map, pid, state, "sdk")
        :error -> bump(state, :invalid)
      end
    end
  end

  # A span whose `{trace_id, span_id}` this collector already recorded from
  # an ingest is a `"duplicate"`: counted, never recorded again, so retrying
  # a call whose outcome was unknown cannot duplicate evidence.
  defp ingest_spans(spans, state) do
    initial = %{"accepted" => 0, "rejected" => 0, "filtered" => 0, "shed" => 0, "duplicate" => 0}

    Enum.reduce(spans, {initial, state}, fn span, {counts, state} ->
      state = bump(bump(state, :received), :ingested)
      before = state.stats
      key = span_key(span)

      state =
        cond do
          key != nil and Map.has_key?(state.seen, key) -> bump(state, :duplicate)
          shedding?(state) -> bump(state, :shed)
          is_map(span) -> admit(Map.put(span, "pid", nil), nil, state, "ingest")
          true -> bump(state, :invalid)
        end

      result = outcome(before, state.stats)
      state = if result == "accepted" and key != nil, do: remember(state, key), else: state
      {Map.update!(counts, result, &(&1 + 1)), state}
    end)
  end

  defp span_key(%{"trace_id" => trace_id, "span_id" => span_id})
       when is_binary(trace_id) and is_binary(span_id),
       do: {trace_id, span_id}

  defp span_key(_span), do: nil

  # FIFO-bounded: past `ingest_seen_max` ids the oldest is forgotten, and a
  # retry of that span would be recorded again; `seen_evicted` counts them.
  defp remember(state, key) do
    seen = Map.put(state.seen, key, true)
    order = :queue.in(key, state.seen_order)

    if map_size(seen) > state.seen_max do
      {{:value, oldest}, order} = :queue.out(order)
      bump(%{state | seen: Map.delete(seen, oldest), seen_order: order}, :seen_evicted)
    else
      %{state | seen: seen, seen_order: order}
    end
  end

  defp outcome(before, after_stats) do
    cond do
      after_stats.duplicate > before.duplicate -> "duplicate"
      after_stats.recorded > before.recorded -> "accepted"
      after_stats.shed > before.shed -> "shed"
      after_stats.invalid > before.invalid -> "rejected"
      after_stats.recorder_dropped > before.recorder_dropped -> "rejected"
      true -> "filtered"
    end
  end

  defp admit(map, pid, state, capture) do
    if Gate.otel?(state.gate, pid, Map.get(map, "duration_us"), Map.get(map, "status") == "error") do
      record(map, state, capture)
    else
      state
    end
  end

  defp record(map, state, capture) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    context =
      Map.merge(state.context, %{
        node: state.node,
        sequence: sequence,
        rich: state.rich,
        capture: capture
      })

    case Span.event(map, context) do
      {:ok, event} ->
        case Recorder.record(state.recorder, event) do
          :ok -> state |> bump(:recorded) |> index(event, map)
          {:dropped, _reason} -> bump(state, :recorder_dropped)
        end

      {:error, _reason} ->
        bump(state, :invalid)
    end
  end

  # A recorded span's service, as its event names it, and its route, from
  # the span attributes the event was built from; both masked.
  @trace_index_max 4_096
  @trace_labels_max 8

  defp index(state, event, map) do
    trace_id = event.attributes["trace_id"]
    service = label(event.attributes["service"])
    route = label(Span.route(Map.get(map, "attributes")))

    if service == nil and route == nil do
      state
    else
      trace = Map.get(state.traces, trace_id, %{services: MapSet.new(), routes: MapSet.new()})

      trace = %{
        services: add_label(trace.services, service),
        routes: add_label(trace.routes, route)
      }

      if Map.has_key?(state.traces, trace_id) do
        %{state | traces: Map.put(state.traces, trace_id, trace)}
      else
        traces = Map.put(state.traces, trace_id, trace)
        order = :queue.in(trace_id, state.trace_order)

        if map_size(traces) > @trace_index_max do
          {{:value, oldest}, order} = :queue.out(order)
          %{state | traces: Map.delete(traces, oldest), trace_order: order}
        else
          %{state | traces: traces, trace_order: order}
        end
      end
    end
  end

  defp label(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value), do: Insider.Redaction.Credentials.mask_text(value)
  end

  defp label(_value), do: nil

  defp add_label(set, nil), do: set

  defp add_label(set, label) do
    if MapSet.size(set) < @trace_labels_max, do: MapSet.put(set, label), else: set
  end

  defp shedding?(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, waiting} -> waiting > state.max_waiting
      _other -> true
    end
  end

  # Processes the spans that ended before this call: the runtime's delivery
  # marker follows their trace messages.
  defp drain_delivered(state, mode \\ :flush)
  defp drain_delivered(%{backend: nil} = state, _mode), do: state

  defp drain_delivered(state, mode) do
    case Tracing.delivered(state.backend) do
      {:ok, reference} ->
        deadline = System.monotonic_time(:millisecond) + @flush_timeout_ms

        case drain_until(reference, deadline, state) do
          {:done, state} -> state
          {:deadline, state} when mode == :flush -> state
          {:deadline, state} -> abandon_until(reference, abandon_deadline(), state)
        end

      :error ->
        state
    end
  end

  defp abandon_deadline, do: System.monotonic_time(:millisecond) + @abandon_timeout_ms

  # The collector is about to exit: every span still waiting before the
  # marker is counted, not built. If the marker does not arrive in time,
  # some spans may still be in flight and the count is incomplete.
  #
  # The deadline is checked before every message: `receive ... after 0`
  # still takes a queued match, so a clamped timeout alone would keep
  # counting past it.
  defp abandon_until(reference, deadline, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      %{state | drain_incomplete: 1}
    else
      receive do
        {:trace_delivered, :all, ^reference} ->
          state

        {:trace, _pid, :return_from, {:otel_span_utils, :end_span, 2}, _span} ->
          abandon_until(reference, deadline, bump(state, :abandoned))
      after
        remaining -> %{state | drain_incomplete: 1}
      end
    end
  end

  # The deadline is checked before every message, not only when none is
  # waiting: spans that keep arriving must not hold a flush past its bound.
  # A flush that stops at the deadline leaves the rest, and the marker, for
  # the next one (`pending` says how many wait); a stale marker is ignored.
  defp drain_until(reference, deadline, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:deadline, state}
    else
      receive do
        {:trace_delivered, :all, ^reference} ->
          {:done, state}

        {:trace, pid, :return_from, {:otel_span_utils, :end_span, 2}, span} ->
          drain_until(reference, deadline, captured(pid, span, state))
      after
        remaining -> {:deadline, state}
      end
    end
  end

  defp status_map(state) do
    {:message_queue_len, pending} = Process.info(self(), :message_queue_len)

    state.stats
    |> Map.merge(%{
      pauses: :atomics.get(state.valve_state, 1),
      paused: :atomics.get(state.valve_state, 2),
      pending: pending,
      drain_incomplete: state.drain_incomplete,
      max_waiting: state.max_waiting,
      installed: if(Tracing.installed?(state.backend), do: 1, else: 0),
      sdk_running: if(Tracing.sdk_running?(), do: 1, else: 0)
    })
  end

  defp bump(state, counter), do: %{state | stats: Map.update!(state.stats, counter, &(&1 + 1))}

  defp valid_options?(options) do
    Options.common?(options, @required ++ @optional, @required) and
      bounded?(Keyword.get(options, :source_instance_id, "otel"), 114) and
      is_boolean(Keyword.get(options, :rich, false)) and
      is_boolean(Keyword.get(options, :capture, true)) and
      positive?(Keyword.get(options, :max_waiting, @default_max_waiting)) and
      positive?(Keyword.get(options, :ingest_seen_max, @default_ingest_seen_max)) and
      gate?(Keyword.get(options, :gate))
  end

  defp gate?(nil), do: true
  defp gate?(gate), do: Gate.key?(gate)

  # Pauses the trace while too many span messages wait, and resumes it once
  # they are drained, publishing the number of pauses and whether it is
  # paused. Spans that end while paused are not observed. It exits with the
  # collector, or on `{:final, from}`. Only the count is checked: a binary a
  # queued message holds is not visible in the collector's memory.
  #
  # Each tick is a timer message rather than a receive timeout, so a tick
  # that comes due while the valve is not running (suspended by a debugger,
  # say) still arrives.
  defp valve(collector, backend, config, paused?) do
    timer = Process.send_after(self(), :valve_tick, @valve_interval_ms)

    receive do
      {:final, from} ->
        Process.cancel_timer(timer)
        send(from, {:valve_final, self()})

      :valve_tick ->
        valve_tick(collector, backend, config, paused?)
    end
  end

  defp valve_tick(collector, backend, config, paused?) do
    case Process.info(collector, :message_queue_len) do
      {:message_queue_len, waiting} ->
        paused? =
          cond do
            not paused? and waiting > config.max and Tracing.pause(backend) == :ok ->
              :atomics.add(config.state, 1, 1)
              :atomics.put(config.state, 2, 1)
              true

            paused? and waiting <= div(config.max, 4) and Tracing.resume(backend) == :ok ->
              :atomics.put(config.state, 2, 0)
              false

            true ->
              paused?
          end

        valve(collector, backend, config, paused?)

      nil ->
        :ok
    end
  end

  # The valve exits before the capture goes.
  defp finish_valve(%{valve: valve}) when is_pid(valve) do
    ref = Process.monitor(valve)
    send(valve, {:final, self()})

    receive do
      {:valve_final, ^valve} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, ^valve, _reason} -> :ok
    after
      @flush_timeout_ms -> Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp finish_valve(_state), do: :ok

  defp safe_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
