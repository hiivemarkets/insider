defmodule InsiderTest.HintsTarget do
  @moduledoc false

  # A GenServer's callbacks that hints name in these tests.

  def handle_call(request, _from, state), do: {:reply, request, state}
  def handle_cast(_request, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}
  def reserve(stock, sku), do: div(1, Map.fetch!(stock, sku))
  def ready?, do: true
end

defmodule Insider.Live.HintsTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Digest
  alias Insider.Live.Hints

  @target "InsiderTest.HintsTarget"

  # The shapes a rich session discloses for a GenServer crash, a supervisor
  # report, a Logger-formatted exception, and a Telemetry exception.
  defp terminate(receipt, module \\ @target) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "logger",
        "kind" => "otp_report",
        "severity" => "error",
        "attributes" => %{"domain" => ["otp"], "label" => "gen_server.terminate"},
        "payload" => %{
          "message" =>
            "%{label: {:gen_server, :terminate}, name: #{module}, reason: {:badarith, [{:erlang, :div, [1, 0], " <>
              "[error_info: \"…[depth_limit]\"]}, {#{module}, :handle_call, 3, [file: \"…[depth_limit]\", line: 5]}, " <>
              "{:gen_server, :try_handle_call, 4, ...}, ...]}, ...}",
          "metadata" => %{"mfa" => "{:gen_server, :error_info, 7}"}
        }
      }
    }
  end

  defp terminated(receipt, ms, offender \\ "atom:Elixir." <> @target, payload \\ nil) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "logger",
        "kind" => "supervisor_child_terminated",
        "severity" => "error",
        "wall_time" =>
          DateTime.to_iso8601(DateTime.add(~U[2026-10-23 17:54:04.000000Z], ms, :millisecond)),
        "attributes" => %{
          "domain" => ["otp", "sasl"],
          "offender_id" => offender,
          "restart_type" => "permanent",
          "reason_class" => "abnormal",
          "reason_fingerprint" => "b1f96d655cf7de80aa"
        },
        "payload" => payload
      }
    }
  end

  defp logged(receipt, message, mfa, severity \\ "error") do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "logger",
        "kind" => "logger_message",
        "severity" => severity,
        "attributes" => %{"domain" => ["elixir"]},
        "payload" => %{"message" => message, "metadata" => %{"mfa" => mfa}}
      }
    }
  end

  defp telemetry(receipt, kind, metadata \\ %{}, severity \\ "info") do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => kind,
        "severity" => severity,
        "attributes" => %{"lifecycle_phase" => "event"},
        "payload" => %{"metadata" => metadata}
      }
    }
  end

  defp context(overrides \\ %{}) do
    Hints.context(
      Map.merge(
        %{
          "session_id" => "live-7",
          "components" => ["logger", "poller", "telemetry"],
          "calls" => nil,
          "max_events" => 4_096,
          "filters" => %{"logger_summaries" => [], "telemetry_summaries" => []},
          "poller" => %{"interval_ms" => 5_000},
          "recorder" => %{"sources" => %{}}
        },
        overrides
      ),
      Map.get(overrides, :available, :ok)
    )
  end

  defp digest(entries, context) do
    entries
    |> Enum.reduce(Digest.new("live-7", 0, context), fn entry, acc ->
      Digest.add(acc, %{"events" => [entry], "next_cursor" => entry["receipt"], "gaps" => []})
    end)
    |> Digest.finish(nil, "shop@host")
  end

  # A digest whose first batch reports 900 events the Recorder evicted.
  defp evicted_digest(entries, context) do
    entries
    |> Enum.reduce(Digest.new("live-7", 0, context), fn entry, acc ->
      gaps =
        if entry["receipt"] == 1,
          do: [%{"reason" => "evicted", "scope" => "receipt_range", "count" => 900}],
          else: []

      Digest.add(acc, %{"events" => [entry], "next_cursor" => entry["receipt"], "gaps" => gaps})
    end)
    |> Digest.finish(nil, "shop@host")
  end

  defp evicted_anomaly(digest), do: Enum.find(digest["anomalies"], &(&1["kind"] == "evicted"))

  defp span(receipt, name) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "otel",
        "kind" => "otel.span",
        "severity" => "info",
        "attributes" => %{
          "name" => name,
          "trace_id" => String.pad_leading("#{receipt}", 32, "0"),
          "span_id" => String.pad_leading("#{receipt}", 16, "0")
        }
      }
    }
  end

  describe "the function a crash points at" do
    test "is the stack's first application frame that a call trace could trace" do
      assert Hints.frame(terminate(1)["event"]) == @target <> ".handle_call/3"

      # Elixir's formatted stacktrace, after runtime frames.
      formatted =
        logged(
          2,
          "** (ArithmeticError) bad argument in arithmetic expression\n    (elixir) lib/kernel.ex:1: Kernel.div/2\n" <>
            "    (shop 0.1.0) lib/shop.ex:34: #{@target}.reserve/2\n    (stdlib) gen_server.erl:2470: :gen_server.try_handle_call/4",
          nil
        )

      assert Hints.frame(formatted["event"]) == @target <> ".reserve/2"

      # A Telemetry exception's rendered stacktrace.
      exception =
        telemetry(3, "shop.op.exception", %{
          "kind" => "error",
          "stacktrace" => [
            "{Enum, :map, 2, [file: ~c\"lib/enum.ex\", line: 1]}",
            "{#{@target}, :handle_info, 2, [file: ~c\"lib/shop.ex\", line: 3]}"
          ]
        })

      assert Hints.frame(exception["event"]) == @target <> ".handle_info/2"
    end

    test "is never a runtime, preloaded, Insider, unloaded, or argument-list frame" do
      for text <- [
            "{GenServer, :call, 3, [file: \"x\"]}",
            "{:gen_server, :try_handle_call, 4, [file: \"x\"]}",
            "{:erlang, :div, 2, []}",
            "{Insider.Live.Hints, :frame, 1, []}",
            "{NoSuch.Module, :run, 1, []}",
            "{#{@target}, :reserve, [%{}, \"fig\"], []}",
            "#{@target}.nope/9"
          ] do
        event = %{"payload" => %{"message" => text}}
        assert Hints.frame(event) == nil, text
      end

      assert Hints.frame(%{"payload" => nil}) == nil
    end

    # A Telemetry stack rendered by the rich profile is a
    # list; its first application frame is the one that failed.
    test "in a rendered Telemetry stack with several application frames, is the first" do
      payload =
        Insider.Collector.Rich.telemetry_payload(%{
          kind: :error,
          stacktrace: [
            {Enum, :map, 2, [file: ~c"lib/enum.ex", line: 1]},
            {InsiderTest.HintsTarget, :handle_cast, 2, [file: ~c"lib/shop.ex", line: 3]},
            {InsiderTest.HintsTarget, :handle_info, 2, [file: ~c"lib/shop.ex", line: 9]},
            {InsiderTest.HintsTarget, :reserve, 2, [file: ~c"lib/shop.ex", line: 12]}
          ]
        })

      event = %{"source" => "telemetry", "kind" => "shop.op.exception", "payload" => payload}
      assert Hints.frame(event) == @target <> ".handle_cast/2"
    end
  end

  describe "a digest's call-trace hint" do
    test "a crash loop names the crashing function, keeps the session's components, and says why" do
      entries = [terminate(1), terminated(2, 0), terminate(3), terminated(4, 3_000)]
      digest = digest(entries, context())

      assert [%{"function" => function, "count" => 2, "first_receipt" => 1}] =
               digest["call_candidates"]

      assert function == @target <> ".handle_call/3"

      assert [hint] = digest["hints"]

      assert %{
               "kind" => "trace_calls",
               "command" =>
                 "mix insider.live amend \"${N[@]}\" --session 'live-7' --component 'logger' --component 'poller' --component 'telemetry' " <>
                   "--component 'calls' --calls 'InsiderTest.HintsTarget.handle_call/3' --calls-results 'exceptions'",
               "options" => %{
                 "components" => ["logger", "poller", "telemetry", "calls"],
                 "calls" => ["InsiderTest.HintsTarget.handle_call/3"],
                 "calls_results" => "exceptions"
               },
               "evidence" => %{"crash_loop" => @target, "count" => 2}
             } = hint

      assert hint["reason"] =~ "#{@target} terminated 2 times, every 3.0 s"
      assert hint["reason"] =~ "point at #{@target}.handle_call/3"

      text = Digest.text(digest)
      assert hint["window"] == %{"since" => 0, "first_receipt" => 1, "last_receipt" => 4}
      assert text =~ "Next (receipts 1-4): #{hint["reason"]}: #{hint["command"]}"
    end

    test "functions the session already traces are kept, and one it traces already is not suggested" do
      traced =
        context(%{
          "components" => ["calls", "logger"],
          "calls" => %{"functions" => ["#{@target}.reserve/2"]}
        })

      [hint] = digest([terminate(1), terminate(2)], traced)["hints"]

      assert hint["options"]["calls"] == ["#{@target}.reserve/2", "#{@target}.handle_call/3"]
      assert hint["options"]["components"] == ["calls", "logger"]

      already =
        context(%{
          "components" => ["calls", "logger"],
          "calls" => %{"functions" => ["#{@target}.handle_call/3"]}
        })

      assert digest([terminate(1), terminate(2)], already)["hints"] == []
    end

    # `--calls` resolves a spelling to its function
    # and refuses the same function twice, so hints compare functions, not
    # spellings, and name each one as `--calls` accepts it.
    test "an equivalent spelling of a traced function is the same function, in both directions" do
      for traced <- ["Elixir.#{@target}.handle_call/3", "#{@target}.handle_call/3"] do
        context = context(%{"components" => ["calls"], "calls" => %{"functions" => [traced]}})
        assert digest([terminate(1), terminate(2)], context)["hints"] == [], traced
      end

      # Evidence that spells the module with Elixir., or as a quoted atom,
      # names it as --calls accepts it.
      prefixed = fn receipt ->
        put_in(
          terminate(receipt),
          ["event", "payload", "message"],
          "{:badarith, [{:\"Elixir.#{@target}\", :reserve, 2, []}]}"
        )
      end

      [hint] = digest([prefixed.(1), prefixed.(2)], context())["hints"]
      assert hint["options"]["calls"] == ["#{@target}.reserve/2"]

      # The callback fallback keeps the session's spelling of a traced
      # callback and adds only the others.
      context =
        context(%{
          "components" => ["calls"],
          "calls" => %{"functions" => ["Elixir.#{@target}.handle_call/3"]}
        })

      [hint] = digest([terminated(1, 0), terminated(2, 3_000)], context)["hints"]

      assert hint["options"]["calls"] == [
               "Elixir.#{@target}.handle_call/3",
               "#{@target}.handle_cast/2",
               "#{@target}.handle_info/2"
             ]

      assert {:ok, _parsed} =
               Insider.Live.CallsOptions.start(hint["options"], ["calls"])
    end

    test "a crash loop whose reports name no function points at the child's GenServer callbacks" do
      digest = digest([terminated(1, 0), terminated(2, 3_000)], context())

      assert [%{"kind" => "trace_calls", "options" => %{"calls" => calls}} = hint] =
               digest["hints"]

      assert calls == [
               "#{@target}.handle_call/3",
               "#{@target}.handle_cast/2",
               "#{@target}.handle_info/2"
             ]

      assert hint["reason"] =~ "its crashes name no function; these are its GenServer callbacks"
    end

    test "a repeated exception is suggested, a single one or a plain error log is not" do
      exception = fn receipt ->
        logged(
          receipt,
          "** (ArithmeticError) bad\n    (shop) lib/shop.ex:3: #{@target}.reserve/2",
          "{Shop.Checkout, :run, 2}"
        )
      end

      assert digest([exception.(1)], context())["hints"] == []

      assert digest(
               [logged(1, "checkout failed", nil), logged(2, "checkout failed", nil)],
               context()
             )["hints"] == []

      assert [
               %{
                 "kind" => "trace_calls",
                 "evidence" => %{"functions" => ["#{@target}.reserve/2"], "count" => 2}
               } = hint
             ] =
               digest([exception.(1), exception.(2)], context())["hints"]

      assert hint["reason"] =~
               "2 failures point at #{@target}.reserve/2 (logger_message, first at receipt 1)"
    end

    test "without call tracing on this OTP the hint says so and gives the recon_trace call" do
      digest =
        digest([terminate(1), terminate(2)], context(%{available: {:error, "requires_otp_28"}}))

      assert [
               %{
                 "kind" => "trace_calls_unavailable",
                 "command" => nil,
                 "options" => nil,
                 "manual" => ":recon_trace.calls({InsiderTest.HintsTarget, :handle_call, 3}, 10)"
               } = hint
             ] = digest["hints"]

      assert hint["reason"] =~ "needs OTP 28 or later (requires_otp_28"
      assert Digest.text(digest) =~ "Next (receipts 1-2): #{hint["reason"]}: #{hint["manual"]}"
    end

    test "a digest without a session context has no hints" do
      assert digest([terminate(1), terminate(2)], nil)["hints"] == []
      lazy = digest([terminate(1), terminate(2)], fn -> nil end)
      assert lazy["hints"] == []
      refute Digest.text(lazy) =~ "Next"
    end

    # An amendment's list replaces the session's, so a
    # hint that would push it past its limit cannot be applied.
    test "a function that would exceed the traced-function limit is explained, not offered" do
      full =
        ~w(Enum.map/2 Enum.filter/2 Enum.reduce/3 Enum.sum/1 Enum.count/1 Enum.sort/1 Enum.uniq/1 Enum.zip/2
           Enum.take/2 Enum.drop/2 Enum.find/2 Enum.join/2 Enum.at/2 Enum.at/3 Enum.max/1 Enum.min/1)

      context = context(%{"components" => ["calls", "logger"], "calls" => %{"functions" => full}})
      digest = digest([terminate(1), terminate(2)], context)
      assert [hint] = digest["hints"]

      assert %{"kind" => "trace_calls", "command" => nil, "options" => nil, "manual" => nil} =
               hint

      assert hint["reason"] =~ "already traces 16 functions, the most --calls allows"
      assert hint["evidence"]["limit"] == 16
      assert Digest.text(digest) =~ "Next (receipts 1-2): #{hint["reason"]}."
    end
  end

  # A value a hint puts in a command is never shell
  # syntax: values that are not valid options are refused, and every value
  # is single-quoted.
  describe "commands in a shell" do
    @hostile ["review; echo PWNED", "a b", "$(id)", "`id`", "it's", "\"q\"", "x\ny"]

    defp shell_argv(shell, command) do
      script = String.replace(command, "mix insider.live amend \"${N[@]}\"", "printf '%s\\0'")
      {output, 0} = System.cmd(shell, ["-c", script])
      String.split(output, <<0>>, trim: true)
    end

    test "hostile Logger domains are never offered as a summary rule" do
      flood = %{
        "recorder" => %{
          "sources" => %{
            "logger" => %{
              "evicted" => 9,
              "retained_events" => 30,
              "reserved_events" => 16,
              "share_percent" => 25
            }
          }
        }
      }

      for hostile <- @hostile do
        events =
          for receipt <- 1..3 do
            put_in(logged(receipt, "boom", nil), ["event", "attributes", "domain"], [hostile])
          end

        hints = digest(events, context(flood))["hints"]
        refute Enum.any?(hints, &(&1["kind"] == "reduce_logger")), inspect(hostile)

        refute Enum.any?(hints, &(is_binary(&1["command"]) and &1["command"] =~ hostile)),
               inspect(hostile)
      end
    end

    test "every value is single-quoted, so a shell passes each one through as one argument" do
      hostile = Enum.join(@hostile, " ")

      crash = fn receipt ->
        logged(receipt, "** (RuntimeError) x\n    (shop) lib/shop.ex:3: #{@target}.ready?/0", nil)
      end

      [hint] = digest([crash.(1), crash.(2)], context(%{"session_id" => hostile}))["hints"]

      expected =
        ["--session", hostile] ++
          Enum.flat_map(~w(logger poller telemetry calls), &["--component", &1]) ++
          ["--calls", "#{@target}.ready?/0", "--calls-results", "exceptions"]

      shells = for shell <- ~w(sh bash zsh), path = System.find_executable(shell), do: path
      assert shells != []

      for shell <- shells, do: assert(shell_argv(shell, hint["command"]) == expected, shell)
    end
  end

  describe "an events batch's hint" do
    test "a batch that shows one crash suggests tracing its function" do
      assert [%{"kind" => "trace_calls", "evidence" => %{"crash_loop" => nil, "count" => 1}}] =
               Hints.batch([terminate(5), %{"receipt" => 6}], context())

      assert Hints.batch([logged(5, "fine", nil, "info")], context()) == []
    end
  end

  describe "eviction hints" do
    defp sources(extra) do
      Map.merge(
        %{
          "inspect" => %{
            "evicted" => 0,
            "retained_events" => 0,
            "reserved_events" => 204,
            "share_percent" => 5
          }
        },
        extra
      )
    end

    defp flood(group, evicted, retained, reserved, share),
      do: %{
        group => %{
          "evicted" => evicted,
          "retained_events" => retained,
          "reserved_events" => reserved,
          "share_percent" => share
        }
      }

    test "a Logger flood is summarised by the module that logged most, keeping the session's rules" do
      logs =
        for receipt <- 1..5,
            do: logged(receipt, "checkout failed for #{receipt}", "{#{@target}, :reserve, 2}")

      other = logged(6, "low stock", "{Shop.Inventory, :check, 1}", "warning")

      context =
        context(%{
          "filters" => %{
            "logger_summaries" => [%{"domain" => ["otp", "sasl"]}],
            "telemetry_summaries" => []
          },
          "recorder" => %{"sources" => sources(flood("logger", 631, 1_200, 1_024, 25))}
        })

      assert [hint, %{"kind" => "record_less"}] = digest(logs ++ [other], context)["hints"]

      assert %{
               "kind" => "reduce_logger",
               "command" =>
                 "mix insider.live amend \"${N[@]}\" --session 'live-7' --logger-summary 'domain:otp.sasl' --logger-summary 'module:InsiderTest.HintsTarget'",
               "options" => %{
                 "logger_summaries" => [
                   %{"domain" => ["otp", "sasl"]},
                   %{"module" => @target}
                 ]
               },
               "evidence" => %{
                 "evicted" => 631,
                 "share_percent" => 25,
                 "origin" => "module:InsiderTest.HintsTarget",
                 "events" => 5
               }
             } = hint

      assert hint["reason"] =~ "evicted 631 logger events"
      assert hint["reason"] =~ "1200 events against its 25% share of 1024"
    end

    test "a Logger flood without call sites is summarised by its domain" do
      logs = for receipt <- 1..3, do: logged(receipt, "boom", nil)
      context = context(%{"recorder" => %{"sources" => flood("logger", 9, 30, 16, 25)}})

      assert [%{"command" => command}, %{"kind" => "record_less"}] =
               digest(logs, context)["hints"]

      assert command =~ "--logger-summary 'domain:elixir'"
    end

    test "a Telemetry flood is summarised by its most recorded kind; a Poller flood samples less often" do
      events =
        for(receipt <- 1..4, do: telemetry(receipt, "shop.pricing.lookup")) ++
          [telemetry(5, "shop.checkout.stop")]

      context =
        context(%{
          "filters" => %{"telemetry_summaries" => ["shop.checkout.stop"]},
          "recorder" => %{
            "sources" =>
              Map.merge(
                flood("telemetry", 159, 700, 614, 15),
                flood("poller", 56, 1_100, 1_024, 25)
              )
          }
        })

      assert [telemetry_hint, poller_hint, %{"kind" => "record_less"}] =
               digest(events, context)["hints"]

      assert %{
               "kind" => "reduce_telemetry",
               "options" => %{
                 "telemetry_summaries" => ["shop.checkout.stop", "shop.pricing.lookup"]
               },
               "evidence" => %{"kind" => "shop.pricing.lookup", "events" => 4}
             } = telemetry_hint

      assert telemetry_hint["command"] =~
               "--telemetry-summary 'shop.checkout.stop' --telemetry-summary 'shop.pricing.lookup'"

      assert %{"kind" => "reduce_poller", "options" => %{"poller_interval_ms" => 10_000}} =
               poller_hint

      assert poller_hint["command"] =~ "--poller-interval-ms '10000'"
    end

    test "a Recorder below its bound suggests a larger one; a source within its share is not a flood" do
      context =
        context(%{
          "max_events" => 64,
          "recorder" => %{
            "sources" =>
              Map.merge(flood("logger", 240, 60, 16, 25), flood("poller", 3, 2, 16, 25))
          }
        })

      assert [%{"kind" => "reduce_logger"}, capacity] =
               digest([logged(1, "boom", "{#{@target}, :reserve, 2}")], context)["hints"]

      assert %{
               "kind" => "raise_capacity",
               "command" =>
                 "mix insider.live amend \"${N[@]}\" --session 'live-7' --max-events '4096'",
               "options" => %{"max_events" => 4_096},
               "evidence" => %{"max_events" => 64, "evicted" => %{"logger" => 240}}
             } = capacity

      assert digest(
               [logged(1, "boom", nil)],
               context(%{"recorder" => %{"sources" => sources(%{})}})
             )["hints"] ==
               []
    end

    # Two readers and two Next servers' spans evicted 659 events in
    # minutes.
    test "a flood with several readers says they share one Recorder and what keeps it" do
      sources = %{"recorder" => %{"sources" => flood("otel", 659, 900, 256, 25)}}

      shared =
        digest([logged(1, "boom", nil)], context(Map.put(sources, "reader_count", 2)))["hints"]

      assert %{
               "kind" => "shared_readers",
               "command" => nil,
               "options" => nil,
               "evidence" => %{"readers" => 2, "evicted" => 659}
             } = Enum.find(shared, &(&1["kind"] == "shared_readers"))

      reason = Enum.find(shared, &(&1["kind"] == "shared_readers"))["reason"]
      assert reason =~ "2 readers share this session's one Recorder"
      assert reason =~ "digest"
      assert reason =~ "--telemetry-summary"

      alone = digest([logged(1, "boom", nil)], context(Map.put(sources, "reader_count", 1)))
      refute Enum.any?(alone["hints"], &(&1["kind"] == "shared_readers"))
    end

    # A source also holds a share of the Recorder's bytes;
    # large events evict over that share with few events retained.
    test "a source over its byte share is a flood, even with the Recorder at its event bound" do
      bytes = %{
        "logger" => %{
          "evicted" => 835,
          "retained_events" => 665,
          "reserved_events" => 1_024,
          "retained_bytes" => 4_191_577,
          "reserved_bytes" => 1_048_576,
          "share_percent" => 25
        }
      }

      context = context(%{"max_events" => 4_096, "recorder" => %{"sources" => bytes}})

      assert [hint, %{"kind" => "record_less"} = less] =
               digest([logged(1, "boom", "{#{@target}, :reserve, 2}")], context)["hints"]

      assert less["reason"] =~ "already at its most events (--max-events 4096)"

      assert %{
               "kind" => "reduce_logger",
               "evidence" => %{"retained_bytes" => 4_191_577, "reserved_bytes" => 1_048_576}
             } = hint

      assert hint["reason"] =~ "4191577 bytes against its 25% share of 1048576 bytes"
    end

    # A sweep at --max-events 4096, the most, evicted most of its
    # requests; a hint to raise it to 4096 changed nothing.
    test "at the Recorder's bound, no hint offers a larger one; record_less names the family that evicted most" do
      most = Insider.Live.Options.start_bounds()["max_events"]["max"]

      events =
        for(receipt <- 1..6, do: telemetry(receipt, "shop.repo.query")) ++
          [telemetry(7, "phoenix.endpoint.stop")]

      context =
        context(%{
          "max_events" => most,
          "recorder" => %{"sources" => flood("telemetry", 50_000, 700, 614, 15)}
        })

      hints = digest(events, context)["hints"]

      refute Enum.any?(hints, &(&1["kind"] == "raise_capacity"))
      refute Enum.any?(hints, &(is_binary(&1["command"]) and &1["command"] =~ "--max-events"))

      assert %{"evidence" => %{"kind" => "shop.repo.query", "events" => 6}} =
               Enum.find(hints, &(&1["kind"] == "reduce_telemetry"))

      assert %{
               "command" => nil,
               "evidence" => %{
                 "max_events" => ^most,
                 "max_events_bound" => ^most,
                 "dominant" => %{
                   "source" => "telemetry",
                   "name" => "shop.repo.query",
                   "events" => 6
                 }
               }
             } = less = Enum.find(hints, &(&1["kind"] == "record_less"))

      assert less["reason"] =~ "a larger one is not possible"
      assert less["reason"] =~ "most of it the Telemetry event shop.repo.query (6 in this window)"

      for flag <-
            ~w(--telemetry-summary --logger-summary --otel-min-duration-ms --exclude-origin --retain-traces --since-mark),
          do: assert(less["reason"] =~ flag, flag)
    end

    test "below the bound, the larger Recorder offered is larger than the session's and within the bound" do
      most = Insider.Live.Options.start_bounds()["max_events"]["max"]
      least = Insider.Live.Options.start_bounds()["max_events"]["min"]

      for max_events <- [least, 64, div(most, 2), most - 1] do
        context =
          context(%{
            "max_events" => max_events,
            "recorder" => %{"sources" => flood("logger", 240, 60, 16, 25)}
          })

        hints = digest([logged(1, "boom", "{#{@target}, :reserve, 2}")], context)["hints"]

        assert %{"options" => %{"max_events" => offered}, "command" => command} =
                 Enum.find(hints, &(&1["kind"] == "raise_capacity")),
               "max_events #{max_events}"

        assert offered > max_events and offered <= most
        assert command =~ "--max-events '#{offered}'"
        refute Enum.any?(hints, &(&1["kind"] == "record_less"))
      end
    end

    test "a span flood raises the span minimum and names the span recorded most" do
      spans =
        for(receipt <- 1..5, do: span(receipt, "shop.repo.query")) ++ [span(6, "GET /orders")]

      otel = fn filters ->
        context(%{
          "components" => ["logger", "otel"],
          "filters" => filters,
          "recorder" => %{"sources" => flood("otel", 900, 500, 409, 10)}
        })
      end

      hint = fn filters ->
        Enum.find(digest(spans, otel.(filters))["hints"], &(&1["kind"] == "reduce_otel"))
      end

      assert %{
               "command" =>
                 "mix insider.live amend \"${N[@]}\" --session 'live-7' --otel-min-duration-ms '10'",
               "options" => %{"otel_min_duration_ms" => 10},
               "evidence" => %{
                 "span" => "shop.repo.query",
                 "events" => 5,
                 "otel_min_duration_ms" => 0
               }
             } = first = hint.(%{"otel_min_duration_ms" => 0})

      assert first["reason"] =~ "5 of the window's spans were shop.repo.query"

      assert %{"options" => %{"otel_min_duration_ms" => 80}} =
               hint.(%{"otel_min_duration_ms" => 40})

      # A set minimum doubles, however small; 10 ms is only the step from 0.
      for current <- [1, 4] do
        doubled = current * 2

        assert %{"options" => %{"otel_min_duration_ms" => ^doubled}} =
                 hint.(%{"otel_min_duration_ms" => current})
      end

      assert %{"options" => %{"otel_min_duration_ms" => 3_600_000}} =
               hint.(%{"otel_min_duration_ms" => 3_000_000})

      assert %{"command" => nil, "options" => nil} =
               at_most = hint.(%{"otel_min_duration_ms" => 3_600_000})

      assert at_most["reason"] =~ "already 3600000, the most"

      # Without the otel component, --otel-min-duration-ms would be refused.
      no_otel = context(%{"recorder" => %{"sources" => flood("otel", 900, 500, 409, 10)}})
      refute Enum.any?(digest(spans, no_otel)["hints"], &(&1["kind"] == "reduce_otel"))
    end

    test "the eviction anomaly follows the hints: a larger Recorder only below the bound, else what to record less of" do
      events = for receipt <- 1..6, do: telemetry(receipt, "shop.repo.query")
      flood = %{"recorder" => %{"sources" => flood("telemetry", 50_000, 700, 614, 15)}}

      at_most = evicted_digest(events, context(flood))
      below = evicted_digest(events, context(Map.put(flood, "max_events", 1_024)))
      unknown = evicted_digest(events, nil)

      assert %{"line" => line, "command" => command} = evicted_anomaly(at_most)
      assert line =~ "Evicted: the Recorder evicted 900 events in this window"
      assert line =~ "already at its most events (--max-events 4096)"
      assert line =~ "summarise the Telemetry event shop.repo.query (6 in this window)"
      refute command =~ "--max-events"
      assert command =~ "--telemetry-summary 'shop.repo.query'"

      assert %{"line" => line, "command" => command} = evicted_anomaly(below)
      assert line =~ "it holds 1024 events"
      assert command =~ "--max-events '4096'"

      assert %{"command" => command} = evicted_anomaly(unknown)
      refute command =~ "--max-events"
      assert command =~ "status"
    end

    test "the eviction anomaly at the bound without an amendment to offer says to mark and record less" do
      # Every recorded kind is already summarised, so no reduce_telemetry.
      events = for receipt <- 1..6, do: telemetry(receipt, "shop.repo.query")

      context =
        context(%{
          "filters" => %{"telemetry_summaries" => ["shop.repo.query"]},
          "recorder" => %{"sources" => flood("telemetry", 50_000, 700, 614, 15)}
        })

      assert %{"line" => line, "command" => command} =
               events |> evicted_digest(context) |> evicted_anomaly()

      assert line =~ "already at its most events (--max-events 4096)"

      assert line =~
               "of the Telemetry event shop.repo.query, which made 6 of this window's events"

      assert line =~ "--retain-traces N"
      assert command =~ "mark \"${N[@]}\" --session live-7"
    end

    test "a summary list at its limit is explained, not extended" do
      rules =
        for module <-
              ~w(Enum Map List Kernel String Integer Float Atom Tuple Process Node Agent Task File Path IO),
            do: %{"module" => module}

      kinds = for index <- 1..16, do: "shop.kind#{index}"

      flood = fn group ->
        %{
          group => %{
            "evicted" => 9,
            "retained_events" => 30,
            "reserved_events" => 16,
            "share_percent" => 25
          }
        }
      end

      context =
        context(%{
          "filters" => %{"logger_summaries" => rules, "telemetry_summaries" => kinds},
          "recorder" => %{"sources" => Map.merge(flood.("logger"), flood.("telemetry"))}
        })

      events = [
        logged(1, "boom", "{#{@target}, :reserve, 2}"),
        telemetry(2, "shop.pricing.lookup")
      ]

      hints = digest(events, context)["hints"]

      for kind <- ["reduce_logger", "reduce_telemetry"] do
        hint = Enum.find(hints, &(&1["kind"] == kind))
        assert %{"command" => nil, "options" => nil} = hint, kind
        assert hint["reason"] =~ "already has 16, the most allowed", kind
        assert hint["evidence"]["limit"] == 16, kind
      end
    end

    # Logger reports (crash, supervisor, and other
    # report messages) are always recorded and never summarised.
    test "a flood of Logger reports gets no summary rule, and says what would help" do
      reports = for receipt <- 1..5, do: terminate(receipt)
      flood = %{"recorder" => %{"sources" => flood("logger", 170, 64, 16, 25)}}
      hints = digest(reports, context(Map.put(flood, "max_events", 64)))["hints"]

      refute Enum.any?(hints, &(is_binary(&1["command"]) and &1["command"] =~ "--logger-summary"))

      assert %{"kind" => "logger_reports", "command" => nil, "options" => nil} =
               report = Enum.find(hints, &(&1["kind"] == "logger_reports"))

      assert report["evidence"]["reports"] == %{"otp_report" => 5}
      assert report["reason"] =~ "5 of the window's Logger events were reports"
      assert report["reason"] =~ "never summarised"
      assert report["reason"] =~ "--max-events"
      assert Enum.any?(hints, &(&1["kind"] == "raise_capacity"))
    end

    # A report flood over its byte share only is not
    # helped by more events; the byte bound is fixed.
    test "a report flood over its byte share only never suggests --max-events" do
      reports = for receipt <- 1..5, do: terminate(receipt)

      bytes = %{
        "logger" => %{
          "evicted" => 835,
          "retained_events" => 40,
          "reserved_events" => 16_000,
          "retained_bytes" => 4_191_577,
          "reserved_bytes" => 1_048_576,
          "share_percent" => 25
        }
      }

      hints =
        digest(reports, context(%{"max_events" => 64, "recorder" => %{"sources" => bytes}}))[
          "hints"
        ]

      report = Enum.find(hints, &(&1["kind"] == "logger_reports"))
      assert %{"command" => nil, "options" => nil} = report
      refute report["reason"] =~ "--max-events"
      refute report["reason"] =~ "raise_capacity"
      assert report["reason"] =~ "the Recorder's byte bound is fixed"
      assert report["reason"] =~ "smaller or fewer reports"
      refute Enum.any?(hints, &(&1["kind"] == "raise_capacity"))
    end

    test "in a mixed flood, only the messages are summarised" do
      events =
        for(receipt <- 1..6, do: terminate(receipt)) ++
          for(
            receipt <- 7..9,
            do: logged(receipt, "boom #{receipt}", "{#{@target}, :reserve, 2}")
          )

      flood = %{"recorder" => %{"sources" => flood("logger", 170, 64, 16, 25)}}
      hint = Enum.find(digest(events, context(flood))["hints"], &(&1["kind"] == "reduce_logger"))

      assert %{
               "kind" => "reduce_logger",
               "options" => %{"logger_summaries" => [%{"module" => @target}]},
               "evidence" => %{"events" => 3, "reports" => %{"otp_report" => 6}}
             } = hint

      assert hint["reason"] =~ "6 reports are always recorded"
    end
  end
end
