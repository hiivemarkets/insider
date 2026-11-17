defmodule Insider.Lab.Live.Watch.Signals do
  @moduledoc false

  # While a watch runs, SIGTERM ends the watch (so it can unsubscribe and
  # report) instead of stopping the VM. Every other signal keeps the default
  # handler's behaviour. `restore/0` reinstalls the default handler.

  @behaviour :gen_event

  @server :erl_signal_server
  @default :erl_signal_handler

  @spec install(pid()) :: :ok
  def install(watcher) when is_pid(watcher),
    do: :gen_event.swap_handler(@server, {@default, :swap}, {__MODULE__, watcher})

  @spec restore() :: :ok
  def restore, do: :gen_event.swap_handler(@server, {__MODULE__, :swap}, {@default, []})

  @impl :gen_event
  def init({watcher, _previous}), do: {:ok, watcher}

  @impl :gen_event
  def handle_event(:sigterm, watcher) do
    send(watcher, Insider.Lab.Live.Watch.stop_message())
    {:ok, watcher}
  end

  def handle_event(signal, watcher) do
    {:ok, _state} = @default.handle_event(signal, {:state})
    {:ok, watcher}
  end

  @impl :gen_event
  def handle_call(_request, watcher), do: {:ok, :ok, watcher}

  @impl :gen_event
  def handle_info(_message, watcher), do: {:ok, watcher}
end
