defmodule Insider.Identity do
  @moduledoc """
  Same-node correlation for explicitly declared process identities.

  Correlation is layered so absent evidence remains `:unknown`; it is never
  converted into a guessed match. The registry intentionally exposes no lookup
  by PID.
  """

  alias Insider.Event
  alias Insider.Identity.Generation
  alias Insider.Identity.Registry
  alias Insider.Identity.Subject
  alias Insider.Protocol.Error

  @type relation :: :same | :different | :unknown
  @type relations :: %{
          physical: relation(),
          process_generation: relation(),
          logical_actor: relation(),
          logical_operation: relation()
        }

  @doc "Starts the identity registry that `declare/3` and `active?/2` operate on."
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(options), to: Registry

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @doc """
  Declares a new process generation for `subject` and returns its
  `Insider.Identity.Generation`. Identities are explicit: nothing is inferred
  from PIDs.
  """
  @spec declare(GenServer.server(), Subject.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, Error.t()}
  defdelegate declare(registry, subject, options \\ []), to: Registry

  @spec active?(GenServer.server(), term()) :: boolean()
  def active?(registry, generation) do
    Generation.valid?(generation) and
      match?({:ok, %Generation{}}, Registry.fetch(registry, generation))
  end

  @spec attach(GenServer.server(), Event.t(), term()) ::
          {:ok, Event.t()} | {:error, Error.t()}
  def attach(registry, %Event{} = event, generation) do
    with {:ok, valid_event} <- Event.validate(event),
         true <- Generation.valid?(generation),
         {:ok, active} <- Registry.fetch(registry, generation),
         :ok <- same_runtime(valid_event, active),
         :ok <- compatible(valid_event.subject, active.subject, "logical actor"),
         :ok <-
           compatible(
             valid_event.causality.process_generation,
             active.id,
             "process generation"
           ),
         :ok <-
           compatible_optional(
             valid_event.causality.logical_operation_id,
             active.logical_operation_id,
             "logical operation"
           ) do
      valid_event
      |> Map.put(:subject, active.subject)
      |> Map.update!(:causality, fn causality ->
        causality
        |> Map.put(:process_generation, active.id)
        |> maybe_put_operation(active.logical_operation_id)
      end)
      |> Event.validate()
    else
      false -> invalid("process generation handle is invalid")
      error -> error
    end
  end

  def attach(_registry, _event, _generation),
    do: invalid("identity can only attach to an event")

  @spec relation(Generation.t(), Generation.t()) :: relations()
  def relation(%Generation{} = left, %Generation{} = right) do
    cond do
      not Generation.valid?(left) or not Generation.valid?(right) ->
        unknown_relations()

      left.node != right.node ->
        %{
          physical: :different,
          process_generation: :different,
          logical_actor: :unknown,
          logical_operation: :unknown
        }

      left.boot_id != right.boot_id ->
        %{
          physical: :unknown,
          process_generation: :different,
          logical_actor: :unknown,
          logical_operation: :unknown
        }

      true ->
        %{
          physical: compare({left.node, left.pid}, {right.node, right.pid}),
          process_generation: compare(left.id, right.id),
          logical_actor: compare(left.subject, right.subject),
          logical_operation:
            compare_optional(left.logical_operation_id, right.logical_operation_id)
        }
    end
  end

  def relation(_left, _right), do: unknown_relations()

  defp same_runtime(%Event{node: node, boot_id: boot_id}, %Generation{
         node: node,
         boot_id: boot_id
       }),
       do: :ok

  defp same_runtime(_event, _generation),
    do: invalid("event and process generation belong to different runtimes")

  defp compatible(nil, _declared, _layer), do: :ok
  defp compatible(value, value, _layer), do: :ok

  defp compatible(_existing, _declared, layer),
    do: invalid("event contains conflicting #{layer} evidence")

  defp compatible_optional(_existing, nil, _layer), do: :ok
  defp compatible_optional(existing, declared, layer), do: compatible(existing, declared, layer)

  defp maybe_put_operation(causality, nil), do: causality

  defp maybe_put_operation(causality, operation_id),
    do: Map.put(causality, :logical_operation_id, operation_id)

  defp compare(value, value), do: :same
  defp compare(_left, _right), do: :different

  defp compare_optional(nil, _right), do: :unknown
  defp compare_optional(_left, nil), do: :unknown
  defp compare_optional(left, right), do: compare(left, right)

  defp unknown_relations do
    %{
      physical: :unknown,
      process_generation: :unknown,
      logical_actor: :unknown,
      logical_operation: :unknown
    }
  end

  defp invalid(message), do: {:error, Error.new(:invalid_identity, message)}
end
