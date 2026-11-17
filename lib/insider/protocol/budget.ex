defmodule Insider.Protocol.Budget do
  @moduledoc """
  Hard operation limits negotiated below library-owned ceilings.
  """

  alias Insider.Protocol.Error

  @defaults %{
    max_duration_ms: 5_000,
    max_events: 1_000,
    max_bytes: 1_048_576,
    max_targets: 1
  }

  @maximums %{
    max_duration_ms: 600_000,
    max_events: 100_000,
    max_bytes: 16_777_216,
    max_targets: 100
  }

  @minimums %{
    max_duration_ms: 1,
    max_events: 1,
    max_bytes: 16_384,
    max_targets: 1
  }

  @enforce_keys [:max_duration_ms, :max_events, :max_bytes, :max_targets]
  defstruct max_duration_ms: @defaults.max_duration_ms,
            max_events: @defaults.max_events,
            max_bytes: @defaults.max_bytes,
            max_targets: @defaults.max_targets

  @type field :: :max_duration_ms | :max_events | :max_bytes | :max_targets

  @type t :: %__MODULE__{
          max_duration_ms: pos_integer(),
          max_events: pos_integer(),
          max_bytes: pos_integer(),
          max_targets: pos_integer()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ [])

  def new(options) when is_list(options) or is_map(options) do
    with {:ok, attributes} <- attributes(options),
         :ok <- validate_fields(attributes),
         values = Map.merge(@defaults, attributes),
         :ok <- validate_values(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(value) do
    {:error,
     Error.new(:invalid_budget, "budget must be a keyword list or map", %{
       received: Insider.Protocol.Value.summary(value)
     })}
  end

  @spec maximum(field()) :: pos_integer()
  def maximum(field), do: Map.fetch!(@maximums, field)

  @spec minimum(field()) :: pos_integer()
  def minimum(field), do: Map.fetch!(@minimums, field)

  defp validate_fields(attributes) do
    case Map.keys(attributes) -- Map.keys(@defaults) do
      [] ->
        :ok

      unknown ->
        {:error,
         Error.new(:invalid_budget, "unknown budget fields", %{
           unknown_field_count: length(unknown)
         })}
    end
  end

  defp validate_values(values) do
    Enum.reduce_while(@maximums, :ok, fn {field, maximum}, :ok ->
      value = Map.fetch!(values, field)
      minimum = Map.fetch!(@minimums, field)

      if is_integer(value) and value >= minimum and value <= maximum do
        {:cont, :ok}
      else
        error =
          Error.new(:invalid_budget, "budget must be a positive integer within its hard limit", %{
            field: field,
            minimum: minimum,
            maximum: maximum,
            received: Insider.Protocol.Value.summary(value)
          })

        {:halt, {:error, error}}
      end
    end)
  end

  defp attributes(options) do
    {:ok, Map.new(options)}
  rescue
    _error ->
      {:error,
       Error.new(:invalid_budget, "budget contains invalid entries", %{
         received: Insider.Protocol.Value.summary(options)
       })}
  end
end
