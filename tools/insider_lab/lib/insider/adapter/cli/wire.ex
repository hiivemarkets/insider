defmodule Insider.Adapter.CLI.Wire do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Result

  @spec encode_result(Result.t()) :: {:ok, binary()} | :error
  def encode_result(%Result{} = result) do
    result
    |> result_map()
    |> encode()
  rescue
    _error -> :error
  end

  @spec encode(map()) :: {:ok, binary()} | :error
  def encode(value) do
    with {:ok, portable} <- portable(value) do
      {:ok, Canonical.encode(portable)}
    end
  rescue
    _error -> :error
  end

  defp result_map(result) do
    result
    |> Map.from_struct()
    |> Map.update!(:error, &error_map/1)
    |> Map.update!(:effects, &Enum.map(&1, fn effect -> Map.from_struct(effect) end))
  end

  defp error_map(nil), do: nil
  defp error_map(%Error{} = error), do: Map.from_struct(error)

  defp portable(value) when is_nil(value) or is_boolean(value) or is_integer(value),
    do: {:ok, value}

  defp portable(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact])
    {:ok, value}
  rescue
    _error -> :error
  end

  defp portable(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp portable(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp portable(value) when is_tuple(value), do: value |> Tuple.to_list() |> portable()

  defp portable(value) when is_list(value), do: portable_list(value, [])

  defp portable(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, output} ->
      with {:ok, key} <- portable_key(key),
           false <- Map.has_key?(output, key),
           {:ok, item} <- portable(item) do
        {:cont, {:ok, Map.put(output, key, item)}}
      else
        _error -> {:halt, :error}
      end
    end)
  end

  defp portable(%Effect{} = effect), do: effect |> Map.from_struct() |> portable()
  defp portable(%Error{} = error), do: error |> Map.from_struct() |> portable()
  defp portable(_value), do: :error

  defp portable_list([], output), do: {:ok, Enum.reverse(output)}

  defp portable_list([head | tail], output) do
    case portable(head) do
      {:ok, item} -> portable_list(tail, [item | output])
      :error -> :error
    end
  end

  defp portable_list(_improper, _output), do: :error

  defp portable_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp portable_key(_key), do: :error
end
