defmodule Insider.Scenario do
  @moduledoc """
  A bounded, portable sequence of declared semantic contract operations.

  Scenario documents contain data, never callbacks, module names, commands, or
  ambient authority. A live contract must be resolved from an explicit module
  allowlist before execution.
  """

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue

  @schema "insider.scenario/v1"
  @wire_keys [
    "contract",
    "expected_incident_fingerprints",
    "id",
    "integrity",
    "limits",
    "reset",
    "schema",
    "seed",
    "steps"
  ]
  @option_keys [:seed, :reset, :steps, :expected_incident_fingerprints, :limits]
  @maximum_bytes 65_536
  @maximum_steps 64
  @maximum_expected_incidents 16
  @maximum_attempts 100
  @maximum_interval_ms 1_000
  @maximum_duration_ms 600_000
  @maximum_cleanup_ms 5_000
  @default_limits %{"cleanup_timeout_ms" => 500, "max_duration_ms" => 5_000}

  @enforce_keys [
    :schema,
    :id,
    :contract,
    :seed,
    :reset,
    :steps,
    :expected_incident_fingerprints,
    :limits,
    :integrity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(contract_description, options) when is_list(options) do
    with :ok <- exact_options(options),
         {:ok, contract} <- contract_reference(contract_description),
         seed <- Keyword.get(options, :seed),
         reset <- Keyword.get(options, :reset),
         steps <- Keyword.get(options, :steps, []),
         expected <- Keyword.get(options, :expected_incident_fingerprints, []),
         limits <- Keyword.get(options, :limits, @default_limits),
         true <- valid_seed?(seed),
         true <- valid_reset?(reset),
         true <- valid_steps?(steps),
         true <- valid_expected?(expected),
         true <- valid_limits?(limits),
         true <- recipe_matches_contract?(contract_description, reset, steps) do
      content = %{
        "contract" => contract,
        "expected_incident_fingerprints" => expected,
        "limits" => limits,
        "reset" => reset,
        "schema" => @schema,
        "seed" => seed,
        "steps" => steps
      }

      digest = digest(content)

      %__MODULE__{
        schema: @schema,
        id: "sha256:" <> digest,
        contract: contract,
        seed: seed,
        reset: reset,
        steps: steps,
        expected_incident_fingerprints: expected,
        limits: limits,
        integrity: %{"algorithm" => "sha256", "content_digest" => digest}
      }
      |> validate()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:invalid_definition)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  def new(_contract_description, _options), do: invalid(:invalid_options)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = scenario) do
    with true <- exact_struct?(scenario),
         true <- scenario.schema == @schema,
         true <- valid_contract_reference?(scenario.contract),
         true <- valid_seed?(scenario.seed),
         true <- valid_reset?(scenario.reset),
         true <- valid_steps?(scenario.steps),
         true <- valid_expected?(scenario.expected_incident_fingerprints),
         true <- valid_limits?(scenario.limits),
         true <- valid_integrity?(scenario.integrity),
         :ok <- verify_integrity(scenario),
         encoded <- Canonical.encode(to_wire_map(scenario)),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, scenario}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:invalid_scenario)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(value), do: invalid_value(value)

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    binary
    |> Jason.decode()
    |> decode_json_result(binary)
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded(:scenario_bytes)
  def decode(value), do: invalid_value(value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema, do: unsupported_schema(schema)

  def decode_map(
        %{
          "schema" => @schema,
          "id" => id,
          "contract" => contract,
          "seed" => seed,
          "reset" => reset,
          "steps" => steps,
          "expected_incident_fingerprints" => expected,
          "limits" => limits,
          "integrity" => integrity
        } = payload
      )
      when map_size(payload) == length(@wire_keys) do
    validate(%__MODULE__{
      schema: @schema,
      id: id,
      contract: contract,
      seed: seed,
      reset: reset,
      steps: steps,
      expected_incident_fingerprints: expected,
      limits: limits,
      integrity: integrity
    })
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)
  def decode_map(value) when is_map(value) and not is_struct(value), do: unsupported_schema(nil)
  def decode_map(value), do: invalid_value(value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = scenario) do
    case validate(scenario) do
      {:ok, valid} -> {:ok, Canonical.encode(to_wire_map(valid))}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def canonical_binary(value), do: invalid_value(value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = scenario) do
    %{
      "schema" => scenario.schema,
      "id" => scenario.id,
      "contract" => scenario.contract,
      "seed" => scenario.seed,
      "reset" => scenario.reset,
      "steps" => scenario.steps,
      "expected_incident_fingerprints" => scenario.expected_incident_fingerprints,
      "limits" => scenario.limits,
      "integrity" => scenario.integrity
    }
  end

  @spec descriptor(term()) :: {:ok, map()} | {:error, Error.t()}
  def descriptor(scenario) do
    with {:ok, valid} <- validate(scenario) do
      {:ok, %{"fingerprint" => valid.integrity["content_digest"], "status" => "available"}}
    end
  end

  @doc "Builds a canonical scenario from an ordered, nonempty subset of existing step IDs."
  @spec retain_steps(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def retain_steps(scenario, retained_step_ids) do
    with {:ok, valid} <- validate(scenario),
         true <- valid_retained_ids?(retained_step_ids),
         steps <- Enum.filter(valid.steps, &(&1["id"] in retained_step_ids)),
         true <- Enum.map(steps, & &1["id"]) == retained_step_ids do
      content =
        valid
        |> to_wire_map()
        |> Map.drop(["id", "integrity"])
        |> Map.put("steps", steps)

      digest = digest(content)

      validate(%{
        valid
        | id: "sha256:" <> digest,
          integrity: %{"algorithm" => "sha256", "content_digest" => digest},
          steps: steps
      })
    else
      _other -> invalid(:invalid_step_subsequence)
    end
  rescue
    _error -> invalid(:subsequence_failed)
  catch
    _kind, _reason -> invalid(:subsequence_failed)
  end

  @doc "Resolves the pinned contract from an explicit bounded module allowlist."
  @spec resolve(term(), term(), atom()) :: {:ok, module()} | {:error, Error.t()}
  def resolve(scenario, modules, environment) do
    with {:ok, valid} <- validate(scenario),
         true <- environment in [:development, :test, :ci],
         true <- ProtocolValue.bounded_list?(modules, 64) and Enum.all?(modules, &is_atom/1),
         matches <- Enum.filter(modules, &contract_match?(&1, valid.contract)),
         [module] <- matches,
         {:ok, description} <- Contract.describe(module),
         true <- recipe_matches_contract?(description, valid.reset, valid.steps),
         true <- mutations_allow_environment?(description, valid, environment) do
      {:ok, module}
    else
      _other -> contract_mismatch()
    end
  rescue
    _error -> contract_mismatch()
  catch
    _kind, _reason -> contract_mismatch()
  end

  defp exact_options(options) do
    with true <- ProtocolValue.bounded_list?(options, length(@option_keys)),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- keys -- @option_keys == [],
         true <- Enum.uniq(keys) == keys,
         true <- Enum.all?([:seed, :reset], &Keyword.has_key?(options, &1)) do
      :ok
    else
      _other -> invalid(:invalid_options)
    end
  end

  defp decode_json_result({:error, %Jason.DecodeError{}}, _binary), do: invalid(:invalid_json)

  defp decode_json_result({:ok, payload}, binary) do
    if Canonical.encode(payload) == binary,
      do: decode_map(payload),
      else: invalid(:noncanonical_encoding)
  end

  defp contract_reference(%{
         "schema" => "insider.contract/v1",
         "id" => id,
         "version" => version,
         "fingerprint" => fingerprint
       }) do
    reference = %{"id" => id, "version" => version, "fingerprint" => fingerprint}

    if valid_contract_reference?(reference),
      do: {:ok, reference},
      else: invalid(:invalid_contract)
  end

  defp contract_reference(_description), do: invalid(:invalid_contract)

  defp valid_contract_reference?(
         %{
           "id" => id,
           "version" => version,
           "fingerprint" => fingerprint
         } = reference
       ) do
    map_size(reference) == 3 and vocabulary?(id) and is_integer(version) and
      version in 1..1_000_000 and valid_prefixed_digest?(fingerprint)
  end

  defp valid_contract_reference?(_reference), do: false

  defp valid_seed?(seed),
    do: is_binary(seed) and byte_size(seed) in 1..256 and String.valid?(seed)

  defp valid_reset?(%{"name" => name, "arguments" => arguments} = reset),
    do: map_size(reset) == 2 and vocabulary?(name) and valid_arguments?(arguments)

  defp valid_reset?(_reset), do: false

  defp valid_steps?(steps) do
    Value.valid_list?(steps, @maximum_steps, @maximum_bytes) and steps != [] and
      Enum.all?(steps, &valid_step?/1) and unique_step_ids?(steps)
  end

  defp valid_retained_ids?(ids) do
    ProtocolValue.bounded_list?(ids, @maximum_steps) and ids != [] and
      Enum.all?(ids, &vocabulary?/1) and Enum.uniq(ids) == ids
  end

  defp valid_step?(
         %{
           "id" => id,
           "type" => "action",
           "name" => name,
           "arguments" => arguments
         } = step
       ),
       do:
         map_size(step) == 4 and vocabulary?(id) and vocabulary?(name) and
           valid_arguments?(arguments)

  defp valid_step?(
         %{
           "id" => id,
           "type" => "observation",
           "name" => name,
           "arguments" => arguments
         } = step
       ),
       do:
         map_size(step) == 4 and vocabulary?(id) and vocabulary?(name) and
           valid_arguments?(arguments)

  defp valid_step?(
         %{
           "id" => id,
           "type" => "wait",
           "kind" => kind,
           "name" => name,
           "arguments" => arguments,
           "expectation" => expectation,
           "max_attempts" => max_attempts,
           "interval_ms" => interval_ms
         } = step
       ) do
    map_size(step) == 8 and vocabulary?(id) and kind in ["observation", "invariant"] and
      vocabulary?(name) and valid_arguments?(arguments) and valid_expectation?(kind, expectation) and
      is_integer(max_attempts) and max_attempts in 1..@maximum_attempts and
      is_integer(interval_ms) and interval_ms in 0..@maximum_interval_ms
  end

  defp valid_step?(_step), do: false

  defp valid_expectation?(
         "observation",
         %{"operator" => "equals", "value" => value} = expectation
       ),
       do: map_size(expectation) == 2 and Value.valid?(value, 16_384)

  defp valid_expectation?("invariant", %{"operator" => "satisfied"} = expectation),
    do: map_size(expectation) == 1

  defp valid_expectation?(_kind, _expectation), do: false

  defp valid_arguments?(arguments), do: Value.valid_list?(arguments, 8, 16_384)

  defp unique_step_ids?(steps) do
    ids = Enum.map(steps, & &1["id"])
    Enum.uniq(ids) == ids
  end

  defp valid_expected?(expected) do
    Value.valid_list?(expected, @maximum_expected_incidents, 2_048) and
      Enum.all?(expected, &valid_digest?/1) and Enum.sort(expected) == expected and
      Enum.uniq(expected) == expected
  end

  defp valid_limits?(
         %{
           "max_duration_ms" => duration,
           "cleanup_timeout_ms" => cleanup
         } = limits
       ),
       do:
         map_size(limits) == 2 and is_integer(duration) and duration in 2..@maximum_duration_ms and
           is_integer(cleanup) and cleanup in 1..@maximum_cleanup_ms and cleanup < duration

  defp valid_limits?(_limits), do: false

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and valid_digest?(digest)

  defp valid_integrity?(_integrity), do: false

  defp verify_integrity(scenario) do
    content_digest = scenario.integrity["content_digest"]

    if scenario.id == "sha256:" <> content_digest and content_digest == digest(content(scenario)),
      do: :ok,
      else: integrity_failed()
  end

  defp recipe_matches_contract?(description, reset, steps) do
    declaration_matches?(description, "resets", reset["name"], reset["arguments"]) and
      Enum.all?(steps, &step_matches_contract?(description, &1))
  end

  defp step_matches_contract?(description, %{"type" => "action"} = step),
    do: declaration_matches?(description, "actions", step["name"], step["arguments"])

  defp step_matches_contract?(description, %{"type" => "observation"} = step),
    do: declaration_matches?(description, "observations", step["name"], step["arguments"])

  defp step_matches_contract?(description, %{"type" => "wait", "kind" => kind} = step),
    do: declaration_matches?(description, kind <> "s", step["name"], step["arguments"])

  defp declaration_matches?(description, group, name, arguments) do
    with declarations when is_list(declarations) <- description[group] do
      Enum.any?(declarations, fn
        %{"name" => ^name, "arity" => arity} -> arity == length(arguments)
        _declaration -> false
      end)
    else
      _other -> false
    end
  end

  defp mutations_allow_environment?(description, scenario, environment) do
    names = [scenario.reset["name"] | action_names(scenario.steps)]

    with resets when is_list(resets) <- description["resets"],
         actions when is_list(actions) <- description["actions"] do
      declarations = resets ++ actions

      Enum.all?(names, fn name ->
        Enum.any?(declarations, fn
          %{"name" => ^name, "environments" => environments} ->
            Atom.to_string(environment) in environments

          _declaration ->
            false
        end)
      end)
    else
      _other -> false
    end
  end

  defp action_names(steps) do
    for %{"type" => "action", "name" => name} <- steps, do: name
  end

  defp contract_match?(module, reference) do
    case Contract.describe(module) do
      {:ok, description} ->
        description["id"] == reference["id"] and
          description["version"] == reference["version"] and
          description["fingerprint"] == reference["fingerprint"]

      {:error, %Error{}} ->
        false
    end
  end

  defp content(scenario) do
    %{
      "contract" => scenario.contract,
      "expected_incident_fingerprints" => scenario.expected_incident_fingerprints,
      "limits" => scenario.limits,
      "reset" => scenario.reset,
      "schema" => scenario.schema,
      "seed" => scenario.seed,
      "steps" => scenario.steps
    }
  end

  defp digest(value),
    do:
      value
      |> Canonical.encode()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp exact_struct?(scenario),
    do: scenario |> Map.from_struct() |> Map.keys() |> Enum.sort() == Enum.sort(@enforce_keys)

  defp valid_prefixed_digest?("sha256:" <> digest), do: valid_digest?(digest)
  defp valid_prefixed_digest?(_value), do: false

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_digest), do: false

  defp vocabulary?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp vocabulary?(_value), do: false

  defp invalid(reason),
    do: {:error, Error.new(:invalid_scenario, "scenario is invalid", %{reason: reason})}

  defp invalid_value(value),
    do:
      {:error,
       Error.new(:invalid_scenario, "scenario value is invalid", %{
         received: Insider.Protocol.Value.summary(value)
       })}

  defp contract_mismatch,
    do:
      {:error,
       Error.new(:scenario_contract_mismatch, "scenario contract cannot be resolved safely")}

  defp integrity_failed,
    do:
      {:error,
       Error.new(:scenario_integrity_failed, "scenario content integrity verification failed")}

  defp limit_exceeded(limit),
    do:
      {:error,
       Error.new(:scenario_limit_exceeded, "scenario exceeds its static limit", %{limit: limit})}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:unsupported_scenario_schema, "scenario schema is unsupported", %{
         schema: Insider.Protocol.Value.summary(schema)
       })}
end
