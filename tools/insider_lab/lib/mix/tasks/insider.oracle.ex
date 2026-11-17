defmodule Mix.Tasks.Insider.Oracle do
  @shortdoc "Runs one fixed ExUnit oracle against a target and saves the run"
  @moduledoc """
  Runs one fixed, value-free ExUnit oracle artifact against one selected test
  command in a target Mix project, without editing the target, and saves a
  versioned `insider.oracle-run/v1` record in a new run directory.

      mix insider.oracle --profile host.json --root /path/to/project \\
        --output /tmp/runs/run-1 --oracle application_env \\
        --application logger --key default_handler \\
        -- test/path/to/selected_test.exs --seed 1

  `--oracle` is `application_env` (with `--application` and one of `--key` or
  `--keys`), `telemetry_dead_handlers` (with `--event`), or
  `otel_global_state`. `--context`, `--timeout-ms`, `--max-output-bytes`,
  `--output-policy` (`allowlisted`, the default, or `redacted`),
  `--fingerprint-timeout-ms`, and `--fingerprint-max-bytes` are optional.
  The run directory must resolve outside the target and its Git work tree.
  Everything after `--` is the selected test command: 1 to 16
  paths inside the root, optionally with `:line`, plus `--seed`,
  `--max-cases`, `--max-failures`, `--timeout`, `--trace`, `--only`,
  `--include`, or `--exclude`.

  The task prints the run record. Exit status is `0` (complete, outcome
  `not_reproduced`), `2` (complete, `confirmed`), `6` (complete,
  `not_observed`), `3` (`empty_selection`), `4` (`unsupported_source`), `5`
  (`truncated`), `70` (`infrastructure_failure`), or `64` for invalid input,
  which creates no run directory. See `guides/agents/oracles.md`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    {output, status} = Insider.Discovery.ExUnit.OracleRunner.CLI.run(arguments)
    Insider.Lab.Output.write(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
