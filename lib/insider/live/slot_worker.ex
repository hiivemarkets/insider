defmodule Insider.Live.SlotWorker do
  @moduledoc false

  # The bounded worker that a discovery scan (`Insider.Live.Discovery`) and a
  # one-shot inspection (`Insider.Live.Inspect`) each run in. The worker
  # takes one of `slots` by registering under its name, so at most
  # `length(slots)` run at once, and another caller is `busy` at once. It runs
  # under a heap limit that kills it when exceeded. The caller waits at most
  # `await_ms` for its reply. A worker that exits is `unavailable`, and one
  # that is late is killed and is a `timeout`.

  alias Insider.Live.Error

  @doc """
  Runs `work` in a worker holding one of `slots` and returns its result.
  Options: `:slots` (the registered names), `:heap_words` (the worker's
  `max_heap_size`), `:include_shared_binaries` (whether off-heap binaries
  count toward it), and `:await_ms`.
  """
  @spec run((-> result), keyword()) :: result | {:error, map()} when result: term()
  def run(work, options) when is_function(work, 0) do
    reply_to = :erlang.alias([:explicit_unalias])
    slots = Keyword.fetch!(options, :slots)

    {pid, monitor} =
      :erlang.spawn_opt(fn -> work(reply_to, slots, work) end, [
        :monitor,
        {:max_heap_size,
         %{
           size: Keyword.fetch!(options, :heap_words),
           kill: true,
           include_shared_binaries: Keyword.fetch!(options, :include_shared_binaries),
           error_logger: false
         }}
      ])

    receive do
      {^reply_to, result} ->
        Process.demonitor(monitor, [:flush])
        true = :erlang.unalias(reply_to)
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        true = :erlang.unalias(reply_to)
        {:error, Error.new("unavailable")}
    after
      Keyword.fetch!(options, :await_ms) ->
        true = :erlang.unalias(reply_to)
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, Error.new("timeout")}
    end
  end

  defp work(reply_to, slots, work) do
    result =
      if Enum.any?(slots, &register/1),
        do: work.(),
        else: {:error, Error.new("busy")}

    send(reply_to, {reply_to, result})
  end

  defp register(name) do
    Process.register(self(), name)
  rescue
    ArgumentError -> false
  end
end
