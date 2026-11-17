defmodule Insider.Live.TimelineScan do
  @moduledoc false

  # Reads a session's retained events for `trace` and `timeline`, newest
  # first, within a time budget. A request or trace an agent asks about is
  # usually recent, and a long session can hold more events than one budget
  # reads. Read from the oldest receipt, the budget can run out before it
  # reaches the request.
  #
  # The scan fixes its upper receipt with one snapshot read (cursor 0, upto
  # 0), then reads pages of `@page` receipts downwards: each page is read
  # forward from its lower cursor with `events_since/3` (so the disclosure
  # boundary applies) and `"upto"` its upper receipt, so events and
  # receipt-range losses after the snapshot are left out. Cumulative losses
  # without a receipt are reported as the last read observed them. It stops at its floor (receipt 0, or the cursor or mark a read is since), at the budget, or when a read
  # fails or makes no progress; the receipts below the upper one it did not
  # read are `unread`, which the timeline reports as a `scan_truncated` gap.

  alias Insider.Live.Timeline
  alias Insider.Live.View

  @page 500
  @read %{"limit" => 500, "max_bytes" => 1_048_576, "scan_limit" => 1_000}
  @read_floor_ms 250

  @type reader :: (String.t(), non_neg_integer() | String.t(), map() ->
                     {:ok, map()} | {:error, map()})

  @doc "The receipts each page covers."
  @spec page() :: pos_integer()
  def page, do: @page

  @doc """
  Scans `session_id` newest first through `reader` (`events_since/3`) for at
  most `budget_ms`, down to receipt `floor` (option `:floor`, default 0: the
  session start; a read since a cursor or a pairing mark reads only the
  receipts after it), timed by `:now` (milliseconds). Returns
  `{:ok, scan, ending}` (`ending` is `nil` when it reached the floor, else
  `"deadline"`, `"no_progress"`, or a read's error code), or the snapshot
  read's error.

  The snapshot is a read from cursor 0 up to receipt 0: it returns no event
  but the newest receipt and the session's cumulative losses since its
  start, which are kept even when the session has no receipt. Every page is
  read with `"upto"` its upper receipt, so its events and receipt-range
  losses cover exactly that page. Cumulative losses are reported as the
  last read observed them, which can include losses during the scan.
  """
  @spec run(String.t(), reader(), pos_integer(), keyword()) ::
          {:ok, map(), String.t() | nil} | {:error, map()}
  def run(session_id, reader, budget_ms, options \\ []) do
    now = Keyword.get(options, :now, &now/0)
    clock = %{now: now, deadline: now.() + budget_ms}

    with {:ok, %{"next_receipt" => top} = snapshot} <-
           reader.(session_id, 0, %{"limit" => 1, "upto" => 0}) do
      floor = min(Keyword.get(options, :floor, 0), top)

      scan =
        session_id
        |> Timeline.scan()
        |> Timeline.add(%{snapshot | "events" => [], "next_cursor" => 0})
        |> Map.merge(%{upper: top, unread: top - floor, reads: 0, first: nil, last: nil})

      pages(session_id, reader, {floor, top}, scan, clock)
    end
  end

  defp pages(_session_id, _reader, {floor, floor}, scan, _clock), do: {:ok, scan, nil}

  defp pages(session_id, reader, {floor, high}, scan, clock) do
    low = max(high - @page, floor)

    case read_page(session_id, reader, low, high, scan, clock) do
      {:ok, scan} -> pages(session_id, reader, {floor, low}, scan, clock)
      {:stop, scan, ending} -> {:ok, scan, ending}
    end
  end

  # Reads receipts `low + 1 .. high` forward, bounded by `"upto"`, so
  # receipts that arrived after the snapshot belong to no page.
  defp read_page(session_id, reader, cursor, high, scan, clock) do
    if clock.deadline - clock.now.() < @read_floor_ms do
      {:stop, scan, "deadline"}
    else
      case reader.(session_id, cursor, Map.put(@read, "upto", high)) do
        {:ok, %{"next_cursor" => next} = batch} ->
          scan = Timeline.add(scan, batch)
          scan = %{scan | unread: scan.unread - max(next - cursor, 0)}
          # What the reader's view hid, page by page (`Insider.Live.View`).
          scan = Map.put(scan, :view_hidden, View.add(scan[:view_hidden], view_counts(batch)))

          cond do
            next >= high -> {:ok, scan}
            next <= cursor -> {:stop, scan, "no_progress"}
            true -> read_page(session_id, reader, next, high, scan, clock)
          end

        {:error, %{"code" => code}} ->
          {:stop, scan, code}
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp view_counts(%{"filtered" => %{"view" => %{} = counts}}), do: counts
  defp view_counts(_batch), do: %{}

  @doc """
  The owner request one scan read makes: an `events_since` read whose
  cumulative losses are totals since the session started, whatever cursor
  it starts at, and which issues no cursor baseline. A page cursor another
  reader issued earlier would otherwise return losses since that reader's
  baseline, which cannot be compared with a total.
  """
  @spec request(String.t(), non_neg_integer(), map()) :: tuple()
  def request(session_id, cursor, options),
    do: {:events_since, session_id, cursor, options, :cumulative}
end
