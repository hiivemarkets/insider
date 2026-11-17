defmodule Insider.Identity.Registry do
  @moduledoc false

  use GenServer

  alias Insider.Identity.Generation
  alias Insider.Identity.Subject
  alias Insider.Protocol.Error

  @default_max_active 1_024
  @maximum_active 100_000
  @maximum_options 4

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, configuration, server_options} <- validate_start_options(options) do
      GenServer.start_link(__MODULE__, configuration, server_options)
    end
  end

  @spec declare(GenServer.server(), Subject.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, Error.t()}
  def declare(server, subject, options \\ []) do
    GenServer.call(server, {:declare, subject, options})
  end

  @spec fetch(GenServer.server(), term()) :: {:ok, Generation.t()} | {:error, Error.t()}
  def fetch(server, generation), do: GenServer.call(server, {:fetch, generation})

  @impl true
  def init(configuration) do
    {:ok, Map.merge(configuration, %{by_id: %{}, by_pid: %{}, monitors: %{}})}
  end

  @impl true
  def handle_call({:declare, subject, options}, {pid, _tag}, state) do
    with :ok <- ensure_local(pid),
         :ok <- validate_declaration(subject, options),
         :ok <- ensure_capacity(state),
         :ok <- ensure_undeclared(state, pid) do
      generation = build_generation(state, pid, subject, options)
      reference = Process.monitor(pid)

      next_state = %{
        state
        | by_id: Map.put(state.by_id, generation.id, generation),
          by_pid: Map.put(state.by_pid, pid, generation.id),
          monitors: Map.put(state.monitors, reference, generation.id)
      }

      {:reply, {:ok, generation}, next_state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:fetch, %Generation{} = candidate}, _from, state) do
    if Generation.valid?(candidate) do
      case Map.fetch(state.by_id, candidate.id) do
        {:ok, ^candidate} -> {:reply, {:ok, candidate}, state}
        _other -> {:reply, invalid("process generation is not active"), state}
      end
    else
      {:reply, invalid("process generation handle is invalid"), state}
    end
  end

  def handle_call({:fetch, _candidate}, _from, state),
    do: {:reply, invalid("process generation handle is invalid"), state}

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, reference) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {generation_id, monitors} ->
        {:noreply,
         %{
           state
           | monitors: monitors,
             by_id: Map.delete(state.by_id, generation_id),
             by_pid: Map.delete(state.by_pid, pid)
         }}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp validate_start_options(options) do
    with :ok <- bounded_keyword(options, @maximum_options),
         :ok <- only_keys(options, [:node, :boot_id, :max_active, :name]),
         node when is_binary(node) <- Keyword.get(options, :node),
         boot_id when is_binary(boot_id) <- Keyword.get(options, :boot_id),
         true <- bounded_string?(node, 256),
         true <- bounded_string?(boot_id, 128),
         max_active <- Keyword.get(options, :max_active, @default_max_active),
         true <- is_integer(max_active) and max_active in 1..@maximum_active do
      configuration = %{node: node, boot_id: boot_id, max_active: max_active}
      server_options = Keyword.take(options, [:name])
      {:ok, configuration, server_options}
    else
      _invalid -> {:error, {:invalid_identity_options, "bounded node and boot_id are required"}}
    end
  end

  defp validate_declaration(subject, options) do
    with true <- Subject.valid?(subject),
         :ok <- bounded_keyword(options, 1),
         :ok <- only_keys(options, [:logical_operation_id]),
         operation_id <- Keyword.get(options, :logical_operation_id),
         true <- is_nil(operation_id) or bounded_string?(operation_id, 128) do
      :ok
    else
      _invalid -> invalid("identity declaration is invalid")
    end
  end

  defp ensure_capacity(state) when map_size(state.by_id) < state.max_active, do: :ok
  defp ensure_capacity(_state), do: invalid("identity registry capacity reached")

  defp ensure_local(pid) do
    if node(pid) == node() do
      :ok
    else
      invalid("identity declarations must originate on the registry node")
    end
  end

  defp ensure_undeclared(state, pid) do
    if Map.has_key?(state.by_pid, pid) do
      invalid("process already declared an active identity")
    else
      :ok
    end
  end

  defp build_generation(state, pid, subject, options) do
    %Generation{
      id: System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36),
      node: state.node,
      boot_id: state.boot_id,
      pid: pid,
      subject: subject,
      logical_operation_id: Keyword.get(options, :logical_operation_id),
      declared_at: System.monotonic_time(:microsecond)
    }
  end

  defp bounded_keyword(options, maximum) when is_list(options),
    do: bounded_keyword(options, maximum, 0)

  defp bounded_keyword(_options, _maximum), do: invalid("options must be a bounded keyword list")

  defp bounded_keyword([], _maximum, _count), do: :ok

  defp bounded_keyword([{key, _value} | rest], maximum, count)
       when is_atom(key) and count < maximum,
       do: bounded_keyword(rest, maximum, count + 1)

  defp bounded_keyword(_options, _maximum, _count),
    do: invalid("options must be a bounded keyword list")

  defp only_keys(options, allowed) do
    if Enum.all?(options, fn {key, _value} -> key in allowed end) do
      :ok
    else
      invalid("identity options contain unknown keys")
    end
  end

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp invalid(message), do: {:error, Error.new(:invalid_identity, message)}
end
