defmodule Insider.Observability.Trigger do
  @moduledoc """
  A bounded, vendor-neutral request for local incident handling.

  A trigger is inert data. It may request only a local freeze or follow-up and
  carries host-produced correlation fingerprints. Raw external identifiers,
  secrets, and customer data must not enter this artifact. It contains no runtime policy,
  environment, authority, target, collection scope, redaction choice, callback,
  endpoint, credential, or transport instruction.

  The content-addressed `id` is also the idempotency key for the exact request.
  It does not authorize an operation or attest that one was performed.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @schema "insider.observability-trigger/v1"
  @operations ["freeze", "follow_up"]
  @option_keys [
    :operation,
    :provider,
    :external_event_fingerprint,
    :external_incident_fingerprint
  ]
  @wire_keys [
    "external_event_fingerprint",
    "external_incident_fingerprint",
    "id",
    "operation",
    "provider",
    "schema"
  ]
  @maximum_bytes 1_024
  @maximum_provider_bytes 64

  @enforce_keys [:schema, :id | @option_keys]
  defstruct @enforce_keys

  @type operation :: String.t()
  @type t :: %__MODULE__{
          schema: String.t(),
          id: String.t(),
          operation: operation(),
          provider: String.t(),
          external_event_fingerprint: String.t(),
          external_incident_fingerprint: String.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with true <- exact_options?(options),
         trigger <-
           struct!(__MODULE__,
             schema: @schema,
             id: "",
             operation: Keyword.fetch!(options, :operation),
             provider: Keyword.fetch!(options, :provider),
             external_event_fingerprint: Keyword.fetch!(options, :external_event_fingerprint),
             external_incident_fingerprint:
               Keyword.fetch!(options, :external_incident_fingerprint)
           ),
         true <- valid_content?(trigger),
         trigger <- %{trigger | id: content_id(trigger)},
         {:ok, trigger} <- validate(trigger) do
      {:ok, trigger}
    else
      _invalid -> invalid("trigger fields are invalid, missing, duplicated, or unknown", options)
    end
  rescue
    _error -> invalid("trigger construction failed", options)
  catch
    _kind, _reason -> invalid("trigger construction failed", options)
  end

  def new(value), do: invalid("trigger fields must be a keyword list", value)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = trigger) do
    if exact_struct?(trigger) and valid_content?(trigger) and trigger.id == content_id(trigger) and
         canonical_size(trigger) <= @maximum_bytes do
      {:ok, trigger}
    else
      invalid("trigger is invalid or unbounded", trigger)
    end
  rescue
    _error -> invalid("trigger validation failed", trigger)
  catch
    _kind, _reason -> invalid("trigger validation failed", trigger)
  end

  def validate(value), do: invalid("value is not an observability trigger", value)

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         {:ok, trigger} <- decode_map(wire),
         true <- Canonical.encode(wire) == binary do
      {:ok, trigger}
    else
      false -> invalid("trigger encoding is not canonical", binary)
      {:error, %Jason.DecodeError{}} -> invalid("trigger is not valid JSON", binary)
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error -> invalid("trigger decoding failed", binary)
  catch
    _kind, _reason -> invalid("trigger decoding failed", binary)
  end

  def decode(binary) when is_binary(binary),
    do: invalid("trigger exceeds the canonical byte limit", binary)

  def decode(value), do: invalid("trigger must be canonical JSON", value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    cond do
      Map.get(wire, "schema") != @schema ->
        {:error,
         Error.new(:unsupported_protocol_version, "unsupported observability trigger schema", %{
           received: Value.summary(Map.get(wire, "schema"))
         })}

      not exact_wire?(wire) ->
        invalid("trigger must contain the exact schema fields", wire)

      true ->
        wire
        |> then(fn value ->
          %__MODULE__{
            schema: value["schema"],
            id: value["id"],
            operation: value["operation"],
            provider: value["provider"],
            external_event_fingerprint: value["external_event_fingerprint"],
            external_incident_fingerprint: value["external_incident_fingerprint"]
          }
        end)
        |> validate()
    end
  rescue
    _error -> invalid("trigger map decoding failed", wire)
  catch
    _kind, _reason -> invalid("trigger map decoding failed", wire)
  end

  def decode_map(value), do: invalid("trigger must be an object", value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = trigger) do
    with {:ok, valid_trigger} <- validate(trigger) do
      {:ok, valid_trigger |> to_wire_map() |> Canonical.encode()}
    end
  end

  def canonical_binary(value), do: invalid("value is not an observability trigger", value)

  @doc "Returns the deterministic idempotency key for a valid trigger."
  @spec idempotency_key(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def idempotency_key(%__MODULE__{} = trigger) do
    with {:ok, valid_trigger} <- validate(trigger), do: {:ok, valid_trigger.id}
  end

  def idempotency_key(value), do: invalid("value is not an observability trigger", value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = trigger) do
    %{
      "schema" => trigger.schema,
      "id" => trigger.id,
      "operation" => trigger.operation,
      "provider" => trigger.provider,
      "external_event_fingerprint" => trigger.external_event_fingerprint,
      "external_incident_fingerprint" => trigger.external_incident_fingerprint
    }
  end

  defp exact_options?(options) do
    Value.bounded_list?(options, length(@option_keys) + 1) and Keyword.keyword?(options) and
      Enum.sort(Keyword.keys(options)) == Enum.sort(@option_keys)
  end

  defp valid_content?(trigger) do
    trigger.schema == @schema and trigger.operation in @operations and
      provider?(trigger.provider) and digest?(trigger.external_event_fingerprint) and
      digest?(trigger.external_incident_fingerprint)
  end

  defp provider?(value) do
    bounded_string?(value, @maximum_provider_bytes) and
      String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)
  end

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp content_id(trigger) do
    content =
      trigger
      |> to_wire_map()
      |> Map.delete("id")

    "sha256:" <> Canonical.sha256(content)
  end

  defp canonical_size(trigger), do: trigger |> to_wire_map() |> Canonical.encode() |> byte_size()

  defp exact_wire?(wire),
    do: map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys

  defp exact_struct?(trigger) do
    expected = struct(__MODULE__)

    map_size(trigger) == map_size(expected) and
      Enum.sort(Map.keys(trigger)) == Enum.sort(Map.keys(expected))
  end

  defp invalid(message, value) do
    {:error, Error.new(:invalid_request, message, %{received: Value.summary(value)})}
  end
end
