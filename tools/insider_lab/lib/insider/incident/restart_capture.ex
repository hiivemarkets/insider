defmodule Insider.Incident.RestartCapture do
  @moduledoc """
  Bounded orchestration for normalized restart-recurrence evidence.

  The caller supplies already-normalized, trusted events paired with trusted
  receipt times. This module fans each event to the recorder and detector in
  one causal step, freezes on the first recurrence finding, assembles one
  redacted capsule, validates its canonical bytes offline, and tears down its
  recorder before returning.

  Signal collection and authorization stay outside this boundary. In
  particular, this module does not turn fixture observations or caller claims
  into trusted Logger events.
  """

  alias Insider.Detectors.RestartRecurrence
  alias Insider.Event
  alias Insider.Incident.Capsule
  alias Insider.Incident.ExportPolicy
  alias Insider.Incident.RestartCapture.Owner
  alias Insider.Protocol.Error
  alias Insider.Provenance
  alias Insider.Recorder

  @maximum_events 64
  @maximum_bytes 1_048_576
  @required_options [
    :authority,
    :deadline_monotonic_ms,
    :export_policy,
    :max_bytes,
    :max_events,
    :observer_effect,
    :provenance
  ]
  @option_keys [:cancelled | @required_options]

  @type observation :: {Event.t(), integer()}
  @type accounting :: %{
          required(:cleanup) => %{required(:status) => :complete | :uncertain | :not_required},
          required(:consumption) => map(),
          required(:loss) => map(),
          required(:observer_effect) => String.t(),
          required(:truncation) => map()
        }
  @type result ::
          {:ok, [Capsule.t()], accounting()}
          | {:error, Error.t(), accounting()}
          | {:timeout, accounting()}
          | {:cancelled, accounting()}

  @spec capture([observation()], keyword()) :: result()
  def capture([], options) when is_list(options), do: capture_list([], options)

  def capture([_head | _tail] = observations, options) when is_list(options),
    do: capture_list(observations, options)

  def capture(_observations, options),
    do: invalid(options, System.monotonic_time(:microsecond), "invalid_capture_input")

  @doc false
  @spec start_async([observation()], keyword(), integer()) ::
          {:ok, pid(), reference()} | result()
  def start_async([], options, started_at)
      when is_list(options) and is_integer(started_at) do
    start_validated([], options, started_at)
  end

  def start_async([_head | _tail] = observations, options, started_at)
      when is_list(options) and is_integer(started_at) do
    start_validated(observations, options, started_at)
  end

  def start_async(_observations, options, started_at),
    do: invalid(options, started_at, "invalid_capture_input")

  defp start_validated(observations, options, started_at) do
    accounting = empty_accounting(options, started_at)

    with :ok <- validate_options(options),
         :continue <- lifecycle_disposition(options, accounting),
         :ok <- validate_observations(observations, options) do
      Owner.start(observations, options, accounting, started_at)
    else
      {:cancelled, accounting} -> {:cancelled, accounting}
      {:timeout, accounting} -> {:timeout, accounting}
      {:error, %Error{} = error} -> {:error, error, accounting}
    end
  rescue
    _error -> invalid(options, started_at, "capture_failed")
  catch
    _kind, _reason -> invalid(options, started_at, "capture_failed")
  end

  defp capture_list(observations, options) do
    started_at = System.monotonic_time(:microsecond)
    accounting = empty_accounting(options, started_at)

    with :ok <- validate_options(options),
         :continue <- lifecycle_disposition(options, accounting),
         :ok <- validate_observations(observations, options) do
      Owner.capture(observations, options, accounting, started_at)
    else
      {:cancelled, accounting} -> {:cancelled, accounting}
      {:timeout, accounting} -> {:timeout, accounting}
      {:error, %Error{} = error} -> {:error, error, accounting}
    end
  rescue
    _error -> invalid(options, System.monotonic_time(:microsecond), "capture_failed")
  catch
    _kind, _reason -> invalid(options, System.monotonic_time(:microsecond), "capture_failed")
  end

  @doc false
  @spec execute(
          Recorder.Handle.t(),
          reference(),
          [observation()],
          keyword(),
          accounting(),
          integer()
        ) ::
          result()
  def execute(handle, clock, observations, options, accounting, started_at) do
    with :ok <- before_deadline(options),
         {:ok, detector} <- RestartRecurrence.new(threshold: 3, window_ms: 1_000),
         {:ok, finding} <- detect(handle, clock, detector, observations, options) do
      finish_capture(handle, finding, options, accounting, started_at)
    else
      :quiet ->
        {:ok, [], finish_open_accounting(handle, accounting, started_at)}

      {:error, :deadline_exceeded} ->
        {:timeout, finish_open_accounting(handle, accounting, started_at)}

      {:error, reason} ->
        open_failure(handle, accounting, started_at, reason)
    end
  end

  defp detect(handle, clock, detector, observations, options) do
    detect_next(handle, clock, detector, observations, options)
  end

  defp detect_next(_handle, _clock, _detector, [], _options), do: :quiet

  defp detect_next(handle, clock, detector, [{event, observed_at} | rest], options) do
    :atomics.put(clock, 1, observed_at)

    with :ok <- before_deadline(options),
         :ok <- Recorder.record(handle, event),
         {next, outputs} <- RestartRecurrence.observe(detector, event, observed_at) do
      case outputs do
        [] -> detect_next(handle, clock, next, rest, options)
        [{:incident, finding}] -> freeze(handle, event, finding)
        [{:detector_error, _error}] -> {:error, :detector_failed}
        _outputs -> {:error, :ambiguous_detector_output}
      end
    else
      {:dropped, reason} -> {:error, recorder_reason(reason)}
      {:error, _reason} = error -> error
    end
  end

  defp freeze(handle, event, finding) do
    with {:ok, _freeze_id} <- Recorder.freeze(handle, event),
         {:ok, snapshot} <- Recorder.snapshot(handle) do
      {:ok, {snapshot, finding}}
    else
      {:error, reason} -> {:error, recorder_reason(reason)}
      {:pending, _metadata} -> {:error, :snapshot_pending}
    end
  end

  defp finish_capture(handle, {snapshot, finding}, options, accounting, started_at) do
    final_accounting = fn bytes -> finish_accounting(accounting, started_at, snapshot, bytes) end

    with :ok <- before_deadline(options),
         {:ok, capsule} <-
           Capsule.assemble(
             snapshot,
             finding,
             Keyword.fetch!(options, :provenance),
             export_policy: Keyword.fetch!(options, :export_policy),
             authority: Keyword.fetch!(options, :authority),
             artifacts: [],
             deadline_monotonic_us: Keyword.fetch!(options, :deadline_monotonic_ms) * 1_000
           ),
         {:ok, bytes} <- Capsule.canonical_binary(capsule),
         {:ok, ^capsule} <- Capsule.decode(bytes),
         true <- byte_size(bytes) <= Keyword.fetch!(options, :max_bytes),
         {:ok, status} <- Recorder.status(handle) do
      accounting = final_accounting.(byte_size(bytes))
      accounting = put_in(accounting, [:consumption, :recorder_status], status)
      {:ok, [capsule], accounting}
    else
      {:error, %Error{} = error} ->
        {:error, error, final_accounting.(0)}

      false ->
        {:error, limit_error("capsule_bytes"), final_accounting.(0)}

      _invalid ->
        failure(final_accounting.(0), started_at, "export_failed", false)
    end
  end

  defp validate_options(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: []

    valid =
      Keyword.keyword?(options) and keys == Enum.uniq(keys) and
        Enum.sort(keys -- [:cancelled]) == Enum.sort(@required_options) and
        Enum.all?(keys, &(&1 in @option_keys)) and
        match?(%ExportPolicy{}, Keyword.get(options, :export_policy)) and
        ExportPolicy.valid?(Keyword.get(options, :export_policy)) and
        match?({:ok, %Provenance{}}, Provenance.validate(Keyword.get(options, :provenance))) and
        valid_authority?(Keyword.get(options, :authority)) and
        bounded_string?(Keyword.get(options, :observer_effect), 256) and
        is_integer(Keyword.get(options, :deadline_monotonic_ms)) and
        Keyword.get(options, :max_events) in 1..@maximum_events and
        Keyword.get(options, :max_bytes) in 1..@maximum_bytes and
        is_boolean(Keyword.get(options, :cancelled, false))

    if valid, do: :ok, else: {:error, input_error("invalid_capture_options")}
  end

  defp validate_observations(observations, options) do
    validate_observation(observations, options, 0, nil, Keyword.fetch!(options, :max_events))
  end

  defp validate_observation([], _options, _count, _previous, _maximum), do: :ok

  defp validate_observation(_remaining, _options, count, _previous, maximum)
       when count >= maximum,
       do: {:error, limit_error("event_budget")}

  defp validate_observation(
         [{%Event{} = event, observed_at} | rest],
         options,
         count,
         previous,
         maximum
       )
       when is_integer(observed_at) do
    with :ok <- before_deadline(options),
         {:ok, _event} <- Event.validate(event),
         true <- is_nil(previous) or previous <= observed_at do
      validate_observation(rest, options, count + 1, observed_at, maximum)
    else
      false -> {:error, input_error("receipt_time_regressed")}
      {:error, :deadline_exceeded} = timeout -> timeout
      _invalid -> {:error, input_error("invalid_normalized_observation")}
    end
  end

  defp validate_observation(_observations, _options, _count, _previous, _maximum),
    do: {:error, input_error("invalid_normalized_observation")}

  defp lifecycle_disposition(options, accounting) do
    cond do
      Keyword.get(options, :cancelled, false) -> {:cancelled, accounting}
      deadline_expired?(options) -> {:timeout, accounting}
      true -> :continue
    end
  end

  defp failure(accounting, started_at, reason, finalize?) do
    error = Error.new(:operation_failed, "restart capture failed", %{reason: reason})

    accounting =
      if finalize?, do: finish_accounting(accounting, started_at, nil, 0), else: accounting

    {:error, error, accounting}
  end

  @doc false
  @spec open_timeout(Recorder.Handle.t(), accounting(), integer()) :: {:timeout, accounting()}
  def open_timeout(handle, accounting, started_at),
    do: {:timeout, finish_open_accounting(handle, accounting, started_at)}

  @doc false
  @spec open_cancelled(Recorder.Handle.t(), accounting(), integer()) ::
          {:cancelled, accounting()}
  def open_cancelled(handle, accounting, started_at),
    do: {:cancelled, finish_open_accounting(handle, accounting, started_at)}

  @doc false
  @spec open_failure(Recorder.Handle.t(), accounting(), integer(), term()) ::
          {:error, Error.t(), accounting()}
  def open_failure(handle, accounting, started_at, _reason \\ :capture_failed) do
    accounting = finish_open_accounting(handle, accounting, started_at)
    failure(accounting, started_at, "capture_worker_failed", false)
  end

  @doc false
  @spec recorder_failure(accounting(), integer(), term()) :: {:error, Error.t(), accounting()}
  def recorder_failure(accounting, started_at, _reason) do
    accounting =
      accounting
      |> finish_accounting(started_at, nil, 0)
      |> put_in([:loss, :gaps], [:recorder_unavailable])

    failure(accounting, started_at, "recorder_failed", false)
  end

  defp invalid(options, started_at, reason) do
    accounting = fallback_accounting(options, started_at)
    {:error, input_error(reason), accounting}
  end

  defp input_error(reason),
    do: Error.new(:invalid_request, "restart capture input is invalid", %{reason: reason})

  defp limit_error(reason),
    do: Error.new(:operation_failed, "restart capture exceeded a fixed budget", %{reason: reason})

  defp recorder_reason(reason) when reason in [:priority_protected, :eviction_limit, :oversized],
    do: :recorder_overloaded

  defp recorder_reason(reason), do: reason

  defp before_deadline(options) do
    if deadline_expired?(options), do: {:error, :deadline_exceeded}, else: :ok
  end

  defp deadline_expired?(options) do
    Keyword.fetch!(options, :deadline_monotonic_ms) <= System.monotonic_time(:millisecond)
  end

  defp empty_accounting(options, started_at) do
    %{
      cleanup: %{status: :not_required},
      consumption: %{capsule_bytes: 0, duration_us: 0, events: 0, resources: 0},
      loss: %{counters: %{}, gaps: []},
      observer_effect: Keyword.get(options, :observer_effect, "unavailable"),
      truncation: %{dropped_events: 0, status: :none},
      started_at_us: started_at
    }
  end

  defp fallback_accounting(options, started_at) when is_list(options),
    do: empty_accounting(options, started_at)

  defp fallback_accounting(_options, started_at),
    do: empty_accounting([], started_at)

  defp finish_accounting(accounting, started_at, nil, capsule_bytes) do
    %{
      accounting
      | consumption: %{
          capsule_bytes: capsule_bytes,
          duration_us: System.monotonic_time(:microsecond) - started_at,
          events: 0,
          resources: 1
        }
    }
  end

  defp finish_accounting(accounting, started_at, snapshot, capsule_bytes) do
    dropped =
      snapshot.counters
      |> Enum.reject(fn {name, _count} ->
        name in [:offered, :accepted, :duplicate, :freeze_idempotent]
      end)
      |> Enum.reduce(0, fn {_name, count}, total -> total + count end)

    %{
      accounting
      | consumption: %{
          capsule_bytes: capsule_bytes,
          duration_us: System.monotonic_time(:microsecond) - started_at,
          events: snapshot.retained_count,
          resources: 1
        },
        loss: %{counters: snapshot.counters, gaps: snapshot.gaps},
        truncation: %{
          dropped_events: dropped,
          status: if(dropped == 0, do: :none, else: :observed)
        }
    }
  end

  defp valid_authority?(authority) do
    is_list(authority) and Keyword.keyword?(authority) and
      Enum.sort(Keyword.keys(authority)) == [:capture_audit_id, :export_audit_id] and
      Enum.all?(Keyword.values(authority), &bounded_string?(&1, 256))
  end

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp finish_open_accounting(handle, accounting, started_at) do
    case Recorder.status(handle) do
      {:ok, status} ->
        snapshot = %{
          counters: status.counters,
          gaps: [],
          retained_count: status.retained_count
        }

        accounting = finish_accounting(accounting, started_at, snapshot, 0)
        put_in(accounting, [:consumption, :recorder_status], status)

      {:error, _reason} ->
        accounting
        |> finish_accounting(started_at, nil, 0)
        |> put_in([:loss, :gaps], [:recorder_unavailable])
    end
  end
end
