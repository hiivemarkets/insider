defmodule Insider.Sentinel.Sandbox.Body do
  @moduledoc """
  Behaviour for trusted work that runs while a disposable target lease is live.

  Body modules are host-configured and selected by module reference through the
  direct API. Portable target and request data never select a module. A body
  must not return until all work it owns has stopped; it should handle the
  `{:cancel_sandbox_body, cancellation_reference}` message and return promptly.
  """

  @type arguments :: %{
          owner_id: binary(),
          target: Insider.Sentinel.Sandbox.Target.t(),
          observed_provenance: map(),
          input: map(),
          deadline: integer(),
          stop_deadline: integer(),
          cancellation_reference: reference()
        }

  @callback identity() :: map()
  @callback run(arguments()) :: {:ok, map()} | {:error, atom(), map()} | {:cancelled, map()}

  @doc false
  @spec valid_result?(term()) :: boolean()
  def valid_result?({:ok, receipt}), do: valid_receipt?(receipt)
  def valid_result?({:cancelled, receipt}), do: valid_receipt?(receipt)

  def valid_result?({:error, reason, receipt}) when is_atom(reason),
    do: valid_receipt?(receipt)

  def valid_result?(_result), do: false

  defp valid_receipt?(receipt),
    do: is_map(receipt) and Insider.Protocol.Value.bounded_data?(receipt, 32_768)
end
