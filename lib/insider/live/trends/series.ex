defmodule Insider.Live.Trends.Series do
  @moduledoc false

  # Per-sample series of a digest window's Poller evidence, for
  # `Insider.Live.Trends`: binary bytes and the port count from each
  # `vm_sample`, ports per type from each `port_top`, and mailbox lengths per
  # process from each `process_top` ranking and each `process_sample` or
  # `process_watch`.
  #
  # Every point is one Poller sample at its wall time. A process that a
  # ranking did not list has no point there, never a zero: it may only have
  # fallen below the ranking. A port type missing from a complete census
  # had no port then, so it counts zero: the scan read every port (no
  # `scan_limit` in `unavailable`), listed every type it found (`type_count`,
  # nothing `omitted`), and folded no type into `other` for the type bound.
  # A type first seen later starts from a zero at each earlier complete
  # census of the window; an incomplete census gives an absent type no point.
  #
  # Each series keeps its maximum and its count of direct samples
  # (`process_sample`, `process_watch`) apart from the point buffer, so
  # compaction never loses the window's peak or its coverage.
  #
  # Events of one poller cycle (`cycle_id`) give one point per series: a
  # watched process that is also ranked is sampled twice in a cycle, and
  # the later sample replaces the earlier.
  #
  # Bounded: at most `@max_series` series per metric (the first seen; later
  # samples of other subjects are counted as untracked) and, per series, the
  # first point and the last `@max_points`.

  alias Insider.Collector.Poller.Ports

  @max_series 64
  @max_points 500

  @direct ["process_sample", "process_watch"]

  @type t :: %{
          series: map(),
          counts: %{String.t() => non_neg_integer()},
          untracked: %{String.t() => non_neg_integer()},
          censuses: map()
        }

  @doc "An empty fold."
  @spec new() :: t()
  def new,
    do: %{
      series: %{},
      counts: %{},
      untracked: %{},
      # The window's complete port censuses as `{at, cycle_id}`: the first,
      # how many, and the most recent ones (newest first), bounded like a
      # series' points, one per poller cycle.
      censuses: %{first: nil, total: 0, recent: [], kept: 0}
    }

  @doc "Folds one disclosed event at wall time `at` (microseconds, or nil)."
  @spec add(t(), map(), integer() | nil) :: t()
  def add(acc, _event, nil), do: acc

  def add(acc, %{"source" => "poller", "kind" => "vm_sample", "attributes" => a}, at)
      when is_map(a) do
    metrics = if is_map(a["metrics"]), do: a["metrics"], else: %{}

    Enum.reduce(["binary_bytes", "port_count"], acc, fn metric, acc ->
      point(acc, {metric, nil}, metrics[metric], at, "vm_sample", cycle(a))
    end)
  end

  def add(acc, %{"source" => "poller", "kind" => "port_top", "attributes" => a}, at)
      when is_map(a) do
    metrics = if is_map(a["metrics"]), do: a["metrics"], else: %{}
    types = for %{"type" => type, "count" => count} <- list(metrics["by_type"]), do: {type, count}

    acc =
      Enum.reduce(types, acc, fn {type, count}, acc -> port_type(acc, type, count, at, a) end)

    # A complete census lists every port's type: one this window's series
    # knows and the census did not list had no port.
    if complete_census?(a, metrics, types) do
      listed = MapSet.new(types, &elem(&1, 0))

      acc.series
      |> Map.keys()
      |> Enum.filter(&match?({"port_type", _type}, &1))
      |> Enum.reject(fn {_metric, type} -> MapSet.member?(listed, type) end)
      |> Enum.reduce(acc, fn {_metric, type}, acc -> port_type(acc, type, 0, at, a) end)
      |> record_census(at, cycle(a)[:cycle])
    else
      acc
    end
  end

  def add(acc, %{"source" => "poller", "kind" => "process_top", "attributes" => a}, at)
      when is_map(a) do
    a
    |> get_in(["metrics", "by_message_queue_len"])
    |> list()
    |> Enum.reduce(acc, &mailbox(&2, &1, at, "process_top", cycle(a)))
  end

  def add(acc, %{"source" => "poller", "kind" => kind, "attributes" => a} = event, at)
      when kind in ["process_sample", "process_watch"] and is_map(a) do
    metrics = if is_map(a["metrics"]), do: a["metrics"], else: %{}

    entry =
      Map.merge(metrics, %{
        "pid" => get_in(event, ["subject", "value"]),
        "name" => a["watch_name"] || metrics["registered_name"]
      })

    mailbox(acc, entry, at, kind, cycle(a))
  end

  def add(acc, _event, _at), do: acc

  @doc """
  The series, each with its metric, subject, pid (mailboxes), source kinds,
  and points oldest first; and the samples left untracked per metric.
  """
  @spec rows(t()) :: %{series: [map()], untracked: %{String.t() => non_neg_integer()}}
  def rows(acc) do
    series =
      for {{metric, key}, s} <- acc.series do
        %{
          metric: metric,
          subject: s.subject || key,
          pid: s.pid,
          kinds: s.kinds |> MapSet.to_list() |> Enum.sort(),
          total: s.total,
          first: s.first,
          max: max_of(s.prior_max, elem(hd(s.recent), 1)),
          direct: s.prior_direct + if(s.last_direct, do: 1, else: 0),
          points: Enum.reverse(s.recent)
        }
      end

    %{series: series, untracked: acc.untracked}
  end

  defp complete_census?(attributes, metrics, types) do
    unavailable = if is_list(attributes["unavailable"]), do: attributes["unavailable"], else: []

    "scan_limit" not in unavailable and is_integer(metrics["type_count"]) and
      length(types) >= metrics["type_count"] and metrics["type_count"] < Ports.max_types() and
      (metrics["omitted"] || 0) == 0
  end

  # Censuses follow the series rule: a later census of the cycle the last
  # one came from replaces it.
  defp record_census(%{censuses: %{recent: [{_at, cycle} | rest]} = c} = acc, at, cycle)
       when not is_nil(cycle) do
    first = if rest == [], do: {at, cycle}, else: c.first
    %{acc | censuses: %{c | first: first, recent: [{at, cycle} | rest]}}
  end

  defp record_census(%{censuses: c} = acc, at, cycle) do
    {recent, kept} = bounded([{at, cycle} | c.recent], c.kept + 1)

    %{
      acc
      | censuses: %{
          first: c.first || {at, cycle},
          total: c.total + 1,
          recent: recent,
          kept: kept
        }
    }
  end

  defp port_type(acc, type, count, at, attributes) when is_binary(type),
    do: point(acc, {"port_type", type}, count, at, "port_top", cycle(attributes))

  defp port_type(acc, _type, _count, _at, _attributes), do: acc

  defp cycle(%{"cycle_id" => id}) when is_binary(id) or is_integer(id), do: %{cycle: id}
  defp cycle(_attributes), do: %{}

  # A process's series is keyed by its pid, so two unregistered processes of
  # one initial call stay apart; its subject is its registered name once
  # any sample names it, else its initial call or pid.
  defp mailbox(acc, %{"message_queue_len" => queue} = entry, at, kind, cycle)
       when is_integer(queue) do
    pid = entry["pid"]
    name = display(entry["name"])
    label = to_string(name || entry["initial_call"] || pid || "?")
    key = {"message_queue_len", pid || label}
    point(acc, key, queue, at, kind, Map.merge(cycle, %{pid: pid, name: name, label: label}))
  end

  defp mailbox(acc, _entry, _at, _kind, _cycle), do: acc

  defp point(acc, key, value, at, kind, identity) when is_integer(value) do
    {metric, _subject} = key

    case Map.fetch(acc.series, key) do
      {:ok, s} ->
        %{acc | series: Map.put(acc.series, key, extend(s, value, at, kind, identity))}

      :error ->
        if Map.get(acc.counts, metric, 0) < @max_series do
          s =
            new_series(value, at, kind, identity)
            |> from_zero(metric, earlier_censuses(acc.censuses, identity[:cycle]))

          %{
            acc
            | series: Map.put(acc.series, key, s),
              counts: Map.update(acc.counts, metric, 1, &(&1 + 1))
          }
        else
          %{acc | untracked: Map.update(acc.untracked, metric, 1, &(&1 + 1))}
        end
    end
  end

  defp point(acc, _key, _value, _at, _kind, _identity), do: acc

  defp new_series(value, at, kind, identity) do
    %{
      pid: identity[:pid],
      subject: identity[:name] || identity[:label],
      kinds: MapSet.new([kind]),
      total: 1,
      first: {at, value},
      recent: [{at, value}],
      kept: 1,
      cycle: identity[:cycle],
      # The maximum and the direct samples of every point but the last,
      # which a later sample of its cycle may replace.
      prior_max: nil,
      prior_direct: 0,
      last_direct: kind in @direct
    }
  end

  # A port type first seen now had no port at each earlier complete census.
  # The complete censuses before the cycle of a new point: the newest one
  # is that cycle's own when the cycles match, and is not a point before it.
  defp earlier_censuses(%{recent: [{_at, cycle} | rest]} = c, cycle) when not is_nil(cycle) do
    case rest do
      [] -> %{first: nil, total: 0, recent: [], kept: 0}
      _earlier -> %{c | total: c.total - 1, recent: rest, kept: c.kept - 1}
    end
  end

  defp earlier_censuses(censuses, _cycle), do: censuses

  defp from_zero(s, "port_type", %{first: {first, _cycle}} = censuses) do
    [{at, value}] = s.recent

    %{
      s
      | total: censuses.total + 1,
        first: {first, 0},
        recent: [{at, value} | Enum.map(censuses.recent, fn {census, _cycle} -> {census, 0} end)],
        kept: censuses.kept + 1,
        prior_max: 0
    }
  end

  defp from_zero(s, _metric, _censuses), do: s

  # A second sample of the cycle the last point came from replaces it.
  defp extend(
         %{cycle: cycle, recent: [_last | rest]} = s,
         value,
         at,
         kind,
         %{cycle: cycle} = identity
       )
       when not is_nil(cycle) do
    %{
      s
      | kinds: MapSet.put(s.kinds, kind),
        subject: identity[:name] || s.subject,
        first: if(rest == [], do: {at, value}, else: s.first),
        recent: [{at, value} | rest],
        last_direct: s.last_direct or kind in @direct
    }
  end

  defp extend(s, value, at, kind, identity) do
    [{_last_at, last} | _older] = s.recent
    {recent, kept} = bounded([{at, value} | s.recent], s.kept + 1)

    %{
      s
      | kinds: MapSet.put(s.kinds, kind),
        subject: identity[:name] || s.subject,
        total: s.total + 1,
        recent: recent,
        kept: kept,
        cycle: identity[:cycle],
        prior_max: max_of(s.prior_max, last),
        prior_direct: s.prior_direct + if(s.last_direct, do: 1, else: 0),
        last_direct: kind in @direct
    }
  end

  # Newest first; past twice the bound, cut back to the bound.
  defp bounded(list, kept) when kept > 2 * @max_points,
    do: {Enum.take(list, @max_points), @max_points}

  defp bounded(list, kept), do: {list, kept}

  defp max_of(nil, value), do: value
  defp max_of(current, value), do: max(current, value)

  defp list(entries) when is_list(entries), do: Enum.filter(entries, &is_map/1)
  defp list(_entries), do: []

  defp display("Elixir." <> name), do: name
  defp display(name) when is_binary(name), do: name
  defp display(_name), do: nil
end
