alias Insider.Collector.SystemMonitor.Handler
alias Insider.Event.Canonical

warmup_iterations = 1_000
rounds = 50
batch_size = 1_000

config_for = fn inbox_size ->
  config = %{
    allowed_events: %{long_gc: true},
    backlog_check_every: 16,
    enabled: :atomics.new(1, signed: false),
    high_water: :atomics.new(1, signed: false),
    inbox: :ets.new(:insider_system_monitor_benchmark, [:set, :public, write_concurrency: true]),
    inbox_size: inbox_size,
    max_mailbox_size: 4_096,
    ownership: :ets.new(:insider_system_monitor_benchmark_ownership, [:set, :public]),
    sequence: :atomics.new(1, signed: false),
    stats: :counters.new(10, [:atomics])
  }

  :atomics.put(config.enabled, 1, 1)
  config
end

event =
  {:monitor, self(), :long_gc,
   [
     {:timeout, 25},
     {:heap_size, 1_000},
     {:heap_block_size, 2_000},
     {:stack_size, 10},
     {:mbuf_size, 20}
   ]}

measure = fn setup, function ->
  for _round <- 1..rounds do
    config = setup.()
    started = System.monotonic_time(:nanosecond)
    Enum.each(1..batch_size, fn _iteration -> function.(config) end)
    elapsed = System.monotonic_time(:nanosecond) - started
    div(elapsed, batch_size)
  end
  |> Enum.sort()
end

percentile = fn samples, fraction ->
  Enum.at(samples, ceil(length(samples) * fraction) - 1)
end

warm_available = config_for.(warmup_iterations)
Enum.each(1..warmup_iterations, fn _iteration -> Handler.capture(event, warm_available) end)
warm_full = config_for.(1)
:ok = Handler.capture(event, warm_full)
Enum.each(1..warmup_iterations, fn _iteration -> Handler.capture(event, warm_full) end)

baseline = measure.(fn -> nil end, fn _config -> :ok end)
available_slot = measure.(fn -> config_for.(batch_size) end, &Handler.capture(event, &1))

full_setup = fn ->
  config = config_for.(1)
  :ok = Handler.capture(event, config)
  config
end

full_inbox = measure.(full_setup, &Handler.capture(event, &1))

budget_ns = %{p95: 50_000, p99: 100_000}

for {series, samples} <- [available_slot: available_slot, full_inbox: full_inbox] do
  p95 = percentile.(samples, 0.95)
  p99 = percentile.(samples, 0.99)

  if p95 > budget_ns.p95 or p99 > budget_ns.p99 do
    raise "#{series} exceeded receiver budget: p95=#{p95}ns p99=#{p99}ns"
  end
end

result = %{
  warmup_iterations: warmup_iterations,
  rounds: rounds,
  observations_per_round: batch_size,
  enforced_budget_ns: budget_ns,
  baseline_ns_per_observation: %{
    p50: percentile.(baseline, 0.50),
    p95: percentile.(baseline, 0.95),
    p99: percentile.(baseline, 0.99)
  },
  available_slot_ns_per_observation: %{
    p50: percentile.(available_slot, 0.50),
    p95: percentile.(available_slot, 0.95),
    p99: percentile.(available_slot, 0.99)
  },
  full_inbox_ns_per_observation: %{
    p50: percentile.(full_inbox, 0.50),
    p95: percentile.(full_inbox, 0.95),
    p99: percentile.(full_inbox, 0.99)
  }
}

IO.puts(Canonical.encode(result))
