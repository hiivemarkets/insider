defmodule Insider.Event do
  @moduledoc """
  Versioned, bounded, portable evidence shared by collectors and detectors.

  Extensible vocabulary remains binary on both sides of the trust boundary.
  Only closed library-owned enums, such as severity, use atoms internally.
  Version 1 monotonic timestamps are signed microseconds. Wall time is display
  and provenance metadata and never establishes causality.
  """

  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Identity.Subject
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue

  @schema "insider.event/v1"
  @max_event_bytes 16_384
  @max_sequence 9_223_372_036_854_775_807
  @minimum_time -9_223_372_036_854_775_808
  @maximum_time 9_223_372_036_854_775_807
  @severities [:debug, :info, :warning, :error, :critical]
  @causality_keys [
    :trace_id,
    :span_id,
    :parent_event_id,
    :logical_operation_id,
    :process_generation
  ]
  @wire_keys [
    "schema",
    "id",
    "node",
    "boot_id",
    "source",
    "kind",
    "severity",
    "monotonic_time",
    "clock_id",
    "source_instance_id",
    "source_sequence",
    "wall_time",
    "subject",
    "causality",
    "attributes",
    "payload",
    "authority",
    "redactions",
    "extensions"
  ]
  @option_keys [
    :id,
    :node,
    :boot_id,
    :source,
    :kind,
    :severity,
    :monotonic_time,
    :clock_id,
    :source_instance_id,
    :source_sequence,
    :wall_time,
    :subject,
    :causality,
    :attributes,
    :payload,
    :authority,
    :redactions,
    :extensions
  ]

  @enforce_keys [
    :schema,
    :id,
    :node,
    :boot_id,
    :source,
    :kind,
    :severity,
    :monotonic_time,
    :clock_id,
    :source_instance_id,
    :source_sequence,
    :authority
  ]
  defstruct @enforce_keys ++
              [
                wall_time: nil,
                subject: nil,
                causality: %{
                  trace_id: nil,
                  span_id: nil,
                  parent_event_id: nil,
                  logical_operation_id: nil,
                  process_generation: nil
                },
                attributes: %{},
                payload: nil,
                redactions: [],
                extensions: %{}
              ]

  @type severity :: :debug | :info | :warning | :error | :critical
  @type causality :: %{
          required(:trace_id) => String.t() | nil,
          required(:span_id) => String.t() | nil,
          required(:parent_event_id) => String.t() | nil,
          required(:logical_operation_id) => String.t() | nil,
          required(:process_generation) => String.t() | nil
        }
  @type t :: %__MODULE__{
          schema: String.t(),
          id: String.t(),
          node: String.t(),
          boot_id: String.t(),
          source: String.t(),
          kind: String.t(),
          severity: severity(),
          monotonic_time: integer(),
          clock_id: String.t(),
          source_instance_id: String.t(),
          source_sequence: pos_integer(),
          wall_time: DateTime.t() | nil,
          subject: map() | nil,
          causality: causality(),
          attributes: map(),
          payload: term(),
          authority: String.t(),
          redactions: [map()],
          extensions: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    if ProtocolValue.bounded_list?(options, length(@option_keys)) and Keyword.keyword?(options) and
         Enum.sort(Keyword.keys(options)) == Enum.sort(@option_keys) do
      with {:ok, normalized_options} <- normalize_wall_time_option(options) do
        event = struct!(__MODULE__, Keyword.put(normalized_options, :schema, @schema))
        validate(event)
      end
    else
      invalid("event fields are missing, duplicated, or unknown", options)
    end
  rescue
    _error -> invalid("event construction failed", options)
  end

  def new(value), do: invalid("event options must be a keyword list", value)

  @spec new!(keyword()) :: t()
  def new!(options) do
    case new(options) do
      {:ok, event} -> event
      {:error, _error} -> raise ArgumentError, "invalid event"
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(event) do
    with {:ok, valid_event, _canonical} <- validate_encoded(event), do: {:ok, valid_event}
  end

  # Validating the aggregate byte bound already requires the canonical encoding,
  # so callers that need both must not pay for it twice. Collector hot paths use
  # this instead of validate/1 followed by canonical_binary/1. Public only so
  # those callers can reach it; it is not part of the published event contract.
  @doc false
  @spec validate_encoded(term()) :: {:ok, t(), binary()} | {:error, Error.t()}
  def validate_encoded(%__MODULE__{} = event) do
    if valid_fields?(event) do
      canonical = event |> to_wire_map() |> Canonical.encode()

      if byte_size(canonical) <= @max_event_bytes,
        do: {:ok, event, canonical},
        else: invalid("event exceeds its aggregate byte bound", event)
    else
      invalid("event contains invalid or unbounded fields", event)
    end
  rescue
    _error -> invalid("event validation failed", event)
  end

  def validate_encoded(value), do: invalid("value is not an event", value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(payload) when is_map(payload) and not is_struct(payload) do
    cond do
      Map.get(payload, "schema") != @schema ->
        unsupported_schema(Map.get(payload, "schema"))

      map_size(payload) != length(@wire_keys) ->
        invalid("event envelope must contain the exact v1 fields", payload)

      Enum.sort(Map.keys(payload)) != Enum.sort(@wire_keys) ->
        invalid("event envelope contains unknown or non-string fields", payload)

      true ->
        decode_v1(payload)
    end
  rescue
    _error -> invalid("event decoding failed", payload)
  end

  def decode_map(payload), do: invalid("event envelope must be an object", payload)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = event) do
    %{
      "schema" => event.schema,
      "id" => event.id,
      "node" => event.node,
      "boot_id" => event.boot_id,
      "source" => event.source,
      "kind" => event.kind,
      "severity" => encode_severity(event.severity),
      "monotonic_time" => event.monotonic_time,
      "clock_id" => event.clock_id,
      "source_instance_id" => event.source_instance_id,
      "source_sequence" => event.source_sequence,
      "wall_time" => encode_wall_time(event.wall_time),
      "subject" => event.subject,
      "causality" => causality_to_wire(event.causality),
      "attributes" => event.attributes,
      "payload" => event.payload,
      "authority" => event.authority,
      "redactions" => event.redactions,
      "extensions" => event.extensions
    }
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(event) do
    with {:ok, _valid_event, canonical} <- validate_encoded(event), do: {:ok, canonical}
  end

  defp decode_v1(payload) do
    with {:ok, severity} <- decode_severity(Map.get(payload, "severity")),
         {:ok, wall_time} <- decode_wall_time(Map.get(payload, "wall_time")),
         {:ok, causality} <- decode_causality(Map.get(payload, "causality")) do
      new(
        id: Map.get(payload, "id"),
        node: Map.get(payload, "node"),
        boot_id: Map.get(payload, "boot_id"),
        source: Map.get(payload, "source"),
        kind: Map.get(payload, "kind"),
        severity: severity,
        monotonic_time: Map.get(payload, "monotonic_time"),
        clock_id: Map.get(payload, "clock_id"),
        source_instance_id: Map.get(payload, "source_instance_id"),
        source_sequence: Map.get(payload, "source_sequence"),
        wall_time: wall_time,
        subject: Map.get(payload, "subject"),
        causality: causality,
        attributes: Map.get(payload, "attributes"),
        payload: Map.get(payload, "payload"),
        authority: Map.get(payload, "authority"),
        redactions: Map.get(payload, "redactions"),
        extensions: Map.get(payload, "extensions")
      )
    end
  end

  defp valid_fields?(event) do
    exact_event?(event) and event.schema == @schema and bounded_id?(event.id) and
      bounded_node?(event.node) and
      bounded_id?(event.boot_id) and vocabulary?(event.source) and vocabulary?(event.kind) and
      event.severity in @severities and valid_time?(event.monotonic_time) and
      bounded_id?(event.clock_id) and bounded_id?(event.source_instance_id) and
      valid_sequence?(event.source_sequence) and valid_wall_time?(event.wall_time) and
      valid_subject?(event.subject) and valid_causality?(event.id, event.causality) and
      Value.valid_map?(event.attributes, 64, 4_096) and Value.valid?(event.payload, 8_192) and
      bounded_id?(event.authority) and valid_redactions?(event.redactions) and
      valid_extensions?(event.extensions)
  end

  defp exact_event?(event),
    do:
      map_size(event) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(event)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp bounded_id?(value), do: bounded_string?(value, 128)
  defp bounded_node?(value), do: bounded_string?(value, 256)

  defp bounded_string?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)
  end

  defp vocabulary?(value) do
    bounded_string?(value, 128) and String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)
  end

  defp valid_time?(value), do: is_integer(value) and value in @minimum_time..@maximum_time
  defp valid_sequence?(value), do: is_integer(value) and value in 1..@max_sequence

  defp valid_wall_time?(nil), do: true

  defp valid_wall_time?(%DateTime{} = value) do
    case normalize_wall_time(value) do
      {:ok, ^value} -> true
      _other -> false
    end
  end

  defp valid_wall_time?(_value), do: false

  defp valid_subject?(nil), do: true

  defp valid_subject?(subject), do: Subject.valid?(subject)

  defp valid_causality?(event_id, causality)
       when is_map(causality) and not is_struct(causality) and map_size(causality) == 5 do
    Enum.sort(Map.keys(causality)) == Enum.sort(@causality_keys) and
      Enum.all?(causality, fn {_key, value} -> is_nil(value) or bounded_id?(value) end) and
      causality.parent_event_id != event_id
  end

  defp valid_causality?(_event_id, _causality), do: false

  defp valid_redactions?(value) do
    Value.valid_list?(value, 64, 4_096) and Enum.all?(value, &valid_redaction?/1)
  end

  defp valid_redaction?(
         %{"action" => action, "count" => count, "path" => path, "policy_id" => policy_id} =
           redaction
       )
       when map_size(redaction) == 4 do
    action in ["drop", "mask", "hash", "reference"] and is_integer(count) and count > 0 and
      Value.valid_list?(path, 8, 1_024) and Enum.all?(path, &bounded_id?/1) and
      bounded_id?(policy_id)
  end

  defp valid_redaction?(_value), do: false

  defp valid_extensions?(value) do
    Value.valid_map?(value, 32, 2_048) and
      Enum.all?(Map.keys(value), fn key ->
        vocabulary?(key) and String.contains?(key, ".") and
          not String.starts_with?(key, "insider.")
      end)
  end

  defp encode_severity(:debug), do: "debug"
  defp encode_severity(:info), do: "info"
  defp encode_severity(:warning), do: "warning"
  defp encode_severity(:error), do: "error"
  defp encode_severity(:critical), do: "critical"

  defp decode_severity("debug"), do: {:ok, :debug}
  defp decode_severity("info"), do: {:ok, :info}
  defp decode_severity("warning"), do: {:ok, :warning}
  defp decode_severity("error"), do: {:ok, :error}
  defp decode_severity("critical"), do: {:ok, :critical}
  defp decode_severity(value), do: invalid("event severity is unknown", value)

  defp encode_wall_time(nil), do: nil

  defp encode_wall_time(%DateTime{} = wall_time) do
    %{wall_time | microsecond: {elem(wall_time.microsecond, 0), 6}}
    |> DateTime.to_iso8601(:extended)
  end

  defp normalize_wall_time_option(options) do
    case Keyword.fetch!(options, :wall_time) do
      nil ->
        {:ok, options}

      %DateTime{} = wall_time ->
        case normalize_wall_time(wall_time) do
          {:ok, normalized} -> {:ok, Keyword.put(options, :wall_time, normalized)}
          :error -> invalid("wall_time must be a canonical UTC DateTime", wall_time)
        end

      value ->
        invalid("wall_time must be a canonical UTC DateTime", value)
    end
  end

  defp normalize_wall_time(%DateTime{} = wall_time) do
    expected = struct(DateTime)

    valid_shape =
      map_size(wall_time) == map_size(expected) and
        Enum.sort(Map.keys(wall_time)) == Enum.sort(Map.keys(expected))

    if valid_shape and valid_wall_time_scalars?(wall_time) and
         wall_time.calendar == Calendar.ISO and wall_time.time_zone == "Etc/UTC" and
         wall_time.zone_abbr == "UTC" and wall_time.utc_offset == 0 and wall_time.std_offset == 0 do
      wall_time
      |> encode_wall_time()
      |> DateTime.from_iso8601()
      |> case do
        {:ok, normalized, 0} -> {:ok, normalized}
        _error -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  # DateTime structs cross a trust boundary here and can be forged like any map.
  # Bound every scalar before DateTime.to_iso8601/2 can format attacker-sized
  # integers. Parsing the encoded value below remains the authority for calendar
  # validity (for example, the number of days in a month).
  defp valid_wall_time_scalars?(%DateTime{
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: {microsecond, precision}
       }) do
    is_integer(year) and year >= -9_999 and year <= 9_999 and
      is_integer(month) and month >= 1 and month <= 12 and
      is_integer(day) and day >= 1 and day <= 31 and
      is_integer(hour) and hour >= 0 and hour <= 23 and
      is_integer(minute) and minute >= 0 and minute <= 59 and
      is_integer(second) and second >= 0 and second <= 59 and
      is_integer(microsecond) and microsecond >= 0 and microsecond <= 999_999 and
      is_integer(precision) and precision >= 0 and precision <= 6
  end

  defp valid_wall_time_scalars?(_wall_time), do: false

  defp decode_wall_time(nil), do: {:ok, nil}

  defp decode_wall_time(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, wall_time, 0} -> {:ok, wall_time}
      _error -> invalid("wall_time must be UTC RFC3339", value)
    end
  end

  defp decode_wall_time(value), do: invalid("wall_time must be UTC RFC3339", value)

  defp causality_to_wire(causality) do
    %{
      "trace_id" => causality.trace_id,
      "span_id" => causality.span_id,
      "parent_event_id" => causality.parent_event_id,
      "logical_operation_id" => causality.logical_operation_id,
      "process_generation" => causality.process_generation
    }
  end

  defp decode_causality(value) when is_map(value) and not is_struct(value) do
    keys = Enum.map(@causality_keys, &Atom.to_string/1)

    if map_size(value) == length(keys) and Enum.all?(Map.keys(value), &(&1 in keys)) do
      {:ok,
       %{
         trace_id: Map.get(value, "trace_id"),
         span_id: Map.get(value, "span_id"),
         parent_event_id: Map.get(value, "parent_event_id"),
         logical_operation_id: Map.get(value, "logical_operation_id"),
         process_generation: Map.get(value, "process_generation")
       }}
    else
      invalid("event causality fields are invalid", value)
    end
  end

  defp decode_causality(value), do: invalid("event causality must be an object", value)

  defp unsupported_schema(value) do
    {:error,
     Error.new(:unsupported_event_schema, "event schema is not supported", %{
       received: ProtocolValue.summary(value),
       supported: [@schema]
     })}
  end

  defp invalid(message, value) do
    {:error,
     Error.new(:invalid_event, message, %{
       received: ProtocolValue.summary(value)
     })}
  end
end
