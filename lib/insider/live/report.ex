defmodule Insider.Live.Report do
  @moduledoc false

  # An agent's report about Insider itself: a bug, a difference between the
  # welcome document and observed behaviour, a missing capability, or
  # confusing output. The record carries the agent's validated category and
  # message plus fixed context the reporter fills in, never event payloads or
  # option values. `put/2` is the bounded, deduplicating queue rule shared by
  # the in-node queue (`Insider.Live.Reports`) and the observer's JSONL queue
  # in the Lab: a report with an already queued fingerprint is counted, not
  # stored twice, and the oldest report is evicted beyond the bound.

  alias Insider.Event.Canonical
  alias Insider.Live.Options

  @schema "insider.live-report/v1"
  @repository "hiivemarkets/insider"
  @max_reports 100
  @fingerprint_hex 16
  @timestamp ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
  # `last_operation` and `last_error_code` are the last call to the target
  # (or, in the node, the last `Insider.Live` call); `last_local_operation`
  # and `last_local_error_code` are the observer's last failure that never
  # reached a target, such as a usage error. The node has no local failures.
  # `session` is the live session the report is about: the observer's
  # explicit `--session`, else the session of its last target command. The
  # node leaves it `nil`.
  @context_keys [
    "environment",
    "insider_commit",
    "insider_version",
    "last_error_code",
    "last_local_error_code",
    "last_local_operation",
    "last_operation",
    "node",
    "session",
    "transport",
    "welcome_hash"
  ]
  # Context keys added after the first record format, in the order they
  # were added; an older record is upgraded with them as `nil`.
  @added_keys ["last_local_error_code", "last_local_operation", "session"]
  @record_keys [
    "category",
    "context",
    "count",
    "fingerprint",
    "first_reported_at",
    "last_reported_at",
    "message",
    "schema"
  ]

  @type t :: %{String.t() => term()}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec max_reports() :: pos_integer()
  def max_reports, do: @max_reports

  @spec context_keys() :: [String.t()]
  def context_keys, do: @context_keys

  @doc "Where submitted reports become issues."
  @spec repository() :: String.t()
  def repository, do: @repository

  @doc """
  The host's submission setting: `"github"` when
  `config :insider, :live_report_submission, :github` allows the observer to
  file reports upstream without `--confirm`, else `"manual"`.
  """
  @spec submission() :: String.t()
  def submission do
    if Application.get_env(:insider, :live_report_submission) == :github,
      do: "github",
      else: "manual"
  end

  @doc """
  Builds a record from a validated report and the reporter's context. Only
  the fixed context keys are kept; a missing one is `nil`.
  """
  @spec new(%{category: String.t(), message: String.t()}, map(), DateTime.t()) :: t()
  def new(%{category: category, message: message}, context, now) do
    at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      "schema" => @schema,
      "fingerprint" => fingerprint(category, message),
      "category" => category,
      "message" => message,
      "context" => Map.new(@context_keys, &{&1, context_value(Map.get(context, &1))}),
      "count" => 1,
      "first_reported_at" => at,
      "last_reported_at" => at
    }
  end

  # Context values are short identifiers; anything else is dropped rather
  # than carried into a report that may leave the machine.
  defp context_value(value) when is_binary(value) and byte_size(value) <= 256, do: value
  defp context_value(_value), do: nil

  @doc """
  The deduplication key: the category and the message with case and
  whitespace runs normalised. Context is excluded, so the same report from
  another node, version or operation has the same fingerprint.
  """
  @spec fingerprint(String.t(), String.t()) :: String.t()
  def fingerprint(category, message) do
    normalized = message |> String.downcase() |> String.split() |> Enum.join(" ")
    binary_part(Canonical.sha256([category, normalized]), 0, @fingerprint_hex)
  end

  @doc """
  Adds `record` to `queue` (oldest first). A queued fingerprint is counted
  and moved to the end with the newer context and time. Returns the new queue
  and what happened.
  """
  @spec put([t()], t()) :: {[t()], %{String.t() => term()}}
  def put(queue, %{"fingerprint" => fingerprint} = record) do
    {queue, record, duplicate} =
      case Enum.split_with(queue, &(&1["fingerprint"] == fingerprint)) do
        {[existing | _], rest} -> {rest, merge(existing, record), true}
        {[], rest} -> {rest, record, false}
      end

    queue = queue ++ [record]
    evicted = max(length(queue) - @max_reports, 0)
    queue = Enum.drop(queue, evicted)

    {queue,
     %{
       "report" => record,
       "duplicate" => duplicate,
       "evicted" => evicted,
       "queued" => length(queue),
       "queue_max" => @max_reports
     }}
  end

  # Records merged from different clocks (a node and its observer) keep the
  # earliest first time and the latest last time. Both are second-precision
  # UTC ISO 8601 strings of fixed width (`new/3` writes them and `record?/1`
  # admits nothing else), which order lexically.
  defp merge(existing, record) do
    %{
      record
      | "count" => existing["count"] + record["count"],
        "first_reported_at" => min(existing["first_reported_at"], record["first_reported_at"]),
        "last_reported_at" => max(existing["last_reported_at"], record["last_reported_at"])
    }
  end

  @doc """
  Whether a decoded value is a well-formed record: the exact key sets, a
  category and message that `Insider.Live.Options.report/1` accepts
  unchanged, the fingerprint they produce, ordered ISO 8601 timestamps, a
  positive count, and context values that are `nil` or short strings.
  """
  @spec record?(term()) :: boolean()
  def record?(
        %{
          "schema" => @schema,
          "category" => category,
          "message" => message,
          "fingerprint" => fingerprint,
          "context" => context,
          "count" => count,
          "first_reported_at" => first,
          "last_reported_at" => last
        } = value
      )
      when is_map(context) and is_integer(count) and count > 0 do
    value |> Map.keys() |> Enum.sort() == @record_keys and
      context |> Map.keys() |> Enum.sort() == @context_keys and
      Enum.all?(context, fn {_key, item} -> item == context_value(item) end) and
      Options.report(%{"category" => category, "message" => message}) ==
        {:ok, %{category: category, message: message}} and
      fingerprint == fingerprint(category, message) and ordered?(first, last)
  end

  def record?(_value), do: false

  @doc """
  Adds the context keys introduced since a record was written (the local
  failure keys, then `session`), as `nil`, so `record?/1` accepts it; any
  other value is returned unchanged.
  """
  @spec upgrade(term()) :: term()
  def upgrade(%{"context" => context} = record) when is_map(context) do
    missing = @added_keys -- Map.keys(context)

    if Enum.sort(Map.keys(context) ++ missing) == @context_keys,
      do: %{record | "context" => Map.merge(context, Map.new(missing, &{&1, nil}))},
      else: record
  end

  def upgrade(value), do: value

  # Timestamps must be exactly the second-precision UTC form `new/3` writes
  # (`YYYY-MM-DDTHH:MM:SSZ`, no fraction or offset), and first must not be
  # after last as instants. Only that fixed-width form orders lexically,
  # which `merge/2` relies on.
  defp ordered?(first, last) when is_binary(first) and is_binary(last) do
    with true <- String.match?(first, @timestamp) and String.match?(last, @timestamp),
         {:ok, first_at, 0} <- DateTime.from_iso8601(first),
         {:ok, last_at, 0} <- DateTime.from_iso8601(last) do
      DateTime.compare(first_at, last_at) != :gt
    else
      _invalid -> false
    end
  end

  defp ordered?(_first, _last), do: false
end
