defmodule Insider.LoadHarness.Profile do
  @moduledoc false

  alias Insider.Event.Canonical

  @schema "insider.load-profile/v1"
  @keys [
    "inbox_size",
    "logger_every",
    "max_artifact_bytes",
    "max_samples",
    "mode",
    "overload_ms",
    "overload_rate_per_second",
    "rate_per_second",
    "recorder_bytes",
    "recorder_events",
    "recovery_ms",
    "sample_interval_ms",
    "schema",
    "seed",
    "steady_ms",
    "target_count",
    "telemetry_every",
    "warmup_ms"
  ]
  @maximum_profile_bytes 65_536
  @maximum_duration_ms 3_600_000
  @maximum_artifact_bytes 5 * 1_024 * 1_024
  @maximum_inbox_size 1_024
  @maximum_samples 512
  @maximum_recorder_bytes 16 * 1_024 * 1_024

  @enforce_keys [
    :canonical_sha256,
    :inbox_size,
    :logger_every,
    :max_artifact_bytes,
    :max_samples,
    :mode,
    :overload_ms,
    :overload_rate_per_second,
    :rate_per_second,
    :recorder_bytes,
    :recorder_events,
    :recovery_ms,
    :sample_interval_ms,
    :seed,
    :steady_ms,
    :target_count,
    :telemetry_every,
    :warmup_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec load(Path.t()) :: {:ok, t()} | {:error, :invalid_profile}
  def load(path) when is_binary(path) and byte_size(path) in 1..4_096 do
    case File.open(path, [:read, :binary], fn file ->
           IO.binread(file, @maximum_profile_bytes + 1)
         end) do
      {:ok, bytes} when is_binary(bytes) -> decode(bytes)
      _error -> {:error, :invalid_profile}
    end
  end

  def load(_path), do: {:error, :invalid_profile}

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_profile}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_profile_bytes do
    canonical_bytes = strip_single_file_newline(bytes)

    with {:ok, value} <- Jason.decode(canonical_bytes),
         true <- Canonical.encode(value) == canonical_bytes,
         true <- is_map(value) and not is_struct(value),
         true <- Enum.sort(Map.keys(value)) == @keys,
         true <- value["schema"] == @schema,
         true <- value["mode"] in ["load", "soak"],
         true <- integer?(value["seed"], 0, 2_147_483_647),
         true <- integer?(value["warmup_ms"], 0, 300_000),
         true <- integer?(value["steady_ms"], 1_000, @maximum_duration_ms),
         true <- integer?(value["overload_ms"], 1, 300_000),
         true <- integer?(value["recovery_ms"], 1_000, 300_000),
         true <- duration(value) <= @maximum_duration_ms,
         true <- integer?(value["sample_interval_ms"], 1_000, 60_000),
         true <- integer?(value["rate_per_second"], 1, 5_000),
         true <- integer?(value["overload_rate_per_second"], 1, 5_000),
         true <- value["overload_rate_per_second"] > value["rate_per_second"],
         true <- integer?(value["logger_every"], 1, 5_000),
         true <- integer?(value["telemetry_every"], 1, 5_000),
         true <- integer?(value["max_samples"], 1, @maximum_samples),
         true <- integer?(value["max_artifact_bytes"], 1_024, @maximum_artifact_bytes),
         true <- integer?(value["inbox_size"], 1, @maximum_inbox_size),
         true <- integer?(value["recorder_events"], 1, 20_000),
         true <- integer?(value["recorder_bytes"], 4_096, @maximum_recorder_bytes),
         true <- integer?(value["target_count"], 0, 32) do
      {:ok, build(value, canonical_bytes)}
    else
      _other -> {:error, :invalid_profile}
    end
  rescue
    _error -> {:error, :invalid_profile}
  end

  def decode(_bytes), do: {:error, :invalid_profile}

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = profile) do
    profile
    |> Map.from_struct()
    |> Map.delete(:canonical_sha256)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("schema", @schema)
  end

  defp build(value, bytes) do
    fields =
      @enforce_keys
      |> Enum.reject(&(&1 == :canonical_sha256))
      |> Map.new(fn key -> {key, value[Atom.to_string(key)]} end)

    struct!(__MODULE__, Map.put(fields, :canonical_sha256, Canonical.sha256_binary(bytes)))
  end

  defp duration(value) do
    value["warmup_ms"] + value["steady_ms"] + value["overload_ms"] + value["recovery_ms"]
  end

  defp integer?(value, minimum, maximum),
    do: is_integer(value) and value in minimum..maximum

  defp strip_single_file_newline(bytes) do
    if String.ends_with?(bytes, "\n"),
      do: binary_part(bytes, 0, byte_size(bytes) - 1),
      else: bytes
  end
end
