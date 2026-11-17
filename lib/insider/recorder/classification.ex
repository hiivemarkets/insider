defmodule Insider.Recorder.Classification do
  @moduledoc """
  Trusted, bounded sensitivity metadata bound to one exact recorded Event.

  Classifications are companions to recorder entries rather than Event fields.
  Their event digest prevents a classification from being moved to different
  evidence, and their policy fingerprint selects the exact field rules that
  must be used at export.
  """

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Redaction.Policy

  @schema "insider.recorder-classification/v1"
  @sensitivities [:public, :internal, :confidential, :secret]
  @wire_keys [
    "event_digest",
    "event_id",
    "fingerprint",
    "policy_fingerprint",
    "policy_id",
    "schema",
    "sensitivity"
  ]

  @enforce_keys [
    :schema,
    :event_id,
    :event_digest,
    :fingerprint,
    :sensitivity,
    :policy_id,
    :policy_fingerprint
  ]
  defstruct @enforce_keys

  defmodule Binding do
    @moduledoc """
    The recorder-wide sensitivity and redaction-policy binding that
    `Insider.Recorder.start_link/1` validates from its `classification:` option.
    Every recorded entry's `Insider.Recorder.Classification` is derived from it.
    """
    @enforce_keys [:sensitivity, :policy_id, :policy_fingerprint]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            sensitivity: atom(),
            policy_id: String.t(),
            policy_fingerprint: String.t()
          }
  end

  @type t :: %__MODULE__{
          schema: String.t(),
          event_id: String.t(),
          event_digest: String.t(),
          fingerprint: String.t(),
          sensitivity: :public | :internal | :confidential | :secret,
          policy_id: String.t(),
          policy_fingerprint: String.t()
        }

  @spec new(Event.t(), atom(), Policy.t()) :: {:ok, t()} | {:error, :invalid_classification}
  def new(event, sensitivity, policy) do
    with {:ok, binding} <- binding(sensitivity, policy),
         {:ok, canonical} <- Event.canonical_binary(event),
         {:ok, classification, _bytes} <- bind(event, canonical, binding) do
      {:ok, classification}
    else
      _other -> {:error, :invalid_classification}
    end
  rescue
    _error -> {:error, :invalid_classification}
  catch
    _kind, _reason -> {:error, :invalid_classification}
  end

  @doc false
  @spec binding(atom(), Policy.t()) :: {:ok, Binding.t()} | {:error, :invalid_classification}
  def binding(sensitivity, %Policy{} = policy) when sensitivity in @sensitivities do
    if Policy.valid?(policy) do
      {:ok,
       %Binding{
         sensitivity: sensitivity,
         policy_id: :binary.copy(policy.id),
         policy_fingerprint: :binary.copy(policy.fingerprint)
       }}
    else
      {:error, :invalid_classification}
    end
  rescue
    _error -> {:error, :invalid_classification}
  end

  def binding(_sensitivity, _policy), do: {:error, :invalid_classification}

  @doc false
  @spec valid_binding?(term()) :: boolean()
  def valid_binding?(%Binding{} = binding) do
    expected = struct(Binding)

    map_size(binding) == map_size(expected) and
      Enum.sort(Map.keys(binding)) == Enum.sort(Map.keys(expected)) and
      binding.sensitivity in @sensitivities and bounded_id?(binding.policy_id) and
      digest?(binding.policy_fingerprint)
  rescue
    _error -> false
  end

  def valid_binding?(_binding), do: false

  @doc false
  @spec bind(Event.t(), binary(), Binding.t()) ::
          {:ok, t(), binary()} | {:error, :invalid_classification}
  def bind(%Event{} = event, canonical, %Binding{} = binding) when is_binary(canonical) do
    if valid_binding?(binding) do
      classification = %__MODULE__{
        schema: @schema,
        event_id: :binary.copy(event.id),
        event_digest: event_digest(canonical),
        fingerprint: "pending",
        sensitivity: binding.sensitivity,
        policy_id: binding.policy_id,
        policy_fingerprint: binding.policy_fingerprint
      }

      classification = %{classification | fingerprint: classification_fingerprint(classification)}

      wire = wire_map(classification)
      {:ok, classification, Canonical.encode(wire)}
    else
      {:error, :invalid_classification}
    end
  rescue
    _error -> {:error, :invalid_classification}
  catch
    _kind, _reason -> {:error, :invalid_classification}
  end

  def bind(_event, _canonical, _binding), do: {:error, :invalid_classification}

  @spec validate(term(), Event.t(), binary()) :: {:ok, t()} | {:error, :invalid_classification}
  def validate(%__MODULE__{} = classification, %Event{} = event, canonical)
      when is_binary(canonical) do
    if exact_struct?(classification) and classification.schema == @schema and
         classification.event_id == event.id and
         classification.event_digest == event_digest(canonical) and
         classification.sensitivity in @sensitivities and bounded_id?(classification.policy_id) and
         digest?(classification.policy_fingerprint) and digest?(classification.fingerprint) and
         classification.fingerprint == classification_fingerprint(classification) do
      {:ok, classification}
    else
      {:error, :invalid_classification}
    end
  rescue
    _error -> {:error, :invalid_classification}
  catch
    _kind, _reason -> {:error, :invalid_classification}
  end

  def validate(_classification, _event, _canonical), do: {:error, :invalid_classification}

  @spec decode_map(term(), Event.t()) :: {:ok, t()} | {:error, :invalid_classification}
  def decode_map(payload, %Event{} = event)
      when is_map(payload) and not is_struct(payload) do
    with true <- map_size(payload) == length(@wire_keys),
         true <- Enum.sort(Map.keys(payload)) == @wire_keys,
         {:ok, sensitivity} <- sensitivity(payload["sensitivity"]),
         classification <-
           %__MODULE__{
             schema: payload["schema"],
             event_id: payload["event_id"],
             event_digest: payload["event_digest"],
             fingerprint: payload["fingerprint"],
             sensitivity: sensitivity,
             policy_id: payload["policy_id"],
             policy_fingerprint: payload["policy_fingerprint"]
           },
         {:ok, canonical} <- Event.canonical_binary(event) do
      validate(classification, event, canonical)
    else
      _other -> {:error, :invalid_classification}
    end
  rescue
    _error -> {:error, :invalid_classification}
  end

  def decode_map(_payload, _event), do: {:error, :invalid_classification}

  @doc false
  @spec to_wire_map(term(), Event.t()) :: {:ok, map()} | {:error, :invalid_classification}
  def to_wire_map(classification, %Event{} = event) do
    with {:ok, canonical} <- Event.canonical_binary(event),
         {:ok, valid} <- validate(classification, event, canonical) do
      {:ok, wire_map(valid)}
    else
      _other -> {:error, :invalid_classification}
    end
  end

  def to_wire_map(_classification, _event), do: {:error, :invalid_classification}

  defp wire_map(classification) do
    %{
      "schema" => classification.schema,
      "event_id" => classification.event_id,
      "event_digest" => classification.event_digest,
      "fingerprint" => classification.fingerprint,
      "sensitivity" => Atom.to_string(classification.sensitivity),
      "policy_id" => classification.policy_id,
      "policy_fingerprint" => classification.policy_fingerprint
    }
  end

  @doc false
  @spec canonical_binary(term(), Event.t()) :: {:ok, binary()} | {:error, :invalid_classification}
  def canonical_binary(classification, %Event{} = event) do
    with {:ok, canonical_event} <- Event.canonical_binary(event),
         {:ok, valid} <- validate(classification, event, canonical_event) do
      {:ok, valid |> wire_map() |> Canonical.encode()}
    else
      _other -> {:error, :invalid_classification}
    end
  end

  def canonical_binary(_classification, _event), do: {:error, :invalid_classification}

  defp sensitivity("public"), do: {:ok, :public}
  defp sensitivity("internal"), do: {:ok, :internal}
  defp sensitivity("confidential"), do: {:ok, :confidential}
  defp sensitivity("secret"), do: {:ok, :secret}
  defp sensitivity(_value), do: {:error, :invalid_classification}

  defp exact_struct?(classification) do
    expected = struct(__MODULE__)

    map_size(classification) == map_size(expected) and
      Enum.sort(Map.keys(classification)) == Enum.sort(Map.keys(expected))
  end

  defp event_digest(binary),
    do:
      :crypto.hash(:sha256, "insider.recorder-classification/event/v1\0" <> binary)
      |> Base.encode16(case: :lower)

  defp classification_fingerprint(classification) do
    %{
      "event_digest" => classification.event_digest,
      "event_id" => classification.event_id,
      "policy_fingerprint" => classification.policy_fingerprint,
      "policy_id" => classification.policy_id,
      "schema" => classification.schema,
      "sensitivity" => Atom.to_string(classification.sensitivity)
    }
    |> Canonical.encode()
    |> then(&("insider.recorder-classification/fingerprint/v1\0" <> &1))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp bounded_id?(value),
    do: is_binary(value) and byte_size(value) in 1..48 and String.valid?(value)
end
