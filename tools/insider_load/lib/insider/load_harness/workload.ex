defmodule Insider.LoadHarness.Workload do
  @moduledoc false

  require Logger

  alias Insider.LoadHarness.Histogram
  alias Insider.LoadHarness.Metrics
  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.SessionSupport

  @tick_us 10_000
  @lcg_modulus 4_294_967_296

  @spec run(Profile.t(), boolean()) :: map()
  def run(%Profile{} = profile, instrumented?) when is_boolean(instrumented?),
    do: run(profile, instrumented?, fn _boundary -> nil end)

  @doc false
  @spec run(Profile.t(), boolean(), (atom() -> term())) :: map()
  def run(%Profile{} = profile, instrumented?, boundary_observer)
      when is_boolean(instrumented?) and is_function(boundary_observer, 1) do
    run(profile, instrumented?, boundary_observer, [])
  end

  @doc false
  @spec run(Profile.t(), boolean(), (atom() -> term()), keyword()) :: map()
  def run(%Profile{} = profile, instrumented?, boundary_observer, options)
      when is_boolean(instrumented?) and is_function(boundary_observer, 1) and is_list(options) do
    runtime = runtime(options)

    warmed =
      initial_state(profile)
      |> run_segment(
        profile.warmup_ms,
        profile.rate_per_second,
        profile,
        instrumented?,
        runtime
      )

    started_at = runtime.monotonic_time.()
    metrics_start = Metrics.snapshot()

    measured = %{
      warmed
      | completed: 0,
        errors: 0,
        histogram: Histogram.new(),
        max_tick_lag_us: 0,
        metrics_start: metrics_start,
        missed: 0,
        missed_remainder: 0,
        missed_skipped_tick: 0,
        next_sample_us: started_at + profile.sample_interval_ms * 1_000,
        samples: [],
        started_at_us: started_at
    }

    steady =
      run_segment(
        measured,
        profile.steady_ms,
        profile.rate_per_second,
        profile,
        instrumented?,
        runtime
      )

    before_overload = boundary_observer.(:before_overload)

    overloaded =
      steady
      |> run_segment(
        profile.overload_ms,
        profile.overload_rate_per_second,
        profile,
        instrumented?,
        runtime
      )

    after_overload = boundary_observer.(:after_overload)

    overload = %{
      "completed_operations" => overloaded.completed - steady.completed,
      "missed_operations" => overloaded.missed - steady.missed,
      "scheduled_operations" =>
        scheduled_operations_for_duration(
          profile.overload_rate_per_second,
          profile.overload_ms
        )
    }

    measured =
      run_segment(overloaded, profile.recovery_ms, 0, profile, instrumented?, runtime)

    metrics = Metrics.delta(metrics_start, Metrics.snapshot())
    samples = ensure_final_sample(measured, profile, metrics, runtime)
    elapsed_us = max(runtime.monotonic_time.() - started_at, 1)
    latency = Histogram.summary(measured.histogram)

    %{
      "host" => %{
        "throughput_per_second" => div(measured.completed * 1_000_000, elapsed_us),
        "errors" => measured.errors,
        "missed_operations" => measured.missed,
        "latency_p99_us" => latency["latency_p99_us"]
      },
      "scheduling" => %{
        "max_tick_lag_us" => measured.max_tick_lag_us,
        "missed_by_cause" => %{
          "segment_end_remainder" => measured.missed_remainder,
          "skipped_tick" => measured.missed_skipped_tick
        },
        "missed_by_segment" => %{
          "overload" => overloaded.missed - steady.missed,
          "recovery" => measured.missed - overloaded.missed,
          "steady" => steady.missed,
          "warmup" => warmed.missed
        }
      },
      "runtime" => Metrics.report_runtime(metrics),
      "samples" => samples,
      "metrics_available" => metrics.available,
      "overload_evidence" => %{
        "after" => after_overload,
        "before" => before_overload
      },
      "overload" => overload,
      "completed" => measured.completed,
      "missed" => measured.missed,
      "histogram" => latency
    }
  end

  @doc false
  @spec scheduled_operations(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def scheduled_operations(rate_per_second, tick_index)
      when is_integer(rate_per_second) and rate_per_second >= 0 and is_integer(tick_index) and
             tick_index >= 0 do
    current = div(rate_per_second * tick_index * @tick_us, 1_000_000)
    following = div(rate_per_second * (tick_index + 1) * @tick_us, 1_000_000)
    following - current
  end

  @doc false
  @spec scheduled_operations_for_duration(non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def scheduled_operations_for_duration(rate_per_second, duration_ms)
      when is_integer(rate_per_second) and rate_per_second >= 0 and is_integer(duration_ms) and
             duration_ms >= 0 do
    div(rate_per_second * duration_ms, 1_000)
  end

  defp initial_state(profile) do
    %{
      completed: 0,
      errors: 0,
      histogram: Histogram.new(),
      max_tick_lag_us: 0,
      metrics_start: nil,
      missed: 0,
      missed_remainder: 0,
      missed_skipped_tick: 0,
      next_sample_us: nil,
      random: profile.seed,
      samples: [],
      started_at_us: nil
    }
  end

  defp run_segment(state, 0, _rate, _profile, _instrumented?, _runtime), do: state

  defp run_segment(state, duration_ms, rate, profile, instrumented?, runtime) do
    segment_start = runtime.monotonic_time.()
    segment_end = segment_start + duration_ms * 1_000
    scheduled = scheduled_operations_for_duration(rate, duration_ms)

    run_ticks(
      state,
      segment_start,
      segment_end,
      rate,
      0,
      scheduled,
      state.completed,
      state.missed,
      profile,
      instrumented?,
      runtime
    )
  end

  defp run_ticks(
         state,
         next_tick,
         segment_end,
         rate,
         tick_index,
         scheduled,
         completed_before,
         missed_before,
         profile,
         instrumented?,
         runtime
       ) do
    now = runtime.monotonic_time.()

    if now >= segment_end do
      state
      |> observe_lag(now - segment_end)
      |> close_segment(scheduled, completed_before, missed_before, profile, runtime)
    else
      state = maybe_sample(state, profile, runtime)

      if now < next_tick do
        runtime.wait_until.(min(next_tick, segment_end))

        run_ticks(
          state,
          next_tick,
          segment_end,
          rate,
          tick_index,
          scheduled,
          completed_before,
          missed_before,
          profile,
          instrumented?,
          runtime
        )
      else
        lag_us = now - next_tick
        skipped_ticks = div(lag_us, @tick_us)

        skipped =
          rate
          |> scheduled_between_ticks(tick_index, skipped_ticks)
          |> min(remaining_operations(state, scheduled, completed_before, missed_before))

        tick_index = tick_index + skipped_ticks

        state = %{
          observe_lag(state, lag_us)
          | missed: state.missed + skipped,
            missed_skipped_tick: state.missed_skipped_tick + skipped
        }

        operations =
          min(
            scheduled_operations(rate, tick_index),
            remaining_operations(state, scheduled, completed_before, missed_before)
          )

        state =
          execute_batch(state, operations, segment_end, profile, instrumented?, runtime)

        run_ticks(
          state,
          next_tick + (skipped_ticks + 1) * @tick_us,
          segment_end,
          rate,
          tick_index + 1,
          scheduled,
          completed_before,
          missed_before,
          profile,
          instrumented?,
          runtime
        )
      end
    end
  end

  defp execute_batch(state, 0, _segment_end, _profile, _instrumented?, _runtime), do: state

  defp execute_batch(state, count, segment_end, profile, instrumented?, runtime) do
    Enum.reduce_while(1..count, state, fn _index, accumulator ->
      started = runtime.monotonic_time.()

      if started >= segment_end do
        {:halt, accumulator}
      else
        next_random = rem(accumulator.random * 1_664_525 + 1_013_904_223, @lcg_modulus)
        checksum = :erlang.phash2({next_random, accumulator.completed}, 1_073_741_824)
        sequence = accumulator.completed + 1

        if instrumented? do
          operation_duration = max(runtime.monotonic_time.() - started, 0)
          emit(sequence, operation_duration, profile)
        end

        finished = runtime.monotonic_time.()

        if finished >= segment_end do
          {:halt, accumulator}
        else
          observed_duration = max(finished - started, 0)

          next_state = %{
            accumulator
            | completed: sequence,
              errors: accumulator.errors + if(is_integer(checksum), do: 0, else: 1),
              histogram: Histogram.observe(accumulator.histogram, observed_duration),
              random: next_random
          }

          runtime.after_operation.(sequence)
          {:cont, next_state}
        end
      end
    end)
  end

  defp emit(sequence, duration, profile) do
    if rem(sequence, profile.telemetry_every) == 0 do
      :telemetry.execute(SessionSupport.telemetry_event(), %{duration: duration}, %{})
    end

    if rem(sequence, profile.logger_every) == 0 do
      Logger.info("insider synthetic load operation")
    end

    :ok
  end

  defp maybe_sample(%{next_sample_us: nil} = state, _profile, _runtime), do: state

  defp maybe_sample(state, profile, runtime) do
    now = runtime.monotonic_time.()

    if now >= state.next_sample_us and length(state.samples) < min(profile.max_samples, 512) do
      metrics = Metrics.delta(state.metrics_start, Metrics.snapshot())
      latency = Histogram.summary(state.histogram)
      elapsed_us = max(now - state.started_at_us, 1)

      sample =
        metrics
        |> Metrics.report_runtime()
        |> Map.merge(%{
          "offset_ms" => div(elapsed_us, 1_000),
          "throughput_per_second" => div(state.completed * 1_000_000, elapsed_us),
          "errors" => state.errors,
          "missed_operations" => state.missed,
          "latency_p99_us" => latency["latency_p99_us"]
        })

      %{
        state
        | samples: [sample | state.samples],
          next_sample_us: now + profile.sample_interval_ms * 1_000
      }
    else
      state
    end
  end

  defp ensure_final_sample(state, profile, metrics, runtime) do
    samples = Enum.reverse(state.samples)
    elapsed_us = max(runtime.monotonic_time.() - state.started_at_us, 1)

    final =
      metrics
      |> Metrics.report_runtime()
      |> Map.merge(%{
        "offset_ms" => max(div(elapsed_us, 1_000), 1),
        "throughput_per_second" => div(state.completed * 1_000_000, elapsed_us),
        "errors" => state.errors,
        "missed_operations" => state.missed,
        "latency_p99_us" => Histogram.summary(state.histogram)["latency_p99_us"]
      })

    limit = min(profile.max_samples, 512)

    cond do
      samples == [] ->
        [final]

      List.last(samples)["offset_ms"] == final["offset_ms"] ->
        List.replace_at(samples, -1, final)

      length(samples) < limit ->
        samples ++ [final]

      true ->
        Enum.take(samples, limit - 1) ++ [final]
    end
  end

  defp wait_until(deadline_us) do
    remaining_us = deadline_us - System.monotonic_time(:microsecond)

    if remaining_us > 0 do
      receive do
      after
        max(div(remaining_us + 999, 1_000), 1) -> :ok
      end
    end
  end

  defp close_segment(state, scheduled, completed_before, missed_before, profile, runtime) do
    missed = remaining_operations(state, scheduled, completed_before, missed_before)

    %{state | missed: state.missed + missed, missed_remainder: state.missed_remainder + missed}
    |> maybe_sample(profile, runtime)
  end

  # Largest observed overshoot of a tick or segment deadline. A deadline is
  # only observed when the loop regains control, so a stall that ends after
  # the segment deadline is measured against that deadline.
  defp observe_lag(state, lag_us),
    do: %{state | max_tick_lag_us: max(state.max_tick_lag_us, lag_us)}

  defp remaining_operations(state, scheduled, completed_before, missed_before) do
    completed = state.completed - completed_before
    missed = state.missed - missed_before
    max(scheduled - completed - missed, 0)
  end

  defp scheduled_between_ticks(_rate, _tick_index, 0), do: 0

  defp scheduled_between_ticks(rate, tick_index, tick_count) do
    last_tick = tick_index + tick_count

    div(rate * last_tick * @tick_us, 1_000_000) -
      div(rate * tick_index * @tick_us, 1_000_000)
  end

  defp runtime(options) do
    %{
      monotonic_time:
        Keyword.get(options, :monotonic_time, fn -> System.monotonic_time(:microsecond) end),
      wait_until: Keyword.get(options, :wait_until, &wait_until/1),
      after_operation: Keyword.get(options, :after_operation, fn _sequence -> :ok end)
    }
  end
end
