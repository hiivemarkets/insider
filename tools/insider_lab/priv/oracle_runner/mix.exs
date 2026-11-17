# Fixed `mix insider.oracle` bootstrap. The runner starts `mix test` in the
# target with `MIX_EXS` naming this file, so Mix loads it in place of the
# target's `mix.exs` before any task or alias runs. It compiles the target's
# own `mix.exs` (so the project, its file identity, and its build stay the
# target's), refuses unsupported hosts, marks the host's `test` alias as already
# run, and puts the run's overlay directory first in `:test_paths`. It never
# writes a file. The only command-line task is `test`, so a host `run` alias is
# never dispatched; aliases of tasks that `mix test` itself runs (such as
# `compile`) run as they would under any `mix test`.
defmodule InsiderLab.OracleRunnerBootstrap do
  @moduledoc false

  @refused_prefix "INSIDER_ORACLE_RUNNER_REFUSED="

  def run do
    host = System.fetch_env!("INSIDER_ORACLE_RUNNER_HOST_MIX_EXS")
    System.delete_env("MIX_EXS")
    Code.compile_file(host)

    case preflight() do
      {:ok, project, host_paths} -> prepare(project, host_paths)
      {:error, reason} -> refuse(reason)
    end
  end

  defp preflight do
    project = Mix.Project.get!()
    config = Mix.Project.config()
    aliases = config[:aliases] || []

    cond do
      Mix.Project.umbrella?(config) -> {:error, "umbrella_project"}
      Mix.env() != :test -> {:error, "mix_env_not_test"}
      not mix_internals?() -> {:error, "unsupported_mix_internals"}
      true -> alias_mode(project, Keyword.has_key?(aliases, :test), host_test_paths(config))
    end
  end

  defp alias_mode(project, test_alias?, host_paths) do
    case {System.fetch_env!("INSIDER_ORACLE_RUNNER_TEST_ALIAS"), test_alias?} do
      {"bypass", true} -> {:ok, project, host_paths}
      {"bypass", false} -> {:error, "test_alias_missing"}
      {"absent", false} -> {:ok, project, host_paths}
      {"absent", true} -> {:error, "test_alias_present"}
    end
  end

  defp mix_internals? do
    Code.ensure_loaded?(Mix.ProjectStack) and Code.ensure_loaded?(Mix.TasksServer) and
      function_exported?(Mix.ProjectStack, :merge_config, 1) and
      function_exported?(Mix.TasksServer, :run, 1)
  end

  defp host_test_paths(config) do
    config[:test_paths] || if(File.dir?("test"), do: ["test"], else: [])
  end

  defp prepare(project, host_paths) do
    overlay = Path.expand(System.fetch_env!("INSIDER_ORACLE_RUNNER_OVERLAY"))

    # Marking the alias as already run makes the CLI's `Mix.Task.run("test")`
    # invoke the task itself, not the host's alias (which may drop a database).
    Mix.TasksServer.run({:alias, "test", project})
    Mix.ProjectStack.merge_config(test_paths: [overlay | host_paths])
  end

  defp refuse(reason) do
    IO.puts([@refused_prefix, :json.encode(%{"reason" => reason})])
    exit({:shutdown, 1})
  end
end

InsiderLab.OracleRunnerBootstrap.run()
