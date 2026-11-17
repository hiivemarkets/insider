defmodule Mix.Tasks.Insider do
  @shortdoc "Runs bounded Insider diagnostics"
  @moduledoc """
  Runs bounded Insider diagnostics and emits machine-readable JSON.

      mix insider capabilities
      mix insider inspect --name Elixir.MyApp.Supervisor

  The task starts the current Mix project before resolving registered names, so
  it observes the application in the same BEAM. Textual PID targeting is not
  accepted because a PID copied from another BEAM can alias an unrelated local
  process.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(arguments) do
    {output, status} = Insider.Adapter.MixTask.run(arguments, Mix.env())
    Insider.Lab.Output.write(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
