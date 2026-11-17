defmodule Insider.Live.MutationsTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Mutations

  @trace "4bf92f3577b34da6a3ce929d0e0e4736"

  defp stop(receipt, type, name, result, pid \\ "<0.9.0>") do
    %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "absinthe.execute.operation.stop",
        "wall_time" => "2026-10-24T21:00:0#{rem(receipt, 10)}.000000Z",
        "subject" => %{"namespace" => "process", "value" => pid},
        "causality" => %{"trace_id" => @trace},
        "attributes" => %{
          "graphql" => %{
            "operation_type" => type,
            "operation_name" => name,
            "result" => result,
            "error_count" => 0,
            "user_error_count" => if(result == "user_errors", do: 2, else: 0)
          }
        }
      }
    }
  end

  defp log(receipt),
    do: %{"receipt" => receipt, "event" => %{"source" => "logger", "kind" => "logger_message"}}

  defp read(cursor, next, events, evicted \\ 0),
    do: %{"cursor" => cursor, "next_cursor" => next, "events" => events, "evicted" => evicted}

  test "keeps one compact record per mutation, and nothing else" do
    ring =
      Mutations.new()
      |> Mutations.start(0)
      |> Mutations.sweep(
        read(0, 4, [
          stop(1, "mutation", "setFeatureToggle", "ok"),
          stop(2, "query", "buyOrderV2", "ok"),
          log(3),
          stop(4, "mutation", "placeBuyOrder", "user_errors", "<0.10.0>")
        ])
      )

    assert [first, second] = Mutations.records(ring, :rich)

    assert first == %{
             "receipt" => 1,
             "at" => "2026-10-24T21:00:01.000000Z",
             "operation" => "setFeatureToggle",
             "result" => "ok",
             "error_count" => 0,
             "user_error_count" => 0,
             "trace_id" => @trace,
             "pid" => "<0.9.0>",
             "user_agent" => nil,
             "typenames" => [],
             "ids" => []
           }

    assert second["result"] == "user_errors"
    assert Mutations.cursor(ring) == 4

    # Strict withholds the operation's name, as the GraphQL outcome does.
    assert [%{"operation" => nil, "result" => "ok"}, _] = Mutations.records(ring, :strict)
    assert [%{"receipt" => 4}] = Mutations.records(ring, :rich, trace_id: @trace, pid: "<0.10.0>")
  end

  test "every loss is counted: the ring's bound, and receipts evicted before a sweep read them" do
    max = Mutations.bounds()["mutations_max"]
    events = for n <- 1..(max + 3), do: stop(n, "mutation", "m", "ok")

    ring =
      Mutations.new()
      |> Mutations.start(0)
      |> Mutations.sweep(read(0, max + 3, events))
      |> Mutations.sweep(read(max + 3, max + 50, [], 47))

    assert %{"records" => ^max, "dropped" => 3, "missed_receipts" => 47} =
             Mutations.describe(ring)

    assert hd(Mutations.records(ring, :rich))["receipt"] == 4
  end

  test "inactive until started" do
    refute Mutations.active?(Mutations.new())
    assert Mutations.active?(Mutations.start(Mutations.new(), 5))
    assert Mutations.cursor(Mutations.start(Mutations.new(), 5)) == 5
  end

  # A client was only on the request span, so proof took 11 minutes. A
  # rejected save printed `result=ok` (a ValidationError inside a 200). A
  # kept record could not be listed by the record it changed.
  test "a record keeps the client's user agent, the response types, and the argument ids" do
    event =
      stop(1, "mutation", "updateSellOrder", "ok")
      |> put_in(["event", "attributes", "graphql", "typenames"], ["ValidationError"])
      |> put_in(["event", "attributes", "graphql", "client"], %{
        "user_agent" => "partner-portfolio-sync/2.3",
        "remote_ip" => "127.0.0.1"
      })
      |> put_in(["event", "payload"], %{
        "graphql_arguments" => %{
          "updateSellOrder" => %{
            "input" => %{
              "sellOrderId" => "so-123",
              "listing" => %{"id" => 42, "price" => "48.00"},
              "ids" => ["a", "b"]
            }
          }
        }
      })

    ring = Mutations.new() |> Mutations.start(0) |> Mutations.sweep(read(0, 1, [event]))

    assert [record] = Mutations.records(ring, :rich)

    assert %{
             "user_agent" => "partner-portfolio-sync/2.3",
             "typenames" => ["ValidationError"],
             "ids" => ["42", "so-123"]
           } = record

    assert [_] = Mutations.records(ring, :rich, id: "so-123")
    assert [_] = Mutations.records(ring, :rich, id: "42")
    assert [] = Mutations.records(ring, :rich, id: "48.00")

    assert Mutations.line(record) ==
             "Kept mutation: updateSellOrder result=ok types=[ValidationError] at 2026-10-24T21:00:01.000000Z " <>
               "(receipt 1, pid <0.9.0>, user agent partner-portfolio-sync/2.3, trace #{@trace}, ids 42, so-123)"

    # Strict withholds the client, the names, and the ids.
    assert [%{"user_agent" => nil, "typenames" => [], "ids" => [], "operation" => nil}] =
             Mutations.records(ring, :strict)

    assert [] = Mutations.records(ring, :strict, id: "so-123")
  end

  # Ids inside a bulk mutation's input list were never indexed.
  test "ids inside lists of input objects are indexed; secret-shaped ones are not" do
    token = "ghp_" <> String.duplicate("A1b2C3d4E5", 4)

    event =
      stop(1, "mutation", "bulkUpdate", "ok")
      |> put_in(["event", "payload"], %{
        "graphql_arguments" => %{
          "bulkUpdate" => %{
            "input" => [%{"id" => "so-123"}, %{"orderId" => 7}, %{"id" => token}]
          }
        }
      })

    ring = Mutations.new() |> Mutations.start(0) |> Mutations.sweep(read(0, 1, [event]))
    assert [%{"ids" => ["7", "so-123"]}] = Mutations.records(ring, :rich)
    assert [_] = Mutations.records(ring, :rich, id: "so-123")
    assert [] = Mutations.records(ring, :rich, id: token)
  end
end
