defmodule Insider.Invariant do
  @moduledoc """
  Evaluates application-declared invariants and records one bounded outcome event.

  Evaluation, disclosure, and recording remain independent. Only a disclosed
  violation whose trigger is frozen into a complete recorder snapshot is a
  confirmed incident.
  """

  alias Insider.Contract
  alias Insider.Contract.Invocation
  alias Insider.Detectors.Input
  alias Insider.Event
  alias Insider.Finding
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle
  alias Insider.Recorder.Snapshot
  alias Insider.Redaction
  alias Insider.Redaction.Outcome, as: RedactionOutcome
  alias Insider.Redaction.Policy

  @option_keys [
    :authority,
    :boot_id,
    :clock_id,
    :executor,
    :recorder,
    :redaction_policy,
    :source_instance_id
  ]

  defmodule Handle do
    @moduledoc """
    Evaluator handle created by `Insider.Invariant.new/1` and passed to
    `Insider.Invariant.check/5`. Its fields are not a public contract.
    """
    @enforce_keys [
      :authority,
      :boot_id,
      :clock_id,
      :executor,
      :recorder,
      :redaction_policy,
      :source_instance_id,
      :sequence
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule Outcome do
    @moduledoc "A local classified invariant outcome; it is not a portable wire contract."

    @enforce_keys [
      :schema,
      :verdict,
      :execution,
      :disclosure,
      :recording,
      :confirmed,
      :invocation
    ]
    defstruct @enforce_keys ++ [:freeze_id, :event, :finding, :snapshot, :redaction, :error]

    @type verdict :: :pass | :violation | :unknown
    @type execution :: :complete | :timeout | :exception | :unavailable | :overloaded | :invalid
    @type disclosure :: :clear | :redacted | :failed
    @type recording :: :recorded | :frozen | :dropped
    @type t :: %__MODULE__{}
  end

  @spec new(keyword()) :: {:ok, Handle.t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with true <- exact_options?(options),
         %RecorderHandle{} = recorder <- Keyword.fetch!(options, :recorder),
         executor when is_pid(executor) or is_atom(executor) <-
           Keyword.fetch!(options, :executor),
         %Policy{} = policy <- Keyword.fetch!(options, :redaction_policy),
         true <- Policy.valid?(policy),
         true <- bounded_configuration?(options) do
      {:ok,
       %Handle{
         authority: copy_option(options, :authority),
         boot_id: copy_option(options, :boot_id),
         clock_id: copy_option(options, :clock_id),
         executor: executor,
         recorder: recorder,
         redaction_policy: policy,
         source_instance_id: copy_option(options, :source_instance_id),
         sequence: :atomics.new(1, signed: false)
       }}
    else
      _error -> invalid("invariant evaluator options are invalid")
    end
  rescue
    _error -> invalid("invariant evaluator options are invalid")
  catch
    _kind, _reason -> invalid("invariant evaluator options are invalid")
  end

  def new(_options), do: invalid("invariant evaluator options are invalid")

  @spec check(Handle.t(), module(), atom() | String.t(), list(), keyword()) :: Outcome.t()
  def check(%Handle{} = handle, contract, invariant, arguments, invocation_options) do
    invocation =
      Contract.invoke(
        handle.executor,
        contract,
        :invariant,
        invariant,
        arguments,
        invocation_options
      )

    {verdict, execution} = classify(invocation)
    {disclosure, sanitized, redaction, disclosure_error} = disclose(invocation, handle)
    event = event(handle, invocation, verdict, execution, disclosure, sanitized)

    record(
      handle,
      invocation,
      verdict,
      execution,
      disclosure,
      sanitized,
      redaction,
      disclosure_error,
      event
    )
  rescue
    _error -> failed_outcome()
  catch
    _kind, _reason -> failed_outcome()
  end

  def check(_handle, _contract, _invariant, _arguments, _options), do: failed_outcome()

  @doc """
  Resolves a frozen invariant outcome after its recorder post-trigger window.

  Pending windows remain unconfirmed and can be passed back later. Only the
  exact trigger event retained by the supplied recorder can produce a finding.
  """
  @spec resolve(Handle.t(), Outcome.t()) :: Outcome.t()
  def resolve(
        %Handle{} = handle,
        %Outcome{
          verdict: :violation,
          execution: :complete,
          disclosure: :clear,
          recording: :frozen,
          confirmed: false,
          freeze_id: freeze_id,
          invocation: %Invocation{},
          event: %Event{}
        } = outcome
      )
      when is_binary(freeze_id) do
    case Recorder.snapshot(handle.recorder) do
      {:ok, %Snapshot{} = snapshot} -> confirm(outcome, snapshot)
      {:pending, _status} -> %{outcome | error: fixed_error("invariant snapshot is pending")}
      {:error, _reason} -> %{outcome | error: fixed_error("invariant snapshot is unavailable")}
    end
  rescue
    _error -> %{outcome | error: fixed_error("invariant snapshot is unavailable")}
  catch
    _kind, _reason -> %{outcome | error: fixed_error("invariant snapshot is unavailable")}
  end

  def resolve(
        %Handle{},
        %Outcome{
          verdict: :violation,
          execution: :complete,
          disclosure: :clear,
          recording: :frozen,
          confirmed: false
        } = outcome
      ) do
    %{outcome | error: fixed_error("invariant outcome is not bound to a recorder freeze")}
  end

  def resolve(_handle, %Outcome{} = outcome), do: outcome
  def resolve(_handle, _outcome), do: failed_outcome()

  defp disclose(invocation, handle) do
    case Redaction.redact(invocation.value, invocation.sensitivity, handle.redaction_policy) do
      {:ok, %RedactionOutcome{} = outcome} ->
        status =
          if outcome.manifest == [] and outcome.value === invocation.value,
            do: :clear,
            else: :redacted

        {status, outcome.value, outcome, nil}

      {:error, %Error{} = error} ->
        {:failed, nil, nil, error}
    end
  end

  defp event(handle, invocation, verdict, execution, disclosure, payload) do
    sequence = :atomics.add_get(handle.sequence, 1, 1)

    Event.new!(
      id: handle.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: Atom.to_string(node()),
      boot_id: handle.boot_id,
      source: "contract",
      kind: event_kind(verdict, execution, disclosure, payload),
      severity: event_severity(verdict, execution, disclosure, payload),
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: handle.clock_id,
      source_instance_id: handle.source_instance_id,
      source_sequence: sequence,
      wall_time: nil,
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{
        "semantic_projection" => "application_invariant/v1",
        "contract_id" => invocation.contract["id"],
        "contract_version" => invocation.contract["version"],
        "contract_fingerprint" => invocation.contract["fingerprint"],
        "invariant" => invocation.name,
        "invocation_status" => Atom.to_string(invocation.status),
        "invocation_reason" => Atom.to_string(invocation.reason),
        "verdict" => Atom.to_string(verdict),
        "execution" => Atom.to_string(execution),
        "disclosure" => Atom.to_string(disclosure),
        "cleanup" => invocation.cleanup.status |> Atom.to_string(),
        "collection_policy_id" => handle.redaction_policy.id,
        "collection_policy_fingerprint" => handle.redaction_policy.fingerprint
      },
      payload: payload,
      authority: handle.authority,
      redactions: [],
      extensions: %{}
    )
  end

  defp record(
         handle,
         invocation,
         verdict,
         execution,
         disclosure,
         sanitized,
         redaction,
         disclosure_error,
         event
       ) do
    if disclosed_violation?(verdict, execution, disclosure, sanitized) do
      freeze(handle, invocation, redaction, event)
    else
      recording = if Recorder.record(handle.recorder, event) == :ok, do: :recorded, else: :dropped

      outcome(invocation, verdict, execution, disclosure, recording,
        event: event,
        redaction: redaction,
        error: disclosure_error
      )
    end
  end

  defp freeze(handle, invocation, redaction, event) do
    case Recorder.freeze(handle.recorder, event) do
      {:ok, freeze_id} ->
        pending =
          outcome(invocation, :violation, :complete, :clear, :frozen,
            freeze_id: freeze_id,
            event: event,
            redaction: redaction
          )

        resolve(handle, pending)

      {:error, _reason} ->
        outcome(invocation, :violation, :complete, :clear, :dropped,
          event: event,
          redaction: redaction,
          error: fixed_error("invariant trigger was not recorded")
        )
    end
  end

  defp confirm(outcome, snapshot) do
    expected_event = outcome.event

    with true <- snapshot.freeze_id == outcome.freeze_id,
         true <- snapshot.trigger_event_id == outcome.event.id,
         %{event: ^expected_event, received_at: received_at} <-
           Enum.find(snapshot.events, &(&1.event.id == outcome.event.id)) do
      finding = semantic_finding!(expected_event, received_at)
      %{outcome | confirmed: true, finding: finding, snapshot: snapshot, error: nil}
    else
      _error -> %{outcome | error: fixed_error("invariant snapshot does not contain its trigger")}
    end
  end

  defp semantic_finding!(event, received_at) do
    attributes = event.attributes

    Finding.new!(
      detector: "semantic_invariant",
      detector_version: "1",
      occurred_at_us: received_at,
      confidence: "high",
      severity: "error",
      trigger_event_id: event.id,
      evidence_event_ids: [event.id],
      details: %{
        "identity" => %{
          "contract_id" => attributes["contract_id"],
          "contract_version" => attributes["contract_version"],
          "contract_fingerprint" => attributes["contract_fingerprint"],
          "invariant" => attributes["invariant"]
        }
      }
    )
  end

  defp outcome(invocation, verdict, execution, disclosure, recording, options) do
    %Outcome{
      schema: "insider.invariant-outcome/v1",
      verdict: verdict,
      execution: execution,
      disclosure: disclosure,
      recording: recording,
      confirmed: Keyword.get(options, :confirmed, false),
      invocation: invocation,
      freeze_id: Keyword.get(options, :freeze_id),
      event: Keyword.get(options, :event),
      finding: Keyword.get(options, :finding),
      snapshot: Keyword.get(options, :snapshot),
      redaction: Keyword.get(options, :redaction),
      error: Keyword.get(options, :error)
    }
  end

  defp classify(%Invocation{status: :ok}), do: {:pass, :complete}
  defp classify(%Invocation{status: :violation}), do: {:violation, :complete}
  defp classify(%Invocation{status: :timeout}), do: {:unknown, :timeout}
  defp classify(%Invocation{status: :overloaded}), do: {:unknown, :overloaded}

  defp classify(%Invocation{reason: :callback_exception}), do: {:unknown, :exception}

  defp classify(%Invocation{reason: reason})
       when reason in [:executor_unavailable, :executor_failed],
       do: {:unknown, :unavailable}

  defp classify(%Invocation{}), do: {:unknown, :invalid}

  defp disclosed_violation?(:violation, :complete, :clear, false), do: true
  defp disclosed_violation?(_verdict, _execution, _disclosure, _value), do: false

  defp event_kind(:violation, :complete, :clear, false), do: "invariant_failed"
  defp event_kind(_verdict, _execution, _disclosure, _value), do: "invariant_checked"

  defp event_severity(:violation, :complete, :clear, false), do: :error
  defp event_severity(_verdict, :timeout, _disclosure, _value), do: :warning
  defp event_severity(_verdict, :exception, _disclosure, _value), do: :warning
  defp event_severity(_verdict, _execution, :failed, _value), do: :warning
  defp event_severity(_verdict, _execution, _disclosure, _value), do: :info

  defp exact_options?(options) do
    ProtocolValue.bounded_list?(options, length(@option_keys) + 1) and Keyword.keyword?(options) and
      length(options) == length(@option_keys) and
      Enum.sort(Keyword.keys(options)) == @option_keys
  end

  defp bounded_configuration?(options) do
    Input.bounded_string?(Keyword.fetch!(options, :authority), 128) and
      Input.bounded_string?(Keyword.fetch!(options, :boot_id), 128) and
      Input.bounded_string?(Keyword.fetch!(options, :clock_id), 128) and
      Input.bounded_string?(Keyword.fetch!(options, :source_instance_id), 96)
  end

  defp copy_option(options, key), do: options |> Keyword.fetch!(key) |> :binary.copy()

  defp failed_outcome do
    %Outcome{
      schema: "insider.invariant-outcome/v1",
      verdict: :unknown,
      execution: :invalid,
      disclosure: :failed,
      recording: :dropped,
      confirmed: false,
      invocation: nil,
      error: fixed_error("invariant evaluation failed")
    }
  end

  defp fixed_error(message), do: Error.new(:operation_failed, message)
  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}
end
