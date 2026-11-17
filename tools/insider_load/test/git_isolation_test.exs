defmodule Insider.LoadHarness.GitIsolationTest do
  # Runs the load harness's git-using tests (revision capture over a fixture
  # repository) in a fresh `mix test` whose git variables point at a
  # sentinel repository, as they do when a pre-commit hook runs the suite,
  # and checks the sentinel is untouched.
  use ExUnit.Case, async: false

  alias Insider.Test.GitIsolation

  @moduletag timeout: 300_000
  @git_using_tests [
    "test/insider/load_harness/boundary_test.exs",
    "--only",
    "git_fixture"
  ]

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-load-git-isolation-" <> suffix)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, sentinel: GitIsolation.sentinel!(Path.join(tmp_dir, "sentinel"))}
  end

  test "git-using tests leave the repository a hook names untouched", %{sentinel: sentinel} do
    before = GitIsolation.fingerprint(sentinel)

    {output, status} =
      System.cmd("mix", ["test" | @git_using_tests],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"} | GitIsolation.poisoned(sentinel)],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/\b[1-9]\d* (tests?|passed)/
    assert GitIsolation.fingerprint(sentinel) == before
  end
end
