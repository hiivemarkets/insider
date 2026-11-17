defmodule Insider.ScenarioTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Insider.Contract
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Scenario
  alias Insider.Scenario.Executor
  alias Insider.TestSupport.ExampleContract
  alias Insider.TestSupport.ScenarioContract

  @digest String.duplicate("a", 64)

  setup do
    Process.register(self(), Insider.TestSupport.ScenarioProbe)
    :ets.new(Insider.TestSupport.ScenarioState, [:named_table, :public])
    executor = start_supervised!({Executor, name: nil, max_concurrency: 2})
    contract_executor = start_supervised!({Contract.Executor, name: nil, max_concurrency: 2})

    on_exit(fn ->
      if Process.whereis(Insider.TestSupport.ScenarioProbe) == self(),
        do: Process.unregister(Insider.TestSupport.ScenarioProbe)
    end)

    %{contract_executor: contract_executor, executor: executor}
  end

  test "canonical scenario pins reset, actions, waits, observations, seed, and incident fingerprints" do
    scenario = scenario!()

    assert {:ok, bytes} = Scenario.canonical_binary(scenario)
    assert {:ok, ^scenario} = Scenario.decode(bytes)
    assert {:ok, ^scenario} = Scenario.decode_map(Jason.decode!(bytes))

    assert {:ok, %{"status" => "available", "fingerprint" => fingerprint}} =
             Scenario.descriptor(scenario)

    assert fingerprint == scenario.integrity["content_digest"]
    assert scenario.id == "sha256:" <> fingerprint
    assert scenario.seed == "seed-42"
    assert scenario.expected_incident_fingerprints == [@digest]
    assert Enum.map(scenario.steps, & &1["type"]) == ["action", "wait", "observation"]
  end

  test "scenario duration accepts ten minutes exactly without widening cleanup" do
    description = scenario!(contract_only: true)
    base = scenario!()

    options = [
      seed: base.seed,
      reset: base.reset,
      steps: base.steps,
      expected_incident_fingerprints: base.expected_incident_fingerprints
    ]

    assert {:ok, %Scenario{limits: limits}} =
             Scenario.new(
               description,
               options ++
                 [limits: %{"cleanup_timeout_ms" => 5_000, "max_duration_ms" => 600_000}]
             )

    assert limits == %{"cleanup_timeout_ms" => 5_000, "max_duration_ms" => 600_000}

    for invalid_limits <- [
          %{"cleanup_timeout_ms" => 5_000, "max_duration_ms" => 600_001},
          %{"cleanup_timeout_ms" => 5_001, "max_duration_ms" => 600_000}
        ] do
      assert {:error, %Error{code: :invalid_scenario}} =
               Scenario.new(description, options ++ [limits: invalid_limits])
    end
  end

  test "retains only an ordered whole-step subsequence and readdresses it" do
    scenario = scenario!()
    retained_ids = ["record", "capture"]

    assert {:ok, %Scenario{} = candidate} = Scenario.retain_steps(scenario, retained_ids)
    assert Enum.map(candidate.steps, & &1["id"]) == retained_ids
    assert candidate.steps == Enum.filter(scenario.steps, &(&1["id"] in retained_ids))
    assert candidate.id != scenario.id
    assert candidate.contract == scenario.contract
    assert candidate.seed == scenario.seed
    assert candidate.reset == scenario.reset
    assert candidate.expected_incident_fingerprints == scenario.expected_incident_fingerprints
    assert candidate.limits == scenario.limits
    assert {:ok, bytes} = Scenario.canonical_binary(candidate)
    assert {:ok, ^candidate} = Scenario.decode(bytes)

    assert {:ok, ^scenario} =
             Scenario.retain_steps(scenario, Enum.map(scenario.steps, & &1["id"]))

    for invalid <- [
          [],
          ["capture", "record"],
          ["record", "record"],
          ["unknown"],
          ["record", 1]
        ] do
      assert {:error, %Error{code: :invalid_scenario}} =
               Scenario.retain_steps(scenario, invalid)
    end

    assert {:error, %Error{code: :invalid_scenario}} =
             Scenario.retain_steps(:invalid, ["record"])
  end

  test "executes sequentially, compares observations in memory, and resets before and after", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario = scenario!()
    {request, context} = authority!(scenario)

    assert %Result{status: :ok, cleanup: %{status: :complete}, value: value, effects: effects} =
             Executor.run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert_receive :reset
    assert_receive {:action, "payload"}
    assert_receive {:observation, "ready"}
    assert_receive {:observation, "captured"}
    assert_receive :reset

    assert value["completed_step_ids"] == ["record", "ready", "capture"]
    assert value["expectation_status"] == "not_evaluated"

    assert Enum.all?(effects, fn effect ->
             not Map.has_key?(effect.details, :value) and
               not Map.has_key?(effect.details, "value")
           end)

    assert Enum.count(effects, &(&1.kind == :contract_mutation)) == 3
    assert Enum.count(effects, &(&1.kind == :semantic_observation)) == 2
  end

  test "an exhausted semantic wait stops later work but still resets", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario = scenario!(steps: [wait_step("never", "actual", "expected", 2)])
    {request, context} = authority!(scenario)

    assert %Result{
             status: :timeout,
             error: %Error{code: :deadline_exceeded},
             cleanup: %{status: :complete},
             effects: effects
           } =
             Executor.run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert_receive :reset
    assert_receive {:observation, "actual"}
    assert_receive {:observation, "actual"}
    assert_receive :reset

    assert [%{details: %{attempts: 2}}] =
             Enum.filter(effects, &(&1.kind == :semantic_observation))
  end

  test "an invariant wait succeeds without exporting its classified value", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    step = %{
      "id" => "truthy",
      "type" => "wait",
      "kind" => "invariant",
      "name" => "truthy",
      "arguments" => [true],
      "expectation" => %{"operator" => "satisfied"},
      "max_attempts" => 2,
      "interval_ms" => 0
    }

    scenario = scenario!(steps: [step])
    {request, context} = authority!(scenario)

    assert %Result{status: :ok, effects: effects} =
             run(executor, contract_executor, scenario, request, context)

    assert_receive :reset
    assert_receive {:invariant, true}
    assert_receive :reset

    assert [%{details: %{attempts: 1, invocation_status: :ok}}] =
             Enum.filter(effects, &(&1.kind == :semantic_observation))
  end

  test "an invariant violation exhausts its exact attempt bound", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario = scenario!(steps: [invariant_wait_step("truthy", false, 2)])
    {request, context} = authority!(scenario)

    assert %Result{status: :timeout, cleanup: %{status: :complete}, effects: effects} =
             run(executor, contract_executor, scenario, request, context)

    assert_receive :reset
    assert_receive {:invariant, false}
    assert_receive {:invariant, false}
    assert_receive :reset

    assert [%{details: %{attempts: 2, invocation_status: :violation}}] =
             Enum.filter(effects, &(&1.kind == :semantic_observation))
  end

  test "a failed action stops later steps and retains an unknown mutation receipt", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario =
      scenario!(steps: [action_step("failure", "fail", []), observation_step("later", "never")])

    {request, context} = authority!(scenario)

    assert %Result{status: :error, cleanup: %{status: :complete}, effects: effects} =
             run(executor, contract_executor, scenario, request, context)

    assert_receive :reset
    assert_receive :action_failed
    assert_receive :reset
    refute_received {:observation, "never"}

    assert Enum.any?(effects, fn effect ->
             effect.kind == :contract_mutation and effect.status == :unknown and
               effect.details[:scenario_step_id] == "failure"
           end)
  end

  test "initial reset and semantic wait callback failures abort without retries", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    failed_reset =
      scenario!(
        reset: %{"name" => "fail_reset", "arguments" => []},
        steps: [observation_step("never", "never")]
      )

    {request, context} = authority!(failed_reset)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             run(executor, contract_executor, failed_reset, request, context)

    assert_receive :reset_failed
    assert_receive :reset_failed
    refute_received {:observation, "never"}

    failed_wait =
      scenario!(
        steps: [
          %{
            "id" => "failure",
            "type" => "wait",
            "kind" => "observation",
            "name" => "fail_observation",
            "arguments" => [],
            "expectation" => %{"operator" => "equals", "value" => "never"},
            "max_attempts" => 3,
            "interval_ms" => 0
          }
        ]
      )

    {request, context} = authority!(failed_wait)

    assert %Result{status: :error, cleanup: %{status: :complete}, effects: effects} =
             run(executor, contract_executor, failed_wait, request, context)

    assert_receive :reset
    assert_receive :observation_failed
    assert_receive :reset
    refute_received :observation_failed

    assert [%{status: :partial, details: %{attempts: 1}}] =
             Enum.filter(effects, &(&1.kind == :semantic_observation))
  end

  test "a failed or timed-out final reset prevents a successful cleanup claim", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    for reset_mode <- [:fail_final, :block_final] do
      :ets.insert(Insider.TestSupport.ScenarioState, [{:resets, 0}, {:reset_mode, reset_mode}])

      scenario =
        scenario!(
          reset: %{"name" => "counted", "arguments" => []},
          steps: [observation_step("body", "done")],
          limits: %{"cleanup_timeout_ms" => 80, "max_duration_ms" => 500}
        )

      {request, context} = authority!(scenario, timeout_ms: 500)

      assert %Result{
               status: :error,
               cleanup: %{status: :uncertain},
               uncertainty: uncertainty
             } = run(executor, contract_executor, scenario, request, context)

      assert Enum.any?(uncertainty, &String.contains?(&1, "not confirmed"))
      assert_receive {:counted_reset, 1}
      assert_receive {:observation, "done"}
      assert_receive {:counted_reset, 2}

      if reset_mode == :block_final, do: assert_receive(:cleanup_started)
    end
  end

  test "the body deadline aborts a mutator before running the reserved cleanup", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario =
      scenario!(
        steps: [action_step("blocked", "block", [])],
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 250}
      )

    {request, context} = authority!(scenario, timeout_ms: 500)

    assert %Result{status: :timeout, cleanup: %{status: :complete}} =
             run(executor, contract_executor, scenario, request, context)

    assert_receive :reset
    assert_receive :block_started
    assert_receive :reset
  end

  test "cancellation stops an active mutation, retains its effect, and performs cleanup", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario =
      scenario!(
        steps: [action_step("blocked", "block", [])],
        limits: %{"cleanup_timeout_ms" => 200, "max_duration_ms" => 600}
      )

    {request, context} = authority!(scenario)

    assert {:ok, handle} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert_receive :reset
    assert_receive :block_started
    assert :ok = Executor.cancel(handle)

    assert %Result{
             status: :cancelled,
             value: nil,
             cleanup: %{status: :complete},
             effects: effects,
             uncertainty: uncertainty
           } = Executor.await(handle, 2_000)

    assert_receive :reset
    assert Enum.count(effects, &(&1.kind == :contract_mutation)) == 3
    assert Enum.any?(uncertainty, &String.contains?(&1, "not rollback"))
  end

  test "cancellation during a semantic wait stops retries and begins cleanup immediately", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    step = wait_step("waiting", "actual", "expected", 2) |> Map.put("interval_ms", 1_000)

    scenario =
      scenario!(
        steps: [step],
        limits: %{"cleanup_timeout_ms" => 200, "max_duration_ms" => 1_500}
      )

    {request, context} = authority!(scenario, timeout_ms: 1_500)

    assert {:ok, handle} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert_receive :reset
    assert_receive {:observation, "actual"}
    assert_runner_phase(handle.pid, :waiting)
    assert :ok = Executor.cancel(handle)

    assert %Result{status: :cancelled, cleanup: %{status: :complete}} =
             Executor.await(handle, 2_000)

    assert_receive :reset
    refute_received {:observation, "actual"}
  end

  test "fails closed before effects for untrusted targets, request mismatch, and contract drift",
       %{
         executor: executor,
         contract_executor: contract_executor
       } do
    scenario = scenario!()
    {request, context} = authority!(scenario)

    host_context = %{context | target_class: :host}

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: request,
               context: host_context,
               contract_executor: contract_executor
             )

    wrong_request = %{request | params: %{"scenario_id" => "sha256:" <> @digest}}

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: wrong_request,
               context: context,
               contract_executor: contract_executor
             )

    remote_request = %{request | target: %{node: "remote@invalid"}}

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: remote_request,
               context: context,
               contract_executor: contract_executor
             )

    assert {:error, %Error{code: :scenario_contract_mismatch}} =
             Scenario.resolve(scenario, [], :test)

    refute_received :reset
  end

  test "executor sheds overload and public handle APIs fail without raising", %{
    contract_executor: contract_executor
  } do
    child_spec = Supervisor.child_spec({Executor, name: nil, max_concurrency: 1}, id: make_ref())
    executor = start_supervised!(child_spec)

    scenario =
      scenario!(
        steps: [action_step("blocked", "block", [])],
        limits: %{"cleanup_timeout_ms" => 150, "max_duration_ms" => 400}
      )

    {request, context} = authority!(scenario, timeout_ms: 500)

    assert {:ok, handle} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert_receive :reset
    assert_receive :block_started

    assert {:error, %Error{code: :operation_failed, retryable: true}} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert {:error, %Error{code: :invalid_request}} = Executor.await(%{}, -1)
    assert {:error, %Error{code: :invalid_request}} = Executor.cancel(%{})
    assert {:error, %Error{code: :invalid_scenario}} = Executor.run(executor, :bad, [], [])

    fake_handle = %{pid: self(), token: make_ref()}
    assert {:error, %Error{code: :deadline_exceeded}} = Executor.await(fake_handle, 0)

    dead_runner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    dead_monitor = Process.monitor(dead_runner)
    send(dead_runner, :stop)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead_runner, :normal}

    assert {:error, %Error{code: :operation_failed}} =
             Executor.await(%{pid: dead_runner, token: make_ref()}, 100)

    assert {:error, %Error{code: :operation_failed}} =
             Executor.start_run(dead_runner, scenario, [ScenarioContract],
               request: request,
               context: context,
               contract_executor: contract_executor
             )

    assert :ok = Executor.cancel(handle)
    assert %Result{status: :cancelled} = Executor.await(handle, 2_000)
    assert_receive :reset
  end

  test "maximum step receipts fit the minimum admitted result budget", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    steps =
      Enum.map(1..64, fn index ->
        suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")
        action_step("step-" <> suffix <> String.duplicate("x", 116), "record", [index])
      end)

    scenario = scenario!(steps: steps)
    assert {:ok, bytes} = Scenario.canonical_binary(scenario)
    assert byte_size(bytes) <= 65_536

    {small_request, small_context} = authority!(scenario, max_bytes: 16_384)

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, scenario, [ScenarioContract],
               request: small_request,
               context: small_context,
               contract_executor: contract_executor
             )

    refute_received :reset

    {request, context} = authority!(scenario, max_bytes: 65_536)

    assert %Result{status: :ok, cleanup: %{status: :complete}, value: value, effects: effects} =
             run(executor, contract_executor, scenario, request, context)

    assert Enum.count_until(value["completed_step_ids"], 65) == 64
    assert Enum.count_until(effects, 67) == 66
  end

  test "execution option lists are exact, unique, proper, and statically bounded", %{
    executor: executor
  } do
    scenario = scenario!()
    {request, context} = authority!(scenario)

    invalid_options = [
      [request: request, context: context, unknown: true],
      [request: request, request: request, context: context],
      List.duplicate({:request, request}, 4),
      [{:request, request}, {:context, context} | :improper]
    ]

    for options <- invalid_options do
      assert {:error, %Error{code: :policy_denied}} =
               Executor.start_run(executor, scenario, [ScenarioContract], options)
    end

    refute_received :reset
  end

  test "caller death cancels future work and still runs the declared reset", %{
    executor: executor,
    contract_executor: contract_executor
  } do
    scenario =
      scenario!(
        steps: [action_step("blocked", "block", [])],
        limits: %{"cleanup_timeout_ms" => 150, "max_duration_ms" => 400}
      )

    {request, context} = authority!(scenario, timeout_ms: 500)
    parent = self()

    caller =
      spawn(fn ->
        result =
          Executor.start_run(executor, scenario, [ScenarioContract],
            request: request,
            context: context,
            contract_executor: contract_executor
          )

        send(parent, {:started_by_child, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:started_by_child, {:ok, handle}}
    assert_receive :reset
    assert_receive :block_started
    monitor = Process.monitor(handle.pid)
    send(caller, :stop)
    assert_receive :reset, 2_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 2_000
  end

  test "rejects tampering, noncanonical bytes, unknown fields, unsafe terms, and invalid recipes" do
    scenario = scenario!()
    wire = Scenario.to_wire_map(scenario)

    assert {:error, %Error{code: :scenario_integrity_failed}} =
             Scenario.decode_map(put_in(wire, ["seed"], "changed"))

    assert {:error, %Error{code: :invalid_scenario}} =
             Scenario.decode_map(Map.put(wire, "command", "mix test"))

    assert {:error, %Error{code: :unsupported_scenario_schema}} =
             Scenario.decode_map(Map.put(wire, "schema", "insider.scenario/v2"))

    pretty = Jason.encode!(wire, pretty: true)
    assert {:error, %Error{code: :invalid_scenario}} = Scenario.decode(pretty)

    assert {:error, %Error{code: :scenario_limit_exceeded}} =
             Scenario.decode(String.duplicate("x", 65_537))

    assert {:error, %Error{code: :invalid_scenario}} = Scenario.validate(self())

    assert {:error, %Error{code: :invalid_scenario}} =
             scenario!(contract_only: true)
             |> then(fn description ->
               Scenario.new(description,
                 seed: "seed",
                 reset: %{"name" => "missing", "arguments" => []},
                 steps: [action_step("action", "record", ["value"])]
               )
             end)
  end

  test "constructor, codec, and resolver reject malformed boundary variants with typed errors" do
    description = scenario!(contract_only: true)
    scenario = scenario!()

    for operation <- [
          fn -> Scenario.new(description, seed: "seed") end,
          fn -> Scenario.new(description, :not_options) end,
          fn ->
            Scenario.new(description,
              seed: "seed",
              reset: scenario.reset,
              unknown: true
            )
          end,
          fn ->
            Scenario.new(description, [
              {:seed, "first"},
              {:seed, "second"},
              {:reset, scenario.reset}
            ])
          end,
          fn -> Scenario.new(description, List.duplicate({:seed, "seed"}, 6)) end,
          fn ->
            Scenario.new(description, [{:seed, "seed"}, {:reset, scenario.reset} | :improper])
          end,
          fn -> Scenario.new(:not_a_contract, seed: "seed", reset: scenario.reset) end,
          fn ->
            Scenario.new(description, seed: "", reset: scenario.reset, steps: scenario.steps)
          end,
          fn -> Scenario.new(description, seed: "seed", reset: %{}, steps: scenario.steps) end,
          fn -> Scenario.new(description, seed: "seed", reset: scenario.reset, steps: []) end,
          fn ->
            Scenario.new(description,
              seed: "seed",
              reset: scenario.reset,
              steps: [hd(scenario.steps), hd(scenario.steps)]
            )
          end,
          fn ->
            Scenario.new(description,
              seed: "seed",
              reset: scenario.reset,
              steps: [Map.put(hd(scenario.steps), "type", "command")]
            )
          end,
          fn ->
            Scenario.new(description,
              seed: "seed",
              reset: scenario.reset,
              steps: scenario.steps,
              expected_incident_fingerprints: ["short"]
            )
          end,
          fn ->
            Scenario.new(description,
              seed: "seed",
              reset: scenario.reset,
              steps: scenario.steps,
              limits: %{"cleanup_timeout_ms" => 10, "max_duration_ms" => 10}
            )
          end,
          fn -> Scenario.canonical_binary(:not_a_scenario) end,
          fn -> Scenario.decode(:not_binary) end,
          fn -> Scenario.decode("{") end,
          fn -> Scenario.decode_map(%{"schema" => "insider.scenario/v1"}) end
        ] do
      assert {:error, %Error{}} = operation.()
    end

    invalid_wait =
      wait_step("invalid", "actual", "expected", 1)
      |> Map.put("expectation", %{"operator" => "contains", "value" => "actual"})

    assert {:error, %Error{code: :invalid_scenario}} =
             Scenario.new(description,
               seed: "seed",
               reset: scenario.reset,
               steps: [invalid_wait]
             )

    bad_description = Map.put(description, "fingerprint", @digest)

    assert {:error, %Error{code: :invalid_scenario}} =
             Scenario.new(bad_description,
               seed: "seed",
               reset: scenario.reset,
               steps: scenario.steps
             )

    for invalid <- [
          %{scenario | seed: ""},
          %{scenario | contract: %{}},
          %{scenario | reset: %{}},
          %{scenario | limits: %{}},
          %{scenario | integrity: %{}}
        ] do
      assert {:error, %Error{code: :invalid_scenario}} = Scenario.validate(invalid)
    end

    assert {:error, %Error{code: :scenario_integrity_failed}} =
             scenario |> Map.replace!(:id, "sha256:" <> @digest) |> Scenario.canonical_binary()

    for {modules, environment} <- [
          {[ScenarioContract], :production},
          {[ExampleContract], :test},
          {[:not_a_contract], :test},
          {[ScenarioContract, ScenarioContract], :test},
          {List.duplicate(ScenarioContract, 65), :test}
        ] do
      assert {:error, %Error{code: :scenario_contract_mismatch}} =
               Scenario.resolve(scenario, modules, environment)
    end
  end

  property "decoding arbitrary terms never raises" do
    check all(value <- term()) do
      case Scenario.decode_map(value) do
        {:error, %Error{}} -> :ok
        {:ok, %Scenario{}} -> :ok
      end
    end
  end

  test "frozen v1 fixture remains canonical and content addressed" do
    fixture = File.read!("test/fixtures/scenario_v1.json")
    assert {:ok, scenario} = Scenario.decode(fixture)
    assert {:ok, ^fixture} = Scenario.canonical_binary(scenario)

    assert scenario.id ==
             "sha256:759da55743e60c251bdc15b6e48e60ed3c54c0f76b7ac75c5d20124537b3be43"
  end

  test "unknown schema vocabulary does not create atoms" do
    Scenario.decode_map(%{"schema" => "warm-up"})
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..100 do
      assert {:error, %Error{code: :unsupported_scenario_schema}} =
               Scenario.decode_map(%{"schema" => "attacker-schema-#{index}"})
    end

    assert :erlang.system_info(:atom_count) == before_count
  end

  defp scenario!(options \\ []) do
    {:ok, description} = Contract.describe(ScenarioContract)

    if Keyword.get(options, :contract_only, false) do
      description
    else
      steps =
        Keyword.get(options, :steps, [
          action_step("record", "record", ["payload"]),
          wait_step("ready", "ready", "ready", 3),
          observation_step("capture", "captured")
        ])

      {:ok, scenario} =
        Scenario.new(description,
          seed: "seed-42",
          reset: Keyword.get(options, :reset, %{"name" => "fixture", "arguments" => []}),
          steps: steps,
          expected_incident_fingerprints: [@digest],
          limits:
            Keyword.get(options, :limits, %{
              "cleanup_timeout_ms" => 500,
              "max_duration_ms" => 5_000
            })
        )

      scenario
    end
  end

  defp action_step(id, name, arguments),
    do: %{"id" => id, "type" => "action", "name" => name, "arguments" => arguments}

  defp observation_step(id, value),
    do: %{"id" => id, "type" => "observation", "name" => "echo", "arguments" => [value]}

  defp wait_step(id, actual, expected, attempts) do
    %{
      "id" => id,
      "type" => "wait",
      "kind" => "observation",
      "name" => "echo",
      "arguments" => [actual],
      "expectation" => %{"operator" => "equals", "value" => expected},
      "max_attempts" => attempts,
      "interval_ms" => 0
    }
  end

  defp invariant_wait_step(id, value, attempts) do
    %{
      "id" => id,
      "type" => "wait",
      "kind" => "invariant",
      "name" => "truthy",
      "arguments" => [value],
      "expectation" => %{"operator" => "satisfied"},
      "max_attempts" => attempts,
      "interval_ms" => 0
    }
  end

  defp authority!(scenario, options \\ []) do
    now = System.monotonic_time(:millisecond)
    target = %{node: Atom.to_string(node())}
    timeout_ms = Keyword.get(options, :timeout_ms, 5_000)
    max_bytes = Keyword.get(options, :max_bytes, 65_536)

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 100, max_bytes: max_bytes)

    {:ok, request} =
      Request.new("scenario.run",
        request_id: "scenario-request",
        environment: :test,
        target: target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "scenario-grant",
        params: %{"scenario_id" => scenario.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "scenario-grant",
        audit_id: "scenario-audit",
        scopes: ["scenario.execute"],
        target: target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "scenario-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "scenario.run" => %{
            available: true,
            provider: "scenario-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp run(executor, contract_executor, scenario, request, context) do
    Executor.run(executor, scenario, [ScenarioContract],
      request: request,
      context: context,
      contract_executor: contract_executor
    )
  end

  defp assert_runner_phase(pid, expected, attempts \\ 100)

  defp assert_runner_phase(pid, expected, attempts) when attempts > 0 do
    if :sys.get_state(pid).phase == expected do
      :ok
    else
      assert_runner_phase(pid, expected, attempts - 1)
    end
  end

  defp assert_runner_phase(_pid, expected, 0), do: flunk("runner never entered #{expected}")
end
