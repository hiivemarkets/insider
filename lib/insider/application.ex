defmodule Insider.Application do
  @moduledoc false

  use Application

  alias Insider.Live.Environment

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(),
      strategy: :one_for_one,
      name: Insider.Supervisor
    )
  end

  @doc false
  @spec children() :: [module()]
  def children, do: children(Environment.resolve())

  # The live session owner and the in-node report queue exist only where live
  # observation is allowed. The owner follows the session root so the Manager
  # is running when the owner starts, and the gate keeper, which reclaims the
  # record-time gates of an owner that dies, so the keeper outlives every owner.
  @doc false
  @spec children(Environment.resolved()) :: [module()]
  def children(environment) do
    if Environment.allowed?(environment),
      do: [
        Insider.Collector.Session.RootSupervisor,
        Insider.Live.Gates,
        Insider.Live.Owner,
        Insider.Live.Reports
      ],
      else: [Insider.Collector.Session.RootSupervisor]
  end
end
