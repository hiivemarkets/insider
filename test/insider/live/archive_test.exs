defmodule Insider.Live.ArchiveTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Archive

  @unbounded 16 * 1_048_576

  defp entry(receipt), do: %{"receipt" => receipt, "event" => %{"kind" => "k"}}

  defp read(cursor, next_cursor, receipts, withheld \\ []) do
    %{
      "cursor" => cursor,
      "next_cursor" => next_cursor,
      "next_receipt" => next_cursor,
      "truncated" => false,
      "events" => Enum.map(receipts, &entry/1),
      "withheld_receipts" => withheld,
      "redaction_withheld" => length(withheld),
      "evicted" => 0
    }
  end

  test "reads entries and withheld receipts in order, counting what it holds no longer" do
    # Receipts 1 and 2 were evicted before the copy; 5 was withheld.
    archive = Archive.new() |> Archive.append(read(0, 7, [3, 4, 6, 7], [5]))

    assert Archive.oldest(archive) == 3

    assert {:ok, all} = Archive.read(archive, 0, 10, @unbounded)
    assert Enum.map(all["events"], & &1["receipt"]) == [3, 4, 6, 7]
    assert %{"next_cursor" => 7, "truncated" => false, "evicted" => 2} = all
    assert %{"redaction_withheld" => 1, "withheld_receipts" => [5]} = all

    # The withheld receipt counts against the entry budget.
    assert {:ok, part} = Archive.read(archive, 3, 2, @unbounded)
    assert %{"next_cursor" => 5, "truncated" => true, "withheld_receipts" => [5]} = part
    assert Enum.map(part["events"], & &1["receipt"]) == [4]

    assert {:ok, %{"events" => [], "next_cursor" => 7}} = Archive.read(archive, 7, 1, @unbounded)
    assert {:error, :invalid_cursor} = Archive.read(archive, 8, 1, @unbounded)
  end

  test "a marker takes the next receipt" do
    archive = Archive.new() |> Archive.append(read(0, 2, [1, 2])) |> Archive.put(&entry/1)
    assert archive.top == 3
    assert {:ok, %{"events" => [%{"receipt" => 3}]}} = Archive.read(archive, 2, 5, @unbounded)
  end

  test "the oldest entries are dropped past the entry bound and read as evicted" do
    max = Archive.bounds()["archived_events_max"]
    archive = Archive.new() |> Archive.append(read(0, max + 2, Enum.to_list(1..(max + 2))))

    assert archive.count == max
    assert Archive.oldest(archive) == 3

    assert {:ok, %{"evicted" => 2, "events" => [%{"receipt" => 3}]}} =
             Archive.read(archive, 0, 1, @unbounded)

    assert Archive.oldest(Archive.new()) == nil
  end

  test "withheld receipts share the entry and byte bounds across repeated appends" do
    max = Archive.bounds()["archived_events_max"]

    archive =
      Enum.reduce(0..9, Archive.new(), fn chunk, archive ->
        first = chunk * 1_000

        Archive.append(
          archive,
          read(first, first + 1_000, [], Enum.to_list((first + 1)..(first + 1_000)))
        )
      end)

    assert archive.count == max
    assert length(archive.withheld) == max
    assert archive.bytes == Enum.reduce(archive.withheld, 0, &(:erlang.external_size(&1) + &2))
    assert hd(archive.withheld) == 10_000 - max + 1

    # Mixed: the oldest evidence goes first, whichever kind it is.
    mixed =
      Archive.new()
      |> Archive.append(read(0, 3, [1, 3], [2]))
      |> Archive.append(read(3, max + 1, Enum.to_list(4..(max + 1))))

    assert mixed.count == max
    assert Archive.oldest(mixed) == 2

    assert {:ok, %{"evicted" => 1, "withheld_receipts" => [2]}} =
             Archive.read(mixed, 0, 2, @unbounded)
  end

  test "a copy that could not read a segment's end is reported by every read that reaches it" do
    # The ninth boundary dropped the first.
    many =
      Enum.reduce(1..10, Archive.new(), fn receipt, archive ->
        archive |> Archive.append(read(receipt - 1, receipt, [receipt])) |> Archive.unread()
      end)

    assert many.unread == [
             {10, 10, 1},
             {9, 9, 1},
             {8, 8, 1},
             {7, 7, 1},
             {6, 6, 1},
             {5, 5, 1},
             {4, 4, 1},
             {1, 3, 3}
           ]

    # Every boundary became its own gap. A read gets
    # at most one gap, carrying how many boundaries it reached.
    gap = fn boundaries ->
      [
        %{
          "reason" => "segment_end_unread",
          "count" => nil,
          "scope" => "unknown",
          "boundaries" => boundaries
        }
      ]
    end

    early = %{"cursor" => 0, "next_cursor" => 2, "truncated" => true}
    assert Archive.unread_gaps(many, early) == gap.(3)

    whole = %{"cursor" => 0, "next_cursor" => 10, "truncated" => false}
    assert Archive.unread_gaps(many, whole) == gap.(10)

    # 100,000 boundaries still make one gap.
    huge =
      Enum.reduce(1..100_000, Archive.new(), fn receipt, archive ->
        archive |> Archive.append(read(receipt - 1, receipt, [])) |> Archive.unread()
      end)

    assert [_, _, _, _, _, _, _, {1, 99_993, 99_993}] = huge.unread

    assert Archive.unread_gaps(huge, %{"cursor" => 0, "next_cursor" => 2, "truncated" => true}) ==
             gap.(99_993)

    # Boundaries outlive the archive's own eviction of the history they mark.
    evicted =
      Archive.append(
        many,
        read(
          10,
          10 + Archive.bounds()["archived_events_max"],
          Enum.to_list(11..(10 + Archive.bounds()["archived_events_max"]))
        )
      )

    assert Archive.oldest(evicted) == 11
    assert Archive.unread_gaps(evicted, whole) == gap.(10)

    archive = Archive.new() |> Archive.append(read(0, 3, [1, 2, 3])) |> Archive.unread()
    assert archive.unread == [{3, 3, 1}]

    for {batch, expected} <- [
          {%{"cursor" => 0, "next_cursor" => 3, "truncated" => false}, gap.(1)},
          {%{"cursor" => 3, "next_cursor" => 5, "truncated" => false}, gap.(1)},
          {%{"cursor" => 0, "next_cursor" => 2, "truncated" => true}, []},
          {%{"cursor" => 0, "next_cursor" => 3, "truncated" => true}, []},
          {%{"cursor" => 4, "next_cursor" => 5, "truncated" => false}, []}
        ],
        do: assert(Archive.unread_gaps(archive, batch) == expected, inspect(batch))

    assert Archive.unread_gaps(nil, %{}) == []
    assert "segment_end_unread" in Insider.Live.Batch.gap_reasons()
  end

  # A final status that could not be read became
  # the earlier bounded counters, so no read reported the uncertainty.
  test "unavailable accounting persists through counters, the seal merge, and later segments" do
    bounded = %{"evidence" => "bounded_status", "configured" => true, "shed" => 3}
    unavailable = %{"configured" => true, "evidence" => "malformed_or_unavailable"}
    bulk = Archive.counters(%{"recorder_counters" => %{}, "telemetry" => bounded})
    final = Archive.counters(%{"recorder_counters" => %{}, "telemetry" => unavailable})

    assert %{"accounting_unavailable" => true} = final["telemetry"]
    merged = Archive.max_counters(bulk, final)
    assert %{"shed" => 3, "accounting_unavailable" => true} = merged["telemetry"]

    # A healthy later segment keeps the flag; so does a segment without it.
    healthy =
      Map.merge(read(0, 1, [1]), %{
        "recorder_counters" => %{},
        "telemetry" => %{bounded | "shed" => 1}
      })

    carried = Archive.carry(healthy, merged)
    assert %{"shed" => 4, "accounting_unavailable" => true} = carried["telemetry"]
    assert Archive.counters(carried)["telemetry"]["accounting_unavailable"]

    removed =
      Map.merge(read(0, 1, [1]), %{
        "recorder_counters" => %{},
        "telemetry" => %{"configured" => false}
      })

    assert Archive.carry(removed, merged)["telemetry"]["accounting_unavailable"]
  end

  test "counters keep a component's losses after it stops running" do
    carried = %{
      "recorder_counters" => %{"rate_limited" => 1},
      "telemetry" => %{"evidence" => "bounded_status", "shed" => 7}
    }

    removed =
      Map.merge(read(0, 1, [1]), %{
        "recorder_counters" => %{},
        "telemetry" => %{"configured" => false}
      })

    assert Archive.carry(removed, carried)["telemetry"]["shed"] == 7
    assert Archive.counters(Archive.carry(removed, carried))["telemetry"]["shed"] == 7

    unavailable =
      Map.put(removed, "telemetry", %{
        "configured" => true,
        "evidence" => "malformed_or_unavailable"
      })

    assert Archive.carry(unavailable, carried)["telemetry"]["evidence"] ==
             "malformed_or_unavailable"

    assert Archive.max_counters(
             %{
               "recorder_counters" => %{"a" => 2},
               "telemetry" => %{"evidence" => "bounded_status", "shed" => 9}
             },
             %{
               "recorder_counters" => %{"a" => 3},
               "telemetry" => %{"evidence" => "bounded_status", "shed" => 7}
             }
           ) == %{
             "recorder_counters" => %{"a" => 3},
             "telemetry" => %{"evidence" => "bounded_status", "shed" => 9}
           }
  end

  test "a running segment continues an archive part and keeps its counters" do
    archive = Archive.new() |> Archive.append(read(0, 3, [1, 2, 3]))
    live = Map.merge(read(3, 5, [4, 5]), %{"recorder_counters" => %{"rate_limited" => 2}})

    {:ok, part} = Archive.read(archive, 1, 4, @unbounded)
    joined = Archive.join(part, live, 2)
    assert Enum.map(joined["events"], & &1["receipt"]) == [2, 3, 4, 5]

    assert %{"cursor" => 1, "next_cursor" => 5, "recorder_counters" => %{"rate_limited" => 2}} =
             joined

    # A part that used the budget keeps its cursor and reports what waits.
    {:ok, part} = Archive.read(archive, 0, 2, @unbounded)
    joined = Archive.join(part, live, 0)
    assert %{"next_cursor" => 2, "next_receipt" => 5, "truncated" => true} = joined
    assert Enum.map(joined["events"], & &1["receipt"]) == [1, 2]

    {:ok, part} = Archive.read(archive, 0, 3, @unbounded)
    assert %{"next_cursor" => 3, "truncated" => true} = Archive.join(part, live, 0)
  end

  test "shift and carry make a segment's read part of the session's" do
    segment =
      Map.merge(read(1, 2, [2], [1]), %{
        "recorder_counters" => %{"rate_limited" => 1},
        "telemetry" => %{"evidence" => "bounded_status", "shed" => 2, "state" => "running"},
        "logger" => %{"configured" => false}
      })

    shifted = Archive.shift(segment, 10)
    assert %{"cursor" => 11, "next_cursor" => 12, "withheld_receipts" => [11]} = shifted
    assert [%{"receipt" => 12}] = shifted["events"]
    assert Archive.shift(segment, 0) == segment

    counters = Archive.counters(segment)

    assert counters == %{
             "recorder_counters" => %{"rate_limited" => 1},
             "telemetry" => %{"evidence" => "bounded_status", "shed" => 2}
           }

    carried = Archive.carry(segment, counters)
    assert carried["recorder_counters"] == %{"rate_limited" => 2}
    assert carried["telemetry"]["shed"] == 4
    assert carried["logger"] == %{"configured" => false}
    assert Archive.carry(segment, %{}) == segment

    assert {:ok, retained} =
             Archive.read_retained(
               Archive.new() |> Archive.append(segment),
               :latest,
               5,
               @unbounded,
               counters
             )

    assert %{"cursor" => 2, "events" => [], "recorder_counters" => %{"rate_limited" => 1}} =
             retained
  end

  # Archive pages once took 100 rich entries (750 KB)
  # under a 128 KiB page bound, which bound only Recorder pages.
  defp rich(receipt),
    do: %{"receipt" => receipt, "event" => %{"message" => String.duplicate("x", 1_000)}}

  defp rich_archive(receipts, withheld \\ []) do
    read =
      Map.merge(read(0, Enum.max(receipts ++ withheld), [], withheld), %{
        "events" => Enum.map(receipts, &rich/1)
      })

    Archive.append(Archive.new(), read)
  end

  test "an archive page stops at its byte bound by external term size, and always takes one" do
    archive = rich_archive(Enum.to_list(1..10))
    size = :erlang.external_size(rich(1))

    assert {:ok, page} = Archive.read(archive, 0, 100, 3 * size)
    assert Enum.map(page["events"], & &1["receipt"]) == [1, 2, 3]
    assert %{"next_cursor" => 3, "truncated" => true, "evicted" => 0} = page
    assert Archive.page_bytes(page) == 3 * size

    # One byte short of three entries takes two; one byte takes the first.
    assert {:ok, %{"next_cursor" => 2}} = Archive.read(archive, 0, 100, 3 * size - 1)
    assert {:ok, %{"next_cursor" => 1, "truncated" => true}} = Archive.read(archive, 0, 100, 1)

    # Reading on from each page's cursor returns every entry once.
    receipts =
      Stream.unfold(0, fn
        10 ->
          nil

        cursor ->
          {:ok, page} = Archive.read(archive, cursor, 100, 2 * size)
          {Enum.map(page["events"], & &1["receipt"]), page["next_cursor"]}
      end)
      |> Enum.concat()

    assert receipts == Enum.to_list(1..10)
  end

  test "withheld receipts cost no page bytes and keep their accounting under the byte bound" do
    archive = rich_archive([1, 3, 4], [2])
    size = :erlang.external_size(rich(1))

    assert {:ok, page} = Archive.read(archive, 0, 100, size)
    assert Enum.map(page["events"], & &1["receipt"]) == [1]
    assert %{"withheld_receipts" => [2], "redaction_withheld" => 1} = page
    assert %{"next_cursor" => 2, "truncated" => true, "evicted" => 0} = page

    assert {:ok, retained} = Archive.read_retained(archive, 2, 100, size, %{})
    assert Enum.map(retained["events"], & &1["receipt"]) == [3]
    assert %{"next_cursor" => 3, "truncated" => true} = retained
  end

  test "a mixed archive and live page shares one entry and byte budget" do
    archive = rich_archive([1, 2])
    size = :erlang.external_size(rich(1))

    # The archive part used two entries and two entries' bytes.
    {:ok, part} = Archive.read(archive, 0, 10, 5 * size)
    assert Archive.live_budget(part, 10, 5 * size) == {8, 3 * size}

    # A part cut by its byte bound leaves nothing for the live part.
    {:ok, part} = Archive.read(archive, 0, 10, size)
    assert Archive.live_budget(part, 10, size) == {0, 0}

    # A part that used the whole byte budget exactly leaves nothing either.
    {:ok, part} = Archive.read(archive, 0, 10, 2 * size)
    assert %{"truncated" => false} = part
    assert Archive.live_budget(part, 10, 2 * size) == {0, 0}

    # An empty part leaves the whole budget.
    {:ok, part} = Archive.read(archive, 2, 10, size)
    assert Archive.live_budget(part, 10, size) == {10, size}
  end
end
