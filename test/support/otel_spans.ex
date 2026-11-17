defmodule Insider.Test.OtelSpans do
  @moduledoc false

  # Span records of the OpenTelemetry Erlang SDK (a test-only dependency),
  # built with the SDK's own record definitions, and a way to end one
  # through the SDK's span-end function exactly as its tracer does.

  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @doc "A recorded, sampled span record that has not ended."
  @spec open(keyword()) :: tuple()
  def open(fields) do
    span(
      trace_id: Keyword.get(fields, :trace_id, 0x0AF7651916CD43DD8448EB211C80319C),
      span_id: Keyword.get(fields, :span_id, 0x00F067AA0BA902B7),
      parent_span_id: Keyword.get(fields, :parent_span_id),
      name: Keyword.get(fields, :name, "GET /graphql"),
      kind: Keyword.get(fields, :kind, :server),
      start_time: Keyword.get(fields, :start_time, :erlang.monotonic_time()),
      # `otel_attributes`'s record: count limit, value length limit,
      # dropped count, and the map.
      attributes: {:attributes, 128, :infinity, 0, Keyword.get(fields, :attributes, %{})},
      status: Keyword.get(fields, :status),
      trace_flags: 1,
      is_recording: true,
      instrumentation_scope:
        {:instrumentation_scope, Keyword.get(fields, :scope, "opentelemetry_phoenix"), "2.0.1",
         :undefined}
    )
  end

  @doc """
  Ends `record` through `otel_span_utils:end_span/2` in a new process, the
  way the SDK's span store does, and returns the ended record and the pid.
  """
  @spec end_in_process(tuple(), integer() | :undefined) :: {tuple(), pid()}
  def end_in_process(record, timestamp \\ :undefined) do
    task = Task.async(fn -> {:otel_span_utils.end_span(record, timestamp), self()} end)
    Task.await(task)
  end

  @doc "Ends `record` through the SDK's span-end function in the calling process."
  @spec end_in_current(tuple()) :: tuple()
  def end_in_current(record), do: :otel_span_utils.end_span(record, :undefined)
end
