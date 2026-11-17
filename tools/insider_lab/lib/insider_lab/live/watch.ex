defmodule Insider.Lab.Live.Watch do
  @moduledoc false

  # `watch`: subscribe this observer process to a live session and report each
  # pushed batch until SIGTERM (or a stop message), the `--for` deadline, the
  # `--max-events` budget, the end of the session, or the loss of the target.
  # Subscriptions do not renew the lease, so the watcher renews it at a third
  # of the lease. Leaving always unsubscribes when the target is still
  # connected; when it is not, the target's own monitor of the subscriber
  # drops it.
  #
  # The target enforces the event budget (`"max_events"`), so the batches
  # never carry more events than it allows and their cursors stay exact: the
  # `stopped` line's `next_cursor` is where a later watch or read resumes.

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Observer
  alias Insider.Lab.Live.Watch.Signals

  @stop {:insider_live_watch, :stop}
  @renew {:insider_live_watch, :renew}
  @deadline {:insider_live_watch, :deadline}
  @default_lease_ms 30_000
  @minimum_renew_ms 100

  @type emit :: (String.t(), map() -> :ok | {:error, term()})
  @type outcome ::
          {:stopped, map()}
          | {:exit, non_neg_integer()}
          | {:target_error, map()}
          | Observer.failure()

  @doc "The message that ends a running watch as if it had received SIGTERM."
  @spec stop_message() :: {:insider_live_watch, :stop}
  def stop_message, do: @stop

  @doc """
  Watches `session` with the `subscribe/3` options (`"view"`, `"cursor"`,
  `"max_events"`). `for_ms:` ends the watch after that many milliseconds.
  """
  @spec run(node(), String.t(), pos_integer(), emit(), map(), keyword()) :: outcome()
  def run(node, session, timeout_ms, emit, options \\ %{}, controls \\ []) do
    with {:ok, status} <- CLI.live_result(node, :status, [session], timeout_ms) do
      true = Node.monitor(node, true)

      try do
        with {:ok, subscription} <- subscribe(node, session, options, timeout_ms) do
          stream = %{
            node: node,
            session: session,
            timeout_ms: timeout_ms,
            emit: emit,
            interval: renew_interval(status),
            max_events: options["max_events"],
            events: 0,
            next_cursor: subscription["cursor"]
          }

          watch(stream, status, subscription, Keyword.get(controls, :for_ms))
        end
      after
        Node.monitor(node, false)
      end
    end
  end

  defp watch(stream, status, subscription, for_ms) do
    :ok = Signals.install(self())
    # Renew at once: the session may be attached close to expiry, and neither
    # `status/1` nor `subscribe/2` renews it. Later renewals follow from the
    # full lease that this renewal restores.
    timer = Process.send_after(self(), @renew, 0)
    deadline = for_ms && Process.send_after(self(), @deadline, for_ms)

    try do
      case stream.emit.("subscribed", %{"result" => status, "subscription" => subscription}) do
        :ok -> loop(stream)
        {:error, _reason} -> {:exit, 70}
      end
    after
      Signals.restore()
      cancel(timer, @renew)
      if deadline, do: cancel(deadline, @deadline)
      unsubscribe(stream.node, stream.session, stream.timeout_ms)
    end
  end

  defp loop(%{session: session, node: node} = stream) do
    receive do
      {:insider_live_events, ^session, batch} when is_map(batch) ->
        delivered(stream, batch)

      {:nodedown, ^node} ->
        {:error, "target_down", %{}}

      @stop ->
        stopped(stream, %{"reason" => "interrupted"})

      @deadline ->
        stopped(stream, %{"reason" => "duration"})

      @renew ->
        case CLI.live_result(node, :renew, [session], stream.timeout_ms) do
          {:ok, _renewed} ->
            Process.send_after(self(), @renew, stream.interval)
            loop(stream)

          # `session_terminal`, or `environment_denied` carrying the revoked
          # session's record: the session has ended.
          {:target_error, %{"code" => "session_terminal"} = error} ->
            final_batch(stream, error)

          {:target_error, %{"code" => "environment_denied", "status" => %{}} = error} ->
            final_batch(stream, error)

          failure ->
            failure
        end
    end
  end

  # A renewal can race the end of the session. The owner still sends every
  # subscriber one last batch, so keep reporting batches (bounded wait) until
  # it arrives instead of dropping its events; without it, report the ended
  # state the target returned.
  defp final_batch(%{session: session} = stream, error) do
    receive do
      {:insider_live_events, ^session, batch} when is_map(batch) ->
        case {emitted(stream, batch), batch["state"]} do
          {{:ok, stream}, "running"} -> final_batch(stream, error)
          {{:ok, stream}, state} -> session_ended(stream, state)
          {{:error, _reason}, _state} -> {:exit, 70}
        end
    after
      stream.timeout_ms ->
        session_ended(stream, get_in(error, ["status", "state"]))
    end
  end

  defp delivered(stream, batch) do
    case {emitted(stream, batch), batch["state"]} do
      {{:ok, stream}, "running"} -> if spent?(stream), do: spent(stream), else: loop(stream)
      {{:ok, stream}, state} -> session_ended(stream, state)
      {{:error, _reason}, _state} -> {:exit, 70}
    end
  end

  defp spent?(%{max_events: nil}), do: false
  defp spent?(stream), do: stream.events >= stream.max_events

  defp emitted(stream, batch) do
    with :ok <- stream.emit.("batch", %{"result" => batch}) do
      {:ok,
       %{
         stream
         | events: stream.events + length(Map.get(batch, "events", [])),
           next_cursor: Map.get(batch, "next_cursor", stream.next_cursor)
       }}
    end
  end

  defp spent(stream), do: stopped(stream, %{"reason" => "max_events"})

  defp session_ended(stream, state),
    do: stopped(stream, %{"reason" => "session_ended", "state" => state})

  # Every ending reports how many events were emitted and where to resume.
  defp stopped(stream, fields),
    do:
      {:stopped,
       Map.merge(fields, %{"events" => stream.events, "next_cursor" => stream.next_cursor})}

  defp subscribe(node, session, options, timeout_ms) do
    case Observer.call(node, Insider.Live, :subscribe, [session, self(), options], timeout_ms) do
      {:ok, {:ok, subscription}} when is_map(subscription) -> {:ok, subscription}
      {:ok, {:error, error}} when is_map(error) -> {:target_error, error}
      {:ok, _other} -> {:error, "unexpected_response", %{"function" => "subscribe"}}
      failure -> failure
    end
  end

  defp unsubscribe(node, session, timeout_ms) do
    if node in Node.list(:connected) do
      _result = Observer.call(node, Insider.Live, :unsubscribe, [session, self()], timeout_ms)
    end

    :ok
  end

  defp renew_interval(status) do
    lease =
      case status do
        %{"lease_ms" => lease} when is_integer(lease) and lease > 0 -> lease
        %{"lease_remaining_ms" => lease} when is_integer(lease) and lease > 0 -> lease
        _status -> @default_lease_ms
      end

    max(div(lease, 3), @minimum_renew_ms)
  end

  defp cancel(timer, message) do
    _remaining = Process.cancel_timer(timer)

    receive do
      ^message -> :ok
    after
      0 -> :ok
    end
  end
end
