defmodule Insider.Runtime.HostPolicy do
  @moduledoc """
  A trusted host bootstrap binding for Runtime protected targets.

  Construct this only from application supervision/startup configuration. It is
  deliberately not decoded from protocol requests, Runtime options, adapters,
  or target parameters. The binding adds application targets to the immutable
  BEAM/OTP policy; it grants no observation authority.
  """

  alias Insider.Policy.ProtectedTargets

  @enforce_keys [:protected_targets]
  defstruct [:protected_targets]

  @type t :: %__MODULE__{protected_targets: ProtectedTargets.t()}

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(options \\ [])

  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- keys == Enum.uniq(keys),
         true <- keys -- [:host_protected_targets] == [],
         {:ok, protected_targets} <-
           ProtectedTargets.new(host_targets: Keyword.get(options, :host_protected_targets, [])) do
      {:ok, %__MODULE__{protected_targets: protected_targets}}
    else
      _error -> {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  end

  def new(_options), do: {:error, :invalid_policy}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{protected_targets: policy}), do: ProtectedTargets.valid?(policy)
  def valid?(_policy), do: false
end
