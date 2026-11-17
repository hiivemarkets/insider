defmodule Insider.RedactionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Redaction
  alias Insider.Redaction.Outcome
  alias Insider.Redaction.Policy

  test "masks and drops declared sensitive paths with an aggregated deterministic manifest" do
    policy =
      policy!(
        rules: [
          [id: "password", path: ["password"], sensitivity: :secret, action: :mask],
          [id: "tokens", path: ["tokens", :each], sensitivity: :secret, action: :drop]
        ]
      )

    input = %{
      "name" => "Ada",
      "password" => "secret-canary",
      "tokens" => ["first-secret", "second-secret"]
    }

    assert {:ok, %Outcome{} = outcome} = Redaction.redact(input, :internal, policy)

    assert outcome.value == %{
             "name" => "Ada",
             "password" => "[REDACTED]",
             "tokens" => [nil, nil]
           }

    assert outcome.manifest == [
             %{
               "action" => "drop",
               "count" => 2,
               "path" => ["key:tokens", "each:*"],
               "policy_id" => policy.id <> ":" <> policy.fingerprint
             },
             %{
               "action" => "mask",
               "count" => 1,
               "path" => ["key:password"],
               "policy_id" => policy.id <> ":" <> policy.fingerprint
             }
           ]

    canonical = Canonical.encode(%{"manifest" => outcome.manifest, "value" => outcome.value})
    refute canonical =~ "secret-canary"
    refute canonical =~ "first-secret"
    assert outcome.consumption.nodes == 6
  end

  test "masked ancestors are opaque even when they contain hostile BEAM terms" do
    policy =
      policy!(
        rules: [
          [id: "opaque", path: ["opaque"], sensitivity: :secret, action: :mask]
        ]
      )

    hostile = %{password: "secret-canary", function: fn -> raise "secret-canary" end}
    input = %{"kept" => true, "opaque" => [hostile | self()]}

    assert {:ok, outcome} = Redaction.redact(input, :internal, policy)
    assert outcome.value == %{"kept" => true, "opaque" => "[REDACTED]"}
    refute Canonical.encode(outcome.manifest) =~ "secret-canary"
  end

  test "undeclared secret roots deny export by default without inspecting their contents" do
    policy = policy!()
    secret = [fn -> raise "must not run" end | self()]

    assert {:ok, outcome} = Redaction.redact(secret, :secret, policy)
    assert outcome.value == nil

    assert [%{"action" => "drop", "count" => 1, "path" => []}] =
             Enum.map(outcome.manifest, &Map.drop(&1, ["policy_id"]))
  end

  test "rules cannot downgrade a root or inherited subtree sensitivity" do
    policy =
      policy!(
        rules: [
          [id: "root", path: [], sensitivity: :public, action: :mask],
          [id: "child", path: ["child"], sensitivity: :public, action: :mask]
        ]
      )

    assert {:ok, root} = Redaction.redact("secret-canary", :secret, policy)
    assert root.value == "[REDACTED]"
    refute Canonical.encode(root.value) =~ "secret-canary"

    nested_policy =
      policy!(
        rules: [
          [id: "parent", path: ["parent"], sensitivity: :confidential, action: :mask],
          [id: "child", path: ["parent", "child"], sensitivity: :public, action: :mask]
        ]
      )

    assert {:ok, nested} =
             Redaction.redact(
               %{"parent" => %{"child" => "secret-canary"}},
               :internal,
               nested_policy
             )

    assert nested.value == %{"parent" => "[REDACTED]"}
  end

  test "an exact rule takes precedence over a terminal wildcard without downgrading sensitivity" do
    policy =
      policy!(
        rules: [
          [id: "all", path: ["items", :each], sensitivity: :confidential, action: :drop],
          [id: "first", path: ["items", 0], sensitivity: :secret, action: :mask]
        ]
      )

    assert {:ok, outcome} =
             Redaction.redact(%{"items" => ["first-secret", "second-secret"]}, :internal, policy)

    assert outcome.value == %{"items" => ["[REDACTED]", nil]}

    assert Enum.map(outcome.manifest, &{&1["action"], &1["path"]}) == [
             {"drop", ["key:items", "each:*"]},
             {"mask", ["key:items", "index:0"]}
           ]
  end

  test "unsupported retained terms and ambiguous keys deny export without source data" do
    policy = policy!()

    for input <- [
          %{"secret-canary" => :atom},
          %{secret: "secret-canary"},
          %{"a" => 1, :a => "secret-canary"},
          ["safe" | "secret-canary"],
          self(),
          make_ref(),
          fn -> :ok end,
          {:secret_canary},
          1.5,
          <<255>>,
          1 <<< 1_000_000
        ] do
      assert {:error, %Error{code: :redaction_failed} = error} =
               Redaction.redact(input, :internal, policy)

      refute inspect(error) =~ "secret-canary"
    end
  end

  test "container, global node, output, and manifest bounds fail closed" do
    width_policy = policy!(max_width: 2)
    assert_failed(Redaction.redact(%{"a" => 1, "b" => 2, "c" => 3}, :internal, width_policy))
    assert_failed(Redaction.redact([1, 2, 3], :internal, width_policy))

    node_policy = policy!(max_nodes: 3)
    assert_failed(Redaction.redact(%{"a" => [1, 2]}, :internal, node_policy))

    output_policy = policy!(max_output_bytes: 64)
    assert_failed(Redaction.redact(String.duplicate("x", 65), :internal, output_policy))

    input_policy = policy!(max_input_bytes: 64, max_output_bytes: 1_024)

    assert_failed(
      Redaction.redact(%{"key" => String.duplicate("x", 62)}, :internal, input_policy)
    )

    manifest_policy =
      policy!(
        max_manifest_records: 1,
        rules: [
          [id: "a", path: ["a"], sensitivity: :secret, action: :mask],
          [id: "b", path: ["b"], sensitivity: :secret, action: :mask]
        ]
      )

    assert_failed(Redaction.redact(%{"a" => 1, "b" => 2}, :internal, manifest_policy))
  end

  test "an outer absolute deadline can only shorten the policy budget" do
    policy = policy!(max_duration_ms: 10_000)
    expired = System.monotonic_time(:microsecond) - 1

    assert {:error, %Error{code: :redaction_failed, details: %{reason: "deadline_exceeded"}}} =
             Redaction.redact(%{"safe" => true}, :internal, policy,
               deadline_monotonic_us: expired
             )

    assert {:error, %Error{code: :redaction_failed}} =
             Redaction.redact(%{"safe" => true}, :internal, policy, unknown: expired)
  end

  test "map order does not change sanitized bytes, manifest, or policy fingerprint" do
    rules = [[id: "secret", path: ["z"], sensitivity: :confidential, action: :mask]]
    first_policy = policy!(rules: rules)
    second_policy = policy!(rules: Enum.reverse(rules))
    assert first_policy.fingerprint == second_policy.fingerprint

    {:ok, first} = Redaction.redact(Map.new([{"z", "secret"}, {"a", 1}]), :internal, first_policy)

    {:ok, second} =
      Redaction.redact(Map.new([{"a", 1}, {"z", "secret"}]), :internal, second_policy)

    assert Canonical.encode(first.value) == Canonical.encode(second.value)
    assert first.manifest == second.manifest
  end

  test "dynamic binary keys cannot grow the atom table" do
    policy = policy!()
    unique = System.unique_integer([:positive])
    keys = Enum.map(1..100, &"redaction-never-atom-#{unique}-#{&1}")
    input = Map.new(Enum.with_index(keys))
    Enum.each(keys, &assert_raise(ArgumentError, fn -> String.to_existing_atom(&1) end))
    assert {:ok, _outcome} = Redaction.redact(input, :internal, policy)
    Enum.each(keys, &assert_raise(ArgumentError, fn -> String.to_existing_atom(&1) end))
  end

  test "manifest is directly compatible with Event v1 redaction records" do
    policy =
      policy!(rules: [[id: "secret", path: ["secret"], sensitivity: :secret, action: :mask]])

    {:ok, outcome} = Redaction.redact(%{"secret" => "value"}, :internal, policy)

    assert {:ok, event} =
             Event.new(
               id: "redacted-event",
               node: "node",
               boot_id: "boot",
               source: "contract",
               kind: "observation",
               severity: :info,
               monotonic_time: 1,
               clock_id: "clock",
               source_instance_id: "source",
               source_sequence: 1,
               wall_time: nil,
               subject: nil,
               causality: %{
                 trace_id: nil,
                 span_id: nil,
                 parent_event_id: nil,
                 logical_operation_id: nil,
                 process_generation: nil
               },
               attributes: %{},
               payload: outcome.value,
               authority: "policy",
               redactions: outcome.manifest,
               extensions: %{}
             )

    assert event.redactions == outcome.manifest
  end

  test "policy construction rejects unbounded, duplicate, ambiguous, and executable rules" do
    assert {:ok, %Policy{}} =
             Policy.new(
               id: "all-options",
               rules: [],
               maximum_sensitivity: :internal,
               max_nodes: 1,
               max_width: 1,
               max_input_bytes: 64,
               max_output_bytes: 64,
               max_manifest_records: 1,
               max_duration_ms: 1
             )

    invalid_options = [
      [],
      [id: "policy", rules: [], unknown: true],
      [id: String.duplicate("x", 49), rules: []],
      [id: "policy", rules: :unbounded],
      List.duplicate({:id, "policy"}, 10_000),
      [id: "policy", rules: [List.duplicate({:id, "rule"}, 10_000)]],
      [
        id: "policy",
        rules: [[id: "rule", path: [:each, "nested"], sensitivity: :secret, action: :mask]]
      ],
      [
        id: "policy",
        rules: [[id: "rule", path: [fn -> :ok end], sensitivity: :secret, action: :mask]]
      ],
      [
        id: "policy",
        rules: [
          [id: "first", path: ["same"], sensitivity: :secret, action: :mask],
          [id: "second", path: ["same"], sensitivity: :secret, action: :drop]
        ]
      ]
    ]

    Enum.each(invalid_options, fn options ->
      assert {:error, %Error{code: :redaction_failed}} = Policy.new(options)
    end)

    assert {:error, %Error{code: :redaction_failed}} = Policy.new(:invalid)

    valid = policy!()
    forged = %{valid | max_nodes: 1 <<< 1_000_000}
    assert {:error, %Error{code: :redaction_failed}} = Redaction.redact(%{}, :internal, forged)

    callback_forgery = Map.put(valid, :callback, fn -> "secret-canary" end)

    assert {:error, %Error{code: :redaction_failed}} =
             Redaction.redact(%{}, :internal, callback_forgery)
  end

  property "the public boundary is total and successful output is bounded JSON data" do
    check all(value <- term(), max_runs: 100) do
      policy = policy!(max_output_bytes: 1_024)

      case Redaction.redact(value, :internal, policy) do
        {:ok, outcome} ->
          assert Insider.Event.Value.valid?(outcome.value, 1_024)
          assert outcome.consumption.output_bytes <= 1_024

        {:error, %Error{code: :redaction_failed}} ->
          :ok
      end
    end
  end

  defp policy!(options \\ []) do
    options = Keyword.merge([id: "test-policy", rules: []], options)
    {:ok, policy} = Policy.new(options)
    policy
  end

  defp assert_failed({:error, %Error{code: :redaction_failed}}), do: :ok
end
