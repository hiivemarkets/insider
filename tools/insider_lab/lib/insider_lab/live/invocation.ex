defmodule Insider.Lab.Live.Invocation do
  @moduledoc false

  # The form an observer command was run with: `mix insider.live` (the Mix
  # task, the default) or `insider-lab live` (the escript). Help and usage
  # errors are built in that form, and `document/2` rewrites the commands the
  # target wrote from the Mix task's form to the one that was run. The target
  # itself always writes the Mix task's form, because it is also called
  # directly from Elixir.
  #
  # Only the fields that carry commands are rewritten: the welcome, a
  # result's `next`, `help`, `resume` commands and `Next:` lines, the
  # `command` of each hint and anomaly, and an error's `help`. Everything
  # else in a document is data the node recorded or names it chose (event
  # payloads, mark labels, reader names, session ids, object keys), and is
  # written as it is, so a value the observer prints can be passed back.
  #
  # A command is `mix insider.live` followed by an operation, `OPERATION`,
  # `help` or `--help`; anything else (`run mix insider.live from
  # tools/insider_lab`) is a sentence about the Mix task and stays as it is.

  alias Insider.Live.Welcome

  @default "mix insider.live"
  @prefix @default <> " "

  @words (["OPERATION", "help", "--help"] ++
            Enum.map(Welcome.observer_commands(), &hd(String.split(&1["name"]))))
         |> Enum.uniq()

  @spec default() :: String.t()
  def default, do: @default

  @doc "`document` with the target's commands in `invocation` (see the module comment)."
  @spec document(term(), String.t()) :: term()
  def document(document, @default), do: document

  def document(%{} = document, invocation) do
    document
    |> update("welcome", &all(&1, invocation))
    |> update("error", &help(&1, invocation))
    |> update("result", &result(&1, document["operation"], invocation))
  end

  def document(document, _invocation), do: document

  # The welcome is generated text, so all of it is presentation.
  defp result(result, "welcome", invocation), do: all(result, invocation)

  defp result(%{} = result, _operation, invocation) do
    command = &command(&1, invocation)

    result
    |> update("welcome", &all(&1, invocation))
    |> update("next", command)
    |> update("help", command)
    |> update("text", &next_lines(&1, invocation))
    |> update("resume", &(&1 |> update("join", command) |> update("observer", command)))
    |> update("hints", &rows(&1, command))
    |> update("anomalies", &rows(&1, command))
    |> update("anomalies_known", &rows(&1, command))
  end

  defp result(result, _operation, _invocation), do: result

  defp help(error, invocation) do
    command = &command(&1, invocation)
    error |> update("help", command) |> update("details", &update(&1, "help", command))
  end

  defp rows(rows, command) when is_list(rows), do: Enum.map(rows, &update(&1, "command", command))
  defp rows(rows, _command), do: rows

  defp update(%{} = map, key, fun) when is_map_key(map, key), do: Map.update!(map, key, fun)
  defp update(value, _key, _fun), do: value

  defp command(text, invocation) when is_binary(text), do: rewrite(text, invocation)
  defp command(list, invocation) when is_list(list), do: Enum.map(list, &command(&1, invocation))
  defp command(value, _invocation), do: value

  defp all(text, invocation) when is_binary(text), do: rewrite(text, invocation)
  defp all(list, invocation) when is_list(list), do: Enum.map(list, &all(&1, invocation))

  defp all(%{} = map, invocation),
    do: Map.new(map, fn {key, value} -> {key, all(value, invocation)} end)

  defp all(value, _invocation), do: value

  # In a human text, only the `Next:` lines of hints and the `next:` lines
  # of anomalies hold commands; the other lines quote what was recorded.
  defp next_lines(text, invocation) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if Regex.match?(~r/\A(Next( \([^)]*\))?:|\s+next:) /, line),
        do: rewrite(line, invocation),
        else: line
    end)
  end

  defp next_lines(text, _invocation), do: text

  @doc "Rewrites each command in `text` from the Mix task's form to `invocation`."
  @spec rewrite(String.t(), String.t()) :: String.t()
  def rewrite(text, @default), do: text

  def rewrite(text, invocation) do
    [head | rest] = :binary.split(text, @prefix, [:global])
    IO.iodata_to_binary([head | Enum.map(rest, &[prefix(&1, invocation), &1])])
  end

  defp prefix(following, invocation),
    do: if(Enum.any?(@words, &command?(following, &1)), do: invocation <> " ", else: @prefix)

  # `word` ends where `following` does or before a byte no word holds.
  defp command?(following, word) do
    size = byte_size(word)

    String.starts_with?(following, word) and
      (byte_size(following) == size or not word_byte?(:binary.at(following, size)))
  end

  defp word_byte?(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-]
end
