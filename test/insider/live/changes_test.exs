defmodule Insider.Live.ChangesTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Changes

  @flag "new-checkout"
  @trace "5bf92f3577b34da6a3ce929d0e0e4730"
  @t0 1_761_300_000_000_000

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  defp subject(pid), do: %{"namespace" => "process", "scope" => "n@h", "value" => pid}

  defp write(receipt, pid, at_us, key, value \\ :none) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "calls",
        "kind" => "call",
        "wall_time" => iso(at_us),
        "subject" => subject(pid),
        "attributes" => %{
          "function" => "MyApp.Flags.put/2",
          "write" => true,
          "key" => key
        },
        "payload" => if(value == :none, do: nil, else: %{"arguments" => [key, value]})
      }
    }
  end

  defp mutation(receipt, pid, end_us, name, trace) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "absinthe.execute.operation.stop",
        "wall_time" => iso(end_us),
        "subject" => subject(pid),
        "causality" => %{"trace_id" => trace},
        "attributes" => %{
          "durations_us" => %{"duration" => 40_000},
          "graphql" => %{
            "operation_type" => "mutation",
            "operation_name" => name,
            "result" => "ok"
          }
        }
      }
    }
  end

  defp server(receipt, pid, end_us, agent) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "bandit.request.stop",
        "wall_time" => iso(end_us),
        "subject" => subject(pid),
        "attributes" => %{
          "request" => %{
            "role" => "server",
            "method" => "POST",
            "path" => "/api/graphql",
            "status" => 200,
            "total_us" => 60_000,
            "user_agent" => agent
          }
        }
      }
    }
  end

  defp span(receipt, pid, end_us, user) do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "otel",
        "kind" => "otel.span",
        "wall_time" => iso(end_us),
        "subject" => subject(pid),
        "causality" => %{"trace_id" => @trace},
        "attributes" => %{
          "trace_id" => @trace,
          "name" => "mutation setFeatureToggle",
          "start_wall_time" => iso(end_us - 50_000),
          "duration_us" => 50_000
        },
        "payload" => %{"span_attributes" => %{"user.id" => user}}
      }
    }
  end

  test "each write names its key, value, and the request that wrote it" do
    entries = [
      write(1, "<0.5.0>", @t0 + 10_000, @flag, 100),
      mutation(2, "<0.5.0>", @t0 + 30_000, "setFeatureToggle", @trace),
      span(3, "<0.5.0>", @t0 + 35_000, "u-arden"),
      server(4, "<0.5.0>", @t0 + 40_000, "python-urllib/3.12"),
      write(5, "<0.6.0>", @t0 + 90_000_000, @flag, 0),
      write(6, "<0.6.0>", @t0 + 90_000_100, "other-key", true)
    ]

    assert [first, second] = Changes.of(entries, key: @flag)

    assert %{
             "receipt" => 1,
             "key" => @flag,
             "value" => 100,
             "function" => "MyApp.Flags.put/2",
             "writer" => %{
               "pid" => "<0.5.0>",
               "operation" => "mutation setFeatureToggle",
               "route" => "POST /api/graphql",
               "user_agent" => "python-urllib/3.12",
               "user_id" => "u-arden",
               "trace_id" => @trace
             }
           } = first

    # An anonymous mutation is named, in rich, by its top-level fields.
    anonymous =
      put_in(mutation(2, "<0.5.0>", @t0 + 30_000, nil, @trace), ["event", "payload"], %{
        "graphql_arguments" => %{"setFeatureToggle" => %{"input" => %{}}}
      })

    assert [%{"writer" => %{"operation" => "mutation setFeatureToggle"}}] =
             Changes.of([hd(entries), anonymous])

    # A write with no request around it still names its process.
    assert %{
             "writer" => %{
               "pid" => "<0.6.0>",
               "operation" => nil,
               "trace_id" => nil,
               "attribution" => "unattributed"
             }
           } = second

    assert first["writer"]["attribution"] == "covering"

    assert [_, _, _] = Changes.of(entries)

    [header, line1, line2] = Changes.lines(Changes.of(entries, key: @flag), @flag)
    assert header == "Changes of #{@flag}: 2 writes"

    assert line1 =~
             ~r/^  \d\d:\d\d:\d\d\.\d\d\d #{@flag} = 100 by mutation setFeatureToggle \(POST \/api\/graphql, user u-arden, python-urllib\/3\.12\), trace #{@trace}, pid <0\.5\.0>$/

    assert line2 =~
             "#{@flag} = 0 by pid <0.6.0> (unattributed: no request of its process around the write)"
  end

  test "a write whose request events were evicted takes its operation from the kept mutation record" do
    records = [
      %{
        "receipt" => 2,
        "at" => iso(@t0 + 30_000),
        "operation" => "setFeatureToggle",
        "result" => "ok",
        "trace_id" => @trace,
        "pid" => "<0.5.0>"
      }
    ]

    assert [%{"writer" => writer}] =
             Changes.of([write(1, "<0.5.0>", @t0 + 10_000, @flag)], mutations: records)

    assert %{
             "operation" => "mutation setFeatureToggle",
             "trace_id" => @trace,
             "kept" => true,
             "attribution" => "kept_record"
           } =
             writer
  end

  # A keep-alive connection's process serves request after
  # request; the next request's facts must never fill in the writer's.
  test "a write takes its writer from its own request, never from the process's next one" do
    other = "6bf92f3577b34da6a3ce929d0e0e4731"

    next_span =
      span(4, "<0.5.0>", @t0 + 1_100_000, "USER-FROM-NEXT-REQUEST")
      |> put_in(["event", "causality", "trace_id"], other)
      |> put_in(["event", "attributes", "trace_id"], other)

    entries = [
      write(1, "<0.5.0>", @t0 + 10_000, @flag, 1),
      mutation(2, "<0.5.0>", @t0 + 30_000, "FirstRequest", @trace),
      next_span
    ]

    assert [%{"writer" => writer}] = Changes.of(entries)

    assert %{
             "operation" => "mutation FirstRequest",
             "trace_id" => @trace,
             "user_id" => nil,
             "attribution" => "covering"
           } = writer

    # With no request around it, only the nearest following request of the
    # process is used, and only the facts of that request's trace.
    later = [
      write(1, "<0.5.0>", @t0, @flag, 1),
      mutation(2, "<0.5.0>", @t0 + 500_000, "SecondRequest", @trace)
      |> put_in(["event", "attributes", "durations_us", "duration"], 1_000),
      next_span
    ]

    assert [%{"writer" => following}] = Changes.of(later)

    assert %{
             "operation" => "mutation SecondRequest",
             "user_id" => nil,
             "attribution" => "following"
           } =
             following

    # Requests of two traces around one write: unattributed, not merged.
    conflict = [
      write(1, "<0.5.0>", @t0 + 10_000, @flag, 1),
      mutation(2, "<0.5.0>", @t0 + 30_000, "FirstRequest", @trace),
      span(3, "<0.5.0>", @t0 + 35_000, "u-other")
      |> put_in(["event", "causality", "trace_id"], other)
      |> put_in(["event", "attributes", "trace_id"], other)
    ]

    assert [
             %{
               "writer" => %{
                 "attribution" => "unattributed",
                 "operation" => nil,
                 "user_id" => nil
               }
             } = c
           ] =
             Changes.of(conflict)

    assert hd(tl(Changes.lines([c], @flag))) =~
             "(unattributed: requests of 2 traces around the write)"
  end

  test "every write counts toward repeated keys, and a page of them says what it left out" do
    entries = for n <- 1..257, do: write(n, "<0.5.0>", @t0 + n * 1_000, @flag, n)
    changes = Changes.of(entries)
    assert Enum.count(changes) == 257
    assert [%{"writes" => 257, "complete" => true}] = Changes.repeated(changes)
    assert [%{"complete" => false}] = Changes.repeated(changes, false)

    assert ["Changes of #{@flag}: 257 writes (the newest 256 shown)" | rows] =
             Changes.lines(Enum.take(changes, -256), @flag, 257)

    assert Enum.count(rows) == 256

    assert hd(Changes.lines(Enum.take(changes, -256), @flag, 256)) ==
             "Changes of #{@flag}: 256 writes"
  end

  test "keys written repeatedly are an anomaly that names their writers" do
    entries =
      for n <- 0..2 do
        [
          write(10 * n + 1, "<0.#{n}.0>", @t0 + n * 120_000_000, @flag, rem(n, 2) * 100),
          mutation(
            10 * n + 2,
            "<0.#{n}.0>",
            @t0 + n * 120_000_000 + 20_000,
            "setFeatureToggle",
            @trace
          ),
          span(10 * n + 3, "<0.#{n}.0>", @t0 + n * 120_000_000 + 25_000, "u-arden")
        ]
      end
      |> List.flatten()

    assert [row] = Changes.repeated(Changes.of(entries))

    assert row == %{
             "key" => @flag,
             "writes" => 3,
             "values" => 2,
             "complete" => true,
             "writers" => [
               %{"writer" => "mutation setFeatureToggle by user u-arden", "writes" => 3}
             ]
           }

    assert Changes.repeated(Changes.of([write(1, "<0.1.0>", @t0, "k", 1)])) == []
  end
end
