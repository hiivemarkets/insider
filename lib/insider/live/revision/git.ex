defmodule Insider.Live.Revision.Git do
  @moduledoc false

  # Resolves `HEAD` to a commit id from a checkout's `.git` directory, or the
  # `.git` file of a linked worktree, a `--separate-git-dir` checkout, or a
  # submodule, including packed refs. Anything it does not recognise yields
  # `nil`.
  #
  # Reads stay inside two directories: the git directory the checkout names,
  # and the common directory its `commondir` names (the git directory itself
  # when there is none). Each must be a real git directory (`HEAD`, plus
  # `objects` and `refs` for a common directory), wherever it lives, as Git
  # accepts. Inside them a name is a fixed file or a plain `refs/…` ref (no
  # empty, `.` or `..` segment, no leading `/`, no control character or
  # backslash), and every path component below the directory is checked with
  # `lstat`: a symbolic link anywhere refuses the read, so a link cannot lead
  # outside.

  @commit ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @unsafe ~r/[\x00-\x1F\x7F\\]/
  @max_file_bytes 1_048_576

  @spec head_commit(Path.t()) :: String.t() | nil
  def head_commit(root) do
    with {:ok, git_dir} <- git_dir(Path.join(root, ".git")),
         {:ok, head} <- read(git_dir, "HEAD"),
         {:ok, common_dir} <- common_dir(git_dir) do
      resolve(String.trim(head), git_dir, common_dir)
    else
      _absent -> nil
    end
  end

  defp git_dir(path) do
    cond do
      File.dir?(path) -> {:ok, Path.expand(path)}
      File.regular?(path) -> path |> Path.dirname() |> read(".git") |> gitdir_file(path)
      true -> :error
    end
  end

  defp gitdir_file({:ok, "gitdir: " <> target}, path) do
    target = String.trim(target)

    if target == "" or String.match?(target, @unsafe),
      do: :error,
      else: {:ok, Path.expand(target, Path.dirname(path))}
  end

  defp gitdir_file(_contents, _path), do: :error

  defp common_dir(git_dir) do
    case read(git_dir, "commondir") do
      {:ok, named} -> named |> String.trim() |> named_common_dir(git_dir)
      :error -> if common_dir?(git_dir), do: {:ok, git_dir}, else: :error
    end
  end

  defp named_common_dir(named, git_dir) do
    common = Path.expand(named, git_dir)

    if named != "" and not String.match?(named, @unsafe) and common_dir?(common),
      do: {:ok, common},
      else: :error
  end

  defp common_dir?(directory) do
    match?({:ok, _head}, read(directory, "HEAD")) and plain_directory?(directory, "objects") and
      plain_directory?(directory, "refs")
  end

  defp plain_directory?(directory, name),
    do: match?({:ok, %{type: :directory}}, File.lstat(Path.join(directory, name)))

  defp resolve("ref: " <> ref, git_dir, common_dir) do
    if ref?(ref) do
      Enum.find_value(Enum.uniq([git_dir, common_dir]), &loose(&1, ref)) ||
        packed(common_dir, ref)
    end
  end

  defp resolve(value, _git_dir, _common_dir), do: commit(value)

  defp loose(directory, ref) do
    case read(directory, ref) do
      {:ok, value} -> commit(String.trim(value))
      :error -> nil
    end
  end

  defp ref?(ref) do
    String.starts_with?(ref, "refs/") and not String.match?(ref, @unsafe) and
      Enum.all?(String.split(ref, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp packed(common_dir, ref) do
    case read(common_dir, "packed-refs") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, " ", parts: 2) do
            [value, ^ref] -> commit(value)
            _other -> nil
          end
        end)

      :error ->
        nil
    end
  end

  defp commit(value), do: if(String.match?(value, @commit), do: value)

  # Reads `name` (slash-separated, already validated) under `directory`. Every
  # component is checked with `lstat` before the next one is entered, so no
  # symbolic link is followed below `directory`; the file itself must be a
  # bounded regular file. Returns `{:ok, contents}` or `:error`, never
  # `{:error, reason}`: an unreadable file, a component that is not a
  # directory, or a path that vanished between `lstat` and `read` all mean an
  # unknown revision, because this runs at compile time.
  defp read(directory, name) do
    segments = String.split(name, "/")

    if Enum.any?(segments, &(&1 in ["", ".", ".."])) do
      :error
    else
      walk(directory, segments)
    end
  end

  defp walk(directory, [last]) do
    path = Path.join(directory, last)

    with {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, contents} <- File.read(path) do
      {:ok, contents}
    else
      _unreadable -> :error
    end
  end

  defp walk(directory, [segment | rest]) do
    path = Path.join(directory, segment)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> walk(path, rest)
      _other -> :error
    end
  end
end
