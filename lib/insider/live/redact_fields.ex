defmodule Insider.Live.RedactFields do
  @moduledoc false

  # Ecto-declared `redact: true` fields for the rich disclosure profile.
  #
  # Rich rendering runs in the emitting process and never calls application
  # code, so it cannot ask a schema which fields it hides. Instead the live
  # owner, at session start, asks every loaded module that exports
  # `__schema__/1` for `__schema__(:redact_fields)`, each call in its own
  # process under one shared deadline and a memory cap, and stores the valid
  # answers (see `collect/1` for what can reach the owner) in a
  # protected ETS table that emitters only read. A schema that does not
  # answer in time, answers with anything but a short list of atoms, or is
  # loaded after the session started is not in the table; its fields are
  # still masked when their names look like credentials.

  @table :insider_live_redact_fields
  @max_modules 4_096
  @max_fields 64
  @max_worker_heap_words 65_536

  @doc "The read-only table name: `{module, [field]}` rows."
  @spec table() :: atom()
  def table, do: @table

  @doc "Creates the table, owned by the calling process (the live owner)."
  @spec create() :: :ok
  def create do
    _table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok
  end

  @doc """
  Replaces the table contents with the redact fields every loaded schema
  reports within `timeout_ms`. Returns the number of schemas stored.
  """
  @spec refresh(non_neg_integer()) :: non_neg_integer()
  def refresh(timeout_ms) do
    rows = collect(timeout_ms)
    true = :ets.delete_all_objects(@table)
    true = :ets.insert(@table, rows)
    length(rows)
  end

  @doc "The redact fields recorded for `module`, or `[]`."
  @spec fields(module()) :: [atom()]
  def fields(module) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      table ->
        case :ets.lookup(table, module) do
          [{^module, fields}] -> fields
          [] -> []
        end
    end
  end

  @doc false
  # The rows every loaded schema reports within `timeout_ms`; public so tests
  # can trace what reaches the collecting process.
  #
  # Nothing a schema controls can reach the collector except a field list
  # the worker built and checked itself:
  # - each worker catches every error, throw, and exit from the accessor and
  #   always sends `{alias, tag, fields}` with `fields` a fresh list of at
  #   most 64 atoms, or `:invalid`;
  # - workers are not monitored or linked, so no exit reason (a worker
  #   killed by its memory cap, or by another process) is ever delivered;
  # - replies go to an alias that is deactivated at the deadline, so a late
  #   reply is dropped by the runtime; stragglers are killed;
  # - each worker has a `max_heap_size` guard that also counts the
  #   reference-counted binaries it references. The runtime enforces it at
  #   garbage collection, so it stops a worker that builds a large term or
  #   binary, but it is not a hard allocation or retained-memory quota: a
  #   binary shared from elsewhere (for example `:persistent_term`, which the
  #   heap does not count) passes unnoticed, and memory in other processes
  #   the accessor starts is not counted. What reaches the owner stays
  #   bounded either way, because only the validated atom list is sent.
  @spec collect(non_neg_integer()) :: [{module(), [atom()]}]
  def collect(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    reply_to = :erlang.alias([:explicit_unalias])

    workers =
      :code.all_loaded()
      |> Stream.map(&elem(&1, 0))
      |> Stream.filter(&function_exported?(&1, :__schema__, 1))
      |> Enum.take(@max_modules)
      |> Map.new(fn module ->
        tag = make_ref()

        pid =
          :erlang.spawn_opt(fn -> answer(reply_to, tag, module) end, [
            {:max_heap_size,
             %{
               size: @max_worker_heap_words,
               kill: true,
               include_shared_binaries: true,
               error_logger: false
             }}
          ])

        {tag, {pid, module}}
      end)

    {rows, waiting} = await(workers, reply_to, deadline, [])
    true = :erlang.unalias(reply_to)
    Enum.each(waiting, fn {_tag, {pid, _module}} -> Process.exit(pid, :kill) end)
    flush(reply_to)
    rows
  end

  defp answer(reply_to, tag, module) do
    fields =
      try do
        normalize(module.__schema__(:redact_fields))
      catch
        _kind, _reason -> :invalid
      end

    send(reply_to, {reply_to, tag, fields})
  end

  defp await(workers, _reply_to, _deadline, rows) when map_size(workers) == 0, do: {rows, %{}}

  defp await(workers, reply_to, deadline, rows) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply_to, tag, fields} when is_map_key(workers, tag) ->
        {{_pid, module}, workers} = Map.pop!(workers, tag)
        rows = if is_list(fields), do: [{module, fields} | rows], else: rows
        await(workers, reply_to, deadline, rows)
    after
      remaining -> {rows, workers}
    end
  end

  defp flush(reply_to) do
    receive do
      {^reply_to, _tag, _fields} -> flush(reply_to)
    after
      0 -> :ok
    end
  end

  # Runs in the worker: a freshly built list of at most `@max_fields` atoms,
  # read without walking further, or `:invalid`. Atoms only, so no binary
  # can travel in a reply.
  defp normalize(fields), do: normalize(fields, @max_fields, [])

  defp normalize([], _left, []), do: :invalid
  defp normalize([], _left, kept), do: Enum.reverse(kept)

  defp normalize([field | rest], left, kept) when is_atom(field) and left > 0,
    do: normalize(rest, left - 1, [field | kept])

  defp normalize(_fields, _left, _kept), do: :invalid
end
