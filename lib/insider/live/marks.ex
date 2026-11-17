defmodule Insider.Live.Marks do
  @moduledoc false

  # Pairing marks. An agent pairing with a programmer who clicks in the app
  # marks the moment before an action ("about to click Confirm"), then reads
  # what happened since the mark (`digest`, `trends`, `events` and
  # `timeline` take `"mark"` or `"mark:LABEL"`) instead of guessing a time or
  # a cursor.
  #
  # A mark is the newest receipt when it was made (`"cursor"`: a read since
  # the mark starts after it, so the `live.mark` event itself and everything
  # after are in it), its time, its label, and the reader that made it. A
  # session keeps its newest `@max` marks and counts those it let go.
  #
  # A label is operator text: one line (control characters become spaces,
  # surrounding blanks are trimmed), credential-masked
  # (`Insider.Redaction.Credentials`), then cut to at most `@label_max_bytes`
  # bytes at a character boundary, before it is kept: a secret typed into a
  # label never reaches the session, in any disclosure profile. A label is
  # looked up after the same normalisation.

  alias Insider.Live.Error
  alias Insider.Redaction.Credentials

  @max 256
  @label_max_bytes 120
  # A label longer than this is refused before any work: the bound on what
  # one mark or one lookup costs the owner.
  @label_input_max_bytes 1_024
  @labels_listed 8

  @type t :: %{marks: [map()], next: pos_integer(), dropped: non_neg_integer()}

  @doc "The bounds, for the welcome document."
  @spec bounds() :: map()
  def bounds,
    do: %{
      "marks_max" => @max,
      "mark_label_max_bytes" => @label_max_bytes,
      "mark_label_input_max_bytes" => @label_input_max_bytes
    }

  @spec new() :: t()
  def new, do: %{marks: [], next: 1, dropped: 0}

  @doc """
  A label as a mark keeps it, and as a lookup compares it:
  `{:ok, label, truncated?}`, or `:error` when it is not a non-blank UTF-8
  string of at most `@label_input_max_bytes` bytes (refused before any work).
  """
  @spec label(term()) :: {:ok, String.t(), boolean()} | :error
  def label(label) when is_binary(label) and byte_size(label) <= @label_input_max_bytes do
    with true <- String.valid?(label),
         line = label |> String.replace(~r/[[:cntrl:]]+/u, " ") |> String.trim(),
         true <- line != "" do
      # Masked before it is cut, so a cut never hides a secret from the mask.
      {masked, _records} = Credentials.mask(line)
      {cut, truncated?} = cut(masked)
      {:ok, cut, truncated?}
    else
      _invalid -> :error
    end
  end

  def label(_label), do: :error

  defp cut(line) when byte_size(line) <= @label_max_bytes, do: {line, false}

  # A character cut in half is dropped whole: the first valid chunk.
  defp cut(line),
    do: {line |> binary_part(0, @label_max_bytes) |> String.chunk(:valid) |> List.first(), true}

  @doc """
  Adds a mark made now after receipt `cursor`; returns it and the marks.
  The oldest mark is let go past `@max`.
  """
  @spec add(
          t(),
          %{label: String.t(), truncated: boolean(), reader: String.t() | nil},
          non_neg_integer()
        ) :: {map(), t()}
  def add(marks, %{label: label, truncated: truncated, reader: reader}, cursor) do
    at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    mark = %{
      "index" => marks.next,
      "label" => label,
      "label_truncated" => truncated,
      "reader" => reader,
      "cursor" => cursor,
      "at" => DateTime.to_iso8601(at)
    }

    kept = Enum.take([mark | marks.marks], @max)
    dropped = marks.dropped + length(marks.marks) + 1 - length(kept)
    {mark, %{marks | marks: kept, next: marks.next + 1, dropped: dropped}}
  end

  @doc """
  The newest mark (`nil`), or the newest with this label, already
  normalised with `label/1`; else
  `mark_not_found` with the label asked for, how many marks there are, and
  the newest labels.
  """
  @spec find(t() | nil, String.t() | nil) :: {:ok, map()} | {:error, map()}
  def find(marks, label) do
    marks = marks || new()

    found =
      case label do
        nil -> List.first(marks.marks)
        label -> Enum.find(marks.marks, &(&1["label"] == label))
      end

    case found do
      nil ->
        {:error,
         Error.new("mark_not_found", %{
           "label" => label,
           "marks" => length(marks.marks),
           "labels" =>
             marks.marks |> Enum.map(& &1["label"]) |> Enum.uniq() |> Enum.take(@labels_listed)
         })}

      mark ->
        {:ok, mark}
    end
  end

  @doc """
  The marks as `insider.live-marks/v1`, oldest first, each with its age;
  `human` adds `"text"`, one line per mark.
  """
  @spec document(String.t(), t() | nil, boolean()) :: map()
  def document(session_id, marks, human) do
    marks = marks || new()
    now = System.os_time(:millisecond)
    listed = marks.marks |> Enum.reverse() |> Enum.map(&Map.put(&1, "age_ms", age_ms(&1, now)))

    document = %{
      "schema" => "insider.live-marks/v1",
      "session_id" => session_id,
      "marks" => listed,
      "dropped" => marks.dropped,
      "max" => @max
    }

    if human, do: Map.put(document, "text", text(session_id, document)), else: document
  end

  defp text(session_id, %{"marks" => []}),
    do: "No marks in #{session_id}: mark --label 'about to …' before the programmer acts.\n"

  defp text(session_id, document) do
    dropped =
      if document["dropped"] > 0, do: " (#{document["dropped"]} older let go)", else: ""

    lines =
      Enum.map(document["marks"], fn mark ->
        by = if mark["reader"], do: " by #{mark["reader"]}", else: ""

        "##{mark["index"]} #{clock(mark["at"])} UTC (#{age_text(mark["age_ms"])} ago) " <>
          "'#{mark["label"]}'#{by}, after receipt #{mark["cursor"]}"
      end)

    Enum.join(["Marks in #{session_id}#{dropped}:" | lines], "\n") <> "\n"
  end

  @doc "How a read since `mark` names it: `since mark 'LABEL' (HH:MM:SS UTC, X s ago)`."
  @spec since_text(map()) :: String.t()
  def since_text(mark) do
    age = age_ms(mark, System.os_time(:millisecond))
    "since mark '#{mark["label"]}' (#{clock(mark["at"])} UTC, #{age_text(age)} ago)"
  end

  @doc "The mark as a read since it reports it, with its age now."
  @spec describe(map()) :: map()
  def describe(mark), do: Map.put(mark, "age_ms", age_ms(mark, System.os_time(:millisecond)))

  defp age_ms(mark, now) do
    {:ok, at, 0} = DateTime.from_iso8601(mark["at"])
    max(now - DateTime.to_unix(at, :millisecond), 0)
  end

  defp clock(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    at |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()
  end

  @doc "An age in milliseconds as people read it: `3.4 s`, `8.0 min`, `1.5 h`."
  @spec age_text(non_neg_integer()) :: String.t()
  def age_text(ms) when ms >= 3_600_000,
    do: :erlang.float_to_binary(ms / 3_600_000, decimals: 1) <> " h"

  def age_text(ms) when ms >= 60_000,
    do: :erlang.float_to_binary(ms / 60_000, decimals: 1) <> " min"

  def age_text(ms), do: :erlang.float_to_binary(ms / 1_000, decimals: 1) <> " s"
end
