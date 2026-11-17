defmodule Insider.Collector.Poller.Provider do
  @moduledoc false

  alias Insider.Collector.Poller.Ets
  alias Insider.Collector.Poller.Ports
  alias Insider.Collector.Poller.Processes

  @type status :: :complete | :partial
  @type result ::
          {:ok, status(), map(), [String.t()]}
          | {:error, :exited | :failed | :protected}
  @type scan_result ::
          {:ok, status(), map(), [String.t()], Processes.snapshot()} | {:error, :failed}
  @type port_result ::
          {:ok, status(), map(), [String.t()], Ports.snapshot()} | {:error, :failed}

  @callback vm_sample() :: result()
  @callback process_sample(pid()) :: result()

  # The whole-node scans run only when the Poller is configured with
  # `top_processes`, `top_ets_tables`, or `top_ports`; a provider without
  # them cannot be.
  @callback process_top(Processes.snapshot() | nil, Processes.options()) :: scan_result()
  @callback ets_top(Ets.options()) :: result()
  @callback port_top(Ports.snapshot() | nil, Ports.options()) :: port_result()

  @optional_callbacks process_top: 2, ets_top: 1, port_top: 2
end
