defmodule Insider.Sentinel.Sandbox.Executor do
  @moduledoc """
  Fixed-capacity supervisor for provider-driven disposable target runs.

  Provider modules are an explicit trusted allowlist configured at startup.
  """

  use Supervisor

  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Sentinel.Sandbox.Registry
  alias Insider.Sentinel.Sandbox.Target

  @default_concurrency 4
  @maximum_concurrency 32
  @default_cleanup_timeout_ms 500
  @maximum_cleanup_timeout_ms 5_000
  @default_body_stop_timeout_ms 50
  @maximum_body_stop_timeout_ms 5_000
  @minimum_result_bytes 65_536
  @maximum_body_input_bytes 98_304
  @option_keys [:request, :context, :body, :cleanup_timeout_ms]

  @type handle :: %{pid: pid(), token: reference()}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    supervisor_options = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, options, supervisor_options)
  end

  @impl true
  def init(options) do
    concurrency = Keyword.get(options, :max_concurrency, @default_concurrency)
    providers = Keyword.get(options, :providers, [])
    bodies = Keyword.get(options, :bodies, [])

    unless is_integer(concurrency) and concurrency in 1..@maximum_concurrency do
      raise ArgumentError, "sandbox max_concurrency must be between 1 and 32"
    end

    children = [
      {Registry, providers: providers, bodies: bodies},
      %{
        id: Insider.Sentinel.Sandbox.RunSupervisor,
        start:
          {DynamicSupervisor, :start_link, [[strategy: :one_for_one, max_children: concurrency]]},
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @spec start_run(Supervisor.supervisor(), Target.t(), keyword()) ::
          {:ok, handle()} | {:error, Error.t()}
  def start_run(executor, target, options) do
    with {:ok, valid_target} <- Target.validate(target),
         true <- valid_options?(options),
         %Request{} = request <- Keyword.get(options, :request),
         %Context{} = context <- Keyword.get(options, :context),
         cleanup_timeout_ms
         when is_integer(cleanup_timeout_ms) and
                cleanup_timeout_ms in 1..@maximum_cleanup_timeout_ms <-
           Keyword.get(options, :cleanup_timeout_ms, @default_cleanup_timeout_ms),
         true <- request.operation == "verification.run",
         true <- request.params == %{"sandbox_target_id" => valid_target.id},
         true <- request.target == %{node: Atom.to_string(node())},
         {:ok, decision} <- Policy.authorize(request, context),
         true <- Policy.dispatchable?(decision),
         {:ok, registry, runs} <- components(executor),
         {:ok, provider} <- resolve_provider(registry, valid_target.provider),
         {:ok, body} <- resolve_body(registry, Keyword.get(options, :body)),
         true <- enough_budget?(decision, body, cleanup_timeout_ms) do
      token = make_ref()

      child =
        {Insider.Sentinel.Sandbox.Runner,
         %{
           caller: self(),
           body: body,
           cleanup_timeout_ms: cleanup_timeout_ms,
           context: context,
           decision: decision,
           provider: provider,
           registry: registry,
           request: request,
           target: valid_target,
           token: token
         }}

      runs
      |> DynamicSupervisor.start_child(child)
      |> admission_result(token)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> denied()
    end
  rescue
    _error -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  @spec run(Supervisor.supervisor(), Target.t(), keyword()) ::
          Insider.Protocol.Result.t() | {:error, Error.t()}
  def run(executor, target, options) do
    with {:ok, handle} <- start_run(executor, target, options) do
      request = Keyword.fetch!(options, :request)
      await(handle, request.timeout_ms + 1_000)
    end
  end

  @spec await(handle(), timeout()) :: Insider.Protocol.Result.t() | {:error, Error.t()}
  def await(%{pid: pid, token: token}, timeout)
      when is_pid(pid) and is_reference(token) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    monitor = Process.monitor(pid)

    receive do
      {^token, %Insider.Protocol.Result{} = result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        unavailable()
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, Error.new(:deadline_exceeded, "sandbox await timed out")}
    end
  end

  def await(_handle, _timeout), do: invalid_handle()

  @spec cancel(handle(), timeout()) :: :ok | {:error, Error.t()}
  def cancel(handle, timeout \\ 1_000)

  def cancel(%{pid: pid, token: token}, timeout)
      when is_pid(pid) and is_reference(token) and is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, {:cancel, token}, timeout)
  catch
    :exit, _reason -> unavailable()
  end

  def cancel(_handle, _timeout), do: invalid_handle()

  @spec counts(Supervisor.supervisor()) ::
          {:ok, %{active: non_neg_integer(), quarantined: non_neg_integer()}}
          | {:error, Error.t()}
  def counts(executor) do
    with {:ok, registry, _runs} <- components(executor), do: {:ok, Registry.counts(registry)}
  catch
    :exit, _reason -> unavailable()
  end

  defp components(executor) do
    children = Supervisor.which_children(executor)

    with {Registry, registry, :worker, _modules} when is_pid(registry) <-
           List.keyfind(children, Registry, 0),
         {Insider.Sentinel.Sandbox.RunSupervisor, runs, :supervisor, _modules}
         when is_pid(runs) <-
           List.keyfind(children, Insider.Sentinel.Sandbox.RunSupervisor, 0) do
      {:ok, registry, runs}
    else
      _other -> {:error, Error.new(:operation_failed, "sandbox executor is unavailable")}
    end
  end

  defp resolve_provider(registry, identity) do
    case Registry.resolve(registry, identity) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, Error.new(:sandbox_provider_mismatch, "sandbox provider is not allowed")}
    end
  end

  defp resolve_body(_registry, nil), do: {:ok, nil}

  defp resolve_body(registry, {module, input}) when is_atom(module) and is_map(input),
    do: resolve_body(registry, {module, input, @default_body_stop_timeout_ms})

  defp resolve_body(registry, {module, input, stop_timeout_ms})
       when is_atom(module) and is_map(input) and is_integer(stop_timeout_ms) and
              stop_timeout_ms in 1..@maximum_body_stop_timeout_ms do
    with true <- Insider.Protocol.Value.bounded_data?(input, @maximum_body_input_bytes),
         {:ok, identity} <- Registry.allow_body(registry, module) do
      {:ok,
       %{
         identity: identity,
         input: input,
         module: module,
         stop_timeout_ms: stop_timeout_ms
       }}
    else
      _other -> {:error, Error.new(:sandbox_body_mismatch, "sandbox body is not allowed")}
    end
  end

  defp resolve_body(_registry, _body),
    do: {:error, Error.new(:sandbox_body_mismatch, "sandbox body is not allowed")}

  defp enough_budget?(decision, body, cleanup_timeout_ms) do
    required_events = if is_nil(body), do: 2, else: 3

    body_stop_timeout_ms =
      case body do
        %{stop_timeout_ms: timeout} -> timeout
        nil -> 0
      end

    decision.effective_limits.max_events >= required_events and
      decision.effective_limits.max_bytes >= @minimum_result_bytes and
      decision.dispatch_deadline_monotonic - System.monotonic_time(:millisecond) >
        cleanup_timeout_ms + body_stop_timeout_ms
  end

  defp admission_result({:ok, pid}, token), do: {:ok, %{pid: pid, token: token}}
  defp admission_result({:error, :max_children}, _token), do: overloaded()
  defp admission_result({:error, {:max_children, _detail}}, _token), do: overloaded()
  defp admission_result({:error, _reason}, _token), do: unavailable()

  defp valid_options?(options) do
    with true <- Insider.Protocol.Value.bounded_list?(options, length(@option_keys) + 1),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options) do
      required = [:request, :context]

      keys -- @option_keys == [] and Enum.uniq(keys) == keys and
        Enum.all?(required, &Keyword.has_key?(options, &1))
    else
      _other -> false
    end
  end

  defp denied,
    do: {:error, Error.new(:policy_denied, "sandbox execution is not authorized")}

  defp overloaded,
    do:
      {:error,
       Error.new(:operation_failed, "sandbox executor is at capacity", %{}, retryable: true)}

  defp unavailable,
    do: {:error, Error.new(:operation_failed, "sandbox executor is unavailable")}

  defp invalid_handle,
    do: {:error, Error.new(:invalid_request, "sandbox handle is invalid")}
end
