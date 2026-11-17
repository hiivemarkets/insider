defmodule Insider.Adapter.CLI.UnavailableDispatcher do
  @moduledoc false

  @behaviour Insider.Adapter.CLI.Dispatcher

  alias Insider.Protocol

  @impl true
  def dispatch(%{operation: "runtime.capabilities"} = request) do
    Protocol.success(request, Insider.Adapter.CLI.capabilities())
  end

  def dispatch(request), do: Protocol.unsupported(request, :runtime_dispatcher)
end
