defmodule Insider.Collector.Otel.Span do
  @moduledoc false

  # The `otel.span` event: one finished OpenTelemetry span as an
  # `insider.event/v1`. Both span sources build it here, so they share one
  # shape and one validation:
  #
  # - spans the node's own SDK ends, captured by `Insider.Collector.Otel`
  #   (`decode/2` reads the SDK's span record);
  # - spans a caller hands in with `Insider.Collector.Otel.ingest/1`, such as
  #   a frontend's spans decoded from OTLP.
  #
  # A span map has string keys: `"trace_id"` (32 lowercase hex digits, not
  # all zero), `"span_id"` and `"parent_span_id"` (16, or `nil` for a root),
  # `"name"`, `"span_kind"`, `"status"`, `"status_message"`, `"service"`,
  # `"scope"`, `"start_time_us"` (Unix microseconds), `"duration_us"`,
  # `"attributes"` (a map), and `"pid"` (the process that ended the span, or
  # `nil`). `event/2` validates it.
  #
  # The span's attributes are rendered, bounded and with credentials masked,
  # into the payload only in the rich profile (`Insider.Collector.Rich`);
  # the strict profile collects neither them nor the status message.

  alias Insider.Collector.GraphqlOutcome
  alias Insider.Collector.Rich
  alias Insider.Event

  @kinds ["internal", "server", "client", "producer", "consumer"]
  @statuses ["ok", "error", "unset"]
  @name_bytes 256
  @label_bytes 128
  @status_message_bytes 1_024
  # Payload budget for the rendered span attributes: Event v1 allows 8 KiB.
  @attributes_bytes 7_000
  @max_time_us 253_402_300_799_999_999
  @trace_id ~r/\A[0-9a-f]{32}\z/
  @span_id ~r/\A[0-9a-f]{16}\z/

  @type context :: %{
          required(:node) => String.t(),
          required(:boot_id) => String.t(),
          required(:clock_id) => String.t(),
          required(:authority) => String.t(),
          required(:source_instance_id) => String.t(),
          required(:sequence) => pos_integer(),
          required(:rich) => boolean(),
          required(:capture) => String.t()
        }

  @doc """
  The route a span's attributes name: its `http.route` or `next.route`
  template, else the path of its `url.path` or `http.target` (without a
  query or fragment), when it starts with `/` and is printable ASCII of at
  most 128 bytes. A request a middleware redirects before routing names
  only its path. `nil` otherwise.
  """
  @spec route(term()) :: String.t() | nil
  def route(attributes) when is_map(attributes) do
    # The SDK keys attributes by atom; an ingested span map by string.
    [
      {"http.route", :"http.route"},
      {"next.route", :"next.route"},
      {"url.path", :"url.path"},
      {"http.target", :"http.target"}
    ]
    |> Enum.find_value(fn {key, atom} ->
      case Map.get(attributes, key) || Map.get(attributes, atom) do
        text when is_binary(text) ->
          path = text |> String.split(["?", "#"], parts: 2) |> hd()
          if byte_size(path) <= 128 and String.match?(path, ~r/\A\/[\x21-\x7E]*\z/), do: path

        _other ->
          nil
      end
    end)
  end

  def route(_attributes), do: nil

  @doc "The span kinds a span map may name."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The span statuses a span map may name."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Reads a finished span record of the OpenTelemetry Erlang SDK (1.x) into a
  span map. `service` is the tracer provider's `service.name`, `pid` the
  process that ended the span. Anything else is `:error`.
  """
  @spec decode(term(), String.t() | nil, pid() | nil) :: {:ok, map()} | :error
  def decode(
        {:span, trace_id, span_id, _tracestate, parent_span_id, _remote, name, kind, start_time,
         end_time, attributes, _events, _links, status, _flags, _recording, scope},
        service,
        pid
      )
      when is_integer(trace_id) and is_integer(span_id) and is_integer(start_time) and
             is_integer(end_time) do
    {status, message} = status(status)

    {:ok,
     %{
       "trace_id" => hex(trace_id, 32),
       "span_id" => hex(span_id, 16),
       "parent_span_id" => if(is_integer(parent_span_id), do: hex(parent_span_id, 16)),
       "name" => name,
       "span_kind" => kind(kind),
       "status" => status,
       "status_message" => message,
       "service" => service,
       "scope" => scope_name(scope),
       "start_time_us" => wall_us(start_time),
       "duration_us" =>
         System.convert_time_unit(max(end_time - start_time, 0), :native, :microsecond),
       "attributes" => attribute_map(attributes),
       "pid" => pid && pid |> :erlang.pid_to_list() |> to_string()
     }}
  end

  def decode(_record, _service, _pid), do: :error

  @doc """
  Builds and validates the `otel.span` event for `span` (a span map).
  Severity is `error` when the span's status is error or its GraphQL
  outcome (`attributes["graphql"]`, from `Insider.Collector.GraphqlOutcome`)
  has GraphQL errors, `warning` when the outcome has only payload
  validation errors, else `info`.
  """
  @spec event(map(), context()) :: {:ok, Event.t()} | {:error, atom()}
  def event(span, context) when is_map(span) do
    with {:ok, fields} <- fields(span) do
      graphql = GraphqlOutcome.from_span_attributes(fields.attributes)

      Event.new(
        id: context.source_instance_id <> "-" <> Integer.to_string(context.sequence, 36),
        node: context.node,
        boot_id: context.boot_id,
        source: "otel",
        kind: "otel.span",
        severity: severity(fields.status, graphql),
        monotonic_time: context.sequence,
        clock_id: context.clock_id,
        source_instance_id: context.source_instance_id,
        source_sequence: context.sequence,
        wall_time: DateTime.from_unix!(fields.start_us + fields.duration_us, :microsecond),
        subject: subject(fields.pid, context.node),
        causality: %{
          trace_id: fields.trace_id,
          span_id: fields.span_id,
          parent_event_id: nil,
          logical_operation_id: nil,
          process_generation: nil
        },
        attributes:
          %{
            "trace_id" => fields.trace_id,
            "span_id" => fields.span_id,
            "parent_span_id" => fields.parent_span_id,
            "name" => fields.name,
            "span_kind" => fields.kind,
            "status" => fields.status,
            "status_message" => if(context.rich, do: rendered(fields.status_message)),
            "service" => fields.service,
            "scope" => fields.scope,
            "capture" => context.capture,
            "start_wall_time" =>
              fields.start_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
            "duration_us" => fields.duration_us
          }
          |> put_graphql(graphql),
        payload:
          if(context.rich,
            do: %{"span_attributes" => Rich.render(fields.attributes, @attributes_bytes)}
          ),
        authority: context.authority,
        redactions: [],
        extensions: %{}
      )
    end
  rescue
    _error -> {:error, :invalid_span}
  catch
    _kind, _reason -> {:error, :invalid_span}
  end

  def event(_span, _context), do: {:error, :invalid_span}

  # A GraphQL error inside an HTTP 200 is an error even when the
  # instrumentation left the span's status unset; a payload that reports
  # only validation errors is a warning.
  defp severity("error", _graphql), do: :error

  defp severity(_status, graphql) do
    cond do
      GraphqlOutcome.error?(graphql) -> :error
      GraphqlOutcome.user_errors?(graphql) -> :warning
      true -> :info
    end
  end

  defp put_graphql(attributes, nil), do: attributes
  defp put_graphql(attributes, graphql), do: Map.put(attributes, "graphql", graphql)

  defp fields(span) do
    fields = %{
      trace_id: Map.get(span, "trace_id"),
      span_id: Map.get(span, "span_id"),
      parent_span_id: Map.get(span, "parent_span_id"),
      name: label(Map.get(span, "name"), @name_bytes),
      kind: Map.get(span, "span_kind"),
      status: Map.get(span, "status"),
      status_message: Map.get(span, "status_message"),
      service: label(Map.get(span, "service"), @label_bytes),
      scope: label(Map.get(span, "scope"), @label_bytes),
      start_us: Map.get(span, "start_time_us"),
      duration_us: Map.get(span, "duration_us"),
      attributes: Map.get(span, "attributes", %{}),
      pid: Map.get(span, "pid")
    }

    if id?(fields.trace_id, @trace_id) and id?(fields.span_id, @span_id) and
         (is_nil(fields.parent_span_id) or id?(fields.parent_span_id, @span_id)) and
         is_binary(fields.name) and fields.name != "" and String.valid?(fields.name) and
         fields.kind in @kinds and
         fields.status in @statuses and optional_text?(fields.status_message) and
         optional_text?(fields.service) and optional_text?(fields.scope) and
         is_integer(fields.start_us) and fields.start_us in 0..@max_time_us and
         is_integer(fields.duration_us) and fields.duration_us >= 0 and
         fields.start_us + fields.duration_us <= @max_time_us and is_map(fields.attributes) and
         pid_text?(fields.pid),
       do: {:ok, fields},
       else: {:error, :invalid_span}
  end

  defp id?(value, pattern),
    do: is_binary(value) and String.match?(value, pattern) and String.trim(value, "0") != ""

  defp optional_text?(nil), do: true
  defp optional_text?(value), do: is_binary(value) and String.valid?(value)

  defp pid_text?(nil), do: true
  defp pid_text?(value), do: is_binary(value) and byte_size(value) <= 64 and String.valid?(value)

  # Span names and resource labels are bounded text; an atom name (the SDK
  # accepts one) is its string.
  defp label(nil, _bytes), do: nil
  defp label(value, bytes) when is_atom(value), do: value |> Atom.to_string() |> label(bytes)

  defp label(value, bytes) when is_binary(value) do
    if String.valid?(value), do: cut(value, bytes), else: value
  end

  defp label(value, _bytes), do: value

  defp cut(value, bytes) when byte_size(value) <= bytes, do: value

  defp cut(value, bytes) do
    value |> binary_part(0, bytes) |> String.chunk(:valid) |> List.first("")
  end

  defp rendered(nil), do: nil

  defp rendered(message),
    do: Rich.render(cut(message, @status_message_bytes), @status_message_bytes)

  defp subject(nil, _node), do: nil

  defp subject(pid, node),
    do: %{"namespace" => "process", "scope" => node, "value" => pid}

  defp hex(value, digits) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(digits, "0")
  end

  defp status({:status, code, message}) when code in [:ok, :error, :unset] do
    message = if is_binary(message) and message != "", do: message
    {Atom.to_string(code), message}
  end

  defp status(_status), do: {"unset", nil}

  defp kind(kind) when kind in [:internal, :server, :client, :producer, :consumer],
    do: Atom.to_string(kind)

  defp kind(_kind), do: "internal"

  defp scope_name({:instrumentation_scope, name, _version, _schema_url}) when is_binary(name),
    do: name

  defp scope_name(_scope), do: nil

  # `opentelemetry:timestamp()` is `erlang:monotonic_time()`. It is turned
  # into a wall time on the OS clock, as the other collectors' events and
  # watched writes are (`Insider.Collector.Calls`), so they compare by time.
  defp wall_us(monotonic) do
    offset = System.os_time() - System.monotonic_time()
    System.convert_time_unit(monotonic + offset, :native, :microsecond)
  end

  defp attribute_map({:attributes, _count_limit, _length_limit, _dropped, map}) when is_map(map),
    do: map

  defp attribute_map(_attributes), do: %{}
end
