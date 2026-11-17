defmodule Insider.LoadHarness.Revision do
  @moduledoc false

  @maximum_lock_bytes 8 * 1_024 * 1_024
  @lock_chunk_bytes 65_536
  @status_timeout_ms 30_000
  # Git reads these from its environment before `-C`, so one inherited from a
  # hook (`GIT_DIR`, `GIT_INDEX_FILE`) would make it describe that repository
  # instead of `project_root`.
  @git_variables ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY)

  @spec capture(Path.t()) :: {:ok, map()} | {:error, :revision_unavailable}
  def capture(project_root) when is_binary(project_root) do
    with {:ok, git_sha} <- git(project_root, ["rev-parse", "HEAD"]),
         {:ok, tree_sha} <- git(project_root, ["rev-parse", "HEAD^{tree}"]),
         {:ok, clean?} <- git_clean?(project_root),
         {:ok, lock_digest} <- lock_digest(Path.join(project_root, "mix.lock")) do
      {:ok,
       %{
         "revision" => %{
           "git_sha" => git_sha,
           "tree_sha" => tree_sha,
           "clean" => clean?
         },
         "mix_lock_sha256" => lock_digest
       }}
    else
      _error -> {:error, :revision_unavailable}
    end
  rescue
    _error -> {:error, :revision_unavailable}
  catch
    _kind, _reason -> {:error, :revision_unavailable}
  end

  def capture(_project_root), do: {:error, :revision_unavailable}

  defp git(project_root, arguments) do
    case System.cmd("git", ["-C", project_root | arguments],
           stderr_to_stdout: true,
           env: Enum.map(@git_variables, &{&1, nil})
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {_output, _status} -> {:error, :git_failed}
    end
  rescue
    _error -> {:error, :git_failed}
  end

  defp git_clean?(project_root) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_failed}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-C", project_root, "status", "--porcelain=v1", "--untracked-files=all"],
            env: Enum.map(@git_variables, &{String.to_charlist(&1), false})
          ])

        collect_status(port, false, System.monotonic_time(:millisecond) + @status_timeout_ms)
    end
  rescue
    _error -> {:error, :git_failed}
  end

  defp collect_status(port, dirty?, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Port.close(port)
      {:error, :git_failed}
    else
      receive do
        {^port, {:data, bytes}} -> collect_status(port, dirty? or bytes != "", deadline)
        {^port, {:exit_status, 0}} -> {:ok, not dirty?}
        {^port, {:exit_status, _status}} -> {:error, :git_failed}
      after
        remaining ->
          Port.close(port)
          {:error, :git_failed}
      end
    end
  end

  defp lock_digest(path) do
    result =
      path
      |> File.stream!(@lock_chunk_bytes, [:read, :binary])
      |> Enum.reduce_while({:crypto.hash_init(:sha256), 0}, fn bytes, {digest, size} ->
        size = size + byte_size(bytes)

        if size <= @maximum_lock_bytes,
          do: {:cont, {:crypto.hash_update(digest, bytes), size}},
          else: {:halt, :too_large}
      end)

    case result do
      {digest, _size} -> {:ok, digest |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      :too_large -> {:error, :lock_too_large}
    end
  rescue
    _error -> {:error, :lock_unavailable}
  end
end
