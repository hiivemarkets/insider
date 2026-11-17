defmodule Insider.TestSupport.ScenarioContract do
  use Insider.Contract, id: "test.scenario", version: 1

  reset(:fixture, with: &reset_fixture/0, environments: [:test])
  reset(:counted, with: &counted_reset/0, environments: [:test])
  reset(:fail_reset, with: &fail_reset/0, environments: [:test])
  action(:record, with: &record/1, environments: [:test])
  action(:block, with: &block/0, environments: [:test])
  action(:fail, with: &fail_action/0, environments: [:test])
  observe(:echo, with: &echo/1, sensitivity: :internal)
  observe(:fail_observation, with: &fail_observation/0, sensitivity: :internal)
  invariant(:truthy, check: &truthy?/1)

  owns(modules: [Insider.TestSupport.ScenarioContract])

  defp reset_fixture do
    notify(:reset)
    %{"reset" => true}
  end

  defp record(value) do
    notify({:action, value})
    value
  end

  defp counted_reset do
    count = :ets.update_counter(Insider.TestSupport.ScenarioState, :resets, 1, {:resets, 0})
    notify({:counted_reset, count})

    case :ets.lookup(Insider.TestSupport.ScenarioState, :reset_mode) do
      [{:reset_mode, :fail_final}] when count > 1 -> raise "controlled reset failure"
      [{:reset_mode, :block_final}] when count > 1 -> block_forever(:cleanup_started)
      _other -> %{"reset" => true}
    end
  end

  defp fail_action do
    notify(:action_failed)
    raise "controlled action failure"
  end

  defp fail_reset do
    notify(:reset_failed)
    raise "controlled reset failure"
  end

  defp block do
    block_forever(:block_started)
  end

  defp block_forever(notification) do
    notify(notification)

    receive do
      :never -> nil
    after
      10_000 -> nil
    end
  end

  defp echo(value) do
    notify({:observation, value})
    value
  end

  defp fail_observation do
    notify(:observation_failed)
    raise "controlled observation failure"
  end

  defp truthy?(value) do
    notify({:invariant, value})
    value == true
  end

  defp notify(message) do
    if pid = Process.whereis(Insider.TestSupport.ScenarioProbe), do: send(pid, message)
  end
end
