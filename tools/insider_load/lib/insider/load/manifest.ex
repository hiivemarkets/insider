defmodule Insider.Load.Manifest do
  @moduledoc """
  Canonical SHA-256 inventory for every emitted load-harness artifact.

  SHA-256 establishes byte identity, not authenticity. Callers must construct
  the manifest from the complete output set before writing it; the manifest
  cannot prove that an omitted file existed.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @schema "insider.load-manifest/v1"
  @maximum_bytes 262_144
  @maximum_term_bytes 524_288
  @maximum_artifacts 128
  @fields [:schema, :id, :artifacts, :integrity]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @artifact_keys ~w(byte_size path sha256)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Builds an inventory from a nonempty map or list of `{relative_path, bytes}` pairs."
  @spec new(map() | [{binary(), binary()}]) :: {:ok, t()} | {:error, Error.t()}
  def new(artifacts) when is_map(artifacts), do: new(Map.to_list(artifacts))

  def new(artifacts) when is_list(artifacts) do
    with true <- artifacts != [] and Value.bounded_list?(artifacts, @maximum_artifacts + 1),
         {:ok, entries} <- build_entries(artifacts),
         true <- unique_sorted_paths?(entries) do
      body = %{"schema" => @schema, "artifacts" => entries}
      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      _other -> invalid(:invalid_artifacts)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  def new(_artifacts), do: invalid(:invalid_value)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = manifest) do
    wire = to_wire_map(manifest)

    with true <- manifest.schema == @schema,
         true <- valid_artifacts?(manifest.artifacts),
         true <- valid_integrity?(manifest.integrity),
         true <- manifest.id == "sha256:" <> manifest.integrity["content_digest"],
         true <- manifest.integrity["content_digest"] == Canonical.sha256(content(manifest)),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         encoded <- Canonical.encode(wire),
         true <- byte_size(encoded) <= @maximum_bytes,
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire do
      {:ok, manifest}
    else
      _other -> invalid(:invalid_manifest)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Checks that the supplied complete output set has exactly the recorded paths and bytes."
  @spec validate_with_artifacts(term(), map() | [{binary(), binary()}]) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_artifacts(manifest, artifacts) do
    with {:ok, valid} <- validate(manifest),
         {:ok, expected} <- new(artifacts),
         true <- valid.artifacts == expected.artifacts do
      {:ok, valid}
    else
      _other -> invalid(:artifact_substitution)
    end
  rescue
    _error -> invalid(:artifact_substitution)
  catch
    _kind, _reason -> invalid(:artifact_substitution)
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(manifest) do
    with {:ok, valid} <- validate(manifest), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary,
         {:ok, manifest} <- decode_map(wire) do
      {:ok, manifest}
    else
      false -> invalid(:noncanonical_encoding)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:decoding_failed)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded()
  def decode(_value), do: invalid(:invalid_encoding)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema,
    do: invalid(:unsupported_schema, %{schema: bounded(schema)})

  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    if exact_keys?(wire, @wire_keys) do
      manifest =
        struct!(
          __MODULE__,
          Map.new(wire, fn {key, value} -> {String.to_existing_atom(key), value} end)
        )

      validate(manifest)
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  defp build_entries(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn
      {path, bytes}, {:ok, entries} when is_binary(bytes) ->
        if safe_path?(path) do
          entry = %{
            "path" => path,
            "byte_size" => byte_size(bytes),
            "sha256" => Canonical.sha256_binary(bytes)
          }

          {:cont, {:ok, [entry | entries]}}
        else
          {:halt, :error}
        end

      _artifact, _entries ->
        {:halt, :error}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1["path"])}
      :error -> :error
    end
  end

  defp valid_artifacts?(artifacts) do
    Value.bounded_list?(artifacts, @maximum_artifacts + 1) and artifacts != [] and
      Enum.all?(artifacts, &valid_artifact?/1) and unique_sorted_paths?(artifacts)
  end

  defp valid_artifact?(artifact),
    do:
      exact_keys?(artifact, @artifact_keys) and safe_path?(artifact["path"]) and
        is_integer(artifact["byte_size"]) and artifact["byte_size"] >= 0 and
        digest?(artifact["sha256"])

  defp unique_sorted_paths?(entries) do
    paths = Enum.map(entries, & &1["path"])
    paths == Enum.sort(paths) and paths == Enum.uniq(paths)
  end

  defp safe_path?(path) when is_binary(path) and byte_size(path) in 1..256 do
    String.valid?(path) and not String.starts_with?(path, ["/", "\\"]) and
      path not in [".", "manifest.json"] and
      not String.contains?(path, ["..", "\\", <<0>>])
  end

  defp safe_path?(_path), do: false

  defp valid_integrity?(integrity),
    do:
      exact_keys?(integrity, ~w(algorithm content_digest)) and integrity["algorithm"] == "sha256" and
        digest?(integrity["content_digest"])

  defp content(manifest), do: manifest |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp exact_keys?(_value, _keys), do: false
  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_value), do: false

  defp invalid(reason, details \\ %{}) do
    {:error,
     Error.new(
       :invalid_request,
       "invalid canonical load manifest",
       Map.put(details, :reason, reason)
     )}
  end

  defp limit_exceeded do
    {:error,
     Error.new(:invalid_request, "load manifest exceeds its byte limit", %{
       maximum_bytes: @maximum_bytes
     })}
  end

  defp bounded(value) when is_binary(value), do: binary_part(value, 0, min(byte_size(value), 128))
  defp bounded(_value), do: "invalid"
end
