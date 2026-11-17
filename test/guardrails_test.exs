defmodule Insider.GuardrailsTest do
  use ExUnit.Case, async: true

  import Bitwise

  @root Path.expand("..", __DIR__)
  @git_hook_variables ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY)

  test "agent tools share one canonical instruction file" do
    assert File.read!(Path.join(@root, "CLAUDE.md")) ==
             "# Claude Code\n\nRead and follow `AGENTS.md`.\n"
  end

  test "required repository guardrails are present" do
    required_paths = [
      ".githooks/commit-msg",
      ".githooks/check-test-pairing",
      ".githooks/pre-commit",
      ".githooks/pre-push",
      ".github/CODEOWNERS",
      ".github/dependabot.yml",
      ".github/pull_request_template.md",
      ".github/workflows/quality.yml",
      "CHANGELOG.md",
      "LICENSES/Apache-2.0.txt",
      "THIRD_PARTY_NOTICES.md"
    ]

    assert Enum.all?(required_paths, &File.exists?(Path.join(@root, &1)))
  end

  test "coverage keeps its threshold and uses the bounded test-only reporter" do
    coverage = Mix.Project.config()[:test_coverage]

    assert coverage[:tool] == Insider.TestSupport.CoverageTool
    assert coverage[:summary] == [threshold: 90]

    # OTP-28-only modules leave the total only below OTP 28; OTP 28+ runs
    # count them (decision 2026-10-23_otp_28_only_modules_...).
    excluded =
      if String.to_integer(System.otp_release()) < 28,
        do: Insider.MixProject.otp_28_only_modules(),
        else: []

    assert coverage[:ignore_modules] == [Insider.TestSupport.CoverageTool | excluded]
  end

  # The exclusion list is derived from the code, so a new OTP-28-only module
  # cannot drop out of the OTP 27 total, or stay in it, unnoticed: the
  # modules that open an isolated trace session (`:trace.session_create/3`,
  # OTP 28) without an OTP 27 mode, and the collectors whose start is refused
  # below OTP 28 (`:ok <- Tracing.preflight()`). The system monitor backend
  # opens a session too, but runs a legacy node-global monitor on OTP 27,
  # so it stays counted.
  test "the OTP-28-only coverage exclusions are exactly the modules that cannot run on OTP 27" do
    sources =
      for path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
          source = File.read!(path),
          [_match, name] <- [Regex.run(~r/defmodule ([\w.]+) do/, source)],
          do: {Module.concat([name]), source}

    session_users =
      for {module, source} <- sources, source =~ ":trace.session_create(", do: module

    otp_27_mode = for {module, source} <- sources, source =~ ":legacy_node_global", do: module

    refused_below_28 =
      for {module, source} <- sources, source =~ ":ok <- Tracing.preflight()", do: module

    assert Insider.Collector.SystemMonitor.Backend in otp_27_mode

    expected = Enum.sort(Enum.uniq((session_users -- otp_27_mode) ++ refused_below_28))
    assert Enum.sort(Insider.MixProject.otp_28_only_modules()) == expected

    # The otel collector is not excluded: its ingest-only mode runs on every
    # OTP release.
    refute Insider.Collector.Otel in expected
  end

  if String.to_integer(System.otp_release()) < 28 do
    test "below OTP 28 the excluded modules only refuse" do
      assert Insider.Collector.Calls.Tracing.preflight() == {:error, :requires_otp_28}
      assert Insider.Collector.Otel.Tracing.preflight() == {:error, :requires_otp_28}
      assert {:error, :requires_otp_28} = Insider.Collector.Otel.Tracing.install(self())
    end
  end

  test "hooks are executable" do
    for name <- ["check-test-pairing", "commit-msg", "pre-commit", "pre-push"] do
      assert {:ok, stat} = File.stat(Path.join([@root, ".githooks", name]))
      assert band(stat.mode, 0o111) != 0
    end
  end

  test "test-pairing hook rejects untested source changes" do
    command = "printf 'lib/insider/new_feature.ex\\n' | .githooks/check-test-pairing"
    {_output, status} = System.cmd("bash", ["-c", command], cd: @root, stderr_to_stdout: true)

    assert status == 1

    command =
      "printf 'lib/insider/new_feature.ex\\ntest/insider/new_feature_test.exs\\n' | " <>
        ".githooks/check-test-pairing"

    {_output, status} = System.cmd("bash", ["-c", command], cd: @root, stderr_to_stdout: true)

    assert status == 0
  end

  test "test-pairing requires tests from each changed project" do
    lab_source = "tools/insider_lab/lib/insider/new_feature.ex"
    lab_test = "tools/insider_lab/test/insider/new_feature_test.exs"
    load_source = "tools/insider_load/lib/insider/new_feature.ex"
    load_test = "tools/insider_load/test/insider/new_feature_test.exs"
    core_test = "test/insider/new_feature_test.exs"

    for {paths, expected_status} <- [
          {[lab_source, core_test], 1},
          {[lab_source, lab_test], 0},
          {[load_source, lab_test], 1},
          {[load_source, load_test], 0},
          {[lab_source, load_source, lab_test], 1},
          {[lab_source, load_source, lab_test, load_test], 0}
        ] do
      command = "printf '#{Enum.join(paths, "\\n")}\\n' | .githooks/check-test-pairing"
      {_output, status} = System.cmd("bash", ["-c", command], cd: @root, stderr_to_stdout: true)
      assert status == expected_status
    end
  end

  test "commit-message hook accepts only the project convention" do
    path = Path.join(System.tmp_dir!(), "insider-commit-message-#{System.unique_integer()}")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "feat(recorder): bound retained events\n")

    assert {_output, 0} =
             System.cmd(Path.join([@root, ".githooks", "commit-msg"]), [path],
               stderr_to_stdout: true
             )

    File.write!(path, "updated some things\n")

    assert {_output, 1} =
             System.cmd(Path.join([@root, ".githooks", "commit-msg"]), [path],
               stderr_to_stdout: true
             )
  end

  test "CI contains the runtime matrix and authoritative deep gates" do
    workflow = File.read!(Path.join([@root, ".github", "workflows", "quality.yml"]))

    for expected <- [
          ~s(elixir: "1.17"),
          ~s(otp: "27"),
          ~s(elixir: "1.20"),
          ~s(otp: "29"),
          "permissions:",
          "mix deps.get --check-locked",
          "mix quality.deep",
          "mix test --cover",
          "mix deps.audit",
          "mix hex.audit"
        ] do
      assert workflow =~ expected
    end

    refute workflow =~ "- run: mix test\n"
  end

  # Releases publish when `main` bumps the version, through a Hex workload
  # identity bound to the `release` environment, and Hex staged publishing
  # holds each one for approval. No stored key may stand in, and no tag
  # starts a release.
  test "the release workflow publishes a version bump on main in the release environment, without a stored key" do
    workflow = File.read!(Path.join([@root, ".github", "workflows", "release.yml"]))

    for expected <- [
          "branches: [main]",
          "- mix.exs\n",
          "- tools/insider_lab/mix.exs\n",
          "workflow_dispatch:",
          "environment: release",
          "id-token: write",
          "contents: write",
          "cancel-in-progress: false",
          "mix deps.get --check-locked",
          "mix hex.publish --yes",
          "INSIDER_LAB_HEX: \"1\"",
          "https://hex.pm/api/packages/${package}/releases/${VERSION}",
          "https://hex.pm/api/packages/insider/releases/${VERSION}",
          "Version.compare",
          "tag --annotate"
        ] do
      assert workflow =~ expected
    end

    refute workflow =~ "tags:"
    refute workflow =~ "secrets."
    refute workflow =~ "HEX_API_KEY"
  end

  test "pre-commit orchestrates every fast check and propagates failure" do
    {environment, log_path} = stubbed_hook_environment()
    hook = Path.join([@root, ".githooks", "pre-commit"])

    assert {_output, 0} =
             System.cmd("bash", [hook], cd: @root, env: environment, stderr_to_stdout: true)

    calls = File.read!(log_path)
    assert calls =~ "git diff --cached --check"
    assert calls =~ "mix format --check-formatted"
    assert calls =~ "mix compile --warnings-as-errors"
    assert calls =~ "mix test"
    assert calls =~ "mix credo --strict"

    failing_environment = [{"MIX_FAIL_ON", "test"} | environment]

    assert {_output, 23} =
             System.cmd("bash", [hook],
               cd: @root,
               env: failing_environment,
               stderr_to_stdout: true
             )
  end

  # A hook runs with GIT_DIR and GIT_INDEX_FILE set; mix must not inherit
  # them, or a test that runs git in a scratch directory acts on this
  # repository.
  test "pre-commit and pre-push run mix without the git variables the hook inherits" do
    {environment, log_path} = stubbed_hook_environment()
    leaked = for name <- @git_hook_variables, do: {name, "/leaked/#{name}"}

    for name <- ["pre-commit", "pre-push"] do
      File.write!(log_path, "")
      hook = Path.join([@root, ".githooks", name])

      assert {_output, 0} =
               System.cmd("bash", [hook],
                 cd: @root,
                 env: leaked ++ environment,
                 stderr_to_stdout: true
               )

      mix_calls =
        log_path |> File.read!() |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^mix /))

      assert mix_calls != []
      for call <- mix_calls, do: refute(call =~ "/leaked/", "#{name}: #{call}")
    end
  end

  test "pre-push runs both gates and stops on failure" do
    {environment, log_path} = stubbed_hook_environment()
    hook = Path.join([@root, ".githooks", "pre-push"])

    assert {_output, 0} =
             System.cmd("bash", [hook], cd: @root, env: environment, stderr_to_stdout: true)

    calls = File.read!(log_path)
    assert calls =~ "mix quality"
    assert calls =~ "mix ex_dna"

    File.write!(log_path, "")
    failing_environment = [{"MIX_FAIL_ON", "quality"} | environment]

    assert {_output, 23} =
             System.cmd("bash", [hook],
               cd: @root,
               env: failing_environment,
               stderr_to_stdout: true
             )

    refute File.read!(log_path) =~ "mix ex_dna"
  end

  defp stubbed_hook_environment do
    temporary_root =
      Path.join(System.tmp_dir!(), "insider-hooks-#{System.unique_integer([:positive])}")

    bin_path = Path.join(temporary_root, "bin")
    log_path = Path.join(temporary_root, "calls.log")
    File.mkdir_p!(bin_path)
    File.write!(log_path, "")
    on_exit(fn -> File.rm_rf(temporary_root) end)

    write_executable(
      Path.join(bin_path, "git"),
      ~S"""
      #!/usr/bin/env bash
      printf 'git %s\n' "$*" >> "$INSIDER_HOOK_LOG"
      case "$*" in
        "diff --cached --name-only --diff-filter=ACMRD") printf 'README.md\n' ;;
        "diff --quiet --") exit "${GIT_DIRTY_STATUS:-0}" ;;
        "ls-files --others --exclude-standard") ;;
      esac
      """
    )

    write_executable(
      Path.join(bin_path, "mix"),
      ~S"""
      #!/usr/bin/env bash
      printf 'mix %s' "$*" >> "$INSIDER_HOOK_LOG"
      for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
        printf ' %s=%s' "$name" "${!name-}" >> "$INSIDER_HOOK_LOG"
      done
      printf '\n' >> "$INSIDER_HOOK_LOG"
      if [ "${MIX_FAIL_ON:-}" = "$*" ]; then
        exit 23
      fi
      """
    )

    path = "#{bin_path}:#{System.get_env("PATH")}"
    {[{"PATH", path}, {"INSIDER_HOOK_LOG", log_path}], log_path}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
