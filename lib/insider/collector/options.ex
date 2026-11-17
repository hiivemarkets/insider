defmodule Insider.Collector.Options do
  @moduledoc false

  # The option checks the trace-session collectors (`Insider.Collector.Calls`
  # and `Insider.Collector.Otel`) share: an exact keyword list of known keys
  # with every required one, the session's bounded identity strings, and
  # bounded positive integers.

  @doc """
  Whether `options` is a keyword list without repeated keys, of keys in
  `allowed` only and with every key in `required`, whose `:authority`,
  `:boot_id`, and `:clock_id` are strings of 1 to 128 bytes and whose
  `:node`, when given, is one of 1 to 256 bytes.
  """
  @spec common?([{atom(), term()}], [atom()], [atom()]) :: boolean()
  def common?(options, allowed, required) do
    keys = Keyword.keys(options)

    Keyword.keyword?(options) and keys == Enum.uniq(keys) and
      Enum.all?(keys, &(&1 in allowed)) and
      Enum.all?(required, &(&1 in keys)) and
      Enum.all?([:authority, :boot_id, :clock_id], &bounded?(Keyword.get(options, &1), 128)) and
      bounded?(Keyword.get(options, :node, "node"), 256)
  end

  @doc "Whether `value` is valid UTF-8 of 1 to `maximum` bytes."
  @spec bounded?(term(), pos_integer()) :: boolean()
  def bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  @doc "Whether `value` is an integer from 1 to 1,073,741,824."
  @spec positive?(term()) :: boolean()
  def positive?(value), do: is_integer(value) and value in 1..1_073_741_824
end
