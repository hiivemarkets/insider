alias Insider.Collector.Gate
alias Insider.Collector.Summary
alias Insider.Collector.Telemetry.Handler
alias Insider.Collector.Telemetry.Policy
alias Insider.Event.Canonical

iterations = 1_000
budget_us = %{p95: 50, p99: 100}
event_name = [:insider, :benchmark, :telemetry, :start]
handler_id = "insider-telemetry-benchmark"

{:ok, policy} =
  Policy.new(
    id: "telemetry-benchmark",
    events: [
      [
        name: event_name,
        kind: "telemetry.benchmark.start",
        lifecycle: "benchmark",
        phase: :start
      ]
    ],
    metadata: [component: "component"],
    measurements: [duration: "duration"],
    correlation: [logical_operation_id: :run_id]
  )

config_for = fn inbox_size ->
  %{
    correlation: policy.correlation,
    events: policy.events,
    inbox: :ets.new(:insider_telemetry_benchmark, [:set, :public, write_concurrency: true]),
    inbox_size: inbox_size,
    measurements: policy.measurements,
    metadata: policy.metadata,
    policy_id: policy.id,
    sequence: :atomics.new(1, []),
    stats: :counters.new(14, [:atomics])
  }
end

measure = fn name, measurements, metadata ->
  for _iteration <- 1..iterations do
    {microseconds, :ok} = :timer.tc(:telemetry, :execute, [name, measurements, metadata])
    microseconds
  end
  |> Enum.sort()
end

percentile = fn samples, fraction ->
  Enum.at(samples, ceil(length(samples) * fraction) - 1)
end

:telemetry.detach(handler_id)

try do
  baseline = measure.([:insider, :benchmark, :telemetry, :unhandled], %{}, %{})
  available_config = config_for.(iterations)
  :ok = :telemetry.attach(handler_id, event_name, &Handler.handle_event/4, available_config)

  available_slot =
    measure.(event_name, %{duration: 1.25}, %{
      run_id: "benchmark-operation",
      component: :benchmark
    })

  :ok = :telemetry.detach(handler_id)
  full_config = config_for.(1)
  :ok = :telemetry.attach(handler_id, event_name, &Handler.handle_event/4, full_config)
  :ok = :telemetry.execute(event_name, %{duration: 0}, %{run_id: "fills-slot"})

  full_inbox =
    measure.(event_name, %{duration: 1.25}, %{
      run_id: "benchmark-operation",
      component: :benchmark
    })

  # A live session's record-time gate on the same event: `dropped` is below
  # its minimum duration, `summarized` is folded into a histogram, and
  # `gated` passes the gate and does the ungated work above.
  gated_run = fn min_duration_ms, summary?, duration ->
    gate =
      Gate.new(%{
        logger: nil,
        origin: %{oban_conf: true, modules: %{Oban.Stager => true}},
        telemetry: [
          %{
            name: event_name,
            kind: "telemetry.benchmark.start",
            min_duration_ms: min_duration_ms,
            summary: summary?
          }
        ],
        summary_interval_ms: 1_000
      })

    config = Map.put(config_for.(iterations), :gate, gate)
    :ok = :telemetry.detach(handler_id)
    :ok = :telemetry.attach(handler_id, event_name, &Handler.handle_event/4, config)

    samples =
      measure.(event_name, %{duration: duration}, %{
        run_id: "benchmark-operation",
        component: :benchmark
      })

    {samples, config, gate}
  end

  {dropped, dropped_config, dropped_gate} = gated_run.(100, false, 10)
  {summarized, summarized_config, summarized_gate} = gated_run.(0, true, 10)
  {gated, gated_config, gated_gate} = gated_run.(0, false, 10)

  # Every emission is seen once, whichever path the gate took: a recorded
  # event adds one counter increment, a dropped one none beyond its filter's.
  kind = "telemetry.benchmark.start"
  true = Gate.seen(gated_gate)[kind] == :counters.get(gated_config.stats, 1)

  true =
    Gate.seen(dropped_gate)[kind] == Gate.counts(dropped_gate)[{"telemetry", kind, "min_duration"}]

  # The largest accepted omission evidence: a 128-byte policy id and sixteen
  # 64-byte nameable measurements, every one withheld, plus one unknown.
  # Names are found by one fold over the list prepared at start.
  named_policy_id = String.duplicate("p", 128)
  named = for index <- 1..16, do: String.to_atom(String.pad_trailing("m#{index}_", 64, "x"))

  named_config =
    config_for.(iterations)
    |> Map.put(:policy_id, named_policy_id)
    |> Map.merge(Handler.nameable(named))

  :ok = :telemetry.detach(handler_id)
  :ok = :telemetry.attach(handler_id, event_name, &Handler.handle_event/4, named_config)
  named_measurements = named |> Map.new(&{&1, 1}) |> Map.put(:unknown, 2)

  named_drops =
    measure.(event_name, named_measurements, %{run_id: "benchmark-operation", component: :benchmark})

  [{_slot, _sequence, named_shape} | _rest] = :ets.tab2list(named_config.inbox)

  true =
    :counters.get(named_config.stats, 7) == 0 and
      Insider.Collector.Telemetry.Omitted.valid?(named_shape.omitted) and
      length(named_shape.omitted["measurement_names"]) == 16 and
      named_shape.omitted["measurements"] == 17

  summarize = fn samples ->
    %{
      p50: percentile.(samples, 0.50),
      p95: percentile.(samples, 0.95),
      p99: percentile.(samples, 0.99)
    }
  end

  available_summary = summarize.(available_slot)
  full_summary = summarize.(full_inbox)
  dropped_summary = summarize.(dropped)
  summarized_summary = summarize.(summarized)
  gated_summary = summarize.(gated)
  named_summary = summarize.(named_drops)

  {[{_kind, _name, slot, _scope}], _interval} = Gate.summaries(summarized_gate)
  histogram = Summary.take(slot)

  # A dropped or summarised event does no handler work: no statistic, no
  # sequence number, no inbox write. The exception is a summary's exemplar
  # candidates: with one constant duration, the first four samples of the
  # interval's top bucket.
  gate_counts = %{
    dropped_received: :counters.get(dropped_config.stats, 1),
    dropped_sequence: :atomics.get(dropped_config.sequence, 1),
    dropped_counted: Gate.counts(dropped_gate)[{"telemetry", "telemetry.benchmark.start", "min_duration"}],
    summarized_received: :counters.get(summarized_config.stats, 1),
    summarized_inbox: :ets.info(summarized_config.inbox, :size),
    summarized_count: histogram["count"],
    gated_received: :counters.get(gated_config.stats, 1)
  }

  true =
    gate_counts == %{
      dropped_received: 0,
      dropped_sequence: 0,
      dropped_counted: iterations,
      summarized_received: 0,
      summarized_inbox: 4,
      summarized_count: iterations,
      gated_received: iterations
    }

  for {name, summary} <- [
        available_slot: available_summary,
        full_inbox: full_summary,
        gate_dropped: dropped_summary,
        gate_summarized: summarized_summary,
        gate_admitted: gated_summary,
        named_drops: named_summary
      ] do
    if summary.p95 > budget_us.p95 or summary.p99 > budget_us.p99 do
      raise "#{name} exceeded Telemetry hot-path budget"
    end
  end

  available_counts = %{
    received: :counters.get(available_config.stats, 1),
    enqueued: :counters.get(available_config.stats, 2),
    shed: :counters.get(available_config.stats, 3),
    invalid: :counters.get(available_config.stats, 4),
    handler_failures: :counters.get(available_config.stats, 7),
    inbox_count: :ets.info(available_config.inbox, :size)
  }

  full_counts = %{
    received: :counters.get(full_config.stats, 1),
    enqueued: :counters.get(full_config.stats, 2),
    shed: :counters.get(full_config.stats, 3),
    invalid: :counters.get(full_config.stats, 4),
    handler_failures: :counters.get(full_config.stats, 7),
    inbox_count: :ets.info(full_config.inbox, :size)
  }

  true =
    available_counts == %{
      received: iterations,
      enqueued: iterations,
      shed: 0,
      invalid: 0,
      handler_failures: 0,
      inbox_count: iterations
    }

  true =
    full_counts == %{
      received: iterations + 1,
      enqueued: 1,
      shed: iterations,
      invalid: 0,
      handler_failures: 0,
      inbox_count: 1
    }

  result = %{
    iterations: iterations,
    budget_us: budget_us,
    baseline_us: summarize.(baseline),
    available_slot_us: available_summary,
    full_inbox_us: full_summary,
    gate_dropped_us: dropped_summary,
    gate_summarized_us: summarized_summary,
    gate_admitted_us: gated_summary,
    named_drops_us: named_summary,
    available_counts: available_counts,
    full_counts: full_counts,
    gate_counts: gate_counts
  }

  IO.puts(Canonical.encode(result))
after
  :telemetry.detach(handler_id)
end
