defmodule Insider.Live.Batch do
  @moduledoc false

  # Shapes `Insider.Collector.Session.read_events/3` pages into one
  # `insider.live-events/v1` batch and makes every loss explicit. Eviction and
  # withheld redaction are exact for the receipt range. Admission and ingress
  # losses have no receipt, so they are reported as cumulative-counter deltas
  # against the counters observed when the reader's cursor was issued.
  # Every returned event passes `Insider.Live.Disclosure`; the reader's view
  # decides on each event as it would be disclosed, and the read limits count
  # only the events returned. A read is selected page by page (`selection/3`,
  # `add/2`, `finish/1`) and keeps only the events it returns, so its memory
  # is its result plus one page.

  alias Insider.Event.Canonical
  alias Insider.Live.Disclosure
  alias Insider.Live.View
  alias Insider.Redaction.Credentials

  @recorder_losses [
    "classification_failed",
    "contended",
    "event_id_conflict",
    "eviction_limit",
    "frozen",
    "internal_error",
    "invalid_event",
    "oversized",
    "priority_protected",
    "rate_key_capacity",
    "rate_limited",
    "unavailable"
  ]
  @ingress_losses %{
    "calls" => ["invalid", "shed", "undrained", "undrained_unknown"],
    "logger" => ["invalid", "shed"],
    "otel" => ["abandoned", "invalid", "shed"],
    "poller" => ["events_invalid"],
    "telemetry" => ["handler_failures", "invalid", "omissions_unrecorded", "shed"]
  }

  # A paused otel capture does not observe the spans that end meanwhile, so
  # their number is unknown. Every read whose interval overlaps a pause
  # reports it with a `nil` count: `otel_paused_ongoing` while the pause
  # lasts at read time, else `otel_paused` when a pause started since the
  # reader's baseline or was ongoing at it. The baseline keeps the pause
  # count and the paused state under these internal keys.
  @pause_starts "$otel_pauses"
  @pause_state "$otel_paused"

  @type counters :: %{optional(String.t()) => non_neg_integer()}
  @type limits :: %{
          required(:limit) => pos_integer(),
          required(:max_bytes) => pos_integer(),
          required(:scan_limit) => pos_integer(),
          optional(:upto) => non_neg_integer() | nil,
          optional(atom()) => term()
        }
  @typedoc "One public read being selected from collector pages."
  @opaque selection :: map()

  @doc """
  Every gap reason this module can emit, for documentation and tests.
  """
  @spec gap_reasons() :: [String.t()]
  def gap_reasons do
    receipt = ["evicted", "redaction_withheld"]
    recorder = Enum.map(@recorder_losses, &("recorder_" <> &1))

    ingress =
      Enum.flat_map(@ingress_losses, fn {component, fields} ->
        [component <> "_accounting_unavailable" | Enum.map(fields, &(component <> "_" <> &1))]
      end)

    # `segment_end_unread` comes from `Insider.Live.Archive.unread_gaps/2`.
    Enum.sort(
      receipt ++
        recorder ++
        ingress ++
        ["otel_paused", "otel_paused_ongoing", "final_read_unavailable", "final_read_withheld"] ++
        ["segment_end_unread"]
    )
  end

  @doc """
  Starts selecting one public read for a reader's `view`: `limit` and
  `max_bytes` bound the events returned (their canonical JSON as projected
  through the `profile` disclosure boundary; the first shown event is always
  returned) and `scan_limit` the retained entries examined, shown or hidden.
  An `upto` limit is the newest receipt the read may return: the read stops
  there, counts its receipt-range losses only up to it, and is complete when
  it reaches it, while the batch still reports the newest receipt when the
  read began (see `check_upto/2`). Feed it collector pages in receipt order
  with `add/2`, each read from `next_cursor/1` for at most `wanted/1`
  entries, and end it with `finish/1`.
  """
  @spec selection(View.t() | nil, limits(), Disclosure.profile()) :: selection()
  def selection(view, limits, profile) do
    allowlist = Disclosure.measurement_allowlist()

    %{
      view: view,
      limits: limits,
      project: &Disclosure.project(&1, allowlist, profile),
      upto: Map.get(limits, :upto),
      evidence: nil,
      cursor: nil,
      upper: nil,
      newest: nil,
      last: nil,
      processed: 0,
      withheld: 0,
      shown: [],
      count: 0,
      bytes: 0,
      hidden: View.counts(view),
      outcome: nil
    }
  end

  @doc """
  Checks a read's `upto` against its first page: it must lie between the
  page's resolved starting cursor and its newest receipt, or the bound
  could not hold. Later pages, and a read without `upto`, always pass.
  """
  @spec check_upto(selection(), map()) :: :ok | {:error, :invalid_upto}
  def check_upto(%{upto: nil}, _page), do: :ok
  def check_upto(%{evidence: evidence}, _page) when not is_nil(evidence), do: :ok

  def check_upto(%{upto: upto}, %{"cursor" => cursor, "next_receipt" => newest})
      when upto >= cursor and upto <= newest,
      do: :ok

  def check_upto(_selection, _page), do: {:error, :invalid_upto}

  @doc """
  The entries the next page may read: what is left of the scan budget, and
  without a view no more than the events still to return, since every entry
  is returned unless redaction withholds it. Zero once the read has ended.
  """
  @spec wanted(selection()) :: non_neg_integer()
  def wanted(%{outcome: nil} = selection) do
    scan = selection.limits.scan_limit - selection.processed

    wanted =
      if selection.view, do: scan, else: min(selection.limits.limit - selection.count, scan)

    max(wanted, 0)
  end

  def wanted(_selection), do: 0

  @doc "The cursor the next page is read from: just after the entries consumed so far."
  @spec next_cursor(selection()) :: non_neg_integer()
  def next_cursor(selection), do: selection.last

  @doc """
  Adds one collector page to the read; the first page is read from the
  public cursor. The first page's `"next_receipt"` (the newest receipt when
  the read began) is the read's snapshot: a later page's entries past it are
  left for the next public read, and the cursor never passes it. Each
  page's hidden and withheld entries are only counted, and its cumulative
  counters and ingress evidence replace the previous page's.

  Returns `:halt` when the read has ended: a limit cut it just before the
  next event it would have returned (the hidden events up to there are
  consumed and counted), it reached its snapshot, or the page stopped at its
  redaction deadline. Otherwise `:cont`, and the caller reads on while
  `wanted/1` is positive.
  """
  @spec add(selection(), map()) :: {:cont | :halt, selection()}
  def add(%{outcome: nil} = selection, page) do
    selection = if selection.evidence, do: selection, else: open(selection, page)
    upper = selection.upper
    events = Enum.filter(page["events"], &(&1["receipt"] <= upper))
    withheld = Enum.filter(page["withheld_receipts"], &(&1 <= upper))
    selection = %{selection | evidence: Map.drop(page, ["events", "withheld_receipts"])}

    case Enum.reduce_while(events, {selection, 0}, &select_event/2) do
      {:cut, receipt, reason, selection, seen} ->
        {:halt, consume(selection, receipt - 1, seen, withheld, {true, reason})}

      {selection, seen} ->
        page_last = min(page["next_cursor"], upper)
        progressed? = page_last > selection.last
        selection = consume(selection, page_last, seen, withheld, nil)

        cond do
          page_last >= upper or not page["truncated"] ->
            {:halt, %{selection | outcome: {false, nil}}}

          # A page that consumed nothing can only have run out of time.
          page["truncated_by"] == "deadline" or not progressed? ->
            {:halt, %{selection | outcome: {true, "deadline"}}}

          true ->
            {:cont, selection}
        end
    end
  end

  @doc "Ends a read whose time ran out before its next page."
  @spec expire(selection()) :: selection()
  def expire(%{outcome: nil} = selection), do: %{selection | outcome: {true, "deadline"}}

  @doc """
  The selected read, in the shape `build/4` takes, and the counts the view
  hid. `"truncated_by"` names the bound that ended the read: `"limit"`,
  `"max_bytes"`, `"scan_limit"` (the scan budget ran out first, so a sparse
  view is never silently starved), `"deadline"`, or `nil`. A read cut short
  recounts its receipt-range losses for the shorter range.
  """
  @spec finish(selection()) :: {map(), %{optional(String.t()) => non_neg_integer()}}
  def finish(selection) do
    {truncated, truncated_by} =
      case selection.outcome do
        nil ->
          {true, if(selection.count >= selection.limits.limit, do: "limit", else: "scan_limit")}

        outcome ->
          outcome
      end

    read =
      Map.merge(selection.evidence, %{
        "cursor" => selection.cursor,
        "next_cursor" => selection.last,
        "next_receipt" => selection.newest,
        "truncated" => truncated,
        "truncated_by" => truncated_by,
        "events" => Enum.reverse(selection.shown),
        # Receipts are consecutive, so every receipt up to the cursor that was
        # neither read nor withheld was evicted.
        "evicted" => selection.last - selection.cursor - selection.processed,
        "redaction_withheld" => selection.withheld
      })

    {read, selection.hidden}
  end

  # The first page fixes the read's snapshot: its newest receipt, and the
  # upper bound the read never passes (`upto` when given, else that receipt).
  defp open(selection, page) do
    newest = page["next_receipt"]

    %{
      selection
      | cursor: page["cursor"],
        upper: selection.upto || newest,
        newest: newest,
        last: page["cursor"]
    }
  end

  # Consumes the page's entries up to `last`: the `seen` events before it and
  # the withheld receipts no later than it.
  defp consume(selection, last, seen, withheld, outcome) do
    withheld = Enum.count(withheld, &(&1 <= last))

    %{
      selection
      | last: last,
        processed: selection.processed + seen + withheld,
        withheld: selection.withheld + withheld,
        outcome: outcome
    }
  end

  defp select_event(entry, {selection, seen}) do
    case hides(selection, entry) do
      nil ->
        show(entry, selection, seen)

      filter ->
        hidden = Map.update!(selection.hidden, filter, &(&1 + 1))
        {:cont, {%{selection | hidden: hidden}, seen + 1}}
    end
  end

  # A view first reads only an event's source, kind, and severity. The
  # disclosure boundary never changes those fields and credential masking
  # changes each exactly as `Credentials.mask_text/1` does (none is a
  # credential key), so the view decides on them as they would be returned
  # without projecting the events it hides: projection costs far more than
  # these three strings. A view's signatures and trace scope read the event
  # as disclosed, so only those views project an event to decide on it.
  defp hides(%{view: nil}, _entry), do: nil

  # The session's own `live` events (an amendment marker) change what every
  # later event means, so no view hides them.
  defp hides(_selection, %{"event" => %{"source" => "live"}}), do: nil

  defp hides(%{view: view} = selection, %{"event" => event} = entry) do
    disclosed =
      Map.new(["source", "kind", "severity"], fn key ->
        case event[key] do
          value when is_binary(value) ->
            {key, if(String.valid?(value), do: Credentials.mask_text(value), else: value)}

          value ->
            {key, value}
        end
      end)

    case View.hides(view, disclosed) do
      nil -> if View.deep?(view), do: View.hides_deep(view, selection.project.(entry)["event"])
      filter -> filter
    end
  end

  defp show(entry, selection, seen) do
    if selection.count >= selection.limits.limit do
      {:halt, {:cut, entry["receipt"], "limit", selection, seen}}
    else
      projected = selection.project.(entry)
      bytes = byte_size(Canonical.encode(projected))

      if selection.count > 0 and selection.bytes + bytes > selection.limits.max_bytes do
        {:halt, {:cut, entry["receipt"], "max_bytes", selection, seen}}
      else
        shown = %{
          selection
          | shown: [projected | selection.shown],
            count: selection.count + 1,
            bytes: selection.bytes + bytes
        }

        {:cont, {shown, seen + 1}}
      end
    end
  end

  @doc """
  Builds the batch for a `finish/1`ed `read` and returns the loss counters to
  store as the baseline of its `"next_cursor"`. A `nil` baseline means the
  cursor was not issued by this reader, so counter losses are reported since
  session start.
  """
  @spec build(String.t(), map(), counters() | nil, map()) :: {map(), counters()}
  def build(session_id, read, baseline, extra) do
    counters = loss_counters(read)
    scope = if is_nil(baseline), do: "since_session_start", else: "since_cursor_issued"
    baseline = baseline || %{}

    gaps =
      receipt_gaps(read) ++
        counter_gaps(counters, baseline, scope) ++
        pause_gaps(counters, baseline, scope) ++ unavailable_gaps(read)

    batch =
      Map.merge(
        %{
          "schema" => "insider.live-events/v1",
          "session_id" => session_id,
          "state" => "running",
          "cursor" => read["cursor"],
          "next_cursor" => read["next_cursor"],
          "next_receipt" => read["next_receipt"],
          "truncated" => read["truncated"],
          "truncated_by" => read["truncated_by"],
          "events" => read["events"],
          "gaps" => gaps
        },
        extra
      )

    # A component whose accounting is unavailable keeps its previous baseline,
    # so its later losses are not attributed to the wrong reader position.
    {batch, Map.merge(baseline, counters)}
  end

  @doc """
  The terminal batch a subscriber receives without a final read:
  `"final_read_unavailable"` when the read failed, `"final_read_withheld"`
  when the session was revoked and nothing more may be disclosed. It starts
  where the subscriber's last batch ended (`cursor`) and ends where its
  unsent reads, whose events its view hid, had advanced (`next_cursor`).
  """
  @spec without_read(String.t(), non_neg_integer(), non_neg_integer(), String.t(), map()) ::
          map()
  def without_read(session_id, cursor, next_cursor, reason, extra)
      when reason in ["final_read_unavailable", "final_read_withheld"] do
    Map.merge(
      %{
        "schema" => "insider.live-events/v1",
        "session_id" => session_id,
        "state" => "running",
        "cursor" => cursor,
        "next_cursor" => next_cursor,
        "next_receipt" => nil,
        "truncated" => false,
        "truncated_by" => nil,
        "events" => [],
        "gaps" => [gap(reason, nil, "unknown")]
      },
      extra
    )
  end

  defp receipt_gaps(read) do
    [{"evicted", read["evicted"]}, {"redaction_withheld", read["redaction_withheld"]}]
    |> Enum.filter(fn {_reason, count} -> count > 0 end)
    |> Enum.map(fn {reason, count} -> gap(reason, count, "receipt_range") end)
  end

  defp counter_gaps(counters, baseline, scope) do
    counters
    |> Enum.sort()
    |> Enum.flat_map(fn {reason, count} ->
      case count - Map.get(baseline, reason, 0) do
        _pause when reason in [@pause_starts, @pause_state] ->
          []

        delta when delta > 0 ->
          [gap(reason, delta, scope)]

        _none ->
          []
      end
    end)
  end

  defp pause_gaps(counters, baseline, scope) do
    starts = Map.get(counters, @pause_starts)

    cond do
      is_nil(starts) ->
        []

      Map.get(counters, @pause_state) == 1 ->
        [gap("otel_paused_ongoing", nil, scope)]

      starts > Map.get(baseline, @pause_starts, 0) or Map.get(baseline, @pause_state) == 1 ->
        [gap("otel_paused", nil, scope)]

      true ->
        []
    end
  end

  defp unavailable_gaps(read) do
    @ingress_losses
    |> Enum.sort()
    |> Enum.flat_map(fn {component, _fields} ->
      case read[component] do
        %{"configured" => true, "evidence" => evidence} when evidence != "bounded_status" ->
          [gap(component <> "_accounting_unavailable", nil, "unknown")]

        # A terminal drain that could not count every waiting span.
        %{"evidence" => "bounded_status", "drain_incomplete" => 1} ->
          [gap(component <> "_accounting_unavailable", nil, "unknown")]

        # An earlier segment's accounting was unavailable; the session's
        # cumulative counters carry that uncertainty (`Insider.Live.Archive`).
        %{"accounting_unavailable" => true} ->
          [gap(component <> "_accounting_unavailable", nil, "unknown")]

        _known ->
          []
      end
    end)
  end

  defp loss_counters(read) do
    recorder =
      Map.new(@recorder_losses, fn name ->
        {"recorder_" <> name, Map.get(read["recorder_counters"], name, 0)}
      end)

    recorder =
      case read["otel"] do
        %{"evidence" => "bounded_status", "pauses" => starts, "paused" => paused} ->
          Map.merge(recorder, %{@pause_starts => starts, @pause_state => paused})

        _other ->
          recorder
      end

    Enum.reduce(@ingress_losses, recorder, fn {component, fields}, counters ->
      case read[component] do
        %{"evidence" => "bounded_status"} = evidence ->
          Enum.reduce(fields, counters, fn field, counters ->
            Map.put(counters, component <> "_" <> field, Map.get(evidence, field, 0))
          end)

        _unconfigured_or_unavailable ->
          counters
      end
    end)
  end

  defp gap(reason, count, scope), do: %{"reason" => reason, "count" => count, "scope" => scope}
end
