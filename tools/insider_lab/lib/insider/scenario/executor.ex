defmodule Insider.Scenario.Executor do
  @moduledoc """
  Fixed-capacity admission for supervised scenario runs.

  `cancel/1` stops future scenario work and asks the runner to perform its
  declared cleanup reset. It never represents cancellation as rollback.
  """

  use DynamicSupervisor

  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Scenario

  @default_concurrency 4
  @maximum_concurrency 32
  @minimum_result_bytes 65_536
  @option_keys [:request, :context, :contract_executor]

  @type handle :: %{pid: pid(), token: reference()}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    supervisor_options = if name, do: [name: name], else: []
    DynamicSupervisor.start_link(__MODULE__, options, supervisor_options)
  end

  @impl true
  def init(options) do
    concurrency = Keyword.get(options, :max_concurrency, @default_concurrency)

    unless is_integer(concurrency) and concurrency in 1..@maximum_concurrency do
      raise ArgumentError, "scenario max_concurrency must be between 1 and 32"
    end

    DynamicSupervisor.init(strategy: :one_for_one, max_children: concurrency)
  end

  @spec start_run(Supervisor.supervisor(), Scenario.t(), [module()], keyword()) ::
          {:ok, handle()} | {:error, Error.t()}
  def start_run(executor, scenario, modules, options) do
    with {:ok, valid} <- Scenario.validate(scenario),
         true <- valid_options?(options),
         %Request{} = request <- Keyword.get(options, :request),
         %Context{} = context <- Keyword.get(options, :context),
         true <- request.operation == "scenario.run",
         true <- request.params == %{"scenario_id" => valid.id},
         true <- request.target == %{node: Atom.to_string(node())},
         {:ok, decision} <- Policy.authorize(request, context),
         {:ok, module} <- Scenario.resolve(valid, modules, context.environment),
         true <- enough_budget?(valid, decision),
         contract_executor <- Keyword.get(options, :contract_executor, Insider.Contract.Executor),
         true <- valid_contract_executor?(contract_executor) do
      token = make_ref()

      child =
        {Insider.Scenario.Runner,
         %{
           caller: self(),
           token: token,
           scenario: valid,
           module: module,
           request: request,
           context: context,
           decision: decision,
           contract_executor: contract_executor
         }}

      case DynamicSupervisor.start_child(executor, child) do
        {:ok, pid} -> {:ok, %{pid: pid, token: token}}
        {:error, :max_children} -> overloaded()
        {:error, {:max_children, _detail}} -> overloaded()
        {:error, _reason} -> unavailable()
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> denied()
    end
  rescue
    _error -> unavailable()
  catch
    :exit, _reason -> unavailable()
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
        {:error, Error.new(:deadline_exceeded, "scenario await timed out")}
    end
  end

  def await(_handle, _timeout), do: invalid_handle()

  @spec cancel(handle()) :: :ok | {:error, Error.t()}
  def cancel(%{pid: pid, token: token}) when is_pid(pid) and is_reference(token) do
    send(pid, {:cancel_scenario, token})
    :ok
  end

  def cancel(_handle), do: invalid_handle()

  @spec run(Supervisor.supervisor(), Scenario.t(), [module()], keyword()) ::
          Insider.Protocol.Result.t() | {:error, Error.t()}
  def run(executor, scenario, modules, options) do
    with {:ok, valid} <- Scenario.validate(scenario),
         {:ok, handle} <- start_run(executor, valid, modules, options) do
      await(handle, valid.limits["max_duration_ms"] + 1_000)
    end
  end

  defp enough_budget?(scenario, decision) do
    required_events = length(scenario.steps) + 2

    decision.effective_limits.max_events >= required_events and
      decision.effective_limits.max_bytes >= @minimum_result_bytes and
      decision.dispatch_deadline_monotonic - System.monotonic_time(:millisecond) >
        scenario.limits["cleanup_timeout_ms"]
  end

  defp valid_options?(options) do
    with true <- Insider.Protocol.Value.bounded_list?(options, length(@option_keys)),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options) do
      keys -- @option_keys == [] and Enum.uniq(keys) == keys and
        Enum.all?([:request, :context], &Keyword.has_key?(options, &1))
    else
      _other -> false
    end
  end

  defp valid_contract_executor?(value), do: is_atom(value) or is_pid(value)

  defp denied,
    do: {:error, Error.new(:policy_denied, "scenario execution is not authorized")}

  defp overloaded,
    do:
      {:error,
       Error.new(:operation_failed, "scenario executor is at capacity", %{}, retryable: true)}

  defp unavailable,
    do: {:error, Error.new(:operation_failed, "scenario executor is unavailable")}

  defp invalid_handle,
    do: {:error, Error.new(:invalid_request, "scenario handle is invalid")}
end
