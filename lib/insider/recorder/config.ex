defmodule Insider.Recorder.Config do
  @moduledoc """
  Validated recorder configuration derived from `Insider.Recorder.start_link/1`
  options: event, byte, trigger-window, rate-limit, admission-stall, and
  source-share bounds plus the trusted classification binding. Hosts do not
  construct it directly.

  `admission_stall_ms` (0..5,000, default 1,000): a writer waiting for the
  admission lock gives up when the lock has not changed hands for this long,
  so a stuck holder fails later writers instead of blocking them; 0 makes a
  single attempt. A queue that moves is waited out.

  `source_shares` (a map of event source to a whole percentage, at most 16
  sources) and `other_share` (the percentage shared by every source not in
  the map): each source's reserved share of `max_events` and `max_bytes`,
  rounded down. The percentages sum to at most 100. A share reserves room
  without holding it: a source may use any room no one else is using, and
  only the entries of a source within its share in both events and bytes are
  safe from other sources' writes. The default reserves Logger 25%,
  Telemetry 15%, Poller 25%, otel 10%, inspection (`"inspect"`) 5%,
  SystemMonitor 5%, and every other source together 5%; 10% is reserved by
  no one.
  """

  alias Insider.Recorder.Classification

  @max_events 100_000
  @max_bytes 16 * 1_024 * 1_024
  @max_window_ms 60_000
  @max_rate_keys 4_096
  @max_admission_stall_ms 5_000
  @max_share_sources 16
  @max_source_bytes 64
  @other "other"
  @default_source_shares %{
    "logger" => 25,
    "telemetry" => 15,
    "poller" => 25,
    "otel" => 10,
    "inspect" => 5,
    "system_monitor" => 5
  }
  @default_other_share 5
  @option_keys [
    :max_events,
    :max_bytes,
    :pre_trigger_ms,
    :post_trigger_ms,
    :rate_limit_count,
    :rate_window_ms,
    :max_rate_keys,
    :admission_stall_ms,
    :source_shares,
    :other_share,
    :classification,
    :clock
  ]

  @enforce_keys @option_keys
  defstruct @option_keys ++ [reservations: %{}, group_indexes: %{}]

  @typedoc """
  A source group's share as `{percent, reserved_events, reserved_bytes}`.
  """
  @type reservation :: {0..100, non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          max_events: pos_integer(),
          max_bytes: pos_integer(),
          pre_trigger_ms: non_neg_integer(),
          post_trigger_ms: non_neg_integer(),
          rate_limit_count: pos_integer(),
          rate_window_ms: pos_integer(),
          max_rate_keys: pos_integer(),
          admission_stall_ms: non_neg_integer(),
          source_shares: %{String.t() => 0..100},
          other_share: 0..100,
          classification: Classification.Binding.t(),
          clock: (-> integer()),
          reservations: %{String.t() => reservation()},
          group_indexes: %{String.t() => pos_integer()}
        }

  @doc "The source shares a recorder reserves when none are given."
  @spec default_source_shares() :: %{String.t() => 0..100}
  def default_source_shares, do: @default_source_shares

  @doc "The share every source without its own share draws on when none is given."
  @spec default_other_share() :: 0..100
  def default_other_share, do: @default_other_share

  @doc """
  The share group an event source belongs to: the source itself when it has
  a share, otherwise `"other"`.
  """
  @spec group(t(), String.t()) :: String.t()
  def group(%__MODULE__{reservations: reservations}, source),
    do: if(is_map_key(reservations, source), do: source, else: @other)

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_options}
  def new(options) when is_list(options) do
    defaults = [
      max_events: 1_024,
      max_bytes: 4 * 1_024 * 1_024,
      pre_trigger_ms: 30_000,
      post_trigger_ms: 5_000,
      rate_limit_count: 1_000,
      rate_window_ms: 1_000,
      max_rate_keys: 256,
      admission_stall_ms: 1_000,
      source_shares: @default_source_shares,
      other_share: @default_other_share,
      classification: nil,
      clock: fn -> System.monotonic_time(:microsecond) end
    ]

    if Keyword.keyword?(options) and unique_known_keys?(options) and
         Keyword.has_key?(options, :classification) do
      with {:ok, classification} <-
             normalize_classification(Keyword.fetch!(options, :classification)) do
        normalized = Keyword.put(options, :classification, classification)
        config = struct!(__MODULE__, Keyword.merge(defaults, normalized))

        if valid?(config),
          do: {:ok, with_group_indexes(%{config | reservations: reservations(config)})},
          else: {:error, :invalid_options}
      else
        _error -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :invalid_options}
  end

  def new(_options), do: {:error, :invalid_options}

  defp unique_known_keys?(options) do
    keys = Keyword.keys(options)
    length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @option_keys))
  end

  defp valid?(config) do
    bounded_positive?(config.max_events, @max_events) and
      bounded_positive?(config.max_bytes, @max_bytes) and
      bounded_non_negative?(config.pre_trigger_ms, @max_window_ms) and
      bounded_non_negative?(config.post_trigger_ms, @max_window_ms) and
      bounded_positive?(config.rate_limit_count, @max_events) and
      bounded_positive?(config.rate_window_ms, @max_window_ms) and
      bounded_positive?(config.max_rate_keys, @max_rate_keys) and
      bounded_non_negative?(config.admission_stall_ms, @max_admission_stall_ms) and
      valid_shares?(config.source_shares, config.other_share) and
      valid_classification?(config.classification) and
      is_function(config.clock, 0)
  end

  defp valid_shares?(shares, other)
       when is_map(shares) and not is_struct(shares) and map_size(shares) <= @max_share_sources do
    bounded_non_negative?(other, 100) and
      Enum.all?(shares, fn {source, percent} ->
        valid_source?(source) and bounded_non_negative?(percent, 100)
      end) and
      Enum.sum(Map.values(shares)) + other <= 100
  end

  defp valid_shares?(_shares, _other), do: false

  defp valid_source?(source),
    do:
      is_binary(source) and source != @other and byte_size(source) in 1..@max_source_bytes and
        String.valid?(source)

  # Each share group's 1-based index into the Recorder's per-source eviction
  # counters, in group order.
  defp with_group_indexes(config) do
    indexes = config.reservations |> Map.keys() |> Enum.sort() |> Enum.with_index(1) |> Map.new()
    %{config | group_indexes: indexes}
  end

  defp reservations(config) do
    config.source_shares
    |> Map.put(@other, config.other_share)
    |> Map.new(fn {group, percent} ->
      {group,
       {percent, div(config.max_events * percent, 100), div(config.max_bytes * percent, 100)}}
    end)
  end

  defp normalize_classification({sensitivity, policy}),
    do: Classification.binding(sensitivity, policy)

  defp normalize_classification(_classification), do: {:error, :invalid_classification}

  defp valid_classification?(classification), do: Classification.valid_binding?(classification)

  defp bounded_positive?(value, maximum),
    do: is_integer(value) and value in 1..maximum

  defp bounded_non_negative?(value, maximum),
    do: is_integer(value) and value in 0..maximum
end
