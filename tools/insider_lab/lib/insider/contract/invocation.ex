defmodule Insider.Contract.Invocation do
  @moduledoc """
  A classified local callback result. It must pass through redaction before export.
  """

  alias Insider.Protocol.Error

  @enforce_keys [
    :schema,
    :contract,
    :kind,
    :name,
    :status,
    :reason,
    :sensitivity,
    :duration_us,
    :cleanup
  ]
  defstruct [
    :schema,
    :contract,
    :kind,
    :name,
    :status,
    :reason,
    :value,
    :sensitivity,
    :error,
    :duration_us,
    :cleanup,
    warnings: [],
    uncertainty: []
  ]

  @type status :: :ok | :violation | :error | :timeout | :cancelled | :overloaded
  @type reason ::
          :completed
          | :invariant_violated
          | :invalid_request
          | :policy_denied
          | :invalid_callback_output
          | :callback_exception
          | :deadline_exceeded
          | :executor_overloaded
          | :executor_unavailable
          | :executor_failed
  @type t :: %__MODULE__{
          schema: String.t(),
          contract: map(),
          kind: atom(),
          name: String.t(),
          status: status(),
          reason: reason(),
          value: term(),
          sensitivity: atom(),
          error: Error.t() | nil,
          duration_us: non_neg_integer(),
          cleanup: map(),
          warnings: [String.t()],
          uncertainty: [String.t()]
        }
end
