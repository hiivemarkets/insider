defmodule Insider.Redaction do
  @moduledoc """
  Fail-closed sanitization of untrusted BEAM terms into bounded Event-compatible values.

  The policy must come from trusted runtime configuration. The returned outcome
  is created only after traversal, manifest construction, and output validation
  all succeed; errors never contain source values or data-derived paths.
  """

  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Protocol.Error
  alias Insider.Redaction.Outcome
  alias Insider.Redaction.Policy

  @sensitivities [:public, :internal, :confidential, :secret]
  @minimum_integer -9_223_372_036_854_775_808
  @maximum_integer 9_223_372_036_854_775_807
  @masked "[REDACTED]"

  @spec redact(term(), atom(), Policy.t()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def redact(value, sensitivity, policy), do: redact(value, sensitivity, policy, [])

  @doc """
  Redacts within an optional caller-owned absolute monotonic deadline.

  The effective deadline is the earlier of the policy duration and
  `:deadline_monotonic_us`. The option is intended for a bounded outer
  operation such as capsule assembly; it cannot extend the policy budget.
  """
  @spec redact(term(), atom(), Policy.t(), keyword()) ::
          {:ok, Outcome.t()} | {:error, Error.t()}
  def redact(value, sensitivity, %Policy{} = policy, options)
      when sensitivity in @sensitivities and is_list(options) do
    started_at = System.monotonic_time(:microsecond)

    if Policy.valid?(policy) and valid_options?(options) do
      policy_deadline = started_at + policy.max_duration_ms * 1_000

      deadline =
        min(policy_deadline, Keyword.get(options, :deadline_monotonic_us, policy_deadline))

      do_redact(value, sensitivity, policy, deadline)
    else
      failed(:invalid_policy)
    end
  end

  def redact(_value, _sensitivity, _policy, _options), do: failed(:invalid_input)

  defp valid_options?([]), do: true

  defp valid_options?(deadline_monotonic_us: deadline) do
    is_integer(deadline) and deadline >= -9_223_372_036_854_775_808 and
      deadline <= 9_223_372_036_854_775_807
  end

  defp valid_options?(_options), do: false

  defp do_redact(value, sensitivity, policy, deadline) do
    state = %{
      deadline: deadline,
      input_bytes: 0,
      manifest: %{},
      nodes: 0,
      policy: policy
    }

    with {:ok, sanitized, state} <- walk(value, [], sensitivity, nil, 0, state),
         sanitized <- if(sanitized == :drop, do: nil, else: sanitized),
         true <- Value.valid?(sanitized, policy.max_output_bytes),
         manifest <- manifest(state),
         true <- valid_manifest?(manifest, policy),
         output_bytes <- byte_size(Canonical.encode(sanitized)),
         :ok <- before_deadline(state) do
      {:ok,
       %Outcome{
         value: sanitized,
         manifest: manifest,
         policy_id: policy.id,
         policy_fingerprint: policy.fingerprint,
         consumption: %{
           nodes: state.nodes,
           input_bytes: state.input_bytes,
           output_bytes: output_bytes,
           manifest_records: length(manifest)
         }
       }}
    else
      {:error, reason} -> failed(reason)
      false -> failed(:output_limit)
    end
  rescue
    _error -> failed(:evaluation_failed)
  catch
    _kind, _reason -> failed(:evaluation_failed)
  end

  defp walk(_value, _path, _sensitivity, _rule, depth, _state) when depth > 8,
    do: {:error, :depth_limit}

  defp walk(value, path, inherited_sensitivity, inherited_rule, depth, state) do
    with {:ok, state} <- visit(state),
         {sensitivity, rule} <-
           effective_rule(path, inherited_sensitivity, inherited_rule, state),
         action <- action(sensitivity, rule, state.policy) do
      case action do
        :keep -> keep(value, path, sensitivity, rule, depth, state)
        :mask -> redact_value(@masked, rule, path, :mask, state)
        :drop -> redact_value(:drop, rule, path, :drop, state)
      end
    end
  end

  defp keep(nil, _path, _sensitivity, _rule, _depth, state), do: {:ok, nil, state}

  defp keep(value, _path, _sensitivity, _rule, _depth, state) when is_boolean(value),
    do: {:ok, value, state}

  defp keep(value, _path, _sensitivity, _rule, _depth, state)
       when is_integer(value) and value >= @minimum_integer and value <= @maximum_integer,
       do: {:ok, value, state}

  defp keep(value, _path, _sensitivity, _rule, _depth, state) when is_binary(value) do
    bytes = byte_size(value)

    cond do
      bytes > 4_096 or not String.valid?(value) ->
        {:error, :invalid_binary}

      state.input_bytes + bytes > state.policy.max_input_bytes ->
        {:error, :input_byte_limit}

      true ->
        {:ok, :binary.copy(value), %{state | input_bytes: state.input_bytes + bytes}}
    end
  end

  defp keep(value, path, sensitivity, rule, depth, state)
       when is_map(value) and not is_struct(value) do
    if map_size(value) <= state.policy.max_width do
      entries = Map.to_list(value)

      if Enum.all?(entries, fn {key, _item} ->
           is_binary(key) and byte_size(key) in 1..128 and String.valid?(key)
         end) do
        key_bytes = Enum.reduce(entries, 0, fn {key, _item}, total -> total + byte_size(key) end)

        if state.input_bytes + key_bytes <= state.policy.max_input_bytes do
          state = %{state | input_bytes: state.input_bytes + key_bytes}

          entries
          |> Enum.sort_by(fn {key, _item} -> key end)
          |> Enum.reduce_while({:ok, %{}, state}, fn {key, item}, {:ok, output, state} ->
            case walk(item, path ++ [key], sensitivity, rule, depth + 1, state) do
              {:ok, :drop, state} ->
                {:cont, {:ok, output, state}}

              {:ok, sanitized, state} ->
                {:cont, {:ok, Map.put(output, :binary.copy(key), sanitized), state}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
        else
          {:error, :input_byte_limit}
        end
      else
        {:error, :invalid_map_key}
      end
    else
      {:error, :width_limit}
    end
  end

  defp keep(value, path, sensitivity, rule, depth, state) when is_list(value) do
    keep_list(value, path, sensitivity, rule, depth, state, [], 0)
  end

  defp keep(_value, _path, _sensitivity, _rule, _depth, _state),
    do: {:error, :unsupported_term}

  defp keep_list([], _path, _sensitivity, _rule, _depth, state, output, _index),
    do: {:ok, Enum.reverse(output), state}

  defp keep_list(_value, _path, _sensitivity, _rule, _depth, state, _output, index)
       when index >= state.policy.max_width,
       do: {:error, :width_limit}

  defp keep_list([head | tail], path, sensitivity, rule, depth, state, output, index) do
    case walk(head, path ++ [index], sensitivity, rule, depth + 1, state) do
      {:ok, :drop, state} ->
        keep_list(tail, path, sensitivity, rule, depth, state, [nil | output], index + 1)

      {:ok, item, state} ->
        keep_list(tail, path, sensitivity, rule, depth, state, [item | output], index + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp keep_list(_improper, _path, _sensitivity, _rule, _depth, _state, _output, _index),
    do: {:error, :improper_list}

  defp visit(state) do
    cond do
      state.nodes >= state.policy.max_nodes -> {:error, :node_limit}
      System.monotonic_time(:microsecond) > state.deadline -> {:error, :deadline_exceeded}
      true -> {:ok, %{state | nodes: state.nodes + 1}}
    end
  end

  defp before_deadline(state) do
    if System.monotonic_time(:microsecond) <= state.deadline,
      do: :ok,
      else: {:error, :deadline_exceeded}
  end

  defp effective_rule(path, sensitivity, inherited_rule, state) do
    exact = Map.get(state.policy.rules, List.to_tuple(path))

    wildcard =
      case path do
        [] ->
          nil

        _path ->
          Map.get(state.policy.rules, path |> List.replace_at(-1, :each) |> List.to_tuple())
      end

    case exact || wildcard do
      nil -> {sensitivity, inherited_rule}
      rule -> {more_sensitive(sensitivity, rule.sensitivity), rule}
    end
  end

  defp more_sensitive(left, right) do
    if sensitivity_rank(left) >= sensitivity_rank(right), do: left, else: right
  end

  defp action(sensitivity, rule, policy) do
    if sensitivity_rank(sensitivity) <= sensitivity_rank(policy.maximum_sensitivity) do
      :keep
    else
      if rule, do: rule.action, else: :drop
    end
  end

  defp sensitivity_rank(:public), do: 0
  defp sensitivity_rank(:internal), do: 1
  defp sensitivity_rank(:confidential), do: 2
  defp sensitivity_rank(:secret), do: 3

  defp redact_value(value, rule, path, action, state) do
    declared_path = if rule, do: rule.path, else: path
    manifest_path = Enum.map(declared_path, &Policy.wire_segment/1)
    key = {Atom.to_string(action), manifest_path}

    manifest =
      Map.update(state.manifest, key, 1, fn count -> min(count + 1, 9_223_372_036_854_775_807) end)

    if map_size(manifest) <= state.policy.max_manifest_records,
      do: {:ok, value, %{state | manifest: manifest}},
      else: {:error, :manifest_limit}
  end

  defp manifest(state) do
    policy_id = state.policy.id <> ":" <> state.policy.fingerprint

    state.manifest
    |> Enum.map(fn {{action, path}, count} ->
      %{"action" => action, "count" => count, "path" => path, "policy_id" => policy_id}
    end)
    |> Enum.sort_by(&Canonical.encode/1)
  end

  defp valid_manifest?(manifest, policy) do
    Value.valid_list?(manifest, policy.max_manifest_records, 4_096) and
      Enum.all?(manifest, fn record ->
        byte_size(Canonical.encode(record)) <= 1_024
      end)
  end

  defp failed(reason) do
    {:error,
     Error.new(:redaction_failed, "redaction denied export", %{
       reason: Atom.to_string(reason)
     })}
  end
end
