defmodule Insider.Live.FiltersTest do
  # One collector session is global per node, and the quiet-default tests
  # change the `:insider` application environment, so this module cannot run
  # in parallel with other session users.
  use ExUnit.Case, async: false

  # One capture for the whole test: each `capture_log/1` call starts a
  # capture child, and its debug progress report would count as filtered.
  @moduletag :capture_log

  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Session.Manager
  alias Insider.Collector.Telemetry, as: TelemetryCollector
  alias Insider.Event.Canonical
  alias Insider.Live
  alias Insider.Live.Filters

  @tick [:insider_live_filters, :tick]
  @query [:insider_quiet, :repo, :query]
  @default_prefix_query [:insider_quiet_default, :repo, :query]
  @tick_kind "insider_live_filters.tick"
  @query_kind "insider_quiet.repo.query"
  @all %{"limit" => 500, "max_bytes" => 1_048_576}
  # The quiet defaults other than repository query events, in their order.
  @known_defaults [
    "phoenix.endpoint.stop",
    "phoenix.router_dispatch.exception",
    "oban.job.exception",
    "absinthe.execute.operation.stop",
    "bandit.request.stop",
    "cowboy.request.stop"
  ]
  @no_defaults_hint "no default Telemetry events exist on this node; pass --telemetry-event or use discover"

  defmodule Noisy do
    # A process whose initial call is this module, for origin rules.
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def run(pid, fun), do: GenServer.call(pid, {:run, fun})

    @impl GenServer
    def init(:ok), do: {:ok, nil}

    @impl GenServer
    def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
  end

  setup do
    on_exit(fn ->
      for key <- [
            :ecto_repos,
            :live_disclosure,
            :live_telemetry_measurements,
            __MODULE__.QuietRepo,
            InsiderQuietDefault.Repo
          ],
          do: Application.delete_env(:insider, key)

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

  describe "quiet defaults" do
    test "a session without explicit events records warnings, OTP reports, slow and failed queries" do
      configure_repos()

      assert {:ok, started} = Live.start(%{})
      id = started["session_id"]
      # Starting the collector itself logs debug-level progress reports.
      cursor = settled(id)
      assert started["components"] == ["logger", "telemetry"]
      assert ["insider_quiet", "repo", "query"] in started["telemetry_events"]
      assert ["insider_quiet_default", "repo", "query"] in started["telemetry_events"]

      assert %{
               "logger_level" => "warning",
               "exclude_origins" => ["oban"],
               "telemetry_min_duration_ms" => 100,
               "telemetry_event_min_duration_ms" => %{@query_kind => 100}
             } = started["filters"]

      :logger.debug("every query line")
      :logger.info("every request line")
      :logger.warning("worth seeing")

      :logger.info(
        %{label: {:supervisor, :progress}, report: [supervisor: {:local, :quiet_sup}]},
        %{domain: [:otp, :sasl]}
      )

      query(5, {:ok, %{}})
      query(150, {:ok, %{}})
      query(2, {:error, :deadlock})
      :telemetry.execute(@default_prefix_query, %{total_time: native(1)}, %{})

      assert {:ok, batch} = Live.events_since(id, cursor, @all)

      # The slow query is info; the failed one is an error. The Logger and
      # Telemetry collectors drain on their own timers, so only each source's
      # own order is fixed.
      assert Enum.group_by(batch["events"], & &1["event"]["source"], & &1["event"]["severity"]) ==
               %{"logger" => ["warning", "info"], "telemetry" => ["info", "error"]}

      assert %{
               "scope" => "since_cursor_issued",
               "logger" => %{"level" => 2, "include" => 0, "exclude" => 0, "origin" => 0},
               "telemetry" => %{
                 @query_kind => %{"min_duration" => 1, "origin" => 0, "summarized" => 0},
                 "insider_quiet_default.repo.query" => %{"min_duration" => 1}
               },
               "view" => %{}
             } = batch["filtered"]

      # The idle read reports nothing new since its cursor.
      assert {:ok, idle} = Live.events_since(id, batch["next_cursor"], @all)
      assert idle["events"] == []
      assert idle["filtered"]["scope"] == "since_cursor_issued"
      assert idle["filtered"]["logger"]["level"] == 0
      assert idle["filtered"]["telemetry"][@query_kind]["min_duration"] == 0
    end

    test "a node without default events keeps the Logger-only default" do
      assert {:ok, %{"components" => ["logger"], "telemetry_events" => []}} = Live.start(%{})
    end

    test "explicit telemetry without events records the defaults that exist and reports the rest" do
      # This test node runs none of the applications behind the known
      # defaults (Phoenix, Oban, Absinthe, Bandit, Cowboy), and has no
      # repository: the telemetry component has nothing to record, so the
      # session runs Logger alone and says why.
      assert {:ok, %{"session_id" => id} = started} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_measurements" => ["duration"]
               })

      assert started["components"] == ["logger"]
      assert started["telemetry_events"] == []
      assert started["telemetry_measurements"] == []
      assert Enum.map(started["telemetry_skipped_defaults"], & &1["event"]) == @known_defaults
      assert Enum.all?(started["telemetry_skipped_defaults"], &(&1["reason"] == "not_on_target"))
      assert started["telemetry_hint"] == @no_defaults_hint

      assert {:ok, _stopped} = Live.stop(id)
      await_slot_free()

      # Telemetry alone would record nothing at all.
      assert {:error,
              %{
                "code" => "invalid_options",
                "field" => "telemetry_events",
                "telemetry_skipped_defaults" => [_ | _],
                "hint" => @no_defaults_hint
              }} = Live.start(%{"components" => ["telemetry"]})

      configure_repos()

      assert {:ok, %{"telemetry_events" => events} = started} =
               Live.start(%{"components" => ["telemetry"]})

      assert started["components"] == ["telemetry"]
      assert ["insider_quiet", "repo", "query"] in events
      assert Enum.map(started["telemetry_skipped_defaults"], & &1["event"]) == @known_defaults
      refute Map.has_key?(started, "telemetry_hint")
    end

    test "explicit event names skip nothing and an unknown one is still refused" do
      assert {:error, %{"code" => "unknown_telemetry_event", "event" => event}} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_events" => [["insider_live_never_an_atom_q9z", "stop"]]
               })

      assert event == ["insider_live_never_an_atom_q9z", "stop"]

      assert {:ok, started} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick)]
               })

      assert started["telemetry_skipped_defaults"] == []
      refute Map.has_key?(started, "telemetry_hint")
    end

    test "an amendment back to the defaults reports the skipped ones too" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_events" => [segments(@tick)]
               })

      assert {:ok, amended} = Live.amend(id, %{"telemetry_events" => nil})
      assert amended["components"] == ["logger"]
      assert amended["telemetry_events"] == []
      assert Enum.map(amended["telemetry_skipped_defaults"], & &1["event"]) == @known_defaults
      assert amended["telemetry_hint"] == @no_defaults_hint
      assert "components" in amended["amendment"]["changed"]

      # Naming an event again brings the telemetry component back.
      assert {:ok, again} = Live.amend(id, %{"telemetry_events" => [segments(@tick)]})
      assert again["components"] == ["logger", "telemetry"]
      assert again["telemetry_skipped_defaults"] == []
      refute Map.has_key?(again, "telemetry_hint")
    end
  end

  describe "record-time Logger filters" do
    test "level, include, exclude, and origin each drop and count their own events" do
      {:ok, noisy} = Noisy.start_link()

      assert {:ok, %{"session_id" => id, "filters" => filters}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_level" => "info",
                 "logger_include" => [
                   %{"domain" => ["insider_filters"]},
                   %{"application" => "insider_filters_app"},
                   %{"module" => "Insider.Live.FiltersTest.Noisy"}
                 ],
                 "logger_exclude" => [%{"domain" => ["insider_filters", "chatty"]}],
                 "exclude_origins" => [%{"module" => "Insider.Live.FiltersTest.Noisy"}]
               })

      cursor = settled(id)
      assert filters["logger_include"] |> length() == 3
      assert filters["exclude_origins"] == [%{"module" => "Insider.Live.FiltersTest.Noisy"}]

      :logger.debug("below the floor", %{domain: [:insider_filters]})
      :logger.info("kept by domain", %{domain: [:insider_filters]})
      :logger.info("kept by application", %{application: :insider_filters_app})
      :logger.info("kept by module", %{mfa: {Noisy, :run, 2}})
      :logger.info("not included")
      :logger.info("excluded", %{domain: [:insider_filters, :chatty, :more]})
      Noisy.run(noisy, fn -> :logger.info("own origin", %{domain: [:insider_filters]}) end)

      assert {:ok, batch} = Live.events_since(id, cursor, @all)
      assert [_, _, _] = batch["events"]

      assert batch["filtered"]["logger"] == %{
               "level" => 1,
               "include" => 1,
               "exclude" => 1,
               "origin" => 1,
               "summarized" => 0
             }
    end

    test "unknown or malformed rules are refused before collection starts" do
      for {options, field} <- [
            {%{"logger_level" => "loud"}, "logger_level"},
            {%{"logger_include" => [%{"domain" => ["no_such_atom_insider_xyz"]}]},
             "logger_include"},
            {%{"logger_exclude" => [%{"module" => "No.Such.Module.InsiderXyz"}]},
             "logger_exclude"},
            {%{"logger_exclude" => [%{"domain" => ["a"], "module" => "Enum"}]}, "logger_exclude"},
            {%{"logger_include" => "elixir"}, "logger_include"},
            {%{"exclude_origins" => ["oban", "oban"]}, "exclude_origins"},
            {%{"exclude_origins" => [%{"domain" => ["elixir"]}]}, "exclude_origins"},
            {%{"exclude_origins" => "oban"}, "exclude_origins"},
            {%{"telemetry_min_duration_ms" => -1}, "telemetry_min_duration_ms"},
            {%{"telemetry_summary_interval_ms" => 10}, "telemetry_summary_interval_ms"},
            {%{"telemetry_summaries" => ["not.recorded"]}, "telemetry_summaries"},
            {%{"telemetry_event_min_duration_ms" => %{"not.recorded" => 1}},
             "telemetry_event_min_duration_ms"},
            {%{"telemetry_event_min_duration_ms" => [1]}, "telemetry_event_min_duration_ms"},
            {%{"logger_summaries" => [%{"module" => "No.Such.Module.InsiderXyz"}]},
             "logger_summaries"},
            {%{"logger_summaries" => "elixir"}, "logger_summaries"},
            {%{"logger_summary_interval_ms" => 999}, "logger_summary_interval_ms"},
            {%{"telemetry_duration_scopes" => %{"not.summarised" => "handler"}},
             "telemetry_duration_scopes"}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => ^field}} =
                 Live.start(Map.put(options, "components", ["logger"]))
      end

      # Logger bursts need the Logger component.
      assert {:error, %{"code" => "invalid_options", "field" => "logger_summaries"}} =
               Live.start(%{
                 "components" => ["poller"],
                 "logger_summaries" => [%{"domain" => ["elixir"]}]
               })

      assert :sys.get_state(Manager).active == nil
    end

    test "dropped Logger events never reach the handler's own work" do
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      collector = component(:logger)
      cursor = settled(id)
      {:ok, before} = LoggerCollector.status(collector)

      for n <- 1..500, do: :logger.debug("noise #{n}")

      # The handler's own counters do not move for a dropped event.
      assert {:ok, after_noise} = LoggerCollector.status(collector)

      assert Map.take(after_noise, [:received, :enqueued, :metadata_suppressed]) ==
               Map.take(before, [:received, :enqueued, :metadata_suppressed])

      assert {:ok, %{"filtered" => %{"logger" => %{"level" => 500}}}} =
               Live.events_since(id, cursor)

      :logger.error("signal")
      assert {:ok, %{received: received}} = LoggerCollector.status(collector)
      assert received == before.received + 1
    end
  end

  describe "record-time Telemetry filters" do
    test "per-event minimum durations drop fast events, never errors, and count them per event" do
      assert {:ok, %{"session_id" => id, "filters" => filters}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick), segments(@query)],
                 "telemetry_min_duration_ms" => 50,
                 "telemetry_event_min_duration_ms" => %{@tick_kind => 10}
               })

      assert filters["telemetry_event_min_duration_ms"] == %{@tick_kind => 10, @query_kind => 50}

      :telemetry.execute(@tick, %{duration: native(9)}, %{})
      :telemetry.execute(@tick, %{duration: native(11)}, %{})
      :telemetry.execute(@tick, %{duration: native(1)}, %{kind: :error, reason: :boom})
      :telemetry.execute(@tick, %{count: 1}, %{})
      :telemetry.execute(@tick, %{duration: native(1)}, %{conn: %{status: 503}})
      :telemetry.execute(@tick, %{duration: native(1)}, %{conn: %{status: 200}})
      query(20, {:ok, %{}})
      query(60, {:ok, %{}})

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert [_, _, _, _, _] = batch["events"]

      assert batch["filtered"]["telemetry"] == %{
               @tick_kind => %{"min_duration" => 2, "origin" => 0, "summarized" => 0},
               @query_kind => %{"min_duration" => 1, "origin" => 0, "summarized" => 0}
             }

      assert batch["filtered"]["logger"] == %{}
    end

    test "Oban's own repository queries are excluded by origin, application queries are not" do
      assert {:ok, %{"session_id" => id, "filters" => %{"exclude_origins" => ["oban"]}}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@query)],
                 "telemetry_min_duration_ms" => 0
               })

      # The shape Ecto SQL emits for a query made through `Oban.Repo`, which
      # passes `telemetry_options: [oban_conf: conf]` (deps/oban
      # lib/oban/repo.ex, deps/ecto_sql lib/ecto/adapters/sql.ex).
      oban_conf = %{
        __struct__: Oban.Config,
        name: Oban,
        prefix: "public",
        node: "dev@host",
        log: false,
        testing: :disabled
      }

      for _poll <- 1..3 do
        :telemetry.execute(
          @query,
          %{query_time: native(1), decode_time: 0, queue_time: 0, total_time: native(1)},
          %{
            type: :ecto_sql_query,
            repo: __MODULE__.QuietRepo,
            result: {:ok, %{num_rows: 0}},
            params: ["available", "default"],
            cast_params: nil,
            query: ~s|SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE o0."state" = $1|,
            source: "oban_jobs",
            stacktrace: nil,
            options: [oban_conf: oban_conf]
          }
        )
      end

      query(1, {:ok, %{}})

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert [_recorded] = batch["events"]
      assert batch["filtered"]["telemetry"][@query_kind]["origin"] == 3
      refute Jason.encode!(batch) =~ "oban"

      # The same polling is recorded when the caller asks for every origin.
      assert {:ok, _stopped} = Live.stop(id)
      await_slot_free()

      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@query)],
                 "telemetry_min_duration_ms" => 0,
                 "exclude_origins" => []
               })

      :telemetry.execute(@query, %{total_time: native(1)}, %{options: [oban_conf: oban_conf]})
      assert {:ok, %{"events" => [_polled]}} = Live.events_since(id, 0, @all)
    end

    test "a module origin rule excludes Telemetry events emitted by that module's processes" do
      {:ok, noisy} = Noisy.start_link()

      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick)],
                 "exclude_origins" => [%{"module" => "Insider.Live.FiltersTest"}]
               })

      Noisy.run(noisy, fn -> :telemetry.execute(@tick, %{count: 1}, %{}) end)
      :telemetry.execute(@tick, %{count: 2}, %{})

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert [_recorded] = batch["events"]
      assert batch["filtered"]["telemetry"][@tick_kind]["origin"] == 1
    end

    test "the oban origin covers Oban's companion applications' processes" do
      # An application spec loaded under oban_met's name, owning Noisy, as
      # Oban.Met.Reporter belongs to oban_met on a real node.
      :ok =
        :application.load(
          {:application, :oban_met,
           [
             description: ~c"test",
             vsn: ~c"0.0.0",
             modules: [Noisy],
             registered: [],
             applications: []
           ]}
        )

      on_exit(fn -> :application.unload(:oban_met) end)
      {:ok, noisy} = Noisy.start_link()

      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick)]
               })

      Noisy.run(noisy, fn -> :telemetry.execute(@tick, %{count: 1}, %{}) end)
      :telemetry.execute(@tick, %{count: 2}, %{})

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert [_recorded] = batch["events"]
      assert batch["filtered"]["telemetry"][@tick_kind]["origin"] == 1
    end

    test "dropped Telemetry events never reach the handler's own work" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick)]
               })

      collector = component(:telemetry)
      for _n <- 1..500, do: :telemetry.execute(@tick, %{duration: native(1)}, %{})

      assert {:ok, %{received: 0, enqueued: 0, measurements_suppressed: 0}} =
               TelemetryCollector.status(collector)

      assert {:ok, batch} = Live.events_since(id, 0)
      assert batch["filtered"]["telemetry"][@tick_kind]["min_duration"] == 500

      :telemetry.execute(@tick, %{duration: native(500)}, %{})
      assert {:ok, %{received: 1}} = TelemetryCollector.status(collector)
    end
  end

  describe "summaries" do
    test "a summarised event is recorded once per interval with count, errors, and percentiles" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@query)],
                 "telemetry_summaries" => [@query_kind],
                 "telemetry_summary_interval_ms" => 1_000
               })

      assert {:ok, _subscription} = Live.subscribe(id, self())
      collector = component(:telemetry)

      # The collector records summaries; suspending it puts every sample in
      # the same interval. Emitters never wait for it.
      :ok = :sys.suspend(collector)

      for ms <- 1..100 do
        result = if rem(ms, 40) == 0, do: {:error, :timeout}, else: {:ok, %{}}
        query(ms, result)
      end

      :telemetry.execute(@query, %{query_time: 7}, %{})
      :ok = :sys.resume(collector)

      summary = await_event(id, &(&1["event"]["attributes"]["lifecycle_phase"] == "summary"))
      assert summary["event"]["kind"] == @query_kind
      assert summary["event"]["severity"] == "warning"

      assert %{
               "count" => 101,
               "errors" => 2,
               "timed" => 100,
               "duration_p50_us" => 51_199,
               "duration_p95_us" => 98_303,
               "duration_max_us" => 100_000
             } = summary["event"]["attributes"]["summary"]

      attributes = summary["event"]["attributes"]["summary"]
      assert attributes["interval_ms"] >= 1_000
      {:ok, started, 0} = DateTime.from_iso8601(attributes["window_started_at"])
      {:ok, ended, 0} = DateTime.from_iso8601(attributes["window_ended_at"])
      assert DateTime.diff(ended, started, :millisecond) >= 1_000

      # Nothing declared what the query durations measure; the test process
      # that emitted them is only their observed context.
      assert attributes["duration_scope"] == %{
               "measured_in" => "unknown",
               "declared" => false,
               "emitter" => %{"context" => "process", "module" => nil}
             }

      assert attributes["exemplars_lost"] == 0
      assert attributes["first_error_retained"] == true

      # The exemplars: the first error and the three slowest, to within one
      # histogram bucket of the maximum, recorded before the summary.
      exemplars = attributes["exemplars"]

      assert [%{"duration_us" => 40_000, "error" => true}] =
               Enum.filter(exemplars, &("first_error" in &1["roles"]))

      slowest = Enum.filter(exemplars, &("slowest" in &1["roles"]))
      assert [_, _, _] = slowest
      assert Enum.all?(slowest, &(&1["duration_us"] >= 100_000 * 15 / 16))

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert length(batch["events"]) == length(exemplars) + 1
      assert batch["filtered"]["telemetry"][@query_kind]["summarized"] == 101

      # Each exemplar receipt opens its event: a read from the receipt before.
      for exemplar <- exemplars do
        receipt = exemplar["receipt"]
        assert receipt < summary["receipt"]

        assert {:ok, %{"events" => [opened]}} =
                 Live.events_since(id, receipt - 1, %{"limit" => 1})

        assert opened["receipt"] == receipt
        assert opened["event"]["kind"] == @query_kind
        assert opened["event"]["attributes"]["exemplar_of"]["kind"] == @query_kind

        assert opened["event"]["attributes"]["durations_us"]["total_time"] ==
                 exemplar["duration_us"]
      end
    end

    test "stopping a session records its pending summary in the terminal batch" do
      id = summarized_session(%{"telemetry_summary_interval_ms" => 10_000})
      assert {:ok, _subscription} = Live.subscribe(id, self())
      query(5, {:error, :deadlock})

      assert {:ok, %{"state" => "stopped"}} = Live.stop(id)
      {final, summaries} = await_terminal(id)
      assert final["state"] == "stopped"

      assert [%{"count" => 1, "errors" => 1, "timed" => 1, "duration_max_us" => 5_000}] =
               summaries
    end

    test "an expiring lease records the pending summary before the terminal read" do
      id = summarized_session(%{"telemetry_summary_interval_ms" => 10_000, "lease_ms" => 1_000})
      assert {:ok, _subscription} = Live.subscribe(id, self())
      query(9, {:ok, %{}})

      {final, summaries} = await_terminal(id)
      assert final["state"] == "expired"
      assert [%{"count" => 1, "errors" => 0, "duration_max_us" => 9_000}] = summaries
    end

    test "stopping after an earlier summary records only the partial interval" do
      id = summarized_session(%{"telemetry_summary_interval_ms" => 1_000})
      assert {:ok, _subscription} = Live.subscribe(id, self())
      query(3, {:ok, %{}})

      first = await_event(id, &summary?/1)
      assert first["event"]["attributes"]["summary"]["count"] == 1

      query(7, {:ok, %{}})
      query(7, {:error, :timeout})
      assert {:ok, _stopped} = Live.stop(id)
      {_final, summaries} = await_terminal(id)

      assert [%{"count" => 2, "errors" => 1, "duration_max_us" => 7_000}] = summaries
    end

    test "a rich summary is withheld when exported under strict with an empty allowlist" do
      Application.put_env(:insider, :live_telemetry_measurements, [])
      durations = ["duration_max_us", "duration_p50_us", "duration_p95_us"]
      id = summarized_session(%{"telemetry_summary_interval_ms" => 10_000})
      assert {:ok, %{"disclosure_profile" => "rich"}} = Live.status(id)
      assert {:ok, _subscription} = Live.subscribe(id, self())
      query(123, {:ok, %{}})

      Application.put_env(:insider, :live_disclosure, :strict)
      assert {:ok, _stopped} = Live.stop(id)
      {final, [summary]} = await_terminal(id)
      assert Map.take(summary, durations) == Map.new(durations, &{&1, nil})

      withheld =
        for record <- Enum.flat_map(final["events"], & &1["redactions"]),
            ["key:attributes", "key:summary", "key:" <> name] <- [record["path"]],
            do: name

      assert Enum.sort(withheld) == durations
    end

    test "strict: summary durations are disclosed only for allowlisted measurements" do
      # The measurement allowlist is the strict profile's rule; the rich
      # profile discloses every measurement.
      Application.put_env(:insider, :live_disclosure, :strict)
      durations = ["duration_max_us", "duration_p50_us", "duration_p95_us"]

      for {at_record, at_export, disclosed?} <- [
            {[:total_time], [:total_time], true},
            {[], [], false},
            {[:count, :duration], [:count, :duration], false},
            {[:total_time], [], false}
          ] do
        Application.put_env(:insider, :live_telemetry_measurements, at_record)
        id = summarized_session(%{"telemetry_summary_interval_ms" => 10_000})
        assert {:ok, _subscription} = Live.subscribe(id, self())
        query(123, {:ok, %{}})

        Application.put_env(:insider, :live_telemetry_measurements, at_export)
        assert {:ok, _stopped} = Live.stop(id)
        {final, [summary]} = await_terminal(id)
        assert summary["count"] == 1
        assert summary["duration_measurements"] == ["total_time"]

        withheld =
          for record <- Enum.flat_map(final["events"], & &1["redactions"]),
              ["key:attributes", "key:summary", "key:" <> name] <- [record["path"]],
              do: name

        if disclosed? do
          assert summary["duration_max_us"] == 123_000
          assert withheld == []
        else
          assert Map.take(summary, durations) == Map.new(durations, &{&1, nil})
          assert Enum.sort(withheld) == durations
        end

        await_slot_free()
      end
    end
  end

  describe "read-time views" do
    test "two readers see different views of one session and neither hides events from the other" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_events" => [segments(@tick)],
                 "logger_level" => "info",
                 "logger_include" => [%{"domain" => ["insider_filters"]}]
               })

      :logger.info("routine", %{domain: [:insider_filters]})
      :logger.error("failure", %{domain: [:insider_filters]})

      :telemetry.execute(@tick, %{count: 1}, %{})

      # Subscriptions start at cursor 0, so both see all three events.
      parent = self()
      watcher = spawn_link(fn -> relay(parent) end)
      view = %{"sources" => ["telemetry"]}
      assert {:ok, %{"view" => ^view}} = Live.subscribe(id, watcher, %{"view" => view})
      assert {:ok, %{"view" => nil}} = Live.subscribe(id, self())

      errors = %{"view" => %{"min_severity" => "error"}}
      ticks = %{"view" => %{"kinds" => ["insider_live_filters.*"], "sources" => ["telemetry"]}}

      assert {:ok, alerts} = Live.events_since(id, 0, Map.merge(@all, errors))
      assert {:ok, telemetry} = Live.events_since(id, 0, Map.merge(@all, ticks))
      assert {:ok, everything} = Live.events_since(id, 0, @all)

      assert Enum.map(alerts["events"], & &1["event"]["severity"]) == ["error"]
      assert alerts["filtered"]["view"] == %{"min_severity" => 2}
      assert Enum.map(telemetry["events"], & &1["event"]["kind"]) == [@tick_kind]
      assert telemetry["filtered"]["view"] == %{"sources" => 2, "kinds" => 0}
      assert [_, _, _] = everything["events"]
      assert everything["filtered"]["view"] == %{}
      assert alerts["next_cursor"] == everything["next_cursor"]

      assert_receive {:relayed, {:insider_live_events, ^id, watched}}, 3_000
      assert Enum.map(watched["events"], & &1["event"]["source"]) == ["telemetry"]
      assert watched["filtered"]["view"] == %{"sources" => 2}

      assert_receive {:insider_live_events, ^id, unfiltered}, 3_000
      assert [_, _, _] = unfiltered["events"]

      for view <- [
            %{"sources" => ["disk"]},
            %{"kinds" => []},
            %{"min_severity" => 3},
            %{"x" => 1}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "view"}} =
                 Live.events_since(id, 0, %{"view" => view})
      end

      assert {:error, %{"code" => "invalid_options", "field" => "view"}} =
               Live.subscribe(id, self(), %{"view" => "telemetry"})

      assert {:error, %{"code" => "invalid_options", "field" => "options"}} =
               Live.subscribe(id, self(), :not_a_map)
    end

    test "a subscriber whose view hides everything still receives the filtered counts" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@tick)]
               })

      for count <- 1..3, do: :telemetry.execute(@tick, %{count: count}, %{})
      view = %{"view" => %{"kinds" => ["other.kind"]}}
      assert {:ok, _subscription} = Live.subscribe(id, self(), view)

      assert_receive {:insider_live_events, ^id, batch}, 8_000
      assert batch["events"] == []
      assert batch["filtered"]["view"] == %{"kinds" => 3}
      assert batch["next_cursor"] == 3

      assert {:ok, _stopped} = Live.stop(id)
      assert_receive {:insider_live_events, ^id, %{"state" => "stopped"} = final}, 3_000
      assert final["filtered"]["view"] == %{"kinds" => 0}
    end

    # A tick whose view hid every event
    # sent nothing but advanced the subscriber's cursor, so the next batch
    # started there: its cursor skipped the previous next_cursor while its
    # view counts covered the skipped receipts.
    test "subscriber batches stay contiguous across ticks whose view hid every event" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_events" => [segments(@tick)],
                 "logger_level" => "info"
               })

      :telemetry.execute(@tick, %{count: 1}, %{})

      assert {:ok, _subscription} =
               Live.subscribe(id, self(), %{"view" => %{"sources" => ["telemetry"]}})

      assert_receive {:insider_live_events, ^id, first}, 5_000
      assert [%{"event" => %{"source" => "telemetry"}}] = first["events"]

      # Hidden by the view. A tick received after they were logged reads
      # them, has nothing to send, and finishes before the status call.
      for index <- 1..3, do: :logger.info("hidden #{index}")
      owner = Process.whereis(Insider.Live.Owner)
      :erlang.trace(owner, true, [:receive])
      assert_receive {:trace, ^owner, :receive, :push}, 2_000
      :erlang.trace(owner, false, [:receive])
      assert {:ok, _status} = Live.status(id)

      :telemetry.execute(@tick, %{count: 2}, %{})
      batches = [first | await_source(id, "telemetry")]

      for {previous, batch} <- Enum.zip(batches, tl(batches)),
          do: assert(batch["cursor"] == previous["next_cursor"])

      accounted =
        Enum.sum(
          for batch <- batches,
              do: length(batch["events"]) + Enum.sum(Map.values(batch["filtered"]["view"]))
        )

      assert accounted == List.last(batches)["next_cursor"] - first["cursor"]
      assert List.last(batches)["filtered"]["view"]["sources"] >= 3
    end

    # Limit and max_bytes once counted the
    # events a view hid, so a sparse view starved.
    test "a sparse view's limit and max_bytes count returned events; the scan budget bounds the rest" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger", "telemetry"],
                 "telemetry_events" => [segments(@tick)],
                 "logger_level" => "info",
                 "logger_include" => [%{"domain" => ["insider_filters"]}]
               })

      # Logger and Telemetry write to the Recorder at the same time; neither
      # loses an event to the other.
      for index <- 1..30 do
        :logger.info("noise #{index}", %{domain: [:insider_filters]})
        if rem(index, 10) == 0, do: :telemetry.execute(@tick, %{count: index}, %{})
      end

      assert {:ok, everything} = Live.events_since(id, 0, @all)
      assert everything["gaps"] == []

      assert Enum.frequencies_by(everything["events"], & &1["event"]["source"]) ==
               %{"logger" => 30, "telemetry" => 3}

      ticks = Enum.filter(everything["events"], &(&1["event"]["source"] == "telemetry"))
      assert [first, second, third] = Enum.map(ticks, & &1["receipt"])
      view = %{"sources" => ["telemetry"]}

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 2, "view" => view})
      assert Enum.map(batch["events"], & &1["receipt"]) == [first, second]
      assert %{"next_cursor" => next, "truncated" => true, "truncated_by" => "limit"} = batch
      assert next == third - 1
      assert batch["filtered"]["view"] == %{"sources" => third - 1 - 2}

      assert {:ok, rest} = Live.events_since(id, next, %{"limit" => 2, "view" => view})
      assert Enum.map(rest["events"], & &1["receipt"]) == [third]
      assert %{"next_cursor" => end_cursor, "truncated_by" => nil} = rest
      assert end_cursor == everything["next_cursor"]

      # Two returned ticks fit; the hidden noise between them costs no bytes.
      size = ticks |> hd() |> Canonical.encode() |> byte_size()
      assert size > 410

      assert {:ok, bytes} =
               Live.events_since(id, 0, %{"max_bytes" => div(size * 5, 2), "view" => view})

      assert Enum.map(bytes["events"], & &1["receipt"]) == [first, second]
      assert %{"next_cursor" => ^next, "truncated_by" => "max_bytes"} = bytes

      # The scan budget ends a read before the limit and says so.
      assert {:ok, scanned} = Live.events_since(id, 0, %{"scan_limit" => 5, "view" => view})
      assert %{"next_cursor" => 5, "truncated" => true, "truncated_by" => "scan_limit"} = scanned
      assert length(scanned["events"]) + Enum.sum(Map.values(scanned["filtered"]["view"])) == 5
    end
  end

  describe "severity" do
    # Each event carries its case number as the `count` measurement, which
    # both profiles disclose once selected.
    @exception [:insider_severity, :router_dispatch, :exception]
    @endpoint [:insider_severity, :endpoint, :stop]
    @plugin [:insider_severity, :plugin, :stop]
    @failing [
      {1, @exception, %{kind: :error, reason: :boom}},
      {2, @endpoint, %{conn: %{status: 500}}},
      {3, @endpoint, %{conn: %{status: 503}}},
      {4, @query, %{result: {:error, :timeout}}},
      {5, @plugin, %{error: :database_down}}
    ]
    @healthy [
      {6, @endpoint, %{conn: %{status: 200}}},
      {7, @endpoint, %{conn: %{status: 404}}},
      {8, @query, %{result: {:ok, %{num_rows: 1}}}},
      {9, @plugin, %{}}
    ]

    test "exceptions and failed stop events are errors, so a min_severity error view keeps them" do
      for profile <- ["rich", "strict"] do
        assert {:ok, %{"session_id" => id, "disclosure_profile" => ^profile}} =
                 Live.start(%{
                   "components" => ["telemetry"],
                   "disclosure" => profile,
                   "telemetry_events" =>
                     Enum.map([@exception, @endpoint, @query, @plugin], &segments/1),
                   "telemetry_measurements" => ["count"]
                 })

        for {number, name, metadata} <- @failing ++ @healthy,
            do: :telemetry.execute(name, %{count: number}, metadata)

        errors_view = Map.put(@all, "view", %{"min_severity" => "error"})
        assert {:ok, errors} = Live.events_since(id, 0, errors_view)
        assert {:ok, everything} = Live.events_since(id, 0, @all)

        assert case_numbers(errors) == Enum.map(@failing, &elem(&1, 0))
        assert errors["filtered"]["view"] == %{"min_severity" => length(@healthy)}

        severities =
          Map.new(everything["events"], fn entry ->
            {entry["event"]["attributes"]["measurements"]["count"], entry["event"]["severity"]}
          end)

        assert severities ==
                 Map.merge(
                   Map.new(@failing, &{elem(&1, 0), "error"}),
                   Map.new(@healthy, &{elem(&1, 0), "info"})
                 )

        assert {:ok, _stopped} = Live.stop(id)
        await_slot_free()
      end
    end
  end

  describe "report/3" do
    test "span filter counts are reported as deltas under otel, and count as filtered" do
      counts = %{{"otel", "min_duration"} => 7, {"logger", "level"} => 2, {"summary_lost"} => 4}
      baseline = %{{"otel", "min_duration"} => 3}

      report = Filters.report(counts, baseline, nil)

      assert report["scope"] == "since_cursor_issued"
      assert report["otel"] == %{"min_duration" => 4}
      assert report["logger"] == %{"level" => 2}
      # A loss is a gap, never a filtered count.
      refute Map.has_key?(report, "summary_lost")
      assert Filters.any?(report)

      quiet = Filters.report(%{{"otel", "min_duration"} => 3}, baseline, %{})
      assert quiet["otel"] == %{"min_duration" => 0}
      refute Filters.any?(quiet)
    end

    test "anything but a report counts nothing" do
      refute Filters.any?(nil)
      refute Filters.any?(%{"logger" => %{"level" => 1}})
    end
  end

  describe "start/3" do
    test "the span minimum needs the otel component and is echoed only with it" do
      assert {:ok, %{config: config, spec: spec}} =
               Filters.start(%{"otel_min_duration_ms" => 25}, [:otel], [])

      assert config["otel_min_duration_ms"] == 25
      assert spec.otel == %{min_duration_ms: 25}

      assert {:ok, %{config: default}} = Filters.start(%{}, [:otel], [])
      assert default["otel_min_duration_ms"] == 0

      assert {:error, %{"code" => "invalid_options", "field" => "otel_min_duration_ms"}} =
               Filters.start(%{"otel_min_duration_ms" => 25}, [:logger], [])

      assert {:ok, %{config: without, spec: %{otel: nil}}} = Filters.start(%{}, [:logger], [])
      refute Map.has_key?(without, "otel_min_duration_ms")
    end

    test "an origin rule is oban or a process rule map, and a module rule names a module" do
      for origins <- [[42], ["not oban"], [%{"module" => 42}], [%{"module" => ""}]] do
        assert {:error, %{"code" => "invalid_options", "field" => "exclude_origins"}} =
                 Filters.start(%{"exclude_origins" => origins}, [:logger], []),
               inspect(origins)
      end

      assert {:ok, %{config: %{"exclude_origins" => [%{"module" => "Insider.Live.Filters"}]}}} =
               Filters.start(
                 %{"exclude_origins" => [%{"module" => "Insider.Live.Filters"}]},
                 [:logger],
                 []
               )
    end
  end

  describe "default_telemetry_events/0" do
    setup do
      on_exit(fn ->
        for repo <- [
              __MODULE__.TextConfigRepo,
              __MODULE__.TextPrefixRepo,
              __MODULE__.MixedPrefixRepo
            ],
            do: Application.delete_env(:insider, repo)
      end)

      %{baseline: Filters.default_telemetry_events()}
    end

    test "with Absinthe loaded, its operation stop is a quiet default recorded at any duration",
         %{baseline: baseline} do
      refute ["absinthe", "execute", "operation", "stop"] in baseline

      spec = [description: ~c"stand-in", vsn: ~c"1.7.0", modules: [], applications: []]
      :ok = :application.load({:application, :absinthe, spec})
      on_exit(fn -> Application.unload(:absinthe) end)

      assert ["absinthe", "execute", "operation", "stop"] in Filters.default_telemetry_events()

      assert {:ok, %{"session_id" => id} = record} = Live.start(%{"components" => ["telemetry"]})

      assert record["filters"]["telemetry_event_min_duration_ms"][
               "absinthe.execute.operation.stop"
             ] == 0

      assert {:ok, _stopped} = Live.stop(id)
    end

    test "with Phoenix loaded, its events are recorded and only the others are skipped",
         %{baseline: baseline} do
      refute ["phoenix", "endpoint", "stop"] in baseline
      # A Phoenix node has these atoms: its modules name them.
      _atoms = [:phoenix, :endpoint, :router_dispatch, :exception]

      spec = [description: ~c"stand-in", vsn: ~c"1.8.0", modules: [], applications: []]
      :ok = :application.load({:application, :phoenix, spec})
      on_exit(fn -> Application.unload(:phoenix) end)

      assert {:ok, %{"session_id" => id} = started} =
               Live.start(%{"components" => ["logger", "telemetry"]})

      assert started["telemetry_events"] == [
               ["phoenix", "endpoint", "stop"],
               ["phoenix", "router_dispatch", "exception"]
             ]

      assert Enum.map(started["telemetry_skipped_defaults"], & &1["event"]) ==
               @known_defaults -- ["phoenix.endpoint.stop", "phoenix.router_dispatch.exception"]

      refute Map.has_key?(started, "telemetry_hint")
      assert started["filters"]["telemetry_event_min_duration_ms"]["phoenix.endpoint.stop"] == 0
      assert {:ok, _stopped} = Live.stop(id)
    end

    test "at most eight repository query events count, and a repository whose atoms are missing is skipped",
         %{baseline: baseline} do
      repos = for n <- 1..9, do: Module.concat(__MODULE__, "BoundRepo#{n}")
      on_exit(fn -> for repo <- repos, do: Application.delete_env(:insider, repo) end)

      # The first two share a prefix: the bound counts entries, as in 0.1.0.
      for {repo, n} <- Enum.with_index(repos, 1) do
        Application.put_env(:insider, repo,
          telemetry_prefix: [:insider_bound, String.to_atom("r#{max(n, 2) - 1}")]
        )
      end

      # Its default prefix ends in a segment that is no atom on this node.
      missing = __MODULE__.NeverAnAtomQ9zRepo
      Application.put_env(:insider, :ecto_repos, [missing | repos])

      {recorded, skipped} = Filters.telemetry_defaults()

      assert recorded -- baseline == for(n <- 1..7, do: ["insider_bound", "r#{n}", "query"])

      assert ["insider", "live", "filters_test", "never_an_atom_q9z_repo", "query"] in skipped
      refute Enum.any?(skipped, &match?(["insider_bound" | _], &1))
    end

    test "a misconfigured repository adds no query event and never raises", %{baseline: baseline} do
      Application.put_env(:insider, :ecto_repos, :not_a_list)
      assert Filters.default_telemetry_events() == baseline

      repos = [
        __MODULE__.TextConfigRepo,
        __MODULE__.TextPrefixRepo,
        __MODULE__.MixedPrefixRepo,
        :lowercase_repo
      ]

      Application.put_env(:insider, :ecto_repos, repos)
      # Not a keyword list: no prefix is read, and the default one has no atoms.
      Application.put_env(:insider, __MODULE__.TextConfigRepo, "config")
      # A prefix that is not a list of atoms names no event.
      Application.put_env(:insider, __MODULE__.TextPrefixRepo, telemetry_prefix: "shop")

      Application.put_env(:insider, __MODULE__.MixedPrefixRepo,
        telemetry_prefix: [:insider, "repo"]
      )

      # A repository that is not an Elixir module has no default prefix.
      assert Filters.default_telemetry_events() == baseline
    end
  end

  defp case_numbers(batch),
    do: Enum.map(batch["events"], & &1["event"]["attributes"]["measurements"]["count"])

  defp configure_repos do
    Application.put_env(:insider, :ecto_repos, [
      __MODULE__.QuietRepo,
      InsiderQuietDefault.Repo,
      "not a repo"
    ])

    Application.put_env(:insider, __MODULE__.QuietRepo, telemetry_prefix: [:insider_quiet, :repo])
  end

  defp summarized_session(options) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(
               Map.merge(
                 %{
                   "components" => ["telemetry"],
                   "telemetry_events" => [segments(@query)],
                   "telemetry_summaries" => [@query_kind]
                 },
                 options
               )
             )

    id
  end

  defp summary?(entry), do: entry["event"]["attributes"]["lifecycle_phase"] == "summary"

  # Collects the summaries of every batch up to and including the terminal
  # one, and returns the terminal batch with them.
  defp await_terminal(id, summaries \\ []) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000

    summaries =
      summaries ++
        for entry <- batch["events"], summary?(entry), do: entry["event"]["attributes"]["summary"]

    if batch["state"] == "running", do: await_terminal(id, summaries), else: {batch, summaries}
  end

  defp query(milliseconds, result) do
    :telemetry.execute(
      @query,
      %{query_time: native(milliseconds), total_time: native(milliseconds)},
      %{type: :ecto_sql_query, result: result, options: []}
    )
  end

  # Records one marker event and returns a cursor after it, so later reads
  # report filtered counts since that cursor rather than since session start.
  defp settled(id) do
    :logger.error("settle", %{domain: [:insider_filters]})
    assert {:ok, %{"next_cursor" => cursor}} = Live.events_since(id, 0, @all)
    assert cursor > 0
    cursor
  end

  defp native(milliseconds), do: System.convert_time_unit(milliseconds, :millisecond, :native)

  defp segments(event), do: Enum.map(event, &Atom.to_string/1)

  defp component(name) do
    session = :sys.get_state(Manager).active.pid
    Map.fetch!(:sys.get_state(session).components, name)
  end

  defp await_event(id, predicate) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000

    case Enum.find(batch["events"], predicate) do
      nil -> await_event(id, predicate)
      event -> event
    end
  end

  # The batches up to and including the first that shows an event of `source`.
  defp await_source(id, source) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000

    if Enum.any?(batch["events"], &(&1["event"]["source"] == source)),
      do: [batch],
      else: [batch | await_source(id, source)]
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, message})
        relay(parent)
    end
  end

  defp await_slot_free,
    do: assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)

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
