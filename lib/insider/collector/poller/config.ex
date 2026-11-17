defmodule Insider.Collector.Poller.Config do
  @moduledoc false

  alias Insider.Protocol.Value
  alias Insider.Policy.ProtectedTargets
  alias Insider.Recorder.Handle

  @required [:authority, :boot_id, :clock_id]
  @optional [
    :cleanup_timeout_ms,
    :cycle_timeout_ms,
    :initial_delay_ms,
    :interval_ms,
    :node,
    :probe_timeout_ms,
    :host_protected_targets,
    :protected_target_policy,
    :provider,
    :source_instance_id,
    :targets,
    :top_ets_tables,
    :top_ports,
    :top_processes,
    :watch_names
  ]
  @maximum_targets 32
  # A ranking event must fit the 4 KiB event attribute bound: a process
  # entry costs about 200 bytes in three rankings, a table about 110 in two.
  @maximum_top_processes 5
  @maximum_top_ets_tables 10
  # A port type costs about 80 bytes and an owner about 110.
  @maximum_top_ports 10
  @maximum_watch_names 16

  @enforce_keys [
    :authority,
    :boot_id,
    :cleanup_timeout_ms,
    :clock_id,
    :cycle_timeout_ms,
    :initial_delay_ms,
    :interval_ms,
    :node,
    :probe_timeout_ms,
    :protected_target_policy,
    :host_protected_targets,
    :provider,
    :recorder,
    :source_instance_id,
    :targets,
    :top_ets_tables,
    :top_ports,
    :top_processes,
    :watch_names
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          authority: String.t(),
          boot_id: String.t(),
          cleanup_timeout_ms: pos_integer(),
          clock_id: String.t(),
          cycle_timeout_ms: pos_integer(),
          initial_delay_ms: non_neg_integer(),
          interval_ms: pos_integer(),
          node: String.t(),
          probe_timeout_ms: pos_integer(),
          protected_target_policy: ProtectedTargets.t(),
          host_protected_targets: [pid()],
          provider: module(),
          recorder: Handle.t(),
          source_instance_id: String.t(),
          targets: [pid()],
          top_ets_tables: non_neg_integer(),
          top_ports: non_neg_integer(),
          top_processes: non_neg_integer(),
          watch_names: [atom()]
        }

  @doc "The most entries each process ranking may ask for."
  @spec maximum_top_processes() :: pos_integer()
  def maximum_top_processes, do: @maximum_top_processes

  @doc "The most entries each ETS ranking may ask for."
  @spec maximum_top_ets_tables() :: pos_integer()
  def maximum_top_ets_tables, do: @maximum_top_ets_tables

  @doc "The most entries each port ranking may ask for."
  @spec maximum_top_ports() :: pos_integer()
  def maximum_top_ports, do: @maximum_top_ports

  @doc "The most registered names one poller may watch."
  @spec maximum_watch_names() :: pos_integer()
  def maximum_watch_names, do: @maximum_watch_names

  @spec new(Handle.t(), keyword()) :: {:ok, t()} | {:error, :invalid_options}
  def new(%Handle{} = recorder, options) when is_list(options) do
    with true <- exact_options?(options),
         {:ok, protection} <- protected_target_policy(options),
         config <- build(recorder, options, protection),
         true <- valid?(config) do
      {:ok, config}
    else
      _other -> {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :invalid_options}
  catch
    _kind, _reason -> {:error, :invalid_options}
  end

  def new(_recorder, _options), do: {:error, :invalid_options}

  defp build(recorder, options, protection) do
    %__MODULE__{
      authority: copy(Keyword.fetch!(options, :authority)),
      boot_id: copy(Keyword.fetch!(options, :boot_id)),
      cleanup_timeout_ms: Keyword.get(options, :cleanup_timeout_ms, 10),
      clock_id: copy(Keyword.fetch!(options, :clock_id)),
      cycle_timeout_ms: Keyword.get(options, :cycle_timeout_ms, 250),
      initial_delay_ms: Keyword.get(options, :initial_delay_ms, 1_000),
      interval_ms: Keyword.get(options, :interval_ms, 1_000),
      node: copy(Keyword.get(options, :node, Atom.to_string(node()))),
      probe_timeout_ms: Keyword.get(options, :probe_timeout_ms, 50),
      protected_target_policy: protection,
      host_protected_targets: Keyword.get(options, :host_protected_targets, []),
      provider: Keyword.get(options, :provider, Insider.Collector.Poller.Erlang),
      recorder: recorder,
      source_instance_id:
        options
        |> Keyword.get_lazy(:source_instance_id, fn ->
          "poller-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
        end)
        |> copy(),
      targets: Keyword.get(options, :targets, []),
      top_ets_tables: Keyword.get(options, :top_ets_tables, 0),
      top_ports: Keyword.get(options, :top_ports, 0),
      top_processes: Keyword.get(options, :top_processes, 0),
      watch_names: Keyword.get(options, :watch_names, [])
    }
  end

  defp exact_options?(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: []

    Value.bounded_list?(options, length(@required) + length(@optional)) and
      Keyword.keyword?(options) and keys == Enum.uniq(keys) and
      Enum.all?(@required, &(&1 in keys)) and keys -- (@required ++ @optional) == []
  end

  defp protected_target_policy(options) do
    case Keyword.fetch(options, :protected_target_policy) do
      {:ok, policy} ->
        if ProtectedTargets.valid?(policy) and
             not Keyword.has_key?(options, :host_protected_targets),
           do: {:ok, policy},
           else: {:error, :invalid_policy}

      :error ->
        ProtectedTargets.new(host_targets: Keyword.get(options, :host_protected_targets, []))
    end
  end

  defp valid?(config) do
    bounded_string?(config.authority, 128) and bounded_string?(config.boot_id, 128) and
      bounded_string?(config.clock_id, 128) and bounded_string?(config.node, 256) and
      bounded_string?(config.source_instance_id, 128) and provider?(config.provider) and
      target_list?(config.targets) and
      target_list?(config.host_protected_targets) and
      ProtectedTargets.valid?(config.protected_target_policy) and
      Enum.all?(config.targets, &(node(&1) == node())) and
      Enum.all?(config.host_protected_targets, &(node(&1) == node())) and
      bounded_integer?(config.interval_ms, 10, 60_000) and
      bounded_integer?(config.initial_delay_ms, 0, 60_000) and
      bounded_integer?(config.probe_timeout_ms, 1, 1_000) and
      bounded_integer?(config.cleanup_timeout_ms, 1, 100) and
      bounded_integer?(config.cycle_timeout_ms, 2, 5_000) and
      config.cycle_timeout_ms >= config.probe_timeout_ms + config.cleanup_timeout_ms and
      bounded_integer?(config.top_processes, 0, @maximum_top_processes) and
      bounded_integer?(config.top_ets_tables, 0, @maximum_top_ets_tables) and
      bounded_integer?(config.top_ports, 0, @maximum_top_ports) and
      watch_names?(config.watch_names) and
      scans_provided?(config)
  end

  defp provider?(provider),
    do:
      is_atom(provider) and byte_size(Atom.to_string(provider)) in 1..128 and
        Code.ensure_loaded?(provider) and
        function_exported?(provider, :vm_sample, 0) and
        function_exported?(provider, :process_sample, 1)

  # The whole-node scans are optional provider callbacks.
  defp scans_provided?(config) do
    (config.top_processes == 0 or function_exported?(config.provider, :process_top, 2)) and
      (config.top_ets_tables == 0 or function_exported?(config.provider, :ets_top, 1)) and
      (config.top_ports == 0 or function_exported?(config.provider, :port_top, 2))
  end

  defp watch_names?(names) do
    Value.bounded_list?(names, @maximum_watch_names) and names == Enum.uniq(names) and
      Enum.all?(names, &(is_atom(&1) and not is_nil(&1) and not is_boolean(&1)))
  end

  defp target_list?(targets) do
    Value.bounded_list?(targets, @maximum_targets) and Enum.all?(targets, &is_pid/1) and
      targets == Enum.uniq(targets)
  end

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value in minimum..maximum

  defp copy(value) when is_binary(value), do: :binary.copy(value)
  defp copy(value), do: value
end
