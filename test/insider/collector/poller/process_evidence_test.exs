defmodule Insider.Collector.Poller.ProcessEvidenceTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Poller
  alias Insider.Collector.Poller.Config
  alias Insider.Collector.Poller.Erlang, as: ErlangProvider
  alias Insider.Collector.Poller.Ets
  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Processes
  alias Insider.Collector.Poller.Ranking
  alias Insider.Event
  alias Insider.Policy.ProtectedTargets
  alias Insider.Recorder

  # Each VM sample waits for the test, so the test steps the poller one
  # cycle at a time: when cycle N's VM probe reports in, every event of
  # cycle N - 1 is recorded.
  @listener __MODULE__.Listener

  defmodule GatedProvider do
    @behaviour Insider.Collector.Poller.Provider

    alias Insider.Collector.Poller.Erlang

    @listener Insider.Collector.Poller.ProcessEvidenceTest.Listener

    @impl true
    def vm_sample do
      send(@listener, {:vm_probe, self()})

      receive do
        :continue -> Erlang.vm_sample()
      end
    end

    @impl true
    defdelegate process_sample(pid), to: Erlang

    @impl true
    defdelegate process_top(previous, options), to: Erlang

    @impl true
    defdelegate ets_top(options), to: Erlang
  end

  defmodule BlockingScanProvider do
    @behaviour Insider.Collector.Poller.Provider

    alias Insider.Collector.Poller.ProcessEvidenceTest.GatedProvider

    @impl true
    defdelegate vm_sample, to: GatedProvider

    @impl true
    defdelegate process_sample(pid), to: GatedProvider

    @impl true
    def process_top(_previous, _options), do: receive(do: (:never -> {:error, :failed}))

    @impl true
    defdelegate ets_top(options), to: GatedProvider
  end

  # A scan cut short by its process limit, and one whose rankings were cut
  # to fit the event bound.
  defmodule LimitedScanProvider do
    @behaviour Insider.Collector.Poller.Provider

    alias Insider.Collector.Poller.ProcessEvidenceTest.GatedProvider
    alias Insider.Collector.Poller.Processes

    @impl true
    defdelegate vm_sample, to: GatedProvider

    @impl true
    defdelegate process_sample(pid), to: GatedProvider

    @impl true
    def process_top(previous, options),
      do: Processes.top(previous, Map.put(options, :max_scan, 1))
  end

  defmodule ByteBoundScanProvider do
    @behaviour Insider.Collector.Poller.Provider

    alias Insider.Collector.Poller.ProcessEvidenceTest.GatedProvider
    alias Insider.Collector.Poller.Processes

    @impl true
    defdelegate vm_sample, to: GatedProvider

    @impl true
    defdelegate process_sample(pid), to: GatedProvider

    @impl true
    def process_top(previous, options),
      do: Processes.top(previous, Map.put(options, :budget_bytes, 400))
  end

  # A scan whose every process_info answer costs `@step_us`, as on a node
  # whose processes are busy: each answer waits for its target to be
  # scheduled. The clock is the scan's own, so the slowness is
  # deterministic while the Poller's probe timer runs on real time.
  defmodule SlowScanProvider do
    @behaviour Insider.Collector.Poller.Provider

    alias Insider.Collector.Poller.ProcessEvidenceTest.GatedProvider
    alias Insider.Collector.Poller.Processes

    @step_us 10_000

    @impl true
    defdelegate vm_sample, to: GatedProvider

    @impl true
    defdelegate process_sample(pid), to: GatedProvider

    # The step counter is an atomics array, not a process, so a scan leaves
    # nothing behind whether it completes or its worker is killed.
    @impl true
    def process_top(previous, options) do
      start = System.monotonic_time(:microsecond)
      steps = :counters.new(1, [])

      clock = fn ->
        step = :counters.get(steps, 1)
        :counters.add(steps, 1, 1)
        start + step * @step_us
      end

      Processes.top(previous, Map.put(options, :clock, clock))
    end
  end

  defmodule Backlog do
    use GenServer

    @impl true
    def init(:ok), do: {:ok, nil}

    # Blocks in a selective receive, so every other message waits in the
    # mailbox: a backed-up server.
    @impl true
    def handle_call({:block, notify}, _from, state) do
      send(notify, {:blocked, self()})

      receive do
        :release -> {:reply, :ok, state}
      end
    end
  end

  defmodule NoScanProvider do
    @behaviour Insider.Collector.Poller.Provider

    @impl true
    def vm_sample, do: {:ok, :complete, %{}, []}

    @impl true
    def process_sample(_pid), do: {:error, :failed}
  end

  setup do
    Process.register(self(), @listener)
    :ok
  end

  describe "process rankings" do
    test "a backed-up server is ranked by its mailbox, named, and its messages are never read" do
      secret = "mailbox-secret-#{System.unique_integer([:positive])}"
      backlog = backed_up(Backlog, 500, secret)

      {handle, poller} =
        uncut([1], fn ->
          handle = start_recorder()
          poller = start_poller(handle, top_processes: 5, top_ets_tables: 10)
          step(1)
          step(2)
          {handle, poller}
        end)

      [process_top, ets_top, vm] = cycle_events(handle, "1")
      assert {process_top.kind, ets_top.kind, vm.kind} == {"process_top", "ets_top", "vm_sample"}
      assert process_top.attributes["field_set"] == "otp_process_top/v1"
      assert Enum.all?([process_top, ets_top, vm], &match?(%DateTime{}, &1.wall_time))

      metrics = process_top.attributes["metrics"]
      entry = Enum.find(metrics["by_message_queue_len"], &(&1["pid"] == Names.pid(backlog)))

      assert entry["name"] == Names.display(Backlog)
      assert entry["initial_call"] == "#{Names.display(Backlog)}.init/1"
      assert entry["current_function"] == "#{Names.display(Backlog)}.handle_call/3"
      assert entry["message_queue_len"] == 500
      assert is_integer(entry["memory_bytes"])
      assert entry["reductions_delta"] == nil

      # The first scan has no previous one to take a delta from.
      assert process_top.attributes["probe_status"] == "partial"
      assert process_top.attributes["unavailable"] == ["reductions_delta"]
      assert metrics["by_reductions_delta"] == []
      assert metrics["window_ms"] == nil
      assert metrics["scanned"] + metrics["skipped_protected"] <= metrics["process_count"]
      assert metrics["skipped_protected"] > 0

      refute Enum.any?(events_json(handle), &(&1 =~ secret))
      release(backlog)
      stop(poller)
    end

    test "the second scan ranks reductions since the first and reports its window" do
      burner = spawn_link(&burner/0)

      # Cycle 1's scan has run when its VM probe reports in; the burner
      # works before cycle 2's scan. A delta needs both scans complete.
      {handle, poller} =
        uncut([1, 2], fn ->
          handle = start_recorder()
          poller = start_poller(handle, top_processes: 5)
          gate = step_hold(1)
          send(burner, {:burn, self()})
          # The burner's work, not a deadline, is waited for: with coverage
          # on a loaded 2-vCPU runner it took longer than the 100 ms default.
          assert_receive :burned, 5_000
          continue(gate)
          step(2)
          step(3)
          {handle, poller}
        end)

      [scan] = cycle_events(handle, "2") |> Enum.filter(&(&1.kind == "process_top"))
      metrics = scan.attributes["metrics"]
      refute "reductions_delta" in scan.attributes["unavailable"]
      assert is_integer(metrics["window_ms"]) and metrics["window_ms"] >= 0

      entry = Enum.find(metrics["by_reductions_delta"], &(&1["pid"] == Names.pid(burner)))
      assert entry["reductions_delta"] >= 250_000
      stop(poller)
    end

    test "Insider's own processes and tables are summed apart and reported next to the VM totals" do
      {handle, poller} =
        uncut([1], fn ->
          handle = start_recorder()
          poller = start_poller(handle, top_processes: 5, top_ets_tables: 10)
          step(1)
          step(2)
          {handle, poller}
        end)

      [process_top, ets_top, vm] = cycle_events(handle, "1")

      ranked_pids =
        ranked(process_top, ["by_message_queue_len", "by_memory", "by_reductions_delta"])

      refute Names.pid(poller) in ranked_pids
      refute Names.pid(handle.pid) in ranked_pids

      insider = process_top.attributes["metrics"]["insider"]
      assert insider["process_count"] >= 2

      # The Recorder's buffer is Insider's, never an application table.
      refute Names.pid(handle.pid) in ranked(ets_top, ["by_memory", "by_size"], "owner_pid")
      tables = ets_top.attributes["metrics"]["insider"]
      assert tables["table_count"] >= 1 and tables["memory_bytes"] > 0

      vm_metrics = vm.attributes["metrics"]
      assert vm_metrics["insider_ets_tables"] == tables["table_count"]
      assert vm_metrics["insider_ets_bytes"] == tables["memory_bytes"]
      assert vm_metrics["insider_ets_bytes"] <= vm_metrics["ets_bytes"]
      assert vm_metrics["insider_process_count"] == insider["process_count"]
      assert vm_metrics["insider_processes_bytes"] == insider["memory_bytes"]
      stop(poller)
    end

    test "a host-protected process is counted and never read" do
      backlog = backed_up(Backlog, 10, "unused")

      {handle, poller} =
        uncut([1], fn ->
          handle = start_recorder()
          poller = start_poller(handle, top_processes: 5, host_protected_targets: [backlog])
          step(1)
          step(2)
          {handle, poller}
        end)

      [process_top, _vm] = cycle_events(handle, "1")
      refute Names.pid(backlog) in ranked(process_top, ["by_message_queue_len", "by_memory"])
      assert process_top.attributes["metrics"]["skipped_protected"] >= 1
      release(backlog)
      stop(poller)
    end

    # On a busy node every process_info answer waits for its target
    # to be scheduled, so a whole-node scan ran past its probe timeout and
    # recorded a timeout with no rankings at all on a loaded CI runner. A scan
    # now stops at a deadline inside its probe timeout and records what it
    # ranked so far.
    test "a scan slowed past its time budget records the rankings it reached, never a timeout" do
      backlog = backed_up(Backlog, 10, "unused")
      handle = start_recorder()

      poller =
        start_poller(handle,
          provider: SlowScanProvider,
          top_processes: 5,
          host_protected_targets: [backlog]
        )

      step(1)
      step(2)

      [process_top, vm] = cycle_events(handle, "1")
      metrics = process_top.attributes["metrics"]
      assert process_top.attributes["probe_status"] == "partial"
      assert "scan_deadline" in process_top.attributes["unavailable"]
      assert metrics["scanned"] > 0 and metrics["scanned"] < metrics["process_count"]
      assert [_ | _] = metrics["by_memory"]
      assert Enum.all?(metrics["by_memory"], &is_binary(&1["initial_call"]))
      refute Names.pid(backlog) in ranked(process_top, ["by_message_queue_len", "by_memory"])

      # An unfinished scan has no complete Insider total to subtract.
      assert metrics["insider"]["complete"] == false
      assert vm.attributes["probe_status"] == "partial"
      assert "insider_processes" in vm.attributes["unavailable"]
      release(backlog)
      stop(poller)
    end

    test "a scan that times out leaves the VM sample partial, never silently without a footprint" do
      handle = start_recorder()

      poller =
        start_poller(handle,
          provider: BlockingScanProvider,
          top_processes: 5,
          # The scan blocks for ever, so any budget times it out. The VM probe
          # waits for this test to step it under the same budget: 20 ms timed
          # it out too on a loaded 2-vCPU runner.
          probe_timeout_ms: 1_000,
          cycle_timeout_ms: 5_000
        )

      step(1)
      step(2)

      [process_top, vm] = cycle_events(handle, "1")
      assert process_top.attributes["probe_status"] == "timeout"
      assert vm.attributes["probe_status"] == "partial"
      assert "insider_processes" in vm.attributes["unavailable"]
      refute Map.has_key?(vm.attributes["metrics"], "insider_process_count")
      stop(poller)
    end

    test "a scan cut short by its process limit leaves the VM footprint unavailable" do
      handle = start_recorder()
      poller = start_poller(handle, provider: LimitedScanProvider, top_processes: 5)

      step(1)
      step(2)

      [process_top, vm] = cycle_events(handle, "1")
      assert "scan_limit" in process_top.attributes["unavailable"]
      assert process_top.attributes["metrics"]["insider"]["complete"] == false
      assert vm.attributes["probe_status"] == "partial"
      assert "insider_processes" in vm.attributes["unavailable"]
      refute Map.has_key?(vm.attributes["metrics"], "insider_process_count")
      stop(poller)
    end

    test "rankings cut to the event bound keep a complete footprint" do
      {handle, poller} =
        uncut([1], fn ->
          handle = start_recorder()
          poller = start_poller(handle, provider: ByteBoundScanProvider, top_processes: 5)
          step(1)
          step(2)
          {handle, poller}
        end)

      [process_top, vm] = cycle_events(handle, "1")
      assert "event_bytes" in process_top.attributes["unavailable"]
      assert process_top.attributes["metrics"]["insider"]["complete"] == true
      refute "insider_processes" in vm.attributes["unavailable"]

      assert vm.attributes["metrics"]["insider_process_count"] ==
               process_top.attributes["metrics"]["insider"]["process_count"]

      stop(poller)
    end
  end

  describe "watched processes" do
    test "a watched name is followed across samples and restarts, and an absent one is reported" do
      name = __MODULE__.Watched
      first = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      Process.register(first, name)
      handle = start_recorder()

      poller =
        start_poller(handle,
          watch_names: [name, :insider_process_evidence_test_absent, :code_server]
        )

      step(1)
      step(2)
      gate = step_hold(3)
      Process.unregister(name)
      second = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      Process.register(second, name)
      continue(gate)
      step(4)

      [one, two, three] =
        for cycle <- ["1", "2", "3"] do
          cycle
          |> then(&cycle_events(handle, &1))
          |> Enum.filter(
            &(&1.kind == "process_watch" and &1.attributes["watch_name"] == Names.display(name))
          )
          |> hd()
        end

      assert one.subject["value"] == Names.pid(first)
      assert one.attributes["field_set"] == "otp_process_watch/v1"
      assert one.attributes["metrics"]["reductions_delta"] == nil
      assert is_integer(one.attributes["metrics"]["message_queue_len"])
      assert two.subject["value"] == Names.pid(first)
      assert is_integer(two.attributes["metrics"]["reductions_delta"])
      assert three.subject["value"] == Names.pid(second)
      assert three.attributes["metrics"]["reductions_delta"] == nil

      cycle_one = cycle_events(handle, "1")

      absent =
        Enum.find(
          cycle_one,
          &(&1.attributes["watch_name"] == "insider_process_evidence_test_absent")
        )

      assert absent.attributes["probe_status"] == "not_registered"
      assert absent.subject == nil

      protected = Enum.find(cycle_one, &(&1.attributes["watch_name"] == "code_server"))
      assert protected.attributes["probe_status"] == "protected"
      assert protected.attributes["target_protection"]["class"] == "beam_otp"

      assert {:ok, %{probes_not_registered: not_registered, watch_count: 3}} =
               Poller.status(poller)

      assert not_registered >= 3
      send(first, :stop)
      send(second, :stop)
      stop(poller)
    end
  end

  test "a host-protected process led by Insider's application master leaves the VM footprint unavailable" do
    member = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
    master = :application_controller.get_master(:insider)
    assert is_pid(master)
    true = Process.group_leader(member, master)
    handle = start_recorder()

    poller = start_poller(handle, top_processes: 5, host_protected_targets: [member])

    step(1)
    step(2)

    [process_top, vm] = cycle_events(handle, "1")
    assert process_top.attributes["metrics"]["insider"]["complete"] == false
    assert "insider_footprint" in process_top.attributes["unavailable"]
    assert vm.attributes["probe_status"] == "partial"
    assert "insider_processes" in vm.attributes["unavailable"]
    refute Map.has_key?(vm.attributes["metrics"], "insider_process_count")
    send(member, :stop)
    stop(poller)
  end

  describe "scan modules" do
    test "a host-protected process is never read even when it is also Insider's control plane" do
      backlog = backed_up(Backlog, 50, "unused")
      {:ok, policy} = ProtectedTargets.new(host_targets: [backlog])
      {:ok, bound} = ProtectedTargets.bind_collector(policy, backlog)

      assert {:protected, %{"class" => "host_declared"}} =
               ProtectedTargets.classify(bound, backlog)

      inventory = ProtectedTargets.scan_inventory(bound)
      assert is_map_key(inventory.protected, backlog)
      refute backlog in inventory.insider
      assert inventory.insider_protected == [backlog]

      {:ok, :partial, metrics, unavailable, snapshot} =
        Processes.top(nil, Map.merge(scan_options(), inventory))

      refute is_map_key(snapshot.reductions, backlog)
      refute Names.pid(backlog) in Enum.map(metrics["by_message_queue_len"], & &1["pid"])
      # Its memory cannot be read, so Insider's total is not complete.
      assert metrics["insider"]["complete"] == false
      assert metrics["insider"]["message_queue_len"] < 50
      assert "insider_footprint" in unavailable
      release(backlog)
    end

    test "a process in Insider's control plane or under its application master is never ranked" do
      backlog = backed_up(Backlog, 50, "unused")
      led = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      master = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
      Process.group_leader(led, master)

      {:ok, _status, metrics, _unavailable, _snapshot} =
        Processes.top(nil, scan_options(insider: [backlog], master: master))

      ranked = Enum.flat_map(["by_message_queue_len", "by_memory"], &metrics[&1])
      refute Names.pid(backlog) in Enum.map(ranked, & &1["pid"])
      refute Names.pid(led) in Enum.map(ranked, & &1["pid"])
      assert metrics["insider"]["process_count"] >= 2
      assert metrics["insider"]["message_queue_len"] >= 50

      release(backlog)
      Enum.each([led, master], &send(&1, :stop))
    end

    # A scan cut by its deadline omits processes that
    # existed all along, so the next scan must not take them for new
    # processes and rank their lifetime reductions as one window's work.
    test "after a deadline-cut scan, an omitted process gets no delta, never its lifetime count" do
      parent = self()

      worker =
        spawn_link(fn ->
          Enum.reduce(1..300_000, 0, &(&1 + &2))
          send(parent, :worked)
          receive(do: (:stop -> :ok))
        end)

      assert_receive :worked, 5_000
      {:reductions, lifetime} = Process.info(worker, :reductions)
      assert lifetime > 100_000

      {:ok, _status, _metrics, _unavailable, complete} = Processes.top(nil, scan_options())
      assert complete.complete == true

      now = System.monotonic_time(:microsecond)

      {:ok, :partial, _metrics, _unavailable, cut} =
        Processes.top(complete, scan_options(deadline_us: now))

      assert cut.complete == false
      refute is_map_key(cut.reductions, worker)

      {:ok, :partial, metrics, unavailable, recovered} = Processes.top(cut, scan_options())
      assert "reductions_delta" in unavailable
      refute Names.pid(worker) in Enum.map(metrics["by_reductions_delta"], & &1["pid"])

      entry = Enum.find(metrics["by_memory"], &(&1["pid"] == Names.pid(worker)))
      if entry, do: assert(entry["reductions_delta"] == nil)

      # The recovered scan is complete again, so the next one ranks deltas.
      assert recovered.complete == true
      send(worker, :stop)
    end

    test "a scan whose deadline has passed reads nothing and says so" do
      now = System.monotonic_time(:microsecond)

      {:ok, :partial, metrics, unavailable, snapshot} =
        Processes.top(nil, scan_options(deadline_us: now, names_deadline_us: now))

      assert "scan_deadline" in unavailable
      assert metrics["scanned"] == 0 and metrics["skipped_protected"] == 0
      assert metrics["by_message_queue_len"] == [] and metrics["by_memory"] == []
      assert metrics["insider"]["complete"] == false
      assert snapshot.reductions == %{}
    end

    test "ranked processes past the naming deadline keep their counters and lose only their names" do
      backlog = backed_up(Backlog, 40, "unused")
      now = System.monotonic_time(:microsecond)

      {:ok, :partial, metrics, unavailable, _snapshot} =
        Processes.top(nil, scan_options(deadline_us: now + 60_000_000, names_deadline_us: now))

      assert "process_names" in unavailable
      refute "scan_deadline" in unavailable
      entry = Enum.find(metrics["by_message_queue_len"], &(&1["pid"] == Names.pid(backlog)))
      assert entry["message_queue_len"] == 40
      assert %{"name" => nil, "initial_call" => nil, "current_function" => nil} = entry
      release(backlog)
    end

    test "rankings that exceed the event byte bound drop entries and say how many" do
      {:ok, :partial, metrics, unavailable, _snapshot} =
        Processes.top(nil, scan_options(top: 10, budget_bytes: 1_200))

      assert "event_bytes" in unavailable
      assert metrics["omitted"] > 0
      assert byte_size(Jason.encode!(metrics)) <= 1_200
    end

    test "ETS tables are ranked by memory and size with their owner, and Insider's are summed" do
      parent = self()

      owner =
        spawn_link(fn ->
          Process.register(self(), __MODULE__.TableOwner)
          table = :ets.new(__MODULE__.Cache, [:set, :private])
          :ets.insert(table, Enum.map(1..5_000, &{&1, :value}))
          send(parent, {:table, table})
          receive(do: (:stop -> :ok))
        end)

      assert_receive {:table, table}, 5000
      {:ok, :complete, metrics, []} = Ets.top(ets_options())

      entry = Enum.find(metrics["by_size"], &(&1["owner_pid"] == Names.pid(owner)))
      assert entry["table"] == Names.display(__MODULE__.Cache)
      assert entry["owner"] == Names.display(__MODULE__.TableOwner)
      assert entry["size"] == 5_000
      assert entry["memory_bytes"] == :ets.info(table, :memory) * :erlang.system_info(:wordsize)

      {:ok, :complete, insider, []} = Ets.top(ets_options(insider: [owner]))
      refute Names.pid(owner) in Enum.map(insider["by_size"], & &1["owner_pid"])
      assert insider["insider"]["size"] >= 5_000

      {:ok, :complete, protected, []} = Ets.top(ets_options(protected: %{owner => :held_name}))
      held = Enum.find(protected["by_size"], &(&1["owner_pid"] == Names.pid(owner)))
      assert held["owner"] == "held_name"
      send(owner, :stop)
    end

    test "fit drops from the longest list, the last named on a tie" do
      metrics = %{"a" => [1, 2], "b" => [1, 2, 3], "c" => [1, 2, 3]}
      budget = byte_size(Jason.encode!(Map.put(metrics, "omitted", 1))) - 1
      fitted = Ranking.fit(metrics, ["a", "b", "c"], budget)
      assert fitted["c"] == [1, 2] and fitted["b"] == [1, 2, 3] and fitted["omitted"] == 1
      assert Ranking.fit(%{"a" => []}, ["a"], 1) == %{"a" => [], "omitted" => 0}
    end

    test "names resolve only to existing atoms and describe code identifiers" do
      assert Names.parse("Insider.Collector.Poller") == {:ok, Insider.Collector.Poller}
      assert Names.parse("Elixir.Insider.Collector.Poller") == {:ok, Insider.Collector.Poller}
      assert Names.parse("code_server") == {:ok, :code_server}
      assert Names.parse("No.Such.Module#{System.unique_integer([:positive])}") == :unknown
      assert Names.parse("not a name") == :invalid
      assert Names.parse("") == :invalid
      assert Names.parse(:atom) == :invalid
      assert Names.mfa({:gen_server, :loop, 7}) == "gen_server.loop/7"
      assert Names.mfa(:undefined) == nil

      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}, 5000

      assert Names.describe(dead) == %{
               "name" => nil,
               "initial_call" => nil,
               "current_function" => nil
             }
    end
  end

  test "rejects out-of-range rankings, malformed watch names, and a provider without scans" do
    handle = start_recorder()

    for invalid <- [
          [top_processes: 6],
          [top_ets_tables: 11],
          [top_ets_tables: -1],
          [watch_names: [:a, :a]],
          [watch_names: ["name"]],
          [watch_names: [nil]],
          [watch_names: Enum.map(1..17, &:"insider_watch_#{&1}")],
          [top_processes: 1, provider: NoScanProvider],
          [top_ets_tables: 1, provider: NoScanProvider]
        ] do
      assert {:error, :invalid_options} = Config.new(handle, base_options() ++ invalid),
             inspect(invalid)
    end

    assert {:ok, %Config{top_processes: 5, top_ets_tables: 10}} =
             Config.new(
               handle,
               base_options() ++
                 [
                   top_processes: Config.maximum_top_processes(),
                   top_ets_tables: Config.maximum_top_ets_tables()
                 ]
             )

    assert ErlangProvider.process_top(nil, scan_options()) |> elem(0) == :ok
  end

  defp backed_up(module, count, secret) do
    {:ok, server} = GenServer.start(module, :ok, name: module)
    on_exit(fn -> Process.exit(server, :kill) end)
    test = self()
    spawn(fn -> GenServer.call(server, {:block, test}, :infinity) end)
    assert_receive {:blocked, ^server}, 5000
    Enum.each(1..count, fn index -> send(server, {:queued, index, secret}) end)
    {:message_queue_len, ^count} = Process.info(server, :message_queue_len)
    server
  end

  defp release(server) do
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 5000
  end

  defp burner do
    receive do
      {:burn, parent} ->
        Enum.reduce(1..500_000, 0, &(&1 + &2))
        send(parent, :burned)
        burner()
    end
  end

  defp step(cycle), do: cycle |> step_hold() |> continue()

  defp step_hold(_cycle) do
    assert_receive {:vm_probe, worker}, 5_000
    worker
  end

  defp continue(worker), do: send(worker, :continue)

  # A process scan stops at 5/8 of its probe timeout, which is at most 1 s.
  # With coverage on a loaded 2-vCPU runner it can stop before it reaches
  # every process, and then it honestly reports `scan_deadline`, an
  # incomplete Insider footprint, and no reductions delta in the next scan.
  # A test whose claim is about a scan that reached every process runs its
  # `scenario` (start a poller and step it; returns `{handle, poller}`) until
  # no process scan of the given `cycles` was cut, at most 5 times. Tests of
  # the cut itself assert the incomplete result instead.
  defp uncut(cycles, scenario, attempts \\ 5)

  defp uncut(_cycles, _scenario, 0),
    do: flunk("every attempt had a process scan cut by its deadline")

  defp uncut(cycles, scenario, attempts) do
    {handle, poller} = scenario.()

    if Enum.any?(cycles, &cut?(handle, &1)) do
      stop(poller)
      drain_probes()
      uncut(cycles, scenario, attempts - 1)
    else
      {handle, poller}
    end
  end

  # Cut by its deadline, or so slow that the probe itself timed out.
  defp cut?(handle, cycle) do
    handle
    |> cycle_events(Integer.to_string(cycle))
    |> Enum.any?(fn event ->
      event.kind == "process_top" and
        (event.attributes["probe_status"] not in ["complete", "partial"] or
           "scan_deadline" in event.attributes["unavailable"])
    end)
  end

  # A stopped poller's VM probe may have reported already.
  defp drain_probes do
    receive do
      {:vm_probe, _worker} -> drain_probes()
    after
      0 -> :ok
    end
  end

  defp stop(poller) do
    monitor = Process.monitor(poller)
    Process.unlink(poller)
    Process.exit(poller, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^poller, _reason}, 5_000
  end

  defp ranked(event, lists, key \\ "pid") do
    metrics = event.attributes["metrics"]
    lists |> Enum.flat_map(&metrics[&1]) |> Enum.map(& &1[key])
  end

  defp cycle_events(handle, cycle_id) do
    handle
    |> recorded_events()
    |> Enum.filter(&(&1.attributes["cycle_id"] == cycle_id))
  end

  defp events_json(handle) do
    handle |> recorded_events() |> Enum.map(&(&1 |> Event.to_wire_map() |> Jason.encode!()))
  end

  defp recorded_events(handle) do
    {:ok, read} = Recorder.read_since(handle, 0, limit: 1_000, max_bytes: 16_777_216)

    Enum.map(read.entries, fn entry ->
      {:ok, event} = Event.decode_map(entry.event)
      event
    end)
  end

  defp start_recorder do
    {:ok, recorder} =
      Recorder.start_link(
        classification: Insider.TestRecorderClassification.binding(),
        max_events: 256,
        max_bytes: 4_194_304,
        post_trigger_ms: 0
      )

    {:ok, handle} = Recorder.handle(recorder)
    handle
  end

  defp start_poller(handle, overrides) do
    options =
      Keyword.merge(
        base_options() ++
          [
            provider: GatedProvider,
            interval_ms: 10,
            probe_timeout_ms: 1_000,
            cycle_timeout_ms: 5_000
          ],
        overrides
      )

    {:ok, poller} = Poller.start_link(handle, options)
    poller
  end

  defp base_options do
    [
      authority: "process-evidence-test",
      boot_id: "boot-test",
      clock_id: "monotonic-us",
      initial_delay_ms: 0,
      source_instance_id: "process-evidence-test"
    ]
  end

  defp scan_options(overrides \\ []) do
    Map.merge(
      %{top: 50, protected: %{}, insider: [], master: nil, budget_bytes: 1_000_000},
      Map.new(overrides)
    )
  end

  defp ets_options(overrides \\ []), do: scan_options(overrides)
end
