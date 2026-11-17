defmodule Insider.LoadHarness.ArtifactStore do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.Load.Manifest
  alias Insider.Load.Report
  alias Insider.Load.Failure
  alias Insider.LoadHarness.Profile

  @spec write(Path.t(), Report.t(), Profile.t(), (Path.t(), binary(), File.io_device() ->
                                                    :ok | {:error, term()})) ::
          {:ok, %{manifest: Manifest.t(), output: Path.t()}} | {:error, term()}
  def write(output, report, profile, writer \\ &write_open_file/3)

  def write(output, %Report{} = report, %Profile{} = profile, writer)
      when is_binary(output) and byte_size(output) in 1..4_096 and is_function(writer, 3) do
    with {:ok, profile_bytes} <- canonical_profile(report, profile),
         {:ok, report_bytes} <- Report.canonical_binary(report),
         artifacts <- %{"profile.json" => profile_bytes, "report.json" => report_bytes},
         :ok <- within_artifact_limit(artifacts, profile.max_artifact_bytes),
         {:ok, manifest} <- Manifest.new(artifacts),
         {:ok, manifest_bytes} <- Manifest.canonical_binary(manifest),
         {:ok, output_identity} <- make_new_directory(output) do
      files = Map.put(artifacts, "manifest.json", manifest_bytes)

      case write_staged(output, files, manifest, writer) do
        :ok ->
          case publish_if_empty(output, files, manifest, output_identity) do
            :ok -> {:ok, %{manifest: manifest, output: Path.expand(output)}}
            {:error, reason} -> publish_failure_if_empty(output, output_identity, reason)
          end

        {:error, reason} ->
          publish_failure_if_empty(output, output_identity, reason)
      end
    else
      {:error, _reason} = error -> error
      _other -> {:error, :artifact_write_failed}
    end
  rescue
    _error -> {:error, :artifact_write_failed}
  catch
    _kind, _reason -> {:error, :artifact_write_failed}
  end

  def write(_output, _report, _profile, _writer), do: {:error, :invalid_artifact_request}

  @spec write_failure(Path.t(), atom()) :: {:ok, Manifest.t()} | {:error, term()}
  def write_failure(output, reason)
      when is_binary(output) and byte_size(output) in 1..4_096 and is_atom(reason) do
    with {:ok, output_identity} <- make_new_directory(output) do
      write_failure_in_directory(output, reason, output_identity)
    end
  rescue
    _error -> {:error, :artifact_write_failed}
  catch
    _kind, _reason -> {:error, :artifact_write_failed}
  end

  def write_failure(_output, _reason), do: {:error, :invalid_artifact_request}

  defp make_new_directory(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> directory_identity(output)
        {:error, :eexist} -> {:error, :output_exists}
        {:error, _reason} -> {:error, :artifact_write_failed}
      end
    else
      {:error, _reason} -> {:error, :artifact_write_failed}
    end
  end

  defp make_private_directory(output) do
    staging =
      output <> ".stage-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    case File.mkdir(staging) do
      :ok ->
        case directory_identity(staging) do
          {:ok, identity} ->
            if File.chmod(staging, 0o700) == :ok and same_directory?(staging, identity) do
              {:ok, staging, identity}
            else
              clean_stage(staging, identity, [])
              {:error, :artifact_write_failed}
            end

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} ->
        {:error, :artifact_write_failed}
    end
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = identity} ->
        {:ok, identity}

      _other ->
        {:error, :artifact_write_failed}
    end
  end

  defp same_directory?(path, identity) do
    case File.lstat(path) do
      {:ok, stat} ->
        stat.type == :directory and
          {stat.major_device, stat.minor_device, stat.inode} ==
            {identity.major_device, identity.minor_device, identity.inode}

      _other ->
        false
    end
  end

  defp publish_failure_if_empty(output, identity, reason) do
    case if(same_directory?(output, identity), do: File.ls(output), else: :error) do
      {:ok, []} ->
        case write_failure_in_directory(output, reason, identity) do
          {:ok, _manifest} -> {:error, {:failure_published, reason}}
          {:error, _error} -> {:error, {:failure_publication_failed, reason}}
        end

      _other ->
        {:error, {:failure_publication_failed, reason}}
    end
  end

  defp write_failure_in_directory(output, reason, identity) do
    with {:ok, failure_bytes} <- Failure.canonical_binary(reason),
         artifacts <- %{"failure.json" => failure_bytes},
         {:ok, manifest} <- Manifest.new(artifacts),
         {:ok, manifest_bytes} <- Manifest.canonical_binary(manifest),
         files <- Map.put(artifacts, "manifest.json", manifest_bytes),
         :ok <- write_staged(output, files, manifest, &write_open_file/3),
         :ok <- publish_if_empty(output, files, manifest, identity) do
      {:ok, manifest}
    end
  rescue
    _error -> {:error, :artifact_write_failed}
  catch
    _kind, _reason -> {:error, :artifact_write_failed}
  end

  defp write_staged(output, files, manifest, writer) do
    with {:ok, staging, identity} <- make_private_directory(output) do
      write_and_verify(staging, files, manifest, writer, identity, output, :staging)
    end
  end

  defp publish_if_empty(output, files, manifest, identity) do
    with true <- same_directory?(output, identity),
         {:ok, []} <- File.ls(output) do
      write_and_verify(output, files, manifest, &write_open_file/3, identity, output, :public)
    else
      _other -> {:error, :artifact_write_failed}
    end
  end

  defp write_and_verify(directory, files, manifest, writer, identity, logical_output, kind) do
    case write_all(directory, files, writer, identity, logical_output) do
      {status, owned} ->
        verification =
          if status == :ok do
            try do
              verify(directory, manifest, owned, identity)
            rescue
              _error -> {:error, :artifact_verification_failed}
            catch
              _kind, _reason -> {:error, :artifact_verification_failed}
            end
          else
            {:error, :artifact_write_failed}
          end

        closed = close_files(owned)
        cleaned = if kind == :staging, do: clean_stage(directory, identity, owned), else: :ok

        case {verification, closed, cleaned} do
          {{:ok, ^manifest}, :ok, :ok} -> :ok
          _other -> {:error, :artifact_write_failed}
        end
    end
  end

  defp write_all(output, artifacts, writer, identity, logical_output) do
    Enum.reduce_while(artifacts, {:ok, []}, fn {name, bytes}, {:ok, owned} ->
      path = Path.join(output, name)

      case if(same_directory?(output, identity),
             do: File.open(path, [:read, :write, :binary, :exclusive]),
             else: {:error, :artifact_write_failed}
           ) do
        {:ok, file} ->
          case :file.read_file_info(file) do
            {:ok, file_info} ->
              identity = File.Stat.from_record(file_info)
              owned = [{path, file, identity, byte_size(bytes)} | owned]

              result =
                try do
                  writer.(Path.join(logical_output, name), bytes, file)
                rescue
                  _error -> {:error, :artifact_write_failed}
                catch
                  _kind, _reason -> {:error, :artifact_write_failed}
                end

              if result == :ok, do: {:cont, {:ok, owned}}, else: {:halt, {:error, owned}}

            {:error, _reason} ->
              File.close(file)
              {:halt, {:error, owned}}
          end

        {:error, _reason} ->
          {:halt, {:error, owned}}
      end
    end)
  end

  defp close_files(owned) do
    Enum.reduce(owned, :ok, fn {_path, file, _identity, _size}, result ->
      case File.close(file) do
        :ok -> result
        _other -> {:error, :artifact_write_failed}
      end
    end)
  end

  defp clean_stage(stage, identity, owned) do
    names = Enum.map(owned, fn {path, _file, _identity, _size} -> Path.basename(path) end)

    with true <- same_directory?(stage, identity),
         {:ok, entries} <- File.ls(stage),
         true <- Enum.sort(entries) == Enum.sort(names),
         true <-
           Enum.all?(owned, fn {path, _file, file_identity, _size} ->
             case File.lstat(path) do
               {:ok, stat} -> same_regular_file?(stat, file_identity)
               _other -> false
             end
           end),
         :ok <- remove_stage_files(stage, identity, owned),
         true <- same_directory?(stage, identity),
         {:ok, []} <- File.ls(stage),
         :ok <- File.rmdir(stage) do
      :ok
    else
      _other -> {:error, :artifact_write_failed}
    end
  end

  defp remove_stage_files(stage, identity, owned) do
    Enum.reduce_while(owned, :ok, fn {path, _file, file_identity, _size}, :ok ->
      with true <- same_directory?(stage, identity),
           {:ok, stat} <- File.lstat(path),
           true <- same_regular_file?(stat, file_identity),
           :ok <- File.rm(path) do
        {:cont, :ok}
      else
        _other -> {:halt, {:error, :artifact_write_failed}}
      end
    end)
  end

  defp write_open_file(_path, bytes, file), do: IO.binwrite(file, bytes)

  defp verify(output, manifest, owned, identity) do
    paths = Enum.map(manifest.artifacts, & &1["path"])

    with true <- same_directory?(output, identity),
         {:ok, names} <- File.ls(output),
         true <- Enum.sort(names) == Enum.sort(["manifest.json" | paths]),
         {:ok, manifest_bytes} <- read_owned(owned, "manifest.json"),
         {:ok, ^manifest} <- Manifest.decode(manifest_bytes),
         {:ok, artifacts} <- read_artifacts(owned, paths) do
      Manifest.validate_with_artifacts(manifest, artifacts)
    else
      _other -> {:error, :artifact_verification_failed}
    end
  end

  defp read_artifacts(owned, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, artifacts} ->
      case read_owned(owned, path) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(artifacts, path, bytes)}}
        {:error, _reason} -> {:halt, {:error, :artifact_verification_failed}}
      end
    end)
  end

  defp read_owned(owned, name) do
    case Enum.find(owned, fn {path, _file, _identity, _size} -> Path.basename(path) == name end) do
      {path, file, identity, size} ->
        with {:ok, path_stat} <- File.lstat(path),
             {:ok, file_info} <- :file.read_file_info(file),
             file_stat <- File.Stat.from_record(file_info),
             true <- same_regular_file?(path_stat, identity),
             true <- same_regular_file?(file_stat, identity),
             true <- file_stat.size <= size,
             {:ok, 0} <- :file.position(file, :bof),
             bytes when is_binary(bytes) <- IO.binread(file, size + 1),
             true <- byte_size(bytes) == size do
          {:ok, bytes}
        else
          :eof when size == 0 -> {:ok, <<>>}
          _other -> {:error, :artifact_verification_failed}
        end

      _other ->
        {:error, :artifact_verification_failed}
    end
  end

  defp same_regular_file?(stat, identity) do
    stat.type == :regular and
      {stat.major_device, stat.minor_device, stat.inode} ==
        {identity.major_device, identity.minor_device, identity.inode}
  end

  defp total_bytes(artifacts),
    do: artifacts |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

  defp canonical_profile(report, profile) do
    bytes = Canonical.encode(Profile.to_wire_map(profile))
    sha256 = Canonical.sha256_binary(bytes)

    if sha256 == profile.canonical_sha256 and sha256 == report.inputs["profile_sha256"],
      do: {:ok, bytes},
      else: {:error, :artifact_contract_mismatch}
  end

  defp within_artifact_limit(artifacts, maximum) do
    if total_bytes(artifacts) <= maximum,
      do: :ok,
      else: {:error, :artifact_limit_exceeded}
  end
end
