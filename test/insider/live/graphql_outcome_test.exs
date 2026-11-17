defmodule Insider.Live.GraphqlOutcomeTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Insider.Live

  @stop [:absinthe, :execute, :operation, :stop]
  @trace_hex "5bf92f3577b34da6a3ce929d0e0e4737"
  @span_hex "00f067aa0ba902b8"

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end
    end)
  end

  # Absinthe's operation stop metadata; Absinthe is not a dependency, so the
  # blueprint is a map with its struct name.
  defp operation(name, type, result) do
    # The operation selects its field's `__typename` and its validation
    # `errors { field type }`.
    errors = field("errors", [field("field"), field("type")])

    blueprint = %{
      __struct__: Absinthe.Blueprint,
      operations: [
        %{
          name: name,
          type: type,
          current: true,
          selections: [field(name, [field("__typename"), errors])]
        }
      ],
      fragments: [],
      result: result
    }

    # In a request process, under its trace context.
    Task.await(
      Task.async(fn ->
        Logger.metadata(otel_trace_id: @trace_hex, otel_span_id: @span_hex)
        :telemetry.execute(@stop, %{duration: 1_000}, %{blueprint: blueprint, options: []})
      end)
    )
  end

  defp field(name, selections \\ []),
    do: %{
      __struct__: Absinthe.Blueprint.Document.Field,
      name: name,
      alias: nil,
      selections: selections
    }

  defp user_error do
    operation("placeBuyOrder", :mutation, %{
      data: %{
        "placeBuyOrder" => %{
          "__typename" => "PlaceBuyOrderPayload",
          "errors" => [
            %{"field" => "unitPrice", "message" => "at least 1.00", "type" => "min"}
          ]
        }
      }
    })
  end

  defp graphql_error do
    operation("listing", :query, %{
      data: nil,
      errors: [%{message: "no listing L-77", path: ["listing"], code: "NOT_FOUND"}]
    })
  end

  defp start(extra \\ %{}) do
    assert {:ok, %{"session_id" => id}} =
             Live.start(
               Map.merge(
                 %{
                   "components" => ["telemetry"],
                   "telemetry_events" => [Enum.map(@stop, &Atom.to_string/1)],
                   "telemetry_min_duration_ms" => 0
                 },
                 extra
               )
             )

    id
  end

  defp operations(id) do
    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 100})

    for %{"event" => %{"kind" => "absinthe.execute.operation.stop"} = event} <- batch["events"],
        do: event
  end

  test "errors inside a 200 response show in events, the digest, and the trace" do
    id = start()
    user_error()
    graphql_error()
    operation("ok", :query, %{data: %{"listing" => %{"id" => "L-1"}}})

    assert [user, error, ok] = operations(id)

    assert user["severity"] == "warning"

    assert %{
             "operation_name" => "placeBuyOrder",
             "result" => "user_errors",
             "user_error_fields" => ["unitPrice"]
           } = user["attributes"]["graphql"]

    assert error["severity"] == "error"

    assert %{"result" => "errors", "error_codes" => ["NOT_FOUND"], "error_paths" => ["listing"]} =
             error["attributes"]["graphql"]

    assert ok["severity"] == "info"
    assert ok["attributes"]["graphql"]["result"] == "ok"

    assert {:ok, digest} = Live.digest(id, %{"human" => true})
    signatures = Enum.map(digest["error_signatures"], & &1["signature"])

    assert "absinthe.execute.operation.stop mutation placeBuyOrder result=user_errors fields=[unitPrice]" in signatures

    assert "absinthe.execute.operation.stop query listing result=errors codes=[NOT_FOUND] paths=[listing]" in signatures

    assert [_, _] = signatures
    assert digest["text"] =~ "placeBuyOrder result=user_errors"

    assert {:ok, trace} = Live.trace(id, @trace_hex, %{"human" => true})
    assert trace["text"] =~ "mutation placeBuyOrder result=user_errors"
    assert trace["text"] =~ "query listing result=errors errors=1 codes=[NOT_FOUND]"
    refute trace["text"] =~ "at least 1.00"
    refute Jason.encode!(digest) =~ "L-77"
  end

  test "under the strict profile only the operation type, result kind, and counts pass" do
    Application.put_env(:insider, :environment, :ci)
    id = start()
    user_error()

    assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 100})

    [entry] =
      Enum.filter(batch["events"], &(&1["event"]["kind"] == "absinthe.execute.operation.stop"))

    assert entry["event"]["attributes"]["graphql"] == %{
             "operation_name" => nil,
             "operation_type" => "mutation",
             "result" => "user_errors",
             "complete" => true,
             "error_count" => 0,
             "error_codes" => [],
             "error_paths" => [],
             "typenames" => [],
             "user_error_count" => 1,
             "user_error_fields" => [],
             "user_error_types" => [],
             "withheld" => 0
           }

    refute Jason.encode!(batch) =~ "placeBuyOrder"
    refute Jason.encode!(batch) =~ "unitPrice"

    # Each withheld name list leaves a drop record, never the names.
    withheld =
      for %{"path" => ["key:attributes", "key:graphql", "key:" <> key], "action" => "drop"} <-
            entry["redactions"],
          do: key

    assert Enum.sort(withheld) ==
             ["operation_name", "typenames", "user_error_fields", "user_error_types"]
  end
end
