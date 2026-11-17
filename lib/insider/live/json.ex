defmodule Insider.Live.JSON do
  @moduledoc """
  `Insider.Live` operations that each return one canonical JSON binary.

  A success is `{"ok":...}` and a failure is `{"error":...}`. Object keys are
  sorted and the output has no insignificant whitespace, so it is stable for
  machine-readable transports such as a Tidewave `project_eval` result.

  [Tidewave `project_eval`](docs/live/live-api-and-transports.md#tidewave-project_eval)
  shows how to load Insider into a Phoenix development server and call these
  functions.
  """

  alias Insider.Event.Canonical
  alias Insider.Live

  @doc "See `Insider.Live.capabilities/0`."
  @spec capabilities() :: binary()
  def capabilities, do: encode({:ok, Live.capabilities()})

  @doc "See `Insider.Live.welcome/1`."
  @spec welcome(map()) :: binary()
  def welcome(options \\ %{}) do
    case Live.welcome(options) do
      {:error, _error} = invalid -> encode(invalid)
      document -> encode({:ok, document})
    end
  end

  @doc "See `Insider.Live.discover/1`."
  @spec discover(map()) :: binary()
  def discover(options \\ %{}), do: encode(Live.discover(options))

  @doc "See `Insider.Live.process/1`."
  @spec process(map()) :: binary()
  def process(options), do: encode(Live.process(options))

  @doc "See `Insider.Live.bin_leak/1`."
  @spec bin_leak(map()) :: binary()
  def bin_leak(options \\ %{}), do: encode(Live.bin_leak(options))

  @doc "See `Insider.Live.ports/1`."
  @spec ports(map()) :: binary()
  def ports(options \\ %{}), do: encode(Live.ports(options))

  @doc "See `Insider.Live.alloc/1`."
  @spec alloc(map()) :: binary()
  def alloc(options \\ %{}), do: encode(Live.alloc(options))

  @doc "See `Insider.Live.start/1`."
  @spec start(map()) :: binary()
  def start(options), do: encode(Live.start(options))

  @doc "See `Insider.Live.events_since/3`."
  @spec events_since(String.t(), non_neg_integer() | String.t(), map()) :: binary()
  def events_since(session_id, cursor, options \\ %{}),
    do: encode(Live.events_since(session_id, cursor, options))

  @doc "See `Insider.Live.digest/2`."
  @spec digest(String.t(), map()) :: binary()
  def digest(session_id, options \\ %{}), do: encode(Live.digest(session_id, options))

  @doc "See `Insider.Live.mark/2`."
  @spec mark(String.t(), map()) :: binary()
  def mark(session_id, options), do: encode(Live.mark(session_id, options))

  @doc "See `Insider.Live.marks/2`."
  @spec marks(String.t(), map()) :: binary()
  def marks(session_id, options \\ %{}), do: encode(Live.marks(session_id, options))

  @doc "See `Insider.Live.trace/3`."
  @spec trace(String.t(), String.t(), map()) :: binary()
  def trace(session_id, trace_id, options \\ %{}),
    do: encode(Live.trace(session_id, trace_id, options))

  @doc "See `Insider.Live.baseline/2`."
  @spec baseline(String.t(), map()) :: binary()
  def baseline(session_id, options \\ %{}), do: encode(Live.baseline(session_id, options))

  @doc "See `Insider.Live.mutations/2`."
  @spec mutations(String.t(), map()) :: binary()
  def mutations(session_id, options \\ %{}), do: encode(Live.mutations(session_id, options))

  @doc "See `Insider.Live.changes/2`."
  @spec changes(String.t(), map()) :: binary()
  def changes(session_id, options \\ %{}), do: encode(Live.changes(session_id, options))

  @doc "See `Insider.Live.timeline/2`."
  @spec timeline(String.t(), map()) :: binary()
  def timeline(session_id, options), do: encode(Live.timeline(session_id, options))

  @doc "See `Insider.Live.trends/2`."
  @spec trends(String.t(), map()) :: binary()
  def trends(session_id, options \\ %{}), do: encode(Live.trends(session_id, options))

  @doc "See `Insider.Live.renew/1`."
  @spec renew(String.t()) :: binary()
  def renew(session_id), do: encode(Live.renew(session_id))

  @doc "See `Insider.Live.status/1`."
  @spec status(String.t()) :: binary()
  def status(session_id), do: encode(Live.status(session_id))

  @doc "See `Insider.Live.stop/2`."
  @spec stop(String.t(), map()) :: binary()
  def stop(session_id, options \\ %{}), do: encode(Live.stop(session_id, options))

  @doc "See `Insider.Live.amend/2`."
  @spec amend(String.t(), map()) :: binary()
  def amend(session_id, options), do: encode(Live.amend(session_id, options))

  @doc "See `Insider.Live.handoff_record/1`."
  @spec handoff_record(String.t()) :: binary()
  def handoff_record(session_id), do: encode(Live.handoff_record(session_id))

  @doc "See `Insider.Live.subscribe/3`."
  @spec subscribe(String.t(), pid(), map()) :: binary()
  def subscribe(session_id, pid, options \\ %{}),
    do: encode(Live.subscribe(session_id, pid, options))

  @doc "See `Insider.Live.unsubscribe/2`."
  @spec unsubscribe(String.t(), pid()) :: binary()
  def unsubscribe(session_id, pid), do: encode(Live.unsubscribe(session_id, pid))

  @doc "See `Insider.Live.ingest_spans/2`."
  @spec ingest_spans(String.t(), [map()]) :: binary()
  def ingest_spans(session_id, spans), do: encode(Live.ingest_spans(session_id, spans))

  @doc "See `Insider.Live.report/1`."
  @spec report(map()) :: binary()
  def report(options), do: encode(Live.report(options))

  @doc "See `Insider.Live.reports/0`."
  @spec reports() :: binary()
  def reports, do: encode(Live.reports())

  defp encode({:ok, value}), do: Canonical.encode(%{"ok" => value})
  defp encode({:error, error}), do: Canonical.encode(%{"error" => error})
end
