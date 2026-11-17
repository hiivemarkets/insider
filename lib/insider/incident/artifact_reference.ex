defmodule Insider.Incident.ArtifactReference do
  @moduledoc """
  A bounded content-addressed reference to evidence kept outside a capsule.

  References contain no path, URL, credentials, or inline bytes. Offline capsule
  validation proves the reference shape, not availability of the referenced
  content. A consumer verifies retrieved content against `sha256` and
  `byte_size` before use.
  """

  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @option_keys [:role, :media_type, :byte_size, :sha256]
  @wire_keys ["byte_size", "media_type", "role", "sha256"]
  @maximum_bytes 1_099_511_627_776

  @enforce_keys @option_keys
  defstruct @option_keys

  @type t :: %__MODULE__{
          role: String.t(),
          media_type: String.t(),
          byte_size: pos_integer(),
          sha256: String.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    if Value.bounded_list?(options, length(@option_keys)) and Keyword.keyword?(options) and
         Enum.sort(Keyword.keys(options)) == Enum.sort(@option_keys) do
      options |> then(&struct!(__MODULE__, &1)) |> validate()
    else
      invalid("artifact reference fields are missing, duplicated, or unknown", options)
    end
  rescue
    _error -> invalid("artifact reference construction failed", options)
  end

  def new(value), do: invalid("artifact reference fields must be a keyword list", value)

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = reference) do
    valid =
      exact_struct?(reference) and vocabulary?(reference.role) and
        media_type?(reference.media_type) and is_integer(reference.byte_size) and
        reference.byte_size in 1..@maximum_bytes and digest?(reference.sha256)

    if valid,
      do: {:ok, reference},
      else: invalid("artifact reference is invalid or unbounded", reference)
  rescue
    _error -> invalid("artifact reference validation failed", reference)
  end

  def validate(value), do: invalid("value is not an artifact reference", value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(payload) when is_map(payload) and not is_struct(payload) do
    if map_size(payload) == length(@wire_keys) and Enum.sort(Map.keys(payload)) == @wire_keys do
      new(
        role: Map.get(payload, "role"),
        media_type: Map.get(payload, "media_type"),
        byte_size: Map.get(payload, "byte_size"),
        sha256: Map.get(payload, "sha256")
      )
    else
      invalid("artifact reference must contain the exact fields", payload)
    end
  rescue
    _error -> invalid("artifact reference decoding failed", payload)
  end

  def decode_map(payload), do: invalid("artifact reference must be an object", payload)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = reference) do
    %{
      "role" => reference.role,
      "media_type" => reference.media_type,
      "byte_size" => reference.byte_size,
      "sha256" => reference.sha256
    }
  end

  defp vocabulary?(value),
    do:
      bounded_string?(value, 128) and
        String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp media_type?(value),
    do:
      bounded_string?(value, 128) and
        String.match?(value, ~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/)

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp exact_struct?(reference),
    do:
      map_size(reference) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(reference)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp invalid(message, value) do
    {:error, Error.new(:invalid_artifact_reference, message, %{received: Value.summary(value)})}
  end
end
