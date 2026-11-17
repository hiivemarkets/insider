defmodule Insider.Protocol.Effect do
  @moduledoc """
  An observed runtime effect, including incomplete or uncertain effects.
  """

  @statuses [:observed, :partial, :unknown]

  @enforce_keys [:kind, :target, :status]
  defstruct [:kind, :target, :status, details: %{}]

  @type status :: :observed | :partial | :unknown
  @type t :: %__MODULE__{kind: atom(), target: String.t(), status: status(), details: map()}

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(kind, target, options \\ []) when is_atom(kind) and is_binary(target) do
    status = Keyword.get(options, :status, :observed)
    details = Keyword.get(options, :details, %{})

    effect = %__MODULE__{kind: kind, target: target, status: status, details: details}

    if valid?(effect), do: effect, else: raise(ArgumentError, "invalid effect")
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{kind: kind, target: target, status: status, details: details}) do
    is_atom(kind) and is_binary(target) and byte_size(target) in 1..256 and
      status in @statuses and is_map(details) and
      Insider.Protocol.Value.bounded_data?(details, 4_096)
  end

  def valid?(_value), do: false
end
