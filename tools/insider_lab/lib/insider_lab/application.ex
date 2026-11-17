defmodule Insider.Lab.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Insider.Lab.Supervisor)
  end

  @doc false
  @spec children() :: [Supervisor.child_spec()]
  def children do
    :insider_lab
    |> Application.get_env(:components, [:contract])
    |> Enum.flat_map(&component_children/1)
    |> Enum.uniq_by(&Supervisor.child_spec(&1, []).id)
  end

  defp component_children(:contract), do: [Insider.Contract.Executor]
  defp component_children(:scenario), do: [Insider.Contract.Executor, Insider.Scenario.Executor]
  defp component_children(:sentinel), do: [{Insider.Sentinel.Sandbox.Executor, providers: []}]

  defp component_children(component) do
    raise ArgumentError,
          "unknown Insider Lab component #{inspect(component)}; expected :contract, :scenario, or :sentinel"
  end
end
