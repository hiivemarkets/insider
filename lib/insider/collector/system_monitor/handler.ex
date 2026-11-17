defmodule Insider.Collector.SystemMonitor.Handler do
  @moduledoc false

  @max_info_entries 16
  @max_integer 9_223_372_036_854_775_807
  @gc_keys [
    :timeout,
    :heap_size,
    :heap_block_size,
    :stack_size,
    :mbuf_size,
    :old_heap_size,
    :old_heap_block_size
  ]

  @spec capture(term(), map()) :: :ok | :overload
  def capture(message, config) do
    bump(config.stats, 1)

    if :atomics.get(config.enabled, 1) == 0 do
      bump(config.stats, 10)
      :ok
    else
      capture_enabled(message, config)
    end
  rescue
    _error -> safe_failure(config)
  catch
    _kind, _reason -> safe_failure(config)
  end

  defp capture_enabled(message, config) do
    sequence = :atomics.add_get(config.sequence, 1, 1)

    case maybe_disable_overloaded(config, sequence) do
      :overload ->
        bump(config.stats, 10)
        :overload

      :ok ->
        case normalize(message) do
          {:ok, event, shape} ->
            if Map.has_key?(config.allowed_events, event),
              do: enqueue(config, sequence, shape),
              else: bump(config.stats, 4)

          :error ->
            bump(config.stats, 4)
        end

        :ok
    end
  end

  defp normalize({:monitor, pid, :long_gc, info}) when is_pid(pid),
    do: tag(:long_gc, monitored_info("vm_long_gc", pid, info, @gc_keys))

  defp normalize({:monitor, pid, :large_heap, info}) when is_pid(pid),
    do: tag(:large_heap, monitored_info("vm_large_heap", pid, info, @gc_keys -- [:timeout]))

  defp normalize({:monitor, pid, :long_message_queue, long})
       when is_pid(pid) and is_boolean(long) do
    with {:ok, subject} <- subject(pid) do
      {:ok, :long_message_queue,
       %{
         kind: "vm_long_message_queue",
         subject: subject,
         attributes: %{"state" => if(long, do: "entered", else: "recovered")}
       }}
    end
  end

  defp normalize({:monitor, target, :long_schedule, info})
       when is_pid(target) or is_port(target),
       do:
         tag(
           :long_schedule,
           monitored_info("vm_long_schedule", target, info, [:timeout, :port_op])
         )

  defp normalize({:monitor, pid, :busy_port, port}) when is_pid(pid) and is_port(port),
    do: tag(:busy_port, busy("vm_busy_port", pid, port))

  defp normalize({:monitor, pid, :busy_dist_port, port}) when is_pid(pid) and is_port(port),
    do: tag(:busy_dist_port, busy("vm_busy_dist_port", pid, port))

  defp normalize(_message), do: :error

  defp tag(event, {:ok, shape}), do: {:ok, event, shape}
  defp tag(_event, :error), do: :error

  defp monitored_info(kind, target, info, keys) do
    with {:ok, attributes} <- info_attributes(info, keys, @max_info_entries, %{}),
         {:ok, subject} <- subject(target) do
      {:ok, %{kind: kind, subject: subject, attributes: attributes}}
    else
      _failure -> :error
    end
  end

  defp busy(kind, pid, port) do
    with {:ok, subject} <- subject(pid), {:ok, port_id} <- target_id(port) do
      {:ok, %{kind: kind, subject: subject, attributes: %{"port" => port_id}}}
    else
      _failure -> :error
    end
  end

  defp info_attributes([], _keys, _remaining, attributes), do: {:ok, attributes}
  defp info_attributes(_info, _keys, 0, _attributes), do: :error

  defp info_attributes([{key, value} | tail], keys, remaining, attributes) do
    case project_info(key, value, keys, attributes) do
      {:ok, projected} -> info_attributes(tail, keys, remaining - 1, projected)
      :error -> :error
    end
  end

  defp info_attributes(_improper, _keys, _remaining, _attributes), do: :error

  defp project_info(key, value, keys, attributes)
       when is_integer(value) and value >= 0 and value <= @max_integer do
    if key in keys do
      projected =
        case key do
          :timeout -> Map.put(attributes, "timeout_ms", value)
          :heap_size -> Map.put(attributes, "heap_size_words", value)
          :heap_block_size -> Map.put(attributes, "heap_block_size_words", value)
          :stack_size -> Map.put(attributes, "stack_size_words", value)
          :mbuf_size -> Map.put(attributes, "message_buffer_size_words", value)
          :old_heap_size -> Map.put(attributes, "old_heap_size_words", value)
          :old_heap_block_size -> Map.put(attributes, "old_heap_block_size_words", value)
          _key -> attributes
        end

      {:ok, projected}
    else
      {:ok, attributes}
    end
  end

  defp project_info(:port_op, value, keys, attributes) do
    if :port_op in keys and value in [:timeout, :input, :output, :event, :dist_cmd],
      do: {:ok, Map.put(attributes, "port_operation", Atom.to_string(value))},
      else: :error
  end

  defp project_info(key, _value, keys, attributes) do
    if key in keys, do: :error, else: {:ok, attributes}
  end

  defp subject(target) do
    with {:ok, value} <- target_id(target) do
      {:ok,
       %{
         "namespace" => if(is_pid(target), do: "process", else: "port"),
         "scope" => nil,
         "value" => value
       }}
    end
  end

  defp target_id(pid) when is_pid(pid) do
    if node(pid) == node(),
      do: {:ok, pid |> :erlang.pid_to_list() |> to_string()},
      else: :error
  end

  defp target_id(port) when is_port(port) do
    if node(port) == node(),
      do: {:ok, port |> :erlang.port_to_list() |> to_string()},
      else: :error
  end

  defp enqueue(config, sequence, shape) do
    slot = rem(sequence - 1, config.inbox_size)

    case :ets.insert_new(config.inbox, {slot, sequence, shape}) do
      true -> bump(config.stats, 2)
      false -> bump(config.stats, 3)
    end
  end

  defp maybe_disable_overloaded(config, sequence) do
    if rem(sequence, config.backlog_check_every) == 0 do
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, length} ->
          update_high_water(config.high_water, length)

          if length >= config.max_mailbox_size do
            if :atomics.exchange(config.enabled, 1, 0) == 1 do
              bump(config.stats, 7)
              :overload
            else
              :ok
            end
          else
            :ok
          end

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp update_high_water(counter, value) do
    current = :atomics.get(counter, 1)

    if value > current and :atomics.compare_exchange(counter, 1, current, value) != current,
      do: update_high_water(counter, value),
      else: :ok
  end

  defp safe_failure(%{stats: stats}) do
    bump(stats, 9)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_failure(_config), do: :ok
  defp bump(stats, index), do: :counters.add(stats, index, 1)
end
