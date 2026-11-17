defmodule Insider.Live.RetentionTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Retention

  @a String.duplicate("a", 32)
  @b String.duplicate("b", 32)
  @c String.duplicate("c", 32)

  defp entry(receipt, trace_id, bytes \\ 0) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "logger",
        "kind" => "logger_message",
        "causality" => %{"trace_id" => trace_id},
        "payload" => %{"message" => String.duplicate("x", bytes)}
      },
      "redactions" => []
    }
  end

  # An Absinthe operation stop of `trace_id`, a mutation unless `type`.
  defp stop(receipt, trace_id, type \\ "mutation") do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "absinthe.execute.operation.stop",
        "causality" => %{"trace_id" => trace_id},
        "attributes" => %{"graphql" => %{"operation_type" => type}}
      },
      "redactions" => []
    }
  end

  defp read(cursor, next, entries, evicted \\ 0),
    do: %{"cursor" => cursor, "next_cursor" => next, "events" => entries, "evicted" => evicted}

  defp receipts(retention, trace_id),
    do: retention |> Retention.entries(trace_id) |> Enum.map(& &1["receipt"])

  test "an explicit pin keeps its trace's backfilled and later events, and only them" do
    retention =
      Retention.new(0)
      |> Retention.pin(@a, [entry(1, @a), entry(3, @a)], 4)
      |> elem(0)
      |> Retention.sweep(read(4, 7, [entry(5, @a), entry(6, @b), entry(7, nil)]))

    assert receipts(retention, @a) == [1, 3, 5]
    assert Retention.entries(retention, @b) == []
    assert Retention.cursor(retention) == 7

    assert %{"pinned" => "explicit", "events" => 3, "lost" => 0, "missed_receipts" => 0} =
             Retention.info(retention, @a)

    assert Retention.info(retention, @b) == nil
    # Pinning again neither duplicates nor loses events.
    {again, nil} = Retention.pin(retention, @a, [entry(3, @a), entry(5, @a)], 7)
    assert receipts(again, @a) == [1, 3, 5]
  end

  test "retain_traces keeps the N most recently active traces and counts the ones it lets go" do
    retention =
      Retention.new(2)
      |> Retention.start(0)
      |> Retention.sweep(read(0, 4, [entry(1, @a), entry(2, @b), entry(3, @a), entry(4, @c)]))

    # b was the least recently active when c arrived.
    assert receipts(retention, @a) == [1, 3]
    assert receipts(retention, @c) == [4]
    assert Retention.info(retention, @b) == nil
    assert %{"pinned" => "auto"} = Retention.info(retention, @a)

    assert %{"evicted_traces" => 1, "dropped_events" => 1, "traces" => 2, "events" => 3} =
             Retention.describe(retention)

    # An explicit pin is never one of the N.
    {pinned, nil} = Retention.pin(retention, @b, [], 4)
    pinned = Retention.sweep(pinned, read(4, 5, [entry(5, @c)]))
    assert %{"pinned" => "explicit"} = Retention.info(pinned, @b)
    assert %{"pinned" => "auto"} = Retention.info(pinned, @a)
  end

  test "receipts the Recorder evicted before the sweep read them count against every pin" do
    {retention, nil} = Retention.pin(Retention.new(0), @a, [entry(1, @a)], 1)
    retention = Retention.sweep(retention, read(1, 40, [entry(40, @a)], 38))

    assert %{"events" => 2, "missed_receipts" => 38} = Retention.info(retention, @a)
    assert Retention.describe(retention)["missed_receipts"] == 38
  end

  test "the byte bound drops auto pins first, then an explicit pin's oldest events, counted" do
    big = div(Retention.bounds()["retained_bytes_max"], 3)

    {retention, nil} = Retention.pin(Retention.new(4), @a, [entry(1, @a, big)], 1)

    retention =
      Retention.sweep(retention, read(1, 3, [entry(2, @b, big), entry(3, @a, big)]))

    # Three entries do not fit: the auto pin b goes first.
    assert Retention.info(retention, @b) == nil
    assert receipts(retention, @a) == [1, 3]

    retention = Retention.sweep(retention, read(3, 5, [entry(4, @a, big), entry(5, @a, big)]))
    assert receipts(retention, @a) == [4, 5]
    assert %{"lost" => 2} = Retention.info(retention, @a)

    assert %{"evicted_traces" => 1, "dropped_events" => 3} = Retention.describe(retention)
    assert Retention.describe(retention)["bytes"] <= Retention.bounds()["retained_bytes_max"]
  end

  test "at most eight explicit pins; the oldest is let go to the retain_traces pool" do
    ids = for n <- 1..9, do: n |> Integer.to_string() |> String.pad_leading(32, "0")

    {retention, released} =
      Enum.reduce(ids, {Retention.new(0), nil}, fn id, {retention, _released} ->
        Retention.pin(retention, id, [], 0)
      end)

    assert released == hd(ids)
    # With retain_traces 0 the released pin is not kept.
    assert Retention.info(retention, hd(ids)) == nil
    assert Enum.count(ids, &Retention.info(retention, &1)) == 8
  end

  test "a hint is offered once per trace" do
    {first?, retention} = Retention.hint(Retention.new(0), @a)
    {again?, retention} = Retention.hint(retention, @a)
    {other?, _retention} = Retention.hint(retention, @b)
    assert {first?, again?, other?} == {true, false, true}
  end

  test "inactive until started or pinned; set_limit keeps the pins" do
    refute Retention.active?(Retention.new(3))
    assert Retention.active?(Retention.start(Retention.new(3), 10))
    assert Retention.cursor(Retention.start(Retention.new(3), 10)) == 10

    retention =
      Retention.new(2)
      |> Retention.start(0)
      |> Retention.sweep(read(0, 2, [entry(1, @a), entry(2, @b)]))
      |> Retention.set_limit(1)

    assert Retention.info(retention, @a) == nil
    assert receipts(retention, @b) == [2]
    refute Retention.active?(Retention.set_limit(Retention.new(2), 0))
  end

  # Two `trace` calls found nothing because no
  # `--retain-traces` was set. A session keeps the traces of mutation
  # requests by default; the events before the operation stop come from a
  # bounded lookback, and what fell out of it is counted.
  describe "mutation traces" do
    test "a mutation's trace is kept with the events before its stop and every later one" do
      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(
          read(0, 6, [entry(1, @a), entry(2, @b), entry(3, @a), stop(4, @b, "query"), stop(5, @a)])
        )
        |> Retention.sweep(read(6, 8, [entry(7, @a), entry(8, @b)]))

      assert receipts(retention, @a) == [1, 3, 5, 7]
      assert Retention.entries(retention, @b) == []
      assert %{"pinned" => "mutation", "lost" => 0} = Retention.info(retention, @a)
      assert %{"mutation_traces" => 1} = Retention.describe(retention)

      assert Retention.active?(
               Retention.start(Retention.keep_mutations(Retention.new(0), true), 0)
             )

      refute Retention.active?(Retention.start(Retention.new(0), 0))
    end

    test "events that fell out of the lookback before the stop are counted as the trace's lost" do
      max = Retention.bounds()["mutation_lookback_max"]
      early = for n <- 1..3, do: entry(n, @a)
      filler = for n <- 4..(max + 3), do: entry(n, @b)

      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, max + 4, early ++ filler ++ [stop(max + 4, @a)]))

      assert receipts(retention, @a) == [max + 4]
      assert %{"lost" => 3} = Retention.info(retention, @a)
    end

    test "at most the bound of mutation traces, the oldest let go and counted; explicit pins stay" do
      max = Retention.bounds()["mutation_traces_max"]
      ids = for n <- 1..(max + 1), do: String.pad_leading(Integer.to_string(n), 32, "0")
      stops = ids |> Enum.with_index(1) |> Enum.map(fn {id, n} -> stop(n, id) end)

      {retention, nil} =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.pin(@c, [entry(1_000, @c)], 0)

      retention = Retention.sweep(retention, read(0, max + 1, stops))

      assert Retention.info(retention, hd(ids)) == nil
      assert %{"pinned" => "mutation"} = Retention.info(retention, List.last(ids))
      assert %{"pinned" => "explicit"} = Retention.info(retention, @c)
      assert %{"mutation_traces" => ^max, "evicted_traces" => 1} = Retention.describe(retention)
    end

    test "an automatic trace that runs a mutation becomes a mutation trace" do
      retention =
        Retention.new(1)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 3, [entry(1, @a), stop(2, @a), entry(3, @b)]))

      assert %{"pinned" => "mutation"} = Retention.info(retention, @a)
      assert %{"pinned" => "auto"} = Retention.info(retention, @b)

      # Within the automatic pool it stays automatic, as --retain-traces kept it.
      kept =
        Retention.new(2)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 3, [entry(1, @a), stop(2, @a), entry(3, @b)]))

      assert %{"pinned" => "auto"} = Retention.info(kept, @a)
    end

    # A trace the automatic pool let go took its events with
    # it, so a later mutation stop kept only itself, with "lost" 0.
    test "a trace the automatic pool lets go goes to the lookback, so its mutation keeps its events" do
      retention =
        Retention.new(1)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 3, [entry(1, @a), entry(2, @b), stop(3, @a)]))

      assert receipts(retention, @a) == [1, 3]
      assert %{"pinned" => "mutation", "lost" => 0} = Retention.info(retention, @a)
    end

    # Default mutation retention must never cost what
    # --retain and --retain-traces keep.
    test "past the byte bound, mutation traces go before automatic traces and explicit pins" do
      big = div(Retention.bounds()["retained_bytes_max"], 3)

      {retention, nil} =
        Retention.new(1)
        |> Retention.keep_mutations(true)
        |> Retention.pin(@c, [entry(1, @c, big)], 1)

      retention =
        Retention.sweep(
          retention,
          read(1, 5, [entry(2, @a, big), stop(3, @a), entry(4, @b, big)])
        )

      assert Retention.info(retention, @a) == nil
      assert %{"pinned" => "auto"} = Retention.info(retention, @b)
      assert %{"pinned" => "explicit", "lost" => 0} = Retention.info(retention, @c)
    end

    # Clearing every loss counter at the bound forgot the
    # recent ones too.
    test "past the loss counters' bound the least recently updated goes, and recent losses stay exact" do
      lookback = Retention.bounds()["mutation_lookback_max"]
      counters = 2_048
      id = &String.pad_leading(Integer.to_string(&1), 32, "0")
      events = for n <- 1..(lookback + counters + 1), do: entry(n, id.(n))

      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, length(events), events))
        |> Retention.sweep(
          read(length(events), length(events) + 2, [
            stop(length(events) + 1, id.(counters)),
            stop(length(events) + 2, id.(1))
          ])
        )

      assert %{"lost" => 1} = Retention.info(retention, id.(counters))
      # The oldest counter went to make room: trace 1's loss is unknown, not
      # silently exact.
      assert %{"lost" => 0} = Retention.info(retention, id.(1))
      assert %{"loss_counters_evicted" => 1} = Retention.describe(retention)
    end
  end
end
