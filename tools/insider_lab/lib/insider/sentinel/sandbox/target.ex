defmodule Insider.Sentinel.Sandbox.Target do
  @moduledoc """
  A canonical expected fingerprint for a disposable Sentinel target.

  It contains no locator, command, path, credential, or execution authority.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Provenance

  @schema "insider.sandbox-target/v1"
  @wire_keys ["id", "integrity", "isolation", "provenance", "provider", "schema"]
  @maximum_bytes 65_536

  @enforce_keys [:schema, :id, :provider, :isolation, :provenance, :integrity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map(), Provenance.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(provider, provenance) do
    with true <- valid_provider?(provider),
         {:ok, wire_provenance} <- normalize_provenance(provenance),
         true <- all_available?(wire_provenance) do
      content = %{
        "isolation" => "disposable",
        "provenance" => wire_provenance,
        "provider" => provider,
        "schema" => @schema
      }

      content_digest = digest(content)

      %__MODULE__{
        schema: @schema,
        id: "sha256:" <> content_digest,
        provider: provider,
        isolation: "disposable",
        provenance: wire_provenance,
        integrity: %{"algorithm" => "sha256", "content_digest" => content_digest}
      }
      |> validate()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:invalid_definition)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = target) do
    with true <- exact_struct?(target),
         true <- target.schema == @schema,
         true <- valid_provider?(target.provider),
         true <- target.isolation == "disposable",
         {:ok, provenance} <- Provenance.decode_map(target.provenance),
         true <- all_available?(target.provenance),
         :ok <- integrity_shape(target.integrity),
         :ok <- content_address_matches(target),
         encoded <- Canonical.encode(to_wire_map(target)),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, %{target | provenance: Provenance.to_wire_map(provenance)}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:invalid_target)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(value), do: invalid_value(value)

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    decoded = Jason.decode(binary)

    case decoded do
      {:ok, payload} -> decode_payload(payload, binary)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded(:target_bytes)
  def decode(value), do: invalid_value(value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema, do: unsupported_schema(schema)

  def decode_map(payload) when is_map(payload) and not is_struct(payload) do
    if map_size(payload) == length(@wire_keys) and Enum.sort(Map.keys(payload)) == @wire_keys do
      validate(%__MODULE__{
        schema: payload["schema"],
        id: payload["id"],
        provider: payload["provider"],
        isolation: payload["isolation"],
        provenance: payload["provenance"],
        integrity: payload["integrity"]
      })
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(value), do: invalid_value(value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = target) do
    target
    |> validate()
    |> encode_validated()
  end

  def canonical_binary(value), do: invalid_value(value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = target) do
    %{
      "schema" => target.schema,
      "id" => target.id,
      "provider" => target.provider,
      "isolation" => target.isolation,
      "provenance" => target.provenance,
      "integrity" => target.integrity
    }
  end

  @spec target_fingerprint(t()) :: String.t()
  def target_fingerprint(%__MODULE__{} = target), do: target.provenance["fingerprint"]

  defp normalize_provenance(%Provenance{} = provenance) do
    with {:ok, valid} <- Provenance.validate(provenance), do: {:ok, Provenance.to_wire_map(valid)}
  end

  defp normalize_provenance(provenance) when is_map(provenance) do
    with {:ok, valid} <- Provenance.decode_map(provenance),
         do: {:ok, Provenance.to_wire_map(valid)}
  end

  defp normalize_provenance(value), do: invalid_value(value)

  defp all_available?(%{"components" => components}) when is_map(components),
    do:
      map_size(components) == 5 and
        Enum.all?(components, fn {_name, value} -> value["status"] == "available" end)

  defp all_available?(_provenance), do: false

  defp valid_provider?(%{"id" => id, "version" => version} = provider),
    do:
      map_size(provider) == 2 and vocabulary?(id) and is_integer(version) and
        version in 1..1_000_000

  defp valid_provider?(_provider), do: false

  defp integrity_shape(%{"algorithm" => "sha256", "content_digest" => value} = envelope)
       when map_size(envelope) == 2,
       do: if(valid_digest?(value), do: :ok, else: :error)

  defp integrity_shape(_envelope), do: :error

  defp content_address_matches(target) do
    claimed = target.integrity["content_digest"]
    actual = target |> content() |> content_hash()
    expected_id = ["sha256:", claimed] |> IO.iodata_to_binary()

    case {claimed == actual, target.id == expected_id} do
      {true, true} -> :ok
      _mismatch -> integrity_failed()
    end
  end

  defp content(target) do
    %{
      "isolation" => target.isolation,
      "provenance" => target.provenance,
      "provider" => target.provider,
      "schema" => target.schema
    }
  end

  defp decode_payload(payload, binary) do
    if Canonical.encode(payload) == binary,
      do: decode_map(payload),
      else: invalid(:noncanonical_encoding)
  end

  defp digest(value), do: content_hash(value)

  defp content_hash(value) do
    encoded = Canonical.encode(value)
    Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end

  defp exact_struct?(target) do
    fields = Map.from_struct(target)

    map_size(fields) == length(@enforce_keys) and
      Enum.all?(@enforce_keys, &Map.has_key?(fields, &1))
  end

  defp encode_validated({:ok, valid}), do: {:ok, valid |> to_wire_map() |> Canonical.encode()}
  defp encode_validated({:error, %Error{} = error}), do: {:error, error}

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_value), do: false

  defp vocabulary?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp vocabulary?(_value), do: false

  defp invalid(reason),
    do:
      {:error, Error.new(:invalid_sandbox_target, "sandbox target is invalid", %{reason: reason})}

  defp invalid_value(value),
    do:
      {:error,
       Error.new(:invalid_sandbox_target, "sandbox target value is invalid", %{
         received: Insider.Protocol.Value.summary(value)
       })}

  defp integrity_failed,
    do:
      {:error,
       Error.new(:sandbox_target_integrity_failed, "sandbox target integrity verification failed")}

  defp limit_exceeded(limit),
    do:
      {:error,
       Error.new(:sandbox_target_limit_exceeded, "sandbox target exceeds its limit", %{
         limit: limit
       })}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:unsupported_sandbox_target_schema, "sandbox target schema is unsupported", %{
         schema: Insider.Protocol.Value.summary(schema)
       })}
end
