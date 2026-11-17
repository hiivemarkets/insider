defmodule InsiderTest.CrashLoop do
  @moduledoc false

  # A supervised GenServer that crashes on one request, as the shop's
  # Inventory does on fig.
  use GenServer

  def start_link(_argument), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, %{"apple" => 5, "fig" => 0}}

  @impl true
  def handle_call({:reserve, sku, qty}, _from, stock), do: {:reply, div(qty, stock[sku]), stock}
end

defmodule InsiderTest.Flood do
  @moduledoc false

  require Logger

  # One call site that logs the same error over and over.
  def run(count),
    do: for(index <- 1..count, do: Logger.error("checkout failed for order #{index}"))

  # A report flood, as `GenServer`'s unexpected-message reports are.
  def reports(count),
    do: for(index <- 1..count, do: Logger.error(%{unexpected: index, module: __MODULE__}))
end

defmodule Insider.Live.HintsLiveTest do
  # One collector session is global per node, so this module cannot run in
  # parallel with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias InsiderTest.CrashLoop

  @function "InsiderTest.CrashLoop.handle_call/3"
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

  defp crash(times) do
    capture_log(fn ->
      for _crash <- 1..times do
        crashing = Process.whereis(CrashLoop)
        catch_exit(GenServer.call(CrashLoop, {:reserve, "fig", 1}))
        assert_eventually(fn -> Process.whereis(CrashLoop) not in [nil, crashing] end)
      end
    end)
  end

  defp hint(hints, kind), do: Enum.find(hints, &(&1["kind"] == kind))

  # A digest without "since" covers the last minute, and its Next: lines
  # say so with the receipts the hint was worked out over.
  defp next(%{
         "window" => %{"since" => "latest-60s", "first_receipt" => first, "last_receipt" => last}
       }),
       do: "Next (receipts #{first}-#{last}, the last 60 s): "

  test "a crash loop's digest and events name the call to trace, and applying the hint records the failing call" do
    assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

    start_supervised!(%{
      id: :insider_hints_crash_loop,
      start:
        {Supervisor, :start_link, [[CrashLoop], [strategy: :one_for_one, max_restarts: 100]]},
      type: :supervisor
    })

    crash(2)

    assert {:ok, digest} = Live.digest(id, %{"human" => true})
    assert [%{"offender" => "InsiderTest.CrashLoop", "restarts" => 2}] = digest["crash_loops"]
    assert [%{"function" => @function}] = digest["call_candidates"]

    # The events that show the crash carry the same hint.
    assert {:ok, %{"hints" => batch_hints}} = Live.events_since(id, 0, %{"limit" => 500})

    if @otp_28? do
      hint = hint(digest["hints"], "trace_calls")

      assert %{
               "command" => "mix insider.live amend \"${N[@]}\" --session " <> _rest,
               "options" => %{
                 "components" => ["logger", "calls"],
                 "calls" => [@function],
                 "calls_results" => "exceptions"
               }
             } = hint

      assert digest["text"] =~ "#{next(hint)}#{hint["reason"]}: #{hint["command"]}"
      assert hint(batch_hints, "trace_calls")["options"] == hint["options"]

      # Applying it records the next crash's call with its arguments and
      # exception, read as the welcome's crash recipe reads it: from the
      # amendment's marker receipt ("latest" is empty).
      assert {:ok, %{"amendment" => %{"marker_receipt" => marker}}} =
               Live.amend(id, hint["options"])

      crash(1)

      assert {:ok, %{"events" => [failure | _rest]}} =
               Live.events_since(id, marker, %{"view" => %{"kinds" => ["call.exception"]}})

      assert %{"function" => @function, "exception" => "ArithmeticError"} =
               failure["event"]["attributes"]

      assert Jason.encode!(failure["event"]["payload"]) =~ "fig"

      # Once traced, the digest no longer suggests it.
      assert {:ok, again} = Live.digest(id)
      assert hint(again["hints"], "trace_calls") == nil
    else
      hint = hint(digest["hints"], "trace_calls_unavailable")
      assert hint["manual"] == ":recon_trace.calls({InsiderTest.CrashLoop, :handle_call, 3}, 10)"
      assert hint["command"] == nil
      assert hint(batch_hints, "trace_calls_unavailable")["manual"] == hint["manual"]
    end
  end

  test "a Logger flood's digest names the evicting source, and applying the hint stops the eviction" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "max_events" => 64})

    capture_log(fn -> InsiderTest.Flood.run(300) end)

    assert {:ok, digest} = Live.digest(id, %{"human" => true})
    assert [%{"reason" => "evicted"} | _rest] = digest["gaps"]
    reduce = hint(digest["hints"], "reduce_logger")

    assert %{
             "command" => "mix insider.live amend \"${N[@]}\" --session " <> _rest,
             "options" => %{"logger_summaries" => [%{"module" => "InsiderTest.Flood"}]},
             "evidence" =>
               %{"source" => "logger", "origin" => "module:InsiderTest.Flood"} = evidence
           } = reduce

    assert evidence["evicted"] > 0 and evidence["retained_events"] >= evidence["reserved_events"]
    assert reduce["command"] =~ "--logger-summary 'module:InsiderTest.Flood'"

    assert %{"options" => %{"max_events" => 4_096}} = hint(digest["hints"], "raise_capacity")
    assert digest["text"] =~ "#{next(reduce)}#{reduce["reason"]}: #{reduce["command"]}"

    # Applying it: the same flood is summarised, not recorded, and evicts
    # nothing.
    assert {:ok, _amended} = Live.amend(id, reduce["options"])
    capture_log(fn -> InsiderTest.Flood.run(300) end)
    assert {:ok, %{"next_cursor" => from}} = Live.events_since(id, "latest")

    assert {:ok, %{"recorder" => %{"sources" => %{"logger" => %{"evicted" => 0}}}}} =
             Live.status(id)

    assert {:ok, after_amendment} = Live.digest(id, %{"since" => max(from - 5, 0)})
    assert hint(after_amendment["hints"], "reduce_logger") == nil
    assert {:ok, batch} = Live.events_since(id, max(from - 5, 0))
    assert batch["filtered"]["logger"]["summarized"] >= 300
  end

  # Reports are recorded whatever the summary rules,
  # so a report flood gets no summary rule, and a mixed flood's summary
  # reduces its messages while its reports are still recorded.
  test "a report flood gets no summary rule; a mixed flood's rule summarises only its messages" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "max_events" => 64})

    capture_log(fn -> InsiderTest.Flood.reports(300) end)

    assert {:ok, digest} = Live.digest(id)
    assert hint(digest["hints"], "reduce_logger") == nil

    assert %{"command" => nil, "evidence" => %{"reports" => reports}} =
             hint(digest["hints"], "logger_reports")

    assert reports["logger_report"] > 0

    capture_log(fn ->
      InsiderTest.Flood.reports(150)
      InsiderTest.Flood.run(150)
    end)

    assert {:ok, mixed} = Live.digest(id)
    reduce = hint(mixed["hints"], "reduce_logger")
    assert %{"options" => %{"logger_summaries" => [%{"module" => "InsiderTest.Flood"}]}} = reduce

    assert {:ok, %{"amendment" => %{"marker_receipt" => marker}}} =
             Live.amend(id, reduce["options"])

    capture_log(fn ->
      InsiderTest.Flood.reports(20)
      InsiderTest.Flood.run(100)
    end)

    assert {:ok, batch} = Live.events_since(id, marker, %{"limit" => 500})
    kinds = Enum.frequencies_by(batch["events"], & &1["event"]["kind"])
    assert kinds["logger_report"] == 20
    # Only each burst's exemplar message is recorded in full.
    assert Map.get(kinds, "logger_message", 0) <= 1
    assert batch["filtered"]["logger"]["summarized"] >= 100
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
