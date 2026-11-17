defmodule Insider.Discovery.ExUnit.OracleRunnerIntegrationTest do
  # Each test owns a temporary Mix project and run directory; the child
  # processes share nothing, so the cases run concurrently.
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.CLI
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy
  alias Insider.Discovery.ExUnit.OracleRunner.Record
  alias Insider.Test.OracleRunnerFixture, as: Fixture

  @leak "Application.put_env(:logger, :oracle_runner_fixture_key, :leaked)"
  @launcher_variables ~w(BINDIR EMU PROGNAME PWD ROOTDIR SHLVL __CF_USER_TEXT_ENCODING)

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-oracle-runner-" <> suffix)
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "confirms a leaked key, saves the run, and leaves the target unchanged", %{
    tmp_dir: tmp_dir
  } do
    root =
      Fixture.create(tmp_dir,
        tests: [
          leak: """
          #{@leak}
          IO.puts("FIXTURE_ENV=" <> Enum.join(Map.keys(System.get_env()), ","))
          IO.puts("FIXTURE_DECLARED=" <> System.get_env("ORACLE_RUNNER_DECLARED", "unset"))
          IO.puts("FIXTURE_SUFFIX=" <> System.get_env("FIXTURE_DB_SUFFIX", "unset"))
          """
        ]
      )

    profile =
      Fixture.profile(tmp_dir, %{
        "passthrough_env" => ["ORACLE_RUNNER_DECLARED", "ORACLE_RUNNER_MISSING"],
        "db_suffix" => %{"variable" => "FIXTURE_DB_SUFFIX", "value" => "_fixture"}
      })

    checksum = Fixture.tree_checksum(root)
    environment = Map.put(System.get_env(), "ORACLE_RUNNER_DECLARED", "declared-value")

    {stdout, status, run} =
      run(tmp_dir, root, profile, ["test/leak_test.exs", "--seed", "0"],
        environment: environment,
        extra: ["--output-policy", "redacted"]
      )

    assert status == 2
    record = run.record
    assert stdout == run.json
    assert record["status"] == "confirmed"
    assert record["completeness"] == "complete"
    assert record["completeness_reason"] == nil
    assert record["outcome"] == "confirmed"
    assert record["oracle_result"]["status"] == "changed"
    assert record["oracle_result"]["context"] == "insider-oracle-run:" <> record["run_id"]
    assert record["exit"] == %{"status" => 0, "termination" => "exited"}
    assert record["suite"] == %{"excluded" => 0, "failures" => 0, "skipped" => 0, "total" => 1}
    assert record["runtime"]["host_helpers"] == 1
    assert record["cleanup"] == %{"process" => "exited", "verdict" => "unchanged"}
    assert record["target"]["fingerprint_before"] == record["target"]["fingerprint_after"]
    assert {record["target"]["changed_path_count"], record["target"]["changed_paths"]} == {0, []}
    assert record["target"]["git_revision"] =~ ~r/\A[0-9a-f]{40}\z/

    oracle_copy = File.read!(Path.join(run.directory, "oracle/application_env_test.exs"))
    oracle_source = Application.app_dir(:insider_lab, "priv/oracles/application_env_test.exs")
    assert oracle_copy == File.read!(oracle_source)
    assert record["oracle"]["source_sha256"] == sha256(oracle_copy)

    for {_name, %{"file" => file, "sha256" => digest}} <- record["command"]["runner_files"],
        do: assert(sha256(File.read!(Path.join(run.directory, file))) == digest)

    assert record["command"]["arguments"] == ["test", "test/leak_test.exs", "--seed", "0"]

    assert String.ends_with?(
             record["command"]["environment"]["set"]["MIX_EXS"],
             "/run/runner/mix.exs"
           )

    environment_record = record["command"]["environment"]
    assert environment_record["passthrough_present"] == ["ORACLE_RUNNER_DECLARED"]
    assert environment_record["passthrough_absent"] == ["ORACLE_RUNNER_MISSING"]
    assert environment_record["set"]["FIXTURE_DB_SUFFIX"] == "_fixture"
    refute run.json =~ "declared-value"

    output = File.read!(Path.join(run.directory, "output.txt"))
    assert record["output"]["policy"] == "redacted"
    assert record["output"]["redactions"] == 1
    assert output =~ "FIXTURE_DECLARED=[insider.oracle: redacted]"
    assert output =~ "FIXTURE_SUFFIX=_fixture"
    refute_in_run(run, "declared-value")
    child_variables = output |> line_value("FIXTURE_ENV=") |> String.split(",")
    allowed = Map.keys(environment_record["set"]) ++ ["HOME", "PATH", "ORACLE_RUNNER_DECLARED"]
    leaked = (Map.keys(System.get_env()) -- allowed) -- @launcher_variables
    assert child_variables -- (allowed ++ @launcher_variables) == []
    assert Enum.filter(child_variables, &(&1 in leaked)) == []
    refute "MIX_EXS" in child_variables

    assert Fixture.tree_checksum(root) == checksum
    assert Fixture.git_status(root) == ""
    refute File.exists?(Path.join(root, "ALIAS_RAN"))
  end

  test "a selected test that writes into the target is reported with the changed path", %{
    tmp_dir: tmp_dir
  } do
    root =
      Fixture.create(tmp_dir,
        tests: [
          writer:
            ~s|File.write!("written_by_test.txt", "x")\nFile.write!("test/test_helper.exs", "")|
        ]
      )

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/writer_test.exs"])

    assert status == 70
    assert run.record["completeness_reason"] == "target_changed"
    assert run.record["cleanup"]["verdict"] == "changed"
    assert run.record["oracle_result"]["status"] == "unchanged"
    assert run.record["target"]["changed_path_count"] == 2

    assert run.record["target"]["changed_paths"] == [
             "test/test_helper.exs",
             "written_by_test.txt"
           ]
  end

  test "reports a healthy control as not reproduced without a test alias", %{tmp_dir: tmp_dir} do
    root =
      Fixture.create(tmp_dir,
        alias?: false,
        tests: [
          restore: """
          original = Application.fetch_env!(:logger, :oracle_runner_fixture_key)
          #{@leak}
          Application.put_env(:logger, :oracle_runner_fixture_key, original)
          """
        ]
      )

    profile = Fixture.profile(tmp_dir, %{"test_alias" => "absent"})
    {_stdout, status, run} = run(tmp_dir, root, profile, ["test/restore_test.exs"])

    assert status == 0
    assert run.record["status"] == "not_reproduced"
    assert run.record["completeness"] == "complete"
    assert run.record["oracle_result"]["status"] == "unchanged"
    assert run.record["cleanup"]["verdict"] == "unchanged"
  end

  test "a test VM that exits before the suite finishes is an infrastructure failure", %{
    tmp_dir: tmp_dir
  } do
    root = Fixture.create(tmp_dir, tests: [halt: "System.halt(0)"])
    {_stdout, status, run} = run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/halt_test.exs"])

    assert status == 70
    assert run.record["exit"] == %{"status" => 0, "termination" => "exited"}
    assert run.record["completeness"] == "infrastructure_failure"
    assert run.record["completeness_reason"] == "result_line_missing"
    assert run.record["outcome"] == "infrastructure_failure"
    assert run.record["oracle_result"] == nil
  end

  test "a failing selected test is not evidence even when the oracle reported", %{
    tmp_dir: tmp_dir
  } do
    root = Fixture.create(tmp_dir, tests: [failing: "#{@leak}\nassert false"])

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/failing_test.exs"])

    assert status == 70
    assert run.record["exit"]["status"] != 0
    assert run.record["completeness_reason"] == "test_command_failed"
    assert run.record["suite"]["failures"] == 1
    assert run.record["oracle_result"]["status"] == "changed"
    assert run.record["outcome"] == "infrastructure_failure"
  end

  test "bounds saved output and reports truncation as a distinct state", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [noisy: ~s|IO.puts(String.duplicate("x", 20_000))|])

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/noisy_test.exs"],
        max_output_bytes: 4_096
      )

    assert status == 5
    assert run.record["status"] == "truncated"
    assert run.record["outcome"] == "not_reproduced"
    assert run.record["oracle_result"]["status"] == "unchanged"
    assert run.record["output"]["truncated"]
    omitted = run.record["output"]["bytes_omitted"]
    assert omitted > 20_000 - 4_096
    saved = File.read!(Path.join(run.directory, "output.txt"))
    assert saved =~ "[insider.oracle: #{omitted} bytes omitted]"
    assert saved =~ "[insider.oracle: output policy allowlisted withheld"
    refute saved =~ "xxxx"
    assert run.record["output"]["lines_withheld"] > 0
  end

  test "a host run alias never executes and does not block the test task", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, run_alias?: true, tests: [leak: @leak])
    checksum = Fixture.tree_checksum(root)
    {_stdout, status, run} = run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/leak_test.exs"])

    assert status == 2
    assert run.record["status"] == "confirmed"
    refute File.exists?(Path.join(root, "RUN_ALIAS_RAN"))
    refute File.exists?(Path.join(root, "ALIAS_RAN"))
    assert Fixture.tree_checksum(root) == checksum
  end

  test "passthrough values printed anywhere never reach a saved artifact", %{tmp_dir: tmp_dir} do
    secret = "canary-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    body = """
    value = System.fetch_env!("ORACLE_RUNNER_SECRET")
    IO.puts("stdout " <> value)
    IO.puts(:stderr, "stderr " <> value)
    IO.puts(String.duplicate("n", 9_000) <> value <> String.duplicate("n", 9_000))
    assert value == "different", "assertion " <> value
    """

    root = Fixture.create(tmp_dir, tests: [canary: body])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => ["ORACLE_RUNNER_SECRET"]})
    environment = Map.put(System.get_env(), "ORACLE_RUNNER_SECRET", secret)

    for {policy, index} <- Enum.with_index(["allowlisted", "redacted"]) do
      {stdout, status, run} =
        run(tmp_dir, root, profile, ["test/canary_test.exs"],
          environment: environment,
          directory: "run-#{index}",
          max_output_bytes: 16_384,
          extra: ["--output-policy", policy]
        )

      assert status == 70
      assert run.record["completeness_reason"] == "test_command_failed"
      assert run.record["output"]["redactions"] >= 1
      refute stdout =~ secret
      refute_in_run(run, secret)
    end
  end

  test "multiline and CRLF passthrough values never reach a saved artifact", %{tmp_dir: tmp_dir} do
    values = %{
      "ORACLE_RUNNER_MULTILINE" => "line-one-canary\nline-two-canary",
      "ORACLE_RUNNER_SUMMARY" => "Generated review_canary app\nThere are no tests to run",
      "ORACLE_RUNNER_CRLF" => "crlf-one-canary\r\ncrlf-two-canary"
    }

    body = """
    for name <- #{inspect(Map.keys(values))}, do: IO.puts(System.fetch_env!(name))
    IO.puts(String.duplicate("n", 9_000) <> System.fetch_env!("ORACLE_RUNNER_MULTILINE"))
    """

    root = Fixture.create(tmp_dir, tests: [multiline: body])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => Map.keys(values)})
    environment = Map.merge(System.get_env(), values)

    for {policy, index} <- Enum.with_index(["allowlisted", "redacted"]),
        limit <- [1_048_576, 16_384] do
      {stdout, _status, run} =
        run(tmp_dir, root, profile, ["test/multiline_test.exs"],
          environment: environment,
          directory: "run-#{index}-#{limit}",
          max_output_bytes: limit,
          extra: ["--output-policy", policy]
        )

      assert run.record["output"]["redactions"] >= 3

      for fragment <-
            ~w(line-one-canary line-two-canary review_canary crlf-one-canary crlf-two-canary) do
        refute stdout =~ fragment
        refute_in_run(run, fragment)
      end
    end
  end

  # Many overlapping passthrough values over a large capture
  # must finish within the bounded redaction and save nothing of them.
  test "64 overlapping passthrough values over a 1 MiB capture are redacted", %{tmp_dir: tmp_dir} do
    values = Map.new(1..64, &{"ORACLE_RUNNER_OVERLAP_#{&1}", String.duplicate("@", &1)})

    body = """
    IO.puts(String.duplicate("@", 2_000_000))
    """

    root = Fixture.create(tmp_dir, tests: [overlap: body])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => Enum.sort(Map.keys(values))})
    environment = Map.merge(System.get_env(), values)

    for {policy, index} <- Enum.with_index(["allowlisted", "redacted"]) do
      {stdout, _status, run} =
        run(tmp_dir, root, profile, ["test/overlap_test.exs"],
          environment: environment,
          directory: "run-#{index}",
          max_output_bytes: 1_048_576,
          extra: ["--output-policy", policy]
        )

      refute Map.has_key?(run.record["output"], "withheld")
      refute stdout =~ "@@"
      refute File.read!(Path.join(run.directory, "output.txt")) =~ "@"
      refute_in_run(run, String.duplicate("@", 64))
    end
  end

  test "a passthrough value beyond the redaction bound withholds the whole output", %{
    tmp_dir: tmp_dir
  } do
    secret = "canary-" <> String.duplicate("z", 2_048)

    body = """
    IO.puts("Result: " <> System.fetch_env!("ORACLE_RUNNER_LARGE"))
    """

    root = Fixture.create(tmp_dir, tests: [large: body])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => ["ORACLE_RUNNER_LARGE"]})
    environment = Map.put(System.get_env(), "ORACLE_RUNNER_LARGE", secret)

    for {policy, index} <- Enum.with_index(["allowlisted", "redacted"]) do
      {_stdout, _status, run} =
        run(tmp_dir, root, profile, ["test/large_test.exs"],
          environment: environment,
          directory: "run-#{index}",
          extra: ["--output-policy", policy]
        )

      assert run.record["output"]["withheld"] == "secret_bytes_exceeded"
      assert run.record["output"]["lines_withheld"] > 0

      assert File.read!(Path.join(run.directory, "output.txt")) ==
               "[insider.oracle: output withheld: secret_bytes_exceeded]\n"

      refute_in_run(run, "canary-")
    end
  end

  test "more replaced spans than the cap withhold the output and persist the reason", %{
    tmp_dir: tmp_dir
  } do
    %{redactions: cap} = OutputPolicy.bounds()

    body = """
    value = System.fetch_env!("ORACLE_RUNNER_REPEATED")
    IO.puts(String.duplicate(value <> " ", #{cap + 1}))
    """

    root = Fixture.create(tmp_dir, tests: [repeated: body])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => ["ORACLE_RUNNER_REPEATED"]})
    environment = Map.put(System.get_env(), "ORACLE_RUNNER_REPEATED", "canary-q7x9")

    for {policy, index} <- Enum.with_index(["allowlisted", "redacted"]) do
      {_stdout, _status, run} =
        run(tmp_dir, root, profile, ["test/repeated_test.exs"],
          environment: environment,
          directory: "run-#{index}",
          extra: ["--output-policy", policy]
        )

      assert {:ok, persisted} = Record.decode(File.read!(Path.join(run.directory, "run.json")))
      assert persisted["output"]["withheld"] == "redaction_count_exceeded"
      assert persisted["output"]["redactions"] == 0
      assert persisted["output"]["lines_withheld"] > 0

      assert File.read!(Path.join(run.directory, "output.txt")) ==
               "[insider.oracle: output withheld: redaction_count_exceeded]\n"

      refute_in_run(run, "canary-q7x9")
    end
  end

  test "a profile cannot pass through MIX_EXS, so the host test alias never runs", %{
    tmp_dir: tmp_dir
  } do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])
    profile = Fixture.profile(tmp_dir, %{"passthrough_env" => ["MIX_EXS"]})
    environment = Map.put(System.get_env(), "MIX_EXS", Path.join(root, "mix.exs"))

    {output, 64} =
      CLI.run(
        base_arguments(profile, root, Path.join(tmp_dir, "run")) ++ ["--", "test/leak_test.exs"],
        environment
      )

    assert Jason.decode!(output)["reason"] == "profile_invalid_passthrough_env"
    refute File.exists?(Path.join(tmp_dir, "run"))
    refute File.exists?(Path.join(root, "ALIAS_RAN"))
  end

  test "a report for a different key than requested is never a confirmation", %{
    tmp_dir: tmp_dir
  } do
    root =
      Fixture.create(tmp_dir,
        helper: ~s|System.put_env("INSIDER_ORACLE_KEY", "other_key")|,
        tests: [other: "Application.put_env(:logger, :other_key, :changed)"]
      )

    {_stdout, status, run} = run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/other_test.exs"])

    assert status == 70
    assert run.record["completeness_reason"] == "result_identity_mismatch"
    assert run.record["outcome"] == "infrastructure_failure"
    assert run.record["oracle_result"] == nil
    assert run.record["oracle"]["inputs"]["INSIDER_ORACLE_KEY"] == "oracle_runner_fixture_key"
  end

  test "a symlinked output parent that resolves inside the target is refused", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])
    checksum = Fixture.tree_checksum(root)
    link = Path.join(tmp_dir, "outside-looking")
    File.ln_s!(Path.join(root, "test"), link)

    {output, 64} =
      CLI.run(
        base_arguments(Fixture.profile(tmp_dir), root, Path.join(link, "run")) ++
          ["--", "test/leak_test.exs"]
      )

    assert Jason.decode!(output)["reason"] == "output_inside_target"
    refute File.exists?(Path.join(root, "test/run"))
    assert Fixture.tree_checksum(root) == checksum
  end

  test "a symlinked root is resolved, and its whole Git work tree is protected", %{
    tmp_dir: tmp_dir
  } do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])
    root_link = Path.join(tmp_dir, "root-link")
    File.ln_s!(root, root_link)
    profile = Fixture.profile(tmp_dir)

    {output, 64} =
      CLI.run(
        base_arguments(profile, root_link, Path.join(root, "run")) ++ ["--", "test/leak_test.exs"]
      )

    assert Jason.decode!(output)["reason"] == "output_inside_target"

    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/mix.exs"), "")
    nested = base_arguments(profile, Path.join(root, "nested"), Path.join(root, "beside-nested"))
    {output, 64} = CLI.run(nested ++ ["--", "mix.exs"])
    assert Jason.decode!(output)["reason"] == "output_inside_target"
    File.rm_rf!(Path.join(root, "nested"))

    {_stdout, 2, run} = run(tmp_dir, root_link, profile, ["test/leak_test.exs"])
    assert run.record["target"]["root"] == real(root)
    assert Fixture.git_status(root) == ""
  end

  # A write inside a submodule used to give an
  # `unchanged` verdict and a clean run. The runner now refuses the target.
  test "a target with a submodule is refused, so a write inside it is never a clean run", %{
    tmp_dir: tmp_dir
  } do
    root =
      Fixture.create(tmp_dir,
        submodule?: true,
        tests: [submodule: ~s|File.write!("vendor/inner.ex", "after\\n")|]
      )

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/submodule_test.exs"])

    assert status == 4
    assert run.record["status"] == "unsupported_source"
    assert run.record["completeness_reason"] == "target_has_nested_repository"
    assert run.record["target"]["fingerprint_error"] == "target_has_nested_repository"
    assert run.record["exit"]["termination"] == "not_started"
    assert run.record["cleanup"]["verdict"] == "unverified"
    assert File.read!(Path.join(root, "vendor/inner.ex")) == "before\n"
  end

  # The selected test restores access to an
  # unreadable directory, edits a file in it, and removes access again. That
  # used to be a clean `unchanged` run; the target is now refused up front.
  test "an unreadable tracked path is refused, so an edit behind it is never clean", %{
    tmp_dir: tmp_dir
  } do
    body = """
    File.chmod!("locked", 0o755)
    File.write!("locked/data.txt", "after\\n")
    File.chmod!("locked", 0o000)
    """

    root =
      Fixture.create(tmp_dir, files: [{"locked/data.txt", "before\n"}], tests: [locked: body])

    locked = Path.join(root, "locked")
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/locked_test.exs"])

    assert status == 4
    assert run.record["completeness_reason"] == "target_path_unreadable"
    assert run.record["target"]["fingerprint_error"] == "target_path_unreadable"
    assert run.record["exit"]["termination"] == "not_started"
    File.chmod!(locked, 0o755)
    assert File.read!(Path.join(locked, "data.txt")) == "before\n"
  end

  test "an unreadable untracked path is refused the same way", %{tmp_dir: tmp_dir} do
    body = """
    File.chmod!("scratch", 0o755)
    File.write!("scratch/file.txt", "after\\n")
    File.chmod!("scratch", 0o000)
    """

    root = Fixture.create(tmp_dir, tests: [scratch: body])
    scratch = Path.join(root, "scratch")
    File.mkdir_p!(scratch)
    File.write!(Path.join(scratch, "file.txt"), "before\n")
    File.chmod!(scratch, 0o000)
    on_exit(fn -> File.chmod(scratch, 0o755) end)

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/scratch_test.exs"])

    assert status == 4
    assert run.record["completeness_reason"] == "target_path_unreadable"
    assert run.record["exit"]["termination"] == "not_started"
  end

  test "a path that becomes unreadable during the run is never a clean verdict", %{
    tmp_dir: tmp_dir
  } do
    body = """
    #{@leak}
    File.mkdir_p!("hidden")
    File.write!("hidden/file.txt", "x")
    File.chmod!("hidden", 0o000)
    """

    root = Fixture.create(tmp_dir, tests: [hide: body])
    on_exit(fn -> File.chmod(Path.join(root, "hidden"), 0o755) end)

    {_stdout, status, run} = run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/hide_test.exs"])

    assert status == 70
    assert run.record["completeness_reason"] == "target_path_unreadable"
    assert run.record["cleanup"]["verdict"] == "unverified"
    assert run.record["target"]["fingerprint_after"] == nil
  end

  test "a fingerprint over its content budget is reported and nothing runs", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/leak_test.exs"],
        extra: ["--fingerprint-max-bytes", "16"]
      )

    assert status == 70
    assert run.record["completeness_reason"] == "target_fingerprint_budget_exceeded"
    assert run.record["target"]["fingerprint_error"] == "target_content_limit_exceeded"
    assert run.record["target"]["fingerprint_budget"]["max_content_bytes"] == 16
    assert run.record["exit"]["termination"] == "not_started"
    refute File.exists?(Path.join(root, "_build"))
  end

  test "a selection that executes no test is empty, not clean", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/leak_test.exs", "--only", "absent_tag"])

    assert status == 3
    assert run.record["status"] == "empty_selection"
    assert run.record["completeness_reason"] == "no_tests_executed"
    assert run.record["outcome"] == "not_observed"
    assert run.record["suite"]["total"] == run.record["suite"]["excluded"]
  end

  test "refuses a host whose test alias contradicts the profile", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])
    checksum = Fixture.tree_checksum(root)
    profile = Fixture.profile(tmp_dir, %{"test_alias" => "absent"})
    {_stdout, status, run} = run(tmp_dir, root, profile, ["test/leak_test.exs"])

    assert status == 4
    assert run.record["status"] == "unsupported_source"
    assert run.record["completeness_reason"] == "test_alias_present"
    assert run.record["suite"] == nil
    assert Fixture.tree_checksum(root) == checksum
    refute File.exists?(Path.join(root, "ALIAS_RAN"))
  end

  test "terminates the process group at the deadline", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [blocked: "Process.sleep(:infinity)"])

    {_stdout, status, run} =
      run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/blocked_test.exs"], timeout_ms: 3_000)

    assert status == 70
    assert run.record["completeness_reason"] == "deadline_exceeded"
    assert run.record["exit"] == %{"status" => nil, "termination" => "deadline_exceeded"}
    assert run.record["cleanup"]["process"] == "group_terminated"
  end

  test "refuses a target that is not a Git work tree without running it", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, git?: false, tests: [leak: @leak])
    {_stdout, status, run} = run(tmp_dir, root, Fixture.profile(tmp_dir), ["test/leak_test.exs"])

    assert status == 4
    assert run.record["completeness_reason"] == "target_not_git_work_tree"
    assert run.record["exit"] == %{"status" => nil, "termination" => "not_started"}
    assert run.record["target"]["fingerprint_before"] == nil
    assert run.record["cleanup"] == %{"process" => "not_started", "verdict" => "unverified"}
    refute File.exists?(Path.join(root, "_build"))
  end

  test "reports a missing mix command as an infrastructure failure", %{tmp_dir: tmp_dir} do
    root = Fixture.create(tmp_dir, tests: [leak: @leak])
    profile = Fixture.profile(tmp_dir, %{"mix_command" => ["insider-oracle-runner-missing-mix"]})
    {_stdout, status, run} = run(tmp_dir, root, profile, ["test/leak_test.exs"])

    assert status == 70
    assert run.record["completeness_reason"] == "command_not_found"
    assert run.record["command"]["executable"] == nil
    assert run.record["cleanup"]["verdict"] == "unchanged"
  end

  defp run(tmp_dir, root, profile, test_arguments, options \\ []) do
    directory = Path.join(tmp_dir, Keyword.get(options, :directory, "run"))

    arguments =
      base_arguments(profile, root, directory) ++
        ["--timeout-ms", Integer.to_string(Keyword.get(options, :timeout_ms, 120_000))] ++
        if(options[:max_output_bytes],
          do: ["--max-output-bytes", Integer.to_string(options[:max_output_bytes])],
          else: []
        ) ++ Keyword.get(options, :extra, []) ++ ["--" | test_arguments]

    {stdout, status} = CLI.run(arguments, Keyword.get(options, :environment, System.get_env()))
    json = File.read!(Path.join(directory, "run.json"))
    {:ok, record} = Record.decode(json)
    assert Record.exit_status(record) == status
    {stdout, status, %{directory: directory, json: json, record: record}}
  end

  defp base_arguments(profile, root, directory) do
    ["--profile", profile, "--root", root, "--output", directory, "--oracle", "application_env"] ++
      ["--application", "logger", "--key", "oracle_runner_fixture_key"]
  end

  defp refute_in_run(run, value) do
    for file <- Path.wildcard(Path.join(run.directory, "**"), match_dot: true),
        File.regular?(file) do
      refute File.read!(file) =~ value, "#{file} contains the passthrough value"
    end
  end

  defp real(path) do
    {resolved, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(resolved)
  end

  defp line_value(output, prefix) do
    output
    |> String.split("\n")
    |> Enum.find_value(
      &(String.starts_with?(&1, prefix) && String.replace_prefix(&1, prefix, ""))
    )
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
