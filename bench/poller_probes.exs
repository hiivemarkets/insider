alias Insider.Collector.Poller.Erlang, as: ErlangProvider
alias Insider.Event.Canonical

process_iterations = 1_000
vm_iterations = 100
process_p95_budget_us = 100
vm_p95_budget_us = 1_000
# The whole-node scans run once per poll interval (Live: 5 s by default).
# Budgets are for a node with 10,000 extra idle processes.
scan_processes = 10_000
scan_iterations = 20
process_top_p95_budget_us = 50_000
ets_top_p95_budget_us = 5_000
# The port census budget is for a node with 1,000 extra ports (UDP sockets)
# held by 100 owners.
scan_ports = 1_000
port_top_p95_budget_us = 10_000

scan_options = %{top: 5, protected: %{}, insider: [], master: nil, budget_bytes: 3_500}

measure = fn iterations, function ->
  for _iteration <- 1..iterations do
    {microseconds, result} = :timer.tc(function)
    true = match?({:ok, _status, _metrics, _unavailable}, result)
    microseconds
  end
  |> Enum.sort()
end

percentile = fn samples, fraction ->
  Enum.at(samples, ceil(length(samples) * fraction) - 1)
end

summary = fn samples ->
  %{
    p50: percentile.(samples, 0.50),
    p95: percentile.(samples, 0.95),
    p99: percentile.(samples, 0.99)
  }
end

target = spawn(fn -> receive(do: (:stop -> :ok)) end)
process_samples = measure.(process_iterations, fn -> ErlangProvider.process_sample(target) end)
vm_samples = measure.(vm_iterations, &ErlangProvider.vm_sample/0)

process_summary = summary.(process_samples)
vm_summary = summary.(vm_samples)

idle = for _index <- 1..scan_processes, do: spawn(fn -> receive(do: (:stop -> :ok)) end)
{:ok, _status, _metrics, _unavailable, snapshot} = ErlangProvider.process_top(nil, scan_options)

process_top_summary =
  measure.(scan_iterations, fn ->
    {:ok, status, metrics, unavailable, _snapshot} =
      ErlangProvider.process_top(snapshot, scan_options)

    {:ok, status, metrics, unavailable}
  end)
  |> summary.()

ets_top_summary = scan_iterations |> measure.(fn -> ErlangProvider.ets_top(scan_options) end) |> summary.()

port_owners =
  for _index <- 1..100 do
    spawn(fn ->
      sockets = for _socket <- 1..div(scan_ports, 100), do: elem(:gen_udp.open(0), 1)
      receive(do: (:stop -> Enum.each(sockets, &:gen_udp.close/1)))
    end)
  end

wait_ports = fn wait_ports ->
  if length(:erlang.ports()) < scan_ports, do: wait_ports.(wait_ports), else: :ok
end

:ok = wait_ports.(wait_ports)

{:ok, _status, _metrics, _unavailable, port_snapshot} =
  ErlangProvider.port_top(nil, scan_options)

port_top_summary =
  measure.(scan_iterations, fn ->
    {:ok, status, metrics, unavailable, _snapshot} =
      ErlangProvider.port_top(port_snapshot, scan_options)

    {:ok, status, metrics, unavailable}
  end)
  |> summary.()

port_snapshot_bytes = :erts_debug.flat_size(port_snapshot) * :erlang.system_info(:wordsize)
Enum.each(port_owners, &send(&1, :stop))
snapshot_bytes = :erts_debug.flat_size(snapshot) * :erlang.system_info(:wordsize)
Enum.each(idle, &send(&1, :stop))

if port_top_summary.p95 > port_top_p95_budget_us,
  do: raise("port census exceeded its development p95 budget")

if process_top_summary.p95 > process_top_p95_budget_us,
  do: raise("process scan exceeded its development p95 budget")

if ets_top_summary.p95 > ets_top_p95_budget_us,
  do: raise("ETS scan exceeded its development p95 budget")

if process_summary.p95 > process_p95_budget_us,
  do: raise("process probe exceeded its development p95 budget")

if vm_summary.p95 > vm_p95_budget_us,
  do: raise("VM probe exceeded its development p95 budget")

monitor = Process.monitor(target)
send(target, :stop)

receive do
  {:DOWN, ^monitor, :process, ^target, :normal} -> :ok
after
  1_000 -> raise "benchmark target did not stop"
end

IO.puts(
  Canonical.encode(%{
    process: %{
      iterations: process_iterations,
      latency_us: process_summary,
      p95_budget_us: process_p95_budget_us,
      target: "other_process"
    },
    vm: %{iterations: vm_iterations, latency_us: vm_summary, p95_budget_us: vm_p95_budget_us},
    process_top: %{
      iterations: scan_iterations,
      extra_idle_processes: scan_processes,
      latency_us: process_top_summary,
      p95_budget_us: process_top_p95_budget_us,
      kept_snapshot_bytes: snapshot_bytes
    },
    ets_top: %{
      iterations: scan_iterations,
      latency_us: ets_top_summary,
      p95_budget_us: ets_top_p95_budget_us
    },
    port_top: %{
      iterations: scan_iterations,
      extra_ports: scan_ports,
      latency_us: port_top_summary,
      p95_budget_us: port_top_p95_budget_us,
      kept_snapshot_bytes: port_snapshot_bytes
    }
  })
)
