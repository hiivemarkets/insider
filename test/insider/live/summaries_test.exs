defmodule Insider.Live.SummariesTest do
  # One collector session is global per node, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Logger

  alias Insider.Collector.Gate
  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Logger.Handler, as: LoggerHandler
  alias Insider.Collector.Session.Manager
  alias Insider.Collector.Summary
  alias Insider.Collector.Telemetry, as: TelemetryCollector
  alias Insider.Collector.Telemetry.Handler, as: TelemetryHandler
  alias Insider.Live

  @lookup [:insider_summaries_test, :lookup]
  @checkout [:insider_summaries_test, :checkout]
  @lookup_kind "insider_summaries_test.lookup"
  @checkout_kind "insider_summaries_test.checkout"
  @all %{"limit" => 500, "max_bytes" => 1_048_576}

  defmodule Pricing do
    # A server that measures its own callback, as a GenServer handler does.
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def lookup(pid, native), do: GenServer.call(pid, {:lookup, native})

    @impl GenServer
    def init(:ok), do: {:ok, nil}

    @impl GenServer
    def handle_call({:lookup, native}, _from, state) do
      :telemetry.execute([:insider_summaries_test, :lookup], %{duration: native}, %{})
      {:reply, :ok, state}
    end
  end

  defmodule ScopeServer do
    # A server whose callback blocks until the test releases it.
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl GenServer
    def init(test), do: {:ok, test}

    @impl GenServer
    def handle_call(:work, _from, test) do
      send(test, {:blocked, self()})

      receive do
        :release -> {:reply, :ok, test}
      end
    end
  end

  defmodule ScopeCaller do
    # A server that calls another one and measures that call: the time its
    # caller waited, though it is emitted inside an OTP server.
    use GenServer

    def start_link(server), do: GenServer.start_link(__MODULE__, server)
    def run(pid), do: GenServer.call(pid, :run)

    @impl GenServer
    def init(server), do: {:ok, server}

    @impl GenServer
    def handle_call(:run, _from, server) do
      started = System.monotonic_time()
      :ok = GenServer.call(server, :work)
      duration = System.monotonic_time() - started
      :telemetry.execute([:insider_summaries_test, :checkout], %{duration: duration}, %{})
      {:reply, :ok, server}
    end
  end

  defmodule BurstSource do
    # The call sites of a log flood.
    require Logger

    def fail(order), do: Logger.error("checkout failed for order #{order}")
    def low(sku), do: Logger.warning("low stock for #{sku}")
    # A shared logging helper: one call site, many messages.
    def report(text), do: Logger.error(text)
  end

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)
  end

  describe "Telemetry exemplars and trends" do
    test "trends show declared handler time next to declared caller latency, p95 and errors across windows" do
      scopes = %{@lookup_kind => "handler", @checkout_kind => "caller"}

      assert {:ok, %{"session_id" => id} = started} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [segments(@lookup), segments(@checkout)],
                 "telemetry_measurements" => ["duration"],
                 "telemetry_min_duration_ms" => 0,
                 "telemetry_summaries" => [@lookup_kind, @checkout_kind],
                 "telemetry_summary_interval_ms" => 1_000,
                 "telemetry_duration_scopes" => scopes
               })

      assert started["filters"]["telemetry_duration_scopes"] == scopes

      {:ok, pricing} = Pricing.start_link()

      # Window 1: lookups take 1 ms inside the server, checkouts 2 ms.
      for _n <- 1..3, do: Pricing.lookup(pricing, native(1))
      for _n <- 1..3, do: checkout(2, :ok)
      end_window(:telemetry)

      # Window 2: the server is as fast; callers wait 8 ms and one fails.
      for _n <- 1..3, do: Pricing.lookup(pricing, native(1))
      for _n <- 1..3, do: checkout(8, :ok)
      checkout(9, {:error, :timeout})
      end_window(:telemetry)

      assert {:ok, trends} = Live.trends(id)
      assert trends["schema"] == "insider.live-trends/v1"
      assert trends["units"]["duration"] == "us"
      assert trends["units"]["rate"] == "events per minute"
      assert trends["logger"] == []

      series = Map.new(trends["telemetry"], &{&1["kind"], &1})
      checkout = series[@checkout_kind]
      lookup = series[@lookup_kind]

      assert lookup["duration_scope"] == %{
               "measured_in" => "handler",
               "declared" => true,
               "emitter" => %{"context" => "otp_server", "module" => inspect(Pricing)}
             }

      assert checkout["duration_scope"] == %{
               "measured_in" => "caller",
               "declared" => true,
               "emitter" => %{"context" => "process", "module" => nil}
             }

      assert [first, second] = checkout["series"]
      assert first["count"] == 3 and second["count"] == 4
      assert first["errors"] == 0 and second["errors"] == 1
      assert second["error_pct"] == 25
      # A window ended within the millisecond it began (interval_ms 0) has
      # no rate rather than an infinite one; window 1 here can be that short.
      for window <- [first, second] do
        if window["interval_ms"] > 0,
          do: assert(window["rate_per_min"] > 0),
          else: assert(window["rate_per_min"] == nil)
      end

      {:ok, started, 0} = DateTime.from_iso8601(second["started_at"])
      {:ok, ended, 0} = DateTime.from_iso8601(second["ended_at"])
      assert DateTime.compare(started, ended) == :lt
      assert first["ended_at"] == second["started_at"]

      assert %{"first" => p95_before, "last" => p95_after, "direction" => "rising"} =
               checkout["change"]["p95_us"]

      assert p95_before < 3_000 and p95_after >= 9_000

      assert checkout["change"]["errors"] == %{
               "first" => 0,
               "last" => 1,
               "delta" => 1,
               "direction" => "rising"
             }

      assert lookup["change"]["p95_us"]["direction"] == "flat"

      # The declarations do not establish that both series measure one
      # operation, so the note is conditional.
      assert note = Enum.find(trends["notes"], &(&1 =~ "If both describe the same operation"))
      assert note =~ @lookup_kind and note =~ @checkout_kind

      # The failing checkout is the second window's first error; its receipt
      # opens the event with its outcome.
      first_error =
        second["exemplars"]
        |> Enum.map(&open(id, %{"receipt" => &1}))
        |> Enum.find(&(&1["severity"] == "error"))

      assert first_error["attributes"]["exemplar_of"] == %{
               "kind" => @checkout_kind,
               "roles" => ["slowest", "first_error"]
             }

      assert first_error["payload"]["metadata"]["result"] =~ ":timeout"

      # Kinds narrow the series; the plain text has one line per series.
      assert {:ok, %{"telemetry" => [%{"kind" => @lookup_kind}], "text" => text}} =
               Live.trends(id, %{"kinds" => [@lookup_kind], "human" => true, "windows" => 1})

      assert text =~ "Trend: #{@lookup_kind} p95"
      assert text =~ "declared handler time"

      assert {:ok, %{"telemetry" => [%{"series" => [_last]}, _other]}} =
               Live.trends(id, %{"windows" => 1})

      # The digest names the same exemplars, trends and note.
      assert {:ok, digest} = Live.digest(id, %{"human" => true})
      latency = Enum.find(digest["latency"], &(&1["kind"] == @checkout_kind))
      assert Enum.any?(latency["exemplars"], &("first_error" in &1["roles"]))

      assert Enum.map(digest["trends"], & &1["kind"]) |> Enum.sort() == [
               @checkout_kind,
               @lookup_kind
             ]

      assert digest["text"] =~ "exemplar receipts"
      assert digest["text"] =~ "If both describe the same operation"
    end

    test "trends refuses malformed options and its JSON twin answers the same" do
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

      for {options, field} <- [
            {%{"windows" => 0}, "windows"},
            {%{"windows" => 501}, "windows"},
            {%{"kinds" => "shop"}, "kinds"},
            {%{"kinds" => [""]}, "kinds"},
            {%{"since" => "latest"}, "since"},
            {%{"human" => "yes"}, "human"}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => ^field}} =
                 Live.trends(id, options)
      end

      assert {:error, %{"code" => "invalid_options"}} = Live.trends(id, %{"other" => 1})
      assert {:error, %{"code" => "invalid_options"}} = Live.trends(id, :not_a_map)

      assert {:ok, %{"telemetry" => [], "logger" => [], "notes" => [], "text" => text}} =
               Live.trends(id, %{"human" => true})

      assert text =~ "No summaries in this window"

      assert %{"ok" => %{"schema" => "insider.live-trends/v1"}} =
               Jason.decode!(Live.JSON.trends(id))
    end
  end

  # Ports, binaries and mailboxes had no per-window
  # trend. A watched process whose mailbox grows, and ports this test opens,
  # are series in `trends/2` with change and growth.
  describe "Poller trends" do
    test "a watched mailbox and open ports are series across poller samples" do
      name = :insider_summaries_backlog
      parent = self()

      backlog =
        spawn_link(fn ->
          Process.register(self(), name)
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      on_exit(fn -> send(backlog, :stop) end)

      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["poller"],
                 "poller_interval_ms" => 1_000,
                 "watch_processes" => [Atom.to_string(name)]
               })

      assert {:ok, _subscription} =
               Live.subscribe(id, self(), %{"view" => %{"kinds" => ["process_watch"]}})

      for _n <- 1..3 do
        for n <- 1..20, do: send(backlog, {:job, n})
        await_kind(id, "process_watch")
        Port.open({:spawn, "cat"}, [:binary])
      end

      # The ports close when this test process, their owner, exits.
      await_kind(id, "process_watch")

      assert {:ok, trends} =
               Live.trends(id, %{"kinds" => ["process_watch", "port_top", "vm_sample"]})

      mailbox =
        Enum.find(
          trends["poller"],
          &(&1["metric"] == "message_queue_len" and &1["subject"] == Atom.to_string(name))
        )

      assert mailbox["coverage"] == "watched"
      assert mailbox["windows"] >= 3
      assert mailbox["change"]["direction"] == "rising"
      assert mailbox["change"]["last"] >= 60
      assert is_integer(mailbox["per_min"]) and mailbox["per_min"] > 0

      cat = Enum.find(trends["poller"], &(&1["metric"] == "port_type" and &1["subject"] == "cat"))
      assert cat["unit"] == "ports"
      assert cat["change"]["last"] - cat["change"]["first"] >= 2

      binary = Enum.find(trends["poller"], &(&1["metric"] == "binary_bytes"))
      assert binary["unit"] == "bytes" and binary["windows"] >= 3

      assert {:ok, %{"text" => text}} = Live.trends(id, %{"human" => true})
      assert text =~ "Mailbox trend: #{name}"
      assert text =~ "Port trend: cat"
    end
  end

  describe "Logger bursts" do
    test "repeated messages collapse into one row per template, call site and interval with an exemplar" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_level" => "info",
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 1_000
               })

      for order <- [17, 18, 17, 4021, 5], do: BurstSource.fail(order)
      BurstSource.low("fig")
      Logger.error("not from the burst source")
      end_window(:logger)

      BurstSource.fail(18)
      BurstSource.fail(17)
      end_window(:logger)

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert batch["filtered"]["logger"]["summarized"] == 8

      bursts =
        for %{"event" => %{"kind" => "logger_summary"}} = entry <- batch["events"], do: entry

      assert [first, low, second] = bursts

      assert first["event"]["severity"] == "error"
      summary = first["event"]["attributes"]["summary"]
      assert summary["count"] == 5
      assert summary["level"] == "error"
      assert summary["call_site"]["module"] == inspect(BurstSource)
      assert summary["call_site"]["function"] == "fail/1"
      assert is_integer(summary["call_site"]["line"])
      assert summary["template"] == "checkout failed for order N"
      assert summary["template_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
      assert summary["call_sites"] == 1
      assert summary["call_site_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
      assert summary["exemplar_lost"] == false
      assert summary["overflow"] == false

      # The exemplar is the interval's first message, recorded in full.
      exemplar = open(id, %{"receipt" => summary["exemplar_receipt"]})
      assert exemplar["kind"] == "logger_message"
      assert exemplar["payload"]["message"] == "checkout failed for order 17"

      assert low["event"]["severity"] == "warning"
      assert low["event"]["attributes"]["summary"]["count"] == 1

      second_summary = second["event"]["attributes"]["summary"]
      assert second_summary["count"] == 2
      assert second_summary["call_site_fingerprint"] == summary["call_site_fingerprint"]
      assert second_summary["template_fingerprint"] == summary["template_fingerprint"]
      assert second_summary["exemplar_receipt"] > summary["exemplar_receipt"]
      assert second_summary["window_started_at"] == summary["window_ended_at"]

      # Messages outside the rule are recorded one by one.
      messages =
        for %{"event" => %{"kind" => "logger_message"} = event} <- batch["events"],
            do: event["payload"]["message"]

      assert "not from the burst source" in messages
      assert [_, _, _, _] = messages

      assert {:ok, digest} = Live.digest(id, %{"human" => true})
      assert [error_burst, _warning] = digest["logger_bursts"]
      assert error_burst["count"] == 7
      assert error_burst["windows"] == 2
      assert error_burst["peak_count"] == 5
      assert [_, _] = error_burst["exemplar_receipts"]

      assert digest["text"] =~
               "Burst: 7 error \"checkout failed for order N\" from #{inspect(BurstSource)}.fail/1:"

      # The digest's error signatures count the recorded exemplars, never
      # a summary as one error.
      refute Enum.any?(digest["error_signatures"], &(&1["kind"] == "logger_summary"))

      assert {:ok, trends} = Live.trends(id, %{"kinds" => ["logger_summary"]})
      assert trends["telemetry"] == []
      assert [%{"series" => [%{"count" => 5}, %{"count" => 2}]}, _warning] = trends["logger"]
      assert Enum.any?(trends["notes"], &(&1 =~ "Error burst: 7 error messages"))
    end

    test "a stop records the pending burst interval in the terminal batch" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      assert {:ok, _subscription} = Live.subscribe(id, self())
      for order <- [1, 2, 3], do: BurstSource.fail(order)

      assert {:ok, %{"state" => "stopped"}} = Live.stop(id)

      assert [%{"count" => 3, "level" => "error"}] =
               id
               |> terminal()
               |> Enum.filter(&(&1["event"]["kind"] == "logger_summary"))
               |> Enum.map(& &1["event"]["attributes"]["summary"])
    end

    test "distinct messages from one logging helper are distinct bursts" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      BurstSource.report("database unavailable")
      BurstSource.report("payment declined")
      BurstSource.report("database unavailable")
      end_window(:logger)

      assert [database, payment] =
               id
               |> burst_summaries()
               |> Enum.sort_by(& &1["template"])

      assert {database["template"], database["count"]} == {"database unavailable", 2}
      assert {payment["template"], payment["count"]} == {"payment declined", 1}
      assert database["call_site_fingerprint"] == payment["call_site_fingerprint"]
      assert database["template_fingerprint"] != payment["template_fingerprint"]

      # Each burst keeps its own failure's exemplar.
      assert open(id, %{"receipt" => payment["exemplar_receipt"]})["payload"]["message"] ==
               "payment declined"
    end

    # Normalisation replaced the one digit of a high-entropy
    # token, so the export mask no longer saw it and the template disclosed
    # it. Templates are masked before they are normalised, and a token cut
    # by the prefix bound is dropped, whatever the profile.
    test "templates withhold credentials as the exemplar does, and report the masking" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      entropy = "QzWrTyUiOpAsDfGhJkLxCvBnMqWeRtYuIoPaS1"
      provider = "sk_live_" <> "AbCdEfGh12345678"
      # A 40-character token straddling the 160-byte template prefix: the
      # 20 characters inside it are too short to look like a credential.
      cut = "Zx9Kq2Lm4Np6Rs8Tv0Wy3Bc5Df7Gh1Jk3Mn5Pq7R"
      filler = String.duplicate("word ", 28)
      boundary = filler <> cut

      BurstSource.report("connection failed " <> entropy)
      BurstSource.report("charge failed " <> provider)
      BurstSource.report(boundary)
      end_window(:logger)

      view = Map.put(@all, "view", %{"kinds" => ["logger_summary"]})
      assert {:ok, %{"events" => bursts}} = Live.events_since(id, 0, view)
      assert [_, _, _] = bursts

      by_template = Map.new(bursts, &{&1["event"]["attributes"]["summary"]["template"], &1})

      for {template, reason} <- [
            {"connection failed [REDACTED:high_entropy]", "high_entropy"},
            {"charge failed [REDACTED:provider_key]", "provider_key"}
          ] do
        assert %{"redactions" => redactions} = Map.fetch!(by_template, template)

        assert Enum.any?(
                 redactions,
                 &(&1["action"] == "mask" and &1["reason"] == reason and
                     &1["path"] == ["key:attributes", "key:summary", "key:template"])
               )
      end

      assert Map.has_key?(by_template, String.trim(filler) <> " …")

      # No template or fingerprint input carries any part of a credential,
      # and every exemplar withholds it too.
      for burst <- bursts, summary = burst["event"]["attributes"]["summary"] do
        text = Jason.encode!(summary)
        refute text =~ String.slice(entropy, 0, 12)
        refute text =~ String.slice(provider, 8, 12)
        refute text =~ String.slice(cut, 0, 12)

        exemplar = Jason.encode!(open(id, %{"receipt" => summary["exemplar_receipt"]}))
        refute exemplar =~ String.slice(entropy, 0, 12)
        refute exemplar =~ String.slice(provider, 8, 12)
        refute exemplar =~ String.slice(cut, 0, 12)
      end
    end

    test "an exemplar the full inbox sheds marks its burst and is a read gap" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      pid = component(:logger)
      %{inbox_size: inbox_size} = :sys.get_state(pid)

      # The collector drains nothing while suspended: recorded messages fill
      # every inbox slot, and the burst's first message finds none.
      :ok = :sys.suspend(pid)
      for n <- 1..inbox_size, do: Logger.error("filler #{n}")
      BurstSource.fail(1)
      BurstSource.fail(2)
      :ok = :sys.resume(pid)
      end_window(:logger)

      assert {:ok, %{exemplars_shed: 1, exemplars_late: 0}} = LoggerCollector.status(pid)

      assert [%{"count" => 2, "exemplar_lost" => true, "exemplar_receipt" => nil}] =
               burst_summaries(id)

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert %{"count" => 1} = gap(batch, "logger_exemplar_lost")
    end

    test "a burst recorded before its exemplar arrives counts the loss once; the late exemplar is still recorded" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      pid = component(:logger)
      %{gate: gate} = :sys.get_state(pid)

      {_id, {_filter, config}} =
        Enum.find(:logger.get_primary_config().filters, fn {_id, {_filter, config}} ->
          is_map(config) and Map.get(config, :gate) == gate
        end)

      log_event = %{
        level: :error,
        msg: {:string, "checkout failed for order 9"},
        meta: %{mfa: {BurstSource, :fail, 1}, line: 1, time: :logger.timestamp(), pid: self()}
      }

      # The logging process's two steps, the gate's decision and the hand-off
      # of its exemplar, with the collector's interval boundary between them.
      assert {:exemplar, burst} = Gate.logger(gate, log_event)
      end_window(:logger)
      assert :ok = LoggerHandler.exemplar(log_event, config, burst)
      assert {:ok, %{exemplars_late: 1, exemplars_shed: 0}} = LoggerCollector.flush(pid)

      assert [%{"count" => 1, "exemplar_lost" => true, "exemplar_receipt" => nil}] =
               burst_summaries(id)

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert %{"count" => 1} = gap(batch, "logger_exemplar_lost")

      assert ["checkout failed for order 9"] =
               for(
                 %{"event" => %{"kind" => "logger_message"} = event} <- batch["events"],
                 do: event["payload"]["message"]
               )
    end

    test "folded distinctions past the key cap are one overflow row per level and a read gap" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["logger"],
                 "logger_summaries" => [%{"module" => inspect(BurstSource)}],
                 "logger_summary_interval_ms" => 300_000
               })

      # Letters are template text; numbers would be masked into one template.
      texts = for a <- ?a..?z, b <- ?a..?c, do: <<"failure ", a, b>>
      Enum.each(texts, &BurstSource.report/1)
      end_window(:logger)

      summaries = burst_summaries(id)
      {[overflow], rows} = Enum.split_with(summaries, & &1["overflow"])
      assert length(rows) == Gate.max_bursts()
      assert overflow["count"] == length(texts) - Gate.max_bursts()
      assert overflow["distinct_lost"] == length(texts) - Gate.max_bursts()
      assert overflow["template"] == nil and overflow["call_site"] == nil
      assert overflow["template_fingerprint"] == "overflow"
      assert overflow["level"] == "error"

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert %{"count" => count} = gap(batch, "logger_summary_overflow")
      assert count == length(texts) - Gate.max_bursts()
    end
  end

  describe "exemplar loss and duration scope" do
    test "a full inbox loses slow candidates, never the interval's first error, and says so" do
      id = checkout_session()
      pid = component(:telemetry)
      %{inbox_size: inbox_size} = :sys.get_state(pid)
      extra = 20

      # Each sample lands in a new top histogram bucket, so each is a
      # candidate; the suspended collector takes none from the inbox.
      :ok = :sys.suspend(pid)

      for bucket <- 1..(inbox_size + extra),
          do: checkout_us(Summary.upper_bound(bucket), :ok)

      checkout(1, {:error, :timeout})
      :ok = :sys.resume(pid)
      end_window(:telemetry)

      assert [summary] = telemetry_summaries(id)
      assert summary["count"] == inbox_size + extra + 1
      assert summary["errors"] == 1
      assert summary["first_error_retained"] == true
      assert summary["exemplars_lost"] == extra

      assert [%{"error" => true}] =
               Enum.filter(summary["exemplars"], &("first_error" in &1["roles"]))

      assert {:ok, %{exemplars_shed: ^extra}} = TelemetryCollector.status(pid)
      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert %{"count" => ^extra} = gap(batch, "telemetry_exemplar_lost")
    end

    test "a candidate that reaches the collector after its interval was summarised is counted late" do
      id = checkout_session()
      pid = component(:telemetry)
      %{gate: gate, handler_config: config} = :sys.get_state(pid)
      measurements = %{duration: native(3)}
      metadata = %{result: {:error, :timeout}}

      # The emitting process's two steps, the gate's decision and the hand-off
      # of its candidate, with the collector's interval boundary between them.
      assert {:exemplar, exemplar} = Gate.telemetry(gate, @checkout, measurements, metadata)
      end_window(:telemetry)
      assert :ok = TelemetryHandler.candidate(@checkout, measurements, metadata, config, exemplar)
      assert {:ok, %{exemplars_late: 1}} = TelemetryCollector.flush(pid)

      assert [summary] = telemetry_summaries(id)
      assert summary["errors"] == 1
      assert summary["exemplars"] == []
      assert summary["first_error_retained"] == false
      assert summary["duration_scope"] == nil

      assert {:ok, batch} = Live.events_since(id, 0, @all)
      assert %{"count" => 1} = gap(batch, "telemetry_exemplar_lost")
    end

    test "a server that calls another server is the emitter, not proof of handler time" do
      id = checkout_session()
      {:ok, server} = ScopeServer.start_link(self())
      {:ok, caller} = ScopeCaller.start_link(server)

      # ScopeCaller emits the event inside its callback, but what it measured
      # is its own wait for the blocked ScopeServer.
      task = Task.async(fn -> ScopeCaller.run(caller) end)
      assert_receive {:blocked, ^server}
      send(server, :release)
      assert :ok = Task.await(task)
      end_window(:telemetry)

      assert [summary] = telemetry_summaries(id)

      assert summary["duration_scope"] == %{
               "measured_in" => "unknown",
               "declared" => false,
               "emitter" => %{"context" => "otp_server", "module" => inspect(ScopeCaller)}
             }

      # Exemplars from a server and a plain process are a mixed context.
      task = Task.async(fn -> ScopeCaller.run(caller) end)
      assert_receive {:blocked, ^server}
      send(server, :release)
      assert :ok = Task.await(task)
      checkout(60_000, :ok)
      end_window(:telemetry)

      assert [_first, second] = telemetry_summaries(id)
      assert second["duration_scope"]["emitter"] == %{"context" => "mixed", "module" => nil}
      assert second["duration_scope"]["measured_in"] == "unknown"
    end

    test "telemetry_duration_scopes is refused unless it maps summarised kinds to handler or caller" do
      for scopes <- [
            %{@checkout_kind => "server_callback"},
            %{@checkout_kind => :handler},
            %{@lookup_kind => "handler"},
            %{"unknown.kind" => "caller"},
            ["handler"],
            "handler"
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "telemetry_duration_scopes"}} =
                 Live.start(%{
                   "components" => ["telemetry"],
                   "telemetry_events" => [segments(@lookup), segments(@checkout)],
                   "telemetry_summaries" => [@checkout_kind],
                   "telemetry_duration_scopes" => scopes
                 })
      end
    end
  end

  defp checkout_session do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["telemetry"],
               "telemetry_events" => [segments(@checkout)],
               "telemetry_measurements" => ["duration"],
               "telemetry_min_duration_ms" => 0,
               "telemetry_summaries" => [@checkout_kind],
               "telemetry_summary_interval_ms" => 300_000
             })

    id
  end

  defp telemetry_summaries(id) do
    assert {:ok, batch} = Live.events_since(id, 0, @all)

    for %{"event" => %{"kind" => @checkout_kind, "attributes" => %{"summary" => summary}}} <-
          batch["events"],
        do: summary
  end

  # Through a view, so filler events never truncate the read before the bursts.
  defp burst_summaries(id) do
    view = Map.put(@all, "view", %{"kinds" => ["logger_summary"]})
    assert {:ok, %{"truncated" => false} = batch} = Live.events_since(id, 0, view)

    for %{"event" => %{"kind" => "logger_summary", "attributes" => %{"summary" => summary}}} <-
          batch["events"],
        do: summary
  end

  defp gap(batch, reason) do
    assert gap = Enum.find(batch["gaps"], &(&1["reason"] == reason)), inspect(batch["gaps"])
    gap
  end

  defp checkout_us(us, result),
    do:
      :telemetry.execute(
        @checkout,
        %{duration: System.convert_time_unit(us, :microsecond, :native)},
        %{result: result}
      )

  # Ends the collector's current summary interval now, as its timer would,
  # and waits until it has been recorded.
  defp end_window(component) do
    pid = component(component)

    message =
      case :sys.get_state(pid) do
        %{summaries: %{token: {_timer, token}}} -> {:summary, token}
        %{bursts: %{token: token}} -> {:bursts, token}
      end

    send(pid, message)
    _state = :sys.get_state(pid)
    :ok
  end

  defp open(id, %{"receipt" => receipt}) do
    assert {:ok, %{"events" => [entry]}} = Live.events_since(id, receipt - 1, %{"limit" => 1})
    assert entry["receipt"] == receipt
    entry["event"]
  end

  defp terminal(id, events \\ []) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000
    events = events ++ batch["events"]
    if batch["state"] == "running", do: terminal(id, events), else: events
  end

  defp checkout(ms, result),
    do: :telemetry.execute(@checkout, %{duration: native(ms)}, %{result: result})

  defp component(name) do
    session = :sys.get_state(Manager).active.pid
    Map.fetch!(:sys.get_state(session).components, name)
  end

  defp native(milliseconds), do: System.convert_time_unit(milliseconds, :millisecond, :native)
  defp segments(event), do: Enum.map(event, &Atom.to_string/1)

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

  defp await_kind(id, kind) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000

    if Enum.any?(batch["events"], &(&1["event"]["kind"] == kind)),
      do: :ok,
      else: await_kind(id, kind)
  end
end
