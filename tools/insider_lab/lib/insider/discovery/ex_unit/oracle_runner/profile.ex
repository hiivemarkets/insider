defmodule Insider.Discovery.ExUnit.OracleRunner.Profile do
  @moduledoc false

  # A host integration profile names what the runner may pass to a target's
  # test VM. It holds environment variable names, never values (except the
  # non-secret database suffix when the operator writes one literally).

  alias Insider.Event.Canonical

  @schema "insider.oracle-host-profile/v1"
  @keys ["db_suffix", "mix_command", "name", "passthrough_env", "schema", "test_alias"]
  @maximum_bytes 16_384
  @maximum_command_elements 8
  @maximum_command_element_bytes 1_024
  @maximum_passthrough 64
  @inherited ["HOME", "PATH"]
  # Names the runner assigns itself. `INSIDER_ORACLE_*` is reserved by prefix.
  # `MIX_EXS` selects the bootstrap; letting a profile set it would let the
  # host's own `mix.exs` and its `test` alias run instead.
  @reserved ["HOME", "MIX_ENV", "MIX_EXS", "PATH"]
  @name_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @variable_pattern ~r/\A[A-Z_][A-Z0-9_]{0,127}\z/
  @suffix_pattern ~r/\A[A-Za-z0-9_]{1,63}\z/

  @type t :: %{required(String.t()) => term()}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec inherited() :: [String.t()]
  def inherited, do: @inherited

  @spec load(Path.t()) ::
          {:ok, %{document: t(), path: String.t(), sha256: String.t()}} | {:error, String.t()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @maximum_bytes <-
           File.stat(expanded),
         {:ok, bytes} <- File.read(expanded),
         true <- byte_size(bytes) <= @maximum_bytes,
         {:ok, decoded} <- Jason.decode(bytes),
         {:ok, document} <- validate(decoded) do
      {:ok, %{document: document, path: expanded, sha256: Canonical.sha256(document)}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, %Jason.DecodeError{}} -> {:error, "profile_invalid_json"}
      _other -> {:error, "profile_unreadable"}
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(%{"schema" => @schema} = profile) do
    with :ok <- exact_keys(profile),
         :ok <- field(profile, "name", &name?/1),
         :ok <- field(profile, "mix_command", &mix_command?/1),
         :ok <- field(profile, "test_alias", &(&1 in ["absent", "bypass"])),
         :ok <- field(profile, "passthrough_env", &passthrough?/1),
         :ok <- field(profile, "db_suffix", &db_suffix?(&1, profile["passthrough_env"])) do
      {:ok, profile}
    end
  end

  def validate(%{"schema" => _schema}), do: {:error, "profile_schema_unsupported"}
  def validate(_profile), do: {:error, "profile_invalid"}

  # Resolves the profile against the invoking environment. Only declared names
  # are read; their values go to the child environment and are never recorded.
  @spec resolve(t(), %{String.t() => String.t()}) ::
          {:ok,
           %{
             db_suffix: {String.t(), String.t()} | nil,
             passthrough: [{String.t(), String.t()}],
             present: [String.t()],
             absent: [String.t()]
           }}
          | {:error, String.t()}
  def resolve(profile, environment) when is_map(environment) do
    {present, absent} =
      Enum.split_with(profile["passthrough_env"], &Map.has_key?(environment, &1))

    with {:ok, db_suffix} <- resolve_db_suffix(profile["db_suffix"], environment) do
      {:ok,
       %{
         absent: absent,
         db_suffix: db_suffix,
         passthrough: Enum.map(present, &{&1, Map.fetch!(environment, &1)}),
         present: present
       }}
    end
  end

  defp resolve_db_suffix(nil, _environment), do: {:ok, nil}

  defp resolve_db_suffix(%{"variable" => variable, "value" => value}, _environment),
    do: {:ok, {variable, value}}

  defp resolve_db_suffix(%{"variable" => variable, "source" => "environment"}, environment) do
    case Map.fetch(environment, variable) do
      {:ok, value} ->
        if suffix?(value), do: {:ok, {variable, value}}, else: {:error, "db_suffix_invalid"}

      :error ->
        {:error, "db_suffix_unavailable"}
    end
  end

  defp exact_keys(profile) do
    if Enum.sort(Map.keys(profile)) == @keys, do: :ok, else: {:error, "profile_invalid"}
  end

  defp field(profile, key, valid?) do
    if valid?.(Map.fetch!(profile, key)), do: :ok, else: {:error, "profile_invalid_" <> key}
  end

  defp name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  defp mix_command?([_executable | _arguments] = command) do
    length(command) <= @maximum_command_elements and Enum.all?(command, &command_element?/1)
  end

  defp mix_command?(_command), do: false

  defp command_element?(element) do
    is_binary(element) and byte_size(element) in 1..@maximum_command_element_bytes and
      String.valid?(element) and not control_byte?(element)
  end

  defp passthrough?(names) when is_list(names) do
    length(names) <= @maximum_passthrough and Enum.uniq(names) == names and
      Enum.all?(names, &free_variable?/1)
  end

  defp passthrough?(_names), do: false

  defp db_suffix?(nil, _passthrough), do: true

  defp db_suffix?(%{"variable" => variable} = suffix, passthrough) when is_list(passthrough) do
    free_variable?(variable) and variable not in passthrough and
      case Map.delete(suffix, "variable") do
        %{"source" => "environment"} = rest -> map_size(rest) == 1
        %{"value" => value} = rest -> map_size(rest) == 1 and suffix?(value)
        _other -> false
      end
  end

  defp db_suffix?(_suffix, _passthrough), do: false

  defp free_variable?(name) do
    is_binary(name) and Regex.match?(@variable_pattern, name) and name not in @reserved and
      not String.starts_with?(name, "INSIDER_ORACLE_")
  end

  defp suffix?(value), do: is_binary(value) and Regex.match?(@suffix_pattern, value)

  defp control_byte?(value), do: Enum.any?(:binary.bin_to_list(value), &(&1 < 0x20 or &1 == 0x7F))
end
