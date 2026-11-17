defmodule InsiderTest.CallsTarget do
  @moduledoc false

  # Functions a live call trace traces in these tests.

  def reserve(stock, sku, qty) do
    left = Map.fetch!(stock, sku)
    div(qty * 100, left)
  end

  def echo(value), do: value

  def wait(notify) do
    send(notify, {:waiting, self()})

    receive do
      :release -> :released
    end
  end
end

defmodule Insider.Live.CallsTest do
  # One collector session is global per node, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.CallsOptions
  alias InsiderTest.CallsTarget

  @reserve "InsiderTest.CallsTarget.reserve/3"
  @reserve_mfa {CallsTarget, :reserve, 3}
  @otp_28? :erlang.system_info(:otp_release) |> List.to_integer() >= 28

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

  describe "options" do
    test "a function resolves to a loaded function, never creating an atom or loading code" do
      assert {:ok, @reserve_mfa} = CallsOptions.function(@reserve)

      assert {:ok, @reserve_mfa} =
               CallsOptions.function("Elixir.InsiderTest.CallsTarget.reserve/3")

      assert {:ok, {:ets, :insert, 2}} = CallsOptions.function(":ets.insert/2")
      assert {:ok, {Enum, :member?, 2}} = CallsOptions.function("Enum.member?/2")

      unknown = "Insider.Test.NoSuchModule#{System.unique_integer([:positive])}"

      for {spec, reason} <- [
            {unknown <> ".run/1", "unknown_atom"},
            {"InsiderTest.CallsTarget.no_such_function_#{System.unique_integer([:positive])}/1",
             "unknown_atom"},
            {"InsiderTest.CallsTarget.reserve/4", "not_found"},
            {":erlang.send/2", "protected"},
            {"Insider.Live.start/1", "protected"},
            {"Insider.start/2", "protected"}
          ] do
        assert {:error,
                %{"code" => "untraceable_function", "function" => ^spec, "reason" => ^reason}} =
                 CallsOptions.function(spec)
      end

      # An existing atom that names no loaded module.
      _atom = :insider_calls_test_unloaded

      assert {:error, %{"reason" => "not_loaded"}} =
               CallsOptions.function(":insider_calls_test_unloaded.run/0")

      for spec <- [
            "reserve/3",
            "InsiderTest.CallsTarget.reserve",
            "InsiderTest.CallsTarget.reserve/x",
            "InsiderTest.CallsTarget.reserve/256",
            "lower.case.fun/1",
            ":Bad.fun/1",
            "InsiderTest.CallsTarget.Reserve/3",
            7,
            String.duplicate("A", 300) <> ".f/1"
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "calls"}} =
                 CallsOptions.function(spec)
      end
    end

    test "the calls options need the calls component, which needs calls; each is bounded" do
      assert {:ok, nil} = CallsOptions.start(%{}, ["logger"])

      assert {:error, %{"field" => "calls_max"}} =
               CallsOptions.start(%{"calls_max" => 5}, ["logger"])

      for {options, field} <- [
            {%{}, "calls"},
            {%{"calls" => []}, "calls"},
            {%{"calls" => [@reserve, @reserve]}, "calls"},
            {%{"calls" => [@reserve, "Elixir." <> @reserve]}, "calls"},
            {%{"calls" => List.duplicate(@reserve, 17)}, "calls"},
            {%{"calls" => [@reserve], "calls_results" => "some"}, "calls_results"},
            {%{"calls" => [@reserve], "calls_max" => 0}, "calls_max"},
            {%{"calls" => [@reserve], "calls_rate_max" => 10_001}, "calls_rate_max"},
            {%{"calls" => [@reserve], "calls_rate_ms" => 0}, "calls_rate_ms"},
            {%{"calls" => [@reserve], "calls_max_bytes" => 255}, "calls_max_bytes"}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => ^field}} =
                 CallsOptions.start(options, ["calls"])
      end

      assert {:ok, parsed} = CallsOptions.start(%{"calls" => [@reserve]}, ["calls"])

      assert CallsOptions.echo(parsed) == %{
               "functions" => [@reserve],
               "results" => "exceptions",
               "max" => 100,
               "rate_max" => 50,
               "rate_ms" => 1_000,
               "max_bytes" => 1_024,
               "writes" => []
             }

      assert CallsOptions.collector_options(parsed) == [
               functions: [{@reserve_mfa, @reserve}],
               results: :exceptions,
               max_calls: 100,
               rate: {50, 1_000},
               max_bytes: 1_024,
               writes: []
             ]

      assert {:error, %{"code" => "invalid_options", "field" => "calls"}} =
               Live.start(%{"components" => ["logger"], "calls" => [@reserve]})
    end
  end

  if @otp_28? do
    describe "on OTP 28 and later" do
      test "the session owns the trace: calls and failures with the failing arguments, capped and masked, in events, digest and status" do
        # The caller that starts the session exits at once; the trace stays.
        {:ok, started} =
          fn ->
            Live.start(%{
              "components" => ["calls"],
              "calls" => [@reserve],
              "calls_max_bytes" => 256,
              "disclosure" => "rich"
            })
          end
          |> Task.async()
          |> Task.await()

        id = started["session_id"]

        assert started["calls"] == %{
                 "functions" => [@reserve],
                 "results" => "exceptions",
                 "max" => 100,
                 "rate_max" => 50,
                 "rate_ms" => 1_000,
                 "max_bytes" => 256,
                 "writes" => []
               }

        assert CallsTarget.reserve(%{"apple" => 5}, "apple", 1) == 20

        fig = %{
          "fig" => 0,
          "password" => "hunter2-secret",
          "blob" => String.duplicate("x", 50_000)
        }

        assert_raise ArithmeticError, fn -> CallsTarget.reserve(fig, "fig", 1) end

        assert {:ok, batch} = Live.events_since(id, 0)
        events = Enum.map(batch["events"], & &1["event"])
        assert Enum.map(events, & &1["kind"]) == ["call", "call", "call.exception"]
        assert Enum.all?(events, &(&1["source"] == "calls"))
        [_ok, failed_call, failure] = events

        assert failure["severity"] == "error"
        assert failure["subject"]["value"] == failed_call["subject"]["value"]

        assert %{
                 "function" => @reserve,
                 "call_id" => 2,
                 "class" => "error",
                 "exception" => "ArithmeticError",
                 "duration_us" => duration
               } = failure["attributes"]

        assert is_integer(duration)
        encoded = Jason.encode!(failure["payload"]["arguments"])
        assert byte_size(encoded) <= 256
        assert encoded =~ "fig"
        refute Jason.encode!(batch) =~ "hunter2"
        assert failure["payload"]["reason"]["__struct__"] == "Elixir.ArithmeticError"
        assert batch["gaps"] == []

        assert {:ok, %{"events" => [_one]}} =
                 Live.events_since(id, 0, %{"view" => %{"kinds" => ["call.exception"]}})

        assert {:ok, digest} = Live.digest(id)

        assert %{
                 "functions" => [
                   %{
                     "function" => @reserve,
                     "calls" => 2,
                     "exceptions" => 1,
                     "failures" => [
                       %{"exception" => "ArithmeticError", "count" => 1, "first_receipt" => 3} =
                         first
                     ]
                   }
                 ],
                 "stopped" => []
               } = digest["calls"]

        assert Jason.encode!(first["arguments"]) =~ "fig"

        assert [
                 %{
                   "signature" =>
                     "call.exception InsiderTest.CallsTarget.reserve/3 ArithmeticError"
                 }
               ] =
                 digest["error_signatures"]

        assert {:ok, %{"text" => text}} = Live.digest(id, %{"human" => true})
        assert text =~ "Calls: #{@reserve} 2 calls, 0 returns, 1 exceptions"
        assert text =~ "1x ArithmeticError, first at receipt 3 with arguments"

        assert {:ok, status} = Live.status(id)
        assert status["calls"]["functions"] == [@reserve]
        assert insider_traced?(@reserve_mfa)

        assert {:ok, stopped} = Live.stop(id)
        receipt = stopped["receipt"]
        assert receipt["outcome"] == "stopped"
        assert receipt["cleanup"]["components"]["calls"] == "absent"

        assert receipt["cleanup"]["call_trace"] == %{
                 "session" => "removed",
                 "functions" => [@reserve],
                 "traced_after" => 0
               }

        refute insider_traced?(@reserve_mfa)
        assert_raise ArithmeticError, fn -> CallsTarget.reserve(fig, "fig", 1) end
        assert {:ok, %{"events" => after_stop}} = Live.events_since(id, 3)
        assert after_stop == []
      end

      test "the strict profile records which call failed and how, never its values" do
        {:ok, %{"session_id" => id}} =
          Live.start(%{
            "components" => ["calls"],
            "calls" => [@reserve],
            "calls_results" => "all",
            "disclosure" => "strict"
          })

        assert CallsTarget.reserve(%{"a" => 1}, "a", 1) == 100
        assert_raise ArithmeticError, fn -> CallsTarget.reserve(%{"a" => 0}, "a", 1) end

        assert {:ok, batch} = Live.events_since(id, 0)

        assert [
                 %{"kind" => "call", "payload" => nil},
                 %{"kind" => "call.return", "payload" => nil, "attributes" => %{"call_id" => 1}},
                 %{"kind" => "call", "payload" => nil},
                 %{"kind" => "call.exception", "payload" => nil, "attributes" => failure}
               ] = Enum.map(batch["events"], & &1["event"])

        assert %{"exception" => "ArithmeticError", "call_id" => 2} = failure
        assert Enum.all?(batch["events"], &(&1["redactions"] == []))
      end

      test "it never touches trace state it did not set: another session and node-global tracing keep tracing" do
        echo = {CallsTarget, :echo, 1}

        # Another tool's isolated session on the same function.
        other = :trace.session_create(:insider_calls_test_other, self(), [])
        1 = :trace.function(other, @reserve_mfa, true, [:local])
        tracee = spawn_link(fn -> tracee_loop() end)
        1 = :trace.process(other, tracee, true, [:call])

        # And node-global (legacy) tracing of another function and process.
        1 = :erlang.trace_pattern(echo, true, [:local])
        1 = :erlang.trace(tracee, true, [:call, {:tracer, self()}])

        on_exit(fn ->
          :erlang.trace_pattern(echo, false, [:local])
          :trace.session_destroy(other)
        end)

        {:ok, %{"session_id" => id}} =
          Live.start(%{
            "components" => ["calls"],
            "calls" => [@reserve, "InsiderTest.CallsTarget.echo/1"]
          })

        assert {:ok, _stopped} = Live.stop(id)

        send(tracee, {:run, fn -> CallsTarget.reserve(%{"a" => 1}, "a", 1) end})
        assert_receive {:trace, ^tracee, :call, {CallsTarget, :reserve, _args}}, 1_000
        send(tracee, {:run, fn -> CallsTarget.echo(:still_traced) end})
        assert_receive {:trace, ^tracee, :call, {CallsTarget, :echo, [:still_traced]}}, 1_000
        assert {:traced, :local} = :erlang.trace_info(echo, :traced)
      end

      test "calls_max stops new calls and still records the result of a call already running" do
        {:ok, %{"session_id" => id}} =
          Live.start(%{
            "components" => ["calls"],
            "calls" => [@reserve, "InsiderTest.CallsTarget.wait/1"],
            "calls_results" => "all",
            "calls_max" => 1
          })

        test = self()
        waiter = spawn(fn -> CallsTarget.wait(test) end)
        assert_receive {:waiting, ^waiter}
        assert CallsTarget.reserve(%{"a" => 1}, "a", 1) == 100

        assert {:ok, batch} = Live.events_since(id, 0)

        assert [
                 %{"kind" => "call", "attributes" => %{"call_id" => 1}},
                 %{"kind" => "call.stopped", "severity" => "warning", "attributes" => stop}
               ] = Enum.map(batch["events"], & &1["event"])

        assert %{
                 "reason" => "calls_max",
                 "calls" => 1,
                 "open" => 1,
                 "results_still_recorded" => true
               } =
                 stop

        refute insider_traced?(@reserve_mfa)
        monitor = Process.monitor(waiter)
        send(waiter, :release)
        assert_receive {:DOWN, ^monitor, :process, ^waiter, :normal}

        assert {:ok, %{"events" => [returned]}} = Live.events_since(id, 2)

        assert %{"kind" => "call.return", "attributes" => %{"call_id" => 1}} = returned["event"]
        assert returned["event"]["payload"]["result"] == "released"
      end

      test "more trace messages than calls_rate_max stop the whole trace and count the shed messages" do
        {:ok, %{"session_id" => id}} =
          Live.start(%{
            "components" => ["calls"],
            "calls" => [@reserve],
            "calls_results" => "none",
            "calls_rate_max" => 3,
            "calls_rate_ms" => 60_000
          })

        for _n <- 1..10, do: CallsTarget.reserve(%{"a" => 1}, "a", 1)

        assert {:ok, batch} = Live.events_since(id, 0)
        kinds = Enum.map(batch["events"], & &1["event"]["kind"])
        assert kinds == ["call", "call", "call", "call.stopped"]
        assert List.last(batch["events"])["event"]["attributes"]["reason"] == "calls_rate"
        assert [%{"reason" => "calls_shed", "count" => shed}] = batch["gaps"]
        assert shed >= 1
        refute insider_traced?(@reserve_mfa)

        assert {:ok, %{"receipt" => receipt}} = Live.stop(id)
        assert receipt["cleanup"]["call_trace"]["traced_after"] == 0
      end

      test "lease expiry removes the trace and the receipt proves it" do
        {:ok, %{"session_id" => id}} =
          Live.start(%{"components" => ["calls"], "calls" => [@reserve], "lease_ms" => 1_000})

        assert {:ok, _subscription} = Live.subscribe(id, self(), %{})
        assert insider_traced?(@reserve_mfa)

        assert_receive {:insider_live_events, ^id, %{"state" => "expired", "receipt" => receipt}},
                       5_000

        assert receipt["cleanup"]["call_trace"]["traced_after"] == 0
        refute insider_traced?(@reserve_mfa)
      end

      test "amend removes the replaced trace and installs the new one" do
        {:ok, %{"session_id" => id}} =
          Live.start(%{"components" => ["calls"], "calls" => [@reserve]})

        assert {:ok, amended} =
                 Live.amend(id, %{"calls" => ["InsiderTest.CallsTarget.echo/1"]})

        assert amended["amendment"]["changed"] == ["calls"]
        assert receipt = amended["amendment"]["receipt"]
        assert receipt["cleanup"]["call_trace"]["functions"] == [@reserve]
        assert receipt["cleanup"]["call_trace"]["traced_after"] == 0
        refute insider_traced?(@reserve_mfa)
        assert insider_traced?({CallsTarget, :echo, 1})

        assert {:ok, %{"amendment" => %{"receipt" => receipt}}} =
                 Live.amend(id, %{"components" => ["logger"]})

        assert receipt["cleanup"]["call_trace"]["traced_after"] == 0
        refute insider_traced?({CallsTarget, :echo, 1})
      end
    end

    defp tracee_loop do
      receive do
        {:run, fun} ->
          fun.()
          tracee_loop()
      end
    end

    # Whether an Insider call trace session traces `mfa`, by the runtime's own
    # session inventory.
    defp insider_traced?(mfa) do
      mfa |> :trace.session_info() |> List.wrap() |> Enum.any?(&match?({:insider_calls, _id}, &1))
    end
  else
    test "on OTP 27 the calls component is refused before anything starts" do
      assert {:error,
              %{
                "code" => "component_unavailable",
                "component" => "calls",
                "reason" => "requires_otp_28"
              }} = Live.start(%{"components" => ["calls"], "calls" => [@reserve]})

      assert Live.capabilities()["active_session_id"] == nil
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
