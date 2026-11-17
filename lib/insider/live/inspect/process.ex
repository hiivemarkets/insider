defmodule Insider.Live.Inspect.Process do
  @moduledoc false

  # `Insider.Live.process/1`: one process, read with `process_info/2` only.
  # It returns a subset of process_info, the current stacktrace's top
  # frames, link and monitor counts, its binaries' count and bytes, and a
  # mailbox summary: the queued messages counted by shape and size class,
  # and the shapes of the first few. A shape is a message's structure, such
  # as `{:"$gen_call", {pid, list}, {:price, binary}}`: types in place of
  # values, two tuple levels deep. In every profile an atom is shown only as
  # a tuple's first element (its tag); any other atom, a bare atom message
  # included, is `atom`, so a shape never carries a value (an atom can be a
  # credential, as in `{:password, :hunter2}`). No message value, dictionary
  # entry, or state (`sys:get_state/1`) is ever read or returned.
  #
  # The mailbox is read only when it holds at most `mailbox_read_max`
  # messages, by a separate reader under its own heap guard, which keeps
  # only the shape counts; a longer queue is reported by length alone.
  # A `$gen_call` whose caller has exited is counted as a dead call, the
  # signature of a server answering callers that already gave up.

  alias Insider.Collector.Poller.Names
  alias Insider.Live.Error
  alias Insider.Live.Inspect

  @schema "insider.live-process/v1"
  @mailbox_read_max 10_000
  @max_shapes 256
  @shapes_listed 20
  @shape_bytes 160
  @file_bytes 256
  @tuple_elements 6
  # 32 MiB on a 64-bit VM: the copied queue, never the binaries it refers to.
  @reader_heap_words 4_194_304
  @items [
    :registered_name,
    :status,
    :message_queue_len,
    :memory,
    :heap_size,
    :total_heap_size,
    :stack_size,
    :reductions,
    :current_function,
    :initial_call,
    {:dictionary, :"$initial_call"},
    :trap_exit,
    :priority,
    :links,
    :monitors,
    :monitored_by,
    :group_leader,
    :garbage_collection
  ]

  @doc "The longest mailbox whose messages are read for their shapes."
  @spec mailbox_read_max() :: pos_integer()
  def mailbox_read_max, do: @mailbox_read_max

  @spec lists() :: [[String.t()]]
  def lists, do: [["stacktrace", "frames"], ["mailbox", "shapes"], ["mailbox", "first"]]

  @spec inspect(map(), Inspect.context()) :: {:ok, map()} | {:error, map()}
  def inspect(%{target: target, frames: frames, messages: messages}, context) do
    with {:ok, pid} <- resolve(target),
         :ok <- allowed(pid, context),
         {:ok, info} <- info(pid) do
      {:ok,
       %{
         "schema" => @schema,
         "implementation" => "native",
         "pid" => Names.pid(pid),
         "name" => registered(info[:registered_name]),
         "insider" => insider?(info[:group_leader], context),
         "info" => summary(info),
         "stacktrace" => stacktrace(pid, frames),
         "binaries" => binaries(pid),
         "mailbox" => mailbox(pid, info[:message_queue_len], messages, context),
         "observer_effect" =>
           "process_info requests served by the process; its queue is copied to a reader when it holds at most #{@mailbox_read_max} messages"
       }}
    end
  end

  # A pid that is a port or remote, or not alive, is not found.
  defp resolve({:name, name}) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _absent -> not_found(%{"name" => Names.display(name)})
    end
  end

  defp resolve({:pid, pid}) do
    if Process.alive?(pid), do: {:ok, pid}, else: not_found(%{"pid" => Names.pid(pid)})
  end

  defp not_found(details), do: {:error, Error.new("process_not_found", details)}

  defp allowed(pid, context) do
    if is_map_key(context.protected, pid),
      do: {:error, Error.new("protected_process", %{"pid" => Names.pid(pid)})},
      else: :ok
  end

  defp info(pid) do
    case :erlang.process_info(pid, @items) do
      items when is_list(items) -> {:ok, Map.new(items)}
      :undefined -> not_found(%{"pid" => Names.pid(pid)})
    end
  end

  defp insider?(leader, context), do: context.master != nil and leader == context.master

  defp summary(info) do
    {ports, processes} = Enum.split_with(info[:links], &is_port/1)
    gc = info[:garbage_collection]

    %{
      "status" => Atom.to_string(info[:status]),
      "initial_call" =>
        Names.mfa(info[{:dictionary, :"$initial_call"}]) || Names.mfa(info[:initial_call]),
      "current_function" => Names.mfa(info[:current_function]),
      "message_queue_len" => info[:message_queue_len],
      "memory_bytes" => info[:memory],
      "heap_size_words" => info[:heap_size],
      "total_heap_size_words" => info[:total_heap_size],
      "stack_size_words" => info[:stack_size],
      "reductions" => info[:reductions],
      "trap_exit" => info[:trap_exit],
      "priority" => Atom.to_string(info[:priority]),
      "links" => %{"processes" => length(processes), "ports" => length(ports)},
      "monitors" => length(info[:monitors]),
      "monitored_by" => length(info[:monitored_by]),
      "minor_gcs" => Keyword.get(gc, :minor_gcs),
      "fullsweep_after" => Keyword.get(gc, :fullsweep_after)
    }
  end

  defp registered(name) when is_atom(name) and name != [], do: Names.display(name)
  defp registered(_name), do: nil

  defp stacktrace(pid, frames) do
    case :erlang.process_info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        %{
          "frames" => stack |> Enum.take(frames) |> Enum.map(&frame/1),
          "depth" => length(stack)
        }

      :undefined ->
        %{"frames" => [], "depth" => 0}
    end
  end

  defp frame({module, function, arity, location}) do
    arity = if is_list(arity), do: length(arity), else: arity

    %{
      "function" => Names.mfa({module, function, arity}),
      "file" => location |> Keyword.get(:file) |> file(),
      "line" => Keyword.get(location, :line)
    }
  end

  # A source path keeps its end, where the file name is.
  defp file(nil), do: nil
  defp file(file) when is_list(file), do: file |> List.to_string() |> file()
  defp file(file) when is_binary(file), do: Inspect.bound_text(file, @file_bytes, :tail)

  defp binaries(pid) do
    case :erlang.process_info(pid, :binary) do
      {:binary, binaries} ->
        {count, bytes} =
          Enum.reduce(binaries, {0, 0}, fn {_id, size, _refc}, {count, bytes} ->
            {count + 1, bytes + size}
          end)

        %{"count" => count, "bytes" => bytes}

      :undefined ->
        %{"count" => nil, "bytes" => nil}
    end
  end

  defp mailbox(_pid, length, _first, _context) when length == 0,
    do: %{
      "length" => 0,
      "read" => true,
      "reason" => nil,
      "shapes" => [],
      "first" => [],
      "calls" => nil
    }

  defp mailbox(_pid, length, _first, _context) when length > @mailbox_read_max,
    do: unread(length, "queue_over_read_max")

  defp mailbox(pid, length, first, context) do
    reply_to = :erlang.alias([:explicit_unalias])

    {reader, monitor} =
      :erlang.spawn_opt(
        fn -> send(reply_to, {reply_to, shapes(pid, first)}) end,
        [
          :monitor,
          {:max_heap_size,
           %{
             size: @reader_heap_words,
             kill: true,
             include_shared_binaries: false,
             error_logger: false
           }}
        ]
      )

    receive do
      {^reply_to, {:ok, read}} ->
        Process.demonitor(monitor, [:flush])
        true = :erlang.unalias(reply_to)
        Map.merge(%{"length" => length, "read" => true, "reason" => nil}, read)

      {^reply_to, :undefined} ->
        Process.demonitor(monitor, [:flush])
        true = :erlang.unalias(reply_to)
        unread(length, "process_exited")

      {:DOWN, ^monitor, :process, ^reader, _reason} ->
        true = :erlang.unalias(reply_to)
        unread(length, "reader_heap_limit")
    after
      Inspect.remaining(context) ->
        true = :erlang.unalias(reply_to)
        Process.exit(reader, :kill)
        Process.demonitor(monitor, [:flush])
        unread(length, "deadline")
    end
  end

  defp unread(length, reason),
    do: %{
      "length" => length,
      "read" => false,
      "reason" => reason,
      "shapes" => [],
      "first" => [],
      "calls" => nil
    }

  # In the reader: the queue is copied here and only its shapes leave.
  defp shapes(pid, first) do
    case :erlang.process_info(pid, :messages) do
      {:messages, messages} ->
        {counts, calls, seen} =
          Enum.reduce(
            messages,
            {%{}, %{"count" => 0, "callers_alive" => 0, "callers_exited" => 0}, 0},
            &count/2
          )

        {:ok,
         %{
           "sampled" => seen,
           "distinct_shapes" => map_size(counts),
           "shapes" =>
             counts
             |> Enum.sort_by(fn {{shape, size}, count} -> {-count, shape, size} end)
             |> Enum.take(@shapes_listed)
             |> Enum.map(fn {{shape, size}, count} ->
               %{"shape" => shape, "size_class" => size, "count" => count}
             end),
           "first" =>
             messages
             |> Enum.take(first)
             |> Enum.map(&%{"shape" => shape(&1), "size_class" => size_class(&1)}),
           "calls" => calls
         }}

      :undefined ->
        :undefined
    end
  end

  defp count(message, {counts, calls, seen}) do
    key = {shape(message), size_class(message)}

    counts =
      if is_map_key(counts, key) or map_size(counts) < @max_shapes - 1,
        do: Map.update(counts, key, 1, &(&1 + 1)),
        else: Map.update(counts, {"other", "mixed"}, 1, &(&1 + 1))

    {counts, call(message, calls), seen + 1}
  end

  defp call({:"$gen_call", {caller, _tag}, _request}, calls) when is_pid(caller) do
    alive = if node(caller) == node(), do: Process.alive?(caller), else: true
    key = if alive, do: "callers_alive", else: "callers_exited"
    calls |> Map.update!("count", &(&1 + 1)) |> Map.update!(key, &(&1 + 1))
  end

  defp call(_message, calls), do: calls

  @doc """
  A message's shape: its structure with types in place of values, tuples
  two levels deep. An atom shows only as a tuple's first element (its tag);
  anywhere else, a bare atom message included, it is `atom`.
  """
  @spec shape(term()) :: String.t()
  def shape(term) do
    term |> render(0, false) |> Inspect.bound_text(@shape_bytes, :head)
  end

  defp render(atom, _depth, true) when is_atom(atom),
    do: atom |> Kernel.inspect() |> Inspect.bound_text(64, :head)

  defp render(atom, _depth, false) when is_atom(atom), do: "atom"

  defp render(tuple, depth, _tag?) when is_tuple(tuple) and depth < 2 do
    elements = Tuple.to_list(tuple)

    rendered =
      elements
      |> Enum.take(@tuple_elements)
      |> Enum.with_index()
      |> Enum.map(fn {element, index} -> render(element, depth + 1, index == 0) end)

    more = if length(elements) > @tuple_elements, do: [".."], else: []
    "{" <> Enum.join(rendered ++ more, ", ") <> "}"
  end

  defp render(tuple, _depth, _tag?) when is_tuple(tuple), do: "tuple"
  defp render([], _depth, _tag?), do: "[]"
  defp render(list, _depth, _tag?) when is_list(list), do: "list"

  defp render(%{__struct__: module}, _depth, _tag?) when is_atom(module),
    do: "%" <> Inspect.bound_text(Names.display(module), 64, :head) <> "{}"

  defp render(map, _depth, _tag?) when is_map(map), do: "map"
  defp render(binary, _depth, _tag?) when is_binary(binary), do: "binary"
  defp render(bits, _depth, _tag?) when is_bitstring(bits), do: "bitstring"
  defp render(integer, _depth, _tag?) when is_integer(integer), do: "integer"
  defp render(float, _depth, _tag?) when is_float(float), do: "float"
  defp render(pid, _depth, _tag?) when is_pid(pid), do: "pid"
  defp render(port, _depth, _tag?) when is_port(port), do: "port"
  defp render(ref, _depth, _tag?) when is_reference(ref), do: "reference"
  defp render(_fun, _depth, _tag?), do: "fun"

  @doc "A message's size class, by its external term size."
  @spec size_class(term()) :: String.t()
  def size_class(term) do
    case :erlang.external_size(term) do
      size when size < 64 -> "under_64b"
      size when size < 1_024 -> "under_1kib"
      size when size < 65_536 -> "under_64kib"
      _size -> "64kib_or_more"
    end
  end

  @doc "The session event's attributes: a compact projection and its lists."
  @spec event(map()) :: {map(), [String.t()]}
  def event(result) do
    mailbox = result["mailbox"]

    {%{
       "pid" => result["pid"],
       "name" => result["name"],
       "insider" => result["insider"],
       "info" =>
         Map.drop(result["info"], ["fullsweep_after", "heap_size_words", "stack_size_words"]),
       "binaries" => result["binaries"],
       "stacktrace" => Enum.take(result["stacktrace"]["frames"], 3),
       "mailbox_length" => mailbox["length"],
       "mailbox_read" => mailbox["read"],
       "mailbox_calls" => mailbox["calls"],
       "mailbox_shapes" => Enum.take(mailbox["shapes"], 5)
     }, ["mailbox_shapes", "stacktrace"]}
  end
end
