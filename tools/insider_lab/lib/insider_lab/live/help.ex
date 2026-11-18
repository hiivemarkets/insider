defmodule Insider.Lab.Live.Help do
  @moduledoc false

  # The observer's usage text (`--help`, `help OPERATION`, and `OPERATION
  # --help`), built from the welcome document's own tables: the quick start,
  # the observer commands with their summaries and examples, and each flag's
  # value syntax. Each text names the command it was run with (`invocation`:
  # `mix insider.live` or `insider-lab live`), and the welcome's commands are
  # rewritten to it (`Insider.Lab.Live.Invocation`); the sentence on running
  # the Mix task in a checkout always names the Mix task. It needs no target,
  # so it shows this checkout's Insider; `welcome --full` shows the target's.

  alias Insider.Lab.Live.Invocation
  alias Insider.Live.Welcome

  @mix_task "mix insider.live"

  @doc "The overview: usage, the quick start, the operations, the target flags, and the tools to pair with."
  @spec overview(String.t()) :: String.t()
  def overview(invocation) do
    contract = Welcome.contract()
    quick_start = contract["quick_start"]
    pairs = contract["pairs_with"]
    commands = Welcome.observer_commands()
    width = commands |> Enum.map(&String.length(&1["name"])) |> Enum.max()
    pair_width = pairs |> Enum.map(&String.length(&1["tool"])) |> Enum.max()

    lines(
      [
        "#{invocation}: observe a running BEAM node on this machine with Insider Live.",
        "",
        "Usage:",
        "  #{invocation} OPERATION [--node NAME@HOST --cookie-file PATH] [OPTIONS]",
        "  #{invocation} help OPERATION      flags, values and examples for one operation",
        "  #{invocation} welcome \"${N[@]}\" --full   the whole reference, read from the target",
        "",
        "Quick start (#{quick_start["setup"]}):"
      ] ++
        indent(quick_start["steps"]) ++
        ["", "Core commands:"] ++
        ["  #{quick_start["load"]}    # first contact: loads Insider into a node without it"] ++
        indent(quick_start["commands"]) ++
        ["", "Operations:"] ++
        Enum.map(commands, &"  #{String.pad_trailing(&1["name"], width)}  #{&1["summary"]}") ++
        ["", "Target flags (\"${N[@]}\"):"] ++
        flags("capabilities", Welcome.observer_target_flags()) ++
        ["", "Pairs well with:"] ++
        Enum.map(pairs, &"  #{String.pad_trailing(&1["tool"], pair_width)}  #{&1["use_for"]}") ++
        [
          "  welcome \"${N[@]}\" gives how to detect and run each (pairs_with) and which this node has (runtime.pairs_with_available)."
        ] ++
        [
          "",
          "Output: one JSON document per command on stdout (watch prints NDJSON); Mix's Compiling and " <>
            "\"Waiting for lock\" notices go to stderr, so parse stdout alone. Exit status: " <>
            exit_statuses() <> ".",
          "This observer is the insider_lab package. The insider package, the library it loads into the node, has no Mix tasks. " <>
            "Install from Hex: mix escript.install hex insider_lab, then run insider-lab live OPERATION from any directory. " <>
            "In an Insider checkout: run #{@mix_task} from tools/insider_lab, or build the escript there (mix escript.build) " <>
            "and run ./insider-lab live OPERATION. Every form takes the same flags. Several agents at once, or a tool that " <>
            "merges stderr into stdout: use the escript; it starts no Mix, so it prints no Mix notices and never waits on the build lock."
        ]
    )
    |> Invocation.rewrite(invocation)
  end

  @doc "One operation's summary, flags with their value syntax, and examples."
  @spec operation(String.t(), String.t()) :: String.t()
  def operation(name, invocation) do
    command = Enum.find(Welcome.observer_commands(), &(&1["name"] == name))

    lines(
      ["#{invocation} #{name}: #{command["summary"]}"] ++
        section("Required:", flags(name, command["required"])) ++
        section("Options:", flags(name, command["optional"])) ++
        target(name, command["target"]) ++
        section("Examples:", indent(command["examples"])) ++
        [
          "",
          "\"${N[@]}\" is #{Welcome.contract()["quick_start"]["setup"]}. " <>
            "#{invocation} --help lists every operation; #{invocation} welcome \"${N[@]}\" --full is the whole reference."
        ]
    )
    |> Invocation.rewrite(invocation)
  end

  @doc """
  The value `flag` takes in `operation`, noting when it repeats, or a note
  that the observer has no such flag.
  """
  @spec value(String.t(), String.t() | nil) :: String.t()
  def value(operation, flag) when is_binary(flag) do
    case Welcome.observer_option(operation, flag) do
      %{"value" => value, "repeatable" => true} -> value <> "; repeat the flag for several"
      %{"value" => value} -> value
      nil -> "not an observer flag"
    end
  end

  def value(_operation, nil), do: "not an observer flag"

  defp target(_name, "none"), do: ["", "Takes no target."]

  defp target(name, mode) do
    section(
      "Target (\"${N[@]}\", #{mode}):",
      flags(name, Welcome.observer_target_flags())
    )
  end

  defp flags(operation, flags) do
    width = flags |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    Enum.map(flags, &"  #{String.pad_trailing(&1, width)}  #{value(operation, &1)}")
  end

  defp section(_title, []), do: []
  defp section(title, lines), do: ["", title | lines]

  defp indent(lines), do: Enum.map(lines, &("  " <> &1))

  defp exit_statuses do
    Welcome.observer_exit_statuses()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map_join(", ", fn {status, code} -> "#{code} #{status}" end)
  end

  defp lines(lines), do: Enum.join(lines, "\n") <> "\n"
end
