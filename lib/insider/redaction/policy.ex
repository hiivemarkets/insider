defmodule Insider.Redaction.Policy do
  @moduledoc "A bounded, callback-free redaction policy selected by trusted runtime code."

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error

  @sensitivities [:public, :internal, :confidential, :secret]
  @actions [:mask, :drop]
  @option_keys [
    :id,
    :maximum_sensitivity,
    :rules,
    :max_nodes,
    :max_width,
    :max_input_bytes,
    :max_output_bytes,
    :max_manifest_records,
    :max_duration_ms
  ]
  @rule_keys [:id, :path, :sensitivity, :action]

  @enforce_keys [
    :id,
    :fingerprint,
    :maximum_sensitivity,
    :rules,
    :max_nodes,
    :max_width,
    :max_input_bytes,
    :max_output_bytes,
    :max_manifest_records,
    :max_duration_ms
  ]
  defstruct @enforce_keys

  @type segment :: String.t() | non_neg_integer() | :each
  @type rule :: %{
          id: String.t(),
          path: [segment()],
          sensitivity: atom(),
          action: atom()
        }
  @type t :: %__MODULE__{
          id: String.t(),
          fingerprint: String.t(),
          maximum_sensitivity: atom(),
          rules: %{tuple() => rule()},
          max_nodes: pos_integer(),
          max_width: pos_integer(),
          max_input_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          max_manifest_records: pos_integer(),
          max_duration_ms: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with :ok <- valid_options(options),
         {:ok, rules} <- rules(Keyword.fetch!(options, :rules)),
         policy <- build(options, rules) do
      {:ok, %{policy | fingerprint: fingerprint(policy)}}
    else
      {:error, %Error{} = error} -> {:error, error}
      :error -> invalid_policy()
    end
  rescue
    _error -> invalid_policy()
  catch
    _kind, _reason -> invalid_policy()
  end

  def new(_options), do: invalid_policy()

  defp valid_options(options) do
    if proper_bounded_list?(options, length(@option_keys)) and Keyword.keyword?(options) do
      keys = Keyword.keys(options)

      if keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @option_keys)) and
           Enum.all?([:id, :rules], &Keyword.has_key?(options, &1)) and
           bounded_id?(Keyword.get(options, :id), 48) and
           Keyword.get(options, :maximum_sensitivity, :internal) in @sensitivities and
           bounded_integer?(Keyword.get(options, :max_nodes, 1_024), 1, 16_384) and
           bounded_integer?(Keyword.get(options, :max_width, 128), 1, 128) and
           bounded_integer?(Keyword.get(options, :max_input_bytes, 65_536), 64, 1_048_576) and
           bounded_integer?(Keyword.get(options, :max_output_bytes, 16_384), 64, 1_048_576) and
           bounded_integer?(Keyword.get(options, :max_manifest_records, 64), 1, 64) and
           bounded_integer?(Keyword.get(options, :max_duration_ms, 100), 1, 10_000) do
        :ok
      else
        :error
      end
    else
      :error
    end
  end

  defp rules(rules) when is_list(rules) do
    if proper_bounded_list?(rules, 64) do
      Enum.reduce_while(rules, {:ok, %{}}, fn rule, {:ok, compiled} ->
        with {:ok, normalized} <- rule(rule),
             false <- Map.has_key?(compiled, List.to_tuple(normalized.path)) do
          {:cont, {:ok, Map.put(compiled, List.to_tuple(normalized.path), normalized)}}
        else
          _error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, compiled} -> {:ok, compiled}
        :error -> invalid_policy()
      end
    else
      invalid_policy()
    end
  end

  defp rules(_rules), do: invalid_policy()

  defp rule(rule) when is_list(rule) do
    if proper_bounded_list?(rule, length(@rule_keys)) and Keyword.keyword?(rule) do
      keys = Keyword.keys(rule)
      path = Keyword.get(rule, :path)

      if keys == Enum.uniq(keys) and Enum.sort(keys) == Enum.sort(@rule_keys) and
           bounded_id?(Keyword.get(rule, :id), 64) and valid_path?(path) and
           Keyword.get(rule, :sensitivity) in @sensitivities and
           Keyword.get(rule, :action) in @actions do
        {:ok,
         %{
           id: :binary.copy(Keyword.fetch!(rule, :id)),
           path: Enum.map(path, &copy_segment/1),
           sensitivity: Keyword.fetch!(rule, :sensitivity),
           action: Keyword.fetch!(rule, :action)
         }}
      else
        :error
      end
    else
      :error
    end
  end

  defp rule(_rule), do: :error

  defp valid_path?(path) do
    proper_bounded_list?(path, 8) and
      Enum.all?(path, fn
        segment when is_binary(segment) -> bounded_id?(segment, 120)
        segment when is_integer(segment) -> segment in 0..127
        :each -> true
        _segment -> false
      end) and wildcard_is_final?(path)
  end

  defp wildcard_is_final?(path) do
    case Enum.find_index(path, &(&1 == :each)) do
      nil -> true
      index -> index == length(path) - 1
    end
  end

  defp copy_segment(segment) when is_binary(segment), do: :binary.copy(segment)
  defp copy_segment(segment), do: segment

  defp build(options, rules) do
    %__MODULE__{
      id: :binary.copy(Keyword.fetch!(options, :id)),
      fingerprint: "pending",
      maximum_sensitivity: Keyword.get(options, :maximum_sensitivity, :internal),
      rules: rules,
      max_nodes: Keyword.get(options, :max_nodes, 1_024),
      max_width: Keyword.get(options, :max_width, 128),
      max_input_bytes: Keyword.get(options, :max_input_bytes, 65_536),
      max_output_bytes: Keyword.get(options, :max_output_bytes, 16_384),
      max_manifest_records: Keyword.get(options, :max_manifest_records, 64),
      max_duration_ms: Keyword.get(options, :max_duration_ms, 100)
    }
  end

  defp fingerprint(policy) do
    rules =
      policy.rules
      |> Map.values()
      |> Enum.map(fn rule ->
        %{
          "action" => Atom.to_string(rule.action),
          "id" => rule.id,
          "path" => Enum.map(rule.path, &wire_segment/1),
          "sensitivity" => Atom.to_string(rule.sensitivity)
        }
      end)
      |> Enum.sort_by(&Canonical.encode/1)

    %{
      "id" => policy.id,
      "maximum_sensitivity" => Atom.to_string(policy.maximum_sensitivity),
      "rules" => rules,
      "limits" => %{
        "max_nodes" => policy.max_nodes,
        "max_width" => policy.max_width,
        "max_input_bytes" => policy.max_input_bytes,
        "max_output_bytes" => policy.max_output_bytes,
        "max_manifest_records" => policy.max_manifest_records,
        "max_duration_ms" => policy.max_duration_ms
      }
    }
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec wire_segment(segment()) :: String.t()
  def wire_segment(:each), do: "each:*"
  def wire_segment(segment) when is_integer(segment), do: "index:" <> Integer.to_string(segment)
  def wire_segment(segment), do: "key:" <> segment

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = policy) do
    exact_shape?(policy) and bounded_id?(policy.id, 48) and valid_digest?(policy.fingerprint) and
      policy.maximum_sensitivity in @sensitivities and
      bounded_integer?(policy.max_nodes, 1, 16_384) and
      bounded_integer?(policy.max_width, 1, 128) and
      bounded_integer?(policy.max_input_bytes, 64, 1_048_576) and
      bounded_integer?(policy.max_output_bytes, 64, 1_048_576) and
      bounded_integer?(policy.max_manifest_records, 1, 64) and
      bounded_integer?(policy.max_duration_ms, 1, 10_000) and valid_compiled_rules?(policy.rules) and
      policy.fingerprint == fingerprint(policy)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_policy), do: false

  defp exact_shape?(policy) do
    expected = struct(__MODULE__)

    map_size(policy) == map_size(expected) and
      Enum.sort(Map.keys(policy)) == Enum.sort(Map.keys(expected))
  end

  defp valid_compiled_rules?(rules) when is_map(rules) and map_size(rules) <= 64 do
    Enum.all?(rules, fn
      {path_tuple, %{id: id, path: path, sensitivity: sensitivity, action: action} = rule}
      when map_size(rule) == 4 ->
        is_tuple(path_tuple) and path_tuple == List.to_tuple(path) and bounded_id?(id, 64) and
          valid_path?(path) and sensitivity in @sensitivities and action in @actions

      _entry ->
        false
    end)
  end

  defp valid_compiled_rules?(_rules), do: false

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower))

  defp valid_digest?(_value), do: false

  defp proper_bounded_list?(value, maximum), do: proper_bounded_list?(value, maximum, 0)
  defp proper_bounded_list?([], _maximum, _count), do: true
  defp proper_bounded_list?(_value, maximum, count) when count >= maximum, do: false

  defp proper_bounded_list?([_head | tail], maximum, count),
    do: proper_bounded_list?(tail, maximum, count + 1)

  defp proper_bounded_list?(_value, _maximum, _count), do: false

  defp bounded_id?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value in minimum..maximum

  defp invalid_policy do
    {:error,
     Error.new(:redaction_failed, "redaction policy is invalid", %{reason: "invalid_policy"})}
  end
end
