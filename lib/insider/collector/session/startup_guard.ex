defmodule Insider.Collector.Session.StartupGuard do
  @moduledoc false

  @opaque t :: %__MODULE__{table: :ets.tid()}

  defstruct [:table]

  @spec new() :: t()
  def new, do: %__MODULE__{table: :ets.new(__MODULE__, [:set, :protected])}

  @spec authorize(t(), reference(), integer()) :: :ok
  def authorize(%__MODULE__{table: table}, token, deadline) do
    true = :ets.insert(table, {token, deadline})
    :ok
  end

  @spec authorized?(term(), term(), integer()) :: boolean()
  def authorized?(%__MODULE__{table: table}, token, now) when is_reference(token) do
    case :ets.lookup(table, token) do
      [{^token, deadline}] when is_integer(deadline) -> now < deadline
      _other -> false
    end
  rescue
    _error -> false
  end

  def authorized?(_guard, _token, _now), do: false

  @spec revoke(t(), reference()) :: :ok
  def revoke(%__MODULE__{table: table}, token) do
    :ets.delete(table, token)
    :ok
  rescue
    _error -> :ok
  end
end
