defmodule Insider.Discovery.ExUnit.OracleRunner.CLITest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.CLI
  alias Insider.Test.OracleRunnerFixture, as: Fixture

  @selected ["test/leak_test.exs"]

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-oracle-cli-" <> suffix)
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    root = Fixture.create(tmp_dir, git?: false, tests: [leak: ":ok"])
    {:ok, tmp_dir: tmp_dir, root: root, profile: Fixture.profile(tmp_dir)}
  end

  test "refuses invalid input with a typed error and creates no run directory", context do
    cases = [
      {[], ["--unknown", "x"], @selected, "invalid_arguments"},
      {[], ["--oracle", "application_env"], @selected, "invalid_arguments"},
      {[{"--oracle", "other"}], [], @selected, "unknown_oracle"},
      {[{"--root", "/nonexistent/insider"}], [], @selected, "invalid_root"},
      {[{"--keys", "a,b"}], [], @selected, "invalid_oracle_inputs"},
      {[{"--event", "a,b"}], [], @selected, "invalid_oracle_inputs"},
      {[{"--key", "line\nbreak"}], [], @selected, "invalid_oracle_inputs"},
      {[{"--context", String.duplicate("c", 1_025)}], [], @selected, "invalid_context"},
      {[{"--timeout-ms", "10"}], [], @selected, "invalid_bounds"},
      {[{"--max-output-bytes", "1"}], [], @selected, "invalid_bounds"},
      {[], [], @selected ++ ["--cover"], "unsupported_test_argument"},
      {[], [], @selected ++ ["--warnings-as-errors"], "unsupported_test_argument"},
      {[], [], [], "invalid_test_selection"},
      {[], [], ["../outside_test.exs"], "invalid_test_selection"},
      {[], [], ["/etc/hosts"], "invalid_test_selection"},
      {[], [], ["test/missing_test.exs"], "invalid_test_selection"},
      {[], [], @selected ++ ["--", "x"], "invalid_test_selection"},
      {[], [], @selected ++ ["--seed", "-1"], "invalid_test_selection"},
      {[{"--profile", "/nonexistent/profile.json"}], [], @selected, "profile_unreadable"}
    ]

    for {overrides, extra, test_arguments, reason} <- cases do
      assert_invalid(
        context,
        arguments(context, overrides, extra) ++ ["--" | test_arguments],
        reason
      )
    end

    assert_invalid(context, arguments(context, [], []) ++ @selected, "missing_test_selection")
  end

  test "refuses a run directory inside the target or one that already exists", context do
    inside = arguments(context, [{"--output", Path.join(context.root, "runs/one")}], [])
    assert_invalid(context, inside ++ ["--" | @selected], "output_inside_target")

    File.mkdir_p!(output_path(context))
    {output, 64} = CLI.run(arguments(context, [], []) ++ ["--" | @selected], System.get_env())
    assert Jason.decode!(output)["reason"] == "output_unavailable"
  end

  test "requires the declared suffix variable in the invoking environment", context do
    profile =
      Fixture.profile(context.tmp_dir, %{
        "db_suffix" => %{"variable" => "FIXTURE_DB_SUFFIX", "source" => "environment"}
      })

    {output, 64} =
      CLI.run(arguments(context, [{"--profile", profile}], []) ++ ["--" | @selected], %{})

    assert Jason.decode!(output)["reason"] == "db_suffix_unavailable"
  end

  test "accepts line selectors and allowlisted test options", context do
    test_arguments = ["test/leak_test.exs:3", "--seed", "0", "--only", "focus", "--trace"]

    {output, status} =
      CLI.run(arguments(context, [], []) ++ ["--" | test_arguments], System.get_env())

    # The fixture is not a Git work tree, so the accepted request stops before running.
    assert status == 4
    assert Jason.decode!(output)["completeness_reason"] == "target_not_git_work_tree"
    assert Jason.decode!(output)["command"]["test_arguments"] == test_arguments
  end

  defp assert_invalid(context, arguments, reason) do
    {output, status} = CLI.run(arguments, System.get_env())

    assert status == 64, "#{reason}: #{output}"

    assert Jason.decode!(output) == %{
             "schema" => "insider.oracle-run-error/v1",
             "status" => "invalid_input",
             "reason" => reason,
             "completeness" => nil
           }

    refute File.exists?(output_path(context))
  end

  defp arguments(context, overrides, extra) do
    base = [
      {"--profile", context.profile},
      {"--root", context.root},
      {"--output", output_path(context)},
      {"--oracle", "application_env"},
      {"--application", "logger"},
      {"--key", "oracle_runner_fixture_key"}
    ]

    overrides
    |> Enum.reduce(base, fn {key, value}, options ->
      List.keystore(options, key, 0, {key, value})
    end)
    |> Enum.flat_map(fn {key, value} -> [key, value] end)
    |> Kernel.++(extra)
  end

  defp output_path(context), do: Path.join(context.tmp_dir, "run")
end
