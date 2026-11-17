defmodule Insider.Collector.IngressProfile do
  @moduledoc """
  Host-owned ingress defaults for collector sessions.

  Staging and production profiles are descriptive readiness artifacts only and
  deny collector startup. Their safe defaults keep Logger payloads off and
  require Telemetry's existing exact policy allowlists.
  """

  alias Insider.Event.Canonical

  @environments [:development, :test, :ci, :staging, :production]

  @enforce_keys [
    :environment,
    :fingerprint,
    :logger_payload,
    :logger_message_semantics,
    :logger_structural_only,
    :observation_enabled,
    :telemetry_projection
  ]
  defstruct [
    :environment,
    :fingerprint,
    :logger_payload,
    :logger_message_semantics,
    :logger_structural_only,
    :observation_enabled,
    :telemetry_projection
  ]

  @type t :: %__MODULE__{
          environment: atom(),
          fingerprint: String.t(),
          logger_payload: boolean(),
          logger_message_semantics: boolean(),
          logger_structural_only: boolean(),
          observation_enabled: boolean(),
          telemetry_projection: String.t()
        }

  @spec new(atom()) :: {:ok, t()} | {:error, :invalid_profile}
  def new(environment) when environment in @environments do
    profile = %{
      "environment" => Atom.to_string(environment),
      "logger_payload" => environment in [:development, :test, :ci],
      "logger_message_semantics" => environment in [:development, :test, :ci],
      "logger_structural_only" => environment in [:staging, :production],
      "observation_enabled" => environment in [:development, :test, :ci],
      "telemetry_projection" => "exact_allowlist_required"
    }

    {:ok,
     %__MODULE__{
       environment: environment,
       fingerprint: Canonical.sha256(profile),
       logger_payload: profile["logger_payload"],
       logger_message_semantics: profile["logger_message_semantics"],
       logger_structural_only: profile["logger_structural_only"],
       observation_enabled: profile["observation_enabled"],
       telemetry_projection: profile["telemetry_projection"]
     }}
  end

  def new(_environment), do: {:error, :invalid_profile}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = profile), do: new(profile.environment) == {:ok, profile}
  def valid?(_profile), do: false
end
