defmodule Insider.TestSupport.VerificationProvider do
  @behaviour Insider.Sentinel.Sandbox.Provider

  @impl true
  def identity, do: %{"id" => "test.verification-sandbox", "version" => 1}

  @impl true
  def acquire(owner_id, target, _deadline) do
    :persistent_term.put({__MODULE__, owner_id}, %{provenance: target.provenance, leak: false})
    :ok
  end

  @impl true
  def observe(owner_id, _deadline), do: {:ok, state(owner_id).provenance}

  @impl true
  def cleanup(owner_id, _deadline) do
    unless state(owner_id).leak, do: :persistent_term.erase({__MODULE__, owner_id})
    :ok
  end

  @impl true
  def inventory(owner_id, _deadline) do
    case :persistent_term.get({__MODULE__, owner_id}, nil) do
      nil ->
        {:ok, []}

      %{leak: true} ->
        :persistent_term.erase({__MODULE__, owner_id})
        {:ok, [%{"id_fingerprint" => owner_fingerprint(owner_id), "kind" => "fixture-leak"}]}

      _state ->
        {:ok, []}
    end
  end

  def mark_leak(owner_id),
    do: :persistent_term.put({__MODULE__, owner_id}, %{state(owner_id) | leak: true})

  defp state(owner_id), do: :persistent_term.get({__MODULE__, owner_id})
  defp owner_fingerprint(owner_id), do: "sha256:" <> digest(owner_id)
  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end

defmodule Insider.TestSupport.VerificationBody do
  alias Insider.Contract
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Scenario.Executor
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Receipt
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.VerificationProvider

  def run(arguments, mode) do
    candidate_id = arguments.input["candidate"]["id"]
    :persistent_term.put({__MODULE__, :invoked, candidate_id}, invocations(candidate_id) + 1)
    record_deadline(candidate_id, arguments.deadline)

    result =
      if mode == :blocking,
        do: await_cancellation(arguments),
        else: run_evaluated(arguments, mode)

    record_outcome(candidate_id, result)
    result
  end

  defp run_evaluated(arguments, mode) do
    with {:ok, candidate} <- Candidate.decode_map(arguments.input["candidate"]),
         {:ok, _bytes} <- Candidate.content(candidate),
         {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         {:ok, scenario_executor} <- Executor.start_link(name: nil, max_concurrency: 1),
         {:ok, contract_executor} <-
           Insider.Contract.Executor.start_link(name: nil, max_concurrency: 1) do
      result = execute(scenario_executor, contract_executor, scenario, arguments, mode)
      Supervisor.stop(scenario_executor)
      Supervisor.stop(contract_executor)
      if mode == :leak, do: VerificationProvider.mark_leak(arguments.owner_id)
      evaluated_result(result, arguments, candidate, scenario, mode)
    else
      _error -> {:error, :verification_body_failed, %{}}
    end
  end

  def invocations(candidate_id), do: :persistent_term.get({__MODULE__, :invoked, candidate_id}, 0)

  def deadlines(candidate_id),
    do: :persistent_term.get({__MODULE__, :deadlines, candidate_id}, [])

  def outcomes(candidate_id),
    do: :persistent_term.get({__MODULE__, :outcomes, candidate_id}, [])

  def reset(candidate_id) do
    :persistent_term.erase({__MODULE__, :invoked, candidate_id})
    :persistent_term.erase({__MODULE__, :deadlines, candidate_id})
    :persistent_term.erase({__MODULE__, :outcomes, candidate_id})
  end

  def tracked?(candidate_id),
    do:
      :persistent_term.get({__MODULE__, :invoked, candidate_id}, :missing) != :missing or
        :persistent_term.get({__MODULE__, :deadlines, candidate_id}, :missing) != :missing or
        :persistent_term.get({__MODULE__, :outcomes, candidate_id}, :missing) != :missing

  defp record_deadline(candidate_id, deadline) do
    key = {__MODULE__, :deadlines, candidate_id}
    :persistent_term.put(key, [deadline | :persistent_term.get(key, [])])
  end

  defp record_outcome(candidate_id, result) do
    outcome =
      case result do
        {:ok, _receipt} -> :ok
        {:cancelled, _receipt} -> :cancelled
        {:error, reason, _receipt} -> reason
      end

    key = {__MODULE__, :outcomes, candidate_id}
    :persistent_term.put(key, [outcome | :persistent_term.get(key, [])])
  end

  defp await_cancellation(arguments) do
    receive do
      {:cancel_sandbox_body, reference} when reference == arguments.cancellation_reference ->
        {:cancelled, %{}}
    end
  end

  defp execute(executor, contract_executor, scenario, arguments, mode) do
    scenario = execution_scenario(scenario, mode)
    now = System.monotonic_time(:millisecond)
    duration = max(10, arguments.deadline - now)
    target = %{node: Atom.to_string(node())}
    {:ok, budget} = Budget.new(max_duration_ms: duration, max_events: 100, max_bytes: 65_536)

    {:ok, request} =
      Request.new("scenario.run",
        request_id: "verification-after",
        environment: :test,
        target: target,
        timeout_ms: duration,
        budget: Map.from_struct(budget),
        capability: "verification-scenario-grant",
        params: %{"scenario_id" => scenario.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "verification-scenario-grant",
        audit_id: "verification-scenario-audit",
        scopes: ["scenario.execute"],
        target: target,
        expires_at_monotonic: now + duration
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "verification-body",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "scenario.run" => %{
            available: true,
            provider: "verification-body",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    Executor.run(executor, scenario, [ConfirmationContract],
      request: request,
      context: context,
      contract_executor: contract_executor
    )
  end

  defp execution_scenario(scenario, :scenario_timeout) do
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, timeout_scenario} =
      Scenario.new(contract,
        seed: "verification-timeout",
        reset: scenario.reset,
        steps: [
          %{
            "id" => "timeout",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["verification-timeout"]
          }
        ],
        expected_incident_fingerprints: scenario.expected_incident_fingerprints,
        limits: %{"cleanup_timeout_ms" => 100, "max_duration_ms" => 300}
      )

    timeout_scenario
  end

  defp execution_scenario(scenario, _mode), do: scenario

  defp evaluated_result(%Result{status: :ok} = result, arguments, candidate, scenario, mode) do
    case receipt(arguments, candidate, scenario, result, mode) do
      {:ok, receipt} -> body_result(mode, receipt)
      {:error, _reason} -> {:error, :verification_receipt_failed, %{}}
    end
  end

  defp evaluated_result(_result, _arguments, _candidate, _scenario, _mode),
    do: {:error, :verification_scenario_failed, %{}}

  defp body_result(:error_partial, receipt), do: {:error, :verification_failed, receipt}
  defp body_result(:cancelled, receipt), do: {:cancelled, receipt}
  defp body_result(_mode, receipt), do: {:ok, receipt}

  defp receipt(arguments, candidate, scenario, result, mode) do
    pre = arguments.observed_provenance
    post = post_provenance(pre, candidate, mode)
    code = post["components"]["code"]["fingerprint"]
    sandbox_owner = "sha256:" <> digest(arguments.owner_id)

    owner =
      case mode do
        :invented_owner -> "sha256:" <> String.duplicate("a", 64)
        :receipt_failure -> "invalid-owner-fingerprint"
        _other -> sandbox_owner
      end

    expected = arguments.input["expected_fingerprint"]
    gate_status = if mode == :failed_gate, do: "failed", else: "passed"

    gates =
      for name <- ["resources", "runtime", "static"], into: %{} do
        status = if name == "static", do: gate_status, else: "passed"

        {name,
         %{
           "code_fingerprint" => code,
           "receipt_digest" => digest(owner <> name),
           "status" => status
         }}
      end

    candidate_id =
      if mode == :wrong_binding,
        do: "sha256:" <> String.duplicate("b", 64),
        else: candidate.id

    Receipt.new(
      regression_id: arguments.input["regression_id"],
      candidate_id: candidate_id,
      scenario_id: scenario.id,
      expected_fingerprint: expected,
      observer: arguments.input["observer"],
      owner_fingerprint: owner,
      observation_run_fingerprint: owner,
      pre_provenance: pre,
      post_provenance: post,
      observed_fingerprints: observed(mode, expected),
      evidence: %{
        "armed_before_scenario" => true,
        "complete" => true,
        "dropped" => 0,
        "finalized_after_scenario" => true,
        "gaps" => 0,
        "post_provenance_observed" => true,
        "scenario_status" =>
          if(match?(%Result{status: :ok}, result), do: "completed", else: "failed"),
        "truncated" => false
      },
      oracle: %{
        "identity" => arguments.input["oracle"],
        "receipt_digest" =>
          if(mode == :duplicate_evidence,
            do: String.duplicate("c", 64),
            else: digest(arguments.owner_id <> "oracle")
          ),
        "status" => "passed"
      },
      gates: gates
    )
    |> case do
      {:ok, receipt} -> {:ok, mutate_receipt(receipt, mode)}
      {:error, _error} -> {:error, :invalid_receipt}
    end
  end

  defp mutate_receipt(receipt, :missing_gate),
    do: update_in(receipt["gates"], &Map.delete(&1, "static"))

  defp mutate_receipt(receipt, :unknown_gate),
    do: put_in(receipt, ["gates", "static", "status"], "unknown")

  defp mutate_receipt(receipt, :wrong_gate_name) do
    receipt
    |> update_in(["gates"], &Map.delete(&1, "static"))
    |> put_in(["gates", "lint"], receipt["gates"]["static"])
  end

  defp mutate_receipt(receipt, _mode), do: receipt

  defp post_provenance(pre, candidate, mode) do
    components = pre["components"]
    attrs = fn name -> components[name]["attributes"] end

    drift_modes = %{
      "configuration" => :drift_configuration,
      "dependencies" => :drift_dependencies,
      "runtime" => :drift_runtime,
      "target" => :drift_target
    }

    component = fn name ->
      if mode == drift_modes[name] or (mode == :target_mismatch and name == "configuration"),
        do: %{"changed" => true},
        else: attrs.(name)
    end

    code =
      if mode == :unchanged_code,
        do: {:available, attrs.("code")},
        else: {:available, %{"candidate" => candidate.content_sha256}}

    {:ok, post} =
      Provenance.new(
        code: code,
        configuration: {:available, component.("configuration")},
        dependencies: {:available, component.("dependencies")},
        runtime: {:available, component.("runtime")},
        target: {:available, component.("target")}
      )

    Provenance.to_wire_map(post)
  end

  defp observed(:failing_after, expected), do: [expected]
  defp observed(:changed_failure, _expected), do: [String.duplicate("f", 64)]
  defp observed(_mode, _expected), do: []
  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end

for mode <- [
      :success,
      :failing_after,
      :changed_failure,
      :missing_gate,
      :failed_gate,
      :target_mismatch,
      :leak,
      :invented_owner,
      :unchanged_code,
      :drift_configuration,
      :drift_dependencies,
      :drift_runtime,
      :drift_target,
      :unknown_gate,
      :wrong_binding,
      :error_partial,
      :duplicate_evidence,
      :cancelled,
      :blocking,
      :receipt_failure,
      :scenario_timeout,
      :wrong_gate_name
    ] do
  module =
    Module.concat(Insider.TestSupport, "VerificationBody#{Macro.camelize(to_string(mode))}")

  defmodule module do
    @behaviour Insider.Sentinel.Sandbox.Body
    @mode mode
    @impl true
    def identity, do: %{"id" => "test.verification-body.#{@mode}", "version" => 1}
    @impl true
    def run(arguments), do: Insider.TestSupport.VerificationBody.run(arguments, @mode)
  end
end
