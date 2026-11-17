defmodule Insider.Lab.LivePeer do
  @moduledoc false

  # Real target nodes for the observer-node tests. `:peer` controls each node
  # over standard I/O, so the test VM stays non-distributed until the observer
  # under test starts its own hidden node.

  alias Insider.Lab.LivePeer.NodeWatch

  @elixir_applications [:elixir, :logger]
  @insider_applications [:insider, :jason, :telemetry]
  @otel_applications [:opentelemetry, :opentelemetry_api]

  @doc """
  Starts a peer named uniquely with `cookie`.

  Options: `:insider` is `:started` (Insider and its dependencies on the code
  path and started) or `:absent` (only Elixir); `:environment` sets the
  `:insider` `:environment` application setting; `:name` reuses a name, to
  start a node again after it stopped; `otel: true` also puts the
  OpenTelemetry SDK on the code path, without starting it, so a session
  can record ingested spans with the `otel` component.
  """
  @spec start(atom(), keyword()) :: {pid(), String.t()}
  def start(cookie, options \\ []) do
    insider = Keyword.get(options, :insider, :absent)

    name =
      Keyword.get_lazy(options, :name, fn ->
        :"insider_live_peer_#{System.unique_integer([:positive])}"
      end)

    arguments =
      [~c"-setcookie", Atom.to_charlist(cookie)] ++
        path_arguments(insider) ++
        otel_arguments(Keyword.get(options, :otel, false)) ++
        environment_arguments(Keyword.get(options, :environment))

    {:ok, peer, node} =
      :peer.start(%{name: name, connection: :standard_io, args: arguments, wait_boot: 30_000})

    if insider == :started do
      {:ok, _started} = :peer.call(peer, :application, :ensure_all_started, [:insider])
    end

    :ok = watch_nodes(peer)
    {peer, Atom.to_string(node)}
  end

  @spec stop(pid()) :: :ok
  def stop(peer) do
    :peer.stop(peer)
  catch
    :exit, _already_stopped -> :ok
  end

  @doc """
  Waits until every node that connected to the peer (the observers a test
  ran against it) has disconnected again, and returns the nodes still
  connected after `timeout_ms`: `[]` when the observers left. Only a peer
  that has stopped is taken to have no connections; a running peer whose
  watcher does not answer makes this exit, so the check fails rather than
  passing unverified. This checks the nodes this test caused, never this
  VM's own distribution state, which another test may own.
  """
  @spec observers_left(pid(), pos_integer()) :: [node()]
  def observers_left(peer, timeout_ms \\ 10_000) do
    if Process.alive?(peer),
      do: :peer.call(peer, NodeWatch, :await_all_down, [timeout_ms], 2 * timeout_ms + 1_000),
      else: []
  end

  # The watcher is a test-support module the peer does not have on its code
  # path, so its object code is loaded there first.
  defp watch_nodes(peer) do
    {NodeWatch, binary, file} = :code.get_object_code(NodeWatch)
    {:module, NodeWatch} = :peer.call(peer, :code, :load_binary, [NodeWatch, file, binary])
    :peer.call(peer, NodeWatch, :start, [])
  end

  defp path_arguments(insider) do
    if insider == :started,
      do: code_paths(@elixir_applications ++ @insider_applications),
      else: code_paths(@elixir_applications)
  end

  defp otel_arguments(true), do: code_paths(@otel_applications)
  defp otel_arguments(false), do: []

  defp code_paths(applications) do
    Enum.flat_map(applications, fn application ->
      [~c"-pa", application |> :code.lib_dir() |> Path.join("ebin") |> String.to_charlist()]
    end)
  end

  defp environment_arguments(nil), do: []

  defp environment_arguments(environment),
    do: [~c"-insider", ~c"environment", Atom.to_charlist(environment)]

  @doc "Writes `cookie` to a fresh file in `directory` with `mode`."
  @spec cookie_file(Path.t(), atom(), non_neg_integer()) :: Path.t()
  def cookie_file(directory, cookie, mode \\ 0o600) do
    path = Path.join(directory, "cookie")
    File.write!(path, Atom.to_string(cookie) <> "\n")
    File.chmod!(path, mode)
    path
  end
end
