defmodule Insider.Live.AnomaliesTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Anomalies

  @burst %{
    "at" => "2026-10-24T21:08:36.100000Z",
    "seconds" => 1,
    "requests" => 30,
    "peak_per_s" => 30,
    "baseline_per_s" => 2,
    "sources" => [
      %{"source" => "user agent sync-client/1.4", "requests" => 30, "traced" => 0}
    ],
    "max_wait_us" => 8_500_000,
    "others_overlapping" => 1,
    "others_max_wait_us" => 7_600_000
  }

  @slowest %{
    "at" => "2026-10-24T21:08:36.300000Z",
    "method" => "POST",
    "path" => "/api/graphql",
    "status" => 200,
    "user_agent" => "sync-client/1.4",
    "wait_us" => 8_500_000
  }

  defp digest(overrides) do
    Map.merge(
      %{
        "session_id" => "live-3",
        "window" => %{"since" => "latest-10m"},
        "requests" => %{
          "requests" => 66,
          "waited_100ms" => 58,
          "slowest_waits" => [@slowest],
          "bursts" => [@burst]
        },
        "error_signatures" => [],
        "crash_loops" => [],
        "processes" => [],
        "vm" => nil,
        "gaps" => []
      },
      overrides
    )
  end

  test "ranks bursts, waits, errors, loops, pressure, and evictions, each with the next command" do
    d =
      digest(%{
        "error_signatures" => [
          %{
            "signature" => "absinthe.execute.operation.stop query listing result=errors",
            "count" => 12,
            "processes" => 9
          }
        ],
        "crash_loops" => [
          %{
            "offender" => "MyApp.Authentication.JwksStrategy",
            "restarts" => 4,
            "period_ms" => 30_000
          }
        ],
        "processes" => [
          %{
            "process" => "Phoenix.CodeReloader.Server",
            "registered_name" => "Phoenix.CodeReloader.Server",
            "pid" => "<0.468.0>",
            "message_queue_len" => 120,
            "max_message_queue_len" => 126
          }
        ],
        "gaps" => [%{"reason" => "evicted", "scope" => "receipt_range", "count" => 1058}]
      })

    anomalies = Anomalies.of(d)

    assert Enum.map(anomalies, & &1["kind"]) ==
             ~w(request_burst pre_handler_wait error_spike crash_loop mailbox evicted)

    assert Enum.all?(anomalies, &is_binary(&1["command"]))

    [burst, wait, errors, loop, mailbox, evicted] = Enum.map(anomalies, & &1["line"])

    # The burst names the window was partly evicted, and what keeps it.
    assert burst ==
             "Request burst at 21:08:36: 30 requests in 1 s (usually 2/s), 30 from user agent sync-client/1.4; " <>
               "waits up to 8.5 s, 1 other request waited up to 7.6 s. 1058 events of this window were evicted, " <>
               "so other bursts may be missing. Inspect the code reloader during the next burst to see " <>
               "where requests queue."

    assert wait =~
             "Pre-handler wait: 58 of 66 requests waited 100 ms or more; slowest 8.5 s POST /api/graphql 200 (sync-client/1.4) at 21:08:36"

    assert errors =~
             "Error spike: 12x absinthe.execute.operation.stop query listing result=errors (9 processes)"

    assert loop =~ "Restart loop: MyApp.Authentication.JwksStrategy restarted 4 times, every 30 s"
    assert mailbox =~ "Mailbox: Phoenix.CodeReloader.Server holds 120 messages (max 126)"
    assert evicted =~ "Evicted: the Recorder evicted 1058 events in this window"

    # Without the session's hints, it never names a Recorder size: status
    # says which source evicts.
    evicted_command = Enum.find(anomalies, &(&1["kind"] == "evicted"))["command"]
    refute evicted_command =~ "--max-events"
    assert evicted_command == "mix insider.live status \"${N[@]}\" --session live-3"

    assert Enum.find(anomalies, &(&1["kind"] == "request_burst"))["command"] =~
             "process \"${N[@]}\" --name Phoenix.CodeReloader.Server"

    # Every command runs as printed.
    for %{"command" => command} <- anomalies do
      assert {_out, 0} = System.cmd("/bin/bash", ["-n", "-c", command], stderr_to_stdout: true),
             command

      refute command =~ "SESSION_ID"
    end

    text = Anomalies.lines(anomalies)
    assert hd(text) == "Anomalies (most important first):"

    assert Enum.at(text, 1) =~
             ~r/^  1\. Request burst at 21:08:36: .*\n     next: mix insider\.live /
  end

  # An initial-call label is not a registered name.
  test "a mailbox command names a registered process, else its pid" do
    row = %{
      "process" => "erlang.apply/2",
      "pid" => "<0.199.0>",
      "message_queue_len" => 300,
      "max_message_queue_len" => 300
    }

    assert [%{"command" => "mix insider.live process \"${N[@]}\" --pid '<0.199.0>'"}] =
             Anomalies.of(digest(%{"requests" => %{}, "processes" => [row]}))

    named = Map.put(row, "registered_name", "MyApp.Worker")

    assert [%{"command" => "mix insider.live process \"${N[@]}\" --name MyApp.Worker"}] =
             Anomalies.of(digest(%{"requests" => %{}, "processes" => [named]}))
  end

  test "a run-queue command names the digest's session and runs as printed" do
    vm = %{"metrics" => %{"run_queue_length" => %{"first" => 0, "last" => 80, "delta" => 80}}}

    assert [%{"kind" => "run_queue", "command" => command}] =
             Anomalies.of(digest(%{"requests" => %{}, "vm" => vm}))

    assert command =~ "--session live-3"
    assert {_out, 0} = System.cmd("/bin/bash", ["-n", "-c", command], stderr_to_stdout: true)
  end

  # What status reports when its window was not read whole.
  test "status anomalies say when the read was incomplete, and why" do
    complete = %{
      "anomalies" => [],
      "window" => %{"complete" => true, "stopped_by" => nil, "events" => 9}
    }

    assert Anomalies.status({:ok, complete}) ==
             %{
               "anomalies" => [],
               "anomalies_window" => "latest-60s",
               "anomalies_complete" => true,
               "anomalies_known" => 0,
               "baseline_set_at" => nil
             }

    partial = %{
      "anomalies" => [],
      "window" => %{"complete" => false, "stopped_by" => "deadline", "events" => 500}
    }

    assert %{
             "anomalies" => [],
             "anomalies_complete" => false,
             "anomalies_note" =>
               "incomplete: the read stopped (deadline) after 500 events of the last 60 s, so an anomaly in the rest is not shown; run digest for the whole window"
           } = Anomalies.status({:ok, partial})

    assert %{
             "anomalies" => nil,
             "anomalies_complete" => false,
             "anomalies_note" =>
               "incomplete: the anomalies could not be read (environment_denied)"
           } = Anomalies.status({:error, %{"code" => "environment_denied"}})
  end

  test "an evicted window without a burst says a burst may have been lost" do
    d =
      digest(%{
        "requests" => %{
          "requests" => 0,
          "waited_100ms" => 0,
          "slowest_waits" => [],
          "bursts" => []
        },
        "gaps" => [%{"reason" => "evicted", "scope" => "receipt_range", "count" => 900}]
      })

    assert [%{"kind" => "evicted", "line" => line}] = Anomalies.of(d)
    assert line =~ "a request burst or error spike among them is not counted"
  end

  test "waits under 1 s, a few errors, and short mailboxes are not anomalies; a quiet digest says so" do
    d =
      digest(%{
        "requests" => %{
          "requests" => 10,
          "waited_100ms" => 2,
          "slowest_waits" => [%{@slowest | "wait_us" => 400_000}],
          "bursts" => []
        },
        "error_signatures" => [%{"signature" => "x", "count" => 2, "processes" => 1}],
        "processes" => [
          %{"process" => "p", "message_queue_len" => 3, "max_message_queue_len" => 9}
        ]
      })

    assert Anomalies.of(d) == []
    assert Anomalies.lines([]) == ["Anomalies: none in this window."]
  end

  describe "known-normal baseline" do
    # The digest's anomalies were mostly dev noise (a
    # restart loop, the observer's own traffic), so nothing new led.
    defp noisy(restarts, span_ms \\ 60_000, fingerprint \\ "aaaa") do
      digest(%{
        "window" => %{"since" => "latest-5m", "span_ms" => span_ms},
        "requests" => %{"requests" => 0, "bursts" => []},
        "crash_loops" => [
          %{
            "offender" => "MyApp.KeyFetcher",
            "offender_id" => "atom:Elixir.MyApp.KeyFetcher",
            "reason_fingerprint" => fingerprint,
            "restarts" => restarts,
            "period_ms" => 30_000
          }
        ]
      })
    end

    @set_at "2026-10-25T14:02:11Z"

    defp marked(digest, previous \\ nil),
      do: Anomalies.baseline(digest, @set_at, "latest-5m", previous)

    test "each anomaly has an opaque identity, a count, and its window; a baseline keeps only those" do
      [loop] = Anomalies.of(noisy(4, 120_000))

      assert %{"count" => 4, "span_ms" => 120_000, "unit" => "rate", "identity" => identity} =
               loop

      assert identity =~ ~r/\A[0-9a-f]{16}\z/

      baseline = marked(noisy(4))

      assert %{
               "set_at" => @set_at,
               "entries" => [%{"kind" => "crash_loop", "identity" => ^identity, "count" => 4}]
             } = baseline

      # A stored baseline holds no text of the anomaly.
      refute inspect(baseline) =~ "KeyFetcher"
      refute inspect(baseline) =~ "aaaa"
    end

    test "a baselined anomaly is folded into one line; what is new leads" do
      baseline = marked(noisy(4))

      folded = Anomalies.fold(noisy(5), baseline)
      assert folded["anomalies"] == []
      assert [%{"kind" => "crash_loop"}] = folded["anomalies_known"]

      assert Anomalies.lines(folded) == [
               "Anomalies: none new; 1 known-normal anomaly hidden (baseline set 14:02; --show-baseline)."
             ]

      with_burst =
        noisy(5)
        |> Map.put("requests", %{"requests" => 66, "waited_100ms" => 0, "bursts" => [@burst]})
        |> Anomalies.fold(baseline)

      assert [%{"kind" => "request_burst"}] = with_burst["anomalies"]
      [head, first | _] = Anomalies.lines(with_burst)

      assert head ==
               "Anomalies (new first; 1 known-normal anomaly hidden, baseline set 14:02; --show-baseline):"

      assert first =~ "  1. Request burst at 21:08:36"

      shown = Anomalies.lines(Map.put(folded, "show_baseline", true))
      assert List.last(shown) =~ "  - Restart loop: MyApp.KeyFetcher restarted 5 times"
      assert Enum.at(shown, 1) == "Known-normal (baseline set 14:02):"
    end

    # The digest tells loops apart by their reason.
    test "the same child failing for another reason is new" do
      baseline = marked(noisy(3, 60_000, "aaaa"))
      folded = Anomalies.fold(noisy(3, 60_000, "bbbb"), baseline)
      assert [%{"kind" => "crash_loop"}] = folded["anomalies"]
      assert folded["anomalies_known"] == []
    end

    test "ten times the baselined rate comes back, compared unrounded over unequal windows" do
      day = 24 * 60 * 60_000
      # 2 restarts a day rounded to 0 per hour.
      baseline = marked(noisy(2, day))

      assert [%{"kind" => "crash_loop", "line" => line}] =
               Anomalies.fold(noisy(20, day), baseline)["anomalies"]

      assert line =~ "Back above its baseline: 10x ("
      assert [] = Anomalies.fold(noisy(19, day), baseline)["anomalies"]

      # 2 a minute baselined; 20 over two minutes is 5x, 40 is 10x.
      minute = marked(noisy(2))
      assert [] = Anomalies.fold(noisy(20, 120_000), minute)["anomalies"]

      assert [%{"line" => back}] = Anomalies.fold(noisy(40, 120_000), minute)["anomalies"]
      assert back =~ "Back above its baseline: 10x (2/min when marked normal at 14:02)."
    end

    # A known maximum must not hide a new candidate below it.
    test "folding happens per candidate, then the top new one of each kind is chosen" do
      processes = fn rows ->
        digest(%{"requests" => %{"requests" => 0, "bursts" => []}, "processes" => rows})
      end

      known = %{
        "process" => "KnownWorker",
        "message_queue_len" => 200,
        "max_message_queue_len" => 200
      }

      new = %{
        "process" => "NewWorker",
        "message_queue_len" => 150,
        "max_message_queue_len" => 150
      }

      folded = Anomalies.fold(processes.([known, new]), marked(processes.([known])))

      assert [%{"kind" => "mailbox", "line" => "Mailbox: NewWorker holds 150 messages" <> _}] =
               folded["anomalies"]

      assert [%{"kind" => "mailbox"}] = folded["anomalies_known"]

      errors = fn rows ->
        digest(%{"requests" => %{"requests" => 0, "bursts" => []}, "error_signatures" => rows})
      end

      noise = %{"signature" => "logger_message key fetch failed", "count" => 9}

      fresh = %{
        "signature" => "absinthe.execute.operation.stop mutation updateOrder result=errors",
        "count" => 6
      }

      folded = Anomalies.fold(errors.([noise, fresh]), marked(errors.([noise])))
      assert [%{"kind" => "error_spike", "line" => line}] = folded["anomalies"]
      assert line =~ "mutation updateOrder result=errors"
      assert [%{"kind" => "error_spike"}] = folded["anomalies_known"]

      slow = fn path, us ->
        %{
          "method" => "POST",
          "path" => path,
          "status" => 200,
          "wait_us" => us,
          "at" => "2026-10-24T21:08:36.300000Z"
        }
      end

      waits = fn rows ->
        digest(%{
          "requests" => %{
            "requests" => 9,
            "waited_100ms" => 2,
            "bursts" => [],
            "slowest_waits" => rows
          }
        })
      end

      folded =
        Anomalies.fold(
          waits.([slow.("/known", 9_000_000), slow.("/new", 2_000_000)]),
          marked(waits.([slow.("/known", 9_000_000)]))
        )

      assert [%{"kind" => "pre_handler_wait", "line" => line}] = folded["anomalies"]
      assert line =~ "POST /new 200"
    end

    # Baselining again marks what is now shown, and keeps
    # what was marked before.
    test "a baseline is built from every candidate and keeps the earlier entries" do
      errors = fn rows ->
        digest(%{"requests" => %{"requests" => 0, "bursts" => []}, "error_signatures" => rows})
      end

      a = %{"signature" => "logger_message a failed", "count" => 9}
      b = %{"signature" => "logger_message b failed", "count" => 6}

      first = marked(errors.([a]))
      second = marked(errors.([a, b]), first)
      assert [_, _] = second["entries"]
      assert Anomalies.fold(errors.([a, b]), second)["anomalies"] == []

      only_b = marked(errors.([b]), first)
      assert [_, _] = only_b["entries"]
    end

    test "without a baseline nothing is folded" do
      assert %{"anomalies" => [_], "anomalies_known" => []} = Anomalies.fold(noisy(4), nil)

      assert Anomalies.lines(Anomalies.fold(noisy(4), nil)) |> hd() ==
               "Anomalies (most important first):"
    end

    test "a shown baseline names kinds and rates, never what the identities hash" do
      text = Anomalies.baseline_lines(marked(noisy(4)))

      assert text =~
               ~r/\ABaseline set 14:02 \(1 known-normal identity; one at 10x its rate comes back\):\n  - crash_loop [0-9a-f]{16} \(4\/min\)\n/

      refute text =~ "KeyFetcher"
    end
  end

  test "the observer's own requests are named once, as left out of the anomalies" do
    d =
      digest(%{
        "requests" => %{
          "requests" => 0,
          "bursts" => [],
          "observer" => %{"requests" => 40, "paths" => ["/tidewave"]}
        }
      })

    assert Anomalies.lines(Anomalies.fold(d, nil)) == [
             "Anomalies: none in this window.",
             "Observer traffic: 40 requests to /tidewave (the observer's own calls) are left out of the anomalies."
           ]
  end
end
