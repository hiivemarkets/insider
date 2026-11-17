defmodule Insider.Sentinel.Verification.Candidate do
  @moduledoc """
  A bounded opaque candidate repair.

  Its bytes are inert data and cannot select execution authority. They may
  contain any byte sequence; only a host-allowlisted body decides how to
  interpret them.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.verification-candidate/v1"
  @formats ["opaque/v1", "unified-diff/v1"]
  @maximum_content_bytes 16_384
  @maximum_content_base64_bytes 21_848
  @maximum_bytes 24_576
  @keys ["byte_size", "content_base64", "content_sha256", "format", "id", "integrity", "schema"]
  @fields [:schema, :id, :format, :content_base64, :byte_size, :content_sha256, :integrity]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(content, format)
      when is_binary(content) and byte_size(content) <= @maximum_content_bytes do
    content_sha256 = hash_binary(content)

    body = %{
      "byte_size" => byte_size(content),
      "content_base64" => Base.encode64(content),
      "content_sha256" => content_sha256,
      "format" => format,
      "schema" => @schema
    }

    digest = hash(body)

    validate(%__MODULE__{
      schema: @schema,
      id: "sha256:" <> digest,
      format: format,
      content_base64: body["content_base64"],
      byte_size: byte_size(content),
      content_sha256: content_sha256,
      integrity: %{"algorithm" => "sha256", "content_digest" => digest}
    })
  rescue
    _error -> invalid(:construction_failed)
  end

  def new(content, _format) when is_binary(content), do: limit_exceeded()
  def new(_content, _format), do: invalid(:invalid_content)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = candidate) do
    with true <- Enum.sort(Map.keys(Map.from_struct(candidate))) == Enum.sort(@fields),
         true <- candidate.schema == @schema,
         true <- candidate.format in @formats,
         true <-
           is_integer(candidate.byte_size) and candidate.byte_size in 1..@maximum_content_bytes,
         true <-
           is_binary(candidate.content_base64) and
             byte_size(candidate.content_base64) <= @maximum_content_base64_bytes,
         {:ok, content} <- Base.decode64(candidate.content_base64),
         true <- Base.encode64(content) == candidate.content_base64,
         true <- byte_size(content) == candidate.byte_size,
         true <- hash_binary(content) == candidate.content_sha256,
         true <- digest?(candidate.content_sha256),
         true <- valid_integrity?(candidate.integrity),
         true <- candidate.id == "sha256:" <> candidate.integrity["content_digest"],
         true <- candidate.integrity["content_digest"] == hash(content_body(candidate)),
         true <- byte_size(Canonical.encode(to_wire_map(candidate))) <= @maximum_bytes do
      {:ok, candidate}
    else
      _other -> invalid(:invalid_candidate)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value) do
    value
    |> Ingress.canonical_decode(@maximum_bytes, &decode_map/1)
    |> normalize_decode()
  end

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema, do: unsupported_schema(schema)

  def decode_map(%{"schema" => @schema} = wire) when map_size(wire) == length(@keys) do
    if Enum.sort(Map.keys(wire)) == @keys do
      validate(%__MODULE__{
        schema: wire["schema"],
        id: wire["id"],
        format: wire["format"],
        content_base64: wire["content_base64"],
        byte_size: wire["byte_size"],
        content_sha256: wire["content_sha256"],
        integrity: wire["integrity"]
      })
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)
  def decode_map(value) when is_map(value) and not is_struct(value), do: unsupported_schema(nil)
  def decode_map(_value), do: invalid(:invalid_value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(candidate) do
    with {:ok, valid} <- validate(candidate), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec content(t()) :: {:ok, binary()} | {:error, Error.t()}
  def content(candidate) do
    with {:ok, valid} <- validate(candidate),
         {:ok, bytes} <- Base.decode64(valid.content_base64),
         do: {:ok, bytes}
  end

  @spec to_wire_map(t()) :: map()
  def to_wire_map(candidate),
    do: %{
      "schema" => candidate.schema,
      "id" => candidate.id,
      "format" => candidate.format,
      "content_base64" => candidate.content_base64,
      "byte_size" => candidate.byte_size,
      "content_sha256" => candidate.content_sha256,
      "integrity" => candidate.integrity
    }

  defp content_body(candidate), do: candidate |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = value),
    do: map_size(value) == 2 and digest?(digest)

  defp valid_integrity?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false
  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result
  defp hash(value), do: value |> Canonical.encode() |> hash_binary()
  defp hash_binary(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_verification_candidate, "verification candidate is invalid", %{
         reason: reason
       })}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :verification_candidate_limit_exceeded,
         "verification candidate exceeds its static limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_verification_candidate_schema,
         "verification candidate schema is unsupported",
         %{schema: Insider.Protocol.Value.summary(schema)}
       )}
end
