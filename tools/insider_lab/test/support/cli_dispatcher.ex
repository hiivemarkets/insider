defmodule Insider.Test.CLIDispatcher do
  @behaviour Insider.Adapter.CLI.Dispatcher

  alias Insider.Protocol

  @impl true
  def dispatch(request) do
    case request.params do
      %{"outcome" => "timeout"} -> Protocol.timeout(request)
      %{"outcome" => "cancelled"} -> Protocol.cancelled(request)
      %{"outcome" => "error"} -> Protocol.failure(request, error())
      _params -> Protocol.success(request, %{healthy: true})
    end
  end

  defp error, do: Insider.Protocol.Error.new(:operation_failed, "injected failure")
end
