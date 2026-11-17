defmodule Insider.Lab.Live.Otlp do
  @moduledoc false

  # `otlp-receive`: an OTLP/HTTP trace receiver on a loopback port of the
  # observer's machine. Each export's spans are decoded here and handed to
  # the target's `Insider.Live.ingest_spans/2`, which turns them into
  # `otel.span` events of the running session under the session's own span
  # contract and masking. The receiver reports one line per export (span
  # counts and trace ids, never span content or resource values such as
  # `service.name`, which only the target masks) until SIGTERM, `--for`, the
  # end of the session, or the loss of the target, renewing the session's
  # lease at a third of it meanwhile. It is bound to one session id: the
  # target refuses its spans once that session has ended, and it stops.
  #
  # Connections are served one at a time by one acceptor process, which
  # bounds the receiver's memory to one request (`Http.max_body_bytes/0`).
  # The acceptor hands each report to the output loop and waits for it to be
  # written before it accepts the next connection, so a slow output consumer
  # holds back clients (in the listen backlog, then refused by the kernel)
  # instead of queueing reports. OTLP exporters send a batch every few
  # seconds and retry.

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Otlp.Decode
  alias Insider.Lab.Live.Otlp.Http
  alias Insider.Lab.Live.Watch.Signals

  @renew {:insider_live_otlp, :renew}
  @renew_retry {:insider_live_otlp, :renew_retry}
  @deadline {:insider_live_otlp, :deadline}
  @request_timeout_ms 10_000
  @max_spans_per_call 512
  @max_reported_traces 32
  @default_lease_ms 30_000
  @minimum_renew_ms 100
  # A renewal retry is sent at least this long before the receiver's
  # estimate of the lease deadline, room for the call to reach the owner.
  @lease_margin_ms 250
  # What `Insider.Live.ingest_spans/2` counts per call, summed per export.
  @counts ["accepted", "rejected", "filtered", "shed", "duplicate"]

  @type emit :: (String.t(), map() -> :ok | {:error, term()})
  @type options :: %{
          required(:bind) => :inet.ip_address(),
          required(:port) => :inet.port_number(),
          optional(:for_ms) => pos_integer() | nil
        }

  @doc """
  Receives OTLP trace exports for `session` on `options.bind:options.port`
  until stopped; see the module comment. Port `0` picks a free port, which
  the `listening` line reports.
  """
  @spec run(node(), String.t(), pos_integer(), emit(), options()) ::
          {:stopped, map()}
          | {:exit, non_neg_integer()}
          | {:target_error, map()}
          | Insider.Lab.Live.Observer.failure()
  def run(node, session, timeout_ms, emit, options) do
    asked_at = System.monotonic_time(:millisecond)

    with {:ok, status} <- CLI.live_result(node, :status, [session], timeout_ms),
         {:ok, _probe} <- CLI.live_result(node, :ingest_spans, [session, []], timeout_ms),
         {:ok, listen} <- listen(options) do
      true = Node.monitor(node, true)

      try do
        receive_exports(
          node,
          session,
          timeout_ms,
          emit,
          listen,
          {status, asked_at},
          options[:for_ms]
        )
      after
        Node.monitor(node, false)
        :gen_tcp.close(listen)
      end
    end
  end

  defp listen(%{bind: bind, port: port}) do
    family = if tuple_size(bind) == 8, do: :inet6, else: :inet

    case :gen_tcp.listen(port, [
           :binary,
           family,
           ip: bind,
           active: false,
           reuseaddr: true,
           backlog: 16
         ]) do
      {:ok, listen} -> {:ok, listen}
      {:error, :eaddrinuse} -> {:error, "port_unavailable", %{"reason" => "in_use"}}
      {:error, _reason} -> {:error, "port_unavailable", %{"reason" => "listen_failed"}}
    end
  end

  defp receive_exports(node, session, timeout_ms, emit, listen, {status, asked_at}, for_ms) do
    {:ok, {address, port}} = :inet.sockname(listen)
    receiver = self()

    {acceptor, monitor} =
      spawn_monitor(fn -> accept(listen, receiver, node, session, timeout_ms) end)

    :ok = Signals.install(self())
    # Renew at once, as watch does: neither status/1 nor the probe renews.
    timer = Process.send_after(self(), @renew, 0)
    deadline = for_ms && Process.send_after(self(), @deadline, for_ms)

    state = %{
      node: node,
      session: session,
      timeout_ms: timeout_ms,
      emit: emit,
      acceptor: monitor,
      interval: renew_interval(status),
      lease_deadline: lease_deadline(asked_at, status, %{interval: renew_interval(status)}),
      totals: Map.merge(Map.new(@counts, &{&1, 0}), %{"exports" => 0, "refused" => 0})
    }

    try do
      listening = %{
        "result" => status,
        "endpoint" => endpoint(address, port),
        "port" => port
      }

      case emit.("listening", listening) do
        :ok -> loop(state)
        {:error, _reason} -> {:exit, 70}
      end
    after
      Process.demonitor(monitor, [:flush])
      Process.exit(acceptor, :kill)
      Signals.restore()
      cancel(timer, @renew)
      if deadline, do: cancel(deadline, @deadline)
    end
  end

  defp endpoint({_a, _b, _c, _d} = address, port),
    do: "http://#{:inet.ntoa(address)}:#{port}/v1/traces"

  defp endpoint(address, port), do: "http://[#{:inet.ntoa(address)}]:#{port}/v1/traces"

  defp loop(%{node: node, acceptor: acceptor} = state) do
    receive do
      {:otlp_report, from, reference, {:export, fields}} ->
        totals = add_counts(state.totals, fields)
        state = %{state | totals: Map.update!(totals, "exports", &(&1 + 1))}
        emit(state, "export", fields, {from, reference})

      {:otlp_report, from, reference, {:refused, fields}} ->
        state = %{state | totals: Map.update!(state.totals, "refused", &(&1 + 1))}
        emit(state, "refused", fields, {from, reference})

      {:otlp_report, _from, _reference, {:target_error, %{"code" => "session_terminal"} = error}} ->
        stopped(state, %{
          "reason" => "session_ended",
          "state" => get_in(error, ["status", "state"])
        })

      {:otlp_report, _from, _reference, {:target_error, error}} ->
        {:target_error, error}

      {:otlp_report, _from, _reference, {:failure, failure}} ->
        failure

      {:nodedown, ^node} ->
        {:error, "target_down", %{}}

      {:DOWN, ^acceptor, :process, _pid, _reason} ->
        {:error, "observer_failed", %{}}

      # `Watch.stop_message/0`, which `Signals` sends on SIGTERM.
      {:insider_live_watch, :stop} ->
        stopped(state, %{"reason" => "interrupted"})

      @deadline ->
        stopped(state, %{"reason" => "duration"})

      @renew ->
        renew(state, :scheduled)

      @renew_retry ->
        renew(state, :retry)
    end
  end

  # Renewals are synchronous, so at most one is in flight, and only one
  # renewal timer is ever pending. A scheduled renewal that fails
  # transiently (the owner is busy, possibly with this receiver's own
  # ingest, or it timed out) is retried once, after a jittered backoff of a
  # quarter to a half of the interval, the delay capped to leave
  # `@lease_margin_ms` before the receiver's conservative estimate of the
  # lease deadline, or none when less remains (a scheduling rule: timers
  # can fire late). If the retry fails too, the
  # next renewal is the scheduled one. At most two renewal calls per
  # interval, never a loop against a saturated owner; the lease survives
  # when the owner can answer the scheduled renewal or its retry in time.
  defp renew(%{node: node, session: session} = state, attempt) do
    sent_at = System.monotonic_time(:millisecond)

    case CLI.live_result(node, :renew, [session], state.timeout_ms) do
      {:ok, renewed} ->
        Process.send_after(self(), @renew, state.interval)
        loop(%{state | lease_deadline: lease_deadline(sent_at, renewed, state)})

      {:target_error, %{"code" => "session_terminal"} = error} ->
        stopped(state, %{
          "reason" => "session_ended",
          "state" => get_in(error, ["status", "state"])
        })

      {:target_error, %{"code" => "environment_denied", "status" => %{}} = error} ->
        stopped(state, %{
          "reason" => "session_ended",
          "state" => get_in(error, ["status", "state"])
        })

      failure ->
        if transient?(failure) do
          schedule_after_failure(state, attempt)
          loop(state)
        else
          failure
        end
    end
  end

  defp transient?({:target_error, %{"code" => code}}), do: code in ["timeout", "busy"]
  defp transient?({:error, "rpc_timeout", _details}), do: true
  defp transient?(_failure), do: false

  defp schedule_after_failure(state, :scheduled) do
    quarter = max(div(state.interval, 4), 1)
    backoff = quarter + :rand.uniform(quarter)
    left = state.lease_deadline - @lease_margin_ms - System.monotonic_time(:millisecond)
    Process.send_after(self(), @renew_retry, max(min(backoff, left), 0))
  end

  defp schedule_after_failure(state, :retry),
    do: Process.send_after(self(), @renew, state.interval)

  # The lease ends no later than its remaining time counted from before the
  # call that reported it, so the estimate is never later than the owner's.
  defp lease_deadline(sent_at, %{"lease_remaining_ms" => remaining}, _state)
       when is_integer(remaining) and remaining >= 0,
       do: sent_at + remaining

  defp lease_deadline(sent_at, _result, state), do: sent_at + 3 * state.interval

  # The acceptor accepts its next connection only after this write.
  defp emit(state, kind, fields, {from, reference}) do
    case state.emit.(kind, fields) do
      :ok ->
        send(from, {:otlp_ack, reference})
        loop(state)

      {:error, _reason} ->
        {:exit, 70}
    end
  end

  defp stopped(state, fields), do: {:stopped, Map.merge(fields, state.totals)}

  ## Acceptor: one connection at a time, one report in flight.

  defp accept(listen, receiver, node, session, timeout_ms) do
    watch = Process.monitor(receiver)
    accept_loop(listen, {receiver, watch}, node, session, timeout_ms)
  end

  defp accept_loop(listen, receiver, node, session, timeout_ms) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        socket |> serve(node, session, timeout_ms) |> report(receiver)
        accept_loop(listen, receiver, node, session, timeout_ms)

      {:error, :closed} ->
        :ok

      # A connection that failed before it was accepted (reset, or the
      # system ran out of descriptors for a moment) does not end the
      # receiver.
      {:error, _reason} ->
        accept_loop(listen, receiver, node, session, timeout_ms)
    end
  end

  # Waits until the output loop has written the report. A terminal report
  # is never acknowledged: the loop ends, and its cleanup kills this process.
  defp report(message, {receiver, watch}) do
    reference = make_ref()
    send(receiver, {:otlp_report, self(), reference, message})

    receive do
      {:otlp_ack, ^reference} -> :ok
      {:DOWN, ^watch, :process, _pid, _reason} -> exit(:normal)
    end
  end

  defp serve(socket, node, session, timeout_ms) do
    with {:ok, format, body} <- Http.read(socket, @request_timeout_ms),
         {:ok, decoded} <- decode(format, body) do
      forward(socket, node, session, timeout_ms, format, decoded)
    else
      {:error, status, reason} ->
        Http.respond(socket, status, :text, reason)
        {:refused, %{"status" => status, "reason" => reason}}
    end
  end

  defp decode(format, body) do
    case apply(Decode, format, [body]) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, 400, reason}
    end
  end

  defp forward(socket, node, session, timeout_ms, format, decoded) do
    case ingest(node, session, timeout_ms, decoded.spans) do
      {:ok, counts} ->
        rejected = counts["rejected"] + decoded.rejected
        message = if rejected > 0, do: "spans outside the span contract were rejected", else: ""
        Http.respond(socket, 200, format, Http.export_response(format, rejected, message))
        {:export, Map.merge(counts, %{"rejected" => rejected, "traces" => traces(decoded.spans)})}

      {:timeout, counts} ->
        # Outcome unknown twice: the exporter may retry (ingest is
        # idempotent), and the receiver keeps running and says so.
        Http.respond(socket, 503, :text, "target_timeout")

        {:refused,
         %{"status" => 503, "reason" => "target_timeout", "accepted" => counts["accepted"]}}

      {:busy, counts} ->
        # The owner's admission was full: transient, and refused before the
        # chunk ran, so the exporter retries later and the receiver keeps
        # running. Chunks before it were recorded; the retry's duplicates
        # are skipped while their ids are in the collector's seen-set.
        Http.respond(socket, 503, :text, "target_busy")

        {:refused,
         %{"status" => 503, "reason" => "target_busy", "accepted" => counts["accepted"]}}

      {:target_error, error} ->
        # The session ended or refused the spans: the exporter must not
        # retry, and the receiver stops.
        message = "the Insider session does not accept spans: " <> to_string(error["code"])
        rejected = length(decoded.spans) + decoded.rejected
        Http.respond(socket, 200, format, Http.export_response(format, rejected, message))
        {:target_error, error}

      failure ->
        # Retryable for the exporter: the target may come back.
        Http.respond(socket, 503, :text, "target_unavailable")
        {:failure, failure}
    end
  end

  # A `timeout` (from the target, or the observer's own call bound) leaves
  # the outcome unknown, so each chunk is retried once: the target's ingest
  # is idempotent per span id while the id is in the collector's bounded
  # seen-set, so the retry skips spans the first attempt recorded.
  defp ingest(node, session, timeout_ms, spans) do
    spans
    |> Enum.chunk_every(@max_spans_per_call)
    |> Enum.reduce_while({:ok, Map.new(@counts, &{&1, 0})}, fn chunk, {:ok, counts} ->
      case ingest_chunk(node, session, timeout_ms, chunk, 1) do
        {:ok, result} -> {:cont, {:ok, add_counts(counts, result)}}
        :timeout -> {:halt, {:timeout, counts}}
        {:target_error, %{"code" => "busy"}} -> {:halt, {:busy, counts}}
        other -> {:halt, other}
      end
    end)
  end

  defp ingest_chunk(node, session, timeout_ms, chunk, retries) do
    result = CLI.live_result(node, :ingest_spans, [session, chunk], timeout_ms)

    cond do
      not outcome_unknown?(result) -> result
      retries > 0 -> ingest_chunk(node, session, timeout_ms, chunk, retries - 1)
      true -> :timeout
    end
  end

  defp outcome_unknown?({:target_error, %{"code" => "timeout"}}), do: true
  defp outcome_unknown?({:error, "rpc_timeout", _details}), do: true
  defp outcome_unknown?(_result), do: false

  defp add_counts(totals, counts),
    do: Map.merge(totals, Map.take(counts, @counts), fn _key, total, count -> total + count end)

  # The traces an export touched, by trace id, with their span counts, so a
  # caller can find the trace a request produced. Trace ids are validated
  # hex; nothing else from the request leaves the target's masking.
  defp traces(spans) do
    spans
    |> Enum.frequencies_by(& &1["trace_id"])
    |> Enum.map(fn {trace_id, count} -> %{"trace_id" => trace_id, "spans" => count} end)
    |> Enum.sort_by(& &1["trace_id"])
    |> Enum.take(@max_reported_traces)
  end

  defp renew_interval(status) do
    lease =
      case status do
        %{"lease_ms" => lease} when is_integer(lease) and lease > 0 -> lease
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
