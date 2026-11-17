defmodule Insider.Live.GatesTest do
  # The gate keeper and the live owner are node-global, so this module cannot
  # run in parallel with other session users.
  use ExUnit.Case, async: false

  alias Insider.Collector.Gate
  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Gates

  @spec_template %{
    logger: %{
      level: :warning,
      include: nil,
      exclude: nil,
      summary: nil,
      summary_interval_ms: 1_000
    },
    origin: nil,
    telemetry: [
      %{name: [:gates_test, :event], kind: "gates_test.event", min_duration_ms: 0, summary: true}
    ],
    summary_interval_ms: 1_000
  }

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
      assert_eventually(fn -> Gates.count() == 0 end)
    end)
  end

  test "a killed owner's gate is reclaimed when the supervisor restarts the owner" do
    assert {:ok, %{"session_id" => _id}} = Live.start(%{"components" => ["logger"]})
    assert [_gate] = gate_keys()

    owner = Process.whereis(Insider.Live.Owner)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    # The restarted owner knows no session and reclaims what the old one held.
    _restarted = await_owner_restart(owner)
    assert gate_keys() == []
    assert Gates.count() == 0
  end

  test "a gate whose creator dies before using it, as in an interrupted start, is reclaimed" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, key} = Gates.create(@spec_template)
        send(parent, {:created, key})
      end)

    monitor = Process.monitor(creator)
    assert_receive {:created, key}
    assert_receive {:DOWN, ^monitor, :process, ^creator, :normal}

    assert Gates.count() == 0
    assert :persistent_term.get(key, :gone) == :gone
  end

  # One keeper crash covers every keeper-restart path, because each restart
  # counts against `Insider.Supervisor`'s restart intensity.
  test "after a keeper crash, live gates and summaries survive and nothing else is left" do
    owner = Process.whereis(Insider.Live.Owner)

    # The active session's summarizing gate.
    id = summarized_session()
    assert {:ok, _subscription} = Live.subscribe(id, self())
    query(4)
    [{session_gate, ^owner}] = Gate.all()

    # A gate of another live creator, and one whose creator will die.
    {:ok, kept} = Gates.create(@spec_template)
    parent = self()

    orphan_creator =
      spawn(fn ->
        {:ok, key} = Gates.create(@spec_template)
        send(parent, {:created, key})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:created, orphan}

    # A summarizing gate created for the owner that the owner never learns
    # of: what a keeper crash between creation and its reply leaves behind.
    :sys.replace_state(owner, fn state ->
      {:ok, _key} = Gates.create(@spec_template)
      state
    end)

    [unacknowledged] = for {key, ^owner} <- Gate.all(), key != session_gate, do: key
    unacknowledged_table = Gate.table(unacknowledged)
    assert :ets.info(unacknowledged_table, :owner) == Process.whereis(Gates)

    keeper = Process.whereis(Gates)
    keeper_monitor = Process.monitor(keeper)
    creator_monitor = Process.monitor(orphan_creator)
    Process.exit(keeper, :kill)
    assert_receive {:DOWN, ^keeper_monitor, :process, ^keeper, :killed}
    send(orphan_creator, :exit)
    assert_receive {:DOWN, ^creator_monitor, :process, ^orphan_creator, :normal}

    assert_eventually(fn ->
      is_pid(Process.whereis(Gates)) and Process.whereis(Gates) != keeper
    end)

    # The owner inherited both tables when the keeper died; a call queued
    # after the transfers shows it kept the session's and deleted the other.
    _capabilities = Live.capabilities()
    assert :ets.info(unacknowledged_table) == :undefined
    assert :ets.info(Gate.table(session_gate), :owner) == owner

    # The restarted keeper adopted the live creators' gates only.
    assert Gates.count() in [2, 3]
    assert %{owner: ^parent} = :persistent_term.get(kept)
    assert :persistent_term.get(orphan, :gone) == :gone

    # Summaries kept working across the crash.
    query(6)
    assert {:ok, %{"state" => "running"}} = Live.status(id)
    assert {:ok, _stopped} = Live.stop(id)
    {final, summaries} = await_terminal(id)
    assert final["gaps"] == []
    assert [%{"count" => 2, "duration_max_us" => 6_000}] = summaries

    # The next start's exclusive creation leaves the owner only its new gate.
    assert {:ok, %{"session_id" => next}} = Live.start(%{"components" => ["logger"]})
    assert [_current] = for({key, ^owner} <- Gate.all(), do: key)
    assert {:ok, _stopped} = Live.stop(next)
    assert :persistent_term.get(unacknowledged, :gone) == :gone
    assert :persistent_term.get(session_gate, :gone) == :gone

    assert :ok = Gates.release(kept)
    assert Gate.all() == []
  end

  test "the keeper holds a bounded number of gates" do
    keys = for _gate <- 1..Gates.max_gates(), do: elem(Gates.create(@spec_template), 1)
    assert {:error, :busy} = Gates.create(@spec_template)

    # A live start that cannot get a gate starts nothing.
    assert {:error, %{"code" => "busy"}} = Live.start(%{"components" => ["logger"]})
    assert :sys.get_state(Manager).active == nil

    for key <- keys, do: assert(:ok = Gates.release(key))
    assert :ok = Gates.release(hd(keys))
    assert {:error, :invalid} = Gates.create(:not_a_spec)

    # A declared duration scope is handler or caller, on a summarised event.
    [rule] = @spec_template.telemetry

    for scope <- ["server_callback", :handler],
        do: assert({:error, :invalid} = Gates.create(spec_with(%{rule | summary: true}, scope)))

    assert {:error, :invalid} = Gates.create(spec_with(%{rule | summary: false}, "handler"))
    assert {:ok, scoped} = Gates.create(spec_with(rule, "caller"))
    assert {[{"gates_test.event", _name, _slot, "caller"}], 1_000} = Gate.summaries(scoped)
    assert :ok = Gates.release(scoped)

    # An exclusive creation replaces the caller's earlier gates, as the live
    # owner's next start reclaims a gate whose release never arrived.
    {:ok, first} = Gates.create(@spec_template, 1_000, exclusive: true)
    {:ok, second} = Gates.create(@spec_template, 1_000, exclusive: true)
    assert Gates.count() == 1
    assert :persistent_term.get(first, :gone) == :gone
    assert :ok = Gates.release(second)
    assert :ok = Gates.reclaim()
  end

  test "a spec of any other shape is refused, and stray messages leave the keeper as it was" do
    template = @spec_template
    logger = template.logger
    matcher = %{domains: [], applications: %{}, modules: %{}}

    for invalid <- [
          Map.put(template, :otel, %{min_duration_ms: -1}),
          Map.put(template, :otel, :all),
          %{template | logger: :warning},
          %{template | logger: %{logger | level: :loud}},
          %{template | logger: %{logger | include: [:not, :a, :matcher]}},
          %{template | origin: %{oban_conf: "yes", modules: %{}}},
          %{template | origin: [Oban]},
          %{template | telemetry: [%{name: [:gates_test, :event]}]}
        ] do
      assert {:error, :invalid} = Gates.create(invalid), inspect(invalid)
    end

    for valid <- [
          Map.put(template, :otel, %{min_duration_ms: 0}),
          %{template | logger: %{logger | include: matcher, exclude: matcher, summary: matcher}},
          %{template | origin: %{oban_conf: true, modules: %{}}}
        ] do
      assert {:ok, key} = Gates.create(valid)
      assert :ok = Gates.release(key)
    end

    send(Gates, :stray)
    assert Gates.count() == 0
  end

  defp spec_with(rule, scope),
    do: %{@spec_template | telemetry: [Map.put(rule, :duration_scope, scope)]}

  test "a summary sample whose storage is gone is reported as a gap, not as summarized" do
    id = summarized_session()
    assert {:ok, %{"next_cursor" => 0}} = Live.events_since(id, 0)

    [{key, _owner}] = Gate.all()
    %{table: table} = :persistent_term.get(key)
    table_owner = :ets.info(table, :owner)
    :sys.replace_state(table_owner, fn state -> :ets.delete(table) && state end)

    query(4)
    query(5)

    assert {:ok, batch} = Live.events_since(id, 0)
    assert batch["filtered"]["telemetry"]["gates_test.query"]["summarized"] == 0

    assert %{"reason" => "telemetry_summary_lost", "count" => 2, "scope" => "since_session_start"} in batch[
             "gaps"
           ]
  end

  test "a start whose gate creation outlives its deadline leaves no gate behind" do
    keeper = Process.whereis(Gates)

    for _attempt <- 1..2 do
      :ok = :sys.suspend(keeper)
      started = Live.start(%{"components" => ["logger"]})
      :ok = :sys.resume(keeper)
      assert {:error, %{"code" => "timeout"}} = started
      assert Gates.count() == 0
      assert Gate.all() == []
    end

    assert {:ok, %{"session_id" => _id}} = Live.start(%{"components" => ["logger"]})
  end

  defp summarized_session do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["telemetry"],
               "telemetry_events" => [["gates_test", "query"]],
               "telemetry_summaries" => ["gates_test.query"],
               "telemetry_summary_interval_ms" => 60_000
             })

    id
  end

  defp query(milliseconds) do
    duration = System.convert_time_unit(milliseconds, :millisecond, :native)
    :telemetry.execute([:gates_test, :query], %{duration: duration}, %{})
  end

  defp await_terminal(id, summaries \\ []) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000

    summaries =
      summaries ++
        for entry <- batch["events"],
            entry["event"]["attributes"]["lifecycle_phase"] == "summary",
            do: entry["event"]["attributes"]["summary"]

    if batch["state"] == "running", do: await_terminal(id, summaries), else: {batch, summaries}
  end

  defp gate_keys, do: for({{Gate, _id} = key, _value} <- :persistent_term.get(), do: key)

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
