defmodule Insider.Collector.Logger do
  @moduledoc """
  Supervised, bounded ingestion of structured OTP Logger events.

  OTP invokes handlers synchronously in the logging process. The handler only
  performs bounded shaping and a single fixed-slot ETS insertion. This process
  drains that inbox into the recorder, keeping recorder recovery and pressure
  work out of application logging paths.

  Set `include_payload: false` to retain only normalized semantic attributes and
  record `payload: nil`; this prevents Logger message content from entering the
  recorder when a capture needs a stricter privacy boundary.

  Set `rich: true` (with the payload included) to record the formatted message
  text, the level, and the rendered Logger metadata instead of the bounded
  message shape, with credentials masked. The live session's rich disclosure
  profile uses it.

  A gate with a Logger summary (`Insider.Collector.Gate`) counts the
  messages it summarises by level, message template and call site, a
  burst; every interval this process records one `logger_summary` event per
  burst, after recording the burst's first message of the interval as its
  exemplar, and names the exemplar's receipt. The gate admits at most
  `Insider.Collector.Gate.max_bursts/0` bursts per interval; the messages
  of the others are one overflow event per level, which counts the bursts
  folded into it.
  """

  use GenServer

  alias Insider.Collector.Gate
  alias Insider.Collector.Logger.Handler
  alias Insider.Collector.IngressProfile
  alias Insider.Event
  alias Insider.Recorder
  alias Insider.Recorder.Handle, as: RecorderHandle

  @required [:authority, :boot_id, :clock_id, :environment]
  @optional [
    :batch_size,
    :drain_interval_ms,
    :gate,
    :handler_id,
    :include_payload,
    :inbox_size,
    :node,
    :rich,
    :source_instance_id
  ]

  @spec start_link(RecorderHandle.t(), keyword()) :: GenServer.on_start()
  def start_link(%RecorderHandle{} = recorder, options) do
    if valid_options?(options) do
      with {:ok, profile} <- IngressProfile.new(Keyword.fetch!(options, :environment)),
           {:ok, _settings} <- profile_settings(profile),
           true <- profile.observation_enabled do
        GenServer.start_link(__MODULE__, {recorder, options})
      else
        false -> {:error, :environment_denied}
        {:error, _reason} -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_recorder, _options), do: {:error, :invalid_options}

  @spec start_link({RecorderHandle.t(), keyword()}) :: GenServer.on_start()
  def start_link({%RecorderHandle{} = recorder, options}), do: start_link(recorder, options)
  def start_link(_arguments), do: {:error, :invalid_options}

  @doc false
  @spec reclaim_stale_filter(atom()) :: :reclaimed | :absent_or_live | :unavailable
  def reclaim_stale_filter(handler_id) when is_atom(handler_id) do
    case filter_lock(handler_id, fn ->
           if stale_insider_filter?(handler_id) do
             case :logger.remove_primary_filter(handler_id) do
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
  end

  def reclaim_stale_filter(_handler_id), do: :unavailable

  @spec status(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def status(server), do: safe_call(server, :status)

  @doc """
  Drains the currently visible bounded inbox before returning collector status.

  This is a barrier for entries visible when the collector handles the call.
  Callers must quiesce producers before using it as an incident freeze boundary;
  concurrently executing Logger filters may insert after the bounded scan.
  """
  @spec flush(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def flush(server), do: safe_call(server, :flush)

  @doc """
  Removes the Logger filter, then drains the inbox, records every pending
  burst interval, and stops, so every event admitted before the removal is
  recorded or summarised. A filter call already running in another process
  when the filter is removed may still insert after the drain.
  """
  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stop(server), do: safe_call(server, :stop)

  @impl GenServer
  def init({recorder, options}) do
    with {:ok, config} <- config(recorder, options),
         :ok <- install_filter(config) do
      {:ok,
       config
       |> Map.put(:drain_token, schedule(config.drain_interval_ms))
       |> schedule_bursts()}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:flush, _from, state) do
    state = drain_batch(state, state.inbox_size)
    {:reply, {:ok, status_map(state)}, state}
  end

  # A final read before a session ends: the inbox is drained and every
  # pending burst interval is recorded now, so it is part of that read.
  def handle_call(:finalize, _from, state) do
    state = state |> drain_batch(state.inbox_size) |> record_bursts()
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:stop, _from, state) do
    _removed = remove_owned_filter(state)
    state = state |> drain_batch(state.inbox_size) |> record_bursts()
    {:stop, :normal, {:ok, status_map(state)}, state}
  end

  @impl GenServer
  def handle_info({:drain, token}, %{drain_token: token} = state) do
    state = drain_batch(state, state.batch_size)

    next_token = schedule(state.drain_interval_ms)
    {:noreply, %{state | drain_token: next_token}}
  end

  def handle_info({:bursts, token}, %{bursts: %{token: token}} = state) do
    # The whole inbox, so the interval's exemplars are recorded first.
    state = state |> drain_batch(state.inbox_size) |> record_bursts() |> schedule_bursts()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _result = remove_owned_filter(state)
    :ok
  end

  defp drain({slot, sequence, _event}, state) do
    case :ets.take(state.inbox, slot) do
      [{^slot, ^sequence, {:exemplar, burst, event}}] ->
        exemplar(state, burst, event)

      [{^slot, ^sequence, event}] ->
        case Recorder.record(state.recorder, event) do
          :ok -> bump(state.stats, 5)
          {:dropped, _reason} -> bump(state.stats, 6)
        end

        state

      _rows ->
        state
    end
  end

  defp drain_batch(state, limit) do
    state.inbox
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_slot, sequence, _event} -> sequence end)
    |> Enum.take(limit)
    |> Enum.reduce(state, &drain/2)
  end

  ## Bursts

  defp schedule_bursts(%{bursts: nil} = state), do: state

  defp schedule_bursts(%{bursts: bursts} = state) do
    token = make_ref()
    Process.send_after(self(), {:bursts, token}, bursts.interval_ms)
    %{state | bursts: %{bursts | token: token}}
  end

  # An exemplar is a summarised message, so it touches no handler counter.
  # One of an interval already recorded arrived late: it is still recorded,
  # as every exemplar is, but no burst names it; its burst was recorded
  # with `exemplar_lost`, and that loss is already counted.
  defp exemplar(state, {:burst, generation, _t, _m, _f, _a, _line, _level} = burst, event) do
    case state.bursts do
      %{taken: taken} = bursts when generation > taken ->
        entry =
          with :ok <- Recorder.record(state.recorder, event),
               receipt when is_integer(receipt) <- Recorder.receipt(state.recorder, event.id) do
            %{receipt: receipt}
          else
            _unrecorded ->
              bump(state.stats, 13)
              Gate.count_exemplar_lost(state.gate, :logger)
              :unrecorded
          end

        %{state | bursts: %{bursts | exemplars: Map.put(bursts.exemplars, burst, entry)}}

      _late ->
        bump(state.stats, 12)
        _recorded = Recorder.record(state.recorder, event)
        state
    end
  end

  defp record_bursts(%{bursts: nil} = state), do: state

  # The work is bounded by the gate's admission: at most `max_bursts/0`
  # rows per interval, and as many of a late writer's earlier interval.
  defp record_bursts(%{bursts: bursts} = state) do
    now = System.monotonic_time(:millisecond)
    ended_us = System.os_time(:microsecond)
    {generation, rows, overflows} = Gate.take_bursts(bursts.spec)

    window = %{
      "interval_ms" => now - bursts.taken_at,
      "window_started_at" => iso(bursts.started_us),
      "window_ended_at" => iso(ended_us)
    }

    # A late writer's row of an earlier interval joins its burst's row.
    {kept, folded} =
      rows
      |> Enum.group_by(fn {{:burst, _g, template, m, f, a, line, level}, _count, _lost} ->
        {template, m, f, a, line, level}
      end)
      |> Enum.map(&burst(bursts.exemplars, &1))
      |> Enum.sort_by(fn {identity, count, _receipt, _counted} -> {-count, identity} end)
      |> Enum.split(Gate.max_bursts())

    # Bursts past the bound (only a late writer can add them) are folded
    # into the overflow rows like any other distinction.
    if folded != [], do: Gate.count_overflow(state.gate, length(folded))

    overflow =
      Enum.reduce(
        folded,
        Map.new(overflows, fn {level, count, distinct} -> {level, {count, distinct}} end),
        fn {{_t, _m, _f, _a, _line, level}, count, _receipt, _counted}, overflow ->
          Map.update(overflow, level, {count, 1}, fn {total, distinct} ->
            {total + count, distinct + 1}
          end)
        end
      )

    Enum.each(kept, &record_burst(state, &1, window, ended_us))

    overflow
    |> Enum.sort_by(fn {level, _counts} -> Map.get(Gate.level_ranks(), level, 7) end)
    |> Enum.each(&record_overflow(state, &1, window, ended_us))

    exemplars =
      for {{:burst, g, _, _, _, _, _, _}, _} = entry <- bursts.exemplars,
          g > generation,
          into: %{},
          do: entry

    %{
      state
      | bursts: %{
          bursts
          | taken: generation,
            taken_at: now,
            started_us: ended_us,
            exemplars: exemplars
        }
    }
  end

  # A burst's count, its exemplar's receipt, and whether a missing exemplar
  # was already counted as lost (by the handler, or here when the Recorder
  # refused it).
  defp burst(exemplars, {identity, rows}) do
    entries = rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.map(&Map.get(exemplars, &1))
    receipt = Enum.find_value(entries, &(match?(%{receipt: _receipt}, &1) && &1.receipt))
    counted = :unrecorded in entries or Enum.any?(rows, fn {_key, _count, lost} -> lost > 0 end)
    {identity, rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(), receipt, counted}
  end

  defp record_burst(state, {identity, count, receipt, counted}, window, ended_us) do
    {template, module, function, arity, line, level} = identity

    # An exemplar still in flight when its burst is recorded is lost to it.
    if is_nil(receipt) and not counted, do: Gate.count_exemplar_lost(state.gate, :logger)

    summary =
      Map.merge(window, %{
        "count" => count,
        "level" => Atom.to_string(level),
        "template" => if(state.rich and state.include_payload, do: template),
        "template_fingerprint" => fingerprint(template),
        "call_site" => call_site(state, module, function, arity, line),
        "call_site_fingerprint" => fingerprint({module, function, arity, line}),
        "call_sites" => 1,
        "exemplar_receipt" => receipt,
        "exemplar_lost" => is_nil(receipt),
        "overflow" => false,
        "distinct_lost" => 0
      })

    emit_burst(state, level, summary, ended_us)
  end

  defp record_overflow(state, {level, {count, distinct}}, window, ended_us) do
    summary =
      Map.merge(window, %{
        "count" => count,
        "level" => Atom.to_string(level),
        "template" => nil,
        "template_fingerprint" => "overflow",
        "call_site" => nil,
        "call_site_fingerprint" => "overflow",
        "call_sites" => nil,
        "exemplar_receipt" => nil,
        "exemplar_lost" => false,
        "overflow" => true,
        "distinct_lost" => distinct
      })

    emit_burst(state, level, summary, ended_us)
  end

  defp emit_burst(state, level, summary, ended_us) do
    sequence = :atomics.add_get(state.sequence, 1, 1)

    with {:ok, event} <- burst_event(state, sequence, level, summary, ended_us),
         :ok <- Recorder.record(state.recorder, event) do
      bump(state.stats, 5)
    else
      {:dropped, _reason} -> bump(state.stats, 6)
      {:error, _reason} -> bump(state.stats, 4)
    end
  end

  defp burst_event(state, sequence, level, summary, ended_us) do
    Event.new(
      id: state.source_instance_id <> "-" <> Integer.to_string(sequence, 36),
      node: state.node,
      boot_id: state.boot_id,
      source: "logger",
      kind: "logger_summary",
      severity: Map.get(Handler.severities(), level, :debug),
      monotonic_time: sequence,
      clock_id: state.clock_id,
      source_instance_id: state.source_instance_id,
      source_sequence: sequence,
      wall_time: DateTime.from_unix!(ended_us, :microsecond),
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{
        "lifecycle_phase" => "summary",
        "projection" => "logger.summary/v1",
        "summary" => summary
      },
      payload: nil,
      authority: state.authority,
      redactions: [],
      extensions: %{}
    )
  end

  # The call site is Logger metadata, withheld when the profile keeps only
  # message structure.
  defp call_site(%{structural_only: true}, _m, _f, _a, _line), do: nil
  defp call_site(_state, nil, _f, _a, _line), do: nil

  defp call_site(_state, module, function, arity, line) do
    %{
      "module" => module_name(module),
      "function" => "#{function}/#{arity}",
      "line" => line
    }
  end

  # Tells templates and call sites apart without naming them, for a profile
  # that withholds them.
  defp fingerprint(term) do
    :sha256
    |> :crypto.hash(if(is_binary(term), do: term, else: :erlang.term_to_binary(term)))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp status_map(state) do
    %{
      received: read(state.stats, 1),
      enqueued: read(state.stats, 2),
      shed: read(state.stats, 3),
      invalid: read(state.stats, 4),
      recorded: read(state.stats, 5),
      recorder_dropped: read(state.stats, 6),
      payload_suppressed: read(state.stats, 7),
      message_semantics_suppressed: read(state.stats, 8),
      metadata_suppressed: read(state.stats, 9),
      exemplars_shed: read(state.stats, 10),
      exemplars_invalid: read(state.stats, 11),
      exemplars_late: read(state.stats, 12),
      exemplars_unrecorded: read(state.stats, 13),
      inbox_count: :ets.info(state.inbox, :size),
      inbox_capacity: state.inbox_size
    }
  end

  defp bursts(gate) do
    case Gate.bursts(gate) do
      nil ->
        nil

      spec ->
        %{
          spec: spec,
          interval_ms: spec.interval_ms,
          token: nil,
          # The last generation recorded, and the exemplars by burst key.
          taken: -1,
          exemplars: %{},
          taken_at: System.monotonic_time(:millisecond),
          started_us: System.os_time(:microsecond)
        }
    end
  end

  defp config(recorder, options) do
    if valid_options?(options) do
      with {:ok, profile} <- IngressProfile.new(Keyword.fetch!(options, :environment)),
           {:ok, settings} <- profile_settings(profile),
           true <- profile.observation_enabled do
        config = %{
          authority: copy(Keyword.fetch!(options, :authority)),
          batch_size: Keyword.get(options, :batch_size, 64),
          boot_id: copy(Keyword.fetch!(options, :boot_id)),
          clock_id: copy(Keyword.fetch!(options, :clock_id)),
          drain_interval_ms: Keyword.get(options, :drain_interval_ms, 10),
          gate: Keyword.get(options, :gate),
          handler_id: Keyword.get(options, :handler_id, :insider_logger),
          include_payload:
            settings.include_payload and Keyword.get(options, :include_payload, true),
          include_message_semantics: settings.include_message_semantics,
          rich: Keyword.get(options, :rich, false),
          structural_only: settings.structural_only,
          inbox: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
          inbox_size: Keyword.get(options, :inbox_size, 256),
          node: copy(Keyword.get(options, :node, Atom.to_string(node()))),
          recorder: recorder,
          sequence: :atomics.new(1, []),
          source_instance_id:
            options
            |> Keyword.get_lazy(:source_instance_id, fn ->
              "logger-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
            end)
            |> copy(),
          stats: :counters.new(13, [:atomics]),
          bursts: bursts(Keyword.get(options, :gate))
        }

        if valid?(config), do: {:ok, config}, else: {:error, :invalid_options}
      else
        false -> {:error, :environment_denied}
        _error -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :invalid_options}
  end

  defp valid_options?(options) when is_list(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: []
    inbox_size = Keyword.get(options, :inbox_size, 256)

    Keyword.keyword?(options) and length(keys) == length(Enum.uniq(keys)) and
      Enum.all?(keys, &(&1 in (@required ++ @optional))) and
      Enum.all?(@required, &Keyword.has_key?(options, &1)) and
      is_atom(Keyword.get(options, :handler_id, :insider_logger)) and
      is_boolean(Keyword.get(options, :include_payload, true)) and
      is_boolean(Keyword.get(options, :rich, false)) and
      match?(
        {:ok, _profile},
        IngressProfile.new(Keyword.get(options, :environment))
      ) and
      bounded?(Keyword.get(options, :node, Atom.to_string(node())), 256) and
      bounded?(Keyword.get(options, :authority), 128) and
      bounded?(Keyword.get(options, :boot_id), 128) and
      bounded?(Keyword.get(options, :clock_id), 128) and
      valid_optional_id?(Keyword.get(options, :source_instance_id)) and
      bounded_integer?(inbox_size, 1, 1_024) and
      bounded_integer?(Keyword.get(options, :batch_size, 64), 1, min(inbox_size, 256)) and
      bounded_integer?(Keyword.get(options, :drain_interval_ms, 10), 1, 1_000) and
      valid_gate?(Keyword.get(options, :gate))
  rescue
    _error -> false
  end

  defp valid_options?(_options), do: false

  defp valid_gate?(nil), do: true
  defp valid_gate?(gate), do: Gate.key?(gate)

  defp valid_optional_id?(nil), do: true
  defp valid_optional_id?(value), do: bounded?(value, 128)

  defp valid?(config) do
    is_atom(config.handler_id) and is_boolean(config.include_payload) and
      is_boolean(config.rich) and
      is_boolean(config.include_message_semantics) and is_boolean(config.structural_only) and
      bounded?(config.node, 256) and
      bounded_integer?(config.inbox_size, 1, 1_024) and
      bounded_integer?(config.batch_size, 1, min(config.inbox_size, 256)) and
      bounded_integer?(config.drain_interval_ms, 1, 1_000) and
      Enum.all?(
        [config.authority, config.boot_id, config.clock_id, config.source_instance_id],
        &bounded?(&1, 128)
      )
  end

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value in minimum..maximum

  defp filter_config(config),
    do:
      Map.take(config, [
        :authority,
        :boot_id,
        :clock_id,
        :gate,
        :include_payload,
        :include_message_semantics,
        :rich,
        :structural_only,
        :inbox,
        :inbox_size,
        :node,
        :sequence,
        :source_instance_id,
        :stats
      ])

  defp install_filter(config) do
    case filter_lock(config.handler_id, fn -> install_or_reclaim(config) end) do
      :aborted -> {:error, :install_contended}
      result -> result
    end
  end

  defp install_or_reclaim(config) do
    filter = {&Handler.filter/2, filter_config(config)}

    case :logger.add_primary_filter(config.handler_id, filter) do
      {:error, {:already_exist, _id}} = error ->
        if stale_insider_filter?(config.handler_id) do
          with :ok <- :logger.remove_primary_filter(config.handler_id),
               do: :logger.add_primary_filter(config.handler_id, filter)
        else
          error
        end

      result ->
        result
    end
  end

  defp stale_insider_filter?(handler_id) do
    %{filters: filters} = :logger.get_primary_config()

    Enum.any?(filters, fn
      {^handler_id, {function, %{inbox: inbox}}} ->
        function == (&Handler.filter/2) and :ets.info(inbox) == :undefined

      _filter ->
        false
    end)
  rescue
    _error -> false
  end

  defp remove_owned_filter(state) do
    filter_lock(state.handler_id, fn ->
      expected = {&Handler.filter/2, filter_config(state)}
      %{filters: filters} = :logger.get_primary_config()

      if Enum.any?(filters, &(&1 == {state.handler_id, expected})),
        do: :logger.remove_primary_filter(state.handler_id),
        else: :ok
    end)
  rescue
    _error -> :ok
  end

  defp filter_lock(handler_id, function),
    do: :global.trans({{__MODULE__, handler_id, node()}, self()}, function, [node()], 0)

  defp schedule(interval) do
    token = make_ref()
    Process.send_after(self(), {:drain, token}, interval)
    token
  end

  defp safe_call(server, message) do
    GenServer.call(server, message)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp read(stats, index), do: :counters.get(stats, index)
  defp bump(stats, index), do: :counters.add(stats, index, 1)
  defp copy(value), do: :binary.copy(value)

  @doc false
  @spec profile_settings(IngressProfile.t()) :: {:ok, map()} | {:error, :invalid_profile}
  def profile_settings(%IngressProfile{} = profile) do
    if IngressProfile.valid?(profile) do
      {:ok,
       %{
         include_message_semantics: profile.logger_message_semantics,
         include_payload: profile.logger_payload,
         structural_only: profile.logger_structural_only
       }}
    else
      {:error, :invalid_profile}
    end
  end

  def profile_settings(_profile), do: {:error, :invalid_profile}
end
