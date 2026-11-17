defmodule Insider.Fixtures.TelemetryLifecycle do
  @moduledoc false

  alias Insider.Fixtures.Observation

  @event_prefix [:insider, :fixture, :operation]
  @timeout 1_000

  @spec run(pos_integer(), :faulty | :healthy) :: Observation.t()
  def run(run_id, variant) do
    parent = self()
    handler_id = {__MODULE__, run_id, make_ref()}
    events = [@event_prefix ++ [:start], @event_prefix ++ [:stop]]

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {parent, run_id})

    try do
      :telemetry.execute(@event_prefix ++ [:start], %{monotonic_time: System.monotonic_time()}, %{
        run_id: run_id
      })

      if variant == :healthy do
        :telemetry.execute(@event_prefix ++ [:stop], %{duration: 1}, %{run_id: run_id})
      end

      expected = if variant == :healthy, do: 2, else: 1

      %Observation{
        run_id: run_id,
        scenario: :telemetry_lifecycle,
        variant: variant,
        events: collect(run_id, expected, [])
      }
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), {pid(), pos_integer()}) :: :ok
  def handle_event(event_name, measurements, %{run_id: run_id}, {destination, run_id}) do
    send(destination, {:fixture_telemetry, run_id, event_name, measurements})
    :ok
  end

  def handle_event(_event_name, _measurements, _metadata, _destination), do: :ok

  defp collect(_run_id, 0, events), do: Enum.reverse(events)

  defp collect(run_id, remaining, events) do
    receive do
      {:fixture_telemetry, ^run_id, event_name, measurements} ->
        sequence = length(events) + 1
        phase = List.last(event_name)

        event = %{
          sequence: sequence,
          kind: telemetry_kind(phase),
          monotonic_time: System.monotonic_time(),
          metadata: %{event_name: event_name, measurements: measurements, run_id: run_id}
        }

        collect(run_id, remaining - 1, [event | events])
    after
      @timeout -> raise "fixture timed out awaiting Telemetry event"
    end
  end

  defp telemetry_kind(:start), do: :telemetry_start
  defp telemetry_kind(:stop), do: :telemetry_stop
end
