defmodule Insider.Recorder do
  @moduledoc """
  A bounded, non-mailbox flight recorder for normalized events.

  Hot-path writes go directly through a recorder-owned bounded ETS store,
  never through a recorder mailbox. Admission is a short ticket lock:
  writers are admitted one at a time in the order they arrived, and a
  writer that finds the lock held waits for its turn rather than dropping
  its event. A holder or waiter that died is passed over. A writer gives up
  with `:contended` only when the lock has not changed hands for
  `admission_stall_ms` (default 1,000); that and every other loss is
  returned and counted.

  **Precondition: call `record/2`, `freeze/2`, `status/1`, and `snapshot/1`
  from Insider-owned collector or control processes, never from an
  application process.** A call may wait while other writers are admitted,
  for as long as the lock keeps changing hands. Insider's collectors meet
  that precondition: Logger and Telemetry handlers run in the emitting
  process but only write to their collector's bounded inbox, and the
  collector process records. A collector held up by a stuck holder backs up
  into that inbox, which sheds with counted loss.

  **Source shares.** Each event source has a reserved share of the event
  and byte bounds (`Insider.Recorder.Config`). When a write needs room, a
  source over its share evicts its own oldest entries first; a source within
  its share takes the oldest entries of sources over theirs. A normal write
  never evicts another source's entries while that source is within its
  share in both events and bytes, so one noisy source cannot evict the
  others' evidence. Protected entries keep their precedence: a normal write
  never evicts them, and a protected write may evict any normal entry and
  then other protected entries (never the freeze trigger), each time taking
  its own source's and over-share sources' entries before the rest.
  Evictions are counted per source in `fill/1` and `status/1`.
  """

  use GenServer

  alias Insider.Event
  alias Insider.Recorder.Classification
  alias Insider.Recorder.Config
  alias Insider.Recorder.Priority
  alias Insider.Recorder.Snapshot

  @max_evictions_per_record 32
  @liveness_polls 64
  @poll_ms 1
  # `evicted` has no slot here: it is the sum of the per-source eviction
  # counters (`Handle.source_evictions`), so each eviction is one atomic
  # update and the total always equals the sum of the sources.
  @counter_names [
    :offered,
    :accepted,
    :evicted,
    :duplicate,
    :freeze_idempotent,
    :already_frozen,
    :recovered_owner_death,
    :invalid_event,
    :classification_failed,
    :contended,
    :rate_limited,
    :rate_key_capacity,
    :oversized,
    :frozen,
    :event_id_conflict,
    :priority_protected,
    :eviction_limit,
    :unavailable,
    :internal_error
  ]
  @counter_indexes (@counter_names -- [:evicted]) |> Enum.with_index(1) |> Map.new()

  defmodule Handle do
    @moduledoc """
    Producer-side capability for one recorder, obtained once with
    `Insider.Recorder.handle/1`.

    The handle carries the ETS tables and counters that direct admission
    writes to; its fields are not a public contract.
    """
    @enforce_keys [
      :pid,
      :config,
      :counters,
      :source_evictions,
      :control,
      :entries,
      :ids,
      :normal,
      :protected,
      :indexes,
      :rates
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            pid: pid(),
            config: Config.t(),
            counters: reference(),
            source_evictions: :counters.counters_ref(),
            control: :ets.tid(),
            entries: :ets.tid(),
            ids: :ets.tid(),
            normal: :ets.tid(),
            protected: :ets.tid(),
            indexes: :ets.tid(),
            rates: :ets.tid()
          }
  end

  @type drop_reason ::
          :invalid_event
          | :classification_failed
          | :contended
          | :rate_limited
          | :rate_key_capacity
          | :oversized
          | :frozen
          | :event_id_conflict
          | :priority_protected
          | :eviction_limit
          | :unavailable
          | :internal_error

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ [])

  def start_link(options) when is_list(options) do
    {name, config_options} = Keyword.pop(options, :name)
    server_options = if name, do: [name: name], else: []

    with {:ok, config} <- Config.new(config_options) do
      GenServer.start_link(__MODULE__, config, server_options)
    end
  end

  def start_link(_options), do: {:error, :invalid_options}

  @spec handle(GenServer.server()) :: {:ok, Handle.t()} | {:error, :unavailable}
  def handle(server) do
    GenServer.call(server, :handle)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec record(Handle.t(), term()) :: :ok | {:dropped, drop_reason()}
  def record(%Handle{} = handle, event) do
    bump(handle, :offered)

    with {:ok, %Event{} = valid_event, canonical} <- Event.validate_encoded(event),
         {:ok, valid_classification, classification_bytes} <-
           classification(handle, valid_event, canonical) do
      if byte_size(canonical) + byte_size(classification_bytes) > handle.config.max_bytes do
        dropped(handle, :oversized)
      else
        with_lock(handle, fn ->
          admit_locked(
            handle,
            valid_event,
            canonical,
            valid_classification,
            classification_bytes,
            Priority.classify(valid_event),
            false
          )
        end)
      end
    else
      {:error, :classification_failed} -> dropped(handle, :classification_failed)
      _error -> dropped(handle, :invalid_event)
    end
  rescue
    _error -> dropped(handle, :unavailable)
  catch
    _kind, _reason -> dropped(handle, :internal_error)
  end

  def record(_handle, _event), do: {:dropped, :unavailable}

  @doc """
  The receipt of the retained event with id `event_id`, or `nil` when it was
  never admitted or is no longer retained. A collector that records an
  event and must name it elsewhere (a summary's exemplar) reads it here.
  """
  @spec receipt(Handle.t(), String.t()) :: pos_integer() | nil
  def receipt(%Handle{} = handle, event_id) when is_binary(event_id) do
    case :ets.lookup(handle.ids, event_id) do
      [{^event_id, receipt, _canonical, _classification}] -> receipt
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec freeze(Handle.t(), term()) ::
          {:ok, String.t()} | {:error, :already_frozen | :busy | drop_reason()}
  def freeze(%Handle{} = handle, trigger_event) do
    bump(handle, :offered)

    with {:ok, %Event{} = event, canonical} <- Event.validate_encoded(trigger_event),
         {:ok, valid_classification, classification_bytes} <-
           classification(handle, event, canonical) do
      if byte_size(canonical) + byte_size(classification_bytes) > handle.config.max_bytes do
        dropped_error(handle, :oversized)
      else
        case acquire(handle) do
          :busy ->
            bump(handle, :contended)
            {:error, :busy}

          :unavailable ->
            dropped_error(handle, :unavailable)

          {:ok, token} ->
            try do
              freeze_locked(handle, event, canonical, valid_classification, classification_bytes)
            rescue
              _error -> dropped_error(handle, :internal_error)
            catch
              _kind, _reason -> dropped_error(handle, :internal_error)
            after
              release(handle, token)
            end
        end
      end
    else
      {:error, :classification_failed} -> dropped_error(handle, :classification_failed)
      _error -> dropped_error(handle, :invalid_event)
    end
  rescue
    _error -> dropped_error(handle, :unavailable)
  end

  def freeze(_handle, _event), do: {:error, :unavailable}

  @spec snapshot(Handle.t()) ::
          {:ok, Snapshot.t()}
          | {:pending, map()}
          | {:error, :not_triggered | :busy | :unavailable}
  def snapshot(%Handle{} = handle) do
    case locked(handle, fn -> snapshot_locked(handle) end) do
      {:error, :contended} -> {:error, :busy}
      result -> result
    end
  end

  def snapshot(_handle), do: {:error, :unavailable}

  @spec status(Handle.t()) :: {:ok, map()} | {:error, :busy | :unavailable}
  def status(%Handle{} = handle) do
    case locked(handle, fn -> status_locked(handle) end) do
      {:error, :contended} -> {:error, :busy}
      result -> result
    end
  end

  def status(_handle), do: {:error, :unavailable}

  @doc """
  How full the recorder is, read without the admission lock so it never
  delays a concurrent producer: the newest receipt assigned
  (`next_receipt`, 0 before the first), the oldest retained receipt (`nil`
  when nothing is retained), the retained event count and stored bytes with
  the bounds they are held to, `sources` (each share group's
  `share_percent`, `reserved_events`, `reserved_bytes`, `retained_events`,
  `retained_bytes`, and the entries it has had `evicted`; sources without a
  share of their own are the `"other"` group), and `memory_bytes`: the
  Recorder's tables and the canonical event binaries they hold off heap.

  The per-source `evicted` counts and the cumulative `evicted` counter of
  `status/1`, their sum, are conservative: an eviction is counted before its
  entry is deleted, so a writer killed in between leaves a counted entry
  still retained (counted again if it is evicted later). They never
  undercount. The receipt-range `evicted` of `read_since/3` is exact.
  """
  @spec fill(Handle.t()) :: {:ok, map()} | {:error, :unavailable}
  def fill(%Handle{} = handle) do
    state = read_state!(handle)

    oldest =
      case :ets.first(handle.entries) do
        :"$end_of_table" -> nil
        receipt -> receipt
      end

    {:ok,
     %{
       next_receipt: state.next_receipt,
       oldest_receipt: oldest,
       retained_events: state.retained_count,
       retained_bytes: state.storage_bytes,
       max_events: handle.config.max_events,
       max_bytes: handle.config.max_bytes,
       sources: sources_report(handle, state),
       memory_bytes: memory_bytes(handle, state)
     }}
  rescue
    _error -> {:error, :unavailable}
  end

  def fill(_handle), do: {:error, :unavailable}

  @doc """
  Reads retained entries whose receipt is greater than `cursor`, in receipt
  order, without requiring a freeze trigger.

  Receipts are assigned consecutively on admission, so every receipt in
  `cursor < receipt <= next_cursor` that is not returned was evicted; the
  result reports that exact count as `evicted`. Admission losses never receive
  a receipt and are visible only in the returned cumulative `counters`.

  The read takes no admission lock, so it never delays a concurrent
  producer. It observes the highest receipt assigned when the
  read began; later admissions are left for the next read. Cursor `:latest`
  is that highest receipt, so the read returns nothing and starts a tail.
  `limit` (1..1,000, default 100) bounds entries and `max_bytes` (1..16 MiB,
  default 1 MiB) bounds stored entry bytes, except that one available entry
  is always returned so a reader makes progress. `truncated` reports either
  bound and `truncated_by` names it (`:limit` or `:max_bytes`, else `nil`).
  """
  @spec read_since(Handle.t(), non_neg_integer() | :latest, keyword()) ::
          {:ok, map()} | {:error, :invalid_cursor | :invalid_options | :unavailable}
  def read_since(handle, cursor, options \\ [])

  def read_since(%Handle{} = handle, cursor, options) when is_list(options) do
    with {:ok, limit, max_bytes} <- read_options(options),
         state = read_state!(handle),
         cursor = if(cursor == :latest, do: state.next_receipt, else: cursor),
         :ok <- valid_cursor(cursor, state.next_receipt) do
      counters = counters(handle)
      bounds = %{upper: state.next_receipt, limit: limit, max_bytes: max_bytes}
      read = %{entries: [], count: 0, bytes: 0, last: cursor}

      {read, next_cursor, truncated_by} =
        collect_since(handle, :ets.next(handle.entries, cursor), bounds, read)

      {:ok,
       %{
         cursor: cursor,
         next_cursor: next_cursor,
         next_receipt: state.next_receipt,
         truncated: truncated_by != nil,
         truncated_by: truncated_by,
         evicted: next_cursor - cursor - read.count,
         entries: Enum.reverse(read.entries),
         counters: counters
       }}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def read_since(_handle, _cursor, _options), do: {:error, :invalid_options}

  defp read_options(options) do
    limit = Keyword.get(options, :limit, 100)
    max_bytes = Keyword.get(options, :max_bytes, 1_024 * 1_024)

    if Keyword.keyword?(options) and Keyword.keys(options) -- [:limit, :max_bytes] == [] and
         is_integer(limit) and limit in 1..1_000 and is_integer(max_bytes) and
         max_bytes in 1..(16 * 1_024 * 1_024),
       do: {:ok, limit, max_bytes},
       else: {:error, :invalid_options}
  end

  defp valid_cursor(cursor, next_receipt)
       when is_integer(cursor) and cursor >= 0 and cursor <= next_receipt,
       do: :ok

  defp valid_cursor(_cursor, _next_receipt), do: {:error, :invalid_cursor}

  # `ets:next/2` on an ordered_set returns the next key in term order even when
  # the previous key was deleted concurrently, so the walk tolerates eviction.
  defp collect_since(_handle, key, %{upper: upper}, read)
       when key == :"$end_of_table" or key > upper,
       do: {read, upper, nil}

  defp collect_since(_handle, _key, %{limit: limit}, %{count: count} = read)
       when count >= limit,
       do: {read, read.last, :limit}

  defp collect_since(handle, key, bounds, read) do
    case :ets.lookup(handle.entries, key) do
      [{^key, _at, _priority, size, _canonical, _classification, _id, _keys}]
      when read.count > 0 and read.bytes + size > bounds.max_bytes ->
        {read, read.last, :max_bytes}

      [{^key, received_at, priority, size, canonical, classification, _id, _keys}] ->
        entry = %{
          receipt: key,
          received_at: received_at,
          priority: priority,
          event_bytes: byte_size(canonical),
          classification_bytes: size - byte_size(canonical),
          event: Jason.decode!(canonical),
          classification: classification
        }

        read = %{
          read
          | entries: [entry | read.entries],
            count: read.count + 1,
            bytes: read.bytes + size,
            last: key
        }

        collect_since(handle, :ets.next(handle.entries, key), bounds, read)

      [] ->
        # Evicted between `next/2` and `lookup/2`. The receipt arithmetic in
        # `read_since/3` counts it.
        collect_since(handle, :ets.next(handle.entries, key), bounds, read)
    end
  end

  @impl GenServer
  def init(%Config{} = config), do: {:ok, new_handle(config)}

  @impl GenServer
  def handle_call(:handle, _from, %Handle{} = handle), do: {:reply, {:ok, handle}, handle}

  defp new_handle(config) do
    counters = :counters.new(map_size(@counter_indexes), [:atomics])
    started_at = now!(config)
    instance_id = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)

    handle = %Handle{
      pid: self(),
      config: config,
      counters: counters,
      # Evictions per share group, bumped with the global `evicted` counter
      # as each entry is deleted, so a writer that dies before its state
      # write still leaves every eviction attributed.
      source_evictions: :counters.new(map_size(config.group_indexes), [:atomics]),
      control: table(:set),
      entries: table(:ordered_set),
      ids: table(:set),
      normal: table(:ordered_set),
      protected: table(:ordered_set),
      indexes: table(:bag),
      rates: table(:set)
    }

    true =
      :ets.insert(handle.control, {
        :state,
        %{
          phase: :open,
          instance_id: instance_id,
          started_at: started_at,
          next_receipt: 0,
          retained_count: 0,
          retained_bytes: 0,
          retained_classification_bytes: 0,
          storage_bytes: 0,
          # Per share group: `{retained_events, retained_bytes}`.
          sources: Map.new(config.reservations, fn {group, _share} -> {group, {0, 0}} end),
          freeze: nil
        }
      })

    # Admission tickets start at 1, and ticket 1 is served first.
    true = :ets.insert(handle.control, {:tickets, 0})
    true = :ets.insert(handle.control, {:lock, 1, nil, now_ms(), false})

    handle
  end

  defp table(type),
    do: :ets.new(__MODULE__, [type, :public, read_concurrency: true, write_concurrency: true])

  defp classification(
         %Handle{config: %{classification: classification}},
         event,
         canonical
       ) do
    case Classification.bind(event, canonical, classification) do
      {:ok, _classification, _bytes} = accepted -> accepted
      {:error, :invalid_classification} -> {:error, :classification_failed}
    end
  end

  defp with_lock(handle, fun) do
    case locked(handle, fun) do
      {:error, :contended} -> dropped(handle, :contended)
      {:error, :unavailable} -> dropped(handle, :unavailable)
      result -> result
    end
  end

  defp locked(handle, fun) do
    case acquire(handle) do
      {:ok, token} ->
        try do
          fun.()
        rescue
          _error -> {:error, :unavailable}
        catch
          _kind, _reason -> {:error, :unavailable}
        after
          release(handle, token)
        end

      :busy ->
        {:error, :contended}

      :unavailable ->
        {:error, :unavailable}
    end
  end

  # Admission is a ticket lock in the control table. A writer takes the next
  # ticket with `:ets.update_counter/3` and writes only after it has claimed
  # the `:lock` row for that ticket; release serves the next ticket. Writers
  # are admitted in ticket order, first come, first served.
  #
  # The `:lock` row is `{:lock, serving, holder, since_ms, dirty}`: the ticket
  # being served, the pid that claimed it (`nil` until claimed), when the row
  # last changed, and whether derived state must be rebuilt because a holder
  # died mid-write. Every change is a compare-and-swap on the whole row
  # (`:ets.select_replace/2`), so exactly one process claims or passes on
  # each ticket.
  #
  # A writer that must wait registers `{{:ticket, t}, pid, alias}` and
  # sleeps until its turn is served, which wakes it through the alias, or a
  # 1 ms poll ends. No waiter spins: a spinning process is always runnable,
  # so its scheduler never sleeps or takes work from another, and the host's
  # own processes wait behind it. The alias is deactivated and drained
  # before the call returns, so no message reaches the caller's
  # mailbox. A served turn is passed on without waiting for the stall bound
  # when its writer is dead or has given up (row `:abandoned`), and after
  # the bound when it has no row (a writer killed between taking its ticket
  # and registering it). A holder found dead is passed on with `dirty` set.
  # A writer gives up when the lock has not changed for
  # `admission_stall_ms`; it marks its row `:abandoned`, passes its turn on
  # if it is being served, and never claims afterwards. Behind a stalled
  # turn, held or registered by a live writer, a caller gives up without
  # taking a ticket, so registrations grow with the writing processes, not
  # with repeated calls.
  defp acquire(handle) do
    case admission(handle) do
      :open -> take_turn(handle, take_ticket(handle))
      :stalled -> :busy
    end
  rescue
    _error -> :unavailable
  end

  defp take_ticket(handle), do: :ets.update_counter(handle.control, :tickets, 1)

  # Before taking a ticket, a caller looks at the served turn. Once it has
  # not changed for the stall bound, a turn that can be passed on (its
  # holder or registered writer died, or its writer gave up) is passed on;
  # one held or registered by a live writer is stalled, and the caller gives
  # up without taking a ticket, so registrations cannot grow with calls. A
  # turn with no registration is either free or about to be claimed, and the
  # caller takes a ticket as usual.
  defp admission(handle) do
    [{:lock, serving, holder, since, _dirty}] = :ets.lookup(handle.control, :lock)

    if now_ms() - since < handle.config.admission_stall_ms do
      :open
    else
      stalled_turn(handle, serving, holder)
    end
  end

  defp stalled_turn(handle, serving, holder) when is_pid(holder) do
    if pass_on(handle, serving, holder, true), do: admission(handle), else: :stalled
  end

  defp stalled_turn(handle, serving, nil) do
    case :ets.lookup(handle.control, {:ticket, serving}) do
      [] ->
        :open

      [_registered] ->
        if pass_on(handle, serving, nil, false), do: admission(handle), else: :stalled
    end
  end

  defp take_turn(handle, ticket) do
    case claim(handle, ticket) do
      :not_served -> queue_for_turn(handle, ticket)
      claimed -> claimed
    end
  end

  defp claim(handle, ticket) do
    now = now_ms()

    cond do
      swap(handle, {:lock, ticket, nil, :_, false}, {:lock, ticket, self(), now, false}) ->
        {:ok, ticket}

      swap(handle, {:lock, ticket, nil, :_, true}, {:lock, ticket, self(), now, true}) ->
        recover(handle, ticket)

      true ->
        :not_served
    end
  end

  defp swap(handle, pattern, row),
    do: :ets.select_replace(handle.control, [{pattern, [], [{:const, row}]}]) == 1

  # Serves the ticket after `ticket` if the row still serves `ticket` with
  # `holder`. `dirty` is `:"$1"` to keep the flag, or a boolean to set it.
  defp advance(handle, ticket, holder, dirty) do
    next = ticket + 1
    spec = [{{:lock, ticket, holder, :_, :"$1"}, [], [{{:lock, next, nil, now_ms(), dirty}}]}]

    if :ets.select_replace(handle.control, spec) == 1 do
      :ets.delete(handle.control, {:ticket, ticket})
      wake(handle, next)
      true
    else
      false
    end
  end

  defp release(handle, ticket), do: advance(handle, ticket, self(), false)

  # Registration runs inside the protected scope, and the alias is
  # deactivated and drained in the outer `after`, which runs even when
  # `abandon/2` fails because the Recorder's tables are gone.
  defp queue_for_turn(handle, ticket) do
    reply = :erlang.alias()

    try do
      try do
        true = :ets.insert(handle.control, {{:ticket, ticket}, self(), reply})
        wait_turn(handle, %{ticket: ticket, reply: reply, polls: 1})
      after
        abandon(handle, reply)
      end
    after
      :erlang.unalias(reply)
      drain_wakes(reply)
    end
  end

  defp wait_turn(handle, wait) do
    [{:lock, serving, holder, since, _dirty}] = :ets.lookup(handle.control, :lock)

    cond do
      serving == wait.ticket ->
        case claim(handle, wait.ticket) do
          {:ok, _ticket} = claimed ->
            :ets.delete(handle.control, {:ticket, wait.ticket})
            claimed

          :not_served ->
            wait_turn(handle, wait)

          :unavailable ->
            :unavailable
        end

      serving > wait.ticket ->
        # Passed on while this writer was descheduled before registering;
        # it never claimed, so it takes a new ticket.
        :ets.delete(handle.control, {:ticket, wait.ticket})
        ticket = take_ticket(handle)
        true = :ets.insert(handle.control, {{:ticket, ticket}, self(), wait.reply})
        wait_turn(handle, %{wait | ticket: ticket})

      true ->
        poll(handle, wait, serving, holder, since)
    end
  end

  # A waiter sleeps until woken or a poll ends, then looks again. Whether the
  # served turn can be passed on is checked every `@liveness_polls` looks (it
  # asks the runtime whether a process is alive) and before giving up.
  defp poll(handle, wait, serving, holder, since) do
    stalled? = now_ms() - since >= handle.config.admission_stall_ms

    cond do
      (stalled? or rem(wait.polls, @liveness_polls) == 0) and
          pass_on(handle, serving, holder, stalled?) ->
        wait_turn(handle, %{wait | polls: 0})

      stalled? ->
        :busy

      true ->
        reply = wait.reply

        receive do
          {^reply, :serving} -> :ok
        after
          @poll_ms -> :ok
        end

        wait_turn(handle, %{wait | polls: wait.polls + 1})
    end
  end

  defp pass_on(handle, serving, holder, _stalled?) when is_pid(holder),
    do: not Process.alive?(holder) and advance(handle, serving, holder, true)

  defp pass_on(handle, serving, nil, stalled?) do
    case :ets.lookup(handle.control, {:ticket, serving}) do
      [{_key, :abandoned, _reply}] -> advance(handle, serving, nil, :"$1")
      [{_key, pid, _reply}] -> not Process.alive?(pid) and advance(handle, serving, nil, :"$1")
      [] -> stalled? and advance(handle, serving, nil, :"$1")
    end
  end

  # Runs after every wait. A row left behind belongs to a writer that did
  # not claim its turn: it is marked `:abandoned` before the turn is passed
  # on, so the writer can never claim it later, and removed once the turn
  # has passed.
  defp abandon(handle, reply) do
    handle.control
    |> :ets.match({{:ticket, :"$1"}, :_, reply})
    |> Enum.each(fn [ticket] ->
      true = :ets.insert(handle.control, {{:ticket, ticket}, :abandoned, nil})
      advance(handle, ticket, nil, :"$1")

      case :ets.lookup(handle.control, :lock) do
        [{:lock, serving, _holder, _since, _dirty}] when serving > ticket ->
          :ets.delete(handle.control, {:ticket, ticket})

        _waiting ->
          :ok
      end
    end)
  end

  defp wake(handle, ticket) do
    case :ets.lookup(handle.control, {:ticket, ticket}) do
      [{_key, pid, reply}] when is_pid(pid) -> send(reply, {reply, :serving})
      _none -> :ok
    end
  end

  defp drain_wakes(reply) do
    receive do
      {^reply, :serving} -> drain_wakes(reply)
    after
      0 -> :ok
    end
  end

  defp recover(handle, ticket) do
    recover_derived_state(handle)
    holder = self()

    :ets.select_replace(handle.control, [
      {{:lock, ticket, holder, :"$1", true}, [],
       [{{:lock, ticket, {:const, holder}, :"$1", false}}]}
    ])

    {:ok, ticket}
  rescue
    _error ->
      advance(handle, ticket, self(), true)
      :unavailable
  end

  defp recover_derived_state(handle) do
    entries = :ets.tab2list(handle.entries)
    state = read_state!(handle)

    :ets.delete_all_objects(handle.ids)
    :ets.delete_all_objects(handle.normal)
    :ets.delete_all_objects(handle.protected)
    :ets.delete_all_objects(handle.indexes)

    # The queues and the per-source usage key entries by share group, which
    # an entry does not store; recovery reads it from the canonical event.
    # Evictions per source live in `source_evictions`, not in this state.
    empty = Map.new(handle.config.reservations, fn {group, _share} -> {group, {0, 0}} end)

    sources =
      Enum.reduce(entries, empty, fn
        {receipt, _at, priority, size, canonical, classification, event_id, index_keys},
        sources ->
          group = Config.group(handle.config, Jason.decode!(canonical)["source"])
          true = :ets.insert(handle.ids, {event_id, receipt, canonical, classification})
          true = :ets.insert(queue(handle, priority), {{group, receipt}})
          Enum.each(index_keys, &:ets.insert(handle.indexes, {&1, receipt}))
          Map.update!(sources, group, fn {count, bytes} -> {count + 1, bytes + size} end)
      end)

    {count, event_bytes, classification_bytes, highest_receipt} =
      Enum.reduce(entries, {0, 0, 0, 0}, fn
        {receipt, _at, _priority, size, canonical, _classification, _id, _keys},
        {count, event_bytes, classification_bytes, highest} ->
          event_size = byte_size(canonical)

          {count + 1, event_bytes + event_size, classification_bytes + size - event_size,
           max(highest, receipt)}
      end)

    write_state!(handle, %{
      state
      | retained_count: count,
        retained_bytes: event_bytes,
        retained_classification_bytes: classification_bytes,
        storage_bytes: event_bytes + classification_bytes,
        sources: sources,
        next_receipt: max(state.next_receipt, highest_receipt)
    })

    bump(handle, :recovered_owner_death)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp freeze_locked(handle, event, canonical, classification, classification_bytes) do
    state = handle |> read_state!() |> close_if_elapsed(handle)

    case state.freeze do
      %{trigger_event_id: id, id: freeze_id} when id == event.id ->
        case :ets.lookup(handle.ids, id) do
          [{^id, _receipt, ^canonical, ^classification}] ->
            bump(handle, :freeze_idempotent)
            {:ok, freeze_id}

          _rows ->
            bump(handle, :event_id_conflict)
            {:error, :event_id_conflict}
        end

      %{} ->
        bump(handle, :already_frozen)
        {:error, :already_frozen}

      nil ->
        case admit_locked(
               handle,
               event,
               canonical,
               classification,
               classification_bytes,
               :protected,
               true,
               state
             ) do
          :ok -> establish_freeze(handle, event)
          {:dropped, reason} -> {:error, reason}
        end
    end
  end

  defp establish_freeze(handle, %Event{id: trigger_event_id} = event) do
    state = read_state!(handle)

    [{^trigger_event_id, opening_receipt, _canonical, _classification}] =
      :ets.lookup(handle.ids, trigger_event_id)

    promote_trigger(handle, opening_receipt, Config.group(handle.config, event.source))
    trigger_at = now!(handle.config)
    close_at = trigger_at + handle.config.post_trigger_ms * 1_000
    freeze_id = state.instance_id <> "-" <> Integer.to_string(opening_receipt, 36)
    phase = if close_at == trigger_at, do: :frozen, else: :post_trigger

    freeze = %{
      id: freeze_id,
      trigger_event_id: trigger_event_id,
      opening_receipt: opening_receipt,
      trigger_at: trigger_at,
      close_at: close_at,
      closed_counters: if(phase == :frozen, do: counters(handle), else: nil)
    }

    write_state!(handle, %{state | phase: phase, freeze: freeze})
    {:ok, freeze_id}
  end

  defp promote_trigger(handle, receipt, group) do
    case :ets.lookup(handle.entries, receipt) do
      [
        {^receipt, received_at, :normal, size, canonical, classification, event_id, index_keys}
      ] ->
        true =
          :ets.insert(
            handle.entries,
            {receipt, received_at, :protected, size, canonical, classification, event_id,
             index_keys}
          )

        :ets.delete(handle.normal, {group, receipt})
        true = :ets.insert(handle.protected, {{group, receipt}})

      [
        {^receipt, _received_at, :protected, _size, _canonical, _classification, _event_id,
         _index_keys}
      ] ->
        :ok
    end
  end

  defp admit_locked(
         handle,
         event,
         canonical,
         classification,
         classification_bytes,
         priority,
         force?,
         state \\ nil
       ) do
    state = (state || read_state!(handle)) |> close_if_elapsed(handle)

    if state.phase == :frozen do
      dropped(handle, :frozen)
    else
      case duplicate?(handle, event.id, canonical, classification) do
        :same ->
          bump(handle, :duplicate)
          :ok

        :conflict ->
          dropped(handle, :event_id_conflict)

        :new ->
          case rate_check(handle, event, force? or priority == :protected) do
            :ok ->
              store_with_room(
                handle,
                state,
                event,
                canonical,
                classification,
                classification_bytes,
                priority
              )

            {:dropped, _reason} = dropped ->
              dropped
          end
      end
    end
  end

  defp duplicate?(handle, event_id, canonical, classification) do
    case :ets.lookup(handle.ids, event_id) do
      [] -> :new
      [{^event_id, _receipt, ^canonical, ^classification}] -> :same
      [_entry] -> :conflict
    end
  end

  defp rate_check(_handle, _event, true), do: :ok

  defp rate_check(handle, event, false) do
    now = now!(handle.config)
    window = handle.config.rate_window_ms * 1_000

    :ets.select_delete(handle.rates, [
      {{:"$1", :"$2", :_}, [{:"=<", :"$2", now - window}], [true]}
    ])

    keys = [{:source, event.source}, {:kind, event.kind}]
    rows = Enum.map(keys, &{&1, :ets.lookup(handle.rates, &1)})
    new_keys = Enum.count(rows, fn {_key, row} -> row == [] end)

    cond do
      :ets.info(handle.rates, :size) + new_keys > handle.config.max_rate_keys ->
        dropped(handle, :rate_key_capacity)

      Enum.any?(rows, fn
        {_key, [{_stored_key, _started_at, count}]} -> count >= handle.config.rate_limit_count
        {_key, []} -> false
      end) ->
        dropped(handle, :rate_limited)

      true ->
        Enum.each(rows, fn
          {key, []} ->
            :ets.insert(handle.rates, {key, now, 1})

          {key, [{_stored_key, started_at, count}]} ->
            :ets.insert(handle.rates, {key, started_at, count + 1})
        end)

        :ok
    end
  end

  defp store_with_room(
         handle,
         state,
         event,
         canonical,
         classification,
         classification_bytes,
         priority
       ) do
    size = byte_size(canonical) + byte_size(classification_bytes)
    group = Config.group(handle.config, event.source)

    case room_plan(handle, state, %{group: group, size: size}, priority) do
      {:ok, victims} ->
        state = Enum.reduce(victims, state, &evict(handle, &1, &2))
        receipt = state.next_receipt + 1
        received_at = now!(handle.config)
        index_keys = index_keys(event)

        entry =
          {receipt, received_at, priority, size, canonical, classification, event.id, index_keys}

        true = :ets.insert(handle.entries, entry)
        true = :ets.insert(handle.ids, {event.id, receipt, canonical, classification})
        true = :ets.insert(queue(handle, priority), {{group, receipt}})
        Enum.each(index_keys, &:ets.insert(handle.indexes, {&1, receipt}))

        write_state!(handle, %{
          state
          | next_receipt: receipt,
            retained_count: state.retained_count + 1,
            retained_bytes: state.retained_bytes + byte_size(canonical),
            retained_classification_bytes:
              state.retained_classification_bytes + byte_size(classification_bytes),
            storage_bytes: state.storage_bytes + size,
            sources: add_usage(state.sources, group, 1, size)
        })

        bump(handle, :accepted)
        :ok

      {:error, reason} ->
        dropped(handle, reason)
    end
  end

  # Plans the evictions that make room for `incoming` without changing any
  # table, so a write that cannot get room leaves the store as it was. Each
  # tier names a queue and whose entries it may take, oldest first: the
  # writer's own source (`:own`), sources other than the writer that are over
  # their share at that point of the plan (`:over`), or any source (`:any`).
  # A writer over its share takes its own entries before over-share ones;
  # a writer within its share takes over-share entries first. Normal writes
  # have no `:any` tier, so a source within its share loses nothing to them.
  defp room_plan(handle, state, incoming, priority) do
    if fits?(handle.config, state, incoming.size) do
      {:ok, []}
    else
      over? = over_share?(handle.config, state.sources, incoming.group, 1, incoming.size)
      order = if over?, do: [:own, :over], else: [:over, :own]

      plan = %{
        tiers: tiers(priority, order),
        state: state,
        victims: [],
        count: 0,
        taken: %{},
        pinned: pinned_receipt(state)
      }

      find_room(handle, incoming, plan)
    end
  end

  defp tiers(:normal, order), do: Enum.map(order, &{:normal, &1})

  defp tiers(:protected, order),
    do:
      Enum.map(order, &{:normal, &1}) ++
        [{:normal, :any}] ++ Enum.map(order, &{:protected, &1}) ++ [{:protected, :any}]

  defp find_room(handle, incoming, %{state: state} = plan) do
    cond do
      fits?(handle.config, state, incoming.size) ->
        {:ok, Enum.reverse(plan.victims)}

      plan.count >= @max_evictions_per_record ->
        {:error, :eviction_limit}

      true ->
        case Enum.find_value(plan.tiers, &candidate(handle, incoming.group, plan, &1)) do
          nil -> {:error, :priority_protected}
          victim -> find_room(handle, incoming, take(handle, victim, plan))
        end
    end
  end

  defp candidate(handle, writer, plan, {queue, :own}), do: oldest(handle, plan, queue, writer)

  defp candidate(handle, writer, plan, {queue, :over}) do
    handle.config.reservations
    |> Map.keys()
    |> Enum.filter(&(&1 != writer and over_share?(handle.config, plan.state.sources, &1, 0, 0)))
    |> oldest_of(handle, plan, queue)
  end

  defp candidate(handle, _writer, plan, {queue, :any}),
    do: handle.config.reservations |> Map.keys() |> oldest_of(handle, plan, queue)

  defp oldest_of(groups, handle, plan, queue) do
    groups
    |> Enum.map(&oldest(handle, plan, queue, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(fn {_queue, _group, receipt} -> receipt end, fn -> nil end)
  end

  # The oldest entry of `group` in `queue` the plan has not taken yet. The
  # freeze trigger is never a candidate.
  defp oldest(handle, plan, queue, group) do
    after_receipt = Map.get(plan.taken, {queue, group}, 0)

    case next_in_group(queue(handle, queue), group, after_receipt, plan.pinned) do
      nil -> nil
      receipt -> {queue, group, receipt}
    end
  end

  defp next_in_group(table, group, after_receipt, pinned) do
    case :ets.next(table, {group, after_receipt}) do
      {^group, ^pinned} -> next_in_group(table, group, pinned, pinned)
      {^group, receipt} -> receipt
      _other_group_or_end -> nil
    end
  end

  defp take(handle, {queue, group, receipt} = victim, plan) do
    [{^receipt, _at, _priority, size, canonical, _classification, _id, _keys}] =
      :ets.lookup(handle.entries, receipt)

    %{
      plan
      | state: release_usage(plan.state, group, size, byte_size(canonical)),
        victims: [victim | plan.victims],
        count: plan.count + 1,
        taken: Map.put(plan.taken, {queue, group}, receipt)
    }
  end

  defp fits?(config, state, incoming_size),
    do:
      state.retained_count < config.max_events and
        state.storage_bytes + incoming_size <= config.max_bytes

  # Whether `group`, with `events` and `bytes` more, would hold more than its
  # reserved share in either dimension.
  defp over_share?(config, sources, group, events, bytes) do
    {_percent, reserved_events, reserved_bytes} = Map.fetch!(config.reservations, group)
    {retained_events, retained_bytes} = Map.fetch!(sources, group)
    retained_events + events > reserved_events or retained_bytes + bytes > reserved_bytes
  end

  defp pinned_receipt(%{freeze: %{opening_receipt: receipt}}), do: receipt
  defp pinned_receipt(_state), do: nil

  # The eviction is counted, once and for its source, before the entry is
  # deleted: a writer killed in between leaves a counted entry that is still
  # retained (an overcount, never a silent loss), and the total and the
  # per-source counts never disagree.
  defp evict(handle, {queue, group, receipt}, state) do
    [{^receipt, _at, _priority, size, canonical, _classification, event_id, index_keys}] =
      :ets.lookup(handle.entries, receipt)

    :counters.add(handle.source_evictions, Map.fetch!(handle.config.group_indexes, group), 1)
    :ets.delete(handle.entries, receipt)
    :ets.delete(handle.ids, event_id)
    :ets.delete(queue(handle, queue), {group, receipt})
    Enum.each(index_keys, &:ets.delete_object(handle.indexes, {&1, receipt}))
    release_usage(state, group, size, byte_size(canonical))
  end

  defp release_usage(state, group, size, event_size) do
    %{
      state
      | retained_count: state.retained_count - 1,
        retained_bytes: state.retained_bytes - event_size,
        retained_classification_bytes: state.retained_classification_bytes - (size - event_size),
        storage_bytes: state.storage_bytes - size,
        sources: add_usage(state.sources, group, -1, -size)
    }
  end

  defp add_usage(sources, group, events, bytes) do
    Map.update!(sources, group, fn {retained_events, retained_bytes} ->
      {retained_events + events, retained_bytes + bytes}
    end)
  end

  defp sources_report(handle, state) do
    config = handle.config

    Map.new(config.reservations, fn {group, {percent, reserved_events, reserved_bytes}} ->
      {events, bytes} = Map.fetch!(state.sources, group)

      {group,
       %{
         share_percent: percent,
         reserved_events: reserved_events,
         reserved_bytes: reserved_bytes,
         retained_events: events,
         retained_bytes: bytes,
         evicted: :counters.get(handle.source_evictions, Map.fetch!(config.group_indexes, group))
       }}
    end)
  end

  # ETS counts a stored binary larger than 64 bytes by its reference only;
  # every canonical event is larger, so its bytes are added.
  defp memory_bytes(handle, state) do
    words =
      [
        handle.control,
        handle.entries,
        handle.ids,
        handle.normal,
        handle.protected,
        handle.indexes,
        handle.rates
      ]
      |> Enum.map(&:ets.info(&1, :memory))
      |> Enum.sum()

    words * :erlang.system_info(:wordsize) + state.retained_bytes
  end

  defp queue(handle, :normal), do: handle.normal
  defp queue(handle, :protected), do: handle.protected

  defp index_keys(event) do
    [
      {:subject, event.subject},
      {:logical_operation, event.causality.logical_operation_id},
      {:trace, event.causality.trace_id},
      {:span, event.causality.span_id}
    ]
    |> Enum.reject(fn {_kind, value} -> is_nil(value) end)
  end

  defp snapshot_locked(handle) do
    state = handle |> read_state!() |> close_if_elapsed(handle)

    case state.phase do
      :open ->
        {:error, :not_triggered}

      :post_trigger ->
        {:pending, %{freeze_id: state.freeze.id, closes_at: state.freeze.close_at}}

      :frozen ->
        {:ok, build_snapshot(handle, state)}
    end
  end

  defp build_snapshot(handle, state) do
    pre_start = state.freeze.trigger_at - handle.config.pre_trigger_ms * 1_000

    events =
      handle.entries
      |> :ets.tab2list()
      |> Enum.filter(fn
        {receipt, received_at, _priority, _size, _canonical, _classification, _id, _keys} ->
          inside_window?(receipt, received_at, state.freeze, pre_start)
      end)
      |> Enum.map(&snapshot_entry!/1)

    retained_bytes = Enum.sum(Enum.map(events, & &1.event_bytes))
    classification_bytes = Enum.sum(Enum.map(events, & &1.classification_bytes))
    public_events = Enum.map(events, &Map.drop(&1, [:event_bytes, :classification_bytes]))
    counters = state.freeze.closed_counters
    gaps = gaps(state, pre_start, counters)

    %Snapshot{
      instance_id: state.instance_id,
      recorder_started_at: state.started_at,
      freeze_id: state.freeze.id,
      trigger_event_id: state.freeze.trigger_event_id,
      opening_receipt: state.freeze.opening_receipt,
      closing_receipt: state.next_receipt,
      freeze_status: :complete,
      completeness: if(gaps == [], do: :complete, else: :incomplete),
      gaps: gaps,
      counters: counters,
      retained_count: length(public_events),
      retained_bytes: retained_bytes,
      classification_bytes: classification_bytes,
      events: public_events
    }
  end

  defp snapshot_entry!(
         {receipt, received_at, priority, size, canonical, classification, _id, _keys}
       ) do
    {:ok, event} = canonical |> Jason.decode!() |> Event.decode_map()

    %{
      receipt: receipt,
      received_at: received_at,
      priority: priority,
      event_bytes: byte_size(canonical),
      classification_bytes: size - byte_size(canonical),
      event: event,
      classification: classification
    }
  end

  defp inside_window?(receipt, _received_at, freeze, _pre_start)
       when receipt == freeze.opening_receipt,
       do: true

  defp inside_window?(_receipt, received_at, freeze, pre_start) do
    before_close =
      (freeze.close_at == freeze.trigger_at and received_at <= freeze.close_at) or
        received_at < freeze.close_at

    received_at >= pre_start and before_close
  end

  defp gaps(state, pre_start, counters) do
    dropped =
      @counter_names
      |> Enum.reject(
        &(&1 in [
            :offered,
            :accepted,
            :evicted,
            :duplicate,
            :freeze_idempotent,
            :already_frozen,
            :recovered_owner_death
          ])
      )
      |> Enum.any?(&(Map.fetch!(counters, &1) > 0))

    []
    |> maybe_gap(state.started_at > pre_start, :prehistory_unavailable)
    |> maybe_gap(counters.evicted > 0, :evicted_evidence)
    |> maybe_gap(counters.recovered_owner_death > 0, :recovered_after_owner_death)
    |> maybe_gap(dropped, :dropped_evidence)
    |> Enum.reverse()
  end

  defp maybe_gap(gaps, true, gap), do: [gap | gaps]
  defp maybe_gap(gaps, false, _gap), do: gaps

  defp status_locked(handle) do
    state = handle |> read_state!() |> close_if_elapsed(handle)

    {:ok,
     Map.merge(state, %{
       counters: counters(handle),
       index_entries: :ets.info(handle.indexes, :size),
       rate_keys: :ets.info(handle.rates, :size),
       sources: sources_report(handle, state)
     })}
  end

  defp close_if_elapsed(%{phase: :post_trigger} = state, handle) do
    if now!(handle.config) >= state.freeze.close_at do
      closed = %{
        state
        | phase: :frozen,
          freeze: %{state.freeze | closed_counters: counters(handle)}
      }

      write_state!(handle, closed)
      closed
    else
      state
    end
  end

  defp close_if_elapsed(state, _handle), do: state

  defp read_state!(handle) do
    [{:state, state}] = :ets.lookup(handle.control, :state)
    state
  end

  defp write_state!(handle, state) do
    true = :ets.insert(handle.control, {:state, state})
    state
  end

  defp now!(config) do
    case config.clock.() do
      value when is_integer(value) -> value
      _value -> raise ArgumentError, "recorder clock must return an integer"
    end
  end

  defp counters(handle) do
    evicted =
      Enum.reduce(1..map_size(handle.config.group_indexes), 0, fn index, sum ->
        sum + :counters.get(handle.source_evictions, index)
      end)

    @counter_indexes
    |> Map.new(fn {name, index} -> {name, :counters.get(handle.counters, index)} end)
    |> Map.put(:evicted, evicted)
  end

  defp bump(handle, name) do
    :counters.add(handle.counters, Map.fetch!(@counter_indexes, name), 1)
  rescue
    _error -> :ok
  end

  defp dropped(handle, reason) do
    bump(handle, reason)
    {:dropped, reason}
  end

  defp dropped_error(handle, reason) do
    bump(handle, reason)
    {:error, reason}
  end
end
