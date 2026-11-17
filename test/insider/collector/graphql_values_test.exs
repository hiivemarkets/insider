defmodule Insider.Collector.GraphqlValuesTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.GraphqlOutcome
  alias Insider.Collector.Rich

  @secret "CanaryPrivateAlpha"

  defp field(name, options \\ []) do
    %{
      __struct__: Absinthe.Blueprint.Document.Field,
      name: name,
      alias: Keyword.get(options, :alias),
      selections: Keyword.get(options, :selections, [])
    }
  end

  defp inline(selections, condition) do
    %{
      __struct__: Absinthe.Blueprint.Document.Fragment.Inline,
      type_condition: %{__struct__: Absinthe.Blueprint.TypeReference.Name, name: condition},
      selections: selections
    }
  end

  defp spread(name), do: %{__struct__: Absinthe.Blueprint.Document.Fragment.Spread, name: name}

  defp metadata(selections, data, fragments \\ []) do
    %{
      blueprint: %{
        __struct__: Absinthe.Blueprint,
        operations: [%{name: "Q", type: :query, current: true, selections: selections}],
        fragments: fragments,
        result: %{data: data}
      }
    }
  end

  # What the rich payload records, as `trace --values` reads it.
  defp recorded(metadata), do: Rich.graphql_payload(metadata)["graphql_data"]

  # `label: password` put a password under a harmless key.
  test "a value is masked by its schema field name, whatever alias the response gave it" do
    selections = [
      field("account",
        selections: [
          field("password", alias: "label"),
          field("displayId"),
          field("apiKey", alias: "settings", selections: [field("value")]),
          field("tokens", alias: "items", selections: [field("secret", alias: "name")])
        ]
      )
    ]

    data = %{
      "account" => %{
        "label" => @secret,
        "displayId" => "STF-1",
        "settings" => %{"value" => @secret},
        "items" => [%{"name" => @secret}, %{"name" => @secret}]
      }
    }

    values = recorded(metadata(selections, data))
    refute inspect(values) =~ @secret
    assert values["account"]["displayId"] == "STF-1"
    assert values["account"]["label"] == "[REDACTED:credential_key]"
    # A credential-named parent masks everything under it.
    assert values["account"]["settings"] == "[REDACTED:credential_key]"

    assert values["account"]["items"] == [
             "[REDACTED:credential_key]",
             "[REDACTED:credential_key]"
           ]
  end

  test "keys no selection made, or that exclusive fragments give different fields, are withheld" do
    selections = [
      field("account",
        selections: [
          inline([field("__typename", alias: "value")], "PublicAccount"),
          inline([field("password", alias: "value")], "PrivateAccount"),
          spread("Amounts")
        ]
      )
    ]

    fragments = [
      %{
        __struct__: Absinthe.Blueprint.Document.Fragment.Named,
        name: "Amounts",
        type_condition: nil,
        selections: [field("totalAmount", selections: [field("amount")])]
      }
    ]

    data = %{
      "account" => %{
        "value" => @secret,
        "unselected" => @secret,
        "totalAmount" => %{"amount" => "500000.00"}
      }
    }

    values = recorded(metadata(selections, data, fragments))
    refute inspect(values) =~ @secret
    assert values["account"]["value"] == "[WITHHELD:unresolved_field]"
    assert values["account"]["unselected"] == "[WITHHELD:unresolved_field]"
    assert values["account"]["totalAmount"]["amount"] == "500000.00"
  end

  test "the walk is bounded; past it values are withheld, never shown unchecked" do
    deep = Enum.reduce(1..10, [field("leaf")], fn n, acc -> [field("f#{n}", selections: acc)] end)
    data = Enum.reduce(1..10, %{"leaf" => @secret}, fn n, acc -> %{"f#{n}" => acc} end)
    refute inspect(recorded(metadata(deep, data))) =~ @secret

    assert GraphqlOutcome.response_data(%{blueprint: %{}}) == nil
    assert recorded(%{other: 1}) == nil
  end

  describe "arguments/1 (the inputs a mutation received)" do
    defp argument(name, value),
      do: %{__struct__: Absinthe.Blueprint.Input.Argument, name: name, value: value}

    defp mutation(fields),
      do: %{
        blueprint: %{
          __struct__: Absinthe.Blueprint,
          operations: [%{name: "M", type: :mutation, current: true, selections: fields}],
          fragments: [],
          result: %{data: %{}}
        }
      }

    test "each top-level field's arguments by schema name, credential-named inputs masked" do
      place =
        Map.put(
          field("placeBuyOrder", alias: "order"),
          :arguments,
          [
            argument("input", %{
              # Decimal -1.50, by its fields (Decimal is not a dependency).
              unit_price: %{amount: %{__struct__: Decimal, sign: -1, coef: 150, exp: -2}},
              password: @secret,
              shop_id: "c-1"
            })
          ]
        )

      args = Rich.graphql_payload(mutation([place]))["graphql_arguments"]

      # The field's schema name, not the alias the client gave it.
      assert %{"placeBuyOrder" => %{"input" => input}} = args
      assert input["password"] == "[REDACTED:credential_key]"
      assert input["shop_id"] == "c-1"
      assert input["unit_price"] == %{"amount" => "-1.50"}
      refute inspect(args) =~ @secret
    end

    test "a credential-named argument is masked whole; queries and fields without arguments record none" do
      field =
        Map.put(field("login"), :arguments, [
          argument("password", @secret),
          argument("email", "e@x")
        ])

      args = Rich.graphql_payload(mutation([field]))["graphql_arguments"]
      assert args == %{"login" => %{"password" => "[REDACTED:credential_key]", "email" => "e@x"}}

      %{blueprint: blueprint} = mutation([field])

      query = %{
        blueprint: %{
          blueprint
          | operations: [%{name: "Q", type: :query, current: true, selections: [field]}]
        }
      }

      assert Rich.graphql_payload(query)["graphql_arguments"] == nil
      assert GraphqlOutcome.arguments(%{}) == nil
    end
  end
end
