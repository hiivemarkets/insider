defmodule Insider.Live.SignalTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Collector.Session.Manager
  alias Insider.Live

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)
  end

  defp start(extra \\ %{}) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(
               Map.merge(%{"components" => ["logger"], "logger_level" => "error"}, extra)
             )

    id
  end

  # Dev noise: a key fetcher that fails the same way, again and again.
  defp noise(n), do: for(_ <- 1..n, do: Logger.error("key fetch failed: unsupported scheme"))

  # A digest whose anomalies are mostly known dev noise leads with nothing
  # new.
  test "baseline marks the current anomalies normal; digests and status hide them and lead with what is new" do
    id = start()
    noise(6)
    assert_eventually(fn -> match?({:ok, %{"events" => [_ | _]}}, Live.events_since(id, 0)) end)

    assert {:ok, %{"anomalies" => [%{"kind" => "error_spike"}]}} =
             Live.digest(id, %{"since" => 0})

    assert {:ok, marked} = Live.baseline(id, %{"since" => 0, "human" => true})
    assert marked["schema"] == "insider.live-baseline/v1"

    assert %{"entries" => [%{"kind" => "error_spike", "identity" => _identity, "count" => 6}]} =
             marked["baseline"]

    assert marked["text"] =~
             ~r/^Marked 1 anomaly normal for this session at \d\d:\d\d \(window since receipt 0\):\n/

    assert marked["text"] =~ "mix insider.live baseline \"${N[@]}\" --session #{id} --clear"

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})
    assert digest["anomalies"] == []
    assert [%{"kind" => "error_spike"}] = digest["anomalies_known"]

    assert digest["text"] =~
             ~r/\nAnomalies: none new; 1 known-normal anomaly hidden \(baseline set \d\d:\d\d; --show-baseline\)\./

    assert {:ok, shown} =
             Live.digest(id, %{"since" => 0, "human" => true, "show_baseline" => true})

    assert shown["text"] =~ "\nKnown-normal (baseline set "

    assert {:ok, %{"anomalies" => [], "anomalies_known" => 1}} = Live.status(id)

    # Ten times the baselined rate comes back.
    noise(60)

    assert_eventually(fn ->
      match?({:ok, %{"anomalies" => [_]}}, Live.digest(id, %{"since" => 0}))
    end)

    assert {:ok, %{"anomalies" => [back]}} = Live.digest(id, %{"since" => 0})
    assert back["line"] =~ "Back above its baseline: "

    # Clear says what it cleared; the anomaly is shown again.
    assert {:ok, cleared} = Live.baseline(id, %{"clear" => true, "human" => true})

    assert cleared["text"] ==
             "Cleared the baseline (1 signature); digests and status show every anomaly again."

    assert {:ok, %{"baseline" => nil}} = Live.baseline(id, %{"show" => true})

    assert {:ok, %{"anomalies" => [_], "anomalies_known" => []}} =
             Live.digest(id, %{"since" => 0})
  end

  test "a window with no anomalies leaves the baseline as it was, and says so; it outlives the session's stop" do
    id = start()
    assert {:ok, empty} = Live.baseline(id, %{"since" => 0, "human" => true})
    assert empty["baseline"] == nil

    assert empty["text"] =~
             "No anomalies since receipt 0 to mark normal; the baseline is unchanged."

    noise(6)

    assert_eventually(fn ->
      match?({:ok, %{"anomalies" => [_]}}, Live.digest(id, %{"since" => 0}))
    end)

    assert {:ok, %{"baseline" => %{"entries" => [_]}}} = Live.baseline(id, %{"since" => 0})

    assert {:ok, _stopped} = Live.stop(id, %{"force" => true})
    assert {:ok, %{"baseline" => %{"entries" => [_]}}} = Live.baseline(id, %{"show" => true})

    assert {:error, %{"code" => "invalid_options", "field" => "clear"}} =
             Live.baseline(id, %{"clear" => true, "show" => true})
  end

  # A baseline is evidence like a digest's: it names
  # nothing a narrowed profile would withhold, and a denied environment is
  # refused.
  test "a baseline holds only hashed identities, and is refused where the environment is denied" do
    id = start()
    for _ <- 1..6, do: Logger.error("sync failed for alice@example.invalid")

    assert_eventually(fn ->
      match?({:ok, %{"anomalies" => [_]}}, Live.digest(id, %{"since" => 0}))
    end)

    assert {:ok, _marked} = Live.baseline(id, %{"since" => 0})

    # The host narrows to strict: nothing of the message is in the baseline.
    Application.put_env(:insider, :environment, :ci)
    assert {:ok, shown} = Live.baseline(id, %{"show" => true, "human" => true})
    refute Jason.encode!(shown) =~ "alice"
    assert shown["text"] =~ ~r/  - error_spike [0-9a-f]{16} \(/

    Application.put_env(:insider, :environment, :production)
    assert {:error, %{"code" => "environment_denied"}} = Live.baseline(id, %{"show" => true})
  end

  # Baselining again marks what is shown now.
  test "baselining again marks the newly shown error and keeps the earlier one" do
    id = start()
    for _ <- 1..9, do: Logger.error("a failed")

    assert_eventually(fn ->
      match?({:ok, %{"anomalies" => [_]}}, Live.digest(id, %{"since" => 0}))
    end)

    assert {:ok, _first} = Live.baseline(id, %{"since" => 0})

    for _ <- 1..6, do: Logger.error("b failed")

    assert_eventually(fn ->
      match?(
        {:ok, %{"anomalies" => [%{"line" => "Error spike: 6x" <> _}]}},
        Live.digest(id, %{"since" => 0})
      )
    end)

    assert {:ok, %{"baseline" => %{"entries" => [_, _]}}} = Live.baseline(id, %{"since" => 0})

    assert {:ok, %{"anomalies" => [], "anomalies_known" => [_, _]}} =
             Live.digest(id, %{"since" => 0})
  end

  # Show and clear renew a running session's lease.
  test "baseline show and clear renew the lease" do
    id = start(%{"lease_ms" => 5_000})

    for options <- [%{"show" => true}, %{"clear" => true}] do
      Process.sleep(1_200)
      assert {:ok, _result} = Live.baseline(id, options)
      assert {:ok, %{"lease_remaining_ms" => remaining}} = Live.status(id)
      assert remaining > 4_500
    end
  end

  defp assert_eventually(predicate, attempts \\ 150)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("expected state was not reached")
end
