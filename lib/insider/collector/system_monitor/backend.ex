defmodule Insider.Collector.SystemMonitor.Backend do
  @moduledoc false

  alias Insider.Collector.SystemMonitor.Policy
  alias Insider.Policy.Context

  @legacy_lock {__MODULE__, :node_global, node()}
  @isolated_provider "erts.trace.system"
  @legacy_provider "erlang.system_monitor"
  @safe_environments [:development, :test, :ci]

  @spec start(Policy.t(), Context.t(), pid(), :ets.tid()) ::
          {:ok, map()} | {:error, atom()}
  def start(%Policy{} = policy, %Context{} = context, receiver, ownership) do
    case mode_for(otp_release(), policy, context) do
      {:ok, :isolated} -> start_isolated(policy, receiver, ownership)
      {:ok, :legacy_node_global} -> start_legacy(policy, receiver, ownership)
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :backend_unavailable}
  catch
    _kind, _reason -> {:error, :backend_unavailable}
  end

  @doc false
  @spec start_for_release(binary(), Policy.t(), Context.t(), pid(), :ets.tid()) ::
          {:ok, map()} | {:error, atom()}
  def start_for_release(release, %Policy{} = policy, %Context{} = context, receiver, ownership) do
    case mode_for(release, policy, context) do
      {:ok, :isolated} -> start_isolated(policy, receiver, ownership)
      {:ok, :legacy_node_global} -> start_legacy(policy, receiver, ownership)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec mode_for(binary(), Policy.t(), Context.t()) ::
          {:ok, :isolated | :legacy_node_global} | {:error, atom()}
  def mode_for(release, %Policy{} = policy, %Context{} = context) do
    with true <- Policy.valid?(policy),
         true <- Context.valid?(context),
         true <- context.environment in @safe_environments do
      select_mode(parse_release(release), policy, context)
    else
      _failure -> {:error, :runtime_context_denied}
    end
  end

  @spec disable(map()) :: atom()
  def disable(%{mode: :isolated, session: session}) do
    if :trace.session_destroy(session), do: :destroyed, else: :already_destroyed
  rescue
    _error -> :cleanup_unknown
  catch
    _kind, _reason -> :cleanup_unknown
  end

  def disable(%{mode: :legacy_node_global}), do: :receiver_termination_required

  @spec observe_legacy_release(map()) :: atom()
  def observe_legacy_release(%{mode: :legacy_node_global, receiver: receiver}) do
    case :erlang.system_monitor() do
      :undefined -> :released_or_absent
      {^receiver, _options} -> :cleanup_unknown
      {_other, _options} -> :foreign_preserved
    end
  rescue
    _error -> :cleanup_unknown
  catch
    _kind, _reason -> :cleanup_unknown
  end

  @spec delivery_reference(:ets.tid()) :: {:ok, reference()} | :unsupported
  def delivery_reference(ownership) do
    case :ets.lookup(ownership, :backend) do
      [{:backend, %{mode: :isolated, session: session}}] ->
        {:ok, :trace.delivered(session, :all)}

      _rows ->
        :unsupported
    end
  rescue
    _error -> :unsupported
  catch
    _kind, _reason -> :unsupported
  end

  defp start_isolated(policy, receiver, ownership) do
    session = :trace.session_create(:insider_system_monitor, receiver, [])

    backend = %{
      mode: :isolated,
      receiver: receiver,
      session: session,
      requested_options: policy.events,
      effective_options: []
    }

    try do
      true = :ets.insert(ownership, {:backend, backend})

      Enum.each(policy.events, fn {event, value} -> :ok = trace_system(session, event, value) end)

      {:system, effective} = trace_system_info(session)
      backend = %{backend | effective_options: effective}
      true = :ets.insert(ownership, {:backend, backend})
      {:ok, backend}
    rescue
      _error ->
        _destroyed = :trace.session_destroy(session)
        {:error, :backend_unavailable}
    catch
      _kind, _reason ->
        _destroyed = :trace.session_destroy(session)
        {:error, :backend_unavailable}
    end
  end

  defp start_legacy(policy, receiver, ownership) do
    case :global.trans(
           {@legacy_lock, self()},
           fn -> install_legacy(policy, receiver, ownership) end,
           [node()],
           0
         ) do
      :aborted -> {:error, :install_contended}
      result -> result
    end
  end

  defp install_legacy(policy, receiver, ownership) do
    case :erlang.system_monitor() do
      :undefined ->
        requested = legacy_options(policy.events)

        case :erlang.system_monitor(receiver, requested) do
          :undefined ->
            {^receiver, effective} = :erlang.system_monitor()

            backend = %{
              mode: :legacy_node_global,
              receiver: receiver,
              requested_options: policy.events,
              effective_options: effective
            }

            true = :ets.insert(ownership, {:backend, backend})
            {:ok, backend}

          previous ->
            restoration = restore_install_race(receiver, previous)
            true = :ets.insert(ownership, {:legacy_install_race, restoration})
            {:error, :legacy_install_race}
        end

      {_pid, _options} ->
        {:error, :system_monitor_conflict}
    end
  end

  defp legacy_options(events) do
    Enum.map(events, fn
      {event, true} -> event
      event -> event
    end)
  end

  defp restore_install_race(receiver, previous) do
    case :erlang.system_monitor() do
      {^receiver, _options} ->
        _displaced = :erlang.system_monitor(previous)
        :restoration_attempted

      {_other, _options} ->
        :interference_preserved

      :undefined ->
        :cleanup_unknown
    end
  rescue
    _error -> :cleanup_unknown
  catch
    _kind, _reason -> :cleanup_unknown
  end

  defp select_mode(release, _policy, context) when release in [28, 29] do
    if feature?(context, @isolated_provider, :session_local),
      do: {:ok, :isolated},
      else: {:error, :runtime_context_denied}
  end

  defp select_mode(27, %{legacy_node_global: true}, %{target_class: :disposable} = context) do
    if feature?(context, @legacy_provider, :node_global),
      do: {:ok, :legacy_node_global},
      else: {:error, :runtime_context_denied}
  end

  defp select_mode(27, %{legacy_node_global: true}, _context),
    do: {:error, :runtime_context_denied}

  defp select_mode(27, _policy, _context), do: {:error, :legacy_capability_required}
  defp select_mode(_release, _policy, _context), do: {:error, :unsupported_otp}

  defp feature?(context, provider, isolation) do
    Map.get(context.features, "events.subscribe") == %{
      available: true,
      provider: provider,
      isolation: isolation
    }
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> to_string()

  # OTP 28-29 support the :system tracee even though OTP 29's published
  # Dialyzer type for trace:info/3 omits it.
  defp trace_system(session, event, value),
    do: :erlang.apply(:trace, :system, [session, event, value])

  defp trace_system_info(session),
    do: :erlang.apply(:trace, :info, [session, :system, :all])

  defp parse_release(release) when is_binary(release) do
    case Integer.parse(release) do
      {value, ""} -> value
      _other -> nil
    end
  end
end
