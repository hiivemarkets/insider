# Write-path gate under concurrent writers. A round runs 1, 2, 4
# and 8 writers in turn; each starts one Recorder, releases its writers at
# once, and has each record its own events back to back, timing every
# `record/2` call. Each count is compared with the same round's single
# writer, and the gate takes the median of those ratios over clean rounds:
#
# - no `:contended` or other loss, in any round;
# - aggregate throughput at least `min_throughput_share` of one writer's;
# - per-call p50 and p95 at most `p50_margin` and `p95_margin` times N times
#   one writer's. The lock admits one event at a time, so a call queued
#   behind N - 1 others waits about N - 1 admissions; the margins cover the
#   hand-off between writers.
#
# Verification condition: run on a host that is not oversubscribed. A FIFO
# lock hands each turn to one particular writer, so when the OS preempts
# the holder's or the next writer's thread, every writer behind it waits out
# the OS time slice (5-15 ms). Running this bench beside 20 busy shell loops
# on a many-core development host made the 4- and 8-writer p95 8-9x the
# fair share and throughput a quarter of one writer's, with p50 unchanged.
# That measures the host, not admission overhead.
#
# `preemption_probe` is an advisory screen, not proof that a round was
# unpreempted. It runs only before and after each round (running it during
# the round would compete with the writers it measures): it spins one
# process per probed scheduler for 100 ms and sums every gap over 1 ms
# between consecutive clock reads. A round is "quiet" when neither probe
# lost more than `max_stolen_share` of its time; that excludes rounds taken
# while the host was visibly busy around them, and cannot see a pause
# inside a round. The gate takes the median over `rounds` quiet rounds, so
# one disturbed round does not decide it; with fewer than `rounds` quiet
# rounds in `max_attempts` it exits 2 (inconclusive). A pass is evidence
# for the host it ran on, which should be otherwise idle.
#
# Margins come from ten runs at load average 15-24: the worst
# p50 ratio was 0.96, the worst p95 ratio 1.15 and the lowest throughput
# share 0.94.
alias Insider.Event
alias Insider.Event.Canonical
alias Insider.Recorder
alias Insider.Redaction.Policy

per_writer = 2_000
rounds = 8
max_attempts = 20
writer_counts = [1, 2, 4, 8]
p50_margin = 1.5
p95_margin = 2.0
min_throughput_share = 0.5
max_stolen_share = 0.02
probe_ms = 100
probes = min(8, System.schedulers_online())

{:ok, policy} =
  Policy.new(id: "recorder-contention-benchmark", maximum_sensitivity: :internal, rules: [])

event = fn writer, sequence ->
  Event.new!(
    id: "benchmark-#{writer}-#{sequence}",
    node: "benchmark@localhost",
    boot_id: "benchmark-boot",
    source: "benchmark",
    kind: "runtime_signal",
    severity: :info,
    monotonic_time: sequence,
    clock_id: "benchmark-clock",
    source_instance_id: "writer-#{writer}",
    source_sequence: sequence,
    wall_time: nil,
    subject: nil,
    causality: %{
      trace_id: nil,
      span_id: nil,
      parent_event_id: nil,
      logical_operation_id: nil,
      process_generation: nil
    },
    attributes: %{"field_set" => "benchmark/v1"},
    payload: nil,
    authority: "benchmark",
    redactions: [],
    extensions: %{}
  )
end

round = fn writers ->
  total = writers * per_writer

  {:ok, recorder} =
    Recorder.start_link(
      classification: {:internal, policy},
      max_events: total,
      max_bytes: 16 * 1_024 * 1_024,
      rate_limit_count: total,
      max_rate_keys: 8,
      post_trigger_ms: 0
    )

  {:ok, handle} = Recorder.handle(recorder)
  parent = self()
  go = make_ref()

  tasks =
    for writer <- 1..writers do
      batch = Enum.map(1..per_writer, &event.(writer, &1))

      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (^go -> :ok)
        timed =
          Enum.map(batch, fn event ->
            started_at = System.monotonic_time()
            result = Recorder.record(handle, event)
            {System.monotonic_time() - started_at, result}
          end)

        timed
      end)
    end

  for %Task{pid: pid} <- tasks, do: receive(do: ({:ready, ^pid} -> :ok))
  started_at = System.monotonic_time()
  for %Task{pid: pid} <- tasks, do: send(pid, go)
  outcomes = Task.await_many(tasks, 120_000)
  elapsed = System.monotonic_time() - started_at
  {:ok, status} = Recorder.status(handle)
  GenServer.stop(recorder)

  timed = List.flatten(outcomes)

  latencies =
    Enum.map(timed, fn {call, _result} ->
      System.convert_time_unit(call, :native, :nanosecond) / 1_000
    end)

  results = Enum.map(timed, fn {_call, result} -> result end)
  seconds = System.convert_time_unit(elapsed, :native, :nanosecond) / 1.0e9

  %{
    latencies: latencies,
    events_per_second: total / seconds,
    losses: results |> Enum.reject(&(&1 == :ok)) |> Enum.frequencies(),
    contended: status.counters.contended,
    accepted: status.counters.accepted,
    total: total
  }
end

percentile = fn samples, fraction ->
  sorted = Enum.sort(samples)
  Enum.at(sorted, ceil(length(sorted) * fraction) - 1)
end

median = fn values -> percentile.(values, 0.5) end

# The largest share of `probe_ms` any probe lost to gaps over 1 ms.
preemption_probe = fn ->
  spin = fn spin, deadline, last, stolen ->
    now = System.monotonic_time(:microsecond)
    gap = now - last
    stolen = if gap > 1_000, do: stolen + gap, else: stolen
    if now >= deadline, do: stolen, else: spin.(spin, deadline, now, stolen)
  end

  1..probes
  |> Enum.map(fn _probe ->
    Task.async(fn ->
      started = System.monotonic_time(:microsecond)
      spin.(spin, started + probe_ms * 1_000, started, 0) / (probe_ms * 1_000)
    end)
  end)
  |> Task.await_many(10_000)
  |> Enum.max()
end

run_round = fn ->
  before = preemption_probe.()
  results = Map.new(writer_counts, fn writers -> {writers, round.(writers)} end)
  stolen = max(before, preemption_probe.())
  %{results: results, stolen: stolen, clean: stolen <= max_stolen_share}
end

attempts =
  Enum.reduce_while(1..max_attempts, [], fn _attempt, attempts ->
    attempts = [run_round.() | attempts]

    if Enum.count(attempts, & &1.clean) >= rounds,
      do: {:halt, attempts},
      else: {:cont, attempts}
  end)
  |> Enum.reverse()

clean = Enum.filter(attempts, & &1.clean)

summary = fn samples ->
  latencies = Enum.flat_map(samples, & &1.latencies)

  %{
    latency_us_per_call: %{
      p50: percentile.(latencies, 0.50),
      p95: percentile.(latencies, 0.95),
      p99: percentile.(latencies, 0.99),
      max: Enum.max(latencies)
    },
    events_per_second_p50: median.(Enum.map(samples, & &1.events_per_second))
  }
end

round_ratios = fn %{results: results} ->
  single = summary.([results[1]])

  Map.new(writer_counts, fn writers ->
    result = summary.([results[writers]])

    {writers,
     %{
       p50: result.latency_us_per_call.p50 / (writers * single.latency_us_per_call.p50),
       p95: result.latency_us_per_call.p95 / (writers * single.latency_us_per_call.p95),
       throughput: result.events_per_second_p50 / single.events_per_second_p50
     }}
  end)
end

per_round = Enum.map(clean, round_ratios)

ratios =
  Map.new(writer_counts, fn writers ->
    of = fn key -> median.(Enum.map(per_round, &get_in(&1, [writers, key]))) end

    {writers,
     %{p50_per_fair_share: of.(:p50), p95_per_fair_share: of.(:p95), throughput_share: of.(:throughput)}}
  end)

measured =
  Map.new(writer_counts, fn writers ->
    all = Enum.map(attempts, & &1.results[writers])

    losses =
      Enum.reduce(all, %{}, fn sample, acc ->
        Map.merge(acc, sample.losses, fn _key, left, right -> left + right end)
      end)

    {writers,
     Map.merge(summary.(all), %{
       contended: Enum.sum(Enum.map(all, & &1.contended)),
       accepted: Enum.sum(Enum.map(all, & &1.accepted)),
       offered: Enum.sum(Enum.map(all, & &1.total)),
       losses: Map.new(losses, fn {loss, count} -> {inspect(loss), count} end)
     })}
  end)

conclusive = length(clean) >= rounds

failures =
  Enum.flat_map(writer_counts, fn writers ->
    result = measured[writers]
    ratio = ratios[writers]

    [
      result.contended > 0 && "#{writers} writers: #{result.contended} contended losses",
      result.accepted != result.offered &&
        "#{writers} writers: #{result.offered - result.accepted} events not admitted",
      conclusive and ratio.p50_per_fair_share > p50_margin &&
        "#{writers} writers: per-call p50 #{ratio.p50_per_fair_share} x fair share, over #{p50_margin}",
      conclusive and ratio.p95_per_fair_share > p95_margin &&
        "#{writers} writers: per-call p95 #{ratio.p95_per_fair_share} x fair share, over #{p95_margin}",
      conclusive and ratio.throughput_share < min_throughput_share &&
        "#{writers} writers: throughput #{ratio.throughput_share} of one writer's, under #{min_throughput_share}"
    ]
    |> Enum.filter(& &1)
  end)

stringify = fn map -> Map.new(map, fn {writers, value} -> {Integer.to_string(writers), value} end) end

IO.puts(
  Canonical.encode(%{
    events_per_writer: per_writer,
    rounds_attempted: length(attempts),
    rounds_quiet_around: length(clean),
    probes_cover: "before_and_after_each_round_not_during",
    stolen_share_around_round: Enum.map(attempts, & &1.stolen),
    conclusive: conclusive,
    writers: stringify.(measured),
    ratios: stringify.(ratios),
    p50_margin: p50_margin,
    p95_margin: p95_margin,
    min_throughput_share: min_throughput_share,
    max_stolen_share: max_stolen_share,
    schedulers_online: System.schedulers_online(),
    failures: failures
  })
)

cond do
  failures != [] ->
    raise "recorder write path left its contention gate: " <> Enum.join(failures, "; ")

  not conclusive ->
    IO.puts(
      :stderr,
      "inconclusive: the probes around #{length(attempts) - length(clean)} of " <>
        "#{length(attempts)} rounds saw scheduler threads preempted; rerun on an idle host"
    )

    System.halt(2)

  true ->
    :ok
end
