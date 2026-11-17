defmodule Insider.Test.OracleRunnerFixture do
  @moduledoc false

  # A disposable Git-tracked Mix project for `mix insider.oracle` tests. Its
  # `test` alias writes `ALIAS_RAN` into the project, so a run that invoked the
  # alias instead of the real task changes the target tree.

  import ExUnit.Assertions

  # Never let a caller's hook or worktree variables point Git at another repository.
  @git_env Insider.Test.GitIsolation.clean()
  # Automatic maintenance and gc are off: a background Git process writing
  # under `.git` must not race the tests' tree reads.
  @git_config [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "maintenance.auto=false",
    "-c",
    "gc.auto=0",
    "-c",
    "user.name=fixture",
    "-c",
    "user.email=fixture@example.invalid"
  ]

  def create(tmp_dir, options \\ []) do
    root = Path.join(tmp_dir, "target")
    File.mkdir_p!(Path.join(root, "test"))
    aliases = {Keyword.get(options, :alias?, true), Keyword.get(options, :run_alias?, false)}
    File.write!(Path.join(root, "mix.exs"), mix_exs(aliases))
    File.write!(Path.join(root, ".gitignore"), "/_build/\n")

    File.write!(Path.join(root, "test/test_helper.exs"), """
    ExUnit.start()
    Application.put_env(:logger, :oracle_runner_fixture_key, :baseline)
    #{Keyword.get(options, :helper, "")}
    """)

    for {name, body} <- Keyword.get(options, :tests, []) do
      File.write!(Path.join(root, "test/#{name}_test.exs"), test_module(name, body))
    end

    for {relative, contents} <- Keyword.get(options, :files, []) do
      File.mkdir_p!(Path.dirname(Path.join(root, relative)))
      File.write!(Path.join(root, relative), contents)
    end

    if Keyword.get(options, :git?, true), do: git_commit(root)
    if Keyword.get(options, :submodule?, false), do: add_submodule(tmp_dir, root)
    root
  end

  def profile(tmp_dir, overrides \\ %{}) do
    document =
      Map.merge(
        %{
          "schema" => "insider.oracle-host-profile/v1",
          "name" => "fixture",
          "mix_command" => [System.find_executable("mix") || flunk("mix unavailable")],
          "test_alias" => "bypass",
          "passthrough_env" => [],
          "db_suffix" => nil
        },
        overrides
      )

    path = Path.join(tmp_dir, "profile-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(document))
    path
  end

  def test_module(name, body) do
    module = name |> to_string() |> Macro.camelize() |> then(&"OracleRunnerFixture.#{&1}Test")

    """
    defmodule #{module} do
      use ExUnit.Case, async: false

      test "#{name}" do
        #{body}
      end
    end
    """
  end

  # Every work-tree file by content, except Mix's ignored build output and Git
  # metadata: the claim under test is about the checkout, not `.git`.
  def tree_checksum(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(excluded?(Path.relative_to(&1, root)) or File.dir?(&1)))
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, root), :crypto.hash(:sha256, File.read!(&1))})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp excluded?(relative),
    do:
      Enum.any?(["_build", ".git"], &(relative == &1 or String.starts_with?(relative, &1 <> "/")))

  def git_status(root) do
    {output, 0} =
      System.cmd("git", ["-C", root, "status", "--porcelain", "--untracked-files=all"],
        env: @git_env
      )

    output
  end

  defp git_commit(root) do
    for arguments <- [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]] do
      {_output, 0} =
        System.cmd("git", ["-C", root | @git_config ++ arguments],
          stderr_to_stdout: true,
          env: @git_env
        )
    end
  end

  # An initialized submodule at `vendor/` with one tracked file, `inner.ex`,
  # committed in the target. `protocol.file.allow` permits the local URL.
  defp add_submodule(tmp_dir, root) do
    inner = Path.join(tmp_dir, "inner-repo")
    File.mkdir_p!(inner)
    File.write!(Path.join(inner, "inner.ex"), "before\n")
    git_commit(inner)

    for arguments <- [
          ["-c", "protocol.file.allow=always", "submodule", "add", "-q", inner, "vendor"],
          ["commit", "-q", "-m", "add submodule"]
        ] do
      {_output, 0} =
        System.cmd("git", ["-C", root | @git_config ++ arguments],
          stderr_to_stdout: true,
          env: @git_env
        )
    end
  end

  # The `run` alias, when present, writes `RUN_ALIAS_RAN`: a run that dispatched
  # it would change the target tree.
  defp mix_exs({test_alias?, run_alias?}) do
    aliases =
      [
        test_alias? && ~s|test: [&mark_alias/1, "test"]|,
        run_alias? && ~s|run: [&mark_run/1, "run"]|
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    """
    defmodule OracleRunnerFixture.MixProject do
      use Mix.Project

      def project, do: [app: :oracle_runner_fixture, version: "0.1.0", aliases: [#{aliases}]]
      def application, do: [extra_applications: [:logger]]

      def mark_alias(_arguments), do: File.write!("ALIAS_RAN", "alias")
      def mark_run(_arguments), do: File.write!("RUN_ALIAS_RAN", "run")
    end
    """
  end
end
