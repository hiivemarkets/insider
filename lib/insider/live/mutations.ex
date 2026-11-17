defmodule Insider.Live.Mutations do
  @moduledoc false

  # A compact record of every GraphQL mutation the session saw, kept apart
  # from the Recorder so a flood (of logs, queries, or a request burst)
  # cannot evict what a mutation did. A mutation by another user
  # can be the cause of a change, and the request stream holds it only
  # while it is retained.
  #
  # The owner sweeps raw, redaction-checked Recorder reads (as per-trace
  # retention does) for `absinthe.execute.operation.stop` events whose
  # GraphQL outcome is a mutation, and keeps for each: its receipt, wall
  # time, operation name, result kind, error counts, response typenames,
  # trace id, process, the client's user agent (`graphql.client`, rich
  # capture only), and the ids among its arguments (fields named `id` or
  # ending in `Id`/`_id`, from the rich `graphql_arguments`, at most
  # @max_ids of at most @id_bytes each), so a record can be found by the
  # record it changed. The client is otherwise only on the request span,
  # and a ValidationError inside a 200 otherwise reads as `result=ok`.
  # Nothing else of the event. At most @max records, oldest dropped first,
  # counted as `dropped`; receipts the Recorder evicted before a sweep read
  # them are counted as `missed_receipts` (some may have been mutations).
  # Reads project the records through the session's profile: strict
  # withholds the operation's name, the typenames, the user agent, and the
  # ids, as the GraphQL outcome's and the request's boundaries do.

  alias Insider.Live.Changes
  alias Insider.Live.Retention
  alias Insider.Redaction.Credentials

  @max 4_096
  @max_ids 8
  @id_bytes 64
  @id_depth 6
  @id_items 32

  defstruct cursor: nil, records: :queue.new(), count: 0, dropped: 0, missed: 0

  @type t :: %__MODULE__{}

  @doc "The ring's bounds, for the welcome document and status."
  @spec bounds() :: map()
  def bounds, do: %{"mutations_max" => @max}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Starts sweeping after receipt `cursor`, unless it already sweeps."
  @spec start(t(), non_neg_integer()) :: t()
  def start(%__MODULE__{cursor: nil} = ring, cursor), do: %{ring | cursor: cursor}
  def start(ring, _cursor), do: ring

  @spec active?(t() | nil) :: boolean()
  def active?(%__MODULE__{cursor: cursor}), do: is_integer(cursor)
  def active?(_ring), do: false

  @spec cursor(t()) :: non_neg_integer() | nil
  def cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc "Copies the mutations of a raw Recorder `read` after the sweep's cursor."
  @spec sweep(t(), map()) :: t()
  def sweep(%__MODULE__{} = ring, read) do
    ring = %{ring | missed: ring.missed + Map.get(read, "evicted", 0)}

    Retention.advance(ring, read, &keep/2)
  end

  defp keep(%{"receipt" => receipt, "event" => event}, ring) do
    case event do
      %{
        "source" => "telemetry",
        "kind" => "absinthe.execute.operation.stop",
        "attributes" => %{"graphql" => %{"operation_type" => "mutation"} = graphql}
      } ->
        record = %{
          "receipt" => receipt,
          "at" => wall_time(event["wall_time"]),
          "operation" => Changes.operation_name(graphql, event["payload"]),
          "result" => graphql["result"],
          "error_count" => graphql["error_count"],
          "user_error_count" => graphql["user_error_count"],
          "trace_id" => get_in(event, ["causality", "trace_id"]),
          "pid" => get_in(event, ["subject", "value"]),
          "user_agent" => text(get_in(graphql, ["client", "user_agent"])),
          "typenames" => Enum.filter(List.wrap(graphql["typenames"]), &is_binary/1),
          "ids" => ids(get_in(event, ["payload", "graphql_arguments"])),
          "event" => view_event(event)
        }

        push(ring, record)

      _other ->
        ring
    end
  end

  defp keep(_entry, ring), do: ring

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  # The ids among a mutation's converted arguments, sorted, unique.
  defp ids(%{} = arguments) do
    arguments
    |> collect_ids(0, [])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_ids)
  end

  defp ids(_arguments), do: []

  defp collect_ids(%{} = map, depth, found) when depth < @id_depth do
    Enum.reduce(map, found, fn {key, value}, found ->
      case id_value(key, value) do
        nil -> collect_ids(value, depth + 1, found)
        id -> [id | found]
      end
    end)
  end

  # A list's items (input objects of a bulk mutation), at most @id_items.
  defp collect_ids(list, depth, found) when is_list(list) and depth < @id_depth,
    do: list |> Enum.take(@id_items) |> Enum.reduce(found, &collect_ids(&1, depth + 1, &2))

  defp collect_ids(_value, _depth, found), do: found

  defp id_value(key, value) when is_binary(key) do
    if id_key?(key), do: id_text(value)
  end

  defp id_value(_key, _value), do: nil

  defp id_key?(key), do: key == "id" or String.ends_with?(key, ["Id", "_id"])

  defp id_text(value) when is_integer(value), do: Integer.to_string(value)

  defp id_text(value) when is_binary(value) and byte_size(value) in 1..@id_bytes do
    if String.valid?(value) and Credentials.mask_text(value) == value, do: value
  end

  defp id_text(_value), do: nil

  # What a reader's view reads of the operation stop (`Insider.Live.View`:
  # source, kind, severity, trace, service, and the signature's metadata),
  # so a kept record is shown only to the views that show its event.
  defp view_event(event) do
    metadata = get_in(event, ["payload", "metadata"])

    payload =
      if is_map(metadata),
        do: %{
          "metadata" =>
            Map.take(metadata, ["status", "kind", "reason", "error", "result", "conn"])
        }

    event
    |> Map.take(["source", "kind", "severity", "wall_time", "subject", "causality", "attributes"])
    |> Map.put("payload", payload)
  end

  defp push(%{count: count} = ring, record) when count < @max,
    do: %{ring | records: :queue.in(record, ring.records), count: count + 1}

  defp push(ring, record) do
    {_oldest, records} = :queue.out(ring.records)
    %{ring | records: :queue.in(record, records), dropped: ring.dropped + 1}
  end

  defp wall_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp wall_time(time) when is_binary(time), do: time
  defp wall_time(_time), do: nil

  @doc """
  The kept records, oldest first, projected for `profile` (`:rich` or
  `:strict`), optionally only those of a `trace_id` or a `pid`, and only
  those whose operation stop `shown?` keeps (given `%{"receipt", "event"}`,
  the event as a view reads it, before projection).
  """
  @spec records(t() | nil, atom(), keyword(), (map() -> boolean())) :: [map()]
  def records(ring, profile, filters \\ [], shown? \\ fn _entry -> true end)
  def records(nil, _profile, _filters, _shown?), do: []

  def records(%__MODULE__{} = ring, profile, filters, shown?) do
    trace_id = Keyword.get(filters, :trace_id)
    pid = Keyword.get(filters, :pid)

    id = Keyword.get(filters, :id)

    for record <- :queue.to_list(ring.records),
        is_nil(trace_id) or record["trace_id"] == trace_id,
        is_nil(pid) or record["pid"] == pid,
        shown?.(%{"receipt" => record["receipt"], "event" => record["event"]}),
        projected = record |> Map.delete("event") |> project(profile),
        is_nil(id) or id in projected["ids"],
        do: projected
  end

  defp project(record, :rich), do: record

  defp project(record, _strict),
    do:
      Map.merge(record, %{"operation" => nil, "user_agent" => nil, "typenames" => [], "ids" => []})

  @doc """
  One kept record as a line: its operation, result, response types, time,
  and in parentheses its receipt, process, user agent, trace, ids, and
  `note`.
  """
  @spec line(map(), String.t() | nil) :: String.t()
  def line(record, note \\ nil) do
    types =
      case record["typenames"] do
        [_ | _] = names -> " types=[#{Enum.join(names, ",")}]"
        _none -> ""
      end

    details =
      [
        "receipt #{record["receipt"]}",
        "pid #{record["pid"]}",
        record["user_agent"] && "user agent #{record["user_agent"]}",
        record["trace_id"] && "trace #{record["trace_id"]}",
        record["ids"] not in [nil, []] && "ids #{Enum.join(record["ids"], ", ")}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    note = if note, do: "; " <> note, else: ""

    "Kept mutation: #{record["operation"] || "mutation"} result=#{record["result"] || "?"}#{types} " <>
      "at #{record["at"]} (#{details}#{note})"
  end

  @doc "The ring's accounting for `status`."
  @spec describe(t() | nil) :: map()
  def describe(nil), do: describe(new())

  def describe(%__MODULE__{} = ring) do
    Map.merge(bounds(), %{
      "records" => ring.count,
      "dropped" => ring.dropped,
      "missed_receipts" => ring.missed,
      "swept_through" => ring.cursor
    })
  end
end
