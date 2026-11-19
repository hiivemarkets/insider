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

  # A failed event of `trace_id`: a Logger error.
  defp failed(receipt, trace_id) do
    receipt |> entry(trace_id) |> put_in(["event", "severity"], "error")
  end

  # An OpenTelemetry span of `trace_id` that took `ms` milliseconds.
  defp span(receipt, trace_id, ms) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "info",
        "causality" => %{"trace_id" => trace_id},
        "attributes" => %{"duration_us" => ms * 1_000}
      },
      "redactions" => []
    }
  end

  # A Telemetry stop of `trace_id` whose `duration` measurement (native
  # units, as recorded) is `ms` milliseconds.
  defp telemetry_stop(receipt, trace_id, ms) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "phoenix.endpoint.stop",
        "severity" => "info",
        "causality" => %{"trace_id" => trace_id},
        "attributes" => %{
          "measurements" => %{"duration" => System.convert_time_unit(ms, :millisecond, :native)}
        }
      },
      "redactions" => []
    }
  end

  defp notable(limit \\ 0),
    do: limit |> Retention.new() |> Retention.keep_notable(true) |> Retention.start(0)

  defp id(n), do: String.pad_leading(Integer.to_string(n), 32, "0")

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

      # With room in the pool it comes back automatic, with its events;
      # when the pool lets it go it becomes a mutation trace.
      assert receipts(retention, @a) == [1, 3]
      assert %{"pinned" => "auto", "lost" => 0} = Retention.info(retention, @a)
      released = Retention.set_limit(retention, 0)
      assert receipts(released, @a) == [1, 3]
      assert %{"pinned" => "mutation", "lost" => 0} = Retention.info(released, @a)
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

  # A failing request's trace came back empty after a minute of normal
  # traffic evicted it: only mutation traces were kept by default. Failed
  # and slow traces are kept too, each kind in its own pool.
  describe "failed and slow traces" do
    test "a failed trace is kept with the events before its error and every later one" do
      retention =
        notable()
        |> Retention.sweep(read(0, 4, [entry(1, @a), entry(2, @b), entry(3, @a), failed(4, @a)]))
        |> Retention.sweep(read(4, 6, [entry(5, @a), entry(6, @b)]))

      assert receipts(retention, @a) == [1, 3, 4, 5]
      assert Retention.entries(retention, @b) == []
      assert %{"pinned" => "failed", "lost" => 0} = Retention.info(retention, @a)

      assert %{"failed_traces" => 1, "slow_traces" => 0, "keep_failed_and_slow" => true} =
               Retention.describe(retention)

      critical =
        Retention.sweep(
          notable(),
          read(0, 1, [put_in(entry(1, @c), ["event", "severity"], "critical")])
        )

      assert %{"pinned" => "failed"} = Retention.info(critical, @c)
    end

    test "a trace with a span or Telemetry duration at the threshold is kept as slow, a faster one is not" do
      threshold = Retention.bounds()["slow_trace_ms"]
      assert threshold == 500

      retention =
        notable()
        |> Retention.sweep(
          read(0, 6, [
            entry(1, @a),
            span(2, @a, threshold),
            entry(3, @b),
            telemetry_stop(4, @b, threshold + 1),
            span(5, @c, threshold - 1),
            telemetry_stop(6, @c, threshold - 1)
          ])
        )

      assert receipts(retention, @a) == [1, 2]
      assert %{"pinned" => "slow"} = Retention.info(retention, @a)
      assert receipts(retention, @b) == [3, 4]
      assert %{"pinned" => "slow"} = Retention.info(retention, @b)
      assert Retention.info(retention, @c) == nil
      assert %{"slow_traces" => 2} = Retention.describe(retention)
    end

    test "without keep_notable neither failed nor slow traces are kept" do
      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 2, [failed(1, @a), span(2, @b, 1_000)]))

      assert Retention.info(retention, @a) == nil
      assert Retention.info(retention, @b) == nil
      refute Retention.describe(retention)["keep_failed_and_slow"]

      assert Retention.active?(notable())
      off = notable() |> Retention.keep_notable(false)
      refute Retention.active?(off)
    end

    test "a burst of failed traces past their pool never lets a mutation trace go" do
      max = Retention.bounds()["failed_traces_max"]
      failures = for n <- 1..(max + 4), do: failed(n + 1, id(n))

      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.keep_notable(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 1, [stop(1, @a)]))
        |> Retention.sweep(read(1, max + 5, failures))

      assert %{"pinned" => "mutation"} = Retention.info(retention, @a)
      assert Retention.info(retention, id(1)) == nil
      assert %{"pinned" => "failed"} = Retention.info(retention, id(max + 4))

      assert %{"failed_traces" => ^max, "mutation_traces" => 1, "evicted_traces" => 4} =
               Retention.describe(retention)
    end

    test "a kept trace moves to the stronger reason: slow, then failed, then mutation" do
      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.keep_notable(true)
        |> Retention.start(0)
        |> Retention.sweep(read(0, 1, [span(1, @a, 900)]))

      assert %{"pinned" => "slow"} = Retention.info(retention, @a)
      retention = Retention.sweep(retention, read(1, 2, [failed(2, @a)]))
      assert %{"pinned" => "failed"} = Retention.info(retention, @a)
      retention = Retention.sweep(retention, read(2, 3, [stop(3, @a)]))
      assert %{"pinned" => "mutation"} = Retention.info(retention, @a)
      # A weaker reason later never demotes it.
      retention = Retention.sweep(retention, read(3, 4, [span(4, @a, 900)]))
      assert %{"pinned" => "mutation", "events" => 4} = Retention.info(retention, @a)
      assert %{"slow_traces" => 0, "failed_traces" => 0} = Retention.describe(retention)
    end

    # A trace whose first event was an error went straight to the
    # 16-trace failed pool, even with room in --retain-traces: the 17th
    # let the first go. Default retention must never cost what
    # retain_traces keeps.
    test "with retain_traces, a trace whose first event fails or is slow joins the automatic pool" do
      max = Retention.bounds()["failed_traces_max"]
      firsts = [&failed(&1, id(&1)), &span(&1, id(&1), 900)]

      for first <- firsts do
        events = for n <- 1..(max + 1), do: first.(n)
        retention = notable(64) |> Retention.sweep(read(0, max + 1, events))

        assert %{"pinned" => "auto"} = Retention.info(retention, id(1))
        assert %{"traces" => traces, "evicted_traces" => 0} = Retention.describe(retention)
        assert traces == max + 1

        # When the pool lets them go they take their reason, within its bound.
        released = Retention.set_limit(retention, 0)
        assert Retention.info(released, id(1)) == nil
        assert %{"pinned" => reason} = Retention.info(released, id(max + 1))
        assert reason in ["failed", "slow"]
        assert %{"traces" => ^max, "evicted_traces" => 1} = Retention.describe(released)
      end
    end

    test "an automatic trace that fails stays automatic until the pool lets it go" do
      retention =
        notable(1) |> Retention.sweep(read(0, 3, [entry(1, @a), failed(2, @a), entry(3, @b)]))

      assert %{"pinned" => "failed"} = Retention.info(retention, @a)
      assert %{"pinned" => "auto"} = Retention.info(retention, @b)

      kept =
        notable(2) |> Retention.sweep(read(0, 3, [entry(1, @a), failed(2, @a), entry(3, @b)]))

      assert %{"pinned" => "auto"} = Retention.info(kept, @a)
    end

    test "past the byte bound, slow traces go first, then failed, then mutation traces" do
      big = div(Retention.bounds()["retained_bytes_max"], 3)

      retention =
        Retention.new(0)
        |> Retention.keep_mutations(true)
        |> Retention.keep_notable(true)
        |> Retention.start(0)
        |> Retention.sweep(
          read(0, 6, [
            entry(1, @a, big),
            stop(2, @a),
            entry(3, @b, big),
            failed(4, @b),
            entry(5, @c, big),
            span(6, @c, 900)
          ])
        )

      assert Retention.info(retention, @c) == nil
      assert %{"pinned" => "failed"} = Retention.info(retention, @b)
      assert %{"pinned" => "mutation"} = Retention.info(retention, @a)

      retention = Retention.sweep(retention, read(6, 8, [entry(7, @c, big), failed(8, @c)]))
      # The older failed trace goes before the mutation trace.
      assert Retention.info(retention, @b) == nil
      assert %{"pinned" => "failed"} = Retention.info(retention, @c)
      assert %{"pinned" => "mutation"} = Retention.info(retention, @a)
    end
  end
end
