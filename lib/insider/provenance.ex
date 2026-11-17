defmodule Insider.Provenance do
  @moduledoc """
  Bounded, portable provenance for incident evidence.

  Provenance has five fixed components: code, configuration, dependencies,
  runtime, and target. Callers describe each component as `{:available, map}`,
  `{:unavailable, reason}`, or `{:redacted, policy_fingerprint}`. Available
  attributes must already be safe to export; this module bounds and fingerprints
  them but does not turn a digest into redaction.

  `capture/1` collects stable, low-risk BEAM runtime and target facts. It never
  shells out, reads the working tree, walks loaded applications, or captures
  environment variables. Build systems may explicitly supply sanitized code,
  dependency, and configuration facts.
  """

  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue

  @schema "insider.provenance/v1"
  @component_schema "insider.provenance-component/v1"
  @component_names ["code", "configuration", "dependencies", "runtime", "target"]
  @option_keys [:code, :configuration, :dependencies, :runtime, :target]
  @capture_option_keys [:code, :configuration, :dependencies, :target]
  @unavailable_reasons [:not_provided, :not_built, :not_supported, :collection_failed]
  @max_component_entries 32
  @max_component_bytes 4_096
  @max_wire_bytes 32_768

  @enforce_keys [:schema, :components, :fingerprint]
  defstruct [:schema, :components, :fingerprint]

  @type unavailable_reason ::
          :not_provided | :not_built | :not_supported | :collection_failed
  @type descriptor ::
          {:available, map()} | {:unavailable, unavailable_reason()} | {:redacted, String.t()}
  @type component :: map()
  @type t :: %__MODULE__{
          schema: String.t(),
          components: %{required(String.t()) => component()},
          fingerprint: String.t()
        }

  @doc """
  Captures stable public runtime and machine-class facts.

  Omitted build-controlled components remain explicitly unavailable. Supplying
  `:runtime` is intentionally unsupported here; use `new/1` for decoding,
  fixtures, or another trusted collector.
  """
  @spec capture(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def capture(options \\ [])

  def capture(options) when is_list(options) do
    if exact_keyword_subset?(options, @capture_option_keys) do
      new(
        code: Keyword.get(options, :code, {:unavailable, :not_provided}),
        configuration: Keyword.get(options, :configuration, {:unavailable, :not_provided}),
        dependencies: Keyword.get(options, :dependencies, {:unavailable, :not_provided}),
        runtime: {:available, runtime_attributes()},
        target: Keyword.get(options, :target, {:available, target_attributes()})
      )
    else
      invalid("capture options are duplicated or unknown", options)
    end
  rescue
    _error -> invalid("runtime provenance collection failed", options)
  end

  def capture(value), do: invalid("capture options must be a keyword list", value)

  @doc """
  Constructs provenance from exactly one descriptor for every v1 component.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    if exact_keyword_set?(options, @option_keys) do
      with {:ok, components} <- build_components(options) do
        provenance = %__MODULE__{
          schema: @schema,
          components: components,
          fingerprint: aggregate_fingerprint(components)
        }

        validate(provenance)
      end
    else
      invalid("provenance components are missing, duplicated, or unknown", options)
    end
  rescue
    _error -> invalid("provenance construction failed", options)
  end

  def new(value), do: invalid("provenance components must be a keyword list", value)

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = provenance) do
    valid =
      exact_struct?(provenance) and provenance.schema == @schema and
        exact_components?(provenance.components) and
        Enum.all?(provenance.components, &valid_component?/1) and
        provenance.fingerprint == aggregate_fingerprint(provenance.components) and
        byte_size(Canonical.encode(to_wire_map(provenance))) <= @max_wire_bytes

    if valid,
      do: {:ok, provenance},
      else: invalid("provenance contains invalid or inconsistent evidence", provenance)
  rescue
    _error -> invalid("provenance validation failed", provenance)
  end

  def validate(value), do: invalid("value is not provenance", value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(payload) when is_map(payload) and not is_struct(payload) do
    cond do
      Map.get(payload, "schema") != @schema ->
        unsupported_schema(Map.get(payload, "schema"))

      map_size(payload) != 3 or
          Enum.sort(Map.keys(payload)) != ["components", "fingerprint", "schema"] ->
        invalid("provenance envelope must contain the exact v1 fields", payload)

      true ->
        decode_v1(payload)
    end
  rescue
    _error -> invalid("provenance decoding failed", payload)
  end

  def decode_map(payload), do: invalid("provenance envelope must be an object", payload)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = provenance) do
    %{
      "schema" => provenance.schema,
      "components" => provenance.components,
      "fingerprint" => provenance.fingerprint
    }
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = provenance) do
    with {:ok, valid_provenance} <- validate(provenance) do
      {:ok, valid_provenance |> to_wire_map() |> Canonical.encode()}
    end
  end

  def canonical_binary(value), do: invalid("value is not provenance", value)

  defp build_components(options) do
    Enum.reduce_while(@component_names, {:ok, %{}}, fn name, {:ok, components} ->
      descriptor = Keyword.fetch!(options, String.to_existing_atom(name))

      case build_component(name, descriptor) do
        {:ok, component} -> {:cont, {:ok, Map.put(components, name, component)}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp build_component(name, {:available, attributes}) do
    if valid_attributes?(attributes) do
      body = %{"attributes" => normalized_copy(attributes), "status" => "available"}
      {:ok, Map.put(body, "fingerprint", component_fingerprint(name, body))}
    else
      invalid("available provenance attributes are invalid or unbounded", attributes)
    end
  end

  defp build_component(name, {:unavailable, reason}) when reason in @unavailable_reasons do
    body = %{"reason" => Atom.to_string(reason), "status" => "unavailable"}
    {:ok, Map.put(body, "fingerprint", component_fingerprint(name, body))}
  end

  defp build_component(name, {:redacted, policy_fingerprint}) do
    if valid_digest?(policy_fingerprint) do
      body = %{"policy_fingerprint" => policy_fingerprint, "status" => "redacted"}
      {:ok, Map.put(body, "fingerprint", component_fingerprint(name, body))}
    else
      invalid("redacted provenance requires a policy fingerprint", policy_fingerprint)
    end
  end

  defp build_component(_name, descriptor),
    do: invalid("provenance component descriptor is invalid", descriptor)

  defp decode_v1(payload) do
    with {:ok, options} <- decode_components(Map.get(payload, "components")),
         {:ok, provenance} <- new(options),
         true <- provenance.fingerprint == Map.get(payload, "fingerprint") do
      {:ok, provenance}
    else
      false -> invalid("provenance aggregate fingerprint does not match", payload)
      {:error, _error} = failure -> failure
      _other -> invalid("provenance envelope is invalid", payload)
    end
  end

  defp decode_components(components) do
    if exact_components?(components) do
      Enum.reduce_while(@component_names, {:ok, []}, fn name, {:ok, options} ->
        component = Map.fetch!(components, name)

        case decode_component(name, component) do
          {:ok, descriptor} ->
            option = {String.to_existing_atom(name), descriptor}
            {:cont, {:ok, [option | options]}}

          {:error, _error} = failure ->
            {:halt, failure}
        end
      end)
    else
      invalid("provenance must contain the exact v1 components", components)
    end
  end

  defp decode_component(
         name,
         %{
           "attributes" => attributes,
           "fingerprint" => fingerprint,
           "status" => "available"
         } = component
       )
       when map_size(component) == 3 do
    verify_decoded_component(name, component, {:available, attributes}, fingerprint)
  end

  defp decode_component(
         name,
         %{
           "fingerprint" => fingerprint,
           "reason" => reason,
           "status" => "unavailable"
         } = component
       )
       when map_size(component) == 3 do
    with {:ok, decoded_reason} <- decode_reason(reason) do
      verify_decoded_component(name, component, {:unavailable, decoded_reason}, fingerprint)
    end
  end

  defp decode_component(
         name,
         %{
           "fingerprint" => fingerprint,
           "policy_fingerprint" => policy_fingerprint,
           "status" => "redacted"
         } = component
       )
       when map_size(component) == 3 do
    verify_decoded_component(name, component, {:redacted, policy_fingerprint}, fingerprint)
  end

  defp decode_component(_name, component),
    do: invalid("provenance component has an invalid shape", component)

  defp verify_decoded_component(name, component, descriptor, fingerprint) do
    with {:ok, rebuilt} <- build_component(name, descriptor),
         true <- rebuilt == component and fingerprint == rebuilt["fingerprint"] do
      {:ok, descriptor}
    else
      false -> invalid("provenance component fingerprint does not match", component)
      {:error, _error} = failure -> failure
    end
  end

  defp decode_reason("not_provided"), do: {:ok, :not_provided}
  defp decode_reason("not_built"), do: {:ok, :not_built}
  defp decode_reason("not_supported"), do: {:ok, :not_supported}
  defp decode_reason("collection_failed"), do: {:ok, :collection_failed}
  defp decode_reason(reason), do: invalid("provenance unavailability reason is unknown", reason)

  defp valid_component?({name, component}) do
    case decode_component(name, component) do
      {:ok, _descriptor} -> true
      {:error, _error} -> false
    end
  end

  defp exact_components?(components) when is_map(components) and not is_struct(components),
    do:
      map_size(components) == length(@component_names) and
        Enum.sort(Map.keys(components)) == @component_names

  defp exact_components?(_components), do: false

  defp valid_attributes?(attributes),
    do: Value.valid_map?(attributes, @max_component_entries, @max_component_bytes)

  defp normalized_copy(attributes) do
    attributes
    |> Canonical.encode()
    |> Jason.decode!()
  end

  defp component_fingerprint(name, body) do
    fingerprint(%{"component" => name, "evidence" => body, "schema" => @component_schema})
  end

  defp aggregate_fingerprint(components),
    do: fingerprint(%{"components" => components, "schema" => @schema})

  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(Canonical.encode(value))
    |> Base.encode16(case: :lower)
  end

  defp valid_digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp runtime_attributes do
    %{
      "elixir_version" => System.version(),
      "erts_version" => :erlang.system_info(:version) |> List.to_string(),
      "insider_version" => application_version(),
      "otp_release" => System.otp_release()
    }
  end

  defp target_attributes do
    {os_family, os_name} = :os.type()

    %{
      "architecture" => :erlang.system_info(:system_architecture) |> List.to_string(),
      "os_family" => Atom.to_string(os_family),
      "os_name" => Atom.to_string(os_name),
      "word_size_bytes" => :erlang.system_info(:wordsize)
    }
  end

  defp application_version do
    case Application.spec(:insider, :vsn) do
      nil -> "unavailable"
      version -> to_string(version)
    end
  end

  defp exact_keyword_subset?(options, allowed) do
    ProtocolValue.bounded_list?(options, length(allowed)) and Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Keyword.keys(options) -- allowed == []
  end

  defp exact_keyword_set?(options, expected) do
    ProtocolValue.bounded_list?(options, length(expected)) and Keyword.keyword?(options) and
      Enum.sort(Keyword.keys(options)) == Enum.sort(expected)
  end

  defp exact_struct?(provenance),
    do:
      map_size(provenance) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(provenance)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp unsupported_schema(schema) do
    {:error,
     Error.new(:unsupported_provenance_schema, "provenance schema is unsupported", %{
       received: ProtocolValue.summary(schema)
     })}
  end

  defp invalid(message, value) do
    {:error, Error.new(:invalid_provenance, message, %{received: ProtocolValue.summary(value)})}
  end
end
