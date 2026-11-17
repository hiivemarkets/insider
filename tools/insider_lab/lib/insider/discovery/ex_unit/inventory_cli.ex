defmodule Insider.Discovery.ExUnit.InventoryCLI do
  @moduledoc false

  alias Insider.Discovery.ExUnit.Inventory

  @switches [
    root: [:string, :keep],
    path: :keep,
    max_files: [:integer, :keep],
    max_bytes: [:integer, :keep],
    max_candidates: [:integer, :keep],
    max_duration_ms: [:integer, :keep]
  ]

  # Exit 1 is left to Mix for an uncaught crash, so no inventory state uses it.
  @exit_statuses %{
    "clean" => 0,
    "candidates" => 2,
    "empty_selection" => 3,
    "unsupported_source" => 4,
    "truncated" => 5
  }

  @spec run([String.t()]) :: {binary(), non_neg_integer()}
  def run(arguments) when is_list(arguments) do
    case OptionParser.parse(arguments, strict: @switches) do
      {options, [], []} ->
        if repeated_scalar_option?(options),
          do: invalid_input("invalid_arguments"),
          else: scan(options)

      _other ->
        invalid_input("invalid_arguments")
    end
  rescue
    _error -> failure("inventory_failed")
  end

  defp repeated_scalar_option?(options) do
    Enum.any?([:root, :max_files, :max_bytes, :max_candidates, :max_duration_ms], fn key ->
      length(Keyword.get_values(options, key)) > 1
    end)
  end

  defp scan(options) do
    root = Keyword.get(options, :root, File.cwd!())

    inventory_options =
      []
      |> put_option(:paths, path_option(options))
      |> put_option(:max_files, Keyword.get(options, :max_files))
      |> put_option(:max_total_bytes, Keyword.get(options, :max_bytes))
      |> put_option(:max_candidates, Keyword.get(options, :max_candidates))
      |> put_option(:max_duration_ms, Keyword.get(options, :max_duration_ms))

    case Inventory.scan(root, inventory_options) do
      {:ok, inventory} -> encode(inventory, Map.fetch!(@exit_statuses, inventory["status"]))
      {:error, :invalid_options} -> invalid_input("invalid_options")
      {:error, reason} -> failure(Atom.to_string(reason))
    end
  end

  defp path_option(options) do
    case Keyword.get_values(options, :path) do
      [] -> nil
      paths -> paths
    end
  end

  defp put_option(options, _key, nil), do: options
  defp put_option(options, key, value), do: Keyword.put(options, key, value)

  defp invalid_input(reason),
    do: error(%{"status" => "invalid_input", "reason" => reason}, 64)

  # A scan that could not finish is the `infrastructure_failure` completeness
  # state; invalid input never started one, so it carries no completeness.
  defp failure(reason) do
    error(
      %{"status" => "failed", "completeness" => "infrastructure_failure", "reason" => reason},
      70
    )
  end

  defp error(fields, exit_status),
    do:
      encode(
        Map.put(fields, "schema", "insider.exunit-candidate-inventory-error/v1"),
        exit_status
      )

  defp encode(value, status), do: {Jason.encode!(value) <> "\n", status}
end
