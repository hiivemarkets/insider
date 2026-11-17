defmodule Insider.Protocol.Request do
  @moduledoc """
  A versioned, bounded request accepted by the Insider runtime.
  """

  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @environments [:development, :test, :ci, :staging, :production]
  @protocol "insider.protocol/v1"
  @schema "insider.request/v1"

  @enforce_keys [
    :schema,
    :protocol,
    :request_id,
    :operation,
    :environment,
    :target,
    :timeout_ms,
    :deadline_monotonic,
    :budget
  ]
  defstruct [
    :schema,
    :protocol,
    :request_id,
    :operation,
    :environment,
    :target,
    :timeout_ms,
    :deadline_monotonic,
    :budget,
    :capability,
    :idempotency_key,
    caller: "local",
    params: %{},
    redaction_policy: :default
  ]

  @type environment :: :development | :test | :ci | :staging | :production

  @type t :: %__MODULE__{
          schema: String.t(),
          protocol: String.t(),
          request_id: String.t(),
          operation: String.t(),
          environment: environment(),
          target: %{required(:node) => String.t()},
          timeout_ms: pos_integer(),
          deadline_monotonic: integer(),
          budget: Budget.t(),
          capability: String.t() | nil,
          idempotency_key: String.t() | nil,
          caller: String.t(),
          params: map(),
          redaction_policy: :default
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(operation, options) do
    with {:ok, budget} <- Budget.new(Keyword.get(options, :budget, [])),
         :ok <- validate_envelope(options),
         {:ok, request_id} <- validate_request_id(Keyword.get(options, :request_id)),
         {:ok, environment} <-
           validate_environment(Keyword.get(options, :environment, :development)),
         {:ok, timeout_ms} <- timeout(options, budget),
         {:ok, params} <- validate_data(:params, Keyword.get(options, :params, %{}), budget),
         {:ok, target} <-
           validate_target(Keyword.get(options, :target, %{node: Atom.to_string(node())})),
         {:ok, caller} <- validate_string(:caller, Keyword.get(options, :caller, "local"), false),
         {:ok, capability} <-
           validate_string(:capability, Keyword.get(options, :capability), true),
         {:ok, idempotency_key} <-
           validate_string(:idempotency_key, Keyword.get(options, :idempotency_key), true),
         {:ok, redaction_policy} <-
           validate_redaction(Keyword.get(options, :redaction_policy, :default)) do
      {:ok,
       %__MODULE__{
         schema: @schema,
         protocol: @protocol,
         request_id: request_id,
         operation: operation,
         environment: environment,
         target: target,
         timeout_ms: timeout_ms,
         deadline_monotonic: System.monotonic_time(:millisecond) + timeout_ms,
         budget: budget,
         capability: capability,
         idempotency_key: idempotency_key,
         caller: caller,
         params: params,
         redaction_policy: redaction_policy
       }}
    end
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = request) do
    options = [
      schema: request.schema,
      protocol: request.protocol,
      request_id: request.request_id,
      environment: request.environment,
      timeout_ms: request.timeout_ms,
      budget: budget_options(request.budget),
      params: request.params,
      target: request.target,
      caller: request.caller,
      capability: request.capability,
      idempotency_key: request.idempotency_key,
      redaction_policy: request.redaction_policy
    ]

    with true <- request.operation in Insider.Protocol.operations(),
         {:ok, rebuilt} <- new(request.operation, options),
         true <- same_validated_fields?(request, rebuilt),
         true <- is_integer(request.deadline_monotonic),
         true <-
           request.deadline_monotonic <=
             System.monotonic_time(:millisecond) + request.timeout_ms do
      true
    else
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid?(_request), do: false

  defp budget_options(%Budget{} = budget), do: Map.from_struct(budget)
  defp budget_options(value), do: value

  defp same_validated_fields?(request, rebuilt) do
    Map.delete(request, :deadline_monotonic) == Map.delete(rebuilt, :deadline_monotonic)
  end

  defp validate_envelope(options) do
    schema = Keyword.get(options, :schema, @schema)
    protocol = Keyword.get(options, :protocol, @protocol)

    if schema == @schema and protocol == @protocol do
      :ok
    else
      {:error, Error.new(:invalid_request, "schema and protocol are library-owned", %{})}
    end
  end

  defp validate_request_id(value) when is_binary(value) and byte_size(value) in 1..256,
    do: {:ok, value}

  defp validate_request_id(value) do
    {:error,
     Error.new(:invalid_request, "request_id must be a bounded non-empty string", %{
       received: Value.summary(value)
     })}
  end

  defp validate_environment(value) when value in @environments, do: {:ok, value}

  defp validate_environment(value) do
    {:error,
     Error.new(:invalid_request, "unknown environment", %{received: Value.summary(value)})}
  end

  defp timeout(options, budget) do
    value = Keyword.get(options, :timeout_ms, budget.max_duration_ms)

    if is_integer(value) and value > 0 and value <= budget.max_duration_ms do
      {:ok, value}
    else
      {:error, Error.new(:invalid_request, "timeout exceeds the effective budget", %{})}
    end
  end

  defp validate_data(field, value, budget) do
    if is_map(value) and Value.bounded_data?(value, budget.max_bytes) do
      {:ok, value}
    else
      {:error,
       Error.new(:invalid_request, "#{field} must be bounded data", %{
         field: field,
         received: Value.summary(value)
       })}
    end
  end

  defp validate_target(%{node: node_name} = target)
       when is_binary(node_name) and map_size(target) == 1 do
    if byte_size(node_name) <= 256 and Value.bounded_data?(target, 4_096) do
      {:ok, target}
    else
      invalid_target(target)
    end
  end

  defp validate_target(value), do: invalid_target(value)

  defp invalid_target(value) do
    {:error,
     Error.new(:invalid_request, "target must contain a bounded node name", %{
       received: Value.summary(value)
     })}
  end

  defp validate_string(_field, nil, true), do: {:ok, nil}

  defp validate_string(_field, value, _optional)
       when is_binary(value) and byte_size(value) in 1..256,
       do: {:ok, value}

  defp validate_string(field, value, _optional) do
    {:error,
     Error.new(:invalid_request, "#{field} must be a bounded non-empty string", %{
       field: field,
       received: Value.summary(value)
     })}
  end

  defp validate_redaction(:default), do: {:ok, :default}

  defp validate_redaction(value) do
    {:error,
     Error.new(:invalid_request, "unknown redaction policy", %{
       received: Value.summary(value)
     })}
  end
end
