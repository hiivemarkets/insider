defmodule Insider.Discovery.ExUnit.OracleRunner.Target do
  @moduledoc false

  # Read-only identity of a target checkout: its Git revision and a content
  # fingerprint of every tracked and untracked, not-ignored path under the root.
  # Git runs with optional locks disabled so that reading never rewrites the
  # shared index. Every Git call has a deadline and an output bound, and a
  # fingerprint has a wall-clock, listing-byte, file-count, and content-byte
  # budget; an overdue Git process is killed.

  alias Insider.Discovery.ExUnit.OracleRunner.Command
  alias Insider.Event.Canonical

  @method "git-ls-files-sha256/v1"
  @chunk_bytes 65_536
  @query_timeout_ms 10_000
  @query_bytes 65_536
  @default_budget %{
    "timeout_ms" => 120_000,
    "max_listing_bytes" => 16_777_216,
    "max_files" => 200_000,
    "max_content_bytes" => 4_294_967_296
  }
  @budget_errors ~w(target_fingerprint_timeout target_listing_limit_exceeded
                    target_file_limit_exceeded target_content_limit_exceeded)
  @errors @budget_errors ++
            ~w(target_listing_failed target_fingerprint_failed target_has_nested_repository
               target_path_unreadable)
  @git_environment [
    {~c"GIT_OPTIONAL_LOCKS", ~c"0"},
    {~c"GIT_DIR", false},
    {~c"GIT_WORK_TREE", false},
    {~c"GIT_INDEX_FILE", false},
    {~c"GIT_COMMON_DIR", false},
    {~c"GIT_OBJECT_DIRECTORY", false},
    {~c"GIT_CEILING_DIRECTORIES", false}
  ]
  @diagnostic_bytes 4_096
  # $1 stderr file, $2 status file, $3 byte limit, $4 head, then Git and its
  # arguments. fd 3 carries the port's stdout past the stderr pipe.
  @listing_script ~S'''
  err=$1 st=$2 lim=$3 head=$4
  shift 4
  { { "$@" 2>&1 1>&3 3>&-; printf '%s' "$?" > "$st"; } | "$head" -c "$lim" > "$err"; } 3>&1
  '''

  @spec fingerprint_method() :: String.t()
  def fingerprint_method, do: @method

  @spec default_budget() :: %{String.t() => pos_integer()}
  def default_budget, do: @default_budget

  @spec budget_error?(String.t()) :: boolean()
  def budget_error?(reason), do: reason in @budget_errors

  @spec errors() :: [String.t()]
  def errors, do: @errors

  @spec toplevel(Path.t(), String.t() | nil) :: String.t() | nil
  def toplevel(root, git \\ nil) do
    case query(root, ["rev-parse", "--show-toplevel"], git) do
      {:ok, output} -> output |> String.trim_trailing("\n") |> nonempty()
      :error -> nil
    end
  end

  @spec revision(Path.t(), String.t() | nil) :: String.t() | nil
  def revision(root, git \\ nil) do
    case query(root, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], git) do
      {:ok, output} -> output |> String.trim() |> revision_value()
      :error -> nil
    end
  end

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp revision_value(value) do
    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value), do: value
  end

  @spec fingerprint(Path.t(), map(), String.t() | nil, Path.t() | nil) ::
          {:ok, %{String.t() => term()}, [list()]} | {:error, String.t()}
  def fingerprint(root, budget \\ @default_budget, git \\ nil, scratch \\ nil) do
    deadline = System.monotonic_time(:millisecond) + budget["timeout_ms"]
    arguments = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    listing = {:separate, scratch || System.tmp_dir!(), stderr_limit(budget)}

    with {:ok, listing} <-
           bounded_git(root, arguments, git, deadline, budget["max_listing_bytes"], listing),
         paths = listing |> String.split(<<0>>, trim: true) |> Enum.uniq() |> Enum.sort(),
         :ok <-
           if(length(paths) <= budget["max_files"],
             do: :ok,
             else: {:error, "target_file_limit_exceeded"}
           ),
         {:ok, entries} <- entries(root, paths, deadline, budget["max_content_bytes"]) do
      {:ok, %{"files" => length(entries), "sha256" => Canonical.sha256(entries)}, entries}
    end
  rescue
    _error -> {:error, "target_fingerprint_failed"}
  end

  # Paths whose kind or content differs, or that exist on only one side.
  @spec changed_paths([list()], [list()]) :: [String.t()]
  def changed_paths(before_entries, after_entries) do
    before_map = Map.new(before_entries, fn [path | identity] -> {path, identity} end)
    after_map = Map.new(after_entries, fn [path | identity] -> {path, identity} end)

    (Map.keys(before_map) ++ Map.keys(after_map))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(before_map, &1) == Map.get(after_map, &1)))
    |> Enum.sort()
  end

  defp entries(root, paths, deadline, content_budget) do
    paths
    |> Enum.reduce_while({[], content_budget}, fn relative, {entries, remaining} ->
      case entry(root, relative, deadline, remaining) do
        {:ok, entry, remaining} -> {:cont, {[entry | entries], remaining}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      {entries, _remaining} -> {:ok, Enum.reverse(entries)}
    end
  end

  defp entry(root, relative, deadline, remaining) do
    if System.monotonic_time(:millisecond) > deadline,
      do: {:error, "target_fingerprint_timeout"},
      else: stat_entry(Path.join(root, relative), relative, deadline, remaining)
  end

  defp stat_entry(path, relative, deadline, remaining) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > remaining ->
        {:error, "target_content_limit_exceeded"}

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, digest, read} <- file_digest(path, deadline, remaining),
             do: {:ok, [relative, "file", digest], remaining - read}

      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, [relative, "symlink", link_target(path)], remaining}

      # Git lists only files, symlinks, and repository boundaries (a submodule
      # or an untracked nested repository) whose contents it never lists, so a
      # directory here would hide writes inside it. Fail closed.
      {:ok, %File.Stat{type: :directory}} ->
        {:error, "target_has_nested_repository"}

      {:ok, %File.Stat{type: type}} ->
        {:ok, [relative, Atom.to_string(type), nil], remaining}

      {:error, :enoent} ->
        {:ok, [relative, "missing", nil], remaining}

      # A path the fingerprint cannot inspect could hide any change behind it.
      {:error, _reason} ->
        {:error, "target_path_unreadable"}
    end
  end

  # The budget is enforced while reading, so a file that grows after `lstat`
  # still cannot exceed it.
  defp file_digest(path, deadline, remaining) do
    path
    |> File.stream!(@chunk_bytes)
    |> Enum.reduce_while({:crypto.hash_init(:sha256), 0}, fn chunk, {hash, read} ->
      read = read + byte_size(chunk)

      cond do
        read > remaining ->
          {:halt, {:error, "target_content_limit_exceeded"}}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, {:error, "target_fingerprint_timeout"}}

        true ->
          {:cont, {:crypto.hash_update(hash, chunk), read}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      {hash, read} -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), read}
    end
  rescue
    File.Error -> {:error, "target_path_unreadable"}
  end

  defp link_target(path) do
    case File.read_link(path) do
      {:ok, target} -> target
      {:error, reason} -> "unreadable:" <> Atom.to_string(reason)
    end
  end

  defp query(root, arguments, git) do
    deadline = System.monotonic_time(:millisecond) + @query_timeout_ms

    case bounded_git(root, arguments, git, deadline, @query_bytes, :merged) do
      {:ok, output} -> {:ok, output}
      {:error, _reason} -> :error
    end
  end

  # Any stderr from the listing already makes it incomplete, so only a short
  # diagnostic prefix is ever kept: at most 4 KiB and never more than the
  # listing byte budget.
  @doc false
  @spec stderr_limit(map()) :: pos_integer()
  def stderr_limit(budget), do: min(@diagnostic_bytes, budget["max_listing_bytes"])

  # A query merges stderr so Git diagnostics do not reach the caller's terminal.
  # The listing keeps stdout alone because its NUL-separated paths are parsed.
  # Git exits 0 even when it could not open a directory and says so only on
  # stderr, so the listing's stderr goes through `head -c LIMIT` into a private
  # scratch file while Git runs: once the limit is reached `head` exits and Git
  # is stopped by SIGPIPE on its next diagnostic, so the file never exceeds the
  # limit. Git's own exit status is written to a second scratch file. The paths
  # are positional shell arguments, not exported to Git.
  defp bounded_git(root, arguments, git, deadline, max_bytes, mode) do
    case git || System.find_executable("git") do
      nil ->
        {:error, "target_listing_failed"}

      executable when mode == :merged ->
        open_git(
          executable,
          ["-C", root | arguments],
          root,
          [:stderr_to_stdout],
          @git_environment
        )
        |> collect([], 0, deadline, max_bytes)

      executable ->
        {:separate, scratch, limit} = mode
        id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        stderr = Path.join(scratch, "insider-git-stderr-" <> id)
        status = Path.join(scratch, "insider-git-status-" <> id)

        wrapper =
          [
            "-c",
            @listing_script,
            "sh",
            stderr,
            status,
            Integer.to_string(limit),
            head_executable()
          ] ++
            [executable, "-C", root | arguments]

        try do
          "/bin/sh"
          |> open_git(wrapper, root, [], @git_environment)
          |> collect([], 0, deadline, max_bytes)
          |> listing_complete(stderr, status)
        after
          File.rm(stderr)
          File.rm(status)
        end
    end
  end

  defp head_executable do
    Enum.find(["/usr/bin/head", "/bin/head"], &File.regular?/1) ||
      raise "fixed head executable unavailable"
  end

  defp open_git(executable, arguments, root, extra, environment) do
    options = [args: arguments, cd: root, env: environment]

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :hide | extra] ++ options
      )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {port, os_pid}
      nil -> {port, nil}
    end
  end

  defp listing_complete({:ok, _listing} = result, stderr, status) do
    case {File.read(status), File.stat(stderr)} do
      {{:ok, "0"}, {:ok, %File.Stat{size: 0}}} ->
        result

      {_status, {:ok, %File.Stat{size: size}}} when size > 0 ->
        {:error, listing_diagnostic(stderr)}

      _failed ->
        {:error, "target_listing_failed"}
    end
  end

  defp listing_complete(error, _stderr, _status), do: error

  defp listing_diagnostic(stderr) do
    head = File.open!(stderr, [:read, :binary], &IO.binread(&1, @diagnostic_bytes))

    if is_binary(head) and String.contains?(head, ["could not open", "Permission denied"]),
      do: "target_path_unreadable",
      else: "target_listing_failed"
  end

  defp collect({port, os_pid}, chunks, size, deadline, max_bytes),
    do: collect(port, os_pid, chunks, size, deadline, max_bytes)

  defp collect(port, os_pid, chunks, size, deadline, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) > max_bytes ->
        stop(port, os_pid)
        {:error, "target_listing_limit_exceeded"}

      {^port, {:data, data}} ->
        collect(port, os_pid, [data | chunks], size + byte_size(data), deadline, max_bytes)

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _status}} ->
        {:error, "target_listing_failed"}
    after
      remaining ->
        stop(port, os_pid)
        {:error, "target_fingerprint_timeout"}
    end
  end

  defp stop(port, os_pid) do
    if os_pid, do: Command.kill_group(os_pid)
    Port.close(port)
  catch
    :error, :badarg -> true
  end
end
