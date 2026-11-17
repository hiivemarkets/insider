defmodule Insider.Fixtures.Runtime do
  @moduledoc false

  @timeout 1_000

  alias Insider.Fixtures.Observation

  @spec mailbox_growth(pos_integer(), :faulty | :healthy, pos_integer()) :: Observation.t()
  def mailbox_growth(run_id, variant, work_items) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn -> mailbox_worker(parent, run_id, variant, 0) end)

    try do
      receive_fixture!({:mailbox_ready, run_id, pid})
      {samples, progress} = mailbox_observation(pid, parent, run_id, variant, work_items)
      settled = %{progress: progress, queued: message_queue_length(pid)}
      stop_process(pid, monitor)

      observation(run_id, :mailbox_growth, variant,
        samples: samples,
        settled: settled,
        resources: [pid]
      )
    after
      ensure_stopped(pid, monitor)
    end
  end

  @spec leaked_task(pos_integer(), :faulty | :healthy) :: Observation.t()
  def leaked_task(run_id, variant) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:task_ready, run_id, self()})
        receive_fixture!(:release)
      end)

    monitor = Process.monitor(pid)

    try do
      receive_fixture!({:task_ready, run_id, pid})

      {live_tasks, completion} =
        case variant do
          :faulty ->
            live_tasks = live_process_count(pid)
            {live_tasks, event(1, :scenario_completed, %{live_tasks: live_tasks})}

          :healthy ->
            release_and_await(pid, monitor, :ok)
            live_tasks = live_process_count(pid)
            {live_tasks, event(1, :scenario_completed, %{live_tasks: live_tasks})}
        end

      if variant == :faulty, do: release_and_await(pid, monitor, 0)

      observation(run_id, :leaked_task, variant,
        events: [completion],
        samples: %{live_tasks: live_tasks},
        settled: %{live_tasks: 0},
        resources: [pid]
      )
    after
      ensure_stopped(pid, monitor)
    end
  end

  @spec late_effect(pos_integer(), :faulty | :healthy) :: Observation.t()
  def late_effect(run_id, variant) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive_fixture!({:release, run_id})
        send(parent, {:effect, run_id})
      end)

    try do
      events =
        case variant do
          :faulty ->
            :timeout = await_effect(run_id)
            timeout = event(1, :operation_timed_out)
            send(pid, {:release, run_id})
            receive_fixture!({:effect, run_id})
            [timeout, event(2, :effect_observed)]

          :healthy ->
            send(pid, {:release, run_id})
            receive_fixture!({:effect, run_id})
            [event(1, :effect_observed), event(2, :operation_completed)]
        end

      await_down!(pid, monitor)
      observation(run_id, :late_effect, variant, events: events, resources: [pid])
    after
      ensure_stopped(pid, monitor)
    end
  end

  @spec recorder_pressure(pos_integer(), :faulty | :healthy, pos_integer()) :: Observation.t()
  def recorder_pressure(run_id, variant, capacity) do
    parent = self()
    {pid, monitor} = spawn_monitor(fn -> pressure_sink(parent, run_id, capacity) end)

    try do
      receive_fixture!({:pressure_ready, run_id, pid})
      offered = if variant == :faulty, do: capacity + 1, else: capacity
      Enum.each(1..offered, &send(pid, {:signal, &1}))
      queued = message_queue_length(pid)
      send(pid, {:drain, parent})

      {observed_offered, accepted, sequences} =
        receive_fixture_result!({:pressure_drained, run_id})

      ^offered = observed_offered
      await_down!(pid, monitor)

      observation(run_id, :recorder_overload, variant,
        events: Enum.map(sequences, &event(&1, :runtime_signal)),
        samples: %{
          accepted: accepted,
          declared_capacity: capacity,
          offered: offered,
          queued: queued
        },
        resources: [pid]
      )
    after
      ensure_stopped(pid, monitor)
    end
  end

  defp mailbox_worker(parent, run_id, :faulty, progress) do
    send(parent, {:mailbox_ready, run_id, self()})
    receive_fixture!(:release)
    mailbox_loop(run_id, progress)
  end

  defp mailbox_worker(parent, run_id, :healthy, progress) do
    send(parent, {:mailbox_ready, run_id, self()})
    mailbox_loop(run_id, progress)
  end

  defp mailbox_loop(run_id, progress) do
    receive do
      {:work, _item} ->
        mailbox_loop(run_id, progress + 1)

      {:barrier, caller} ->
        send(caller, {:mailbox_progress, run_id, progress})
        mailbox_loop(run_id, progress)

      :release ->
        mailbox_loop(run_id, progress)

      :stop ->
        :ok
    after
      @timeout -> exit(:fixture_timeout)
    end
  end

  defp mailbox_observation(pid, parent, run_id, :faulty, work_items) do
    first_batch = div(work_items, 2)
    enqueue_work(pid, 1, first_batch)
    first_queue = message_queue_length(pid)
    enqueue_work(pid, first_batch + 1, work_items - first_batch)
    second_queue = message_queue_length(pid)
    send(pid, {:barrier, parent})
    samples = %{progress: 0, queued: second_queue, queue_growth: [first_queue, second_queue]}
    send(pid, :release)
    {samples, receive_progress!(run_id)}
  end

  defp mailbox_observation(pid, parent, run_id, :healthy, work_items) do
    first_batch = div(work_items, 2)
    enqueue_work(pid, 1, first_batch)
    send(pid, {:barrier, parent})
    first_progress = receive_progress!(run_id)
    first_queue = message_queue_length(pid)
    enqueue_work(pid, first_batch + 1, work_items - first_batch)
    send(pid, {:barrier, parent})
    progress = receive_progress!(run_id)
    second_queue = message_queue_length(pid)

    samples = %{
      progress: progress,
      progress_samples: [first_progress, progress],
      queued: second_queue,
      queue_growth: [first_queue, second_queue]
    }

    {samples, progress}
  end

  defp enqueue_work(_pid, _next_item, 0), do: :ok

  defp enqueue_work(pid, next_item, remaining) do
    send(pid, {:work, next_item})
    enqueue_work(pid, next_item + 1, remaining - 1)
  end

  defp receive_progress!(run_id) do
    receive do
      {:mailbox_progress, ^run_id, progress} -> progress
    after
      @timeout -> raise "fixture timed out awaiting mailbox progress"
    end
  end

  defp message_queue_length(pid) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)
    length
  end

  defp stop_process(pid, monitor) do
    send(pid, :stop)
    await_down!(pid, monitor)
  end

  defp pressure_sink(parent, run_id, capacity) do
    send(parent, {:pressure_ready, run_id, self()})
    receive_fixture!({:drain, parent})
    {offered, accepted, retained_sequences} = drain_signals(capacity, 0, 0, [])

    send(
      parent,
      {:pressure_drained, run_id, {offered, accepted, Enum.reverse(retained_sequences)}}
    )
  end

  defp drain_signals(capacity, offered, accepted, retained) do
    receive do
      {:signal, sequence} when accepted < capacity ->
        drain_signals(capacity, offered + 1, accepted + 1, [sequence | retained])

      {:signal, _sequence} ->
        drain_signals(capacity, offered + 1, accepted, retained)
    after
      0 -> {offered, accepted, retained}
    end
  end

  defp release_and_await(pid, monitor, result) do
    send(pid, :release)
    await_down!(pid, monitor)
    result
  end

  defp live_process_count(pid), do: if(Process.alive?(pid), do: 1, else: 0)

  defp await_down!(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @timeout -> raise "fixture process did not terminate"
    end
  end

  defp ensure_stopped(pid, monitor) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp await_effect(run_id) do
    receive do
      {:effect, ^run_id} -> :effect
    after
      0 -> :timeout
    end
  end

  defp receive_fixture!(message) do
    receive do
      ^message -> message
    after
      @timeout -> raise "fixture synchronization timed out"
    end
  end

  defp receive_fixture_result!({tag, run_id}) do
    receive do
      {^tag, ^run_id, result} -> result
    after
      @timeout -> raise "fixture synchronization timed out"
    end
  end

  defp observation(run_id, scenario, variant, fields) do
    struct!(
      Observation,
      Keyword.merge([run_id: run_id, scenario: scenario, variant: variant], fields)
    )
  end

  defp event(sequence, kind, metadata \\ %{}) do
    %{
      sequence: sequence,
      kind: kind,
      monotonic_time: System.monotonic_time(),
      metadata: metadata
    }
  end
end
