defmodule Insider.Discovery.ExUnit.OracleRunner.OutputPolicyTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Command
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy

  @secret "canary-SECRET-4f2a9c"
  @summary """
  Compiling 2 files (.ex)
  Generated fixture app
  Running ExUnit with seed: 1, max_cases: 36
  Excluding tags: [:stress]
  Finished in 2.3 seconds (0.00s async, 2.3s sync)
  Result: 5 passed
  1 test, 0 failures
  """

  defp capture(text), do: %{head: text, tail: "", bytes_omitted: 0}

  test "allowlisted keeps only fixed summary lines and counts the rest" do
    text =
      @summary <> "user line #{@secret}\nINSIDER_ORACLE_RUNNER_SUITE={}\n** (RuntimeError) boom\n"

    saved = OutputPolicy.apply("allowlisted", capture(text), [@secret])

    assert saved.text ==
             @summary <> "[insider.oracle: output policy allowlisted withheld 3 lines]\n"

    assert saved.lines_withheld == 3
    assert saved.redactions == 1
  end

  test "an allowlisted format that carries a passthrough value is withheld" do
    saved = OutputPolicy.apply("allowlisted", capture("Generated #{@secret} app\n"), [@secret])
    refute saved.text =~ @secret
    assert saved.lines_withheld == 1
  end

  test "redacted keeps every line and replaces every exact value, longest first" do
    text = "a #{@secret} b #{@secret}\nport 5432\nnested #{@secret}-suffix\n"

    saved =
      OutputPolicy.apply("redacted", capture(text), [@secret, "5432", "", @secret <> "-suffix"])

    assert saved.text ==
             "a [insider.oracle: redacted] b [insider.oracle: redacted]\n" <>
               "port [insider.oracle: redacted]\nnested [insider.oracle: redacted]\n"

    assert saved.redactions == 4
    assert saved.lines_withheld == 0
  end

  test "a value cut by the omission point cannot survive as a fragment on either side" do
    {left, right} = String.split_at(@secret, 9)

    capture = %{
      head: "kept line\nhead #{@secret}\npartial #{left}",
      tail: "#{right} partial\ntail #{@secret}\nlast\n",
      bytes_omitted: 1_000
    }

    for policy <- OutputPolicy.policies() do
      saved = OutputPolicy.apply(policy, capture, [@secret])
      refute saved.text =~ left
      refute saved.text =~ right
      assert saved.text =~ "[insider.oracle: 1000 bytes omitted]"
    end

    assert OutputPolicy.apply("redacted", capture, [@secret]).text ==
             "kept line\nhead [insider.oracle: redacted]\n[insider.oracle: 1000 bytes omitted]\n" <>
               "tail [insider.oracle: redacted]\nlast\n"
  end

  test "a value split across port chunks is still redacted from the assembled capture" do
    {left, right} = String.split_at(@secret, 7)
    chunks = ["noise\nvalue=", left, right, "\n", "INSIDER_X=1\n"]
    state = Command.new_state(%{max_output_bytes: 4_096, prefixes: ["INSIDER_X="]})

    result =
      chunks |> Enum.reduce(state, &Command.scan(&2, &1)) |> Command.finish("exited", 0, "exited")

    for policy <- OutputPolicy.policies() do
      refute OutputPolicy.apply(policy, result, [@secret]).text =~ left <> right
    end
  end

  test "a multiline or CRLF value is redacted before lines are split" do
    multiline = "line-one-canary\nline-two-canary"
    summary_shaped = "Generated review_canary app\nThere are no tests to run"
    crlf = "crlf-one-canary\r\ncrlf-two-canary"
    text = "a #{multiline} b\n#{summary_shaped}\nc #{crlf} d\r\nResult: 1 passed\n"

    for policy <- OutputPolicy.policies() do
      saved = OutputPolicy.apply(policy, capture(text), [multiline, summary_shaped, crlf])

      for fragment <-
            ~w(line-one-canary line-two-canary review_canary crlf-one-canary crlf-two-canary) do
        refute saved.text =~ fragment, "#{policy} kept #{fragment}"
      end

      assert saved.redactions == 3
      assert saved.text =~ "Result: 1 passed"
    end
  end

  test "a multiline value cut by the omission point loses its retained lines on both sides" do
    secret = "first-canary-line\nsecond-canary-line\nthird-canary-line"

    capture = %{
      head: "kept\nprefix first-canary-line\nsecond-canary-line\n",
      tail: "second-canary-line\nthird-canary-line suffix\nlast\n",
      bytes_omitted: 500
    }

    for policy <- ["redacted"] do
      saved = OutputPolicy.apply(policy, capture, [secret])
      refute saved.text =~ "canary-line"
      assert saved.text == "kept\n[insider.oracle: 500 bytes omitted]\nlast\n"
    end
  end

  # Redacting a shorter value first must not hide the start or
  # end of a longer value that the omission cut.
  test "an overlapping shorter value cannot hide a cut multiline value at the head" do
    long = "Generated first_canary app\nGenerated second_canary app\ntrailing-canary"

    capture = %{
      head: "kept\n" <> binary_part(long, 0, byte_size(long) - 11),
      tail: "last\n",
      bytes_omitted: 900
    }

    for policy <- OutputPolicy.policies() do
      saved = OutputPolicy.apply(policy, capture, [long, "trai"])
      refute saved.text =~ "first_canary", policy
      refute saved.text =~ "second_canary", policy
    end
  end

  test "an overlapping shorter value cannot hide a cut multiline value at the tail" do
    long = "lead-canary\nGenerated first_canary app\nGenerated second_canary app"

    capture = %{
      head: "kept\n",
      tail: binary_part(long, 9, byte_size(long) - 9) <> "\nlast\n",
      bytes_omitted: 900
    }

    for policy <- OutputPolicy.policies() do
      saved = OutputPolicy.apply(policy, capture, [long, "ary"])
      refute saved.text =~ "first_canary", policy
      refute saved.text =~ "second_canary", policy
      if policy == "redacted", do: assert(saved.text =~ "last")
    end
  end

  test "a complete value straddling the removed boundary fragment is removed whole" do
    straddling = "Generated straddle_canary app\nxyztr"
    capture = %{head: "kept\n" <> straddling, tail: "last\n", bytes_omitted: 900}

    for policy <- OutputPolicy.policies() do
      saved = OutputPolicy.apply(policy, capture, [straddling, "tr-rest-of-value"])
      refute saved.text =~ "straddle_canary", policy
    end
  end

  test "overlapping complete values are removed as one span, leaving no fragment" do
    text = "x abc-canaryde y\n"

    assert OutputPolicy.apply("redacted", capture(text), ["abc-canary", "canaryde"]) ==
             %{
               text: "x [insider.oracle: redacted] y\n",
               lines_withheld: 0,
               redactions: 1,
               withheld: nil
             }
  end

  # 64 values "x" .. "x" * 64 over a run of "x" made the old
  # per-value occurrence lists use tens of MB for a 4 KiB capture and blow a
  # 16-million-word heap for 1 MiB.
  @overlapping for n <- 1..64, do: String.duplicate("x", n)

  defp bounded(fun) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false})
        {micros, result} = :timer.tc(fun)
        send(caller, {:bounded, self(), micros, result})
      end)

    receive do
      {:bounded, ^pid, micros, result} ->
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        {micros, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("redaction exceeded its heap bound: #{inspect(reason)}")
    end
  end

  test "many overlapping values over a 1 MiB capture stay within a heap and time bound" do
    run = String.duplicate("x", 1_048_576)

    for policy <- OutputPolicy.policies(),
        capture <- [
          capture(run),
          %{head: binary_part(run, 0, 524_288), tail: "\n" <> run, bytes_omitted: 7}
        ] do
      {micros, saved} = bounded(fn -> OutputPolicy.apply(policy, capture, @overlapping) end)

      refute saved.text =~ "x", policy
      assert saved.withheld == nil
      assert micros < 5_000_000, "#{policy} took #{micros}µs"
    end
  end

  test "redaction time grows linearly with the capture, not with overlap count" do
    measure = fn bytes ->
      text = String.duplicate("xy", div(bytes, 2))
      values = for n <- 1..64, do: String.duplicate("xy", n) |> binary_part(0, n)

      [{micros, _saved} | _] =
        for _ <- 1..3 do
          bounded(fn -> OutputPolicy.apply("redacted", capture(text), values) end)
        end
        |> Enum.sort()

      max(micros, 1)
    end

    small = measure.(65_536)
    large = measure.(1_048_576)

    # 16x the input; a quadratic or per-value blow-up would be ≥ 64x.
    assert large / small < 48, "65 KiB #{small}µs, 1 MiB #{large}µs"
  end

  # A one-byte value between separators gives one
  # disjoint span per two bytes; retaining them, or the replacement output,
  # was killed at a 16-million-word heap. Past the redaction cap it withholds.
  test "disjoint matches past the redaction cap withhold within the heap bound" do
    %{redactions: cap} = OutputPolicy.bounds()

    for bytes <- [1_048_576, 4_194_304],
        policy <- OutputPolicy.policies(),
        capture <- [
          capture(String.duplicate("x ", div(bytes, 2))),
          %{
            head: String.duplicate("x ", div(bytes, 4)),
            tail: String.duplicate("x ", div(bytes, 4)),
            bytes_omitted: 9
          }
        ] do
      {micros, saved} = bounded(fn -> OutputPolicy.apply(policy, capture, ["x"]) end)

      assert %{withheld: "redaction_count_exceeded", redactions: 0} = saved
      assert saved.text == "[insider.oracle: output withheld: redaction_count_exceeded]\n"
      assert micros < 5_000_000, "#{policy} #{bytes} took #{micros}µs"
    end

    at_cap = String.duplicate("x" <> String.duplicate(".", 62) <> "\n", cap)

    {_micros, saved} = bounded(fn -> OutputPolicy.apply("redacted", capture(at_cap), ["x"]) end)
    assert %{withheld: nil, redactions: ^cap} = saved
    refute saved.text =~ "x"

    over = at_cap <> "x\n"

    {_micros, saved} = bounded(fn -> OutputPolicy.apply("redacted", capture(over), ["x"]) end)
    assert saved.withheld == "redaction_count_exceeded"
  end

  # The fallback built a line list just to count lines.
  test "withholding a newline-dense capture counts lines within the heap bound" do
    newlines = String.duplicate("\n", 4_194_304)
    oversized = String.duplicate("v", 1_025)

    for policy <- OutputPolicy.policies(),
        {capture, lines} <- [
          {capture(newlines), 4_194_304},
          {%{head: newlines, tail: newlines <> "partial", bytes_omitted: 3}, 8_388_609}
        ] do
      {micros, saved} = bounded(fn -> OutputPolicy.apply(policy, capture, [oversized]) end)

      assert saved == %{
               text: "[insider.oracle: output withheld: secret_bytes_exceeded]\n",
               lines_withheld: lines,
               redactions: 0,
               withheld: "secret_bytes_exceeded"
             }

      assert micros < 5_000_000, "#{policy} took #{micros}µs"
    end
  end

  test "filtering a newline-dense capture stays within the heap bound" do
    newlines = String.duplicate("\n", 4_194_304)

    for capture <- [
          capture(newlines),
          %{head: "\n" <> newlines, tail: newlines <> "\n", bytes_omitted: 3}
        ] do
      {_micros, allowlisted} =
        bounded(fn -> OutputPolicy.apply("allowlisted", capture, ["zz"]) end)

      {_micros, redacted} = bounded(fn -> OutputPolicy.apply("redacted", capture, ["zz"]) end)

      lines = if capture.bytes_omitted == 0, do: 4_194_304, else: 8_388_609
      assert allowlisted.lines_withheld == lines
      assert redacted.lines_withheld == 0
      assert byte_size(redacted.text) >= lines
    end
  end

  # CI on OTP 27: one regex call per line made newline-dense filtering take
  # over 60 s. Lines are now matched a chunk at a time; a capture dense with
  # allowed CRLF lines is the costliest shape for both policies.
  test "filtering a capture dense with allowed lines stays within the heap and time bound" do
    count = 262_144
    dense = String.duplicate("Result: 1 passed\r\n", count)

    for policy <- OutputPolicy.policies() do
      {micros, saved} = bounded(fn -> OutputPolicy.apply(policy, capture(dense), ["zz"]) end)

      assert saved.lines_withheld == 0
      assert binary_part(saved.text, 0, 34) == "Result: 1 passed\nResult: 1 passed\n"
      refute saved.text =~ "\r"
      assert micros < 5_000_000, "#{policy} took #{micros}µs"
    end
  end

  # An unanchored trailing-CR pattern rescanned
  # every suffix of a CR run that ends in an ordinary byte, so 16 Ki CRs took
  # seconds. Internal CR runs are kept byte for byte; only a run ending the
  # line is removed, and the cost stays linear in the run length.
  test "long CR runs inside and at the end of lines are normalized in linear time" do
    run = String.duplicate("\r", 1_048_576)

    cases = [
      {"prefix" <> run <> "x\n", "prefix" <> run <> "x\n"},
      {"prefix" <> run <> "x", "prefix" <> run <> "x\n"},
      {"prefix" <> run <> "\n", "prefix\n"},
      {"prefix" <> run, "prefix\n"},
      {"a\r\rb" <> run <> "x\r\r\nRe\r" <> run, "a\r\rb" <> run <> "x\nRe\n"}
    ]

    for {text, redacted} <- cases do
      {micros, saved} = bounded(fn -> OutputPolicy.apply("redacted", capture(text), []) end)
      assert saved.text == redacted
      assert micros < 5_000_000, "redacted took #{micros}µs"

      {micros, saved} = bounded(fn -> OutputPolicy.apply("allowlisted", capture(text), []) end)
      assert saved.lines_withheld == length(String.split(redacted, "\n")) - 1
      assert micros < 5_000_000, "allowlisted took #{micros}µs"
    end

    allowed = "Result: 1 passed" <> run

    for {text, kept} <- [
          {allowed <> "\n", "Result: 1 passed\n"},
          {allowed <> "x\n", ""},
          {String.duplicate("1", 1_048_576) <> " tests" <> run <> "x\n", ""}
        ] do
      {micros, saved} = bounded(fn -> OutputPolicy.apply("allowlisted", capture(text), []) end)
      assert String.starts_with?(saved.text, kept <> "[insider.oracle: output policy")
      assert micros < 5_000_000, "allowlisted took #{micros}µs"
    end
  end

  # The chunked filter must keep, trim, and count exactly what a line-by-line
  # filter does, across chunk boundaries, partial lines, and omissions.
  test "chunked line filtering agrees with a line-by-line reference" do
    :rand.seed(:exsss, {3, 5, 8})

    pool = [
      "Result: 3 passed",
      "Result: 3 passed\r",
      "Result: 1 passed\r\r",
      "Result: 3 passed junk",
      "Generated my_app app",
      "1 test, 0 failures",
      "Finished in 0.1 seconds (0.0s async, 0.1s sync)",
      "There are no tests to run",
      "Running ExUnit with seed: 1, max_cases: 2",
      "Excluding tags: [:slow]",
      "Including tags: [:x]\r",
      "Failed: 1 test",
      "Skipped: 2 tests",
      "Excluded: 1 property",
      "Invalid: 1 doctest",
      "3 doctests, 0 failures",
      "Compiling 3 files (.ex)",
      "compiling 3 files (.ex)",
      " Result: 3 passed",
      "",
      "\r",
      "x\ry",
      "junk",
      "é",
      <<255, ?R>>,
      String.duplicate("n", 20_000),
      "x" <> String.duplicate("\r", 20_000) <> "y",
      "Result: 2 passed" <> String.duplicate("\r", 20_000),
      "z\r\ry" <> String.duplicate("\r", 3)
    ]

    # 200 rounds generated about 200 MB, which both policies and the
    # reference read: 9 s on a fast host, and past the 60 s test timeout on
    # a loaded 2-vCPU runner (inside :re.replace only because that is where
    # the time goes). Redaction is linear: 50 KB to 800 KB inputs of each
    # worst-case shape scale 2x per 2x. 60 rounds keep every shape, the
    # chunk-crossing lines included.
    for round <- 1..60 do
      lines = for _ <- 1..Enum.random([1, 3, 40, 2_000]), do: Enum.random(pool)
      text = Enum.join(lines, "\n") <> Enum.random(["", "\n", "\r", "\r\n"])
      cut = :rand.uniform(byte_size(text) + 1) - 1

      capture =
        if rem(round, 2) == 0,
          do: capture(text),
          else: %{
            head: binary_part(text, 0, cut),
            tail: binary_part(text, cut, byte_size(text) - cut),
            bytes_omitted: 5
          }

      for policy <- OutputPolicy.policies() do
        saved = OutputPolicy.apply(policy, capture, [])
        assert {saved.text, saved.lines_withheld} == line_reference(policy, capture), policy
      end
    end
  end

  @reference_allowlist [
    ~r/\ARunning ExUnit with seed: \d+, max_cases: \d+\z/,
    ~r/\A(?:Excluding|Including) tags: \[[A-Za-z0-9_:, ]*\]\z/,
    ~r/\AFinished in [0-9.]+ seconds? \([0-9.]+s async, [0-9.]+s sync\)\z/,
    ~r/\AResult: \d+(?:\/\d+)? passed(?: \([0-9a-z,\/ ]+\))?\z/,
    ~r/\A(?:Failed|Skipped|Excluded|Invalid): \d+ (?:tests?|propert(?:y|ies)|doctests?)\z/,
    ~r/\A\d+ (?:tests?|doctests?|propert(?:y|ies))(?:, \d+ [a-z]+)*\z/,
    ~r/\AThere are no tests to run\z/,
    ~r/\ACompiling \d+ files? \(\.[a-z]+\)\z/,
    ~r/\AGenerated [a-z0-9_]+ app\z/
  ]

  defp line_reference(policy, %{head: head, tail: tail, bytes_omitted: 0}) do
    {kept, withheld} = reference_lines(policy, split_lines(head <> tail))
    reference_text(policy, kept, [], [], withheld)
  end

  defp line_reference(policy, %{head: head, tail: tail, bytes_omitted: omitted}) do
    head_lines = head |> String.split("\n") |> Enum.drop(-1)
    tail_lines = tail |> String.split("\n") |> Enum.drop(1) |> drop_final_empty()
    {head_kept, head_withheld} = reference_lines(policy, head_lines)
    {tail_kept, tail_withheld} = reference_lines(policy, tail_lines)
    omission = ["[insider.oracle: #{omitted} bytes omitted]"]
    reference_text(policy, head_kept, omission, tail_kept, head_withheld + tail_withheld)
  end

  defp split_lines(text), do: text |> String.split("\n") |> drop_final_empty()

  defp drop_final_empty(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  defp reference_lines(policy, lines) do
    lines = Enum.map(lines, &String.trim_trailing(&1, "\r"))

    {kept, withheld} =
      Enum.split_with(lines, fn line ->
        policy == "redacted" or
          (String.valid?(line) and Enum.any?(@reference_allowlist, &Regex.match?(&1, line)))
      end)

    {kept, length(withheld)}
  end

  defp reference_text(policy, head, omission, tail, withheld) do
    footer =
      if policy == "allowlisted",
        do: ["[insider.oracle: output policy allowlisted withheld #{withheld} lines]"],
        else: []

    {IO.iodata_to_binary(Enum.map(head ++ omission ++ tail ++ footer, &[&1, ?\n])), withheld}
  end

  test "a single line captured across head and tail without omission is one line" do
    line = String.duplicate("a", 3_000)

    for chunks <- [[line], [line, "\n"]] do
      state = Command.new_state(%{max_output_bytes: 4_096, prefixes: []})

      capture =
        chunks
        |> Enum.reduce(state, &Command.scan(&2, &1))
        |> Command.finish("exited", 0, "exited")

      assert capture.bytes_omitted == 0
      assert byte_size(capture.tail) > 0

      assert OutputPolicy.apply("allowlisted", capture, [String.duplicate("v", 1_025)]).lines_withheld ==
               1

      assert OutputPolicy.apply("allowlisted", capture, []).lines_withheld == 1
    end
  end

  # The single compiled scan must cover exactly what every overlapping
  # occurrence of every value covers.
  test "adversarial overlapping values cover the same bytes as an exhaustive reference" do
    :rand.seed(:exsss, {7, 11, 13})

    for _ <- 1..300 do
      text = random_text(:rand.uniform(80))
      values = for _ <- 1..:rand.uniform(8), do: random_text(:rand.uniform(6))

      saved = OutputPolicy.apply("redacted", capture(text), values)
      assert saved.text == reference(text, values), inspect({text, values})
    end
  end

  defp random_text(length), do: for(_ <- 1..length, into: "", do: <<Enum.random(~c"ab ")>>)

  defp reference(text, values) do
    covered =
      for value <- Enum.uniq(values),
          from <- 0..(byte_size(text) - byte_size(value))//1,
          binary_part(text, from, byte_size(value)) == value,
          at <- from..(from + byte_size(value) - 1),
          into: MapSet.new(),
          do: at

    redacted =
      text
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_byte, at} -> MapSet.member?(covered, at) end)
      |> Enum.map(fn [{_byte, at} | _] = run ->
        if MapSet.member?(covered, at),
          do: "[insider.oracle: redacted]",
          else: for({byte, _at} <- run, into: "", do: <<byte>>)
      end)
      |> IO.iodata_to_binary()

    redacted |> String.split("\n") |> Enum.map_join(&[&1, ?\n])
  end

  test "a value set beyond the bounds withholds all output and says why" do
    %{secrets: count, secret_bytes: bytes, total_bytes: total} = OutputPolicy.bounds()
    text = "Result: 5 passed\nsecret here\n"

    cases = [
      {for(n <- 1..(count + 1), do: "value-#{n}"), "secret_count_exceeded"},
      {[String.duplicate("v", bytes + 1)], "secret_bytes_exceeded"},
      {for(n <- 1..(div(total, bytes - 8) + 1), do: "#{n}-" <> String.duplicate("v", bytes - 8)),
       "secret_bytes_exceeded"}
    ]

    for policy <- OutputPolicy.policies(), {values, reason} <- cases do
      assert OutputPolicy.apply(policy, capture(text), values) == %{
               text: "[insider.oracle: output withheld: #{reason}]\n",
               lines_withheld: 2,
               redactions: 0,
               withheld: reason
             }
    end
  end

  # Long periodic values force a long look-ahead at every start position; the
  # scan stops at its work budget and withholds, still within the time bound.
  test "a scan that exhausts its work budget withholds all output under both policies" do
    values = for n <- 1..16, do: binary_part(String.duplicate("xy", 512), 0, 1024 - n)
    text = String.duplicate("xy", 524_288) <> "\n"

    for policy <- OutputPolicy.policies() do
      {micros, saved} = bounded(fn -> OutputPolicy.apply(policy, capture(text), values) end)

      assert saved == %{
               text: "[insider.oracle: output withheld: redaction_work_exceeded]\n",
               lines_withheld: 1,
               redactions: 0,
               withheld: "redaction_work_exceeded"
             }

      assert micros < 5_000_000, "#{policy} took #{micros}µs"
    end
  end

  test "values at the bounds are still redacted" do
    %{secrets: count, secret_bytes: bytes} = OutputPolicy.bounds()
    long = String.duplicate("q", bytes)
    values = [long | for(n <- 1..(count - 1), do: "value-#{n}")]
    text = "a #{long} b value-7\n"

    assert %{text: "a [insider.oracle: redacted] b [insider.oracle: redacted]\n", withheld: nil} =
             OutputPolicy.apply("redacted", capture(text), values)
  end
end
