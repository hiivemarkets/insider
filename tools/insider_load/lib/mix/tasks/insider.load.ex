defmodule Mix.Tasks.Insider.Load do
  @moduledoc "Produces bounded paired synthetic load evidence."

  use Mix.Task

  alias Insider.LoadHarness.Runner

  @shortdoc "Runs the bounded Insider load evidence harness"

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("app.start")

    case OptionParser.parse(arguments, strict: [profile: :string, output: :string]) do
      {[profile: profile, output: output], [], []} -> run_harness(profile, output)
      _other -> Mix.raise("usage: mix insider.load --profile PATH --output NEW_DIRECTORY")
    end
  end

  defp run_harness(profile, output) do
    case Runner.run(profile, output) do
      {:ok, result} ->
        summary = %{
          "artifact_directory" => result.output,
          "report_id" => result.report.id,
          "outcome" => result.report.outcome,
          "production_capacity" => result.report.production_capacity,
          "budget_evaluation" => result.report.budget_evaluation
        }

        Mix.shell().info(Jason.encode!(summary))

        if result.report.outcome == "passed" do
          :ok
        else
          Mix.raise("synthetic evidence gates failed; inspect the emitted report")
        end

      {:error, reason} ->
        Mix.raise("synthetic evidence harness failed: #{inspect(reason)}")
    end
  end
end
