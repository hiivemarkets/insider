defmodule Insider.Test.Eventually do
  @moduledoc false

  # Waits for a state the test does not control the timing of, such as a
  # supervised restart. It polls `predicate` every 10 ms and fails with
  # `message` when the predicate is still false after `timeout_ms`. Use it
  # only for an explicit condition, never to retry a failed operation.

  import ExUnit.Assertions, only: [flunk: 1]

  @spec await((-> as_boolean(term())), pos_integer(), String.t()) :: :ok
  def await(predicate, timeout_ms \\ 5_000, message \\ "the condition did not become true") do
    wait(predicate, System.monotonic_time(:millisecond) + timeout_ms, message)
  end

  defp wait(predicate, deadline, message) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(message)

      true ->
        Process.sleep(10)
        wait(predicate, deadline, message)
    end
  end
end
