defmodule Insider.Collector.Telemetry do
  @moduledoc """
  Bounded, allowlist-only ingestion of `:telemetry` events.

  Telemetry executes handlers synchronously in the emitting process. The
  installed handler therefore performs bounded scalar projection and one
  fixed-slot ETS write; this process drains records and maintains bounded
  lifecycle-pair health away from the caller's hot path.

  Each accepted event is attributed to the bounded PID of its synchronous
  emitter, allowing consumers to distinguish subject-correlated evidence from
  ambient events.

  With `rich: true` the handler records every metadata key as a rendered,
  bounded payload, and every measurement unless the policy selects some,
  with credentials masked. The live session's rich disclosure profile uses
  it; the policy's metadata allowlist then does not apply.
  """

  use GenServer

  alias Insider.Collector.Gate
  alias Insider.Collector.GraphqlClient
  alias Insider.Collector.Summary
  alias Insider.Collector.Telemetry.Handler
  alias Insider.Collector.Telemetry.Omitted
  alias Insider.Collector.Telemetry.Policy
  alias Insider.Collector.IngressProfile
  alias Insider.Event
  alias Insider.Protocol.Value, as: ProtocolValue
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle

  @required [:authority, :boot_id, :clock_id, :environment]
  @optional [
    :batch_size,
    :drain_interval_ms,
    :gate,
    :handler_id,
    :inbox_size,
    :nameable_measurements,
    :node,
    :rich,
    :source_instance_id
  ]
  @max_handler_rows 4_096
  # The slowest events each summary keeps as exemplars, besides its first
  # error.
  @exemplar_slowest 3
  @max_source_instance_id_bytes 114
  @max_nameable_measurements 16

  @spec start_link(RecorderHandle.t(), Policy.t(), keyword()) :: GenServer.on_start()
  def start_link(%RecorderHandle{} = recorder, %Policy{} = policy, options) do
    if Policy.valid?(policy) and valid_options?(options) do
      with {:ok, profile} <- IngressProfile.new(Keyword.fetch!(options, :environment)),
           true <- profile.observation_enabled do
        case GenServer.start_link(__MODULE__, {self(), recorder, policy, options}) do
          {:ok, pid} ->
            case GenServer.call(pid, :startup_result) do
              :ok -> {:ok, pid}
              {:error, reason} -> {:error, reason}
            end

          result ->
            result
        end
      else
        false -> {:error, :environment_denied}
        {:error, _reason} -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def start_link(_recorder, _policy, _options), do: {:error, :invalid_options}

  @spec start_link({RecorderHandle.t(), Policy.t(), keyword()}) :: GenServer.on_start()
  def start_link({%RecorderHandle{} = recorder, %Policy{} = policy, options}),
    do: start_link(recorder, policy, options)

  def start_link(_arguments), do: {:error, :invalid_options}

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server), do: safe_call(server, :status)

  @spec flush(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def flush(server), do: safe_call(server, :flush)

  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stop(server), do: safe_call(server, :stop)

  @doc """
  Detaches the handler, drains the inbox, records every pending summary
  interval, and stops: the stop a sealed session's last read relies on.
  Returns the handler cleanup and the collector's final status.
  """
  @spec seal(GenServer.server()) ::
          {:ok, %{handler: atom(), status: map()}} | {:error, :unavailable}
  def seal(server), do: safe_call(server, :seal)

  @doc false
  @spec reclaim_stale_handler(Policy.t(), atom() | String.t()) ::
          :reclaimed | :absent_or_live | :unavailable
  def reclaim_stale_handler(%Policy{event_names: event_names}, handler_id)
      when is_list(event_names) and (is_atom(handler_id) or is_binary(handler_id)) do
    case handler_lock(handler_id, fn ->
           rows =
             event_names
             |> Enum.flat_map(&:telemetry.list_handlers/1)
             |> Enum.filter(&(&1.id == handler_id))
             |> Enum.uniq()
             |> bounded_rows()

           if stale_rows?(rows) do
             case :telemetry.detach(handler_id) do
               :ok -> :reclaimed
               _other -> :unavailable
             end
           else
             :absent_or_live
           end
         end) do
      :aborted -> :unavailable
      result -> result
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  def reclaim_stale_handler(_policy, _handler_id), do: :unavailable

  @impl GenServer
  def init({owner, recorder, policy, options}) do
    Process.flag(:trap_exit, true)

    case config(owner, recorder, policy, options) do
      {:ok, state} ->
        case install_handler(state) do
          :ok ->
            {:ok,
             %{
               state
               | drain_token: schedule(state.drain_interval_ms),
                 startup_result: :ok
             }
             |> schedule_summary()}

          {:error, reason} ->
            {:ok, %{state | startup_result: {:error, reason}}}
        end

      {:error, reason} ->
        {:ok, %{drain_token: nil, owner: owner, startup_result: {:error, reason}}}
    end
  end

  @impl GenServer
  def handle_call(:startup_result, _from, %{startup_result: :ok} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, %{startup_result: {:error, reason}} = state),
    do: {:stop, :normal, {:error, reason}, state}

  def handle_call(:status, _from, state), do: {:reply, {:ok, status_map(state)}, state}

  def handle_call(:flush, _from, state) do
    {state, _drained} = drain_all(state)
    {:reply, {:ok, status_map(state)}, state}
  end

  # A final read before a session ends: the inbox is drained and every
  # pending summary interval is recorded now, so it is part of that read.
  # The interval timer keeps running; a later interval starts empty.
  def handle_call(:finalize, _from, state) do
    {state, _drained} = drain_all(state)
    state = if state.summaries, do: record_summaries(state), else: state
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:stop, _from, state) do
    cancel_timer(state.drain_token)
    handler = remove_owned_handler(state)
    {state, drained} = drain_all(state)

    cleanup = %{
      handler: handler,
      drained: drained,
      concurrent_emitters: :not_quiesced,
      drain_scope: :visible_after_detach,
      open_lifecycles: map_size(state.open_lifecycles),
      recorder_dropped: read(state.stats, 6),
      measurements_suppressed: read(state.stats, 8),
      metadata_suppressed: read(state.stats, 9)
    }

    {:stop, :normal, {:ok, cleanup}, %{state | drain_token: nil}}
  end

  # Like `:stop`, and every pending summary interval is recorded after the
  # drain, so no summarized sample is left without its summary.
  def handle_call(:seal, _from, state) do
    cancel_timer(state.drain_token)
    handler = remove_owned_handler(state)
    {state, _drained} = drain_all(state)
    state = if state.summaries, do: record_summaries(state), else: state
    reply = {:ok, %{handler: handler, status: status_map(state)}}
    {:stop, :normal, reply, %{state | drain_token: nil}}
  end

  @impl GenServer
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state),
    do: {:stop, reason, state}

  def handle_info({:drain, token}, %{drain_token: {_timer_ref, token}} = state) do
    state = drain_batch(state, state.batch_size)
    {:noreply, %{state | drain_token: schedule(state.drain_interval_ms)}}
  end

  def handle_info({:summary, token}, %{summaries: %{token: {_timer_ref, token}}} = state) do
    # The whole inbox, so the interval's exemplar candidates are in.
    {state, _drained} = drain_all(state)
    {:noreply, state |> record_summaries() |> schedule_summary()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A gate that summarises events gets one summary event per summarised
  # event name per interval, recorded here after the interval's inbox drain.
  # An interval without a sample records nothing; its absence is not a gap,
  # because the gate's `summarized` count shows every folded event.
  #
  # Each summary names its exemplars: up to `@exemplar_slowest` of the
  # interval's slowest events and its first error, recorded just before it,
  # each with its receipt. They are chosen from the candidates the emitting
  # processes sent (`Insider.Collector.Summary`); the rest are not recorded.
  # Every candidate lost on the way is counted: by reason in the status
  # (`exemplars_shed`, `exemplars_invalid` by the handler, `exemplars_late`,
  # `exemplars_unrecorded` here), in the summary's `exemplars_lost` when it
  # was lost before the summary was recorded, and in the gate.
  defp schedule_summary(%{summaries: nil} = state), do: state

  defp schedule_summary(%{summaries: summaries} = state) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:summary, token}, summaries.interval_ms)
    %{state | summaries: %{summaries | token: {timer_ref, token}}}
  end

  defp record_summaries(%{summaries: summaries} = state) do
    now = System.monotonic_time(:millisecond)
    ended_us = System.os_time(:microsecond)

    window = %{
      "interval_ms" => now - summaries.taken_at,
      "window_started_at" => iso(summaries.started_us),
      "window_ended_at" => iso(ended_us)
    }

    state =
      Enum.reduce(summaries.slots, state, fn {kind, name, slot, scope}, state ->
        generation = Summary.generation(slot)
        {candidates, state} = take_candidates(state, kind, generation)

        case Summary.take(slot) do
          nil -> state
          stats -> record_summary(state, kind, name, stats, window, candidates, scope)
        end
      end)

    %{state | summaries: %{state.summaries | taken_at: now, started_us: ended_us}}
  end

  defp record_summary(state, kind, name, stats, window, candidates, scope) do
    slow = candidates |> slowest() |> Enum.map(&elem(&1, 0))

    {exemplars, retained} =
      candidates
      |> Enum.flat_map(&record_exemplar(state, kind, slow, &1))
      |> Enum.unzip()

    unrecorded = length(candidates) - length(exemplars)
    for _lost <- 1..unrecorded//1, do: unrecorded_exemplar(state)
    sequence = :atomics.add_get(state.sequence, 1, 1)

    summary =
      stats
      |> Map.merge(window)
      |> Map.merge(%{
        "exemplars" => exemplars,
        "exemplars_lost" => stats["exemplars_lost"] + unrecorded,
        "first_error_retained" =>
          if(stats["errors"] > 0, do: Enum.any?(exemplars, &("first_error" in &1["roles"]))),
        "duration_scope" => duration_scope(retained, scope)
      })

    shape = %{
      kind: kind,
      phase: :summary,
      event_name: Enum.map(name, &Atom.to_string/1),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      measurements: %{},
      metadata: %{},
      summary: summary
    }

    with {:ok, event, _evidence} <- event(state, sequence, shape),
         :ok <- Recorder.record(state.recorder, event) do
      bump(state.stats, 5)
    else
      {:dropped, _reason} -> bump(state.stats, 6)
      {:error, _reason} -> bump(state.stats, 4)
    end

    state
  end

  # A candidate of an interval already summarised arrived late: its summary
  # is recorded without it, so it is counted as lost.
  defp buffer_candidate(state, sequence, %{kind: kind, exemplar: {generation, _d, _e}} = shape) do
    if generation <= Map.get(state.exemplars_taken, kind, -1) do
      bump(state.stats, 13)
      Gate.count_exemplar_lost(state.gate, :telemetry)
      state
    else
      buffered = get_in(state.exemplars, [kind, generation]) || []
      kept = keep_candidates([{sequence, shape} | buffered])

      %{
        state
        | exemplars:
            Map.update(
              state.exemplars,
              kind,
              %{generation => kept},
              &Map.put(&1, generation, kept)
            )
      }
    end
  end

  defp take_candidates(state, kind, generation) do
    candidates = get_in(state.exemplars, [kind, generation]) || []

    remaining =
      for {later, kept} <- Map.get(state.exemplars, kind, %{}),
          later > generation,
          into: %{},
          do: {later, kept}

    {Enum.sort_by(candidates, &elem(&1, 0)),
     %{
       state
       | exemplars: Map.put(state.exemplars, kind, remaining),
         exemplars_taken: Map.put(state.exemplars_taken, kind, generation)
     }}
  end

  # The interval's first error and its slowest candidates, so a buffer never
  # holds more than `@exemplar_slowest + 1` events per interval.
  defp keep_candidates(candidates) do
    slowest = slowest(candidates)
    first_error = Enum.filter(candidates, &first_error?/1)
    Enum.uniq_by(first_error ++ slowest, &elem(&1, 0))
  end

  defp slowest(candidates) do
    candidates
    |> Enum.filter(fn {_sequence, %{exemplar: {_g, duration, _e}}} -> is_integer(duration) end)
    |> Enum.sort_by(fn {sequence, %{exemplar: {_g, duration, _e}}} -> {-duration, sequence} end)
    |> Enum.take(@exemplar_slowest)
  end

  defp first_error?({_sequence, %{exemplar: {_g, _duration, first_error?}}}), do: first_error?

  defp unrecorded_exemplar(state) do
    bump(state.stats, 14)
    Gate.count_exemplar_lost(state.gate, :telemetry)
  end

  # `[{exemplar, candidate}]` when the candidate was recorded and its
  # receipt is known, else `[]`: a loss the summary counts.
  defp record_exemplar(state, kind, slow, {sequence, shape} = candidate) do
    {_generation, duration, _first_error} = shape.exemplar

    roles =
      Enum.reject(
        [
          if(sequence in slow, do: "slowest"),
          if(first_error?(candidate), do: "first_error")
        ],
        &is_nil/1
      )

    shape = Map.put(shape, :exemplar_of, %{"kind" => kind, "roles" => roles})

    with {:ok, event, _evidence} <- event(state, sequence, shape),
         :ok <- Recorder.record(state.recorder, event),
         receipt when is_integer(receipt) <- Recorder.receipt(state.recorder, event.id) do
      [
        {%{
           "receipt" => receipt,
           "roles" => roles,
           "duration_us" => duration,
           "error" => Map.get(shape, :error, false)
         }, candidate}
      ]
    else
      _not_recorded -> []
    end
  end

  # What the interval's durations measure is known only when the session
  # declared it for the kind. Where the exemplars were emitted is observed:
  # inside one OTP server, in plain processes, or both. That context is
  # never taken for the scope.
  defp duration_scope([], _scope), do: nil

  defp duration_scope(retained, scope) do
    emitter =
      case retained |> Enum.map(fn {_sequence, shape} -> shape.emitter end) |> Enum.uniq() do
        [{:otp_server, module}] -> %{"context" => "otp_server", "module" => module_name(module)}
        [:process] -> %{"context" => "process", "module" => nil}
        _mixed -> %{"context" => "mixed", "module" => nil}
      end

    %{"measured_in" => scope || "unknown", "declared" => scope != nil, "emitter" => emitter}
  end

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  @impl GenServer
  def terminate(_exit_reason, %{startup_result: {:error, _startup_reason}}), do: :ok

  def terminate(_reason, state) do
    cancel_timer(state.drain_token)
    _result = remove_owned_handler(state)
    :ok
  end

  defp config(owner, recorder, policy, options) do
    config = %{
      authority: copy(Keyword.fetch!(options, :authority)),
      batch_size: Keyword.get(options, :batch_size, 64),
      boot_id: copy(Keyword.fetch!(options, :boot_id)),
      clock_id: copy(Keyword.fetch!(options, :clock_id)),
      drain_interval_ms: Keyword.get(options, :drain_interval_ms, 10),
      drain_token: nil,
      gate: Keyword.get(options, :gate),
      handler_id:
        Keyword.get_lazy(options, :handler_id, fn ->
          "insider-telemetry-" <>
            Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
        end),
      inbox: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
      inbox_size: Keyword.get(options, :inbox_size, 256),
      lifecycle_completed: 0,
      lifecycle_duplicate_starts: 0,
      lifecycle_expired: 0,
      lifecycle_missing_correlation: 0,
      lifecycle_missing_starts: 0,
      lifecycle_missing_terminals: 0,
      lifecycle_started: 0,
      lifecycle_terminals: 0,
      lifecycle_tracking_shed: 0,
      node: copy(Keyword.get(options, :node, Atom.to_string(node()))),
      open_lifecycles: %{},
      owner: owner,
      policy: policy,
      recorder: recorder,
      sequence: :atomics.new(1, []),
      source_instance_id:
        options
        |> Keyword.get_lazy(:source_instance_id, fn ->
          "telemetry-" <>
            Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
        end)
        |> copy(),
      stats: :counters.new(14, [:atomics]),
      # Exemplar candidates by kind and interval generation, and the last
      # generation summarised per kind.
      exemplars: %{},
      exemplars_taken: %{},
      startup_result: :pending,
      summaries: summaries(Keyword.get(options, :gate)),
      unmatched_completions: 0
    }

    handler_config =
      Map.take(config, [
        :gate,
        :inbox,
        :inbox_size,
        :sequence,
        :stats
      ])
      |> Map.merge(%{
        correlation: policy.correlation,
        events: policy.events,
        measurements: policy.measurements,
        metadata: policy.metadata,
        policy_id: policy.id,
        rich: Keyword.get(options, :rich, false),
        # This collection's generation of remembered GraphQL clients.
        client_generation: GraphqlClient.generation()
      })
      |> Map.merge(Handler.nameable(Keyword.get(options, :nameable_measurements, [])))

    {:ok, Map.put(config, :handler_config, handler_config)}
  rescue
    _error -> {:error, :invalid_options}
  end

  defp summaries(gate) do
    case Gate.summaries(gate) do
      nil ->
        nil

      {slots, interval_ms} ->
        %{
          slots: slots,
          interval_ms: interval_ms,
          taken_at: System.monotonic_time(:millisecond),
          started_us: System.os_time(:microsecond),
          token: nil
        }
    end
  end

  defp valid_options?(options) do
    with true <- ProtocolValue.bounded_list?(options, length(@required) + length(@optional)),
         true <- Keyword.keyword?(options),
         true <- valid_option_keys?(Keyword.keys(options)) do
      inbox_size = Keyword.get(options, :inbox_size, 256)

      handler_id?(Keyword.get(options, :handler_id, "insider-telemetry")) and
        is_boolean(Keyword.get(options, :rich, false)) and
        nameable_measurements?(Keyword.get(options, :nameable_measurements, [])) and
        bounded?(Keyword.get(options, :node, Atom.to_string(node())), 256) and
        bounded?(Keyword.get(options, :authority), 128) and
        bounded?(Keyword.get(options, :boot_id), 128) and
        bounded?(Keyword.get(options, :clock_id), 128) and
        match?(
          {:ok, _profile},
          IngressProfile.new(Keyword.get(options, :environment))
        ) and
        valid_optional_source_id?(Keyword.get(options, :source_instance_id)) and
        bounded_integer?(inbox_size, 1, 1_024) and
        bounded_integer?(Keyword.get(options, :batch_size, 64), 1, min(inbox_size, 256)) and
        bounded_integer?(Keyword.get(options, :drain_interval_ms, 10), 1, 1_000) and
        valid_gate?(Keyword.get(options, :gate))
    else
      _failure -> false
    end
  rescue
    _error -> false
  end

  defp valid_option_keys?(keys) do
    Enum.uniq(keys) == keys and Enum.all?(keys, &(&1 in (@required ++ @optional))) and
      Enum.all?(@required, &(&1 in keys))
  end

  defp valid_gate?(nil), do: true
  defp valid_gate?(gate), do: Gate.key?(gate)

  # Measurement names a drop record may carry: a short list of distinct
  # atoms the host approved, so a withheld measurement outside it is only
  # counted and one withheld measurement is never named twice.
  defp nameable_measurements?(names) do
    ProtocolValue.bounded_list?(names, @max_nameable_measurements) and
      Enum.uniq(names) == names and
      Enum.all?(names, &(is_atom(&1) and bounded?(Atom.to_string(&1), 64)))
  end

  defp drain_batch(state, limit) do
    state.inbox
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_slot, sequence, _shape} -> sequence end)
    |> Enum.take(limit)
    |> Enum.reduce(state, &drain/2)
  end

  # Every row, the first-error slots outside the ring included.
  defp drain_all(state) do
    before = read(state.stats, 5) + read(state.stats, 6)
    state = drain_batch(state, :ets.info(state.inbox, :size))
    after_count = read(state.stats, 5) + read(state.stats, 6)
    {state, after_count - before}
  end

  defp drain({slot, sequence, _shape}, state) do
    case :ets.take(state.inbox, slot) do
      [{^slot, ^sequence, shape}] ->
        drain_shape(state, sequence, shape)

      _rows ->
        state
    end
  end

  defp drain_shape(state, sequence, %{exemplar: _exemplar} = shape),
    do: buffer_candidate(state, sequence, shape)

  defp drain_shape(state, sequence, shape) do
    case event(state, sequence, shape) do
      {:ok, event, evidence} ->
        case Recorder.record(state.recorder, event) do
          :ok ->
            bump(state.stats, 5)
            # Only an admitted event was recorded without its evidence; a
            # rejected one is a Recorder loss.
            if evidence == :unrecorded, do: bump(state.stats, 10)
            lifecycle(state, sequence, shape)

          {:dropped, _reason} ->
            bump(state.stats, 6)
            state
        end

      {:error, _reason} ->
        bump(state.stats, 4)
        state
    end
  end

  # The omission evidence is an attribute and never costs the event. If it
  # would push the attributes past Event v1's bound, the event is built with
  # the counts alone; if even those do not fit, without the evidence, marked
  # `:unrecorded` so that `omissions_unrecorded` counts it once the Recorder
  # admits the event.
  defp event(state, sequence, shape) do
    case new_event(state, sequence, shape) do
      {:ok, event} ->
        {:ok, event, :kept}

      {:error, _reason} = error ->
        case Map.get(shape, :omitted) do
          nil -> error
          omitted -> with_less_evidence(state, sequence, shape, omitted)
        end
    end
  end

  defp with_less_evidence(state, sequence, shape, %{"measurement_names" => [_ | _]} = omitted) do
    unnamed = Omitted.unnamed(omitted)

    case new_event(state, sequence, %{shape | omitted: unnamed}) do
      {:ok, event} -> {:ok, event, :kept}
      {:error, _reason} -> with_less_evidence(state, sequence, shape, unnamed)
    end
  end

  defp with_less_evidence(state, sequence, shape, _omitted) do
    with {:ok, event} <- new_event(state, sequence, %{shape | omitted: nil}),
         do: {:ok, event, :unrecorded}
  end

  defp new_event(state, sequence, shape) do
    Event.new(
      id: state.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: state.node,
      boot_id: state.boot_id,
      source: "telemetry",
      kind: shape.kind,
      severity: severity(shape),
      monotonic_time: sequence,
      clock_id: state.clock_id,
      source_instance_id: state.source_instance_id,
      source_sequence: sequence,
      wall_time: wall_time(shape),
      subject: subject(state, shape),
      causality: shape.causality,
      attributes:
        shape
        |> summary_attributes(%{
          "event_name" => shape.event_name,
          "lifecycle_phase" => Atom.to_string(shape.phase),
          "measurements" => shape.measurements,
          "metadata" => shape.metadata,
          "projection" => Map.get(shape, :projection, "telemetry.allowlist/v1")
        })
        |> put_omitted(Map.get(shape, :omitted))
        |> put_graphql(Map.get(shape, :graphql))
        |> put_request(Map.get(shape, :request))
        |> put_oban(Map.get(shape, :oban))
        |> put_exemplar_of(Map.get(shape, :exemplar_of)),
      payload: Map.get(shape, :payload),
      authority: state.authority,
      redactions: [],
      extensions: %{}
    )
  rescue
    _error -> {:error, :invalid_shape}
  catch
    _kind, _reason -> {:error, :invalid_shape}
  end

  # The severity rule is the welcome document's `"severity"` table: an
  # exception phase or a failure (`Insider.Collector.Telemetry.Outcome`) is
  # an error; a GraphQL payload that reports only validation errors, and a
  # summary that folded an error, are warnings.
  defp severity(%{phase: :exception}), do: :error
  defp severity(%{error: true}), do: :error
  defp severity(%{graphql: %{"result" => "user_errors"}}), do: :warning
  defp severity(%{phase: :summary, summary: %{"errors" => errors}}) when errors > 0, do: :warning
  defp severity(_shape), do: :info

  # A handled event carries its emission time; a summary, which the
  # collector records itself, the time it was recorded.
  defp wall_time(%{wall_time_us: wall_time_us}) when is_integer(wall_time_us),
    do: DateTime.from_unix!(wall_time_us, :microsecond)

  defp wall_time(_shape), do: DateTime.from_unix!(System.os_time(:microsecond), :microsecond)

  # A summary stands for many emitters, so it has no process subject.
  defp subject(_state, %{phase: :summary}), do: nil

  defp subject(state, shape),
    do: %{"namespace" => "process", "scope" => state.node, "value" => shape.emitter_pid}

  defp summary_attributes(%{phase: :summary, summary: summary}, attributes),
    do: Map.merge(attributes, %{"projection" => "telemetry.summary/v1", "summary" => summary})

  defp summary_attributes(_shape, attributes), do: attributes

  # An Absinthe operation's value-free outcome (`GraphqlOutcome`).
  # A request's timing and source (`Insider.Collector.RequestTiming`).
  defp put_request(attributes, nil), do: attributes
  defp put_request(attributes, request), do: Map.put(attributes, "request", request)

  # An Oban job event's job (`Insider.Collector.ObanJob`).
  defp put_oban(attributes, nil), do: attributes
  defp put_oban(attributes, job), do: Map.put(attributes, "oban", job)

  defp put_graphql(attributes, nil), do: attributes
  defp put_graphql(attributes, outcome), do: Map.put(attributes, "graphql", outcome)

  defp put_omitted(attributes, nil), do: attributes
  defp put_omitted(attributes, omitted), do: Map.put(attributes, Omitted.key(), omitted)

  # An exemplar names the summary it stands for and why it was kept.
  defp put_exemplar_of(attributes, nil), do: attributes
  defp put_exemplar_of(attributes, of), do: Map.put(attributes, "exemplar_of", of)

  defp lifecycle(state, sequence, shape) do
    state = expire_lifecycles(state, sequence)
    lifecycle_key = {shape.lifecycle, shape.causality.logical_operation_id}
    lifecycle_phase(state, sequence, shape.phase, lifecycle_key)
  end

  defp lifecycle_phase(state, _sequence, :start, {_rule, nil}),
    do: %{state | lifecycle_missing_correlation: state.lifecycle_missing_correlation + 1}

  defp lifecycle_phase(state, sequence, :start, lifecycle_key) do
    cond do
      Map.has_key?(state.open_lifecycles, lifecycle_key) ->
        %{state | lifecycle_duplicate_starts: state.lifecycle_duplicate_starts + 1}

      map_size(state.open_lifecycles) >= state.policy.max_open_lifecycles ->
        %{state | lifecycle_tracking_shed: state.lifecycle_tracking_shed + 1}

      true ->
        %{
          state
          | lifecycle_started: state.lifecycle_started + 1,
            open_lifecycles: Map.put(state.open_lifecycles, lifecycle_key, sequence)
        }
    end
  end

  defp lifecycle_phase(state, _sequence, phase, {_rule, nil}) when phase in [:stop, :exception],
    do: %{
      state
      | lifecycle_missing_correlation: state.lifecycle_missing_correlation + 1,
        lifecycle_terminals: state.lifecycle_terminals + 1
    }

  defp lifecycle_phase(state, _sequence, phase, lifecycle_key)
       when phase in [:stop, :exception] do
    case Map.pop(state.open_lifecycles, lifecycle_key) do
      {nil, _unchanged} ->
        %{
          state
          | lifecycle_missing_starts: state.lifecycle_missing_starts + 1,
            lifecycle_terminals: state.lifecycle_terminals + 1,
            unmatched_completions: state.unmatched_completions + 1
        }

      {_open, remaining} ->
        %{
          state
          | lifecycle_completed: state.lifecycle_completed + 1,
            lifecycle_terminals: state.lifecycle_terminals + 1,
            open_lifecycles: remaining
        }
    end
  end

  defp lifecycle_phase(state, _sequence, _phase, _lifecycle_key), do: state

  defp expire_lifecycles(state, sequence) do
    minimum = sequence - state.policy.max_lifecycle_age_events

    {expired, retained} =
      Enum.split_with(state.open_lifecycles, fn {_key, opened} -> opened < minimum end)

    %{
      state
      | lifecycle_expired: state.lifecycle_expired + length(expired),
        lifecycle_missing_terminals: state.lifecycle_missing_terminals + length(expired),
        open_lifecycles: Map.new(retained)
    }
  end

  defp status_map(state) do
    %{
      received: read(state.stats, 1),
      enqueued: read(state.stats, 2),
      shed: read(state.stats, 3),
      invalid: read(state.stats, 4),
      recorded: read(state.stats, 5),
      recorder_dropped: read(state.stats, 6),
      handler_failures: read(state.stats, 7),
      measurements_suppressed: read(state.stats, 8),
      metadata_suppressed: read(state.stats, 9),
      omissions_unrecorded: read(state.stats, 10),
      exemplars_shed: read(state.stats, 11),
      exemplars_invalid: read(state.stats, 12),
      exemplars_late: read(state.stats, 13),
      exemplars_unrecorded: read(state.stats, 14),
      inbox_count: :ets.info(state.inbox, :size),
      inbox_capacity: state.inbox_size,
      lifecycle_started: state.lifecycle_started,
      lifecycle_completed: state.lifecycle_completed,
      lifecycle_duplicate_starts: state.lifecycle_duplicate_starts,
      lifecycle_expired: state.lifecycle_expired,
      lifecycle_missing_correlation: state.lifecycle_missing_correlation,
      lifecycle_missing_starts: state.lifecycle_missing_starts,
      lifecycle_missing_terminals: state.lifecycle_missing_terminals,
      lifecycle_tracking_shed: state.lifecycle_tracking_shed,
      lifecycle_terminals: state.lifecycle_terminals,
      unmatched_completions: state.unmatched_completions,
      open_lifecycles: map_size(state.open_lifecycles)
    }
  end

  defp install_handler(state) do
    case handler_lock(state.handler_id, fn -> install_or_reclaim(state) end) do
      :aborted -> {:error, :install_contended}
      :ok -> attach_client(state)
      result -> result
    end
  end

  # A rich session that records Absinthe operation stops names their
  # request's client (`Insider.Collector.GraphqlClient`).
  defp attach_client(state) do
    config = state.handler_config

    if config.rich and Map.has_key?(config.events, {:absinthe, :execute, :operation, :stop}),
      do: GraphqlClient.attach(state.handler_id, config.client_generation),
      else: :ok
  end

  defp install_or_reclaim(state) do
    result =
      :telemetry.attach_many(
        state.handler_id,
        state.policy.event_names,
        &Handler.handle_event/4,
        state.handler_config
      )

    case result do
      {:error, :already_exists} ->
        if stale_insider_handler?(state) do
          :ok = :telemetry.detach(state.handler_id)

          :telemetry.attach_many(
            state.handler_id,
            state.policy.event_names,
            &Handler.handle_event/4,
            state.handler_config
          )
        else
          {:error, {:already_exists, state.handler_id}}
        end

      other ->
        other
    end
  end

  defp stale_insider_handler?(state) do
    rows = handler_rows(state)
    stale_rows?(rows)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp stale_rows?(rows) do
    rows != :too_many and rows != [] and
      Enum.all?(rows, fn row ->
        row.function == (&Handler.handle_event/4) and is_map(row.config) and
          Map.has_key?(row.config, :inbox) and :ets.info(row.config.inbox) == :undefined
      end)
  end

  defp remove_owned_handler(state) do
    :ok = GraphqlClient.detach(state.handler_id)

    case handler_presence(state) do
      :owned ->
        case :telemetry.detach(state.handler_id) do
          :ok -> :removed
          {:error, :not_found} -> :already_detached
        end

      :absent ->
        :already_detached

      :other ->
        :not_owned
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp owned_handler?(state) do
    Enum.all?(state.policy.event_names, fn event_name ->
      event_name
      |> :telemetry.list_handlers()
      |> bounded_rows()
      |> case do
        :too_many ->
          false

        rows ->
          Enum.any?(rows, fn row ->
            row.id == state.handler_id and row.function == (&Handler.handle_event/4) and
              row.config == state.handler_config
          end)
      end
    end)
  end

  defp handler_presence(state) do
    cond do
      owned_handler?(state) -> :owned
      Enum.any?(state.policy.event_names, &handler_id_present?(&1, state.handler_id)) -> :other
      true -> :absent
    end
  end

  defp handler_id_present?(event_name, handler_id) do
    event_name
    |> :telemetry.list_handlers()
    |> bounded_rows()
    |> case do
      :too_many -> true
      rows -> Enum.any?(rows, &(&1.id == handler_id))
    end
  end

  defp handler_rows(state) do
    state.policy.event_names
    |> Enum.flat_map(&:telemetry.list_handlers/1)
    |> Enum.filter(&(&1.id == state.handler_id))
    |> Enum.uniq()
    |> bounded_rows()
  end

  defp bounded_rows(rows) do
    if length(Enum.take(rows, @max_handler_rows + 1)) > @max_handler_rows,
      do: :too_many,
      else: rows
  end

  defp handler_lock(handler_id, function),
    do: :global.trans({{__MODULE__, handler_id, node()}, self()}, function, [node()], 0)

  defp safe_call(server, message) do
    GenServer.call(server, message)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp schedule(interval) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:drain, token}, interval)
    {timer_ref, token}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer({timer_ref, _token}),
    do: Process.cancel_timer(timer_ref, async: false, info: false)

  defp handler_id?(value) when is_atom(value) do
    encoded = Atom.to_string(value)
    byte_size(encoded) in 1..128 and String.valid?(encoded)
  end

  defp handler_id?(value), do: bounded?(value, 128)
  defp valid_optional_source_id?(nil), do: true
  defp valid_optional_source_id?(value), do: bounded?(value, @max_source_instance_id_bytes)

  defp bounded?(value, maximum) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= maximum and String.valid?(value)
  end

  defp bounded?(_value, _maximum), do: false

  defp bounded_integer?(value, minimum, maximum) when is_integer(value),
    do: value >= minimum and value <= maximum

  defp bounded_integer?(_value, _minimum, _maximum), do: false

  defp read(stats, index), do: :counters.get(stats, index)
  defp bump(stats, index), do: :counters.add(stats, index, 1)
  defp copy(value), do: :binary.copy(value)
end
