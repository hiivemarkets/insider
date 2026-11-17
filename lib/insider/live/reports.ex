defmodule Insider.Live.Reports do
  @moduledoc false

  # The in-node report queue for callers inside the node, such as a Tidewave
  # `project_eval` or an `:erpc` call. Production code may not write files
  # (`scripts/verify-production-artifact`), so the queue is bounded memory
  # held by this process and is lost when the node stops;
  # `mix insider.live reports --node …` copies it into the observer's JSONL
  # queue. It starts beside `Insider.Live.Owner` where live observation is
  # allowed and does not depend on it, so a wedged owner can still be reported.
  #
  # Requests follow the owner's discipline: a caller takes one of a fixed
  # number of admission slots before its message is queued (`busy`
  # otherwise) and carries an absolute deadline; a request handled after its
  # deadline is refused before it changes the queue, so a caller that saw
  # `timeout` never leaves a report behind. The last public `Insider.Live`
  # operation and its error code, which every report carries as context, are
  # one overwritten row in a public ETS table owned by this process, so
  # tracking a call never queues a message.

  use GenServer

  alias Insider.Collector.Admission
  alias Insider.Live.Environment
  alias Insider.Live.Report
  alias Insider.Live.Revision
  alias Insider.Live.Welcome

  @admitted_calls_max 8
  @call_timeout_ms 2_000
  @outer_margin_ms 200

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_argument), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec admitted_calls_max() :: pos_integer()
  def admitted_calls_max, do: @admitted_calls_max

  @doc "Records the outcome of a public operation; a no-op when not running."
  @spec record_call(String.t(), term()) :: :ok
  def record_call(operation, result) do
    code =
      case result do
        {:error, %{"code" => code}} -> code
        _success -> nil
      end

    :ets.insert(__MODULE__, {:last_call, operation, code})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec report(%{category: String.t(), message: String.t()}) ::
          {:ok, map()} | {:error, :unavailable | :busy | :timeout}
  def report(report), do: call({:report, report})

  @spec list() :: {:ok, map()} | {:error, :unavailable | :busy | :timeout}
  def list, do: call(:list)

  defp call(request) do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, admission} <- admission(pid) do
      case Admission.acquire(admission, @admitted_calls_max) do
        :ok ->
          deadline = System.monotonic_time(:millisecond) + @call_timeout_ms
          message = {:admitted, admission, deadline, request}
          GenServer.call(pid, message, @call_timeout_ms + @outer_margin_ms)

        :overloaded ->
          {:error, :busy}
      end
    else
      _absent -> {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  # As in `Insider.Live.Owner.admission/1`: the spec keeps the admission
  # opaque to callers.
  @spec admission(pid()) :: {:ok, Admission.t()} | :error
  defp admission(pid) do
    case :persistent_term.get({__MODULE__, pid}, :missing) do
      %Admission{} = admission -> {:ok, admission}
      _missing -> :error
    end
  end

  @impl GenServer
  def init(nil) do
    _table = :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    admission = Admission.new()
    :persistent_term.put({__MODULE__, self()}, admission)
    {:ok, %{admission: admission, queue: []}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
  end

  @impl GenServer
  def handle_call(
        {:admitted, admission, deadline, request},
        _from,
        %{admission: admission} = state
      )
      when is_integer(deadline) do
    Admission.release(admission)

    if System.monotonic_time(:millisecond) >= deadline,
      do: {:reply, {:error, :timeout}, state},
      else: handle_request(request, state)
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unavailable}, state}

  defp handle_request({:report, report}, state) do
    record = Report.new(report, context(), DateTime.utc_now())
    {queue, receipt} = Report.put(state.queue, record)

    receipt =
      Map.merge(receipt, %{"schema" => "insider.live-report-receipt/v1", "queue" => "node"})

    {:reply, {:ok, receipt}, %{state | queue: queue}}
  end

  defp handle_request(:list, state) do
    {:reply,
     {:ok,
      %{
        "schema" => "insider.live-reports/v1",
        "queue" => "node",
        "queue_max" => Report.max_reports(),
        "submission" => Report.submission(),
        "reports" => state.queue
      }}, state}
  end

  defp context do
    {operation, code} =
      case :ets.lookup(__MODULE__, :last_call) do
        [{:last_call, operation, code}] -> {operation, code}
        [] -> {nil, nil}
      end

    %{
      "transport" => "node",
      "insider_version" => Welcome.version(),
      "insider_commit" => Revision.commit(),
      "welcome_hash" => Welcome.hash(),
      "node" => Atom.to_string(node()),
      "environment" => Atom.to_string(Environment.resolve().environment),
      "last_operation" => operation,
      "last_error_code" => code
    }
  end
end
