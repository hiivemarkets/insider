defmodule Insider.Policy do
  @moduledoc """
  Pure capability discovery and deny-by-default runtime authorization.

  Request identity and environment fields are claims. Only `Context` contains
  trusted runtime facts and pre-verified grants.
  """

  alias Insider.Policy.Context
  alias Insider.Policy.Decision
  alias Insider.Policy.Grant
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Protocol.Value

  @policy_fingerprint "insider.policy/v1"
  @production_prohibited ["scenario.run", "verification.run"]
  @protected_trace_modules ["erlang", "erts", "init"]
  @trace_cleanup_grace_ms 60_000
  @dispatch_reserve_ms 5

  @rules %{
    "runtime.capabilities" => %{class: :baseline, scope: nil},
    "runtime.health" => %{class: :baseline, scope: nil},
    "runtime.fingerprint" => %{class: :baseline, scope: nil},
    "runtime.snapshot" => %{class: :observation, scope: "runtime.observe"},
    "runtime.diff" => %{class: :observation, scope: "runtime.observe"},
    "process.describe" => %{class: :observation, scope: "runtime.observe"},
    "process.await" => %{class: :observation, scope: "runtime.observe"},
    "supervision.tree" => %{class: :observation, scope: "runtime.observe"},
    "mailbox.summarize" => %{class: :observation, scope: "runtime.observe"},
    "events.subscribe" => %{class: :capture, scope: "events.subscribe"},
    "incident.capture" => %{class: :capture, scope: "incident.capture"},
    "incident.export" => %{class: :capture, scope: "incident.export"},
    "contract.list" => %{class: :semantic, scope: "contract.observe"},
    "contract.observe" => %{class: :semantic, scope: "contract.observe"},
    "contract.check" => %{class: :semantic, scope: "contract.observe"},
    "trace.start" => %{class: :trace, scope: "runtime.trace"},
    "trace.stop" => %{class: :trace, scope: "runtime.trace"},
    "scenario.run" => %{class: :mutation, scope: "scenario.execute"},
    "verification.run" => %{class: :mutation, scope: "verification.execute"}
  }

  @spec evaluate(Request.t(), Context.t() | nil) :: Decision.t()
  def evaluate(%Request{} = request, %Context{} = context) do
    if Context.valid?(context) do
      evaluate_trusted(request, context)
    else
      denied_without_context(request, :invalid_runtime_context)
    end
  end

  def evaluate(%Request{} = request, _context),
    do: denied_without_context(request, :missing_runtime_context)

  defp evaluate_trusted(request, context) do
    rule = Map.get(@rules, request.operation)
    feature = Map.get(context.features, request.operation, unavailable_feature())
    now = System.monotonic_time(:millisecond)

    {outcome, reason, grant} = disposition(request, context, rule, feature, now)

    base = decision(request, context, rule, feature, grant, now)

    base
    |> then(&%{&1 | outcome: outcome, reason: reason, grant_audit_id: grant && grant.audit_id})
    |> finalize_decision()
  end

  defp denied_without_context(request, reason) do
    fallback_context = %Context{
      environment: request.environment,
      actor: "unverified",
      deployment_limits: request.budget
    }

    decision =
      decision(
        request,
        fallback_context,
        Map.get(@rules, request.operation),
        unavailable_feature(),
        nil,
        System.monotonic_time(:millisecond)
      )

    %{decision | outcome: :deny, reason: reason}
  end

  @spec authorize(Request.t(), Context.t() | nil) :: {:ok, Decision.t()} | {:error, Error.t()}
  def authorize(%Request{} = request, context) do
    case evaluate(request, context) do
      %Decision{outcome: :allow} = decision ->
        {:ok, decision}

      %Decision{} = decision ->
        code =
          case decision.reason do
            :runtime_unavailable -> :unsupported_capability
            :unsupported_operation -> :unsupported_operation
            _reason -> :policy_denied
          end

        {:error,
         Error.new(code, "runtime policy denied the operation", %{
           operation: Value.summary(decision.operation),
           policy_fingerprint: decision.policy_fingerprint,
           reason: decision.reason
         })}
    end
  end

  @spec capabilities(Context.t()) :: [map()]
  def capabilities(%Context{} = context) do
    if Context.valid?(context) do
      @rules
      |> Enum.sort_by(fn {operation, _rule} -> operation end)
      |> Enum.map(fn {operation, rule} -> capability(operation, rule, context) end)
    else
      []
    end
  end

  @doc "Returns whether an allowed decision is still valid for immediate dispatch."
  @spec dispatchable?(Decision.t()) :: boolean()
  def dispatchable?(%Decision{outcome: :allow, dispatch_deadline_monotonic: deadline})
      when is_integer(deadline),
      do: deadline > System.monotonic_time(:millisecond)

  def dispatchable?(_decision), do: false

  @spec audit(Decision.t(), Result.t() | nil) :: map()
  def audit(%Decision{} = decision, result \\ nil) do
    validate_result_correlation!(decision, result)

    evidence = %{
      schema: "insider.policy-decision/v1",
      decision_id: fingerprint(decision.request_id <> ":policy"),
      request_id_fingerprint: fingerprint(decision.request_id),
      operation: audited_operation(decision.operation),
      decision: decision.outcome,
      reason: decision.reason,
      configured_environment: decision.configured_environment,
      claimed_environment: decision.claimed_environment,
      actor: decision.actor,
      target_fingerprint: fingerprint(decision.target),
      required_scope: decision.required_scope,
      grant_audit_id: decision.grant_audit_id,
      authorization_expires_at_monotonic: decision.authorization_expires_at_monotonic,
      request_deadline_monotonic: decision.request_deadline_monotonic,
      dispatch_deadline_monotonic: decision.dispatch_deadline_monotonic,
      requested_limits: decision.requested_limits,
      effective_limits: decision.effective_limits,
      policy_fingerprint: decision.policy_fingerprint,
      runtime_available: decision.runtime_available,
      runtime_provider: decision.runtime_provider,
      runtime_isolation: decision.runtime_isolation,
      verified_grant_present: not is_nil(decision.grant_audit_id),
      result_status: result_status(result),
      effects: effect_summary(result),
      cleanup: cleanup_summary(result),
      truncated: truncated_summary(result),
      dropped_field_count: dropped_field_count(result),
      uncertainty_count: uncertainty_count(result)
    }

    if Value.bounded_data?(evidence, 16_384),
      do: evidence,
      else: raise(ArgumentError, "policy audit evidence exceeded its bound")
  end

  defp disposition(_request, _context, nil, _feature, _now),
    do: {:deny, :unsupported_operation, nil}

  defp disposition(request, context, _rule, _feature, _now)
       when request.environment != context.environment,
       do: {:deny, :environment_mismatch, nil}

  defp disposition(request, context, rule, feature, now) do
    if request.deadline_monotonic <= now do
      {:deny, :deadline_expired, nil}
    else
      disposition_live(request, context, rule, feature, now)
    end
  end

  defp disposition_live(request, context, rule, feature, now) do
    cond do
      not feature.available ->
        {:deny, :runtime_unavailable, nil}

      context.environment == :production and request.operation in @production_prohibited ->
        {:deny, :production_prohibited, nil}

      context.environment in [:staging, :production] and rule.class != :baseline ->
        {:deny, :not_production_ready, nil}

      rule.class == :trace and feature.isolation != :session_local ->
        {:deny, :unsafe_trace_provider, nil}

      rule.class == :trace and not safe_trace_selector?(request) ->
        {:deny, :unsafe_trace_selector, nil}

      rule.class == :mutation and context.target_class != :disposable ->
        {:deny, :disposable_target_required, nil}

      rule.class == :baseline ->
        {:allow, :baseline_discovery, nil}

      true ->
        grant_disposition(request, context, rule, now)
    end
  end

  defp grant_disposition(%{capability: nil}, _context, _rule, _now),
    do: {:deny, :grant_required, nil}

  defp grant_disposition(request, context, rule, now) do
    case Enum.find(context.grants, &(&1.reference == request.capability)) do
      nil ->
        {:deny, :unknown_grant, nil}

      %Grant{} = grant ->
        cond do
          grant.target != request.target ->
            {:deny, :target_mismatch, grant}

          rule.scope not in grant.scopes ->
            {:deny, :scope_mismatch, grant}

          rule.class == :trace and
              not (is_binary(request.idempotency_key) and
                       grant.owner_id == request.idempotency_key) ->
            {:deny, :owner_mismatch, grant}

          grant_expired?(request, grant, now) ->
            {:deny, :grant_expired, grant}

          true ->
            reason =
              if grant.expires_at_monotonic <= now, do: :cleanup_grant, else: :verified_grant

            {:allow, reason, grant}
        end
    end
  end

  defp decision(request, context, rule, feature, grant, now) do
    authorization_expiry = authorization_expiry(request, grant)
    dispatch_deadline = earliest_deadline(request.deadline_monotonic, authorization_expiry)

    %Decision{
      outcome: :deny,
      reason: :unresolved,
      request_id: request.request_id,
      operation: request.operation,
      configured_environment: context.environment,
      claimed_environment: request.environment,
      actor: context.actor,
      target: request.target,
      required_scope: if(rule, do: rule.scope),
      requested_limits: Map.from_struct(request.budget),
      effective_limits: effective_limits(request, context, dispatch_deadline, now),
      authorization_expires_at_monotonic: authorization_expiry,
      request_deadline_monotonic: request.deadline_monotonic,
      dispatch_deadline_monotonic: dispatch_deadline,
      policy_fingerprint: @policy_fingerprint,
      runtime_available: feature.available,
      runtime_provider: feature.provider,
      runtime_isolation: feature.isolation
    }
  end

  defp effective_limits(request, context, dispatch_deadline, now) do
    requested = Map.from_struct(request.budget)
    deployed = Map.from_struct(context.deployment_limits)

    limits =
      requested
      |> Map.new(fn {field, value} -> {field, min(value, Map.fetch!(deployed, field))} end)
      |> Map.put(:max_targets, 1)

    Map.update!(limits, :max_duration_ms, &min(&1, max(1, dispatch_deadline - now)))
  end

  defp capability(operation, rule, context) do
    feature = Map.get(context.features, operation, unavailable_feature())

    %{
      operation: operation,
      class: rule.class,
      required_scope: rule.scope,
      runtime_available: feature.available,
      runtime_provider: feature.provider,
      runtime_isolation: feature.isolation,
      policy_disposition: discovery_disposition(operation, rule, context, feature),
      effective_maximums:
        context.deployment_limits |> Map.from_struct() |> Map.put(:max_targets, 1),
      protected_constraints: protected_constraints(rule.class)
    }
  end

  defp discovery_disposition(operation, rule, context, feature) do
    cond do
      rule.class == :trace and feature.available and feature.isolation != :session_local ->
        :unsafe_trace_provider

      context.environment == :production and operation in @production_prohibited ->
        :production_prohibited

      context.environment in [:staging, :production] and rule.class != :baseline ->
        :not_production_ready

      rule.class == :baseline ->
        :allow

      true ->
        :grant_required
    end
  end

  defp safe_trace_selector?(%{operation: "trace.stop"}), do: true

  defp safe_trace_selector?(%{params: %{"selector" => selector}}),
    do: safe_selector?(selector)

  defp safe_trace_selector?(%{params: %{selector: selector}}), do: safe_selector?(selector)
  defp safe_trace_selector?(_request), do: false

  defp safe_selector?(%{"module" => module, "function" => function, "arity" => arity} = selector)
       when map_size(selector) == 3,
       do: constrained_mfa?(module, function, arity)

  defp safe_selector?(%{module: module, function: function, arity: arity} = selector)
       when map_size(selector) == 3,
       do: constrained_mfa?(module, function, arity)

  defp safe_selector?(_selector), do: false

  defp constrained_mfa?(module, function, arity) do
    Enum.all?([module, function], &(is_binary(&1) and byte_size(&1) in 1..256 and &1 != "_")) and
      is_integer(arity) and arity in 0..255 and not protected_module?(module)
  end

  defp protected_module?("Elixir.Insider" <> _suffix), do: true
  defp protected_module?(module), do: module in @protected_trace_modules

  defp protected_constraints(:trace), do: ["exact_mfa", "no_wildcards", "no_global_targets"]
  defp protected_constraints(:mutation), do: ["disposable_target"]
  defp protected_constraints(_class), do: []

  defp unavailable_feature,
    do: %{available: false, provider: "unavailable", isolation: :unavailable}

  defp grant_expired?(%{operation: "trace.stop"}, grant, now),
    do: grant.expires_at_monotonic + @trace_cleanup_grace_ms <= now

  defp grant_expired?(_request, grant, now), do: grant.expires_at_monotonic <= now

  defp authorization_expiry(%{operation: "trace.stop"}, %Grant{} = grant),
    do: grant.expires_at_monotonic + @trace_cleanup_grace_ms

  defp authorization_expiry(_request, %Grant{} = grant), do: grant.expires_at_monotonic
  defp authorization_expiry(_request, nil), do: nil

  defp earliest_deadline(request_deadline, nil), do: request_deadline

  defp earliest_deadline(request_deadline, authorization_expiry),
    do: min(request_deadline, authorization_expiry)

  defp finalize_decision(%Decision{outcome: :allow} = decision) do
    if decision.dispatch_deadline_monotonic - System.monotonic_time(:millisecond) <=
         @dispatch_reserve_ms do
      %{decision | outcome: :deny, reason: :deadline_expired}
    else
      decision
    end
  end

  defp finalize_decision(decision), do: decision

  defp validate_result_correlation!(_decision, nil), do: :ok

  defp validate_result_correlation!(decision, %Result{} = result) do
    valid =
      decision.outcome == :allow and
        result.request_id == decision.request_id and
        result.operation == decision.operation and
        result.target == decision.target and
        result.requested_limits == decision.requested_limits and
        result.effective_limits == decision.effective_limits and
        result.policy_fingerprint == decision.policy_fingerprint

    unless valid do
      raise ArgumentError, "policy decision and result do not correlate"
    end
  end

  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp audited_operation(operation) when is_map_key(@rules, operation), do: operation
  defp audited_operation(operation), do: Value.summary(operation)

  defp result_status(%Result{status: status}), do: status
  defp result_status(nil), do: nil

  defp effect_summary(%Result{effects: effects}) do
    statuses = Enum.frequencies_by(effects, & &1.status)
    %{count: length(effects), statuses: statuses}
  end

  defp effect_summary(nil), do: %{count: 0, statuses: %{}}

  defp cleanup_summary(%Result{cleanup: %{status: status}}), do: %{status: status}
  defp cleanup_summary(nil), do: %{status: :not_required}

  defp truncated_summary(%Result{truncated: nil}), do: nil
  defp truncated_summary(%Result{truncated: truncated}), do: truncated
  defp truncated_summary(nil), do: nil

  defp dropped_field_count(%Result{dropped: dropped}), do: map_size(dropped)
  defp dropped_field_count(nil), do: 0

  defp uncertainty_count(%Result{uncertainty: uncertainty}), do: length(uncertainty)
  defp uncertainty_count(nil), do: 0
end
