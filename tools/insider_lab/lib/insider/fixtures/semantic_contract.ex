defmodule Insider.Fixtures.SemanticContract do
  @moduledoc """
  A deliberately simple semantic fixture used to prove invariant incidents.

  A sample violates the contract when its declared total differs from the sum
  of its item values. The fixture retains the supplied values so test and demo
  evidence reflects a real application-level logic error.
  """

  use Insider.Contract, id: "insider.fixture.semantic", version: 1

  invariant(:total_matches_items, check: &total_matches_items?/1)

  @spec sample(integer(), [integer()]) :: map()
  def sample(total, items) when is_integer(total) and is_list(items) do
    %{"total" => total, "items" => items}
  end

  defp total_matches_items?(%{"total" => total, "items" => items})
       when is_integer(total) and is_list(items) do
    total == Enum.sum(items)
  end

  defp total_matches_items?(_sample), do: false
end
