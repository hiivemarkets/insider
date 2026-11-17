defmodule Insider.Collector.Telemetry.Omitted do
  @moduledoc false

  # Collection-time omission evidence for one Telemetry event: what its
  # allowlist policy did not record. It is the event attribute `"omitted"`,
  # present only when something was left out:
  #
  #     %{
  #       "policy_id" => "insider-live-telemetry",
  #       "measurements" => 3,                 # every withheld measurement
  #       "measurement_names" => ["duration"], # those the host may name
  #       "metadata" => 2                      # every withheld metadata key
  #     }
  #
  # Counts are exact. Names come only from the collector's
  # `nameable_measurements`, so no unknown key is retained. It is ordinary,
  # bounded attribute data, not an export manifest: `Event.redactions` stays
  # the export authority's field, which the incident capsule boundary
  # requires to be empty. `Insider.Live.Disclosure` lifts it into the Live
  # entry's manifest as `drop` records.

  @key "omitted"
  @max_names 16
  @max_name_bytes 64
  @max_policy_id_bytes 128

  @type t :: %{String.t() => term()}

  @doc "The attribute key."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The evidence for counts and names, or `nil` when nothing was withheld."
  @spec new(String.t(), non_neg_integer(), [String.t()], non_neg_integer()) :: t() | nil
  def new(_policy_id, 0, _names, 0), do: nil

  def new(policy_id, measurements, names, metadata) do
    %{
      "policy_id" => policy_id,
      "measurements" => measurements,
      "measurement_names" => names,
      "metadata" => metadata
    }
  end

  @doc "The same evidence without measurement names; the counts are unchanged."
  @spec unnamed(t()) :: t()
  def unnamed(omitted), do: %{omitted | "measurement_names" => []}

  @doc "Whether a decoded value is well-formed evidence."
  @spec valid?(term()) :: boolean()
  def valid?(
        %{
          "policy_id" => policy_id,
          "measurements" => measurements,
          "measurement_names" => names,
          "metadata" => metadata
        } = omitted
      )
      when map_size(omitted) == 4 and is_integer(measurements) and measurements >= 0 and
             is_integer(metadata) and metadata >= 0 and is_list(names) do
    bounded?(policy_id, @max_policy_id_bytes) and length(names) <= @max_names and
      Enum.all?(names, &bounded?(&1, @max_name_bytes)) and names == Enum.uniq(names) and
      length(names) <= measurements and measurements + metadata > 0
  end

  def valid?(_value), do: false

  @doc """
  The `drop` records for well-formed evidence: one per named measurement,
  one counting the other withheld measurements, and one counting withheld
  metadata keys, each under the evidence's policy id.
  """
  @spec drops(t()) :: [map()]
  def drops(%{"policy_id" => policy_id, "measurement_names" => names} = omitted) do
    unnamed = omitted["measurements"] - length(names)

    Enum.map(names, &drop(["key:attributes", "key:measurements", "key:" <> &1], 1, policy_id)) ++
      if(unnamed > 0,
        do: [drop(["key:attributes", "key:measurements"], unnamed, policy_id)],
        else: []
      ) ++
      if omitted["metadata"] > 0,
        do: [drop(["key:attributes", "key:metadata"], omitted["metadata"], policy_id)],
        else: []
  end

  defp drop(path, count, policy_id),
    do: %{"action" => "drop", "count" => count, "path" => path, "policy_id" => policy_id}

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)
end
