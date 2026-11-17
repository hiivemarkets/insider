defmodule Insider.Sentinel.Sandbox do
  @moduledoc """
  Provider-driven lifecycle for a disposable clean target.

  The core owns authorization, deadlines, lease accounting, and cleanup proof.
  Providers own platform effects; the core never invokes a shell, filesystem,
  network, node, container, or device directly.
  """

  defdelegate start_run(executor, target, options),
    to: Insider.Sentinel.Sandbox.Executor

  defdelegate run(executor, target, options), to: Insider.Sentinel.Sandbox.Executor
  defdelegate await(handle, timeout), to: Insider.Sentinel.Sandbox.Executor
  defdelegate cancel(handle), to: Insider.Sentinel.Sandbox.Executor
  defdelegate cancel(handle, timeout), to: Insider.Sentinel.Sandbox.Executor
end
