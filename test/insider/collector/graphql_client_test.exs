defmodule Insider.Collector.GraphqlClientTest do
  # Telemetry handlers are node-global.
  use ExUnit.Case, async: false

  alias Insider.Collector.GraphqlClient

  @start [:phoenix, :endpoint, :start]
  @stop [:phoenix, :endpoint, :stop]
  @exception [:phoenix, :endpoint, :exception]

  defp conn(agent),
    do: %{
      __struct__: Plug.Conn,
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"user-agent", agent}]
    }

  defp in_request(fun), do: Task.await(Task.async(fun))

  setup do
    on_exit(fn -> GraphqlClient.detach(:graphql_client_test) end)
  end

  test "a request's client is known between its endpoint start and stop, bounded and masked" do
    generation = GraphqlClient.generation()
    :ok = GraphqlClient.attach(:graphql_client_test, generation)
    token = "ghp_" <> String.duplicate("A1b2C3d4E5", 4)

    in_request(fn ->
      :telemetry.execute(@start, %{}, %{conn: conn("sync/2.3 " <> token)})
      client = GraphqlClient.current(generation)
      assert client["remote_ip"] == "127.0.0.1"
      assert client["user_agent"] =~ "sync/2.3"
      refute client["user_agent"] =~ "A1b2C3"

      :telemetry.execute(@stop, %{}, %{conn: conn("x")})
      assert GraphqlClient.current(generation) == nil

      :telemetry.execute(@start, %{}, %{conn: conn("y/1")})
      :telemetry.execute(@exception, %{}, %{conn: conn("y/1"), kind: :error, reason: :boom})
      assert GraphqlClient.current(generation) == nil
    end)
  end

  # A collection that stopped mid-request left the client in
  # the request process, and a later collection took it for its own.
  test "a client remembered by an earlier collection is never the current one" do
    first = GraphqlClient.generation()
    :ok = GraphqlClient.attach(:graphql_client_test, first)

    in_request(fn ->
      :telemetry.execute(@start, %{}, %{conn: conn("old-client/1")})
      :ok = GraphqlClient.detach(:graphql_client_test)
      :telemetry.execute(@stop, %{}, %{conn: conn("old-client/1")})

      second = GraphqlClient.generation()
      :ok = GraphqlClient.attach(:graphql_client_test, second)
      assert GraphqlClient.current(second) == nil
      assert GraphqlClient.current(nil) == nil
    end)
  end
end
