defmodule Insider.Lab.PublicDocumentationTest do
  use ExUnit.Case, async: true

  # `mix docs` in this project is a maintainer step that CI does not run. This
  # keeps the one failure it reports that a unit test can observe: a
  # `@moduledoc false` module leaking into the documented Lab API through a
  # public type or spec, which ex_doc renders as a dead reference.
  test "documented Lab modules reference only documented modules in public signatures" do
    {:ok, modules} = :application.get_key(:insider_lab, :modules)
    product_modules = Enum.filter(modules, &compiled_from_lib?/1)
    documented = Enum.filter(product_modules, &documented?/1)

    leaks =
      for module <- documented,
          referenced <- referenced_modules(module),
          referenced in product_modules,
          not documented?(referenced),
          uniq: true,
          do: {module, referenced}

    assert leaks == []
  end

  defp compiled_from_lib?(module) do
    source = module.module_info(:compile)[:source] |> List.to_string()
    String.starts_with?(source, Path.expand("../lib", __DIR__) <> "/")
  end

  defp documented?(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _language, _format, :hidden, _meta, _docs} -> false
      {:docs_v1, _anno, _language, _format, _doc, _meta, _docs} -> true
      {:error, _reason} -> false
    end
  end

  defp referenced_modules(module) do
    hidden_functions = hidden_functions(module)
    exported = module.__info__(:functions)

    specs =
      case Code.Typespec.fetch_specs(module) do
        {:ok, specs} ->
          for {signature, asts} <- specs,
              signature in exported,
              signature not in hidden_functions,
              do: asts

        :error ->
          []
      end

    callbacks =
      case Code.Typespec.fetch_callbacks(module) do
        {:ok, callbacks} -> for {_signature, asts} <- callbacks, do: asts
        :error -> []
      end

    types =
      case Code.Typespec.fetch_types(module) do
        {:ok, types} -> for {:type, {_name, ast, args}} <- types, do: [ast | args]
        :error -> []
      end

    [specs, callbacks, types] |> remote_modules() |> Enum.uniq()
  end

  defp hidden_functions(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _language, _format, _doc, _meta, docs} ->
        for {{:function, name, arity}, _anno, _signature, :hidden, _meta} <- docs,
            do: {name, arity}

      {:error, _reason} ->
        []
    end
  end

  defp remote_modules({:remote_type, _anno, [{:atom, _, module}, {:atom, _, _name}, args]}),
    do: [module | remote_modules(args)]

  defp remote_modules(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> remote_modules()

  defp remote_modules(list) when is_list(list), do: Enum.flat_map(list, &remote_modules/1)
  defp remote_modules(_leaf), do: []
end
