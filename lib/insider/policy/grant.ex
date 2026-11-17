defmodule Insider.Policy.Grant do
  @moduledoc """
  A pre-verified authorization grant. Cryptographic verification is deliberately external.
  """

  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @scopes [
    "runtime.observe",
    "events.subscribe",
    "incident.capture",
    "incident.export",
    "contract.observe",
    "runtime.trace",
    "scenario.execute",
    "verification.execute"
  ]
  @option_keys [:reference, :audit_id, :scopes, :target, :expires_at_monotonic, :owner_id]
  @max_scopes length(@scopes)

  @enforce_keys [:reference, :audit_id, :scopes, :target, :expires_at_monotonic]
  defstruct [:reference, :audit_id, :scopes, :target, :expires_at_monotonic, :owner_id]

  @type t :: %__MODULE__{
          reference: String.t(),
          audit_id: String.t(),
          scopes: [String.t()],
          target: %{node: String.t()},
          expires_at_monotonic: integer(),
          owner_id: String.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- @option_keys == [] do
      build(options)
    else
      invalid("verified grant contains invalid fields", options)
    end
  end

  def new(value), do: invalid("verified grant must be a keyword list", value)

  defp build(options) do
    grant = %__MODULE__{
      reference: Keyword.get(options, :reference),
      audit_id: Keyword.get(options, :audit_id),
      scopes: Keyword.get(options, :scopes),
      target: Keyword.get(options, :target),
      expires_at_monotonic: Keyword.get(options, :expires_at_monotonic),
      owner_id: Keyword.get(options, :owner_id)
    }

    if valid?(grant) do
      {:ok, grant}
    else
      invalid("verified grant is invalid", options)
    end
  end

  defp invalid(message, value) do
    {:error,
     Error.new(:policy_denied, message, %{
       received: Value.summary(value)
     })}
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = grant) do
    bounded_string?(grant.reference) and bounded_string?(grant.audit_id) and
      Value.bounded_list?(grant.scopes, @max_scopes) and grant.scopes != [] and
      Enum.uniq(grant.scopes) == grant.scopes and
      Enum.all?(grant.scopes, &(&1 in @scopes)) and
      valid_target?(grant.target) and is_integer(grant.expires_at_monotonic) and
      (is_nil(grant.owner_id) or bounded_string?(grant.owner_id))
  end

  def valid?(_value), do: false

  defp bounded_string?(value), do: is_binary(value) and byte_size(value) in 1..256

  defp valid_target?(%{node: node_name} = target) do
    map_size(target) == 1 and bounded_string?(node_name)
  end

  defp valid_target?(_target), do: false
end
