defmodule Insider.Collector.Poller.Processes do
  @moduledoc false

  # The Poller's whole-node process scan: the top processes by mailbox
  # length, memory, and reductions since the previous scan, plus Insider's
  # own footprint. Each process is read with four scalar `process_info/2`
  # items; only the ranked processes are then named (see
  # `Insider.Collector.Poller.Names`). Protected processes are counted and
  # never read. Insider's own processes (its control plane, and every
  # process whose group leader is the `:insider` application master) are
  # summed under `"insider"` and never ranked, so an agent cannot mistake
  # Insider's buffers for the application's.
  #
  # `process_info/2` on another process is answered by that process, so on
  # a busy node each answer waits for its target to be scheduled and a whole
  # scan can take seconds. A scan therefore stops at `deadline_us` and names
  # ranked processes only until `names_deadline_us`, so it returns what it
  # reached inside its probe timeout instead of timing out with nothing.

  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ranking

  @max_scan 50_000
  @items [:group_leader, :message_queue_len, :memory, :reductions]
  @lists ["by_message_queue_len", "by_memory", "by_reductions_delta"]

  # `complete` is false when the scan stopped early (scan limit or
  # deadline), so a process missing from it may have existed all along.
  @type snapshot :: %{
          at_us: integer(),
          reductions: %{pid() => non_neg_integer()},
          complete: boolean()
        }
  # `insider_protected` (Insider processes a host also protects, never read),
  # `host_declared` (every host declaration), `max_scan`, the monotonic
  # microsecond deadlines `deadline_us` (stop scanning) and
  # `names_deadline_us` (stop naming), and `clock` (the monotonic clock the
  # deadlines are read with) are optional.
  @type options :: %{
          required(:top) => pos_integer(),
          required(:protected) => %{pid() => atom() | nil},
          required(:insider) => [pid()],
          required(:master) => pid() | nil,
          required(:budget_bytes) => pos_integer(),
          optional(:insider_protected) => [pid()],
          optional(:host_declared) => [pid()],
          optional(:max_scan) => pos_integer(),
          optional(:deadline_us) => integer(),
          optional(:names_deadline_us) => integer(),
          optional(:clock) => (-> integer())
        }

  @doc "The most processes one scan reads; the rest are reported as not scanned."
  @spec max_scan() :: pos_integer()
  def max_scan, do: @max_scan

  @doc """
  Scans every local process once. `previous` is the snapshot the last scan
  returned (`nil` before the first), from which each process's reductions
  delta is taken. A process absent from a complete snapshot started after
  it, so its whole count is its delta; absent from an incomplete one (that
  scan stopped early), its baseline is unknown, so its delta is `nil` and
  `unavailable` lists `reductions_delta`. Returns the metrics and the
  snapshot for the next scan.
  """
  @spec top(snapshot() | nil, options()) ::
          {:ok, :complete | :partial, map(), [String.t()], snapshot()}
  def top(previous, options) do
    at_us = System.monotonic_time(:microsecond)
    pids = :erlang.processes()

    context = %{
      top: options.top,
      protected: options.protected,
      insider: MapSet.new(options.insider),
      # Without Insider's application master only the control plane is
      # Insider's, so a skipped host declaration can hide a member only when
      # there is a master.
      unknown_membership:
        if(options.master,
          do: MapSet.new(Map.get(options, :host_declared, [])),
          else: MapSet.new()
        ),
      master: options.master,
      max_scan: Map.get(options, :max_scan, @max_scan),
      # An integer is always below an atom, so without a deadline the scan
      # never stops early.
      deadline_us: Map.get(options, :deadline_us, :infinity),
      names_deadline_us: Map.get(options, :names_deadline_us, :infinity),
      clock: Map.get(options, :clock, fn -> System.monotonic_time(:microsecond) end),
      previous: previous
    }

    scan = scan(pids, 0, initial(), context)

    # Insider's totals are complete only when every process was scanned and
    # no process that is, or may be, Insider's was skipped for protection: a
    # control-plane process a host protects, or any live host declaration,
    # whose group leader cannot be read. Dropping ranking entries for the
    # event bound leaves them complete.
    complete =
      not scan.truncated and not scan.deadline_reached and not scan.unknown_membership and
        Map.get(options, :insider_protected, []) == []

    {rankings, unnamed} =
      Enum.map_reduce(
        [
          {"by_message_queue_len", scan.queue},
          {"by_memory", scan.memory},
          {"by_reductions_delta", scan.reductions}
        ],
        false,
        fn {list, ranked}, unnamed ->
          {entries, list_unnamed} = entries(ranked, context)
          {{list, entries}, unnamed or list_unnamed}
        end
      )

    metrics =
      rankings
      |> Map.new()
      |> Map.merge(%{
        "process_count" => length(pids),
        "scanned" => scan.scanned,
        "skipped_protected" => scan.skipped,
        "window_ms" => previous && div(at_us - previous.at_us, 1_000),
        "insider" => Map.put(scan.insider, "complete", complete)
      })
      |> Ranking.fit(@lists, options.budget_bytes)

    unavailable =
      [
        {scan.truncated, "scan_limit"},
        {scan.deadline_reached, "scan_deadline"},
        {unnamed, "process_names"},
        {not complete, "insider_footprint"},
        {is_nil(previous) or not previous.complete, "reductions_delta"},
        {metrics["omitted"] > 0, "event_bytes"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    status = if unavailable == [], do: :complete, else: :partial

    snapshot = %{
      at_us: at_us,
      reductions: scan.snapshot,
      complete: not scan.truncated and not scan.deadline_reached
    }

    {:ok, status, metrics, unavailable, snapshot}
  end

  defp initial do
    %{
      scanned: 0,
      skipped: 0,
      truncated: false,
      deadline_reached: false,
      unknown_membership: false,
      queue: [],
      memory: [],
      reductions: [],
      snapshot: %{},
      insider: %{"process_count" => 0, "memory_bytes" => 0, "message_queue_len" => 0}
    }
  end

  defp scan([], _visited, scan, _context), do: scan
  defp scan(_pids, max, scan, %{max_scan: max}), do: %{scan | truncated: true}

  defp scan([pid | rest], visited, scan, context) do
    if context.clock.() >= context.deadline_us,
      do: %{scan | deadline_reached: true},
      else: scan(rest, visited + 1, visit(pid, scan, context), context)
  end

  defp visit(pid, scan, context) do
    if is_map_key(context.protected, pid) do
      %{
        scan
        | skipped: scan.skipped + 1,
          unknown_membership:
            scan.unknown_membership or MapSet.member?(context.unknown_membership, pid)
      }
    else
      case :erlang.process_info(pid, @items) do
        [
          {:group_leader, leader},
          {:message_queue_len, queue},
          {:memory, memory},
          {:reductions, reductions}
        ] ->
          scan = %{scan | scanned: scan.scanned + 1}

          if insider?(pid, leader, context),
            do: add_insider(scan, queue, memory),
            else: rank(scan, pid, queue, memory, reductions, context)

        _exited ->
          scan
      end
    end
  end

  defp insider?(pid, leader, context),
    do: MapSet.member?(context.insider, pid) or (is_pid(leader) and leader == context.master)

  defp add_insider(scan, queue, memory) do
    insider =
      scan.insider
      |> Map.update!("process_count", &(&1 + 1))
      |> Map.update!("memory_bytes", &(&1 + memory))
      |> Map.update!("message_queue_len", &(&1 + queue))

    %{scan | insider: insider}
  end

  defp rank(scan, pid, queue, memory, reductions, context) do
    delta = delta(context.previous, pid, reductions)
    row = {pid, queue, memory, delta}
    k = context.top

    %{
      scan
      | snapshot: Map.put(scan.snapshot, pid, reductions),
        queue: if(queue > 0, do: Ranking.insert(scan.queue, queue, row, k), else: scan.queue),
        memory: Ranking.insert(scan.memory, memory, row, k),
        reductions:
          if(is_integer(delta) and delta > 0,
            do: Ranking.insert(scan.reductions, delta, row, k),
            else: scan.reductions
          )
    }
  end

  defp delta(nil, _pid, _reductions), do: nil

  defp delta(%{reductions: counts, complete: complete}, pid, reductions) do
    case counts do
      %{^pid => before} -> max(reductions - before, 0)
      _absent when complete -> reductions
      _absent -> nil
    end
  end

  @unnamed %{"name" => nil, "initial_call" => nil, "current_function" => nil}

  # Each name is another process_info answer, so past the naming deadline
  # an entry keeps its counters and goes unnamed; the boolean says whether
  # any did.
  defp entries(ranked, context) do
    ranked
    |> Ranking.rows()
    |> Enum.map_reduce(false, fn {pid, queue, memory, delta}, unnamed ->
      {names, unnamed} =
        if context.clock.() >= context.names_deadline_us,
          do: {@unnamed, true},
          else: {Names.describe(pid), unnamed}

      entry =
        Map.merge(names, %{
          "pid" => Names.pid(pid),
          "message_queue_len" => queue,
          "memory_bytes" => memory,
          "reductions_delta" => delta
        })

      {entry, unnamed}
    end)
  end
end
