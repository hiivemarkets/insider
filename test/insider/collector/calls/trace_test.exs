defmodule Insider.Collector.Calls.TraceTest do
  # The call trace's bookkeeping, fed the runtime's own trace message shapes,
  # so its limits, pairing and rendering hold on every OTP release.
  use ExUnit.Case, async: true

  alias Insider.Collector.Calls.Trace
  alias Insider.Event

  @mfa {__MODULE__, :reserve, 3}
  @label "Insider.Collector.Calls.TraceTest.reserve/3"
  @ms 1_000_000

  defp trace(options \\ []) do
    [
      functions: [{@mfa, @label}],
      results: :exceptions,
      max_calls: 100,
      rate: {100, 1_000},
      max_bytes: 512,
      rich: true
    ]
    |> Keyword.merge(options)
    |> Trace.new()
  end

  defp call(pid, args, ns), do: {:trace_ts, pid, :call, {__MODULE__, :reserve, args}, ns}
  defp returned(pid, value, ns), do: {:trace_ts, pid, :return_from, @mfa, value, ns}

  defp raised(pid, class, reason, ns),
    do: {:trace_ts, pid, :exception_from, @mfa, {class, reason}, ns}

  defp run(trace, messages) do
    Enum.reduce(messages, {trace, [], []}, fn message, {trace, records, actions} ->
      {trace, new, action} = Trace.handle(trace, message)
      {trace, records ++ new, if(action, do: actions ++ [action], else: actions)}
    end)
  end

  test "a failing call is paired with its call: call_id, duration, exception module and the arguments that failed" do
    pid = self()
    stock = %{"apple" => 5, "fig" => 0}

    {trace, records, []} =
      run(trace(), [
        call(pid, [stock, "apple", 1], 1 * @ms),
        returned(pid, 20, 2 * @ms),
        call(pid, [stock, "fig", 1], 3 * @ms),
        raised(pid, :error, :badarith, 5 * @ms)
      ])

    # Returns are not recorded with results: :exceptions; they only pair.
    assert Enum.map(records, & &1.kind) == ["call", "call", "call.exception"]
    [first, second, failure] = records

    assert first.attributes == %{"function" => @label, "call_id" => 1}
    assert first.payload["arguments"] == [%{"apple" => 5, "fig" => 0}, "apple", 1]
    assert second.attributes["call_id"] == 2

    assert failure.severity == :error
    assert failure.pid == pid

    assert failure.attributes == %{
             "function" => @label,
             "call_id" => 2,
             "duration_us" => 2_000,
             "class" => "error",
             "exception" => "ArithmeticError"
           }

    assert failure.payload["arguments"] == [%{"apple" => 5, "fig" => 0}, "fig", 1]
    assert failure.payload["reason"]["__struct__"] == "Elixir.ArithmeticError"

    assert %{received: 4, calls: 2, open: 0, shed: 0, invalid: 0, stopped: 0} =
             Trace.counts(trace)
  end

  test "results all records returns; none keeps no frames; exits and throws have no exception module" do
    pid = self()

    {_trace, records, []} =
      run(trace(results: :all), [
        call(pid, [%{}, "a", 1], 0),
        returned(pid, {:ok, 3}, 7_000),
        call(pid, [%{}, "b", 1], 8_000),
        raised(pid, :exit, :shutdown, 9_000),
        call(pid, [%{}, "c", 1], 10_000),
        raised(pid, :throw, :done, 11_000)
      ])

    assert [
             %{kind: "call"},
             %{kind: "call.return", attributes: returned, payload: %{"result" => "{:ok, 3}"}},
             %{kind: "call"},
             %{kind: "call.exception", attributes: exited},
             %{kind: "call"},
             %{kind: "call.exception", attributes: thrown}
           ] = records

    assert returned == %{"function" => @label, "call_id" => 1, "duration_us" => 7}
    assert %{"class" => "exit", "exception" => nil, "call_id" => 2} = exited
    assert %{"class" => "throw", "exception" => nil, "call_id" => 3} = thrown

    {trace, records, []} = run(trace(results: :none), [call(pid, [%{}, "a", 1], 0)])
    assert [%{kind: "call"}] = records
    assert Trace.counts(trace).open == 0
  end

  test "nested calls pair innermost first; a result without its call's frame is shed" do
    pid = self()

    {trace, records, []} =
      run(trace(results: :all), [
        call(pid, [%{}, "outer", 1], 0),
        call(pid, [%{}, "inner", 1], 1_000),
        returned(pid, :inner, 2_000),
        returned(pid, :outer, 4_000),
        returned(spawn(fn -> :ok end), :orphan, 5_000)
      ])

    returns =
      for %{kind: "call.return", attributes: a} <- records, do: {a["call_id"], a["duration_us"]}

    assert returns == [{2, 1}, {1, 4}]
    assert %{shed: 1, open: 0} = Trace.counts(trace)
  end

  test "every frame waits so pairing stays exact; only open_max frames keep their arguments" do
    pid = self()
    calls = for n <- 1..(Trace.open_max() + 1), do: call(pid, [%{}, "x", n], n)
    {trace, _records, []} = run(trace(max_calls: 10_000, rate: {10_000, 1_000}), calls)
    assert Trace.counts(trace).open == Trace.open_max() + 1

    {trace, [failure], nil} = Trace.handle(trace, raised(pid, :error, :badarith, 10_000))
    assert failure.attributes["call_id"] == Trace.open_max() + 1
    assert failure.payload["arguments"] == nil
    assert failure.attributes["arguments_omitted"] == "open_frames_limit"

    {_trace, [failure], nil} = Trace.handle(trace, raised(pid, :error, :badarith, 10_001))
    assert failure.attributes["call_id"] == Trace.open_max()
    assert failure.payload["arguments"] == [%{}, "x", Trace.open_max()]
    refute Map.has_key?(failure.attributes, "arguments_omitted")
  end

  test "calls_max stops new calls but still records the results of calls already running" do
    pid = self()
    other = spawn(fn -> :ok end)

    {trace, records, actions} =
      run(trace(max_calls: 2), [
        call(pid, [%{}, "a", 1], 1),
        call(other, [%{}, "b", 1], 2),
        call(pid, [%{}, "late", 1], 3),
        raised(other, :error, :badarith, 4)
      ])

    assert actions == [:stop_calls]
    assert Enum.map(records, & &1.kind) == ["call", "call", "call.stopped", "call.exception"]
    stopped = Enum.find(records, &(&1.kind == "call.stopped"))

    assert %{
             "reason" => "calls_max",
             "calls" => 2,
             "calls_max" => 2,
             "open" => 2,
             "results_still_recorded" => true
           } = stopped.attributes

    assert stopped.severity == :warning
    assert List.last(records).attributes["call_id"] == 2
    # The late call is shed but keeps its place on its process's stack.
    assert %{shed: 1, calls: 2, stopped: 1, open: 2} = Trace.counts(trace)
  end

  test "more trace messages than the rate allows stop everything; later windows start over" do
    pid = self()
    within = for n <- 1..3, do: call(pid, [%{}, "a", n], n * @ms)
    later = for n <- 1..3, do: call(pid, [%{}, "b", n], 2_000 * @ms + n * @ms)

    {trace, records, []} = run(trace(rate: {3, 1_000}, results: :none), within ++ later)
    assert [_, _, _, _, _, _] = records
    assert Trace.counts(trace).stopped == 0

    {trace, records, actions} =
      run(trace, [call(pid, [%{}, "c", 1], 2_010 * @ms), returned(pid, 1, 2_011 * @ms)])

    assert actions == [:stop_all]

    assert [%{kind: "call.stopped", attributes: %{"reason" => "calls_rate", "rate_max" => 3}}] =
             records

    assert %{shed: 2, stopped: 1, calls: 6} = Trace.counts(trace)
  end

  # A recursive call shed after calls_max took the
  # accepted outer call's frame, so the inner result was paired with it.
  test "results of recursive calls shed after calls_max never pair with the accepted outer call" do
    pid = self()

    {trace, records, [:stop_calls]} =
      run(trace(max_calls: 1, results: :all), [
        call(pid, [%{}, "outer", 2], 1_000),
        call(pid, [%{}, "inner", 1], 2_000),
        call(pid, [%{}, "innermost", 0], 2_500),
        raised(pid, :error, :badarith, 3_000),
        returned(pid, {:caught, 1}, 4_000),
        returned(pid, {:outer, 2}, 9_000)
      ])

    assert [
             %{kind: "call", attributes: %{"call_id" => 1}},
             %{kind: "call.stopped"},
             %{kind: "call.return", attributes: returned, payload: %{"result" => result}}
           ] = records

    assert returned == %{"function" => @label, "call_id" => 1, "duration_us" => 8}
    assert result == "{:outer, 2}"
    assert %{shed: 4, open: 0} = Trace.counts(trace)
  end

  test "a result that does not match the frame on top of its stack stops the trace rather than guess" do
    other = {__MODULE__, :other, 1}
    trace = trace(functions: [{@mfa, @label}, {other, "other/1"}])
    pid = self()

    {trace, records, [:stop_all]} =
      run(trace, [
        call(pid, [%{}, "a", 1], 1),
        {:trace_ts, pid, :return_from, other, :ok, 2},
        raised(pid, :error, :badarith, 3)
      ])

    assert [%{kind: "call"}, %{kind: "call.stopped", attributes: %{"reason" => "pairing_lost"}}] =
             records

    assert %{shed: 2, stopped: 1} = Trace.counts(trace)
  end

  test "beyond frames_max waiting frames pairing stops, failing closed" do
    pid = self()
    max = Trace.frames_max()
    calls = for n <- 1..(max + 1), do: call(pid, [%{}, "x", n], n * 1_000_000)

    {trace, records, actions} =
      run(trace(max_calls: 10_000, rate: {10_000, 1_000}, rich: false), calls)

    assert actions == [:stop_calls, :stop_all]

    assert %{kind: "call.stopped", attributes: %{"reason" => "pairing_limit"}} =
             List.last(records)

    assert %{calls: 10_000, open: ^max, stopped: 1} = Trace.counts(trace)
  end

  test "a strict call message carries only the arity and still pairs" do
    pid = self()

    {_trace, [call, failure], []} =
      run(trace(rich: false), [
        {:trace_ts, pid, :call, {__MODULE__, :reserve, 3}, 1_000},
        raised(pid, :error, :badarith, 3_000)
      ])

    assert %{kind: "call", payload: nil, attributes: %{"call_id" => 1}} = call

    assert %{payload: nil, attributes: %{"call_id" => 1, "exception" => "ArithmeticError"}} =
             failure

    refute Map.has_key?(failure.attributes, "arguments_omitted")

    assert {_trace, [], nil} =
             Trace.handle(trace(), {:trace_ts, pid, :call, {__MODULE__, :reserve, 4}, 1})
  end

  test "a result over the rate stops everything, as a call over it does" do
    pid = self()

    {trace, records, actions} =
      run(trace(rate: {1, 1_000}), [
        call(pid, [%{}, "a", 1], 1),
        raised(pid, :error, :badarith, 2)
      ])

    assert actions == [:stop_all]

    assert [%{kind: "call"}, %{kind: "call.stopped", attributes: %{"reason" => "calls_rate"}}] =
             records

    assert Trace.counts(trace).stopped == 1
  end

  test "an exception value that is no class and reason pair is an unknown class" do
    pid = self()

    {_trace, [_call, failure], []} =
      run(trace(), [call(pid, [%{}, "a", 1], 1), {:trace_ts, pid, :exception_from, @mfa, :odd, 2}])

    assert %{"class" => "unknown", "exception" => nil, "call_id" => 1} = failure.attributes
    assert failure.payload["reason"] == "odd"
  end

  test "past frames_max waiting frames an accepted call stops the trace and is still recorded" do
    pid = self()
    max = Trace.frames_max()
    calls = for n <- 1..(max + 1), do: call(pid, [%{}, "x", n], n * 1_000)

    {trace, records, actions} =
      run(trace(max_calls: max + 10, rate: {max + 10, 1_000_000}, rich: false), calls)

    assert actions == [:stop_all]
    assert [%{kind: "call", attributes: %{"call_id" => last}}, stopped] = Enum.take(records, -2)
    assert last == max + 1
    assert %{kind: "call.stopped", attributes: %{"reason" => "pairing_limit"}} = stopped
    assert %{calls: calls, open: ^max, stopped: 1} = Trace.counts(trace)
    assert calls == max + 1
  end

  test "an overload stops everything once" do
    {trace, [stopped], :stop_all} = Trace.overload(trace(), 5)
    assert stopped.attributes["reason"] == "overload"
    {_trace, [bytes], :stop_all} = Trace.overload(trace(), 5, "ingress_bytes")
    assert bytes.attributes["reason"] == "ingress_bytes"
    assert {^trace, [], nil} = Trace.overload(trace, 6)
    {trace, [], nil} = Trace.handle(trace, call(self(), [%{}, "a", 1], 7))
    assert Trace.counts(trace).shed == 1
  end

  test "unknown functions and malformed messages are invalid, never recorded" do
    {trace, [], nil} = Trace.handle(trace(), {:trace_ts, self(), :call, {Enum, :at, [[], 0]}, 1})

    {trace, [], nil} =
      Trace.handle(trace, {:trace_ts, self(), :return_from, {Enum, :at, 2}, 1, 2})

    {trace, [], nil} = Trace.handle(trace, {:trace_delivered, :all, make_ref()})
    assert %{invalid: 3, received: 3, calls: 0} = Trace.counts(trace)
  end

  test "values are capped and credentials masked in rich; strict renders nothing" do
    pid = self()
    secret = %{"password" => "hunter2-very-secret", "blob" => String.duplicate("x", 100_000)}

    {_trace, [record], nil} =
      Trace.handle(trace(max_bytes: 256), call(pid, [secret, "fig", 1], 1))

    encoded = Jason.encode!(record.payload["arguments"])
    assert byte_size(encoded) <= 256
    refute encoded =~ "hunter2"
    assert encoded =~ "REDACTED"

    {_trace, [strict, failure], nil} =
      run(trace(rich: false), [
        call(pid, [secret, "fig", 1], 1),
        raised(pid, :error, :badarith, 2)
      ])
      |> then(fn {trace, records, _actions} -> {trace, records, nil} end)

    assert strict.payload == nil
    assert failure.payload == nil
    assert failure.attributes["exception"] == "ArithmeticError"
  end

  test "each record is an insider.event/v1; a payload too large for an event is withheld and says so" do
    context = %{
      node: "node@host",
      boot_id: "boot",
      clock_id: "insider-live-monotonic-us",
      authority: "insider-live",
      source_instance_id: "calls-test",
      sequence: 7,
      offset_ns: System.os_time(:nanosecond) - System.monotonic_time(:nanosecond)
    }

    ns = System.monotonic_time(:nanosecond)
    {_trace, [record], nil} = Trace.handle(trace(), call(self(), [%{}, "a", 1], ns))

    assert {:ok, %Event{} = event} = Trace.event(record, context)
    assert %{source: "calls", kind: "call", source_sequence: 7, id: "calls-test-7"} = event
    assert event.subject["namespace"] == "process"
    assert abs(DateTime.diff(event.wall_time, DateTime.utc_now(), :second)) < 5

    huge = %{record | payload: %{"arguments" => [String.duplicate("y", 20_000)]}}
    assert {:ok, withheld} = Trace.event(huge, context)
    assert withheld.payload == nil
    assert withheld.attributes["payload_withheld"] == true

    stopped = %{record | kind: "call.stopped", pid: nil, payload: nil}
    assert {:ok, %Event{subject: nil}} = Trace.event(stopped, context)

    # Without a payload to withhold, an event that does not fit is the error.
    assert {:error, _unfit} = Trace.event(%{stopped | kind: "Not A Kind"}, context)
    assert {:error, _unfit} = Trace.event(%{huge | kind: "Not A Kind"}, context)
  end

  describe "watched writes" do
    @set {__MODULE__, :set, 2}
    @put_env {Application, :put_env, 3}

    defp writes(rich) do
      Trace.new(
        functions: [{@set, "Store.set/2"}, {@put_env, "Application.put_env/3"}],
        writes: [@set, @put_env],
        results: :none,
        max_calls: 100,
        rate: {100, 1_000},
        max_bytes: 512,
        rich: rich
      )
    end

    test "a write records its key, under rich with the value as arguments" do
      {_trace, [record], nil} =
        Trace.handle(
          writes(true),
          {:trace_ts, self(), :call, {__MODULE__, :set, ["review-flag", true]}, 1}
        )

      assert %{"function" => "Store.set/2", "write" => true, "key" => "review-flag"} =
               record.attributes

      assert record.payload["arguments"] == ["review-flag", true]

      {_trace, [env], nil} =
        Trace.handle(
          writes(true),
          {:trace_ts, self(), :call, {Application, :put_env, [:shop, :checkout, "on"]}, 1}
        )

      assert env.attributes["key"] == "shop checkout"
    end

    # Strict traces with the arity flag; the write's match spec sends only
    # its key, and only when it is a short name.
    test "under strict the key arrives as the match spec's message, and nothing else" do
      {_trace, [record], nil} =
        Trace.handle(
          writes(false),
          {:trace_ts, self(), :call, {__MODULE__, :set, 2}, "review-flag", 1}
        )

      assert %{"write" => true, "key" => "review-flag"} = record.attributes
      assert record.payload == nil

      {_trace, [unnamed], nil} =
        Trace.handle(
          writes(false),
          {:trace_ts, self(), :call, {__MODULE__, :set, 2}, {:insider_unnamed_key}, 1}
        )

      assert unnamed.attributes["key"] == nil

      {_trace, [pair], nil} =
        Trace.handle(
          writes(false),
          {:trace_ts, self(), :call, {Application, :put_env, 3}, {:shop, :checkout}, 1}
        )

      assert pair.attributes["key"] == "shop checkout"
    end

    test "a credential-shaped or long key is masked or withheld" do
      token = "ghp_" <> String.duplicate("A1b2C3d4E5", 4)

      {_trace, [masked], nil} =
        Trace.handle(writes(true), {:trace_ts, self(), :call, {__MODULE__, :set, [token, 1]}, 1})

      refute masked.attributes["key"] =~ "A1b2C3"

      {_trace, [long], nil} =
        Trace.handle(
          writes(true),
          {:trace_ts, self(), :call, {__MODULE__, :set, [String.duplicate("k", 200), 1]}, 1}
        )

      assert long.attributes["key"] == nil
    end

    # The watcher knows the key, so a credential-named key's
    # value never reaches the record, its exception, or its JSON.
    test "the value written under a credential-named key, or a secret-shaped value, is masked with its length only" do
      secret = "review-short-password"
      token = "ghp_" <> String.duplicate("A1b2C3d4E5", 4)

      cases = [
        {{__MODULE__, :set, [:password, secret]}, ["password", "[masked: 21 bytes]"]},
        # A term is measured as its external size.
        {{__MODULE__, :set, ["api_token", %{"nested" => secret}]},
         ["api_token", "[masked: #{:erlang.external_size(%{"nested" => secret})} bytes]"]},
        {{Application, :put_env, [:shop, :secret_key_base, secret]},
         ["shop", "secret_key_base", "[masked: 21 bytes]"]},
        {{__MODULE__, :set, [:flag, token]}, ["flag", "[masked: 44 bytes]"]}
      ]

      for {call, arguments} <- cases do
        {_trace, [record], nil} = Trace.handle(writes(true), {:trace_ts, self(), :call, call, 1})
        assert record.payload["arguments"] == arguments
        refute inspect(record, limit: :infinity) =~ secret
        refute inspect(record, limit: :infinity) =~ "A1b2C3"
      end

      # A failing write's exception carries the same masked arguments.
      trace =
        Trace.new(
          functions: [{@set, "Store.set/2"}],
          writes: [@set],
          results: :exceptions,
          max_calls: 100,
          rate: {100, 1_000},
          max_bytes: 512,
          rich: true
        )

      {trace, [_call], nil} =
        Trace.handle(
          trace,
          {:trace_ts, self(), :call, {__MODULE__, :set, [:password, secret]}, 1}
        )

      {_trace, [failed], nil} =
        Trace.handle(
          trace,
          {:trace_ts, self(), :exception_from, @set, {:error, :badarg}, 2}
        )

      assert failed.kind == "call.exception"
      assert failed.payload["arguments"] == ["password", "[masked: 21 bytes]"]
      refute inspect(failed, limit: :infinity) =~ secret
    end
  end
end
