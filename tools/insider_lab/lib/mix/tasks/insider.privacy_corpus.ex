defmodule Mix.Tasks.Insider.PrivacyCorpus do
  @shortdoc "Projects a synthetic privacy corpus through the ingress allowlists"
  @moduledoc """
  Runs a caller-supplied synthetic privacy corpus through the exact Logger and
  Telemetry ingress code paths and prints an `insider.privacy-corpus-report/v1`
  JSON document that names retained fields without their values.

      mix insider.privacy_corpus --corpus priv/privacy_corpus/example.json --environment production
      mix insider.privacy_corpus --corpus /path/to/corpus.json --environment staging

  Exit status is `0` when no declared canary token appears in projected output,
  `2` when at least one does, `64` for invalid arguments or an invalid corpus,
  and `70` when the run cannot be completed. The corpus content and the review
  of every retained field remain human work; a clean exit is not an approval.
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    {output, status} = Insider.Lab.PrivacyCorpus.CLI.run(arguments)
    Insider.Lab.Output.write(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
