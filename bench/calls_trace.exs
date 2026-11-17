# The cost of a live call trace to the traced function's callers, and that
# it ends with the trace: nanoseconds per call of one traced function with no
# trace, while traced (every call a trace message), after the trace stopped
# itself at calls_max (patterns removed, process flags kept), and after the
# session stopped (trace session destroyed). Median of 5 runs each.
#
#   mix run bench/calls_trace.exs
#
# Budget: once the trace has stopped or been removed, a call costs at most
# 1.5 times an untraced one (plus 20 ns of timer noise); the traced cost is
# reported, not bounded. Needs OTP 28 or later.

defmodule CallsBench.Target do
  def run(value), do: value + 1
end

alias Insider.Live

calls = 200_000
traced_calls = 500
runs = 5

time = fn count ->
  started = System.monotonic_time(:nanosecond)
  Enum.each(1..count, &CallsBench.Target.run/1)
  div(System.monotonic_time(:nanosecond) - started, count)
end

median = fn samples -> samples |> Enum.sort() |> Enum.at(div(length(samples), 2)) end

{:ok, _apps} = Application.ensure_all_started(:insider)

if Insider.Collector.Calls.Tracing.preflight() != :ok do
  IO.puts("skipped: call tracing needs OTP 28 or later")
  System.halt(0)
end

_warm = time.(calls)
untraced = median.(for _run <- 1..runs, do: time.(calls))

{traced, stopped, removed, recorded} =
  Enum.reduce(1..runs, {[], [], [], []}, fn _run, {traced, stopped, removed, recorded} ->
    {:ok, %{"session_id" => id}} =
      Live.start(%{
        "components" => ["calls"],
        "calls" => ["CallsBench.Target.run/1"],
        "calls_results" => "none",
        "calls_max" => traced_calls,
        "calls_rate_max" => 10_000,
        "calls_rate_ms" => 1_000,
        "disclosure" => "rich",
        "max_events" => 4_096
      })

    traced_ns = time.(traced_calls)
    {:ok, batch} = Live.events_since(id, "latest", %{"limit" => 1})
    stopped_ns = time.(calls)
    {:ok, %{"receipt" => receipt}} = Live.stop(id, %{"force" => true})
    0 = receipt["cleanup"]["call_trace"]["traced_after"]
    removed_ns = time.(calls)

    {[traced_ns | traced], [stopped_ns | stopped], [removed_ns | removed],
     [batch["next_cursor"] | recorded]}
  end)

results = %{
  "untraced_ns_per_call" => untraced,
  "traced_ns_per_call" => median.(traced),
  "stopped_at_calls_max_ns_per_call" => median.(stopped),
  "removed_ns_per_call" => median.(removed),
  "receipts_per_run" => recorded,
  "otp_release" => List.to_string(:erlang.system_info(:otp_release))
}

IO.puts(Jason.encode!(results, pretty: true))

budget = div(untraced * 3, 2) + 20

for key <- ["stopped_at_calls_max_ns_per_call", "removed_ns_per_call"] do
  if results[key] > budget do
    IO.puts("FAIL #{key} #{results[key]} ns > budget #{budget} ns")
    System.halt(1)
  end
end

IO.puts("PASS: a stopped or removed trace costs at most #{budget} ns per call")
