defmodule Insider.Incident.ExportPolicy do
  @moduledoc """
  Trusted capsule-export classification paired with a redaction policy.

  The classification is integration configuration, not an Event claim. It is
  fingerprinted and recorded in each capsule so an offline consumer knows which
  boundary produced the artifact.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Redaction.Policy

  @roots [:finding, :snapshot, :event, :provenance, :authority, :artifacts]
  @sensitivities [:public, :internal, :confidential, :secret]

  @enforce_keys [:redaction_policy, :sensitivities, :max_duration_ms, :fingerprint]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          redaction_policy: Policy.t(),
          sensitivities: %{required(atom()) => atom()},
          max_duration_ms: pos_integer(),
          fingerprint: String.t()
        }

  @spec new(Policy.t(), keyword(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(redaction_policy, sensitivities, options \\ [])

  def new(%Policy{} = redaction_policy, sensitivities, options)
      when is_list(sensitivities) and is_list(options) do
    max_duration_ms = Keyword.get(options, :max_duration_ms, 10_000)

    if Policy.valid?(redaction_policy) and exact_sensitivities?(sensitivities) and
         exact_duration_options?(options, max_duration_ms) do
      sensitivity_map = Map.new(sensitivities)

      policy = %__MODULE__{
        redaction_policy: redaction_policy,
        sensitivities: sensitivity_map,
        max_duration_ms: max_duration_ms,
        fingerprint: fingerprint(redaction_policy, sensitivity_map, max_duration_ms)
      }

      {:ok, policy}
    else
      invalid()
    end
  rescue
    _error -> invalid()
  end

  def new(_redaction_policy, _sensitivities, _options), do: invalid()

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = export_policy) do
    exact_struct?(export_policy) and Policy.valid?(export_policy.redaction_policy) and
      exact_sensitivity_map?(export_policy.sensitivities) and
      is_integer(export_policy.max_duration_ms) and export_policy.max_duration_ms in 1..30_000 and
      export_policy.fingerprint ==
        fingerprint(
          export_policy.redaction_policy,
          export_policy.sensitivities,
          export_policy.max_duration_ms
        )
  rescue
    _error -> false
  end

  def valid?(_value), do: false

  defp exact_sensitivities?(sensitivities) do
    Value.bounded_list?(sensitivities, length(@roots)) and Keyword.keyword?(sensitivities) and
      Enum.sort(Keyword.keys(sensitivities)) == Enum.sort(@roots) and
      Enum.all?(sensitivities, fn {_root, sensitivity} -> sensitivity in @sensitivities end)
  end

  defp exact_sensitivity_map?(sensitivities)
       when is_map(sensitivities) and not is_struct(sensitivities) do
    map_size(sensitivities) == length(@roots) and
      Enum.sort(Map.keys(sensitivities)) == Enum.sort(@roots) and
      Enum.all?(sensitivities, fn {_root, sensitivity} -> sensitivity in @sensitivities end)
  end

  defp exact_sensitivity_map?(_sensitivities), do: false

  defp exact_duration_options?(options, max_duration_ms),
    do:
      Value.bounded_list?(options, 1) and Keyword.keyword?(options) and
        Keyword.keys(options) in [[], [:max_duration_ms]] and is_integer(max_duration_ms) and
        max_duration_ms in 1..30_000

  defp fingerprint(redaction_policy, sensitivities, max_duration_ms) do
    %{
      "max_duration_ms" => max_duration_ms,
      "redaction_policy_fingerprint" => redaction_policy.fingerprint,
      "root_sensitivities" =>
        Map.new(sensitivities, fn {root, sensitivity} ->
          {Atom.to_string(root), Atom.to_string(sensitivity)}
        end),
      "schema" => "insider.incident-export-policy/v1"
    }
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp exact_struct?(policy),
    do:
      map_size(policy) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(policy)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp invalid do
    {:error,
     Error.new(:redaction_failed, "capsule export policy is invalid", %{
       reason: "invalid_export_policy"
     })}
  end
end
