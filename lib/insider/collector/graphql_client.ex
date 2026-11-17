defmodule Insider.Collector.GraphqlClient do
  @moduledoc false

  # The client of the request an Absinthe operation runs in, for its
  # `graphql.client` (rich capture only). Absinthe's operation metadata
  # carries no conn, so while a rich session records
  # `absinthe.execute.operation.stop`, a handler on Phoenix's endpoint start
  # remembers the request's client in the request process (one
  # process-dictionary key), already bounded and credential-masked, and the
  # endpoint's stop or exception forgets it. An operation outside an
  # endpoint request (a test, a channel) has no client. With the client's
  # user agent only on the request span, tying an operation to its client
  # took several times longer.
  #
  # A wrong client is worse than none. Each collection has its own
  # generation, and a remembered client counts only for the generation
  # that remembered it: when a collection stops between a request's start
  # and stop, the stop is never seen, and a later collection does not take
  # that request's client for its own operations.

  alias Insider.Collector.RequestTiming

  @key :"$insider_graphql_client"
  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :endpoint, :exception]
  ]

  @doc "A new collection generation."
  @spec generation() :: reference()
  def generation, do: make_ref()

  @doc "Attaches the endpoint handler for `generation`, under an id derived from the collector's."
  @spec attach(term(), reference()) :: :ok | {:error, term()}
  def attach(handler_id, generation) do
    case :telemetry.attach_many(id(handler_id), @events, &__MODULE__.handle_event/4, generation) do
      {:error, :already_exists} ->
        :ok = :telemetry.detach(id(handler_id))
        :telemetry.attach_many(id(handler_id), @events, &__MODULE__.handle_event/4, generation)

      result ->
        result
    end
  end

  @doc "Detaches the endpoint handler; detaching twice is fine."
  @spec detach(term()) :: :ok
  def detach(handler_id) do
    _result = :telemetry.detach(id(handler_id))
    :ok
  end

  defp id(handler_id), do: {__MODULE__, handler_id}

  @doc false
  @spec handle_event([atom()], map(), map(), reference()) :: :ok
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: %{} = conn}, generation) do
    client =
      RequestTiming.client(user_agent(Map.get(conn, :req_headers)), Map.get(conn, :remote_ip))

    _previous = Process.put(@key, {generation, client})
    :ok
  rescue
    _error -> forget()
  end

  def handle_event([:phoenix, :endpoint, _stop_or_exception], _measurements, _metadata, _gen),
    do: forget()

  defp forget do
    _previous = Process.delete(@key)
    :ok
  end

  defp user_agent(headers) when is_list(headers) do
    Enum.find_value(Enum.take(headers, 64), fn
      {"user-agent", value} -> value
      _other -> nil
    end)
  end

  defp user_agent(_headers), do: nil

  @doc """
  The current request's client as `generation` remembered it, or `nil`:
  outside an endpoint request, or remembered by another collection.
  """
  @spec current(reference() | nil) :: map() | nil
  def current(generation) when is_reference(generation) do
    case Process.get(@key) do
      {^generation, client} -> client
      _none_or_stale -> nil
    end
  end

  def current(_generation), do: nil
end
