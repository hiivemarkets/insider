defmodule Insider.Policy.Context do
  @moduledoc """
  Trusted runtime facts supplied outside the untrusted request envelope.
  """

  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @environments [:development, :test, :ci, :staging, :production]
  @target_classes [:host, :disposable]
  @option_keys [:environment, :actor, :target_class, :grants, :features, :deployment_limits]
  @max_grants 64

  @enforce_keys [:environment, :actor, :deployment_limits]
  defstruct [
    :environment,
    :actor,
    :deployment_limits,
    target_class: :host,
    grants: [],
    features: %{}
  ]

  @type t :: %__MODULE__{
          environment: atom(),
          actor: String.t(),
          deployment_limits: Budget.t(),
          target_class: :host | :disposable,
          grants: [Grant.t()],
          features: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- @option_keys == [] do
      build(options)
    else
      invalid("runtime context contains invalid fields", options)
    end
  end

  def new(value), do: invalid("runtime context must be a keyword list", value)

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = context) do
    context.environment in @environments and bounded_string?(context.actor) and
      context.target_class in @target_classes and valid_grants?(context.grants) and
      valid_features?(context.features) and valid_budget?(context.deployment_limits)
  end

  def valid?(_context), do: false

  defp build(options) do
    with {:ok, environment} <- environment(Keyword.get(options, :environment)),
         {:ok, actor} <- bounded_string(:actor, Keyword.get(options, :actor)),
         {:ok, target_class} <- target_class(Keyword.get(options, :target_class, :host)),
         {:ok, grants} <- grants(Keyword.get(options, :grants, [])),
         {:ok, features} <- features(Keyword.get(options, :features, %{})),
         {:ok, deployment_limits} <-
           Budget.new(Keyword.get(options, :deployment_limits, maximum_limits())) do
      {:ok,
       %__MODULE__{
         environment: environment,
         actor: actor,
         target_class: target_class,
         grants: grants,
         features: features,
         deployment_limits: deployment_limits
       }}
    end
  end

  defp environment(value) when value in @environments, do: {:ok, value}
  defp environment(value), do: invalid("configured environment is invalid", value)

  defp target_class(value) when value in @target_classes, do: {:ok, value}
  defp target_class(value), do: invalid("target class is invalid", value)

  defp grants(value) when is_list(value) do
    if valid_grants?(value),
      do: {:ok, value},
      else: invalid("grants are invalid or ambiguous", value)
  end

  defp grants(value), do: invalid("grants must be a list", value)

  defp features(value) when is_map(value) do
    if valid_features?(value),
      do: {:ok, value},
      else: invalid("runtime features are invalid", value)
  end

  defp features(value), do: invalid("runtime features must be a map", value)

  defp bounded_string(_field, value) when is_binary(value) and byte_size(value) in 1..256,
    do: {:ok, value}

  defp bounded_string(field, value), do: invalid("#{field} is invalid", value)

  defp bounded_string?(value), do: is_binary(value) and byte_size(value) in 1..256

  defp valid_grants?(value) when is_list(value) do
    Value.bounded_list?(value, @max_grants) and Enum.all?(value, &Grant.valid?/1) and
      Enum.uniq_by(value, & &1.reference) == value
  end

  defp valid_grants?(_value), do: false

  defp valid_features?(value) when is_map(value) do
    map_size(value) <= 100 and Value.bounded_data?(value, 65_536) and
      Enum.all?(value, fn
        {operation, %{available: available, provider: provider, isolation: isolation}} ->
          is_binary(operation) and byte_size(operation) <= 256 and is_boolean(available) and
            is_binary(provider) and byte_size(provider) <= 256 and
            isolation in [:read_only, :session_local, :node_global, :unavailable]

        _entry ->
          false
      end)
  end

  defp valid_features?(_value), do: false

  defp valid_budget?(%Budget{} = budget), do: Budget.new(Map.from_struct(budget)) == {:ok, budget}
  defp valid_budget?(_budget), do: false

  defp maximum_limits do
    %{
      max_duration_ms: Budget.maximum(:max_duration_ms),
      max_events: Budget.maximum(:max_events),
      max_bytes: Budget.maximum(:max_bytes),
      max_targets: Budget.maximum(:max_targets)
    }
  end

  defp invalid(message, value) do
    {:error, Error.new(:policy_denied, message, %{received: Value.summary(value)})}
  end
end
