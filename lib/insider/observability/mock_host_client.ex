defmodule Insider.Observability.MockHostClient do
  @moduledoc """
  Contract for a host-owned asynchronous handoff of inert mock events.

  Insider provides no implementation and never invokes this callback. The
  contract does not authorize live delivery; a host accepting a value still
  must preserve its `mock: true` and `delivery_status: not_attempted` claims.
  """

  alias Insider.Observability.MockEvent

  @callback handoff(MockEvent.t()) :: :accepted | {:error, :rejected}
end
