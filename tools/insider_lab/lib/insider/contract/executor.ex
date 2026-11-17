defmodule Insider.Contract.Executor do
  @moduledoc """
  A fixed-capacity supervisor for failure-isolated contract callbacks.

  Excess invocations are shed instead of queued as callback work.
  """

  use DynamicSupervisor

  @default_concurrency 8
  @maximum_concurrency 64

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
      raise ArgumentError, "contract max_concurrency must be between 1 and 64"
    end

    DynamicSupervisor.init(strategy: :one_for_one, max_children: concurrency)
  end

  @doc false
  @spec admit(Supervisor.supervisor(), map()) :: DynamicSupervisor.on_start_child()
  def admit(executor, invocation),
    do: DynamicSupervisor.start_child(executor, {Insider.Contract.Runner, invocation})

  @doc false
  @spec release(Supervisor.supervisor(), pid(), non_neg_integer()) :: :ok | {:error, term()}
  def release(executor, runner, timeout_ms)
      when is_pid(runner) and is_integer(timeout_ms) and timeout_ms >= 0 do
    task = Task.async(fn -> terminate_child(executor, runner) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :release_timeout}
    end
  end

  defp terminate_child(executor, runner) do
    case DynamicSupervisor.terminate_child(executor, runner) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
