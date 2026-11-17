defmodule Insider.Adapter.CLI.Dispatcher do
  @moduledoc """
  Execution boundary used by the CLI transport.

  A host application supplies a module implementing this behaviour. The CLI
  validates input before dispatch and accepts only a correlated protocol result
  back from the implementation. Authorization context is trusted host state,
  never request data; a dispatcher using `Insider.Policy` must perform its
  `dispatchable?/1` check immediately before it starts runtime work.
  """

  alias Insider.Protocol.Request
  alias Insider.Protocol.Result

  @callback dispatch(Request.t()) :: Result.t()
end
