defmodule Insider.Sentinel.Sandbox.CleanupOwnership do
  @moduledoc false

  use GenServer

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, :ok)

  @spec authorize(pid(), reference(), pid(), timeout()) :: :ok | :error
  def authorize(server, key, job, timeout),
    do: call(server, {:authorize_many, [{key, job}]}, timeout)

  @spec authorize_many(pid(), [{reference(), pid()}], timeout()) :: :ok | :error
  def authorize_many(server, owners, timeout),
    do: call(server, {:authorize_many, owners}, timeout)

  @spec register(pid(), reference(), pid(), timeout()) :: :ok | :error
  def register(server, key, provider, timeout),
    do: call(server, {:register, key, provider}, timeout)

  @spec unregister(pid(), reference(), pid(), timeout()) :: :ok | :error
  def unregister(server, key, provider, timeout),
    do: call(server, {:unregister, key, provider}, timeout)

  @spec active(pid(), [reference()], timeout()) :: {:ok, [pid()]} | :error
  def active(server, keys, timeout) do
    case call(server, {:active, keys}, timeout) do
      providers when is_list(providers) -> {:ok, providers}
      :error -> :error
    end
  end

  @spec close_active(pid(), [reference()], timeout()) :: {:ok, [pid()]} | :error
  def close_active(server, keys, timeout) do
    case call(server, {:close_active, keys}, timeout) do
      providers when is_list(providers) -> {:ok, providers}
      :error -> :error
    end
  end

  @spec close_all_active(pid(), timeout()) :: {:ok, [pid()]} | :error
  def close_all_active(server, timeout) do
    case call(server, :close_all_active, timeout) do
      providers when is_list(providers) -> {:ok, providers}
      :error -> :error
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{owners: %{}}}

  @impl true
  def handle_call({:authorize_many, owners}, _from, state) do
    valid =
      is_list(owners) and
        Enum.all?(owners, fn
          {key, job} ->
            is_reference(key) and is_pid(job) and not Map.has_key?(state.owners, key)

          _malformed ->
            false
        end) and
        owners |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(owners)

    if valid do
      updated =
        Enum.reduce(owners, state, fn {key, job}, accumulated ->
          owner = %{closed: false, job: job, job_monitor: Process.monitor(job), provider: nil}
          put_in(accumulated, [:owners, key], owner)
        end)

      {:reply, :ok, updated}
    else
      {:reply, :error, state}
    end
  end

  def handle_call({:register, key, provider}, {job, _tag}, state) when is_pid(provider) do
    case Map.fetch(state.owners, key) do
      {:ok, %{closed: false, job: ^job, provider: nil} = owner} ->
        provider_state = %{monitor: Process.monitor(provider), pid: provider}
        {:reply, :ok, put_in(state, [:owners, key], %{owner | provider: provider_state})}

      _unauthorized_or_active ->
        {:reply, :error, state}
    end
  end

  def handle_call({:register, _key, _provider}, _from, state), do: {:reply, :error, state}

  def handle_call({:unregister, key, provider}, {job, _tag}, state) do
    case Map.fetch(state.owners, key) do
      {:ok, %{job: ^job, provider: %{pid: ^provider} = active} = owner} ->
        Process.demonitor(active.monitor, [:flush])
        {:reply, :ok, update_owner(state, key, %{owner | provider: nil})}

      _missing_or_stale ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:active, keys}, _from, state) do
    providers =
      keys
      |> Enum.flat_map(fn key ->
        case Map.get(state.owners, key) do
          %{provider: %{pid: pid}} -> [pid]
          _missing_or_inactive -> []
        end
      end)
      |> Enum.uniq()

    {:reply, providers, state}
  end

  def handle_call({:close_active, keys}, _from, state) do
    if is_list(keys) and Enum.all?(keys, &is_reference/1) do
      {providers, owners} = close_owners(keys, state.owners)
      {:reply, Enum.uniq(providers), %{state | owners: owners}}
    else
      {:reply, :error, state}
    end
  end

  def handle_call(:close_all_active, _from, state) do
    {providers, owners} = close_owners(Map.keys(state.owners), state.owners)
    {:reply, Enum.uniq(providers), %{state | owners: owners}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    {:noreply, remove_down(state, monitor, pid)}
  end

  defp remove_down(state, monitor, pid) do
    Enum.reduce(state.owners, state, fn {key, owner}, accumulated ->
      cond do
        owner.job_monitor == monitor and owner.job == pid ->
          update_owner(accumulated, key, %{owner | job: nil, job_monitor: nil})

        match?(%{monitor: ^monitor, pid: ^pid}, owner.provider) ->
          update_owner(accumulated, key, %{owner | provider: nil})

        true ->
          accumulated
      end
    end)
  end

  defp update_owner(state, key, %{job: nil, provider: nil}),
    do: %{state | owners: Map.delete(state.owners, key)}

  defp update_owner(state, key, owner), do: put_in(state, [:owners, key], owner)

  defp close_owners(keys, owners) do
    Enum.reduce(keys, {[], owners}, fn key, {providers, owners} ->
      case Map.fetch(owners, key) do
        {:ok, owner} ->
          providers =
            case owner.provider do
              %{pid: pid} -> [pid | providers]
              nil -> providers
            end

          {providers, Map.put(owners, key, %{owner | closed: true})}

        :error ->
          {providers, owners}
      end
    end)
  end

  defp call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> :error
  end
end
