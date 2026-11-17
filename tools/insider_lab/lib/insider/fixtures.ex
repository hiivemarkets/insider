defmodule Insider.Fixtures do
  @moduledoc """
  Deterministic faulty scenarios and nearby healthy controls.

  Fixtures exercise actual OTP processes, supervisors, mailboxes, tasks, and
  Telemetry handlers. They synchronize with messages instead of sleeps and
  clean up every resource before returning.
  """

  alias Insider.Fixtures.Observation
  alias Insider.Fixtures.RestartStorm
  alias Insider.Fixtures.Runtime
  alias Insider.Fixtures.TelemetryLifecycle

  @scenarios [
    :restart_storm,
    :mailbox_growth,
    :leaked_task,
    :late_effect,
    :telemetry_lifecycle,
    :semantic_invariant,
    :recorder_overload
  ]
  @variants [:faulty, :healthy]
  @maximum_work 1_000

  @spec run(atom(), atom(), keyword()) :: {:ok, Observation.t()} | {:error, atom()}
  def run(scenario, variant, options \\ [])

  def run(scenario, _variant, _options) when scenario not in @scenarios,
    do: {:error, :unknown_scenario}

  def run(_scenario, variant, _options) when variant not in @variants,
    do: {:error, :unknown_variant}

  def run(scenario, variant, options) when is_list(options) do
    with :ok <- validate_options(scenario, options) do
      run_id = System.unique_integer([:positive, :monotonic])
      {:ok, execute(scenario, variant, options, run_id)}
    end
  end

  def run(_scenario, _variant, _options), do: {:error, :invalid_options}

  @spec run!(atom(), atom(), keyword()) :: Observation.t()
  def run!(scenario, variant, options \\ []) do
    case run(scenario, variant, options) do
      {:ok, observation} -> observation
      {:error, reason} -> raise ArgumentError, "fixture rejected: #{reason}"
    end
  end

  defp execute(:restart_storm, variant, _options, run_id),
    do: RestartStorm.run(run_id, variant)

  defp execute(:mailbox_growth, variant, options, run_id),
    do: Runtime.mailbox_growth(run_id, variant, Keyword.get(options, :work_items, 20))

  defp execute(:leaked_task, variant, _options, run_id),
    do: Runtime.leaked_task(run_id, variant)

  defp execute(:late_effect, variant, _options, run_id),
    do: Runtime.late_effect(run_id, variant)

  defp execute(:telemetry_lifecycle, variant, _options, run_id),
    do: TelemetryLifecycle.run(run_id, variant)

  defp execute(:semantic_invariant, variant, _options, run_id) do
    items = if variant == :faulty, do: [4, 5], else: [4, 6]

    %Observation{
      run_id: run_id,
      scenario: :semantic_invariant,
      variant: variant,
      samples: %{total: 10, items: items}
    }
  end

  defp execute(:recorder_overload, variant, options, run_id) do
    capacity = Keyword.get(options, :capacity, 10)
    Runtime.recorder_pressure(run_id, variant, capacity)
  end

  defp validate_options(:mailbox_growth, options),
    do: validate_single_positive_option(options, :work_items)

  defp validate_options(:recorder_overload, options),
    do: validate_single_positive_option(options, :capacity)

  defp validate_options(_scenario, []), do: :ok
  defp validate_options(_scenario, _options), do: {:error, :invalid_options}

  defp validate_single_positive_option([], _name), do: :ok

  defp validate_single_positive_option([{name, value}], name)
       when is_integer(value) and value > 0 and value <= @maximum_work,
       do: :ok

  defp validate_single_positive_option(_options, _name), do: {:error, :invalid_options}
end
