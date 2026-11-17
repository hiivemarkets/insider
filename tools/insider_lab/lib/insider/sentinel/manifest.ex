defmodule Insider.Sentinel.Manifest do
  @moduledoc """
  A closed, content-addressed handoff from an incident capsule to Sentinel.

  The manifest contains no executable recipe and embeds no capsule bytes. It
  binds the exact canonical capsule bytes, summarizes the six prerequisites
  needed for confirmation, and fixes the permitted execution posture.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @schema "insider.sentinel-manifest/v1"
  @wire_keys ["capsule", "execution_policy", "id", "integrity", "prerequisites", "schema"]
  @prerequisite_names ["code", "configuration", "dependencies", "runtime", "target", "scenario"]
  @provenance_names ["code", "configuration", "dependencies", "runtime", "target"]
  @maximum_bytes 65_536
  @maximum_capsule_bytes 1_048_576
  @execution_policy %{
    "cleanup" => "required",
    "purpose" => "confirmation",
    "source_mutation" => "prohibited",
    "target_class" => "disposable"
  }

  @enforce_keys [:schema, :id, :capsule, :prerequisites, :execution_policy, :integrity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: String.t(),
          id: String.t(),
          capsule: map(),
          prerequisites: map(),
          execution_policy: map(),
          integrity: map()
        }

  @spec new(Capsule.t() | binary(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(capsule_or_binary, scenario) do
    with {:ok, capsule, canonical} <- canonical_capsule(capsule_or_binary),
         {:ok, scenario_summary} <- validate_descriptor(scenario),
         {:ok, prerequisites} <- prerequisites(capsule.provenance, scenario_summary),
         capsule_reference <- capsule_reference(capsule, canonical) do
      content = %{
        "capsule" => capsule_reference,
        "execution_policy" => @execution_policy,
        "prerequisites" => prerequisites,
        "schema" => @schema
      }

      content_digest = digest(content)

      %__MODULE__{
        schema: @schema,
        id: "sha256:" <> content_digest,
        capsule: capsule_reference,
        prerequisites: prerequisites,
        execution_policy: @execution_policy,
        integrity: %{"algorithm" => "sha256", "content_digest" => content_digest}
      }
      |> validate()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:construction_failed)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = manifest) do
    with true <- exact_struct?(manifest),
         true <- manifest.schema == @schema,
         true <- valid_capsule_reference?(manifest.capsule),
         true <- valid_prerequisites?(manifest.prerequisites),
         true <- manifest.execution_policy == @execution_policy,
         true <- valid_integrity?(manifest.integrity),
         true <- manifest.id == "sha256:" <> manifest.integrity["content_digest"],
         true <- manifest.integrity["content_digest"] == digest(content(manifest)),
         encoded <- Canonical.encode(to_wire_map(manifest)),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, manifest}
    else
      _other -> invalid(:invalid_manifest)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(value), do: invalid_value(value)

  @doc """
  Validates a manifest and its exact canonical capsule as one offline unit.
  """
  @spec validate_with_capsule(term(), Capsule.t() | binary()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_capsule(manifest, capsule_or_binary) do
    with {:ok, valid_manifest} <- validate(manifest),
         {:ok, capsule, canonical} <- canonical_capsule(capsule_or_binary),
         true <- valid_manifest.capsule == capsule_reference(capsule, canonical),
         true <- correlated?(valid_manifest.prerequisites, capsule.provenance) do
      {:ok, valid_manifest}
    else
      {:error, %Error{} = error} -> {:error, error}
      false -> integrity_failed()
    end
  rescue
    _error -> invalid(:capsule_binding_failed)
  catch
    _kind, _reason -> invalid(:capsule_binding_failed)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    case Jason.decode(binary) do
      {:ok, payload} -> decode_canonical_payload(payload, binary)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded(:manifest_bytes)
  def decode(value), do: invalid_value(value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema,
    do: unsupported_schema(schema)

  def decode_map(
        %{
          "schema" => @schema,
          "id" => id,
          "capsule" => capsule,
          "prerequisites" => prerequisites,
          "execution_policy" => execution_policy,
          "integrity" => integrity
        } = payload
      )
      when map_size(payload) == length(@wire_keys) do
    validate(%__MODULE__{
      schema: @schema,
      id: id,
      capsule: capsule,
      prerequisites: prerequisites,
      execution_policy: execution_policy,
      integrity: integrity
    })
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)

  def decode_map(payload) when is_map(payload) and not is_struct(payload),
    do: unsupported_schema(nil)

  def decode_map(value), do: invalid_value(value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = manifest) do
    case validate(manifest) do
      {:ok, valid_manifest} -> {:ok, valid_manifest |> to_wire_map() |> Canonical.encode()}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def canonical_binary(value), do: invalid_value(value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = manifest) do
    %{
      "schema" => manifest.schema,
      "id" => manifest.id,
      "capsule" => manifest.capsule,
      "prerequisites" => manifest.prerequisites,
      "execution_policy" => manifest.execution_policy,
      "integrity" => manifest.integrity
    }
  end

  @doc """
  Derives confirmation readiness without changing the serialized manifest.

  Blocked prerequisites retain their unavailable reason or redaction policy and
  are returned in stable prerequisite order.
  """
  @spec readiness(term(), Capsule.t() | binary()) :: {:ok, map()} | {:error, Error.t()}
  def readiness(manifest, capsule_or_binary) do
    with {:ok, valid_manifest} <- validate_with_capsule(manifest, capsule_or_binary) do
      blocked =
        Enum.flat_map(@prerequisite_names, fn name ->
          case valid_manifest.prerequisites[name] do
            %{"status" => "available"} -> []
            descriptor -> [Map.put(descriptor, "name", name)]
          end
        end)

      status = if blocked == [], do: "ready", else: "blocked"
      {:ok, %{"blocked" => blocked, "status" => status}}
    end
  end

  defp canonical_capsule(%Capsule{} = capsule) do
    with {:ok, valid_capsule} <- Capsule.validate(capsule),
         {:ok, canonical} <- Capsule.canonical_binary(valid_capsule) do
      {:ok, valid_capsule, canonical}
    end
  end

  defp canonical_capsule(binary) when is_binary(binary) do
    with {:ok, capsule} <- Capsule.decode(binary),
         {:ok, canonical} <- Capsule.canonical_binary(capsule),
         true <- canonical == binary do
      {:ok, capsule, canonical}
    else
      false -> invalid(:noncanonical_capsule)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp canonical_capsule(value), do: invalid_value(value)

  defp prerequisites(provenance, scenario) do
    components = provenance["components"]

    if is_map(components) do
      Enum.reduce_while(@provenance_names, {:ok, %{"scenario" => scenario}}, fn name,
                                                                                {:ok, acc} ->
        case summary_component(components[name]) do
          {:ok, summary} -> {:cont, {:ok, Map.put(acc, name, summary)}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
    else
      invalid(:invalid_provenance)
    end
  end

  defp summary_component(
         %{
           "attributes" => _attributes,
           "fingerprint" => fingerprint,
           "status" => "available"
         } = component
       )
       when map_size(component) == 3,
       do: validate_descriptor(%{"fingerprint" => fingerprint, "status" => "available"})

  defp summary_component(
         %{
           "fingerprint" => fingerprint,
           "reason" => reason,
           "status" => "unavailable"
         } = component
       )
       when map_size(component) == 3,
       do:
         validate_descriptor(%{
           "fingerprint" => fingerprint,
           "reason" => reason,
           "status" => "unavailable"
         })

  defp summary_component(
         %{
           "fingerprint" => fingerprint,
           "policy_fingerprint" => policy_fingerprint,
           "status" => "redacted"
         } = component
       )
       when map_size(component) == 3,
       do:
         validate_descriptor(%{
           "fingerprint" => fingerprint,
           "policy_fingerprint" => policy_fingerprint,
           "status" => "redacted"
         })

  defp summary_component(_component), do: invalid(:invalid_provenance_component)

  defp validate_descriptor(%{"fingerprint" => fingerprint, "status" => "available"} = value)
       when map_size(value) == 2 do
    if digest?(fingerprint), do: {:ok, value}, else: invalid(:invalid_prerequisite)
  end

  defp validate_descriptor(
         %{"fingerprint" => fingerprint, "reason" => reason, "status" => "unavailable"} = value
       )
       when map_size(value) == 3 do
    if digest?(fingerprint) and
         reason in [
           "not_provided",
           "not_built",
           "not_supported",
           "collection_failed"
         ],
       do: {:ok, value},
       else: invalid(:invalid_prerequisite)
  end

  defp validate_descriptor(
         %{
           "fingerprint" => fingerprint,
           "policy_fingerprint" => policy_fingerprint,
           "status" => "redacted"
         } = value
       )
       when map_size(value) == 3 do
    if digest?(fingerprint) and digest?(policy_fingerprint),
      do: {:ok, value},
      else: invalid(:invalid_prerequisite)
  end

  defp validate_descriptor(_value), do: invalid(:invalid_prerequisite)

  defp valid_prerequisites?(prerequisites)
       when is_map(prerequisites) and not is_struct(prerequisites) do
    map_size(prerequisites) == length(@prerequisite_names) and
      Enum.sort(Map.keys(prerequisites)) == Enum.sort(@prerequisite_names) and
      Enum.all?(@prerequisite_names, fn name ->
        match?({:ok, _summary}, validate_descriptor(prerequisites[name]))
      end)
  end

  defp valid_prerequisites?(_prerequisites), do: false

  defp valid_capsule_reference?(
         %{
           "byte_size" => byte_size,
           "canonical_sha256" => canonical_sha256,
           "id" => "sha256:" <> id_digest,
           "schema" => "insider.incident-capsule/v1"
         } = reference
       )
       when map_size(reference) == 4,
       do:
         is_integer(byte_size) and byte_size in 1..@maximum_capsule_bytes and
           digest?(canonical_sha256) and digest?(id_digest)

  defp valid_capsule_reference?(_reference), do: false

  defp valid_integrity?(
         %{"algorithm" => "sha256", "content_digest" => content_digest} = integrity
       )
       when map_size(integrity) == 2,
       do: digest?(content_digest)

  defp valid_integrity?(_integrity), do: false

  defp correlated?(prerequisites, provenance) do
    components = provenance["components"]

    is_map(components) and
      Enum.all?(@provenance_names, fn name ->
        expected = prerequisites[name]
        match?({:ok, ^expected}, summary_component(components[name]))
      end)
  rescue
    _error -> false
  end

  defp capsule_reference(capsule, canonical) do
    %{
      "schema" => capsule.schema,
      "id" => capsule.id,
      "byte_size" => byte_size(canonical),
      "canonical_sha256" => sha256(canonical)
    }
  end

  defp content(manifest) do
    %{
      "schema" => manifest.schema,
      "capsule" => manifest.capsule,
      "prerequisites" => manifest.prerequisites,
      "execution_policy" => manifest.execution_policy
    }
  end

  defp decode_canonical_payload(payload, binary) do
    case decode_map(payload) do
      {:ok, manifest} ->
        if Canonical.encode(payload) == binary,
          do: {:ok, manifest},
          else: invalid(:noncanonical_encoding)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp exact_struct?(manifest),
    do:
      map_size(manifest) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(manifest)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp digest(value), do: value |> Canonical.encode() |> sha256()

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp unsupported_schema(schema) do
    {:error,
     Error.new(
       :unsupported_sentinel_manifest_schema,
       "sentinel manifest schema is unsupported",
       %{
         received: Value.summary(schema)
       }
     )}
  end

  defp integrity_failed,
    do:
      {:error, Error.new(:sentinel_manifest_integrity_failed, "sentinel capsule binding failed")}

  defp limit_exceeded(limit) do
    {:error,
     Error.new(:sentinel_manifest_limit_exceeded, "sentinel manifest limit exceeded", %{
       limit: Atom.to_string(limit)
     })}
  end

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_sentinel_manifest, "sentinel manifest is invalid", %{
         reason: Atom.to_string(reason)
       })}

  defp invalid_value(value),
    do:
      {:error,
       Error.new(:invalid_sentinel_manifest, "sentinel manifest is invalid", %{
         received: Value.summary(value)
       })}
end
