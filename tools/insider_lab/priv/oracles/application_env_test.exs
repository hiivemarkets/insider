defmodule InsiderLab.ApplicationEnvOracleArtifact do
  @moduledoc false

  @application_variable "INSIDER_ORACLE_APPLICATION"
  @key_variable "INSIDER_ORACLE_KEY"
  @keys_variable "INSIDER_ORACLE_KEYS"
  @context_variable "INSIDER_ORACLE_CONTEXT"
  @maximum_name_bytes 255
  @maximum_keys 16
  @maximum_keys_bytes @maximum_keys * @maximum_name_bytes + (@maximum_keys - 1)
  @maximum_context_bytes 1_024
  @maximum_value_bytes 1_048_576
  @prefix "INSIDER_APPLICATION_ENV_ORACLE="
  @schema "insider.application-env-oracle/v1"

  def install do
    case bounded_context() do
      {:ok, context} -> install(context)
      {:error, reason} -> emit(operational_failure(reason, nil))
    end
  end

  defp install(context) do
    with {:ok, application_name} <- bounded_name(@application_variable),
         {:ok, selection} <- key_selection(),
         {:ok, application} <- loaded_application(application_name) do
      install_after_suite(application, application_name, selection, context)
    else
      {:error, reason} -> emit(operational_failure(reason, context))
    end
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

  @doc false
  def validate_keys_input(encoded)
      when is_binary(encoded) and byte_size(encoded) in 1..@maximum_keys_bytes do
    segments = String.split(encoded, ",", trim: false)

    with true <- length(segments) <= @maximum_keys || {:error, "too_many_keys"},
         {:ok, names} <- bounded_names(segments),
         true <- Enum.uniq(names) == names || {:error, "duplicate_key"} do
      {:ok, names}
    end
  end

  def validate_keys_input(_encoded), do: {:error, "invalid_target_name"}

  defp bounded_context do
    case System.fetch_env(@context_variable) do
      {:ok, encoded} -> validate_context_input(encoded)
      :error -> {:ok, nil}
    end
  end

  defp key_selection do
    case {System.fetch_env(@key_variable), System.fetch_env(@keys_variable)} do
      {{:ok, key}, :error} -> single_key(key)
      {:error, {:ok, keys}} -> multiple_keys(keys)
      {{:ok, _key}, {:ok, _keys}} -> {:error, "conflicting_key_selectors"}
      {:error, :error} -> {:error, "missing_key_selector"}
    end
  end

  defp single_key(key) do
    with {:ok, name} <- bounded_name_value(key), do: {:ok, {:single, name}}
  end

  defp multiple_keys(keys) do
    with {:ok, names} <- validate_keys_input(keys), do: {:ok, {:multiple, names}}
  end

  defp bounded_name(variable) do
    case System.fetch_env(variable) do
      {:ok, value} -> bounded_name_value(value)
      :error -> {:error, "invalid_target_name"}
    end
  end

  defp bounded_name_value(value) when byte_size(value) in 1..@maximum_name_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, "invalid_target_name"}
  end

  defp bounded_name_value(_value), do: {:error, "invalid_target_name"}

  defp bounded_names(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, names} ->
      case bounded_name_value(segment) do
        {:ok, name} -> {:cont, {:ok, [name | names]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loaded_application(name) do
    case Enum.find(Application.loaded_applications(), &(Atom.to_string(elem(&1, 0)) == name)) do
      nil -> {:error, "application_not_loaded"}
      {application, _description, _version} -> {:ok, application}
    end
  end

  defp install_after_suite(application, application_name, selection, context) do
    salt = :crypto.strong_rand_bytes(32)
    key_names = key_names(selection)
    initial = capture(application, key_names, salt)

    ExUnit.after_suite(fn _result ->
      final = capture(application, key_names, salt)
      emit(comparison(application_name, selection, initial, final, context))
    end)
  end

  defp key_names({:single, key_name}), do: [key_name]
  defp key_names({:multiple, key_names}), do: key_names

  defp capture(application, key_names, salt) do
    environment = Application.get_all_env(application)
    Enum.map(key_names, &capture_key(environment, &1, salt))
  rescue
    _error -> Enum.map(key_names, fn _key_name -> unobserved() end)
  end

  defp capture_key(environment, key_name, salt) do
    case Enum.find(environment, fn {key, _value} -> Atom.to_string(key) == key_name end) do
      nil ->
        %{presence: "missing", fingerprint: nil, comparable: true, observed: true}

      {_key, value} ->
        if :erlang.external_size(value) <= @maximum_value_bytes do
          digest =
            :crypto.mac(:hmac, :sha256, salt, :erlang.term_to_binary(value, [:deterministic]))
            |> Base.encode16(case: :lower)

          %{
            presence: "present",
            fingerprint: "hmac-sha256:" <> digest,
            comparable: true,
            observed: true
          }
        else
          %{presence: "present", fingerprint: nil, comparable: false, observed: true}
        end
    end
  rescue
    _error -> unobserved()
  end

  defp unobserved,
    do: %{presence: "unknown", fingerprint: nil, comparable: false, observed: false}

  defp comparison(application_name, {:single, key_name}, [initial], [final], context) do
    base(application_name, context)
    |> Map.put("key", key_name)
    |> Map.merge(target_fields(initial, final))
  end

  defp comparison(application_name, {:multiple, key_names}, initials, finals, context) do
    comparisons = Enum.zip_with(initials, finals, &unchanged/2)

    targets =
      Enum.zip_with([key_names, initials, finals], fn [key_name, initial, final] ->
        Map.put(target_fields(initial, final), "key", key_name)
      end)

    unchanged = aggregate_unchanged(comparisons)

    base(application_name, context)
    |> Map.merge(%{
      "status" => status(unchanged),
      "unchanged" => nullable(unchanged),
      "targets" => targets
    })
  end

  defp target_fields(initial, final) do
    unchanged = unchanged(initial, final)

    %{
      "status" => status(unchanged),
      "initial_presence" => initial.presence,
      "final_presence" => final.presence,
      "initial_observed" => initial.observed,
      "final_observed" => final.observed,
      "initial_fingerprint" => nullable(initial.fingerprint),
      "final_fingerprint" => nullable(final.fingerprint),
      "unchanged" => nullable(unchanged)
    }
  end

  defp unchanged(initial, final) do
    cond do
      not initial.observed or not final.observed -> nil
      initial.presence != final.presence -> false
      initial.presence == "missing" -> true
      initial.comparable and final.comparable -> initial.fingerprint == final.fingerprint
      true -> nil
    end
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
      limits()
      |> Map.merge(%{
        "schema" => @schema,
        "status" => "operational_failure",
        "reason" => reason,
        "context" => nullable(context),
        "limitations" => limitations()
      })

  defp base(application_name, context),
    do:
      limits()
      |> Map.merge(%{
        "schema" => @schema,
        "application" => application_name,
        "context" => nullable(context),
        "limitations" => limitations()
      })

  defp limits,
    do: %{
      "value_byte_limit" => @maximum_value_bytes,
      "key_limit" => @maximum_keys,
      "context_byte_limit" => @maximum_context_bytes
    }

  defp limitations,
    do: [
      "caller_must_bind_test_and_revision",
      "context_is_caller_supplied_and_unverified",
      "fingerprints_comparable_within_run_only",
      "state_change_does_not_establish_causality"
    ]

  defp emit(report), do: IO.puts([@prefix, :json.encode(report)])
end

InsiderLab.ApplicationEnvOracleArtifact.install()
