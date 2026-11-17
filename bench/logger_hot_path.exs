alias Insider.Collector.Gate
alias Insider.Collector.Logger.Handler
alias Insider.Event.Canonical

iterations = 1_000
budget_us = %{p95: 100, p99: 250}

config_for = fn inbox_size ->
  %{
    authority: "benchmark",
    boot_id: "benchmark-boot",
    clock_id: "logger-order",
    inbox: :ets.new(:insider_logger_benchmark, [:set, :public, write_concurrency: true]),
    inbox_size: inbox_size,
    include_payload: false,
    include_message_semantics: false,
    structural_only: false,
    node: "benchmark@localhost",
    sequence: :atomics.new(1, []),
    source_instance_id: "logger-benchmark",
    stats: :counters.new(13, [:atomics])
  }
end

event = %{
  level: :error,
  msg:
    {:report,
     %{
       label: {:supervisor, :child_terminated},
       report: %{
         supervisor: {:local, self()},
         errorContext: :child_terminated,
         offender: %{id: :worker, pid: self(), restart_type: :permanent},
         reason: {:error, :fixture_crash}
       }
     }},
  meta: %{domain: [:otp, :sasl], pid: self(), trace_id: "benchmark-trace"}
}

measure = fn function ->
  for _iteration <- 1..iterations do
    {microseconds, _result} = :timer.tc(function)
    microseconds
  end
  |> Enum.sort()
end

baseline = measure.(fn -> event end)
available_config = config_for.(iterations)
available_slot = measure.(fn -> Handler.filter(event, available_config) end)

full_config = config_for.(1)
^event = Handler.filter(event, full_config)
full_inbox = measure.(fn -> Handler.filter(event, full_config) end)

# A live session's record-time gate. `excluded` drops the supervisor report
# through every check up to the exclude rule; `gated` admits it, so its cost
# is the gate plus the ungated path above.
gate = fn exclude ->
  Gate.new(%{
    logger: %{level: :warning, include: nil, exclude: exclude},
    origin: %{oban_conf: true, modules: %{Oban.Stager => true}},
    telemetry: [],
    summary_interval_ms: 1_000
  })
end

exclude_otp = %{domains: [[:otp]], applications: %{}, modules: %{}}
excluded_gate = gate.(exclude_otp)
excluded_config = Map.put(config_for.(iterations), :gate, excluded_gate)
excluded = measure.(fn -> Handler.filter(event, excluded_config) end)
gated_config = Map.put(config_for.(iterations), :gate, gate.(nil))
gated = measure.(fn -> Handler.filter(event, gated_config) end)

# Summarised messages (a live session's --logger-summary): three of four
# repeat one template with varying numbers, one bump of an admitted burst;
# every fourth is a new template, admitted while the interval has room and
# then folded into its level's overflow row. Each pays the template on its
# first 160 bytes and at most a handful of counter updates.
burst_gate =
  Gate.new(%{
    logger: %{
      level: :info,
      include: nil,
      exclude: nil,
      summary: %{domains: [], applications: %{}, modules: %{BenchBurst => true}},
      summary_interval_ms: 1_000
    },
    origin: nil,
    telemetry: [],
    summary_interval_ms: 1_000
  })

burst_config = Map.put(config_for.(iterations), :gate, burst_gate)
letters = fn number -> for <<digit <- Integer.to_string(number)>>, into: "", do: <<digit - ?0 + ?a>> end

burst_events =
  for number <- 1..iterations do
    text =
      if rem(number, 4) == 0,
        do: "payment declined for " <> letters.(number),
        else: "checkout failed for order #{number} after #{rem(number, 97)} ms"

    %{
      level: :error,
      msg: {:string, text},
      meta: %{mfa: {BenchBurst, :run, 1}, line: 10, pid: self(), time: :logger.timestamp()}
    }
  end

bursts =
  burst_events
  |> Enum.map(fn burst_event ->
    {microseconds, _result} = :timer.tc(fn -> Handler.filter(burst_event, burst_config) end)
    microseconds
  end)
  |> Enum.sort()

percentile = fn samples, fraction ->
  Enum.at(samples, ceil(length(samples) * fraction) - 1)
end

summarize = fn samples ->
  %{
    p50: percentile.(samples, 0.50),
    p95: percentile.(samples, 0.95),
    p99: percentile.(samples, 0.99)
  }
end

available_summary = summarize.(available_slot)
full_summary = summarize.(full_inbox)

available_counts = %{
  received: :counters.get(available_config.stats, 1),
  enqueued: :counters.get(available_config.stats, 2),
  shed: :counters.get(available_config.stats, 3),
  invalid: :counters.get(available_config.stats, 4),
  inbox_count: :ets.info(available_config.inbox, :size)
}

full_counts = %{
  received: :counters.get(full_config.stats, 1),
  enqueued: :counters.get(full_config.stats, 2),
  shed: :counters.get(full_config.stats, 3),
  invalid: :counters.get(full_config.stats, 4),
  inbox_count: :ets.info(full_config.inbox, :size)
}

true =
  available_counts == %{
    received: iterations,
    enqueued: iterations,
    shed: 0,
    invalid: 0,
    inbox_count: iterations
  }

true =
  full_counts == %{
    received: iterations + 1,
    enqueued: 1,
    shed: iterations,
    invalid: 0,
    inbox_count: 1
  }

# The counters above must prove the handler did the work before any latency
# figure is trusted. A stale fixture makes filter/2 rescue immediately, which
# would otherwise clear this budget while measuring nothing.
gated_counts = %{
  excluded_received: :counters.get(excluded_config.stats, 1),
  excluded_sequence: :atomics.get(excluded_config.sequence, 1),
  excluded_inbox: :ets.info(excluded_config.inbox, :size),
  excluded_counted: Gate.counts(excluded_gate)[{"logger", "exclude"}],
  gated_received: :counters.get(gated_config.stats, 1)
}

# A dropped event does no handler work: no statistic, no sequence, no write.
true =
  gated_counts == %{
    excluded_received: 0,
    excluded_sequence: 0,
    excluded_inbox: 0,
    excluded_counted: iterations,
    gated_received: iterations
  }

excluded_summary = summarize.(excluded)
gated_summary = summarize.(gated)
burst_summary = summarize.(bursts)

# Every message was summarised and none was handled as a recorded event;
# the inbox holds one exemplar per admitted burst; the rest of the distinct
# templates are folded and counted.
{_generation, burst_rows, burst_overflow} = Gate.take_bursts(Gate.bursts(burst_gate))

burst_counts = %{
  summarized: Gate.counts(burst_gate)[{"logger", "summarized"}],
  received: :counters.get(burst_config.stats, 1),
  inbox: :ets.info(burst_config.inbox, :size),
  rows: length(burst_rows),
  counted: Enum.sum(Enum.map(burst_rows, &elem(&1, 1))) + Enum.sum(Enum.map(burst_overflow, &elem(&1, 1))),
  distinct_lost: Enum.sum(Enum.map(burst_overflow, &elem(&1, 2)))
}

true =
  burst_counts == %{
    summarized: iterations,
    received: 0,
    inbox: Gate.max_bursts(),
    rows: Gate.max_bursts(),
    counted: iterations,
    distinct_lost: div(iterations, 4) + 1 - Gate.max_bursts()
  }

for {name, summary} <- [
      available_slot: available_summary,
      full_inbox: full_summary,
      excluded: excluded_summary,
      gated: gated_summary,
      bursts: burst_summary
    ] do
  if summary.p95 > budget_us.p95 or summary.p99 > budget_us.p99 do
    raise "#{name} exceeded Logger hot-path budget"
  end
end

result = %{
  iterations: iterations,
  budget_us: budget_us,
  baseline_us: summarize.(baseline),
  available_slot_us: available_summary,
  full_inbox_us: full_summary,
  gate_excluded_us: excluded_summary,
  gate_admitted_us: gated_summary,
  gate_burst_us: burst_summary,
  burst_counts: burst_counts,
  available_counts: available_counts,
  full_counts: full_counts,
  gate_counts: gated_counts
}

IO.puts(Canonical.encode(result))
