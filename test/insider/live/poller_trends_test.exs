defmodule Insider.Live.PollerTrendsTest do
  # Trends covered only Telemetry and Logger summaries. Port,
  # binary and mailbox growth was a first-to-last delta in the digest, so
  # readers sampled and computed rates by hand. A window's Poller events, as
  # `events_since/3` returns them, now give per-sample series.
  use ExUnit.Case, async: true

  alias Insider.Live.Digest
  alias Insider.Live.Trends

  @t0 ~U[2026-10-23 11:54:00.000000Z]

  defp at(s), do: @t0 |> DateTime.add(s, :second) |> DateTime.to_iso8601()

  defp poller(receipt, s, kind, attributes, subject \\ nil) do
    %{
      "receipt" => receipt,
      "redactions" => [],
      "event" => %{
        "source" => "poller",
        "kind" => kind,
        "severity" => "debug",
        "wall_time" => at(s),
        "subject" => subject && %{"namespace" => "process", "value" => subject},
        "attributes" => attributes
      }
    }
  end

  defp vm(receipt, s, ports, binary),
    do:
      poller(receipt, s, "vm_sample", %{
        "metrics" => %{"port_count" => ports, "binary_bytes" => binary, "process_count" => 90}
      })

  defp port_top(receipt, s, cat, tcp),
    do:
      poller(receipt, s, "port_top", %{
        "metrics" => %{
          "port_count" => cat + tcp,
          "type_count" => Enum.count([cat, tcp], &(&1 > 0)),
          "by_type" =>
            [%{"type" => "cat", "count" => cat}, %{"type" => "tcp_inet", "count" => tcp}]
            |> Enum.reject(&(&1["count"] == 0))
        }
      })

  defp process_top(receipt, s, entries),
    do: poller(receipt, s, "process_top", %{"metrics" => %{"by_message_queue_len" => entries}})

  defp pricing(queue),
    do: %{"name" => "Shop.Pricing", "pid" => "<0.200.0>", "message_queue_len" => queue}

  defp trends(entries, options \\ []) do
    reader = fn
      cursor, _options, _budget when cursor == 0 ->
        receipt = length(entries)

        {:ok,
         %{
           "cursor" => 0,
           "next_cursor" => receipt,
           "next_receipt" => receipt,
           "events" => entries,
           "gaps" => [],
           "filtered" => nil,
           "state" => "running"
         }}
    end

    deadline = System.monotonic_time(:millisecond) + 3_000

    {:ok, digest, rows} =
      Digest.read_window("live-7", {:cursor, 0}, reader, deadline, "shop@host")

    Trends.document(
      digest,
      rows,
      Keyword.get(options, :kinds, []),
      Keyword.get(options, :windows, 60)
    )
  end

  defp series(document, metric, subject \\ nil),
    do: Enum.find(document["poller"], &(&1["metric"] == metric and &1["subject"] == subject))

  test "binary bytes and port count are series per VM sample with change and growth per minute" do
    document =
      trends([
        vm(1, 0, 28, 12_400_000),
        vm(2, 5, 31, 15_000_000),
        vm(3, 10, 34, 17_800_000),
        vm(4, 60, 40, 24_400_000)
      ])

    assert document["units"]["bytes"] == "bytes"
    assert document["units"]["per_min"] == "change per minute"

    binary = series(document, "binary_bytes")
    assert binary["unit"] == "bytes"
    assert binary["source_kinds"] == ["vm_sample"]
    assert binary["windows"] == 4

    assert binary["change"] == %{
             "first" => 12_400_000,
             "last" => 24_400_000,
             "delta" => 12_000_000,
             "direction" => "rising"
           }

    # 12,000,000 bytes over 60 s.
    assert binary["per_min"] == 12_000_000
    assert binary["max"] == 24_400_000

    assert [first, second | _rest] = binary["series"]
    assert first == %{"at" => at(0), "value" => 12_400_000, "delta" => nil}
    assert second == %{"at" => at(5), "value" => 15_000_000, "delta" => 2_600_000}

    ports = series(document, "port_count")
    assert ports["unit"] == "ports"
    assert ports["per_min"] == 12

    text = Trends.text(Map.put(document, "notes", []))

    assert text =~
             "VM trend: binary_bytes 11.8 MiB -> 23.3 MiB (rising, +11.4 MiB/min) over 4 samples"

    assert text =~ "VM trend: port_count 28 -> 40 (rising, +12/min) over 4 samples"
  end

  test "ports are a series per type; a type absent from a complete scan counts zero ports" do
    document =
      trends([
        port_top(1, 0, 10, 2),
        port_top(2, 5, 13, 0),
        port_top(3, 10, 16, 2)
      ])

    cat = series(document, "port_type", "cat")
    assert cat["unit"] == "ports"
    assert Enum.map(cat["series"], & &1["value"]) == [10, 13, 16]
    assert cat["change"]["direction"] == "rising"
    assert cat["per_min"] == 36

    # A scan that lists all its types (type_count) had none of a missing
    # type; one cut to top_ports says nothing about it.
    tcp = series(document, "port_type", "tcp_inet")
    assert Enum.map(tcp["series"], & &1["value"]) == [2, 0, 2]
    assert tcp["change"]["direction"] == "flat"

    cut = put_in(port_top(4, 15, 19, 0)["event"]["attributes"]["metrics"]["type_count"], 3)
    tcp = series(trends([port_top(1, 0, 10, 2), cut]), "port_type", "tcp_inet")
    assert Enum.map(tcp["series"], & &1["value"]) == [2]

    assert Trends.text(document) =~ "Port trend: cat 10 -> 16 (rising, +36/min) over 3 samples"
  end

  test "mailboxes are a series per process, ranked or watched, and say when ranking leaves gaps" do
    receipts = %{"name" => "Shop.Receipts", "pid" => "<0.210.0>", "message_queue_len" => 31}

    watch =
      poller(
        4,
        15,
        "process_watch",
        %{
          "watch_name" => "Shop.Receipts",
          "metrics" => %{"registered_name" => "Elixir.Shop.Receipts", "message_queue_len" => 0}
        },
        "<0.210.0>"
      )

    document =
      trends([
        process_top(1, 0, [pricing(91), receipts]),
        process_top(2, 5, [pricing(200)]),
        process_top(3, 10, [pricing(310), %{receipts | "message_queue_len" => 12}]),
        watch
      ])

    pricing = series(document, "message_queue_len", "Shop.Pricing")
    assert pricing["unit"] == "messages"
    assert pricing["pid"] == "<0.200.0>"
    assert pricing["source_kinds"] == ["process_top"]
    assert Enum.map(pricing["series"], & &1["value"]) == [91, 200, 310]
    assert pricing["per_min"] == 1_314
    assert pricing["coverage"] == "ranked"

    # A ranked-only series has no point where the process was not ranked,
    # never a zero; a watched sample joins the same process's series.
    receipts = series(document, "message_queue_len", "Shop.Receipts")

    assert Enum.map(receipts["series"], &{&1["at"], &1["value"]}) == [
             {at(0), 31},
             {at(10), 12},
             {at(15), 0}
           ]

    assert receipts["source_kinds"] == ["process_top", "process_watch"]
    # One watched point does not make the ranked stretch
    # (with its gap) continuous.
    assert receipts["coverage"] == "mixed"
    assert receipts["change"]["direction"] == "falling"

    # Growing mailboxes first.
    assert [first | _rest] =
             Enum.filter(document["poller"], &(&1["metric"] == "message_queue_len"))

    assert first["subject"] == "Shop.Pricing"

    text = Trends.text(document)

    assert text =~
             "Mailbox trend: Shop.Pricing 91 -> 310 (rising, +1314/min) over 3 samples (when ranked)"

    assert text =~
             "Mailbox trend: Shop.Receipts 31 -> 0 (falling, -124/min) over 3 samples (partly ranked)"
  end

  test "kinds narrow the series, windows bound the points, and a single sample has no growth" do
    entries =
      for n <- 1..30, do: vm(n, n * 5, 28 + n, 1_000_000 * n)

    entries = entries ++ [port_top(31, 200, 4, 0)]

    document = trends(entries, kinds: ["vm_sample"], windows: 5)

    assert Enum.map(document["poller"], & &1["metric"]) |> Enum.sort() == [
             "binary_bytes",
             "port_count"
           ]

    binary = series(document, "binary_bytes")
    assert binary["windows"] == 30
    assert [%{"value" => 26_000_000} | _] = binary["series"]
    assert [_, _, _, _, _] = binary["series"]
    # The change compares the first and last sample read, not the shown ones.
    assert binary["change"]["first"] == 1_000_000
    assert document["telemetry"] == [] and document["logger"] == []

    single = trends([port_top(1, 0, 4, 0)])
    cat = series(single, "port_type", "cat")
    assert cat["per_min"] == nil
    assert cat["change"]["direction"] == "flat"
  end

  test "series are bounded in number per group, and the omitted ones are counted" do
    workers =
      for n <- 1..40,
          do: %{
            "pid" => "<0.#{n}.0>",
            "initial_call" => "Worker.init/1",
            "message_queue_len" => n
          }

    document = trends([process_top(1, 0, workers), process_top(2, 5, workers)])

    mailboxes = Enum.filter(document["poller"], &(&1["metric"] == "message_queue_len"))
    assert Enum.count(mailboxes) == 10
    assert document["poller_omitted"]["message_queue_len"] == 30
    # Two workers with one initial call are two series, told apart by pid.
    assert mailboxes |> Enum.map(& &1["pid"]) |> Enum.uniq() |> length() == 10
  end

  test "no Poller events: the text says how to get these series" do
    document = trends([])
    assert document["poller"] == []
    assert Trends.text(document) =~ "--component poller"
  end

  # Smoke finding: a watched process that is also ranked had two points per
  # poller cycle. Events of one cycle (`cycle_id`) give one point.
  test "a ranked and watched process has one point per poller cycle" do
    cycle = fn entry, id -> put_in(entry["event"]["attributes"]["cycle_id"], id) end

    watch = fn receipt, s, queue ->
      poller(
        receipt,
        s,
        "process_watch",
        %{"watch_name" => "Shop.Pricing", "metrics" => %{"message_queue_len" => queue}},
        "<0.200.0>"
      )
    end

    document =
      trends([
        cycle.(process_top(1, 0, [pricing(103)]), "c1"),
        cycle.(watch.(2, 0, 103), "c1"),
        cycle.(process_top(3, 5, [pricing(110)]), "c2"),
        cycle.(watch.(4, 5, 111), "c2")
      ])

    pricing = series(document, "message_queue_len", "Shop.Pricing")
    assert pricing["windows"] == 2
    assert Enum.map(pricing["series"], & &1["value"]) == [103, 111]
    assert pricing["coverage"] == "watched"
  end

  # A census cut by the scan limit says nothing of
  # the types it did not list, even when it lists every type it found.
  test "only a complete port census establishes a zero" do
    limited = fn receipt, s, cat, tcp ->
      entry = port_top(receipt, s, cat, tcp)
      put_in(entry["event"]["attributes"]["unavailable"], ["scan_limit"])
    end

    document = trends([port_top(1, 0, 10, 0), limited.(2, 5, 0, 3), port_top(3, 10, 12, 3)])
    cat = series(document, "port_type", "cat")
    assert Enum.map(cat["series"], & &1["value"]) == [10, 12]
    assert cat["change"]["direction"] == "rising"

    # A ranking cut to top_ports (more types than listed) gives no zero
    # either; a complete census does.
    cut = put_in(port_top(2, 5, 0, 3)["event"]["attributes"]["metrics"]["type_count"], 4)
    complete = port_top(2, 5, 0, 3)

    assert [10, 12] ==
             trends([port_top(1, 0, 10, 0), cut, port_top(3, 10, 12, 3)])
             |> series("port_type", "cat")
             |> Map.fetch!("series")
             |> Enum.map(& &1["value"])

    assert [10, 0, 12] ==
             trends([port_top(1, 0, 10, 0), complete, port_top(3, 10, 12, 3)])
             |> series("port_type", "cat")
             |> Map.fetch!("series")
             |> Enum.map(& &1["value"])
  end

  # A type first seen after complete censuses that
  # lacked it grew from zero.
  test "a port type that appears later starts from the zero of earlier complete censuses" do
    limited = put_in(port_top(2, 30, 0, 2)["event"]["attributes"]["unavailable"], ["scan_limit"])

    document = trends([port_top(1, 0, 0, 2), limited, port_top(3, 60, 10, 2)])
    cat = series(document, "port_type", "cat")

    # The complete census at 0 s lacked cat; the limited one at 30 s says
    # nothing about it.
    assert Enum.map(cat["series"], &{&1["at"], &1["value"]}) == [{at(0), 0}, {at(60), 10}]
    assert cat["change"] == %{"first" => 0, "last" => 10, "delta" => 10, "direction" => "rising"}
    assert cat["per_min"] == 10
    assert cat["windows"] == 2
  end

  # Compacting the point buffer kept the first and
  # the recent points only, and lost the window's peak.
  test "the maximum covers every sample read, across compaction and same-cycle replacement" do
    samples =
      for n <- 1..1_001 do
        vm(n, n, 28, if(n == 2, do: 999_999, else: 100))
      end

    binary = series(trends(samples, windows: 5), "binary_bytes")
    assert binary["windows"] == 1_001
    assert binary["max"] == 999_999
    assert [_, _, _, _, _] = binary["series"]

    # A later sample of the same cycle replaces the earlier one, and so
    # does its value in the maximum.
    cycle = fn entry, id -> put_in(entry["event"]["attributes"]["cycle_id"], id) end

    replaced =
      trends([
        cycle.(vm(1, 0, 28, 100), "c1"),
        cycle.(vm(2, 5, 28, 5_000), "c2"),
        cycle.(vm(3, 5, 28, 200), "c2")
      ])

    binary = series(replaced, "binary_bytes")
    assert binary["max"] == 200
    assert binary["windows"] == 2
    assert Enum.map(binary["series"], & &1["value"]) == [100, 200]
  end

  test "mailbox coverage is watched only when every point is a direct sample" do
    watch = fn receipt, s, queue ->
      poller(
        receipt,
        s,
        "process_watch",
        %{"watch_name" => "Shop.Pricing", "metrics" => %{"message_queue_len" => queue}},
        "<0.200.0>"
      )
    end

    cycle = fn entry, id -> put_in(entry["event"]["attributes"]["cycle_id"], id) end

    watched =
      trends([
        cycle.(watch.(1, 0, 10), "c1"),
        cycle.(process_top(2, 0, [pricing(10)]), "c1"),
        cycle.(watch.(3, 5, 20), "c2")
      ])

    # A ranking in the same cycle as a direct sample keeps the point direct.
    assert series(watched, "message_queue_len", "Shop.Pricing")["coverage"] == "watched"
  end

  # The backfill took every complete census, so two of one
  # cycle gave two zero points, and a census introducing a type gave one
  # from its own cycle too.
  test "backfilled zeros follow one point per poller cycle" do
    cycle = fn entry, id -> put_in(entry["event"]["attributes"]["cycle_id"], id) end

    repeated =
      trends([
        cycle.(port_top(1, 0, 0, 2), "c1"),
        cycle.(port_top(2, 30, 0, 2), "c1"),
        cycle.(port_top(3, 60, 10, 2), "c2")
      ])

    cat = series(repeated, "port_type", "cat")
    assert Enum.map(cat["series"], &{&1["at"], &1["value"]}) == [{at(30), 0}, {at(60), 10}]
    assert cat["windows"] == 2
    assert cat["first_at"] == at(30)
    assert cat["per_min"] == 20

    # A replacement census that introduces the type is that cycle's point.
    introduced =
      trends([
        cycle.(port_top(1, 0, 0, 2), "c1"),
        cycle.(port_top(2, 30, 0, 2), "c2"),
        cycle.(port_top(3, 40, 7, 2), "c2")
      ])

    cat = series(introduced, "port_type", "cat")
    assert Enum.map(cat["series"], &{&1["at"], &1["value"]}) == [{at(0), 0}, {at(40), 7}]
    assert cat["windows"] == 2
  end
end
