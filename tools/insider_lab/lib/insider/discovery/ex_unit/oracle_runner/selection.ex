defmodule Insider.Discovery.ExUnit.OracleRunner.Selection do
  @moduledoc false

  # The selected test command forwarded after `--`, checked without touching
  # the filesystem, so the CLI and the v1 decoder apply the same rule. The CLI
  # additionally requires each selected path to exist under the root.
  #
  # Forwarded `mix test` options are an allowlist. Options that can write
  # outside `_build` (`--cover` writes `cover/`), change which files Mix loads,
  # or change the exit contract (`--warnings-as-errors`) are refused.

  @switches [
    seed: :integer,
    max_cases: :integer,
    max_failures: :integer,
    timeout: :integer,
    trace: :boolean,
    only: :keep,
    include: :keep,
    exclude: :keep
  ]
  @maximum_selectors 16
  @maximum_path_bytes 4_095
  @maximum_tag_bytes 255

  @spec parse(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse(arguments) when is_list(arguments) do
    with true <- Enum.all?(arguments, &is_binary/1) || {:error, "invalid_test_selection"},
         {options, selectors, []} <- OptionParser.parse(arguments, strict: @switches) do
      if "--" not in arguments and length(selectors) in 1..@maximum_selectors and
           Enum.all?(selectors, &selector?/1) and Enum.all?(options, &option?/1),
         do: {:ok, Enum.map(selectors, &path/1)},
         else: {:error, "invalid_test_selection"}
    else
      {:error, reason} -> {:error, reason}
      _unsupported -> {:error, "unsupported_test_argument"}
    end
  end

  def parse(_arguments), do: {:error, "invalid_test_selection"}

  defp path(selector), do: Regex.replace(~r/(?::\d+)+\z/, selector, "")

  defp selector?(selector) do
    path = path(selector)
    segments = Path.split(path)

    text?(selector, @maximum_path_bytes) and path != "" and Path.type(path) == :relative and
      not String.starts_with?(path, "-") and "." not in segments and ".." not in segments
  end

  defp option?({key, value}) when key in [:only, :include, :exclude],
    do: text?(value, @maximum_tag_bytes)

  defp option?({:seed, value}), do: value >= 0
  defp option?({:trace, value}), do: is_boolean(value)
  defp option?({_key, value}), do: value >= 1

  defp text?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      not Enum.any?(:binary.bin_to_list(value), &(&1 < 0x20 or &1 == 0x7F))
  end
end
