defmodule InsiderTest.FlagStore do
  @moduledoc false
  # A process-global in-memory flag store, like a feature-flag library's local overrides.
  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
end

defmodule Insider.Live.VanishingTest do
  # One live session per node; the call trace is node-wide.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag skip:
               :erlang.system_info(:otp_release) < ~c"28" && "the calls component requires OTP 28"

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias InsiderTest.FlagStore

  @flag "new-checkout"
  @stop [:absinthe, :execute, :operation, :stop]
  @server [:bandit, :request, :stop]
  @tick [:insider_vanishing, :tick]

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
               Map.merge(
                 %{
                   "components" => ["calls", "telemetry"],
                   "watch_writes" => ["InsiderTest.FlagStore.set/2"],
                   "calls_results" => "none",
                   "telemetry_events" => [
                     Enum.map(@stop, &to_string/1),
                     Enum.map(@server, &to_string/1),
                     Enum.map(@tick, &to_string/1)
                   ],
                   "telemetry_min_duration_ms" => 0
                 },
                 extra
               )
             )

    id
  end

  # Another user's request: setFeatureToggle writes the flag, in the
  # request process, under its trace context.
  defp flip(value, trace) do
    Task.await(
      Task.async(fn ->
        Logger.metadata(otel_trace_id: trace, otel_span_id: "00f067aa0ba902b7")

        conn = %{
          __struct__: Plug.Conn,
          method: "POST",
          request_path: "/api/graphql",
          status: 200,
          remote_ip: {127, 0, 0, 1},
          req_headers: [{"user-agent", "python-urllib/3.12"}]
        }

        # Each stop's duration is the time since the request started, as
        # Absinthe and Phoenix measure it, so the operation's interval covers
        # the write however long the process waits to be scheduled.
        started = System.monotonic_time()
        :telemetry.execute([:phoenix, :endpoint, :start], %{system_time: 0}, %{conn: conn})
        FlagStore.set(@flag, value)

        blueprint = %{
          __struct__: Absinthe.Blueprint,
          operations: [
            %{name: "setFeatureToggle", type: :mutation, current: true, selections: []}
          ],
          fragments: [],
          result: %{data: %{}}
        }

        elapsed = fn -> System.monotonic_time() - started end
        :telemetry.execute(@stop, %{duration: elapsed.()}, %{blueprint: blueprint, options: []})
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: elapsed.()}, %{conn: conn})

        now = System.monotonic_time()

        :telemetry.execute(@server, %{monotonic_time: now, duration: now - started}, %{conn: conn})
      end)
    )
  end

  @on "5bf92f3577b34da6a3ce929d0e0e4731"
  @off "5bf92f3577b34da6a3ce929d0e0e4732"

  test "changes names who flipped a flag, and the digest leads with it" do
    id = start()
    flip(100, @on)
    flip(0, @off)

    assert {:ok, changes} = Live.changes(id, %{"key" => @flag, "human" => true})
    assert changes["schema"] == "insider.live-changes/v1"
    assert [on, off] = changes["changes"]

    assert %{
             "key" => @flag,
             "value" => 100,
             "writer" => %{
               "operation" => "mutation setFeatureToggle",
               "route" => "POST /api/graphql",
               "user_agent" => "python-urllib/3.12",
               "trace_id" => @on
             }
           } = on

    assert off["value"] == 0
    assert changes["text"] =~ "Changes of #{@flag}: 2 writes\n"

    assert changes["text"] =~
             "#{@flag} = 100 by mutation setFeatureToggle (POST /api/graphql, python-urllib/3.12), trace #{@on}"

    assert {:ok, digest} = Live.digest(id, %{"since" => 0, "human" => true})

    assert [%{"kind" => "value_changes", "line" => line, "command" => command}] =
             digest["anomalies"]

    assert line ==
             "Value changed: #{@flag} written 2 times in this window (2 values) by mutation setFeatureToggle ×2."

    assert command == "mix insider.live changes \"${N[@]}\" --session #{id} --key '#{@flag}'"

    # The kept records name the client the request came from.
    assert {:ok, %{"records" => [%{"user_agent" => "python-urllib/3.12"}, _]}} =
             Live.mutations(id)

    assert {_out, 0} = System.cmd("/bin/bash", ["-n", "-c", command], stderr_to_stdout: true)

    # The mutation's stop is still in the Recorder and among the trace's
    # items: the kept record claims no eviction, and the text adds nothing.
    assert {:ok, trace} = Live.trace(id, @on, %{"human" => true})
    assert [%{"operation" => "setFeatureToggle", "evicted" => false}] = trace["mutations"]
    refute trace["text"] =~ "Kept mutation"
  end

  # Kept records pass the reader's view like events do.
  test "kept mutation records pass the reader's view, given or stored" do
    id = start()
    flip(100, @on)
    logger_only = %{"sources" => ["logger"]}

    assert {:ok, trace} = Live.trace(id, @on, %{"view" => logger_only, "human" => true})
    assert trace["mutations"] == []
    refute trace["text"] =~ "Kept mutation"

    assert {:ok, _read} =
             Live.events_since(id, 0, %{
               "reader" => "r",
               "view" => logger_only,
               "view_keep" => true
             })

    assert {:ok, %{"mutations" => [], "stored_view" => %{"reader" => "r"}}} =
             Live.trace(id, @on, %{"reader" => "r"})

    # A view that keeps them keeps them.
    assert {:ok, %{"mutations" => [_kept]}} =
             Live.trace(id, @on, %{"view" => %{"sources" => ["telemetry", "calls"]}})
  end

  # Counts cover every write read; a page says what it left
  # out, and an eviction makes the counts lower bounds.
  test "changes counts every write, pages the newest 256, and says when writes were evicted" do
    id = start(%{"calls_max" => 1_000, "calls_rate_max" => 10_000})
    for n <- 1..257, do: FlagStore.set(@flag, n)

    assert {:ok, changes} = Live.changes(id, %{"key" => @flag, "human" => true})
    assert Enum.count(changes["changes"]) == 256
    assert %{"writes" => 257, "shown" => 256, "omitted" => 1} = changes
    assert hd(changes["changes"])["value"] == 2
    assert [%{"writes" => 257, "complete" => true}] = changes["repeated"]
    assert changes["text"] =~ "Changes of #{@flag}: 257 writes (the newest 256 shown)\n"
    assert changes["gaps"] == []

    Live.stop(id, %{"force" => true})
    assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)

    id = start(%{"calls_max" => 1_000, "calls_rate_max" => 10_000, "max_events" => 64})
    for n <- 1..300, do: FlagStore.set(@flag, n)

    assert {:ok, changes} = Live.changes(id, %{"key" => @flag})
    assert [%{"complete" => false, "writes" => writes}] = changes["repeated"]
    assert writes < 300
    assert Enum.any?(changes["gaps"], &(&1["reason"] == "evicted"))

    assert {:ok, %{"anomalies" => anomalies}} = Live.digest(id, %{"since" => 0})
    assert %{"line" => line} = Enum.find(anomalies, &(&1["kind"] == "value_changes"))
    assert line =~ "written at least #{writes} times in this window"
    assert line =~ "some writes were evicted or not examined"
  end

  test "a mutation's compact record survives eviction and still names the writer" do
    id = start(%{"max_events" => 64})
    flip(100, @on)
    flip(0, @off)
    # The owner's push tick (every 500 ms) copies it; its state call waits
    # for the tick to finish.
    send(Process.whereis(Insider.Live.Owner), :push)
    :sys.get_state(Insider.Live.Owner)
    # Telemetry floods the Recorder past the operation stop's eviction.
    for _chunk <- 1..4 do
      for n <- 1..100, do: :telemetry.execute(@tick, %{duration: n}, %{})
      assert {:ok, _caught_up} = Live.events_since(id, "latest")
    end

    # The flood's evictions after the copy are counted, not lost silently.
    assert {:ok, %{"mutations" => %{"records" => 2, "dropped" => 0, "missed_receipts" => missed}}} =
             Live.status(id)

    assert missed > 0

    assert {:ok, %{"changes" => [change, _off]}} = Live.changes(id, %{"key" => @flag})

    assert %{"operation" => "mutation setFeatureToggle", "kept" => true, "trace_id" => @on} =
             change["writer"]

    # The digest's anomaly names the writer from the kept records too.
    assert {:ok, %{"anomalies" => [%{"kind" => "value_changes", "line" => line} | _]}} =
             Live.digest(id, %{"since" => 0})

    # The flood's evictions make the count a lower bound.
    assert line =~
             "written at least 2 times in this window (2 values) by mutation setFeatureToggle ×2; " <>
               "some writes were evicted or not examined."

    # The mutation's trace was kept by default, so the
    # trace shows its operation stop, and the kept record adds no line.
    assert {:ok, trace} = Live.trace(id, @on, %{"human" => true})

    assert [%{"operation" => "setFeatureToggle", "result" => "ok", "evicted" => true}] =
             trace["mutations"]

    assert trace["text"] =~ "Retained: kept because it ran a GraphQL mutation"
    refute trace["text"] =~ "Kept mutation"

    # Past the mutation traces retention keeps, the oldest goes; its kept
    # record still names it, and says its events were evicted.
    max = Insider.Live.Retention.bounds()["mutation_traces_max"]

    for n <- 1..max,
        do:
          flip(n, "6bf92f3577b34da6a3ce929d0e#{String.pad_leading(Integer.to_string(n), 6, "0")}")

    send(Process.whereis(Insider.Live.Owner), :push)
    :sys.get_state(Insider.Live.Owner)

    assert {:ok, trace} = Live.trace(id, @on, %{"human" => true})
    assert trace["text"] =~ "\nKept mutation: setFeatureToggle result=ok at "
    assert trace["text"] =~ "evicted from the Recorder"
  end

  # A repeated CI run found it: a write was paired with
  # the wrong events, or with none, because its time came from another
  # clock. Telemetry, Logger, and Poller events take their wall time from
  # the OS clock (System.os_time/1); a watched write took it from Erlang
  # system time (monotonic + time offset), which can differ from the OS
  # clock while the VM's time correction catches up. A write made just
  # before its operation's stop could then appear after it. The write's
  # time is now on the OS clock: between OS-clock readings taken right
  # before and right after it. (This host's two clocks agree within a
  # microsecond, so here the test pins the contract; the census runner did
  # not.)
  test "a watched write is timed on the OS clock, as the events it is paired with" do
    id = start()
    before_us = System.os_time(:microsecond)
    FlagStore.set(@flag, 7)
    after_us = System.os_time(:microsecond)

    assert_eventually(fn ->
      match?({:ok, %{"changes" => [_write]}}, Live.changes(id, %{"key" => @flag}))
    end)

    assert {:ok, %{"changes" => [%{"at" => at}]}} = Live.changes(id, %{"key" => @flag})
    {:ok, at, 0} = DateTime.from_iso8601(at)
    at_us = DateTime.to_unix(at, :microsecond)
    assert before_us <= at_us and at_us <= after_us
  end

  test "under strict a write records its key and writer, never its value" do
    Application.put_env(:insider, :environment, :ci)
    id = start(%{"telemetry_measurements" => ["duration"]})
    flip(100, @on)

    assert {:ok, %{"changes" => [change]}} = Live.changes(id, %{"key" => @flag})
    assert change["key"] == @flag
    assert change["value"] == nil
    assert change["writer"]["pid"] =~ ~r/^<\d+\.\d+\.\d+>$/
    assert change["writer"]["user_agent"] == nil

    # Strict captures no client for the operation, and its record names none.
    assert {:ok, %{"events" => events}} = Live.events_since(id, 0)

    for %{"event" => %{"kind" => "absinthe.execute.operation.stop"} = e} <- events,
        do: assert(e["attributes"]["graphql"]["client"] == nil)

    assert {:ok, %{"records" => [%{"user_agent" => nil, "operation" => nil}]}} =
             Live.mutations(id)
  end

  # `{:message, false}` suppressed these calls entirely, so
  # they were neither recorded nor counted toward the trace's limits.
  test "under strict a write whose key is no short name is recorded with a nil key, within the limits" do
    Application.put_env(:insider, :environment, :ci)
    id = start(%{"calls_max" => 3, "calls_rate_max" => 1_000})

    FlagStore.set({:tuple, :key}, 1)
    FlagStore.set(String.duplicate("k", 129), 1)
    for _n <- 1..20, do: FlagStore.set({:tuple, :key}, 1)

    assert {:ok, batch} = Live.events_since(id, 0)
    calls = Enum.filter(batch["events"], &(&1["event"]["source"] == "calls"))

    assert [nil, nil, nil] =
             for(%{"event" => %{"kind" => "call"} = e} <- calls, do: e["attributes"]["key"])

    assert Enum.any?(
             calls,
             &match?(
               %{
                 "event" => %{
                   "kind" => "call.stopped",
                   "attributes" => %{"reason" => "calls_max"}
                 }
               },
               &1
             )
           )

    refute Jason.encode!(batch) =~ "kkkkkkkk"
  end

  # A credential-named key's value never reaches an event.
  test "the value written under a credential-named key is masked in events, changes, and text" do
    id = start()
    FlagStore.set(:password, "review-short-password")

    assert {:ok, changes} = Live.changes(id, %{"key" => "password", "human" => true})
    assert [%{"value" => "[masked: 21 bytes]"}] = changes["changes"]
    assert {:ok, batch} = Live.events_since(id, 0)

    for document <- [changes, batch],
        do: refute(Jason.encode!(document) =~ "review-short-password")
  end

  test "watch_writes is validated and needs the calls component" do
    assert {:error, %{"code" => "invalid_options", "field" => "watch_writes"}} =
             Live.start(%{
               "components" => ["logger"],
               "watch_writes" => ["InsiderTest.FlagStore.set/2"]
             })

    assert {:error, %{"code" => "untraceable_function"}} =
             Live.start(%{
               "components" => ["calls"],
               "watch_writes" => [":persistent_term.put/2"]
             })

    assert {:error, %{"code" => "invalid_options", "field" => "key"}} =
             Live.changes("live-none", %{"key" => String.duplicate("k", 200)})
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
