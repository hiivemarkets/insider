defmodule Insider.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Policy.Decision
  alias Insider.Policy.Grant
  alias Insider.Protocol
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @request_id "req-policy-1"

  describe "deny-by-default evaluation" do
    test "allows only baseline discovery without a verified grant" do
      request = request!("runtime.health")
      context = context!()

      assert %Decision{outcome: :allow, reason: :baseline_discovery} =
               Policy.evaluate(request, context)

      assert %Decision{outcome: :deny, reason: :grant_required} =
               Policy.evaluate(request!("runtime.snapshot"), context)
    end

    test "trusts configured environment rather than the request claim" do
      request = request!("runtime.health", environment: :development)
      context = context!(environment: :production)

      assert %Decision{outcome: :deny, reason: :environment_mismatch} =
               Policy.evaluate(request, context)
    end

    test "denies an operation absent from the closed policy table" do
      request = %{request!("runtime.health") | operation: "runtime.evaluate"}

      assert %Decision{outcome: :deny, reason: :unsupported_operation} =
               Policy.evaluate(request, context!())
    end

    test "fails closed without trusted runtime context" do
      assert %Decision{outcome: :deny, reason: :missing_runtime_context} =
               Policy.evaluate(request!("runtime.health"), nil)

      forged = %Context{
        environment: :development,
        actor: "agent",
        deployment_limits: nil
      }

      assert %Decision{outcome: :deny, reason: :invalid_runtime_context} =
               Policy.evaluate(request!("runtime.health"), forged)
    end
  end

  describe "verified grants and protected operations" do
    test "an unverified capability reference grants no authority" do
      request = request!("runtime.snapshot", capability: "secret-capability-reference")

      assert %Decision{outcome: :deny, reason: :unknown_grant} =
               Policy.evaluate(request, context!())
    end

    test "requires a live grant scoped to the operation and target" do
      request = request!("runtime.snapshot", capability: "cap-ref")

      wrong_scope = grant!(scopes: ["runtime.trace"])
      wrong_target = grant!(target: %{node: "another@node"})
      expired = grant!(expires_at_monotonic: System.monotonic_time(:millisecond) - 1)

      assert Policy.evaluate(request, context!(grants: [wrong_scope])).reason == :scope_mismatch
      assert Policy.evaluate(request, context!(grants: [wrong_target])).reason == :target_mismatch
      assert Policy.evaluate(request, context!(grants: [expired])).reason == :grant_expired

      grant = grant!(scopes: ["runtime.observe"])

      assert %Decision{outcome: :allow, grant_audit_id: "grant-audit-1"} =
               Policy.evaluate(request, context!(grants: [grant]))
    end

    test "mutation requires both a scoped grant and a disposable target" do
      request = request!("scenario.run", capability: "cap-ref")
      grant = grant!(scopes: ["scenario.execute"])

      assert Policy.evaluate(request, context!(grants: [grant])).reason ==
               :disposable_target_required

      assert %Decision{outcome: :allow} =
               Policy.evaluate(request, context!(grants: [grant], target_class: :disposable))
    end

    test "production hard prohibitions override every grant" do
      for operation <- ["scenario.run", "verification.run"] do
        request = request!(operation, environment: :production, capability: "admin-ref")

        scope =
          if operation == "scenario.run", do: "scenario.execute", else: "verification.execute"

        grant = grant!(reference: "admin-ref", scopes: [scope])

        decision =
          Policy.evaluate(
            request,
            context!(environment: :production, target_class: :disposable, grants: [grant])
          )

        assert decision.outcome == :deny
        assert decision.reason == :production_prohibited
      end
    end

    test "trace requires a constrained selector and never permits broad targets" do
      grant = grant!(scopes: ["runtime.trace"])

      for selector <- ["all", "existing", %{"module" => "_"}, nil] do
        request =
          request!("trace.start",
            capability: "cap-ref",
            params: %{"selector" => selector}
          )

        assert Policy.evaluate(request, context!(grants: [grant])).reason ==
                 :unsafe_trace_selector
      end

      request =
        request!("trace.start",
          capability: "cap-ref",
          idempotency_key: "trace-session-1",
          params: %{
            "selector" => %{"module" => "MyApp.Worker", "function" => "run", "arity" => 1}
          }
        )

      assert %Decision{outcome: :allow} = Policy.evaluate(request, context!(grants: [grant]))
    end

    test "an expired matching grant may stop trace work but cannot start more" do
      grant =
        grant!(
          scopes: ["runtime.trace"],
          expires_at_monotonic: System.monotonic_time(:millisecond) - 1
        )

      start_request =
        request!("trace.start",
          capability: "cap-ref",
          idempotency_key: "trace-session-1",
          params: %{
            "selector" => %{"module" => "MyApp.Worker", "function" => "run", "arity" => 1}
          }
        )

      stop_request =
        request!("trace.stop", capability: "cap-ref", idempotency_key: "trace-session-1")

      assert Policy.evaluate(start_request, context!(grants: [grant])).reason == :grant_expired
      assert %Decision{outcome: :allow} = Policy.evaluate(stop_request, context!(grants: [grant]))
    end

    test "trace denies protected runtime and Insider modules" do
      grant = grant!(scopes: ["runtime.trace"])

      for module <- ["erlang", "erts", "init", "Elixir.Insider.Policy"] do
        request =
          request!("trace.start",
            capability: "cap-ref",
            idempotency_key: "trace-session-1",
            params: %{
              "selector" => %{"module" => module, "function" => "run", "arity" => 1}
            }
          )

        assert Policy.evaluate(request, context!(grants: [grant])).reason ==
                 :unsafe_trace_selector
      end
    end
  end

  describe "limits, discovery, authorization, and audit" do
    test "environment matrix covers every declared operation" do
      for environment <- [:development, :test, :ci, :staging, :production],
          operation <- Protocol.operations() do
        options = matrix_request_options(operation, environment)
        request = request!(operation, options)
        grants = matrix_grants(operation)

        decision =
          Policy.evaluate(
            request,
            context!(
              environment: environment,
              target_class: :disposable,
              grants: grants
            )
          )

        cond do
          operation in ["runtime.capabilities", "runtime.health", "runtime.fingerprint"] ->
            assert decision.outcome == :allow

          environment in [:development, :test, :ci] ->
            assert decision.outcome == :allow

          environment == :production and operation in ["scenario.run", "verification.run"] ->
            assert decision.outcome == :deny
            assert decision.reason == :production_prohibited

          true ->
            assert decision.outcome == :deny
            assert decision.reason == :not_production_ready
        end
      end
    end

    test "clamps effective bounds to trusted deployment limits" do
      request =
        request!("runtime.snapshot",
          capability: "cap-ref",
          budget: [
            max_duration_ms: 20_000,
            max_events: 20_000,
            max_bytes: 2_000_000,
            max_targets: 20
          ]
        )

      grant = grant!(scopes: ["runtime.observe"])

      context =
        context!(
          grants: [grant],
          deployment_limits: %{
            max_duration_ms: 2_000,
            max_events: 200,
            max_bytes: 200_000,
            max_targets: 2
          }
        )

      assert %Decision{outcome: :allow, effective_limits: effective} =
               Policy.evaluate(request, context)

      assert effective == %{
               max_duration_ms: 2_000,
               max_events: 200,
               max_bytes: 200_000,
               max_targets: 1
             }
    end

    test "denies an expired request before dispatch" do
      request = %{
        request!("runtime.health")
        | deadline_monotonic: System.monotonic_time(:millisecond) - 1
      }

      assert %Decision{outcome: :deny, reason: :deadline_expired} =
               Policy.evaluate(request, context!())
    end

    test "capability discovery separates runtime availability from policy" do
      context =
        context!(
          features: %{
            "runtime.health" => %{available: true, provider: "erts", isolation: :read_only},
            "trace.start" => %{available: true, provider: "otp_trace", isolation: :session_local}
          }
        )

      capabilities = Policy.capabilities(context)
      health = Enum.find(capabilities, &(&1.operation == "runtime.health"))
      trace = Enum.find(capabilities, &(&1.operation == "trace.start"))
      snapshot = Enum.find(capabilities, &(&1.operation == "runtime.snapshot"))

      assert health.runtime_available
      assert health.policy_disposition == :allow
      assert trace.runtime_available
      assert trace.policy_disposition == :grant_required
      refute snapshot.runtime_available
      assert snapshot.policy_disposition == :grant_required

      assert [] ==
               Policy.capabilities(%Context{
                 environment: :development,
                 actor: "agent",
                 deployment_limits: nil
               })
    end

    test "authorize returns a typed policy error without leaking the capability reference" do
      secret = "secret-capability-reference"
      request = request!("runtime.snapshot", capability: secret)

      assert {:error, %Error{code: :policy_denied} = error} =
               Policy.authorize(request, context!())

      refute inspect(error) =~ secret
    end

    test "audit evidence is bounded and excludes values and capability references" do
      secret = "secret-capability-reference"
      request = request!("runtime.snapshot", capability: secret)
      decision = Policy.evaluate(request, context!())
      audit = Policy.audit(decision)

      refute inspect(audit) =~ secret
      assert audit.decision == :deny
      assert audit.effects == %{count: 0, statuses: %{}}

      baseline = request!("runtime.health")
      allowed = Policy.evaluate(baseline, context!())
      effect = Effect.new(:probe_started, "probe-1", status: :observed)

      result =
        Protocol.success(baseline, %{secret: secret},
          effects: [effect],
          effective_limits: allowed.effective_limits,
          policy_fingerprint: allowed.policy_fingerprint
        )

      completed = Policy.audit(allowed, result)

      refute inspect(completed) =~ secret
      assert completed.result_status == :ok
      assert completed.effects == %{count: 1, statuses: %{observed: 1}}
      assert completed.cleanup == %{status: :not_required}
      assert Value.bounded_data?(completed, 16_384)
    end

    test "audit rejects a result from another request or operation" do
      request = request!("runtime.health", request_id: "request-a")
      decision = Policy.evaluate(request, context!())
      other_request = request!("runtime.fingerprint", request_id: "request-b")
      other_result = Protocol.success(other_request, :ok)

      assert_raise ArgumentError, ~r/do not correlate/, fn ->
        Policy.audit(decision, other_result)
      end

      denied = Policy.evaluate(request!("runtime.snapshot"), context!())

      assert_raise ArgumentError, ~r/do not correlate/, fn ->
        Policy.audit(denied, Protocol.success(request!("runtime.snapshot"), :should_not_run))
      end
    end

    test "audit fingerprints caller-controlled correlation identifiers" do
      secret = "do-not-retain-correlation-secret"

      request =
        request!("runtime.health",
          request_id: secret,
          target: %{node: secret}
        )

      audit = request |> Policy.evaluate(context!()) |> Policy.audit()

      refute inspect(audit) =~ secret
      assert byte_size(audit.request_id_fingerprint) == 64
      assert byte_size(audit.target_fingerprint) == 64
    end

    test "trace requires a session-local provider and an exact selector map" do
      request =
        request!("trace.start",
          capability: "cap-ref",
          idempotency_key: "trace-session-1",
          params: %{
            "selector" => %{
              "module" => "MyApp.Worker",
              "function" => "run",
              "arity" => 1,
              "processes" => "all"
            }
          }
        )

      grant = grant!(scopes: ["runtime.trace"])
      assert Policy.evaluate(request, context!(grants: [grant])).reason == :unsafe_trace_selector

      exact_request =
        put_in(request.params, %{
          "selector" => %{"module" => "MyApp.Worker", "function" => "run", "arity" => 1}
        })

      features =
        Map.put(all_features(), "trace.start", %{
          available: true,
          provider: "legacy_trace",
          isolation: :node_global
        })

      assert Policy.evaluate(exact_request, context!(grants: [grant], features: features)).reason ==
               :unsafe_trace_provider
    end

    test "grant lifetime caps work and cleanup authority has an ownership-bound grace period" do
      now = System.monotonic_time(:millisecond)

      grant =
        grant!(
          scopes: ["runtime.trace"],
          expires_at_monotonic: now + 1_000
        )

      request =
        request!("trace.start",
          capability: "cap-ref",
          idempotency_key: "trace-session-1",
          timeout_ms: 5_000,
          params: %{
            "selector" => %{"module" => "MyApp.Worker", "function" => "run", "arity" => 1}
          }
        )

      decision = Policy.evaluate(request, context!(grants: [grant]))
      assert decision.outcome == :allow
      assert decision.effective_limits.max_duration_ms <= 1_000
      assert decision.authorization_expires_at_monotonic == grant.expires_at_monotonic
      assert decision.dispatch_deadline_monotonic <= decision.request_deadline_monotonic
      assert Policy.dispatchable?(decision)

      expired =
        grant!(
          scopes: ["runtime.trace"],
          expires_at_monotonic: now - 60_001
        )

      stop = request!("trace.stop", capability: "cap-ref", idempotency_key: "trace-session-1")
      wrong_owner = %{stop | idempotency_key: "someone-else"}

      assert Policy.evaluate(stop, context!(grants: [expired])).reason == :grant_expired
      assert Policy.evaluate(wrong_owner, context!(grants: [grant])).reason == :owner_mismatch

      ownerless = grant!(scopes: ["runtime.trace"], owner_id: nil)
      assert Policy.evaluate(request, context!(grants: [ownerless])).reason == :owner_mismatch
    end

    test "reserves dispatch time and exposes a recheckable deadline" do
      request = %{
        request!("runtime.health")
        | deadline_monotonic: System.monotonic_time(:millisecond) + 1
      }

      decision = Policy.evaluate(request, context!())
      assert decision.outcome == :deny
      assert decision.reason == :deadline_expired
      refute Policy.dispatchable?(decision)

      allowed = Policy.evaluate(request!("runtime.health"), context!())

      refute Policy.dispatchable?(%{
               allowed
               | dispatch_deadline_monotonic: System.monotonic_time(:millisecond) - 1
             })
    end

    test "rejects ambiguous grants and policy ceilings above library limits" do
      grant = grant!(scopes: ["runtime.observe"])

      assert {:error, %Error{code: :policy_denied}} =
               Context.new(
                 environment: :development,
                 actor: "agent",
                 grants: [grant, grant]
               )

      assert {:error, %Error{code: :invalid_budget}} =
               Context.new(
                 environment: :development,
                 actor: "agent",
                 deployment_limits: %{max_events: Budget.maximum(:max_events) + 1}
               )
    end

    test "bounds scope and grant registry cardinality" do
      assert {:error, %Error{code: :policy_denied}} =
               grant!(scopes: ["runtime.observe"])
               |> Map.from_struct()
               |> Map.put(:scopes, List.duplicate("runtime.observe", 9))
               |> Enum.to_list()
               |> Grant.new()

      grants =
        for index <- 1..65 do
          grant = grant!(scopes: ["runtime.observe"])
          %{grant | reference: "cap-#{index}", audit_id: "audit-#{index}"}
        end

      assert {:error, %Error{code: :policy_denied}} =
               Context.new(environment: :development, actor: "agent", grants: grants)
    end

    test "rejects malformed trusted context and grant fields as typed errors" do
      for options <- [
            [:not_a_keyword],
            [environment: :development, actor: "agent", surprise: true],
            [environment: :unknown, actor: "agent"],
            [environment: :development, actor: ""],
            [environment: :development, actor: "agent", target_class: :shared],
            [environment: :development, actor: "agent", grants: :all],
            [environment: :development, actor: "agent", features: []],
            [
              environment: :development,
              actor: "agent",
              features: %{
                "trace.start" => %{available: true, provider: "test", isolation: :global}
              }
            ]
          ] do
        assert {:error, %Error{}} = Context.new(options)
      end

      for options <- [
            [:not_a_keyword],
            [surprise: true],
            [],
            [reference: "ref", audit_id: "audit", scopes: ["unknown"]],
            [
              reference: "ref",
              audit_id: "audit",
              scopes: ["runtime.observe"],
              target: %{node: ""},
              expires_at_monotonic: 1
            ]
          ] do
        assert {:error, %Error{}} = Grant.new(options)
      end
    end

    test "grant validation rejects non-grants and malformed trusted targets" do
      grant = grant!([])

      refute Grant.valid?(:not_a_grant)
      refute Grant.valid?(%{grant | target: "node-a"})
    end

    property "context and grant decoders never raise on arbitrary terms" do
      check all(value <- term()) do
        assert_typed_constructor_result(Context.new(value))
        assert_typed_constructor_result(Grant.new(value))
      end
    end
  end

  defp request!(operation, options \\ []) do
    {:ok, request} =
      Protocol.request(operation, Keyword.put_new(options, :request_id, @request_id))

    request
  end

  defp context!(options \\ []) do
    {:ok, context} =
      Context.new(
        Keyword.merge(
          [environment: :development, actor: "test-agent", features: all_features()],
          options
        )
      )

    context
  end

  defp grant!(options) do
    defaults = [
      reference: "cap-ref",
      audit_id: "grant-audit-1",
      scopes: ["runtime.observe"],
      target: %{node: Atom.to_string(node())},
      expires_at_monotonic: System.monotonic_time(:millisecond) + 60_000,
      owner_id: "trace-session-1"
    ]

    {:ok, grant} = Grant.new(Keyword.merge(defaults, options))
    grant
  end

  defp all_features do
    Map.new(Protocol.operations(), fn operation ->
      isolation =
        if operation in ["trace.start", "trace.stop"], do: :session_local, else: :read_only

      {operation, %{available: true, provider: "test", isolation: isolation}}
    end)
  end

  defp matrix_request_options(operation, environment) do
    base = [environment: environment]

    if operation in ["runtime.capabilities", "runtime.health", "runtime.fingerprint"] do
      base
    else
      base
      |> Keyword.put(:capability, "cap-ref")
      |> maybe_put_trace_fields(operation)
    end
  end

  defp maybe_put_trace_fields(options, "trace.start") do
    options
    |> Keyword.put(:idempotency_key, "trace-session-1")
    |> Keyword.put(:params, %{
      "selector" => %{"module" => "MyApp.Worker", "function" => "run", "arity" => 1}
    })
  end

  defp maybe_put_trace_fields(options, "trace.stop"),
    do: Keyword.put(options, :idempotency_key, "trace-session-1")

  defp maybe_put_trace_fields(options, _operation), do: options

  defp matrix_grants(operation) do
    case operation_scope(operation) do
      nil -> []
      scope -> [grant!(scopes: [scope])]
    end
  end

  defp operation_scope(operation)
       when operation in [
              "runtime.snapshot",
              "runtime.diff",
              "process.describe",
              "process.await",
              "supervision.tree",
              "mailbox.summarize"
            ],
       do: "runtime.observe"

  defp operation_scope("events.subscribe"), do: "events.subscribe"
  defp operation_scope("incident.capture"), do: "incident.capture"
  defp operation_scope("incident.export"), do: "incident.export"

  defp operation_scope(operation)
       when operation in ["contract.list", "contract.observe", "contract.check"],
       do: "contract.observe"

  defp operation_scope(operation) when operation in ["trace.start", "trace.stop"],
    do: "runtime.trace"

  defp operation_scope("scenario.run"), do: "scenario.execute"
  defp operation_scope("verification.run"), do: "verification.execute"
  defp operation_scope(_operation), do: nil

  defp assert_typed_constructor_result({:ok, %Context{}}), do: :ok
  defp assert_typed_constructor_result({:ok, %Grant{}}), do: :ok

  defp assert_typed_constructor_result({:error, %Error{details: details}}) do
    assert Value.bounded_data?(details, 4_096)
  end
end
