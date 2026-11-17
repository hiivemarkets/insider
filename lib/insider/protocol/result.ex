defmodule Insider.Protocol.Result do
  @moduledoc """
  A typed outcome that keeps values, failures, effects, streams, and cleanup separate.

  Non-success results may retain a bounded partial value when evidence became
  available before a later operational failure. The error remains authoritative
  for operational status; callers must not interpret a partial value as success.
  """

  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Request
  alias Insider.Protocol.Value

  @statuses [:ok, :error, :timeout, :cancelled, :unsupported]
  @confidences [:certain, :high, :medium, :low, :unknown]
  @cleanup_statuses [:not_required, :complete, :partial, :uncertain, :unknown]
  @truncation_reserve_bytes 512

  @enforce_keys [:schema, :protocol, :request_id, :operation, :status]
  defstruct [
    :schema,
    :protocol,
    :request_id,
    :operation,
    :status,
    :value,
    :error,
    :truncated,
    :target,
    :target_fingerprint,
    :code_fingerprint,
    :dependency_fingerprint,
    :runtime_fingerprint,
    :policy_fingerprint,
    effects: [],
    stdout: [],
    stderr: [],
    logger_events: [],
    compiler_events: [],
    trace_events: [],
    redactions: [],
    warnings: [],
    dropped: %{},
    duration_us: 0,
    requested_limits: %{},
    effective_limits: %{},
    consumption: %{},
    cleanup: %{status: :not_required},
    confidence: :certain,
    uncertainty: []
  ]

  @type status :: :ok | :error | :timeout | :cancelled | :unsupported

  @type t :: %__MODULE__{
          schema: String.t(),
          protocol: String.t(),
          request_id: String.t(),
          operation: String.t(),
          status: status(),
          value: term(),
          error: Error.t() | nil,
          effects: [Effect.t()],
          stdout: [term()],
          stderr: [term()],
          logger_events: [term()],
          compiler_events: [term()],
          trace_events: [term()],
          redactions: [term()],
          warnings: [String.t()],
          truncated: %{reason: atom(), dropped: non_neg_integer()} | nil,
          dropped: map(),
          duration_us: non_neg_integer(),
          requested_limits: map(),
          effective_limits: map(),
          consumption: map(),
          target: map(),
          target_fingerprint: String.t() | nil,
          code_fingerprint: String.t() | nil,
          dependency_fingerprint: String.t() | nil,
          runtime_fingerprint: String.t() | nil,
          policy_fingerprint: String.t() | nil,
          cleanup: map(),
          confidence: atom(),
          uncertainty: [String.t()]
        }

  @spec new(Request.t(), status(), keyword()) :: t()
  def new(%Request{} = request, status, options \\ []) when status in @statuses do
    limits = Map.from_struct(request.budget)

    result = %__MODULE__{
      schema: "insider.result/v1",
      protocol: request.protocol,
      request_id: request.request_id,
      operation: request.operation,
      status: status,
      value: Keyword.get(options, :value),
      error: Keyword.get(options, :error),
      effects: Keyword.get(options, :effects, []),
      stdout: Keyword.get(options, :stdout, []),
      stderr: Keyword.get(options, :stderr, []),
      logger_events: Keyword.get(options, :logger_events, []),
      compiler_events: Keyword.get(options, :compiler_events, []),
      trace_events: Keyword.get(options, :trace_events, []),
      redactions: Keyword.get(options, :redactions, []),
      warnings: Keyword.get(options, :warnings, []),
      dropped: Keyword.get(options, :dropped, %{}),
      duration_us: Keyword.get(options, :duration_us, 0),
      requested_limits: Keyword.get(options, :requested_limits, limits),
      effective_limits: Keyword.get(options, :effective_limits, limits),
      consumption: Keyword.get(options, :consumption, %{}),
      target: Keyword.get(options, :target, request.target),
      target_fingerprint: Keyword.get(options, :target_fingerprint),
      code_fingerprint: Keyword.get(options, :code_fingerprint),
      dependency_fingerprint: Keyword.get(options, :dependency_fingerprint),
      runtime_fingerprint: Keyword.get(options, :runtime_fingerprint),
      policy_fingerprint: Keyword.get(options, :policy_fingerprint),
      cleanup: Keyword.get(options, :cleanup, %{status: :not_required}),
      confidence: Keyword.get(options, :confidence, :certain),
      uncertainty: Keyword.get(options, :uncertainty, [])
    }

    validate!(result, request)
  end

  @spec truncate(t(), atom(), non_neg_integer()) :: t()
  def truncate(%__MODULE__{} = result, reason, dropped)
      when is_atom(reason) and is_integer(dropped) and dropped >= 0 do
    truncated = %{result | truncated: %{reason: reason, dropped: dropped}}

    with %{max_bytes: max_bytes} when is_integer(max_bytes) <- result.effective_limits,
         true <- bounded_payload?(truncated, max_bytes) do
      truncated
    else
      _other -> raise ArgumentError, "truncation metadata exceeds the result budget"
    end
  end

  defp validate!(result, request) do
    if valid?(result, request), do: result, else: raise(ArgumentError, "invalid protocol result")
  end

  @doc false
  @spec valid?(term(), term()) :: boolean()
  def valid?(%__MODULE__{} = result, %Request{} = request) do
    valid =
      with {:ok, effective_budget} <- effective_budget(result, request) do
        result.schema == "insider.result/v1" and result.protocol == request.protocol and
          result.request_id == request.request_id and result.operation == request.operation and
          coherent_status?(result) and
          is_list(result.effects) and
          Enum.all?(result.effects, &Effect.valid?/1) and
          aggregate_event_count(result) <= effective_budget.max_events and
          Enum.all?(stream_fields(result), &valid_stream?(&1, effective_budget.max_events)) and
          string_list?(result.warnings) and
          string_list?(result.uncertainty) and
          is_map(result.dropped) and
          is_integer(result.duration_us) and result.duration_us >= 0 and
          is_map(result.consumption) and result.target == request.target and
          valid_cleanup?(result.cleanup) and result.confidence in @confidences and
          fingerprints_valid?(result) and
          bounded_payload?(result, effective_budget.max_bytes - @truncation_reserve_bytes)
      else
        _error -> false
      end

    valid
  rescue
    _error -> false
  end

  def valid?(_result, _request), do: false

  defp coherent_status?(%{status: :ok, error: nil}), do: true
  defp coherent_status?(%{status: :cancelled, error: nil}), do: true

  defp coherent_status?(%{status: status, error: error})
       when status in [:error, :timeout, :unsupported],
       do: Error.valid?(error)

  defp coherent_status?(_result), do: false

  defp stream_fields(result) do
    [
      result.stdout,
      result.stderr,
      result.logger_events,
      result.compiler_events,
      result.trace_events,
      result.redactions
    ]
  end

  defp valid_stream?(value, maximum) when is_list(value), do: length(value) <= maximum
  defp valid_stream?(_value, _maximum), do: false

  defp aggregate_event_count(result) do
    length(result.effects) + Enum.sum(Enum.map(stream_fields(result), &safe_length/1))
  end

  defp safe_length(value) when is_list(value), do: length(value)
  defp safe_length(_value), do: 0

  defp string_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp string_list?(_value), do: false

  defp valid_cleanup?(%{status: status}) when status in @cleanup_statuses, do: true
  defp valid_cleanup?(_cleanup), do: false

  defp effective_budget(result, request) do
    requested = Map.from_struct(request.budget)

    with true <- result.requested_limits == requested,
         {:ok, %Budget{} = effective} <- Budget.new(result.effective_limits),
         true <-
           effective
           |> Map.from_struct()
           |> Enum.all?(fn {field, value} -> value <= Map.fetch!(requested, field) end) do
      {:ok, effective}
    else
      _other -> :error
    end
  end

  defp fingerprints_valid?(result) do
    Enum.all?(
      [
        result.target_fingerprint,
        result.code_fingerprint,
        result.dependency_fingerprint,
        result.runtime_fingerprint,
        result.policy_fingerprint
      ],
      &(is_nil(&1) or (is_binary(&1) and byte_size(&1) <= 256))
    )
  end

  defp bounded_payload?(result, max_bytes) do
    payload =
      result
      |> Map.from_struct()
      |> Map.drop([:schema, :protocol, :request_id, :operation, :status])

    Value.bounded_data?(payload, max_bytes)
  end
end
