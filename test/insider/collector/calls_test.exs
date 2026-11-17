defmodule InsiderTest.CollectorCallsTarget do
  @moduledoc false

  def run(value), do: value * 2

  def size(list) when is_list(list), do: length(list)
  def size(binary), do: byte_size(binary)

  # Returns a large shared binary.
  def blob(bytes), do: :binary.copy(<<7>>, bytes)

  # Returns a small sub-binary that keeps a large binary alive.
  def slice(bytes), do: binary_part(:binary.copy(<<8>>, bytes), 0, 65)

  # rec(n) catches the exception rec(0) raises n levels down.
  def rec(0), do: raise(ArithmeticError)

  def rec(n) do
    {:inner, rec(n - 1)}
  rescue
    ArithmeticError -> {:caught, n}
  end
end

defmodule Insider.Collector.CallsTest do
  # The call-trace collector on its own: option validation, the OTP 27
  # refusal at component boot, and, on OTP 28 and later, the trace session
  # it owns from start to removal. Each test checks its own trace session by
  # its weak reference; the collector-session tests take the node's one
  # global collector-session slot, so the module cannot run in parallel with
  # other session users.
  use ExUnit.Case, async: false

  alias Insider.Collector.Calls
  alias Insider.Collector.Calls.Tracing
  alias Insider.Collector.Session
  alias Insider.Recorder
  alias Insider.Runtime.HostPolicy
  alias InsiderTest.CollectorCallsTarget, as: Target

  @mfa {Target, :run, 1}
  @label "InsiderTest.CollectorCallsTarget.run/1"
  @otp_28? Tracing.preflight() == :ok

  defp recorder do
    {:ok, pid} = Recorder.start_link(classification: Insider.TestRecorderClassification.binding())
    {:ok, handle} = Recorder.handle(pid)
    handle
  end

  defp options(extra \\ []) do
    Keyword.merge(
      [
        authority: "calls-test",
        boot_id: "boot-test",
        clock_id: "calls-clock",
        environment: :test,
        functions: [{@mfa, @label}],
        results: :all,
        rich: true
      ],
      extra
    )
  end

  test "malformed options are refused before anything is traced" do
    handle = recorder()

    for options <- [
          Keyword.delete(options(), :functions),
          options(functions: []),
          options(functions: [{@mfa, ""}]),
          options(functions: [{{Target, :run, 256}, @label}]),
          options(functions: [:not_a_function]),
          options(results: :some),
          options(rate: {0, 1}),
          options(rate: :fast),
          options(max_calls: 0),
          options(rich: :yes),
          options(node: ""),
          options(unknown: 1),
          options(authority: String.duplicate("a", 129)),
          [{:authority, "a"} | options()]
        ] do
      assert {:error, :invalid_options} = Calls.start_link(handle, options)
    end

    assert {:error, :invalid_options} = Calls.start_link(:not_a_handle, options())

    assert {:error, :environment_denied} =
             Calls.start_link(handle, options(environment: :staging))

    assert {:error, :invalid_options} = Calls.start_link(handle, options(environment: :moon))
  end

  test "the trace session's pure parts: match specifications and absent backends" do
    assert Tracing.match_spec(:none) == [{:_, [], []}]
    assert Tracing.match_spec(:exceptions) == [{:_, [], [{:exception_trace}]}]
    assert Tracing.match_spec(:all) == Tracing.match_spec(:exceptions)

    # A watched write under strict sends its key, only when it is a short
    # name; anything else sends a fixed sentinel, never `false` (which would
    # suppress the call, and with it the limits), and copies no argument.
    [named, other] = Tracing.write_spec({Store, :set, 2}, :none)
    assert {[:"$1", :_], [_guard], [{:message, :"$1"}]} = named
    assert other == {:_, [], [{:message, {{:insider_unnamed_key}}}]}

    assert [{[:"$1", :"$2", :_], [_g], [{:message, {{:"$1", :"$2"}}}, {:exception_trace}]}, _] =
             Tracing.write_spec({Application, :put_env, 3}, :exceptions)

    spec = Tracing.write_spec({Store, :set, 2}, :none)

    assert {:ok, "review-flag", [], []} =
             :erlang.match_spec_test(["review-flag", true], spec, :trace)

    assert {:ok, {:insider_unnamed_key}, [], []} =
             :erlang.match_spec_test([String.duplicate("k", 200), 1], spec, :trace)

    assert {:ok, {:insider_unnamed_key}, [], []} =
             :erlang.match_spec_test([{:tuple, :key}, 1], spec, :trace)

    assert {:ok, :checkout, [], []} = :erlang.match_spec_test([:checkout, 1], spec, :trace)

    assert Tracing.remove(nil) == %{
             "session" => "not_installed",
             "functions" => 0,
             "traced_after" => 0
           }

    assert Tracing.patterns(nil) == 0
    assert Tracing.delivered(nil) == :error
    assert Tracing.traced_after({:insider_calls_never_created, -1}, [@mfa]) == 0
  end

  if @otp_28? do
    test "the collector owns one isolated trace session, records through it, and removes it provably" do
      handle = recorder()
      assert {:ok, pid} = Calls.start_link(handle, options())
      assert {:ok, %{weak: weak, functions: [@mfa]}} = Calls.inventory(pid)
      assert weak in :trace.session_info(:all)
      assert {:ok, %{traced: 1, functions: 1, calls: 0, stopped: 0}} = Calls.status(pid)

      assert Target.run(21) == 42
      assert {:ok, %{received: 2, recorded: 2, calls: 1, open: 0}} = Calls.flush(pid)
      assert {:ok, %{entries: entries}} = Recorder.read_since(handle, 0, limit: 10)
      assert Enum.map(entries, & &1.event["kind"]) == ["call", "call.return"]

      monitor = Process.monitor(pid)
      assert {:ok, %{status: %{recorded: 2}, trace: removal}} = Calls.stop(pid)
      assert removal == %{"session" => "removed", "functions" => 1, "traced_after" => 0}
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5000
      refute weak in :trace.session_info(:all)
      assert Tracing.traced_after(weak, [@mfa]) == 0
    end

    # At runtime: every message of a recursive call is
    # queued before the collector reads the first, which hits calls_max.
    test "queued recursive results after calls_max never pair with the accepted outer call" do
      handle = recorder()
      rec = {Target, :rec, 1}
      functions = [{rec, "InsiderTest.CollectorCallsTarget.rec/1"}]
      assert {:ok, pid} = Calls.start_link(handle, options(functions: functions, max_calls: 1))

      :ok = :sys.suspend(pid)
      assert Target.rec(2) == {:inner, {:caught, 1}}
      :ok = :sys.resume(pid)

      assert {:ok, %{calls: 1, recorded: 3}} = Calls.flush(pid)
      assert {:ok, %{entries: entries}} = Recorder.read_since(handle, 0, limit: 10)

      assert [
               %{"kind" => "call", "attributes" => %{"call_id" => 1}, "payload" => called},
               %{"kind" => "call.stopped", "attributes" => %{"reason" => "calls_max"}},
               %{"kind" => "call.return", "attributes" => %{"call_id" => 1}, "payload" => result}
             ] = Enum.map(entries, & &1.event)

      assert called["arguments"] == [2]
      assert result["result"] == "{:inner, {:caught, 1}}"
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    test "a strict trace copies no argument: a queued call holds only its arity" do
      handle = recorder()
      size = {Target, :size, 1}
      functions = [{size, "InsiderTest.CollectorCallsTarget.size/1"}]
      options = options(functions: functions, results: :none, rich: false)
      assert {:ok, pid} = Calls.start_link(handle, options)

      :ok = :sys.suspend(pid)
      assert Target.size(Enum.to_list(1..200_000)) == 200_000
      await(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end)
      {:memory, memory} = Process.info(pid, :memory)
      assert memory < 100_000
      :ok = :sys.resume(pid)

      assert {:ok, %{recorded: 1}} = Calls.flush(pid)
      assert {:ok, %{entries: [entry]}} = Recorder.read_since(handle, 0, limit: 10)
      assert %{"kind" => "call", "payload" => nil} = entry.event
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    # Shared binaries held by messages waiting in an
    # off-heap mailbox appear neither in the collector's memory nor in its
    # binary list. The inlet measures every message as it reads it.
    test "a queued shared binary argument stops the trace at its byte budget while the collector is suspended" do
      handle = recorder()
      size = {Target, :size, 1}
      functions = [{size, "InsiderTest.CollectorCallsTarget.size/1"}]
      options = options(functions: functions, results: :none, max_ingress_bytes: 8_000_000)
      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)
      assert Target.size(:binary.copy(<<1>>, 16 * 1_024 * 1_024)) == 16 * 1_024 * 1_024
      await(fn -> weak not in List.wrap(:trace.session_info(size)) end)
      :ok = :sys.resume(pid)

      assert {:ok, %{calls: 0, stopped: 1, shed: 1}} = Calls.flush(pid)
      assert {:ok, %{entries: [entry]}} = Recorder.read_since(handle, 0, limit: 10)

      assert %{"kind" => "call.stopped", "attributes" => %{"reason" => "ingress_bytes"}} =
               entry.event

      assert {:ok, %{trace: %{"traced_after" => 0}}} = Calls.stop(pid)
    end

    test "a strict trace's large binary result is bounded the same way" do
      handle = recorder()
      blob = {Target, :blob, 1}
      functions = [{blob, "InsiderTest.CollectorCallsTarget.blob/1"}]

      options =
        options(functions: functions, results: :all, rich: false, max_ingress_bytes: 8_000_000)

      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)
      assert byte_size(Target.blob(16 * 1_024 * 1_024)) == 16 * 1_024 * 1_024
      await(fn -> weak not in List.wrap(:trace.session_info(blob)) end)
      :ok = :sys.resume(pid)

      assert {:ok, %{calls: 1, stopped: 1, shed: 1}} = Calls.flush(pid)
      assert {:ok, %{entries: entries}} = Recorder.read_since(handle, 0, limit: 10)

      assert [
               %{"kind" => "call", "payload" => nil},
               %{"kind" => "call.stopped", "attributes" => %{"reason" => "ingress_bytes"}}
             ] = Enum.map(entries, & &1.event)

      assert {:ok, _stopped} = Calls.stop(pid)
    end

    # A helper process the collector started was
    # traced, and its own calls filled the trace.
    test "the collector and its inlet never trace themselves, even through a function they call" do
      handle = recorder()
      reduce = {Enum, :reduce, 3}
      functions = [{reduce, "Enum.reduce/3"}]

      options =
        options(functions: functions, results: :none, max_calls: 10_000, rate: {10_000, 1_000})

      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{inlet: inlet}} = Calls.inventory(pid)

      # Handling each traced call makes the collector call Enum.reduce/3.
      for n <- 1..5, do: Enum.reduce([n], 0, &+/2)
      assert {:ok, %{recorded: recorded}} = Calls.flush(pid)
      assert recorded >= 5
      assert {:ok, %{entries: entries}} = Recorder.read_since(handle, 0, limit: 1_000)

      own = for pid <- [pid, inlet], do: pid |> :erlang.pid_to_list() |> to_string()
      subjects = Enum.map(entries, &get_in(&1.event, ["subject", "value"]))
      assert Enum.filter(subjects, &(&1 in own)) == []
      assert to_string(:erlang.pid_to_list(self())) in subjects
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    # Flush and stop drained only to the inlet.
    test "flush drains through the inlet, and reports what a paused inlet still holds" do
      handle = recorder()
      assert {:ok, pid} = Calls.start_link(handle, options())
      assert {:ok, %{inlet: inlet}} = Calls.inventory(pid)
      # The inlet has read the backend the collector handed it.
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 0} end)

      :erlang.suspend_process(inlet)
      assert Target.run(1) == 2
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 2} end)
      assert {:ok, %{recorded: 0, inlet_pending: 2, undrained: 0}} = Calls.flush(pid)

      :erlang.resume_process(inlet)
      assert {:ok, %{recorded: 2, inlet_pending: 0}} = Calls.flush(pid)
      assert {:ok, %{status: %{undrained: 0}}} = Calls.stop(pid)
    end

    test "stop counts the messages a paused inlet never forwarded as undrained" do
      handle = recorder()
      assert {:ok, pid} = Calls.start_link(handle, options())
      assert {:ok, %{inlet: inlet}} = Calls.inventory(pid)
      # The inlet has read the backend the collector handed it.
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 0} end)

      :erlang.suspend_process(inlet)
      assert Target.run(1) == 2
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 2} end)

      assert {:ok, %{status: %{recorded: 0, undrained: 2}, trace: %{"traced_after" => 0}}} =
               Calls.stop(pid)

      assert {:ok, %{entries: []}} = Recorder.read_since(handle, 0, limit: 10)
    end

    # The inlet was paused after it took a message
    # from its mailbox and before it forwarded it; stop reported no loss.
    test "stop accounts for a message the inlet holds mid-admission" do
      handle = recorder()
      size = {Target, :size, 1}
      functions = [{size, "InsiderTest.CollectorCallsTarget.size/1"}]
      options = options(functions: functions, results: :none, max_ingress_bytes: 64_000_000)
      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{inlet: inlet}} = Calls.inventory(pid)
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 0} end)

      # Pause the inlet the moment it takes a message: a trace, in the inlet
      # only, of its "taken" count, which it makes before measuring. The
      # measuring that follows takes the inlet milliseconds.
      probe = :trace.session_create(:insider_calls_test_probe, self(), [])
      on_exit(fn -> :trace.session_destroy(probe) end)
      1 = :trace.function(probe, {:atomics, :add, 3}, [{[:_, 4, 1], [], []}], [:local])
      1 = :trace.process(probe, inlet, true, [:call])

      # This process reacts to the probe at high priority.
      Process.flag(:priority, :high)
      assert Target.size(Enum.to_list(1..5_000_000)) == 5_000_000
      assert_receive {:trace, ^inlet, :call, {:atomics, :add, [_ref, 4, 1]}}, 2_000
      :erlang.suspend_process(inlet)
      Process.flag(:priority, :normal)
      :trace.session_destroy(probe)

      # The window under test was reached: the inlet holds the message it
      # took, outside its receive loop, and the collector has not handled it
      # (`:sys.get_state/1` runs after anything already in its mailbox).
      refute Process.info(inlet, :current_function) ==
               {:current_function, {Calls, :inlet, 4}}

      %{ingress: ingress, handled: handled} = :sys.get_state(pid)
      assert :atomics.get(ingress, 4) - :atomics.get(ingress, 2) - handled == 1

      assert {:ok, %{status: status, trace: %{"traced_after" => 0}}} = Calls.stop(pid)
      assert {:ok, %{entries: []}} = Recorder.read_since(handle, 0, limit: 10)

      # The one call was in flight, so it is counted as lost, exactly.
      assert %{undrained: 1, undrained_unknown: 0, recorded: 0} = status
    end

    test "a stop that cannot prove the inlet's state reports its loss count as unknown" do
      handle = recorder()
      assert {:ok, pid} = Calls.start_link(handle, options())
      assert {:ok, %{inlet: inlet}} = Calls.inventory(pid)
      await(fn -> Process.info(inlet, :message_queue_len) == {:message_queue_len, 0} end)

      # Paused while idle: nothing in flight, but nothing proves it either.
      :erlang.suspend_process(inlet)
      assert {:ok, %{status: %{undrained: 0, undrained_unknown: 1}}} = Calls.stop(pid)
    end

    test "a stop whose drain completes reports exact zero loss" do
      assert {:ok, pid} = Calls.start_link(recorder(), options())
      assert Target.run(1) == 2

      assert {:ok, %{status: %{undrained: 0, undrained_unknown: 0, recorded: 2}}} =
               Calls.stop(pid)
    end

    # A small sub-binary keeps its whole backing
    # binary alive; a top-level binary argument or result is charged that.
    test "a sub-binary argument is charged the binary it keeps alive" do
      handle = recorder()
      size = {Target, :size, 1}
      functions = [{size, "InsiderTest.CollectorCallsTarget.size/1"}]
      options = options(functions: functions, results: :none, max_ingress_bytes: 8_000_000)
      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)
      assert Target.size(Target.slice(16 * 1_024 * 1_024)) == 65
      await(fn -> weak not in List.wrap(:trace.session_info(size)) end)
      :ok = :sys.resume(pid)

      assert {:ok, %{calls: 0, stopped: 1}} = Calls.flush(pid)
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    test "a strict sub-binary result is charged the binary it keeps alive" do
      handle = recorder()
      slice = {Target, :slice, 1}
      functions = [{slice, "InsiderTest.CollectorCallsTarget.slice/1"}]

      options =
        options(functions: functions, results: :all, rich: false, max_ingress_bytes: 8_000_000)

      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)
      assert byte_size(Target.slice(16 * 1_024 * 1_024)) == 65
      await(fn -> weak not in List.wrap(:trace.session_info(slice)) end)
      :ok = :sys.resume(pid)

      assert {:ok, %{calls: 1, stopped: 1}} = Calls.flush(pid)
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    test "an oversized argument stops the trace at its byte budget before the collector reads it" do
      handle = recorder()
      size = {Target, :size, 1}
      functions = [{size, "InsiderTest.CollectorCallsTarget.size/1"}]
      # 200,000 small integers measure about 1 MB.
      options = options(functions: functions, results: :none, max_ingress_bytes: 500_000)
      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)
      assert Target.size(Enum.to_list(1..200_000)) == 200_000
      # The valve removes the trace while the collector has read nothing.
      await(fn -> weak not in List.wrap(:trace.session_info(size)) end)
      assert Target.size([1]) == 1
      :ok = :sys.resume(pid)

      assert {:ok, %{received: 1, shed: 1, calls: 0, stopped: 1}} = Calls.flush(pid)
      assert {:ok, %{entries: [entry]}} = Recorder.read_since(handle, 0, limit: 10)

      assert %{"kind" => "call.stopped", "attributes" => %{"reason" => "ingress_bytes"}} =
               entry.event

      assert {:ok, %{trace: %{"traced_after" => 0}}} = Calls.stop(pid)
    end

    test "a burst of small calls stops the trace at its byte budget too" do
      handle = recorder()

      options =
        options(
          results: :none,
          max_calls: 10_000,
          rate: {10_000, 1_000},
          max_ingress_bytes: 20_000,
          max_waiting: 100_000
        )

      assert {:ok, pid} = Calls.start_link(handle, options)
      assert {:ok, %{weak: weak}} = Calls.inventory(pid)

      :ok = :sys.suspend(pid)

      Enum.reduce_while(1..10_000, :tracing, fn n, _state ->
        Target.run(n)

        if weak in List.wrap(:trace.session_info(@mfa)),
          do: {:cont, :tracing},
          else: {:halt, :stopped}
      end)

      refute weak in List.wrap(:trace.session_info(@mfa))
      :ok = :sys.resume(pid)

      # Only what fit the budget reached the collector.
      assert {:ok, %{calls: calls, stopped: 1}} = Calls.flush(pid)
      assert calls in 1..400
      assert {:ok, %{entries: entries}} = Recorder.read_since(handle, 0, limit: 1_000)
      assert %{"kind" => "call.stopped"} = stop = List.last(entries).event
      assert stop["attributes"]["reason"] == "ingress_bytes"
      assert {:ok, _stopped} = Calls.stop(pid)
    end

    test "a collector that is killed takes its inlet and its trace session with it" do
      handle = recorder()
      Process.flag(:trap_exit, true)
      assert {:ok, pid} = Calls.start_link(handle, options())
      assert {:ok, %{weak: weak, inlet: inlet}} = Calls.inventory(pid)
      monitor = Process.monitor(inlet)
      assert Tracing.traced_after(weak, [@mfa]) == 1
      refute_received {:DOWN, ^monitor, :process, ^inlet, _early}

      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}, 5000
      # The inlet is linked to the collector, and the session goes with the
      # last process that holds it. Signals from two senders are not ordered:
      # the link's exit can reach the inlet before this test's monitor, which
      # then reports `:noproc`; either way the inlet is gone.
      assert_receive {:DOWN, ^monitor, :process, ^inlet, reason}
                     when reason in [:killed, :noproc],
                     5000

      await(fn -> Tracing.traced_after(weak, [@mfa]) == 0 end)
    end

    test "a function that is no longer loaded is refused at install and leaves no trace session" do
      before = :trace.session_info(:all)
      options = options(functions: [{{:insider_calls_test_unloaded, :run, 0}, "x"}])
      assert {:error, :function_not_traceable} = Calls.start_link(recorder(), options)
      assert :trace.session_info(:all) -- before == []
    end

    test "a collector session proves in its receipt that the trace is gone" do
      {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
      session_options = session_options("calls-collector-session")

      {:ok, handle} = Session.start(host_policy, session_options)
      assert {:ok, %{"components" => %{"calls" => "running"}}} = Session.health(handle)
      assert Target.run(1) == 2

      assert {:ok, %{"calls" => %{"evidence" => "bounded_status", "calls" => 1}}} =
               Session.read_events(handle, 0)

      assert {:ok, %{"components" => %{"calls" => "absent"}}} = Session.seal_ingress(handle)
      assert {:ok, receipt} = Session.stop(handle)
      assert receipt["outcome"] == "stopped"

      assert receipt["cleanup"]["call_trace"] == %{
               "session" => "removed",
               "functions" => [@label],
               "traced_after" => 0
             }
    end

    # The inlet and the trace session act on their own; wait for an
    # explicit state, up to 5 s.
    defp await(predicate),
      do: Insider.Test.Eventually.await(predicate, 5_000, "expected state was not reached")
  else
    test "on OTP 27 the collector refuses at boot, and so does a collector session with it" do
      assert {:error, :requires_otp_28} = Calls.start_link(recorder(), options())

      {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
      assert {:error, _startup} = Session.start(host_policy, session_options("calls-otp27"))
    end
  end

  defp session_options(id) do
    [
      id: id,
      environment: :test,
      authority: "session-test",
      boot_id: "boot-test",
      clock_id: "session-clock",
      recorder_options: [classification: Insider.TestRecorderClassification.binding()],
      components: [:calls],
      calls_options: [functions: [{@mfa, @label}], results: :exceptions, rich: false]
    ]
  end
end
