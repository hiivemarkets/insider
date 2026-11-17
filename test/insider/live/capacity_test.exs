defmodule Insider.Live.CapacityTest do
  # One collector session is global per node, and these tests set the
  # `:insider` disclosure profile, so this module cannot run in parallel with
  # other session users.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Insider.Collector.Session
  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Archive

  @tick [:insider_live_capacity, :tick]
  @all %{"limit" => 500, "max_bytes" => 1_048_576}

  setup do
    Application.put_env(:insider, :live_disclosure, :rich)

    on_exit(fn ->
      Application.delete_env(:insider, :live_disclosure)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  test "a rich Logger flood cannot evict Telemetry or Poller evidence" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger", "telemetry", "poller"],
               "logger_level" => "info",
               "telemetry_events" => [["insider_live_capacity", "tick"]],
               "telemetry_measurements" => ["count"],
               "max_events" => 64,
               "lease_ms" => 60_000
             })

    # The Poller samples at once and then every second.
    assert_eventually(fn -> receipts(id, "poller") != [] end)
    poller = receipts(id, "poller")
    for count <- 1..3, do: :telemetry.execute(@tick, %{count: count}, %{})
    assert [_, _, _] = telemetry = receipts(id, "telemetry")

    # 400 Logger lines, about six times the Recorder's 64 events, read in
    # batches so the Logger collector's inbox never sheds.
    for chunk <- 1..4 do
      for line <- 1..100,
          do: :logger.info("flood #{chunk}-#{line} " <> String.duplicate("x", 200))

      assert {:ok, _caught_up} = Live.events_since(id, "latest")
    end

    assert {:ok, batch} = Live.events_since(id, 0, @all)
    retained = Enum.group_by(batch["events"], & &1["event"]["source"], & &1["receipt"])

    assert Enum.take(retained["telemetry"], 3) == telemetry
    assert Enum.take(retained["poller"], length(poller)) == poller
    assert [%{"reason" => "evicted", "count" => evicted}] = batch["gaps"]
    assert evicted > 300

    assert {:ok, %{"recorder" => %{"sources" => sources}}} = Live.status(id)
    assert %{"evicted" => ^evicted, "reserved_events" => 16} = sources["logger"]
    assert %{"evicted" => 0, "reserved_events" => 9} = sources["telemetry"]
    assert %{"evicted" => 0, "reserved_events" => 16} = sources["poller"]
  end

  # With two readers, the digest's hints say the readers share the
  # Recorder the flood evicts from.
  test "a flood with two named readers gets the shared_readers hint" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger"],
               "logger_level" => "info",
               "max_events" => 64,
               "lease_ms" => 60_000
             })

    assert {:ok, _a} = Live.events_since(id, 0, %{"reader" => "agent-a"})
    assert {:ok, _b} = Live.events_since(id, 0, %{"reader" => "agent-b"})

    for line <- 1..100, do: :logger.info("flood #{line}")
    assert {:ok, _caught_up} = Live.events_since(id, "latest")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0})

    assert %{"evidence" => %{"readers" => 2, "evicted" => evicted}} =
             Enum.find(digest["hints"], &(&1["kind"] == "shared_readers"))

    assert evicted > 0
    # Other readers are active, so stopping takes force.
    assert {:ok, _stopped} = Live.stop(id, %{"force" => true})
  end

  test "status reports Insider's own memory and each source's share of the Recorder" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger", "poller"], "lease_ms" => 60_000})

    :logger.warning("one line")
    assert {:ok, _caught_up} = Live.events_since(id, "latest")
    assert {:ok, status} = Live.status(id)

    assert %{
             "processes" => processes,
             "processes_bytes" => processes_bytes,
             "recorder_bytes" => recorder_bytes,
             "total_bytes" => total
           } = status["insider_memory"]

    assert Enum.sort(Map.keys(processes)) ==
             ~w(live_owner logger poller recorder session session_manager)

    assert Enum.all?(Map.values(processes), &(is_integer(&1) and &1 > 0))
    assert processes_bytes == processes |> Map.values() |> Enum.sum()
    assert recorder_bytes > status["recorder"]["retained_bytes"]
    assert total == processes_bytes + recorder_bytes
    refute Map.has_key?(status["recorder"], "memory_bytes")
    refute Map.has_key?(status["health"], "memory")

    assert %{"share_percent" => 25, "reserved_bytes" => 1_048_576, "retained_events" => logger} =
             status["recorder"]["sources"]["logger"]

    assert logger >= 1
    assert plain?(status)

    assert {:ok, stopped} = Live.stop(id)
    assert %{"insider_memory" => nil, "recorder" => nil} = stopped
  end

  # Measured with `bench/live_read_memory.exs`, on an
  # owner holding no other state: the owner peaks at about 2.9 MB building a 1 MiB result and 0.7 MB examining 4 MiB
  # of hidden entries; the Manager and Session at about 0.5 MB, one page.
  # Before paging, the owner peaked at 4.1 and 6.7 MB, the Session at 7.7
  # and 9.6 MB, and the Manager at 4.1 MB, and they kept 2.5 to 9.6 MB after
  # the read.
  @owner_result_peak 4 * 1_048_576
  @owner_scan_peak 1_048_576
  @page_peak 1_048_576
  @owner_after 256 * 1_024
  @page_after 1_048_576

  test "a max-size read holds one page besides its result and Insider keeps nothing after" do
    # The bounds were measured on an owner holding no other state. An owner
    # keeps ended sessions readable for a while (about 220 KB after an
    # earlier test), which raised its heap and peaks with test order, so
    # this test starts from a restarted, empty owner.
    restart_owner()

    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["logger"],
               "logger_level" => "info",
               "lease_ms" => 60_000
             })

    fill_recorder(id)
    assert {:ok, %{"recorder" => fill}} = Live.status(id)
    assert fill["retained_bytes"] > 3 * 1_048_576
    readers = read_path()

    before = idle_memory(readers)
    {read, peaks} = peak_memory(readers, fn -> Live.events_since(id, 0, @all) end)
    assert {:ok, %{"truncated_by" => "max_bytes", "events" => events}} = read
    assert Enum.count_until(events, 101) > 100
    assert peaks.owner <= @owner_result_peak, inspect(peaks)
    assert peaks.manager <= @page_peak and peaks.session <= @page_peak, inspect(peaks)
    assert_released(readers, before)

    # A view that hides every entry examines all 4 MiB and returns nothing.
    hidden = Map.put(@all, "view", %{"sources" => ["telemetry"]})
    before = idle_memory(readers)
    {read, peaks} = peak_memory(readers, fn -> Live.events_since(id, 0, hidden) end)
    assert {:ok, %{"events" => [], "truncated" => false, "filtered" => filtered} = batch} = read
    assert filtered["view"]["sources"] == fill["retained_events"]
    assert batch["next_cursor"] == batch["next_receipt"]
    assert peaks.owner <= @owner_scan_peak, inspect(peaks)
    assert peaks.manager <= @page_peak and peaks.session <= @page_peak, inspect(peaks)
    assert_released(readers, before)
  end

  # What a read left behind: each process's idle memory after the read over
  # its idle memory just before it, both measured from here (status's
  # `insider_memory` includes the owner's work building the status reply).
  # An absolute bound failed on Elixir 1.17/OTP 27 depending on test order:
  # the owner's state legitimately holds an ended session kept readable for
  # a while (about 220 KB when an earlier test's session ended just before),
  # and its own collection then leaves a heap of about 600 KB sized for that
  # live state, before and after the read alike.
  defp assert_released(readers, before) do
    idle = idle_memory(readers)
    kept = Map.new(idle, fn {name, bytes} -> {name, bytes - before[name]} end)
    assert kept.owner <= @owner_after, inspect(%{before: before, idle: idle})
    assert kept.manager <= @page_after, inspect(%{before: before, idle: idle})
    assert kept.session <= @page_after, inspect(%{before: before, idle: idle})
  end

  # `:sys.get_state/1` returns only after the process has replied to the read
  # and run its `handle_continue` collection.
  defp idle_memory(readers) do
    Map.new(readers, fn {name, pid} ->
      :sys.get_state(pid)
      {:memory, bytes} = Process.info(pid, :memory)
      {name, bytes}
    end)
  end

  # Archive pages once took 100 entries whatever their
  # size (750 KB of rich events against the 128 KiB page bound), and a page
  # joining the archive and the Recorder gave the Recorder a fresh byte
  # budget. The owner's archive pages and Recorder page requests are traced
  # during reads of an amended session (archive pages, then a mixed page)
  # and of the stopped one with `upto`. Each read must return every receipt
  # once, and every page must keep the shared bound. The owner's heap is no
  # measure here: archive pages share the entries the owner already holds,
  # and a hidden scan peaked at 1.44 MB over its collected heap with or
  # without the byte bound.
  test "archive and mixed pages keep the page bound, before and after a stop" do
    restart_owner()
    page_bytes = Live.Owner.bounds()["read_page_bytes"]

    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "info"})

    fill_recorder(id, 3)
    assert {:ok, %{"amendment" => _}} = Live.amend(id, %{"max_events" => 2_048})
    fill_recorder(id, 1)
    assert {:ok, %{"recorder" => fill, "next_receipt" => top}} = Live.status(id)
    assert fill["archived_events"] >= 300

    {receipts, pages} = traced_pages(fn -> receipts_through(id, 0, %{}) end)
    assert receipts == Enum.to_list(1..top)
    assert_pages_bounded(pages, page_bytes)

    # The first read from just before the amendment joins the archive's
    # last entry with the Recorder's first ones under the same budget.
    {_receipts, pages} =
      traced_pages(fn -> receipts_through(id, fill["archived_events"] - 1, %{}) end)

    assert [{:archive, part}, {:recorder, live_bytes} | _rest] = pages
    assert [_last] = part["events"]
    assert live_bytes == page_bytes - Archive.page_bytes(part)
    assert_pages_bounded(pages, page_bytes, false)

    assert {:ok, _stopped} = Live.stop(id)
    upto = div(top, 2)
    {receipts, pages} = traced_pages(fn -> receipts_through(id, 0, %{"upto" => upto}) end)
    assert receipts == Enum.to_list(1..upto)
    assert_pages_bounded(pages, page_bytes)
  end

  # Every archive page holds at most the page bytes or one entry, at least
  # one page was cut by bytes (when `cut?`), and a Recorder page after an archive part is
  # asked for no more than what the part left (or one byte, for counters).
  defp assert_pages_bounded(pages, page_bytes, cut? \\ true) do
    archive = for {:archive, page} <- pages, do: page
    assert archive != []

    assert Enum.all?(archive, &within_page?(&1, page_bytes))

    if cut?,
      do:
        assert(
          Enum.any?(archive, &(&1["truncated"] and Enum.count_until(&1["events"], 100) < 100))
        )

    joins =
      for [{:archive, part}, {:recorder, bytes}] <- Enum.chunk_every(pages, 2, 1),
          do: {part, bytes}

    assert Enum.all?(joins, fn {part, bytes} -> left_for_recorder?(part, bytes, page_bytes) end)
  end

  # One entry always fits; more must fit within the page bytes.
  defp within_page?(%{"events" => [_one]}, _page_bytes), do: true
  defp within_page?(page, page_bytes), do: Archive.page_bytes(page) <= page_bytes

  # One byte asks the Recorder only for its counters and newest receipt.
  defp left_for_recorder?(_part, 1, _page_bytes), do: true

  defp left_for_recorder?(part, bytes, page_bytes),
    do: Archive.page_bytes(part) + bytes <= page_bytes

  # The owner's archive pages (`Archive.read/4` and `read_retained/5`
  # results) and the byte bound of each Recorder page it asks for, in order.
  defp traced_pages(fun) do
    owner = Process.whereis(Live.Owner)
    return = [{:_, [], [{:return_trace}]}]
    1 = :erlang.trace_pattern({Archive, :read, 4}, return, [:local])
    1 = :erlang.trace_pattern({Session, :read_events, 3}, true, [:global])
    1 = :erlang.trace(owner, true, [:call, {:tracer, self()}])

    result =
      try do
        fun.()
      after
        :erlang.trace(owner, false, [:call])
        :erlang.trace_pattern({Archive, :read, 4}, false, [:local])
        :erlang.trace_pattern({Session, :read_events, 3}, false, [:global])
      end

    ref = :erlang.trace_delivered(owner)
    assert_receive {:trace_delivered, ^owner, ^ref}, 1_000
    {result, collect_pages(owner, [])}
  end

  defp collect_pages(owner, pages) do
    receive do
      {:trace, ^owner, :return_from, {Archive, :read, 4}, {:ok, page}} ->
        collect_pages(owner, [{:archive, page} | pages])

      {:trace, ^owner, :call, {Session, :read_events, [_handle, _cursor, options]}} ->
        collect_pages(owner, [{:recorder, Keyword.fetch!(options, :max_bytes)} | pages])

      {:trace, ^owner, _kind, _mfa, _result} ->
        collect_pages(owner, pages)

      {:trace, ^owner, _kind, _mfa} ->
        collect_pages(owner, pages)
    after
      0 -> Enum.reverse(pages)
    end
  end

  # Every receipt a reader gets from `cursor` in 64 KiB batches, which end
  # at `upto` when it is given, with no loss along the way.
  defp receipts_through(id, cursor, options) do
    {:ok, batch} = Live.events_since(id, cursor, Map.merge(%{"limit" => 500}, options))
    assert batch["gaps"] == [], inspect(batch["gaps"])
    receipts = Enum.map(batch["events"], & &1["receipt"])

    if batch["truncated"],
      do: receipts ++ receipts_through(id, batch["next_cursor"], options),
      else: receipts
  end

  # A fresh owner through the supervisor's own terminate and restart, not a
  # kill: a kill is a crash and counts toward Insider.Supervisor's restart
  # intensity (3 in 5 s), so with other tests that kill an Insider child
  # just before (GatesTest kills the owner and the gate keeper) it shut the
  # application down mid-suite. terminate_child/restart_child do not count.
  defp restart_owner do
    old = Process.whereis(Live.Owner)
    :ok = Supervisor.terminate_child(Insider.Supervisor, Live.Owner)
    {:ok, owner} = Supervisor.restart_child(Insider.Supervisor, Live.Owner)
    assert is_pid(owner) and owner != old
  end

  defp read_path do
    %{
      owner: Process.whereis(Live.Owner),
      manager: Process.whereis(Manager),
      session: :sys.get_state(Manager).active.pid
    }
  end

  # Logs about 4 MiB of rich Logger events: lines of about 3 KiB with about
  # 4 KiB of metadata, 100 at a time so the collector's inbox never sheds,
  # and fewer than the Recorder's 1,000 per source and second.
  defp fill_recorder(id, chunks \\ 6) do
    metadata = Map.new(1..4, &{:"field_#{&1}", String.duplicate("m", 900)})

    for chunk <- 1..chunks do
      for line <- 1..100 do
        :logger.info("fill #{chunk}-#{line} " <> String.duplicate("x", 3_000), metadata)
      end

      assert {:ok, _caught_up} = Live.events_since(id, "latest")
    end
  end

  # The most memory each process held while `fun` ran beyond its heap
  # collected just before, from its garbage-collection trace: every
  # collection reports the heap blocks and heap fragments it found, so their
  # sum is the process's heap then. Over the collected heap, so state the
  # owner legitimately keeps (an archive, ended sessions kept readable) is
  # not counted as the read's.
  defp peak_memory(pids, fun) do
    word = :erlang.system_info(:wordsize)

    base =
      Map.new(pids, fn {name, pid} ->
        :erlang.garbage_collect(pid)
        {:total_heap_size, words} = Process.info(pid, :total_heap_size)
        1 = :erlang.trace(pid, true, [:garbage_collection, {:tracer, self()}])
        {name, words * word}
      end)

    result =
      try do
        fun.()
      after
        Enum.each(pids, fn {_name, pid} -> :erlang.trace(pid, false, [:garbage_collection]) end)
      end

    peaks =
      Map.new(pids, fn {name, pid} ->
        ref = :erlang.trace_delivered(pid)
        assert_receive {:trace_delivered, ^pid, ^ref}, 1_000
        {name, max(collected_peak(pid, 0) - base[name], 0)}
      end)

    {result, peaks}
  end

  defp collected_peak(pid, peak) do
    receive do
      {:trace, ^pid, _gc, info} ->
        words =
          Keyword.fetch!(info, :heap_block_size) + Keyword.fetch!(info, :old_heap_block_size) +
            Keyword.fetch!(info, :mbuf_size)

        collected_peak(pid, max(peak, words * :erlang.system_info(:wordsize)))
    after
      0 -> peak
    end
  end

  defp receipts(id, source) do
    {:ok, batch} = Live.events_since(id, 0, Map.put(@all, "view", %{"sources" => [source]}))
    Enum.map(batch["events"], & &1["receipt"])
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

  defp plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and plain?(item) end)

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  defp plain?(value),
    do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)
end
