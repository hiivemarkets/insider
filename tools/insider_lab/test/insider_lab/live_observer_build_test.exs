defmodule Insider.Lab.Live.ObserverBuildTest do
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.ObserverBuild
  alias Insider.Live.Build

  # The observer reports its own build in every document. Hashing every
  # Insider module on each call loaded them all, which was the largest part
  # of an escript call's fixed cost, so it is fixed at compile time.
  test "the observer's build is the Insider build this node runs" do
    assert ObserverBuild.identity() == Build.identity()
    assert ObserverBuild.identity()["beams_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "Mix does not recompile it while the Insider build is unchanged" do
    refute ObserverBuild.__mix_recompile__?()
  end

  # The unchanged case alone passes with a callback
  # that always returns false. `Installation.ensure/3` compares builds with
  # the cached identity, so the cache must be invalidated when the build
  # changes. The changes run in an isolated peer, never in this test VM.
  describe "in an isolated peer, a changed Insider build" do
    setup do
      # Over standard I/O: this test VM is not distributed.
      {:ok, peer, _node} =
        :peer.start(%{
          connection: :standard_io,
          args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1]),
          wait_boot: 30_000
        })

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _reason -> :ok
        end
      end)

      :ok = :peer.call(peer, :application, :load, [:insider], 60000)
      {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:elixir], 60000)
      %{peer: peer}
    end

    test "starts unchanged: the same identity, and no recompile", %{peer: peer} do
      assert :peer.call(peer, ObserverBuild, :identity, [], 60000) ==
               :peer.call(peer, Build, :identity, [], 60000)

      refute :peer.call(peer, ObserverBuild, :__mix_recompile__?, [], 60000)
    end

    test "a different loaded Insider module makes Mix recompile it", %{peer: peer} do
      # Replace one Insider module with a different body (its MD5 changes).
      [{Insider.Live.Trends, _binary}] =
        :peer.call(
          peer,
          Code,
          :compile_string,
          ["defmodule Insider.Live.Trends do def changed, do: :yes end"],
          60000
        )

      refute :peer.call(peer, Build, :identity, [], 60000) ==
               ObserverBuild.identity()

      assert :peer.call(peer, ObserverBuild, :__mix_recompile__?, [], 60000)
    end

    test "a different Insider version makes Mix recompile it", %{peer: peer} do
      {:ok, keys} = :peer.call(peer, :application, :get_all_key, [:insider], 60000)
      :ok = :peer.call(peer, :application, :unload, [:insider], 60000)

      :ok =
        :peer.call(
          peer,
          :application,
          :load,
          [{:application, :insider, Keyword.put(keys, :vsn, ~c"0.0.0-other")}],
          60000
        )

      assert :peer.call(peer, Build, :identity, [], 60000)["version"] ==
               "0.0.0-other"

      assert :peer.call(peer, ObserverBuild, :__mix_recompile__?, [], 60000)
    end
  end
end
