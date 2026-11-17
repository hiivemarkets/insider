defmodule Insider.Test.OracleArtifactRunner do
  @moduledoc false

  import ExUnit.Assertions

  def run_process(executable, arguments, environment, directory \\ nil, timeout_ms \\ 10_000) do
    {executable, arguments, environment} = with_empty_values(executable, arguments, environment)

    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: arguments,
      env: environment
    ]

    options = if directory, do: Keyword.put(options, :cd, to_charlist(directory)), else: options
    port = Port.open({:spawn_executable, executable}, options)
    collect(port, [], System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)
  end

  def report(output, prefix) do
    line =
      output
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, prefix))
      |> then(&(&1 || flunk("oracle output missing: #{output}")))

    line
    |> String.replace_prefix(prefix, "")
    |> Jason.decode!()
  end

  def prefix_count(output, prefix),
    do: output |> String.split("\n") |> Enum.count(&String.starts_with?(&1, prefix))

  # Erlang ports drop environment entries whose value is empty, so those are set
  # by env(1) in front of the executable, which assigns NAME= in the child.
  defp with_empty_values(executable, arguments, environment) do
    case Enum.split_with(environment, fn {_name, value} -> value == [] end) do
      {[], _environment} ->
        {executable, arguments, environment}

      {empty, present} ->
        env = System.find_executable("env") || flunk("env executable unavailable")
        assignments = Enum.map(empty, fn {name, []} -> List.to_string(name) <> "=" end)
        {env, assignments ++ [executable | arguments], present}
    end
  end

  defp collect(port, output, deadline, timeout_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | output], deadline, timeout_ms)

      {^port, {:exit_status, status}} ->
        {status, output |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining ->
        Port.close(port)
        flunk("oracle fixture exceeded #{timeout_ms} ms")
    end
  end
end
