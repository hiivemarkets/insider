defmodule Insider.Collector.SystemMonitor.Receiver do
  @moduledoc false

  alias Insider.Collector.SystemMonitor.Handler

  @spec start_link(map(), reference(), pid()) :: {:ok, pid()}
  def start_link(config, control_ref, collector) do
    pid = spawn_link(fn -> init(config, control_ref, collector) end)
    {:ok, pid}
  end

  @spec barrier(pid(), reference(), timeout()) :: :ok | {:error, :receiver_busy}
  def barrier(receiver, control_ref, timeout) do
    request = make_ref()
    send(receiver, {:insider_system_monitor, control_ref, :barrier, self(), request})

    receive do
      {:insider_system_monitor, ^control_ref, :barrier_ack, ^request} -> :ok
    after
      timeout -> {:error, :receiver_busy}
    end
  end

  @spec stop(pid(), reference(), timeout()) ::
          :stopped | :forced | :cleanup_unknown | :already_stopped
  def stop(receiver, control_ref, timeout) do
    if Process.alive?(receiver) do
      monitor = Process.monitor(receiver)
      send(receiver, {:insider_system_monitor, control_ref, :stop})

      receive do
        {:DOWN, ^monitor, :process, ^receiver, :normal} -> :stopped
        {:DOWN, ^monitor, :process, ^receiver, _reason} -> :forced
      after
        timeout ->
          Process.exit(receiver, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^receiver, _reason} -> :forced
          after
            timeout ->
              Process.demonitor(monitor, [:flush])
              :cleanup_unknown
          end
      end
    else
      :already_stopped
    end
  end

  defp init(config, control_ref, collector) do
    Process.flag(:message_queue_data, :off_heap)
    loop(config, control_ref, collector, nil)
  end

  defp loop(config, control_ref, collector, delivery_waiter) do
    receive do
      {:insider_system_monitor, ^control_ref, :barrier, caller, request} when is_pid(caller) ->
        case Insider.Collector.SystemMonitor.Backend.delivery_reference(config.ownership) do
          {:ok, delivery_ref} ->
            loop(config, control_ref, collector, {delivery_ref, caller, request})

          :unsupported ->
            send(caller, {:insider_system_monitor, control_ref, :barrier_ack, request})
            loop(config, control_ref, collector, delivery_waiter)
        end

      {:trace_delivered, _tracee, delivery_ref}
      when is_tuple(delivery_waiter) and elem(delivery_waiter, 0) == delivery_ref ->
        {_ref, caller, request} = delivery_waiter
        send(caller, {:insider_system_monitor, control_ref, :barrier_ack, request})
        loop(config, control_ref, collector, nil)

      {:insider_system_monitor, ^control_ref, :stop} ->
        :ok

      message ->
        case Handler.capture(message, config) do
          :overload ->
            send(collector, {:insider_system_monitor, control_ref, :overload, self()})
            loop(config, control_ref, collector, delivery_waiter)

          _result ->
            loop(config, control_ref, collector, delivery_waiter)
        end
    end
  end
end
