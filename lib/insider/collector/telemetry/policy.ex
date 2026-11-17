defmodule Insider.Collector.Telemetry.Policy do
  @moduledoc """
  Validated pure-data allowlist for Telemetry collection.

  Source keys are existing atoms supplied by application configuration. Output
  names are bounded strings, so handling an event never creates atoms.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Value

  @max_events 64
  @max_event_segments 8
  @max_projections 16
  @max_open_lifecycles 1_024
  @max_lifecycle_age_events 1_000_000
  @phases [:event, :start, :stop, :exception]
  @vocabulary ~r/\A[a-z][a-z0-9_.-]*\z/
  @correlation_keys [
    :logical_operation_id,
    :parent_event_id,
    :process_generation,
    :span_id,
    :trace_id
  ]
  @keys [
    :id,
    :events,
    :metadata,
    :measurements,
    :correlation,
    :max_open_lifecycles,
    :max_lifecycle_age_events
  ]

  @enforce_keys [
    :id,
    :fingerprint,
    :events,
    :event_names,
    :metadata,
    :measurements,
    :correlation,
    :max_open_lifecycles,
    :max_lifecycle_age_events
  ]
  defstruct @enforce_keys

  @type event_rule :: %{
          name: [atom()],
          kind: String.t(),
          phase: atom(),
          lifecycle: String.t(),
          failure_event: boolean()
        }
  @type t :: %__MODULE__{
          id: String.t(),
          fingerprint: String.t(),
          events: %{required(tuple()) => event_rule()},
          event_names: [[atom()]],
          metadata: %{optional(atom()) => String.t()},
          measurements: %{optional(atom()) => String.t()},
          correlation: %{optional(atom()) => atom()},
          max_open_lifecycles: pos_integer(),
          max_lifecycle_age_events: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(options) do
    with true <- Value.bounded_list?(options, length(@keys)),
         true <- exact_options?(options),
         {:ok, id} <- bounded_binary(Keyword.fetch!(options, :id), 128),
         {:ok, unsorted_rules} <- event_rules(Keyword.fetch!(options, :events)),
         {:ok, metadata} <- projection(Keyword.get(options, :metadata, [])),
         {:ok, measurements} <- projection(Keyword.get(options, :measurements, [])),
         {:ok, correlation} <- correlation(Keyword.get(options, :correlation, [])),
         true <- valid_lifecycle_policy?(unsorted_rules, correlation),
         max_open <- Keyword.get(options, :max_open_lifecycles, 256),
         max_age <- Keyword.get(options, :max_lifecycle_age_events, 10_000),
         true <- is_integer(max_open) and max_open in 1..@max_open_lifecycles,
         true <- is_integer(max_age) and max_age in 1..@max_lifecycle_age_events do
      rules = Enum.sort_by(unsorted_rules, &event_key/1)
      event_names = Enum.map(rules, & &1.name)
      events = Map.new(rules, &{List.to_tuple(&1.name), &1})

      policy = %__MODULE__{
        id: id,
        fingerprint:
          fingerprint(id, rules, metadata, measurements, correlation, max_open, max_age),
        events: events,
        event_names: event_names,
        metadata: metadata,
        measurements: measurements,
        correlation: correlation,
        max_open_lifecycles: max_open,
        max_lifecycle_age_events: max_age
      }

      {:ok, policy}
    else
      _failure -> {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  catch
    _kind, _reason -> {:error, :invalid_policy}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = policy) do
    with true <- bounded_policy_shape?(policy),
         wire_events = Map.values(policy.events),
         true <- Enum.all?(wire_events, &stored_rule?/1),
         {:ok, rebuilt} <-
           new(
             id: policy.id,
             events: Enum.map(wire_events, &(Map.drop(&1, [:failure_event]) |> Map.to_list())),
             metadata: Map.to_list(policy.metadata),
             measurements: Map.to_list(policy.measurements),
             correlation: Map.to_list(policy.correlation),
             max_open_lifecycles: policy.max_open_lifecycles,
             max_lifecycle_age_events: policy.max_lifecycle_age_events
           ) do
      rebuilt == policy
    else
      _failure -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_policy), do: false

  defp exact_options?(options) do
    Keyword.keyword?(options) and Keyword.has_key?(options, :id) and
      Keyword.has_key?(options, :events) and
      length(options) == length(Enum.uniq_by(options, &elem(&1, 0))) and
      Enum.all?(Keyword.keys(options), &(&1 in @keys))
  end

  defp event_rules(rules) do
    with true <- rules != [] and Value.bounded_list?(rules, @max_events),
         {:ok, normalized} <- map_all(rules, &event_rule/1),
         true <- Enum.uniq_by(normalized, & &1.name) == normalized do
      {:ok, normalized}
    else
      _failure -> :error
    end
  end

  defp event_rule(rule) do
    if Value.bounded_list?(rule, 4) and Keyword.keyword?(rule) and
         Enum.sort(Keyword.keys(rule)) == [:kind, :lifecycle, :name, :phase] do
      with {:ok, name} <- event_name(Keyword.fetch!(rule, :name)),
           {:ok, kind} <- vocabulary(Keyword.fetch!(rule, :kind)),
           {:ok, lifecycle} <- bounded_binary(Keyword.fetch!(rule, :lifecycle), 128),
           phase when phase in @phases <- Keyword.fetch!(rule, :phase),
           true <- name != [:telemetry, :handler, :failure] or phase == :event do
        {:ok,
         %{
           name: name,
           kind: kind,
           phase: phase,
           lifecycle: lifecycle,
           failure_event: name == [:telemetry, :handler, :failure]
         }}
      else
        _failure -> :error
      end
    else
      :error
    end
  end

  defp event_name(name) do
    if name != [] and Value.bounded_list?(name, @max_event_segments) and
         Enum.all?(name, &(is_atom(&1) and bounded_atom?(&1))),
       do: {:ok, name},
       else: :error
  end

  defp projection(entries) do
    with true <- Value.bounded_list?(entries, @max_projections),
         true <- Keyword.keyword?(entries),
         true <- length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))),
         {:ok, normalized} <-
           map_all(entries, fn
             {source, output} when is_atom(source) ->
               case bounded_binary(output, 64) do
                 {:ok, value} ->
                   if bounded_atom?(source), do: {:ok, {source, value}}, else: :error

                 :error ->
                   :error
               end

             _entry ->
               :error
           end),
         outputs = Enum.map(normalized, &elem(&1, 1)),
         true <- length(outputs) == length(Enum.uniq(outputs)) do
      {:ok, Map.new(normalized)}
    else
      _failure -> :error
    end
  end

  defp correlation(entries) do
    if Value.bounded_list?(entries, length(@correlation_keys)) and Keyword.keyword?(entries) and
         length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))) and
         Enum.all?(entries, fn {target, source} ->
           target in @correlation_keys and is_atom(source) and bounded_atom?(source)
         end) do
      {:ok, Map.new(entries)}
    else
      :error
    end
  end

  defp fingerprint(id, rules, metadata, measurements, correlation, max_open, max_age) do
    wire = %{
      "id" => id,
      "events" =>
        Enum.map(rules, fn rule ->
          %{
            "name" => Enum.map(rule.name, &Atom.to_string/1),
            "kind" => rule.kind,
            "lifecycle" => rule.lifecycle,
            "phase" => Atom.to_string(rule.phase)
          }
        end),
      "metadata" => wire_projection(metadata),
      "measurements" => wire_projection(measurements),
      "correlation" =>
        correlation
        |> Enum.sort()
        |> Enum.map(fn {target, source} -> [Atom.to_string(target), Atom.to_string(source)] end),
      "max_open_lifecycles" => max_open,
      "max_lifecycle_age_events" => max_age
    }

    wire
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp wire_projection(projection) do
    projection
    |> Enum.sort()
    |> Enum.map(fn {source, output} -> [Atom.to_string(source), output] end)
  end

  defp event_key(rule), do: Enum.map(rule.name, &Atom.to_string/1)

  defp valid_lifecycle_policy?(rules, correlation) do
    Enum.all?(rules, &(&1.phase == :event)) or Map.has_key?(correlation, :logical_operation_id)
  end

  defp bounded_policy_shape?(policy) do
    expected = struct(__MODULE__)

    map_size(policy) == map_size(expected) and
      Enum.sort(Map.keys(policy)) == Enum.sort(Map.keys(expected)) and
      bounded?(policy.id, 128) and hex_digest?(policy.fingerprint) and
      bounded_plain_map?(policy.events, @max_events) and
      Value.bounded_list?(policy.event_names, @max_events) and
      Enum.all?(policy.event_names, &valid_event_name?/1) and
      bounded_plain_map?(policy.metadata, @max_projections) and
      bounded_plain_map?(policy.measurements, @max_projections) and
      bounded_plain_map?(policy.correlation, length(@correlation_keys))
  end

  defp stored_rule?(rule) do
    is_map(rule) and not is_struct(rule) and map_size(rule) == 5 and
      Enum.sort(Map.keys(rule)) == [:failure_event, :kind, :lifecycle, :name, :phase] and
      valid_event_name?(rule.name) and bounded?(rule.kind, 128) and
      String.match?(rule.kind, @vocabulary) and bounded?(rule.lifecycle, 128) and
      rule.phase in @phases and is_boolean(rule.failure_event)
  end

  defp valid_event_name?(name) do
    Value.bounded_list?(name, @max_event_segments) and name != [] and
      Enum.all?(name, &(is_atom(&1) and bounded_atom?(&1)))
  end

  defp bounded_plain_map?(value, maximum),
    do: is_map(value) and not is_struct(value) and map_size(value) <= maximum

  defp hex_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do:
      value |> :binary.bin_to_list() |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)

  defp hex_digest?(_value), do: false

  defp vocabulary(value) do
    with {:ok, bounded} <- bounded_binary(value, 128),
         true <- String.match?(bounded, @vocabulary) do
      {:ok, bounded}
    else
      _failure -> :error
    end
  end

  defp map_all(values, mapper) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, accumulated} ->
      case mapper.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | accumulated]}}
        _failure -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp bounded_binary(value, maximum)
       when is_binary(value) and byte_size(value) in 1..maximum//1 do
    if String.valid?(value), do: {:ok, :binary.copy(value)}, else: :error
  end

  defp bounded_binary(_value, _maximum), do: :error

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_atom?(value) do
    encoded = Atom.to_string(value)
    byte_size(encoded) in 1..64 and String.valid?(encoded)
  end
end
