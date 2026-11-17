defmodule Insider.Protocol do
  @moduledoc """
  Versioned request and effect-honest result constructors.

  Transport adapters must validate through this module rather than converting
  external strings to atoms.
  """

  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Protocol.Value

  @version "insider.protocol/v1"
  @request_schema "insider.request/v1"

  @operations [
    "runtime.capabilities",
    "runtime.health",
    "runtime.fingerprint",
    "runtime.snapshot",
    "runtime.diff",
    "process.describe",
    "process.await",
    "supervision.tree",
    "mailbox.summarize",
    "trace.start",
    "trace.stop",
    "events.subscribe",
    "incident.capture",
    "incident.export",
    "contract.list",
    "contract.observe",
    "contract.check",
    "scenario.run",
    "verification.run"
  ]

  @spec version() :: String.t()
  def version, do: @version

  @spec operations() :: [String.t()]
  def operations, do: @operations

  @spec request(String.t(), keyword()) :: {:ok, Request.t()} | {:error, Error.t()}
  def request(operation, options \\ []) do
    if operation in @operations do
      options = Keyword.merge([schema: @request_schema, protocol: @version], options)
      Request.new(operation, options)
    else
      {:error,
       Error.new(:unsupported_operation, "operation is not part of the current protocol", %{
         received: Value.summary(operation)
       })}
    end
  end

  @spec decode_request(term()) :: {:ok, Request.t()} | {:error, Error.t()}
  def decode_request(%{"protocol" => protocol}) when protocol != @version do
    {:error,
     Error.new(:unsupported_protocol_version, "protocol version is not supported", %{
       received: Value.summary(protocol),
       supported: [@version]
     })}
  end

  def decode_request(%{"protocol" => @version, "schema" => schema})
      when schema != @request_schema do
    {:error,
     Error.new(:unsupported_protocol_version, "request schema is not supported", %{
       received: Value.summary(schema),
       supported: [@request_schema]
     })}
  end

  def decode_request(
        %{
          "protocol" => @version,
          "schema" => @request_schema,
          "operation" => operation
        } = payload
      ) do
    with {:ok, environment} <- decode_environment(Map.get(payload, "environment", "development")),
         {:ok, budget} <- decode_budget(Map.get(payload, "budget", %{})),
         {:ok, target} <-
           decode_target(Map.get(payload, "target", %{"node" => Atom.to_string(node())})),
         {:ok, redaction_policy} <-
           decode_redaction_policy(Map.get(payload, "redaction_policy", "default")) do
      request(operation,
        schema: @request_schema,
        protocol: @version,
        request_id: Map.get(payload, "request_id"),
        environment: environment,
        timeout_ms: Map.get(payload, "timeout_ms", Keyword.fetch!(budget, :max_duration_ms)),
        budget: budget,
        params: Map.get(payload, "params", %{}),
        caller: Map.get(payload, "caller", "local"),
        capability: Map.get(payload, "capability"),
        idempotency_key: Map.get(payload, "idempotency_key"),
        redaction_policy: redaction_policy,
        target: target
      )
    end
  end

  def decode_request(payload) do
    {:error,
     Error.new(:invalid_request, "request envelope is missing required fields", %{
       received: Value.summary(payload)
     })}
  end

  @spec success(Request.t(), term(), keyword()) :: Result.t()
  def success(request, value, options \\ []),
    do: Result.new(request, :ok, Keyword.put(options, :value, value))

  @spec failure(Request.t(), Error.t(), keyword()) :: Result.t()
  def failure(request, %Error{} = error, options \\ []),
    do: Result.new(request, :error, Keyword.put(options, :error, error))

  @spec timeout(Request.t(), keyword()) :: Result.t()
  def timeout(request, options \\ []) do
    error = Error.new(:deadline_exceeded, "operation exceeded its deadline", %{}, retryable: true)
    Result.new(request, :timeout, Keyword.put(options, :error, error))
  end

  @spec cancelled(Request.t(), keyword()) :: Result.t()
  def cancelled(request, options \\ []) do
    warnings = [
      "cancellation does not roll back observed effects" | Keyword.get(options, :warnings, [])
    ]

    options =
      options
      |> Keyword.put(:warnings, warnings)
      |> Keyword.put_new(:cleanup, %{status: :unknown})

    Result.new(request, :cancelled, options)
  end

  @spec unsupported(Request.t(), atom()) :: Result.t()
  def unsupported(request, capability) when is_atom(capability) do
    error =
      Error.new(:unsupported_capability, "capability is unavailable for this target", %{
        capability: capability
      })

    Result.new(request, :unsupported, error: error)
  end

  defp decode_environment("development"), do: {:ok, :development}
  defp decode_environment("test"), do: {:ok, :test}
  defp decode_environment("ci"), do: {:ok, :ci}
  defp decode_environment("staging"), do: {:ok, :staging}
  defp decode_environment("production"), do: {:ok, :production}

  defp decode_environment(value) do
    {:error,
     Error.new(:invalid_request, "unknown environment", %{received: Value.summary(value)})}
  end

  defp decode_target(%{"node" => node_name} = target) when map_size(target) == 1,
    do: {:ok, %{node: node_name}}

  defp decode_target(value) do
    {:error,
     Error.new(:invalid_request, "target must contain only a node name", %{
       received: Value.summary(value)
     })}
  end

  defp decode_redaction_policy("default"), do: {:ok, :default}

  defp decode_redaction_policy(value) do
    {:error,
     Error.new(:invalid_request, "unknown redaction policy", %{
       received: Value.summary(value)
     })}
  end

  defp decode_budget(payload) when is_map(payload) do
    allowed = ["max_duration_ms", "max_events", "max_bytes", "max_targets"]

    unknown =
      if map_size(payload) > length(allowed), do: :too_many, else: Map.keys(payload) -- allowed

    case unknown do
      [] ->
        {:ok,
         [
           max_duration_ms: Map.get(payload, "max_duration_ms", 5_000),
           max_events: Map.get(payload, "max_events", 1_000),
           max_bytes: Map.get(payload, "max_bytes", 1_048_576),
           max_targets: Map.get(payload, "max_targets", 1)
         ]}

      :too_many ->
        {:error,
         Error.new(:invalid_budget, "too many external budget fields", %{
           field_count: map_size(payload)
         })}

      unknown_fields ->
        {:error,
         Error.new(:invalid_budget, "unknown external budget fields", %{
           unknown_field_count: length(unknown_fields)
         })}
    end
  end

  defp decode_budget(payload) do
    {:error,
     Error.new(:invalid_budget, "budget must be an object", %{received: Value.summary(payload)})}
  end
end
