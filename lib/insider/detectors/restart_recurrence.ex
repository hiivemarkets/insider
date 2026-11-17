defmodule Insider.Detectors.RestartRecurrence do
  @moduledoc """
  Detects repeated abnormal supervisor child terminations without owning a process.

  The detector is a bounded streaming reducer. Callers supply their trusted receipt
  time in microseconds; an event's source-local ordering field is never interpreted
  as elapsed time.
  """

  alias Insider.Event
  alias Insider.Detectors.Input
  alias Insider.Finding, as: SharedFinding

  @version "1"
  @default_threshold 3
  @default_window_ms 1_000
  @default_max_keys 256
  @maximum_threshold 32
  @maximum_window_ms 60_000
  @maximum_keys 4_096
  @minimum_time -9_223_372_036_854_775_808
  @maximum_time 9_223_372_036_854_775_807

  defmodule State do
    @moduledoc """
    Opaque reducer state created by `Insider.Detectors.RestartRecurrence.new/1`.

    Treat the struct as a value: pass it to `observe/3` and keep the returned
    state. Its fields are not a public contract.
    """
    @enforce_keys [:threshold, :window_us, :max_keys]
    defstruct [:threshold, :window_us, :max_keys, :last_observed_at, buckets: %{}, seen: %{}]

    @type t :: %__MODULE__{
            threshold: pos_integer(),
            window_us: pos_integer(),
            max_keys: pos_integer(),
            last_observed_at: integer() | nil,
            buckets: map(),
            seen: map()
          }
  end

  defmodule Finding do
    @moduledoc false

    @enforce_keys [
      :schema,
      :detector,
      :detector_version,
      :fingerprint,
      :occurred_at_us,
      :count,
      :window_ms,
      :identity,
      :reason_fingerprints,
      :confidence,
      :severity,
      :trigger_event_id,
      :evidence_event_ids
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            schema: String.t(),
            detector: String.t(),
            detector_version: String.t(),
            fingerprint: String.t(),
            occurred_at_us: integer(),
            count: pos_integer(),
            window_ms: pos_integer(),
            identity: map(),
            reason_fingerprints: [String.t()],
            confidence: String.t(),
            severity: String.t(),
            trigger_event_id: String.t(),
            evidence_event_ids: [String.t()]
          }
  end

  defmodule Error do
    @moduledoc "A bounded explanation of why a target event could not be evaluated."
    @enforce_keys [:reason, :event_id]
    defstruct [:reason, :event_id, details: %{}]

    @type t :: %__MODULE__{reason: atom(), event_id: String.t() | nil, details: map()}
  end

  @type output :: {:incident, SharedFinding.t()} | {:detector_error, Error.t()}

  @spec new(keyword()) :: {:ok, State.t()} | {:error, :invalid_options}
  def new(options \\ [])

  def new(options) when is_list(options) do
    allowed = [:threshold, :window_ms, :max_keys]

    if Keyword.keyword?(options) and length(options) <= length(allowed) and
         Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      threshold = Keyword.get(options, :threshold, @default_threshold)
      window_ms = Keyword.get(options, :window_ms, @default_window_ms)
      max_keys = Keyword.get(options, :max_keys, @default_max_keys)

      if threshold in 2..@maximum_threshold and window_ms in 1..@maximum_window_ms and
           max_keys in 1..@maximum_keys do
        {:ok, %State{threshold: threshold, window_us: window_ms * 1_000, max_keys: max_keys}}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :invalid_options}
  end

  def new(_options), do: {:error, :invalid_options}

  @spec observe(State.t(), term(), integer()) :: {State.t(), [output()]}
  def observe(%State{} = state, event, observed_at_us)
      when is_integer(observed_at_us) and
             observed_at_us >= @minimum_time and observed_at_us <= @maximum_time do
    with {:ok, event} <- Event.validate(event) do
      observe_valid(state, event, observed_at_us)
    else
      {:error, _validation_error} -> error(state, Input.event_id(event), :invalid_event)
    end
  rescue
    _error -> error(state, Input.event_id(event), :evaluation_failed)
  end

  def observe(%State{} = state, event, _observed_at_us),
    do: error(state, Input.event_id(event), :invalid_observed_at)

  defp observe_valid(%State{last_observed_at: last} = state, event, now)
       when is_integer(last) and now < last,
       do: error(state, event.id, :time_regressed)

  defp observe_valid(state, event, now) do
    state = %{state | last_observed_at: now}

    case classify(event) do
      {:target, semantics} -> observe_target(state, event, semantics, now)
      :ignore -> {state, []}
      {:detector_error, reason} -> error(state, event.id, reason)
    end
  end

  defp classify(%Event{source: "logger", kind: "supervisor_child_terminated"} = event) do
    attributes = event.attributes

    with true <- trusted_projection?(attributes),
         "child_terminated" <- Map.get(attributes, "termination_context"),
         restart_type when restart_type in ["permanent", "transient", "temporary"] <-
           Map.get(attributes, "restart_type"),
         reason_class when reason_class in ["normal", "shutdown", "abnormal"] <-
           Map.get(attributes, "reason_class"),
         supervisor when is_binary(supervisor) and byte_size(supervisor) in 1..320 <-
           Map.get(attributes, "supervisor"),
         offender_id when is_binary(offender_id) and byte_size(offender_id) in 1..320 <-
           Map.get(attributes, "offender_id"),
         offender_pid when is_binary(offender_pid) and byte_size(offender_pid) in 1..128 <-
           Map.get(attributes, "offender_pid"),
         true <- Input.canonical_pid?(offender_pid),
         reason_fingerprint <- Map.get(attributes, "reason_fingerprint"),
         true <- Input.digest?(reason_fingerprint) do
      if restart_type == "temporary" or reason_class != "abnormal" do
        :ignore
      else
        {:target,
         %{
           key: {event.node, event.boot_id, supervisor, offender_id},
           offender_pid: offender_pid,
           reason_fingerprint: reason_fingerprint
         }}
      end
    else
      _value -> {:detector_error, :insufficient_restart_semantics}
    end
  end

  defp classify(%Event{}), do: :ignore

  defp trusted_projection?(attributes) do
    Map.get(attributes, "semantic_projection") == "otp_supervisor/v1" and
      Enum.any?(Map.get(attributes, "domain", []), &(&1 in ["otp", "sasl"]))
  end

  defp observe_target(state, event, semantics, now) do
    canonical = canonical_digest(event)
    {state, bucket} = prune(state, semantics.key, now)

    cond do
      match?({^canonical, _at}, Map.get(state.seen, event.id)) ->
        {state, []}

      Map.has_key?(state.seen, event.id) ->
        error(state, event.id, :event_id_conflict)

      bucket != nil and Enum.any?(bucket.observations, &(&1.pid == semantics.offender_pid)) ->
        remember_duplicate(state, semantics.key, bucket, event, semantics, canonical)

      bucket == nil and map_size(state.buckets) >= state.max_keys ->
        error(state, event.id, :key_capacity)

      true ->
        add_observation(state, bucket, event, semantics, canonical, now)
    end
  end

  defp add_observation(state, bucket, event, semantics, canonical, now) do
    bucket = bucket || %{active: false, last_at: now, observations: []}

    observation = %{
      at: now,
      canonical: canonical,
      duplicate: nil,
      event_id: event.id,
      pid: semantics.offender_pid,
      reason_fingerprint: semantics.reason_fingerprint
    }

    observations = Enum.take(bucket.observations ++ [observation], -state.threshold)
    should_emit = not bucket.active and length(observations) >= state.threshold

    bucket = %{
      bucket
      | active: bucket.active or should_emit,
        last_at: now,
        observations: observations
    }

    state =
      state
      |> put_bucket(semantics.key, bucket)
      |> rebuild_seen()

    if should_emit do
      {state, [{:incident, finding(state, event, semantics.key, observations, now)}]}
    else
      {state, []}
    end
  end

  defp prune(state, key, now) do
    cutoff = now - state.window_us

    buckets =
      state.buckets
      |> Enum.reduce(%{}, fn {bucket_key, bucket}, retained ->
        observations = Enum.reject(bucket.observations, &(&1.at < cutoff))

        if observations == [] do
          retained
        else
          active = bucket.active and now - bucket.last_at <= state.window_us
          Map.put(retained, bucket_key, %{bucket | active: active, observations: observations})
        end
      end)

    seen = Map.reject(state.seen, fn {_id, {_canonical, at}} -> at < cutoff end)
    state = %{state | buckets: buckets, seen: seen}
    {state, Map.get(buckets, key)}
  end

  defp put_bucket(state, key, bucket),
    do: %{state | buckets: Map.put(state.buckets, key, bucket)}

  defp remember_duplicate(state, key, bucket, event, semantics, canonical) do
    {observations, remembered?} =
      Enum.map_reduce(bucket.observations, false, fn observation, remembered? ->
        if observation.pid == semantics.offender_pid and is_nil(observation.duplicate) do
          duplicate = %{event_id: event.id, canonical: canonical, at: observation.at}
          {%{observation | duplicate: duplicate}, true}
        else
          {observation, remembered?}
        end
      end)

    if remembered? do
      state = state |> put_bucket(key, %{bucket | observations: observations}) |> rebuild_seen()
      {state, []}
    else
      error(state, event.id, :duplicate_id_capacity)
    end
  end

  defp rebuild_seen(state) do
    seen =
      state.buckets
      |> Map.values()
      |> Enum.flat_map(& &1.observations)
      |> Enum.flat_map(fn observation ->
        primary = {observation.event_id, {observation.canonical, observation.at}}

        case observation.duplicate do
          nil -> [primary]
          duplicate -> [primary, {duplicate.event_id, {duplicate.canonical, duplicate.at}}]
        end
      end)
      |> Map.new()

    %{state | seen: seen}
  end

  defp finding(state, event, {node, boot_id, supervisor, offender_id}, observations, now) do
    identity = %{
      "node" => node,
      "boot_id" => boot_id,
      "supervisor" => supervisor,
      "offender_id" => offender_id
    }

    SharedFinding.new!(
      detector: "restart_recurrence",
      detector_version: @version,
      occurred_at_us: now,
      confidence: "medium",
      severity: "error",
      trigger_event_id: event.id,
      evidence_event_ids: Enum.map(observations, & &1.event_id),
      details: %{
        "count" => length(observations),
        "window_ms" => div(state.window_us, 1_000),
        "identity" => identity,
        "reason_fingerprints" =>
          observations
          |> Enum.map(& &1.reason_fingerprint)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
      }
    )
  end

  defp canonical_digest(event) do
    {:ok, binary} = Event.canonical_binary(event)
    :crypto.hash(:sha256, binary)
  end

  defp error(state, id, reason) do
    {state, [{:detector_error, %Error{reason: reason, event_id: id}}]}
  end
end
