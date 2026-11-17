defmodule Insider.Live.TandemTest do
  # Several agents sharing the node's one live session: named readers,
  # protected stops with a read-only drain window, live amendment, and
  # handoff. One collector session is global per node, so this module cannot
  # run in parallel with other session users.
  use ExUnit.Case, async: false

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Owner
  alias Insider.Live.Welcome

  @tick [:insider_live_tandem_test, :tick]
  @other [:insider_live_tandem_test, :other]
  @telemetry %{
    "components" => ["telemetry"],
    "telemetry_events" => [["insider_live_tandem_test", "tick"]]
  }

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  describe "named readers" do
    test "status lists each named reader with its cursor, lag, last read, and subscription" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..5)

      assert {:ok, %{"next_cursor" => 2}} =
               Live.events_since(id, 0, %{"reader" => "agent-a", "limit" => 2})

      assert {:ok, %{"next_cursor" => 5}} = Live.events_since(id, 0, %{"reader" => "agent-b"})
      # An unnamed read is not listed.
      assert {:ok, _batch} = Live.events_since(id, 0)

      assert {:ok, %{"reader" => "watcher", "cursor" => 5}} =
               Live.subscribe(id, self(), %{"reader" => "watcher", "cursor" => "latest"})

      assert {:ok, status} = Live.status(id)
      assert status["next_receipt"] == 5

      assert [
               %{"name" => "agent-a", "cursor" => 2, "behind" => 3, "subscribed" => false},
               %{"name" => "agent-b", "cursor" => 5, "behind" => 0, "subscribed" => false},
               %{"name" => "watcher", "cursor" => 5, "subscribed" => true, "active" => true}
             ] = status["readers"]

      for reader <- status["readers"] do
        assert reader["active"]
        assert reader["last_seen_ms_ago"] >= 0
        assert {:ok, _at, 0} = DateTime.from_iso8601(reader["last_seen_at"])
      end

      # A delivered batch moves the subscribed reader's cursor.
      tick(6..6)
      assert_receive {:insider_live_events, ^id, %{"next_cursor" => 6}}, 3_000
      assert {:ok, status} = Live.status(id)
      assert %{"name" => "watcher", "cursor" => 6} = List.last(status["readers"])

      assert status["scope"]["filters"] =~ "every reader"
      assert status["scope"]["view"] =~ "only"
    end

    test "a reader name is bounded and validated on every operation that takes one" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

      for name <- ["", "-leading", String.duplicate("a", 33), "has space", 7] do
        for {call, field} <- [
              {fn -> Live.events_since(id, 0, %{"reader" => name}) end, "reader"},
              {fn -> Live.subscribe(id, self(), %{"reader" => name}) end, "reader"},
              {fn -> Live.stop(id, %{"reader" => name}) end, "reader"},
              {fn -> Live.amend(id, %{"reader" => name, "max_events" => 64}) end, "reader"}
            ] do
          assert {:error, %{"code" => "invalid_options", "field" => ^field}} = call.()
        end
      end

      assert {:error, %{"code" => "invalid_options", "field" => "force"}} =
               Live.stop(id, %{"force" => "yes"})

      assert {:error, %{"code" => "invalid_options", "field" => "other"}} =
               Live.stop(id, %{"other" => true})

      assert {:error, %{"code" => "invalid_options", "field" => "options"}} = Live.stop(id, [])
      assert {:ok, %{"state" => "running"}} = Live.status(id)
    end

    # Eviction removed a quiet named subscriber, so
    # a stop no longer saw it.
    test "a subscribed reader is never forgotten and keeps holding a stop" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      assert {:ok, _subscription} = Live.subscribe(id, self(), %{"reader" => "watcher"})
      max = Owner.bounds()["readers_max"]

      for index <- 1..(max + 4),
          do: assert({:ok, _batch} = Live.events_since(id, 0, %{"reader" => "r#{index}"}))

      assert {:ok, %{"readers" => readers}} = Live.status(id)
      assert length(readers) == max
      assert %{"subscribed" => true} = Enum.find(readers, &(&1["name"] == "watcher"))

      # Every other reader is idle; the quiet subscription still holds.
      :sys.replace_state(Owner, fn state ->
        readers =
          Map.new(state.session.readers, fn {name, r} ->
            {name, %{r | seen_at: r.seen_at - 1_000_000}}
          end)

        put_in(state.session.readers, readers)
      end)

      assert {:error, %{"code" => "readers_active", "readers" => [%{"name" => "watcher"}]}} =
               Live.stop(id, %{"reader" => "r1"})
    end

    test "only the most recently seen readers are kept" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      max = Owner.bounds()["readers_max"]

      for index <- 0..max,
          do: assert({:ok, _batch} = Live.events_since(id, 0, %{"reader" => "r#{index}"}))

      assert {:ok, %{"readers" => readers}} = Live.status(id)
      names = Enum.map(readers, & &1["name"])
      assert length(names) == max
      refute "r0" in names
      assert "r#{max}" in names
    end
  end

  describe "stop protection and retention" do
    test "a stop waits for an active peer, force stops, and the peer drains the stopped session" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..30)

      assert {:ok, %{"next_cursor" => 10}} =
               Live.events_since(id, 0, %{"reader" => "agent-b", "limit" => 10})

      assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "agent-a"})

      assert {:error, refused} = Live.stop(id, %{"reader" => "agent-a"})
      assert %{"code" => "readers_active", "unnamed_subscribers" => 0} = refused
      assert [%{"name" => "agent-b", "cursor" => 10, "subscribed" => false}] = refused["readers"]
      assert refused["retry_after_ms"] in 1..Owner.bounds()["reader_active_ms"]
      assert refused["reader_active_ms"] == Owner.bounds()["reader_active_ms"]
      assert refused["stopped_readable_ms"] == Owner.bounds()["stopped_readable_ms"]

      # An unnamed stop is refused too; the session keeps running.
      assert {:error, %{"code" => "readers_active"}} = Live.stop(id)
      assert {:ok, %{"state" => "running"}} = Live.status(id)

      assert {:ok, stopped} = Live.stop(id, %{"reader" => "agent-a", "force" => true})
      assert %{"state" => "stopped", "reason" => "stop_requested"} = stopped
      assert {:ok, until, 0} = DateTime.from_iso8601(stopped["readable_until"])
      assert DateTime.compare(until, DateTime.utc_now()) == :gt
      assert Live.capabilities()["active_session_id"] == nil
      assert {:ok, ^stopped} = Live.stop(id)

      # agent-b drains the rest from its own cursor.
      assert {:ok, drained} = Live.events_since(id, 10, %{"reader" => "agent-b", "limit" => 500})
      assert Enum.map(drained["events"], & &1["receipt"]) == Enum.to_list(11..30)
      assert %{"state" => "stopped", "lease_remaining_ms" => 0, "truncated" => false} = drained
      assert %{"next_cursor" => 30, "next_receipt" => 30, "gaps" => []} = drained
      assert drained["readable_remaining_ms"] in 1..Owner.bounds()["stopped_readable_ms"]
      assert %{"scope" => "since_cursor_issued"} = drained["filtered"]

      # A view and the read bounds work on the archive as on a running session.
      assert {:ok, %{"events" => [], "next_cursor" => 30}} =
               Live.events_since(id, 0, %{"view" => %{"kinds" => ["nothing"]}})

      assert {:ok, %{"events" => [_one], "truncated_by" => "limit"}} =
               Live.events_since(id, 0, %{"limit" => 1})

      assert {:ok, %{"events" => [], "cursor" => 30}} = Live.events_since(id, "latest")

      assert {:error, %{"code" => "invalid_cursor", "oldest_receipt" => 1, "next_receipt" => 30}} =
               Live.events_since(id, 31)

      # Drained reads say which disclosure profile their events crossed, a
      # reader's upto bounds them, and a digest reads the archive through them.
      assert drained["disclosure_profile"] in ["rich", "strict"]
      assert drained["disclosure_profile"] == stopped["disclosure_profile"]

      assert {:ok, %{"next_cursor" => 15, "truncated" => false} = bounded} =
               Live.events_since(id, 10, %{"upto" => 15})

      assert Enum.map(bounded["events"], & &1["receipt"]) == Enum.to_list(11..15)

      assert {:error, %{"code" => "invalid_options", "field" => "upto"}} =
               Live.events_since(id, 10, %{"upto" => 31})

      assert {:ok, %{"schema" => "insider.live-digest/v1"}} = Live.digest(id)

      assert {:ok, status} = Live.status(id)
      assert %{"state" => "stopped", "next_receipt" => 30} = status
      assert status["readable_remaining_ms"] > 0
      assert [%{"name" => "agent-a"}, %{"name" => "agent-b", "cursor" => 30}] = status["readers"]

      # Nothing more is collected or renewed.
      assert {:error, %{"code" => "session_terminal"}} = Live.renew(id)
      assert {:error, %{"code" => "session_terminal"}} = Live.subscribe(id, self())

      # When the window passes, the archive is freed.
      send(Process.whereis(Owner), {:retention_expired, id})
      assert {:error, %{"code" => "session_terminal"} = ended} = Live.events_since(id, 0)
      assert ended["status"]["state"] == "stopped"
      assert {:ok, %{"readable_remaining_ms" => 0, "readers" => []}} = Live.status(id)
    end

    test "the stopper's own reads, idle readers, and unnamed subscribers do not hold a stop" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "agent-b"})
      assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "agent-a"})
      assert {:ok, _subscription} = Live.subscribe(id, self())

      # agent-b's last read is older than the window.
      idle = Owner.bounds()["reader_active_ms"] + 1

      :sys.replace_state(Owner, fn state ->
        update_in(state.session.readers["agent-b"].seen_at, &(&1 - idle))
      end)

      assert {:ok, %{"readers" => readers}} = Live.status(id)

      assert %{"name" => "agent-b", "active" => false} =
               Enum.find(readers, &(&1["name"] == "agent-b"))

      assert {:ok, %{"state" => "stopped"}} = Live.stop(id, %{"reader" => "agent-a"})
      assert_receive {:insider_live_events, ^id, %{"state" => "stopped"}}, 3_000
    end

    test "a named subscriber holds a stop until it unsubscribes and gets its last batch from the copy" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      assert {:ok, _subscription} = Live.subscribe(id, self(), %{"reader" => "watcher"})
      tick(1..3)
      assert_receive {:insider_live_events, ^id, %{"next_cursor" => 3}}, 3_000

      :sys.replace_state(Owner, fn state ->
        update_in(state.session.readers["watcher"].seen_at, &(&1 - 1_000_000))
      end)

      assert {:error, %{"code" => "readers_active", "retry_after_ms" => nil} = refused} =
               Live.stop(id, %{"reader" => "agent-a"})

      assert [%{"name" => "watcher", "subscribed" => true}] = refused["readers"]

      tick(4..5)
      assert {:ok, %{"state" => "stopped"}} = Live.stop(id, %{"force" => true})

      assert_receive {:insider_live_events, ^id, %{"state" => "stopped"} = final}, 3_000
      assert Enum.map(final["events"], & &1["receipt"]) == [4, 5]
      assert %{"receipt" => %{"outcome" => "stopped"}, "next_cursor" => 5} = final
    end
  end

  # Events recorded after the copy and before the
  # collectors stopped were lost without a gap. The copy now seals ingress
  # first, so events admitted but never read are in the archive.
  test "a stop keeps every admitted event, including those not yet read" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    assert {:ok, %{"next_cursor" => 0}} = Live.events_since(id, 0)
    tick(1..20)
    assert {:ok, %{"state" => "stopped"}} = Live.stop(id)

    assert {:ok, drained} = Live.events_since(id, 0, %{"limit" => 500})
    assert Enum.map(drained["events"], & &1["receipt"]) == Enum.to_list(1..20)
    assert %{"next_receipt" => 20, "gaps" => []} = drained
    tick(21..21)
    assert {:ok, %{"next_receipt" => 20}} = Live.events_since(id, "latest")
  end

  # Removing a component hid its earlier losses.
  test "losses of a component an amendment removed stay reported, through a stop" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    collector = :sys.get_state(:sys.get_state(Manager).active.pid).components.telemetry
    :ok = :sys.suspend(collector)
    for count <- 1..300, do: :telemetry.execute(@tick, %{count: count}, %{})
    :ok = :sys.resume(collector)

    shed = fn batch -> Enum.find(batch["gaps"], &(&1["reason"] == "telemetry_shed")) end
    all = %{"limit" => 500, "max_bytes" => 1_048_576}
    assert {:ok, before} = Live.events_since(id, 0, all)
    assert %{"count" => 44, "scope" => "since_session_start"} = shed.(before)

    # A nil option returns to its default: no Telemetry events without it.
    assert {:ok, _amended} =
             Live.amend(id, %{"components" => ["logger"], "telemetry_events" => nil})

    assert {:ok, after_amend} = Live.events_since(id, 0, all)
    assert %{"count" => 44} = shed.(after_amend)

    assert {:ok, _stopped} = Live.stop(id, %{"force" => true})
    assert {:ok, retained} = Live.events_since(id, 0, all)
    assert %{"count" => 44} = shed.(retained)
  end

  # What happens between the bulk copy and
  # the seal. Sealing the running segment directly, with no read since the
  # events, puts that work entirely in the seal.
  describe "the seal ends a segment with its last counters and summaries" do
    test "losses counted before the seal are reported by later reads" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      collector = :sys.get_state(:sys.get_state(Manager).active.pid).components.telemetry
      :ok = :sys.suspend(collector)
      tick(1..300)
      :ok = :sys.resume(collector)

      assert {:ok, _sealed} = Insider.Collector.Session.seal_ingress(handle(), 1_000)

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500, "max_bytes" => 1_048_576})
      assert Enum.map(batch["events"], & &1["receipt"]) == Enum.to_list(1..256)

      assert [%{"count" => 44, "scope" => "since_session_start"}] =
               Enum.filter(batch["gaps"], &(&1["reason"] == "telemetry_shed"))
    end

    test "a summarized sample's pending interval is recorded by the seal" do
      summarized =
        Map.merge(@telemetry, %{
          "telemetry_summaries" => ["insider_live_tandem_test.tick"],
          "telemetry_summary_interval_ms" => 300_000,
          "telemetry_measurements" => ["duration"]
        })

      assert {:ok, %{"session_id" => id}} = Live.start(summarized)
      :telemetry.execute(@tick, %{duration: 1_000}, %{})
      assert {:ok, _sealed} = Insider.Collector.Session.seal_ingress(handle(), 1_000)

      # The one sample is also the interval's exemplar, recorded before it.
      assert {:ok, %{"events" => [exemplar, summary], "gaps" => []}} = Live.events_since(id, 0)
      assert %{"count" => 1} = summary["event"]["attributes"]["summary"]

      assert [%{"receipt" => receipt, "roles" => ["slowest"]}] =
               summary["event"]["attributes"]["summary"]["exemplars"]

      assert exemplar["receipt"] == receipt
    end

    # The pause omitted the time the sealed segment
    # was being copied. The Manager is held after the seal, so the last copy
    # waits a known time.
    test "an amendment's uncollected_ms starts at the seal" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      session = :sys.get_state(Manager).active.pid
      :erlang.trace(session, true, [:receive])
      amend = Task.async(fn -> Live.amend(id, %{"max_events" => 64}) end)

      assert_receive {:trace, ^session, :receive,
                      {:"$gen_call", _from, {:admitted, _admission, :seal_ingress}}},
                     5_000

      :erlang.trace(session, false, [:receive])
      :ok = :sys.suspend(Manager)
      Process.sleep(300)
      :ok = :sys.resume(Manager)

      assert {:ok, %{"amendment" => amendment}} = Task.await(amend, 15_000)
      assert amendment["uncollected_ms"] >= 300
    end
  end

  # A Telemetry collector whose final status cannot
  # be read (here: the session points at a collector that is gone) must
  # leave telemetry_accounting_unavailable on every later read.
  describe "unavailable final accounting" do
    test "survives a stop into the drain window" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..3)
      assert {:ok, %{"gaps" => []}} = Live.events_since(id, 0)
      real = lose_telemetry_collector()

      assert {:ok, %{"state" => "stopped"}} = Live.stop(id)
      assert {:ok, retained} = Live.events_since(id, 0)
      assert unavailable?(retained)
      Process.exit(real, :kill)
    end

    test "survives an amendment into the later, healthy segment" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..3)
      real = lose_telemetry_collector()
      # The orphaned collector's handler would block the next segment's.
      :ok = :telemetry.detach("insider-session-telemetry")

      assert {:ok, _amended} = Live.amend(id, %{"max_events" => 64})
      Process.exit(real, :kill)
      tick(4..4)

      assert {:ok, batch} = Live.events_since(id, 0)
      assert unavailable?(batch)
      assert {:ok, later} = Live.events_since(id, batch["next_cursor"])
      assert unavailable?(later)
    end

    # The failure lands at the original boundary, a
    # healthy bulk copy followed by a seal that cannot read the Telemetry
    # collector's final status. The bulk copy has counted 44 shed events.
    test "a collector lost at the seal keeps the bulk copy's losses through a stop" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      shed_before_seal()
      real = lose_telemetry_collector_at_seal()

      assert {:ok, %{"state" => "stopped"}} = Live.stop(id)
      assert_received {:lost_at_seal, ^real}

      assert {:ok, retained} =
               Live.events_since(id, 0, %{"limit" => 500, "max_bytes" => 1_048_576})

      assert Enum.map(retained["events"], & &1["receipt"]) == Enum.to_list(1..256)
      assert shed(retained) == 44
      assert unavailable?(retained)
    end

    test "a collector lost at the seal keeps the bulk copy's losses through an amendment" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      shed_before_seal()
      real = lose_telemetry_collector_at_seal()

      assert {:ok, %{"amendment" => %{"applied" => true}}} =
               Live.amend(id, %{"max_events" => 512})

      assert_received {:lost_at_seal, ^real}
      tick(301..301)

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500, "max_bytes" => 1_048_576})
      assert shed(batch) == 44
      assert unavailable?(batch)
      assert {:ok, later} = Live.events_since(id, batch["next_cursor"])
      assert unavailable?(later)
    end
  end

  describe "amendment" do
    test "amend adds a measurement without losing history, cursors, or subscribers" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(Map.put(@telemetry, "telemetry_measurements", ["count"]))

      tick(1..3)

      assert {:ok, %{"next_cursor" => 2}} =
               Live.events_since(id, 0, %{"reader" => "agent-b", "limit" => 2})

      assert {:ok, %{"cursor" => 3}} =
               Live.subscribe(id, self(), %{"cursor" => "latest", "reader" => "watcher"})

      assert {:ok, amended} =
               Live.amend(id, %{
                 "telemetry_measurements" => ["count", "duration"],
                 "telemetry_events" => [
                   ["insider_live_tandem_test", "tick"],
                   ["insider_live_tandem_test", "other"]
                 ],
                 "telemetry_min_duration_ms" => 0,
                 "reader" => "agent-a"
               })

      assert %{"schema" => "insider.live-amendment/v1", "session_id" => ^id} = amended
      assert amended["telemetry_measurements"] == ["count", "duration"]

      assert %{
               "number" => 1,
               "applied" => true,
               "by" => "agent-a",
               "marker_receipt" => 4,
               "requested" => [
                 "telemetry_events",
                 "telemetry_measurements",
                 "telemetry_min_duration_ms"
               ],
               "receipt" => %{"outcome" => "stopped"}
             } = amended["amendment"]

      # Each effective value that changed is named, including the per-event
      # minimums the new event list implies.
      assert ["telemetry_event_min_duration_ms" | requested] = amended["amendment"]["changed"]
      assert requested == amended["amendment"]["requested"]

      assert amended["amendment"]["uncollected_ms"] >= 0

      :telemetry.execute(@tick, %{count: 4, duration: 7}, %{})
      :telemetry.execute(@other, %{count: 5}, %{})

      # The whole history reads in one batch: the old segment, the marker,
      # and the new segment, with consecutive receipts and no gap.
      assert {:ok, batch} = Live.events_since(id, 0, %{"reader" => "agent-c"})
      assert Enum.map(batch["events"], & &1["receipt"]) == [1, 2, 3, 4, 5, 6]

      assert %{"next_cursor" => 6, "next_receipt" => 6, "truncated" => false, "gaps" => []} =
               batch

      [_one, _two, _three, marker, new, other] = batch["events"]
      assert %{"source" => "live", "kind" => "live.session_amended"} = marker["event"]

      assert %{
               "changed" => ["telemetry_event_min_duration_ms" | _requested],
               "from" => %{"telemetry_measurements" => ["count"]},
               "to" => %{"telemetry_measurements" => ["count", "duration"]},
               "by" => "agent-a"
             } = marker["event"]["attributes"]

      assert new["event"]["attributes"]["measurements"] == %{"count" => 4, "duration" => 7}
      assert other["event"]["kind"] == "insider_live_tandem_test.other"

      # agent-b continues from its cursor; a narrow view still shows the marker.
      assert {:ok, %{"events" => events, "next_cursor" => 6}} =
               Live.events_since(id, 2, %{"view" => %{"kinds" => ["nothing"]}})

      assert [%{"receipt" => 4, "event" => %{"kind" => "live.session_amended"}}] = events

      # A cursor inside the archive is valid; a bounded read stops there.
      assert {:ok, %{"events" => [%{"receipt" => 2}], "next_cursor" => 2, "truncated" => true}} =
               Live.events_since(id, 1, %{"limit" => 1})

      assert {:ok, %{"events" => [%{"receipt" => 4}, %{"receipt" => 5}]}} =
               Live.events_since(id, 3, %{"limit" => 2})

      # The subscriber kept its cursor and receives the marker and new events.
      assert_receive {:insider_live_events, ^id, pushed}, 3_000
      assert Enum.map(pushed["events"], & &1["receipt"]) == [4, 5, 6]

      assert {:ok, status} = Live.status(id)
      assert %{"next_receipt" => 6, "telemetry_measurements" => ["count", "duration"]} = status
      assert %{"oldest_receipt" => 1, "archived_events" => 4} = status["recorder"]
      assert [%{"number" => 1, "marker_receipt" => 4}] = status["amendments"]
      assert Enum.map(status["readers"], & &1["name"]) == ["agent-b", "agent-c", "watcher"]

      assert {:error, %{"code" => "invalid_cursor", "oldest_receipt" => 1, "next_receipt" => 6}} =
               Live.events_since(id, 7)

      # A second amendment continues the receipts, and a stop keeps them all.
      assert {:ok, %{"amendment" => %{"number" => 2, "marker_receipt" => 7}}} =
               Live.amend(id, %{
                 "logger_level" => "debug",
                 "components" => ["logger", "telemetry"]
               })

      tick(8..8)
      assert {:ok, %{"state" => "stopped"}} = Live.stop(id, %{"force" => true})
      assert {:ok, all} = Live.events_since(id, 0)
      assert Enum.map(all["events"], & &1["receipt"]) == Enum.to_list(1..8)
    end

    test "an amendment that cannot apply changes nothing" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..2)

      assert {:error, %{"code" => "invalid_options", "field" => "options"}} = Live.amend(id, %{})

      assert {:error, %{"code" => "invalid_options", "field" => "options"}} =
               Live.amend(id, %{"reader" => "agent-a"})

      assert {:error, %{"code" => "invalid_options", "field" => "cursor"}} =
               Live.amend(id, %{"cursor" => 0})

      assert {:error, %{"code" => "invalid_options", "field" => "telemetry_measurements"}} =
               Live.amend(id, %{"telemetry_measurements" => ["not_allowed"]})

      assert {:error, %{"code" => "unknown_telemetry_event"}} =
               Live.amend(id, %{"telemetry_events" => [["insider_live_tandem_never_an_atom_x"]]})

      assert {:error, %{"code" => "unknown_session"}} =
               Live.amend("live-none", %{"max_events" => 64})

      assert {:ok, %{"next_cursor" => 2, "events" => [_one, _two]}} = Live.events_since(id, 0)
      assert {:ok, %{"amendments" => [], "next_receipt" => 2} = status} = Live.status(id)
      assert status["recorder"]["archived_events"] == 0
    end

    test "when the new options cannot start, the previous ones run again" do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      tick(1..2)

      # The collector's Logger handler id is taken, so a segment with the
      # logger component cannot start; the telemetry-only one can.
      with_logger_handler_taken(fn ->
        assert {:error, failed} =
                 Live.amend(id, %{"components" => ["logger", "telemetry"], "reader" => "agent-a"})

        assert %{"code" => "amend_failed", "rolled_back" => true} = failed

        assert %{"applied" => false, "changed" => [], "requested" => ["components"]} =
                 failed["amendment"]
      end)

      tick(4..4)
      assert {:ok, batch} = Live.events_since(id, 0)
      assert Enum.map(batch["events"], & &1["receipt"]) == [1, 2, 3, 4]
      marker = Enum.at(batch["events"], 2)
      assert %{"kind" => "live.session_amended"} = marker["event"]
      assert %{"applied" => false, "by" => "agent-a"} = marker["event"]["attributes"]
      assert {:ok, %{"state" => "running", "components" => ["telemetry"]}} = Live.status(id)
    end

    test "when neither the new nor the previous options can start, the session ends readable" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(Map.put(@telemetry, "telemetry_measurements", ["count"]))

      tick(1..3)
      assert {:ok, _subscription} = Live.subscribe(id, self())
      assert_receive {:insider_live_events, ^id, %{"next_cursor" => 3}}, 3_000

      # The host no longer allows the session's own measurement, so its
      # previous options are invalid now.
      Application.put_env(:insider, :live_telemetry_measurements, [:duration])
      on_exit(fn -> Application.delete_env(:insider, :live_telemetry_measurements) end)

      with_logger_handler_taken(fn ->
        assert {:error, failed} =
                 Live.amend(id, %{
                   "components" => ["logger", "telemetry"],
                   "telemetry_measurements" => ["duration"]
                 })

        assert %{"code" => "amend_failed", "rolled_back" => false} = failed
        assert %{"state" => "terminated", "reason" => "amend_failed"} = failed["status"]
        assert {:ok, until, 0} = DateTime.from_iso8601(failed["status"]["readable_until"])
        assert DateTime.compare(until, DateTime.utc_now()) == :gt
      end)

      assert_receive {:insider_live_events, ^id, %{"state" => "terminated"} = final}, 3_000
      assert %{"events" => [], "cursor" => 3, "next_cursor" => 3} = final

      assert {:ok, %{"events" => events, "state" => "terminated"}} = Live.events_since(id, 0)
      assert Enum.map(events, & &1["receipt"]) == [1, 2, 3]
      assert Live.capabilities()["active_session_id"] == nil
    end
  end

  test "handoff carries what a peer needs to continue the session" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    tick(1..4)
    assert {:ok, _batch} = Live.events_since(id, 0, %{"reader" => "agent-a", "limit" => 3})

    assert {:ok, handoff} = Live.handoff_record(id)
    assert handoff["schema"] == "insider.live-handoff/v1"
    assert handoff["node"] == Atom.to_string(node())
    assert handoff["welcome_hash"] == Welcome.hash()
    assert %{"session_id" => ^id, "state" => "running", "next_receipt" => 4} = handoff
    assert handoff["configuration"]["telemetry_events"] == [["insider_live_tandem_test", "tick"]]
    assert handoff["configuration"]["filters"]["logger_level"] == "warning"
    assert handoff["configuration"]["scope"]["filters"] =~ "every reader"
    assert [%{"name" => "agent-a", "cursor" => 3, "behind" => 1}] = handoff["readers"]

    assert handoff["resume"]["observer"] == [
             "mix insider.live events \"${N[@]}\" --session #{id} --cursor 3 --reader agent-a"
           ]

    assert %{"ok" => ^handoff} = Jason.decode!(Live.JSON.handoff_record(id))
    assert {:error, %{"code" => "unknown_session"}} = Live.handoff_record("live-none")

    # `handoff/1` is the name the production-artifact boundary reserves for
    # a host delivery client (Insider.Observability.MockHostClient).
    refute function_exported?(Live, :handoff, 1)
    refute function_exported?(Live.JSON, :handoff, 1)
  end

  # Configured Poller options do not
  # trap later amendments, and a handoff carries them.
  describe "poller options across amendments" do
    @poller %{
      "components" => ["logger", "poller"],
      "poller_interval_ms" => 1_000,
      "watch_processes" => ["code_server"]
    }

    test "an amendment that removes the poller drops the poller options it kept" do
      assert {:ok, %{"session_id" => id}} = Live.start(@poller)

      assert {:ok, %{"poller" => nil, "components" => ["logger"]}} =
               Live.amend(id, %{"components" => ["logger"]})

      assert {:ok, %{"poller" => nil}} = Live.status(id)

      # Adding the poller back starts from the defaults.
      assert {:ok, %{"poller" => %{"interval_ms" => 5_000, "watch_processes" => []}}} =
               Live.amend(id, %{"components" => ["logger", "poller"]})
    end

    test "a poller option given with the poller removed is still refused" do
      assert {:ok, %{"session_id" => id}} = Live.start(@poller)

      assert {:error, %{"code" => "invalid_options", "field" => "watch_processes"}} =
               Live.amend(id, %{
                 "components" => ["logger"],
                 "watch_processes" => ["code_server"]
               })

      assert {:ok, %{"components" => ["logger", "poller"]}} = Live.status(id)
    end

    # Resetting the components returns them to the
    # defaults, which leave the poller out, so the kept poller options go
    # back to theirs too; a poller option given with that reset is refused.
    test "a components reset drops the kept poller options, and re-adding the poller uses defaults" do
      assert {:ok, %{"session_id" => id}} = Live.start(@poller)
      defaults = Insider.Live.Filters.default_components()
      refute "poller" in defaults

      assert {:error, %{"code" => "invalid_options", "field" => "poller_interval_ms"}} =
               Live.amend(id, %{"components" => nil, "poller_interval_ms" => 2_000})

      assert {:ok, %{"components" => ^defaults, "poller" => nil}} =
               Live.amend(id, %{"components" => nil})

      assert {:ok, %{"poller" => %{"interval_ms" => 5_000, "watch_processes" => []}}} =
               Live.amend(id, %{"components" => ["logger", "poller"]})
    end

    test "a nil option returns to its default while the poller keeps running" do
      assert {:ok, %{"session_id" => id}} = Live.start(@poller)

      assert {:ok, %{"poller" => poller}} =
               Live.amend(id, %{"watch_processes" => nil, "poller_interval_ms" => nil})

      assert poller == %{
               "interval_ms" => 5_000,
               "top_processes" => 5,
               "top_ets_tables" => 5,
               "top_ports" => 5,
               "watch_processes" => []
             }
    end

    test "handoff carries the poller configuration, as amended" do
      assert {:ok, %{"session_id" => id}} = Live.start(@poller)

      assert {:ok, _amended} =
               Live.amend(id, %{"watch_processes" => ["code_server", "Logger.Supervisor"]})

      assert {:ok, %{"poller" => poller}} = Live.status(id)
      assert poller["watch_processes"] == ["code_server", "Logger.Supervisor"]
      assert poller["interval_ms"] == 1_000
      assert {:ok, handoff} = Live.handoff_record(id)
      assert handoff["configuration"]["poller"] == poller
    end
  end

  # Integration: the otel component is an
  # ingress like Logger and Telemetry, so the seal stops its capture before
  # the last copy, and its losses are carried through amendments and the
  # drain window like theirs. The otel component needs OTP 28 (as in
  # Insider.Collector.OtelTest, the tests exist only there).
  if :erlang.system_info(:otp_release) >= ~c"28" do
    describe "the otel component across a seal" do
      @otel %{"components" => ["otel"], "otel_min_duration_ms" => 0}

      test "the seal stops the otel capture, and spans recorded before it are kept" do
        assert {:ok, %{"session_id" => id}} = Live.start(@otel)
        assert {:ok, %{"accepted" => 2}} = Insider.Collector.Otel.ingest([span("01"), span("02")])

        assert {:ok, %{"components" => %{"otel" => "absent"}}} =
                 Insider.Collector.Session.seal_ingress(handle(), 1_000)

        assert {:error, :not_running} = Insider.Collector.Otel.ingest([span("03")])
        assert {:ok, batch} = Live.events_since(id, 0)
        assert Enum.map(batch["events"], & &1["event"]["kind"]) == ["otel.span", "otel.span"]
        assert Enum.reject(batch["gaps"], &(&1["reason"] == "segment_end_unread")) == []
      end

      test "otel losses stay reported through an amendment and the drain window" do
        assert {:ok, %{"session_id" => id}} = Live.start(@otel)

        assert {:ok, %{"accepted" => 1, "rejected" => 1}} =
                 Insider.Collector.Otel.ingest([span("01"), %{"span_id" => "bad"}])

        invalid = fn batch ->
          for %{"reason" => "otel_invalid", "count" => count} <- batch["gaps"], do: count
        end

        assert {:ok, first} = Live.events_since(id, 0)
        assert invalid.(first) == [1]

        assert {:ok, %{"amendment" => %{"applied" => true}}} =
                 Live.amend(id, %{"components" => ["otel", "logger"]})

        assert {:ok, amended} = Live.events_since(id, 0)
        assert invalid.(amended) == [1]

        assert {:ok, %{"state" => "stopped"}} = Live.stop(id, %{"force" => true})
        assert {:ok, drained} = Live.events_since(id, 0)
        assert invalid.(drained) == [1]
        assert [_span, %{"event" => %{"kind" => "live.session_amended"}}] = drained["events"]
      end
    end
  end

  defp span(id) do
    %{
      "trace_id" => "0af7651916cd43dd8448eb211c80319c",
      "span_id" => String.pad_leading(id, 16, "0"),
      "parent_span_id" => nil,
      "name" => "GET /tandem",
      "span_kind" => "server",
      "status" => "ok",
      "status_message" => nil,
      "service" => "tandem",
      "scope" => "test",
      "start_time_us" => 1_761_148_800_000_000,
      "duration_us" => 2_500,
      "attributes" => %{}
    }
  end

  defp tick(counts), do: for(count <- counts, do: :telemetry.execute(@tick, %{count: count}, %{}))

  defp handle, do: :sys.get_state(Owner).session.handle

  # Points the running collector session at a Telemetry collector that has
  # exited and returns the real one, which keeps running until killed.
  defp lose_telemetry_collector do
    session = :sys.get_state(Manager).active.pid
    real = :sys.get_state(session).components.telemetry
    gone = spawn(fn -> :ok end)
    monitor = Process.monitor(gone)
    assert_receive {:DOWN, ^monitor, :process, ^gone, _reason}, 5000
    :sys.replace_state(session, &put_in(&1.components.telemetry, gone))
    real
  end

  # Fills the Telemetry collector's ingress past its bound (256 recorded,
  # 44 shed) while it is held, so the bulk copy reads known losses.
  defp shed_before_seal do
    collector = :sys.get_state(:sys.get_state(Manager).active.pid).components.telemetry
    :ok = :sys.suspend(collector)
    tick(1..300)
    :ok = :sys.resume(collector)
  end

  # Kills the running Telemetry collector inside the collector session,
  # when the session receives the seal and before it handles it, so the
  # bulk copy before it was healthy and the seal cannot read the
  # collector's final status. The kill precedes the seal's own call to the
  # collector, because signals from one process arrive in order. The
  # handler the killed collector leaves behind is detached there too, so
  # the next segment can attach its own.
  defp lose_telemetry_collector_at_seal do
    session = :sys.get_state(Manager).active.pid
    real = :sys.get_state(session).components.telemetry
    test = self()

    hook = fn
      :armed, {:in, {:"$gen_call", _from, {:admitted, _admission, :seal_ingress}}}, _state ->
        Process.exit(real, :kill)
        _ = :telemetry.detach("insider-session-telemetry")
        send(test, {:lost_at_seal, real})
        :done

      :armed, _event, _state ->
        :armed
    end

    :ok = :sys.install(session, {hook, :armed})
    real
  end

  defp shed(batch) do
    batch["gaps"]
    |> Enum.filter(&(&1["reason"] == "telemetry_shed"))
    |> Enum.map(& &1["count"])
    |> Enum.sum()
  end

  defp unavailable?(batch),
    do:
      Enum.any?(
        batch["gaps"],
        &(&1 == %{
            "reason" => "telemetry_accounting_unavailable",
            "count" => nil,
            "scope" => "unknown"
          })
      )

  # Holds the Logger primary filter id the collector's Logger component
  # installs, with a filter that is not Insider's, while `fun` runs, so a
  # segment with the logger component cannot start.
  defp with_logger_handler_taken(fun) do
    :ok = :logger.add_primary_filter(:insider_logger, {fn _event, _extra -> :ignore end, nil})

    try do
      fun.()
    after
      :logger.remove_primary_filter(:insider_logger)
    end
  end

  defp assert_eventually(predicate, attempts \\ 100)

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
