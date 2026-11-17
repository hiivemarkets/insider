defmodule Insider.Test.GitIsolation do
  @moduledoc false

  # Git hooks export GIT_DIR and GIT_INDEX_FILE (and Git may export the
  # others), and every git command a test starts inherits them, so a test
  # that runs git in a scratch directory would act on the repository the
  # hook belongs to instead. `clean/0` is the child environment that removes
  # them; `sentinel!/1`, `poisoned/1` and `fingerprint/1` let a test prove that
  # a git-using test leaves a repository named by those variables untouched.

  @variables ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY)

  @doc "The git variables a hook can leak, each removed from a child environment."
  @spec clean() :: [{String.t(), nil}]
  def clean, do: Enum.map(@variables, &{&1, nil})

  @doc "Creates a committed repository at `path` without host configuration."
  @spec sentinel!(Path.t()) :: Path.t()
  def sentinel!(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "sentinel.txt"), "sentinel\n")
    git!(path, ["init", "-q"])
    # No background maintenance, which would change the sentinel by itself.
    git!(path, ["config", "maintenance.auto", "false"])
    git!(path, ["config", "gc.auto", "0"])
    git!(path, ["add", "sentinel.txt"])
    git!(path, ["commit", "-q", "-m", "sentinel"])
    path
  end

  @doc "A child environment whose git variables all point into `sentinel`."
  @spec poisoned(Path.t()) :: [{String.t(), String.t()}]
  def poisoned(sentinel) do
    git = Path.join(sentinel, ".git")

    [
      {"GIT_DIR", git},
      {"GIT_WORK_TREE", sentinel},
      {"GIT_INDEX_FILE", Path.join(git, "index")},
      {"GIT_COMMON_DIR", git},
      {"GIT_OBJECT_DIRECTORY", Path.join(git, "objects")}
    ]
  end

  @doc "Every file under `directory` with its SHA-256, and every directory."
  @spec fingerprint(Path.t()) :: %{String.t() => String.t() | :directory}
  def fingerprint(directory) do
    directory
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Map.new(fn path ->
      key = Path.relative_to(path, directory)

      if File.dir?(path),
        do: {key, :directory},
        else: {key, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
    end)
  end

  defp git!(directory, arguments) do
    environment =
      clean() ++
        [
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_AUTHOR_NAME", "sentinel"},
          {"GIT_AUTHOR_EMAIL", "sentinel@example.invalid"},
          {"GIT_COMMITTER_NAME", "sentinel"},
          {"GIT_COMMITTER_EMAIL", "sentinel@example.invalid"}
        ]

    {_output, 0} =
      System.cmd("git", arguments, cd: directory, env: environment, stderr_to_stdout: true)

    :ok
  end
end
