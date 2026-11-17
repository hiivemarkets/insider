defmodule Insider.Collector.Poller do
  @moduledoc """
  Periodically records bounded scalar VM and explicitly targeted process samples.

  By default the poller never enumerates processes and never requests
  messages, dictionaries, links, monitors, stack traces, or other private
  process state. Configured with `top_processes` or `top_ets_tables`, each
  cycle also scans every local process or ETS table once for bounded
  rankings (`process_top`, `ets_top`), reading only scalar counters, the
  group leader, and, for ranked processes, the registered name, current
  function, and the `$initial_call` dictionary key. Protected targets are
  never read; Insider's own processes and tables are summed apart from the
  rankings and reported next to the VM totals. With `top_ports`, each cycle
  also counts every local port by type and owner (`port_top`), reading only
  each port's name, connected process, and OS pid, with each type's growth
  since the previous census; ports of Insider's own processes are counted
  apart. `watch_names` samples the processes registered under those names
  each cycle (`process_watch`).
  Probe work runs in one monitored worker at a time. A timeout bounds how long
  the poller waits; it cannot roll back a `process_info/2` request already
  delivered to the target, so timeout events disclose that uncertainty.
  """

  use GenServer

  alias Insider.Collector.Poller.Config
  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ports
  alias Insider.Collector.Poller.Processes
  alias Insider.Event
  alias Insider.Identity.Subject
  alias Insider.Policy.ProtectedTargets
  alias Insider.Protocol.Value
  alias Insider.Recorder
  alias Insider.Recorder.Handle

  # A ranking event's metrics must leave room for its other attributes
  # within the 4 KiB event attribute bound.
  @scan_budget_bytes 3_500
  @scan_result_bytes 16_384
  # Each scan's Insider totals: {count key, bytes key} under its
  # `"insider"` metrics, and the VM sample fields they become.
  @footprint %{
    processes:
      {"process_count", "memory_bytes", "insider_process_count", "insider_processes_bytes"},
    ets: {"table_count", "memory_bytes", "insider_ets_tables", "insider_ets_bytes"}
  }

  @stats [
    :cycles_started,
    :cycles_completed,
    :cycles_truncated,
    :probes_started,
    :probes_complete,
    :probes_partial,
    :probes_timeout,
    :probes_protected,
    :probes_exited,
    :probes_failed,
    :probes_not_registered,
    :probes_truncated,
    :events_recorded,
    :events_invalid,
    :recorder_dropped,
    :cleanup_uncertain
  ]

  @spec start_link(Handle.t(), keyword()) :: GenServer.on_start()
  def start_link(%Handle{} = recorder, options) do
    with {:ok, config} <- Config.new(recorder, options) do
      GenServer.start_link(__MODULE__, config)
    end
  end

  def start_link(_recorder, _options), do: {:error, :invalid_options}

  @spec start_link({Handle.t(), keyword()}) :: GenServer.on_start()
  def start_link({%Handle{} = recorder, options}), do: start_link(recorder, options)
  def start_link(_arguments), do: {:error, :invalid_options}

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server) do
    GenServer.call(server, :status)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Permanently stops periodic polling and waits, within `deadline`, for the
  current probe to reach an accounting boundary.

  A successful reply is a barrier: the returned status includes every event
  this poller can still offer to its recorder, and this poller will never start
  another probe. A deadline failure makes no quiescence claim, but still
  cancels future polling and quarantines the current worker.
  """
  @spec quiesce(GenServer.server(), integer(), timeout()) ::
          {:ok, map()} | {:error, :quiescence_in_progress | :request_expired | :unavailable}
  def quiesce(server, deadline, timeout)
      when is_integer(deadline) and is_integer(timeout) and timeout > 0 do
    GenServer.call(server, {:quiesce, deadline}, timeout)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, {:timeout, _call} -> {:error, :request_expired}
    :exit, _reason -> {:error, :unavailable}
  end

  def quiesce(_server, _deadline, _timeout), do: {:error, :unavailable}

  @impl GenServer
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    with {:ok, protection} <-
           ProtectedTargets.bind_collector(config.protected_target_policy, config.recorder.pid) do
      state = %{
        config: %{config | protected_target_policy: protection},
        cycle: nil,
        cycle_sequence: 0,
        inflight: nil,
        last_event_time: nil,
        mode: :running,
        port_scan: nil,
        process_scan: nil,
        quiesce: nil,
        sequence: 0,
        stats: Map.new(@stats, &{&1, 0}),
        timer: nil,
        watched: %{}
      }

      {:ok, schedule(state, config.initial_delay_ms)}
    else
      _error -> {:stop, :invalid_options}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call({:quiesce, _deadline}, _from, %{mode: :quiesced} = state) do
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call({:quiesce, _deadline}, _from, %{mode: :quiescing} = state) do
    {:reply, {:error, :quiescence_in_progress}, state}
  end

  def handle_call({:quiesce, deadline}, from, state) when is_integer(deadline) do
    state = cancel_scheduled(state)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:reply, {:error, :request_expired}, state}

      is_nil(state.inflight) ->
        state =
          complete_quiescence(%{state | mode: :quiescing, quiesce: %{from: from, timer: nil}})

        {:noreply, state}

      true ->
        token = make_ref()
        timer = Process.send_after(self(), {:quiesce_timeout, token}, max(remaining - 1, 0))

        {:noreply,
         %{
           state
           | mode: :quiescing,
             quiesce: %{from: from, timer: timer, token: token}
         }}
    end
  end

  @impl GenServer
  def handle_info({:scheduled_poll, token}, %{timer: {_timer, token}, cycle: nil} = state) do
    {:noreply, state |> Map.put(:timer, nil) |> start_cycle()}
  end

  def handle_info(
        {:quiesce_timeout, token},
        %{mode: :quiescing, quiesce: %{from: from, token: token}} = state
      ) do
    state = quarantine_inflight(state)
    GenServer.reply(from, {:error, :request_expired})
    {:noreply, %{state | quiesce: nil}}
  end

  def handle_info(
        {:poller_probe_result, token, result},
        %{inflight: %{phase: :running, token: token} = inflight} = state
      ) do
    cancel_timer(inflight.timeout_timer)
    Process.demonitor(inflight.monitor, [:flush])

    {result, state} = keep_snapshot(state, inflight.probe, result)

    state =
      state
      |> Map.put(:inflight, nil)
      |> emit_result(inflight.probe, result, elapsed(inflight.started_at_us), "observed")
      |> advance_cycle()

    {:noreply, state}
  end

  def handle_info(
        {:probe_timeout, token},
        %{inflight: %{phase: :running, token: token} = inflight} = state
      ) do
    Process.exit(inflight.worker, :kill)
    cleanup_token = make_ref()

    cleanup_timer =
      Process.send_after(
        self(),
        {:cleanup_timeout, cleanup_token},
        cleanup_delay(state)
      )

    inflight = %{
      inflight
      | cleanup_timer: cleanup_timer,
        cleanup_token: cleanup_token,
        phase: :awaiting_cleanup
    }

    {:noreply, %{state | inflight: inflight}}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{inflight: %{phase: :awaiting_cleanup, monitor: monitor, worker: worker} = inflight} =
          state
      ) do
    cancel_timer(inflight.cleanup_timer)

    state =
      state
      |> Map.put(:inflight, nil)
      |> emit_result(
        inflight.probe,
        {:error, :timeout},
        elapsed(inflight.started_at_us),
        "observed"
      )
      |> advance_cycle()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{inflight: %{phase: :quarantined, monitor: monitor, worker: worker}} = state
      ) do
    state = state |> Map.put(:inflight, nil) |> advance_cycle()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{inflight: %{phase: :running, monitor: monitor, worker: worker} = inflight} = state
      ) do
    cancel_timer(inflight.timeout_timer)

    state =
      state
      |> Map.put(:inflight, nil)
      |> emit_result(
        inflight.probe,
        {:error, :failed},
        elapsed(inflight.started_at_us),
        "observed"
      )
      |> advance_cycle()

    {:noreply, state}
  end

  def handle_info(
        {:cleanup_timeout, token},
        %{inflight: %{phase: :awaiting_cleanup, cleanup_token: token} = inflight} = state
      ) do
    inflight = %{inflight | cleanup_timer: nil, cleanup_token: nil, phase: :quarantined}

    state =
      state
      |> bump(:cleanup_uncertain)
      |> Map.put(:inflight, inflight)
      |> emit_result(
        inflight.probe,
        {:error, :timeout},
        elapsed(inflight.started_at_us),
        "uncertain"
      )

    {:noreply, state}
  end

  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_scheduled(state)
    cancel_timer(if(state.quiesce, do: state.quiesce.timer, else: nil))

    if state.inflight do
      Process.exit(state.inflight.worker, :kill)
      Process.demonitor(state.inflight.monitor, [:flush])
    end

    :ok
  end

  defp start_cycle(state) do
    cycle_sequence = state.cycle_sequence + 1

    cycle = %{
      deadline_us: now_us() + state.config.cycle_timeout_ms * 1_000,
      footprint: %{},
      id: Integer.to_string(cycle_sequence, 36),
      probes: cycle_probes(state.config)
    }

    state
    |> Map.merge(%{cycle: cycle, cycle_sequence: cycle_sequence})
    |> bump(:cycles_started)
    |> advance_cycle()
  end

  # The scans run before the VM sample, which reports their Insider
  # footprint next to the VM totals.
  defp cycle_probes(config) do
    scans =
      [
        {config.top_processes > 0, :processes},
        {config.top_ets_tables > 0, :ets},
        {config.top_ports > 0, :ports}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    scans ++
      [:vm | Enum.map(config.watch_names, &{:watch, &1})] ++
      Enum.map(config.targets, &{:process, &1})
  end

  defp advance_cycle(%{cycle: %{probes: []}} = state), do: finish_cycle(state)

  defp advance_cycle(%{mode: :quiescing} = state), do: truncate_cycle(state)

  defp advance_cycle(%{cycle: cycle} = state) do
    if now_us() >= cycle.deadline_us do
      truncate_cycle(state)
    else
      [probe | _rest] = cycle.probes
      advance_probe(state, resolve(probe))
    end
  end

  # A watched name is resolved when its probe starts, so a process that
  # restarts under the same name is followed.
  defp resolve({:watch, name}), do: {:watch, name, Process.whereis(name)}
  defp resolve(probe), do: probe

  defp advance_probe(state, {:watch, _name, nil} = unregistered) do
    state
    |> pop_probe()
    |> emit_result(unregistered, {:error, :not_registered}, 0, "not_started")
    |> advance_cycle()
  end

  defp advance_probe(state, probe) do
    case protection(probe, state) do
      {:protected, evidence} ->
        state
        |> pop_probe()
        |> emit_result(probe, {:error, :protected}, 0, "not_started", evidence)
        |> advance_cycle()

      :allowed ->
        start_probe(state, probe)
    end
  end

  defp start_probe(state, probe) do
    case probe_timeout(state) do
      {:ok, timeout_ms} -> launch_probe(state, probe, timeout_ms)
      :truncate -> truncate_cycle(state)
    end
  end

  # The timeout is known before the worker starts, so a process scan can
  # finish inside it (see `probe_arguments/4`).
  defp launch_probe(state, probe, timeout_ms) do
    token = make_ref()
    parent = self()
    provider = state.config.provider
    started_at_us = now_us()
    arguments = probe_arguments(state, probe, started_at_us, timeout_ms)

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:run_probe, ^token} ->
              result = provider |> safely_probe(probe, arguments) |> bounded_result(probe)
              send(parent, {:poller_probe_result, token, result})
          end
        end,
        [:link, :monitor]
      )

    timeout_timer = Process.send_after(self(), {:probe_timeout, token}, timeout_ms)

    inflight = %{
      cleanup_timer: nil,
      cleanup_token: nil,
      monitor: monitor,
      phase: :running,
      probe: probe,
      started_at_us: started_at_us,
      timeout_timer: timeout_timer,
      token: token,
      worker: worker
    }

    send(worker, {:run_probe, token})

    state
    |> pop_probe()
    |> bump(:probes_started)
    |> Map.put(:inflight, inflight)
  end

  defp probe_timeout(state) do
    remaining_ms = div(max(state.cycle.deadline_us - now_us(), 0), 1_000)
    available_ms = remaining_ms - state.config.cleanup_timeout_ms

    if available_ms >= 1 do
      {:ok, min(state.config.probe_timeout_ms, available_ms)}
    else
      :truncate
    end
  end

  defp pop_probe(state), do: update_in(state, [:cycle, :probes], &tl/1)

  defp truncate_cycle(state) do
    skipped = length(state.cycle.probes)

    state
    |> bump(:cycles_truncated)
    |> add(:probes_truncated, skipped)
    |> put_in([:cycle, :probes], [])
    |> emit_truncation(skipped)
    |> finish_cycle()
  end

  # A process scan stops scanning at 5/8 of its probe timeout and naming at
  # 7/8, so it returns what it reached before the timeout fires; the rest
  # absorbs the answer it is waiting for when its deadline passes.
  defp probe_arguments(state, :processes, started_at_us, timeout_ms) do
    budget_us = timeout_ms * 1_000

    options =
      state
      |> scan_options(state.config.top_processes)
      |> Map.merge(%{
        deadline_us: started_at_us + div(budget_us * 5, 8),
        names_deadline_us: started_at_us + div(budget_us * 7, 8)
      })

    [state.process_scan, options]
  end

  defp probe_arguments(state, :ets, _started_at_us, _timeout_ms),
    do: [scan_options(state, state.config.top_ets_tables)]

  defp probe_arguments(state, :ports, _started_at_us, _timeout_ms),
    do: [state.port_scan, scan_options(state, state.config.top_ports)]

  defp probe_arguments(_state, :vm, _started_at_us, _timeout_ms), do: []
  defp probe_arguments(_state, {:watch, _name, pid}, _started_at_us, _timeout_ms), do: [pid]
  defp probe_arguments(_state, {:process, pid}, _started_at_us, _timeout_ms), do: [pid]

  # Resolved for each scan, so a protected process that restarted since the
  # session began is still never read.
  defp scan_options(state, top) do
    state.config.protected_target_policy
    |> ProtectedTargets.scan_inventory()
    |> Map.merge(%{top: top, master: insider_master(), budget_bytes: @scan_budget_bytes})
  end

  # Every process Insider's application starts has its application master
  # as group leader. Without the application (a bare collector in a test),
  # only the control plane is Insider's.
  defp insider_master do
    case :application_controller.get_master(:insider) do
      master when is_pid(master) -> master
      :undefined -> nil
    end
  end

  defp safely_probe(provider, probe, arguments),
    do: safely_apply(provider, probe_function(probe), arguments)

  defp probe_function(:processes), do: :process_top
  defp probe_function(:ets), do: :ets_top
  defp probe_function(:ports), do: :port_top
  defp probe_function(:vm), do: :vm_sample
  defp probe_function(_process), do: :process_sample

  defp safely_apply(provider, function, arguments) do
    apply(provider, function, arguments)
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp emit_result(
         state,
         probe,
         result,
         duration_us,
         cleanup,
         protection \\ %{"class" => "not_applicable"}
       ) do
    {status, metrics, unavailable} = normalize_result(result)
    {state, status, metrics, unavailable} = annotate(state, probe, status, metrics, unavailable)

    attributes = %{
      "cleanup" => cleanup,
      "cycle_id" => state.cycle.id,
      "field_set" => field_set(probe),
      "metrics" => metrics,
      "observer_effect" => "synchronous_runtime_inspection",
      "probe_status" => Atom.to_string(status),
      "provider" => Atom.to_string(state.config.provider),
      "sample_duration_us" => min(max(duration_us, 0), 9_223_372_036_854_775_807),
      "timeout_cancellation" =>
        if(status == :timeout, do: "not_guaranteed", else: "not_applicable"),
      "target_protection" => protection,
      "unavailable" => unavailable
    }

    state
    |> bump(probe_counter(status))
    |> record_event(probe, watch_name(attributes, probe))
  end

  defp watch_name(attributes, {:watch, name, _pid}),
    do: Map.put(attributes, "watch_name", Names.display(name))

  defp watch_name(attributes, _probe), do: attributes

  defp normalize_result({:ok, status, metrics, unavailable})
       when status in [:complete, :partial] and is_map(metrics) and is_list(unavailable),
       do: {status, metrics, unavailable}

  defp normalize_result({:error, status})
       when status in [:timeout, :protected, :exited, :failed, :not_registered],
       do: {status, %{}, []}

  defp normalize_result(_result), do: {:failed, %{}, []}

  # A process scan's snapshot is kept for the next scan's reductions deltas,
  # and a port census's for its growth, and neither is recorded. A failed
  # scan keeps the previous snapshot, so the next delta spans both
  # intervals and its window_ms says so.
  defp keep_snapshot(state, :processes, {:ok, status, metrics, unavailable, snapshot}),
    do: {{:ok, status, metrics, unavailable}, %{state | process_scan: snapshot}}

  defp keep_snapshot(state, :ports, {:ok, status, metrics, unavailable, snapshot}),
    do: {{:ok, status, metrics, unavailable}, %{state | port_scan: snapshot}}

  defp keep_snapshot(state, _probe, result), do: {result, state}

  # The scans' complete Insider totals go into this cycle's VM sample, next
  # to the VM totals that include them; a total a scan marks incomplete
  # (`"complete" => false`: cut by the scan limit, or an Insider process a
  # host protects) stays out, so the VM sample reports it unavailable. A
  # watched process's reductions since the previous sample of the same
  # process become its reductions_delta.
  defp annotate(state, scan, status, metrics, unavailable)
       when scan in [:processes, :ets] and status in [:complete, :partial] do
    {count_key, bytes_key, count_field, bytes_field} = Map.fetch!(@footprint, scan)

    with %{"insider" => %{^count_key => count, ^bytes_key => bytes} = insider} <- metrics,
         true <- is_integer(count) and is_integer(bytes),
         true <- Map.get(insider, "complete", true) do
      footprint = %{count_field => count, bytes_field => bytes}
      state = update_in(state, [:cycle, :footprint], &Map.merge(&1, footprint))
      {state, status, metrics, unavailable}
    else
      _incomplete -> {state, status, metrics, unavailable}
    end
  end

  defp annotate(state, :vm, status, metrics, unavailable) when status in [:complete, :partial] do
    missing =
      [
        {state.config.top_processes > 0, "insider_process_count", "insider_processes"},
        {state.config.top_ets_tables > 0, "insider_ets_tables", "insider_ets"}
      ]
      |> Enum.filter(fn {scanned, field, _group} ->
        scanned and not is_map_key(state.cycle.footprint, field)
      end)
      |> Enum.map(&elem(&1, 2))

    status = if missing == [], do: status, else: :partial
    {state, status, Map.merge(metrics, state.cycle.footprint), unavailable ++ missing}
  end

  defp annotate(state, {:watch, name, pid}, status, metrics, unavailable)
       when status in [:complete, :partial] do
    case metrics do
      %{"reductions_total" => reductions} when is_integer(reductions) ->
        delta =
          case state.watched do
            %{^name => {^pid, previous}} -> max(reductions - previous, 0)
            _first_or_restarted -> nil
          end

        state = put_in(state, [:watched, name], {pid, reductions})
        {state, status, Map.put(metrics, "reductions_delta", delta), unavailable}

      _other ->
        {state, status, metrics, unavailable}
    end
  end

  defp annotate(state, _probe, status, metrics, unavailable),
    do: {state, status, metrics, unavailable}

  defp record_event(state, probe, attributes) do
    sequence = state.sequence + 1
    observed = now_us()

    monotonic_time =
      if state.last_event_time, do: max(observed, state.last_event_time + 1), else: observed

    options = [
      id: event_id(state.config.source_instance_id, sequence),
      node: state.config.node,
      boot_id: state.config.boot_id,
      source: "poller",
      kind: kind(probe),
      severity: :debug,
      monotonic_time: monotonic_time,
      clock_id: state.config.clock_id,
      source_instance_id: state.config.source_instance_id,
      source_sequence: sequence,
      wall_time: DateTime.from_unix!(System.os_time(:microsecond), :microsecond),
      subject: subject(probe, state.config.node),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: attributes,
      payload: nil,
      authority: state.config.authority,
      redactions: [],
      extensions: %{}
    ]

    state = %{state | last_event_time: monotonic_time, sequence: sequence}

    case Event.new(options) do
      {:ok, event} -> record(state, event)
      {:error, _error} -> bump(state, :events_invalid)
    end
  rescue
    _error -> bump(state, :events_invalid)
  catch
    _kind, _reason -> bump(state, :events_invalid)
  end

  defp record(state, event) do
    case Recorder.record(state.config.recorder, event) do
      :ok -> bump(state, :events_recorded)
      {:dropped, _reason} -> bump(state, :recorder_dropped)
    end
  end

  defp finish_cycle(state) do
    state = state |> bump(:cycles_completed) |> Map.merge(%{cycle: nil, inflight: nil})

    case state.mode do
      :running -> schedule(state, state.config.interval_ms)
      :quiescing -> complete_quiescence(state)
      :quiesced -> state
    end
  end

  defp complete_quiescence(%{quiesce: %{from: from} = quiesce} = state) do
    cancel_timer(quiesce.timer)
    state = %{state | mode: :quiesced, quiesce: nil, timer: nil}
    GenServer.reply(from, {:ok, status_map(state)})
    state
  end

  defp complete_quiescence(state), do: %{state | mode: :quiesced, timer: nil}

  defp quarantine_inflight(%{inflight: nil} = state),
    do: %{state | mode: :quiesced, timer: nil}

  defp quarantine_inflight(%{inflight: %{phase: :quarantined} = inflight} = state) do
    cancel_timer(inflight.timeout_timer)
    cancel_timer(inflight.cleanup_timer)
    Process.exit(inflight.worker, :kill)

    state
  end

  defp quarantine_inflight(%{inflight: inflight} = state) do
    cancel_timer(inflight.timeout_timer)
    cancel_timer(inflight.cleanup_timer)
    Process.exit(inflight.worker, :kill)

    %{
      state
      | inflight: %{
          inflight
          | cleanup_timer: nil,
            cleanup_token: nil,
            phase: :awaiting_cleanup
        }
    }
  end

  defp schedule(state, delay_ms) do
    token = make_ref()
    timer = Process.send_after(self(), {:scheduled_poll, token}, delay_ms)
    %{state | timer: {timer, token}}
  end

  defp cancel_scheduled(%{timer: nil} = state), do: state

  defp cancel_scheduled(%{timer: {timer, _token}} = state) do
    cancel_timer(timer)
    %{state | timer: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp status_map(state) do
    state.stats
    |> Map.put(:cycle_active, not is_nil(state.cycle))
    |> Map.put(:probe_active, not is_nil(state.inflight))
    |> Map.put(:quiesced, state.mode == :quiesced)
    |> Map.put(:target_count, length(state.config.targets))
    |> Map.put(:watch_count, length(state.config.watch_names))
    |> Map.put(:timer_scheduled, not is_nil(state.timer))
  end

  defp protection(probe, _state) when probe in [:vm, :processes, :ets, :ports], do: :allowed

  defp protection(probe, state) do
    case ProtectedTargets.classify(state.config.protected_target_policy, probe_pid(probe)) do
      {:protected, evidence} -> {:protected, evidence}
      {:allowed, _evidence} -> :allowed
    end
  end

  defp probe_pid({:process, pid}), do: pid
  defp probe_pid({:watch, _name, pid}), do: pid

  defp kind(:vm), do: "vm_sample"
  defp kind(:cycle), do: "poll_cycle"
  defp kind(:processes), do: "process_top"
  defp kind(:ets), do: "ets_top"
  defp kind(:ports), do: "port_top"
  defp kind({:process, _pid}), do: "process_sample"
  defp kind({:watch, _name, _pid}), do: "process_watch"
  defp field_set(:vm), do: "otp_vm_scalar/v1"
  defp field_set(:cycle), do: "poll_cycle/v1"
  defp field_set(:processes), do: "otp_process_top/v1"
  defp field_set(:ets), do: "otp_ets_top/v1"
  defp field_set(:ports), do: "otp_port_top/v1"
  defp field_set({:process, _pid}), do: "otp_process_scalar/v1"
  defp field_set({:watch, _name, _pid}), do: "otp_process_watch/v1"

  defp subject({:process, pid}, node_name), do: process_subject(pid, node_name)

  defp subject({:watch, _name, pid}, node_name) when is_pid(pid),
    do: process_subject(pid, node_name)

  defp subject(_probe, _node), do: nil

  defp process_subject(pid, node_name),
    do: Subject.new!("process", pid |> :erlang.pid_to_list() |> to_string(), node_name)

  defp probe_counter(:complete), do: :probes_complete
  defp probe_counter(:partial), do: :probes_partial
  defp probe_counter(:timeout), do: :probes_timeout
  defp probe_counter(:protected), do: :probes_protected
  defp probe_counter(:exited), do: :probes_exited
  defp probe_counter(:failed), do: :probes_failed
  defp probe_counter(:not_registered), do: :probes_not_registered

  defp bump(state, counter), do: update_in(state, [:stats, counter], &(&1 + 1))
  defp add(state, counter, amount), do: update_in(state, [:stats, counter], &(&1 + amount))

  defp emit_truncation(state, skipped) do
    attributes = %{
      "cleanup" => "not_started",
      "cycle_id" => state.cycle.id,
      "field_set" => field_set(:cycle),
      "metrics" => %{"skipped_probes" => skipped},
      "observer_effect" => "none",
      "probe_status" => "truncated",
      "provider" => Atom.to_string(state.config.provider),
      "sample_duration_us" => 0,
      "timeout_cancellation" => "not_applicable",
      "unavailable" => ["cycle_deadline"]
    }

    record_event(state, :cycle, attributes)
  end

  defp event_id(source_instance_id, sequence) do
    digest = :crypto.hash(:sha256, source_instance_id <> ":" <> Integer.to_string(sequence))
    "poll-" <> Base.encode16(digest, case: :lower)
  end

  defp now_us, do: System.monotonic_time(:microsecond)
  defp elapsed(started_at_us), do: max(now_us() - started_at_us, 0)

  defp cleanup_delay(state) do
    remaining_us = max(state.cycle.deadline_us - now_us(), 1)
    min(state.config.cleanup_timeout_ms, max(div(remaining_us + 999, 1_000), 1))
  end

  # A process scan's snapshot is never recorded; it is bounded by the scan
  # limit instead of the byte bound its recorded metrics get.
  defp bounded_result(
         {:ok, status, metrics, unavailable,
          %{at_us: at_us, reductions: reductions, complete: complete}} = result,
         :processes
       )
       when is_integer(at_us) and is_map(reductions) and is_boolean(complete) do
    if map_size(reductions) <= Processes.max_scan() and
         Enum.all?(reductions, fn {pid, count} -> is_pid(pid) and is_integer(count) end) and
         bounded_data?({:ok, status, metrics, unavailable}, @scan_result_bytes),
       do: result,
       else: {:error, :failed}
  end

  # A port census's snapshot is bounded by the census's type limit.
  defp bounded_result(
         {:ok, status, metrics, unavailable,
          %{at_us: at_us, port_count: port_count, types: types}} = result,
         :ports
       )
       when is_integer(at_us) and is_integer(port_count) and is_map(types) do
    if map_size(types) <= Ports.max_types() and
         Enum.all?(types, fn {type, count} -> is_binary(type) and is_integer(count) end) and
         bounded_data?({:ok, status, metrics, unavailable}, @scan_result_bytes),
       do: result,
       else: {:error, :failed}
  end

  defp bounded_result(result, probe) when probe in [:processes, :ets, :ports],
    do: if(bounded_data?(result, @scan_result_bytes), do: result, else: {:error, :failed})

  defp bounded_result(result, _probe),
    do: if(bounded_data?(result, 4_096), do: result, else: {:error, :failed})

  defp bounded_data?(result, bytes) do
    Value.bounded_data?(result, bytes)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end
end
