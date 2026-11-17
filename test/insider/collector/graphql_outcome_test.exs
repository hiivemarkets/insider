defmodule Insider.Collector.GraphqlOutcomeTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.GraphqlOutcome

  # The shapes Absinthe's operation stop metadata carries; Absinthe is not a
  # dependency, so each is a map with its struct name.
  defp blueprint(operation, result, fragments \\ []) do
    %{
      blueprint: %{
        __struct__: Absinthe.Blueprint,
        operations: [%{name: "other", type: :query, current: false, selections: []}, operation],
        fragments: fragments,
        result: result
      }
    }
  end

  defp operation(name, type, selections),
    do: %{name: name, type: type, current: true, selections: selections}

  defp field(name, options \\ []) do
    %{
      __struct__: Absinthe.Blueprint.Document.Field,
      name: name,
      alias: Keyword.get(options, :alias),
      selections: Keyword.get(options, :selections, [])
    }
  end

  defp inline(selections, condition \\ nil) do
    %{
      __struct__: Absinthe.Blueprint.Document.Fragment.Inline,
      type_condition: type(condition),
      selections: selections
    }
  end

  defp type(nil), do: nil
  defp type(name), do: %{__struct__: Absinthe.Blueprint.TypeReference.Name, name: name}

  defp spread(name), do: %{__struct__: Absinthe.Blueprint.Document.Fragment.Spread, name: name}

  defp named(name, selections, condition \\ nil) do
    %{
      __struct__: Absinthe.Blueprint.Document.Fragment.Named,
      name: name,
      type_condition: type(condition),
      selections: selections
    }
  end

  # mutation placeBuyOrder { placeBuyOrder(input: ...) { __typename
  #   ... on ValidationError { errors { field type message } } } }
  defp place_buy_order do
    errors = field("errors", selections: [field("field"), field("type"), field("message")])

    operation("placeBuyOrder", :mutation, [
      field("placeBuyOrder", selections: [field("__typename"), inline([errors])])
    ])
  end

  test "a 200 mutation whose payload reports validation errors names fields, never values" do
    result = %{
      data: %{
        "placeBuyOrder" => %{
          "__typename" => "ValidationError",
          "errors" => [
            %{"field" => "unitPrice", "message" => "must be at least $1.00", "type" => "min"},
            %{"field" => "unitPrice", "message" => "secret 0.01", "type" => "min"}
          ]
        }
      }
    }

    outcome = GraphqlOutcome.from_metadata(blueprint(place_buy_order(), result))

    assert outcome == %{
             "operation_name" => "placeBuyOrder",
             "operation_type" => "mutation",
             "result" => "user_errors",
             "complete" => true,
             "error_count" => 0,
             "error_codes" => [],
             "error_paths" => [],
             "typenames" => ["ValidationError"],
             "user_error_count" => 2,
             "user_error_fields" => ["unitPrice"],
             "user_error_types" => ["min"],
             "withheld" => 0
           }

    refute inspect(outcome) =~ "1.00"
    refute inspect(outcome) =~ "secret"
    refute GraphqlOutcome.error?(outcome)
    assert GraphqlOutcome.user_errors?(outcome)

    assert GraphqlOutcome.text(outcome) ==
             "mutation placeBuyOrder result=user_errors types=[ValidationError] " <>
               "user_errors=2 fields=[unitPrice]"
  end

  # An alias can give any field the response key of a
  # structural one; values must never pass as names.
  test "aliases cannot pass a value off as a typename, an error field, or a type" do
    # query AliasProbe { account { __typename: password
    #   errors: details { field: password type: password } } }
    probe =
      operation("AliasProbe", :query, [
        field("account",
          selections: [
            field("password", alias: "__typename"),
            field("details",
              alias: "errors",
              selections: [field("password", alias: "field"), field("password", alias: "type")]
            )
          ]
        )
      ])

    secret = "CanaryPrivateAlpha"

    result = %{
      data: %{
        "account" => %{
          "__typename" => secret,
          "errors" => [%{"field" => secret, "type" => secret}]
        }
      }
    }

    outcome = GraphqlOutcome.from_metadata(blueprint(probe, result))
    refute inspect(outcome) =~ secret
    assert %{"result" => "ok", "typenames" => [], "user_error_count" => 0} = outcome
    refute GraphqlOutcome.text(outcome) =~ secret

    # The real fields under aliases are still read, by their response keys.
    renamed =
      operation("Renamed", :mutation, [
        field("placeBuyOrder",
          alias: "order",
          selections: [
            field("__typename", alias: "kind"),
            field("errors", alias: "problems", selections: [field("field", alias: "where")])
          ]
        )
      ])

    data = %{
      "order" => %{"kind" => "ValidationError", "problems" => [%{"where" => "unitPrice"}]}
    }

    assert %{
             "result" => "user_errors",
             "typenames" => ["ValidationError"],
             "user_error_fields" => ["unitPrice"]
           } = GraphqlOutcome.from_metadata(blueprint(renamed, %{data: data}))
  end

  # One response key from two fields on mutually
  # exclusive types; the runtime type picks which, so the key is ambiguous.
  test "a key two fragments give different fields is never read; a typename must be a fragment's type" do
    secret = "CanaryPrivateAlpha"
    data = %{"account" => %{"value" => secret}}

    inline_probe =
      operation("Probe", :query, [
        field("account",
          selections: [
            inline([field("__typename", alias: "value")], "PublicAccount"),
            inline([field("password", alias: "value")], "PrivateAccount")
          ]
        )
      ])

    named_probe =
      operation("Probe", :query, [
        field("account", selections: [spread("Public"), spread("Private")])
      ])

    fragments = [
      named("Public", [field("__typename", alias: "value")], "PublicAccount"),
      named("Private", [field("password", alias: "value")], "PrivateAccount")
    ]

    for outcome <- [
          GraphqlOutcome.from_metadata(blueprint(inline_probe, %{data: data})),
          GraphqlOutcome.from_metadata(blueprint(named_probe, %{data: data}, fragments))
        ] do
      refute inspect(outcome) =~ secret
      assert %{"typenames" => [], "withheld" => 1} = outcome
    end

    # Likewise for an error's field.
    errors_probe =
      operation("Probe", :mutation, [
        field("check",
          selections: [
            field("errors",
              selections: [
                inline([field("field")], "FieldError"),
                inline([field("password", alias: "field")], "Secret")
              ]
            )
          ]
        )
      ])

    errors_data = %{"check" => %{"errors" => [%{"field" => secret}]}}
    errors_outcome = GraphqlOutcome.from_metadata(blueprint(errors_probe, %{data: errors_data}))
    refute inspect(errors_outcome) =~ secret
    assert %{"user_error_count" => 1, "user_error_fields" => []} = errors_outcome

    # A typename the fragments could not produce is withheld; one they can is kept.
    typed =
      operation("T", :mutation, [
        field("placeBuyOrder",
          selections: [field("__typename"), inline([field("orderId")], "PlaceBuyOrderSuccess")]
        )
      ])

    assert %{"typenames" => [], "withheld" => 1} =
             GraphqlOutcome.from_metadata(
               blueprint(typed, %{data: %{"placeBuyOrder" => %{"__typename" => secret}}})
             )

    assert %{"typenames" => ["PlaceBuyOrderSuccess"]} =
             GraphqlOutcome.from_metadata(
               blueprint(typed, %{
                 data: %{"placeBuyOrder" => %{"__typename" => "PlaceBuyOrderSuccess"}}
               })
             )
  end

  # GraphQL merges fields with one response key.
  test "selections of one response key are merged, so a repeated field's errors are read" do
    duplicate =
      operation("Duplicate", :mutation, [
        field("check", selections: [field("__typename")]),
        field("check", selections: [field("errors", selections: [field("field")])])
      ])

    data = %{"check" => %{"__typename" => "Check", "errors" => [%{"field" => "amount"}]}}

    assert %{"result" => "user_errors", "user_error_fields" => ["amount"], "complete" => true} =
             GraphqlOutcome.from_metadata(blueprint(duplicate, %{data: data}))

    # Nested `errors` selections merge too, and through a fragment.
    nested =
      operation("Nested", :mutation, [
        field("check",
          selections: [field("errors", selections: [field("type")]), spread("Fields")]
        )
      ])

    fragments = [named("Fields", [field("errors", selections: [field("field")])], "Check")]
    data = %{"check" => %{"errors" => [%{"field" => "amount", "type" => "min"}]}}

    assert %{"user_error_fields" => ["amount"], "user_error_types" => ["min"]} =
             GraphqlOutcome.from_metadata(blueprint(nested, %{data: data}, fragments))
  end

  # A traversal cut-off or an aggregate count past
  # the bound leaves the outcome incomplete.
  test "nested fragments are followed to a depth; past it, and past the aggregate count, it is incomplete" do
    errors = field("errors", selections: [field("field")])

    wrap = fn selections, levels ->
      Enum.reduce(1..levels, selections, &[inline(&2, "T#{&1}")])
    end

    data = %{"check" => %{"errors" => [%{"field" => "amount"}]}}

    four = operation("Four", :mutation, [field("check", selections: wrap.([errors], 4))])

    assert %{"result" => "user_errors", "complete" => true} =
             GraphqlOutcome.from_metadata(blueprint(four, %{data: data}))

    deep = operation("Deep", :mutation, [field("check", selections: wrap.([errors], 9))])

    assert %{"result" => nil, "complete" => false} =
             GraphqlOutcome.from_metadata(blueprint(deep, %{data: data}))

    # Two payloads of 3,000 validation errors each: 6,000 > 4,096.
    two =
      operation("Two", :mutation, [
        field("a", selections: [errors]),
        field("b", selections: [errors])
      ])

    many = for _n <- 1..3_000, do: %{"field" => "amount"}

    assert %{"user_error_count" => 4_096, "complete" => false} =
             GraphqlOutcome.from_metadata(
               blueprint(two, %{data: %{"a" => %{"errors" => many}, "b" => %{"errors" => many}}})
             )

    # Exactly 4,096 is exact and complete.
    exact = for _n <- 1..2_048, do: %{"field" => "amount"}

    assert %{"user_error_count" => 4_096, "complete" => true} =
             GraphqlOutcome.from_metadata(
               blueprint(two, %{data: %{"a" => %{"errors" => exact}, "b" => %{"errors" => exact}}})
             )
  end

  # 4 levels of 64-wide spreads expanded 16,777,216
  # fields in the emitting process (5.22 s).
  test "fragment amplification is bounded: repeated spreads expand once, distinct ones hit the budget" do
    repeated =
      for level <- 1..4 do
        selections =
          if level == 4,
            do: [field("errors", selections: [field("field")])],
            else: List.duplicate(spread("F#{level + 1}"), 64)

        named("F#{level}", selections, "Check")
      end

    query =
      operation("Amplify", :mutation, [
        field("check", selections: List.duplicate(spread("F1"), 64))
      ])

    data = %{"check" => %{"errors" => [%{"field" => "amount"}]}}

    {us, outcome} =
      :timer.tc(fn -> GraphqlOutcome.from_metadata(blueprint(query, %{data: data}, repeated)) end)

    assert %{"result" => "user_errors", "complete" => true} = outcome
    assert us < 50_000, "took #{us} us"

    # 4 levels of 64 distinct fragments each: 16,777,216 paths to the leaves.
    distinct =
      for level <- 1..4, n <- 1..64 do
        selections =
          if level == 4,
            do: [field("f#{n}")],
            else: for(m <- 1..64, do: spread("F#{level + 1}_#{m}"))

        named("F#{level}_#{n}", selections, "Check")
      end

    wide =
      operation("Wide", :mutation, [
        field("check", selections: for(n <- 1..64, do: spread("F1_#{n}")))
      ])

    {us, outcome} =
      :timer.tc(fn ->
        GraphqlOutcome.from_metadata(blueprint(wide, %{data: %{"check" => %{}}}, distinct))
      end)

    assert %{"result" => nil, "complete" => false} = outcome
    assert us < 50_000, "took #{us} us"
  end

  test "named fragments are followed, and a response key no selection made is not read" do
    fragment = named("Problems", [field("errors", selections: [field("field")])])
    query = operation("Q", :mutation, [field("placeBuyOrder", selections: [spread("Problems")])])
    data = %{"placeBuyOrder" => %{"errors" => [%{"field" => "amount"}]}}

    assert %{"user_error_fields" => ["amount"]} =
             GraphqlOutcome.from_metadata(blueprint(query, %{data: data}, [fragment]))

    # Without the fragment, nothing selected `errors` is known: what the
    # spread selects is unknown, so the outcome is incomplete, never ok.
    assert %{"result" => nil, "complete" => false, "user_error_count" => 0} =
             GraphqlOutcome.from_metadata(blueprint(query, %{data: data}))
  end

  test "top-level error paths name schema fields: aliases resolve, indices become []" do
    query =
      operation("Listing", :query, [
        field("listing",
          alias: "l",
          selections: [field("bids", selections: [field("buyer")])]
        )
      ])

    errors = [
      %{message: "denied for user 42", path: ["l", "bids", 3, "buyer"], code: "UNAUTHORIZED"},
      %{message: "x", path: ["l", "bids", 4, "buyer"], extensions: %{code: :forbidden}},
      %{message: "y", path: ["l", "nope"]},
      %{message: "z", locations: [%{line: 1, column: 2}]}
    ]

    partial =
      GraphqlOutcome.from_metadata(blueprint(query, %{data: %{"l" => nil}, errors: errors}))

    assert %{
             "result" => "partial",
             "error_count" => 4,
             "error_codes" => ["UNAUTHORIZED", "forbidden"],
             "error_paths" => ["listing.bids[].buyer"],
             # the path through a key no selection made
             "withheld" => 1
           } = partial

    assert GraphqlOutcome.error?(partial)
    refute inspect(partial) =~ "42"

    assert %{"result" => "errors", "operation_name" => nil, "operation_type" => nil} =
             GraphqlOutcome.from_metadata(
               blueprint(%{name: nil, type: nil, current: false}, %{errors: errors})
             )

    assert %{"result" => "ok", "error_count" => 0} =
             GraphqlOutcome.from_metadata(blueprint(query, %{data: %{"l" => %{"id" => "L1"}}}))
  end

  # A path segment is bounded before it is copied.
  test "an oversized path segment withholds the path without building it" do
    big = String.duplicate("a", 1_048_576)
    query = operation("Q", :query, [field(big)])

    outcome =
      GraphqlOutcome.from_metadata(
        blueprint(query, %{errors: [%{message: "m", path: List.duplicate(big, 8)}]})
      )

    assert %{"error_paths" => [], "withheld" => 1} = outcome
  end

  test "names that are not identifiers are withheld and counted; lists are bounded" do
    query = operation("Q", :mutation, for(n <- 1..10, do: field("field#{n}")))

    errors =
      for n <- 1..10,
          do: %{message: "m", path: ["field#{n}"], code: "CODE_#{n}"}

    bad = [%{message: "m", code: "has space"}, %{message: "m", code: String.duplicate("a", 49)}]
    name = %{query | name: "drop table; --"}

    outcome = GraphqlOutcome.from_metadata(blueprint(name, %{errors: errors ++ bad}))

    assert outcome["operation_name"] == nil
    assert ["CODE_1", _, _, _, _, "CODE_6"] = outcome["error_codes"]
    assert ["field1", _, _, _, _, "field6"] = outcome["error_paths"]
    # 4 codes and 4 paths past six, 2 bad codes, the name
    assert outcome["withheld"] == 11
  end

  # What the bounds leave unexamined is never reported
  # as success, and counts say whether they are exact.
  test "counts are exact past the examined entries; unexamined fields make the outcome incomplete" do
    errors = for n <- 1..65, do: %{message: "m#{n}"}

    assert %{"error_count" => 65, "complete" => true, "result" => "errors"} =
             GraphqlOutcome.from_metadata(blueprint(place_buy_order(), %{errors: errors}))

    payload = %{"errors" => for(_n <- 1..65, do: %{"field" => "amount"})}

    assert %{"user_error_count" => 65, "complete" => true} =
             GraphqlOutcome.from_metadata(
               blueprint(place_buy_order(), %{data: %{"placeBuyOrder" => payload}})
             )

    # 65 top-level fields; the validation error is in the 65th, which is not
    # examined, so the result is unknown, not ok.
    selections =
      for n <- 1..65 do
        field("f#{String.pad_leading("#{n}", 2, "0")}",
          selections: [field("errors", selections: [field("field")])]
        )
      end

    data =
      Map.new(1..65, fn n ->
        key = "f#{String.pad_leading("#{n}", 2, "0")}"
        {key, %{"errors" => if(n == 65, do: [%{"field" => "x"}], else: [])}}
      end)

    wide =
      GraphqlOutcome.from_metadata(
        blueprint(operation("W", :mutation, selections), %{data: data})
      )

    assert %{"complete" => false, "result" => nil} = wide
    refute GraphqlOutcome.text(wide) =~ "result=ok"
  end

  test "metadata without a blueprint has no outcome" do
    assert GraphqlOutcome.from_metadata(%{blueprint: %{result: %{}}}) == nil
    assert GraphqlOutcome.from_metadata(:none) == nil
    assert GraphqlOutcome.event?([:absinthe, :execute, :operation, :stop])
    refute GraphqlOutcome.event?([:absinthe, :execute, :operation, :start])
  end

  test "span attributes give the operation and top-level errors; payload names have no provenance" do
    errors = Jason.encode!([%{message: "v 9", path: ["placeBuyOrder"], code: "VALIDATION"}])

    assert %{
             "operation_name" => "placeBuyOrder",
             "operation_type" => "mutation",
             "result" => "errors",
             "error_codes" => ["VALIDATION"],
             "error_paths" => ["placeBuyOrder"]
           } =
             GraphqlOutcome.from_span_attributes(%{
               :"graphql.operation.name" => "placeBuyOrder",
               :"graphql.operation.type" => :mutation,
               :"graphql.response.errors" => errors
             })

    # A recorded result has no selections to tell a real `errors` from an
    # alias, so its payload is not read: the result is unknown.
    secret = "CanaryPrivateAlpha"

    result =
      Jason.encode!(%{
        data: %{"x" => %{"__typename" => secret, "errors" => [%{"field" => secret}]}}
      })

    from_result =
      GraphqlOutcome.from_span_attributes(%{
        "graphql.operation.type" => "mutation",
        "graphql.response.result" => result
      })

    assert %{"result" => nil, "typenames" => [], "user_error_count" => 0} = from_result
    refute inspect(from_result) =~ secret

    # Errors in a recorded result count; with data they are partial.
    partial = Jason.encode!(%{data: %{"x" => nil}, errors: [%{message: "m", path: ["x"]}]})

    assert %{"result" => "partial", "error_count" => 1} =
             GraphqlOutcome.from_span_attributes(%{"graphql.response.result" => partial})

    # Without the result, an empty error list does not mean ok: a payload's
    # validation errors are in the result (placeBuyOrder's ValidationError
    # span once said result=ok).
    assert %{"result" => nil, "error_count" => 0} =
             GraphqlOutcome.from_span_attributes(%{
               "graphql.operation.name" => "placeBuyOrder",
               "graphql.response.errors" => "[]"
             })

    # The name and type alone say nothing of the result.
    assert %{"result" => nil, "operation_name" => "Q"} =
             GraphqlOutcome.from_span_attributes(%{"graphql.operation.name" => "Q"})

    assert GraphqlOutcome.from_span_attributes(%{"http.method" => "POST"}) == nil
  end
end
