defmodule Insider.Collector.Logger.Template do
  @moduledoc false

  # A message's template: its first line with the values that vary from one
  # message to the next (numbers, pids, references, ports, long hex runs)
  # replaced, and runs of whitespace collapsed. Two messages that differ only
  # in such values have one template. Words such as an interpolated name are
  # kept: they are the message text, disclosed only where the text itself is.
  #
  # The input is cut to its first `bytes` bytes before any pattern runs, and
  # chardata is read only that far, so a template costs the same for a huge
  # message as for a short one. A cut is marked with an ellipsis.
  #
  # Credentials are masked (`Insider.Redaction.Credentials.mask_text/1`)
  # before anything is replaced, in every profile: normalising first could
  # change a secret's shape (its one digit becoming `N`) so that the export
  # mask no longer recognises it. The token a cut runs through is dropped,
  # since its visible part may be too short to look like the secret it is
  # the start of. The masked template is the one grouped, fingerprinted, and
  # stored. If masking fails, the template is a redaction marker.

  alias Insider.Redaction.Credentials

  @default_bytes 160
  # The most chardata list elements read for one prefix, so a deeply nested
  # or mostly empty list is bounded too.
  @max_elements 1_024
  @failed "[REDACTED:redacted_field]"

  @doc """
  The template of `text`, a string or chardata. Only its first `bytes`
  bytes are read.
  """
  @spec normalise(IO.chardata(), pos_integer()) :: String.t()
  def normalise(text, bytes \\ @default_bytes) do
    {prefix, cut?} = prefix(text, bytes)
    [line | rest] = String.split(prefix, "\n", parts: 2)
    # The first line was cut only when the cut fell inside it.
    cut_line? = cut? and rest == []

    template =
      line
      |> drop_cut_token(cut_line?)
      |> Credentials.mask_text()
      |> String.replace(~r/#(PID|Reference|Port)<[^>]*>/, "#\\1<_>")
      |> String.replace(~r/\b[0-9a-f]{8,}\b/, "X")
      |> String.replace(~r/\d+/, "N")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if cut?, do: template <> " …", else: template
  rescue
    _error -> @failed
  end

  defp drop_cut_token(line, false), do: line
  defp drop_cut_token(line, true), do: String.replace(line, ~r/\S+\z/u, "")

  @doc """
  The template of a Logger message: a string, chardata, or the format of a
  `{format, arguments}` message. `nil` for anything else.
  """
  @spec of_message(term()) :: String.t() | nil
  def of_message({:string, chardata}), do: normalise(chardata)
  def of_message({format, arguments}) when is_list(arguments), do: format(format)
  def of_message(_message), do: nil

  defp format(format) when is_atom(format), do: format |> Atom.to_string() |> normalise()
  defp format(format) when is_binary(format) or is_list(format), do: normalise(format)
  defp format(_format), do: nil

  @doc "`text` cut to at most `bytes` bytes on a UTF-8 boundary, marked with an ellipsis."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, bytes) when byte_size(text) <= bytes, do: text
  def truncate(text, bytes), do: valid_prefix(binary_part(text, 0, bytes)) <> "…"

  # At most `bytes` bytes of `chardata` as a valid UTF-8 string, and whether
  # anything was left out.
  defp prefix(text, bytes) when is_binary(text) and byte_size(text) <= bytes,
    do: {valid_prefix(text), false}

  defp prefix(text, bytes) when is_binary(text),
    do: {valid_prefix(binary_part(text, 0, bytes)), true}

  defp prefix(chardata, bytes) when is_list(chardata) do
    {parts, _left, _elements, cut?} = walk(chardata, [], bytes, @max_elements)
    {parts |> Enum.reverse() |> IO.iodata_to_binary() |> valid_prefix(), cut?}
  end

  defp prefix(_other, _bytes), do: {"", false}

  defp walk([], parts, left, elements), do: {parts, left, elements, false}
  defp walk(_rest, parts, left, 0), do: {parts, left, 0, true}
  defp walk(_rest, parts, 0, elements), do: {parts, 0, elements, true}

  defp walk([head | tail], parts, left, elements) do
    case element(head, parts, left, elements - 1) do
      {parts, left, elements, false} -> walk(tail, parts, left, elements)
      cut -> cut
    end
  end

  defp walk(_improper, parts, left, elements), do: {parts, left, elements, true}

  defp element(binary, parts, left, elements) when is_binary(binary) do
    if byte_size(binary) <= left,
      do: {[binary | parts], left - byte_size(binary), elements, false},
      else: {[binary_part(binary, 0, left) | parts], 0, elements, true}
  end

  defp element(codepoint, parts, left, elements) when is_integer(codepoint) do
    case <<codepoint::utf8>> do
      encoded when byte_size(encoded) <= left ->
        {[encoded | parts], left - byte_size(encoded), elements, false}

      _encoded ->
        {parts, 0, elements, true}
    end
  rescue
    ArgumentError -> {parts, left, elements, true}
  end

  defp element(list, parts, left, elements) when is_list(list),
    do: walk(list, parts, left, elements)

  defp element(_other, parts, left, elements), do: {parts, left, elements, true}

  defp valid_prefix(text) do
    case String.chunk(text, :valid) do
      [valid | _rest] -> if String.valid?(valid), do: valid, else: ""
      [] -> ""
    end
  end
end
