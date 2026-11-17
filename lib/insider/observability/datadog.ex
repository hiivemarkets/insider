defmodule Insider.Observability.Datadog do
  @moduledoc """
  Pure mapping to a mock Datadog Events v2 request body.

  This module does not contain or invoke a Datadog client.
  """

  alias Insider.Incident.Capsule
  alias Insider.Observability.Export
  alias Insider.Observability.MockEvent
  alias Insider.Protocol.Error

  @spec map(Export.t(), Capsule.t()) :: {:ok, MockEvent.t()} | {:error, Error.t()}
  def map(export, capsule), do: MockEvent.new(export, capsule, "datadog")
end
