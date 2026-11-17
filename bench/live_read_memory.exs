# Read-path gate for Live reads. Three sessions run one after
# another in one owner, which is never restarted, so later ones read while
# the owner keeps earlier stopped sessions readable (their archives):
#
# - `large`: about 4 MiB of rich Logger lines of about 3 KiB with about 4 KiB
#   of metadata, a full Recorder whose pages are bound by bytes;
# - `small`: 900 lines of about 1.2 KiB like a web shop's checkout
#   errors, about 2.1 MB, whose pages are bound by entries;
# - `amended`: 300 large lines, an amendment that moves them into the
#   session's archive, then 100 more, so reads from cursor 0 page through
#   the archive and join it to the Recorder.
#
# Each round makes the two largest reads a caller can ask for, from cursor 0
# with `limit` 500 and `max_bytes` 1 MiB: `full` (no view, cut at 1 MiB of
# returned JSON) and `hidden` (a view that hides every entry, so the read
# examines everything and returns nothing but an amendment marker).
#
# The gate separates what a read costs from what the owner legitimately
# keeps:
#
# - `peak`: the most each process (owner, session Manager, Session) held
#   during the read beyond its heap collected just before, from its
#   garbage-collection trace (each collection reports the heap blocks and
#   heap fragments it found);
# - `kept`: how much each process's state grew across the read, in words of
#   its state term (`:erts_debug.size/1`, after `:sys.get_state/1`, so the
#   read's reply and collection have run). Process memory after the read is
#   reported as `memory_delta_max` but not gated: once the owner holds a few
#   MB of retained archives, the heap a full collection leaves is sized for
#   that state and moves in steps of several hundred KB (1.57 MB once after
#   a small read) without the owner keeping anything of the read;
# - `retained`: the owner's idle memory before each session starts, which
#   holds the stopped sessions kept readable (at most
#   `bounds.retained_readable_sessions`, each archive at most
#   `bounds.archived_bytes_max` of external term size, most of it in shared
#   binaries outside the heap);
# - the median read time, at most half the owner's 2,000 ms read timeout.
#
# Peaks also grow with the state a process holds, because its collections
# size the heap for its live data: with about 4 MB of retained archives the
# owner peaked at 3.2 MB during a hidden scan that took 0.7 MB over an empty
# owner. The hidden bound (4 MiB) allows that; the full bound (6 MiB) covers
# the 1 MiB result itself, 2.9 MB for large events and 4.9 MB for 500 small
# ones over an empty owner. `retained_owner` allows 4 MiB of owner heap per
# readable stopped session: a stopped full 4 MiB Recorder measured about
# 2.5 MB and the 2.1 MB small one about 1.6 MB, their binaries being shared
# outside the heap.
#
# Before paging (an empty owner, load average 60), the large full read
# peaked at 4.1 MB in the owner, 4.1 MB in the Manager and 7.7 MB in the
# Session, and the processes kept 2.5 to 9.6 MB after it. A review found
# that the previous form of this bench, whose limits were absolute, failed
# once stopped sessions stayed readable.
alias Insider.Collector.Session.Manager
alias Insider.Event.Canonical
alias Insider.Live

rounds = 8
max_read_ms = 1_000

bounds = %{
  peak: %{
    full: %{owner: 6 * 1_048_576, manager: 1_048_576, session: 1_048_576},
    hidden: %{owner: 4 * 1_048_576, manager: 1_048_576, session: 1_048_576}
  },
  kept: %{owner: 256 * 1_024, manager: 1_048_576, session: 1_048_576},
  retained_owner: Live.Owner.bounds()["retained_readable_sessions"] * 4 * 1_048_576
}

Application.put_env(:insider, :live_disclosure, :rich)
Logger.configure(level: :info)
# The fill is for the Recorder only, not the console.
:ok = :logger.remove_handler(:default)

large = %{
  text: String.duplicate("x", 3_000),
  metadata: Map.new(1..4, &{:"field_#{&1}", String.duplicate("m", 900)})
}

small = %{text: String.duplicate("y", 1_200), metadata: %{}}

# `{lines, line shape}` before and after an amendment (`nil`: none).
profiles = [
  large: %{fill: {600, large}, amended: nil},
  small: %{fill: {900, small}, amended: nil},
  amended: %{fill: {300, large}, amended: {100, large}}
]

reads = %{
  full: %{"limit" => 500, "max_bytes" => 1_048_576},
  hidden: %{"limit" => 500, "max_bytes" => 1_048_576, "view" => %{"sources" => ["telemetry"]}}
}

word = :erlang.system_info(:wordsize)

collected_peak = fn collected_peak, pid, peak ->
  receive do
    {:trace, ^pid, _gc, info} ->
      words =
        Keyword.fetch!(info, :heap_block_size) + Keyword.fetch!(info, :old_heap_block_size) +
          Keyword.fetch!(info, :mbuf_size)

      collected_peak.(collected_peak, pid, max(peak, words * word))
  after
    0 -> peak
  end
end

# The words of each process's state, shared subterms once: the data it
# keeps. `:sys.get_state/1` returns only after the read's reply and the
# collection after it.
state_bytes = fn readers ->
  Map.new(readers, fn {name, pid} -> {name, :erts_debug.size(:sys.get_state(pid)) * word} end)
end

memory = fn readers ->
  Map.new(readers, fn {name, pid} -> {name, elem(Process.info(pid, :memory), 1)} end)
end

measure = fn id, readers, options ->
  before = state_bytes.(readers)
  memory_before = memory.(readers)

  base =
    Map.new(readers, fn {name, pid} ->
      :erlang.garbage_collect(pid)
      {:total_heap_size, words} = Process.info(pid, :total_heap_size)
      1 = :erlang.trace(pid, true, [:garbage_collection, {:tracer, self()}])
      {name, words * word}
    end)

  started_at = System.monotonic_time()
  {:ok, batch} = Live.events_since(id, 0, options)
  elapsed = System.monotonic_time() - started_at
  Enum.each(readers, fn {_name, pid} -> :erlang.trace(pid, false, [:garbage_collection]) end)

  peaks =
    Map.new(readers, fn {name, pid} ->
      ref = :erlang.trace_delivered(pid)
      receive do: ({:trace_delivered, ^pid, ^ref} -> :ok)
      {name, max(collected_peak.(collected_peak, pid, 0) - base[name], 0)}
    end)

  after_read = state_bytes.(readers)
  memory_after = memory.(readers)

  %{
    ms: System.convert_time_unit(elapsed, :native, :microsecond) / 1_000,
    events: length(batch["events"]),
    json_bytes: byte_size(Canonical.encode(batch["events"])),
    peaks: peaks,
    kept: Map.new(after_read, fn {name, bytes} -> {name, bytes - before[name]} end),
    memory_delta:
      Map.new(memory_after, fn {name, bytes} -> {name, bytes - memory_before[name]} end)
  }
end

median = fn values ->
  sorted = Enum.sort(values)
  Enum.at(sorted, div(length(sorted), 2))
end

fill = fn id, {lines, shape} ->
  for chunk <- 1..div(lines, 100) do
    for line <- 1..100, do: :logger.info("fill #{chunk}-#{line} " <> shape.text, shape.metadata)
    {:ok, _caught_up} = Live.events_since(id, "latest")
  end
end

run_profile = fn profile ->
  owner = Process.whereis(Live.Owner)
  :sys.get_state(owner)
  {:memory, retained} = Process.info(owner, :memory)

  {:ok, %{"session_id" => id}} =
    Live.start(%{"components" => ["logger"], "logger_level" => "info", "lease_ms" => 300_000})

  fill.(id, profile.fill)

  if profile.amended do
    {:ok, _amendment} = Live.amend(id, %{"max_events" => 2_048})
    fill.(id, profile.amended)
  end

  {:ok, %{"recorder" => recorder}} = Live.status(id)

  readers = %{
    owner: owner,
    manager: Process.whereis(Manager),
    session: :sys.get_state(Manager).active.pid
  }

  samples =
    Enum.map(1..rounds, fn _round ->
      Map.new(reads, fn {name, options} -> {name, measure.(id, readers, options)} end)
    end)

  {:ok, _stopped} = Live.stop(id)

  measured =
    Map.new(reads, fn {name, _options} ->
      runs = Enum.map(samples, & &1[name])

      max_of = fn key ->
        Map.new(readers, fn {r, _} ->
          {r, runs |> Enum.map(&get_in(&1, [key, r])) |> Enum.max()}
        end)
      end

      {name,
       %{
         events: median.(Enum.map(runs, & &1.events)),
         json_bytes: median.(Enum.map(runs, & &1.json_bytes)),
         read_ms_median: median.(Enum.map(runs, & &1.ms)),
         peak_bytes_max: max_of.(:peaks),
         kept_bytes_max: max_of.(:kept),
         memory_delta_max: max_of.(:memory_delta)
       }}
    end)

  %{
    owner_retained_before: retained,
    recorder: Map.take(recorder, ["retained_events", "retained_bytes", "archived_events"]),
    reads: measured
  }
end

report = Map.new(profiles, fn {name, profile} -> {name, run_profile.(profile)} end)

failures =
  for {profile, run} <- report,
      failure <-
        if(run.owner_retained_before > bounds.retained_owner,
          do: [
            "#{profile} owner retained #{run.owner_retained_before} over #{bounds.retained_owner}"
          ],
          else: []
        ) ++
          for(
            {name, read} <- run.reads,
            {kind, measured, limits} <- [
              {"peak", read.peak_bytes_max, bounds.peak[name]},
              {"kept", read.kept_bytes_max, bounds.kept}
            ],
            {reader, limit} <- limits,
            measured[reader] > limit,
            do: "#{profile} #{name} #{reader} #{kind} #{measured[reader]} over #{limit}"
          ) ++
          for(
            {name, read} <- run.reads,
            read.read_ms_median > max_read_ms,
            do: "#{profile} #{name} median read #{read.read_ms_median} ms over #{max_read_ms} ms"
          ),
      do: failure

IO.puts(
  Canonical.encode(%{
    rounds: rounds,
    profiles: report,
    bounds: Map.put(bounds, :max_read_ms, max_read_ms),
    failures: failures
  })
)

if failures != [], do: raise("live read path exceeded its gate: #{inspect(failures)}")
