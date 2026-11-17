defmodule Insider.Detectors.MailboxGrowth do
  @moduledoc """
  Detects sustained mailbox growth with no observed reductions progress.

  This bounded streaming reducer consumes complete scalar process samples from
  `Insider.Collector.Poller`. A finding means only that the sampled mailbox grew
  while the cumulative reductions counter did not; it does not prove that no
  application, NIF, port, or external work completed.
  """

  alias Insider.Event
  alias Insider.Detectors.Input
  alias Insider.Finding
  alias Insider.Identity.Subject

  @version "1"
  @default_sample_count 3
  @default_window_ms 5_000
  @default_minimum_queue_length 10
  @default_minimum_growth 2
  @default_max_keys 256
  @maximum_samples 32
  @maximum_window_ms 60_000
  @maximum_counter 9_223_372_036_854_775_807
  @maximum_keys 4_096
  @maximum_ignored_subjects 32
  @minimum_time -9_223_372_036_854_775_808
  @maximum_time 9_223_372_036_854_775_807

  defmodule State do
    @moduledoc """
    Opaque reducer state created by `Insider.Detectors.MailboxGrowth.new/1`.

    Treat the struct as a value: pass it to `observe/3` and keep the returned
    state. Its fields are not a public contract.
    """
    @enforce_keys [
      :sample_count,
      :window_us,
      :minimum_queue_length,
      :minimum_growth,
      :max_keys,
      :ignored_subjects
    ]
    defstruct @enforce_keys ++ [:last_observed_at, buckets: %{}, seen: %{}]

    @type t :: %__MODULE__{
            sample_count: pos_integer(),
            window_us: pos_integer(),
            minimum_queue_length: pos_integer(),
            minimum_growth: pos_integer(),
            max_keys: pos_integer(),
            ignored_subjects: [Subject.t()],
            last_observed_at: integer() | nil,
            buckets: map(),
            seen: map()
          }
  end

  defmodule Error do
    @moduledoc "A bounded explanation of why a sample could not be evaluated."
    @enforce_keys [:reason, :event_id]
    defstruct [:reason, :event_id, details: %{}]

    @type t :: %__MODULE__{reason: atom(), event_id: String.t() | nil, details: map()}
  end

  @type output :: {:finding, Finding.t()} | {:detector_error, Error.t()}

  @spec new(keyword()) :: {:ok, State.t()} | {:error, :invalid_options}
  def new(options \\ [])

  def new(options) when is_list(options) do
    allowed = [
      :sample_count,
      :window_ms,
      :minimum_queue_length,
      :minimum_growth,
      :max_keys,
      :ignored_subjects
    ]

    if exact_options?(options, allowed) do
      config = %{
        sample_count: Keyword.get(options, :sample_count, @default_sample_count),
        window_ms: Keyword.get(options, :window_ms, @default_window_ms),
        minimum_queue_length:
          Keyword.get(options, :minimum_queue_length, @default_minimum_queue_length),
        minimum_growth: Keyword.get(options, :minimum_growth, @default_minimum_growth),
        max_keys: Keyword.get(options, :max_keys, @default_max_keys),
        ignored_subjects: Keyword.get(options, :ignored_subjects, [])
      }

      if valid_config?(config) do
        {:ok,
         %State{
           sample_count: config.sample_count,
           window_us: config.window_ms * 1_000,
           minimum_queue_length: config.minimum_queue_length,
           minimum_growth: config.minimum_growth,
           max_keys: config.max_keys,
           ignored_subjects: config.ignored_subjects
         }}
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
  def observe(%State{} = state, event, observed_at_us) do
    if valid_observed_at?(observed_at_us) do
      case Event.validate(event) do
        {:ok, event} -> observe_valid(state, event, observed_at_us)
        {:error, _validation_error} -> error(state, Input.event_id(event), :invalid_event)
      end
    else
      error(state, Input.event_id(event), :invalid_observed_at)
    end
  rescue
    _error -> error(state, Input.event_id(event), :evaluation_failed)
  end

  defp valid_observed_at?(value),
    do: is_integer(value) and value >= @minimum_time and value <= @maximum_time

  defp observe_valid(%State{last_observed_at: last} = state, event, now)
       when is_integer(last) and now < last,
       do: error(state, event.id, :time_regressed)

  defp observe_valid(state, event, now) do
    state = %{state | last_observed_at: now}

    case classify(event) do
      {:sample, semantics} -> observe_sample(state, event, semantics, now)
      {:unavailable, key, status} -> unavailable(state, event, key, status)
      {:gap, stream} -> evidence_gap(state, event, stream)
      :ignore -> {state, []}
      {:detector_error, reason, scope} -> state |> clear_scope(scope) |> error(event.id, reason)
    end
  end

  defp classify(%Event{source: "poller", kind: "process_sample"} = event) do
    with {:ok, identity} <- process_identity(event),
         "otp_process_scalar/v1" <- Map.get(event.attributes, "field_set"),
         {:ok, cycle_sequence} <- Input.cycle_sequence(Map.get(event.attributes, "cycle_id")),
         status when status in ["complete", "partial", "timeout", "failed", "protected", "exited"] <-
           Map.get(event.attributes, "probe_status") do
      identity =
        Map.merge(identity, %{
          cycle_sequence: cycle_sequence,
          source_sequence: event.source_sequence
        })

      classify_process_status(event, identity, status)
    else
      _value -> {:detector_error, :insufficient_sample, possible_scope(event)}
    end
  end

  defp classify(%Event{source: "poller", kind: "poll_cycle"} = event) do
    if Map.get(event.attributes, "field_set") == "poll_cycle/v1" and
         Map.get(event.attributes, "probe_status") == "truncated" do
      {:gap, {event.node, event.boot_id, event.source_instance_id}}
    else
      :ignore
    end
  end

  defp classify(%Event{}), do: :ignore

  defp classify_process_status(event, identity, "complete") do
    metrics = Map.get(event.attributes, "metrics")

    with metrics when is_map(metrics) <- metrics,
         queue when is_integer(queue) and queue in 0..@maximum_counter <-
           Map.get(metrics, "message_queue_len"),
         reductions when is_integer(reductions) and reductions in 0..@maximum_counter <-
           Map.get(metrics, "reductions_total") do
      {:sample, Map.merge(identity, %{queue: queue, reductions: reductions})}
    else
      _value -> {:detector_error, :insufficient_sample, {:key, identity.key}}
    end
  end

  defp classify_process_status(_event, identity, status),
    do: {:unavailable, identity.key, status}

  defp process_identity(%Event{subject: subject} = event) do
    with true <- Subject.valid?(subject),
         %{"namespace" => "process", "scope" => scope, "value" => pid} <- subject,
         true <- scope == event.node,
         true <- Input.canonical_pid?(pid) do
      generation = event.causality.process_generation
      key = {event.node, event.boot_id, pid, generation, event.source_instance_id}

      {:ok,
       %{
         key: key,
         subject: subject,
         identity: %{
           "node" => event.node,
           "boot_id" => event.boot_id,
           "process_pid" => pid,
           "process_generation" => generation
         }
       }}
    else
      _value -> {:error, :invalid_identity}
    end
  end

  defp possible_scope(event) do
    case process_identity(event) do
      {:ok, identity} -> {:key, identity.key}
      {:error, _reason} -> {:stream, stream(event)}
    end
  end

  defp observe_sample(state, event, semantics, now) do
    if semantics.subject in state.ignored_subjects do
      {state, []}
    else
      state = prune(state, now)
      canonical = canonical_digest(event)

      cond do
        match?({^canonical, _at}, Map.get(state.seen, event.id)) ->
          {state, []}

        Map.has_key?(state.seen, event.id) ->
          error(state, event.id, :event_id_conflict)

        not Map.has_key?(state.buckets, semantics.key) and
            map_size(state.buckets) >= state.max_keys ->
          error(state, event.id, :key_capacity)

        true ->
          observation = %{
            at: now,
            canonical: canonical,
            cycle_sequence: semantics.cycle_sequence,
            event_id: event.id,
            queue: semantics.queue,
            reductions: semantics.reductions,
            source_sequence: semantics.source_sequence
          }

          advance_bucket(state, event, semantics, observation)
      end
    end
  end

  defp advance_bucket(state, event, semantics, observation) do
    bucket = Map.get(state.buckets, semantics.key, %{active: false, observations: []})
    previous = List.last(bucket.observations)

    cond do
      is_nil(previous) ->
        put_observation(state, semantics.key, %{bucket | observations: [observation]}, [])

      observation.cycle_sequence <= previous.cycle_sequence or
          observation.source_sequence <= previous.source_sequence ->
        reset_with_error(state, event, semantics.key, observation, :sample_order_conflict)

      observation.cycle_sequence != previous.cycle_sequence + 1 ->
        reset_with_error(state, event, semantics.key, observation, :evidence_gap)

      observation.reductions < previous.reductions ->
        reset_with_error(state, event, semantics.key, observation, :reductions_regressed)

      observation.reductions > previous.reductions or observation.queue <= previous.queue ->
        put_observation(state, semantics.key, %{active: false, observations: [observation]}, [])

      bucket.active ->
        observations = bounded_append(bucket.observations, observation, state.sample_count)
        put_observation(state, semantics.key, %{bucket | observations: observations}, [])

      true ->
        observations = bounded_append(bucket.observations, observation, state.sample_count)
        should_emit = qualifies?(state, observations)
        bucket = %{bucket | active: should_emit, observations: observations}

        outputs =
          if should_emit,
            do: [{:finding, finding(state, event, semantics.identity, observations)}],
            else: []

        put_observation(state, semantics.key, bucket, outputs)
    end
  end

  defp reset_with_error(state, event, key, observation, reason) do
    buckets = Map.put(state.buckets, key, %{active: false, observations: [observation]})
    state = %{state | buckets: buckets}
    state |> rebuild_seen() |> error(event.id, reason)
  end

  defp qualifies?(state, observations) do
    first = hd(observations)
    last = List.last(observations)

    length(observations) == state.sample_count and last.queue >= state.minimum_queue_length and
      last.queue - first.queue >= state.minimum_growth and
      last.at - first.at <= state.window_us and first.reductions == last.reductions
  end

  defp bounded_append(observations, observation, maximum),
    do: Enum.take(observations ++ [observation], -maximum)

  defp put_observation(state, key, bucket, outputs) do
    state = %{state | buckets: Map.put(state.buckets, key, bucket)} |> rebuild_seen()
    {state, outputs}
  end

  defp unavailable(state, event, key, status) do
    state = clear_key(state, key)

    if ignored_key?(state, key) or status in ["protected", "exited"] do
      {state, []}
    else
      error(state, event.id, :sample_unavailable, %{"probe_status" => status})
    end
  end

  defp ignored_key?(state, {node, _boot_id, pid, _generation, _source_instance}) do
    Enum.any?(state.ignored_subjects, fn subject ->
      subject["scope"] == node and subject["value"] == pid
    end)
  end

  defp evidence_gap(state, event, stream) do
    state = clear_stream(state, stream)
    error(state, event.id, :evidence_gap)
  end

  defp clear_scope(state, {:key, key}), do: clear_key(state, key)
  defp clear_scope(state, {:stream, stream}), do: clear_stream(state, stream)

  defp clear_key(state, key) do
    state = %{state | buckets: Map.delete(state.buckets, key)}
    rebuild_seen(state)
  end

  defp clear_stream(state, stream) do
    buckets =
      Map.reject(state.buckets, fn {{node, boot_id, _pid, _generation, source_instance}, _bucket} ->
        {node, boot_id, source_instance} == stream
      end)

    %{state | buckets: buckets} |> rebuild_seen()
  end

  defp stream(event), do: {event.node, event.boot_id, event.source_instance_id}

  defp prune(state, now) do
    cutoff = now - state.window_us

    buckets =
      Enum.reduce(state.buckets, %{}, fn {key, bucket}, retained ->
        observations = Enum.reject(bucket.observations, &(&1.at < cutoff))

        if observations == [] do
          retained
        else
          Map.put(retained, key, %{bucket | observations: observations})
        end
      end)

    %{state | buckets: buckets} |> rebuild_seen()
  end

  defp rebuild_seen(state) do
    seen =
      state.buckets
      |> Map.values()
      |> Enum.flat_map(& &1.observations)
      |> Map.new(&{&1.event_id, {&1.canonical, &1.at}})

    %{state | seen: seen}
  end

  defp finding(state, event, identity, observations) do
    first = hd(observations)
    last = List.last(observations)

    Finding.new!(
      detector: "mailbox_growth",
      detector_version: @version,
      occurred_at_us: last.at,
      confidence: "medium",
      severity: "warning",
      trigger_event_id: event.id,
      evidence_event_ids: Enum.map(observations, & &1.event_id),
      details: %{
        "sample_count" => length(observations),
        "window_ms" => div(state.window_us, 1_000),
        "identity" => identity,
        "queue_start" => first.queue,
        "queue_end" => last.queue,
        "queue_growth" => last.queue - first.queue,
        "reductions_start" => first.reductions,
        "reductions_end" => last.reductions
      }
    )
  end

  defp canonical_digest(event) do
    {:ok, binary} = Event.canonical_binary(event)
    :crypto.hash(:sha256, binary)
  end

  defp exact_options?(options, allowed) do
    Keyword.keyword?(options) and length(options) <= length(allowed) and
      Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
      Enum.all?(Keyword.keys(options), &(&1 in allowed))
  end

  defp valid_config?(config) do
    config.sample_count in 3..@maximum_samples and config.window_ms in 1..@maximum_window_ms and
      config.minimum_queue_length in 1..@maximum_counter and
      config.minimum_growth in 1..@maximum_counter and config.max_keys in 1..@maximum_keys and
      is_list(config.ignored_subjects) and
      length(config.ignored_subjects) <= @maximum_ignored_subjects and
      Enum.all?(config.ignored_subjects, &ignored_subject?/1) and
      Enum.uniq(config.ignored_subjects) == config.ignored_subjects
  end

  defp ignored_subject?(%{"namespace" => "process", "scope" => scope, "value" => pid} = subject),
    do: Subject.valid?(subject) and is_binary(scope) and Input.canonical_pid?(pid)

  defp ignored_subject?(_subject), do: false

  defp error(state, id, reason, details \\ %{}) do
    {state, [{:detector_error, %Error{reason: reason, event_id: id, details: details}}]}
  end
end
