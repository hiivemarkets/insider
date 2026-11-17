defmodule Mix.Tasks.Insider.Candidates do
  @shortdoc "Lists bounded ExUnit investigation candidates as JSON"
  @moduledoc """
  Lists static ExUnit isolation-risk signals for agent-directed investigation.

      mix insider.candidates --root /path/to/project
      mix insider.candidates --root /path/to/project --path test/integration
      mix insider.candidates --root /path/to/project --path test/a_test.exs --path test/b_test.exs

  Exit status is `0` only for a complete scan with no candidates, `2` for a
  complete scan with candidates, `3` when the selection held no eligible
  `_test.exs` file, `4` when a source could not be analyzed, `5` when a bound
  truncated the scan, `64` for invalid arguments, and `70` when inventory cannot
  be completed. Exits `3` to `5` still print the inventory and its candidates.
  Candidates are not confirmed runtime failures.
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    {output, status} = Insider.Discovery.ExUnit.InventoryCLI.run(arguments)
    Insider.Lab.Output.write(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
