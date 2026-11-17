defmodule Insider.Collector.Session do
  @moduledoc """
  Host-owned, opt-in composition of bounded development/test/CI collectors.

  This is not a transport, deployment, tracing, mutation, or production
  enablement API. Its opaque handle is a local ownership capability; callers
  must not serialize or forward it outside their trusted host boundary.

  See [Supervised collector sessions](docs/collectors.md#supervised-collector-sessions)
  for the collectors, bounds, and ownership rules.
  """

  use GenServer

  alias Insider.Collector.Admission
  alias Insider.Collector.Calls
  alias Insider.Collector.Calls.Tracing, as: CallsTracing
  alias Insider.Collector.IngressProfile
  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Otel
  alias Insider.Collector.Poller
  alias Insider.Collector.Session.Manager
  alias Insider.Collector.Session.StartupGuard
  alias Insider.Collector.Telemetry
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Policy.ProtectedTargets
  alias Insider.Recorder
  alias Insider.Recorder.Config, as: RecorderConfig
  alias Insider.Redaction
  alias Insider.Runtime.HostPolicy

  @components [:logger, :telemetry, :poller, :otel, :calls]
  @maximum_history 32
  @maximum_mailbox 256
  @cleanup_timeout_ms 200
  @component_status_timeout_ms 100
  @maximum_evidence_timeout_ms 5_000
  @evidence_reply_reserve_ms 5

  @type receipt :: map()

  @spec start(HostPolicy.t(), keyword()) ::
          {:ok, Insider.Collector.Session.Handle.t()} | {:error, term()}
  def start(%HostPolicy{} = host_policy, options), do: Manager.start(host_policy, options)
  def start(_host_policy, _options), do: {:error, :invalid_options}

  @spec health(Insider.Collector.Session.Handle.t()) :: {:ok, map()} | {:error, term()}
  def health(handle), do: Manager.health(handle)

  @doc """
  Flushes bounded collector inboxes and returns fixed-schema scalar accounting.

  The result excludes event bodies, payloads, process handles, and raw status
  maps. A successful call permanently quiesces the session Poller before
  draining currently visible Logger and Telemetry inbox entries and sampling
  Recorder counters. Empty visible inboxes do not prove that concurrent
  application emitters stopped; terminal cleanup still requires `stop/1` or
  `kill/1`.
  """
  @spec flush_evidence(Insider.Collector.Session.Handle.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def flush_evidence(handle, timeout_ms \\ @maximum_evidence_timeout_ms),
    do: Manager.flush_evidence(handle, timeout_ms)

  @doc """
  Drains the bounded Logger and Telemetry inboxes and returns scalar ingress accounting.

  This is a nonterminal workload-boundary operation. It does not inspect or
  quiesce the Poller, does not inspect the Recorder, and cannot prove that
  external emitters have paused.
  """
  @spec flush_ingress_evidence(Insider.Collector.Session.Handle.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def flush_ingress_evidence(handle, timeout_ms \\ @maximum_evidence_timeout_ms),
    do: Manager.flush_ingress_evidence(handle, timeout_ms)

  @doc """
  Stops the session's ingress for good and keeps its Recorder readable.

  The Poller stops, the Telemetry handler is detached before its inbox is
  drained, and the Logger filter is removed before its inbox is drained,
  so after the reply nothing more is recorded and every event that was
  admitted is in the Recorder. `read_events/3` keeps working; `stop/1` or
  `kill/1` still ends the session, and its receipt reports each component's
  cleanup as it was at the seal. The live owner seals a session before it
  copies it for the last time, so no recorded event is lost to a stop.
  """
  @spec seal_ingress(Insider.Collector.Session.Handle.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def seal_ingress(handle, timeout_ms \\ @maximum_evidence_timeout_ms),
    do: Manager.seal_ingress(handle, timeout_ms)

  @doc """
  Records one event that a caller outside the collectors built, such as a
  live one-shot inspection, into the running session's Recorder.

  The session process records it, so it is serialised with the seal: after
  `seal_ingress/2` it is refused with `:sealed`. Returns `:ok`, the
  Recorder's `{:dropped, reason}`, or `{:error, reason}`.
  """
  @spec record_event(Insider.Collector.Session.Handle.t(), Insider.Event.t(), pos_integer()) ::
          :ok | {:dropped, atom()} | {:error, term()}
  def record_event(handle, event, timeout_ms \\ @maximum_evidence_timeout_ms),
    do: Manager.record_event(handle, event, timeout_ms)

  @doc """
  Reads redacted recorder events after `cursor`, without a freeze trigger.

  The call first drains the visible Logger and Telemetry inboxes, then reads
  the session Recorder with `Insider.Recorder.read_since/3` and passes every
  returned event through `Insider.Redaction` under the session's trusted
  recorder classification policy. An event whose redaction fails is withheld
  and counted in `"redaction_withheld"` (its receipt is listed in
  `"withheld_receipts"`); its receipt still advances the cursor. Cursor
  `:latest` is the newest receipt after the drain, so the read returns no
  events and `"cursor"` reports where it started.

  The result also carries cumulative scalar loss accounting: exact receipt
  eviction for the read range, Recorder admission counters, and the Logger,
  Telemetry, and Poller ingress counters, so callers can report every gap.
  Options: `:limit` (1..1,000), `:max_bytes` (1..16 MiB), and `:timeout_ms`
  (1..5,000, default 5,000). A redaction deadline truncates the batch.
  `"truncated_by"` names what ended a truncated read: `"limit"`,
  `"max_bytes"`, or `"deadline"` (otherwise `nil`).
  """
  @spec read_events(
          Insider.Collector.Session.Handle.t(),
          non_neg_integer() | :latest,
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def read_events(handle, cursor, options \\ []),
    do: Manager.read_events(handle, cursor, options)

  @spec stop(Insider.Collector.Session.Handle.t()) :: {:ok, receipt()} | {:error, term()}
  def stop(handle), do: Manager.stop(handle)

  @spec kill(Insider.Collector.Session.Handle.t()) :: {:ok, receipt()} | {:error, term()}
  def kill(handle), do: Manager.kill(handle)

  @doc false
  @spec prepare(pid(), term(), term()) ::
          {:ok, map()} | {:error, :invalid_options | :environment_denied}
  def prepare(owner, %HostPolicy{} = host_policy, options)
      when is_pid(owner) and is_list(options) do
    with true <- HostPolicy.valid?(host_policy),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- keys == Enum.uniq(keys),
         true <- keys -- allowed_keys() == [],
         true <- Enum.all?(required_keys(), &(&1 in keys)),
         id when is_binary(id) and byte_size(id) in 1..64 <- Keyword.fetch!(options, :id),
         true <- String.valid?(id),
         environment <- Keyword.fetch!(options, :environment),
         {:ok, profile} <- IngressProfile.new(environment),
         :enabled <- if(profile.observation_enabled, do: :enabled, else: :environment_denied),
         recorder_options <- Keyword.fetch!(options, :recorder_options),
         {:ok, _recorder_config} <- RecorderConfig.new(recorder_options),
         components <- Keyword.get(options, :components, [:logger]),
         true <- valid_components?(components),
         true <- telemetry_valid?(components, options),
         true <- common_values?(options),
         true <- nested_options?(options) do
      {:ok,
       %{
         authority: :binary.copy(Keyword.fetch!(options, :authority)),
         boot_id: :binary.copy(Keyword.fetch!(options, :boot_id)),
         components: components,
         calls_options: Keyword.get(options, :calls_options, []),
         environment: environment,
         host_policy: host_policy,
         id: :binary.copy(id),
         logger_options: Keyword.get(options, :logger_options, []),
         otel_options: Keyword.get(options, :otel_options, []),
         owner: owner,
         poller_options: Keyword.get(options, :poller_options, []),
         recorder_options: Keyword.fetch!(options, :recorder_options),
         telemetry_options: Keyword.get(options, :telemetry_options, []),
         telemetry_policy: Keyword.get(options, :telemetry_policy),
         clock_id: :binary.copy(Keyword.fetch!(options, :clock_id))
       }}
    else
      :environment_denied -> {:error, :environment_denied}
      false -> {:error, :invalid_options}
      {:error, :invalid_profile} -> {:error, :invalid_options}
      {:error, :invalid_options} -> {:error, :invalid_options}
      _other -> {:error, :environment_denied}
    end
  rescue
    _error -> {:error, :invalid_options}
  end

  def prepare(_owner, _host_policy, _options), do: {:error, :invalid_options}

  @doc false
  @spec start_link({pid(), map(), reference(), String.t()}) :: GenServer.on_start()
  def start_link({manager, config, token, incarnation}) do
    GenServer.start_link(__MODULE__, {manager, config, token, incarnation})
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arguments) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [arguments]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec health(pid(), Admission.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def health(pid, admission, timeout), do: admitted_call(pid, admission, :health, timeout)

  @doc false
  @spec flush_evidence(pid(), Admission.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def flush_evidence(pid, admission, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@maximum_evidence_timeout_ms do
    deadline =
      System.monotonic_time(:millisecond) + max(timeout_ms - @evidence_reply_reserve_ms, 0)

    admitted_evidence_call(pid, admission, {:flush_evidence, deadline}, timeout_ms)
  end

  def flush_evidence(_pid, _admission, _timeout_ms), do: {:error, :invalid_options}

  @doc false
  @spec flush_ingress_evidence(pid(), Admission.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def flush_ingress_evidence(pid, admission, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@maximum_evidence_timeout_ms do
    deadline =
      System.monotonic_time(:millisecond) + max(timeout_ms - @evidence_reply_reserve_ms, 0)

    admitted_evidence_call(pid, admission, {:flush_ingress_evidence, deadline}, timeout_ms)
  end

  def flush_ingress_evidence(_pid, _admission, _timeout_ms), do: {:error, :invalid_options}

  @doc false
  @spec seal_ingress(pid(), Admission.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def seal_ingress(pid, admission, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@maximum_evidence_timeout_ms,
      do: admitted_evidence_call(pid, admission, :seal_ingress, timeout_ms)

  def seal_ingress(_pid, _admission, _timeout_ms), do: {:error, :invalid_options}

  @doc false
  @spec record_event(pid(), Admission.t(), term(), pos_integer()) ::
          :ok | {:dropped, atom()} | {:error, term()}
  def record_event(pid, admission, %Insider.Event{} = event, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@maximum_evidence_timeout_ms do
    deadline =
      System.monotonic_time(:millisecond) + max(timeout_ms - @evidence_reply_reserve_ms, 0)

    case admitted_evidence_call(pid, admission, {:record_event, event, deadline}, timeout_ms) do
      # The caller gave up waiting; the session may have been writing.
      {:error, :request_expired} -> {:error, :outcome_unknown}
      reply -> reply
    end
  end

  def record_event(_pid, _admission, _event, _timeout_ms), do: {:error, :invalid_options}

  # `finalize` makes the Telemetry collector record its pending summary
  # intervals before the read, for a final read before the session ends.
  # Cursor `:latest` is the newest receipt once the inboxes are drained.
  @doc false
  @spec read_events(
          pid(),
          Admission.t(),
          {integer() | :latest, pos_integer(), pos_integer(), boolean()},
          pos_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def read_events(pid, admission, {cursor, limit, max_bytes, finalize}, timeout_ms)
      when is_boolean(finalize) and is_integer(timeout_ms) and
             timeout_ms in 1..@maximum_evidence_timeout_ms do
    deadline =
      System.monotonic_time(:millisecond) + max(timeout_ms - @evidence_reply_reserve_ms, 0)

    admitted_evidence_call(
      pid,
      admission,
      {:read_events, deadline, cursor, limit, max_bytes, finalize},
      timeout_ms
    )
  end

  def read_events(_pid, _admission, _read, _timeout_ms), do: {:error, :invalid_options}

  @doc false
  @spec terminate(pid(), Admission.t(), :stop | :kill, timeout()) ::
          {:ok, receipt()} | {:error, term()}
  def terminate(pid, admission, action, timeout) when action in [:stop, :kill],
    do: admitted_call(pid, admission, {:terminate, action}, timeout)

  @doc false
  @spec terminal_health(receipt()) :: map()
  def terminal_health(receipt) do
    %{
      "schema" => "insider.collector-session-health/v1",
      "state" => receipt["outcome"],
      "terminal" => true,
      "receipt_id" => receipt["id"],
      "history_count" => receipt["history_count"]
    }
  end

  @doc false
  @spec ownership(pid(), Admission.t(), timeout()) :: {:ok, map()} | {:error, :unavailable}
  def ownership(pid, admission, timeout), do: admitted_call(pid, admission, :ownership, timeout)

  @doc false
  @spec manager_ownership_released(receipt()) :: receipt()
  def manager_ownership_released(receipt) do
    cleanup = Map.put(receipt["cleanup"], "manager_ownership", "absent")
    body = receipt |> Map.drop(["id"]) |> Map.put("cleanup", cleanup)
    Map.put(body, "id", "sha256:" <> Insider.Event.Canonical.sha256(body))
  end

  @doc false
  @spec startup_failure_receipt(String.t(), String.t(), term()) :: receipt()
  def startup_failure_receipt(id, incarnation, reason),
    do: receipt(id, incarnation, "startup_failed", %{"startup" => classify_reason(reason)}, 0)

  @doc false
  # A start that ran past its budget: the Manager's wait ended, or the
  # session cancelled its own startup (`:startup_cancelled`) because its
  # authorization had expired. Both are a timeout, with the start's budget
  # and the time it took.
  @spec start_timeout_receipt(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          receipt()
  def start_timeout_receipt(id, incarnation, budget_ms, elapsed_ms) do
    cleanup = %{
      "startup" => "timeout",
      "start_budget_ms" => budget_ms,
      "start_elapsed_ms" => elapsed_ms
    }

    receipt(id, incarnation, "startup_failed", cleanup, 0)
  end

  @doc false
  @spec unexpected_receipt(map(), term(), :absent | :residual | :unavailable) :: receipt()
  def unexpected_receipt(active, reason, manager_child) do
    receipt(
      active.id,
      active.incarnation,
      "cleanup_incomplete",
      %{
        "manager_child" => Atom.to_string(manager_child),
        "session_exit" => classify_reason(reason),
        "verification" => "unavailable_or_incomplete"
      },
      0
    )
  end

  @doc false
  @spec forced_cleanup_receipt(map(), map()) :: receipt()
  def forced_cleanup_receipt(active, cleanup) when is_map(active) and is_map(cleanup),
    do: receipt(active.id, active.incarnation, "cleanup_incomplete", cleanup, 0)

  @doc false
  @spec startup_cleanup_receipt(map(), map()) :: receipt()
  def startup_cleanup_receipt(active, cleanup) when is_map(active) and is_map(cleanup),
    do:
      receipt(
        active.id,
        active.incarnation,
        "startup_failed",
        Map.put(cleanup, "startup", "inventory_unavailable"),
        0
      )

  @impl GenServer
  def init({manager, config, token, incarnation}) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    if startup_authorized?(Map.get(config, :startup_guard), token) do
      owner_monitor = Process.monitor(config.owner)

      state = %{
        admission: Map.fetch!(config, :session_admission),
        components: %{},
        config: config,
        history: [%{"component" => "session", "event" => "started", "reason" => "none"}],
        incarnation: incarnation,
        manager: manager,
        mode: :starting,
        monitors: %{owner_monitor => :owner},
        owner_monitor: owner_monitor,
        recorder_handle: nil,
        sealed: %{},
        sealed_evidence: %{},
        call_trace: nil,
        call_trace_removal: nil,
        token: token
      }

      case start_components(state) do
        {:ok, state} ->
          {:ok, %{state | mode: :running}}

        {:error, reason, state} ->
          _cleanup = cleanup(state)
          {:stop, reason}
      end
    else
      {:stop, :startup_cancelled}
    end
  end

  @impl GenServer
  def handle_call({:admitted, admission, :health}, _from, %{admission: admission} = state) do
    release_admission(state.admission)
    {:reply, {:ok, health_map(state)}, state}
  end

  def handle_call({:admitted, admission, :ownership}, _from, %{admission: admission} = state) do
    release_admission(state.admission)

    {:reply,
     {:ok,
      %{
        components: state.components,
        telemetry_policy: state.config.telemetry_policy
      }}, state}
  end

  def handle_call(
        {:admitted, admission, {:flush_evidence, deadline}},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) do
    release_admission(state.admission)
    {:reply, evidence_reply(state, deadline), state}
  end

  def handle_call(
        {:admitted, admission, {:flush_ingress_evidence, deadline}},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) do
    release_admission(state.admission)
    {:reply, ingress_evidence_reply(state, deadline), state}
  end

  def handle_call({:admitted, admission, :seal_ingress}, _from, %{admission: admission} = state) do
    release_admission(state.admission)
    {reply, state} = seal(state)
    {:reply, reply, state}
  end

  # An event built outside the collectors is recorded here, so it never
  # lands after the seal. A request that arrives at or after its deadline
  # is refused before the Recorder is called. One admitted before its
  # deadline may still complete after it (it can wait for the Recorder's
  # admission lock); its caller, having stopped waiting, reports the outcome
  # as unknown, never as not recorded.
  def handle_call(
        {:admitted, admission, {:record_event, event, deadline}},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) do
    release_admission(state.admission)

    reply =
      cond do
        System.monotonic_time(:millisecond) >= deadline -> {:error, :request_expired}
        state.mode != :running or map_size(state.sealed) > 0 -> {:error, :sealed}
        state.recorder_handle == nil -> {:error, :unavailable}
        true -> Recorder.record(state.recorder_handle, event)
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:admitted, admission, {:read_events, deadline, cursor, limit, max_bytes, finalize}},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) do
    release_admission(state.admission)
    reply = events_reply(state, deadline, cursor, limit, max_bytes, finalize)
    {:reply, reply, state, {:continue, :collect}}
  end

  def handle_call(
        {:admitted, admission, {:terminate, action}},
        _from,
        %{admission: admission} = state
      )
      when action in [:stop, :kill] do
    release_admission(state.admission)
    outcome = if action == :kill, do: "killed", else: "stopped"
    {cleanup, state} = cleanup(%{state | mode: :stopping})
    outcome = if clean?(cleanup), do: outcome, else: "cleanup_incomplete"
    receipt = receipt(state.config.id, state.incarnation, outcome, cleanup, length(state.history))
    send(state.manager, {:session_terminal, self(), state.token, receipt})
    {:stop, :normal, {:ok, receipt}, state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :invalid_request}, state}

  # A read decodes and redacts a page of entries; once it is replied they are
  # garbage, so they are collected at once instead of keeping the heap they
  # grew until a later collection.
  @impl GenServer
  def handle_continue(:collect, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    finish(state, "stopped", "owner_down")
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {component, monitors} ->
        _ = component
        _ = pid
        _ = reason
        finish(%{state | monitors: monitors}, "cleanup_incomplete", "component_down")
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case component_for_pid(state.components, pid) do
      nil ->
        {:noreply, state}

      component ->
        _ = component
        _ = pid
        _ = reason
        finish(state, "cleanup_incomplete", "component_down")
    end
  end

  def handle_info(_message, state) do
    if mailbox_overloaded?() do
      finish(
        add_history(state, "session", "mailbox_overload", "bounded_shutdown"),
        "cleanup_incomplete",
        "mailbox_overload"
      )
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    if state.mode not in [:stopping] do
      {cleanup, _state} = cleanup(state)

      receipt =
        receipt(
          state.config.id,
          state.incarnation,
          "cleanup_incomplete",
          cleanup,
          length(state.history)
        )

      send(state.manager, {:session_terminal, self(), state.token, receipt})
    end

    _ = reason
    :ok
  end

  defp start_components(state) do
    # Carry the current ownership inventory through every stage. In
    # particular, `with`'s local bindings are not available to its `else`
    # branch, which would make a late failure forget a recorder or prior
    # collector during rollback.
    if startup_authorized_state?(state) do
      case Recorder.start_link(state.config.recorder_options) do
        {:ok, recorder} ->
          {:ok, state} = add_component(state, :recorder, recorder)
          start_recorder_stage(state, recorder)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_recorder_stage(state, recorder) do
    if startup_authorized_state?(state) do
      case Recorder.handle(recorder) do
        {:ok, recorder_handle} ->
          start_logger_stage(
            %{state | recorder_handle: recorder_handle},
            recorder,
            recorder_handle
          )

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_logger_stage(state, recorder, recorder_handle) do
    if startup_authorized_state?(state) do
      case maybe_start_logger(state, recorder_handle) do
        {:ok, state} ->
          if startup_authorized_state?(state),
            do: start_telemetry_stage(state, recorder, recorder_handle),
            else: {:error, :startup_cancelled, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_telemetry_stage(state, recorder, recorder_handle) do
    if startup_authorized_state?(state) do
      case maybe_start_telemetry(state, recorder_handle) do
        {:ok, state} ->
          if startup_authorized_state?(state),
            do: start_otel_stage(state, recorder, recorder_handle),
            else: {:error, :startup_cancelled, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_otel_stage(state, recorder, recorder_handle) do
    if startup_authorized_state?(state) do
      case maybe_start_otel(state, recorder_handle) do
        {:ok, state} ->
          if startup_authorized_state?(state),
            do: start_calls_stage(state, recorder, recorder_handle),
            else: {:error, :startup_cancelled, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_calls_stage(state, recorder, recorder_handle) do
    if startup_authorized_state?(state) do
      case maybe_start_calls(state, recorder_handle) do
        {:ok, state} ->
          if startup_authorized_state?(state),
            do: start_poller_stage(state, recorder, recorder_handle),
            else: {:error, :startup_cancelled, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp start_poller_stage(state, recorder, recorder_handle) do
    if startup_authorized_state?(state) do
      case ProtectedTargets.bind_session(
             state.config.host_policy.protected_targets,
             self(),
             recorder,
             Map.values(state.components)
           ) do
        {:ok, policy} ->
          case maybe_start_poller(state, recorder_handle, policy) do
            {:ok, state} ->
              if startup_authorized_state?(state),
                do: {:ok, state},
                else: {:error, :startup_cancelled, state}

            {:error, reason} ->
              {:error, reason, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :startup_cancelled, state}
    end
  end

  defp startup_authorized_state?(state) do
    startup_authorized?(Map.get(state.config, :startup_guard), state.token)
  end

  defp maybe_start_logger(state, handle) do
    if :logger in state.config.components do
      options =
        common_options(state) ++ [handler_id: :insider_logger] ++ state.config.logger_options

      with {:ok, pid} <- LoggerCollector.start_link(handle, options),
           {:ok, state} <- add_component(state, :logger, pid),
           do: {:ok, state}
    else
      {:ok, state}
    end
  end

  defp maybe_start_telemetry(state, handle) do
    if :telemetry in state.config.components do
      options =
        common_options(state) ++
          [handler_id: "insider-session-telemetry"] ++ state.config.telemetry_options

      with {:ok, pid} <- Telemetry.start_link(handle, state.config.telemetry_policy, options),
           {:ok, state} <- add_component(state, :telemetry, pid),
           do: {:ok, state}
    else
      {:ok, state}
    end
  end

  defp maybe_start_otel(state, handle) do
    if :otel in state.config.components do
      options = common_options(state) ++ state.config.otel_options

      with {:ok, pid} <- Otel.start_link(handle, options),
           {:ok, state} <- add_component(state, :otel, pid),
           do: {:ok, state}
    else
      {:ok, state}
    end
  end

  # The trace's inventory (its session's weak reference and functions) is
  # kept here, so cleanup can check the trace is gone without asking the
  # collector that set it.
  defp maybe_start_calls(state, handle) do
    if :calls in state.config.components do
      options = common_options(state) ++ state.config.calls_options

      with {:ok, pid} <- Calls.start_link(handle, options),
           {:ok, state} <- add_component(state, :calls, pid),
           {:ok, inventory} <- Calls.inventory(pid),
           do: {:ok, %{state | call_trace: inventory}}
    else
      {:ok, state}
    end
  end

  defp maybe_start_poller(state, handle, policy) do
    if :poller in state.config.components do
      options =
        poller_common_options(state) ++
          [protected_target_policy: policy] ++ state.config.poller_options

      with {:ok, pid} <- Poller.start_link(handle, options),
           {:ok, state} <- add_component(state, :poller, pid),
           do: {:ok, state}
    else
      {:ok, state}
    end
  end

  defp add_component(state, component, pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    {:ok,
     %{
       state
       | components: Map.put(state.components, component, pid),
         monitors: Map.put(state.monitors, monitor, component),
         history: add_history(state, Atom.to_string(component), "started", "none").history
     }}
  end

  defp common_options(state) do
    [
      authority: state.config.authority,
      boot_id: state.config.boot_id,
      clock_id: state.config.clock_id,
      environment: state.config.environment
    ]
  end

  defp poller_common_options(state) do
    [
      authority: state.config.authority,
      boot_id: state.config.boot_id,
      clock_id: state.config.clock_id
    ]
  end

  # Stops the ingress components as cleanup does, in the same order, and
  # keeps the Recorder. Each component's monitor is dropped first, so its
  # exit is not a component failure. The call trace is removed first; the
  # Poller reports its status, then stops; the otel collector removes its
  # capture, then drains the spans that ended before; Telemetry detaches,
  # drains, and records its pending summary intervals; the Logger removes
  # its filter, then drains. Each one's final status is kept as its evidence
  # for later reads, so losses counted up to the seal stay reported; a
  # component whose final status could not be read reports its accounting
  # as unavailable. A second seal stops nothing.
  defp seal(state) do
    state = seal_components(state, [:calls, :poller, :otel, :telemetry, :logger])

    {{:ok,
      %{
        "schema" => "insider.collector-session-seal/v1",
        "session_id" => state.config.id,
        "components" => state.sealed
      }}, state}
  end

  defp seal_components(state, components) do
    {results, state} =
      Enum.reduce(components, {%{}, state}, fn component, {results, state} ->
        case Map.fetch(state.components, component) do
          {:ok, pid} ->
            monitors = :maps.filter(fn _monitor, owner -> owner != component end, state.monitors)

            for {monitor, ^component} <- state.monitors,
                do: Process.demonitor(monitor, [:flush])

            {result, evidence, state} = seal_component(component, pid, state)

            {Map.put(results, Atom.to_string(component), result),
             %{
               state
               | components: Map.delete(state.components, component),
                 monitors: monitors,
                 sealed_evidence: Map.put(state.sealed_evidence, component, evidence)
             }}

          :error ->
            {results, state}
        end
      end)

    %{state | sealed: Map.merge(results, state.sealed)}
  end

  # The trace's removal observation is kept for the cleanup receipt.
  defp seal_component(:calls, pid, state) do
    case Calls.stop(pid) do
      {:ok, %{status: status, trace: removal}} ->
        result = if removal["traced_after"] == 0, do: "absent", else: "residual"

        {result, sealed_evidence(:calls, {:ok, status}), %{state | call_trace_removal: removal}}

      _other ->
        {terminate_pid(pid), sealed_evidence(:calls, :unavailable), state}
    end
  end

  defp seal_component(component, pid, state) do
    {result, evidence} = seal_component(component, pid)
    {result, evidence, state}
  end

  defp seal_component(:poller, pid) do
    status = Poller.status(pid)
    {result, _components} = stop_component(:poller, pid, %{poller: pid})
    {result, sealed_evidence(:poller, status)}
  end

  # A seal whose drain could not count every waiting span leaves the
  # component's accounting unavailable, which reads report as a gap.
  defp seal_component(:otel, pid) do
    case Otel.stop(pid) do
      {:ok, %{trace: trace, status: %{drain_incomplete: 1}}} ->
        result =
          if trace in ["removed", "already_removed", "not_installed"],
            do: "absent",
            else: "residual"

        {result, sealed_evidence(:otel, :unavailable)}

      {:ok, %{trace: trace, status: status}} ->
        result =
          if trace in ["removed", "already_removed", "not_installed"],
            do: "absent",
            else: "residual"

        {result, sealed_evidence(:otel, {:ok, status})}

      _other ->
        {terminate_pid(pid), sealed_evidence(:otel, :unavailable)}
    end
  end

  defp seal_component(:telemetry, pid) do
    case Telemetry.seal(pid) do
      {:ok, %{handler: handler, status: status}} ->
        result = if handler in [:removed, :already_detached], do: "absent", else: "residual"
        {result, sealed_evidence(:telemetry, {:ok, status})}

      _other ->
        {terminate_pid(pid), sealed_evidence(:telemetry, :unavailable)}
    end
  end

  defp seal_component(:logger, pid) do
    case LoggerCollector.stop(pid) do
      {:ok, status} -> {"absent", sealed_evidence(:logger, {:ok, status})}
      _other -> {terminate_pid(pid), sealed_evidence(:logger, :unavailable)}
    end
  end

  defp sealed_evidence(component, {:ok, status}) do
    case project_component_status(component, status) do
      {:ok, evidence} ->
        Map.merge(%{"configured" => true, "evidence" => "bounded_status"}, evidence)

      _malformed ->
        sealed_evidence(component, :unavailable)
    end
  end

  defp sealed_evidence(_component, _unavailable),
    do: %{"configured" => true, "evidence" => "malformed_or_unavailable"}

  # A component already stopped by `seal/1` keeps the result of that stop.
  # The call trace is removed first, as a seal would, so its removal is
  # observed; a configured trace that never started reports `not_started`.
  defp cleanup(state) do
    state = seal_components(state, [:calls])

    # The otel component appears in the inventory only when configured, so
    # the receipts of sessions without it keep their shape.
    {results, components} =
      [:poller, :otel, :telemetry, :logger, :recorder]
      |> Enum.filter(&(&1 != :otel or :otel in state.config.components))
      |> Enum.reduce({%{}, state.components}, fn component, {results, components} ->
        pid = Map.get(components, component)
        {result, components} = stop_component(component, pid, components)
        {Map.put(results, Atom.to_string(component), result), components}
      end)

    results =
      if :calls in state.config.components,
        do: Map.merge(%{"calls" => "not_started"}, results),
        else: results

    results = Map.merge(results, Map.get(state, :sealed, %{}))

    monitors =
      state.monitors
      |> Map.keys()
      |> Enum.map(fn monitor -> Process.demonitor(monitor, [:flush]) end)

    inventory = %{
      "components" => results,
      "logger_filter" => logger_filter_absence(),
      "manager_ownership" => "pending_manager_removal",
      "monitors" =>
        if(Enum.all?(monitors, &(&1 in [true, false])), do: "dropped", else: "unavailable"),
      "policy_reference" => "dropped",
      "recorder_ets" => recorder_tables_absence(Map.get(state.components, :recorder)),
      "session_timers" => "none_owned",
      "telemetry_handler" => telemetry_handler_absence(state.config.telemetry_policy)
    }

    # Only a session with the calls component has the key, so the receipts
    # of other sessions keep their shape.
    inventory =
      if :calls in state.config.components,
        do: Map.put(inventory, "call_trace", call_trace_absence(state)),
        else: inventory

    {inventory, %{state | components: components, monitors: %{}, recorder_handle: nil}}
  end

  # The proof that the call trace is gone: the collector's own removal, and
  # this session's independent check of the runtime's session inventory for
  # the trace session and each traced function (`traced_after` counts the
  # functions still traced by it, `nil` if the runtime could not answer).
  defp call_trace_absence(%{call_trace: nil}),
    do: %{"session" => "not_started", "functions" => [], "traced_after" => 0}

  defp call_trace_absence(%{call_trace: %{weak: weak, functions: functions}} = state) do
    removal = state.call_trace_removal || %{"session" => "collector_exited"}

    %{
      "session" => removal["session"],
      "functions" => Enum.map(functions, &mfa_text/1),
      "traced_after" => CallsTracing.traced_after(weak, functions)
    }
  end

  defp mfa_text({module, function, arity}),
    do: "#{inspect(module)}.#{function}/#{arity}"

  @logger_evidence_fields [
    :received,
    :enqueued,
    :shed,
    :invalid,
    :recorded,
    :recorder_dropped,
    :payload_suppressed,
    :message_semantics_suppressed,
    :metadata_suppressed,
    :exemplars_shed,
    :exemplars_invalid,
    :exemplars_late,
    :exemplars_unrecorded,
    :inbox_count,
    :inbox_capacity
  ]
  @otel_evidence_fields [
    :received,
    :recorded,
    :recorder_dropped,
    :invalid,
    :shed,
    :ingested,
    :duplicate,
    :seen_evicted,
    :abandoned,
    :drain_incomplete,
    :pauses,
    :paused,
    :pending,
    :max_waiting,
    :installed,
    :sdk_running
  ]
  @calls_evidence_fields [
    :received,
    :recorded,
    :recorder_dropped,
    :invalid,
    :shed,
    :undrained,
    :undrained_unknown,
    :inlet_pending,
    :calls,
    :open,
    :stopped,
    :pending,
    :max_waiting,
    :functions,
    :traced
  ]
  @telemetry_evidence_fields [
    :received,
    :enqueued,
    :shed,
    :invalid,
    :recorded,
    :recorder_dropped,
    :handler_failures,
    :measurements_suppressed,
    :metadata_suppressed,
    :omissions_unrecorded,
    :exemplars_shed,
    :exemplars_invalid,
    :exemplars_late,
    :exemplars_unrecorded,
    :inbox_count,
    :inbox_capacity,
    :lifecycle_started,
    :lifecycle_completed,
    :lifecycle_duplicate_starts,
    :lifecycle_expired,
    :lifecycle_missing_correlation,
    :lifecycle_missing_starts,
    :lifecycle_missing_terminals,
    :lifecycle_tracking_shed,
    :lifecycle_terminals,
    :unmatched_completions,
    :open_lifecycles
  ]
  @poller_integer_fields [
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
    :cleanup_uncertain,
    :target_count,
    :watch_count
  ]
  @poller_boolean_fields [:cycle_active, :probe_active, :quiesced, :timer_scheduled]
  @recorder_integer_fields [
    :next_receipt,
    :retained_count,
    :retained_bytes,
    :retained_classification_bytes,
    :storage_bytes,
    :index_entries,
    :rate_keys
  ]
  @recorder_counter_fields [
    :offered,
    :accepted,
    :evicted,
    :duplicate,
    :freeze_idempotent,
    :already_frozen,
    :recovered_owner_death,
    :invalid_event,
    :classification_failed,
    :contended,
    :rate_limited,
    :rate_key_capacity,
    :oversized,
    :frozen,
    :event_id_conflict,
    :priority_protected,
    :eviction_limit,
    :unavailable,
    :internal_error
  ]

  defp evidence_reply(state, deadline) do
    with {:ok, poller} <- quiesce_poller(state, deadline),
         {:ok, logger} <- evidence_component(state, :logger, :flush, deadline),
         {:ok, telemetry} <- evidence_component(state, :telemetry, :flush, deadline),
         {:ok, recorder} <- recorder_evidence(state.recorder_handle, deadline) do
      {:ok,
       %{
         "schema" => "insider.collector-session-evidence/v1",
         "session_id" => state.config.id,
         "state" => Atom.to_string(state.mode),
         "logger" => logger,
         "telemetry" => telemetry,
         "poller" => poller,
         "recorder" => recorder,
         "visible_inboxes_empty" => visible_inboxes_empty?(logger, telemetry),
         "poller_idle" => poller_idle?(poller),
         "producer_quiescence" => "poller_proven_external_emitters_not_proven",
         "external_emitter_quiescence" => "not_proven",
         "event_content_included" => false,
         "cleanup_evidence" => "terminal_receipt_required"
       }}
    end
  end

  defp ingress_evidence_reply(state, deadline) do
    with {:ok, logger} <- evidence_component(state, :logger, :flush, deadline),
         {:ok, telemetry} <- evidence_component(state, :telemetry, :flush, deadline) do
      {:ok,
       %{
         "schema" => "insider.collector-session-ingress-evidence/v1",
         "session_id" => state.config.id,
         "state" => Atom.to_string(state.mode),
         "logger" => logger,
         "telemetry" => telemetry,
         "visible_inboxes_empty" => visible_inboxes_empty?(logger, telemetry),
         "external_emitter_quiescence" => "not_proven",
         "poller_quiescence" => "not_requested",
         "event_content_included" => false
       }}
    end
  end

  # A final read records the pending summary intervals of both collectors.
  defp events_reply(state, deadline, cursor, limit, max_bytes, finalize) do
    request = if finalize, do: :finalize, else: :flush

    with {:ok, logger} <- evidence_component(state, :logger, request, deadline),
         {:ok, telemetry} <- evidence_component(state, :telemetry, request, deadline),
         {:ok, otel} <- evidence_component(state, :otel, :flush, deadline),
         {:ok, poller} <- evidence_component(state, :poller, :status, deadline),
         {:ok, calls} <- evidence_component(state, :calls, :flush, deadline),
         {:ok, _timeout} <- remaining_evidence_timeout(deadline),
         {:ok, read} <- read_recorder(state.recorder_handle, cursor, limit, max_bytes),
         {:ok, counters} <- project_integer_status(read.counters, @recorder_counter_fields) do
      {_sensitivity, policy} = Keyword.fetch!(state.config.recorder_options, :classification)
      redacted = redact_entries(read, policy, deadline)

      {:ok,
       %{
         "schema" => "insider.collector-session-events/v1",
         "session_id" => state.config.id,
         "state" => Atom.to_string(state.mode),
         "cursor" => read.cursor,
         "next_cursor" => redacted.next_cursor,
         "next_receipt" => read.next_receipt,
         "truncated" => redacted.truncated,
         "truncated_by" => redacted.truncated_by,
         "events" => Enum.reverse(redacted.events),
         "evicted" => redacted.next_cursor - read.cursor - redacted.processed,
         "redaction_withheld" => redacted.withheld,
         "withheld_receipts" => Enum.reverse(redacted.withheld_receipts),
         "recorder_counters" => counters,
         # Each share group's usage and evictions, read lock-free.
         "recorder_sources" => (recorder_fill(state.recorder_handle) || %{})["sources"],
         "logger" => logger,
         "telemetry" => telemetry,
         "otel" => otel,
         "poller" => poller,
         "calls" => calls,
         "external_emitter_quiescence" => "not_proven"
       }}
    end
  end

  defp read_recorder(handle, cursor, limit, max_bytes) do
    case Recorder.read_since(handle, cursor, limit: limit, max_bytes: max_bytes) do
      {:ok, read} -> {:ok, read}
      {:error, :invalid_cursor} -> {:error, :invalid_cursor}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # Redaction runs in this Session under the trusted classification policy it
  # was started with. A deadline stops the batch at the last processed receipt;
  # any other redaction failure withholds that event but still consumes it.
  defp redact_entries(read, policy, deadline) do
    initial = %{
      events: [],
      next_cursor: read.next_cursor,
      processed: 0,
      last: read.cursor,
      truncated: read.truncated,
      truncated_by: read.truncated_by && Atom.to_string(read.truncated_by),
      withheld: 0,
      withheld_receipts: []
    }

    Enum.reduce_while(read.entries, initial, fn entry, acc ->
      case redact_entry(entry, policy, deadline) do
        {:ok, event} ->
          {:cont,
           %{
             acc
             | events: [event | acc.events],
               processed: acc.processed + 1,
               last: entry.receipt
           }}

        :withheld ->
          {:cont,
           %{
             acc
             | withheld: acc.withheld + 1,
               withheld_receipts: [entry.receipt | acc.withheld_receipts],
               processed: acc.processed + 1,
               last: entry.receipt
           }}

        :deadline ->
          {:halt, %{acc | next_cursor: acc.last, truncated: true, truncated_by: "deadline"}}
      end
    end)
  end

  defp redact_entry(entry, policy, deadline) do
    classification = entry.classification

    with :ok <- before_read_deadline(deadline),
         true <- classification.policy_id == policy.id,
         true <- classification.policy_fingerprint == policy.fingerprint,
         {:ok, outcome} <-
           Redaction.redact(entry.event, classification.sensitivity, policy,
             deadline_monotonic_us: deadline * 1_000
           ) do
      {:ok,
       %{
         "receipt" => entry.receipt,
         "received_at_us" => entry.received_at,
         "priority" => Atom.to_string(entry.priority),
         "event" => outcome.value,
         "redactions" => outcome.manifest
       }}
    else
      :deadline -> :deadline
      {:error, %{details: %{reason: "deadline_exceeded"}}} -> :deadline
      _other -> :withheld
    end
  end

  defp before_read_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: :deadline
  end

  defp quiesce_poller(state, deadline) do
    case Map.fetch(state.components, :poller) do
      :error ->
        {:ok, %{"configured" => false, "evidence" => "not_configured"}}

      {:ok, pid} when is_pid(pid) ->
        with {:ok, timeout} <- remaining_evidence_timeout(deadline),
             {:ok, status} <- Poller.quiesce(pid, deadline, timeout),
             {:ok, evidence} <- project_component_status(:poller, status),
             true <- poller_idle?(Map.merge(%{"evidence" => "bounded_quiescence"}, evidence)) do
          {:ok, Map.merge(%{"configured" => true, "evidence" => "bounded_quiescence"}, evidence)}
        else
          {:error, :request_expired} = error -> error
          _other -> {:error, :producer_quiescence_unavailable}
        end

      {:ok, _other} ->
        {:error, :producer_quiescence_unavailable}
    end
  end

  defp evidence_component(state, component, request, deadline) do
    case Map.fetch(state.components, component) do
      # A sealed component reports the final status it was sealed with.
      :error ->
        {:ok,
         Map.get(state.sealed_evidence, component, %{
           "configured" => false,
           "evidence" => "not_configured"
         })}

      {:ok, pid} when is_pid(pid) ->
        with {:ok, timeout} <- remaining_evidence_timeout(deadline),
             {:ok, status} <- bounded_component_call(pid, request, timeout),
             {:ok, evidence} <- project_component_status(component, status) do
          {:ok, Map.merge(%{"configured" => true, "evidence" => "bounded_status"}, evidence)}
        else
          {:error, :request_expired} = error -> error
          _other -> {:ok, %{"configured" => true, "evidence" => "malformed_or_unavailable"}}
        end

      {:ok, _other} ->
        {:ok, %{"configured" => true, "evidence" => "malformed_or_unavailable"}}
    end
  end

  defp recorder_evidence(handle, deadline) do
    with {:ok, _timeout} <- remaining_evidence_timeout(deadline),
         {:ok, status} <- Recorder.status(handle),
         {:ok, evidence} <- project_recorder_status(status) do
      {:ok, Map.merge(%{"configured" => true, "evidence" => "bounded_status"}, evidence)}
    else
      {:error, :request_expired} = error -> error
      _other -> {:ok, %{"configured" => true, "evidence" => "malformed_or_unavailable"}}
    end
  end

  defp bounded_component_call(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, {:timeout, _call} -> {:error, :request_expired}
    :exit, _reason -> {:error, :unavailable}
  end

  defp remaining_evidence_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :request_expired}
  end

  defp project_component_status(:logger, status),
    do: project_integer_status(status, @logger_evidence_fields)

  defp project_component_status(:calls, status),
    do: project_integer_status(status, @calls_evidence_fields)

  defp project_component_status(:telemetry, status),
    do: project_integer_status(status, @telemetry_evidence_fields)

  defp project_component_status(:otel, status),
    do: project_integer_status(status, @otel_evidence_fields)

  defp project_component_status(:poller, status) when is_map(status) do
    with {:ok, integers} <- project_integer_status(status, @poller_integer_fields),
         true <- Enum.all?(@poller_boolean_fields, &is_boolean(Map.get(status, &1))) do
      booleans = Map.new(@poller_boolean_fields, &{Atom.to_string(&1), Map.fetch!(status, &1)})
      {:ok, Map.merge(integers, booleans)}
    else
      _other -> {:error, :malformed_status}
    end
  end

  defp project_component_status(_component, _status), do: {:error, :malformed_status}

  defp project_recorder_status(status) when is_map(status) do
    with true <- Map.get(status, :phase) in [:open, :post_trigger, :frozen],
         {:ok, integers} <- project_integer_status(status, @recorder_integer_fields),
         counters when is_map(counters) <- Map.get(status, :counters),
         {:ok, projected_counters} <- project_integer_status(counters, @recorder_counter_fields) do
      {:ok,
       integers
       |> Map.put("phase", Atom.to_string(Map.fetch!(status, :phase)))
       |> Map.put("counters", projected_counters)}
    else
      _other -> {:error, :malformed_status}
    end
  end

  defp project_integer_status(status, fields) when is_map(status) do
    if Enum.all?(fields, &(is_integer(Map.get(status, &1)) and Map.get(status, &1) >= 0)) do
      {:ok, Map.new(fields, &{Atom.to_string(&1), Map.fetch!(status, &1)})}
    else
      {:error, :malformed_status}
    end
  end

  defp project_integer_status(_status, _fields), do: {:error, :malformed_status}

  defp visible_inboxes_empty?(logger, telemetry) do
    Enum.all?([logger, telemetry], fn
      %{"configured" => false} -> true
      %{"evidence" => "bounded_status", "inbox_count" => 0} -> true
      _other -> false
    end)
  end

  defp poller_idle?(%{"configured" => false}), do: true

  defp poller_idle?(%{
         "evidence" => evidence,
         "cycle_active" => false,
         "probe_active" => false,
         "quiesced" => true,
         "timer_scheduled" => false
       }),
       do: evidence in ["bounded_status", "bounded_quiescence"]

  defp poller_idle?(_evidence), do: false

  defp finish(state, requested_outcome, reason) do
    {cleanup, state} = cleanup(%{state | mode: :stopping})

    outcome =
      if requested_outcome == "stopped" and clean?(cleanup),
        do: "stopped",
        else: "cleanup_incomplete"

    state = add_history(state, "session", "terminated", reason)
    receipt = receipt(state.config.id, state.incarnation, outcome, cleanup, length(state.history))
    send(state.manager, {:session_terminal, self(), state.token, receipt})
    {:stop, :normal, state}
  end

  defp stop_component(_component, nil, components), do: {"not_started", components}

  defp stop_component(:telemetry, pid, components) do
    result =
      case Telemetry.stop(pid) do
        {:ok, cleanup} ->
          if(cleanup.handler in [:removed, :already_detached], do: "absent", else: "residual")

        _other ->
          terminate_pid(pid)
      end

    {result, Map.delete(components, :telemetry)}
  end

  # The capture is removed before the collector exits; a collector that does
  # not answer is terminated, and its exit removes the capture too.
  defp stop_component(:otel, pid, components) do
    result =
      case Otel.stop(pid) do
        {:ok, %{trace: trace}} when trace in ["removed", "already_removed", "not_installed"] ->
          "absent"

        {:ok, _cleanup} ->
          "residual"

        _other ->
          terminate_pid(pid)
      end

    {result, Map.delete(components, :otel)}
  end

  defp stop_component(_component, pid, components) do
    {terminate_pid(pid), Map.delete(components, component_for_pid(components, pid))}
  end

  defp terminate_pid(pid) when not is_pid(pid), do: "not_started"

  defp terminate_pid(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      _ = safe_stop(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> "absent"
      after
        @cleanup_timeout_ms -> force_stop(pid, monitor)
      end
    else
      "already_absent"
    end
  rescue
    _error -> "inspection_unavailable"
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, @cleanup_timeout_ms)
  catch
    :exit, _reason -> :unavailable
  end

  defp force_stop(pid, monitor) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> "absent_after_force"
    after
      @cleanup_timeout_ms -> "residual"
    end
  end

  defp health_map(state) do
    {component_states, component_evidence, degraded?} =
      [:recorder | state.config.components]
      |> Enum.reduce({%{}, %{}, false}, fn component, {states, evidence, degraded?} ->
        {status, observation} = component_observation(component, state.components[component])

        {
          Map.put(states, Atom.to_string(component), status),
          Map.put(evidence, Atom.to_string(component), observation),
          degraded? or status != "running"
        }
      end)

    report_mode = if state.mode == :running and degraded?, do: :degraded, else: state.mode

    %{
      "schema" => "insider.collector-session-health/v1",
      "state" => Atom.to_string(report_mode),
      "correctness" => "not_proven_by_liveness",
      "components" => component_states,
      "component_evidence" => component_evidence,
      "history" => Enum.take(state.history, @maximum_history),
      "history_count" => length(state.history),
      "mailbox_bound" => "public_api_admission_limit",
      "memory" => memory_map(state),
      "recorder" => recorder_fill(state.recorder_handle),
      "session_id" => state.config.id
    }
  end

  # Insider's own footprint for this session, in bytes: the Session and each
  # live component process as `Process.info/2` reports `:memory` (heap,
  # stack, and message queue; refc binaries are shared and not included).
  # The Recorder's tables are its fill's `"ets_bytes"`.
  defp memory_map(state) do
    Enum.reduce(state.components, %{"session" => process_memory(self())}, fn
      {component, pid}, memory when is_pid(pid) ->
        case process_memory(pid) do
          nil -> memory
          bytes -> Map.put(memory, Atom.to_string(component), bytes)
        end

      _component, memory ->
        memory
    end)
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> nil
    end
  end

  # Lock-free, so a health check never makes a producer drop.
  defp recorder_fill(nil), do: nil

  defp recorder_fill(handle) do
    case Recorder.fill(handle) do
      {:ok, fill} -> Map.new(fill, fn {key, value} -> {Atom.to_string(key), plain(value)} end)
      {:error, :unavailable} -> nil
    end
  end

  # The fill's per-source table, with string keys like the rest of health.
  defp plain(sources) when is_map(sources) do
    Map.new(sources, fn {group, usage} ->
      {group, Map.new(usage, fn {key, value} -> {Atom.to_string(key), value} end)}
    end)
  end

  defp plain(value), do: value

  defp component_observation(_component, nil), do: {"absent", "not_started_or_exited"}

  defp component_observation(:recorder, pid) when is_pid(pid) do
    if Process.alive?(pid),
      do: {"running", "owned_handle_not_queried"},
      else: {"absent", "exited"}
  end

  defp component_observation(_component, pid) when is_pid(pid) do
    if Process.alive?(pid) do
      case safe_component_status(pid) do
        {:ok, status} ->
          if is_map(status) and bounded_status?(status),
            do: {"running", "bounded_status"},
            else: {"unavailable", "malformed_or_unavailable"}

        _other ->
          {"unavailable", "malformed_or_unavailable"}
      end
    else
      {"absent", "exited"}
    end
  end

  defp component_observation(_component, _other), do: {"unavailable", "malformed_or_unavailable"}

  defp safe_component_status(pid) do
    GenServer.call(pid, :status, @component_status_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp bounded_status?(status) do
    map_size(status) <= 64 and
      Enum.all?(status, fn
        {key, value}
        when (is_atom(key) or (is_binary(key) and byte_size(key) <= 128)) and
               (is_integer(value) or is_boolean(value)) ->
          true

        _other ->
          false
      end)
  end

  defp component_for_pid(components, pid),
    do: Enum.find_value(components, fn {name, value} -> if value == pid, do: name end)

  defp add_history(state, component, event, reason) do
    entry = %{"component" => component, "event" => event, "reason" => reason}
    %{state | history: Enum.take([entry | state.history], @maximum_history)}
  end

  defp mailbox_overloaded? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, count} -> count > @maximum_mailbox
      _other -> true
    end
  end

  @spec admitted_call(pid(), Admission.t(), term(), timeout()) ::
          {:ok, map()} | {:error, term()}
  defp admitted_call(pid, admission, message, timeout)
       when is_pid(pid) do
    case Admission.acquire(admission, @maximum_mailbox) do
      :ok -> safe_call(pid, {:admitted, admission, message}, timeout)
      :overloaded -> {:error, :mailbox_overloaded}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp admitted_call(_pid, _admission, _message, _timeout), do: {:error, :unavailable}

  defp admitted_evidence_call(pid, admission, message, timeout) when is_pid(pid) do
    case Admission.acquire(admission, @maximum_mailbox) do
      :ok -> safe_evidence_call(pid, {:admitted, admission, message}, timeout)
      :overloaded -> {:error, :mailbox_overloaded}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp admitted_evidence_call(_pid, _admission, _message, _timeout),
    do: {:error, :unavailable}

  @spec release_admission(Admission.t()) :: :ok
  defp release_admission(admission), do: Admission.release(admission)

  defp logger_filter_absence do
    # A killed Logger collector cannot run its terminate callback. Reclaim only
    # the recognizable Insider filter whose inbox ETS owner is already gone.
    _ = LoggerCollector.reclaim_stale_filter(:insider_logger)
    %{filters: filters} = :logger.get_primary_config()

    if Enum.any?(filters, fn {id, _filter} -> id == :insider_logger end),
      do: "residual",
      else: "absent"
  rescue
    _error -> "inspection_unavailable"
  end

  defp telemetry_handler_absence(nil), do: "absent"

  defp telemetry_handler_absence(%TelemetryPolicy{event_names: event_names} = policy) do
    # As above, do not detach a foreign fixed-id handler. The collector helper
    # requires the exact Handler function and a dead owned inbox.
    _ = Telemetry.reclaim_stale_handler(policy, "insider-session-telemetry")

    present? =
      event_names
      |> Enum.flat_map(&:telemetry.list_handlers/1)
      |> Enum.any?(&(&1.id == "insider-session-telemetry"))

    if present?, do: "residual", else: "absent"
  rescue
    _error -> "inspection_unavailable"
  end

  defp recorder_tables_absence(nil), do: "not_started"

  defp recorder_tables_absence(pid) do
    if Process.alive?(pid), do: "residual", else: "absent"
  rescue
    _error -> "inspection_unavailable"
  end

  defp clean?(inventory) do
    Enum.all?(inventory["components"], fn {_component, status} ->
      status in ["not_started", "absent", "already_absent", "absent_after_force"]
    end) and
      inventory["logger_filter"] == "absent" and inventory["telemetry_handler"] == "absent" and
      inventory["recorder_ets"] in ["not_started", "absent"] and
      inventory["monitors"] == "dropped" and
      Map.get(inventory, "call_trace", %{"traced_after" => 0})["traced_after"] == 0
  end

  defp receipt(id, incarnation, outcome, cleanup, history_count) do
    body = %{
      "schema" => "insider.collector-session-receipt/v1",
      "session_id" => id,
      "incarnation" => incarnation,
      "outcome" => outcome,
      "cleanup" => cleanup,
      "history_count" => min(max(history_count, 0), @maximum_history)
    }

    Map.put(body, "id", "sha256:" <> Insider.Event.Canonical.sha256(body))
  end

  defp classify_reason(reason)
       when reason in [:normal, :shutdown, :killed, :timeout, :owner_down, :mailbox_overload],
       do: Atom.to_string(reason)

  defp classify_reason(_reason), do: "other"

  defp valid_components?(components),
    do:
      is_list(components) and components != [] and length(components) <= length(@components) and
        components == Enum.uniq(components) and Enum.all?(components, &(&1 in @components))

  defp telemetry_valid?(components, options) do
    if :telemetry in components,
      do: TelemetryPolicy.valid?(Keyword.get(options, :telemetry_policy)),
      else: is_nil(Keyword.get(options, :telemetry_policy))
  end

  defp common_values?(options) do
    Enum.all?([:authority, :boot_id, :clock_id], fn key ->
      value = Keyword.get(options, key)
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)
    end)
  end

  defp nested_options?(options) do
    Enum.all?(
      [:logger_options, :telemetry_options, :poller_options, :otel_options, :calls_options],
      fn key ->
        nested = Keyword.get(options, key, [])
        Keyword.keyword?(nested) and Keyword.keys(nested) == Enum.uniq(Keyword.keys(nested))
      end
    ) and
      no_reserved_keys?(Keyword.get(options, :logger_options, []), [
        :authority,
        :boot_id,
        :clock_id,
        :environment,
        :handler_id
      ]) and
      no_reserved_keys?(Keyword.get(options, :telemetry_options, []), [
        :authority,
        :boot_id,
        :clock_id,
        :environment,
        :handler_id
      ]) and
      no_reserved_keys?(Keyword.get(options, :poller_options, []), [
        :authority,
        :boot_id,
        :clock_id,
        :environment,
        :protected_target_policy,
        :host_protected_targets
      ]) and
      no_reserved_keys?(Keyword.get(options, :otel_options, []), [
        :authority,
        :boot_id,
        :clock_id,
        :environment
      ]) and
      no_reserved_keys?(Keyword.get(options, :calls_options, []), [
        :authority,
        :boot_id,
        :clock_id,
        :environment
      ])
  end

  defp no_reserved_keys?(options, reserved),
    do: Enum.all?(reserved, &(not Keyword.has_key?(options, &1)))

  defp required_keys, do: [:id, :environment, :authority, :boot_id, :clock_id, :recorder_options]

  defp allowed_keys,
    do:
      required_keys() ++
        [
          :components,
          :logger_options,
          :telemetry_options,
          :telemetry_policy,
          :poller_options,
          :otel_options,
          :calls_options
        ]

  defp safe_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_evidence_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :request_expired}
    :exit, _reason -> {:error, :unavailable}
  end

  @spec startup_authorized?(term(), term()) :: boolean()
  defp startup_authorized?(guard, token),
    do: StartupGuard.authorized?(guard, token, System.monotonic_time(:millisecond))
end
