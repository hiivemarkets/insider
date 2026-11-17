defmodule InsiderLab.OtelGlobalStateOracleArtifact do
  @moduledoc false

  @context_variable "INSIDER_ORACLE_CONTEXT"
  @maximum_context_bytes 1_024
  @maximum_value_bytes 1_048_576
  @prefix "INSIDER_OTEL_GLOBAL_STATE_ORACLE="
  @schema "insider.otel-global-state-oracle/v1"
  @api_application :opentelemetry_api
  @sdk_application :opentelemetry
  # Every process-global the installed `opentelemetry_api` exposes a reader for,
  # paired with that exported zero-arity accessor on `:opentelemetry`. The API
  # has no tracer-provider accessor: the global provider is observable only
  # through its default tracer. `set_text_map_propagator/1` writes the injector
  # and the extractor together, and the API exposes no combined reader.
  @globals [
    {"default_tracer", :get_tracer},
    {"text_map_injector", :get_text_map_injector},
    {"text_map_extractor", :get_text_map_extractor}
  ]

  def install do
    case bounded_context() do
      {:ok, context} -> install(context)
      {:error, reason} -> emit(operational_failure(reason, nil))
    end
  end

  defp install(context) do
    if application_loaded?(@api_application),
      do: install_after_suite(context),
      else: emit(operational_failure("opentelemetry_api_not_loaded", context))
  end

  @doc false
  def validate_context_input(encoded) when is_binary(encoded) do
    if byte_size(encoded) in 1..@maximum_context_bytes and String.valid?(encoded) and
         String.printable?(encoded) and
         not Enum.any?(String.to_charlist(encoded), &(&1 < 0x20 or &1 == 0x7F)) do
      {:ok, encoded}
    else
      {:error, "invalid_context"}
    end
  end

  def validate_context_input(_encoded), do: {:error, "invalid_context"}

  defp bounded_context do
    case System.fetch_env(@context_variable) do
      {:ok, encoded} -> validate_context_input(encoded)
      :error -> {:ok, nil}
    end
  end

  defp application_loaded?(application),
    do: Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == application))

  defp application_started?(application),
    do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == application))

  defp install_after_suite(context) do
    salt = :crypto.strong_rand_bytes(32)
    initial = capture(salt)

    ExUnit.after_suite(fn _result ->
      final = capture(salt)
      emit(comparison(initial, final, context))
    end)
  end

  defp capture(salt) do
    %{
      globals: Enum.map(@globals, fn {_name, accessor} -> capture_global(accessor, salt) end),
      sdk_loaded: application_loaded?(@sdk_application),
      sdk_started: application_started?(@sdk_application)
    }
  end

  defp capture_global(accessor, salt) do
    value = apply(:opentelemetry, accessor, [])

    if :erlang.external_size(value) <= @maximum_value_bytes do
      digest =
        :crypto.mac(:hmac, :sha256, salt, :erlang.term_to_binary(value, [:deterministic]))
        |> Base.encode16(case: :lower)

      %{fingerprint: "hmac-sha256:" <> digest, comparable: true, observed: true}
    else
      %{fingerprint: nil, comparable: false, observed: true}
    end
  rescue
    _error -> unobserved()
  catch
    _kind, _reason -> unobserved()
  end

  defp unobserved, do: %{fingerprint: nil, comparable: false, observed: false}

  defp comparison(initial, final, context) do
    comparisons = Enum.zip_with(initial.globals, final.globals, &unchanged/2)

    targets =
      Enum.zip_with([@globals, initial.globals, final.globals], fn [{name, _accessor}, i, f] ->
        Map.put(target_fields(i, f), "global", name)
      end)

    unchanged = aggregate_unchanged(comparisons)

    base(context)
    |> Map.merge(%{
      "status" => status(unchanged),
      "unchanged" => nullable(unchanged),
      "targets" => targets,
      "initial_sdk_loaded" => initial.sdk_loaded,
      "initial_sdk_started" => initial.sdk_started,
      "final_sdk_loaded" => final.sdk_loaded,
      "final_sdk_started" => final.sdk_started
    })
  end

  defp target_fields(initial, final) do
    unchanged = unchanged(initial, final)

    %{
      "status" => status(unchanged),
      "initial_observed" => initial.observed,
      "final_observed" => final.observed,
      "initial_fingerprint" => nullable(initial.fingerprint),
      "final_fingerprint" => nullable(final.fingerprint),
      "unchanged" => nullable(unchanged)
    }
  end

  defp unchanged(initial, final) do
    if initial.comparable and final.comparable,
      do: initial.fingerprint == final.fingerprint,
      else: nil
  end

  defp aggregate_unchanged(values) do
    cond do
      Enum.any?(values, &(&1 == false)) -> false
      Enum.any?(values, &is_nil/1) -> nil
      true -> true
    end
  end

  defp status(true), do: "unchanged"
  defp status(false), do: "changed"
  defp status(nil), do: "inconclusive"

  defp nullable(nil), do: :null
  defp nullable(value), do: value

  defp operational_failure(reason, context),
    do:
      base(context)
      |> Map.merge(%{"status" => "operational_failure", "reason" => reason})

  defp base(context),
    do: %{
      "schema" => @schema,
      "api_application" => Atom.to_string(@api_application),
      "sdk_application" => Atom.to_string(@sdk_application),
      "context" => nullable(context),
      "limitations" => limitations(),
      "value_byte_limit" => @maximum_value_bytes,
      "context_byte_limit" => @maximum_context_bytes
    }

  defp limitations,
    do: [
      "caller_must_bind_test_and_revision",
      "context_is_caller_supplied_and_unverified",
      "fingerprints_comparable_within_run_only",
      "global_state_change_does_not_establish_causality",
      "only_default_tracer_and_text_map_propagator_are_observed"
    ]

  defp emit(report), do: IO.puts([@prefix, :json.encode(report)])
end

InsiderLab.OtelGlobalStateOracleArtifact.install()
