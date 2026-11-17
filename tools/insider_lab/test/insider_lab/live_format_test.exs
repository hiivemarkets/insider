defmodule Insider.Lab.LiveFormatTest do
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Format

  @wall_time "2026-10-22T05:01:51.107000Z"

  defp full_event(fields) do
    Map.merge(
      %{
        "schema" => "insider.event/v1",
        "id" => "telemetry-synthetic-1",
        "node" => "shop@host",
        "boot_id" => "boot-synthetic",
        "source" => "telemetry",
        "kind" => "shop.checkout.stop",
        "severity" => "info",
        "monotonic_time" => 1,
        "clock_id" => "clock-synthetic",
        "source_instance_id" => "telemetry-synthetic",
        "source_sequence" => 1,
        "wall_time" => @wall_time,
        "subject" => %{"namespace" => "process", "scope" => "shop@host", "value" => "<0.412.0>"},
        "causality" => %{
          "trace_id" => nil,
          "span_id" => nil,
          "logical_operation_id" => nil,
          "parent_event_id" => nil,
          "process_generation" => nil
        },
        "attributes" => %{},
        "payload" => nil,
        "authority" => "insider-live",
        "redactions" => [],
        "extensions" => %{}
      },
      fields
    )
  end

  defp entry(event, redactions \\ []),
    do: %{
      "receipt" => 7,
      "received_at_us" => -5_000,
      "priority" => "normal",
      "event" => event,
      "redactions" => redactions
    }

  test "json keeps what varies and drops the constant, null, and empty envelope fields" do
    lean = Format.lean_entry(entry(full_event(%{"payload" => nil})))

    assert lean == %{
             "receipt" => 7,
             "event" => %{
               "id" => "telemetry-synthetic-1",
               "source" => "telemetry",
               "kind" => "shop.checkout.stop",
               "severity" => "info",
               "wall_time" => @wall_time,
               "subject" => %{
                 "namespace" => "process",
                 "scope" => "shop@host",
                 "value" => "<0.412.0>"
               },
               "attributes" => %{}
             }
           }

    traced =
      full_event(%{"causality" => %{"trace_id" => String.duplicate("a", 32), "span_id" => nil}})

    record = %{"action" => "mask", "path" => ["key:payload"]}
    lean = Format.lean_entry(entry(traced, [record]))
    assert lean["event"]["causality"] == %{"trace_id" => String.duplicate("a", 32)}
    assert lean["redactions"] == [record]

    batch = %{"cursor" => 0, "events" => [entry(full_event(%{}))]}

    assert {:json, %{"result" => %{"events" => [%{"receipt" => 7}]}}} =
             Format.render("events", %{format: "json"}, %{"result" => batch})

    assert {:json, %{"result" => ^batch}} =
             Format.render("events", %{format: "full"}, %{"result" => batch})
  end

  test "a compact telemetry line shows durations, the request line and status, never a debugger page" do
    event =
      full_event(%{
        "kind" => "phoenix.endpoint.stop",
        "severity" => "error",
        "attributes" => %{
          "measurements" => %{"duration" => 71_900_000, "count" => 1},
          "durations_us" => %{"duration" => 71_900}
        },
        "payload" => %{
          "metadata" => %{
            "conn" => %{
              "__struct__" => "Plug.Conn",
              "method" => "GET",
              "request_path" => "/graphql",
              "status" => 500,
              "resp_body" => "<!DOCTYPE html><html><body>Plug.Debugger page</body></html>",
              "req_headers" => [%{"cookie" => "[REDACTED:credential_key]"}],
              "private" => %{"phoenix_endpoint" => "MyAppWeb.Endpoint"}
            },
            "reason" => %{
              "__struct__" => "Elixir.RuntimeError",
              "message" => "Stale conn passed\nmore"
            },
            "result" => "<html><body>oops</body></html>"
          }
        }
      })

    line = Format.event_line(entry(event, [%{"action" => "mask"}]))

    assert line ==
             "7 05:01:51.107 telemetry phoenix.endpoint.stop error <0.412.0> duration_us=71900 count=1 " <>
               "method=GET path=/graphql status=500 reason=RuntimeError " <>
               ~s(reason_message="Stale conn passed" result="[html 30 bytes]" redactions=1)

    refute line =~ "Debugger"
    refute line =~ "phoenix_endpoint"
    assert Format.html?("  <!doctype html>") and not Format.html?("plain <b>text")
  end

  test "compact lines for summaries, supervisor reports, Logger messages, and Poller samples" do
    summary =
      full_event(%{
        "subject" => nil,
        "wall_time" => nil,
        "attributes" => %{
          "summary" => %{
            "count" => 50,
            "errors" => 50,
            "duration_p50_us" => 5_001_459,
            "duration_p95_us" => 5_001_459,
            "duration_max_us" => 5_001_470,
            "interval_ms" => 5_000
          }
        }
      })

    assert Format.event_line(entry(summary)) ==
             "7 - telemetry shop.checkout.stop info - count=50 errors=50 p50_us=5001459 p95_us=5001459 max_us=5001470 interval_ms=5000"

    terminated =
      full_event(%{
        "source" => "logger",
        "kind" => "supervisor_child_terminated",
        "severity" => "error",
        "attributes" => %{
          "offender_id" => "atom:Elixir.Shop.Inventory",
          "restart_type" => "permanent",
          "reason_class" => "abnormal",
          "reason_fingerprint" => "b1f96d655cf7de80aa"
        }
      })

    assert Format.event_line(entry(terminated)) =~
             "logger supervisor_child_terminated error <0.412.0> offender=Shop.Inventory restart=permanent reason=abnormal fingerprint=b1f96d655cf7"

    message =
      full_event(%{
        "source" => "logger",
        "kind" => "logger_message",
        "severity" => "error",
        "attributes" => %{"domain" => ["elixir"]},
        "payload" => %{
          "message" => "checkout failed: timeout\nstack",
          "metadata" => %{"mfa" => "{Shop.Checkout, :run, 1}"}
        }
      })

    assert Format.event_line(entry(message)) =~
             ~s(domain=elixir mfa="{Shop.Checkout, :run, 1}" message="checkout failed: timeout")

    vm =
      full_event(%{
        "source" => "poller",
        "kind" => "vm_sample",
        "severity" => "debug",
        "subject" => nil,
        "attributes" => %{
          "metrics" => %{"process_count" => 120, "ets_bytes" => 1_560, "atom_count" => 1}
        }
      })

    assert Format.event_line(entry(vm)) ==
             "7 05:01:51.107 poller vm_sample debug - process_count=120 ets_bytes=1560"

    top =
      full_event(%{
        "source" => "poller",
        "kind" => "process_top",
        "attributes" => %{
          "metrics" => %{
            "by_message_queue_len" => [%{"name" => "Shop.Pricing", "message_queue_len" => 2_345}]
          }
        }
      })

    assert Format.event_line(entry(top)) =~ "top_mailbox=Shop.Pricing message_queue_len=2345"

    sample =
      full_event(%{
        "source" => "poller",
        "kind" => "process_sample",
        "attributes" => %{
          "metrics" => %{
            "registered_name" => "Shop.Pricing",
            "message_queue_len" => 3,
            "memory_bytes" => 10
          }
        }
      })

    assert Format.event_line(entry(sample)) =~
             "name=Shop.Pricing message_queue_len=3 memory_bytes=10"

    assert Format.event_line(%{"receipt" => 1}) =~ "?"
  end

  # ets_top and port_top printed only "-" in compact, so their
  # content was invisible. Every Poller kind names what it measured.
  test "every Poller kind has a compact line with its content" do
    poller = fn kind, attributes ->
      entry(
        full_event(%{
          "source" => "poller",
          "kind" => kind,
          "severity" => "debug",
          "subject" => nil,
          "attributes" => attributes
        })
      )
    end

    ets =
      poller.("ets_top", %{
        "probe_status" => "complete",
        "metrics" => %{
          "table_count" => 41,
          "by_memory" => [
            %{
              "table" => "Shop.Cache",
              "owner" => "Shop.Cache",
              "memory_bytes" => 1_048_576,
              "size" => 10
            },
            %{
              "table" => "sessions",
              "owner" => "<0.300.0>",
              "memory_bytes" => 2_048,
              "size" => 900
            }
          ],
          "by_size" => [
            %{
              "table" => "sessions",
              "owner" => "<0.300.0>",
              "memory_bytes" => 2_048,
              "size" => 900
            }
          ],
          "insider" => %{"table_count" => 6, "memory_bytes" => 5_750_000, "size" => 4_000},
          "omitted" => 0
        }
      })

    assert Format.event_line(ets) ==
             "7 05:01:51.107 poller ets_top debug - tables=41 by_memory=Shop.Cache:1048576,sessions:2048 " <>
               "by_size=sessions:900 insider_tables=6 insider_bytes=5750000"

    ports =
      poller.("port_top", %{
        "probe_status" => "partial",
        "unavailable" => ["port_count_delta"],
        "metrics" => %{
          "port_count" => 44,
          "port_count_delta" => 3,
          "os_process_count" => 39,
          "type_count" => 2,
          "by_type" => [
            %{"type" => "cat", "count" => 39, "os_process_count" => 39, "delta" => 3},
            %{"type" => "tcp_inet", "count" => 5, "os_process_count" => 0, "delta" => nil}
          ],
          "by_owner" => [
            %{
              "owner" => "Shop.Shipping",
              "owner_pid" => "<0.250.0>",
              "count" => 39,
              "top_type" => "cat"
            }
          ],
          "insider" => %{"port_count" => 0, "os_process_count" => 0},
          "omitted" => 0
        }
      })

    assert Format.event_line(ports) ==
             "7 05:01:51.107 poller port_top debug - ports=44 delta=3 os_processes=39 " <>
               "by_type=cat:39(+3),tcp_inet:5 by_owner=Shop.Shipping:39 unavailable=port_count_delta"

    top =
      poller.("process_top", %{
        "metrics" => %{
          "process_count" => 512,
          "by_message_queue_len" => [
            %{"name" => "Shop.Pricing", "pid" => "<0.1.0>", "message_queue_len" => 170},
            %{
              "name" => nil,
              "initial_call" => "Task.Supervised.invoke_mfa/2",
              "message_queue_len" => 2
            }
          ],
          "by_memory" => [%{"name" => "Shop.ImageCache", "memory_bytes" => 7_012_352}],
          "by_reductions_delta" => [%{"pid" => "<0.9.0>", "reductions_delta" => 90_000}]
        }
      })

    assert Format.event_line(top) ==
             "7 05:01:51.107 poller process_top debug - top_mailbox=Shop.Pricing message_queue_len=170 processes=512 " <>
               "by_message_queue_len=Shop.Pricing:170,Task.Supervised.invoke_mfa/2:2 " <>
               "by_memory=Shop.ImageCache:7012352 by_reductions_delta=<0.9.0>:90000"

    watch =
      poller.("process_watch", %{
        "watch_name" => "Shop.Receipts",
        "metrics" => %{
          "registered_name" => "Elixir.Shop.Receipts",
          "message_queue_len" => 43,
          "memory_bytes" => 9_000,
          "status" => "waiting",
          "current_function" => %{
            "module" => "Elixir.Process",
            "function" => "sleep",
            "arity" => 1
          }
        }
      })

    assert Format.event_line(watch) ==
             "7 05:01:51.107 poller process_watch debug - name=Shop.Receipts message_queue_len=43 " <>
               "memory_bytes=9000 status=waiting current_function=Process.sleep/1"

    cycle =
      poller.("poll_cycle", %{
        "probe_status" => "truncated",
        "unavailable" => ["cycle_deadline"],
        "metrics" => %{"skipped_probes" => 2}
      })

    assert Format.event_line(cycle) ==
             "7 05:01:51.107 poller poll_cycle debug - status=truncated skipped_probes=2 unavailable=cycle_deadline"

    vm =
      poller.("vm_sample", %{
        "metrics" => %{"port_count" => 44, "binary_bytes" => 22_600_000, "process_count" => 512}
      })

    assert Format.event_line(vm) =~ "process_count=512 port_count=44 binary_bytes=22600000"

    # Every Poller kind the collector records has more than its head.
    for line <- Enum.map([ets, ports, top, watch, cycle, vm], &Format.event_line/1),
        do: refute(String.ends_with?(line, " -"), line)
  end

  test "a compact call-trace line names the function, the call, the exception and the arguments that failed" do
    failure =
      full_event(%{
        "source" => "calls",
        "kind" => "call.exception",
        "severity" => "error",
        "attributes" => %{
          "function" => "Shop.Inventory.handle_call/3",
          "call_id" => 4,
          "duration_us" => 12,
          "class" => "error",
          "exception" => "ArithmeticError"
        },
        "payload" => %{
          "arguments" => ["{:reserve, \"fig\", 1}", "{#PID<0.1.0>, ...}", %{"fig" => 0}]
        }
      })

    line = Format.event_line(entry(failure))

    assert line =~
             "calls call.exception error <0.412.0> function=Shop.Inventory.handle_call/3 call_id=4 " <>
               "duration_us=12 class=error exception=ArithmeticError arguments="

    assert line =~ "fig"

    stopped =
      full_event(%{
        "source" => "calls",
        "kind" => "call.stopped",
        "severity" => "warning",
        "subject" => nil,
        "attributes" => %{"reason" => "calls_max", "calls" => 100}
      })

    assert Format.event_line(entry(stopped)) =~ "calls call.stopped warning - reason=calls_max"
  end

  test "each compact batch ends with a # line: cursors, truncation, profile, gaps, and filtered counts" do
    batch = %{
      "cursor" => 0,
      "next_cursor" => 58,
      "next_receipt" => 120,
      "truncated_by" => "limit",
      "state" => "running",
      "disclosure_profile" => "rich",
      "events" => [entry(full_event(%{}))],
      "gaps" => [
        %{"reason" => "evicted", "count" => 4, "scope" => "receipt_range"},
        %{"reason" => "logger_accounting_unavailable", "count" => nil, "scope" => "unknown"}
      ],
      "filtered" => %{
        "scope" => "since_session_start",
        "logger" => %{"level" => 120, "include" => 0},
        "telemetry" => %{"shop.checkout.stop" => %{"min_duration" => 3}},
        "view" => %{}
      }
    }

    document = %{
      "result" => batch,
      "welcome" => %{"schema" => "insider.live-welcome-quick-start/v1", "quick_start" => %{}}
    }

    assert {:text, text} = Format.render("events", %{format: "compact"}, document)

    [welcome, event, trailer, lost, more] =
      text |> IO.iodata_to_binary() |> String.split("\n", trim: true)

    assert welcome =~ "# welcome:"
    assert event =~ "7 05:01:51.107 telemetry shop.checkout.stop info"

    assert trailer ==
             "# batch cursor=0 next_cursor=58 next_receipt=120 events=1 truncated_by=limit state=running disclosure=rich " <>
               "gaps=evicted:4,logger_accounting_unavailable:unknown " <>
               "filtered=logger.level:120,telemetry.shop.checkout.stop.min_duration:3"

    # An evicted range and a cut read each say so in one line, with what to do.
    assert lost ==
             "# lost: 4 events evicted in this range (the Recorder was full and dropped its oldest); " <>
               "the first event shown is receipt 7, not 1. Read sooner, or record less: digest hints say what"

    assert more ==
             "# more: this read stopped at its --limit; continue with --cursor 58, or raise --limit (up to 500)"

    cut = %{batch | "truncated_by" => "max_bytes", "gaps" => []}

    assert IO.iodata_to_binary(Format.batch_lines(cut)) =~
             "\n# more: this read stopped at its --max-bytes; continue with --cursor 58, or raise --max-bytes (up to 1048576)\n"

    quiet = %{batch | "gaps" => [], "filtered" => %{"logger" => %{"level" => 0}}, "events" => []}
    assert IO.iodata_to_binary(Format.batch_lines(quiet)) =~ "gaps=none filtered=none"
  end

  test "a compact otel line names the span, its kind, duration, status, outcome, and trace" do
    trace = "4bf92f3577b34da6a3ce929d0e0e4736"

    span =
      full_event(%{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "warning",
        "attributes" => %{
          "trace_id" => trace,
          "span_id" => "00f067aa0ba902b7",
          "name" => "mutation placeBuyOrder",
          "span_kind" => "server",
          "status" => "unset",
          "duration_us" => 13_400,
          "graphql" => %{
            "operation_type" => "mutation",
            "operation_name" => "placeBuyOrder",
            "result" => "user_errors",
            "error_count" => 0,
            "user_error_count" => 1,
            "user_error_fields" => ["unitPrice"]
          }
        }
      })

    assert Format.event_line(entry(span)) ==
             "7 05:01:51.107 otel otel.span warning <0.412.0> " <>
               ~s(name="mutation placeBuyOrder" span_kind=server duration_us=13400 status=unset ) <>
               "result=user_errors user_errors=1 fields=[unitPrice] trace=#{trace}"

    plain = put_in(span, ["attributes"], %{"name" => "GET /", "span_kind" => "server"})

    assert Format.event_line(entry(plain)) ==
             ~s(7 05:01:51.107 otel otel.span warning <0.412.0> name="GET /" span_kind=server)
  end

  # Compact hid the arguments, the response type, and the actor, so the
  # agent needed --format full and jq.
  test "a compact GraphQL operation line keeps the decisive fields: operation, types, arguments, actor, client" do
    trace = "7e4854e3bd370467348303f2b105932c"

    stop =
      full_event(%{
        "kind" => "absinthe.execute.operation.stop",
        "causality" => %{"trace_id" => trace},
        "attributes" => %{
          "durations_us" => %{"duration" => 2_300},
          "graphql" => %{
            "operation_type" => "mutation",
            "operation_name" => nil,
            "result" => "ok",
            "error_count" => 0,
            "typenames" => ["ValidationError"],
            "client" => %{"user_agent" => "sync-client/2.3", "remote_ip" => "127.0.0.1"}
          }
        },
        "payload" => %{
          "metadata" => %{"options" => %{"context" => %{"actor" => %{"id" => "user-de54"}}}},
          "graphql_arguments" => %{
            "updateOrder" => %{
              "input" => %{
                "expiry_date" => "~U[2027-04-23 00:00:00Z]",
                "order_id" => "dbb1a9ab-bc6f-4a6a-a0a2-2bd0f81eef2a",
                "price" => %{"amount" => "6.30", "currency" => "EUR"},
                "note" => String.duplicate("n", 100),
                "tags" => ["a", "b", "c"]
              }
            }
          },
          "graphql_data" => %{"updateOrder" => %{"__typename" => "ValidationError"}}
        }
      })

    assert Format.event_line(entry(stop)) ==
             "7 05:01:51.107 telemetry absinthe.execute.operation.stop info <0.412.0> " <>
               "graphql=mutation:updateOrder result=ok types=[ValidationError] " <>
               ~s(args="expiry_date:~U[2027-04-23 00:00:00Z],note:#{String.duplicate("n", 47)}…,) <>
               ~s(order_id:dbb1a9ab-bc6f-4a6a-a0a2-2bd0f81eef2a,price.amount:6.30,price.currency:EUR,+1 more" ) <>
               "actor=user-de54 client=sync-client/2.3 duration_us=2300 trace=#{trace}"

    # Strict: no payload, no names, no client; the outcome's kind and counts stay.
    strict =
      stop
      |> Map.put("payload", nil)
      |> put_in(["attributes", "graphql"], %{
        "operation_type" => "mutation",
        "operation_name" => nil,
        "result" => "ok",
        "typenames" => []
      })

    assert Format.event_line(entry(strict)) ==
             "7 05:01:51.107 telemetry absinthe.execute.operation.stop info <0.412.0> " <>
               "graphql=mutation result=ok duration_us=2300 trace=#{trace}"
  end

  # Agents decoded Oban's term-encoded args by hand.
  test "a compact Oban job line names the worker, queue, attempt, state, and the args" do
    oban = %{
      "job_id" => 7,
      "worker" => "Oban.Pro.Decorator",
      "queue" => "notifications",
      "attempt" => 1,
      "max_attempts" => 20,
      "state" => "success",
      "args_keys" => ["arg", "fun", "mod"]
    }

    job =
      full_event(%{
        "kind" => "oban.job.stop",
        "attributes" => %{"durations_us" => %{"duration" => 3_000}, "oban" => oban},
        "payload" => %{
          "oban_args" => %{
            "mod" => "MyApp.Auditor",
            "fun" => "write_record",
            "arg" => ["2ded1cd"]
          }
        }
      })

    assert Format.event_line(entry(job)) ==
             "7 05:01:51.107 telemetry oban.job.stop info <0.412.0> worker=Oban.Pro.Decorator queue=notifications " <>
               ~s(attempt=1/20 state=success args={"arg":["2ded1cd"],"fun":"write_record","mod":"MyApp.Auditor"} ) <>
               "duration_us=3000"

    strict = Map.put(job, "payload", nil)

    assert Format.event_line(entry(strict)) ==
             "7 05:01:51.107 telemetry oban.job.stop info <0.412.0> worker=Oban.Pro.Decorator queue=notifications " <>
               "attempt=1/20 state=success args_keys=[arg,fun,mod] duration_us=3000"

    span =
      full_event(%{
        "source" => "otel",
        "kind" => "otel.span",
        "attributes" => %{
          "name" => "Oban.Pro.Decorator process",
          "span_kind" => "consumer",
          "duration_us" => 3_100
        },
        "payload" => %{
          "span_attributes" => %{
            "oban.job.worker" => "Oban.Pro.Decorator",
            "messaging.destination.name" => "notifications",
            "oban.job.attempt" => 1,
            "oban.job.max_attempts" => 20
          }
        }
      })

    assert Format.event_line(entry(span)) ==
             ~s(7 05:01:51.107 otel otel.span info <0.412.0> name="Oban.Pro.Decorator process" span_kind=consumer ) <>
               "duration_us=3100 worker=Oban.Pro.Decorator queue=notifications attempt=1/20"
  end

  test "a compact batch that set the reader's view says so before its trailer" do
    batch = %{
      "events" => [],
      "cursor" => 0,
      "next_cursor" => 5,
      "view_note" =>
        "this view is now reader agent-a's view for its later reads (events, digest, trace, timeline) until --view-clear; it hid 5 events here"
    }

    text = batch |> Format.batch_lines() |> IO.iodata_to_binary()

    assert text =~
             ~r/\A# note: this view is now reader agent-a's view .* until --view-clear; it hid 5 events here\n# batch /
  end

  test "watch lines, and the digest's human text" do
    subscribed = %{
      "kind" => "subscribed",
      "target" => "shop@host",
      "result" => %{"session_id" => "live-6", "disclosure_profile" => "strict"},
      "subscription" => %{"cursor" => 12, "max_events" => nil}
    }

    assert {:text, text} = Format.render("watch", %{format: "compact"}, subscribed)

    assert IO.iodata_to_binary(text) ==
             "# subscribed session=live-6 target=shop@host disclosure=strict cursor=12\n"

    stopped = %{"kind" => "stopped", "reason" => "duration", "events" => 3, "next_cursor" => 15}
    assert {:text, text} = Format.render("watch", %{format: "compact"}, stopped)

    assert IO.iodata_to_binary(text) ==
             "# stopped events=3 next_cursor=15 reason=duration\n" <>
               "# more: watch stopped at its --for; continue with watch --from-cursor 15, or events --cursor 15\n"

    assert {:json, ^stopped} = Format.render("watch", %{format: "json"}, stopped)

    batch = %{"kind" => "batch", "result" => %{"events" => [entry(full_event(%{}))]}}

    assert {:json, %{"result" => %{"events" => [lean]}}} =
             Format.render("watch", %{format: "json"}, batch)

    refute Map.has_key?(lean["event"], "boot_id")

    assert {:text, "summary\n"} =
             Format.render("digest", %{human?: true}, %{"result" => %{"text" => "summary\n"}})

    digest = %{"result" => %{"schema" => "insider.live-digest/v1"}}
    assert {:json, ^digest} = Format.render("digest", %{human?: false}, digest)

    # bin_leak --human prints its text, the biggest holder first.
    # trace and timeline --human print their text, not the JSON.
    for operation <- ["trace", "timeline"] do
      assert {:text, "tree\n"} =
               Format.render(operation, %{human?: true}, %{"result" => %{"text" => "tree"}})
    end

    assert {:text, "holders\n"} =
             Format.render("bin_leak", %{human?: true}, %{"result" => %{"text" => "holders\n"}})

    leak = %{"result" => %{"schema" => "insider.live-bin-leak/v1"}}
    assert {:json, ^leak} = Format.render("bin_leak", %{human?: false, options: %{}}, leak)
    assert Format.formats() == ["json", "compact", "full"]
  end

  # A read of decoded Oban jobs cut by the byte cap
  # keeps its job lines and still says how to continue, in flags events takes.
  test "a compact Oban read cut by the byte cap prints the job lines and a valid # more: hint" do
    oban = %{
      "job_id" => 7,
      "worker" => "Oban.Pro.Decorator",
      "queue" => "notifications",
      "attempt" => 1,
      "max_attempts" => 20,
      "state" => "success",
      "args_keys" => ["arg", "fun", "mod"]
    }

    job =
      full_event(%{
        "kind" => "oban.job.stop",
        "attributes" => %{"durations_us" => %{"duration" => 3_000}, "oban" => oban},
        "payload" => %{"oban_args" => %{"mod" => "MyApp.Auditor", "fun" => "write_record"}}
      })

    batch = %{
      "cursor" => 6,
      "next_cursor" => 7,
      "next_receipt" => 40,
      "truncated_by" => "max_bytes",
      "events" => [entry(job)],
      "gaps" => []
    }

    lines =
      batch |> Format.batch_lines() |> IO.iodata_to_binary() |> String.split("\n", trim: true)

    assert [job_line, "# batch " <> _trailer, more] = lines
    assert job_line =~ "worker=Oban.Pro.Decorator queue=notifications attempt=1/20 state=success"
    assert job_line =~ ~s(args={"fun":"write_record","mod":"MyApp.Auditor"})

    assert more ==
             "# more: this read stopped at its --max-bytes; continue with --cursor 7, " <>
               "or raise --max-bytes (up to 1048576)"

    for step <- steps(more) do
      [operation | flags] = command(step, "events")

      assert {:ok, _command} =
               CLI.parse(
                 [operation | flags] ++ ~w(--session s --node app@localhost --cookie-file /x)
               ),
             step
    end
  end

  # A compact watch printed events flags that watch
  # rejects. Every next step a compact line prints parses as a command of
  # the operation it names, or else of the one that printed it.
  test "every next step a compact events or watch line prints is a command that is accepted" do
    cut = fn bound ->
      %{
        "cursor" => 0,
        "next_cursor" => 58,
        "next_receipt" => 120,
        "truncated_by" => bound,
        "events" => [entry(full_event(%{}))],
        "gaps" => [%{"reason" => "evicted", "count" => 4, "scope" => "receipt_range"}]
      }
    end

    events =
      for bound <- ["limit", "max_bytes", "scan_limit"],
          do: {"events", Format.batch_lines(cut.(bound))}

    # A pushed batch is cut by the fixed push bounds; the stream goes on, so
    # it prints no next step.
    pushed =
      for bound <- ["limit", "max_bytes"] do
        {:text, text} =
          Format.render("watch", %{format: "compact"}, %{
            "kind" => "batch",
            "result" => cut.(bound)
          })

        refute IO.iodata_to_binary(text) =~ "# more:"
        {"watch", text}
      end

    stopped =
      for reason <- ["max_events", "duration", "interrupted"] do
        line = %{"kind" => "stopped", "reason" => reason, "events" => 4, "next_cursor" => 4}
        {:text, text} = Format.render("watch", %{format: "compact"}, line)
        assert IO.iodata_to_binary(text) =~ "# more: watch stopped", reason
        {"watch", text}
      end

    steps =
      for {printed_by, text} <- events ++ pushed ++ stopped,
          line <- text |> IO.iodata_to_binary() |> String.split("\n"),
          String.starts_with?(line, "# more:"),
          step <- steps(line),
          do: command(step, printed_by)

    assert length(steps) == 12

    for [operation | flags] = step <- steps do
      assert {:ok, _command} =
               CLI.parse(
                 [operation | flags] ++ ~w(--session s --node app@localhost --cookie-file /x)
               ),
             inspect(step)
    end
  end

  # The steps after "continue with", split at ", or "; "raise --limit" raises
  # it on the read that continues.
  defp steps(line) do
    [first | rest] =
      line |> String.split("continue with ") |> List.last() |> String.split(", or ")

    [
      first
      | Enum.map(rest, fn
          "raise " <> raised -> first <> " " <> raised
          other -> other
        end)
    ]
  end

  # "watch --from-cursor 4 (and a larger --max-events)" is
  # `watch --from-cursor 4 --max-events 1`; a flag without a number is given 1.
  defp command(step, printed_by) do
    operation =
      case Regex.run(~r/\A(watch|events) --/, step) do
        [_, operation] -> operation
        nil -> printed_by
      end

    flags =
      ~r/(--[a-z-]+)(?: (\d+))?/
      |> Regex.scan(step)
      |> Enum.flat_map(fn
        [_, flag, value] -> [flag, value]
        [_, flag] -> [flag, "1"]
      end)

    [operation | flags]
  end
end
