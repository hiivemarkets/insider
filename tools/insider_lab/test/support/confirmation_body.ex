defmodule Insider.TestSupport.ConfirmationContract do
  use Insider.Contract, id: "test.confirmation", version: 1

  reset(:fixture, with: &reset/0, environments: [:test])
  action(:fail, with: &fail/0, environments: [:test])
  observe(:echo, with: &echo/1, sensitivity: :internal)
  owns(modules: [Insider.TestSupport.ConfirmationContract])

  defp reset, do: %{"reset" => true}
  defp fail, do: raise("controlled confirmation scenario failure")

  defp echo("verification-timeout") do
    receive do
      :release_verification_timeout_callback -> :unexpected
    end
  end

  defp echo(value), do: value
end

defmodule Insider.TestSupport.ConfirmationProvider do
  @behaviour Insider.Sentinel.Sandbox.Provider

  @impl true
  def identity, do: %{"id" => "test.confirmation-sandbox", "version" => 1}

  @impl true
  def acquire(owner_id, target, _deadline) do
    :persistent_term.put({__MODULE__, owner_id}, target.provenance)

    if get_in(target.provenance, ["components", "code", "attributes", "mode"]) ==
         "acquire_error",
       do: {:error, :acquire_failed},
       else: :ok
  end

  @impl true
  def observe(owner_id, _deadline), do: {:ok, :persistent_term.get({__MODULE__, owner_id})}

  @impl true
  def cleanup(owner_id, _deadline) do
    provenance = :persistent_term.get({__MODULE__, owner_id})

    if get_in(provenance, ["components", "code", "attributes", "mode"]) != "cleanup_partial" do
      :persistent_term.erase({__MODULE__, owner_id})
    end

    :ok
  end

  @impl true
  def inventory(owner_id, _deadline) do
    case :persistent_term.get({__MODULE__, owner_id}, nil) do
      nil ->
        {:ok, []}

      provenance ->
        :persistent_term.erase({__MODULE__, owner_id})
        digest = provenance["fingerprint"]
        {:ok, [%{"id_fingerprint" => "sha256:" <> digest, "kind" => "fixture"}]}
    end
  end
end

defmodule Insider.TestSupport.ConfirmationBody do
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Scenario
  alias Insider.Scenario.Executor
  alias Insider.Sentinel.Confirmation.Receipt
  alias Insider.TestSupport.ConfirmationContract

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}

  def run(arguments, mode) do
    with true <- arguments.input["observer"] == @observer,
         true <- arguments.input["repair_oracle"] in [nil, @oracle],
         {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         {:ok, scenario_executor} <- Executor.start_link(name: nil, max_concurrency: 1),
         {:ok, contract_executor} <-
           Insider.Contract.Executor.start_link(name: nil, max_concurrency: 1) do
      result = execute_scenario(scenario_executor, contract_executor, scenario, arguments)
      receipt = receipt(arguments, scenario, result, mode)
      Supervisor.stop(scenario_executor)
      Supervisor.stop(contract_executor)
      {:ok, receipt}
    else
      _error -> {:error, :confirmation_adapter_failed, %{}}
    end
  end

  defp execute_scenario(executor, contract_executor, scenario, arguments) do
    {request, context} = authority!(scenario, arguments.deadline)

    Executor.run(executor, scenario, [ConfirmationContract],
      request: request,
      context: context,
      contract_executor: contract_executor
    )
  end

  defp receipt(arguments, scenario, result, mode) do
    expected = arguments.input["expected_fingerprint"]
    mode = resolve_mode(mode, result)
    evidence = evidence(mode)
    scenario_status = if match?(%Result{status: :ok}, result), do: "completed", else: "failed"

    owner_fingerprint =
      if mode == :stale,
        do: "sha256:" <> String.duplicate("0", 64),
        else: owner_fingerprint(arguments.owner_id)

    {:ok, receipt} =
      Receipt.new(
        manifest_id: arguments.input["manifest_id"],
        capsule_id: arguments.input["capsule_id"],
        scenario_id: scenario.id,
        target_id: arguments.target.id,
        expected_fingerprint: expected,
        owner_fingerprint: owner_fingerprint,
        observed_target_fingerprint: arguments.observed_provenance["fingerprint"],
        observation_run_fingerprint: owner_fingerprint,
        observer: @observer,
        lease_execution: "confirmed",
        scenario_status: scenario_status,
        observed_incident_fingerprints: observed(mode, expected),
        evidence: evidence,
        repair_oracle: oracle(arguments.input["repair_oracle"], mode),
        reason: reason(scenario_status, evidence)
      )

    receipt
  end

  defp resolve_mode(:required_execution, %Result{} = result),
    do: if(required_executed?(result), do: :matching, else: :none)

  defp resolve_mode({:required_execution, selected}, %Result{} = result)
       when selected in [:matching, :none],
       do: if(required_executed?(result), do: selected, else: :none)

  defp resolve_mode(mode, _result), do: mode

  defp required_executed?(%Result{status: :ok, value: %{"completed_step_ids" => ids}}),
    do: "required" in ids

  defp required_executed?(_result), do: false

  defp observed(mode, expected) when mode in [:matching, :matching_scenario_failed],
    do: [expected]

  defp observed(:unrelated, _expected), do: [String.duplicate("f", 64)]
  defp observed(_mode, _expected), do: []

  defp evidence(:incomplete),
    do: %{
      "armed_before_scenario" => true,
      "complete" => false,
      "dropped" => 1,
      "finalized_after_scenario" => true,
      "gaps" => 0,
      "truncated" => false
    }

  defp evidence(_mode),
    do: %{
      "armed_before_scenario" => true,
      "complete" => true,
      "dropped" => 0,
      "finalized_after_scenario" => true,
      "gaps" => 0,
      "truncated" => false
    }

  defp reason(_scenario_status, %{"complete" => false}), do: "observer_failed"
  defp reason("failed", _evidence), do: "scenario_failed"
  defp reason("completed", _evidence), do: nil
  defp oracle(nil, _mode), do: nil

  defp oracle(identity, mode) do
    status = if mode == :repaired, do: "passed", else: "failed"
    %{"identity" => identity, "receipt_digest" => String.duplicate("d", 64), "status" => status}
  end

  defp authority!(scenario, outer_deadline) do
    now = System.monotonic_time(:millisecond)
    duration = min(scenario.limits["max_duration_ms"], max(10, outer_deadline - now))
    target = %{node: Atom.to_string(node())}
    {:ok, budget} = Budget.new(max_duration_ms: duration, max_events: 100, max_bytes: 65_536)

    {:ok, request} =
      Request.new("scenario.run",
        request_id: "confirmation-scenario",
        environment: :test,
        target: target,
        timeout_ms: duration,
        budget: Map.from_struct(budget),
        capability: "confirmation-scenario-grant",
        params: %{"scenario_id" => scenario.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "confirmation-scenario-grant",
        audit_id: "confirmation-scenario-audit",
        scopes: ["scenario.execute"],
        target: target,
        expires_at_monotonic: now + duration
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "confirmation-body",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "scenario.run" => %{
            available: true,
            provider: "confirmation-body",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp owner_fingerprint(owner_id),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, owner_id), case: :lower)
end

for mode <- [
      :matching,
      :matching_scenario_failed,
      :repaired,
      :unrelated,
      :none,
      :incomplete,
      :stale
    ] do
  module =
    Module.concat(Insider.TestSupport, "ConfirmationBody#{Macro.camelize(to_string(mode))}")

  defmodule module do
    @behaviour Insider.Sentinel.Sandbox.Body
    @mode mode

    @impl true
    def identity, do: %{"id" => "test.confirmation-body.#{@mode}", "version" => 1}

    @impl true
    def run(arguments), do: Insider.TestSupport.ConfirmationBody.run(arguments, @mode)
  end
end

defmodule Insider.TestSupport.MinimizerConfirmationBody do
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.TestSupport.ConfirmationBody

  @impl true
  def identity, do: %{"id" => "test.minimizer-confirmation-body", "version" => 1}

  @impl true
  def run(arguments), do: ConfirmationBody.run(arguments, :required_execution)
end

defmodule Insider.TestSupport.MinimizerNondeterministicBody do
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Scenario
  alias Insider.TestSupport.ConfirmationBody

  @impl true
  def identity, do: %{"id" => "test.minimizer-nondeterministic-body", "version" => 1}

  @impl true
  def run(arguments) do
    with {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         counter when is_reference(counter) <-
           :persistent_term.get({__MODULE__, scenario.seed}, :missing) do
      selected =
        if match?([_, _, _], scenario.steps) or rem(:atomics.add_get(counter, 1, 1), 2) == 1,
          do: :matching,
          else: :none

      ConfirmationBody.run(arguments, {:required_execution, selected})
    else
      _other -> {:error, :minimizer_counter_missing, %{}}
    end
  end
end

defmodule Insider.TestSupport.MinimizerBaselineNondeterministicBody do
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Scenario
  alias Insider.TestSupport.ConfirmationBody

  @impl true
  def identity, do: %{"id" => "test.minimizer-baseline-nondeterministic-body", "version" => 1}

  @impl true
  def run(arguments) do
    with {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         counter when is_reference(counter) <-
           :persistent_term.get({__MODULE__, scenario.seed}, :missing) do
      selected = if rem(:atomics.add_get(counter, 1, 1), 2) == 1, do: :matching, else: :none
      ConfirmationBody.run(arguments, {:required_execution, selected})
    else
      _other -> {:error, :minimizer_counter_missing, %{}}
    end
  end
end

defmodule Insider.TestSupport.MinimizerBlockingBody do
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Scenario

  @impl true
  def identity, do: %{"id" => "test.minimizer-blocking-body", "version" => 1}

  @impl true
  def run(arguments) do
    case :persistent_term.get({__MODULE__, seed(arguments.input)}, :missing) do
      parent when is_pid(parent) ->
        send(parent, {:minimizer_blocking_body_started, self()})

        receive do
          :unexpected_release -> {:ok, %{}}
        end

      _missing ->
        {:error, :minimizer_parent_missing, %{}}
    end
  end

  defp seed(%{"seed" => seed}), do: seed

  defp seed(%{"scenario" => scenario}) do
    case Scenario.decode_map(scenario) do
      {:ok, scenario} -> scenario.seed
      _error -> nil
    end
  end

  defp seed(_input), do: nil
end
