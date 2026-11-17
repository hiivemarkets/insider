defmodule Insider.Protocol.StrictOptions do
  @moduledoc false

  alias Insider.Protocol.Value

  @spec exact?(term(), [atom()]) :: boolean()
  def exact?(options, expected_keys) when is_list(expected_keys) do
    Value.bounded_list?(options, length(expected_keys)) and Keyword.keyword?(options) and
      Enum.sort(Keyword.keys(options)) == Enum.sort(expected_keys)
  end

  @spec build(term(), [atom()], (keyword() -> term()), (atom() -> term())) :: term()
  def build(options, expected_keys, builder, invalid)
      when is_list(expected_keys) and is_function(builder, 1) and is_function(invalid, 1) do
    if exact?(options, expected_keys),
      do: builder.(options),
      else: invalid.(:invalid_options)
  rescue
    _error -> invalid.(:construction_failed)
  end
end
