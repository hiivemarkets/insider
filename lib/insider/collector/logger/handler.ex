defmodule Insider.Collector.Logger.Handler do
  @moduledoc false

  alias Insider.Collector.Gate
  alias Insider.Collector.Logger.Shape
  alias Insider.Collector.Rich
  alias Insider.Event
  alias Insider.Event.Canonical

  # Logger level to event severity; any other level is `:debug`.
  @severities %{
    emergency: :critical,
    alert: :critical,
    critical: :critical,
    error: :error,
    warning: :warning,
    notice: :info,
    info: :info,
    debug: :debug
  }

  @doc "The event severity of each Logger level, for the welcome document."
  @spec severities() :: %{atom() => Insider.Event.severity()}
  def severities, do: @severities

  @spec filter(map(), map()) :: map()
  def filter(log_event, config) do
    log(log_event, %{config: config})
    log_event
  rescue
    _error -> log_event
  catch
    _kind, _reason -> log_event
  end

  @spec log(map(), map()) :: :ok
  def log(log_event, %{config: config}) do
    # The record-time gate decides first; a dropped event costs nothing more.
    case Gate.logger(Map.get(config, :gate), log_event) do
      :record -> admit(log_event, config)
      :drop -> :ok
      {:exemplar, burst} -> exemplar(log_event, config, burst)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def log(_log_event, _config), do: :ok

  defp admit(log_event, config) do
    bump(config.stats, 1)
    if not config.include_payload, do: bump(config.stats, 7)
    if not config.include_message_semantics, do: bump(config.stats, 8)
    bump(config.stats, 9, suppressed_metadata_count(log_event, config))
    sequence = :atomics.add_get(config.sequence, 1, 1)

    case normalize(log_event, config, sequence) do
      {:ok, event} -> record(config, event)
      :error -> bump(config.stats, 4)
    end
  end

  @doc """
  Hands a burst's first message in an interval to the collector, as the
  logging process does after the gate's decision; the collector records
  it as the burst's exemplar. It is already counted as summarised, so it
  touches no handler counter. One that finds its inbox slot taken, or that
  cannot be normalised, is lost: counted in the collector's status, and
  marked in its burst, which the gate counts.
  """
  @spec exemplar(map(), map(), Gate.burst_key()) :: :ok
  def exemplar(log_event, config, burst) do
    sequence = :atomics.add_get(config.sequence, 1, 1)

    case normalize(log_event, config, sequence) do
      {:ok, event} ->
        slot = rem(sequence - 1, config.inbox_size)

        if not :ets.insert_new(config.inbox, {slot, sequence, {:exemplar, burst, event}}),
          do: lose(config, burst, 10)

      :error ->
        lose(config, burst, 11)
    end

    :ok
  end

  defp lose(config, burst, counter) do
    bump(config.stats, counter)
    _marked = Gate.logger_exemplar_lost(Map.get(config, :gate), burst)
    :ok
  end

  defp normalize(%{level: level, msg: message, meta: metadata}, config, sequence)
       when is_map(metadata) do
    label = report_label(message)

    Event.new(
      id: config.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: config.node,
      boot_id: config.boot_id,
      source: "logger",
      kind: kind(message, metadata, label, config.structural_only),
      severity: severity(level),
      monotonic_time: sequence,
      clock_id: config.clock_id,
      source_instance_id: config.source_instance_id,
      source_sequence: sequence,
      wall_time: wall_time(metadata, config.structural_only),
      subject: subject(metadata, config),
      causality: causality(metadata, config.structural_only),
      attributes:
        attributes(
          metadata,
          label,
          message,
          config.include_message_semantics,
          config.structural_only
        ),
      payload: payload(level, message, metadata, config),
      authority: config.authority,
      redactions: [],
      extensions: %{}
    )
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, _error} -> fallback(config, sequence, level, message, metadata, label)
    end
  end

  defp normalize(_event, _config, _sequence), do: :error

  defp suppressed_metadata_count(%{meta: metadata}, %{structural_only: true})
       when is_map(metadata),
       do: min(map_size(metadata), 256)

  # A rich payload carries the metadata, so none of it is suppressed.
  defp suppressed_metadata_count(_event, %{include_payload: true, rich: true}), do: 0

  defp suppressed_metadata_count(%{meta: metadata}, _config) when is_map(metadata) do
    known = [
      :domain,
      :time,
      :pid,
      :trace_id,
      :span_id,
      :parent_event_id,
      :logical_operation_id,
      :process_generation
    ]

    admitted = Enum.count(known, &Map.has_key?(metadata, &1))
    min(max(map_size(metadata) - admitted, 0), 256)
  end

  defp suppressed_metadata_count(_event, _config), do: 0

  defp fallback(config, sequence, level, message, metadata, label) do
    Event.new(
      id: config.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: config.node,
      boot_id: config.boot_id,
      source: "logger",
      kind: kind(message, metadata, label, config.structural_only),
      severity: severity(level),
      monotonic_time: sequence,
      clock_id: config.clock_id,
      source_instance_id: config.source_instance_id,
      source_sequence: sequence,
      wall_time: wall_time(metadata, config.structural_only),
      subject: subject(metadata, config),
      causality: causality(metadata, config.structural_only),
      attributes: fallback_attributes(config, message, metadata, label),
      payload: fallback_payload(message, config),
      authority: config.authority,
      redactions: [],
      extensions: %{}
    )
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, _error} -> :error
    end
  end

  defp record(config, event) do
    slot = rem(event.source_sequence - 1, config.inbox_size)

    if :ets.insert_new(config.inbox, {slot, event.source_sequence, event}) do
      bump(config.stats, 2)
    else
      bump(config.stats, 3)
    end
  end

  defp payload(level, message, metadata, %{include_payload: true, rich: true}),
    do: Rich.logger_payload(level, message, metadata)

  defp payload(_level, message, _metadata, %{include_payload: true}), do: Shape.encode(message)
  defp payload(_level, _message, _metadata, %{include_payload: false}), do: nil

  defp fallback_payload(message, %{include_payload: true}),
    do: %{"type" => message_type(message)}

  defp fallback_payload(_message, %{include_payload: false}), do: nil

  defp kind(_message, _metadata, _label, true), do: "logger_structural"

  defp kind(message, metadata, "proc_lib.crash", false) do
    if otp_domain?(metadata), do: "process_crashed", else: generic_report_kind(message, metadata)
  end

  defp kind(message, metadata, "supervisor.child_terminated", false) do
    if otp_domain?(metadata),
      do: "supervisor_child_terminated",
      else: generic_report_kind(message, metadata)
  end

  defp kind({:report, _report}, metadata, _label, false) do
    if otp_domain?(metadata), do: "otp_report", else: "logger_report"
  end

  defp kind({format, arguments}, _metadata, _label, false)
       when is_list(arguments) and is_list(format),
       do: "logger_format"

  defp kind(_message, _metadata, _label, false), do: "logger_message"

  defp generic_report_kind({:report, _report}, metadata) do
    if otp_domain?(metadata), do: "otp_report", else: "logger_report"
  end

  defp generic_report_kind(_message, _metadata), do: "logger_message"

  defp report_label({:report, %{label: {:proc_lib, :crash}}}), do: "proc_lib.crash"

  defp report_label({:report, %{label: {:supervisor, :child_terminated}}}),
    do: "supervisor.child_terminated"

  defp report_label({:report, %{label: label}}), do: bounded_label(label)
  defp report_label(_message), do: nil

  defp bounded_label(label) when is_atom(label), do: label |> Atom.to_string() |> truncate(128)

  defp bounded_label({left, right}) when is_atom(left) and is_atom(right),
    do: truncate(Atom.to_string(left) <> "." <> Atom.to_string(right), 128)

  defp bounded_label(_label), do: "other"

  defp severity(level), do: Map.get(@severities, level, :debug)

  defp wall_time(_metadata, true), do: nil

  defp wall_time(%{time: time}, false) when is_integer(time) do
    case DateTime.from_unix(time, :microsecond) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  defp wall_time(_metadata, false), do: nil

  # The process subject names its node, as Telemetry and span events do, so
  # one process reads the same in every source.
  defp subject(_metadata, %{structural_only: true}), do: nil

  defp subject(%{pid: pid}, config) when is_pid(pid) do
    %{
      "namespace" => "process",
      "scope" => config.node,
      "value" => pid |> :erlang.pid_to_list() |> to_string()
    }
  end

  defp subject(_metadata, _config), do: nil

  defp causality(_metadata, true), do: empty_causality()

  # Explicit `trace_id`/`span_id` metadata wins; otherwise the
  # OpenTelemetry SDK's own Logger metadata for the active span
  # (`otel_trace_id`, `otel_span_id`), in its W3C hex shape.
  defp causality(metadata, false) do
    %{
      trace_id: bounded_metadata(metadata, :trace_id) || otel_id(metadata, :otel_trace_id, 32),
      span_id: bounded_metadata(metadata, :span_id) || otel_id(metadata, :otel_span_id, 16),
      parent_event_id: bounded_metadata(metadata, :parent_event_id),
      logical_operation_id: bounded_metadata(metadata, :logical_operation_id),
      process_generation: bounded_metadata(metadata, :process_generation)
    }
  end

  defp otel_id(metadata, key, digits) do
    case Map.get(metadata, key) do
      value when is_binary(value) and byte_size(value) == digits ->
        if value =~ ~r/\A[0-9a-f]+\z/ and String.trim(value, "0") != "",
          do: :binary.copy(value)

      _other ->
        nil
    end
  end

  defp empty_causality,
    do: %{
      trace_id: nil,
      span_id: nil,
      parent_event_id: nil,
      logical_operation_id: nil,
      process_generation: nil
    }

  defp bounded_metadata(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) and byte_size(value) in 1..128 ->
        if String.valid?(value), do: :binary.copy(value), else: nil

      _value ->
        nil
    end
  end

  defp attributes(_metadata, _label, _message, _include_message_semantics, true),
    do: %{"ingress_profile" => "logger_structural/v1", "message_semantics" => "suppressed"}

  defp attributes(metadata, label, message, true, false) do
    base = %{
      "domain" => domain(metadata),
      "label" => label || "none",
      "message_type" => message_type(message)
    }

    Map.merge(base, supervisor_attributes(message, metadata, true))
  end

  # Future denied production profiles still construct this path in tests.  Do
  # not turn message-derived identifiers, labels, or fingerprints into a
  # secondary payload channel when that profile is later enabled.
  defp attributes(metadata, _label, _message, false, false) do
    %{
      "domain" => domain(metadata),
      "message_semantics" => "suppressed",
      "message_type" => "suppressed"
    }
  end

  defp fallback_attributes(%{structural_only: true}, _message, _metadata, _label),
    do: %{"ingress_profile" => "logger_structural/v1", "message_semantics" => "suppressed"}

  defp fallback_attributes(config, message, metadata, label) do
    Map.merge(
      %{
        "domain" => domain(metadata),
        "label" => label || "unknown",
        "message_type" => message_type(message),
        "payload_truncated" => true
      },
      supervisor_attributes(message, metadata, config.include_message_semantics)
    )
  end

  defp supervisor_attributes(
         {:report, %{label: {:supervisor, :child_terminated}, report: report}},
         metadata,
         true
       ) do
    if otp_domain?(metadata) do
      offender = report_value(report, :offender)

      compact(%{
        "semantic_projection" => "otp_supervisor/v1",
        "supervisor" => semantic_id(report_value(report, :supervisor)),
        "termination_context" => known_atom(report_value(report, :errorContext)),
        "offender_id" => semantic_id(report_value(offender, :id)),
        "offender_pid" => pid_id(report_value(offender, :pid)),
        "restart_type" => known_atom(report_value(offender, :restart_type)),
        "reason_class" => reason_class(report_value(report, :reason)),
        "reason_fingerprint" => reason_fingerprint(report_value(report, :reason))
      })
    else
      %{}
    end
  end

  defp supervisor_attributes(_message, _metadata, _include_message_semantics), do: %{}

  defp report_value(report, key) when is_map(report), do: Map.get(report, key)
  defp report_value(report, key) when is_list(report), do: report_value(report, key, 32)

  defp report_value(_report, _key), do: nil

  defp report_value(_report, _key, 0), do: nil
  defp report_value([], _key, _remaining), do: nil
  defp report_value([{key, value} | _tail], key, _remaining), do: value

  defp report_value([_entry | tail], key, remaining) when is_list(tail),
    do: report_value(tail, key, remaining - 1)

  defp report_value(_improper, _key, _remaining), do: nil

  defp semantic_id(nil), do: nil
  defp semantic_id(value) when is_atom(value), do: "atom:" <> Atom.to_string(value)

  defp semantic_id(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 256,
      do: "binary:" <> :binary.copy(value),
      else: nil
  end

  defp semantic_id(value)
       when is_integer(value) and value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
       do: "integer:" <> Integer.to_string(value)

  defp semantic_id(value) when is_pid(value), do: "pid:" <> pid_id(value)

  defp semantic_id(value) when is_tuple(value) and tuple_size(value) in 1..4 do
    components = value |> Tuple.to_list() |> Enum.map(&semantic_id/1)

    if Enum.all?(components, &is_binary/1) do
      digest =
        :crypto.hash(:sha256, Canonical.encode(%{"type" => "tuple", "items" => components}))

      "tuple-sha256:" <> Base.encode16(digest, case: :lower)
    end
  end

  defp semantic_id(_value), do: nil

  defp pid_id(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_id(_value), do: nil

  defp known_atom(value) when is_atom(value), do: value |> Atom.to_string() |> truncate(64)
  defp known_atom(_value), do: nil

  defp reason_class(:normal), do: "normal"
  defp reason_class(:shutdown), do: "shutdown"
  defp reason_class({:shutdown, _detail}), do: "shutdown"
  defp reason_class(nil), do: nil
  defp reason_class(_reason), do: "abnormal"

  defp reason_fingerprint(nil), do: nil

  defp reason_fingerprint(reason) do
    reason
    |> Shape.encode()
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    _error -> nil
  end

  defp compact(attributes) do
    Map.reject(attributes, fn {_key, value} -> is_nil(value) end)
  end

  defp domain(%{domain: domain}) when is_list(domain) do
    domain
    |> Enum.take(16)
    |> Enum.map(fn
      value when is_atom(value) -> value |> Atom.to_string() |> truncate(128)
      _value -> "other"
    end)
  end

  defp domain(_metadata), do: []

  defp otp_domain?(%{domain: domain}) when is_list(domain),
    do: Enum.any?(Enum.take(domain, 16), &(&1 in [:otp, :sasl]))

  defp otp_domain?(_metadata), do: false

  defp message_type({:report, _report}), do: "report"
  defp message_type({format, arguments}) when is_list(format) and is_list(arguments), do: "format"
  defp message_type({:string, _string}), do: "string"
  defp message_type(_message), do: "other"

  defp truncate(value, maximum) when byte_size(value) <= maximum, do: value
  defp truncate(value, maximum), do: binary_part(value, 0, maximum)

  defp bump(stats, index), do: :counters.add(stats, index, 1)

  defp bump(stats, index, amount) do
    if amount > 0, do: :counters.add(stats, index, amount), else: :ok
  end
end
