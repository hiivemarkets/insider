defmodule Insider.Live.DigestTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Digest

  @t0 ~U[2026-10-22 05:01:51.107000Z]

  defp at(ms), do: @t0 |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

  defp entry(receipt, event), do: %{"receipt" => receipt, "event" => event, "redactions" => []}

  defp terminated(
         receipt,
         ms,
         offender \\ "atom:Elixir.Shop.Inventory",
         fingerprint \\ "b1f96d655cf7de80aa"
       ) do
    entry(receipt, %{
      "source" => "logger",
      "kind" => "supervisor_child_terminated",
      "severity" => "error",
      "wall_time" => at(ms),
      "subject" => %{"value" => "<0.1.#{receipt}>"},
      "attributes" => %{
        "offender_id" => offender,
        "supervisor" => "atom:Elixir.Shop.Supervisor",
        "restart_type" => "permanent",
        "reason_class" => "abnormal",
        "reason_fingerprint" => fingerprint
      },
      "payload" => nil
    })
  end

  defp stop(receipt, ms, us, severity \\ "info") do
    entry(receipt, %{
      "source" => "telemetry",
      "kind" => "shop.checkout.stop",
      "severity" => severity,
      "wall_time" => at(ms),
      "subject" => %{"value" => "<0.2.#{receipt}>"},
      "attributes" => %{
        "lifecycle_phase" => "event",
        "measurements" => %{"duration" => us * 1_000},
        "durations_us" => %{"duration" => us}
      },
      "payload" => %{
        "metadata" => %{"result" => "{:error, {:timeout, {GenServer, :call, [Shop.Pricing]}}}"}
      }
    })
  end

  defp summary(receipt, ms, p95) do
    entry(receipt, %{
      "source" => "telemetry",
      "kind" => "shop.pricing.lookup",
      "severity" => "info",
      "wall_time" => at(ms),
      "subject" => nil,
      "attributes" => %{
        "lifecycle_phase" => "summary",
        "summary" => %{
          "count" => 40,
          "errors" => 0,
          "duration_p50_us" => 0,
          "duration_p95_us" => p95,
          "duration_max_us" => p95 + 6,
          "interval_ms" => 5_000
        }
      }
    })
  end

  defp vm(receipt, ms, processes, ets) do
    entry(receipt, %{
      "source" => "poller",
      "kind" => "vm_sample",
      "severity" => "debug",
      "wall_time" => at(ms),
      "attributes" => %{
        "metrics" => %{"process_count" => processes, "ets_bytes" => ets, "note" => "x"}
      }
    })
  end

  defp top(receipt, ms, length) do
    entry(receipt, %{
      "source" => "poller",
      "kind" => "process_top",
      "severity" => "debug",
      "wall_time" => at(ms),
      "attributes" => %{
        "metrics" => %{
          "by_message_queue_len" => [
            %{"pid" => "<0.9.0>", "name" => "Shop.Pricing", "message_queue_len" => length}
          ]
        }
      }
    })
  end

  defp logged(receipt, message, mfa) do
    entry(receipt, %{
      "source" => "logger",
      "kind" => "logger_message",
      "severity" => "error",
      "wall_time" => at(receipt),
      "subject" => %{"value" => "<0.3.#{receipt}>"},
      "attributes" => %{"domain" => ["elixir"]},
      "payload" => %{"level" => "error", "message" => message, "metadata" => %{"mfa" => mfa}}
    })
  end

  defp batch(events, extra \\ %{}) do
    Map.merge(
      %{
        "state" => "running",
        "lease_remaining_ms" => 100_000,
        "disclosure_profile" => "rich",
        "next_cursor" => events |> List.last(%{"receipt" => 0}) |> Map.fetch!("receipt"),
        "next_receipt" => 40,
        "events" => events,
        "gaps" => [],
        "filtered" => nil
      },
      extra
    )
  end

  defp fold(batches) do
    batches
    |> Enum.reduce(Digest.new("live-6", 0), &Digest.add(&2, &1))
    |> Digest.finish(nil, "shop@host")
  end

  defp traced(receipt, kind, attributes, payload \\ nil, severity \\ "info") do
    entry(receipt, %{
      "source" => "calls",
      "kind" => kind,
      "severity" => severity,
      "wall_time" => at(receipt),
      "subject" => if(kind == "call.stopped", do: nil, else: %{"value" => "<0.4.#{receipt}>"}),
      "attributes" => attributes,
      "payload" => payload
    })
  end

  # The maximum came from the first 1,000 results.
  test "a call trace's max is exact over every result, and its median names its sample" do
    reserve = "Shop.Inventory.handle_call/3"

    returns =
      for n <- 1..1_001 do
        us = if n == 1_001, do: 9_000_000, else: 1
        traced(n, "call.return", %{"function" => reserve, "call_id" => n, "duration_us" => us})
      end

    assert %{"functions" => [row]} = fold([batch(returns, %{"next_receipt" => 1_001})])["calls"]

    assert %{
             "returns" => 1_001,
             "timed" => 1_001,
             "max_us" => 9_000_000,
             "p50_us" => 1,
             "p50_sample" => 1_000
           } = row
  end

  test "call traces: per function counts, durations, failures with their first arguments, and stops" do
    reserve = "Shop.Inventory.handle_call/3"
    fig = ["{:reserve, \"fig\", 1}", "{#PID<0.1.0>, ...}", %{"fig" => 0}]
    reason = %{"__struct__" => "Elixir.ArithmeticError", "message" => "bad argument"}

    failed = fn receipt, id, us, arguments, exception, class ->
      traced(
        receipt,
        "call.exception",
        %{
          "function" => reserve,
          "call_id" => id,
          "duration_us" => us,
          "class" => class,
          "exception" => exception
        },
        %{"reason" => reason, "arguments" => arguments},
        "error"
      )
    end

    digest =
      fold([
        batch([
          traced(1, "call", %{"function" => reserve, "call_id" => 1}),
          traced(2, "call.return", %{"function" => reserve, "call_id" => 1, "duration_us" => 10}),
          traced(3, "call", %{"function" => reserve, "call_id" => 2}),
          failed.(4, 2, 30, fig, "ArithmeticError", "error"),
          traced(5, "call", %{"function" => reserve, "call_id" => 3}),
          failed.(6, 3, 20, ["later"], "ArithmeticError", "error"),
          traced(7, "call", %{"function" => reserve, "call_id" => 4}),
          failed.(8, 4, nil, nil, nil, "exit"),
          traced(9, "call.stopped", %{"reason" => "calls_max", "calls" => 4}, nil, "warning")
        ])
      ])

    assert %{"functions" => [row], "stopped" => [stop]} = digest["calls"]
    assert stop == %{"reason" => "calls_max", "calls" => 4, "receipt" => 9}

    assert %{
             "function" => ^reserve,
             "calls" => 4,
             "returns" => 1,
             "exceptions" => 3,
             "p50_us" => 20,
             "max_us" => 30,
             "failures" => [arithmetic, exit]
           } = row

    assert %{
             "class" => "error",
             "exception" => "ArithmeticError",
             "count" => 2,
             "first_receipt" => 4,
             "first_call_id" => 2,
             "arguments" => ^fig,
             "reason" => ^reason
           } = arithmetic

    assert %{"class" => "exit", "exception" => nil, "count" => 1} = exit

    signatures = Enum.map(digest["error_signatures"], &{&1["signature"], &1["count"]})

    assert signatures == [
             {"call.exception Shop.Inventory.handle_call/3 ArithmeticError", 2},
             {"call.exception Shop.Inventory.handle_call/3 exit", 1}
           ]

    text = Digest.text(digest)

    assert text =~
             "Calls: Shop.Inventory.handle_call/3 4 calls, 1 returns, 3 exceptions (max 30 us); " <>
               "2x ArithmeticError, first at receipt 4 with arguments " <>
               "({:reserve, \"fig\", 1}, {#PID<0.1.0>, ...}, %{\"fig\" => 0})."

    assert text =~ "Call trace stopped (calls_max) after 4 calls, at receipt 9."

    assert %{"timed" => 3, "p50_sample" => 3} = row

    # A window without call traces has none.
    assert fold([batch([terminated(1, 0)])])["calls"] == nil
  end

  test "a crash loop is grouped by offender and reason, with its period" do
    digest =
      fold([
        batch([terminated(1, 0), terminated(2, 3_000), terminated(3, 6_000)]),
        batch([
          terminated(4, 9_000),
          terminated(5, 9_500, "atom:Elixir.Shop.Inventory", "other"),
          terminated(6, 9_600, "atom:Elixir.Shop.Once")
        ])
      ])

    assert [loop] = digest["crash_loops"]

    assert %{
             "offender" => "Shop.Inventory",
             "offender_id" => "atom:Elixir.Shop.Inventory",
             "restart_type" => "permanent",
             "reason_fingerprint" => "b1f96d655cf7de80aa",
             "restarts" => 4,
             "period_ms" => 3_000,
             "period_min_ms" => 3_000,
             "period_max_ms" => 3_000,
             "first_receipt" => 1,
             "last_receipt" => 4
           } = loop

    assert loop["first_wall_time"] == at(0)

    assert digest["counts"]["by_offender"] == %{
             "atom:Elixir.Shop.Inventory" => 5,
             "atom:Elixir.Shop.Once" => 1
           }

    assert digest["counts"]["by_kind"] == %{"supervisor_child_terminated" => 6}
    assert digest["window"]["span_ms"] == 9_600
    assert digest["window"]["reads"] == 2
    assert digest["window"]["complete"]
    assert digest["disclosure_profile"] == "rich"

    text = Digest.text(digest)
    assert text =~ "Crash loop: Shop.Inventory (permanent) terminated 4 times, every 3.0 s"
    assert text =~ "(rich disclosure)"
  end

  test "latency tables come from summaries and recorded durations, slowest p95 first" do
    events =
      for receipt <- 1..19, do: stop(receipt, receipt * 100, 5_001_459, "error")

    digest =
      fold([
        batch(
          events ++
            [stop(20, 2_000, 800), summary(21, 5_000, 900_994), summary(22, 10_000, 850_000)]
        )
      ])

    assert [slowest, summarised] = digest["latency"]

    assert %{
             "kind" => "shop.checkout.stop",
             "from" => "events",
             "count" => 20,
             "errors" => 19,
             "p50_us" => 5_001_459,
             "p95_us" => 5_001_459,
             "max_us" => 5_001_459
           } = slowest

    assert %{
             "kind" => "shop.pricing.lookup",
             "from" => "summaries",
             "count" => 80,
             "p95_us" => 850_000,
             "max_us" => 901_000
           } = summarised

    assert [_first, _second] = summarised["intervals"]

    text = Digest.text(digest)

    assert text =~
             "Slowest: shop.checkout.stop p50 5.00 s, p95 5.00 s, max 5.00 s over 20 events, 19 errors"

    # The failing stops carry the exit itself, so the hint has evidence.
    assert text =~
             "19 errors; pinned near 5 s, consistent with GenServer.call timeouts " <>
               "(19 {:timeout, {GenServer, :call, _}} exits seen)"

    assert [%{"call_timeouts" => 19} | _rest] = digest["latency"]

    assert text =~
             "Latency: shop.pricing.lookup p50 0 us, p95 850 ms, max 901 ms over 80 summarised events"
  end

  test "error signatures name code, not values, and never quote an HTML page" do
    digest =
      fold([
        batch([
          logged(
            1,
            "** (ArithmeticError) bad argument in arithmetic expression: 3 / 0",
            "{Shop.Inventory, :handle_call, 3}"
          ),
          logged(
            2,
            "** (ArithmeticError) bad argument in arithmetic expression: 5 / 0",
            "{Shop.Inventory, :handle_call, 3}"
          ),
          logged(3, "<!DOCTYPE html><html><body>debugger #PID<0.1.0></body></html>", nil),
          stop(4, 4, 812, "error"),
          stop(5, 5, 900, "info")
        ])
      ])

    assert [first | rest] = digest["error_signatures"]

    assert %{
             "signature" =>
               "logger_message {Shop.Inventory, :handle_call, 3} ArithmeticError ** (ArithmeticError) bad argument in arithmetic expression: N / N",
             "count" => 2,
             "processes" => 2,
             "first_receipt" => 1,
             "last_receipt" => 2
           } = first

    signatures = Enum.map(rest, & &1["signature"])
    assert "logger_message [html]" in signatures
    assert Enum.any?(signatures, &(&1 =~ "shop.checkout.stop result={:error, {:timeout"))
    refute Jason.encode!(digest) =~ "debugger"
    assert Digest.text(digest) =~ "Top errors: 2x logger_message"
  end

  # A process row is one process, keyed by
  # its pid, whatever label the evidence gives it.
  test "unregistered processes that share an initial call stay apart" do
    ranking = fn receipt, lengths ->
      entry(receipt, %{
        "source" => "poller",
        "kind" => "process_top",
        "severity" => "debug",
        "wall_time" => at(receipt),
        "attributes" => %{
          "metrics" => %{
            "by_message_queue_len" =>
              for {pid, length} <- lengths do
                %{
                  "pid" => pid,
                  "name" => nil,
                  "initial_call" => "Agent.Server.init/1",
                  "message_queue_len" => length
                }
              end
          }
        }
      })
    end

    digest =
      fold([
        batch([
          ranking.(1, [{"<0.10.0>", 100}, {"<0.11.0>", 20}]),
          ranking.(2, [{"<0.10.0>", 120}, {"<0.11.0>", 20}])
        ])
      ])

    assert [
             %{
               "pid" => "<0.10.0>",
               "process" => "Agent.Server.init/1",
               "first_message_queue_len" => 100,
               "message_queue_len" => 120
             },
             %{
               "pid" => "<0.11.0>",
               "process" => "Agent.Server.init/1",
               "first_message_queue_len" => 20,
               "message_queue_len" => 20
             }
           ] = digest["processes"]
  end

  test "a registered process ranked and watched is one row" do
    watch =
      entry(3, %{
        "source" => "poller",
        "kind" => "process_watch",
        "severity" => "debug",
        "wall_time" => at(3),
        "subject" => %{"namespace" => "process", "value" => "<0.9.0>"},
        "attributes" => %{
          "watch_name" => "Shop.Pricing",
          "metrics" => %{"registered_name" => "Elixir.Shop.Pricing", "message_queue_len" => 40}
        }
      })

    digest = fold([batch([top(1, 0, 10), top(2, 1_000, 30), watch])])

    assert [
             %{
               "pid" => "<0.9.0>",
               "process" => "Shop.Pricing",
               "first_message_queue_len" => 10,
               "message_queue_len" => 40,
               "max_message_queue_len" => 40
             }
           ] = digest["processes"]
  end

  test "VM deltas, the longest mailbox, filtered counts, and gaps cover the window" do
    gaps1 = [
      %{"reason" => "evicted", "count" => 3, "scope" => "receipt_range"},
      %{"reason" => "logger_shed", "count" => 2, "scope" => "since_session_start"}
    ]

    gaps2 = [
      %{"reason" => "evicted", "count" => 4, "scope" => "receipt_range"},
      %{"reason" => "logger_shed", "count" => 9, "scope" => "since_cursor_issued"},
      %{"reason" => "poller_accounting_unavailable", "count" => nil, "scope" => "unknown"}
    ]

    filtered = %{
      "scope" => "since_session_start",
      "logger" => %{"level" => 120, "include" => 0},
      "telemetry" => %{"shop.checkout.stop" => %{"min_duration" => 3}},
      "view" => %{}
    }

    digest =
      fold([
        batch([vm(1, 0, 100, 1_000), top(2, 0, 10)], %{"gaps" => gaps1, "filtered" => filtered}),
        batch([vm(3, 30_000, 340, 4_000), top(4, 30_000, 2_345)], %{
          "gaps" => gaps2,
          "filtered" => %{"logger" => %{"level" => 1}}
        })
      ])

    assert %{
             "samples" => 2,
             "span_ms" => 30_000,
             "metrics" => %{
               "process_count" => %{"first" => 100, "last" => 340, "delta" => 240},
               "ets_bytes" => %{"first" => 1_000, "last" => 4_000, "delta" => 3_000}
             }
           } = digest["vm"]

    refute Map.has_key?(digest["vm"]["metrics"], "note")

    assert [
             %{
               "process" => "Shop.Pricing",
               "message_queue_len" => 2_345,
               "first_message_queue_len" => 10,
               "max_message_queue_len" => 2_345
             }
           ] = digest["processes"]

    assert digest["filtered"] == filtered

    assert digest["gaps"] == [
             %{"reason" => "evicted", "count" => 7, "scope" => "receipt_range"},
             %{"reason" => "logger_shed", "count" => 2, "scope" => "since_session_start"},
             %{"reason" => "poller_accounting_unavailable", "count" => nil, "scope" => "unknown"}
           ]

    text = Digest.text(digest)
    assert text =~ "Longest mailbox: Shop.Pricing 2345 messages"
    # Without the Poller's footprint fields a total says it includes Insider's.
    assert text =~
             "VM: processes (including Insider's own) 100 -> 340 (+240), ETS (including Insider's own) 1000 B -> 3 KiB (+2 KiB)."

    assert text =~ "Not recorded (filters): 120 Logger and 3 Telemetry events"
    # A loss says why and what prevents it.
    assert text =~
             "Lost: evicted 7, logger_shed 2, poller_accounting_unavailable unknown. " <>
               "Evicted: the Recorder was full and dropped its oldest events; read sooner, or record less (the hints say what)."
  end

  defp burst(receipt, fields) do
    entry(receipt, %{
      "source" => "logger",
      "kind" => "logger_summary",
      "severity" => "error",
      "wall_time" => at(receipt * 1_000),
      "attributes" => %{
        "summary" =>
          Map.merge(
            %{
              "count" => 10,
              "level" => "error",
              "template" => "checkout failed for N",
              "template_fingerprint" => "aaaaaaaaaaaaaaaa",
              "call_site" => %{"module" => "Shop.Checkout", "function" => "run/2", "line" => 96},
              "call_site_fingerprint" => "cccccccccccccccc",
              "call_sites" => 1,
              "exemplar_receipt" => receipt - 1,
              "exemplar_lost" => false,
              "interval_ms" => 5_000
            },
            fields
          )
      }
    })
  end

  test "Logger bursts are one per template and call site, with the overflow row on its own" do
    database = %{
      "template" => "database unavailable",
      "template_fingerprint" => "bbbbbbbbbbbbbbbb"
    }

    overflow = %{
      "overflow" => true,
      "distinct_lost" => 4,
      "count" => 30,
      "template" => nil,
      "template_fingerprint" => "overflow",
      "call_site" => nil,
      "call_site_fingerprint" => nil,
      "call_sites" => nil,
      "exemplar_receipt" => nil
    }

    digest =
      fold([
        batch([
          burst(2, %{}),
          burst(4, Map.put(database, "count", 3)),
          burst(6, overflow),
          burst(8, %{"count" => 25})
        ])
      ])

    assert [checkout, folded, unavailable] = digest["logger_bursts"]
    assert %{"overflow" => true, "count" => 30, "distinct_lost" => 4} = folded
    assert %{"count" => 35, "windows" => 2, "exemplar_receipts" => [1, 7]} = checkout
    assert %{"template" => "database unavailable", "count" => 3} = unavailable

    text = Digest.text(digest)
    assert text =~ ~s(Burst: 35 error "checkout failed for N" from Shop.Checkout.run/2:96)
    assert text =~ ~s(Burst: 3 error "database unavailable" from Shop.Checkout.run/2:96)
    assert text =~ "Burst overflow: 30 error messages"
  end

  test "a summary's exemplar losses reach its latency row, and a withheld duration keeps its receipt" do
    lossy = fn receipt, fields ->
      summary(receipt, receipt * 1_000, 900_000)
      |> update_in(["event", "attributes", "summary"], &Map.merge(&1, fields))
    end

    digest =
      fold([
        batch([
          lossy.(3, %{
            "errors" => 1,
            "exemplars" => [
              %{"receipt" => 1, "roles" => ["slowest"], "duration_us" => nil, "error" => false},
              %{
                "receipt" => 2,
                "roles" => ["slowest"],
                "duration_us" => 900_000,
                "error" => false
              }
            ],
            "exemplars_lost" => 2,
            "first_error_retained" => false
          })
        ])
      ])

    assert [row] = digest["latency"]
    assert Enum.map(row["exemplars"], & &1["receipt"]) == [2, 1]
    assert row["exemplars_lost"] == 2
    assert row["first_error_lost_intervals"] == 1

    assert [%{"exemplars_lost" => 2, "first_error_retained" => false}] =
             hd(digest["trends"])["series"]

    assert Digest.text(digest) =~
             "exemplar receipts 2, 1; 2 exemplar candidates lost, first error not retained in 1 interval"
  end

  test "an empty or unfinished window says so" do
    empty = fold([batch([], %{"next_cursor" => 40})])
    assert %{"events" => 0, "first_receipt" => nil, "complete" => true} = empty["window"]
    assert empty["latency"] == [] and empty["crash_loops"] == [] and empty["vm"] == nil
    assert Digest.text(empty) =~ "no events after receipt 0"

    unfinished =
      Digest.new("live-6", 0)
      |> Digest.add(batch([stop(1, 0, 10)], %{"next_cursor" => 1}))
      |> Digest.finish("deadline", "shop@host")

    assert %{"complete" => false, "stopped_by" => "deadline", "next_cursor" => 1} =
             unfinished["window"]

    assert Digest.text(unfinished) =~ "Incomplete (deadline): read on with --since 1."
  end

  test "a five-second latency without a call-timeout exit is reported as latency only" do
    healthy =
      for receipt <- 1..5 do
        entry = stop(receipt, receipt, 5_000_000)
        put_in(entry, ["event", "payload", "metadata", "result"], "ok")
      end

    digest = fold([batch(healthy)])
    assert [%{"kind" => "shop.checkout.stop", "call_timeouts" => 0}] = digest["latency"]

    text = Digest.text(digest)

    assert text =~
             "Slowest: shop.checkout.stop p50 5.00 s, p95 5.00 s, max 5.00 s over 5 events, 0 errors."

    refute text =~ "GenServer"

    # A logged exit is evidence too, for the slowest kind.
    logged =
      logged(
        6,
        "** (exit) exited in: GenServer.call(Shop.Pricing, :price, 5000)\n    ** (EXIT) time out " <>
          "{:timeout, {GenServer, :call, [Shop.Pricing, :price, 5000]}}",
        "{Shop.Checkout, :run, 2}"
      )

    assert Digest.text(fold([batch(healthy ++ [logged])])) =~
             "consistent with GenServer.call timeouts (1 {:timeout, {GenServer, :call, _}} exits seen)"
  end

  defp deadline(ms \\ 3_000), do: System.monotonic_time(:millisecond) + ms

  defp stops(range), do: for(receipt <- range, do: stop(receipt, receipt, 10))

  test "a paginated digest stops at the newest receipt its first read saw while events keep arriving" do
    parent = self()

    # The first read sees receipts up to 600 and returns 500 of them; 100
    # more arrive before the second read, which is bounded at 600.
    reader = fn cursor, options, budget ->
      send(parent, {:read, cursor, options["limit"], options["upto"], budget})

      case cursor do
        0 ->
          {:ok,
           batch(stops(1..500), %{"cursor" => 0, "next_cursor" => 500, "next_receipt" => 600})}

        500 ->
          {:ok,
           batch(stops(501..600), %{"cursor" => 500, "next_cursor" => 600, "next_receipt" => 700})}
      end
    end

    assert {:ok, digest} = Digest.read("live-6", {:cursor, 0}, reader, deadline(), "shop@host")

    assert %{
             "cursor" => 0,
             "next_cursor" => 600,
             "upto" => 600,
             "events" => 600,
             "last_receipt" => 600,
             "reads" => 2,
             "complete" => true
           } = digest["window"]

    assert digest["counts"]["by_kind"] == %{"shop.checkout.stop" => 600}
    assert [%{"count" => 600}] = digest["latency"]
    # The second read asks only for what is left of the window, bounded at it.
    assert_received {:read, 0, 500, nil, budget} when budget <= 3_000
    assert_received {:read, 500, 100, 600, _budget}
  end

  test "a read that passes the window's end stops the digest instead of being folded" do
    reader = fn
      0, _options, _budget ->
        {:ok, batch(stops(1..5), %{"cursor" => 0, "next_cursor" => 5, "next_receipt" => 10})}

      5, _options, _budget ->
        {:ok, batch(stops(6..12), %{"cursor" => 5, "next_cursor" => 12, "next_receipt" => 12})}
    end

    assert {:ok, digest} = Digest.read("live-6", {:cursor, 0}, reader, deadline(), "shop@host")

    assert %{
             "events" => 5,
             "next_cursor" => 5,
             "complete" => false,
             "stopped_by" => "read_past_window"
           } =
             digest["window"]
  end

  test "latest-N ends at the newest receipt the lookup saw, and losses past it are not counted" do
    parent = self()

    reader = fn
      "latest", _options, budget ->
        send(parent, {:lookup, budget})
        {:ok, batch([], %{"cursor" => 600, "next_cursor" => 600, "next_receipt" => 600})}

      400, options, _budget ->
        send(parent, {:read, 400, options["limit"], options["upto"]})

        # The bounded read reports the window's own losses.
        {:ok,
         batch([], %{
           "cursor" => 400,
           "next_cursor" => 600,
           "next_receipt" => 700,
           "gaps" => [%{"reason" => "evicted", "count" => 200, "scope" => "receipt_range"}]
         })}
    end

    assert {:ok, digest} = Digest.read("live-6", {:last, 200}, reader, deadline(), "shop@host")

    assert %{
             "cursor" => 400,
             "next_cursor" => 600,
             "upto" => 600,
             "events" => 0,
             "complete" => true
           } =
             digest["window"]

    assert digest["gaps"] == [
             %{"reason" => "evicted", "count" => 200, "scope" => "receipt_range"}
           ]

    assert_received {:lookup, _budget}
    assert_received {:read, 400, 200, 600}
  end

  test "one budget covers the latest-N lookup and every read" do
    parent = self()

    reader = fn cursor, _options, budget ->
      send(parent, {:budget, cursor, budget})
      {:ok, batch([], %{"cursor" => 0, "next_cursor" => 5, "next_receipt" => 5})}
    end

    assert {:ok, _digest} =
             Digest.read("live-6", {:last, 5}, reader, deadline(1_000), "shop@host")

    assert_received {:budget, "latest", lookup} when lookup <= 1_000
    assert_received {:budget, 0, read} when read <= lookup

    # No time left: nothing is read and the digest is a timeout.
    never = fn _cursor, _options, _budget -> flunk("read past the deadline") end

    assert {:error, %{"code" => "timeout"}} =
             Digest.read("live-6", {:last, 5}, never, deadline(-1), "shop@host")

    # A failure after the first read ends the window early and says so.
    failing = fn
      0, _options, _budget ->
        {:ok, batch(stops(1..2), %{"cursor" => 0, "next_cursor" => 2, "next_receipt" => 4})}

      2, _options, _budget ->
        {:error, %{"code" => "busy"}}
    end

    assert {:ok,
            %{"window" => %{"complete" => false, "stopped_by" => "busy", "next_cursor" => 2}}} =
             Digest.read("live-6", {:cursor, 0}, failing, deadline(), "shop@host")

    stalled = fn _cursor, _options, _budget ->
      {:ok, batch([], %{"cursor" => 0, "next_cursor" => 0, "next_receipt" => 4})}
    end

    assert {:ok, %{"window" => %{"stopped_by" => "no_progress"}}} =
             Digest.read("live-6", {:cursor, 0}, stalled, deadline(), "shop@host")
  end

  test "with no time left a cursor read is a timeout, and running out mid-window stops it" do
    never = fn _cursor, _options, _budget -> flunk("read past the deadline") end

    assert {:error, %{"code" => "timeout"}} =
             Digest.read("live-6", {:cursor, 0}, never, deadline(-1), "shop@host")

    # The first read spends the budget below the read floor: the window is
    # what it read, stopped by the deadline.
    slow = fn 0, _options, _budget ->
      Process.sleep(250)
      {:ok, batch(stops(1..2), %{"cursor" => 0, "next_cursor" => 2, "next_receipt" => 4})}
    end

    assert {:ok, digest} = Digest.read("live-6", {:cursor, 0}, slow, deadline(400), "shop@host")

    assert %{"complete" => false, "stopped_by" => "deadline", "events" => 2, "next_cursor" => 2} =
             digest["window"]

    assert digest["schema"] == Digest.schema()
  end

  test "entries without an event are skipped and events without a usable wall time keep the span" do
    cart = fn receipt, wall_time, attributes ->
      entry(receipt, %{
        "source" => "telemetry",
        "kind" => "shop.cart.stop",
        "severity" => "info",
        "wall_time" => wall_time,
        "attributes" => attributes
      })
    end

    digest =
      fold([
        batch(
          [
            %{"receipt" => 1},
            stop(2, 0, 10),
            cart.(3, "yesterday", %{"durations_us" => %{"queue" => 5}}),
            cart.(4, nil, %{})
          ],
          %{"gaps" => nil, "disclosure_profile" => nil}
        )
      ])

    assert %{
             "events" => 3,
             "first_receipt" => 2,
             "last_receipt" => 4,
             "first_wall_time" => first,
             "last_wall_time" => first,
             "span_ms" => 0
           } = digest["window"]

    assert first == at(0)
    assert digest["counts"]["by_kind"] == %{"shop.checkout.stop" => 1, "shop.cart.stop" => 2}
    # A durations map without a total duration is no latency sample.
    assert Enum.map(digest["latency"], & &1["kind"]) == ["shop.checkout.stop"]
    assert digest["gaps"] == []

    text = Digest.text(digest)
    assert text =~ "Insider digest of live-6 on shop@host: receipts 2-4, 3 events"
    refute text =~ "disclosure"
  end

  test "process rows come only from samples with a queue length, named as an agent writes them" do
    sample = fn receipt, pid, metrics ->
      entry(receipt, %{
        "source" => "poller",
        "kind" => "process_sample",
        "severity" => "debug",
        "wall_time" => at(receipt),
        "subject" => %{"namespace" => "process", "value" => pid},
        "attributes" => %{"metrics" => metrics}
      })
    end

    unranked =
      entry(3, %{
        "source" => "poller",
        "kind" => "process_top",
        "severity" => "debug",
        "wall_time" => at(3),
        "attributes" => %{"metrics" => %{"by_memory" => []}}
      })

    lengthless = top(4, 4, nil)

    digest =
      fold([
        batch([
          sample.(1, "<0.20.0>", %{
            "registered_name" => "Elixir.Shop.Cart",
            "message_queue_len" => 7
          }),
          sample.(2, "<0.21.0>", %{"registered_name" => "cart_registry", "message_queue_len" => 3}),
          unranked,
          lengthless
        ])
      ])

    assert [
             %{"pid" => "<0.20.0>", "process" => "Shop.Cart", "message_queue_len" => 7},
             %{"pid" => "<0.21.0>", "process" => "cart_registry", "message_queue_len" => 3}
           ] = digest["processes"]
  end

  test "error signatures read exception structs, HTTP statuses, and Logger domains" do
    failing = fn receipt, source, kind, attributes, payload ->
      entry(receipt, %{
        "source" => source,
        "kind" => kind,
        "severity" => "error",
        "wall_time" => at(receipt),
        "subject" => %{"value" => "<0.5.#{receipt}>"},
        "attributes" => attributes,
        "payload" => payload
      })
    end

    digest =
      fold([
        batch([
          failing.(1, "telemetry", "shop.repo.query", %{}, %{
            "metadata" => %{
              "status" => 503,
              "reason" => %{"__struct__" => "Elixir.DBConnection.ConnectionError"},
              "result" => 42
            }
          }),
          failing.(2, "telemetry", "shop.repo.query", %{}, %{
            "metadata" => %{"error" => %{"__struct__" => "shop_driver_error"}}
          }),
          failing.(3, "logger", "logger_message", %{"domain" => ["otp", "sasl"]}, %{
            "message" => %{"report" => "crash"}
          }),
          failing.(
            4,
            "logger",
            "supervisor_child_terminated",
            %{"reason_class" => "abnormal"},
            nil
          )
        ])
      ])

    assert Enum.map(digest["error_signatures"], & &1["signature"]) == [
             "shop.repo.query DBConnection.ConnectionError status=503",
             "shop.repo.query shop_driver_error",
             "logger_message otp.sasl",
             "supervisor_child_terminated unknown abnormal"
           ]

    assert digest["counts"]["by_offender"] == %{"unknown" => 1}
  end

  test "the text reports call traces without failures or timings, filter totals, and MiB" do
    add = "Shop.Cart.add/2"
    drop = "Shop.Cart.drop/1"

    digest =
      fold([
        batch(
          [
            traced(1, "call", %{"function" => add}),
            traced(2, "call.return", %{"function" => add, "duration_us" => 10}),
            traced(3, "call", %{"function" => drop}),
            traced(4, "call.exception", %{"function" => drop, "class" => "exit"}, nil, "error"),
            vm(5, 5, 100, 1_048_576),
            vm(6, 6, 100, 3_145_728)
          ],
          %{
            "filtered" => %{"logger" => nil, "telemetry" => %{"shop.x" => %{"min_duration" => 3}}}
          }
        )
      ])

    assert [%{"function" => ^drop, "p50_us" => nil, "max_us" => nil}, %{"function" => ^add}] =
             digest["calls"]["functions"]

    text = Digest.text(digest)

    assert text =~
             "Calls: Shop.Cart.drop/1 1 calls, 0 returns, 1 exceptions (max ?); 1x exit, first at receipt 4.\n"

    assert text =~ "Calls: Shop.Cart.add/2 1 calls, 1 returns, 0 exceptions (max 10 us).\n"
    assert text =~ "VM: ETS (including Insider's own) 1.0 MiB -> 3.0 MiB (+2.0 MiB)."
    assert text =~ "Not recorded (filters): 0 Logger and 3 Telemetry events; see filtered."
  end

  # The human digest once blamed the application for Insider's own
  # Recorder table and left out the port leak.
  test "the human VM line separates Insider's own processes, memory and ETS from the node's, and shows ports" do
    sample = fn receipt, metrics ->
      entry(receipt, %{
        "source" => "poller",
        "kind" => "vm_sample",
        "severity" => "debug",
        "wall_time" => at(receipt),
        "attributes" => %{"metrics" => metrics}
      })
    end

    first = %{
      "process_count" => 194,
      "insider_process_count" => 15,
      "processes_bytes" => 18_000_000,
      "insider_processes_bytes" => 200_000,
      "ets_bytes" => 1_572_864,
      "insider_ets_bytes" => 524_288,
      "ets_count" => 52,
      "insider_ets_tables" => 12,
      "port_count" => 40
    }

    last = %{
      first
      | "process_count" => 204,
        "insider_process_count" => 15,
        "ets_bytes" => 7_549_747,
        "insider_ets_bytes" => 6_501_171,
        "port_count" => 82
    }

    digest = fold([batch([sample.(1, first), sample.(2, last)])])

    assert %{
             "process_count" => %{"first" => 179, "last" => 189, "delta" => 10},
             "ets_bytes" => %{"first" => 1_048_576, "last" => 1_048_576, "delta" => 0},
             "ets_count" => %{"delta" => 0},
             "processes_bytes" => %{"delta" => 0}
           } = digest["vm"]["target"]

    text = Digest.text(digest)

    assert text =~
             "VM: processes 179 -> 189 (+10), Insider ETS 512 KiB -> 6.2 MiB (+5.7 MiB), ports 40 -> 82 (+42)."

    refute text =~ "ETS 1.5 MiB"
  end

  test "latency rows count exemplar losses over intervals and have no max without one" do
    summarised = fn receipt, kind, p95, fields ->
      summary(receipt, receipt * 1_000, p95)
      |> put_in(["event", "kind"], kind)
      |> update_in(["event", "attributes", "summary"], &Map.merge(&1, fields))
    end

    digest =
      fold([
        batch([
          summarised.(1, "shop.a.lookup", 900_000, %{
            "exemplars_lost" => 2,
            "first_error_retained" => true
          }),
          summarised.(2, "shop.b.lookup", 800_000, %{
            "duration_max_us" => nil,
            "exemplars_lost" => 1,
            "first_error_retained" => false
          }),
          summarised.(3, "shop.b.lookup", 800_000, %{
            "duration_max_us" => nil,
            "exemplars_lost" => 1,
            "first_error_retained" => false
          })
        ])
      ])

    assert [%{"kind" => "shop.a.lookup"}, %{"kind" => "shop.b.lookup", "max_us" => nil}] =
             digest["latency"]

    text = Digest.text(digest)

    assert text =~
             "Slowest: shop.a.lookup p50 0 us, p95 900 ms, max 900 ms over 40 summarised events, 0 errors; " <>
               "2 exemplar candidates lost.\n"

    assert text =~
             "Latency: shop.b.lookup p50 0 us, p95 800 ms, max ? over 80 summarised events, 0 errors; " <>
               "2 exemplar candidates lost, first error not retained in 2 intervals.\n"
  end

  # A digest without --since
  # read the session from its start and, out of budget, reported history
  # eight minutes old. A time window starts at the first event the Recorder
  # admitted that recently.
  describe "a time window" do
    defp ago(seconds),
      do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

    # Receipts 1..40 were admitted ten minutes ago, 41..45 in the last few
    # seconds; 46 arrives after the lookup. Event wall times are not in
    # receipt order: every odd old receipt carries a
    # fresh wall time, every even fresh one an old wall time. The reader
    # answers probes (the first disclosed event after a cursor, with its
    # admission time) and window reads like the owner does; a probe from a
    # cursor in `unknown` finds no disclosed event before its scan stops.
    defp timed_reader(parent, unknown \\ []) do
      now = System.monotonic_time(:microsecond)
      admitted = fn r -> now - if(r <= 40, do: 600 - r, else: 46 - r) * 1_000_000 end

      wall = fn
        r when r <= 40 and rem(r, 2) == 1 -> ago(1)
        r when r <= 40 -> ago(600 - r)
        r when rem(r, 2) == 0 -> ago(900)
        r -> ago(46 - r)
      end

      event = fn r -> put_in(logged(r, "boom #{r}", nil), ["event", "wall_time"], wall.(r)) end

      fn
        "latest", _options, _budget ->
          {:ok, batch([], %{"cursor" => 45, "next_cursor" => 45, "next_receipt" => 45})}

        cursor, %{"probe" => true}, _budget ->
          send(parent, {:probe, cursor})

          {:ok,
           if cursor in unknown do
             %{"cursor" => cursor, "receipt" => nil, "exhausted" => false, "next_receipt" => 46}
           else
             %{
               "cursor" => cursor,
               "receipt" => cursor + 1,
               "received_at_us" => admitted.(cursor + 1),
               "exhausted" => false,
               "next_receipt" => 46
             }
           end}

        cursor, options, _budget ->
          upto = options["upto"] || 46
          events = for receipt <- (cursor + 1)..upto//1, do: event.(receipt)
          {:ok, batch(events, %{"cursor" => cursor, "next_cursor" => upto, "next_receipt" => 46})}
      end
    end

    defp probes do
      Stream.repeatedly(fn ->
        receive do
          {:probe, cursor} -> cursor
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
    end

    test "starts at the first event admitted inside it, whatever the events' own wall times, in a few probes" do
      reader = timed_reader(self())

      assert {:ok, digest} =
               Digest.read("live-6", {:recent, 60_000}, reader, deadline(), "shop@host")

      # 42 and 44 carry old wall times but were admitted in the window; the
      # odd old receipts carry fresh wall times but were not.
      assert %{
               "since" => "latest-60s",
               "start_exact" => true,
               "cursor" => 40,
               "upto" => 45,
               "first_receipt" => 41,
               "last_receipt" => 45,
               "events" => 5,
               "complete" => true
             } = window = digest["window"]

      assert {:ok, from, 0} = DateTime.from_iso8601(window["from_wall_time"])
      assert {:ok, as_of, 0} = DateTime.from_iso8601(window["as_of"])
      assert DateTime.diff(as_of, from, :millisecond) in 59_000..61_000
      assert window["age_ms"] in 0..5_000

      # A binary search over 45 receipts, not a scan.
      assert Enum.count_until(probes(), 9) <= 8

      # The anomalies come first (five errors are a spike), then the window.
      [header, "Anomalies (most important first):", spike, _next, window_line | _rest] =
        digest |> Digest.text() |> String.split("\n")

      assert spike == "  1. Error spike: 5x logger_message boom N (5 processes)."

      assert header =~ "receipts 41-45, 5 events"

      assert window_line =~
               ~r/^Window: the last 60 s \(since \d\d:\d\d:\d\d UTC\), up to receipt 45; newest event [\d.]+ s ago\.$/
    end

    test "a probe that finds no disclosed event in time keeps every receipt after it and says so" do
      reader = timed_reader(self(), Enum.to_list(20..39))

      assert {:ok, digest} =
               Digest.read("live-6", {:recent, 60_000}, reader, deadline(), "shop@host")

      assert %{
               "start_exact" => false,
               "cursor" => cursor,
               "last_receipt" => 45,
               "complete" => true
             } =
               digest["window"]

      # Never past the first recent receipt: nothing recent is dropped.
      assert cursor in 19..40
      assert digest["window"]["events"] == 45 - cursor

      assert Digest.text(digest) =~
               "its start could not be narrowed exactly, so it may include older events"
    end

    # Adjacent search bounds dropped the first recent
    # receipt. `n` receipts, the first `old` admitted ten minutes ago, the
    # rest now; the window must start exactly after the last old one.
    defp split_reader(n, old, delay_ms \\ 0) do
      now = System.monotonic_time(:microsecond)
      admitted = fn r -> if r <= old, do: now - 600_000_000, else: now - 500_000 end

      fn
        "latest", _options, _budget ->
          {:ok, batch([], %{"cursor" => n, "next_cursor" => n, "next_receipt" => n})}

        cursor, %{"probe" => true}, _budget ->
          Process.sleep(delay_ms)

          {:ok,
           if cursor >= n do
             %{
               "receipt" => nil,
               "received_at_us" => nil,
               "exhausted" => true,
               "next_receipt" => n
             }
           else
             %{
               "receipt" => cursor + 1,
               "received_at_us" => admitted.(cursor + 1),
               "exhausted" => false,
               "next_receipt" => n
             }
           end}

        cursor, options, _budget ->
          upto = options["upto"] || n
          events = for r <- (cursor + 1)..upto//1, do: logged(r, "boom #{r}", nil)
          {:ok, batch(events, %{"cursor" => cursor, "next_cursor" => upto, "next_receipt" => n})}
      end
    end

    test "every split of old and recent receipts starts right after the last old one" do
      for n <- 0..40, old <- 0..n do
        assert {:ok, %{"window" => window}} =
                 Digest.read(
                   "live-6",
                   {:recent, 60_000},
                   split_reader(n, old),
                   deadline(),
                   "shop@host"
                 )

        assert %{"cursor" => ^old, "start_exact" => true, "complete" => true} = window,
               "#{old} old of #{n}: #{inspect(window)}"

        assert window["events"] == n - old
        assert window["first_receipt"] == if(old < n, do: old + 1)
      end
    end

    # The reported start is the cutoff the search used,
    # taken before any probe, however long the probes take.
    test "the window's start is the cutoff taken before the search, not after it" do
      before = System.os_time(:microsecond)

      assert {:ok, %{"window" => window}} =
               Digest.read(
                 "live-6",
                 {:recent, 1_000},
                 split_reader(3, 1, 300),
                 deadline(),
                 "shop@host"
               )

      assert %{"cursor" => 1, "start_exact" => true} = window
      {:ok, from, 0} = DateTime.from_iso8601(window["from_wall_time"])
      # Two probes of 300 ms each: a cutoff taken after them would be 600 ms later.
      assert (DateTime.to_unix(from, :microsecond) - (before - 1_000_000)) in 0..200_000
    end

    test "a search that runs out of budget is a timeout, not an empty window" do
      parent = self()
      slow = timed_reader(parent)

      reader = fn
        0, %{"probe" => true} = options, budget ->
          # The first probe spends the budget below the read floor.
          Process.sleep(200)
          slow.(0, options, budget)

        cursor, options, budget ->
          slow.(cursor, options, budget)
      end

      assert {:error, %{"code" => "timeout"}} =
               Digest.read("live-6", {:recent, 60_000}, reader, deadline(400), "shop@host")
    end

    test "a window without recent events is empty, and an old session-start window says it is stale" do
      reader = timed_reader(self())

      assert {:ok, empty} =
               Digest.read("live-6", {:recent, 1_000}, reader, deadline(), "shop@host")

      assert %{"events" => events, "since" => "latest-1s", "start_exact" => true} =
               empty["window"]

      assert events <= 1

      old = fn
        "latest", _options, _budget ->
          {:ok, batch([], %{"cursor" => 3, "next_cursor" => 3, "next_receipt" => 3})}

        cursor, _options, _budget ->
          events =
            for r <- (cursor + 1)..3//1,
                do: put_in(logged(r, "x", nil), ["event", "wall_time"], ago(480))

          {:ok, batch(events, %{"cursor" => cursor, "next_cursor" => 3, "next_receipt" => 3})}
      end

      assert {:ok, digest} = Digest.read("live-6", {:cursor, 0}, old, deadline(), "shop@host")
      assert %{"since" => 0, "from_wall_time" => nil} = digest["window"]
      assert digest["window"]["age_ms"] >= 479_000

      text = Digest.text(digest)

      assert text =~
               "Window: after receipt 0 (the session start), up to receipt 3; newest event 8.0 min ago."

      assert text =~
               "The newest event in this window is 8.0 min old; digest --since latest-60s covers the last minute."
    end

    test "hints say which window they cover" do
      hint = %{
        "kind" => "reduce_logger",
        "reason" => "flood",
        "command" => "mix insider.live amend \"${N[@]}\"",
        "options" => %{}
      }

      digest =
        Digest.new("live-6", 40)
        |> Digest.add(batch([logged(41, "a", nil), logged(45, "b", nil)], %{"next_cursor" => 45}))
        |> Map.put(:window, {:recent, 60_000})
        |> Map.put(:from_us, System.os_time(:microsecond) - 60_000_000)
        |> Map.put(:context, fn -> nil end)
        |> Digest.finish(nil, "shop@host")
        |> Digest.put_hints([hint])

      assert [
               %{
                 "window" => %{
                   "since" => "latest-60s",
                   "first_receipt" => 41,
                   "last_receipt" => 45
                 }
               }
             ] = digest["hints"]

      assert Digest.text(digest) =~
               "Next (receipts 41-45, the last 60 s): flood: mix insider.live amend \"${N[@]}\""
    end
  end

  # The N+1 a fix removed repeated one
  # query shape 25 times in one request; the digest says so, with its caller.
  test "one query shape repeated ten times in one request is an N+1 anomaly, with the trace to read" do
    trace = "d2ba1d8800000000000000000000beef"

    span = fn n, table ->
      entry(n, %{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "info",
        "wall_time" => at(n),
        "attributes" => %{
          "trace_id" => trace,
          "span_id" => String.pad_leading(Integer.to_string(n), 16, "0"),
          "parent_span_id" => "00000000000000aa",
          "name" => "app.repo.query:#{table}",
          "span_kind" => "client",
          "duration_us" => 1_000
        },
        # A known shape is the evidence that one statement repeated.
        "payload" => %{
          "span_attributes" => %{"db.statement" => "SELECT * FROM #{table} WHERE (step_id = $1)"}
        }
      })
    end

    parent =
      entry(100, %{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "info",
        "wall_time" => at(100),
        "attributes" => %{
          "trace_id" => trace,
          "span_id" => "00000000000000aa",
          "name" => "resolve orders",
          "span_kind" => "internal",
          "duration_us" => 90_000
        }
      })

    edges = for n <- 1..12, do: span.(n, "order_items")
    users = for n <- 20..22, do: span.(n, "users")
    digest = fold([batch(edges ++ users ++ [parent])])

    assert [
             %{
               "trace_id" => ^trace,
               "groups" => [%{"source" => "order_items", "count" => 12}]
             }
           ] =
             digest["repeated_queries"]

    assert [%{"kind" => "n_plus_one", "line" => line, "command" => command}] =
             Enum.filter(digest["anomalies"], &(&1["kind"] == "n_plus_one"))

    assert line ==
             "N+1 queries in one request: order_items × 12 from span \"resolve orders\" " <>
               "(no repo stacktrace recorded), 12 ms total (trace #{trace})."

    assert command ==
             "mix insider.live trace \"${N[@]}\" --session live-6 --trace-id #{trace} --human"

    assert {_out, 0} = System.cmd("/bin/bash", ["-n", "-c", command], stderr_to_stdout: true)
    assert Digest.text(digest) =~ "N+1 queries in one request: order_items × 12"

    # Nine repeats are not an N+1 anomaly.
    quiet = fold([batch(Enum.take(edges, 9) ++ [parent])])
    assert quiet["repeated_queries"] == []
    refute Enum.any?(quiet["anomalies"], &(&1["kind"] == "n_plus_one"))
  end

  # Every query span the trace groups counts in the
  # digest too, and query evidence past the cap is counted and said.
  test "attribute-named query spans count, and query evidence past the cap is said" do
    trace = "e3ba1d8800000000000000000000beef"

    attributed = fn n, table ->
      entry(n, %{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "info",
        "wall_time" => at(n),
        "attributes" => %{
          "trace_id" => trace,
          "span_id" => String.pad_leading(Integer.to_string(n), 16, "0"),
          "name" => "SELECT #{table}",
          "span_kind" => "client",
          "duration_us" => 1_000
        },
        "payload" => %{
          "span_attributes" => %{
            "source" => table,
            "db.statement" => "SELECT u0.id FROM #{table} AS u0 WHERE (u0.id = $1)"
          }
        }
      })
    end

    digest = fold([batch(for n <- 1..12, do: attributed.(n, "users"))])
    assert [%{"groups" => [%{"source" => "users", "count" => 12}]}] = digest["repeated_queries"]
    assert %{"seen" => 12, "examined" => 12, "omitted" => 0} = digest["query_evidence"]

    once = for n <- 1..8_192, do: attributed.(n, "t#{n}")
    late = for n <- 8_193..8_204, do: attributed.(n, "users")
    capped = fold([batch(once ++ late)])

    assert %{"seen" => 8_204, "examined" => 8_192, "omitted" => 12, "complete" => false} =
             capped["query_evidence"]

    assert Digest.text(capped) =~
             "Repeated queries: 12 of 8204 query spans and events were not examined (cap 8192); an N+1 among them is not shown."
  end
end
