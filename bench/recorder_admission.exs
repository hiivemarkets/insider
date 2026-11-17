alias Insider.Event
alias Insider.Event.Canonical
alias Insider.Recorder
alias Insider.Redaction.Policy

iterations = 2_000
rounds = 12
p95_budget_us_per_record = 50.0

events =
  Enum.map(1..iterations, fn sequence ->
    Event.new!(
      id: "benchmark-event-#{sequence}",
      node: "benchmark@localhost",
      boot_id: "benchmark-boot",
      source: "benchmark",
      kind: "runtime_signal",
      severity: :info,
      monotonic_time: sequence,
      clock_id: "benchmark-clock",
      source_instance_id: "recorder-benchmark",
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
  end)

{:ok, policy} =
  Policy.new(id: "recorder-benchmark", maximum_sensitivity: :internal, rules: [])

samples =
  Enum.map(1..rounds, fn _round ->
    options = [
      classification: {:internal, policy},
      max_events: iterations,
      max_bytes: 16 * 1_024 * 1_024,
      rate_limit_count: iterations,
      max_rate_keys: 8,
      post_trigger_ms: 0
    ]

    {:ok, recorder} = Recorder.start_link(options)
    {:ok, handle} = Recorder.handle(recorder)

    started_at = System.monotonic_time()
    Enum.each(events, fn event -> :ok = Recorder.record(handle, event) end)
    elapsed = System.monotonic_time() - started_at
    GenServer.stop(recorder)

    System.convert_time_unit(elapsed, :native, :nanosecond) / iterations / 1_000
  end)
  |> Enum.sort()

percentile = fn fraction -> Enum.at(samples, ceil(rounds * fraction) - 1) end
p95 = percentile.(0.95)

if p95 > p95_budget_us_per_record do
  raise "recorder admission exceeded its development p95 budget"
end

IO.puts(
  Canonical.encode(%{
    classified: true,
    iterations_per_round: iterations,
    rounds: rounds,
    latency_us_per_record: %{
      p50: percentile.(0.50),
      p95: p95,
      p99: percentile.(0.99)
    },
    p95_budget_us_per_record: p95_budget_us_per_record
  })
)
