defmodule Insider.Collector.SummaryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Insider.Collector.Gate
  alias Insider.Collector.Logger.Template
  alias Insider.Collector.Summary

  test "every duration falls in a bucket whose upper bound is within 1/16 above it" do
    values =
      Enum.to_list(0..2_000) ++
        Enum.map(1..2_000, &(&1 * 7_919)) ++ [1 <<< 39, (1 <<< 40) - 1]

    for value <- values do
      upper = Summary.upper_bound(Summary.bucket(value))
      assert upper >= value
      assert upper - value <= div(value, 16), "#{value} -> #{upper}"
    end

    # Buckets are ordered and the last one takes everything larger.
    assert Summary.bucket(31) < Summary.bucket(32)
    assert Summary.bucket(1 <<< 40) == Summary.buckets() - 1
    assert Summary.bucket(1 <<< 50) == Summary.buckets() - 1
  end

  test "an interval reports count, errors, and p50/p95/max of its own samples only" do
    slot = new_slot()

    for ms <- 1..100, do: Summary.add(slot, rem(ms, 25) == 0, {:duration, ms * 1_000})
    Summary.add(slot, false, nil)

    assert Summary.take(slot) == %{
             "count" => 101,
             "errors" => 4,
             "timed" => 100,
             "duration_measurements" => ["duration"],
             "duration_p50_us" => 51_199,
             "duration_p95_us" => 98_303,
             "duration_max_us" => 100_000,
             "exemplars_lost" => 0
           }

    # The next interval sees only what was added after the take.
    assert Summary.take(slot) == nil

    for us <- [10, 20, 30], do: Summary.add(slot, false, {:total_time, us})

    assert %{
             "count" => 3,
             "errors" => 0,
             "duration_measurements" => ["total_time"],
             "duration_p50_us" => 20,
             "duration_p95_us" => 30,
             "duration_max_us" => 30
           } = Summary.take(slot)
  end

  test "an interval with only untimed samples has no percentiles" do
    slot = new_slot()
    Summary.add(slot, true, nil)

    assert %{"count" => 1, "errors" => 1, "timed" => 0, "duration_p50_us" => nil} =
             stats = Summary.take(slot)

    assert stats["duration_max_us"] == nil
    assert stats["duration_measurements"] == []
  end

  test "percentiles never exceed the interval maximum" do
    histogram = List.duplicate(0, Summary.buckets()) |> List.replace_at(Summary.bucket(1_000), 1)
    assert Summary.percentile(histogram, 1, 95, 1_000) == 1_000
    assert Summary.upper_bound(Summary.bucket(1_000)) > 1_000
    # A histogram shorter than its total falls back to the maximum.
    assert Summary.percentile(List.duplicate(0, 3), 5, 50, 77) == 77
  end

  test "a slot whose table is gone loses samples without failing" do
    table = :ets.new(:summary_test, [:set, :public])
    slot = Summary.new_slot(table, 0)
    :ets.delete(table)
    assert Summary.add(slot, true, {:duration, 5}) == :lost
    assert Summary.take(slot) == nil
  end

  test "concurrent samples land in one interval with all their fields" do
    slot = new_slot()
    writers = 8
    per_writer = 30_000
    parent = self()

    pids =
      for writer <- 1..writers do
        spawn_link(fn ->
          value = writer * 1_000

          for sample <- 1..per_writer do
            timed = if rem(sample, 2) == 0, do: {:duration, value}
            Summary.add(slot, rem(sample, 3) == 0, timed)
          end

          send(parent, {:written, self()})
        end)
      end

    intervals = take_while_writing(slot, MapSet.new(pids), [])
    values = for writer <- 1..writers, do: writer * 1_000
    assert [_first, _second | _rest] = intervals

    for stats <- intervals do
      assert stats["errors"] <= stats["count"], inspect(stats)
      assert stats["timed"] <= stats["count"], inspect(stats)

      if stats["timed"] > 0 do
        assert stats["duration_max_us"] in values, inspect(stats)
        assert 1_000 <= stats["duration_p50_us"], inspect(stats)
        assert stats["duration_p50_us"] <= stats["duration_p95_us"], inspect(stats)
        assert stats["duration_p95_us"] <= stats["duration_max_us"], inspect(stats)
      else
        assert stats["duration_max_us"] == nil
      end
    end

    total = fn field -> intervals |> Enum.map(& &1[field]) |> Enum.sum() end
    assert total.("count") == writers * per_writer
    assert total.("errors") == writers * div(per_writer, 3)
    assert total.("timed") == writers * div(per_writer, 2)
    assert Enum.max(Enum.map(intervals, &(&1["duration_max_us"] || 0))) == writers * 1_000
  end

  defp new_slot do
    :summary_test
    |> :ets.new([:set, :public, write_concurrency: true])
    |> Summary.new_slot(0)
  end

  # Takes intervals while the writers run, then one last interval after all
  # of them finished.
  defp take_while_writing(slot, running, intervals) do
    intervals = add_interval(intervals, Summary.take(slot))

    receive do
      {:written, pid} -> take_while_writing(slot, MapSet.delete(running, pid), intervals)
    after
      0 ->
        if MapSet.size(running) == 0,
          do: Enum.reverse(add_interval(intervals, Summary.take(slot))),
          else: take_while_writing(slot, running, intervals)
    end
  end

  defp add_interval(intervals, nil), do: intervals
  defp add_interval(intervals, stats), do: [stats | intervals]

  test "exemplar candidates are the first error and samples in the running maximum's bucket, capped" do
    slot = new_slot()

    # The first sample sets the maximum; one in a lower bucket is not slow.
    assert {:exemplar, {0, 1_000, false}} = Summary.add(slot, false, {:duration, 1_000})
    assert :ok = Summary.add(slot, false, {:duration, 500})
    assert {:exemplar, {0, 2_000, false}} = Summary.add(slot, false, {:duration, 2_000})

    # Only the interval's first error is a candidate for being one.
    assert {:exemplar, {0, 100, true}} = Summary.add(slot, true, {:duration, 100})
    assert :ok = Summary.add(slot, true, {:duration, 100})
    assert :ok = Summary.add(slot, true, nil)

    # The first four samples of the top bucket are candidates, no more.
    repeats = for _n <- 1..40, do: Summary.add(slot, false, {:duration, 2_000})
    assert Enum.count(repeats, &match?({:exemplar, _candidate}, &1)) == 3
    assert Enum.count(repeats, &(&1 == :ok)) == 37

    # A sample in a new top bucket is one again.
    assert {:exemplar, {0, 9_000, false}} = Summary.add(slot, false, {:duration, 9_000})

    assert Summary.generation(slot) == 0
    assert %{"count" => 47, "errors" => 3} = Summary.take(slot)
    assert Summary.generation(slot) == 1

    # The next interval starts again: an untimed first error has no duration.
    assert {:exemplar, {1, nil, true}} = Summary.add(slot, true, nil)
  end

  test "Logger bursts count summarised messages per template, call site and level and name each interval's first" do
    site = fn line -> %{mfa: {SummaryTestCheckout, :run, 2}, line: line, domain: [:elixir]} end
    message = fn level, meta -> %{level: level, msg: {:string, "checkout failed"}, meta: meta} end
    key = burst_gate()

    burst = {:burst, 0, "checkout failed", SummaryTestCheckout, :run, 2, 94, :error}
    assert Gate.logger(key, message.(:error, site.(94))) == {:exemplar, burst}
    assert Gate.logger(key, message.(:error, site.(94))) == :drop
    assert Gate.logger(key, message.(:error, site.(94))) == :drop
    # Another line or level is another burst; a report, another module, or a
    # message below the level floor is decided as before.
    assert {:exemplar, {:burst, 0, _t, _m, _f, _a, 95, :error}} =
             Gate.logger(key, message.(:error, site.(95)))

    assert {:exemplar, {:burst, 0, _t, _m, _f, _a, 94, :warning}} =
             Gate.logger(key, message.(:warning, site.(94)))

    report = %{level: :error, msg: {:report, %{a: 1}}, meta: site.(94)}
    assert Gate.logger(key, report) == :record
    assert Gate.logger(key, message.(:error, %{mfa: {Other, :run, 0}, line: 1})) == :record
    assert Gate.logger(key, message.(:debug, site.(94))) == :drop

    bursts = Gate.bursts(key)
    assert bursts.interval_ms == 1_000
    assert {0, rows, []} = Gate.take_bursts(bursts)

    assert Enum.sort(rows) == [
             {burst, 3, 0},
             {put_elem(burst, 7, :warning), 1, 0},
             {put_elem(burst, 6, 95), 1, 0}
           ]

    # A late writer that read the old generation adds a row the next take
    # collects, so no message is lost or counted twice.
    :ets.update_counter(bursts.table, burst, {2, 1}, {burst, 0, 0})
    assert Gate.logger(key, message.(:error, site.(94))) == {:exemplar, put_elem(burst, 1, 1)}
    assert {1, rows, []} = Gate.take_bursts(bursts)
    assert Enum.sort(rows) == [{burst, 1, 0}, {put_elem(burst, 1, 1), 1, 0}]
    assert {2, [], []} = Gate.take_bursts(bursts)

    counts = Gate.counts(key)
    assert counts[{"logger", "summarized"}] == 6
    assert counts[{"logger", "level"}] == 1
    assert counts[{"exemplar_lost", "logger"}] == 0
    assert counts[{"summary_overflow", "logger"}] == 0

    # A table that is gone records the message: nothing is lost.
    :ets.delete(bursts.table)
    assert Gate.logger(key, message.(:error, site.(94))) == :record
    assert Gate.take_bursts(bursts) == {0, [], []}
    Gate.delete(key)
  end

  test "a Logger burst is one message template: distinct texts at one call site are two bursts" do
    key = burst_gate()
    meta = %{mfa: {SummaryTestCheckout, :report, 1}, line: 7}
    log = fn msg -> Gate.logger(key, %{level: :error, msg: msg, meta: meta}) end

    # A shared logging helper: one call site, two failures.
    assert {:exemplar, {:burst, 0, "database unavailable", _, _, _, 7, :error}} =
             log.({:string, "database unavailable"})

    assert {:exemplar, {:burst, 0, "payment declined", _, _, _, 7, :error}} =
             log.({:string, ["payment ", ~c"declined"]})

    # Numbers, pids and hex vary from one message to the next; the template
    # does not.
    assert {:exemplar, {:burst, 0, "order N failed after N ms", _, _, _, 7, :error}} =
             log.({:string, "order 1234 failed after 15 ms"})

    assert log.({:string, "order 99 failed after 3 ms"}) == :drop

    # A format message's template is its format string.
    assert {:exemplar, {:burst, 0, "retrying ~p in ~b ms", _, _, _, 7, :error}} =
             log.({~c"retrying ~p in ~b ms", [:job, 10]})

    assert log.({"retrying ~p in ~b ms", [:other, 20]}) == :drop

    assert {0, rows, []} = Gate.take_bursts(Gate.bursts(key))

    assert rows |> Enum.map(fn {burst, count, 0} -> {elem(burst, 2), count} end) |> Enum.sort() ==
             [
               {"database unavailable", 1},
               {"order N failed after N ms", 2},
               {"payment declined", 1},
               {"retrying ~p in ~b ms", 2}
             ]

    Gate.delete(key)
  end

  test "a template is normalised from at most its first 160 bytes" do
    assert Template.normalise("worker #PID<0.12.0> got token deadbeefcafe1234 at 12:30\nsecond") ==
             "worker #PID<_> got token X at N:N"

    long = String.duplicate("é", 1_000) <> " 42"
    template = Template.normalise(long)
    assert byte_size(template) <= 160 + byte_size("…")
    assert String.valid?(template)
    assert String.ends_with?(template, "…")
    refute template =~ "N"

    # Chardata is read only as far as the bound, never flattened whole.
    deep = List.duplicate("ab", 100_000)
    assert byte_size(Template.normalise(deep)) <= 160 + byte_size("…")
    assert Template.normalise([~c"x", ?=, "1"]) == "x=N"
  end

  test "10,000 distinct Logger lines keep at most 64 burst rows and fold the rest into one overflow row per level" do
    key = burst_gate()
    bursts = Gate.bursts(key)

    decisions =
      for line <- 1..10_000 do
        level = if rem(line, 2) == 0, do: :error, else: :warning
        meta = %{mfa: {SummaryTestCheckout, :run, 2}, line: line}
        Gate.logger(key, %{level: level, msg: {:string, "line"}, meta: meta})
      end

    assert Enum.count(decisions, &match?({:exemplar, _burst}, &1)) == Gate.max_bursts()
    assert Enum.count(decisions, &(&1 == :drop)) == 10_000 - Gate.max_bursts()

    # Storage is bounded at ingress: the admitted rows, an admission row and
    # one overflow row per level.
    assert :ets.info(bursts.table, :size) <= Gate.max_bursts() + 1 + 2

    assert {0, rows, overflow} = Gate.take_bursts(bursts)
    assert length(rows) == Gate.max_bursts()

    assert [{:error, error_count, error_distinct}, {:warning, warning_count, warning_distinct}] =
             Enum.sort(overflow)

    # Every message is counted once, in its row or its level's overflow row.
    assert Enum.sum(Enum.map(rows, &elem(&1, 1))) + error_count + warning_count == 10_000

    # Each folded distinction is counted, to within hash collisions (never
    # more than there were).
    distinct = error_distinct + warning_distinct
    assert distinct <= 10_000 - Gate.max_bursts()
    assert distinct >= 9_500
    assert Gate.counts(key)[{"summary_overflow", "logger"}] == distinct

    # Repeating a folded message adds to the count, not to the distinctions.
    warning = fn line ->
      meta = %{mfa: {SummaryTestCheckout, :run, 2}, line: line}
      Gate.logger(key, %{level: :warning, msg: {:string, "again"}, meta: meta})
    end

    for line <- 1..Gate.max_bursts(), do: assert({:exemplar, _burst} = warning.(line))
    assert warning.(Gate.max_bursts() + 1) == :drop
    assert warning.(20_000) == :drop
    assert warning.(20_000) == :drop
    assert {1, rows, [{:warning, 3, 2}]} = Gate.take_bursts(bursts)
    assert length(rows) == Gate.max_bursts()
    Gate.delete(key)
  end

  test "concurrent writers of distinct keys admit at most 64 rows and conserve every message" do
    key = burst_gate()
    parent = self()
    writers = 32
    keys_per_writer = 40
    repeats = 3

    for writer <- 1..writers do
      spawn_link(fn ->
        decisions =
          for line <- 1..keys_per_writer, _repeat <- 1..repeats do
            meta = %{mfa: {SummaryTestCheckout, :run, writer}, line: line}
            Gate.logger(key, %{level: :error, msg: {:string, "boom"}, meta: meta})
          end

        send(parent, {:written, Enum.count(decisions, &match?({:exemplar, _burst}, &1))})
      end)
    end

    exemplars =
      for _writer <- 1..writers do
        assert_receive {:written, count}, 10_000
        count
      end

    assert {0, rows, overflow} = Gate.take_bursts(Gate.bursts(key))
    assert length(rows) == Gate.max_bursts()
    # Every admitted row named exactly one exemplar.
    assert Enum.sum(exemplars) == length(rows)

    total = Enum.sum(Enum.map(rows, &elem(&1, 1))) + Enum.sum(Enum.map(overflow, &elem(&1, 1)))
    assert total == writers * keys_per_writer * repeats
    Gate.delete(key)
  end

  test "a lost Logger exemplar marks its burst and is counted once" do
    key = burst_gate()
    meta = %{mfa: {SummaryTestCheckout, :run, 2}, line: 3}

    assert {:exemplar, burst} =
             Gate.logger(key, %{level: :error, msg: {:string, "x"}, meta: meta})

    assert Gate.logger_exemplar_lost(key, burst) == :marked
    assert Gate.counts(key)[{"exemplar_lost", "logger"}] == 1
    assert {0, [{^burst, 1, 1}], []} = Gate.take_bursts(Gate.bursts(key))

    # After the take the burst was recorded without it: the collector counts
    # that loss, so the gate does not count it again.
    assert Gate.logger_exemplar_lost(key, burst) == :taken
    assert Gate.counts(key)[{"exemplar_lost", "logger"}] == 1
    assert Gate.count_exemplar_lost(key, :logger) == :ok
    assert Gate.counts(key)[{"exemplar_lost", "logger"}] == 2
    Gate.delete(key)
  end

  test "a lost Telemetry exemplar is counted in its interval's summary and in the gate" do
    key =
      Gate.new(%{
        logger: nil,
        origin: nil,
        telemetry: [
          %{
            name: [:summary_test, :lost],
            kind: "summary_test.lost",
            min_duration_ms: 0,
            summary: true
          }
        ],
        summary_interval_ms: 1_000
      })

    name = [:summary_test, :lost]
    assert {:exemplar, exemplar} = Gate.telemetry(key, name, %{duration: 10}, %{})
    assert Gate.telemetry_exemplar_lost(key, name, exemplar) == :counted
    assert {[{"summary_test.lost", ^name, slot, nil}], 1_000} = Gate.summaries(key)
    assert %{"count" => 1, "exemplars_lost" => 1} = Summary.take(slot)

    # One that is lost after its interval was summarised is a late loss: the
    # summary is recorded, so only the gate counts it.
    assert Gate.telemetry_exemplar_lost(key, name, exemplar) == :late
    assert Gate.counts(key)[{"exemplar_lost", "telemetry"}] == 2
    assert Gate.count_exemplar_lost(key, :telemetry) == :ok
    assert Gate.counts(key)[{"exemplar_lost", "telemetry"}] == 3
    Gate.delete(key)
  end

  defp burst_gate do
    Gate.new(%{
      logger: %{
        level: :info,
        include: nil,
        exclude: nil,
        summary: %{domains: [], applications: %{}, modules: %{SummaryTestCheckout => true}},
        summary_interval_ms: 1_000
      },
      origin: nil,
      telemetry: [],
      summary_interval_ms: 1_000
    })
  end

  test "a missing or deleted gate records everything and counts nothing" do
    event = %{level: :debug, msg: {:string, "x"}, meta: %{}}
    assert Gate.logger(nil, event) == :record
    assert Gate.telemetry(nil, [:a], %{}, %{}) == :record
    assert Gate.counts(nil) == %{}
    assert Gate.summaries(nil) == nil

    key =
      Gate.new(%{
        logger: %{level: :error, include: nil, exclude: nil},
        origin: nil,
        telemetry: [
          %{
            name: [:summary_test, :event],
            kind: "summary_test.event",
            min_duration_ms: 1,
            summary: false
          }
        ],
        summary_interval_ms: 1_000
      })

    assert Gate.logger(key, event) == :drop
    assert Gate.logger(key, :not_a_log_event) == :record
    assert Gate.telemetry(key, [:not, :configured], %{}, %{}) == :record
    assert Gate.telemetry(key, :not_a_list, %{}, %{}) == :record
    assert Gate.telemetry(key, [:summary_test, :event], %{duration: 0}, %{}) == :drop
    assert Gate.summaries(key) == nil
    assert Gate.counts(key)[{"logger", "level"}] == 1
    assert Gate.counts(key)[{"telemetry", "summary_test.event", "min_duration"}] == 1

    assert Gate.delete(key) == :ok
    assert Gate.delete(nil) == :ok
    assert Gate.logger(key, event) == :record
    assert Gate.telemetry(key, [:summary_test, :event], %{duration: 0}, %{}) == :record
    assert Gate.counts(key) == %{}
    assert Gate.summaries(key) == nil
    refute Gate.key?({Gate, 0})
    refute Gate.key?(:other)
  end

  test "collector loss counts reach a live gate and are no-ops once it is gone" do
    key = Gate.new(%{logger: nil, origin: nil, telemetry: [], summary_interval_ms: 1_000})

    assert Gate.count_overflow(key, 3) == :ok
    assert Gate.count_overflow(key, 2) == :ok
    assert Gate.count_exemplar_lost(key, :telemetry) == :ok
    assert Gate.count_exemplar_lost(key, :logger) == :ok

    counts = Gate.counts(key)
    assert counts[{"summary_overflow", "logger"}] == 5
    assert counts[{"exemplar_lost", "telemetry"}] == 1
    assert counts[{"exemplar_lost", "logger"}] == 1
    # A gate without Logger bursts has no burst table to mark.
    assert Gate.logger_exemplar_lost(key, {:burst, 0}) == :taken
    assert Gate.bursts(key) == nil

    assert Gate.delete(key) == :ok
    # Deleting again, and every count after it, changes nothing.
    assert Gate.delete(key) == :ok
    assert Gate.count_overflow(key, 3) == :ok
    assert Gate.count_exemplar_lost(key, :logger) == :ok
    assert Gate.logger_exemplar_lost(key, {:burst, 0}) == :taken
    assert Gate.counts(key) == %{}
    assert Gate.table(key) == nil
    assert Gate.table(nil) == nil
    assert Gate.bursts(key) == nil
  end

  test "seen counts every emission the gate decided: recorded, filtered, or lost" do
    assert Gate.seen(nil) == %{}

    rule = fn kind, summary? ->
      %{
        name: [:summary_test, String.to_atom(kind)],
        kind: "summary_test." <> kind,
        min_duration_ms: 1,
        summary: summary?
      }
    end

    key =
      Gate.new(%{
        logger: nil,
        origin: nil,
        telemetry: [rule.("timed", false), rule.("summed", true), rule.("silent", false)],
        summary_interval_ms: 1_000
      })

    long = System.convert_time_unit(5, :millisecond, :native)
    assert Gate.telemetry(key, [:summary_test, :timed], %{duration: 0}, %{}) == :drop
    assert Gate.telemetry(key, [:summary_test, :timed], %{duration: long}, %{}) == :record
    # The interval's first sample is its slowest so far: an exemplar candidate.
    assert {:exemplar, {0, 5_000, false}} =
             Gate.telemetry(key, [:summary_test, :summed], %{duration: long}, %{})

    # A sample whose summary table is gone is lost, neither recorded nor filtered.
    :ets.delete(Gate.table(key))
    assert Gate.telemetry(key, [:summary_test, :summed], %{duration: long}, %{}) == :drop

    assert Gate.seen(key) == %{
             "summary_test.timed" => 2,
             "summary_test.summed" => 2,
             "summary_test.silent" => 0
           }

    counts = Gate.counts(key)
    assert counts[{"telemetry", "summary_test.timed", "min_duration"}] == 1
    assert counts[{"telemetry", "summary_test.summed", "summarized"}] == 1
    assert counts[{"summary_lost"}] == 1

    Gate.delete(key)
    assert Gate.seen(key) == %{}
  end

  test "a template masks credentials before it is normalised and drops a token the cut runs through" do
    # One digit made the token a high-entropy secret; normalised first, it
    # would have become N and no longer look like one.
    assert Template.normalise("connection failed QzWrTyUiOpAsDfGhJkLxCvBnMqWeRtYuIoPaS1") ==
             "connection failed [REDACTED:high_entropy]"

    assert Template.normalise(["retry ", "Authorization: Bearer ", ~c"abc123"]) ==
             "retry Authorization: [REDACTED:authorization_header]"

    # The cut falls inside the first line: its last token is dropped. A cut
    # after the first line leaves that line whole.
    assert Template.normalise("ok " <> String.duplicate("Z", 40), 10) == "ok …"
    assert Template.normalise("ok Zq\n" <> String.duplicate("Z", 40), 10) == "ok Zq …"
  end

  test "chardata a template cannot read whole is cut where reading stopped" do
    # An improper tail, a non-chardata element, an invalid codepoint, and a
    # codepoint wider than the bytes left each end the read like a byte cut.
    assert Template.normalise(["ok " | "tail"]) == "ok …"
    assert Template.normalise(["ok ", :atom, "more"]) == "ok …"
    assert Template.normalise(["ok ", -1, "more"]) == "ok …"
    assert Template.normalise(["ok ", 0x110000]) == "ok …"
    assert Template.normalise([~c"ok ", ?é], 4) == "ok …"
    # A binary element that crosses the bound keeps its fitting bytes, and
    # its cut token is dropped.
    assert Template.normalise(["ok abcdef", "rest"], 5) == "ok …"
    # The element bound cuts a list of empty parts before its text.
    assert Template.normalise(List.duplicate("", 2_000) ++ ["text"]) == " …"
  end

  test "a template of no text, invalid text, or an unreadable term is empty, and a failure is a marker" do
    assert Template.normalise("") == ""
    assert Template.normalise(<<0xFF, "abc">>) == ""
    assert Template.normalise("abc" <> <<0xFF>> <> "def") == "abc"
    assert Template.normalise(:not_chardata) == ""
    assert Template.normalise("abc", -1) == "[REDACTED:redacted_field]"
  end

  test "a Logger message's template comes from its string, chardata, or format" do
    assert Template.of_message({:string, ["took ", "12", " ms"]}) == "took N ms"
    assert Template.of_message({~c"took ~p ms", [12]}) == "took ~p ms"
    assert Template.of_message({"took ~p ms", [12]}) == "took ~p ms"
    assert Template.of_message({:took_12_ms, []}) == "took_N_ms"
    assert Template.of_message({{:not, :a, :format}, []}) == nil
    assert Template.of_message(%{report: true}) == nil
    assert Template.of_message({"format", :not_a_list}) == nil
  end

  test "truncate keeps short text and cuts long text on a UTF-8 boundary" do
    assert Template.truncate("short", 10) == "short"
    assert Template.truncate("abcdef", 3) == "abc…"
    assert Template.truncate("aé", 2) == "a…"
  end
end
