alias Insider.Collector.Telemetry, as: TelemetryCollector
alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
alias Insider.Event.Canonical
alias Insider.Recorder
alias Insider.Redaction.Policy, as: RedactionPolicy

event_name = [:insider, :benchmark, :composed, :event]
baseline_event_name = [:insider, :benchmark, :composed, :baseline]
handler_id = "insider-composed-pipeline-benchmark"
lossless_iterations = 4_096
batch_size = 256
overload_iterations = 2_048
inbox_size = 1_024
target_events_per_second = 2_500
word_size = :erlang.system_info(:wordsize)

measure = fn function ->
  started = System.monotonic_time(:nanosecond)
  result = function.()
  {System.monotonic_time(:nanosecond) - started, result}
end

rate = fn count, elapsed_ns -> div(count * 1_000_000_000, max(elapsed_ns, 1)) end

ets_bytes = fn recorder ->
  [:control, :entries, :ids, :normal, :protected, :indexes, :rates]
  |> Enum.map(&Map.fetch!(recorder, &1))
  |> Enum.reduce(0, fn table, total -> total + :ets.info(table, :memory) * word_size end)
end

update_high_water = fn recorder, collector_inbox, status, current ->
  %{
    "event_count" => max(current["event_count"], status.retained_count),
    "event_bytes" => max(current["event_bytes"], status.retained_bytes),
    "storage_bytes" => max(current["storage_bytes"], status.storage_bytes),
    "recorder_ets_bytes" => max(current["recorder_ets_bytes"], ets_bytes.(recorder)),
    "collector_inbox_ets_bytes" =>
      max(current["collector_inbox_ets_bytes"], :ets.info(collector_inbox, :memory) * word_size)
  }
end

{:ok, redaction_policy} =
  RedactionPolicy.new(
    id: "composed-pipeline-benchmark",
    maximum_sensitivity: :internal,
    rules: []
  )

{:ok, telemetry_policy} =
  TelemetryPolicy.new(
    id: "composed-pipeline-benchmark",
    events: [
      [
        name: event_name,
        kind: "telemetry.benchmark.event",
        lifecycle: "benchmark",
        phase: :event
      ]
    ],
    metadata: [component: "component"],
    measurements: [duration: "duration"],
    correlation: []
  )

{:ok, recorder_pid} =
  Recorder.start_link(
    classification: {:internal, redaction_policy},
    max_events: lossless_iterations + inbox_size,
    max_bytes: 16 * 1_024 * 1_024,
    rate_limit_count: lossless_iterations + inbox_size,
    max_rate_keys: 8,
    post_trigger_ms: 0
  )

{:ok, recorder} = Recorder.handle(recorder_pid)

{:ok, collector} =
  TelemetryCollector.start_link(recorder, telemetry_policy,
    authority: "development-benchmark",
    boot_id: "composed-pipeline-benchmark",
    clock_id: "telemetry-order",
    environment: :development,
    handler_id: handler_id,
    source_instance_id: "composed-pipeline-benchmark",
    inbox_size: inbox_size,
    batch_size: batch_size,
    drain_interval_ms: 1_000
  )

collector_state = :sys.get_state(collector)

try do
  {baseline_elapsed_ns, :ok} =
    measure.(fn ->
      Enum.each(1..lossless_iterations, fn sequence ->
        :telemetry.execute(
          baseline_event_name,
          %{duration: sequence},
          %{component: :benchmark}
        )
      end)
    end)

  initial_high_water = %{
    "event_count" => 0,
    "event_bytes" => 0,
    "storage_bytes" => 0,
    "recorder_ets_bytes" => ets_bytes.(recorder),
    "collector_inbox_ets_bytes" => :ets.info(collector_state.inbox, :memory) * word_size
  }

  {instrumented_elapsed_ns, high_water} =
    measure.(fn ->
      1..div(lossless_iterations, batch_size)
      |> Enum.reduce(initial_high_water, fn batch, current ->
        first = (batch - 1) * batch_size + 1

        Enum.each(first..(first + batch_size - 1), fn sequence ->
          :telemetry.execute(
            event_name,
            %{duration: sequence},
            %{component: :benchmark}
          )
        end)

        {:ok, before_flush} = TelemetryCollector.status(collector)
        true = before_flush.inbox_count <= inbox_size
        {:ok, _flushed} = TelemetryCollector.flush(collector)
        {:ok, recorder_status} = Recorder.status(recorder)
        update_high_water.(recorder, collector_state.inbox, recorder_status, current)
      end)
    end)

  :ok = :sys.suspend(collector)

  {overload_elapsed_ns, :ok} =
    measure.(fn ->
      Enum.each(1..overload_iterations, fn sequence ->
        :telemetry.execute(
          event_name,
          %{duration: lossless_iterations + sequence},
          %{component: :benchmark}
        )
      end)
    end)

  true = :ets.info(collector_state.inbox, :size) == inbox_size
  :ok = :sys.resume(collector)
  {:ok, final_collector} = TelemetryCollector.flush(collector)
  {:ok, final_recorder} = Recorder.status(recorder)
  high_water = update_high_water.(recorder, collector_state.inbox, final_recorder, high_water)

  true =
    final_collector.received ==
      final_collector.enqueued + final_collector.shed + final_collector.invalid +
        final_collector.handler_failures

  true =
    final_collector.enqueued ==
      final_collector.recorded + final_collector.recorder_dropped + final_collector.inbox_count

  true = final_collector.received == lossless_iterations + overload_iterations
  true = final_collector.enqueued == lossless_iterations + inbox_size
  true = final_collector.shed == overload_iterations - inbox_size
  true = final_collector.invalid == 0
  true = final_collector.handler_failures == 0
  true = final_collector.recorded == final_collector.enqueued
  true = final_collector.recorder_dropped == 0
  true = final_collector.inbox_count == 0
  true = final_recorder.counters.offered == final_collector.recorded
  true = final_recorder.counters.accepted == final_collector.recorded
  true = final_recorder.retained_count <= recorder.config.max_events
  true = final_recorder.storage_bytes <= recorder.config.max_bytes

  actual_events_per_second = rate.(lossless_iterations, instrumented_elapsed_ns)
  true = actual_events_per_second >= target_events_per_second

  {:ok, cleanup} = TelemetryCollector.stop(collector)
  true = cleanup.handler in [:removed, :already_detached]
  false = Process.alive?(collector)
  false = Enum.any?(:telemetry.list_handlers(event_name), &(&1.id == handler_id))
  :ok = GenServer.stop(recorder_pid)
  false = Process.alive?(recorder_pid)

  counters = %{
    "offered" => final_collector.received,
    "enqueued" => final_collector.enqueued,
    "shed" => final_collector.shed,
    "invalid" => final_collector.invalid,
    "recorded" => final_collector.recorded,
    "recorder_dropped" => final_collector.recorder_dropped
  }

  result = %{
    "schema" => "insider.benchmark.composed-collector-pipeline/v1",
    "scope" => %{
      "claim" => "bounded development-machine regression measurement",
      "production_capacity" => false,
      "collector" => "telemetry",
      "pipeline" => "telemetry.execute -> fixed-slot inbox -> collector flush -> recorder"
    },
    "source" => %{
      "revision" => System.get_env("INSIDER_BENCHMARK_REVISION", "unrecorded"),
      "worktree_state" => System.get_env("INSIDER_BENCHMARK_WORKTREE_STATE", "unrecorded"),
      "runtime" => %{
        "elixir" => System.version(),
        "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
        "erts" => List.to_string(:erlang.system_info(:version)),
        "schedulers_online" => :erlang.system_info(:schedulers_online),
        "word_size_bytes" => word_size,
        "os" => Enum.join(Tuple.to_list(:os.type()) |> Enum.map(&Atom.to_string/1), "/")
      }
    },
    "bounds" => %{
      "lossless_iterations" => lossless_iterations,
      "batch_size" => batch_size,
      "overload_iterations" => overload_iterations,
      "inbox_events" => inbox_size,
      "recorder_events" => recorder.config.max_events,
      "recorder_bytes" => recorder.config.max_bytes,
      "target_events_per_second" => target_events_per_second
    },
    "comparison" => %{
      "baseline" => %{
        "elapsed_ns" => baseline_elapsed_ns,
        "events_per_second" => rate.(lossless_iterations, baseline_elapsed_ns),
        "ns_per_event" => div(baseline_elapsed_ns, lossless_iterations)
      },
      "instrumented_lossless" => %{
        "elapsed_ns" => instrumented_elapsed_ns,
        "events_per_second" => actual_events_per_second,
        "ns_per_event" => div(instrumented_elapsed_ns, lossless_iterations)
      },
      "overload_ingress" => %{
        "elapsed_ns" => overload_elapsed_ns,
        "events_per_second" => rate.(overload_iterations, overload_elapsed_ns),
        "ns_per_event" => div(overload_elapsed_ns, overload_iterations)
      }
    },
    "counters" => counters,
    "conservation" => %{
      "received_equals_enqueued_plus_shed_plus_invalid_plus_handler_failures" => true,
      "enqueued_equals_recorded_plus_recorder_dropped_plus_inbox" => true
    },
    "high_water" => high_water,
    "cleanup" => %{
      "collector_stopped" => true,
      "drain_scope" => Atom.to_string(cleanup.drain_scope),
      "emitters_quiesced" => true,
      "handler" => Atom.to_string(cleanup.handler),
      "handler_absent" => true,
      "open_lifecycles" => cleanup.open_lifecycles,
      "recorder_stopped" => true,
      "recorder_dropped" => cleanup.recorder_dropped,
      "remaining_inbox_events" => final_collector.inbox_count
    },
    "result" => %{"status" => "passed"}
  }

  IO.puts(Canonical.encode(result))
after
  :telemetry.detach(handler_id)

  if Process.alive?(collector) do
    :ok = :sys.resume(collector)
    TelemetryCollector.stop(collector)
  end

  if Process.alive?(recorder_pid), do: GenServer.stop(recorder_pid)
end
