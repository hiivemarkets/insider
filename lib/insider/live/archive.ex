defmodule Insider.Live.Archive do
  @moduledoc false

  # The receipts of a live session that no running Recorder holds any more:
  # every segment before an amendment, and after a stop the whole session
  # for its read-only retention window. The owner copies them here from
  # `Insider.Collector.Session.read_events/3` results that are already
  # redaction-checked and use live-session receipts, so reading an archive
  # returns the same read shape, which `Insider.Live.Batch` selects and
  # builds unchanged; disclosure is applied at read time as for a running
  # session.
  #
  # Live-session receipts stay consecutive across segments: a segment's
  # Recorder counts from 1 again, so its receipts are shifted by the
  # session's `offset` (`shift/2`), and its cumulative loss counters are
  # added to those its earlier segments ended with (`carry/2`), so cursor
  # baselines stay valid across an amendment.
  #
  # Bounded like a Recorder: at most 4,096 entries and 8 MiB of external
  # term size. Entries past a bound are dropped oldest first; a read reports
  # them, like any receipt neither returned nor withheld, as `evicted`.

  @max_entries 4_096
  @max_bytes 8 * 1_024 * 1_024
  # The integer fields of a component's bounded ingress evidence are the
  # cumulative counters `Insider.Live.Batch` reports losses from, except the
  # state gauges: a collector's current state, not a count. A segment's
  # counters end with its collector, so its gauges end at 0 (a pause
  # ongoing at the seal ended when the capture was removed) and never add
  # to a later segment's own state.
  @components ["calls", "logger", "otel", "poller", "telemetry"]
  @gauges %{"otel" => ["paused", "pending"]}

  # A withheld receipt costs one entry and its integer's external size, so
  # both kinds of retained evidence share the bounds. `unread` holds the
  # boundaries (the newest receipt copied) of copies that could not read a
  # segment to its end, newest first, as ranges `{first, last, boundaries}`:
  # beyond `@max_unread` ranges the two oldest are coalesced into one that
  # covers both, so no boundary is forgotten, and every read overlapping a
  # range reports its boundaries.
  @max_unread 8

  defstruct entries: [], withheld: [], count: 0, bytes: 0, top: 0, unread: []

  @type t :: %__MODULE__{
          entries: [map()],
          withheld: [pos_integer()],
          count: non_neg_integer(),
          bytes: non_neg_integer(),
          top: non_neg_integer(),
          unread: [{non_neg_integer(), non_neg_integer(), pos_integer()}]
        }

  @doc "The archive's bounds, for the welcome document."
  @spec bounds() :: map()
  def bounds, do: %{"archived_events_max" => @max_entries, "archived_bytes_max" => @max_bytes}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends a live-session read that starts at or after the archive's newest
  receipt. Its receipts up to `"next_cursor"` are covered from now on; any
  of them neither returned nor withheld reads as evicted.
  """
  @spec append(t(), map()) :: t()
  def append(%__MODULE__{} = archive, read) do
    entries = Enum.filter(read["events"], &(&1["receipt"] > archive.top))
    withheld = Enum.filter(read["withheld_receipts"], &(&1 > archive.top))
    bytes = Enum.reduce(entries ++ withheld, 0, &(:erlang.external_size(&1) + &2))

    bound(%{
      archive
      | entries: archive.entries ++ entries,
        withheld: archive.withheld ++ withheld,
        count: archive.count + length(entries) + length(withheld),
        bytes: archive.bytes + bytes,
        top: max(archive.top, read["next_cursor"])
    })
  end

  @doc """
  Marks the archive's newest receipt as the end of a segment whose last
  events could not be copied, so reads that reach it report the gap
  `segment_end_unread`.
  """
  @spec unread(t()) :: t()
  def unread(%__MODULE__{} = archive),
    do: %{archive | unread: coalesce([{archive.top, archive.top, 1} | archive.unread])}

  defp coalesce(ranges) when length(ranges) <= @max_unread, do: ranges

  defp coalesce(ranges) do
    {newer, [{first1, last1, count1}, {first2, last2, count2}]} =
      Enum.split(ranges, length(ranges) - 2)

    newer ++ [{min(first1, first2), max(last1, last2), count1 + count2}]
  end

  @doc """
  The `segment_end_unread` gap of a batch from `cursor` to `next_cursor`:
  at most one, whose `"boundaries"` counts the marked boundaries in every
  range the batch reached. Its count is `nil`: how many events a boundary
  lost is unknown.
  """
  @spec unread_gaps(t() | nil, map()) :: [map()]
  def unread_gaps(nil, _batch), do: []

  def unread_gaps(%__MODULE__{unread: unread}, batch) do
    reached =
      for {first, last, boundaries} <- unread,
          batch["cursor"] <= last and batch["next_cursor"] >= first,
          not (batch["truncated"] and batch["next_cursor"] == first),
          reduce: 0,
          do: (total -> total + boundaries)

    if reached == 0,
      do: [],
      else: [
        %{
          "reason" => "segment_end_unread",
          "count" => nil,
          "scope" => "unknown",
          "boundaries" => reached
        }
      ]
  end

  @doc "Appends one entry (an amendment marker) at the next receipt."
  @spec put(t(), (pos_integer() -> map())) :: t()
  def put(%__MODULE__{} = archive, build) do
    entry = build.(archive.top + 1)

    bound(%{
      archive
      | entries: archive.entries ++ [entry],
        count: archive.count + 1,
        bytes: archive.bytes + :erlang.external_size(entry),
        top: archive.top + 1
    })
  end

  defp bound(%{count: count, bytes: bytes} = archive)
       when count <= @max_entries and bytes <= @max_bytes,
       do: archive

  # The oldest retained evidence goes first, entry or withheld receipt.
  defp bound(
         %{entries: [%{"receipt" => receipt} = oldest | entries], withheld: withheld} = archive
       )
       when withheld == [] or receipt < hd(withheld) do
    bound(%{
      archive
      | entries: entries,
        count: archive.count - 1,
        bytes: archive.bytes - :erlang.external_size(oldest)
    })
  end

  defp bound(%{withheld: [oldest | withheld]} = archive) do
    bound(%{
      archive
      | withheld: withheld,
        count: archive.count - 1,
        bytes: archive.bytes - :erlang.external_size(oldest)
    })
  end

  @doc "The oldest receipt the archive can return, or `nil` when it holds none."
  @spec oldest(t()) :: pos_integer() | nil
  def oldest(%__MODULE__{entries: entries, withheld: withheld}) do
    [List.first(entries), List.first(withheld)]
    |> Enum.map(fn
      %{"receipt" => receipt} -> receipt
      other -> other
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  @doc """
  Reads at most `limit` entries after `cursor`, counting withheld receipts
  as `Insider.Collector.Session.read_events/3` does, in its read shape
  without counters. `{:error, :invalid_cursor}` past the newest receipt. A
  zero `limit` (a paged read with nothing left to take) reads nothing and
  stays at `cursor`.

  `max_bytes` bounds the entries taken by their external term size, the
  measure the archive's own byte bound uses (`page_bytes/1`); the first
  entry is always taken, so a reader makes progress. A withheld receipt
  returns no event and costs no page bytes.
  """
  @spec read(t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, :invalid_cursor}
  def read(%__MODULE__{top: top}, cursor, _limit, _max_bytes) when cursor > top,
    do: {:error, :invalid_cursor}

  def read(%__MODULE__{} = archive, cursor, limit, max_bytes) do
    events = Enum.drop_while(archive.entries, &(&1["receipt"] <= cursor))
    withheld = Enum.drop_while(archive.withheld, &(&1 <= cursor))
    {taken, more?} = take(events, withheld, {limit, max_bytes, true}, [])

    next_cursor =
      case {more?, taken} do
        {false, _taken} -> archive.top
        {true, []} -> cursor
        {true, [{receipt, _entry} | _rest]} -> receipt
      end

    events = for {_receipt, %{} = entry} <- Enum.reverse(taken), do: entry
    withheld = for {receipt, :withheld} <- Enum.reverse(taken), do: receipt

    {:ok,
     %{
       "cursor" => cursor,
       "next_cursor" => next_cursor,
       "next_receipt" => archive.top,
       "truncated" => more?,
       "events" => events,
       "evicted" => next_cursor - cursor - length(taken),
       "redaction_withheld" => length(withheld),
       "withheld_receipts" => withheld
     }}
  end

  @doc "The page bytes of an archive read's events: their external term size."
  @spec page_bytes(map()) :: non_neg_integer()
  def page_bytes(read), do: Enum.reduce(read["events"], 0, &(:erlang.external_size(&1) + &2))

  @doc """
  The entries and page bytes left for the running segment after an archive
  `part` read with `entries` and `max_bytes`: none of either when the part
  stopped at a bound or used every byte, so the live part then supplies only
  its newest receipt and counters (`join/3` with a zero budget).
  """
  @spec live_budget(map(), non_neg_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def live_budget(part, entries, max_bytes) do
    left = entries - length(part["events"]) - part["redaction_withheld"]
    bytes = max_bytes - page_bytes(part)
    if part["truncated"] or left <= 0 or bytes <= 0, do: {0, 0}, else: {left, bytes}
  end

  # Merges entries and withheld receipts in receipt order, newest first,
  # within `{entries, bytes, first?}`; the first entry ignores the bytes.
  defp take(events, withheld, {0, _bytes, _first?}, taken),
    do: {taken, events != [] or withheld != []}

  defp take([], [], _budget, taken), do: {taken, false}

  defp take([%{"receipt" => receipt} = entry | rest], withheld, budget, taken)
       when withheld == [] or receipt < hd(withheld) do
    {limit, bytes, first?} = budget
    size = :erlang.external_size(entry)

    if first? or size <= bytes,
      do: take(rest, withheld, {limit - 1, bytes - size, false}, [{receipt, entry} | taken]),
      else: {taken, true}
  end

  defp take(events, [receipt | withheld], {limit, bytes, first?}, taken),
    do: take(events, withheld, {limit - 1, bytes, first?}, [{receipt, :withheld} | taken])

  @doc """
  Continues an archive `part` with `live`, a read of the running segment
  from the archive's newest receipt that asked for `budget` entries (none
  when the part used the whole scan budget, in which case only its newest
  receipt and counters are taken). The result has `live`'s counters.
  """
  @spec join(map(), map(), non_neg_integer()) :: map()
  def join(part, live, budget) do
    if part["truncated"] or budget == 0 do
      Map.merge(live, %{
        part
        | "truncated" => part["truncated"] or live["next_receipt"] > part["next_cursor"]
      })
      |> Map.put("next_receipt", live["next_receipt"])
    else
      Map.merge(live, %{
        "cursor" => part["cursor"],
        "events" => part["events"] ++ live["events"],
        "evicted" => part["evicted"] + live["evicted"],
        "redaction_withheld" => part["redaction_withheld"] + live["redaction_withheld"],
        "withheld_receipts" => part["withheld_receipts"] ++ live["withheld_receipts"]
      })
    end
  end

  @doc "Shifts a segment read's receipts and cursors to live-session receipts."
  @spec shift(map(), non_neg_integer()) :: map()
  def shift(read, 0), do: read

  def shift(read, offset) do
    Map.merge(read, %{
      "cursor" => read["cursor"] + offset,
      "next_cursor" => read["next_cursor"] + offset,
      "next_receipt" => read["next_receipt"] + offset,
      "events" => Enum.map(read["events"], &%{&1 | "receipt" => &1["receipt"] + offset}),
      "withheld_receipts" => Enum.map(read["withheld_receipts"], &(&1 + offset))
    })
  end

  @doc """
  The cumulative loss counters of a read: its Recorder counters and the
  integer fields of each component's bounded ingress evidence. A component
  whose accounting was unavailable is kept as such
  (`"accounting_unavailable" => true`), so the uncertainty is never lost
  when counters are merged or carried into later segments.
  """
  @spec counters(map()) :: map()
  def counters(read) do
    Enum.reduce(@components, %{"recorder_counters" => read["recorder_counters"]}, fn component,
                                                                                     acc ->
      case read[component] do
        %{"evidence" => "bounded_status"} = evidence ->
          counts = :maps.filter(fn _key, value -> is_integer(value) end, evidence)

          gauges =
            for key <- Map.get(@gauges, component, []), is_map_key(counts, key), do: {key, 0}

          counts = Map.merge(counts, Map.new(gauges))
          counts = Map.put(counts, "evidence", "bounded_status")

          counts =
            if evidence["accounting_unavailable"],
              do: Map.put(counts, "accounting_unavailable", true),
              else: counts

          Map.put(acc, component, counts)

        %{"configured" => true} ->
          Map.put(acc, component, %{
            "configured" => true,
            "evidence" => "malformed_or_unavailable",
            "accounting_unavailable" => true
          })

        _other ->
          acc
      end
    end)
  end

  @doc """
  The larger of two cumulative counter maps (as `counters/1` returns),
  counter by counter: the counters before and after a seal, where a sealed
  component reports only what earlier segments ended with. Unavailable
  accounting on either side stays unavailable; counts known from the other
  side are kept.
  """
  @spec max_counters(map(), map()) :: map()
  def max_counters(left, right) do
    Map.merge(left, right, fn _key, one, two when is_map(one) and is_map(two) ->
      Map.merge(one, two, fn
        _counter, a, b when is_integer(a) and is_integer(b) -> max(a, b)
        _counter, a, b when is_boolean(a) and is_boolean(b) -> a or b
        "evidence", "bounded_status", _b -> "bounded_status"
        "evidence", _a, b -> b
        _counter, a, _b -> a
      end)
    end)
  end

  @doc """
  Adds the counters earlier segments ended with to a read's cumulative
  counters. A component this segment does not run (not configured, or
  sealed) reports the counters it ended with, so its earlier losses stay
  reported; one whose accounting is unavailable stays unavailable.
  """
  @spec carry(map(), map()) :: map()
  def carry(read, carried) when map_size(carried) == 0, do: read

  def carry(read, carried) do
    Enum.reduce(carried, read, fn
      {"recorder_counters", counters}, read ->
        Map.update(read, "recorder_counters", counters, &sum(&1, counters))

      {component, counters}, read ->
        case read[component] do
          %{"evidence" => "bounded_status"} = evidence ->
            Map.put(read, component, sum(evidence, counters))

          %{"configured" => true} ->
            read

          _absent ->
            Map.put(read, component, counters)
        end
    end)
  end

  @doc "Sums two count maps key by key; non-integer values of `base` are kept."
  @spec sum(map(), map()) :: map()
  def sum(base, added) do
    Map.merge(base, added, fn
      _key, left, right when is_integer(left) and is_integer(right) -> left + right
      _key, left, _right -> left
    end)
  end

  @doc """
  A read of a stopped session's archive with the counters it ended with.
  """
  @spec read_retained(
          t(),
          non_neg_integer() | :latest,
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: {:ok, map()} | {:error, :invalid_cursor}
  def read_retained(archive, :latest, limit, max_bytes, counters),
    do: read_retained(archive, archive.top, limit, max_bytes, counters)

  def read_retained(archive, cursor, limit, max_bytes, counters) do
    with {:ok, read} <- read(archive, cursor, limit, max_bytes),
         do: {:ok, Map.merge(read, counters)}
  end
end
