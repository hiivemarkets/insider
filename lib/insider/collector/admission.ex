defmodule Insider.Collector.Admission do
  @moduledoc false

  @opaque t :: %__MODULE__{counter: :atomics.atomics_ref()}

  defstruct [:counter]

  @spec new() :: t()
  def new, do: %__MODULE__{counter: :atomics.new(1, [])}

  @spec acquire(t(), pos_integer()) :: :ok | :overloaded
  def acquire(%__MODULE__{counter: counter} = admission, limit)
      when is_integer(limit) and limit > 0 do
    count = :atomics.get(counter, 1)

    cond do
      count >= limit ->
        :overloaded

      :atomics.compare_exchange(counter, 1, count, count + 1) == :ok ->
        :ok

      true ->
        acquire(admission, limit)
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{counter: counter}) do
    count = :atomics.get(counter, 1)
    if count > 0, do: :atomics.add_get(counter, 1, -1), else: 0
    :ok
  rescue
    _error -> :ok
  end
end
