defmodule Insider.Fixtures.RestartStorm do
  @moduledoc false

  use Supervisor

  alias Insider.Fixtures.Observation
  alias Insider.Fixtures.RestartStorm.Owner

  @spec run(pos_integer(), :faulty | :healthy) :: Observation.t()
  def run(run_id, variant), do: Owner.run(run_id, variant)

  @impl true
  def init({parent, run_id, variant, counter, token}) do
    child = %{
      id: __MODULE__.Worker,
      start: {__MODULE__.Worker, :start_link, [{parent, run_id, variant, counter, token}]},
      restart: :permanent
    }

    Supervisor.init([child], strategy: :one_for_one, max_restarts: 4, max_seconds: 1)
  end

  defmodule Worker do
    @moduledoc false

    use GenServer, restart: :permanent

    @spec start_link({pid(), pos_integer(), :faulty | :healthy, pid(), reference()}) ::
            GenServer.on_start()
    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl true
    def init({parent, run_id, variant, counter, token}) do
      {generation, begun} =
        Agent.get_and_update(counter, fn state ->
          generation = state.generation + 1
          {{generation, state.begun}, %{state | generation: generation}}
        end)

      send(
        parent,
        {:fixture_worker, run_id, :worker_started, self(), generation, System.monotonic_time()}
      )

      state = {parent, run_id, variant, generation, token}
      if begun, do: {:ok, state, {:continue, :maybe_crash}}, else: {:ok, state}
    end

    @impl true
    def handle_continue(:maybe_crash, {parent, run_id, :faulty, generation, _token})
        when generation <= 3 do
      send(
        parent,
        {:fixture_worker, run_id, :worker_crashed, self(), generation, System.monotonic_time()}
      )

      {:stop, :fixture_crash, nil}
    end

    def handle_continue(:maybe_crash, state), do: {:noreply, state}

    @impl true
    def handle_info(
          {:fixture_begin, token},
          {_parent, _run_id, _variant, _generation, token} = state
        ),
        do: handle_continue(:maybe_crash, state)

    def handle_info(_message, state), do: {:noreply, state}
  end
end
