defmodule Insider.Collector.Poller.Erlang do
  @moduledoc false

  @behaviour Insider.Collector.Poller.Provider

  alias Insider.Collector.Poller.Ets
  alias Insider.Collector.Poller.Ports
  alias Insider.Collector.Poller.Processes

  @process_fields [
    :registered_name,
    :status,
    :message_queue_len,
    :memory,
    :total_heap_size,
    :heap_size,
    :stack_size,
    :reductions,
    :current_function
  ]

  @impl true
  def vm_sample do
    probes = [
      {:memory, &memory/0},
      {:counts, &counts/0},
      {:schedulers, &schedulers/0},
      {:activity, &activity/0}
    ]

    {metrics, unavailable} =
      Enum.reduce(probes, {%{}, []}, fn {name, probe}, {metrics, unavailable} ->
        case safe(probe) do
          {:ok, value} -> {Map.merge(metrics, value), unavailable}
          :error -> {metrics, [Atom.to_string(name) | unavailable]}
        end
      end)

    status = if unavailable == [], do: :complete, else: :partial
    {:ok, status, metrics, Enum.reverse(unavailable)}
  end

  @impl true
  def process_sample(pid) when is_pid(pid) and node(pid) == node() do
    case :erlang.process_info(pid, @process_fields) do
      :undefined -> {:error, :exited}
      values when is_list(values) -> normalize_process(values)
    end
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  def process_sample(_pid), do: {:error, :protected}

  @impl true
  defdelegate process_top(previous, options), to: Processes, as: :top

  @impl true
  defdelegate ets_top(options), to: Ets, as: :top

  @impl true
  defdelegate port_top(previous, options), to: Ports, as: :top

  defp memory do
    :erlang.memory([
      :total,
      :processes,
      :processes_used,
      :system,
      :atom,
      :atom_used,
      :binary,
      :code,
      :ets
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key) <> "_bytes", value} end)
  end

  defp counts do
    %{
      "atom_count" => :erlang.system_info(:atom_count),
      "atom_limit" => :erlang.system_info(:atom_limit),
      "ets_count" => :erlang.system_info(:ets_count),
      "port_count" => :erlang.system_info(:port_count),
      "port_limit" => :erlang.system_info(:port_limit),
      "process_count" => :erlang.system_info(:process_count),
      "process_limit" => :erlang.system_info(:process_limit)
    }
  end

  defp schedulers do
    %{
      "dirty_cpu_schedulers" => :erlang.system_info(:dirty_cpu_schedulers),
      "dirty_io_schedulers" => :erlang.system_info(:dirty_io_schedulers),
      "schedulers" => :erlang.system_info(:schedulers),
      "schedulers_online" => :erlang.system_info(:schedulers_online)
    }
  end

  defp activity do
    %{
      "run_queue_length" => :erlang.statistics(:total_run_queue_lengths_all),
      "total_active_tasks" => :erlang.statistics(:total_active_tasks_all)
    }
  end

  defp normalize_process(values) do
    values = Map.new(values)

    with {:ok, registered_name} <- registered_name(values[:registered_name]),
         {:ok, status} <- vocabulary(values[:status]),
         {:ok, current_function} <- current_function(values[:current_function]),
         true <- Enum.all?(integer_fields(), &valid_counter?(values[&1])) do
      metrics = %{
        "current_function" => current_function,
        "heap_size_words" => values[:heap_size],
        "memory_bytes" => values[:memory],
        "message_queue_len" => values[:message_queue_len],
        "reductions_total" => values[:reductions],
        "registered_name" => registered_name,
        "stack_size_words" => values[:stack_size],
        "status" => status,
        "total_heap_size_words" => values[:total_heap_size]
      }

      {:ok, :complete, metrics, []}
    else
      _other -> {:error, :failed}
    end
  end

  defp integer_fields,
    do: [:heap_size, :memory, :message_queue_len, :reductions, :stack_size, :total_heap_size]

  defp valid_counter?(value),
    do: is_integer(value) and value in 0..9_223_372_036_854_775_807

  defp registered_name([]), do: {:ok, nil}
  defp registered_name(name), do: vocabulary(name)

  defp current_function({module, function, arity}) when is_integer(arity) and arity in 0..255 do
    with {:ok, module} <- vocabulary(module), {:ok, function} <- vocabulary(function) do
      {:ok, %{"arity" => arity, "function" => function, "module" => module}}
    end
  end

  defp current_function(_value), do: {:error, :invalid_current_function}

  defp vocabulary(value) when is_atom(value) do
    string = Atom.to_string(value)

    if byte_size(string) in 1..128 and String.valid?(string),
      do: {:ok, string},
      else: {:error, :invalid_vocabulary}
  end

  defp vocabulary(_value), do: {:error, :invalid_vocabulary}

  defp safe(function) do
    {:ok, function.()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
