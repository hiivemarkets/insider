defmodule Insider.LoadHarness.Provider do
  @moduledoc false

  @behaviour Insider.Collector.Poller.Provider

  @impl true
  def vm_sample do
    {:ok, :complete,
     %{
       "memory_bytes" => :erlang.memory(:total),
       "port_count" => :erlang.system_info(:port_count),
       "process_count" => :erlang.system_info(:process_count),
       "run_queue" => :erlang.statistics(:run_queue)
     }, []}
  rescue
    _error -> {:error, :failed}
  end

  @impl true
  def process_sample(pid) when is_pid(pid) do
    case Process.info(pid, [:message_queue_len, :memory, :reductions]) do
      values when is_list(values) ->
        {:ok, :complete, Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end), []}

      _other ->
        {:error, :exited}
    end
  rescue
    _error -> {:error, :failed}
  end
end
