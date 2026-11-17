defmodule Insider.LoadHarness.SessionSupport do
  @moduledoc false

  alias Insider.Collector.Session
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.LoadHarness.Profile
  alias Insider.Redaction.Policy, as: RedactionPolicy
  alias Insider.Runtime.HostPolicy

  @telemetry_event [:insider, :load, :host_operation]

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @spec start(Profile.t(), [pid()], String.t()) ::
          {:ok, Insider.Collector.Session.Handle.t()} | {:error, term()}
  def start(%Profile{} = profile, targets, id) when is_list(targets) and is_binary(id) do
    with {:ok, host_policy} <- HostPolicy.new(host_protected_targets: []),
         {:ok, redaction_policy} <-
           RedactionPolicy.new(
             id: "insider-load-scalars",
             maximum_sensitivity: :internal,
             rules: []
           ),
         {:ok, telemetry_policy} <- telemetry_policy() do
      Session.start(host_policy,
        id: id,
        environment: :ci,
        authority: "insider-load-harness",
        boot_id: "synthetic-load",
        clock_id: "monotonic-time",
        recorder_options: [
          classification: {:internal, redaction_policy},
          max_events: profile.recorder_events,
          max_bytes: profile.recorder_bytes,
          rate_limit_count: profile.rate_per_second,
          rate_window_ms: 1_000,
          max_rate_keys: 16,
          pre_trigger_ms: 0,
          post_trigger_ms: 0
        ],
        components: [:logger, :telemetry, :poller],
        logger_options: [
          include_payload: false,
          inbox_size: profile.inbox_size,
          batch_size: min(profile.inbox_size, 256),
          drain_interval_ms: 10
        ],
        telemetry_policy: telemetry_policy,
        telemetry_options: [
          inbox_size: profile.inbox_size,
          batch_size: min(profile.inbox_size, 256),
          drain_interval_ms: 10
        ],
        poller_options: [
          provider: Insider.LoadHarness.Provider,
          targets: targets,
          interval_ms: max(profile.sample_interval_ms, 10),
          initial_delay_ms: 0,
          probe_timeout_ms: 50,
          cleanup_timeout_ms: 10,
          cycle_timeout_ms: 250
        ]
      )
    end
  end

  @spec fresh_cycle(Profile.t()) :: {:ok, map()} | {:error, term()}
  def fresh_cycle(%Profile{} = profile) do
    id = "load-fresh-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    case with_session(fn -> start(profile, [], id) end, fn _handle -> :fresh_cycle end) do
      {:ok, :fresh_cycle, receipt} when is_map(receipt) -> {:ok, receipt}
      {:ok, :fresh_cycle, nil} -> {:error, :cleanup_failed}
      {:error, reason, _receipt} -> {:error, reason}
    end
  end

  @doc false
  @spec with_session(
          (-> {:ok, term()} | {:error, term()}),
          (term() -> term()),
          keyword()
        ) ::
          {:ok, term(), map() | nil}
          | {:error, :session_start_failed | :phase_execution_failed, map() | nil}
  def with_session(start_fun, execute_fun, options \\ [])
      when is_function(start_fun, 0) and is_function(execute_fun, 1) and is_list(options) do
    stop_fun = Keyword.get(options, :stop, &Session.stop/1)
    kill_fun = Keyword.get(options, :kill, &Session.kill/1)

    case safe_start(start_fun) do
      {:ok, handle} -> execute_and_terminate(handle, execute_fun, stop_fun, kill_fun)
      {:error, _reason} -> {:error, :session_start_failed, nil}
    end
  end

  defp execute_and_terminate(handle, execute_fun, stop_fun, kill_fun) do
    execution =
      try do
        {:ok, execute_fun.(handle)}
      rescue
        _error -> {:error, :phase_execution_failed}
      catch
        _kind, _reason -> {:error, :phase_execution_failed}
      end

    receipt = terminate(handle, stop_fun, kill_fun)

    case execution do
      {:ok, result} -> {:ok, result, receipt}
      {:error, reason} -> {:error, reason, receipt}
    end
  end

  defp safe_start(start_fun) do
    case start_fun.() do
      {:ok, _handle} = started -> started
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_start_result}
    end
  rescue
    _error -> {:error, :start_failed}
  catch
    _kind, _reason -> {:error, :start_failed}
  end

  defp terminate(handle, stop_fun, kill_fun) do
    case safe_terminate(stop_fun, handle) do
      {:ok, receipt} ->
        if complete_receipt?(receipt),
          do: receipt,
          else: kill_receipt(kill_fun, handle, receipt)

      {:error, _reason} ->
        kill_receipt(kill_fun, handle, nil)
    end
  end

  defp kill_receipt(kill_fun, handle, fallback) do
    case safe_terminate(kill_fun, handle) do
      {:ok, receipt} -> receipt
      {:error, _reason} -> fallback
    end
  end

  @doc false
  @spec complete_receipt?(term()) :: boolean()
  def complete_receipt?(%{"outcome" => outcome, "cleanup" => cleanup})
      when outcome in ["stopped", "killed"] and is_map(cleanup) do
    components = cleanup["components"]

    is_map(components) and
      Enum.sort(Map.keys(components)) == ~w(logger poller recorder telemetry) and
      Enum.all?(components, fn {_component, status} ->
        status in ["absent", "absent_after_force", "already_absent", "not_started"]
      end) and cleanup["logger_filter"] == "absent" and
      cleanup["telemetry_handler"] == "absent" and
      cleanup["recorder_ets"] in ["absent", "not_started"] and
      cleanup["manager_ownership"] == "absent" and cleanup["monitors"] == "dropped" and
      cleanup["policy_reference"] == "dropped" and cleanup["session_timers"] == "none_owned"
  end

  def complete_receipt?(_receipt), do: false

  defp safe_terminate(fun, handle) when is_function(fun, 1) do
    case fun.(handle) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_termination_result}
    end
  rescue
    _error -> {:error, :termination_failed}
  catch
    _kind, _reason -> {:error, :termination_failed}
  end

  defp telemetry_policy do
    TelemetryPolicy.new(
      id: "insider-load-telemetry",
      events: [
        [
          name: @telemetry_event,
          kind: "load.host.operation",
          lifecycle: "load",
          phase: :event
        ]
      ],
      measurements: [duration: "duration"],
      metadata: [],
      correlation: []
    )
  end
end
