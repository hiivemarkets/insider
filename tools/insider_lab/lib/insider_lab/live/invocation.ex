defmodule Insider.Lab.Live.Invocation do
  @moduledoc false

  # The form an observer command was run with: `mix insider.live` (the Mix
  # task, the default) or `insider-lab live` (the escript). Help and usage
  # errors are built in that form, and everything the observer writes passes
  # through `writer/2`, which rewrites the commands the target wrote
  # (`Insider.Live` hints, `next` commands, `Next:` lines, the welcome's
  # examples) from the Mix task's form to the one that was run. The target
  # itself always writes the Mix task's form, because it is also called
  # directly from Elixir.
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

  @doc "Wraps `writer` so that it writes the target's commands in `invocation`."
  @spec writer((iodata() -> term()), String.t()) :: (iodata() -> term())
  def writer(writer, @default), do: writer

  def writer(writer, invocation) when is_binary(invocation),
    do: fn bytes -> bytes |> IO.iodata_to_binary() |> rewrite(invocation) |> writer.() end

  @doc """
  Rewrites each command in `text` from the Mix task's form to `invocation`.
  The replacement holds no character that JSON escapes, so encoded JSON stays
  valid and its string values are rewritten.
  """
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
