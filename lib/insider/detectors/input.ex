defmodule Insider.Detectors.Input do
  @moduledoc false

  alias Insider.Event

  @spec event_id(term()) :: String.t() | nil
  def event_id(%Event{id: id}) when is_binary(id) and byte_size(id) in 1..128,
    do: if(String.valid?(id), do: id, else: nil)

  def event_id(_event), do: nil

  @doc false
  @spec bounded_id?(term()) :: boolean()
  def bounded_id?(value), do: bounded_string?(value, 128)

  @doc false
  @spec bounded_string?(term(), pos_integer()) :: boolean()
  def bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  @doc false
  @spec digest?(term()) :: boolean()
  def digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  @doc false
  @spec canonical_pid?(term()) :: boolean()
  def canonical_pid?(value) when is_binary(value) and byte_size(value) <= 128 do
    value
    |> String.to_charlist()
    |> :erlang.list_to_pid()
    |> :erlang.pid_to_list()
    |> to_string()
    |> Kernel.==(value)
  rescue
    _error -> false
  end

  def canonical_pid?(_value), do: false

  @doc false
  @spec cycle_sequence(term()) :: {:ok, pos_integer()} | {:error, :invalid_cycle}
  def cycle_sequence(value) when is_binary(value) and byte_size(value) in 1..16 do
    case Integer.parse(value, 36) do
      {sequence, ""} when sequence >= 1 ->
        if Integer.to_string(sequence, 36) == value,
          do: {:ok, sequence},
          else: {:error, :invalid_cycle}

      _other ->
        {:error, :invalid_cycle}
    end
  end

  def cycle_sequence(_value), do: {:error, :invalid_cycle}
end
