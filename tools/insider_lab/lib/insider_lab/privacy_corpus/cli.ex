defmodule Insider.Lab.PrivacyCorpus.CLI do
  @moduledoc false

  alias Insider.Lab.PrivacyCorpus

  @switches [corpus: [:string, :keep], environment: [:string, :keep]]
  @environments %{"production" => :production, "staging" => :staging}
  @max_corpus_bytes 16_777_216
  @applications [:insider, :insider_lab]
  @error_schema "insider.privacy-corpus-error/v1"

  @spec run([String.t()]) :: {binary(), non_neg_integer()}
  def run(arguments) when is_list(arguments) do
    with {options, [], []} <- OptionParser.parse(arguments, strict: @switches),
         [path] <- Keyword.get_values(options, :corpus),
         [environment] <- Keyword.get_values(options, :environment),
         {:ok, environment} <- Map.fetch(@environments, environment) do
      evaluate(path, environment)
    else
      _failure -> error("invalid_input", "invalid_arguments", 64)
    end
  rescue
    _error -> error("failed", "privacy_corpus_failed", 70)
  end

  defp evaluate(path, environment) do
    with {:ok, contents} <- read_bounded(path),
         {:ok, corpus} <- decode(contents) do
      ensure_insider_modules_loaded()

      case PrivacyCorpus.run(corpus, environment: environment) do
        {:ok, %{"status" => "no_canary_hits"} = report} -> encode(report, 0)
        {:ok, report} -> encode(report, 2)
        {:error, {reason, index}} -> error("invalid_input", Atom.to_string(reason), 64, index)
        {:error, :privacy_corpus_failed} -> error("failed", "privacy_corpus_failed", 70)
        {:error, reason} -> error("invalid_input", Atom.to_string(reason), 64)
      end
    else
      {:error, reason} -> error("invalid_input", reason, 64)
    end
  end

  defp read_bounded(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_corpus_bytes,
         {:ok, contents} <- File.read(path) do
      {:ok, contents}
    else
      false -> {:error, "corpus_too_large"}
      _failure -> {:error, "corpus_unreadable"}
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, corpus} when is_map(corpus) -> {:ok, corpus}
      _failure -> {:error, "invalid_json"}
    end
  end

  # Policy names resolve only to existing atoms. Loading Insider's own modules
  # first makes the resolvable set deterministic instead of depending on which
  # modules an earlier task happened to touch. No atom is created here.
  defp ensure_insider_modules_loaded do
    Enum.each(@applications, fn application ->
      _loaded = Application.load(application)

      application
      |> Application.spec(:modules)
      |> List.wrap()
      |> Enum.each(&Code.ensure_loaded/1)
    end)
  end

  defp error(status, reason, exit_status, index \\ nil) do
    %{"schema" => @error_schema, "status" => status, "reason" => reason}
    |> put_index(index)
    |> encode(exit_status)
  end

  defp put_index(error, nil), do: error
  defp put_index(error, index), do: Map.put(error, "index", index)

  defp encode(value, status), do: {Jason.encode!(value) <> "\n", status}
end
