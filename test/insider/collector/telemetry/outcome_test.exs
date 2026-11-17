defmodule Insider.Collector.Telemetry.OutcomeTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Telemetry.Outcome

  # One failing metadata shape per row of `Outcome.rules/0`, in row order,
  # as the libraries named in the row's examples emit it.
  @failures [
    {[:phoenix, :router_dispatch, :exception], %{kind: :error, reason: :boom}},
    {[:my_app, :repo, :query], %{result: {:error, :timeout}, source: "users"}},
    {[:phoenix, :endpoint, :stop], %{conn: %{status: 503, method: "GET"}}},
    {[:telemetry_span, :stop], %{kind: :exit}},
    {[:oban, :plugin, :stop], %{plugin: Oban.Plugins.Pruner, error: :db_down}},
    {[:absinthe, :execute, :operation, :stop],
     %{blueprint: %{__struct__: Absinthe.Blueprint, result: %{errors: [%{message: "m"}]}}}}
  ]

  test "every rule row has a failing example that the rule rates as a failure" do
    assert length(@failures) == length(Outcome.rules())
    assert Enum.all?(Outcome.rules(), &(&1["severity"] == "error"))

    for {name, metadata} <- @failures do
      assert Outcome.error?(name, metadata), inspect({name, metadata})
    end
  end

  test "exception events are failures whatever their metadata" do
    assert Outcome.error?([:oban, :job, :exception], %{})
    assert Outcome.error?([:exception], :not_a_map)
    refute Outcome.error?([:exception, :count], %{})
  end

  test "each failure shape, and the healthy shapes beside it" do
    for metadata <- [
          %{result: {:error, %{reason: :closed}}},
          %{result: :error},
          %{conn: %{status: 500}},
          %{conn: %{status: 599}},
          %{status: 502},
          %{kind: :error},
          %{kind: :exit},
          %{kind: :throw},
          %{error: "connection refused"},
          %{error: :timeout},
          # A later shape still applies when an earlier key is healthy.
          %{result: {:ok, %{}}, conn: %{status: 504}},
          %{conn: %{status: 200}, kind: :error}
        ] do
      assert Outcome.failed?(metadata), inspect(metadata)
    end

    for metadata <- [
          %{},
          %{result: {:ok, %{num_rows: 1}}},
          %{result: :ok},
          %{result: {:error}},
          %{conn: %{status: 200}},
          %{conn: %{status: 404}},
          %{conn: %{status: 499}},
          %{conn: %{status: 600}},
          %{conn: %{status: "500"}},
          %{conn: %{status: nil}},
          %{status: 404},
          %{status: 500.0},
          %{kind: :ok},
          %{kind: "error"},
          %{error: nil},
          %{error: false},
          :not_a_map,
          nil
        ] do
      refute Outcome.failed?(metadata), inspect(metadata)
    end
  end
end
