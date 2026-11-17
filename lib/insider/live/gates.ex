defmodule Insider.Live.Gates do
  @moduledoc false

  # The cleanup owner of live record-time gates (`Insider.Collector.Gate`).
  #
  # A gate is a `:persistent_term` entry plus, with summaries, an ETS table,
  # and neither is released when the process that asked for it dies. This
  # keeper creates every live gate, owns its summary table, monitors the
  # process the gate was created for, and erases the gate when that process
  # goes down: after an owner kill, a supervisor restart, or a start that was
  # interrupted between creating the gate and starting collection. It is
  # bounded: at most `max_gates/0` gates exist at once.
  #
  # The live owner releases a gate when its session ends, and a restarted
  # owner calls `reclaim/0` before it accepts a call, so a gate never
  # outlives the owner that created it. Creation carries a deadline and a
  # request reference: a request handled after its deadline creates
  # nothing, and a caller whose call timed out sends `{:abort, reference}`
  # right after it, which erases whatever that request created. Messages
  # from one process arrive in order, so the abort is always handled after
  # its request.
  #
  # The owner is each summary table's heir. If this keeper dies, the tables
  # pass to the owners, summaries keep working, and the restarted keeper
  # adopts the gates of creators that are still alive and erases the rest.
  #
  # It starts with the live owner under `Insider.Supervisor`, before it.

  use GenServer

  alias Insider.Collector.Gate

  @max_gates 8
  @call_timeout_ms 1_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_options \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The most gates that may exist at once."
  @spec max_gates() :: pos_integer()
  def max_gates, do: @max_gates

  @doc """
  Creates a gate for the calling process within `timeout_ms`. A creation the
  keeper handles too late creates nothing, and a timed-out one is aborted.
  With `exclusive: true` (the live owner, which holds at most one gate), the
  caller's earlier gates are erased first, so a gate whose release or abort
  never reached the keeper is reclaimed by the next start.
  """
  @spec create(Gate.spec(), pos_integer(), keyword()) ::
          {:ok, Gate.key()} | {:error, :busy | :invalid | :timeout | :unavailable}
  def create(spec, timeout_ms \\ @call_timeout_ms, options \\ []) do
    reference = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    exclusive = Keyword.get(options, :exclusive, false)

    case call({:create, spec, reference, deadline, exclusive}, timeout_ms) do
      {:error, :timeout} ->
        GenServer.cast(__MODULE__, {:abort, reference})
        {:error, :timeout}

      result ->
        result
    end
  end

  @doc """
  Erases a gate. Releasing an unknown gate succeeds. A release the keeper
  does not answer is completed by the owner's next `reclaim/0`.
  """
  @spec release(Gate.key()) :: :ok
  def release(key) do
    _released = call({:release, key})
    :ok
  end

  @doc """
  Erases every gate of the calling process and every gate whose creator is
  no longer alive. The live owner calls it whenever it holds no gate: when
  it starts, and before it creates a session's gate, so a gate whose release
  or abort never reached the keeper is reclaimed then.
  """
  @spec reclaim() :: :ok
  def reclaim do
    _reclaimed = call(:reclaim)
    :ok
  end

  @doc "The number of gates held, after reclaiming those of dead creators."
  @spec count() :: non_neg_integer()
  def count do
    case call(:count) do
      count when is_integer(count) -> count
      {:error, _reason} -> 0
    end
  end

  @impl GenServer
  def init(:ok) do
    gates =
      Enum.reduce(Gate.all(), %{}, fn {key, owner}, gates ->
        if is_pid(owner) and Process.alive?(owner) do
          Map.put(gates, key, {owner, Process.monitor(owner), nil})
        else
          Gate.delete(key)
          gates
        end
      end)

    {:ok, gates}
  end

  @impl GenServer
  def handle_call({:create, spec, reference, deadline, exclusive}, {caller, _tag}, gates) do
    gates = if exclusive, do: erase_held(gates, caller), else: gates
    gates = reclaim_dead(gates)

    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :timeout}, gates}

      not valid_spec?(spec) ->
        {:reply, {:error, :invalid}, gates}

      map_size(gates) >= @max_gates ->
        {:reply, {:error, :busy}, gates}

      true ->
        key = Gate.new(spec, caller)
        {:reply, {:ok, key}, Map.put(gates, key, {caller, Process.monitor(caller), reference})}
    end
  end

  def handle_call({:release, key}, _from, gates), do: {:reply, :ok, erase(gates, key)}

  def handle_call(:reclaim, {caller, _tag}, gates),
    do: {:reply, :ok, gates |> erase_held(caller) |> reclaim_dead()}

  def handle_call(:count, _from, gates) do
    gates = reclaim_dead(gates)
    {:reply, map_size(gates), gates}
  end

  defp erase_held(gates, caller) do
    held = for {key, {^caller, _monitor, _reference}} <- gates, do: key
    Enum.reduce(held, gates, &erase(&2, &1))
  end

  @impl GenServer
  def handle_cast({:abort, reference}, gates) do
    aborted = for {key, {_owner, _monitor, ^reference}} <- gates, do: key
    {:noreply, Enum.reduce(aborted, gates, &erase(&2, &1))}
  end

  @impl GenServer
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, gates) do
    owned = for {key, {^pid, _monitor, _reference}} <- gates, do: key
    {:noreply, Enum.reduce(owned, gates, &erase(&2, &1))}
  end

  def handle_info(_message, gates), do: {:noreply, gates}

  # A creator's `DOWN` may still be queued behind this call; liveness is
  # checked directly so a caller never sees a dead creator's gate.
  defp reclaim_dead(gates) do
    dead = for {key, {owner, _monitor, _ref}} <- gates, not Process.alive?(owner), do: key
    Enum.reduce(dead, gates, &erase(&2, &1))
  end

  defp erase(gates, key) do
    case Map.pop(gates, key) do
      {nil, gates} ->
        gates

      {{_owner, monitor, _reference}, gates} ->
        Process.demonitor(monitor, [:flush])
        Gate.delete(key)
        gates
    end
  end

  defp valid_spec?(
         %{
           logger: logger,
           origin: origin,
           telemetry: telemetry,
           summary_interval_ms: interval
         } = spec
       )
       when is_list(telemetry) and is_integer(interval) and interval > 0 do
    valid_logger?(logger) and valid_origin?(origin) and Enum.all?(telemetry, &valid_rule?/1) and
      valid_otel?(Map.get(spec, :otel))
  end

  defp valid_spec?(_spec), do: false

  defp valid_otel?(nil), do: true
  defp valid_otel?(%{min_duration_ms: min}) when is_integer(min) and min >= 0, do: true
  defp valid_otel?(_otel), do: false

  defp valid_logger?(nil), do: true

  defp valid_logger?(%{
         level: level,
         include: include,
         exclude: exclude,
         summary: summary,
         summary_interval_ms: interval
       }),
       do:
         level in ~w(emergency alert critical error warning notice info debug)a and
           valid_matcher?(include) and valid_matcher?(exclude) and valid_matcher?(summary) and
           is_integer(interval) and interval > 0

  defp valid_logger?(_logger), do: false

  defp valid_matcher?(nil), do: true

  defp valid_matcher?(%{domains: domains, applications: applications, modules: modules}),
    do: is_list(domains) and is_map(applications) and is_map(modules)

  defp valid_matcher?(_matcher), do: false

  defp valid_origin?(nil), do: true

  defp valid_origin?(%{oban_conf: oban_conf, modules: modules}),
    do: is_boolean(oban_conf) and is_map(modules)

  defp valid_origin?(_origin), do: false

  # A rule declares its duration scope only when it is summarised.
  defp valid_rule?(
         %{name: [_ | _] = name, kind: kind, min_duration_ms: min, summary: summary} = rule
       ),
       do:
         Enum.all?(name, &is_atom/1) and is_binary(kind) and is_integer(min) and min >= 0 and
           is_boolean(summary) and
           valid_duration_scope?(Map.get(rule, :duration_scope), summary)

  defp valid_rule?(_rule), do: false

  defp valid_duration_scope?(nil, _summary), do: true
  defp valid_duration_scope?(scope, true), do: scope in ["handler", "caller"]
  defp valid_duration_scope?(_scope, false), do: false

  defp call(request, timeout_ms \\ @call_timeout_ms) do
    GenServer.call(__MODULE__, request, timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end
end
