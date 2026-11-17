defmodule Insider.Discovery.ExUnit.OracleRunner.OutputPolicy do
  @moduledoc false

  # Decides what of the child's captured output may be saved. The child may
  # print anything, including values of passthrough variables, so nothing is
  # saved verbatim:
  #
  # * `allowlisted` (default) keeps only lines that match fixed, value-free
  #   Mix and ExUnit summary formats and withholds every other line.
  # * `redacted` keeps every line after replacing each exact passthrough value.
  #   It cannot catch a value the child transformed (encoded, split, or
  #   embedded in a URL), which the run record states as a limitation.
  #
  # In both policies every exact passthrough value is replaced in the raw
  # captured bytes before anything is split into lines or normalized, so a
  # value containing a newline or CRLF is matched whole. When the head/tail
  # bound cut the stream, the end of the head that could begin a value and the
  # start of the tail that could end one are removed, and then the partial
  # line at each side of the cut is dropped whole, so no part of a value cut by
  # the omission survives on either side.
  #
  # Redaction work and memory are bounded. All values are matched by one
  # compiled pattern in a single left-to-right scan that merges overlapping
  # matches as it goes and appends each finished span's replacement straight
  # to the output binary. Lines are then kept or withheld chunk by chunk: each
  # chunk of about `@chunk_bytes` whole lines takes one pattern run in C, so
  # the cost of a line is a byte scan, not a regex call, and no list longer
  # than one chunk's lines is held. Heap use does not grow with the capture.
  # The scan makes at most one match call per matching start position,
  # whatever the number of overlapping values; a call may look ahead by the
  # longest value, so it is charged that length against `@work_budget`. At
  # most `@maximum_redactions` spans are replaced, which bounds how much
  # replacement can grow the output. The boundary cuts compare at most
  # `@maximum_secret_bytes` suffixes per value.
  #
  # A value set beyond the count or size bounds, a scan that exhausts its
  # budget, or more spans than the cap fails closed: nothing captured is saved,
  # the text is a fixed marker naming the reason, and withheld lines are
  # counted chunk by chunk, without copying or splitting the capture.

  @policies ["allowlisted", "redacted"]
  @replacement "[insider.oracle: redacted]"
  @maximum_secrets 64
  @maximum_secret_bytes 1024
  @maximum_total_secret_bytes 16_384
  @maximum_redactions 16_384
  @work_budget 134_217_728
  @chunk_bytes 16_384

  # Bodies of the fixed summary formats. A line is allowed when one matches
  # all of it once its trailing carriage returns are removed. All are ASCII,
  # none matches an empty line, and none can cross a newline, so one
  # multiline run over a chunk of whole lines finds exactly its allowed lines.
  @allowlist [
    ~S"Running ExUnit with seed: \d+, max_cases: \d+",
    ~S"(?:Excluding|Including) tags: \[[A-Za-z0-9_:, ]*\]",
    ~S"Finished in [0-9.]+ seconds? \([0-9.]+s async, [0-9.]+s sync\)",
    ~S"Result: \d+(?:/\d+)? passed(?: \([0-9a-z,/ ]+\))?",
    ~S"(?:Failed|Skipped|Excluded|Invalid): \d+ (?:tests?|propert(?:y|ies)|doctests?)",
    ~S"\d+ (?:tests?|doctests?|propert(?:y|ies))(?:, \d+ [a-z]+)*",
    ~S"There are no tests to run",
    ~S"Compiling \d+ files? \(\.[a-z]+\)",
    ~S"Generated [a-z0-9_]+ app"
  ]
  # The lookahead holds the first characters of the bodies above. It rejects
  # any other line in one step; on OTP 27 trying all nine bodies at every line
  # start cost about 140 ns a line.
  @allowed_lines "^(?=[0-9CEFGIRST])(" <>
                   Enum.map_join(@allowlist, "|", &"(?:#{&1})") <> ")\\r*+$"

  # Trailing CRs are matched only from the first CR of a run, and possessively,
  # so a run that ends in an ordinary byte is scanned once instead of once per
  # suffix, which was quadratic in the run length.
  @trailing_returns "(?<!\\r)\\r++(?=\\n|\\z)"

  @spec policies() :: [String.t()]
  def policies, do: @policies

  @type result :: %{
          text: binary(),
          lines_withheld: non_neg_integer(),
          redactions: non_neg_integer(),
          withheld: nil | String.t()
        }

  @spec bounds() :: %{
          secrets: pos_integer(),
          secret_bytes: pos_integer(),
          total_bytes: pos_integer(),
          redactions: pos_integer(),
          work: pos_integer()
        }
  def bounds,
    do: %{
      secrets: @maximum_secrets,
      secret_bytes: @maximum_secret_bytes,
      total_bytes: @maximum_total_secret_bytes,
      redactions: @maximum_redactions,
      work: @work_budget
    }

  @spec withheld_reasons() :: [String.t()]
  def withheld_reasons,
    do: [
      "secret_count_exceeded",
      "secret_bytes_exceeded",
      "redaction_work_exceeded",
      "redaction_count_exceeded"
    ]

  @spec apply(String.t(), %{head: binary(), tail: binary(), bytes_omitted: non_neg_integer()}, [
          String.t()
        ]) :: result()
  def apply(policy, capture, secrets) when policy in @policies do
    secrets =
      secrets |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort_by(&(-byte_size(&1)))

    case exceeded(secrets) do
      nil -> redact_or_withhold(policy, capture, secrets)
      reason -> withhold(capture, reason)
    end
  end

  defp exceeded(secrets) do
    cond do
      length(secrets) > @maximum_secrets ->
        "secret_count_exceeded"

      Enum.any?(secrets, &(byte_size(&1) > @maximum_secret_bytes)) or
          Enum.sum(Enum.map(secrets, &byte_size/1)) > @maximum_total_secret_bytes ->
        "secret_bytes_exceeded"

      true ->
        nil
    end
  end

  defp redact_or_withhold(policy, capture, secrets) do
    redact(policy, capture, secrets)
  catch
    {:withhold, reason} -> withhold(capture, reason)
  end

  # Nothing captured is saved: the text is a fixed marker and every line of
  # the capture counts as withheld. Without an omission the head and tail are
  # one stream, so a line split between them is one line.
  defp withhold(%{head: head, tail: tail, bytes_omitted: omitted}, reason) do
    lines =
      if omitted == 0,
        do: newlines(head) + newlines(tail) + unterminated(tail, head),
        else:
          newlines(head) + unterminated(head, <<>>) + newlines(tail) + unterminated(tail, <<>>)

    %{
      text: "[insider.oracle: output withheld: #{reason}]\n",
      lines_withheld: lines,
      redactions: 0,
      withheld: reason
    }
  end

  # A byte loop over the binary: it allocates nothing and costs a few
  # nanoseconds a byte however dense the newlines are.
  defp newlines(text), do: newlines(text, 0)

  defp newlines(<<?\n, rest::binary>>, count), do: newlines(rest, count + 1)
  defp newlines(<<_byte, rest::binary>>, count), do: newlines(rest, count)
  defp newlines(<<>>, count), do: count

  defp through_last_newline(text), do: through_last_newline(text, 0, 0)

  defp through_last_newline(<<?\n, rest::binary>>, at, _last),
    do: through_last_newline(rest, at + 1, at + 1)

  defp through_last_newline(<<_byte, rest::binary>>, at, last),
    do: through_last_newline(rest, at + 1, last)

  defp through_last_newline(<<>>, _at, last), do: last

  # One more line when the stream, `text` or else `before`, does not end in a
  # newline.
  defp unterminated(<<>>, <<>>), do: 0
  defp unterminated(<<>>, before), do: unterminated(before, <<>>)
  defp unterminated(text, _before), do: if(:binary.last(text) == ?\n, do: 0, else: 1)

  defp redact(policy, capture, secrets) do
    {{head, head_edge}, {tail, tail_edge}, budget} =
      redact_capture(capture, secrets, budget(secrets))

    allow =
      if policy == "redacted",
        do: {:all, compile(@trailing_returns)},
        else: compile(@allowed_lines)

    {head_text, head_withheld} = filter(head, allow, head_edge)
    {tail_text, tail_withheld} = filter(tail, allow, tail_edge)
    withheld = head_withheld + tail_withheld

    omission =
      if capture.bytes_omitted > 0,
        do: "[insider.oracle: #{capture.bytes_omitted} bytes omitted]\n",
        else: <<>>

    footer =
      if policy == "allowlisted",
        do: "[insider.oracle: output policy allowlisted withheld #{withheld} lines]\n",
        else: <<>>

    %{
      text: IO.iodata_to_binary([head_text, omission, tail_text, footer]),
      lines_withheld: withheld,
      redactions: budget.redactions,
      withheld: nil
    }
  end

  defp budget([]), do: %{pattern: nil, calls: 0, redactions: 0}

  defp budget([longest | _] = secrets),
    do: %{
      pattern: :binary.compile_pattern(secrets),
      calls: div(@work_budget, byte_size(longest)),
      redactions: 0
    }

  # Without an omission the head and tail are one contiguous stream.
  defp redact_capture(%{head: head, tail: tail, bytes_omitted: 0}, _secrets, budget) do
    text = head <> tail
    {text, budget} = redact_window(text, 0, byte_size(text), budget)
    {{text, :whole}, {<<>>, :whole}, budget}
  end

  # Boundary fragments are found in the original captured bytes, before any
  # replacement could change them, and a complete value that straddles the new
  # boundary moves it so the value is dropped whole. Only complete values
  # inside the kept part are replaced.
  defp redact_capture(%{head: head, tail: tail}, secrets, budget) do
    {head, budget} = redact_window(head, 0, value_start_cut(head, secrets), budget)
    {tail, budget} = redact_window(tail, value_end_cut(tail, secrets), byte_size(tail), budget)
    {{head, :drop_last_partial}, {tail, :drop_first_partial}, budget}
  end

  # Where the head must end: before its longest end that begins some value.
  defp value_start_cut(head, secrets) do
    size = byte_size(head)

    cut =
      secrets
      |> Enum.map(fn secret ->
        Enum.find(min(byte_size(secret) - 1, size)..1//-1, 0, fn length ->
          String.starts_with?(secret, binary_part(head, size - length, length))
        end)
      end)
      |> Enum.max(fn -> 0 end)

    size - cut
  end

  # Where the tail must start: after its longest start that ends some value.
  defp value_end_cut(tail, secrets) do
    size = byte_size(tail)

    secrets
    |> Enum.map(fn secret ->
      Enum.find(min(byte_size(secret) - 1, size)..1//-1, 0, fn length ->
        String.ends_with?(secret, binary_part(tail, 0, length))
      end)
    end)
    |> Enum.max(fn -> 0 end)
  end

  # Redacts `text[lo, hi)` in one scan. Every occurrence of every value,
  # overlapping ones included, is merged into disjoint spans as it is found:
  # the compiled pattern returns the longest value at the leftmost start, and
  # the scan resumes one byte later, extending the pending span while matches
  # touch it. Each finished span is written out at once. A span across `lo`
  # moves `lo` to its end and one across `hi` moves `hi` to its start, so a
  # value at either boundary is dropped whole; spans are disjoint, so one move
  # settles each boundary.
  defp redact_window(text, lo, hi, %{pattern: nil} = budget),
    do: {binary_part(text, lo, hi - lo), budget}

  defp redact_window(text, lo, hi, budget) do
    window = %{lo: lo, hi: hi, position: lo, out: <<>>}
    scan(text, 0, nil, window, budget)
  end

  defp scan(_text, _start, _pending, _window, %{calls: 0}),
    do: throw({:withhold, "redaction_work_exceeded"})

  defp scan(text, start, pending, window, budget) do
    budget = %{budget | calls: budget.calls - 1}

    case :binary.match(text, budget.pattern, scope: {start, byte_size(text) - start}) do
      {from, length} when is_tuple(pending) and from <= elem(pending, 1) ->
        pending = {elem(pending, 0), max(elem(pending, 1), from + length)}
        scan(text, from + 1, pending, window, budget)

      {from, length} ->
        case emit(text, pending, window, budget) do
          {:cont, window, budget} when from < window.hi ->
            scan(text, from + 1, {from, from + length}, window, budget)

          {_continue, window, budget} ->
            finish(text, window, budget)
        end

      :nomatch ->
        {_continue, window, budget} = emit(text, pending, window, budget)
        finish(text, window, budget)
    end
  end

  defp emit(_text, nil, window, budget), do: {:cont, window, budget}

  defp emit(_text, {_from, to}, %{lo: lo} = window, budget) when to <= lo,
    do: {:cont, window, budget}

  defp emit(_text, {from, to}, %{lo: lo} = window, budget) when from < lo,
    do: {:cont, %{window | lo: to, position: to}, budget}

  defp emit(_text, {from, _to}, %{hi: hi} = window, budget) when from >= hi,
    do: {:halt, window, budget}

  defp emit(_text, {from, to}, %{hi: hi} = window, budget) when to > hi,
    do: {:halt, %{window | hi: from}, budget}

  defp emit(_text, _span, _window, %{redactions: @maximum_redactions}),
    do: throw({:withhold, "redaction_count_exceeded"})

  defp emit(text, {from, to}, %{out: out, position: position} = window, budget) do
    out = <<out::binary, binary_part(text, position, from - position)::binary, @replacement>>
    {:cont, %{window | out: out, position: to}, %{budget | redactions: budget.redactions + 1}}
  end

  defp finish(text, %{out: out, position: position, hi: hi}, budget),
    do: {<<out::binary, binary_part(text, position, hi - position)::binary>>, budget}

  defp compile(source) do
    {:ok, pattern} = :re.compile(source, [:multiline, {:newline, :lf}])
    pattern
  end

  # Keeps or withholds each line, appending kept lines to one binary. At an
  # omission the head's last partial line and the tail's first partial line
  # are dropped whole and uncounted, as is the empty segment after a final
  # newline.
  defp filter(text, allow, :drop_first_partial),
    do: chunks(text, allow, :whole, after_first_newline(text), <<>>, 0)

  defp filter(text, allow, edge), do: chunks(text, allow, edge, 0, <<>>, 0)

  defp after_first_newline(text) do
    case :binary.match(text, "\n") do
      {at, 1} -> at + 1
      :nomatch -> byte_size(text)
    end
  end

  # A chunk runs from `start` through the first newline at least
  # `@chunk_bytes` on, or to the end, so it holds only whole lines, except a
  # final partial line at the end, and holds at most about `@chunk_bytes` / 7
  # allowed lines, the shortest allowed line being 6 bytes and a newline.
  defp chunks(text, _allow, _edge, start, kept, withheld) when start >= byte_size(text),
    do: {kept, withheld}

  defp chunks(text, allow, edge, start, kept, withheld) do
    size = byte_size(text)
    from = start + @chunk_bytes - 1

    stop =
      with true <- from < size,
           {at, 1} <- :binary.match(text, "\n", scope: {from, size - from}) do
        at + 1
      else
        _end -> size
      end

    {kept, withheld} = chunk(binary_part(text, start, stop - start), allow, edge, kept, withheld)
    chunks(text, allow, edge, stop, kept, withheld)
  end

  defp chunk(chunk, allow, edge, kept, withheld) do
    {chunk, partial} =
      cond do
        :binary.last(chunk) == ?\n -> {chunk, 0}
        edge == :whole -> {chunk, 1}
        true -> {binary_part(chunk, 0, through_last_newline(chunk)), 0}
      end

    keep(chunk, allow, partial, kept, withheld)
  end

  defp keep(chunk, {:all, trailing_returns}, partial, kept, withheld) do
    chunk =
      if :binary.match(chunk, "\r") == :nomatch,
        do: chunk,
        else: :re.replace(chunk, trailing_returns, "", [:global, {:return, :binary}])

    ending = if partial == 1, do: "\n", else: <<>>
    {<<kept::binary, chunk::binary, ending::binary>>, withheld}
  end

  defp keep(chunk, allowed_lines, partial, kept, withheld) do
    lines = newlines(chunk) + partial

    case :re.run(chunk, allowed_lines, [:global, {:capture, [1], :index}]) do
      :nomatch ->
        {kept, withheld + lines}

      {:match, matches} ->
        kept =
          Enum.reduce(matches, kept, fn [{at, bytes}], kept ->
            <<kept::binary, binary_part(chunk, at, bytes)::binary, ?\n>>
          end)

        {kept, withheld + lines - length(matches)}
    end
  end
end
