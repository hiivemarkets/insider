defmodule Insider.Lab.LiveShellExamplesTest do
  # The welcome and the docs teach agents to set `N` once and pass it to
  # every observer command. A string in `N` splits into words in bash but
  # stays one word in zsh (the macOS default), so the first command of the
  # quick start failed there with `invalid_options`. These tests run the
  # commands through each shell that exists on this machine, with a shell
  # function in place of `mix`, and parse the words it receives with the
  # observer's own parser.
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.CLI
  alias Insider.Live.Welcome

  @root Path.expand("../../../..", __DIR__)
  @shells Enum.filter(["bash", "zsh"], &System.find_executable/1)

  # Placeholders in the examples that the parser checks for shape.
  @placeholders [{"TRACE_ID", String.duplicate("a", 32)}]

  test "the welcome's setup and every generated example give the same words in each shell" do
    setup = Welcome.contract()["quick_start"]["setup"]
    examples = Welcome.example_commands()
    assert setup =~ ~r/\AN=\(.+\)\z/
    assert length(examples) > 20

    for shell <- @shells do
      words = run(shell, [setup | examples])

      for {example, argv} <- Enum.zip(examples, words) do
        assert Enum.take(argv, 1) != [], "#{shell}: #{example}"
        assert ["--node", "NAME@HOST", "--cookie-file", "PATH"] -- argv == [] or no_target?(argv)
        refute Enum.any?(argv, &String.contains?(&1, " --cookie-file ")), "#{shell}: #{example}"
        assert {:ok, _command} = CLI.parse(argv), "#{shell}: #{example} gave #{inspect(argv)}"
      end
    end
  end

  test "every observer command line in the documentation parses in each shell" do
    commands = documented_commands()
    assert length(commands) > 40

    for shell <- @shells do
      words = run(shell, Enum.map(commands, &elem(&1, 1)))

      for {{source, line}, argv} <- Enum.zip(commands, words) do
        assert parses?(CLI.parse(argv)), "#{shell}: #{source}: #{line} gave #{inspect(argv)}"
      end
    end
  end

  # The docs teach three forms of one command: the escript installed from
  # Hex, the escript built in a checkout, and the Mix task. The test above
  # parses each line, so each form must appear for it to be checked.
  test "the documentation shows the Hex escript, the checkout escript, and the Mix task" do
    commands = Enum.map(documented_commands(), &elem(&1, 1))

    for form <- ["insider-lab live ", "./insider-lab live ", "mix insider.live "] do
      assert Enum.any?(commands, &String.starts_with?(&1, form)), form
    end
  end

  defp parses?({:error, _code, _details}), do: false
  defp parses?(_parsed), do: true

  defp no_target?([operation | _rest]), do: operation in ["report", "reports", "--help", "help"]

  # Every line of a fenced block in the README, `docs/`, the guides, the
  # usage rules, and the Lab README that runs `mix insider.live` or the
  # escript's `live` (built here, `./insider-lab`, or installed on the `PATH`
  # from Hex, `insider-lab`), with its `\` continuation lines joined.
  defp documented_commands do
    paths =
      ["README.md", "usage-rules.md", "tools/insider_lab/README.md"] ++
        (Path.wildcard(Path.join(@root, "{docs,guides}/**/*.md"))
         |> Enum.map(&Path.relative_to(&1, @root)))

    for path <- paths,
        line <- path |> then(&File.read!(Path.join(@root, &1))) |> fenced_lines(),
        command = String.trim_leading(line),
        String.match?(
          command,
          ~r/\A(timeout \d+ )?(mix insider\.live|(\.\/)?insider-lab live)( |\z)/
        ),
        do: {path, command}
  end

  defp fenced_lines(text) do
    text
    |> String.replace(~r/\\\n\s*/, "")
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {fenced, acc} ->
      cond do
        String.match?(line, ~r/^\s*```/) -> {not fenced, acc}
        fenced -> {fenced, [line | acc]}
        true -> {fenced, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # Runs each command with `mix` and the escript replaced by a function that
  # prints the words it received, after the welcome's own setup line.
  defp run(shell, [setup | _] = lines) do
    script =
      [
        ~S|mix() { shift; for word in "$@"; do printf '%s\037' "$word"; done; printf '\036'; }|,
        ~S|timeout() { shift; "$@"; }|,
        if(String.starts_with?(setup, "N="),
          do: nil,
          else: "N=(--node NAME@HOST --cookie-file PATH)"
        )
        | Enum.map(lines, &shell_line/1)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {output, status} = System.cmd(shell, ["-c", script], stderr_to_stdout: true)

    assert status == 0,
           "#{shell} stopped: #{output |> String.split(~r/[\x1e\x1f]/) |> List.last()}"

    output
    |> String.split("\x1e", trim: true)
    |> Enum.map(&String.split(&1, "\x1f", trim: true))
  end

  defp shell_line(line) do
    line
    |> String.replace(~r/\A(\.\/)?insider-lab live/, "mix insider.live")
    |> then(fn line ->
      Enum.reduce(@placeholders, line, fn {from, to}, acc -> String.replace(acc, from, to) end)
    end)
  end
end
