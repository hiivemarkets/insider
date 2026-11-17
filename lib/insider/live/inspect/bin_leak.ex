defmodule Insider.Live.Inspect.BinLeak do
  @moduledoc false

  # `Insider.Live.bin_leak/1`, after `recon:bin_leak/1`: every process's
  # reference-counted binaries are measured, every process is garbage
  # collected, and they are measured again. Two rankings come out:
  #
  # - `by_retained_bytes`: what each process still references after the
  #   collection. A process that keeps growing here holds its binaries on
  #   purpose (a leak: a list of sub-binaries pinning large ones, a cache).
  # - `by_freed_bytes`: what the collection released, garbage the process
  #   had not collected yet (recon's notion of a binary leak).
  #
  # Protected processes are neither read nor collected. Insider's own
  # processes are collected and summed under `"insider"`, never ranked.
  # The collections are requested asynchronously and awaited until the
  # deadline; a process whose collection did not finish is counted in
  # `"gc_pending"`.

  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ranking
  alias Insider.Live.Inspect
  alias Insider.Redaction.Credentials

  @schema "insider.live-bin-leak/v1"
  @max_scan 50_000
  # The collections may use at most this share of the time left, leaving
  # the rest for the second measurement.
  @gc_share 0.6
  # The human text's bound, its labels', and room for its omitted line.
  @text_bytes 8_192
  @label_bytes 128
  @omitted_line_bytes 64

  @spec max_scan() :: pos_integer()
  def max_scan, do: @max_scan

  @spec lists() :: [[String.t()]]
  def lists, do: [["by_retained_bytes"], ["by_freed_bytes"]]

  @spec inspect(map(), Inspect.context()) :: {:ok, map()}
  def inspect(%{top: top} = parsed, context) do
    started = System.monotonic_time(:millisecond)
    vm_before = :erlang.memory(:binary)
    all = :erlang.processes()
    max_scan = Map.get(context, :max_scan) || @max_scan
    pids = Enum.take(all, max_scan)
    me = self()

    {candidates, skipped} =
      Enum.reduce(pids, {[], 0}, fn pid, {candidates, skipped} ->
        cond do
          pid == me -> {candidates, skipped}
          is_map_key(context.protected, pid) -> {candidates, skipped + 1}
          true -> {[pid | candidates], skipped}
        end
      end)

    before = Map.new(candidates, &{&1, measure(&1)})
    {collected, pending} = collect(Map.keys(before), context)
    rows = for {pid, {count, bytes}} <- before, do: row(pid, count, bytes, measure(pid))

    {insider, application} = Enum.split_with(rows, &Inspect.insider?(&1.pid, context))
    retained = rank(application, & &1.after_bytes, top)

    {:ok,
     %{
       "schema" => @schema,
       "implementation" => "native",
       "process_count" => length(all),
       "scanned" => map_size(before),
       "skipped_protected" => skipped,
       "collected" => collected,
       "gc_pending" => pending,
       "by_retained_bytes" => retained,
       "biggest_holder" => biggest_holder(retained),
       "by_freed_bytes" =>
         application |> Enum.filter(&(&1.freed_bytes > 0)) |> rank(& &1.freed_bytes, top),
       "insider" => %{
         "process_count" => length(insider),
         "binary_bytes_before" => insider |> Enum.map(& &1.before_bytes) |> Enum.sum(),
         "binary_bytes_after" => insider |> Enum.map(& &1.after_bytes) |> Enum.sum()
       },
       "vm_binary_bytes_before" => vm_before,
       "vm_binary_bytes_after" => :erlang.memory(:binary),
       "truncated_by" =>
         Enum.filter(
           [length(all) > max_scan && "scan_limit", pending > 0 && "deadline"],
           &is_binary/1
         ),
       "elapsed_ms" => System.monotonic_time(:millisecond) - started,
       "observer_effect" => "garbage_collected_every_scanned_process",
       "note" =>
         "biggest_holder: the process that still references the most binary bytes after a garbage collection, first in by_retained_bytes " <>
           "(a leak holds them: freed_bytes near 0); by_freed_bytes: what the collection released (garbage not yet collected, not a leak)"
     }
     |> put_text(Map.get(parsed, :human, false))}
  end

  @doc """
  The process holding the most binary bytes after the collection: the first
  entry of `by_retained_bytes` when it holds any, else `nil`.
  """
  @spec biggest_holder([map()]) :: map() | nil
  def biggest_holder([%{"binary_bytes_after" => bytes} = holder | _rest]) when bytes > 0,
    do: holder

  def biggest_holder(_retained), do: nil

  defp put_text(result, true), do: Map.put(result, "text", text(result))
  defp put_text(result, false), do: result

  @doc """
  The most bytes `text/1` returns. The result's lists are cut around it to
  the result bound, so a human request fits as a JSON one does.
  """
  @spec text_bytes_max() :: pos_integer()
  def text_bytes_max, do: @text_bytes

  @doc """
  A short plain-text summary for a developer, at most `text_bytes_max/0`
  bytes: the heading, the holders (the biggest first), what the collection
  freed, and whether the evidence is complete. Labels are cut to
  `@label_bytes`; lines that do not fit are counted, never dropped silently.
  With a cut scan, pending collections, or protected processes skipped, it
  says the evidence is incomplete and claims no absence.
  """
  @spec text(map()) :: String.t()
  def text(result) do
    missing = missing(result)
    holders = Enum.filter(result["by_retained_bytes"], &(&1["binary_bytes_after"] > 0))

    head = [
      "bin_leak: binary holders after a garbage collection of #{result["scanned"]} processes"
    ]

    holder_lines =
      case {holders, missing} do
        {[], []} ->
          ["No inspected process holds binaries after the collection."]

        {[], _missing} ->
          ["None found among the processes read (the evidence is incomplete, below)."]

        {rows, _missing} ->
          Enum.map(rows, &holder_line/1)
      end

    freed_lines =
      case {result["by_freed_bytes"], missing} do
        {[], []} ->
          ["Freed by the collection: nothing among the processes read."]

        {[], _missing} ->
          ["Freed by the collection: none found among the processes read."]

        {rows, _missing} ->
          ["Freed by the collection (garbage, not a leak):"] ++
            Enum.map(rows, &"  #{label(&1)} freed #{bytes(&1["freed_bytes"])}")
      end

    tail = [
      evidence_line(result, missing),
      "VM binary memory #{bytes(result["vm_binary_bytes_before"])} -> #{bytes(result["vm_binary_bytes_after"])}. " <>
        "A holder that stays first with 0 B freed, and grows when bin_leak runs again, keeps its binaries " <>
        "(often small sub-binaries pinning large ones); process --name NAME shows where it is."
    ]

    # Lines are masked as export will mask them before they are measured,
    # so masking cannot expand the text past its bound later. The heading,
    # the biggest holder, and the completeness lines always fit; the other
    # lines are kept in order while they fit.
    [first | rest] = Enum.map(holder_lines, &Credentials.mask_text/1)
    tail = Enum.map(tail, &Credentials.mask_text/1)
    fixed = head ++ [first] ++ tail
    budget = @text_bytes - byte_size(Enum.join(fixed, "\n")) - @omitted_line_bytes
    {kept, omitted} = take_lines(Enum.map(rest ++ freed_lines, &Credentials.mask_text/1), budget)

    more =
      if omitted > 0, do: ["  #{omitted} more lines not shown (see the JSON result)"], else: []

    Enum.join(head ++ [first] ++ kept ++ more ++ tail, "\n") <> "\n"
  end

  defp take_lines(lines, budget) do
    {kept, _left, omitted} =
      Enum.reduce(lines, {[], budget, 0}, fn line, {kept, left, omitted} ->
        cost = byte_size(line) + 1

        if omitted == 0 and cost <= left,
          do: {[line | kept], left - cost, omitted},
          else: {kept, left, omitted + 1}
      end)

    {Enum.reverse(kept), omitted}
  end

  defp missing(result) do
    [
      {"scan_limit" in (result["truncated_by"] || []), "the scan limit stopped the scan"},
      {(result["gc_pending"] || 0) > 0, "#{result["gc_pending"]} collections did not finish"},
      {(result["skipped_protected"] || 0) > 0,
       "#{result["skipped_protected"]} protected processes not read"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp evidence_line(result, []),
    do: "Evidence complete: #{result["scanned"]} processes scanned and collected."

  defp evidence_line(_result, missing),
    do: "Evidence incomplete: " <> Enum.join(missing, "; ") <> "."

  defp holder_line(row) do
    "  #{label(row)} holds #{bytes(row["binary_bytes_after"])} in #{row["binary_count_after"]} binaries, " <>
      "#{bytes(row["freed_bytes"])} freed"
  end

  # A name is masked before it is cut, so its masked form, not its raw
  # form, takes the label's bound: the biggest holder's line cannot grow
  # past it when the text is masked again on export.
  defp label(row) do
    name =
      (row["name"] || row["initial_call"] || "unnamed")
      |> Credentials.mask_text()
      |> Inspect.bound_text(@label_bytes, :head)

    "#{name} (#{row["pid"]})"
  end

  defp bytes(value) when is_integer(value) and value >= 1_048_576,
    do: "#{Float.round(value / 1_048_576, 1)} MiB"

  defp bytes(value) when is_integer(value) and value >= 1_024,
    do: "#{Float.round(value / 1_024, 1)} KiB"

  defp bytes(value) when is_integer(value), do: "#{value} B"
  defp bytes(_value), do: "?"

  # A process that exited is measured as holding nothing.
  defp measure(pid) do
    case :erlang.process_info(pid, :binary) do
      {:binary, binaries} ->
        Enum.reduce(binaries, {0, 0}, fn {_id, size, _refc}, {count, bytes} ->
          {count + 1, bytes + size}
        end)

      :undefined ->
        {0, 0}
    end
  end

  defp collect(pids, context) do
    reference = make_ref()
    requested = Enum.count(pids, &request(&1, reference))
    budget = trunc(Inspect.remaining(context) * @gc_share)
    deadline = System.monotonic_time(:millisecond) + budget
    collected = await(reference, requested, 0, deadline)
    {collected, requested - collected}
  end

  defp request(pid, reference) do
    :async == :erlang.garbage_collect(pid, async: reference)
  rescue
    ArgumentError -> false
  end

  defp await(_reference, requested, collected, _deadline) when collected == requested,
    do: collected

  defp await(reference, requested, collected, deadline) do
    receive do
      {:garbage_collect, ^reference, _result} ->
        await(reference, requested, collected + 1, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> collected
    end
  end

  defp row(pid, count, bytes, {after_count, after_bytes}) do
    %{
      pid: pid,
      before_count: count,
      before_bytes: bytes,
      after_count: after_count,
      after_bytes: after_bytes,
      freed_bytes: bytes - after_bytes
    }
  end

  defp rank(rows, key, top) do
    rows
    |> Enum.reduce([], fn row, ranked -> Ranking.insert(ranked, key.(row), row, top) end)
    |> Ranking.rows()
    |> Enum.map(fn row ->
      row.pid
      |> Names.describe()
      |> Map.merge(%{
        "pid" => Names.pid(row.pid),
        "binary_count_before" => row.before_count,
        "binary_bytes_before" => row.before_bytes,
        "binary_count_after" => row.after_count,
        "binary_bytes_after" => row.after_bytes,
        "freed_bytes" => row.freed_bytes
      })
    end)
  end

  @spec event(map()) :: {map(), [String.t()]}
  def event(result) do
    trim = fn rows ->
      rows
      |> Enum.take(5)
      |> Enum.map(
        &Map.take(&1, ["pid", "name", "initial_call", "binary_bytes_after", "freed_bytes"])
      )
    end

    {result
     |> Map.take([
       "scanned",
       "skipped_protected",
       "gc_pending",
       "insider",
       "vm_binary_bytes_before",
       "vm_binary_bytes_after",
       "truncated_by"
     ])
     |> Map.merge(%{
       "biggest_holder" => result["biggest_holder"] && hd(trim.([result["biggest_holder"]])),
       "by_retained_bytes" => trim.(result["by_retained_bytes"]),
       "by_freed_bytes" => trim.(result["by_freed_bytes"])
     }), ["by_retained_bytes", "by_freed_bytes"]}
  end
end
