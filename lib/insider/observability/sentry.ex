defmodule Insider.Observability.Sentry do
  @moduledoc """
  Pure mapping to a mock Sentry event payload.

  This module does not contain or invoke a Sentry client.
  """

  alias Insider.Incident.Capsule
  alias Insider.Observability.Export
  alias Insider.Observability.MockEvent
  alias Insider.Protocol.Error

  @spec map(Export.t(), Capsule.t()) :: {:ok, MockEvent.t()} | {:error, Error.t()}
  def map(export, capsule), do: MockEvent.new(export, capsule, "sentry")
end
