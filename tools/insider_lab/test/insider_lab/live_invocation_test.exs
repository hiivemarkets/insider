defmodule Insider.Lab.LiveInvocationTest do
  # Help, usage errors and option errors need no target, so these tests never
  # make this VM a distributed node and can run alongside the others.
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Invocation

  @escript "insider-lab live"
  @mix "mix insider.live"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-live-invocation-" <> suffix)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, reports: Path.join(directory, "reports")}
  end

  # Runs one command as the escript (`invocation: "insider-lab live"`) or as
  # the Mix task (no option: the default), and returns everything it wrote.
  defp run(arguments, context, invocation) do
    owner = self()
    reference = make_ref()
    options = [reports_directory: context.reports]
    options = if invocation == @mix, do: options, else: [{:invocation, invocation} | options]

    status =
      CLI.run(
        arguments,
        fn bytes ->
          send(owner, {reference, IO.iodata_to_binary(bytes)})
          :ok
        end,
        options
      )

    assert_received {^reference, output}
    refute_received {^reference, _more}
    {status, output}
  end

  # A command named in the other form: the form, then an operation, OPERATION,
  # help or --help.
  defp command_in(text, form) do
    words = ["OPERATION", "help", "--help" | Map.keys(CLI.operations())]
    Enum.any?(words, &(text =~ ~r/#{Regex.escape(form)} #{Regex.escape(&1)}(?![\w-])/))
  end

  for invocation <- [@escript, @mix] do
    test "--help names #{invocation} in its usage, quick start and examples", context do
      invocation = unquote(invocation)

      for arguments <- [["--help"], ["-h"], ["help"]] do
        {0, text} = run(arguments, context, invocation)

        assert String.starts_with?(text, "#{invocation}: observe a running BEAM node")
        assert text =~ "  #{invocation} OPERATION [--node NAME@HOST --cookie-file PATH]"
        assert text =~ "  #{invocation} help OPERATION "
        assert text =~ ~s(#{invocation} capabilities "${N[@]}" --load)
        assert text =~ ~s(#{invocation} stop "${N[@]}" --session SESSION_ID)
      end
    end

    test "help OPERATION and OPERATION --help name #{invocation}", context do
      invocation = unquote(invocation)
      {0, text} = run(["help", "start"], context, invocation)
      assert {0, ^text} = run(["start", "--help"], context, invocation)

      assert String.starts_with?(text, "#{invocation} start: ")
      assert text =~ ~s(#{invocation} start "${N[@]}" --component logger)
      assert text =~ "#{invocation} --help lists every operation"

      {0, submit} = run(["help", "reports", "submit"], context, invocation)
      assert submit =~ "#{invocation} reports submit --confirm"
    end

    test "a usage error points to #{invocation} --help", context do
      invocation = unquote(invocation)

      for arguments <- [["frobnicate"], [], ["help", "frobnicate"]] do
        {64, output} = run(arguments, context, invocation)
        %{"error" => error} = Jason.decode!(output)

        assert error["code"] == "usage"
        assert error["details"]["help"] == "#{invocation} --help"
        assert error["message"] =~ "#{invocation} --help"
      end
    end

    test "an option error points to #{invocation} help OPERATION", context do
      invocation = unquote(invocation)
      target = ["--node", "app@localhost", "--cookie-file", "/nonexistent/cookie"]

      {64, output} = run(["start", "--frobnicate" | target], context, invocation)
      %{"error" => error} = Jason.decode!(output)

      assert error["code"] == "invalid_options"
      assert error["details"]["help"] == "#{invocation} help start"
    end

    test "parse/2 builds help and errors in #{invocation}" do
      invocation = unquote(invocation)

      assert {:help, overview} = CLI.parse(["--help"], invocation)
      assert String.starts_with?(overview, "#{invocation}: ")
      assert {:help, operation} = CLI.parse(~w(help trace), invocation)
      assert String.starts_with?(operation, "#{invocation} trace: ")

      assert {:error, "usage", %{"help" => help}} = CLI.parse(["frobnicate"], invocation)
      assert help == "#{invocation} --help"

      assert {:error, "invalid_options", %{"help" => help}} =
               CLI.parse(~w(mark --session s --label x --frobnicate), invocation)

      assert help == "#{invocation} help mark"
    end
  end

  test "parse/1 and run/3 without an invocation keep the Mix task's form", context do
    assert CLI.parse(["--help"]) == CLI.parse(["--help"], @mix)
    assert CLI.parse(~w(help start)) == CLI.parse(~w(help start), @mix)

    {0, text} = run(["--help"], context, @mix)
    assert {:help, ^text} = CLI.parse(["--help"])
  end

  test "the escript's help names no command in the Mix task's form", context do
    for arguments <- [["--help"], ["help", "start"], ["help", "watch"], ["help", "reports"]] do
      {0, text} = run(arguments, context, @escript)
      refute command_in(text, @mix), Enum.join(arguments, " ")
    end
  end

  # The overview says how to run the observer from a checkout; that sentence
  # names the Mix task as such, so the escript's help keeps it.
  test "the escript's help keeps the sentences that describe the Mix task", context do
    {0, text} = run(["--help"], context, @escript)
    flat = String.replace(text, ~r/\s+/, " ")

    assert flat =~ "In an Insider checkout: run mix insider.live from tools/insider_lab"
    assert flat =~ "then run insider-lab live in place of mix insider.live, from any directory"
  end

  describe "rewrite/2" do
    test "names the invocation in a command and keeps a sentence about the Mix task" do
      text =
        "Next: mix insider.live digest \"${N[@]}\" --session s --since-mark --human. " <>
          "Run mix insider.live from tools/insider_lab, in place of mix insider.live, " <>
          "or mix insider.live --help, mix insider.live help OPERATION, mix insider.live OPERATION, " <>
          "mix insider.live reports submit --confirm, mix insider.live otlp-receive, " <>
          "mix insider.live started, mix insider.live start-up, mix insider.live help."

      assert Invocation.rewrite(text, @escript) ==
               "Next: insider-lab live digest \"${N[@]}\" --session s --since-mark --human. " <>
                 "Run mix insider.live from tools/insider_lab, in place of mix insider.live, " <>
                 "or insider-lab live --help, insider-lab live help OPERATION, insider-lab live OPERATION, " <>
                 "insider-lab live reports submit --confirm, insider-lab live otlp-receive, " <>
                 "mix insider.live started, mix insider.live start-up, insider-lab live help."
    end

    test "the Mix task's form is the default and leaves text unchanged" do
      assert Invocation.default() == @mix
      text = "mix insider.live digest \"${N[@]}\" --session s"
      assert Invocation.rewrite(text, @mix) == text
    end
  end

  describe "document/2" do
    @captured "mix insider.live start"

    test "rewrites the fields that carry commands" do
      document = %{
        "operation" => "digest",
        "welcome" => %{"read_with" => %{"observer" => "mix insider.live welcome \"${N[@]}\""}},
        "result" => %{
          "next" => "mix insider.live digest \"${N[@]}\" --session s",
          "help" => "mix insider.live help digest",
          "hints" => [%{"command" => "mix insider.live amend \"${N[@]}\" --session s"}],
          "anomalies" => [%{"command" => "mix insider.live trace \"${N[@]}\" --trace-id t"}],
          "anomalies_known" => [%{"command" => "mix insider.live events \"${N[@]}\""}],
          "resume" => %{
            "observer" => ["mix insider.live events \"${N[@]}\" --session s --cursor 4"],
            "join" => "mix insider.live events \"${N[@]}\" --session s --cursor latest"
          },
          "welcome" => %{"read_with" => %{"observer" => "mix insider.live welcome \"${N[@]}\""}},
          "text" =>
            "Digest of s.\n  1. N+1 queries\n     next: mix insider.live trace \"${N[@]}\"\n" <>
              "Next: raise the bound: mix insider.live amend \"${N[@]}\" --session s"
        }
      }

      rewritten = Invocation.document(document, @escript)
      result = rewritten["result"]

      assert rewritten["welcome"]["read_with"]["observer"] ==
               "insider-lab live welcome \"${N[@]}\""

      assert result["welcome"]["read_with"]["observer"] == "insider-lab live welcome \"${N[@]}\""
      assert result["next"] == "insider-lab live digest \"${N[@]}\" --session s"
      assert result["help"] == "insider-lab live help digest"
      assert [%{"command" => "insider-lab live amend " <> _}] = result["hints"]
      assert [%{"command" => "insider-lab live trace " <> _}] = result["anomalies"]
      assert [%{"command" => "insider-lab live events " <> _}] = result["anomalies_known"]
      assert ["insider-lab live events " <> _] = result["resume"]["observer"]
      assert "insider-lab live events " <> _ = result["resume"]["join"]

      assert result["text"] ==
               "Digest of s.\n  1. N+1 queries\n     next: insider-lab live trace \"${N[@]}\"\n" <>
                 "Next: raise the bound: insider-lab live amend \"${N[@]}\" --session s"
    end

    test "rewrites an error's help, and a welcome result in full" do
      error = %{
        "error" => %{
          "help" => "mix insider.live help mark",
          "details" => %{"help" => "mix insider.live help mark", "labels" => [@captured]}
        }
      }

      rewritten = Invocation.document(error, @escript)
      assert rewritten["error"]["help"] == "insider-lab live help mark"
      assert rewritten["error"]["details"]["help"] == "insider-lab live help mark"
      assert rewritten["error"]["details"]["labels"] == [@captured]

      welcome = %{
        "operation" => "welcome",
        "result" => %{"quick_start" => %{"commands" => ["mix insider.live start \"${N[@]}\""]}}
      }

      assert Invocation.document(welcome, @escript)["result"]["quick_start"]["commands"] ==
               ["insider-lab live start \"${N[@]}\""]
    end

    test "never touches captured data, object keys or identifiers" do
      captured_map = %{@captured => 1, "insider-lab live start" => 2, "next" => @captured}

      document = %{
        "operation" => "events",
        "result" => %{
          "reader" => @captured,
          "session_id" => @captured,
          "mark" => %{"label" => @captured},
          "marks" => [%{"label" => @captured}],
          "events" => [
            %{
              "receipt" => 1,
              "event" => %{
                "payload" => %{"message" => @captured, "metadata" => captured_map},
                "attributes" => %{"command" => @captured, "help" => @captured}
              }
            }
          ],
          "text" => "Top errors: 1x logger_message #{@captured}\nNext: read on: #{@captured}"
        }
      }

      rewritten = Invocation.document(document, @escript)
      result = rewritten["result"]

      assert Map.delete(result, "text") == Map.delete(document["result"], "text")

      assert result["text"] ==
               "Top errors: 1x logger_message #{@captured}\nNext: read on: insider-lab live start"

      assert rewritten |> Jason.encode!() |> Jason.decode!() == rewritten
    end

    test "the Mix task's form leaves a document as it is" do
      document = %{"result" => %{"next" => "mix insider.live digest \"${N[@]}\""}}
      assert Invocation.document(document, @mix) == document
    end
  end
end
