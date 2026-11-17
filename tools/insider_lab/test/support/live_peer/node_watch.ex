defmodule Insider.Lab.LivePeer.NodeWatch do
  @moduledoc false

  # Runs inside a target peer. It records every node that connects (the
  # observers under test are hidden nodes) and disconnects, so a test can
  # wait, on the target it started, for the observers it ran to leave,
  # instead of asserting on the test VM's distribution, which another test
  # may hold at that moment.

  @doc "Starts the watcher; returns once it receives node events."
  @spec start() :: :ok
  def start do
    caller = self()
    reference = make_ref()

    pid =
      spawn(fn ->
        :ok = :net_kernel.monitor_nodes(true, %{node_type: :all})
        send(caller, {reference, :ready})
        loop(MapSet.new(), [])
      end)

    true = Process.register(pid, __MODULE__)

    receive do
      {^reference, :ready} -> :ok
    end
  end

  @doc """
  Waits until no recorded node is connected, and returns the nodes still
  connected after `timeout_ms` (`[]` when none are). A watcher that does not
  answer is an exit, never `[]`: the check cannot pass when it cannot tell.
  """
  @spec await_all_down(pos_integer()) :: [node()]
  def await_all_down(timeout_ms) do
    reference = make_ref()
    send(__MODULE__, {:await, self(), reference})

    receive do
      {^reference, :down} ->
        []
    after
      timeout_ms ->
        send(__MODULE__, {:connected, self(), reference})

        receive do
          {^reference, nodes} when is_list(nodes) -> nodes
        after
          timeout_ms -> exit(:node_watch_unresponsive)
        end
    end
  end

  defp loop(up, waiters) do
    receive do
      {:nodeup, node, _info} ->
        loop(MapSet.put(up, node), waiters)

      {:nodedown, node, _info} ->
        up = MapSet.delete(up, node)
        loop(up, release(up, waiters))

      {:await, from, reference} ->
        loop(up, release(up, [{from, reference} | waiters]))

      {:connected, from, reference} ->
        send(from, {reference, MapSet.to_list(up)})
        loop(up, waiters)
    end
  end

  defp release(up, waiters) do
    if MapSet.size(up) == 0 do
      Enum.each(waiters, fn {from, reference} -> send(from, {reference, :down}) end)
      []
    else
      waiters
    end
  end
end
