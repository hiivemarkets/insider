defmodule Insider.Live.Owner do
  @moduledoc false

  # The durable, supervised owner of the one live collector session. This
  # process, never the caller, owns the `Insider.Collector.Session`, so a
  # transport process such as a Tidewave eval or an `:erpc` call can exit
  # without stopping the session. A renewable lease bounds an abandoned one.
  # It starts only under `Insider.Supervisor` in development, test, and ci.
  #
  # Requests use the same bounded admission as the session Manager: a caller
  # acquires one of a fixed number of slots before its message is queued, and
  # every request carries an absolute deadline. A request that is handled
  # after its deadline, or without the reserve its worst-case work needs, is
  # refused before any side effect, so a caller that saw `timeout` never
  # leaves an unreported session behind.

  use GenServer

  alias Insider.Collector.Admission
  alias Insider.Collector.Gate
  alias Insider.Collector.Otel
  alias Insider.Collector.Session
  alias Insider.Collector.Session.Manager
  alias Insider.Collector.Telemetry.Handler, as: TelemetryHandler
  alias Insider.Event
  alias Insider.Identity.Subject
  alias Insider.Live.Archive
  alias Insider.Live.Batch
  alias Insider.Live.CallsOptions
  alias Insider.Live.Disclosure
  alias Insider.Live.Environment
  alias Insider.Live.Error
  alias Insider.Live.Filters
  alias Insider.Live.Gates
  alias Insider.Live.Hints
  alias Insider.Live.Marks
  alias Insider.Live.Options
  alias Insider.Live.PollerOptions
  alias Insider.Live.Mutations
  alias Insider.Live.Retention
  alias Insider.Live.View
  alias Insider.Live.RedactFields
  alias Insider.Redaction.Credentials
  alias Insider.Redaction.Policy, as: RedactionPolicy
  alias Insider.Runtime.HostPolicy

  @admitted_calls_max 16
  @retained_terminals 8
  @max_subscribers 4
  @max_baselines 64
  @push_interval_ms 500
  @push_limit 100
  @push_max_bytes 262_144
  @push_scan_limit 1_000
  @subscriber_mailbox_limit 32
  @read_timeout_ms 2_000
  @read_reply_reserve_ms 200
  @push_read_timeout_ms 1_000
  @recorder_max_bytes 4 * 1_024 * 1_024
  # A read is fed to `Insider.Live.Batch` in collector pages of at most this
  # many entries and stored bytes (one entry always fits), so no process on
  # the read path holds more than one page of entries besides the result.
  @page_entries 100
  @page_bytes 128 * 1_024
  # One retention sweep copies at most this many entries, within this time.
  @sweep_entries 1_000
  @sweep_ms 100
  # Naming the valid receipts in an `invalid_cursor` error takes one session
  # health call (1,200 ms) plus the reply.
  @cursor_error_reserve_ms 1_400
  @stop_retry_ms 1_000
  # A subscriber whose view or the record-time filters hid events, and that
  # had nothing else to receive, still gets a batch with the filtered counts
  # this often, so its silence is never ambiguous.
  @filtered_report_ms 5_000
  # Creating the session's gate in `Insider.Live.Gates` is one short call.
  @gate_timeout_ms 500
  @redact_fields_timeout_ms 200
  # Readers name themselves; `status` lists at most this many, the most
  # recently seen, and `stop` refuses while another was seen this recently
  # or is subscribed.
  @readers_max 16
  # The traces whose services and routes a scoped view can match.
  @trace_index_max 4_096
  @reader_active_ms 30_000
  # A stopped session stays readable from its archive for this long, so
  # peers can drain; at most this many stopped sessions are readable.
  @stopped_readable_ms 120_000
  @retained_readable 2
  @amendments_listed 8
  # Copying a segment into the archive reads at most this many entries per
  # collector read, within at most this much of the request's budget, and
  # leaves the rest for what follows the copy: a stop (1,500 ms) and the
  # reply, or an amendment's stop, two gate creations, redact-field
  # collections and session starts (rollback included), and the reply.
  @capture_chunk 1_000
  @capture_max_ms 4_000
  @after_capture_ms %{stop: 1_700, amend: 5_900}

  @gated_operations [:amend, :events_since, :ingest_spans, :renew, :start, :subscribe]
  # Operations whose reply can carry a read: a batch, a stop's final reads,
  # or an amendment's copy of the running segment.
  @reading_operations [:amend, :events_since, :stop]

  # The remaining request budget each operation needs to finish before its
  # deadline. They cover the collector calls each one can make: session
  # health (1,200 ms), gate creation (500 ms), Ecto redact-field collection
  # (200 ms), session start (1,400 ms), session stop (1,500 ms), and the
  # archive copy a stop or an amendment makes first (at least 1,000 ms).
  @reserve_ms %{
    active_session_id: 0,
    amend: 9_900,
    events_since: 300,
    # The health refresh (bounded by its own 1,200 ms call) and the
    # collector's reply window; the deadline is checked again after the
    # refresh, before any span is forwarded.
    ingest_spans: 2_300,
    hint_context: 0,
    known_normal: 0,
    reader_view: 0,
    # A pin's backfill reads the Recorder within what is left of the
    # request, keeping this much for the reply.
    trace_retention: 300,
    retention_hint: 0,
    inspect_context: 0,
    # Recording an inspection makes one session call, bounded by
    # @record_inspection_ms and by the deadline less 200 ms for the reply.
    record_inspection: 300,
    # A mark reads the newest receipt, then records its event: two session
    # calls, each bounded by what is left less 200 ms for the reply.
    mark: 300,
    marks: 0,
    renew: 1_700,
    start: 3_500,
    status: 1_700,
    stop: 6_100,
    subscribe: 1_700,
    unsubscribe: 0
  }
  @ended_reasons [:expired_or_unknown_session, :cleanup_in_progress]
  @record_inspection_ms 1_000

  # Room between the collector's deadline plus its reply window and the
  # caller's deadline, for the owner's own reply.
  @ingest_reply_margin_ms 200

  @spec bounds() :: map()
  def bounds do
    %{
      "admitted_calls_max" => @admitted_calls_max,
      "subscribers_max" => @max_subscribers,
      "push_interval_ms" => @push_interval_ms,
      "push_events_max" => @push_limit,
      "push_bytes_max" => @push_max_bytes,
      "push_scanned_max" => @push_scan_limit,
      "recorder_max_bytes" => @recorder_max_bytes,
      "read_page_entries" => @page_entries,
      "read_page_bytes" => @page_bytes,
      "retained_terminal_sessions" => @retained_terminals,
      "filtered_report_ms" => @filtered_report_ms,
      "readers_max" => @readers_max,
      "trace_index_max" => @trace_index_max,
      "reader_active_ms" => @reader_active_ms,
      "stopped_readable_ms" => @stopped_readable_ms,
      "retained_readable_sessions" => @retained_readable,
      "amendments_listed" => @amendments_listed
    }
    |> Map.merge(Archive.bounds())
    |> Map.merge(Marks.bounds())
  end

  @doc false
  @spec admitted_calls_max() :: pos_integer()
  def admitted_calls_max, do: @admitted_calls_max

  @doc false
  @spec admission(pid()) :: {:ok, Admission.t()} | :error
  def admission(pid) do
    case :persistent_term.get({__MODULE__, pid}, :missing) do
      %Admission{} = admission -> {:ok, admission}
      _missing -> :error
    end
  end

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_options \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    Process.flag(:message_queue_data, :off_heap)
    {:ok, host_policy} = HostPolicy.new()

    # The export policy is fixed here, never caller supplied. It bounds and
    # validates every returned value and yields the per-event redaction
    # manifest; `Insider.Live.Disclosure` then applies the session's
    # disclosure profile and credential masking.
    {:ok, redaction_policy} =
      RedactionPolicy.new(
        id: "insider-live",
        maximum_sensitivity: :internal,
        rules: [],
        max_nodes: 4_096,
        max_output_bytes: 32_768
      )

    admission = Admission.new()
    # Ecto redact fields for rich rendering, read by emitters, written here.
    :ok = RedactFields.create()
    :persistent_term.put({__MODULE__, self()}, admission)
    # A new owner knows no session: gates a previous owner left behind are
    # reclaimed before this owner accepts a call.
    :ok = Gates.reclaim()

    {:ok,
     %{
       admission: admission,
       boot_id: "live-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
       host_policy: host_policy,
       push_timer: nil,
       redaction_policy: redaction_policy,
       session: nil,
       terminals: []
     }}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
  end

  @impl GenServer
  def handle_call(
        {:admitted, admission, deadline, request},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) and is_tuple(request) do
    Admission.release(admission)

    operation = elem(request, 0)

    cond do
      remaining(deadline) <= 0 ->
        {:reply, {:error, Error.new("timeout")}, state}

      operation not in @gated_operations and
          remaining(deadline) <= Map.get(@reserve_ms, operation, 0) ->
        {:reply, {:error, Error.new("timeout")}, state}

      true ->
        {reply, state} = dispatch(request, deadline, state)

        if operation in @reading_operations,
          do: {:reply, reply, state, {:continue, :collect}},
          else: {:reply, reply, state}
    end
  end

  # Raw same-node messages are outside the admission boundary.
  def handle_call(_request, _from, state),
    do: {:reply, {:error, Error.new("invalid_options", %{"field" => "request"})}, state}

  # A read's pages and result are garbage once it has been replied or pushed.
  # Collecting them at once returns the owner's heap to the size of its state
  # instead of keeping it until the next collection, which an idle owner may
  # not reach for a long time.
  @impl GenServer
  def handle_continue(:collect, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:lease_check, id}, %{session: %{id: id} = session} = state) do
    cond do
      session.revoking or not Environment.allowed?(Environment.resolve()) ->
        end_or_retry(state, "revoked", "environment_denied")

      lease_remaining(session) == 0 ->
        end_or_retry(state, "expired", "lease_expired")

      true ->
        {:noreply, schedule_lease(state, lease_remaining(session))}
    end
  end

  # A pending revocation is retried by its own timer, not by push ticks.
  def handle_info(:push, state) do
    state = %{state | push_timer: nil}

    state =
      cond do
        match?(%{session: %{revoking: true}}, state) -> state
        Environment.allowed?(Environment.resolve()) -> state |> push() |> sweep()
        true -> state |> revoke() |> elem(1)
      end

    {:noreply, schedule_push(state), {:continue, :collect}}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{session: session} = state)
      when is_map(session) do
    case Map.fetch(session.subscribers, pid) do
      {:ok, %{monitor: ^monitor}} ->
        session = %{session | subscribers: Map.delete(session.subscribers, pid)}
        {:noreply, %{state | session: session}}

      _other ->
        {:noreply, state}
    end
  end

  # The gate keeper died and this owner inherited a summary table. The
  # active session's table is kept (and deleted when the gate is released);
  # any other belongs to a gate this owner never acknowledged, such as one
  # created just before the keeper died mid-reply, so it is deleted now and
  # its gate released. A release the restarted keeper cannot take yet is
  # completed by the next start's exclusive creation.
  def handle_info({:"ETS-TRANSFER", table, _from, {Gate, _id} = key}, state) do
    if not match?(%{session: %{gate: ^key}}, state) do
      Gate.delete_table(table)
      Gates.release(key)
    end

    {:noreply, state}
  end

  # A stopped session's retention window has passed: its archive is freed
  # and reads get `session_terminal` again.
  def handle_info({:retention_expired, id}, state) do
    terminals =
      Enum.map(state.terminals, fn
        %{id: ^id} = terminal -> %{terminal | retained: nil, readable_until: nil, timer: nil}
        terminal -> terminal
      end)

    {:noreply, %{state | terminals: terminals}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch({:active_session_id}, _deadline, state),
    do: {{:ok, state.session && state.session.id}, state}

  defp dispatch({:start, options}, deadline, state) do
    gated(state, deadline, :start, fn state ->
      case refresh(state) do
        {%{session: nil} = state, _health} ->
          start_session(options, state)

        {%{session: session} = state, _health} ->
          {{:error, Error.new("session_already_active", %{"active_session_id" => session.id})},
           state}
      end
    end)
  end

  # A running session is read from its Recorder (and its archive, before its
  # last amendment); a stopped one, within its retention window, from the
  # archive its stop copied.
  # A timeline or trace scan's read (`Insider.Live.TimelineScan.request/3`):
  # a read like `events_since`, but its losses are the session's cumulative
  # totals whatever cursor it starts at, and it issues no cursor baseline,
  # so it neither depends on nor moves another reader's accounting.
  defp dispatch({:events_since, id, cursor, options, :cumulative}, deadline, state),
    do: events_since(state, id, cursor, options, deadline, true)

  # `status`'s anomalies: a cumulative read that also leaves the lease alone.
  defp dispatch({:events_since, id, cursor, options, :observe}, deadline, state),
    do: events_since(state, id, cursor, options, deadline, :observe)

  defp dispatch({:events_since, id, cursor, options}, deadline, state),
    do: events_since(state, id, cursor, options, deadline, false)

  # A digest's time window is found by probing: the receipt and Recorder
  # admission time of the first disclosed event after `cursor`, read from
  # the Recorder or archive pages like `events_since`, but without a view,
  # without renewing the lease, and without keeping a cursor baseline, so
  # probing never moves another reader's gap accounting.
  defp dispatch({:probe, id, cursor, :observe}, deadline, state)
       when is_integer(cursor) and cursor >= 0 do
    observed(state, deadline, fn state ->
      case readable(state, id) do
        {:ok, source} -> probe(state, source, cursor, deadline)
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:probe, id, cursor}, deadline, state) when is_integer(cursor) and cursor >= 0 do
    gated(state, deadline, :events_since, fn state ->
      case readable(state, id) do
        {:ok, source} -> probe(state, source, cursor, deadline)
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:renew, id}, deadline, state) do
    gated(state, deadline, :renew, fn state ->
      {state, _health} = refresh(state)

      case active(state, id) do
        {:ok, session} ->
          session = renew_lease(session)
          {{:ok, lease_status(session)}, %{state | session: session}}

        {:error, error} ->
          {{:error, error}, state}
      end
    end)
  end

  # Status, stop, and unsubscribe stay available after an environment
  # change so a caller can always observe and complete cleanup.
  defp dispatch({:status, id}, _deadline, state) do
    case state.session do
      %{id: ^id} ->
        case state |> sweep() |> refresh() do
          {%{session: %{id: ^id} = session} = state, health} ->
            {{:ok, running_status(session, health)}, state}

          {state, _health} ->
            terminal_reply(state, id, :status)
        end

      _other ->
        terminal_reply(state, id, :status)
    end
  end

  # A stop refuses while another named reader was active within
  # `@reader_active_ms` or is subscribed, unless forced. Stopping an ended
  # session returns its record again.
  defp dispatch({:stop, id, options}, deadline, state) do
    case {Options.stop(options), state.session} do
      {{:error, error}, _session} ->
        {{:error, error}, state}

      {{:ok, stop}, %{id: ^id} = session} ->
        case {peers(session, stop.reader), stop.force} do
          {[], _force} -> stop(state, deadline)
          {_peers, true} -> stop(state, deadline)
          {named, false} -> {{:error, readers_active(session, named)}, state}
        end

      {{:ok, _stop}, _session} ->
        terminal_reply(state, id, :stop)
    end
  end

  # A subscription starts at cursor 0, at a cursor no newer than the newest
  # receipt, or at `"latest"`, the newest receipt now. Subscribing again
  # replaces the view and the event budget; it moves the cursor only when
  # one is given.
  defp dispatch({:subscribe, id, pid, options}, deadline, state) do
    gated(state, deadline, :subscribe, fn state ->
      {state, health} = refresh(state)

      with {:ok, session} <- active(state, id),
           :ok <- valid_subscriber(pid),
           {:ok, %{reader: reader, view: given}} <- Options.reading(options),
           options = with_reader_view(options, session, reader, given),
           {:ok, subscription} <- Options.subscribe(options),
           {:ok, cursor} <- start_cursor(subscription.cursor, fill(session, health)),
           {:ok, session} <- add_subscriber(session, pid, %{subscription | cursor: cursor}) do
        subscriber = Map.fetch!(session.subscribers, pid)
        session = seen(session, subscriber.reader, subscriber.sent_cursor, given)
        state = schedule_push(%{state | session: session})
        {{:ok, subscription(session, subscriber)}, state}
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:unsubscribe, id, pid}, _deadline, state) do
    with {:ok, session} <- active(state, id), :ok <- valid_subscriber(pid) do
      session = drop_subscriber(session, pid)
      {{:ok, subscription(session, nil)}, %{state | session: session}}
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  # An amendment validates the session's options with the given ones
  # replacing theirs, as a start would, before any side effect. A `nil`
  # value returns that option to its default, and so does a kept Poller or
  # call-trace option when the amended components (given, kept, or the
  # defaults after a reset) leave that component out (dropping the calls
  # component drops its trace); such an option given with its component
  # left out is refused as at start.
  defp dispatch({:amend, id, options}, deadline, state) do
    gated(state, deadline, :amend, fn state ->
      {state, _health} = refresh(state)

      with {:ok, session} <- active(state, id),
           {:ok, reader, changes} <- Options.amend(options),
           merged = amended_options(session.options, changes),
           {:ok, parsed} <- Options.start(merged),
           :ok <- Credentials.warm() do
        change = %{reader: reader, requested: changes |> Map.keys() |> Enum.sort()}
        amend(state, session, {merged, parsed}, change, deadline)
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  # Ingest runs inside the owner, so it is ordered with start and stop: the
  # session checked here is the session whose otel collector records the
  # spans, and a session started later can never receive them. After the health refresh, a call without time left for the
  # collector to take the spans and reply is refused before forwarding, and
  # the collector refuses spans it takes after its own, earlier deadline.
  # A `timeout` after the collector took the spans is outcome unknown (two
  # processes cannot make it otherwise); the collector's ingest is
  # idempotent per span id while the id is in its bounded seen-set, so a
  # retry duplicates only spans it has already forgotten (`seen_evicted`).
  defp dispatch({:ingest_spans, id, spans}, deadline, state) do
    gated(state, deadline, :ingest_spans, fn state ->
      {state, _health} = refresh(state)
      collector_deadline = deadline - Otel.ingest_reply_ms() - @ingest_reply_margin_ms

      with {:ok, _session} <- active(state, id),
           :ok <- in_time(collector_deadline) do
        {ingested(id, Otel.ingest(spans, collector_deadline)), state}
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  # A one-shot inspection runs in the caller. It asks first for what to
  # apply: the running session's effective disclosure profile (else the
  # host's) and the host's protected targets, and which session to record
  # into.
  defp dispatch({:inspect_context}, _deadline, state) do
    {profile, id} =
      case state.session do
        %{revoking: false, id: id} = session -> {Disclosure.effective(session.disclosure), id}
        _none -> {elem(Disclosure.host_profile(), 0), nil}
      end

    {{:ok, %{profile: profile, session_id: id, protection: state.host_policy.protected_targets}},
     state}
  end

  # A digest's hints need the running session's configuration and the
  # Recorder's per-source usage as of its latest read, without the
  # collector health check `status` makes.
  defp dispatch({:reader_view, id, reader}, _deadline, state),
    do: dispatch_reader_view(state, id, reader)

  # What retention keeps of one trace, pinning it first when asked, for
  # `trace`: the kept events through the session's disclosure boundary,
  # what retention says of them, and the effective profile. A running
  # session is swept first, so the reply holds every event copied so far.
  #
  # Values are checked against the effective profile first, so a refused
  # request changes nothing. Kept events pass the reader's view, resolved
  # against the trace index as a read's is.
  defp dispatch({:trace_retention, id, trace_id, request}, deadline, state) do
    gated(state, deadline, :trace_retention, fn state ->
      with {:ok, source} <- readable(state, id),
           records = records(source),
           :ok <- values_allowed(request.values, records),
           {:ok, view} <- retained_view(request.reading, records) do
        case source do
          {:running, _session} ->
            state = sweep(state)

            session =
              if request.retain, do: pin(state.session, trace_id, deadline), else: state.session

            {{:ok, kept(session, trace_id, view)}, %{state | session: session} |> schedule_push()}

          {:retained, terminal} ->
            {{:ok, kept(terminal.retained, trace_id, view)}, state}
        end
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  # The kept mutation records (`Insider.Live.Mutations`) of a session,
  # projected for its profile and passed through the reader's view (given
  # in `reading`, or the named reader's own) as its events are, optionally
  # of one trace or process. A running session is swept first. For one
  # trace each record says whether the Recorder (or the session's archive)
  # still holds its event (`"evicted"`). A read of a running session renews
  # its lease.
  defp dispatch({:mutations, id, filters, reading}, deadline, state) do
    gated(state, deadline, :reader_view, fn state ->
      with {:ok, source} <- readable(state, id),
           {:ok, view} <- retained_view(reading, records(source)) do
        state =
          if match?({:running, _session}, source),
            do: state |> sweep() |> Map.update!(:session, &renew_lease/1),
            else: state

        records =
          if match?({:running, _session}, source), do: state.session, else: records(source)

        {{:ok, kept_mutations(records, filters, view)}, state}
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  # Whether this is the first time `trace` offers to pin `trace_id`.
  # The session's known-normal anomaly baseline (`Insider.Live.Anomalies`),
  # behind the gates a digest read passes: read from a running or retained
  # session (renewing a running one's lease), set or cleared on a running
  # one (renewing it), which keeps it for its life and its read-only
  # window. `status` reads it observing: refused where observation is not
  # allowed, never revoking, never renewing. Its entries are hashed
  # identities and counts, so no profile narrows them.
  defp dispatch({:known_normal, id, :observe}, deadline, state) do
    observed(state, deadline, fn state ->
      case readable(state, id) do
        {:ok, source} -> {{:ok, Map.get(records(source), :known_normal)}, state}
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:known_normal, id, :get}, deadline, state) do
    gated(state, deadline, :known_normal, fn state ->
      case readable(state, id) do
        {:ok, {:running, session}} ->
          {{:ok, Map.get(session, :known_normal)}, %{state | session: renew_lease(session)}}

        {:ok, source} ->
          {{:ok, Map.get(records(source), :known_normal)}, state}

        {:error, error} ->
          {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:known_normal, id, {:put, baseline}}, deadline, state) do
    gated(state, deadline, :known_normal, fn state ->
      case active(state, id) do
        {:ok, session} ->
          session = session |> Map.put(:known_normal, baseline) |> renew_lease()
          {{:ok, Map.get(state.session, :known_normal)}, %{state | session: session}}

        {:error, error} ->
          {{:error, error}, state}
      end
    end)
  end

  defp dispatch({:retention_hint, id, trace_id}, _deadline, state) do
    case state.session do
      %{id: ^id, retention: retention} = session ->
        {first?, retention} = Retention.hint(retention, trace_id)
        {{:ok, first?}, %{state | session: %{session | retention: retention}}}

      _other ->
        {{:ok, false}, state}
    end
  end

  defp dispatch({:hint_context, id}, _deadline, state) do
    case state.session do
      %{revoking: false, id: ^id} = session ->
        context =
          session
          |> configuration()
          |> Map.merge(%{
            "session_id" => id,
            "recorder" => %{"sources" => Map.get(session, :recorder_sources) || %{}},
            "reader_count" => map_size(session.readers) + map_size(session.subscribers)
          })

        {{:ok, context}, state}

      _other ->
        {{:error, Error.new("unknown_session")}, state}
    end
  end

  # A pairing mark (`Insider.Live.Marks`): the newest receipt now, then a
  # `live.mark` event. A read since the mark starts after that receipt, so
  # it holds the mark's event and everything after it. The mark is kept
  # even when its event could not be recorded, and says so. It renews the
  # lease; a stopped session takes no new mark.
  defp dispatch({:mark, id, request}, deadline, state) do
    gated(state, deadline, :mark, fn state ->
      case readable(state, id) do
        {:ok, {:running, session}} ->
          mark(state, session, request, deadline)

        {:ok, {:retained, terminal}} ->
          {{:error, Error.new("session_terminal", %{"status" => terminal.record})}, state}

        {:error, error} ->
          {{:error, error}, state}
      end
    end)
  end

  # A running or stopped session's marks.
  defp dispatch({:marks, id, human}, deadline, state) do
    gated(state, deadline, :marks, fn state ->
      case readable(state, id) do
        {:ok, source} ->
          {{:ok, Marks.document(id, Map.get(records(source), :marks), human)}, state}

        {:error, error} ->
          {{:error, error}, state}
      end
    end)
  end

  # The mark a read since `"mark"` (`nil`) or `"mark:LABEL"` starts at.
  defp dispatch({:mark_lookup, id, label}, deadline, state) do
    gated(state, deadline, :marks, fn state ->
      case readable(state, id) do
        {:ok, source} -> {source |> records() |> Map.get(:marks) |> Marks.find(label), state}
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  # Then its result is recorded as an `inspect.KIND` event in that session,
  # when it still runs.
  defp dispatch({:record_inspection, id, kind, attributes, subject}, deadline, state) do
    case state.session do
      %{id: ^id, revoking: false} = session ->
        timeout = deadline |> remaining() |> Kernel.-(200) |> min(@record_inspection_ms) |> max(1)

        recorded =
          state
          |> inspection_event(session, kind, attributes, subject)
          |> record_built(session.handle, timeout)

        {{:ok, inspection_recorded(id, recorded)}, state}

      _ended ->
        {{:ok, %{"session_id" => id, "recorded" => false, "reason" => "session_ended"}}, state}
    end
  end

  # An admitted envelope may carry any tuple; an unknown operation is refused
  # rather than crashing the owner and the session it holds.
  defp dispatch(_request, _deadline, state),
    do: {{:error, Error.new("invalid_options", %{"field" => "request"})}, state}

  @component_options [{"poller", PollerOptions}, {"calls", CallsOptions}]

  defp amended_options(options, changes) do
    merged = options |> Map.merge(changes) |> Map.reject(&is_nil(elem(&1, 1)))
    # The components the start validation will use: without the option,
    # its defaults.
    components = Map.get_lazy(merged, "components", &Filters.default_components/0)

    if is_list(components) do
      Enum.reduce(@component_options, merged, fn {component, module}, merged ->
        if component in components,
          do: merged,
          else: Map.drop(merged, module.start_keys() -- Map.keys(changes))
      end)
    else
      merged
    end
  end

  defp in_time(deadline),
    do: if(now() < deadline, do: :ok, else: {:error, Error.new("timeout")})

  # Observation requires the environment to be allowed now, not only when the
  # session started. The gate runs before the deadline reserve, so a denial is
  # never turned into a `timeout`. A revoked environment stops the active
  # session through the normal cleanup path before the denial is returned; a
  # revocation whose cleanup failed keeps denying and retries on a timer.
  defp gated(state, deadline, operation, fun) do
    case allowed(state) do
      {:ok, state} ->
        if remaining(deadline) <= Map.fetch!(@reserve_ms, operation),
          do: {{:error, Error.new("timeout")}, state},
          else: fun.(state)

      {:error, error, state} ->
        {{:error, error}, state}
    end
  end

  defp gate(state, deadline, :observe, fun), do: observed(state, deadline, fun)
  defp gate(state, deadline, _cumulative, fun), do: gated(state, deadline, :events_since, fun)

  # `status`'s observing reads: refused when observation is not allowed,
  # but never revoking or ending the session (that is for the operations
  # that act on it), and never renewing its lease.
  defp observed(state, deadline, fun) do
    environment = Environment.resolve()

    cond do
      match?(%{session: %{revoking: true}}, state) or not Environment.allowed?(environment) ->
        {{:error, Error.new("environment_denied", Environment.describe(environment))}, state}

      remaining(deadline) <= Map.fetch!(@reserve_ms, :events_since) ->
        {{:error, Error.new("timeout")}, state}

      true ->
        fun.(state)
    end
  end

  defp allowed(%{session: %{revoking: true}} = state) do
    denial = Map.put(Environment.describe(Environment.resolve()), "revocation_pending", true)
    {:error, Error.new("environment_denied", denial), state}
  end

  defp allowed(state) do
    environment = Environment.resolve()

    if Environment.allowed?(environment) do
      {:ok, state}
    else
      {details, state} = revoke(state)
      denial = Map.merge(Environment.describe(environment), details)
      {:error, Error.new("environment_denied", denial), state}
    end
  end

  defp revoke(%{session: nil} = state), do: {%{}, state}

  defp revoke(state) do
    case finish(state, "revoked", "environment_denied") do
      {:ok, record, state} -> {%{"status" => record}, state}
      {:error, _error, state} -> {%{"revocation_pending" => true}, revocation_pending(state)}
    end
  end

  # Cleanup failed, so collection is still running. Replace the lease timer
  # with a bounded cleanup retry rather than waiting out the lease.
  defp revocation_pending(%{session: session} = state) do
    state = %{state | session: %{session | revoking: true}}
    schedule_lease(state, @stop_retry_ms)
  end

  defp read_events(state, {:running, session}, cursor, read_options, deadline) do
    {renew?, read_options} = Keyword.pop(read_options, :renew, true)
    session = if renew?, do: renew_lease(session), else: session
    state = %{state | session: session}

    case read_batch(session, cursor, read_options, read_timeout(deadline), lease(session)) do
      {:ok, batch, session} ->
        {{:ok, hinted(batch, session, read_options)}, %{state | session: session}}

      {:error, :invalid_cursor} ->
        invalid_cursor(state, {:running, session}, deadline)

      {:error, :invalid_upto} ->
        {invalid_upto(), state}

      {:error, reason} ->
        session_error(state, reason)
    end
  end

  # A stopped session's archive reads like the running session did, with
  # the ended state, no lease, how long it stays readable, and the
  # disclosure profile its events crossed.
  defp read_events(state, {:retained, terminal} = source, cursor, read_options, deadline) do
    extra = %{
      "state" => terminal.record["state"],
      "lease_remaining_ms" => 0,
      "readable_remaining_ms" => readable_remaining(terminal),
      "disclosure_profile" => Atom.to_string(Disclosure.effective(terminal.retained.disclosure))
    }

    case read_batch(terminal.retained, cursor, read_options, read_timeout(deadline), extra) do
      {:ok, batch, retained} ->
        {{:ok, batch}, put_terminal(state, %{terminal | retained: retained})}

      {:error, :invalid_upto} ->
        {invalid_upto(), state}

      {:error, _invalid_cursor} ->
        invalid_cursor(state, source, deadline)
    end
  end

  defp invalid_upto, do: {:error, Error.new("invalid_options", %{"field" => "upto"})}

  # A named reader without a view reads through its own view; a view given
  # with a name becomes that reader's view (`nil` or `%{}` clears it). A
  # view scoped to services or routes is resolved against the session's
  # trace index before the read.
  # A cursor given as a pairing mark (`"mark"`, `"mark:LABEL"`) reads after
  # the mark's receipt, and the batch names the mark.
  defp events_since(state, id, cursor, options, deadline, cumulative) do
    gate(state, deadline, cumulative, fn state ->
      with {:ok, source} <- readable(state, id),
           {:ok, %{reader: reader, view: given}} <- Options.reading(options),
           records = records(source),
           {:ok, cursor, mark} <- from_mark(records, cursor),
           options = with_reader_view(options, records, reader, given),
           {:ok, read_options} <- Options.read(options) do
        read_options =
          read_options
          |> Keyword.update!(:view, &resolve(&1, records))
          |> Keyword.put(:store_view, given)
          |> Keyword.put(:cumulative, cumulative != false)
          |> Keyword.update!(:renew, &(&1 and cumulative != :observe))

        case Options.cursor(cursor) do
          {:ok, cursor} ->
            state |> read_events(source, cursor, read_options, deadline) |> put_mark(mark)

          :error ->
            invalid_cursor(state, source, deadline)
        end
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  defp from_mark(records, cursor) do
    case Options.mark_cursor(cursor) do
      {:mark, label} ->
        with {:ok, mark} <- Marks.find(Map.get(records, :marks), label),
             do: {:ok, mark["cursor"], mark}

      :invalid ->
        {:error, Error.new("invalid_options", %{"field" => "cursor"})}

      :cursor ->
        {:ok, cursor, nil}
    end
  end

  defp put_mark({{:ok, batch}, state}, %{} = mark),
    do: {{:ok, Map.put(batch, "mark", Marks.describe(mark))}, state}

  defp put_mark(reply, _mark), do: reply

  ## Retention (`Insider.Live.Retention`)

  defp kept(records, trace_id, view) do
    retention = Map.get(records, :retention)
    profile = Disclosure.effective(records.disclosure)
    allowlist = Disclosure.measurement_allowlist()

    %{
      "disclosure_profile" => Atom.to_string(profile),
      "entries" =>
        retention
        |> Retention.entries(trace_id)
        |> Enum.map(&Disclosure.project(&1, allowlist, profile))
        |> Enum.reject(&(View.hides(view, &1["event"]) || View.hides_deep(view, &1["event"]))),
      "retention" => Retention.info(retention, trace_id)
    }
  end

  # Response values are payload content: only the rich profile records them.
  defp values_allowed(true, records) do
    case Disclosure.effective(records.disclosure) do
      :rich ->
        :ok

      profile ->
        {:error,
         Error.new("disclosure_denied", %{
           "field" => "values",
           "required" => "rich",
           "disclosure_profile" => Atom.to_string(profile),
           "hint" =>
             "values are the GraphQL response data recorded only under the rich profile; start a session with " <>
               "--disclosure rich where the host allows it (development and test default to rich)"
         })}
    end
  end

  defp values_allowed(_values, _records), do: :ok

  # The reader's view as a read would apply it, without storing it.
  defp retained_view(reading, records) do
    with {:ok, %{reader: reader, view: given}} <- Options.reading(reading),
         options = with_reader_view(reading, records, reader, given),
         {:ok, read_options} <- Options.read(options) do
      {:ok, resolve(Keyword.get(read_options, :view), records)}
    end
  end

  # A pin is backfilled with the trace's events the Recorder (and the
  # archive) still hold, up to where the sweep has copied; receipts the
  # deadline left unread count as missed.
  defp pin(session, trace_id, deadline) do
    upto = Retention.cursor(session.retention)
    budget = deadline - Map.fetch!(@reserve_ms, :trace_retention)
    {entries, reached} = backfill(session, trace_id, 0, upto, budget, [])
    {retention, _released} = Retention.pin(session.retention, trace_id, entries, reached)

    retention =
      if is_integer(upto) and reached < upto,
        do:
          Retention.sweep(retention, %{
            "events" => [],
            "next_cursor" => 0,
            "evicted" => upto - reached
          }),
        else: retention

    %{session | retention: retention}
  end

  defp backfill(session, trace_id, cursor, upto, deadline, found) do
    timeout = deadline - now()

    with true <- timeout > 0 and (is_nil(upto) or cursor < upto),
         {:ok, read} <- read_entries(session, cursor, @page_entries, timeout, false) do
      next = if upto, do: min(read["next_cursor"], upto), else: read["next_cursor"]

      found =
        for(
          entry <- read["events"],
          entry["receipt"] <= next,
          View.trace_id(entry["event"] || %{}) == trace_id,
          do: entry
        )
        |> Enum.reverse(found)

      if next > cursor and next < (upto || read["next_receipt"]),
        do: backfill(session, trace_id, next, upto, deadline, found),
        else: {Enum.reverse(found), next}
    else
      _done -> {Enum.reverse(found), cursor}
    end
  end

  # Copies what is new since each sweep's cursor into retention and the
  # mutation ring (`Insider.Live.Mutations`), each at most @sweep_entries
  # entries within @sweep_ms; a later tick goes on.
  defp sweep(%{session: %{handle: handle} = session} = state) when handle != nil do
    session =
      Enum.reduce([{:retention, Retention}, {:mutations, Mutations}], session, fn {field, module},
                                                                                  session ->
        data = Map.get(session, field)

        if module.active?(data),
          do:
            Map.put(
              session,
              field,
              sweep_pages(session, module, data, now() + @sweep_ms, @sweep_entries)
            ),
          else: session
      end)

    %{state | session: session}
  end

  defp sweep(state), do: state

  defp sweep_pages(session, module, data, deadline, left) do
    cursor = module.cursor(data)
    timeout = deadline - now()

    with true <- timeout > 0 and left > 0,
         {:ok, read} <- read_entries(session, cursor, min(left, @page_entries), timeout, false) do
      read_count = length(read["events"]) + length(read["withheld_receipts"] || [])
      evicted = max(read["next_cursor"] - cursor - read_count, 0)
      data = module.sweep(data, Map.put(read, "evicted", evicted))

      if read["next_cursor"] > cursor and read["next_cursor"] < read["next_receipt"],
        do: sweep_pages(session, module, data, deadline, left - read_count),
        else: data
    else
      _done -> data
    end
  end

  defp kept_mutations(records, filters, view) do
    profile = Disclosure.effective(records.disclosure)
    allowlist = Disclosure.measurement_allowlist()

    shown? = fn entry ->
      event = Disclosure.project(entry, allowlist, profile)["event"]
      is_nil(View.hides(view, event) || View.hides_deep(view, event))
    end

    kept = Mutations.records(Map.get(records, :mutations), profile, filters, shown?)

    kept =
      if Keyword.has_key?(filters, :trace_id),
        do: Enum.map(kept, &Map.put(&1, "evicted", not still_recorded?(records, &1["receipt"]))),
        else: kept

    %{"records" => kept, "accounting" => Mutations.describe(Map.get(records, :mutations))}
  end

  # Whether a read at the receipt still finds it (the Recorder, or the
  # session's archive); a read that fails says nothing, so it counts as held.
  defp still_recorded?(records, receipt) do
    case read_entries(records, receipt - 1, 1, 100, false) do
      {:ok, read} ->
        Enum.any?(read["events"], &(&1["receipt"] == receipt)) or
          receipt in (read["withheld_receipts"] || [])

      _unavailable ->
        true
    end
  end

  defp records({:running, session}), do: session
  defp records({:retained, terminal}), do: terminal.retained

  defp with_reader_view(options, records, reader, :keep) when is_binary(reader) do
    case get_in(records, [:readers, reader]) do
      %{view: %{} = spec} -> Map.put(options, "view", spec)
      _none -> options
    end
  end

  defp with_reader_view(options, _records, _reader, _given), do: options

  # A named reader's own view, or `nil`.
  defp dispatch_reader_view(state, id, reader) do
    case readable(state, id) do
      {:ok, source} ->
        view = get_in(records(source), [:readers, reader])
        {{:ok, view && view[:view]}, state}

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp probe(state, source, cursor, deadline) do
    records =
      case source do
        {:running, session} -> session
        {:retained, terminal} -> terminal.retained
      end

    case probe_pages(records, cursor, now() + read_timeout(deadline), 0) do
      {:ok, found} ->
        {{:ok, Map.put(found, "cursor", cursor)}, state}

      {:error, reason} when reason != :invalid_cursor and elem(source, 0) == :running ->
        session_error(state, reason)

      {:error, _invalid_cursor} ->
        invalid_cursor(state, source, deadline)
    end
  end

  # Pages of at most `@probe_entries` entries, until the first disclosed
  # event. A withheld receipt has no admission time to show, so the probe
  # reads past it; it stops undecided (`"receipt"` nil, `"exhausted"`
  # false) after `@probe_scan` retained entries (each page asks only for
  # what is left of them) or at its deadline, and exhausted when it read to
  # the newest receipt without a disclosed event.
  @probe_entries 32
  @probe_scan 1_000

  defp probe_pages(records, page_cursor, until, scanned) do
    entries = min(@probe_entries, @probe_scan - scanned)

    with {:ok, page} <- read_entries(records, page_cursor, entries, max(until - now(), 1), false) do
      %{"next_cursor" => next, "next_receipt" => newest} = page
      scanned = scanned + length(page["events"]) + page["redaction_withheld"]

      case page["events"] do
        [first | _rest] ->
          {:ok, probed(newest, first["receipt"], first["received_at_us"], false)}

        [] when next >= newest ->
          {:ok, probed(newest, nil, nil, true)}

        [] when next > page_cursor and scanned < @probe_scan ->
          if now() < until,
            do: probe_pages(records, next, until, scanned),
            else: {:ok, probed(newest, nil, nil, false)}

        [] ->
          {:ok, probed(newest, nil, nil, false)}
      end
    end
  end

  defp probed(newest, receipt, received_at_us, exhausted) do
    %{
      "receipt" => receipt,
      "received_at_us" => received_at_us,
      "exhausted" => exhausted,
      "next_receipt" => newest
    }
  end

  # A batch that shows a crash or exception carries `"hints"`: the call
  # trace that would record the failing call (`Insider.Live.Hints`). A
  # digest's own bounded reads (`upto`) work theirs out over the window.
  defp hinted(batch, session, read_options) do
    with nil <- Keyword.get(read_options, :upto),
         [_ | _] = hints <-
           Hints.batch(
             batch["events"],
             Hints.context(Map.put(configuration(session), "session_id", session.id))
           ) do
      Map.put(batch, "hints", hints)
    else
      _none -> batch
    end
  end

  # One reader's batch from `source` (the running session, or a stopped
  # session's retained archive), and `source` with the batch's baseline
  # and the named reader's new cursor and view. A cumulative read (a trace
  # or timeline scan page) marks the reader seen without moving its cursor.
  # A named reader's batch says which view it was read through.
  defp read_batch(source, cursor, read_options, timeout_ms, extra) do
    {view, limits} = Keyword.pop(read_options, :view)
    {reader, limits} = Keyword.pop(limits, :reader)
    {cumulative, limits} = Keyword.pop(limits, :cumulative, false)
    {store_view, limits} = Keyword.pop(limits, :store_view, :keep)

    with {:ok, {read, hidden}} <- scan(source, cursor, view, Map.new(limits), timeout_ms) do
      # `"latest"` is resolved by the read, so the baseline is looked up
      # by the cursor the read started at. A cumulative read has none.
      baseline = if cumulative, do: nil, else: baseline(source.baselines, read["cursor"])
      {batch, counters} = Batch.build(source.id, read, baseline, extra)
      filter_baseline = if baseline, do: Map.get(baseline, "filtered")
      {batch, counts} = filtered(source, batch, filter_baseline, hidden)
      counters = Map.put(counters, "filtered", counts)

      source =
        if cumulative,
          do: source,
          else: %{source | baselines: put_baseline(source.baselines, read, counters)}

      # The Recorder's per-source usage as of this read, for hints.
      source = Map.put(source, :recorder_sources, read["recorder_sources"])
      reader_cursor = if cumulative, do: :keep, else: batch["next_cursor"]

      batch =
        if reader,
          do:
            batch
            |> Map.merge(%{"reader" => reader, "view" => view && view.spec})
            |> put_view_note(source, reader, store_view),
          else: batch

      {:ok, batch, seen(source, reader, reader_cursor, store_view)}
    end
  end

  # One public read for a reader at `cursor` through its `view`, selected by
  # `Insider.Live.Batch` page by page: `limit` and `max_bytes` bound the
  # events returned and `scan_limit` the entries examined. Without a view
  # every entry is returned unless redaction withholds it, so a read asks
  # for only as many entries as it still has events to return and reads on
  # past withheld ones. Pages after the first never move the read's
  # snapshot, and one that would start after the deadline is not read: the
  # read then ends with `"deadline"`.
  defp scan(session, cursor, view, limits, timeout_ms, finalize \\ false) do
    deadline = now() + timeout_ms
    selection = Batch.selection(view, limits, Disclosure.effective(session.disclosure))
    read_pages(session, cursor, selection, {finalize, deadline})
  end

  # Pages are fed to `Insider.Live.Batch` in receipt order. A reader's
  # `upto` bounds the read before anything is selected, so its losses are
  # counted from the receipts up to it, while the batch still reports the
  # newest receipt when the read began; it must lie between the resolved
  # starting cursor and that receipt (checked on the first page), or the
  # bound could not hold.
  defp read_pages(session, cursor, selection, {finalize, deadline}) do
    entries = min(Batch.wanted(selection), @page_entries)

    with {:ok, page} <- read_entries(session, cursor, entries, remaining(deadline), finalize),
         :ok <- Batch.check_upto(selection, page) do
      case Batch.add(selection, page) do
        {:halt, selection} -> {:ok, Batch.finish(selection)}
        {:cont, selection} -> read_on(session, selection, deadline)
      end
    end
  end

  defp read_on(session, selection, deadline) do
    cond do
      Batch.wanted(selection) == 0 ->
        {:ok, Batch.finish(selection)}

      remaining(deadline) <= 0 ->
        {:ok, selection |> Batch.expire() |> Batch.finish()}

      true ->
        read_pages(session, Batch.next_cursor(selection), selection, {false, deadline})
    end
  end

  # A retained session reads only its archive. A running one reads its
  # Recorder, whose receipts are shifted by the session's `offset` and
  # whose counters carry those of its earlier segments; a cursor before the
  # last amendment reads the archive first, then the Recorder within what
  # is left of the same entry and byte budget (`Archive.live_budget/3`).
  # With nothing left, the Recorder is asked for one entry and one byte, for
  # its newest receipt and counters only. Archive entries count their
  # external term size and Recorder entries their stored bytes. Each call is
  # one page: at most `@page_bytes`, or one entry when the first is larger,
  # plus at most the first Recorder entry after a part of the archive.
  defp read_entries(%{handle: nil} = retained, cursor, entries, _timeout_ms, _finalize) do
    Archive.read_retained(
      retained.archive,
      cursor,
      entries,
      @page_bytes,
      retained.carried.counters
    )
  end

  defp read_entries(%{offset: offset} = session, cursor, entries, timeout_ms, finalize)
       when is_integer(cursor) and cursor < offset do
    with {:ok, part} <- Archive.read(session.archive, cursor, entries, @page_bytes),
         {budget, bytes} = Archive.live_budget(part, entries, @page_bytes),
         {:ok, live} <-
           live_read(session, offset, {max(budget, 1), max(bytes, 1)}, timeout_ms, finalize) do
      {:ok, Archive.join(part, live, budget)}
    end
  end

  defp read_entries(session, cursor, entries, timeout_ms, finalize),
    do: live_read(session, cursor, {entries, @page_bytes}, timeout_ms, finalize)

  defp live_read(session, cursor, {entries, bytes}, timeout_ms, finalize) do
    segment_cursor = if cursor == :latest, do: :latest, else: cursor - session.offset

    with {:ok, read} <-
           Session.read_events(session.handle, segment_cursor,
             limit: entries,
             max_bytes: bytes,
             timeout_ms: timeout_ms,
             finalize_summaries: finalize
           ) do
      {:ok, read |> Archive.shift(session.offset) |> Archive.carry(session.carried.counters)}
    end
  end

  # Adds the `"filtered"` counts to a built batch: record-time since the
  # reader's filter baseline, read-time for the events its view hid
  # (`hidden`, including those of reads it was not sent). Summary samples
  # that could not be stored are a loss, so they are a gap, not a filtered
  # count. Returns the gate counts to keep as the next baseline.
  defp filtered(source, batch, filter_baseline, hidden) do
    counts = filter_counts(source)
    report = Filters.report(counts, filter_baseline, hidden)

    gaps =
      batch["gaps"] ++
        Filters.loss_gaps(counts, filter_baseline) ++ Archive.unread_gaps(source.archive, batch)

    {Map.merge(batch, %{"filtered" => report, "gaps" => gaps}), counts}
  end

  # The record-time filter counts since the session started: the running
  # gate's plus those its earlier segments' gates ended with.
  defp filter_counts(%{gate: nil, carried: carried}), do: carried.filtered

  defp filter_counts(%{gate: gate, carried: carried}),
    do: Archive.sum(Gate.counts(gate), carried.filtered)

  # The admission check already guarantees more than the read reserve.
  defp read_timeout(deadline),
    do: min(@read_timeout_ms, remaining(deadline) - @read_reply_reserve_ms)

  # `invalid_cursor` names the receipts a cursor may read when the session's
  # health still fits in the request's budget; otherwise they are `nil`.
  defp invalid_cursor(state, {:retained, terminal}, _deadline) do
    archive = terminal.retained.archive
    fill = %{"oldest_receipt" => Archive.oldest(archive), "next_receipt" => archive.top}
    {{:error, cursor_error(fill)}, state}
  end

  defp invalid_cursor(state, {:running, session}, deadline) do
    fill =
      if remaining(deadline) > @cursor_error_reserve_ms do
        case Session.health(session.handle) do
          {:ok, health} -> fill(session, health)
          _unavailable -> nil
        end
      end

    {{:error, cursor_error(fill)}, state}
  end

  # The Recorder's fill in live-session receipts: the oldest receipt a read
  # can return (the archive's, after an amendment) and the newest one, and
  # how many events the archive holds.
  defp fill(session, %{"recorder" => %{} = fill}) do
    live_oldest = fill["oldest_receipt"] && fill["oldest_receipt"] + session.offset
    archived = session.archive && Archive.oldest(session.archive)

    Map.merge(fill, %{
      "oldest_receipt" => archived || live_oldest,
      "next_receipt" => fill["next_receipt"] + session.offset,
      "archived_events" => if(session.archive, do: session.archive.count, else: 0)
    })
  end

  defp fill(_session, _health), do: nil

  defp cursor_error(fill) do
    Error.new("invalid_cursor", %{
      "oldest_receipt" => fill && fill["oldest_receipt"],
      "next_receipt" => fill && fill["next_receipt"]
    })
  end

  # `nil` (no cursor given) keeps a subscriber's cursor, or starts a new one
  # at 0. Any other cursor is checked against the newest receipt.
  defp start_cursor(nil, _fill), do: {:ok, nil}

  defp start_cursor(cursor, fill) do
    case Options.cursor(cursor) do
      {:ok, 0} ->
        {:ok, 0}

      {:ok, _cursor} when fill == nil ->
        {:error, Error.new("unavailable")}

      {:ok, :latest} ->
        {:ok, fill["next_receipt"]}

      {:ok, cursor} ->
        if cursor <= fill["next_receipt"], do: {:ok, cursor}, else: {:error, cursor_error(fill)}

      :error ->
        {:error, cursor_error(fill)}
    end
  end

  defp start_session(options, state) do
    environment = Environment.resolve()
    id = "live-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)

    # Masking patterns and Ecto `redact: true` fields are prepared here, in
    # the owner, never in an emitter.
    with {:ok, parsed} <- Options.start(options),
         :ok <- Credentials.warm(),
         {:ok, handle, gate} <- start_segment(state, id, parsed, environment) do
      state = %{state | session: new_session(id, handle, gate, options, parsed)}
      state = state |> schedule_lease(parsed.lease_ms) |> schedule_push()
      {{:ok, started(state.session, environment)}, state}
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  # Starts one collector session (a segment of the live session) under its
  # own record-time gate; a start that fails leaves neither behind.
  defp start_segment(state, collector_id, parsed, environment) do
    _schemas = RedactFields.refresh(@redact_fields_timeout_ms)

    with {:ok, gate} <- create_gate(parsed.filters.spec) do
      options = session_options(collector_id, parsed, environment, state, gate)

      case Session.start(state.host_policy, options) do
        {:ok, handle} ->
          {:ok, handle, gate}

        {:error, reason} ->
          release_gate(gate)
          {:error, start_error(reason)}
      end
    end
  end

  # The keeper owns the gate, so it is reclaimed even if this owner dies. A
  # creation that outlives its timeout is aborted in the keeper, so a start
  # that failed never leaves a gate behind.
  defp create_gate(spec) do
    # This owner holds no gate between sessions, so creation is exclusive.
    case Gates.create(spec, @gate_timeout_ms, exclusive: true) do
      {:ok, gate} -> {:ok, gate}
      {:error, :busy} -> {:error, Error.new("busy")}
      {:error, :timeout} -> {:error, Error.new("timeout")}
      {:error, :unavailable} -> {:error, Error.new("unavailable")}
      {:error, :invalid} -> {:error, Error.new("start_failed", %{"receipt" => nil})}
    end
  end

  # After a keeper restart this owner holds the gate's summary table (it is
  # the table's heir), so it deletes the table once the keeper has erased
  # the gate.
  defp release_gate(nil), do: :ok

  defp release_gate(gate) do
    table = Gate.table(gate)
    Gates.release(gate)
    Gate.delete_table(table)
  end

  defp session_options(id, parsed, environment, state, gate) do
    [
      id: id,
      environment: environment.environment,
      authority: "insider-live",
      boot_id: state.boot_id,
      clock_id: "insider-live-monotonic-us",
      recorder_options: [
        classification: {:internal, state.redaction_policy},
        max_events: parsed.max_events,
        max_bytes: @recorder_max_bytes
      ],
      components: parsed.components
    ]
    # The disclosure profile decides what the collectors record: rich
    # captures Logger text and metadata and Telemetry metadata; strict
    # collects no Logger message content at all. The record-time gate
    # (`Insider.Live.Filters`) decides in each emitting process before the
    # handler does any other work.
    |> put_if(
      :logger in parsed.components,
      :logger_options,
      logger_options(parsed.disclosure) ++ [gate: gate]
    )
    |> put_if(:telemetry in parsed.components, :telemetry_policy, parsed.telemetry_policy)
    |> put_if(
      :telemetry in parsed.components,
      :telemetry_options,
      telemetry_options(parsed.disclosure, gate)
    )
    |> put_if(
      :poller in parsed.components,
      :poller_options,
      parsed.poller && PollerOptions.collector_options(parsed.poller)
    )
    # Spans carry their attributes and status message only in the rich
    # profile; the gate applies the origin and minimum-duration filters.
    |> put_if(:otel in parsed.components, :otel_options,
      gate: gate,
      rich: parsed.disclosure == :rich
    )
    # Arguments, results and reasons are rendered only in the rich profile.
    |> put_if(
      :calls in parsed.components,
      :calls_options,
      parsed.calls &&
        CallsOptions.collector_options(parsed.calls) ++ [rich: parsed.disclosure == :rich]
    )
  end

  defp logger_options(:rich), do: [rich: true]
  defp logger_options(:strict), do: [include_payload: false]

  # A drop record may name a withheld measurement only when the host allows
  # it to be selected; any other withheld measurement is only counted.
  defp telemetry_options(profile, gate) do
    named = Disclosure.measurement_allowlist() |> Map.values()
    [gate: gate, nameable_measurements: named] ++ if(profile == :rich, do: [rich: true], else: [])
  end

  defp put_if(options, true, key, value), do: options ++ [{key, value}]
  defp put_if(options, false, _key, _value), do: options

  # `options` are the start options as given, which an amendment merges
  # over; the configuration fields are the parsed ones (`put_config/2`).
  # `offset` is the live receipt before the running segment's first, and
  # `archive` holds the receipts of the segments before it.
  defp new_session(id, handle, gate, options, parsed) do
    put_config(
      %{
        id: id,
        handle: handle,
        gate: gate,
        options: options,
        lease_deadline: now() + parsed.lease_ms,
        lease_timer: nil,
        revoking: false,
        baselines: %{},
        subscribers: %{},
        readers: %{},
        trace_index: %{},
        retention: nil,
        mutations: nil,
        known_normal: nil,
        offset: 0,
        archive: nil,
        carried: %{counters: %{}, filtered: %{}},
        segment: 0,
        amendments: [],
        # Pairing marks (`Insider.Live.Marks`), kept across amendments and stops.
        marks: Marks.new()
      },
      parsed
    )
  end

  # Retention keeps its traces across an amendment; a new `retain_traces`
  # lets go of automatic traces past it, and a positive one starts the
  # sweep from the session's first receipt.
  defp put_config(session, parsed) do
    # With the telemetry component, the traces of mutation requests are
    # kept by default (`Insider.Live.Retention`), as their records are.
    telemetry? = :telemetry in parsed.components

    retention =
      (Map.get(session, :retention) || Retention.new(parsed.retain_traces))
      |> Retention.set_limit(parsed.retain_traces)
      |> Retention.keep_mutations(telemetry?)
      |> then(&if(parsed.retain_traces > 0 or telemetry?, do: Retention.start(&1, 0), else: &1))

    # Every mutation the telemetry component records keeps a compact record.
    mutations =
      if :telemetry in parsed.components,
        do: (Map.get(session, :mutations) || Mutations.new()) |> Mutations.start(0),
        else: Map.get(session, :mutations)

    Map.merge(session, %{
      retention: retention,
      mutations: mutations,
      filters: parsed.filters.config,
      components: Enum.map(parsed.components, &Atom.to_string/1),
      telemetry_events: parsed.telemetry_events,
      telemetry_measurements: parsed.telemetry_measurements,
      disclosure: parsed.disclosure,
      max_events: parsed.max_events,
      lease_ms: parsed.lease_ms,
      poller: parsed.poller,
      calls: parsed.calls
    })
  end

  # The environment can change between the admission gate and collector
  # startup, so the collector's own environment refusal is reported as such.
  defp start_error(:environment_denied),
    do: Error.new("environment_denied", Environment.describe(Environment.resolve()))

  defp start_error(:invalid_options), do: Error.new("invalid_options", %{"field" => "options"})

  # Another host holds the one global collector session; its id is not ours.
  defp start_error(:session_already_active),
    do: Error.new("session_already_active", %{"active_session_id" => nil})

  defp start_error(:mailbox_overloaded), do: Error.new("busy")
  defp start_error(:unavailable), do: Error.new("unavailable")

  defp start_error(%{"schema" => "insider.collector-session-receipt/v1"} = receipt),
    do: Error.new("start_failed", %{"receipt" => receipt})

  defp start_error(_reason), do: Error.new("start_failed", %{"receipt" => nil})

  defp session_error(state, reason)
       when reason in [:expired_or_unknown_session, :cleanup_in_progress] do
    {record, state} = ended(state)
    {{:error, Error.new("session_terminal", %{"status" => record})}, state}
  end

  defp session_error(state, reason), do: {{:error, read_error(reason)}, state}

  defp read_error(:mailbox_overloaded), do: Error.new("busy")
  defp read_error(:request_expired), do: Error.new("timeout")
  defp read_error(_reason), do: Error.new("unavailable")

  defp ingested(id, {:ok, counts}),
    do: {:ok, Map.merge(counts, %{"schema" => "insider.live-ingest/v1", "session_id" => id})}

  # The session is active, so a collector that is not running means the
  # session was started without the otel component.
  defp ingested(_id, {:error, :not_running}),
    do:
      {:error,
       Error.new("component_unavailable", %{
         "component" => "otel",
         "reason" => "component_not_running"
       })}

  defp ingested(_id, {:error, :invalid_options}),
    do: {:error, Error.new("invalid_options", %{"field" => "spans"})}

  defp ingested(_id, {:error, :timeout}), do: {:error, Error.new("timeout")}

  # The services and routes of each trace's recorded spans, for views
  # scoped to services or routes (`Insider.Live.View.resolve/3`): the otel
  # collector's index of the running segment (`Insider.Collector.Otel.trace_index/1`,
  # spans it recorded from the SDK and from ingest, credential-masked)
  # merged with the index earlier segments ended with, which a stop or an
  # amendment carries (`carry_trace_index/1`). An index that cannot be read
  # in time counts as empty: a scoped read then keeps only what it matches
  # directly.
  defp trace_index(%{handle: handle} = records) when handle != nil,
    do: merge_index(Map.get(records, :trace_index) || %{}, live_index())

  defp trace_index(records), do: Map.get(records, :trace_index) || %{}

  defp live_index do
    with pid when is_pid(pid) <- Process.whereis(Otel),
         {:ok, %{} = index} <- Otel.trace_index(pid) do
      index
    else
      _unavailable -> %{}
    end
  end

  # Before a segment's collectors stop, its index joins the carried one.
  defp carry_trace_index(session),
    do: %{session | trace_index: merge_index(session.trace_index || %{}, live_index())}

  # The newer index wins on a trace both hold; beyond `@trace_index_max`
  # traces, carried ones the newer index does not hold are dropped first.
  defp merge_index(carried, newer) do
    merged = Map.merge(carried, newer, fn _trace, old, new -> union(old, new) end)
    excess = map_size(merged) - @trace_index_max

    if excess > 0 do
      dropped =
        carried |> Map.keys() |> Enum.reject(&Map.has_key?(newer, &1)) |> Enum.take(excess)

      Map.drop(merged, dropped)
    else
      merged
    end
  end

  defp union(old, new) do
    %{
      services: old.services |> MapSet.union(new.services) |> Enum.take(8) |> MapSet.new(),
      routes: old.routes |> MapSet.union(new.routes) |> Enum.take(8) |> MapSet.new()
    }
  end

  defp resolve(view, records),
    do:
      View.resolve(view, trace_index(records), Disclosure.effective(records.disclosure) == :rich)

  defp active(%{session: %{id: id} = session}, id), do: {:ok, session}

  defp active(state, id) do
    case find_terminal(state, id) do
      {:ok, terminal} -> {:error, Error.new("session_terminal", %{"status" => terminal.record})}
      :error -> {:error, Error.new("unknown_session")}
    end
  end

  # The session a read may use: the running one, or a stopped one still in
  # its retention window.
  defp readable(%{session: %{id: id} = session}, id), do: {:ok, {:running, session}}

  defp readable(state, id) do
    case find_terminal(state, id) do
      {:ok, %{retained: %{}} = terminal} -> {:ok, {:retained, terminal}}
      {:ok, terminal} -> {:error, Error.new("session_terminal", %{"status" => terminal.record})}
      :error -> {:error, Error.new("unknown_session")}
    end
  end

  defp valid_subscriber(pid) when is_pid(pid), do: :ok
  defp valid_subscriber(_pid), do: {:error, Error.new("invalid_subscriber")}

  # A subscriber reads from `cursor`; its next batch starts at `sent_cursor`,
  # where the last batch it was sent ended, so a read it was not sent (its
  # view hid every event) never opens a hole between batches. `remaining` is
  # its event budget, `nil` when unlimited.
  defp add_subscriber(session, pid, subscription) do
    cond do
      Map.has_key?(session.subscribers, pid) ->
        subscribers =
          Map.update!(session.subscribers, pid, &resubscribe(&1, session, subscription))

        {:ok, %{session | subscribers: subscribers}}

      map_size(session.subscribers) >= @max_subscribers ->
        {:error, Error.new("subscriber_limit")}

      true ->
        subscriber =
          %{
            monitor: Process.monitor(pid),
            view: subscription.view,
            reader: subscription.reader,
            remaining: subscription.max_events,
            hidden: %{},
            # A new subscriber may receive a counts-only batch on its first tick.
            reported_at: now() - @filtered_report_ms
          }
          |> Map.merge(positioned(session, subscription.cursor || 0))

        {:ok, %{session | subscribers: Map.put(session.subscribers, pid, subscriber)}}
    end
  end

  defp resubscribe(subscriber, _session, %{cursor: nil} = subscription) do
    %{
      subscriber
      | view: subscription.view,
        reader: subscription.reader,
        remaining: subscription.max_events
    }
  end

  defp resubscribe(subscriber, session, subscription) do
    subscriber
    |> Map.merge(positioned(session, subscription.cursor))
    |> Map.merge(%{
      view: subscription.view,
      reader: subscription.reader,
      remaining: subscription.max_events,
      hidden: %{}
    })
  end

  # Losses and filtered counts are reported against the baselines issued
  # with `cursor`, as for `events_since/3`; since session start otherwise.
  defp positioned(session, cursor) do
    baseline = baseline(session.baselines, cursor)

    %{
      cursor: cursor,
      sent_cursor: cursor,
      baseline: baseline,
      filter_baseline: baseline && Map.get(baseline, "filtered")
    }
  end

  defp drop_subscriber(session, pid) do
    case Map.pop(session.subscribers, pid) do
      {nil, _subscribers} ->
        session

      {subscriber, subscribers} ->
        Process.demonitor(subscriber.monitor, [:flush])
        %{session | subscribers: subscribers}
    end
  end

  # Cursor 0 always means "since session start", so it neither stores nor
  # consumes an issued-cursor baseline. Otherwise the first issuance of a
  # cursor wins: a later reader of the same cursor may see a loss reported
  # twice, but never misses one.
  defp baseline(_baselines, 0), do: nil
  defp baseline(baselines, cursor), do: Map.get(baselines, cursor)

  defp put_baseline(baselines, %{"next_cursor" => 0}, _counters), do: baselines

  defp put_baseline(baselines, read, counters) do
    baselines = Map.put_new(baselines, read["next_cursor"], counters)

    if map_size(baselines) > @max_baselines,
      do: Map.delete(baselines, baselines |> Map.keys() |> Enum.min()),
      else: baselines
  end

  # A session can end underneath its owner: a collector crash, a direct stop,
  # or a session root reset. Health is the cheapest exact way to notice
  # before renewing or subscribing.
  defp refresh(%{session: nil} = state), do: {state, nil}

  defp refresh(%{session: session} = state) do
    case Session.health(session.handle) do
      {:ok, %{"terminal" => true}} ->
        {_record, state} = ended(state)
        {state, nil}

      {:ok, health} ->
        {state, health}

      {:error, reason} when reason in [:expired_or_unknown_session, :cleanup_in_progress] ->
        {_record, state} = ended(state)
        {state, nil}

      {:error, _reason} ->
        {state, nil}
    end
  end

  defp end_or_retry(state, terminal_state, reason) do
    case finish(state, terminal_state, reason) do
      {:ok, _record, state} ->
        {:noreply, state}

      {:error, _error, state} when terminal_state == "revoked" ->
        {:noreply, revocation_pending(state)}

      {:error, _error, state} ->
        {:noreply, schedule_lease(state, @stop_retry_ms)}
    end
  end

  # A stop the Manager refused or could not run leaves the collector session
  # in place, so the owner keeps it rather than orphaning it. Before the
  # collectors stop, a stop copies the session into an archive that stays
  # readable for its retention window; that copy, or one an expiring
  # session makes for its subscribers, gives each subscriber its last batch.
  # A revoked session reads nothing more for its subscribers.
  defp finish(%{session: session} = state, terminal_state, reason, deadline \\ nil) do
    archived = archive_for(session, terminal_state, deadline)

    final_reads =
      Enum.map(session.subscribers, fn {pid, subscriber} ->
        {pid, subscriber, final_read(archived, subscriber)}
      end)

    case Session.stop(session.handle) do
      {:error, failure} when failure not in @ended_reasons ->
        {:error, read_error(failure), state}

      result ->
        notify_terminal(session, final_reads, terminal_state, elem(receipt_of(result), 0))
        readable = if terminal_state == "stopped", do: retained_of(archived)
        {record, state} = retain(state, session, terminal_state, reason, result, readable)
        {:ok, record, state}
    end
  end

  defp archive_for(_session, "revoked", _deadline), do: :withheld

  defp archive_for(session, terminal_state, deadline)
       when terminal_state == "stopped" or map_size(session.subscribers) > 0 do
    session = carry_trace_index(session)

    case capture(session, capture_budget(deadline, :stop)) do
      {:ok, archive, counters, _sealed_at} -> {:ok, retained(session, archive, counters)}
      {:error, _reason} -> :unavailable
    end
  end

  defp archive_for(_session, _terminal_state, _deadline), do: :unavailable

  defp retained_of({:ok, retained}), do: retained
  defp retained_of(_archived), do: nil

  # A stopped session's read source: its archive with the counters and
  # filter counts it ended with, its baselines, and its readers.
  defp retained(session, archive, counters) do
    %{
      id: session.id,
      handle: nil,
      gate: nil,
      archive: archive,
      carried: %{counters: counters, filtered: filter_counts(session)},
      disclosure: session.disclosure,
      baselines: session.baselines,
      readers: session.readers,
      trace_index: Map.get(session, :trace_index),
      retention: Map.get(session, :retention),
      mutations: Map.get(session, :mutations),
      marks: Map.get(session, :marks),
      known_normal: Map.get(session, :known_normal),
      subscribers: %{}
    }
  end

  defp ended(%{session: session} = state) do
    result = Session.stop(session.handle)

    final_reads =
      Enum.map(session.subscribers, fn {pid, subscriber} ->
        {pid, subscriber, {:missing, "final_read_unavailable"}}
      end)

    notify_terminal(session, final_reads, "terminated", elem(receipt_of(result), 0))
    retain(state, session, "terminated", "session_ended", result, nil)
  end

  defp final_read(:withheld, _subscriber), do: {:missing, "final_read_withheld"}
  defp final_read(:unavailable, _subscriber), do: {:missing, "final_read_unavailable"}

  # The copy first recorded the pending summary intervals, so a session
  # ending mid-interval still delivers them.
  defp final_read({:ok, retained}, subscriber) do
    case scan(
           retained,
           subscriber.cursor,
           resolve(subscriber.view, retained),
           push_limits(subscriber),
           @push_read_timeout_ms
         ) do
      {:ok, selected} ->
        {batch, _counters, _counts, _hidden} =
          subscriber_batch(retained, subscriber, selected, %{})

        {:ok, batch}

      {:error, _reason} ->
        {:missing, "final_read_unavailable"}
    end
  end

  defp notify_terminal(session, final_reads, terminal_state, receipt) do
    extra =
      session
      |> lease()
      |> Map.merge(%{"state" => terminal_state, "receipt" => receipt, "lease_remaining_ms" => 0})

    Enum.each(final_reads, fn {pid, subscriber, final} ->
      batch =
        case final do
          {:ok, batch} ->
            Map.merge(batch, extra)

          {:missing, reason} ->
            session.id
            |> Batch.without_read(subscriber.sent_cursor, subscriber.cursor, reason, extra)
            |> Map.put("filtered", nil)
        end

      _ = deliver(pid, {:insider_live_events, session.id, batch})
      Process.demonitor(subscriber.monitor, [:flush])
    end)
  end

  defp receipt_of({:ok, receipt}), do: {receipt, false}
  defp receipt_of({:error, :expired_or_unknown_session}), do: {nil, false}
  defp receipt_of({:error, _reason}), do: {nil, true}

  # `stopped` is the collector's stop result; `readable`, the retained read
  # source of a session that stays readable for `@stopped_readable_ms`.
  defp retain(state, session, terminal_state, reason, stopped, readable) do
    cancel_timer(session.lease_timer)
    cancel_timer(state.push_timer)
    # Collection has stopped, so no handler needs the gate any more.
    release_gate(session.gate)
    {receipt, pending} = receipt_of(stopped)
    ended_at = DateTime.utc_now()

    record =
      session
      |> configuration()
      |> Map.merge(%{
        "schema" => "insider.live-status/v1",
        "session_id" => session.id,
        "state" => terminal_state,
        "reason" => reason,
        "lease_remaining_ms" => 0,
        "subscribers" => 0,
        "health" => nil,
        "next_receipt" => nil,
        "recorder" => nil,
        "insider_memory" => nil,
        "receipt" => receipt,
        "receipt_pending" => pending,
        "ended_at" => iso8601(ended_at),
        "readable_until" =>
          readable && ended_at |> DateTime.add(@stopped_readable_ms, :millisecond) |> iso8601()
      })

    terminal = %{
      id: session.id,
      record: record,
      handle: session.handle,
      retained: readable,
      readable_until: readable && now() + @stopped_readable_ms,
      timer:
        readable &&
          Process.send_after(self(), {:retention_expired, session.id}, @stopped_readable_ms)
    }

    terminals = [terminal | state.terminals] |> Enum.take(@retained_terminals) |> bound_readable()
    {record, %{state | session: nil, terminals: terminals, push_timer: nil}}
  end

  # Only the newest `@retained_readable` stopped sessions keep an archive.
  defp bound_readable(terminals) do
    {terminals, _kept} =
      Enum.map_reduce(terminals, 0, fn
        %{retained: nil} = terminal, kept ->
          {terminal, kept}

        terminal, kept when kept < @retained_readable ->
          {terminal, kept + 1}

        terminal, kept ->
          cancel_timer(terminal.timer)
          {%{terminal | retained: nil, readable_until: nil, timer: nil}, kept}
      end)

    terminals
  end

  defp iso8601(time), do: time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  # `status` of an ended session adds what changes while it is readable:
  # how long it stays readable, its newest receipt, and its readers.
  defp terminal_reply(state, id, kind) do
    case find_terminal(state, id) do
      {:ok, terminal} ->
        terminal = complete_receipt(terminal)
        state = put_terminal(state, terminal)

        if kind == :status,
          do: {{:ok, terminal_status(terminal)}, state},
          else: {{:ok, terminal.record}, state}

      :error ->
        {{:error, Error.new("unknown_session")}, state}
    end
  end

  defp terminal_status(%{retained: nil} = terminal),
    do: Map.merge(terminal.record, %{"readable_remaining_ms" => 0, "readers" => []})

  defp terminal_status(%{retained: retained} = terminal) do
    top = retained.archive.top

    Map.merge(terminal.record, %{
      "readable_remaining_ms" => readable_remaining(terminal),
      "next_receipt" => top,
      "readers" => readers(retained, top)
    })
  end

  defp readable_remaining(%{readable_until: nil}), do: 0
  defp readable_remaining(%{readable_until: until}), do: max(until - now(), 0)

  defp put_terminal(state, terminal),
    do: %{
      state
      | terminals: Enum.map(state.terminals, &if(&1.id == terminal.id, do: terminal, else: &1))
    }

  # A stop whose cleanup was still in progress is completed from the
  # Manager's retained receipt when its status is next requested.
  defp complete_receipt(%{record: %{"receipt_pending" => true} = record} = terminal) do
    {receipt, pending} = receipt_of(Session.stop(terminal.handle))
    %{terminal | record: %{record | "receipt" => receipt, "receipt_pending" => pending}}
  end

  defp complete_receipt(terminal), do: terminal

  defp find_terminal(state, id) do
    case Enum.find(state.terminals, &(&1.id == id)) do
      nil -> :error
      terminal -> {:ok, terminal}
    end
  end

  defp push(%{session: nil} = state), do: state

  # A subscriber whose event budget is spent is sent nothing more until the
  # terminal batch.
  defp push(%{session: session} = state) do
    Enum.reduce_while(session.subscribers, state, fn {pid, subscriber}, state ->
      if subscriber.remaining == 0 or overloaded?(pid) do
        {:cont, state}
      else
        # A view scoped to services or routes follows the traces ingested
        # since the subscription began.
        case scan(
               state.session,
               subscriber.cursor,
               resolve(subscriber.view, state.session),
               push_limits(subscriber),
               @push_read_timeout_ms
             ) do
          {:ok, selected} ->
            {:cont, deliver_batch(state, pid, subscriber, selected)}

          {:error, reason} when reason in [:expired_or_unknown_session, :cleanup_in_progress] ->
            {_record, state} = ended(state)
            {:halt, state}

          {:error, _reason} ->
            {:cont, state}
        end
      end
    end)
  end

  # A batch is sent when it has events or gaps, or, at most every
  # `@filtered_report_ms`, when only filtered counts changed. A read that is
  # not sent still advances the subscriber's read cursor; its record-time
  # filter baseline and view counts carry over to the next batch that is
  # sent, which starts where the last sent batch ended.
  defp deliver_batch(%{session: session} = state, pid, subscriber, selected) do
    {batch, counters, counts, hidden} =
      subscriber_batch(session, subscriber, selected, lease(session))

    advanced = %{subscriber | cursor: batch["next_cursor"], baseline: counters, hidden: hidden}

    sent = %{
      advanced
      | sent_cursor: batch["next_cursor"],
        filter_baseline: counts,
        hidden: %{},
        reported_at: now(),
        remaining: spend(subscriber.remaining, batch["events"])
    }

    report? =
      batch["events"] != [] or batch["gaps"] != [] or
        (Filters.any?(batch["filtered"]) and now() - subscriber.reported_at >= @filtered_report_ms)

    {subscriber, session} =
      cond do
        not report? ->
          {advanced, session}

        deliver(pid, {:insider_live_events, session.id, batch}) == :ok ->
          {sent, seen(session, subscriber.reader, batch["next_cursor"])}

        true ->
          {subscriber, session}
      end

    %{state | session: %{session | subscribers: Map.put(session.subscribers, pid, subscriber)}}
  end

  # The batch of a subscriber's read: it starts at `sent_cursor`, because
  # the reads it was not sent since its last batch hid every event, and it
  # counts what they hid with what this read hid.
  defp subscriber_batch(session, subscriber, {read, hidden}, extra) do
    hidden = View.add(subscriber.hidden, hidden)
    {batch, counters} = Batch.build(session.id, read, subscriber.baseline, extra)
    {batch, counts} = filtered(session, batch, subscriber.filter_baseline, hidden)
    batch = Map.put(batch, "cursor", subscriber.sent_cursor)

    # A named subscriber's batches, its last included, say whose they are
    # and the view they were read through, as a named read's do.
    batch =
      if subscriber.reader,
        do:
          Map.merge(batch, %{
            "reader" => subscriber.reader,
            "view" => subscriber.view && subscriber.view.spec
          }),
        else: batch

    {batch, counters, counts, hidden}
  end

  # A push returns no more events than the subscriber's remaining budget.
  defp push_limits(subscriber) do
    %{
      limit: min(@push_limit, subscriber.remaining || @push_limit),
      max_bytes: @push_max_bytes,
      scan_limit: @push_scan_limit
    }
  end

  defp spend(nil, _events), do: nil
  defp spend(remaining, events), do: remaining - length(events)

  # A remote subscriber cannot be inspected; `:nosuspend` keeps a busy
  # distribution buffer from blocking the owner and its cursor stays put.
  defp overloaded?(pid) when node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length > @subscriber_mailbox_limit
      nil -> true
    end
  end

  defp overloaded?(_pid), do: false

  defp deliver(pid, message), do: :erlang.send(pid, message, [:noconnect, :nosuspend])

  defp schedule_push(%{push_timer: nil, session: %{retention: retention} = session} = state)
       when session.subscribers == %{} do
    if Retention.active?(retention) or Mutations.active?(session.mutations),
      do: %{state | push_timer: Process.send_after(self(), :push, @push_interval_ms)},
      else: state
  end

  defp schedule_push(%{push_timer: nil, session: %{subscribers: subscribers}} = state)
       when map_size(subscribers) > 0,
       do: %{state | push_timer: Process.send_after(self(), :push, @push_interval_ms)}

  defp schedule_push(state), do: state

  defp schedule_lease(%{session: session} = state, milliseconds) do
    cancel_timer(session.lease_timer)
    timer = Process.send_after(self(), {:lease_check, session.id}, milliseconds)
    %{state | session: %{session | lease_timer: timer}}
  end

  defp renew_lease(session), do: %{session | lease_deadline: now() + session.lease_ms}

  defp lease_remaining(session), do: max(session.lease_deadline - now(), 0)

  # Every batch says which disclosure profile its events crossed, as
  # evaluated for this read.
  defp lease(session),
    do: %{
      "lease_remaining_ms" => lease_remaining(session),
      "disclosure_profile" => Atom.to_string(Disclosure.effective(session.disclosure))
    }

  defp lease_status(session) do
    %{
      "schema" => "insider.live-lease/v1",
      "session_id" => session.id,
      "state" => "running",
      "lease_ms" => session.lease_ms,
      "lease_remaining_ms" => lease_remaining(session),
      "lease_expires_at" => expires_at(session)
    }
  end

  defp started(session, environment) do
    session
    |> lease_status()
    |> Map.merge(configuration(session))
    |> Map.merge(%{
      "schema" => "insider.live-session/v1",
      "cursor" => 0,
      "environment" => Atom.to_string(environment.environment)
    })
  end

  # The Recorder's fill comes from the same health call: `next_receipt` is
  # the newest receipt (a reader at that cursor is caught up) and
  # `recorder` how much is retained against its bounds, per source too.
  # `readers` are the named readers and `amendments` the latest amendments,
  # newest first.
  defp running_status(session, health) do
    fill = fill(session, health)
    next_receipt = fill && fill["next_receipt"]

    session
    |> lease_status()
    |> Map.merge(configuration(session))
    |> Map.merge(%{
      "schema" => "insider.live-status/v1",
      "reason" => nil,
      "subscribers" => map_size(session.subscribers),
      "health" => health && Map.drop(health, ["recorder", "memory"]),
      "next_receipt" => next_receipt,
      "recorder" => fill && Map.drop(fill, ["next_receipt", "memory_bytes"]),
      "insider_memory" => health && insider_memory(health),
      "receipt" => nil,
      "receipt_pending" => false,
      "telemetry_subscriptions" => telemetry_subscriptions(session),
      "readers" => readers(session, next_receipt),
      "amendments" => session.amendments,
      "retention" => Retention.describe(session.retention),
      "mutations" => Mutations.describe(session.mutations),
      "readable_until" => nil
    })
  end

  # Recording filters apply to every reader of the session; a view only to
  # the read or watch that passes it. Every configuration says so.
  @scope %{
    "filters" =>
      "record time: components, events, measurements and filters decide what this session records, for every reader; amend changes them for everyone",
    "view" => "read time: a view narrows only the events or watch call that passes it"
  }

  # Each subscribed Telemetry event, with whether this session's handler is
  # attached to it and how many times it was emitted since the start or the
  # last amendment (each segment has its own gate),
  # recorded or filtered. `"subscribed"` with `"seen"` 0 means the event
  # was not emitted; `"seen"` is `nil` when the gate is gone.
  defp telemetry_subscriptions(session) do
    seen = Gate.seen(session.gate)

    for segments <- session.telemetry_events do
      kind = Enum.join(segments, ".")
      state = if attached?(segments, session.gate), do: "subscribed", else: "detached"
      %{"event" => kind, "state" => state, "seen" => Map.get(seen, kind)}
    end
  end

  defp attached?(segments, gate) do
    name = Enum.map(segments, &String.to_existing_atom/1)
    handler = &TelemetryHandler.handle_event/4

    Enum.any?(:telemetry.list_handlers(name), fn row ->
      row.event_name == name and row.function == handler and is_map(row.config) and
        Map.get(row.config, :gate) == gate
    end)
  rescue
    _error -> false
  end

  # Insider's own memory while it serves this session, in bytes: this owner,
  # the session Manager, the Session and its collector processes as
  # `Process.info/2` reports `:memory`, and the Recorder's tables with the
  # event binaries they hold (`nil` while the Recorder cannot be read).
  defp insider_memory(health) do
    processes =
      [{"live_owner", self()}, {"session_manager", Process.whereis(Manager)}]
      |> Enum.reduce(health["memory"], fn {name, pid}, processes ->
        case pid && Process.info(pid, :memory) do
          {:memory, bytes} -> Map.put(processes, name, bytes)
          _gone -> processes
        end
      end)

    processes_bytes = processes |> Map.values() |> Enum.sum()
    recorder_bytes = health["recorder"] && health["recorder"]["memory_bytes"]

    %{
      "processes" => processes,
      "processes_bytes" => processes_bytes,
      "recorder_bytes" => recorder_bytes,
      "total_bytes" => processes_bytes + (recorder_bytes || 0)
    }
  end

  defp configuration(session) do
    %{
      "components" => session.components,
      "disclosure_profile" => Atom.to_string(Disclosure.effective(session.disclosure)),
      "masking_policy_id" => Credentials.policy_id(),
      "telemetry_events" => session.telemetry_events,
      "telemetry_measurements" => session.telemetry_measurements,
      "max_events" => session.max_events,
      "retain_traces" => session.retention.limit,
      "lease_ms" => session.lease_ms,
      "filters" => session.filters,
      "poller" => PollerOptions.echo(session.poller),
      "calls" => CallsOptions.echo(session.calls),
      "scope" => @scope
    }
  end

  # Readers name themselves on reads, subscriptions, stops, and amendments.
  # A named read or delivered batch records the reader's cursor and when it
  # was seen (a trace or timeline scan, which reads the session newest
  # first, keeps the cursor: `:keep`), and a read that gave a view makes it
  # the reader's own view (`nil` clears it). Beyond `@readers_max` the
  # least recently seen unsubscribed reader is forgotten. A subscribed
  # reader is never forgotten, so it holds a stop until it unsubscribes: at
  # most `@readers_max` plus the subscriber bound are kept.
  defp seen(source, name, cursor, view \\ :keep)
  defp seen(source, nil, _cursor, _view), do: source

  defp seen(%{readers: readers} = source, name, cursor, view) do
    previous = Map.get(readers, name, %{cursor: nil, view: nil})

    readers =
      Map.put(readers, name, %{
        cursor: if(cursor == :keep, do: previous.cursor, else: cursor),
        view: if(view == :keep, do: Map.get(previous, :view), else: view),
        seen_at: now(),
        seen_wall: iso8601(DateTime.utc_now())
      })

    subscribed = subscribed_names(source)

    evictable =
      Enum.reject(readers, fn {reader, _seen} -> reader == name or reader in subscribed end)

    readers =
      if map_size(readers) > @readers_max and evictable != [],
        do: Map.delete(readers, evictable |> Enum.min_by(&elem(&1, 1).seen_at) |> elem(0)),
        else: readers

    %{source | readers: readers}
  end

  # A read that changes its reader's stored view says so: the view now
  # applies to the reader's later reads. Otherwise a read's --view-kind
  # silently becomes the reader's view and hides events from its next
  # digest.
  defp put_view_note(batch, _source, _reader, :keep), do: batch

  defp put_view_note(batch, source, reader, given) do
    previous = get_in(source, [:readers, reader, :view])

    cond do
      given == previous ->
        batch

      is_nil(given) ->
        Map.put(batch, "view_note", "reader #{reader}'s view is cleared")

      true ->
        hidden = (get_in(batch, ["filtered", "view"]) || %{}) |> Map.values() |> Enum.sum()

        Map.put(
          batch,
          "view_note",
          "this view is now reader #{reader}'s view for its later reads (events, digest, trace, timeline) " <>
            "until --view-clear; it hid #{hidden} events here"
        )
    end
  end

  defp subscribed_names(source),
    do: for({_pid, %{reader: name}} <- source.subscribers, name, into: MapSet.new(), do: name)

  # Each named reader with its cursor, how far it is behind `next_receipt`
  # (`nil` when unknown), when it was last seen, whether it is subscribed,
  # and whether it counts as active for a stop.
  defp readers(source, next_receipt) do
    subscribed =
      for {_pid, %{reader: name}} <- source.subscribers, name, into: MapSet.new(), do: name

    now = now()

    source.readers
    |> Enum.sort()
    |> Enum.map(fn {name, reader} ->
      ago = now - reader.seen_at
      subscribed? = MapSet.member?(subscribed, name)

      %{
        "name" => name,
        "cursor" => reader.cursor,
        "behind" => next_receipt && reader.cursor && max(next_receipt - reader.cursor, 0),
        "last_seen_ms_ago" => ago,
        "last_seen_at" => reader.seen_wall,
        "subscribed" => subscribed?,
        "active" => subscribed? or ago <= @reader_active_ms,
        "view" => Map.get(reader, :view)
      }
    end)
  end

  # The readers a stop by `stopper` would cut off: other named readers that
  # are active. Only a named reader can be told apart from the stopper, so
  # only named readers hold a stop; unnamed subscribers are counted.
  defp peers(session, stopper) do
    session |> readers(nil) |> Enum.filter(&(&1["active"] and &1["name"] != stopper))
  end

  # `retry_after_ms` is when the last of them goes idle, unless one is
  # subscribed, which stays active until it unsubscribes.
  defp readers_active(session, named) do
    retry =
      if not Enum.any?(named, & &1["subscribed"]),
        do: named |> Enum.map(&(@reader_active_ms - &1["last_seen_ms_ago"])) |> Enum.max()

    unnamed =
      Enum.count(session.subscribers, fn {_pid, subscriber} -> is_nil(subscriber.reader) end)

    Error.new("readers_active", %{
      "readers" => Enum.map(named, &Map.drop(&1, ["active", "behind"])),
      "unnamed_subscribers" => unnamed,
      "reader_active_ms" => @reader_active_ms,
      "retry_after_ms" => retry,
      "stopped_readable_ms" => @stopped_readable_ms
    })
  end

  defp stop(state, deadline) do
    case finish(state, "stopped", "stop_requested", deadline) do
      {:ok, record, state} -> {{:ok, record}, state}
      {:error, error, state} -> {{:error, error}, state}
    end
  end

  # Copies the running segment, from its oldest retained receipt to its
  # newest, into the session's archive (the first read records the pending
  # summary intervals), then seals the segment's ingress, so nothing more
  # is recorded, and copies what arrived meanwhile: the copy ends where the
  # Recorder does. Returns the archive, the session's cumulative loss
  # counters (the final read carries the sealed components' final status),
  # and when ingress stopped (the seal; `nil` when it failed), or
  # `{:error, reason}` (`:request_expired` when the budget ran out) with
  # nothing changed. If the seal or the last copy fails, the archive's end
  # is marked unread, which reads report as a gap.
  defp capture(session, budget_ms) do
    deadline = now() + budget_ms
    archive = session.archive || Archive.new()

    with {:ok, archive, bulk} <- copy(session, session.offset, archive, true, deadline) do
      counters = Archive.counters(bulk)
      sealed_at = now()

      case Session.seal_ingress(session.handle, seal_timeout(deadline)) do
        {:ok, _sealed} ->
          case copy(session, archive.top, archive, false, deadline) do
            {:ok, archive, final} ->
              {:ok, archive, Archive.max_counters(counters, Archive.counters(final)), sealed_at}

            {:error, _reason} ->
              {:ok, Archive.unread(archive), counters, sealed_at}
          end

        {:error, _reason} ->
          {:ok, Archive.unread(archive), counters, nil}
      end
    end
  end

  defp copy(session, cursor, archive, finalize, deadline) do
    timeout_ms = min(@read_timeout_ms, remaining(deadline))

    with true <- timeout_ms > 0 || {:error, :request_expired},
         {:ok, read} <-
           live_read(session, cursor, {@capture_chunk, @page_bytes}, timeout_ms, finalize) do
      archive = Archive.append(archive, read)

      if read["next_cursor"] < read["next_receipt"],
        do: copy(session, read["next_cursor"], archive, false, deadline),
        else: {:ok, archive, read}
    end
  end

  defp seal_timeout(deadline), do: deadline |> remaining() |> min(@read_timeout_ms) |> max(1)

  defp capture_budget(nil, _operation), do: @capture_max_ms

  defp capture_budget(deadline, operation),
    do: min(@capture_max_ms, remaining(deadline) - Map.fetch!(@after_capture_ms, operation))

  # An amendment keeps the live session, its id, cursors, readers, and
  # subscribers. It copies the running segment into the archive, stops its
  # collectors, and starts a new segment with the merged options; the
  # receipts continue after an amendment marker, an event every reader
  # sees. Nothing changes when the copy fails. If the new segment cannot
  # start, the previous options start again (`amend_failed`, rolled back);
  # if that fails too, the session ends and stays readable like a stopped
  # one.
  defp amend(state, session, wanted, change, deadline) do
    session = carry_trace_index(session)

    case capture(session, capture_budget(deadline, :amend)) do
      {:ok, archive, counters, sealed_at} ->
        swap(state, session, {archive, counters}, wanted, Map.put(change, :sealed_at, sealed_at))

      {:error, reason} ->
        session_error(state, reason)
    end
  end

  # The pause in collection starts when ingress was sealed (or, if the seal
  # failed, when the collectors are stopped here).
  defp swap(state, session, {archive, counters}, {options, parsed}, change) do
    paused_at = change.sealed_at || now()
    change = Map.merge(change, %{paused_at: paused_at, handle: session.handle})

    case Session.stop(session.handle) do
      {:error, failure} when failure not in @ended_reasons ->
        {{:error, read_error(failure)}, state}

      stopped ->
        carried = %{counters: counters, filtered: filter_counts(session)}
        release_gate(session.gate)
        segment = session.segment + 1
        id = session.id <> "." <> Integer.to_string(segment)
        environment = Environment.resolve()
        change = Map.put(change, :stopped, stopped)

        base = %{
          session
          | handle: nil,
            gate: nil,
            archive: archive,
            carried: carried,
            segment: segment
        }

        case start_segment(state, id, parsed, environment) do
          {:ok, handle, gate} ->
            change = Map.put(change, :applied, true)
            {amendment, state} = amended(state, base, {handle, gate}, {options, parsed}, change)
            {{:ok, amendment_reply(state.session, amendment)}, state}

          {:error, _error} ->
            roll_back(state, base, {id, environment}, change)
        end
    end
  end

  defp roll_back(state, base, {id, environment}, change) do
    with {:ok, previous} <- Options.start(base.options),
         {:ok, handle, gate} <- start_segment(state, id, previous, environment) do
      change = Map.put(change, :applied, false)
      {amendment, state} = amended(state, base, {handle, gate}, {base.options, previous}, change)
      details = %{"rolled_back" => true, "amendment" => amendment}
      {{:error, Error.new("amend_failed", details)}, state}
    else
      {:error, _error} ->
        retained = retained(base, base.archive, base.carried.counters)

        final_reads =
          Enum.map(base.subscribers, fn {pid, subscriber} ->
            {pid, subscriber, final_read({:ok, retained}, subscriber)}
          end)

        notify_terminal(base, final_reads, "terminated", elem(receipt_of(change.stopped), 0))
        ended = %{base | handle: change.handle}

        {record, state} =
          retain(state, ended, "terminated", "amend_failed", change.stopped, retained)

        {{:error, Error.new("amend_failed", %{"rolled_back" => false, "status" => record})},
         state}
    end
  end

  # The new segment runs: the marker takes the next receipt, the segment's
  # receipts follow it, and the lease restarts with the (new) lease_ms.
  defp amended(state, base, {handle, gate}, {options, parsed}, change) do
    before = flat_config(base)

    session =
      base |> put_config(parsed) |> Map.merge(%{handle: handle, gate: gate, options: options})

    current = flat_config(session)

    changed =
      current
      |> Enum.filter(fn {key, value} -> before[key] != value end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    amendment = %{
      "number" => session.segment,
      "applied" => change.applied,
      "by" => change.reader,
      "requested" => change.requested,
      "changed" => changed,
      "uncollected_ms" => now() - change.paused_at,
      "at" => iso8601(DateTime.utc_now()),
      "receipt" => elem(receipt_of(change.stopped), 0)
    }

    values = {Map.take(before, changed), Map.take(current, changed)}
    archive = Archive.put(session.archive, &marker(state, session, amendment, values, &1))
    amendment = Map.put(amendment, "marker_receipt", archive.top)

    session =
      renew_lease(%{
        session
        | archive: archive,
          offset: archive.top,
          amendments: Enum.take([amendment | session.amendments], @amendments_listed)
      })

    {amendment,
     %{state | session: session} |> schedule_lease(session.lease_ms) |> schedule_push()}
  end

  defp amendment_reply(session, amendment) do
    session
    |> lease_status()
    |> Map.merge(configuration(session))
    |> Map.merge(%{"schema" => "insider.live-amendment/v1", "amendment" => amendment})
  end

  # Every configuration value by start option name, filters included.
  defp flat_config(session) do
    config = configuration(session)

    config
    |> Map.drop(["filters", "masking_policy_id", "scope"])
    |> Map.merge(config["filters"])
  end

  # The `live.session_amended` event: what changed, from what to what, who
  # asked, and how long nothing was collected. Views never hide it. When
  # the values do not fit an event, it names only the changed options.
  defp marker(state, session, amendment, {from, to}, receipt) do
    attributes =
      amendment
      |> Map.drop(["at", "receipt"])
      |> Map.merge(%{"from" => from, "to" => to})

    event =
      case Event.new(marker_event(state, session, attributes)) do
        {:ok, event} ->
          event

        {:error, _unfit} ->
          Event.new!(marker_event(state, session, Map.drop(attributes, ["from", "to"])))
      end

    %{
      "receipt" => receipt,
      "received_at_us" => System.monotonic_time(:microsecond),
      "priority" => "normal",
      "event" => Event.to_wire_map(event),
      "redactions" => []
    }
  end

  defp marker_event(state, session, attributes) do
    [
      id: "#{session.id}.amendment.#{session.segment}",
      node: Atom.to_string(node()),
      boot_id: state.boot_id,
      source: "live",
      kind: "live.session_amended",
      severity: :info,
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: "insider-live-monotonic-us",
      source_instance_id: session.id,
      source_sequence: session.segment,
      wall_time: DateTime.utc_now(),
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: attributes,
      payload: nil,
      authority: "insider-live",
      redactions: [],
      extensions: %{}
    ]
  end

  # An `inspect.KIND` event, source `inspect`, severity info. Its attributes
  # are the inspection's compact projection, already cut to the event
  # bound; `subject` is the inspected process's pid, if any.
  defp inspection_event(state, session, kind, attributes, subject) do
    sequence = System.unique_integer([:positive, :monotonic])

    Event.new(
      id: "#{session.id}.inspect.#{sequence}",
      node: Atom.to_string(node()),
      boot_id: state.boot_id,
      source: "inspect",
      kind: "inspect." <> kind,
      severity: :info,
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: "insider-live-monotonic-us",
      source_instance_id: session.id <> ".inspect",
      source_sequence: sequence,
      wall_time: DateTime.utc_now(),
      subject: subject && Subject.new!("process", subject, Atom.to_string(node())),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: attributes,
      payload: nil,
      authority: "insider-live",
      redactions: [],
      extensions: %{}
    )
  end

  defp mark(state, session, request, deadline) do
    timeout = fn ->
      deadline |> remaining() |> Kernel.-(200) |> min(@record_inspection_ms) |> max(1)
    end

    case read_entries(session, :latest, 1, timeout.(), false) do
      {:ok, %{"next_receipt" => cursor}} ->
        {mark, marks} = Marks.add(session.marks, request, cursor)

        recorded =
          state
          |> mark_event(session, mark)
          |> record_built(session.handle, timeout.())

        reply =
          session.id
          |> inspection_recorded(recorded)
          |> Map.merge(%{
            "schema" => "insider.live-mark/v1",
            "mark" => mark,
            "marks" => length(marks.marks)
          })

        {{:ok, reply}, %{state | session: %{renew_lease(session) | marks: marks}}}

      {:error, reason} ->
        session_error(state, reason)
    end
  end

  # A `live.mark` event, source `live`, severity info: views never hide it.
  defp mark_event(state, session, mark) do
    Event.new(
      id: "#{session.id}.mark.#{mark["index"]}",
      node: Atom.to_string(node()),
      boot_id: state.boot_id,
      source: "live",
      kind: "live.mark",
      severity: :info,
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: "insider-live-monotonic-us",
      source_instance_id: session.id <> ".mark",
      source_sequence: mark["index"],
      wall_time: DateTime.utc_now(),
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: Map.take(mark, ["index", "label", "reader", "cursor"]),
      payload: nil,
      authority: "insider-live",
      redactions: [],
      extensions: %{}
    )
  end

  defp record_built({:ok, event}, handle, timeout),
    do: Session.record_event(handle, event, timeout)

  defp record_built({:error, _invalid}, _handle, _timeout), do: {:error, :invalid_event}

  defp inspection_recorded(id, :ok),
    do: %{"session_id" => id, "recorded" => true, "reason" => nil}

  # The session call timed out: the write may or may not have happened.
  defp inspection_recorded(id, {:error, :outcome_unknown}),
    do: %{"session_id" => id, "recorded" => nil, "reason" => "outcome_unknown"}

  defp inspection_recorded(id, {_dropped_or_error, reason}),
    do: %{"session_id" => id, "recorded" => false, "reason" => reason_text(reason)}

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_reason), do: "unavailable"

  # `cursor` is where the subscriber's next batch starts and `max_events`
  # its remaining event budget (`nil` when unlimited).
  defp subscription(session, subscriber) do
    %{
      "schema" => "insider.live-subscription/v1",
      "session_id" => session.id,
      "subscribed" => subscriber != nil,
      "subscribers" => map_size(session.subscribers),
      "push_interval_ms" => @push_interval_ms,
      "view" => subscriber && subscriber.view && subscriber.view.spec,
      "cursor" => subscriber && subscriber.sent_cursor,
      "max_events" => subscriber && subscriber.remaining,
      "reader" => subscriber && subscriber.reader
    }
  end

  defp expires_at(session) do
    DateTime.utc_now()
    |> DateTime.add(lease_remaining(session), :millisecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp remaining(deadline), do: deadline - now()

  defp now, do: System.monotonic_time(:millisecond)
end
