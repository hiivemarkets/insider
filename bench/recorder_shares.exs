# Write-path gate for per-source shares. A full Recorder (1,024
# events, 4 MiB) takes a Logger flood with Telemetry and Poller writes
# mixed in, so every write evicts. Each round times every `record/2` call
# twice, in turn: with the default shares, and with one share for every
# source (`source_shares: %{}`, `other_share: 100`), which evicts the
# oldest normal entry as the Recorder did before shares. The gate:
#
# - every write is admitted (`:ok`), with either configuration;
# - with shares, the Telemetry and Poller entries within their shares
#   survive the flood;
# - the median over rounds of the per-round p50 and p95 ratios (shares over
#   one share) is at most `p50_margin` and `p95_margin`, and the median
#   shares p95 is at most `p95_budget_us`, a coarse ceiling: the ratios are
#   the regression check, since absolute times follow the host's load.
#
# Before shares (same workload, load average 50) a write took p50 49 µs and
# p95 198 µs. The margins come from repeated runs on a loaded host.
alias Insider.Event
alias Insider.Event.Canonical
alias Insider.Recorder
alias Insider.Redaction.Policy

writes = 4_000
rounds = 12
p50_margin = 1.5
p95_margin = 1.5
p95_budget_us = 400.0

{:ok, policy} =
  Policy.new(id: "recorder-shares-benchmark", maximum_sensitivity: :internal, rules: [])

event = fn source, sequence ->
  Event.new!(
    id: "#{source}-#{sequence}",
    node: "benchmark@localhost",
    boot_id: "benchmark-boot",
    source: source,
    kind: source <> ".sample",
    severity: :info,
    monotonic_time: sequence,
    clock_id: "benchmark-clock",
    source_instance_id: source <> "-benchmark",
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
    attributes: %{"message" => String.duplicate("x", 2_000)},
    payload: nil,
    authority: "benchmark",
    redactions: [],
    extensions: %{}
  )
end

# One in twenty writes is Telemetry and one in twenty Poller; the rest are
# the Logger flood. The first 1,024 writes fill the Recorder untimed.
source = fn sequence ->
  case rem(sequence, 20) do
    0 -> "telemetry"
    10 -> "poller"
    _flood -> "logger"
  end
end

fill = Enum.map(1..1_024, &event.(source.(&1), &1))
timed = Enum.map(1_025..(1_024 + writes), &event.(source.(&1), &1))

configurations = %{
  shares: [],
  one_share: [source_shares: %{}, other_share: 100]
}

percentile = fn sorted, fraction -> Enum.at(sorted, ceil(length(sorted) * fraction) - 1) end

run = fn options ->
  {:ok, recorder} =
    Recorder.start_link(
      [
        classification: {:internal, policy},
        max_events: 1_024,
        max_bytes: 4 * 1_024 * 1_024,
        rate_limit_count: 100_000,
        post_trigger_ms: 0
      ] ++ options
    )

  {:ok, handle} = Recorder.handle(recorder)
  Enum.each(fill, &(:ok = Recorder.record(handle, &1)))

  {latencies, results} =
    timed
    |> Enum.map(fn event ->
      started_at = System.monotonic_time()
      result = Recorder.record(handle, event)
      {System.monotonic_time() - started_at, result}
    end)
    |> Enum.unzip()

  {:ok, fill} = Recorder.fill(handle)
  GenServer.stop(recorder)

  sorted =
    latencies
    |> Enum.map(&(System.convert_time_unit(&1, :native, :nanosecond) / 1_000))
    |> Enum.sort()

  %{
    p50: percentile.(sorted, 0.50),
    p95: percentile.(sorted, 0.95),
    losses: Enum.count(results, &(&1 != :ok)),
    sources: fill.sources
  }
end

samples =
  Enum.map(1..rounds, fn _round ->
    Map.new(configurations, fn {name, options} -> {name, run.(options)} end)
  end)

median = fn values ->
  sorted = Enum.sort(values)
  Enum.at(sorted, div(length(sorted), 2))
end

p50_ratio = median.(Enum.map(samples, &(&1.shares.p50 / &1.one_share.p50)))
p95_ratio = median.(Enum.map(samples, &(&1.shares.p95 / &1.one_share.p95)))
shares_p95 = median.(Enum.map(samples, & &1.shares.p95))
one_share_p95 = median.(Enum.map(samples, & &1.one_share.p95))
losses = samples |> Enum.flat_map(&[&1.shares.losses, &1.one_share.losses]) |> Enum.sum()

# Telemetry and Poller write 200 events each, more than their 153- and
# 256-event shares hold, so each keeps its own newest within its share and
# loses only what it wrote beyond it; the flood never takes their room.
protected? =
  Enum.all?(samples, fn %{shares: %{sources: sources}} ->
    Enum.all?(["telemetry", "poller"], fn group ->
      usage = sources[group]
      usage.retained_events >= min(usage.reserved_events, 200)
    end)
  end)

failures =
  [
    {losses > 0, "#{losses} writes were not admitted"},
    {not protected?, "the flood evicted Telemetry or Poller entries within their shares"},
    {p50_ratio > p50_margin, "p50 ratio #{p50_ratio} over #{p50_margin}"},
    {p95_ratio > p95_margin, "p95 ratio #{p95_ratio} over #{p95_margin}"},
    {shares_p95 > p95_budget_us, "shares p95 #{shares_p95} µs over #{p95_budget_us} µs"}
  ]
  |> Enum.filter(&elem(&1, 0))
  |> Enum.map(&elem(&1, 1))

IO.puts(
  Canonical.encode(%{
    writes_per_round: writes,
    rounds: rounds,
    latency_us_per_record: %{
      shares: %{
        p50_median: median.(Enum.map(samples, & &1.shares.p50)),
        p95_median: shares_p95
      },
      one_share: %{
        p50_median: median.(Enum.map(samples, & &1.one_share.p50)),
        p95_median: one_share_p95
      }
    },
    median_ratio: %{p50: p50_ratio, p95: p95_ratio},
    margins: %{p50: p50_margin, p95: p95_margin, p95_budget_us: p95_budget_us},
    losses: losses,
    shares_kept_telemetry_and_poller: protected?,
    failures: failures
  })
)

if failures != [], do: raise("recorder share write path exceeded its gate: #{inspect(failures)}")
