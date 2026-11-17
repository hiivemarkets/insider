defmodule Insider.Runtime do
  @moduledoc """
  Bounded, read-only access to runtime diagnostics.

  Runtime operations return `Insider.Protocol.Result` values so IEx, Mix tasks,
  and future adapters share the same limits and outcome vocabulary. The caller
  supplies the trusted environment; releases must not infer it from an
  untrusted request.
  """

  alias Insider.Collector.Poller.Erlang, as: ErlangProvider
  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Policy.ProtectedTargets
  alias Insider.Protocol
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Protocol.Value
  alias Insider.Runtime.HostPolicy

  @provider "insider.runtime.erlang"
  @capability "insider.runtime.local-observation"
  @audit_id "insider.runtime.local-process"
  @default_probe_timeout_ms 50
  @default_cleanup_timeout_ms 10
  @maximum_probe_timeout_ms 1_000
  @maximum_cleanup_timeout_ms 100
  @maximum_heap_words 1_048_576
  @admission_reserve_ms 1_000
  @environments [:development, :test, :ci]
  @option_keys [:environment, :provider, :probe_timeout_ms, :cleanup_timeout_ms]

  @type option ::
          {:environment, :development | :test | :ci}
          | {:provider, module()}
          | {:probe_timeout_ms, pos_integer()}
          | {:cleanup_timeout_ms, pos_integer()}

  @doc false
  @spec observation_capability() :: String.t()
  def observation_capability, do: @capability

  @doc "Returns the runtime operations available in the declared environment."
  @spec capabilities([option()]) :: Result.t() | {:error, Error.t()}
  def capabilities(options) when is_list(options) do
    with {:ok, runtime} <- options(options),
         {:ok, request} <- request("runtime.capabilities", runtime, %{}) do
      dispatch_runtime(request, runtime)
    end
  end

  @doc false
  @spec describe(pid(), [option()]) :: Result.t() | {:error, Error.t()}
  def describe(_pid, _options),
    do: {:error, invalid_request("runtime process inspection requires a trusted host policy")}

  @doc """
  Describes a target using a host-owned protected-target binding.

  `host_policy` must come from trusted host startup configuration via
  `bind_host_policy/1`; protocol requests, adapter parameters, and Runtime
  options cannot replace it. This is a binding primitive, not a session or
  production-enablement lifecycle.
  """
  @spec describe(pid(), [option()], HostPolicy.t()) :: Result.t() | {:error, Error.t()}
  def describe(pid, options, %HostPolicy{} = host_policy) when is_pid(pid) and is_list(options) do
    with true <- HostPolicy.valid?(host_policy),
         {:ok, runtime} <- options(options, host_policy),
         {:ok, request} <-
           request("process.describe", runtime, %{"pid" => pid_string(pid)}, @capability) do
      dispatch_runtime(request, runtime)
    else
      false -> {:error, invalid_request("runtime host policy is invalid")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def describe(_pid, _options, _host_policy),
    do: {:error, invalid_request("runtime target, options, or host policy is invalid")}

  @doc "Builds an additive protected-target binding from trusted host startup configuration."
  @spec bind_host_policy(keyword()) :: {:ok, HostPolicy.t()} | {:error, :invalid_policy}
  def bind_host_policy(options), do: HostPolicy.new(options)

  @doc false
  @spec dispatch(Request.t(), keyword()) :: Result.t()
  def dispatch(%Request{operation: "process.describe"} = request, _options) do
    Protocol.failure(
      request,
      Error.new(:policy_denied, "runtime process inspection requires a trusted host policy")
    )
  end

  def dispatch(%Request{} = request, options) when is_list(options) do
    case options(options) do
      {:ok, runtime} -> dispatch_runtime(request, runtime)
      {:error, %Error{} = error} -> Protocol.failure(request, error)
    end
  end

  @doc false
  @spec dispatch(Request.t(), [option()], HostPolicy.t()) :: Result.t()
  def dispatch(%Request{} = request, options, %HostPolicy{} = host_policy)
      when is_list(options) do
    if HostPolicy.valid?(host_policy) do
      case options(options, host_policy) do
        {:ok, runtime} -> dispatch_runtime(request, runtime)
        {:error, %Error{} = error} -> Protocol.failure(request, error)
      end
    else
      Protocol.failure(request, invalid_request("runtime host policy is invalid"))
    end
  end

  defp dispatch_runtime(request, runtime) do
    with {:ok, context} <- context(request, runtime),
         {:ok, decision} <- Policy.authorize(request, context) do
      execute(request, decision, runtime)
    else
      {:error, %Error{} = error} -> Protocol.failure(request, error)
    end
  end

  defp request(operation, runtime, params, capability \\ nil) do
    max_duration_ms =
      runtime.probe_timeout_ms + runtime.cleanup_timeout_ms + @admission_reserve_ms

    Protocol.request(operation,
      request_id: request_id(),
      environment: runtime.environment,
      timeout_ms: max_duration_ms,
      budget: [
        max_duration_ms: max_duration_ms,
        max_events: 1,
        max_bytes: 65_536,
        max_targets: 1
      ],
      params: params,
      capability: capability
    )
  end

  defp context(request, runtime) do
    grants =
      if request.operation == "process.describe" do
        with {:ok, grant} <-
               Grant.new(
                 reference: @capability,
                 audit_id: @audit_id,
                 scopes: ["runtime.observe"],
                 target: request.target,
                 expires_at_monotonic: request.deadline_monotonic
               ) do
          [grant]
        else
          _error -> []
        end
      else
        []
      end

    Context.new(
      environment: runtime.environment,
      actor: "insider-runtime-local",
      grants: grants,
      features: features(),
      deployment_limits: %{
        max_duration_ms: runtime.probe_timeout_ms + runtime.cleanup_timeout_ms + 10,
        max_events: 1,
        max_bytes: 65_536,
        max_targets: 1
      }
    )
  end

  defp features do
    %{
      "runtime.capabilities" => %{
        available: true,
        provider: @provider,
        isolation: :read_only
      },
      "process.describe" => %{
        available: true,
        provider: @provider,
        isolation: :read_only
      }
    }
  end

  defp execute(%Request{operation: "runtime.capabilities"} = request, decision, runtime) do
    value = %{
      "schema" => "insider.runtime-capabilities/v1",
      "protocol" => Protocol.version(),
      "environment" => Atom.to_string(runtime.environment),
      "operations" => Policy.capabilities(context!(request, runtime)),
      "interfaces" => ["elixir", "mix"],
      "constraints" => [
        "same_node",
        "explicit_process_target",
        "scalar_fields_only",
        "no_messages_or_process_state"
      ]
    }

    Protocol.success(request, value, result_options(decision, 0, %{status: :not_required}))
  end

  defp execute(%Request{operation: "process.describe"} = request, decision, runtime) do
    with true <- Policy.dispatchable?(decision),
         {:ok, pid} <- parse_pid(request.params),
         true <- node(pid) == node(),
         {:allowed, _evidence} <- ProtectedTargets.classify(runtime.protected_target_policy, pid) do
      probe(request, decision, runtime, pid)
    else
      {:protected, evidence} -> protected_failure(request, decision, evidence)
      false -> failure(request, decision, "target is not a live same-node process", :protected)
      {:error, reason} -> failure(request, decision, "process target is invalid", reason)
    end
  end

  defp execute(request, _decision, _runtime),
    do: Protocol.unsupported(request, :runtime_operation)

  defp probe(request, decision, runtime, pid) do
    started_at = System.monotonic_time(:microsecond)
    caller = self()
    token = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn -> guard_probe(caller, token, runtime.provider, pid) end,
        [
          :monitor,
          {:max_heap_size, %{size: @maximum_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {:DOWN, ^monitor, :process, ^worker, {:runtime_probe_result, ^token, result}} ->
        finish_probe(request, decision, runtime, pid, result, elapsed(started_at))

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        failure(request, decision, "runtime probe failed", :failed, elapsed(started_at))
    after
      runtime.probe_timeout_ms ->
        send(worker, {:cancel_runtime_probe, token})
        cleanup = await_cleanup(monitor, worker, runtime.cleanup_timeout_ms)

        Protocol.timeout(
          request,
          result_options(decision, elapsed(started_at), cleanup,
            uncertainty: ["the synchronous runtime inspection may already have been delivered"]
          )
        )
    end
  end

  defp guard_probe(caller, token, provider, target) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    guardian = self()

    probe =
      :erlang.spawn_opt(
        fn ->
          send(guardian, {:guarded_probe_result, token, self(), safe_probe(provider, target)})
        end,
        [
          :link,
          {:max_heap_size, %{size: @maximum_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {:guarded_probe_result, ^token, ^probe, result} ->
        await_probe_exit(probe)
        Process.demonitor(caller_monitor, [:flush])
        exit({:runtime_probe_result, token, result})

      {:cancel_runtime_probe, ^token} ->
        stop_probe(probe)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        stop_probe(probe)

      {:EXIT, ^probe, _reason} ->
        Process.demonitor(caller_monitor, [:flush])
        exit({:runtime_probe_result, token, {:error, :failed}})
    end
  end

  defp stop_probe(probe) do
    Process.exit(probe, :kill)
    await_probe_exit(probe)
  end

  defp await_probe_exit(probe) do
    receive do
      {:EXIT, ^probe, _reason} -> :ok
    after
      @maximum_cleanup_timeout_ms -> :uncertain
    end
  end

  defp finish_probe(
         request,
         decision,
         runtime,
         pid,
         {:ok, status, metrics, unavailable},
         duration
       )
       when status in [:complete, :partial] and is_map(metrics) and is_list(unavailable) do
    value = %{
      "schema" => "insider.process-description/v1",
      "target" => %{"node" => Atom.to_string(node(pid)), "pid" => pid_string(pid)},
      "provider" => Atom.to_string(runtime.provider),
      "observer_effect" => "synchronous_runtime_inspection",
      "status" => Atom.to_string(status),
      "metrics" => metrics,
      "unavailable" => unavailable
    }

    if Value.bounded_data?(value, decision.effective_limits.max_bytes) do
      Protocol.success(
        request,
        value,
        result_options(decision, duration, %{status: :complete},
          consumption: %{
            duration_us: duration,
            evidence_bytes: :erlang.external_size(value),
            events: 0,
            targets: 1
          }
        )
      )
    else
      failure(request, decision, "runtime evidence exceeded its byte bound", :oversized, duration)
    end
  end

  defp finish_probe(request, decision, _runtime, _pid, {:error, reason}, duration),
    do: failure(request, decision, "runtime process inspection failed", reason, duration)

  defp finish_probe(request, decision, _runtime, _pid, _result, duration),
    do:
      failure(request, decision, "runtime provider returned an invalid result", :failed, duration)

  defp failure(request, decision, message, reason, duration \\ 0) do
    error = Error.new(:operation_failed, message, %{reason: Value.summary(reason)})
    Protocol.failure(request, error, result_options(decision, duration, %{status: :not_required}))
  end

  defp protected_failure(request, decision, evidence) do
    error =
      Error.new(:policy_denied, "runtime target is protected", %{target_protection: evidence})

    Protocol.failure(request, error, result_options(decision, 0, %{status: :not_required}))
  end

  defp result_options(decision, duration, cleanup, options \\ []) do
    [
      cleanup: cleanup,
      duration_us: duration,
      effective_limits: decision.effective_limits,
      policy_fingerprint: decision.policy_fingerprint
    ]
    |> Keyword.merge(options)
  end

  defp await_cleanup(monitor, worker, timeout_ms) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        %{status: :complete}
    after
      timeout_ms ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        %{status: :uncertain}
    end
  end

  defp safe_probe(provider, pid) do
    provider.process_sample(pid)
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp parse_pid(%{"pid" => value} = params) when map_size(params) == 1 and is_binary(value) do
    if byte_size(value) <= 64 and Regex.match?(~r/^<\d+\.\d+\.\d+>$/, value) do
      {:ok, :erlang.list_to_pid(String.to_charlist(value))}
    else
      {:error, :invalid_pid}
    end
  rescue
    _error -> {:error, :invalid_pid}
  end

  defp parse_pid(_params), do: {:error, :invalid_params}

  defp options(options) do
    with {:ok, host_policy} <- HostPolicy.new() do
      options(options, host_policy)
    end
  end

  defp options(options, host_policy) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- @option_keys,
         environment when environment in @environments <- Keyword.get(options, :environment),
         provider when is_atom(provider) <- Keyword.get(options, :provider, ErlangProvider),
         true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :process_sample, 1),
         probe_timeout when probe_timeout in 1..@maximum_probe_timeout_ms <-
           Keyword.get(options, :probe_timeout_ms, @default_probe_timeout_ms),
         cleanup_timeout when cleanup_timeout in 1..@maximum_cleanup_timeout_ms <-
           Keyword.get(options, :cleanup_timeout_ms, @default_cleanup_timeout_ms) do
      {:ok,
       %{
         environment: environment,
         protected_target_policy: host_policy.protected_targets,
         provider: provider,
         probe_timeout_ms: probe_timeout,
         cleanup_timeout_ms: cleanup_timeout
       }}
    else
      _invalid -> {:error, invalid_request("runtime options are invalid")}
    end
  end

  defp context!(request, runtime) do
    {:ok, context} = context(request, runtime)
    context
  end

  defp invalid_request(message), do: Error.new(:invalid_request, message)
  defp request_id, do: "runtime-" <> Integer.to_string(System.unique_integer([:positive]))
  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp elapsed(started_at), do: max(System.monotonic_time(:microsecond) - started_at, 0)
end
