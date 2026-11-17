defmodule Insider.Test.FaultRerunHost do
  @moduledoc false

  # A fixture host for the fault-and-rerun oracle: an in-memory order store
  # standing in for committed local rows, and workers that open a provider
  # account for an order and add it to a category. Each worker differs only
  # in when it commits the account id locally and whether it sends an
  # idempotency key. Returns are the `:ok | {:error, reason}` a job returns.

  use Agent

  alias Insider.Test.FaultRerunHost.Provider

  def start_link(_options), do: Agent.start_link(fn -> %{orders: %{}, sequence: 0} end)

  @doc "Creates one order with no account and returns it as the fixture."
  def fixture(store) do
    Agent.get_and_update(store, fn state ->
      number = state.sequence + 1
      order_id = "order-#{number}"
      order = %{account: nil, linked: false}

      {%{store: store, order_id: order_id},
       %{state | sequence: number, orders: Map.put(state.orders, order_id, order)}}
    end)
  end

  def order(fixture), do: Agent.get(fixture.store, &Map.fetch!(&1.orders, fixture.order_id))

  @doc "The provider ids committed rows reference, grouped by creating boundary."
  def references(fixture), do: %{account_create: [order(fixture).account]}

  @doc "Commits `changes` to the order row."
  def commit(fixture, changes) do
    Agent.update(fixture.store, fn state ->
      update_in(state, [:orders, fixture.order_id], &Map.merge(&1, changes))
    end)
  end

  @doc """
  Creates the account, adds it to the category, and only then commits the id:
  a failed category call leaves the account unrecorded, and the retry creates
  another.
  """
  def create_then_commit(fixture) do
    case order(fixture) do
      %{account: nil} ->
        with {:ok, %{"id" => id}} <- Provider.create_account(fixture.order_id),
             :ok <- Provider.link(id, "customer_funds") do
          commit(fixture, %{account: id, linked: true})
        end

      _done ->
        :ok
    end
  end

  @doc "Commits the account id before the fallible category call; the retry reuses it."
  def commit_then_link(fixture) do
    order = order(fixture)

    id =
      order.account ||
        with {:ok, %{"id" => id}} <- Provider.create_account(fixture.order_id) do
          commit(fixture, %{account: id})
          id
        end

    cond do
      not is_binary(id) ->
        id

      order.linked ->
        :ok

      true ->
        with :ok <- Provider.link(id, "customer_funds", []), do: commit(fixture, %{linked: true})
    end
  end

  @doc "Like `create_then_commit/1`, but sends the order id as the idempotency key."
  def keyed(fixture) do
    case order(fixture) do
      %{account: nil} ->
        with {:ok, %{"id" => id}} <-
               Provider.create_account(fixture.order_id, idempotency_key: fixture.order_id),
             :ok <- Provider.link(id, "customer_funds") do
          commit(fixture, %{account: id, linked: true})
        end

      _done ->
        :ok
    end
  end

  @doc "Treats a failed category call as done and commits nothing."
  def swallowing(fixture) do
    with {:ok, %{"id" => id}} <- Provider.create_account(fixture.order_id) do
      case Provider.link(id, "customer_funds") do
        :ok -> commit(fixture, %{account: id, linked: true})
        {:error, _reason} -> :ok
      end
    end
  end

  @doc "Makes the provider calls from a task, as a worker that fans out does."
  def in_task(fixture), do: Task.async(fn -> create_then_commit(fixture) end) |> Task.await()

  @doc "Like `keyed/1`, but two tasks send the same create at once."
  def concurrent_keyed(fixture) do
    create = fn ->
      Provider.create_account(fixture.order_id, idempotency_key: fixture.order_id)
    end

    with [{:ok, %{"id" => id}}, {:ok, _same}] <-
           Task.await_many([Task.async(create), Task.async(create)]),
         :ok <- Provider.link(id, "customer_funds") do
      commit(fixture, %{account: id, linked: true})
    end
  end

  @doc "Raises on a failed category call instead of returning the error."
  def raising(fixture) do
    case create_then_commit(fixture) do
      :ok -> :ok
      {:error, _reason} -> raise RuntimeError, "category call failed"
    end
  end

  @doc "Opens `count` accounts, committing only the last."
  def many(fixture, count) do
    ids =
      for _number <- 1..count do
        {:ok, %{"id" => id}} = Provider.create_account(fixture.order_id)
        id
      end

    with :ok <- Provider.link(List.last(ids), "customer_funds") do
      commit(fixture, %{account: List.last(ids), linked: true})
    end
  end
end

defmodule Insider.Test.FaultRerunHost.Provider do
  @moduledoc false

  # A provider client whose every function dispatches to a stub installed by
  # the calling process or one of its `$callers`, as Mimic's private mode
  # does. An unstubbed call raises, the way a test refuses a live call. The
  # default-argument pairs are the shape that let a hand-built recorder for
  # one arity miss calls through the other.

  def stub(__MODULE__, name, fun) when is_atom(name) and is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    Process.put({__MODULE__, name, arity}, fun)
    :ok
  end

  def create_account(owner), do: dispatch(:create_account, [owner])
  def create_account(owner, options), do: dispatch(:create_account, [owner, options])
  def link(account, category), do: dispatch(:link, [account, category])
  def link(account, category, options), do: dispatch(:link, [account, category, options])

  @doc "Thirteen arguments: more than the oracle can stub."
  def wide(a, b, c, d, e, f, g, h, i, j, k, l, m),
    do: dispatch(:wide, [a, b, c, d, e, f, g, h, i, j, k, l, m])

  defp dispatch(name, args) do
    key = {__MODULE__, name, length(args)}

    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid -> stub_in(pid, key) end)
    |> case do
      nil -> raise "unstubbed provider call #{name}/#{length(args)}"
      fun -> apply(fun, args)
    end
  end

  defp stub_in(pid, key) when pid == self(), do: Process.get(key)

  defp stub_in(pid, key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> List.keyfind(dictionary, key, 0, {key, nil}) |> elem(1)
      nil -> nil
    end
  end
end
