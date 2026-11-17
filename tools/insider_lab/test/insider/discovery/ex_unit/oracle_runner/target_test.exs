defmodule Insider.Discovery.ExUnit.OracleRunner.TargetTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Target
  alias Insider.Test.OracleRunnerFixture, as: Fixture

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-oracle-target-" <> suffix)
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir, root: Fixture.create(tmp_dir, tests: [leak: ":ok"])}
  end

  test "fingerprints tracked and untracked files and reports exactly what changed", %{root: root} do
    {:ok, before, before_entries} = Target.fingerprint(root)
    assert before["files"] == 4

    File.write!(Path.join(root, "untracked.txt"), "x")
    File.write!(Path.join(root, "test/test_helper.exs"), "changed")
    {:ok, after_fingerprint, after_entries} = Target.fingerprint(root)

    assert after_fingerprint != before

    assert Target.changed_paths(before_entries, after_entries) == [
             "test/test_helper.exs",
             "untracked.txt"
           ]
  end

  test "a content budget stops at an oversized file", %{root: root} do
    File.write!(Path.join(root, "big.bin"), :binary.copy("z", 100_000))
    budget = %{Target.default_budget() | "max_content_bytes" => 50_000}

    assert Target.fingerprint(root, budget) == {:error, "target_content_limit_exceeded"}
  end

  test "listing and file-count budgets are enforced", %{root: root} do
    assert Target.fingerprint(root, %{Target.default_budget() | "max_listing_bytes" => 8}) ==
             {:error, "target_listing_limit_exceeded"}

    assert Target.fingerprint(root, %{Target.default_budget() | "max_files" => 2}) ==
             {:error, "target_file_limit_exceeded"}
  end

  test "an overdue Git process is killed at the deadline", %{tmp_dir: tmp_dir, root: root} do
    marker = Path.join(tmp_dir, "slow-git.pid")
    slow_git = Path.join(tmp_dir, "slow-git")
    File.write!(slow_git, "#!/bin/sh\necho $$ > #{marker}\nexec sleep 30\n")
    File.chmod!(slow_git, 0o755)

    started = System.monotonic_time(:millisecond)
    # Two seconds lets the fake Git start and record its pid even when the full
    # concurrent suite loads the machine (500 ms was observed too short once);
    # the claim under test is the kill at the deadline, not spawn latency.
    budget = %{Target.default_budget() | "timeout_ms" => 2_000}

    assert Target.fingerprint(root, budget, slow_git) == {:error, "target_fingerprint_timeout"}
    assert System.monotonic_time(:millisecond) - started < 10_000

    # SIGKILL is delivered asynchronously, and a killed process stays visible
    # to `kill -0` until it is reaped. Thus the check waits a bounded time for
    # the process to go. A fake Git that is not killed lives for 30 s.
    pid = marker |> File.read!() |> String.trim()
    assert gone?(pid, System.monotonic_time(:millisecond) + 5_000)
  end

  defp gone?(pid, deadline) do
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)

    cond do
      status != 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        gone?(pid, deadline)
    end
  end

  # Git lists a submodule or a nested repository as one directory entry and
  # never its files, so its contents cannot be fingerprinted: fail closed.
  test "a target with an initialized submodule cannot be fingerprinted", %{tmp_dir: tmp_dir} do
    root = Fixture.create(Path.join(tmp_dir, "with-submodule"), submodule?: true)
    assert File.read!(Path.join(root, "vendor/inner.ex")) == "before\n"
    assert Target.fingerprint(root) == {:error, "target_has_nested_repository"}
  end

  test "an untracked nested repository is refused the same way", %{root: root} do
    nested = Path.join(root, "scratch")
    File.mkdir_p!(nested)
    git_env = Insider.Test.GitIsolation.clean()

    {_output, 0} =
      System.cmd("git", ["-C", nested, "init", "-q"], stderr_to_stdout: true, env: git_env)

    File.write!(Path.join(nested, "file.ex"), "x")

    assert Target.fingerprint(root) == {:error, "target_has_nested_repository"}
  end

  # A path the fingerprint cannot read makes it incomplete.
  test "an unreadable directory holding a tracked file fails the fingerprint", %{tmp_dir: tmp_dir} do
    root = Fixture.create(Path.join(tmp_dir, "tracked"), files: [{"locked/data.txt", "before\n"}])
    locked = Path.join(root, "locked")
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    assert Target.fingerprint(root) == {:error, "target_path_unreadable"}
  end

  test "an unreadable untracked directory fails the fingerprint", %{root: root} do
    scratch = Path.join(root, "scratch")
    File.mkdir_p!(scratch)
    File.write!(Path.join(scratch, "file.txt"), "x")
    File.chmod!(scratch, 0o000)
    on_exit(fn -> File.chmod(scratch, 0o755) end)

    assert Target.fingerprint(root) == {:error, "target_path_unreadable"}
  end

  test "a listed file whose contents cannot be read fails the fingerprint", %{root: root} do
    secret = Path.join(root, "mix.exs")
    File.chmod!(secret, 0o000)
    on_exit(fn -> File.chmod(secret, 0o644) end)

    assert Target.fingerprint(root) == {:error, "target_path_unreadable"}
  end

  # A Git that writes stderr without end must be cut
  # off at the bounded diagnostic prefix, stopped, and leave no scratch file.
  test "unbounded Git stderr is cut off, the process stopped, and scratch removed", %{
    tmp_dir: tmp_dir,
    root: root
  } do
    scratch = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(scratch)
    marker = Path.join(tmp_dir, "noisy-git.pid")
    noisy_git = Path.join(tmp_dir, "noisy-git")
    File.write!(noisy_git, "#!/bin/sh\nprintf '%s' $$ > #{marker}\nexec yes stderr-noise >&2\n")
    File.chmod!(noisy_git, 0o755)

    started = System.monotonic_time(:millisecond)
    budget = %{Target.default_budget() | "timeout_ms" => 30_000, "max_listing_bytes" => 64}

    assert Target.fingerprint(root, budget, noisy_git, scratch) ==
             {:error, "target_listing_failed"}

    assert System.monotonic_time(:millisecond) - started < 10_000
    assert File.ls!(scratch) == []

    pid = marker |> File.read!() |> String.trim()
    assert {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "the captured diagnostic never exceeds the listing budget" do
    assert Target.stderr_limit(%{"max_listing_bytes" => 64}) == 64
    assert Target.stderr_limit(Target.default_budget()) == 4_096
  end

  test "budget errors are distinguished from unavailable identity" do
    assert Target.budget_error?("target_fingerprint_timeout")
    assert Target.budget_error?("target_content_limit_exceeded")
    refute Target.budget_error?("target_listing_failed")
  end

  test "revision and work-tree root are read without a work tree as nil", %{tmp_dir: tmp_dir} do
    plain = Path.join(tmp_dir, "plain")
    File.mkdir_p!(plain)
    assert Target.toplevel(plain) == nil
    assert Target.revision(plain) == nil
  end
end
