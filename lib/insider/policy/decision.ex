defmodule Insider.Policy.Decision do
  @moduledoc """
  A bounded, auditable policy outcome. It intentionally excludes capability references.
  """

  @enforce_keys [
    :outcome,
    :reason,
    :request_id,
    :operation,
    :configured_environment,
    :claimed_environment,
    :actor,
    :target,
    :requested_limits,
    :effective_limits,
    :policy_fingerprint,
    :runtime_available
  ]
  defstruct [
    :outcome,
    :reason,
    :request_id,
    :operation,
    :configured_environment,
    :claimed_environment,
    :actor,
    :target,
    :required_scope,
    :grant_audit_id,
    :authorization_expires_at_monotonic,
    :request_deadline_monotonic,
    :dispatch_deadline_monotonic,
    :requested_limits,
    :effective_limits,
    :policy_fingerprint,
    :runtime_available,
    :runtime_provider,
    :runtime_isolation
  ]

  @type t :: %__MODULE__{}
end
