defmodule Insider.Collector.Session.RootSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl Supervisor
  def init(_options) do
    # The session supervisor starts first. The Manager admits calls as soon as
    # its init/1 returns, and a start it admits needs the supervisor: if the
    # supervisor is not yet registered, the start fails with :noproc and
    # leaves a quarantined start that nothing clears.
    children = [
      {DynamicSupervisor,
       strategy: :one_for_one, name: Insider.Collector.Session.Supervisor, max_children: 1},
      Insider.Collector.Session.Manager
    ]

    # Manager owns the only session handle/history state. If either it or the
    # dynamic session supervisor fails, restart both and tear down every child
    # instead of retaining handles that no longer describe live ownership.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
