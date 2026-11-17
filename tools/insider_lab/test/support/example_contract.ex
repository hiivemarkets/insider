defmodule Insider.TestSupport.ExampleContract do
  use Insider.Contract, id: "test.checkout", version: 2

  identity(:checkout, from: &checkout_id/1, sensitivity: :internal)
  observe(:summary, with: &summary/1, sensitivity: :confidential)
  invariant(:positive_total, check: &positive_total?/1)

  action(:echo,
    with: &echo/1,
    environments: [:development, :test],
    sensitivity: :internal
  )

  reset(:fixture, with: &reset_fixture/0, environments: [:test])

  owns(modules: [Insider.TestSupport.ExampleContract])

  defp checkout_id(%{"id" => id}), do: %{"value" => id, "scope" => "tenant-1"}
  defp summary(value), do: %{"summary" => value}
  defp positive_total?(%{"total" => total}), do: total > 0
  defp echo(value), do: value
  defp reset_fixture, do: %{"reset" => true}
end
