defmodule Insider.LiveTest do
  # One collector session is global per node, and the environment tests change
  # the `:insider` application environment, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.Session.Manager
  alias Insider.Event.Canonical
  alias Insider.Live
  alias Insider.Live.Environment

  defmodule Backlog do
    use GenServer

    @impl true
    def init(_test), do: {:ok, nil}

    # Blocks in a selective receive, so every other message waits: a
    # backed-up server.
    @impl true
    def handle_call({:block, notify}, _from, state) do
      send(notify, {:blocked, self()})

      receive do
        :release -> {:reply, :ok, state}
      end
    end
  end

  @tick [:insider_live_test, :tick]
  @telemetry %{
    "components" => ["telemetry"],
    "telemetry_events" => [["insider_live_test", "tick"]],
    "telemetry_measurements" => ["count"]
  }

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)
      Application.delete_env(:insider, :live_telemetry_measurements)
      Application.delete_env(:insider, :live_disclosure)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      # Collector cleanup finishes asynchronously in the Manager; the next
      # test needs the one global session slot free.
      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  test "a cursor read after N events returns exactly those events in order and renews the lease" do
    assert {:ok, started} = Live.start(Map.put(@telemetry, "lease_ms", 60_000))
    assert plain?(started)
    id = started["session_id"]
    assert %{"cursor" => 0, "state" => "running", "components" => ["telemetry"]} = started

    for count <- 1..5,
        do: :telemetry.execute(@tick, %{count: count}, %{secret: "never-projected"})

    assert {:ok, batch} = Live.events_since(id, 0)
    assert plain?(batch)
    assert Enum.map(batch["events"], & &1["receipt"]) == [1, 2, 3, 4, 5]
    assert Enum.map(batch["events"], &measurement(&1, "count")) == [1, 2, 3, 4, 5]
    assert Enum.all?(batch["events"], &(&1["event"]["kind"] == "insider_live_test.tick"))
    assert %{"next_cursor" => 5, "truncated" => false, "gaps" => []} = batch
    assert batch["lease_remaining_ms"] > 59_000
    refute Jason.encode!(batch) =~ "never-projected"

    assert {:ok, %{"events" => [], "next_cursor" => 5}} = Live.events_since(id, 5)

    assert {:ok, %{"events" => first, "next_cursor" => 2, "truncated" => true}} =
             Live.events_since(id, 0, %{"limit" => 2})

    assert Enum.map(first, & &1["receipt"]) == [1, 2]

    assert {:ok, %{"events" => rest}} = Live.events_since(id, 2)
    assert Enum.map(rest, & &1["receipt"]) == [3, 4, 5]

    assert {:ok, %{"lease_ms" => 60_000} = renewed} = Live.renew(id)
    assert plain?(renewed)
  end

  test "eviction between reads is reported as a counted receipt-range gap" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "max_events", 16))

    for count <- 1..4, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"next_cursor" => 4, "gaps" => []}} = Live.events_since(id, 0)

    for count <- 5..24, do: :telemetry.execute(@tick, %{count: count}, %{})

    assert {:ok, batch} = Live.events_since(id, 4, %{"limit" => 100})
    assert Enum.map(batch["events"], & &1["receipt"]) == Enum.to_list(9..24)
    assert batch["gaps"] == [%{"reason" => "evicted", "count" => 4, "scope" => "receipt_range"}]
    assert batch["next_cursor"] == 24
  end

  # Without a view a read took only `limit` entries,
  # so an entry redaction withheld ended it early and it reported an
  # exhausted scan budget it had not used.
  test "an entry redaction withholds does not end a read early, with or without a view" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    for count <- 1..3, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"next_cursor" => 3}} = Live.events_since(id, "latest")

    # Receipt 1 no longer matches the session's classification policy, so the
    # redaction pass withholds it.
    session = :sys.get_state(Manager).active.pid
    entries = :sys.get_state(session).recorder_handle.entries
    [{1, _at, _priority, _size, _canonical, classification, _id, _keys}] = :ets.lookup(entries, 1)
    true = :ets.update_element(entries, 1, {6, %{classification | policy_id: "tampered"}})

    withheld = gap("redaction_withheld", 1, "receipt_range")

    for options <- [%{"limit" => 1}, %{"limit" => 1, "view" => %{}}] do
      assert {:ok, batch} = Live.events_since(id, 0, options)
      assert Enum.map(batch["events"], & &1["receipt"]) == [2], inspect(options)
      assert %{"next_cursor" => 2, "truncated" => true, "truncated_by" => "limit"} = batch
      assert batch["gaps"] == [withheld]
    end

    for options <- [%{"limit" => 2}, %{"limit" => 2, "view" => %{}}] do
      assert {:ok, batch} = Live.events_since(id, 0, options)
      assert Enum.map(batch["events"], & &1["receipt"]) == [2, 3], inspect(options)
      assert %{"next_cursor" => 3, "truncated" => false, "truncated_by" => nil} = batch
      assert batch["gaps"] == [withheld]
    end

    # The scan budget still counts the withheld entry.
    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 5, "scan_limit" => 1})
    assert %{"events" => [], "next_cursor" => 1, "truncated_by" => "scan_limit"} = batch
    assert batch["gaps"] == [withheld]
  end

  test "a reader can tail from the newest receipt that status and invalid_cursor name" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "max_events", 16))
    for count <- 1..20, do: :telemetry.execute(@tick, %{count: count}, %{})

    # "latest" resolves after the read drains the inboxes: an empty batch at
    # the newest receipt.
    assert {:ok, tail} = Live.events_since(id, "latest")
    assert %{"cursor" => 20, "next_cursor" => 20, "next_receipt" => 20, "events" => []} = tail
    assert %{"truncated" => false, "truncated_by" => nil, "gaps" => []} = tail

    assert {:ok, status} = Live.status(id)
    assert status["next_receipt"] == 20

    assert %{
             "oldest_receipt" => 5,
             "retained_events" => 16,
             "max_events" => 16,
             "max_bytes" => 4_194_304,
             "retained_bytes" => bytes
           } = status["recorder"]

    assert bytes > 0
    refute Map.has_key?(status["health"], "recorder")

    for count <- 21..22, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"events" => events, "next_cursor" => 22}} = Live.events_since(id, 20)
    assert Enum.map(events, & &1["receipt"]) == [21, 22]

    for cursor <- [23, -1, "newest", 1.5] do
      assert {:error, error} = Live.events_since(id, cursor)
      assert plain?(error)
      assert %{"code" => "invalid_cursor", "oldest_receipt" => 7, "next_receipt" => 22} = error
    end

    assert {:ok, stopped} = Live.stop(id)
    assert %{"next_receipt" => nil, "recorder" => nil} = stopped
  end

  test "a subscription starts at a cursor or the newest receipt and stops at its event budget" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    for count <- 1..3, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"next_cursor" => 3}} = Live.events_since(id, 0)

    assert {:error, %{"code" => "invalid_cursor", "next_receipt" => 3}} =
             Live.subscribe(id, self(), %{"cursor" => 4})

    assert {:error, %{"code" => "invalid_options", "field" => "max_events"}} =
             Live.subscribe(id, self(), %{"max_events" => 0})

    assert {:ok, subscription} =
             Live.subscribe(id, self(), %{"cursor" => "latest", "max_events" => 4})

    assert %{"cursor" => 3, "max_events" => 4, "subscribed" => true} = subscription

    for count <- 4..9, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert_receive {:insider_live_events, ^id, batch}, 3_000
    assert Enum.map(batch["events"], & &1["receipt"]) == [4, 5, 6, 7]
    assert %{"cursor" => 3, "next_cursor" => 7, "truncated_by" => "limit"} = batch

    # The budget is spent: a later tick sends nothing.
    owner = Process.whereis(Insider.Live.Owner)
    :erlang.trace(owner, true, [:receive])
    assert_receive {:trace, ^owner, :receive, :push}, 2_000
    :erlang.trace(owner, false, [:receive])
    assert {:ok, %{"subscribers" => 1}} = Live.status(id)
    refute_received {:insider_live_events, ^id, _batch}

    # Subscribing again without a cursor keeps it and replaces the budget.
    assert {:ok, %{"cursor" => 7, "max_events" => 1}} =
             Live.subscribe(id, self(), %{"max_events" => 1})

    assert_receive {:insider_live_events, ^id, batch}, 3_000
    assert %{"cursor" => 7, "next_cursor" => 8, "events" => [%{"receipt" => 8}]} = batch

    # A cursor given again moves the subscription there.
    assert {:ok, %{"cursor" => 2, "max_events" => 1}} =
             Live.subscribe(id, self(), %{"cursor" => 2, "max_events" => 1})

    assert_receive {:insider_live_events, ^id, batch}, 3_000
    assert %{"cursor" => 2, "next_cursor" => 3, "events" => [%{"receipt" => 3}]} = batch

    # The terminal batch carries no events beyond the budget.
    assert {:ok, _stopped} = Live.stop(id)
    assert_receive {:insider_live_events, ^id, %{"state" => "stopped"} = final}, 3_000
    assert %{"cursor" => 3, "next_cursor" => 3, "events" => []} = final
  end

  test "ingress shedding is a counted gap relative to the cursor it was issued with" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    collector = telemetry_collector()

    :ok = :sys.suspend(collector)
    for count <- 1..300, do: :telemetry.execute(@tick, %{count: count}, %{})
    :ok = :sys.resume(collector)

    all = %{"limit" => 500, "max_bytes" => 1_048_576}
    assert {:ok, batch} = Live.events_since(id, 0, all)
    assert Enum.map(batch["events"], &measurement(&1, "count")) == Enum.to_list(1..256)
    assert batch["gaps"] == [gap("telemetry_shed", 44, "since_session_start")]

    cursor = batch["next_cursor"]
    assert {:ok, %{"gaps" => []}} = Live.events_since(id, cursor, all)

    :ok = :sys.suspend(collector)
    for count <- 1..257, do: :telemetry.execute(@tick, %{count: count}, %{})
    :ok = :sys.resume(collector)

    assert {:ok, batch} = Live.events_since(id, cursor, all)
    assert batch["gaps"] == [gap("telemetry_shed", 1, "since_cursor_issued")]
  end

  test "lease expiry stops the session and status reports the cleanup receipt" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 1_000))
    assert {:ok, _subscription} = Live.subscribe(id, self())

    assert_receive {:insider_live_events, ^id, %{"state" => "expired"} = final}, 3_000
    assert plain?(final)

    status = await_receipt_settled(id)
    assert plain?(status)
    assert %{"state" => "expired", "reason" => "lease_expired"} = status
    assert status["receipt"]["outcome"] == "stopped"
    assert final["receipt"] in [nil, status["receipt"]]
    assert status["receipt"]["cleanup"]["telemetry_handler"] == "absent"
    assert Live.capabilities()["active_session_id"] == nil
    assert {:error, %{"code" => "session_terminal"} = error} = Live.events_since(id, 0)
    assert error["status"]["state"] == "expired"
    assert {:error, %{"code" => "session_terminal"}} = Live.renew(id)
  end

  test "the caller process exiting does not stop the session" do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, %{"session_id" => id}} = Live.start(@telemetry)
        send(parent, {:started, id})
      end)

    monitor = Process.monitor(caller)
    assert_receive {:started, id}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 2_000

    :telemetry.execute(@tick, %{count: 1}, %{})

    assert {:ok, %{"state" => "running", "health" => health}} = Live.status(id)
    assert health["state"] == "running"
    assert {:ok, %{"events" => [_event]}} = Live.events_since(id, 0)

    assert {:ok, stopped} = Live.stop(id)
    assert plain?(stopped)
    assert %{"state" => "stopped", "reason" => "stop_requested"} = stopped
    assert stopped["receipt"]["outcome"] == "stopped"
    assert {:ok, ^stopped} = Live.stop(id)
  end

  test "a subscriber receives bounded batches and a dead subscriber is dropped" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

    :telemetry.execute(@tick, %{count: 1}, %{})
    :telemetry.execute(@tick, %{count: 2}, %{})

    relay = spawn(fn -> relay(parent) end)
    assert {:ok, subscription} = Live.subscribe(id, relay)
    assert plain?(subscription)
    assert %{"subscribed" => true, "subscribers" => 1} = subscription

    assert_receive {:relayed, {:insider_live_events, ^id, batch}}, 3_000
    assert plain?(batch)
    assert Enum.map(batch["events"], &measurement(&1, "count")) == [1, 2]
    assert %{"cursor" => 0, "next_cursor" => 2, "state" => "running"} = batch

    owner = Process.whereis(Insider.Live.Owner)
    :erlang.trace(owner, true, [:receive])
    relay_monitor = Process.monitor(relay)
    Process.exit(relay, :kill)
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :killed}, 1_000

    # Once the owner has taken the DOWN into its mailbox, this call queues
    # behind it, so status observes the drop without polling.
    assert_receive {:trace, ^owner, :receive, {:DOWN, _ref, :process, ^relay, :killed}}, 1_000
    :erlang.trace(owner, false, [:receive])

    assert {:ok, %{"subscribers" => 0}} = Live.status(id)

    assert {:ok, %{"subscribed" => true}} = Live.subscribe(id, self())
    assert {:ok, %{"subscribed" => false, "subscribers" => 0}} = Live.unsubscribe(id, self())
    assert {:error, %{"code" => "invalid_subscriber"}} = Live.subscribe(id, :not_a_pid)

    subscribers = for _index <- 1..4, do: spawn(fn -> relay(parent) end)
    for pid <- subscribers, do: assert({:ok, _subscription} = Live.subscribe(id, pid))
    assert {:error, %{"code" => "subscriber_limit"}} = Live.subscribe(id, self())

    assert {:ok, %{"receipt" => receipt}} = Live.stop(id)

    for _pid <- subscribers do
      assert_receive {:relayed, {:insider_live_events, ^id, %{"state" => "stopped"} = final}},
                     1_000

      assert final["receipt"] == receipt
    end
  end

  test "staging, production, and unconfigured environments are refused" do
    for environment <- [:staging, :production, :unexpected] do
      Application.put_env(:insider, :environment, environment)

      assert {:error, error} = Live.start(@telemetry)
      assert plain?(error)
      assert %{"code" => "environment_denied", "allowed" => false} = error

      capabilities = Live.capabilities()
      assert capabilities["allowed"] == false
      assert capabilities["environment_source"] == "application_env"
    end

    assert %{"environment" => "unrecognized"} = Live.capabilities()

    production = %{environment: :production, source: :application_env}
    assert Insider.Application.children(production) == [Insider.Collector.Session.RootSupervisor]
    refute Environment.allowed?(%{environment: :unconfigured, source: :none})

    Application.put_env(:insider, :environment, :ci)
    assert %{"environment" => "ci", "allowed" => true} = Live.capabilities()

    Application.delete_env(:insider, :environment)
    assert %{"environment" => "test", "environment_source" => "mix_env"} = Live.capabilities()
  end

  test "capabilities describe the node and the live contract without starting a session" do
    capabilities = Live.capabilities()

    assert plain?(capabilities)
    assert capabilities["schema"] == "insider.live-capabilities/v1"
    assert capabilities["insider_version"] == Mix.Project.config()[:version]
    assert capabilities["allowed"] == true
    assert capabilities["owner_running"] == true
    assert capabilities["components"] == ["calls", "logger", "otel", "poller", "telemetry"]
    # The SDK is a test dependency of this node, present but never started.
    assert capabilities["otel"] == %{"sdk_present" => true, "sdk_running" => false}
    assert capabilities["active_session_id"] == nil

    assert capabilities["bounds"]["lease_ms"] == %{
             "default" => 120_000,
             "max" => 900_000,
             "min" => 1_000
           }

    assert :sys.get_state(Manager).active == nil
  end

  test "malformed options and unknown sessions are closed-vocabulary errors" do
    errors = [
      Live.start(%{"components" => ["system_monitor"]}),
      Live.start(%{"components" => []}),
      Live.start(%{"unknown" => true}),
      Live.start(%{"components" => ["telemetry"]}),
      Live.start(%{"log_payload" => true, "components" => ["logger"]}),
      Live.start(%{"lease_ms" => 10}),
      Live.start(%{"components" => ["logger"], "telemetry_events" => [["a"]]}),
      Live.start(Map.put(@telemetry, "telemetry_events", [["Not", "valid"]])),
      Live.start(:not_a_map),
      Live.start(
        Map.put(@telemetry, "telemetry_measurements", ["insider_live_never_an_atom_q9z"])
      ),
      Live.start(Map.put(@telemetry, "telemetry_events", [["insider_live_never_an_atom_q9z"]])),
      Live.events_since("live-missing", 0),
      Live.renew("live-missing"),
      Live.status("live-missing"),
      Live.stop("live-missing")
    ]

    assert Enum.map(errors, fn {:error, error} -> error["code"] end) ==
             List.duplicate("invalid_options", 10) ++
               ["unknown_telemetry_event"] ++
               List.duplicate("unknown_session", 4)

    assert Enum.all?(errors, &plain?/1)
    assert {:error, %{"field" => "unknown"}} = Live.start(%{"unknown" => true})
    assert {:error, %{"field" => "log_payload"}} = Live.start(%{"log_payload" => true})

    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

    assert {:error, %{"code" => "session_already_active", "active_session_id" => ^id}} =
             Live.start(@telemetry)

    assert {:error, %{"code" => "invalid_cursor"}} = Live.events_since(id, -1)
    assert {:error, %{"code" => "invalid_cursor"}} = Live.events_since(id, 1)
    assert {:error, %{"code" => "invalid_options"}} = Live.events_since(id, 0, %{"limit" => 0})

    documented =
      File.read!(Path.expand("../../docs/live/live-welcome-and-reports.md", __DIR__))

    for code <- Insider.Live.Error.codes() do
      assert documented =~ "`#{code}`",
             "docs/live/live-welcome-and-reports.md must document error code #{code}"
    end
  end

  # The strict disclosure profile (the ci default) is the original boundary.
  # `Insider.Live.DisclosureTest` covers the rich profile.
  test "strict: Logger message content, reports, and metadata never leave the node" do
    Application.put_env(:insider, :environment, :ci)
    secret = "api_key=synthetic-review-secret"
    # The quiet default records warning and above; this test needs notices.
    assert {:ok, %{"session_id" => id} = started} =
             Live.start(%{"components" => ["logger"], "logger_level" => "debug"})

    refute Map.has_key?(started, "log_payload")

    capture_log(fn ->
      :logger.notice(secret)
      :logger.error(%{token: secret, nested: [secret]})
      :logger.warning(~c"#{secret}")
      :logger.notice("plain", %{secret_metadata: secret})
    end)

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
    logged = Enum.filter(batch["events"], &(&1["event"]["source"] == "logger"))
    assert Enum.count_until(logged, 4) == 4
    assert Enum.all?(logged, &is_nil(&1["event"]["payload"]))
    refute Jason.encode!(batch) =~ "synthetic-review-secret"
    refute Live.JSON.events_since(id, 0, %{"limit" => 500}) =~ "synthetic-review-secret"
  end

  test "strict: Logger causality and supervisor identities are withheld unless opaque" do
    Application.put_env(:insider, :environment, :ci)
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    span_id = "00f067aa0ba902b7"

    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "debug"})

    capture_log(fn ->
      :logger.notice("ordinary", %{
        trace_id: "synthetic-trace-secret",
        span_id: "synthetic-span-secret",
        logical_operation_id: "synthetic-operation-secret",
        parent_event_id: "synthetic-parent-secret",
        process_generation: "synthetic-generation-secret"
      })

      :logger.notice("correlated", %{trace_id: trace_id, span_id: span_id})

      :logger.error(
        %{
          label: {:supervisor, :child_terminated},
          report: [
            supervisor: {:local, :insider_live_test_sup},
            errorContext: :child_terminated,
            reason: :boom,
            offender: [pid: self(), id: "synthetic-child-secret", restart_type: :temporary]
          ]
        },
        %{domain: [:otp, :sasl]}
      )
    end)

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
    json = Live.JSON.events_since(id, 0, %{"limit" => 500})

    for output <- [Jason.encode!(batch), json], do: refute(output =~ "synthetic-")

    causalities = Enum.map(batch["events"], & &1["event"]["causality"])

    assert %{"trace_id" => ^trace_id, "span_id" => ^span_id} =
             Enum.find(causalities, & &1["trace_id"])

    assert Enum.all?(causalities, fn causality ->
             is_nil(causality["logical_operation_id"]) and is_nil(causality["parent_event_id"]) and
               is_nil(causality["process_generation"])
           end)

    withheld = Enum.flat_map(batch["events"], & &1["redactions"])
    paths = MapSet.new(withheld, & &1["path"])
    assert ["key:causality", "key:logical_operation_id"] in paths
    assert ["key:causality", "key:trace_id"] in paths
    assert Enum.all?(withheld, &(&1["policy_id"] == "insider-live-boundary/v1"))

    terminated =
      Enum.find(batch["events"], &(&1["event"]["kind"] == "supervisor_child_terminated"))

    assert "binary-sha256:" <> digest = terminated["event"]["attributes"]["offender_id"]
    assert byte_size(digest) == 64
  end

  test "strict: telemetry measurements are numeric values from the host allowlist only" do
    Application.put_env(:insider, :environment, :ci)

    assert {:error, %{"code" => "invalid_options", "field" => "telemetry_measurements"}} =
             Live.start(Map.put(@telemetry, "telemetry_measurements", ["api_key"]))

    assert "duration" in Live.capabilities()["telemetry_measurements_allowed"]

    # The duration values here are not durations; keep every event.
    options =
      @telemetry
      |> Map.put("telemetry_measurements", ["count", "duration"])
      |> Map.put("telemetry_min_duration_ms", 0)

    assert {:ok, %{"session_id" => id}} = Live.start(options)

    :telemetry.execute(
      @tick,
      %{count: 1, duration: "synthetic-duration-secret", api_key: "k"},
      %{}
    )

    :telemetry.execute(@tick, %{count: 2, duration: 1.5}, %{})

    assert {:ok, batch} = Live.events_since(id, 0)
    refute Jason.encode!(batch) =~ "synthetic-"
    refute Live.JSON.events_since(id, 0) =~ "synthetic-"

    assert [first, second] =
             Enum.map(batch["events"], & &1["event"]["attributes"]["measurements"])

    assert first == %{"count" => 1, "duration" => nil}
    assert second == %{"count" => 2, "duration" => "1.5"}

    # api_key was never selected (and is not nameable), so the collector only
    # counts it; the non-numeric duration is the boundary's drop.
    assert [
             %{
               "path" => ["key:attributes", "key:measurements"],
               "count" => 1,
               "policy_id" => "insider-live-telemetry"
             },
             %{
               "path" => ["key:attributes", "key:measurements", "key:duration"],
               "policy_id" => "insider-live-boundary/v1"
             }
           ] = hd(batch["events"])["redactions"]

    # Non-numeric scalars (here a boolean) are withheld. The boundary applies
    # the allowlist at read time, so a host that narrows it during a session
    # narrows what that session discloses from then on.
    :telemetry.execute(@tick, %{count: 3, duration: true}, %{})
    assert {:ok, %{"events" => [third]}} = Live.events_since(id, 2)
    assert third["event"]["attributes"]["measurements"] == %{"count" => 3, "duration" => nil}

    Application.put_env(:insider, :live_telemetry_measurements, [:count])
    :telemetry.execute(@tick, %{count: 4, duration: 7}, %{})

    assert {:ok, %{"events" => [fourth]}} = Live.events_since(id, 3)
    assert fourth["event"]["attributes"]["measurements"] == %{"count" => 4}
    refute Jason.encode!(fourth["event"]) =~ "duration"

    assert [%{"path" => ["key:attributes", "key:measurements", "key:duration"]}] =
             fourth["redactions"]

    assert {:ok, _stopped} = Live.stop(id)
    assert Live.capabilities()["telemetry_measurements_allowed"] == ["count"]

    assert {:error, %{"field" => "telemetry_measurements"}} =
             Live.start(Map.put(@telemetry, "telemetry_measurements", ["duration"]))

    for invalid <- [["not_an_atom_list"], :count, %{count: true}] do
      Application.put_env(:insider, :live_telemetry_measurements, invalid)
      assert Live.capabilities()["telemetry_measurements_allowed"] == []
    end
  end

  test "a failed revocation retries cleanup on its own and keeps denying observation" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 900_000))
    relay = spawn(fn -> relay(parent) end)
    assert {:ok, _subscription} = Live.subscribe(id, relay)

    manager = Process.whereis(Manager)
    :ok = :sys.suspend(manager)
    on_exit(fn -> resume(manager) end)
    Application.put_env(:insider, :environment, :production)

    assert {:error, %{"code" => "environment_denied", "revocation_pending" => true} = denied} =
             Live.events_since(id, 0)

    refute Map.has_key?(denied, "status")
    %{session: %{lease_timer: timer}} = :sys.get_state(Insider.Live.Owner)
    assert Process.read_timer(timer) <= 1_000

    Application.put_env(:insider, :environment, :test)

    assert {:error, %{"code" => "environment_denied", "revocation_pending" => true}} =
             Live.renew(id)

    :ok = :sys.resume(manager)

    assert_receive {:relayed, {:insider_live_events, ^id, %{"state" => "revoked"} = final}},
                   5_000

    status = await_receipt_settled(id)
    assert %{"state" => "revoked"} = status
    assert status["receipt"]["outcome"] == "stopped"
    assert final["receipt"] in [nil, status["receipt"]]
  end

  test "cursor zero always reports losses since session start" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    session = :sys.get_state(Manager).active.pid
    recorder = :sys.get_state(session).recorder_handle
    assert {:dropped, :invalid_event} = Insider.Recorder.record(recorder, :not_an_event)

    invalid = %{
      "reason" => "recorder_invalid_event",
      "count" => 1,
      "scope" => "since_session_start"
    }

    for _reader <- 1..2 do
      assert {:ok, %{"next_cursor" => 0, "gaps" => [^invalid]}} = Live.events_since(id, 0)
    end
  end

  test "a host environment change revokes the active session and denies observation" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    relay = spawn(fn -> relay(parent) end)
    assert {:ok, _subscription} = Live.subscribe(id, relay)
    :telemetry.execute(@tick, %{count: 1}, %{})

    Application.put_env(:insider, :environment, :production)

    assert {:error, %{"code" => "environment_denied", "allowed" => false} = denied} =
             Live.events_since(id, 0)

    refute Map.has_key?(denied, "events")
    assert %{"state" => "revoked", "reason" => "environment_denied"} = denied["status"]
    assert denied["status"]["receipt"] in [nil, await_collector_receipt(handle)]

    assert_receive {:relayed, {:insider_live_events, ^id, %{"state" => "revoked"} = final}},
                   2_000

    assert final["events"] == []
    assert [%{"reason" => "final_read_withheld", "count" => nil}] = final["gaps"]
    assert final["receipt"] == denied["status"]["receipt"]

    assert {:error, %{"code" => "environment_denied"}} = Live.renew(id)
    assert {:error, %{"code" => "environment_denied"}} = Live.subscribe(id, self())
    assert {:ok, %{"state" => "revoked"}} = Live.status(id)
    assert {:ok, %{"state" => "revoked"}} = Live.stop(id)
    assert %{"outcome" => "stopped"} = await_collector_receipt(handle)
  end

  test "a subscription tick revokes the session when the environment is no longer allowed" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    relay = spawn(fn -> relay(parent) end)
    assert {:ok, _subscription} = Live.subscribe(id, relay)

    Application.put_env(:insider, :environment, :staging)
    :telemetry.execute(@tick, %{count: 1}, %{})

    assert_receive {:relayed, {:insider_live_events, ^id, batch}}, 2_000
    assert %{"state" => "revoked", "events" => []} = batch
    assert %{"outcome" => "stopped"} = await_collector_receipt(handle)
  end

  test "ending a session cancels its lease timer" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 900_000))
    %{session: %{lease_timer: timer}} = :sys.get_state(Insider.Live.Owner)
    assert is_integer(Process.read_timer(timer))

    assert {:ok, _stopped} = Live.stop(id)
    refute Process.read_timer(timer)
  end

  test "renewal and subscription reconcile a collector session that already ended" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    stop_collector(handle)

    assert {:error, %{"code" => "session_terminal", "status" => status}} = Live.renew(id)
    assert %{"state" => "terminated", "reason" => "session_ended"} = status
    assert {:error, %{"code" => "session_terminal"}} = Live.subscribe(id, self())
  end

  test "a start that expires in the owner queue has no side effect" do
    owner = Process.whereis(Insider.Live.Owner)
    :ok = :sys.suspend(owner)
    on_exit(fn -> resume(owner) end)

    task = Task.async(fn -> Live.start(@telemetry) end)
    assert {:error, %{"code" => "timeout"}} = Task.await(task, 10_000)

    :ok = :sys.resume(owner)
    assert Live.capabilities()["active_session_id"] == nil
    assert :sys.get_state(Manager).active == nil
  end

  test "owner admission is bounded and rejects excess callers before they queue" do
    owner = Process.whereis(Insider.Live.Owner)
    :ok = :sys.suspend(owner)
    on_exit(fn -> resume(owner) end)
    parent = self()
    limit = Insider.Live.Owner.bounds()["admitted_calls_max"]

    tasks =
      for _index <- 1..(limit + 8) do
        Task.async(fn ->
          result = Live.renew("live-missing")
          send(parent, {:renew_result, result})
          result
        end)
      end

    for _index <- 1..8 do
      assert_receive {:renew_result, {:error, %{"code" => "busy"}}}, 2_000
    end

    refute_receive {:renew_result, _result}, 100
    :ok = :sys.resume(owner)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:error, %{"code" => "unknown_session"}}, &1)) == limit
  end

  test "malformed option keys produce a decodable JSON error and the owner stays usable" do
    for options <- [
          %{<<255>> => true},
          %{:atom_key => 1},
          %{1 => 2},
          %{nil => true},
          %{true => 1},
          %{false => 1},
          Map.put(@telemetry, nil, true),
          Map.put(@telemetry, false, true)
        ] do
      assert %{"error" => %{"code" => "invalid_options", "field" => "options"}} =
               canonical!(Live.JSON.start(options))

      assert Live.capabilities()["active_session_id"] == nil
      assert :sys.get_state(Manager).active == nil
    end

    assert {:ok, %{"session_id" => read_id}} = Live.start(@telemetry)

    for options <- [%{nil => 1}, %{true => 1}, %{:limit => 1}] do
      assert {:error, %{"code" => "invalid_options", "field" => "options"}} =
               Live.events_since(read_id, 0, options)
    end

    assert {:ok, _stopped} = Live.stop(read_id)

    assert %{"error" => %{"code" => "unknown_session"}} =
             canonical!(Live.JSON.events_since(<<255>>, 0))

    assert %{"ok" => %{"owner_responsive" => true}} = canonical!(Live.JSON.capabilities())
    assert %{"ok" => %{"session_id" => id}} = canonical!(Live.JSON.start(@telemetry))
    assert %{"ok" => %{"state" => "stopped"}} = canonical!(Live.JSON.stop(id))
  end

  test "the JSON facade emits one canonical JSON document per operation" do
    start = Live.JSON.start(@telemetry)
    assert %{"ok" => %{"session_id" => id}} = canonical!(start)

    :telemetry.execute(@tick, %{count: 1}, %{})

    for json <- [
          Live.JSON.capabilities(),
          Live.JSON.events_since(id, 0),
          Live.JSON.renew(id),
          Live.JSON.status(id),
          Live.JSON.subscribe(id, self()),
          Live.JSON.unsubscribe(id, self())
        ] do
      assert %{"ok" => _result} = canonical!(json)
    end

    assert %{"ok" => %{"state" => "stopped"}} = canonical!(Live.JSON.stop(id))

    assert %{"error" => %{"code" => "unknown_session"}} =
             canonical!(Live.JSON.status("live-missing"))
  end

  test "a node without Mix or configuration is unconfigured and denied" do
    unconfigured = Environment.resolve([])
    assert unconfigured == %{environment: :unconfigured, source: :none}
    refute Environment.allowed?(unconfigured)

    assert %{"environment" => "test", "environment_source" => "mix_env"} =
             Environment.describe(Environment.resolve([{:mix, ~c"mix", ~c"1"}]))

    Application.put_env(:insider, :environment, :ci)
    assert %{environment: :ci, source: :application_env} = Environment.resolve([])
  end

  test "calls report the owner as unavailable while it is down, then it restarts empty" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    on_exit(fn -> Supervisor.restart_child(Insider.Supervisor, Insider.Live.Owner) end)
    :ok = Supervisor.terminate_child(Insider.Supervisor, Insider.Live.Owner)

    assert {:error, %{"code" => "unavailable"}} = Live.status(id)

    assert %{"error" => %{"code" => "unavailable"}} = canonical!(Live.JSON.start(@telemetry))

    assert %{"owner_running" => false, "owner_responsive" => false, "active_session_id" => nil} =
             Live.capabilities()

    Application.put_env(:insider, :environment, :production)
    assert {:error, %{"code" => "environment_denied", "allowed" => false}} = Live.status(id)
    Application.delete_env(:insider, :environment)

    # The owner's exit stops its collector session through the Manager's
    # asynchronous owner-down cleanup, which ends in a retained receipt.
    assert %{"outcome" => "stopped"} = await_collector_receipt(handle)

    # restart_child returns only after the new owner's init has completed.
    assert {:ok, _pid} = Supervisor.restart_child(Insider.Supervisor, Insider.Live.Owner)
    assert %{"owner_responsive" => true, "active_session_id" => nil} = Live.capabilities()
    assert {:error, %{"code" => "unknown_session"}} = Live.status(id)
  end

  test "a call queued on an owner that dies is answered unavailable" do
    owner = Process.whereis(Insider.Live.Owner)
    monitor = Process.monitor(owner)
    :ok = :sys.suspend(owner)
    task = Task.async(fn -> Live.status("live-missing") end)
    await_queued(owner)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
    assert {:error, %{"code" => "unavailable"}} = Task.await(task, 5_000)

    restarted = await_owner_restart(owner)

    assert %{"owner_running" => true, "owner_responsive" => true, "active_session_id" => nil} =
             Live.capabilities()

    assert Process.whereis(Insider.Live.Owner) == restarted
  end

  test "capabilities report an owner that does not answer instead of blocking" do
    owner = Process.whereis(Insider.Live.Owner)
    :ok = :sys.suspend(owner)
    on_exit(fn -> resume(owner) end)

    assert %{"owner_running" => true, "owner_responsive" => false, "active_session_id" => nil} =
             Live.capabilities()
  end

  test "an environment change between the gate and collector startup is environment_denied" do
    assert {:ok, %{"session_id" => old}} = Live.start(@telemetry)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    stop_collector(handle)

    # The owner still holds the ended session, so the next start first asks
    # the Manager for its health. Hold that request while the host changes.
    manager = Process.whereis(Manager)
    on_exit(fn -> resume(manager) end)
    :ok = :sys.suspend(manager)
    task = Task.async(fn -> Live.start(@telemetry) end)
    await_queued(manager)
    Application.put_env(:insider, :environment, :production)
    :ok = :sys.resume(manager)

    assert {:error, error} = Task.await(task, 10_000)
    assert %{"code" => "environment_denied", "allowed" => false} = error
    assert error["environment"] == "production"
    assert {:ok, %{"state" => "terminated"}} = Live.status(old)
    assert Live.capabilities()["active_session_id"] == nil
  end

  test "an admitted request for an unknown operation is refused and the owner survives" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    owner = Process.whereis(Insider.Live.Owner)
    {:ok, admission} = Insider.Live.Owner.admission(owner)
    :ok = Insider.Collector.Admission.acquire(admission, Insider.Live.Owner.admitted_calls_max())
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert {:error, %{"code" => "invalid_options", "field" => "request"}} =
             GenServer.call(owner, {:admitted, admission, deadline, {:unknown_operation}})

    assert Process.whereis(Insider.Live.Owner) == owner
    :telemetry.execute(@tick, %{count: 1}, %{})
    assert {:ok, %{"events" => [_event]}} = Live.events_since(id, 0)
  end

  test "raw owner calls that bypass admission are refused without side effects" do
    assert {:error, %{"code" => "invalid_options", "field" => "request"}} =
             GenServer.call(Insider.Live.Owner, {:start, @telemetry})

    assert Live.capabilities()["active_session_id"] == nil
    assert :sys.get_state(Manager).active == nil
  end

  test "status and reads report a collector session that ended underneath the owner" do
    for read? <- [false, true] do
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
      receipt = stop_collector(handle)
      assert receipt["outcome"] == "stopped"

      status =
        if read? do
          assert {:error, %{"code" => "session_terminal", "status" => status}} =
                   Live.events_since(id, 0)

          status
        else
          assert {:ok, status} = Live.status(id)
          status
        end

      assert %{"state" => "terminated", "reason" => "session_ended"} = status
      assert status["receipt"] == receipt
      assert Live.capabilities()["active_session_id"] == nil
    end
  end

  test "a subscriber learns that the collector session ended underneath the owner" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    relay = spawn(fn -> relay(parent) end)
    assert {:ok, _subscription} = Live.subscribe(id, relay)
    %{session: %{handle: handle}} = :sys.get_state(Insider.Live.Owner)
    receipt = stop_collector(handle)

    assert_receive {:relayed, {:insider_live_events, ^id, %{"state" => "terminated"} = final}},
                   3_000

    assert final["receipt"] == receipt
    assert [%{"reason" => "final_read_unavailable", "count" => nil}] = final["gaps"]
  end

  test "a collector session held by the host blocks a live start" do
    {:ok, host_policy} = Insider.Runtime.HostPolicy.new()

    {:ok, handle} =
      Insider.Collector.Session.start(host_policy,
        id: "host-held",
        environment: :test,
        authority: "live-test",
        boot_id: "boot-test",
        clock_id: "live-test-clock",
        recorder_options: [classification: Insider.TestRecorderClassification.binding()]
      )

    on_exit(fn -> Insider.Collector.Session.stop(handle) end)

    assert {:error, %{"code" => "session_already_active", "active_session_id" => nil}} =
             Live.start(@telemetry)

    assert Live.capabilities()["active_session_id"] == nil
    assert {:ok, _receipt} = Insider.Collector.Session.stop(handle)
  end

  test "an unresponsive session Manager makes start unavailable and stop keep the session" do
    manager = Process.whereis(Manager)
    on_exit(fn -> resume(manager) end)

    :ok = :sys.suspend(manager)
    assert {:error, %{"code" => "unavailable"}} = Live.start(@telemetry)
    assert Live.capabilities()["active_session_id"] == nil
    :ok = :sys.resume(manager)

    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    :ok = :sys.suspend(manager)
    assert {:error, %{"code" => "unavailable"}} = Live.stop(id)
    :ok = :sys.resume(manager)

    assert {:ok, %{"state" => "running"}} = Live.status(id)
    assert {:ok, %{"state" => "stopped", "receipt" => %{"outcome" => "stopped"}}} = Live.stop(id)
  end

  test "a lease that expires while the Manager is unresponsive is stopped once it recovers" do
    parent = self()
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 1_000))
    relay = spawn(fn -> relay(parent) end)
    assert {:ok, _subscription} = Live.subscribe(id, relay)
    manager = Process.whereis(Manager)
    on_exit(fn -> resume(manager) end)
    :ok = :sys.suspend(manager)

    refute_receive {:relayed, {:insider_live_events, ^id, %{"state" => "expired"}}}, 2_500
    :ok = :sys.resume(manager)

    assert_receive {:relayed, {:insider_live_events, ^id, %{"state" => "expired"} = final}},
                   10_000

    status = await_receipt_settled(id)
    assert %{"state" => "expired", "reason" => "lease_expired"} = status
    assert status["receipt"]["outcome"] == "stopped"
    assert final["receipt"] in [nil, status["receipt"]]
  end

  test "an early or duplicate lease check keeps a session with lease remaining" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 60_000))
    owner = Process.whereis(Insider.Live.Owner)
    %{session: %{lease_timer: first_timer}} = :sys.get_state(owner)

    # A stale timer message can arrive after a reschedule. The status call is
    # queued behind it from the same sender, so it observes the result.
    send(owner, {:lease_check, id})
    assert {:ok, %{"state" => "running", "lease_remaining_ms" => remaining}} = Live.status(id)
    assert remaining > 50_000

    %{session: %{lease_timer: timer}} = :sys.get_state(owner)
    refute Process.read_timer(first_timer)
    assert is_integer(Process.read_timer(timer))
  end

  test "option shapes are validated before any collection starts" do
    oversized = Map.new(0..length(Live.capabilities()["start_options"]), &{"key#{&1}", true})

    for {options, field} <- [
          {oversized, "options"},
          {Map.put(@telemetry, "telemetry_events", ["insider_live_test"]), "telemetry_events"},
          {Map.put(@telemetry, "telemetry_events", [
             @telemetry["telemetry_events"] |> hd(),
             @telemetry["telemetry_events"] |> hd()
           ]), "telemetry_events"}
        ] do
      assert {:error, %{"code" => "invalid_options", "field" => ^field}} = Live.start(options)
    end

    assert :sys.get_state(Manager).active == nil
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

    assert {:error, %{"code" => "invalid_options", "field" => "options"}} =
             Live.events_since(id, 0, :not_a_map)

    assert {:error, %{"code" => "unknown_session"}} = Live.unsubscribe("live-missing", self())
    assert {:error, %{"code" => "invalid_subscriber"}} = Live.unsubscribe(id, :not_a_pid)

    assert {:ok, %{"subscribed" => false, "subscribers" => 0}} =
             Live.unsubscribe(id, spawn(fn -> :ok end))
  end

  test "the Poller component reports VM samples through the live boundary unchanged" do
    assert {:ok, %{"session_id" => id, "components" => ["poller"]}} =
             Live.start(%{"components" => ["poller"]})

    assert_eventually(fn ->
      {:ok, batch} = Live.events_since(id, 0)
      Enum.any?(batch["events"], &(&1["event"]["source"] == "poller"))
    end)

    {:ok, batch} = Live.events_since(id, 0)
    sample = Enum.find(batch["events"], &(&1["event"]["source"] == "poller"))
    assert %{"metrics" => metrics, "probe_status" => status} = sample["event"]["attributes"]
    assert is_map(metrics) and is_binary(status)
    assert sample["redactions"] == []
    assert {:ok, _at, 0} = DateTime.from_iso8601(sample["event"]["wall_time"])
    assert batch["disclosure_profile"] == "rich"
  end

  test "telemetry events carry their emission wall time and durations in microseconds" do
    native = System.convert_time_unit(5_000, :millisecond, :native)

    assert {:ok, %{"session_id" => id}} =
             Live.start(Map.put(@telemetry, "telemetry_measurements", ["count", "duration"]))

    before = DateTime.utc_now()
    :telemetry.execute(@tick, %{count: 1, duration: native}, %{})
    later = DateTime.utc_now()

    assert {:ok, %{"events" => [entry], "disclosure_profile" => "rich"}} =
             Live.events_since(id, 0)

    assert {:ok, wall_time, 0} = DateTime.from_iso8601(entry["event"]["wall_time"])

    assert DateTime.compare(wall_time, before) != :lt and
             DateTime.compare(wall_time, later) != :gt

    assert entry["event"]["attributes"]["measurements"]["duration"] == native
    # `count` is not a time measurement, so it has no microsecond twin.
    assert entry["event"]["attributes"]["durations_us"] == %{"duration" => 5_000_000}
  end

  test "strict: durations in microseconds are derived only from disclosed measurements" do
    Application.put_env(:insider, :environment, :ci)
    native = System.convert_time_unit(200, :millisecond, :native)
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    :telemetry.execute(@tick, %{count: 1, duration: native}, %{})

    assert {:ok, %{"events" => [entry], "disclosure_profile" => "strict"}} =
             Live.events_since(id, 0)

    refute Map.has_key?(entry["event"]["attributes"], "durations_us")
    assert {:ok, %{"session_id" => _stopped}} = Live.stop(id)

    assert {:ok, %{"session_id" => id}} =
             Live.start(Map.put(@telemetry, "telemetry_measurements", ["duration"]))

    :telemetry.execute(@tick, %{count: 1, duration: native}, %{})
    assert {:ok, %{"events" => [entry]}} = Live.events_since(id, 0)
    assert entry["event"]["attributes"]["durations_us"] == %{"duration" => 200_000}
  end

  test "digest summarises a window: counts, crash loop period, latency, and a human summary" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger", "telemetry"],
               "telemetry_events" => [["insider_live_test", "tick"]],
               "telemetry_measurements" => ["duration"],
               "telemetry_min_duration_ms" => 0,
               # Only this test's reports, not other modules' log lines.
               "logger_include" => [%{"domain" => ["otp", "sasl"]}]
             })

    slow = System.convert_time_unit(5_001, :millisecond, :native)
    fast = System.convert_time_unit(1, :millisecond, :native)
    start_us = System.os_time(:microsecond)

    capture_log(fn ->
      for crash <- 0..2 do
        :telemetry.execute(@tick, %{duration: slow}, %{})
        :telemetry.execute(@tick, %{duration: fast}, %{})

        # Each report carries its own Logger time, three seconds apart.
        :logger.error(
          %{
            label: {:supervisor, :child_terminated},
            report: [
              supervisor: {:local, :insider_live_test_sup},
              errorContext: :child_terminated,
              reason: :boom,
              offender: [pid: self(), id: Insider.LiveTest.Inventory, restart_type: :permanent]
            ]
          },
          %{domain: [:otp, :sasl], time: start_us + crash * 3_000_000}
        )
      end
    end)

    assert {:ok, digest} = Live.digest(id, %{"human" => true})
    assert plain?(digest)

    assert %{
             "schema" => "insider.live-digest/v1",
             "session_id" => ^id,
             "state" => "running",
             "disclosure_profile" => "rich",
             "window" => %{"cursor" => 0, "events" => 9, "complete" => true, "next_cursor" => 9}
           } = digest

    assert digest["counts"]["by_kind"]["insider_live_test.tick"] == 6
    assert digest["counts"]["by_kind"]["supervisor_child_terminated"] == 3
    assert digest["counts"]["by_offender"] == %{"atom:Elixir.Insider.LiveTest.Inventory" => 3}

    assert [%{"offender" => "Insider.LiveTest.Inventory", "restarts" => 3, "period_ms" => 3_000}] =
             digest["crash_loops"]

    assert [%{"kind" => "insider_live_test.tick", "from" => "events", "count" => 6} = latency] =
             digest["latency"]

    assert latency["p95_us"] == 5_001_000 and latency["p50_us"] == 1_000

    assert digest["text"] =~
             "Crash loop: Insider.LiveTest.Inventory (permanent) terminated 3 times, every 3.0 s"

    assert digest["text"] =~ "Slowest: insider_live_test.tick"
    # A 5 s duration without a call-timeout exit is reported as latency only.
    refute digest["text"] =~ "GenServer"

    assert {:ok, %{"window" => %{"upto" => 9}}} = Live.digest(id)

    # The newest N receipts.
    assert {:ok, %{"window" => %{"cursor" => 7, "events" => 2}} = last} =
             Live.digest(id, %{"since" => "latest-2"})

    refute Map.has_key?(last, "text")
    assert {:ok, %{"window" => %{"cursor" => 0}}} = Live.digest(id, %{"since" => "latest-4096"})
    next = digest["window"]["next_cursor"]

    assert {:ok, %{"window" => %{"cursor" => ^next, "complete" => true}}} =
             Live.digest(id, %{"since" => next})

    assert %{"ok" => %{"schema" => "insider.live-digest/v1"}} =
             Jason.decode!(Live.JSON.digest(id, %{"since" => 3}))

    assert {:error, %{"code" => "invalid_options", "field" => "since"}} =
             Live.digest(id, %{"since" => "latest"})

    assert {:error, %{"code" => "invalid_cursor"}} = Live.digest(id, %{"since" => 1_000_000})
    assert {:error, %{"code" => "unknown_session"}} = Live.digest("live-none")

    assert {:error, %{"code" => "unknown_session"}} =
             Live.digest("live-none", %{"since" => "latest-5"})
  end

  # The Recorder evicts normal entries before protected ones
  # whatever their age, so a loss after the window must not be counted in
  # it, and a withheld receipt inside it must not be hidden.
  test "a digest window counts exactly its own losses when a later entry is evicted" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger", "telemetry"],
               "telemetry_events" => [["insider_live_test", "tick"]],
               "telemetry_measurements" => ["count"],
               "logger_include" => [%{"domain" => ["otp", "sasl"]}],
               "max_events" => 16
             })

    capture_log(fn ->
      for index <- 1..15 do
        :logger.error(
          %{
            label: {:supervisor, :child_terminated},
            report: [
              supervisor: {:local, :insider_live_test_sup},
              errorContext: :child_terminated,
              reason: :boom,
              offender: [pid: self(), id: {:child, index}, restart_type: :permanent]
            ]
          },
          %{domain: [:otp, :sasl]}
        )
      end
    end)

    assert {:ok, %{"next_cursor" => 15}} = Live.events_since(id, "latest")

    # Receipt 1 no longer matches the session's classification policy, so
    # the redaction pass withholds it.
    session = :sys.get_state(Manager).active.pid
    entries = :sys.get_state(session).recorder_handle.entries
    [{1, _at, _priority, _size, _canonical, classification, _id, _keys}] = :ets.lookup(entries, 1)
    true = :ets.update_element(entries, 1, {6, %{classification | policy_id: "tampered"}})

    # A read bounded at receipt 15 counts only its own losses.
    for count <- 16..17, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, bounded} = Live.events_since(id, 0, %{"upto" => 15, "limit" => 500})
    assert Enum.map(bounded["events"], & &1["receipt"]) == Enum.to_list(2..15)
    assert %{"next_cursor" => 15, "truncated" => false} = bounded
    assert bounded["gaps"] == [gap("redaction_withheld", 1, "receipt_range")]

    # Unbounded, receipt 17 evicted 16, a normal entry newer than the window.
    assert {:ok, whole} = Live.events_since(id, 0, %{"limit" => 500})
    assert Enum.map(whole["events"], & &1["receipt"]) == Enum.to_list(2..15) ++ [17]

    assert Enum.sort(whole["gaps"]) ==
             Enum.sort([
               gap("evicted", 1, "receipt_range"),
               gap("redaction_withheld", 1, "receipt_range")
             ])
  end

  test "upto must lie between the read's starting cursor and the newest receipt" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    for count <- 1..5, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"next_cursor" => 5}} = Live.events_since(id, "latest")

    # Below the cursor (an integer, or "latest" once resolved) or past the
    # newest receipt, a bound could not hold, so it is refused.
    for {cursor, upto} <- [{4, 3}, {"latest", 3}, {0, 6}, {5, 6}] do
      assert {:error, %{"code" => "invalid_options", "field" => "upto"}} =
               Live.events_since(id, cursor, %{"upto" => upto}),
             inspect({cursor, upto})
    end

    for upto <- [-1, "3", 2.5] do
      assert {:error, %{"code" => "invalid_options", "field" => "upto"}} =
               Live.events_since(id, 0, %{"upto" => upto})
    end

    # At the cursor the read is empty and complete; it never moves back.
    for {cursor, upto} <- [{0, 0}, {3, 3}, {"latest", 5}] do
      assert {:ok, %{"events" => [], "truncated" => false, "truncated_by" => nil} = batch} =
               Live.events_since(id, cursor, %{"upto" => upto})

      assert batch["next_cursor"] == upto
      assert batch["next_receipt"] == 5
    end

    # Reaching upto completes a read even when newer receipts exist.
    assert {:ok, batch} = Live.events_since(id, 1, %{"upto" => 3})
    assert Enum.map(batch["events"], & &1["receipt"]) == [2, 3]

    assert %{"next_cursor" => 3, "next_receipt" => 5, "truncated" => false, "truncated_by" => nil} =
             batch
  end

  # Integration: a read is served in pages of
  # `read_page_entries`, and its upto bound holds across them.
  test "upto bounds a read served in several pages" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(Map.put(@telemetry, "telemetry_min_duration_ms", 0))

    page = Insider.Live.Owner.bounds()["read_page_entries"]
    newest = 2 * page + 50
    for count <- 1..newest, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert {:ok, %{"next_cursor" => ^newest}} = Live.events_since(id, "latest")
    upto = page + 30

    assert {:ok, batch} =
             Live.events_since(id, 0, %{"upto" => upto, "limit" => 500, "max_bytes" => 1_048_576})

    assert Enum.map(batch["events"], & &1["receipt"]) == Enum.to_list(1..upto)

    assert %{"next_cursor" => ^upto, "next_receipt" => ^newest, "truncated" => false} = batch
    assert batch["truncated_by"] == nil
    assert batch["gaps"] == []
  end

  test "a digest admits nothing past its window and keeps the window's withheld loss" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger", "telemetry"],
               "telemetry_events" => [["insider_live_test", "tick"]],
               "telemetry_measurements" => ["count"],
               "logger_include" => [%{"domain" => ["otp", "sasl"]}],
               "max_events" => 16
             })

    capture_log(fn ->
      for index <- 1..15 do
        :logger.error(
          %{
            label: {:supervisor, :child_terminated},
            report: [
              supervisor: {:local, :insider_live_test_sup},
              errorContext: :child_terminated,
              reason: :boom,
              offender: [pid: self(), id: {:child, index}, restart_type: :permanent]
            ]
          },
          %{domain: [:otp, :sasl]}
        )
      end
    end)

    assert {:ok, %{"next_cursor" => 15}} = Live.events_since(id, "latest")
    session = :sys.get_state(Manager).active.pid
    entries = :sys.get_state(session).recorder_handle.entries
    [{1, _at, _priority, _size, _canonical, classification, _id, _keys}] = :ets.lookup(entries, 1)
    true = :ets.update_element(entries, 1, {6, %{classification | policy_id: "tampered"}})

    # The reviewer's reproduction: `upto` = 15 is captured by the latest-N
    # lookup, then normal receipts 16 and 17 arrive, and 17 evicts 16,
    # before the window is read.
    reader = fn
      "latest", options, _budget ->
        result = Live.events_since(id, "latest", options)
        for count <- 16..17, do: :telemetry.execute(@tick, %{count: count}, %{})
        result

      cursor, options, _budget ->
        Live.events_since(id, cursor, options)
    end

    deadline = System.monotonic_time(:millisecond) + 3_000

    assert {:ok, digest} =
             Insider.Live.Digest.read(id, {:last, 15}, reader, deadline, "test@host")

    assert %{"cursor" => 0, "upto" => 15, "next_cursor" => 15, "events" => 14, "complete" => true} =
             digest["window"]

    assert digest["gaps"] == [gap("redaction_withheld", 1, "receipt_range")]
  end

  # Without --since a digest covers the last minute, so
  # a long session's old history neither hides nor delays fresh activity.
  # The minute is the Recorder's admission time, which receipts follow; an
  # event's own wall time may be older or out of order.
  test "a digest without since covers what was recorded in the last minute; since 0 the session" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "info"})

    old_us = System.os_time(:microsecond) - 600_000_000
    # Odd events carry a Logger time ten minutes old, even ones the current time.
    at = fn index -> if rem(index, 2) == 1, do: %{time: old_us + index}, else: %{} end

    capture_log(fn ->
      for index <- 1..30, do: :logger.error("stale #{index}", at.(index))
    end)

    assert_eventually(fn ->
      match?({:ok, %{"next_cursor" => 30}}, Live.events_since(id, "latest"))
    end)

    # Receipts 1..30 were admitted ten minutes ago.
    entries = :sys.get_state(:sys.get_state(Manager).active.pid).recorder_handle.entries
    admitted = System.monotonic_time(:microsecond) - 600_000_000

    for receipt <- 1..30,
        do: true = :ets.update_element(entries, receipt, {2, admitted + receipt})

    capture_log(fn ->
      for index <- 31..34, do: :logger.error("fresh #{index}", at.(index))
    end)

    assert_eventually(fn ->
      match?({:ok, %{"next_cursor" => 34}}, Live.events_since(id, "latest"))
    end)

    assert {:ok, digest} = Live.digest(id, %{"human" => true})

    assert %{
             "since" => "latest-60s",
             "start_exact" => true,
             "cursor" => 30,
             "first_receipt" => 31,
             "events" => 4,
             "complete" => true,
             "upto" => 34
           } = window = digest["window"]

    assert window["age_ms"] < 60_000

    assert [_header, "Anomalies: none in this window.", "Window: the last 60 s" <> _rest | _lines] =
             String.split(digest["text"], "\n")

    assert digest["counts"]["by_severity"]["error"] == 4

    assert {:ok, %{"window" => %{"since" => 0, "events" => 34}}} =
             Live.digest(id, %{"since" => 0})

    # A stopped session's archive is probed the same way.
    assert {:ok, _stopped} = Live.stop(id)

    assert {:ok, %{"window" => %{"since" => "latest-60s", "events" => 4, "first_receipt" => 31}}} =
             Live.digest(id)
  end

  # With receipt 1 old and the rest recent, the window
  # dropped receipt 2; with two receipts it was empty. Running and retained.
  test "a time window keeps the first recent receipt right after the old ones" do
    for {n, old} <- [{2, 1}, {5, 1}, {5, 4}, {3, 0}, {3, 3}] do
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      capture_log(fn -> for index <- 1..n, do: :logger.error("event #{index}") end)

      assert_eventually(fn ->
        match?({:ok, %{"next_cursor" => ^n}}, Live.events_since(id, "latest"))
      end)

      entries = :sys.get_state(:sys.get_state(Manager).active.pid).recorder_handle.entries
      admitted = System.monotonic_time(:microsecond) - 600_000_000

      for receipt <- 1..old//1,
          do: true = :ets.update_element(entries, receipt, {2, admitted + receipt})

      expected = %{
        "cursor" => old,
        "events" => n - old,
        "start_exact" => true,
        "complete" => true
      }

      assert {:ok, %{"window" => running}} = Live.digest(id)
      assert Map.take(running, Map.keys(expected)) == expected, "#{old} old of #{n} running"
      assert {:ok, _stopped} = Live.stop(id)
      assert {:ok, %{"window" => retained}} = Live.digest(id)
      assert Map.take(retained, Map.keys(expected)) == expected, "#{old} old of #{n} retained"
    end
  end

  # A probe that met only withheld receipts
  # must not make the window falsely empty, and scans at most 1,000 entries.
  test "a time window's probe reads past withheld receipts, at most 1,000 of them" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(Map.put(@telemetry, "components", ["logger", "telemetry"]))

    # 1,000 Logger records (the Recorder's per-source rate limit), admitted
    # 100 at a time so the handler keeps up, then one Telemetry event.
    for chunk <- 1..10 do
      capture_log(fn ->
        for index <- (chunk * 100 - 99)..(chunk * 100), do: :logger.error("fresh #{index}")
      end)

      last = chunk * 100

      assert_eventually(fn ->
        match?({:ok, %{"next_cursor" => ^last}}, Live.events_since(id, "latest"))
      end)
    end

    :telemetry.execute(@tick, %{count: 1}, %{})
    assert {:ok, %{"next_cursor" => 1_001}} = Live.events_since(id, "latest")

    entries = :sys.get_state(:sys.get_state(Manager).active.pid).recorder_handle.entries

    for receipt <- 1..1_000 do
      [{^receipt, _at, _priority, _size, _canonical, classification, _id, _keys}] =
        :ets.lookup(entries, receipt)

      true =
        :ets.update_element(entries, receipt, {6, %{classification | policy_id: "tampered"}})
    end

    assert {:ok, digest} = Live.digest(id)

    # The probe from 0 stops undecided at receipt 1,000, so the start stays
    # at 0 (not exact) and receipt 1,001 is kept.
    assert %{
             "cursor" => 0,
             "events" => 1,
             "first_receipt" => 1_001,
             "start_exact" => false,
             "complete" => true
           } = digest["window"]

    # Every withheld receipt after the start is a loss the digest reports.
    assert [%{"reason" => "redaction_withheld", "count" => 1_000}] = digest["gaps"]
  end

  test "a digest's latest-N lookup is bounded by the digest budget" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    owner = Process.whereis(Insider.Live.Owner)
    :ok = :sys.suspend(owner)
    on_exit(fn -> resume(owner) end)

    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Live.digest(id, %{"since" => "latest-1"}) end)
    assert {:error, %{"code" => "timeout"}} = Task.await(task, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # The lookup gets the digest's budget, plus the call's outer margin, not
    # a call budget of its own before the digest's budget starts.
    assert elapsed < Insider.Live.Options.digest_budget_ms() + 500, "took #{elapsed} ms"
    :ok = :sys.resume(owner)
    assert {:ok, %{"window" => %{"complete" => true}}} = Live.digest(id, %{"since" => "latest-1"})
  end

  defmodule Crasher do
    use GenServer

    def start_link(_argument), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_cast(:crash, _state), do: raise(ArithmeticError)
  end

  test "digest names a real child that keeps crashing, with its exception" do
    assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

    capture_log(fn ->
      supervisor =
        start_supervised!(%{
          id: :insider_live_test_crash_loop,
          start:
            {Supervisor, :start_link,
             [[{Crasher, nil}], [strategy: :one_for_one, max_restarts: 10]]},
          type: :supervisor
        })

      assert is_pid(supervisor)

      for _crash <- 1..2 do
        crashing = Process.whereis(Crasher)
        GenServer.cast(Crasher, :crash)
        assert_eventually(fn -> Process.whereis(Crasher) not in [nil, crashing] end)
      end
    end)

    assert {:ok, digest} = Live.digest(id)

    assert [
             %{
               "offender" => "Insider.LiveTest.Crasher",
               "restarts" => 2,
               "reason_class" => "abnormal"
             } = loop
           ] =
             digest["crash_loops"]

    assert is_integer(loop["period_ms"])
    signatures = Enum.map(digest["error_signatures"], & &1["signature"])
    assert Enum.any?(signatures, &(&1 =~ "ArithmeticError")), inspect(signatures)
  end

  test "the Poller names a backed-up process, watches it, and reports Insider's footprint apart" do
    {:ok, backlog} = GenServer.start(__MODULE__.Backlog, self(), name: __MODULE__.Backlog)
    on_exit(fn -> Process.exit(backlog, :kill) end)
    test = self()
    spawn(fn -> GenServer.call(backlog, {:block, test}, :infinity) end)
    assert_receive {:blocked, ^backlog}
    Enum.each(1..200, &send(backlog, {:queued, &1}))
    name = "Insider.LiveTest.Backlog"

    assert {:ok, %{"session_id" => id} = started} =
             Live.start(%{"components" => ["poller"], "watch_processes" => ["Elixir." <> name]})

    assert started["poller"] == %{
             "interval_ms" => 5_000,
             "top_processes" => 5,
             "top_ets_tables" => 5,
             "top_ports" => 5,
             "watch_processes" => [name]
           }

    assert {:ok, _subscription} = Live.subscribe(id, self())
    events = receive_until(id, "process_watch", [])
    by_kind = Map.new(events, &{&1["kind"], &1})
    assert Enum.all?(events, &is_binary(&1["wall_time"]))

    top = by_kind["process_top"]["attributes"]["metrics"]
    entry = Enum.find(top["by_message_queue_len"], &(&1["name"] == name))
    assert entry["message_queue_len"] == 200
    assert entry["current_function"] == name <> ".handle_call/3"
    assert top["insider"]["process_count"] > 0

    tables = by_kind["ets_top"]["attributes"]["metrics"]
    ranked = Enum.map(tables["by_memory"] ++ tables["by_size"], & &1["table"])
    refute "Insider.Recorder" in ranked

    vm = by_kind["vm_sample"]["attributes"]["metrics"]
    assert vm["insider_ets_bytes"] == tables["insider"]["memory_bytes"]
    assert vm["insider_ets_bytes"] > 0 and vm["insider_ets_bytes"] <= vm["ets_bytes"]

    watch = by_kind["process_watch"]
    assert watch["attributes"]["watch_name"] == name
    assert watch["subject"]["value"] == backlog |> :erlang.pid_to_list() |> to_string()
    assert watch["attributes"]["metrics"]["message_queue_len"] == 200
  end

  test "poller options need the poller component and resolve watched names without creating atoms" do
    unknown = "No.Such.Process#{System.unique_integer([:positive])}"

    for {options, error} <- [
          {%{"components" => ["logger"], "top_processes" => 3},
           %{"code" => "invalid_options", "field" => "top_processes"}},
          {%{"components" => ["poller"], "watch_processes" => [unknown]},
           %{"code" => "unknown_process_name", "name" => unknown}},
          {%{"components" => ["poller"], "watch_processes" => ["not a name"]},
           %{"code" => "invalid_options", "field" => "watch_processes"}},
          {%{"components" => ["poller"], "watch_processes" => ["code_server", "code_server"]},
           %{"code" => "invalid_options", "field" => "watch_processes"}},
          {%{"components" => ["poller"], "watch_processes" => "code_server"},
           %{"code" => "invalid_options", "field" => "watch_processes"}}
        ] do
      assert {:error, ^error} = Live.start(options) |> then(&take_error(&1, error))
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> unknown) end

    assert {:ok, %{"session_id" => id, "poller" => nil}} =
             Live.start(%{"components" => ["logger"]})

    assert {:ok, %{"poller" => nil}} = Live.status(id)
  end

  test "the growing-mailbox recipe runs as written: digest, find the process, then amend to watch it" do
    {:ok, backlog} = GenServer.start(__MODULE__.Backlog, self(), name: __MODULE__.Backlog)
    on_exit(fn -> Process.exit(backlog, :kill) end)
    test = self()
    spawn(fn -> GenServer.call(backlog, {:block, test}, :infinity) end)
    assert_receive {:blocked, ^backlog}
    Enum.each(1..30, &send(backlog, {:queued, &1}))

    recipe =
      Enum.find(Live.welcome()["recipes"], &String.starts_with?(&1["symptom"], "growing mailbox"))

    # Each observer command, run through the same Live operation the
    # observer calls; NAME is what the discovery read showed.
    {id, name} =
      Enum.reduce(recipe["commands"], {nil, nil}, fn command, {id, name} ->
        [_mix, _task, operation, "\"${N[@]}\"" | flags] = String.split(command)
        run_recipe_command(operation, flag_values(flags, name), id, name)
      end)

    assert name == "Insider.LiveTest.Backlog"
    assert {:ok, _subscription} = Live.subscribe(id, self())

    watch =
      id |> receive_until("process_watch", []) |> Enum.find(&(&1["kind"] == "process_watch"))

    assert watch["attributes"]["watch_name"] == name
    assert watch["attributes"]["metrics"]["message_queue_len"] == 30

    # The recipe's last step inspected the process once: its mailbox by
    # shape, never a value, and the same summary recorded in the session.
    # The poller records concurrently, and the Recorder's try-lock drops a
    # concurrent record with `:contended`; that drop must then be reported,
    # never hidden.
    assert_receive {:inspected, %{"mailbox" => mailbox, "session" => session}}
    assert session["session_id"] == id

    unless session["recorded"] do
      assert session["reason"] == "contended"
      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 1})
      assert Enum.any?(batch["gaps"], &(&1["reason"] == "contended"))
    end

    assert mailbox["length"] == 30
    assert [%{"shape" => "{:queued, integer}", "count" => 30}] = mailbox["shapes"]
  end

  defp run_recipe_command("start", flags, _id, name) do
    options =
      %{"components" => flags["--component"]}
      |> put_flag("watch_processes", flags["--watch-process"])
      |> put_flag("poller_interval_ms", flags["--poller-interval-ms"], &String.to_integer/1)

    assert {:ok, %{"session_id" => id}} = Live.start(options)
    {id, name}
  end

  defp run_recipe_command("digest", _flags, id, name) do
    assert {:ok, %{"schema" => "insider.live-digest/v1"}} = Live.digest(id)
    {id, name}
  end

  defp run_recipe_command("events", _flags, id, nil) do
    assert {:ok, _subscription} = Live.subscribe(id, self())
    events = receive_until(id, "process_top", [])
    assert {:ok, _unsubscribed} = Live.unsubscribe(id, self())
    top = Enum.find(events, &(&1["kind"] == "process_top"))
    [entry | _rest] = top["attributes"]["metrics"]["by_message_queue_len"]
    {id, entry["name"]}
  end

  defp run_recipe_command("events", _flags, id, name), do: {id, name}

  defp run_recipe_command("amend", flags, id, name) do
    options =
      %{}
      |> put_flag("watch_processes", flags["--watch-process"])
      |> put_flag("poller_interval_ms", flags["--poller-interval-ms"], &String.to_integer/1)

    assert {:ok, %{"session_id" => ^id, "amendment" => %{"applied" => true}}} =
             Live.amend(id, options)

    {id, name}
  end

  defp run_recipe_command("process", flags, id, name) do
    assert {:ok, result} = Live.process(%{"name" => hd(flags["--name"])})
    send(self(), {:inspected, result})
    {id, name}
  end

  defp flag_values(flags, name) do
    flags
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn [flag, value], values ->
      value = if value == "NAME", do: name, else: value
      Map.update(values, flag, [value], &(&1 ++ [value]))
    end)
  end

  defp put_flag(options, key, values, convert \\ & &1)
  defp put_flag(options, _key, nil, _convert), do: options

  defp put_flag(options, "watch_processes", values, _convert),
    do: Map.put(options, "watch_processes", values)

  defp put_flag(options, key, [value], convert), do: Map.put(options, key, convert.(value))

  defp take_error({:error, error}, expected), do: {:error, Map.take(error, Map.keys(expected))}
  defp take_error(other, _expected), do: other

  # Collects pushed poller events until one of `kind` arrives.
  defp receive_until(id, kind, events) do
    assert_receive {:insider_live_events, ^id, batch}, 10_000
    events = events ++ Enum.map(batch["events"], & &1["event"])

    if Enum.any?(events, &(&1["kind"] == kind)),
      do: events,
      else: receive_until(id, kind, events)
  end

  defp await_queue_length(pid, length),
    do:
      assert_eventually(fn ->
        Process.info(pid, :message_queue_len) == {:message_queue_len, length}
      end)

  # Supervision and timer transitions are asynchronous to their observer.
  # Wait only for an explicit state predicate, under a short bound; this does
  # not retry a failed operation.
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

  defp await_queued(pid),
    do:
      assert_eventually(fn ->
        match?(
          {:message_queue_len, length} when length >= 1,
          Process.info(pid, :message_queue_len)
        )
      end)

  # Waits through the Manager's public health API until the collector session
  # is retained as terminal, then returns its (idempotent) stop receipt.
  defp await_collector_receipt(handle) do
    assert_eventually(
      fn -> match?({:ok, %{"terminal" => true}}, Insider.Collector.Session.health(handle)) end,
      250
    )

    assert {:ok, receipt} = Insider.Collector.Session.stop(handle)
    receipt
  end

  # Stops a collector session directly. Stop can return while its cleanup is
  # still being verified; then the receipt arrives once the Manager retains it.
  defp stop_collector(handle) do
    case Insider.Collector.Session.stop(handle) do
      {:ok, receipt} -> receipt
      {:error, :cleanup_in_progress} -> await_collector_receipt(handle)
    end
  end

  # A live stop whose collector cleanup was still in progress records
  # `receipt_pending`; status completes it once the Manager has the receipt.
  defp await_receipt_settled(id) do
    assert_eventually(
      fn -> match?({:ok, %{"receipt_pending" => false}}, Live.status(id)) end,
      250
    )

    {:ok, status} = Live.status(id)
    status
  end

  # The supervisor lists the restarted child only after its init returned,
  # so the new owner is ready for calls.
  defp await_owner_restart(old) do
    assert_eventually(fn -> is_pid(restarted_owner(old)) end, 250)
    restarted_owner(old)
  end

  defp restarted_owner(old) do
    Enum.find_value(Supervisor.which_children(Insider.Supervisor), fn
      {Insider.Live.Owner, pid, _type, _modules} when is_pid(pid) and pid != old -> pid
      _child -> nil
    end)
  end

  defp canonical!(json) do
    decoded = Jason.decode!(json)
    assert Canonical.encode(decoded) == json
    assert map_size(decoded) == 1
    decoded
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp measurement(entry, name), do: entry["event"]["attributes"]["measurements"][name]

  defp gap(reason, count, scope), do: %{"reason" => reason, "count" => count, "scope" => scope}

  defp telemetry_collector do
    session = :sys.get_state(Manager).active.pid
    :sys.get_state(session).components.telemetry
  end

  describe "ingest_spans/2" do
    defp ingested_span(overrides \\ %{}) do
      Map.merge(
        %{
          "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736",
          "span_id" => "00f067aa0ba902b7",
          "parent_span_id" => nil,
          "name" => "GET /listings/[id]",
          "span_kind" => "server",
          "status" => "error",
          "status_message" => nil,
          "service" => "example-marketplace",
          "scope" => "next.js",
          "start_time_us" => 1_792_685_131_645_000,
          "duration_us" => 1_200,
          "attributes" => %{"authorization" => "Bearer s3cr3t-token-value"},
          "pid" => nil
        },
        overrides
      )
    end

    # The otel component runs only on OTP 28+ (isolated trace sessions); the
    # other cases below do not need it.
    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "records spans in a running otel session under its masking, with counts" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})

      assert {:ok, result} =
               Live.ingest_spans(id, [ingested_span(), ingested_span(%{"trace_id" => "bad"})])

      assert plain?(result)

      assert %{
               "schema" => "insider.live-ingest/v1",
               "session_id" => ^id,
               "accepted" => 1,
               "rejected" => 1,
               "shed" => 0
             } = result

      assert {:ok, %{"events" => [%{"event" => event}]}} = Live.events_since(id, 0)
      assert %{"source" => "otel", "kind" => "otel.span", "severity" => "error"} = event
      assert event["attributes"]["service"] == "example-marketplace"
      assert event["attributes"]["capture"] == "ingest"
      refute Jason.encode!(event) =~ "s3cr3t"

      assert Live.JSON.ingest_spans(id, []) =~ ~s("accepted":0)
    end

    # Dedupe is per otel collector, and an
    # amendment replaces the collector, so it resets dedupe without counting
    # the forgotten ids as `seen_evicted`. This pins the documented boundary.
    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "an amendment resets ingest dedupe, and seen_evicted does not count the reset" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})

      assert {:ok, %{"accepted" => 1, "duplicate" => 0}} =
               Live.ingest_spans(id, [ingested_span()])

      assert {:ok, %{"accepted" => 0, "duplicate" => 1}} =
               Live.ingest_spans(id, [ingested_span()])

      assert {:ok, %{"amendment" => %{"applied" => true}}} =
               Live.amend(id, %{"max_events" => 4_096})

      assert {:ok, %{"accepted" => 1, "duplicate" => 0}} =
               Live.ingest_spans(id, [ingested_span()])

      assert {:ok, %{"events" => events}} = Live.events_since(id, 0)
      assert Enum.count(events, &(&1["event"]["kind"] == "otel.span")) == 2

      assert {:ok, %{seen_evicted: 0}} =
               Insider.Collector.Otel.status(Process.whereis(Insider.Collector.Otel))
    end

    # With the collector held, the caller got `timeout` and the
    # span appeared once the collector caught up. A call the collector
    # takes after its deadline records nothing.
    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "an ingest that times out records nothing, even after the collector catches up" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["otel"]})
      collector = Process.whereis(Insider.Collector.Otel)
      {:ok, before} = Insider.Collector.Otel.status(collector)
      :ok = :sys.suspend(collector)

      assert {:error, %{"code" => "timeout"}} = Live.ingest_spans(id, [ingested_span()])

      :ok = :sys.resume(collector)
      # Status is handled after the held ingest call, which it follows in
      # the collector's mailbox.
      assert {:ok, ^before} = Insider.Collector.Otel.status(collector)
      assert {:ok, %{"events" => events}} = Live.events_since(id, 0)
      refute Enum.any?(events, &(&1["event"]["kind"] == "otel.span"))

      assert {:ok, %{"accepted" => 1}} = Live.ingest_spans(id, [ingested_span()])
    end

    # Ingest checked the session's status, then recorded through
    # the globally registered collector, so a stop and a start in between
    # put the span into the next session. Ingest now runs in the owner,
    # ordered with start and stop: queued before them, it lands in its own
    # session, never in the next one.
    @tag skip: :erlang.system_info(:otp_release) < ~c"28" && "the otel component requires OTP 28"
    test "a span queued before a stop and a start never lands in the next session" do
      {:ok, %{"session_id" => old}} = Live.start(%{"components" => ["otel"]})
      owner = Process.whereis(Insider.Live.Owner)
      :ok = :sys.suspend(owner)

      ingest = Task.async(fn -> Live.ingest_spans(old, [ingested_span()]) end)
      await_queue_length(owner, 1)
      stop = Task.async(fn -> Live.stop(old) end)
      await_queue_length(owner, 2)
      start = Task.async(fn -> Live.start(%{"components" => ["otel"]}) end)
      await_queue_length(owner, 3)
      :ok = :sys.resume(owner)

      assert {:ok, %{"session_id" => ^old, "accepted" => 1}} = Task.await(ingest)
      assert {:ok, %{"state" => "stopped"}} = Task.await(stop)

      case Task.await(start) do
        {:ok, %{"session_id" => new}} ->
          assert {:ok, %{"events" => events}} = Live.events_since(new, 0)
          refute Enum.any?(events, &(&1["event"]["kind"] == "otel.span"))

        {:error, _cleanup_in_progress} ->
          :ok
      end

      assert {:error, %{"code" => "session_terminal"}} =
               Live.ingest_spans(old, [ingested_span()])
    end

    test "an ended session is session_terminal with its status" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      {:ok, _stopped} = Live.stop(id)

      assert {:error, %{"code" => "session_terminal", "status" => %{"state" => "stopped"}}} =
               Live.ingest_spans(id, [ingested_span()])
    end

    test "a session without the otel component is component_unavailable" do
      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

      assert {:error,
              %{
                "code" => "component_unavailable",
                "component" => "otel",
                "reason" => "component_not_running"
              }} = Live.ingest_spans(id, [ingested_span()])
    end

    test "refuses an unknown session, more spans than one call takes, and a non-list" do
      assert {:error, %{"code" => "unknown_session"}} = Live.ingest_spans("live-0", [])
      assert Live.JSON.ingest_spans("live-0", []) =~ ~s("code":"unknown_session")
      assert Live.JSON.trace("live-0", String.duplicate("a", 32)) =~ ~s("error")
      assert Live.JSON.timeline("live-0", %{"pid" => "<0.1.0>"}) =~ ~s("error")

      {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      too_many = List.duplicate(ingested_span(), Insider.Collector.Otel.ingest_max() + 1)

      assert {:error, %{"code" => "invalid_options", "field" => "spans"}} =
               Live.ingest_spans(id, too_many)

      assert {:error, %{"code" => "invalid_options", "field" => "spans"}} =
               Live.ingest_spans(id, :spans)
    end

    test "is refused outside development, test, and ci" do
      Application.put_env(:insider, :environment, :prod)
      assert {:error, %{"code" => "environment_denied"}} = Live.ingest_spans("live-1", [])
    end
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, message})
        relay(parent)
    end
  end

  # Distribution-safe plain data: no structs, pids, references, ports, funs,
  # tuples, atoms other than booleans and nil, or non-string map keys.
  defp plain?({:ok, value}), do: plain?(value)
  defp plain?({:error, value}), do: plain?(value)

  defp plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and plain?(item) end)

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  defp plain?(value),
    do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)
end
