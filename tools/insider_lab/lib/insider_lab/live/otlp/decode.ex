defmodule Insider.Lab.Live.Otlp.Decode do
  @moduledoc false

  # Decodes an OTLP/HTTP trace export (`ExportTraceServiceRequest`, protobuf
  # or JSON) into the span maps `Insider.Collector.Otel.ingest/1` takes, one
  # per span:
  #
  #     %{"trace_id" => hex32, "span_id" => hex16, "parent_span_id" => hex16 | nil,
  #       "name" => text, "span_kind" => "server", "status" => "error",
  #       "status_message" => text | nil, "service" => text | nil,
  #       "scope" => text | nil, "start_time_us" => integer,
  #       "duration_us" => integer, "attributes" => %{key => value}, "pid" => nil}
  #
  # `service` is the resource's `service.name` and `scope` the instrumentation
  # scope's name. Attribute values are scalars or lists of scalars: an OTLP
  # key-value list is flattened into dotted keys (`a.b`), a list holding
  # anything but scalars becomes its JSON text, bytes become lowercase hex,
  # and values nest at most four levels deep. The decoder checks the wire
  # format and the identifiers' widths: a span with a malformed or all-zero
  # identifier is counted as rejected; the target applies the span contract
  # and the session's masking to the rest.
  #
  # Protobuf follows opentelemetry-proto `trace/v1/trace.proto` and
  # `common/v1/common.proto`; JSON follows the OTLP/HTTP JSON mapping
  # (lowerCamelCase names, hex trace and span ids, 64-bit integers as numbers
  # or strings, enums as integers).

  import Bitwise

  @max_depth 4
  # OTLP's SPAN_KIND_UNSPECIFIED (0) is treated as internal, as the spec says.
  @span_kinds %{2 => "server", 3 => "client", 4 => "producer", 5 => "consumer"}
  @statuses %{1 => "ok", 2 => "error"}
  @zero_trace_id <<0::128>>
  @zero_span_id <<0::64>>
  @min_int64 -0x8000_0000_0000_0000
  @max_uint64 0xFFFF_FFFF_FFFF_FFFF
  @max_double_integer trunc(1.7976931348623157e308)

  @type span :: %{String.t() => term()}
  @type decoded :: %{spans: [span()], rejected: non_neg_integer()}

  @doc """
  Decodes a protobuf `ExportTraceServiceRequest`: `{:ok, %{spans:, rejected:}}`
  or `{:error, reason}` for a body that is not one.
  """
  @spec protobuf(binary()) :: {:ok, decoded()} | {:error, String.t()}
  def protobuf(body) when is_binary(body) do
    body
    |> fields()
    |> repeated(1)
    |> Enum.map(&proto_resource_spans/1)
    |> collect()
  catch
    {:otlp_invalid, reason} -> {:error, reason}
  end

  @doc "Decodes an OTLP/JSON `ExportTraceServiceRequest`; see `protobuf/1`."
  @spec json(binary()) :: {:ok, decoded()} | {:error, String.t()}
  def json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = request} ->
        request
        |> json_list("resourceSpans")
        |> Enum.map(&json_resource_spans/1)
        |> collect()

      _invalid ->
        {:error, "malformed_json"}
    end
  catch
    {:otlp_invalid, reason} -> {:error, reason}
  end

  # Each span is `{:ok, span}` or `:rejected`.
  defp collect(resources) do
    outcomes = List.flatten(resources)
    spans = for {:ok, span} <- outcomes, do: span
    {:ok, %{spans: spans, rejected: length(outcomes) - length(spans)}}
  end

  defp span(service, scope, fields) do
    with {:ok, trace_id} <- identifier(fields.trace_id, 16, @zero_trace_id),
         {:ok, span_id} <- identifier(fields.span_id, 8, @zero_span_id),
         {:ok, parent} <- parent(fields.parent_span_id) do
      {:ok,
       %{
         "trace_id" => trace_id,
         "span_id" => span_id,
         "parent_span_id" => parent,
         "name" => fields.name,
         "span_kind" => Map.get(@span_kinds, fields.kind, "internal"),
         "status" => Map.get(@statuses, fields.status, "unset"),
         "status_message" => blank_to_nil(fields.status_message),
         "service" => service,
         "scope" => blank_to_nil(scope),
         "start_time_us" => div(fields.start, 1_000),
         "duration_us" => div(max(fields.end - fields.start, 0), 1_000),
         "attributes" => flatten(fields.attributes),
         "pid" => nil
       }}
    else
      :error -> :rejected
    end
  end

  defp identifier(bytes, size, zero) when byte_size(bytes) == size and bytes != zero,
    do: {:ok, Base.encode16(bytes, case: :lower)}

  defp identifier(_bytes, _size, _zero), do: :error

  # An absent or empty parent id makes a root; a supplied one must be valid.
  defp parent(<<>>), do: {:ok, nil}
  defp parent(bytes), do: identifier(bytes, 8, @zero_span_id)

  defp service(%{"service.name" => name}) when is_binary(name), do: blank_to_nil(name)
  defp service(_attributes), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # Nested key-value lists become dotted keys; a list stays a list only while
  # it holds scalars.
  defp flatten(attributes), do: attributes |> flatten("") |> Map.new()

  defp flatten(attributes, prefix) do
    Enum.flat_map(attributes, fn
      {key, %{} = nested} -> flatten(nested, prefix <> key <> ".")
      {key, list} when is_list(list) -> [{prefix <> key, scalar_list(list)}]
      {key, value} -> [{prefix <> key, value}]
    end)
  end

  defp scalar_list(list) do
    if Enum.all?(list, &(not is_map(&1) and not is_list(&1))),
      do: list,
      else: Jason.encode!(list)
  end

  defp invalid!(reason), do: throw({:otlp_invalid, reason})

  ## Protobuf

  defp proto_resource_spans(bytes) do
    fields = fields(bytes)

    service =
      case singular(fields, 1, 2) do
        nil -> nil
        resource -> resource |> fields() |> repeated(1) |> proto_attributes(0) |> service()
      end

    for scope_spans <- repeated(fields, 2),
        scope_fields = fields(scope_spans),
        scope = proto_scope(singular(scope_fields, 1, 2)),
        span <- repeated(scope_fields, 2) do
      span(service, scope, proto_span(fields(span)))
    end
  end

  defp proto_scope(nil), do: ""
  defp proto_scope(bytes), do: bytes |> fields() |> singular(1, 2) |> proto_text()

  defp proto_span(fields) do
    status = fields |> singular(15, 2) |> proto_fields()

    %{
      trace_id: singular(fields, 1, 2) || "",
      span_id: singular(fields, 2, 2) || "",
      parent_span_id: singular(fields, 4, 2) || "",
      name: fields |> singular(5, 2) |> proto_text(),
      kind: singular(fields, 6, 0) || 0,
      start: singular(fields, 7, 1) || 0,
      end: singular(fields, 8, 1) || 0,
      attributes: fields |> repeated(9) |> proto_attributes(0),
      status: singular(status, 3, 0) || 0,
      status_message: status |> singular(2, 2) |> proto_text()
    }
  end

  defp proto_fields(nil), do: []
  defp proto_fields(bytes), do: fields(bytes)

  defp proto_attributes(key_values, depth) do
    Map.new(key_values, fn bytes ->
      fields = fields(bytes)
      {fields |> singular(1, 2) |> proto_text(), proto_value(singular(fields, 2, 2), depth)}
    end)
  end

  defp proto_value(nil, _depth), do: nil
  defp proto_value(_bytes, depth) when depth >= @max_depth, do: invalid!("value_too_deep")

  defp proto_value(bytes, depth) do
    case bytes |> fields() |> List.last() do
      {1, 2, text} -> proto_text(text)
      {2, 0, flag} -> flag != 0
      {3, 0, integer} -> signed(integer)
      {4, 1, bits} -> double(bits)
      {5, 2, array} -> array |> fields() |> repeated(1) |> Enum.map(&proto_value(&1, depth + 1))
      {6, 2, list} -> list |> fields() |> repeated(1) |> proto_attributes(depth + 1)
      {7, 2, raw} -> Base.encode16(raw, case: :lower)
      _empty_or_unknown -> nil
    end
  end

  defp proto_text(nil), do: ""

  defp proto_text(bytes) do
    if String.valid?(bytes), do: bytes, else: invalid!("invalid_utf8")
  end

  defp signed(value) when value >= 1 <<< 63, do: value - (1 <<< 64)
  defp signed(value), do: value

  # NaN and the infinities do not match a float pattern on the BEAM.
  defp double(bits) do
    case <<bits::little-64>> do
      <<value::little-float-64>> -> value
      _not_finite -> nil
    end
  end

  # The last occurrence of a singular field wins; a known field with another
  # wire type makes the message malformed.
  defp singular(fields, number, wire_type) do
    Enum.reduce(fields, nil, fn
      {^number, ^wire_type, value}, _previous -> value
      {^number, _other, _value}, _previous -> invalid!("wrong_wire_type")
      _field, previous -> previous
    end)
  end

  defp repeated(fields, number) do
    for {^number, type, value} <- fields do
      if type == 2, do: value, else: invalid!("wrong_wire_type")
    end
  end

  defp fields(binary), do: fields(binary, [])

  defp fields(<<>>, acc), do: Enum.reverse(acc)

  defp fields(binary, acc) do
    {key, rest} = varint(binary)
    {value, rest} = wire_value(key &&& 7, rest)
    fields(rest, [{key >>> 3, key &&& 7, value} | acc])
  end

  defp wire_value(0, binary), do: varint(binary)
  defp wire_value(1, <<value::little-64, rest::binary>>), do: {value, rest}
  defp wire_value(5, <<value::little-32, rest::binary>>), do: {value, rest}

  defp wire_value(2, binary) do
    case varint(binary) do
      {size, rest} when byte_size(rest) >= size ->
        <<value::binary-size(^size), rest::binary>> = rest
        {value, rest}

      _short ->
        invalid!("truncated")
    end
  end

  defp wire_value(type, _binary) when type in [1, 5], do: invalid!("truncated")
  defp wire_value(_type, _binary), do: invalid!("unsupported_wire_type")

  defp varint(binary), do: varint(binary, 0, 0)

  defp varint(<<1::1, bits::7, rest::binary>>, shift, acc) when shift < 63,
    do: varint(rest, shift + 7, acc ||| bits <<< shift)

  defp varint(<<0::1, bits::7, rest::binary>>, shift, acc),
    do: {(acc ||| bits <<< shift) &&& 0xFFFF_FFFF_FFFF_FFFF, rest}

  defp varint(_binary, _shift, _acc), do: invalid!("truncated")

  ## JSON

  defp json_resource_spans(%{} = resource_spans) do
    service =
      case resource_spans["resource"] do
        %{} = resource -> resource |> json_list("attributes") |> json_attributes(0) |> service()
        _absent -> nil
      end

    for scope_spans <- json_list(resource_spans, "scopeSpans"),
        scope = json_scope(scope_spans),
        span <- json_list(scope_spans, "spans") do
      span(service, scope, json_span(span))
    end
  end

  defp json_resource_spans(_other), do: invalid!("malformed_request")

  defp json_scope(%{"scope" => %{"name" => name}}) when is_binary(name), do: name
  defp json_scope(%{}), do: ""
  defp json_scope(_other), do: invalid!("malformed_request")

  defp json_span(%{} = span) do
    status = if is_map(span["status"]), do: span["status"], else: %{}

    %{
      trace_id: json_hex(span["traceId"]),
      span_id: json_hex(span["spanId"]),
      parent_span_id: json_hex(span["parentSpanId"]),
      name: json_string(span["name"]),
      kind: json_integer(span["kind"]),
      start: json_integer(span["startTimeUnixNano"]),
      end: json_integer(span["endTimeUnixNano"]),
      attributes: span |> json_list("attributes") |> json_attributes(0),
      status: json_integer(status["code"]),
      status_message: json_string(status["message"])
    }
  end

  defp json_span(_other), do: invalid!("malformed_request")

  defp json_list(map, key) do
    case map[key] do
      nil -> []
      list when is_list(list) -> list
      _other -> invalid!("malformed_request")
    end
  end

  # An absent or empty id is `""` (a parent becomes a root, a trace or span
  # id is rejected); malformed hex, or a value that is not a string, is
  # `:malformed`, which rejects the span whichever id it is.
  defp json_hex(nil), do: ""

  defp json_hex(text) when is_binary(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> :malformed
    end
  end

  defp json_hex(_other), do: :malformed

  defp json_string(text) when is_binary(text), do: text
  defp json_string(_absent), do: ""

  # OTLP integers are int64 (attribute values) or fixed64 (times): anything
  # outside both ranges is not OTLP, and is refused before arithmetic on it.
  defp json_integer(value) when is_integer(value) and value in @min_int64..@max_uint64, do: value
  defp json_integer(nil), do: 0

  defp json_integer(text) when is_binary(text) do
    case Integer.parse(text) do
      {value, ""} -> json_integer(value)
      _malformed -> invalid!("malformed_request")
    end
  end

  defp json_integer(_other), do: invalid!("malformed_request")

  defp json_attributes(key_values, depth) do
    Map.new(key_values, fn
      %{"key" => key} = key_value when is_binary(key) ->
        {key, json_value(key_value["value"], depth)}

      _other ->
        invalid!("malformed_request")
    end)
  end

  defp json_value(_value, depth) when depth >= @max_depth, do: invalid!("value_too_deep")
  defp json_value(%{"stringValue" => text}, _depth) when is_binary(text), do: text
  defp json_value(%{"boolValue" => flag}, _depth) when is_boolean(flag), do: flag
  defp json_value(%{"intValue" => integer}, _depth), do: json_integer(integer)
  defp json_value(%{"doubleValue" => number}, _depth) when is_float(number), do: number

  # ProtoJSON allows an integer spelling for a double: any integer a finite
  # double can hold is valid, beyond the 64-bit integer range; a larger one
  # is refused before `/ 1` would raise.
  defp json_value(%{"doubleValue" => number}, _depth)
       when is_integer(number) and abs(number) <= @max_double_integer,
       do: number / 1

  defp json_value(%{"doubleValue" => number}, _depth) when is_integer(number),
    do: invalid!("malformed_request")

  defp json_value(%{"arrayValue" => %{} = array}, depth),
    do: array |> json_list("values") |> Enum.map(&json_value(&1, depth + 1))

  defp json_value(%{"kvlistValue" => %{} = list}, depth),
    do: list |> json_list("values") |> json_attributes(depth + 1)

  defp json_value(%{"bytesValue" => text}, _depth) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, raw} -> Base.encode16(raw, case: :lower)
      :error -> invalid!("malformed_request")
    end
  end

  defp json_value(_empty_or_unknown, _depth), do: nil
end
