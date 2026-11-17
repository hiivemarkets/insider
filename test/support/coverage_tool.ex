# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec
# Adapted from Mix.Tasks.Test.Coverage; modified for bounded HTML reporting.

defmodule Insider.TestSupport.CoverageTool do
  @moduledoc false

  @compile {:no_warn_undefined,
            [
              {:cover, :analyse, 2},
              {:cover, :analyse_to_file, 3},
              {:cover, :modules, 0}
            ]}

  @default_threshold 90
  @internal_export "insider-reporting"

  @doc false
  def start(compile_path, options) do
    if options[:export] do
      Mix.Tasks.Test.Coverage.start(compile_path, options)
    else
      # Reuse Elixir's version-matched cover setup, but replace its unbounded
      # asynchronous HTML fan-out with the bounded reporter below.
      _unused_callback =
        Mix.Tasks.Test.Coverage.start(
          compile_path,
          Keyword.put(options, :export, @internal_export)
        )

      fn -> generate_results(options) end
    end
  end

  @doc false
  def generate_results(options) do
    {:result, covered_lines, _failed} = :cover.analyse(:coverage, :line)
    ignored = options[:ignore_modules] || []
    modules = Enum.reject(:cover.modules(), &ignored?(&1, ignored))

    if summary_options = Keyword.get(options, :summary, true) do
      print_summary(covered_lines, modules, summary_options)
    end

    write_html(modules, Keyword.get(options, :output, "cover"), &:cover.analyse_to_file/3)
  end

  @doc false
  def write_html(modules, output, analyzer) when is_function(analyzer, 3) do
    File.mkdir_p!(output)

    Enum.each(modules, fn module ->
      path = ~c"#{output}/#{module}.html"

      case analyzer.(module, path, [:html]) do
        {:ok, _path} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed to generate coverage for #{inspect(module)}: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("Generated HTML coverage results in #{inspect(output)} directory")
  end

  @doc false
  def summarize(results, modules) do
    module_set = MapSet.new(modules)
    table = :ets.new(__MODULE__, [:set, :private])

    try do
      for {{module, line}, coverage} <- results, module in module_set, line != 0 do
        case coverage do
          {1, 0} -> :ets.insert(table, {{module, line}, true})
          {0, 1} -> :ets.insert_new(table, {{module, line}, false})
        end
      end

      per_module = for module <- modules, do: {percentage(table, module), module}
      {per_module, percentage(table, :_)}
    after
      :ets.delete(table)
    end
  end

  @doc false
  def summary_name_width([]), do: 10

  def summary_name_width(rows),
    do: rows |> Enum.map(&String.length(elem(&1, 1))) |> Enum.max() |> max(10)

  defp ignored?(module, ignores),
    do: Enum.any?(ignores, &ignored_by?(module, &1))

  defp ignored_by?(module, %Regex{} = pattern),
    do: Regex.match?(pattern, inspect(module))

  defp ignored_by?(module, ignored), do: module == ignored

  defp percentage(table, module) do
    covered = :ets.select_count(table, [{{{module, :_}, true}, [], [true]}])
    uncovered = :ets.select_count(table, [{{{module, :_}, false}, [], [true]}])

    if covered + uncovered == 0,
      do: 100.0,
      else: covered / (covered + uncovered) * 100
  end

  @doc false
  def print_summary(results, modules, options) do
    {module_results, total} = summarize(results, modules)
    threshold = threshold(options)

    rows = Enum.map(module_results, fn {coverage, module} -> {coverage, inspect(module)} end)
    name_width = summary_name_width(rows)
    separator = String.duplicate("-", name_width)

    Mix.shell().info("| Percentage | #{String.pad_trailing("Module", name_width)} |")
    Mix.shell().info("|------------|-#{separator}-|")
    rows |> Enum.sort() |> Enum.each(&display(&1, threshold, name_width))
    Mix.shell().info("|------------|-#{separator}-|")
    display({total, "Total"}, threshold, name_width)
    Mix.shell().info("")

    if total < threshold do
      Mix.shell().info("Coverage test failed, threshold not met:\n")
      Mix.shell().info("    Coverage:  #{format_number(total, 6)}%")
      Mix.shell().info("    Threshold: #{format_number(threshold, 6)}%\n")
      System.at_exit(fn _ -> exit({:shutdown, 3}) end)
    end
  end

  defp display({coverage, name}, threshold, width) do
    color = if coverage >= threshold, do: :green, else: :red

    Mix.shell().info([
      "| ",
      color,
      format_number(coverage, 9),
      "%",
      :reset,
      " | ",
      String.pad_trailing(name, width),
      " |"
    ])
  end

  defp threshold(true), do: @default_threshold
  defp threshold(options), do: Keyword.get(options, :threshold, @default_threshold)

  defp format_number(number, width) when is_integer(number),
    do: format_number(number / 1, width)

  defp format_number(number, width), do: :io_lib.format("~#{width}.2f", [number])
end
