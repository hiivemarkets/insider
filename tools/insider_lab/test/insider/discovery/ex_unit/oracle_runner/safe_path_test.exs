defmodule Insider.Discovery.ExUnit.OracleRunner.SafePathTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner
  alias Insider.Discovery.ExUnit.OracleRunner.Oracle
  alias Insider.Discovery.ExUnit.OracleRunner.SafePath

  @unsafe [
    "../x",
    "/abs/x",
    "oracle/../../x",
    "oracle/../x",
    "oracle/./x",
    "a//b",
    "",
    ".",
    "x/",
    "with\nnewline",
    <<0xFF>>
  ]

  test "accepts only plain relative names" do
    for path <- [
          "oracle/application_env_test.exs",
          "runner/mix.exs",
          "runner/overlay/test_helper.exs"
        ],
        do: assert(SafePath.relative?(path), path)

    for path <- @unsafe ++ [nil, 1], do: refute(SafePath.relative?(path), inspect(path))
  end

  test "joins only under the base directory" do
    assert SafePath.join_under("/runs/one", "runner/mix.exs") == {:ok, "/runs/one/runner/mix.exs"}

    for path <- @unsafe,
        do: assert(SafePath.join_under("/runs/one", path) == :error, inspect(path))
  end

  # oracle_runner.ex stage/2 joins the oracle's file name into a path.
  # Everything this test creates, including where an escape would land, is under
  # one unique parent, and only that parent is removed.
  test "staging refuses an oracle outside the closed registry or an unsafe file name", %{} do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-stage-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    output = Path.join(parent, "run")
    File.mkdir_p!(output)
    on_exit(fn -> File.rm_rf!(parent) end)
    spec = Oracle.fetch!("application_env")

    for forged <- [
          %{spec | file: "../escape.exs"},
          %{spec | file: Path.join(parent, "absolute-escape.exs")},
          %{spec | file: "nested/../../escape.exs"},
          %{spec | id: "unknown"}
        ] do
      assert OracleRunner.stage(output, forged) == {:error, "artifact_path_unsafe"}
    end

    assert File.ls!(parent) == ["run"]
    assert File.ls!(output) == []
    assert {:ok, staged} = OracleRunner.stage(output, spec)
    assert Map.has_key?(staged, "oracle/application_env_test.exs")
  end

  # oracle_runner.ex runner_set/2: the child's runner
  # paths come from the same validated staging plan, or the run fails closed.
  test "runner paths are the staged files and refuse a forged oracle", %{} do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-runner-paths-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    output = Path.join(parent, "run")
    root = Path.join(parent, "target")
    File.mkdir_p!(output)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(parent) end)
    spec = Oracle.fetch!("application_env")

    for forged <- [
          %{spec | file: "../escape.exs"},
          %{spec | file: Path.join(parent, "absolute-escape.exs")},
          %{spec | file: "nested/../../escape.exs"},
          %{spec | id: "unknown"}
        ] do
      assert OracleRunner.runner_paths(output, root, forged) == {:error, "artifact_path_unsafe"}
    end

    assert {:ok, paths} = OracleRunner.runner_paths(output, root, spec)
    assert {:ok, _staged} = OracleRunner.stage(output, spec)

    assert paths["INSIDER_ORACLE_RUNNER_HOST_MIX_EXS"] == Path.join(root, "mix.exs")
    assert File.regular?(paths["MIX_EXS"])
    assert File.regular?(paths["INSIDER_ORACLE_RUNNER_ORACLE"])
    assert File.regular?(Path.join(paths["INSIDER_ORACLE_RUNNER_OVERLAY"], "test_helper.exs"))

    for {_name, path} <- Map.delete(paths, "INSIDER_ORACLE_RUNNER_HOST_MIX_EXS"),
        do: assert(String.starts_with?(path, output <> "/"))
  end
end
