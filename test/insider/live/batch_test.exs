defmodule Insider.Live.BatchTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Live.Batch
  alias Insider.Live.View

  test "receipt-range losses are exact and counter losses are relative to the issued cursor" do
    first = read(%{"next_cursor" => 4, "evicted" => 2, "redaction_withheld" => 1})
    first = put_in(first, ["recorder_counters", "rate_limited"], 3)
    first = put_in(first, ["logger", "shed"], 5)

    {batch, counters} = Batch.build("live-1", first, nil, %{"lease_remaining_ms" => 9})

    assert batch["gaps"] == [
             gap("evicted", 2, "receipt_range"),
             gap("redaction_withheld", 1, "receipt_range"),
             gap("logger_shed", 5, "since_session_start"),
             gap("recorder_rate_limited", 3, "since_session_start")
           ]

    assert %{"next_cursor" => 4, "state" => "running", "lease_remaining_ms" => 9} = batch

    second = read(%{"cursor" => 4, "next_cursor" => 4})
    second = put_in(second, ["recorder_counters", "rate_limited"], 3)
    second = put_in(second, ["logger", "shed"], 7)

    {batch, _counters} = Batch.build("live-1", second, counters, %{})
    assert batch["gaps"] == [gap("logger_shed", 2, "since_cursor_issued")]
  end

  test "unavailable ingress accounting is an explicit unknown gap and keeps its baseline" do
    baseline = %{"logger_shed" => 4, "recorder_rate_limited" => 0}

    unavailable =
      read(%{"logger" => %{"configured" => true, "evidence" => "malformed_or_unavailable"}})

    {batch, counters} = Batch.build("live-1", unavailable, baseline, %{})

    assert batch["gaps"] == [gap("logger_accounting_unavailable", nil, "unknown")]
    assert counters["logger_shed"] == 4

    recovered = put_in(read(%{}), ["logger", "shed"], 6)
    {batch, _counters} = Batch.build("live-1", recovered, counters, %{})
    assert batch["gaps"] == [gap("logger_shed", 2, "since_cursor_issued")]
  end

  test "a terminal batch without a final read reports why it is incomplete" do
    for reason <- ["final_read_unavailable", "final_read_withheld"] do
      batch =
        Batch.without_read("live-1", 7, 9, reason, %{"state" => "expired", "receipt" => nil})

      assert %{"cursor" => 7, "next_cursor" => 9, "events" => [], "state" => "expired"} = batch
      assert batch["gaps"] == [gap(reason, nil, "unknown")]
    end
  end

  describe "selection" do
    test "with a view, limit counts shown events and the hidden ones up to the next shown" do
      {:ok, view} = View.parse(%{"sources" => ["telemetry"]})
      sources = ["telemetry", "logger", "logger", "telemetry", "logger", "telemetry", "logger"]
      read = read_of(sources, 0, 7)

      {selected, hidden} = select([read], view, limits(2, 1_048_576, 1_000), :rich)

      assert Enum.map(selected["events"], & &1["receipt"]) == [1, 4]
      # Receipt 5 is hidden and consumed; 6 is the first shown event left out.
      assert hidden == %{"sources" => 3}
      assert %{"next_cursor" => 5, "truncated" => true, "truncated_by" => "limit"} = selected
      assert %{"evicted" => 0, "redaction_withheld" => 0} = selected

      {whole, hidden} = select([read], view, limits(3, 1_048_576, 1_000), :rich)
      assert Enum.map(whole["events"], & &1["receipt"]) == [1, 4, 6]
      assert hidden == %{"sources" => 4}
      assert %{"next_cursor" => 7, "truncated" => false, "truncated_by" => nil} = whole
    end

    test "max_bytes counts the canonical JSON of returned events only, and the first is always returned" do
      {:ok, view} = View.parse(%{"sources" => ["telemetry"]})
      read = read_of(["telemetry", "logger", "telemetry", "telemetry"], 0, 4)

      # Bytes are counted on the returned (projected) entries, which the
      # disclosure projection can make larger than the stored ones.
      {all, _hidden} = select([read], view, limits(10, 1_048_576, 1_000), :rich)

      size =
        all["events"] |> Enum.take(2) |> Enum.map(&byte_size(Canonical.encode(&1))) |> Enum.sum()

      # Two returned events fit exactly although the hidden one is scanned.
      {selected, _hidden} = select([read], view, limits(10, size, 1_000), :rich)
      assert Enum.map(selected["events"], & &1["receipt"]) == [1, 3]
      assert %{"next_cursor" => 3, "truncated_by" => "max_bytes"} = selected

      {first, _hidden} = select([read], nil, limits(10, 1, 1_000), :rich)
      assert Enum.map(first["events"], & &1["receipt"]) == [1]
      assert %{"next_cursor" => 1, "truncated" => true, "truncated_by" => "max_bytes"} = first
    end

    test "a read that used its whole scan budget before the limit reports scan_limit" do
      {:ok, view} = View.parse(%{"sources" => ["telemetry"]})
      read = truncated(read_of(["logger", "telemetry", "logger"], 0, 3), "limit")

      {selected, hidden} = select([read], view, limits(50, 65_536, 3), :rich)

      assert Enum.map(selected["events"], & &1["receipt"]) == [2]
      assert hidden == %{"sources" => 2}
      assert %{"next_cursor" => 3, "truncated" => true, "truncated_by" => "scan_limit"} = selected

      # Without a view the read takes `limit` entries, and reaching it is `limit`.
      read = truncated(read_of(["logger", "logger"], 0, 2), "limit")
      {selected, _hidden} = select([read], nil, limits(2, 65_536, 2), :rich)
      assert %{"truncated_by" => "limit"} = selected

      # A page its redaction deadline stopped ends the read.
      read = truncated(read_of(["logger"], 0, 1), "deadline")
      selection = Batch.selection(nil, limits(2, 65_536, 2), :rich)
      assert {:halt, selection} = Batch.add(selection, read)
      assert Batch.wanted(selection) == 0
      {selected, _hidden} = Batch.finish(selection)
      assert %{"truncated_by" => "deadline", "next_cursor" => 1} = selected

      # So does time running out before the next page.
      read = truncated(read_of(["logger"], 0, 1), "max_bytes")
      selection = Batch.selection(nil, limits(2, 65_536, 2), :rich)
      assert {:cont, selection} = Batch.add(selection, read)
      assert Batch.wanted(selection) == 1
      {selected, _hidden} = selection |> Batch.expire() |> Batch.finish()
      assert %{"truncated_by" => "deadline", "next_cursor" => 1, "events" => [_one]} = selected
    end

    test "a cut recounts evicted and withheld receipts for the shorter range" do
      read =
        Map.merge(read_of(["logger", "logger", "logger", "logger"], 0, 7), %{
          "events" =>
            Enum.zip_with([2, 3, 6, 7], read_of(List.duplicate("logger", 4), 0, 4)["events"], fn
              receipt, entry -> %{entry | "receipt" => receipt}
            end),
          "evicted" => 2,
          "redaction_withheld" => 1,
          "withheld_receipts" => [5]
        })

      {selected, _hidden} = select([read], nil, limits(2, 1_048_576, 2), :rich)

      assert Enum.map(selected["events"], & &1["receipt"]) == [2, 3]
      assert %{"next_cursor" => 5, "evicted" => 2, "redaction_withheld" => 1} = selected

      {batch, _counters} = Batch.build("live-1", selected, nil, %{})

      assert Enum.take(batch["gaps"], 2) == [
               gap("evicted", 2, "receipt_range"),
               gap("redaction_withheld", 1, "receipt_range")
             ]

      {selected, _hidden} = select([read], nil, limits(1, 1_048_576, 2), :rich)
      assert %{"next_cursor" => 2, "evicted" => 1, "redaction_withheld" => 0} = selected
    end

    # A continuation read past withheld entries is a
    # new snapshot, so an event admitted between the two reads came back in
    # the current batch, past the newest receipt the read began with.
    test "a later page never moves past the first page's newest receipt" do
      # The first page saw receipts up to 2 and took receipt 1 (withheld).
      first = %{withheld(truncated(read_of(["logger"], 0, 1), "limit")) | "next_receipt" => 2}
      # Receipt 3 was admitted before the second page's own snapshot.
      more = read_of(["logger", "logger"], 1, 3)
      more = %{more | "events" => tl(more["events"]), "redaction_withheld" => 1}
      more = Map.merge(more, %{"withheld_receipts" => [2], "truncated" => false})

      selection = Batch.selection(nil, limits(1, 1_048_576, 2), :rich)
      assert {:cont, selection} = Batch.add(selection, first)
      assert Batch.next_cursor(selection) == 1
      assert Batch.wanted(selection) == 1
      assert {:halt, selection} = Batch.add(selection, more)
      {selected, _hidden} = Batch.finish(selection)

      assert %{"cursor" => 0, "next_cursor" => 2, "next_receipt" => 2, "events" => []} = selected
      assert %{"truncated" => false, "truncated_by" => nil} = selected
      assert %{"redaction_withheld" => 2, "evicted" => 0} = selected

      # The next public read, from 2, is the one that returns receipt 3.
      {next, _hidden} = select([read_of(["logger"], 2, 3)], nil, limits(1, 1_048_576, 1), :rich)
      assert Enum.map(next["events"], & &1["receipt"]) == [3]
    end

    test "a read selected page by page equals the same read selected in one page" do
      sources = Enum.map(1..60, &Enum.at(["telemetry", "logger", "logger", "poller"], rem(&1, 4)))
      whole = read_of(sources, 0, 60)
      {:ok, view} = View.parse(%{"sources" => ["telemetry", "poller"]})

      for page_size <- [1, 7, 25],
          view <- [nil, view],
          {limit, max_bytes, scan} <- [{10, 1_048_576, 60}, {60, 1_048_576, 40}, {60, 2_000, 60}] do
        limits = limits(limit, max_bytes, scan)
        expected = paged(whole, 1_000, view, limits)
        assert expected == paged(whole, page_size, view, limits), inspect({page_size, limits})
        assert {%{"truncated" => true}, _hidden} = expected
      end
    end

    test "the view decides on source, kind, and severity as they are disclosed" do
      token = "ghp_" <> String.duplicate("a1", 12)
      kind = "logger." <> token
      {:ok, view} = View.parse(%{"exclude_kinds" => [kind]})

      read =
        update_in(read_of(["logger", "logger"], 0, 2), ["events"], fn [first, second] ->
          [put_in(first, ["event", "kind"], kind), second]
        end)

      {selected, hidden} = select([read], view, limits(10, 1_048_576, 10), :rich)

      # Masking changed the kind before the view saw it, so nothing matched
      # the excluded raw kind and the returned event carries the masked one.
      assert hidden == %{"exclude_kinds" => 0}
      assert [masked, _second] = selected["events"]
      assert masked["event"]["kind"] == "logger.[REDACTED:provider_key]"
      assert [%{"action" => "mask", "path" => ["key:kind"]}] = masked["redactions"]

      {:ok, view} = View.parse(%{"kinds" => ["logger.*"], "min_severity" => "info"})
      {selected, hidden} = select([read], view, limits(10, 1_048_576, 10), :strict)
      assert hidden == %{"kinds" => 0, "min_severity" => 0}
      assert [_masked, _second] = selected["events"]
    end
  end

  test "every emitted gap reason belongs to the documented vocabulary" do
    reasons = Batch.gap_reasons()

    documented =
      File.read!(Path.expand("../../../docs/live/live-sessions-and-readers.md", __DIR__))

    assert "evicted" in reasons
    assert "telemetry_handler_failures" in reasons
    assert "poller_events_invalid" in reasons

    for reason <- reasons do
      assert documented =~ "`#{reason}`",
             "docs/live/live-sessions-and-readers.md must document gap reason #{reason}"
    end
  end

  test "spans a terminal drain abandoned are a counted gap; an incomplete drain is unknown" do
    otel = fn extra ->
      Map.merge(
        %{
          "configured" => true,
          "evidence" => "bounded_status",
          "abandoned" => 0,
          "drain_incomplete" => 0,
          "invalid" => 0,
          "shed" => 0,
          "pauses" => 0,
          "paused" => 0
        },
        extra
      )
    end

    {batch, _counters} =
      Batch.build("live-1", read(%{"otel" => otel.(%{"abandoned" => 37})}), nil, %{})

    assert %{"reason" => "otel_abandoned", "count" => 37, "scope" => "since_session_start"} in batch[
             "gaps"
           ]

    {batch, _counters} =
      Batch.build("live-1", read(%{"otel" => otel.(%{"drain_incomplete" => 1})}), nil, %{})

    assert %{"reason" => "otel_accounting_unavailable", "count" => nil, "scope" => "unknown"} in batch[
             "gaps"
           ]
  end

  defp read(overrides) do
    Map.merge(
      %{
        "cursor" => 0,
        "next_cursor" => 0,
        "next_receipt" => 0,
        "truncated" => false,
        "events" => [],
        "evicted" => 0,
        "redaction_withheld" => 0,
        "withheld_receipts" => [],
        "recorder_counters" => %{"rate_limited" => 0, "oversized" => 0},
        "logger" => %{
          "configured" => true,
          "evidence" => "bounded_status",
          "shed" => 0,
          "invalid" => 0
        },
        "telemetry" => %{"configured" => false, "evidence" => "not_configured"},
        "poller" => %{"configured" => false, "evidence" => "not_configured"}
      },
      overrides
    )
  end

  # A read of consecutive receipts from `cursor + 1`, one event per source.
  defp read_of(sources, cursor, next_cursor) do
    events =
      sources
      |> Enum.with_index(cursor + 1)
      |> Enum.map(fn {source, receipt} ->
        %{
          "receipt" => receipt,
          "received_at_us" => receipt,
          "priority" => "normal",
          "event" => %{
            "source" => source,
            "kind" => source <> ".event",
            "severity" => "info",
            "attributes" => %{}
          },
          "redactions" => []
        }
      end)

    read(%{
      "cursor" => cursor,
      "next_cursor" => next_cursor,
      "next_receipt" => next_cursor,
      "events" => events
    })
  end

  defp limits(limit, max_bytes, scan),
    do: %{limit: limit, max_bytes: max_bytes, scan_limit: scan}

  # Feeds the given pages in order, as the owner does, until the read ends.
  defp select(pages, view, limits, profile) do
    feed(pages, Batch.selection(view, limits, profile))
  end

  defp feed([page | rest], selection) do
    case Batch.add(selection, page) do
      {:halt, selection} ->
        Batch.finish(selection)

      {:cont, selection} ->
        if rest == [] or Batch.wanted(selection) == 0,
          do: Batch.finish(selection),
          else: feed(rest, selection)
    end
  end

  # Reads `whole` as the owner would read a Recorder holding it: pages of at
  # most `page_size` and the selection's wanted entries from its cursor.
  defp paged(whole, page_size, view, limits) do
    page_through(whole, page_size, 0, Batch.selection(view, limits, :rich))
  end

  defp page_through(whole, page_size, cursor, selection) do
    upper = whole["next_receipt"]
    next = min(cursor + min(page_size, Batch.wanted(selection)), upper)
    events = Enum.filter(whole["events"], &(&1["receipt"] > cursor and &1["receipt"] <= next))
    truncated = next < upper

    page =
      Map.merge(whole, %{
        "cursor" => cursor,
        "next_cursor" => next,
        "events" => events,
        "truncated" => truncated,
        "truncated_by" => if(truncated, do: "limit")
      })

    case Batch.add(selection, page) do
      {:halt, selection} ->
        Batch.finish(selection)

      {:cont, selection} ->
        if Batch.wanted(selection) == 0,
          do: Batch.finish(selection),
          else: page_through(whole, page_size, Batch.next_cursor(selection), selection)
    end
  end

  # A page that more entries follow, read up to a newer snapshot.
  defp truncated(read, reason),
    do: Map.merge(read, %{"truncated" => true, "truncated_by" => reason, "next_receipt" => 10})

  defp withheld(read) do
    Map.merge(read, %{
      "events" => [],
      "redaction_withheld" => length(read["events"]),
      "withheld_receipts" => Enum.map(read["events"], & &1["receipt"])
    })
  end

  defp gap(reason, count, scope), do: %{"reason" => reason, "count" => count, "scope" => scope}
end
