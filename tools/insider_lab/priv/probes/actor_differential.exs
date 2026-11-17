defmodule InsiderLab.ActorDifferentialOracle do
  @moduledoc false

  # A multi-actor differential access-control oracle, loaded into a host's test
  # VM by an agent-written ExUnit probe with `Code.require_file/1`. `run/1`
  # performs one host operation once per declared actor, each time against a
  # freshly built fixture, and compares every outcome with the access rule the
  # caller declares. Controls run first: an entitled control must be granted
  # and must produce the declared effect, and a refused control must be refused
  # without changing state. An unhealthy control makes the whole call an
  # infrastructure failure, and no other actor is attempted.
  #
  # The fixture, the actor setup, the request, the grant check, and the state
  # projection are host adapters supplied by the caller. The report holds no
  # response or state value: only field paths and their kinds, GraphQL type
  # names, error codes, and equality of keyed fingerprints within one call.

  @schema "insider.actor-differential-oracle/v1"
  @prefix "INSIDER_ACTOR_DIFFERENTIAL_ORACLE="
  @maximum_actors 16
  @maximum_operation_bytes 255
  @maximum_context_bytes 1_024
  @maximum_state_keys 16
  @maximum_shape_paths 64
  @maximum_shape_depth 8
  @maximum_shape_nodes 4_096
  @maximum_path_bytes 255
  @maximum_type_names 16
  @maximum_error_codes 16
  @maximum_fingerprint_bytes 1_048_576
  @maximum_fingerprint_terms 65_536
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
  @actor_name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @fields [:operation, :context, :fixture, :actors, :request, :allowed?, :state, :effect]
  @required_fields [:operation, :fixture, :actors, :request, :allowed?]
  @actor_fields [:name, :access, :control, :as]

  @doc """
  Runs the declared differential, prints one `#{@prefix}` JSON line, and
  returns the same report as a string-keyed map with `nil` for JSON null.
  """
  @spec run(term()) :: %{String.t() => term()}
  def run(declaration) do
    report =
      case validate(declaration) do
        {:ok, plan} -> execute(plan)
        {:error, reason} -> invalid(reason, declaration)
      end

    emit(report)
    report
  end

  ## Declaration

  defp validate(declaration) do
    with {:ok, fields} <- fields(declaration),
         :ok <- known_fields(fields),
         {:ok, operation} <- operation(fields),
         {:ok, context} <- context(Map.get(fields, :context)),
         :ok <- function(fields[:fixture], [0], "invalid_fixture"),
         :ok <- function(fields[:request], [2], "invalid_request"),
         :ok <- function(fields[:allowed?], [1, 2], "invalid_allowed_check"),
         :ok <- optional_function(Map.get(fields, :state), [1], "invalid_state"),
         {:ok, effect} <- effect(Map.get(fields, :effect, []), Map.get(fields, :state)),
         {:ok, actors} <- actors(fields[:actors]) do
      {:ok,
       %{
         operation: operation,
         context: context,
         fixture: fields.fixture,
         request: fields.request,
         allowed?: fields.allowed?,
         state: Map.get(fields, :state),
         effect: effect,
         actors: actors
       }}
    end
  end

  defp fields(declaration) when is_list(declaration) do
    if Keyword.keyword?(declaration) and unique_keys?(declaration),
      do: {:ok, Map.new(declaration)},
      else: {:error, "invalid_declaration"}
  end

  defp fields(declaration) when is_map(declaration) and not is_struct(declaration) do
    if Enum.all?(Map.keys(declaration), &is_atom/1),
      do: {:ok, declaration},
      else: {:error, "invalid_declaration"}
  end

  defp fields(_declaration), do: {:error, "invalid_declaration"}

  defp unique_keys?(keyword),
    do: length(Keyword.keys(keyword)) == length(Enum.uniq(Keyword.keys(keyword)))

  defp known_fields(fields) do
    cond do
      Enum.any?(Map.keys(fields), &(&1 not in @fields)) -> {:error, "unknown_field"}
      Enum.any?(@required_fields, &(not Map.has_key?(fields, &1))) -> {:error, "missing_field"}
      true -> :ok
    end
  end

  defp operation(%{operation: operation}) do
    if label?(operation, @maximum_operation_bytes),
      do: {:ok, operation},
      else: {:error, "invalid_operation"}
  end

  defp context(nil), do: {:ok, nil}

  defp context(context) do
    if label?(context, @maximum_context_bytes),
      do: {:ok, context},
      else: {:error, "invalid_context"}
  end

  defp label?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      String.printable?(value) and
      not Enum.any?(String.to_charlist(value), &(&1 < 0x20 or &1 == 0x7F))
  end

  defp function(value, arities, reason) do
    if Enum.any?(arities, &is_function(value, &1)), do: :ok, else: {:error, reason}
  end

  defp optional_function(nil, _arities, _reason), do: :ok
  defp optional_function(value, arities, reason), do: function(value, arities, reason)

  defp effect([], _state), do: {:ok, []}

  defp effect(keys, state) when is_list(keys) and is_function(state, 1) do
    with true <- proper_list_within?(keys, @maximum_state_keys),
         names = Enum.map(keys, &key_name/1),
         true <- Enum.all?(names, &is_binary/1) and Enum.uniq(names) == names do
      {:ok, names}
    else
      _invalid -> {:error, "invalid_effect"}
    end
  end

  defp effect(_keys, _state), do: {:error, "invalid_effect"}

  defp proper_list_within?([], _remaining), do: true

  defp proper_list_within?([_head | tail], remaining) when remaining > 0,
    do: proper_list_within?(tail, remaining - 1)

  defp proper_list_within?(_list, _remaining), do: false

  defp actors(actors) when is_list(actors) and length(actors) in 2..@maximum_actors do
    with {:ok, actors} <- each_actor(actors),
         :ok <- unique_actors(actors) do
      cond do
        not Enum.any?(actors, &(&1.control and &1.access == :allow)) ->
          {:error, "missing_allow_control"}

        Enum.all?(actors, & &1.control) ->
          {:error, "no_compared_actor"}

        true ->
          {:ok, actors}
      end
    end
  end

  defp actors(_actors), do: {:error, "invalid_actors"}

  defp each_actor(actors) do
    Enum.reduce_while(actors, {:ok, []}, fn actor, {:ok, valid} ->
      case actor(actor) do
        {:ok, actor} -> {:cont, {:ok, [actor | valid]}}
        :error -> {:halt, {:error, "invalid_actor"}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp actor(actor) when is_list(actor) do
    if Keyword.keyword?(actor) and unique_keys?(actor), do: actor(Map.new(actor)), else: :error
  end

  defp actor(%{name: name, access: access, as: as} = actor) when not is_struct(actor) do
    control = Map.get(actor, :control, false)

    if Enum.all?(Map.keys(actor), &(&1 in @actor_fields)) and is_binary(name) and
         Regex.match?(@actor_name, name) and access in [:allow, :deny] and is_boolean(control) and
         is_function(as, 1),
       do: {:ok, %{name: name, access: access, control: control, as: as}},
       else: :error
  end

  defp actor(_actor), do: :error

  defp unique_actors(actors) do
    names = Enum.map(actors, & &1.name)
    if Enum.uniq(names) == names, do: :ok, else: {:error, "duplicate_actor"}
  end

  ## Execution

  defp execute(plan) do
    key = :crypto.strong_rand_bytes(32)
    [baseline_actor | other_controls] = controls(plan.actors)
    baseline = attempt(plan, baseline_actor, key)

    case allow_control_health(plan, baseline) do
      :healthy ->
        run_after_baseline(plan, key, baseline_actor, baseline, other_controls)

      {:unhealthy, reason} ->
        unhealthy(plan, %{baseline_actor.name => {baseline, nil, reason}}, "control_unhealthy")
    end
  end

  # Entitled controls first, then refused controls, then compared actors.
  defp controls(actors),
    do:
      Enum.filter(actors, &(&1.control and &1.access == :allow)) ++
        Enum.filter(actors, &(&1.control and &1.access == :deny))

  defp run_after_baseline(plan, key, baseline_actor, baseline, other_controls) do
    initial = %{baseline_actor.name => {baseline, nil, nil}}

    controls =
      Enum.reduce_while(other_controls, {:ok, initial}, fn actor, {:ok, done} ->
        attempt = attempt(plan, actor, key)

        case control_health(plan, actor, attempt, baseline) do
          :healthy ->
            {:cont, {:ok, Map.put(done, actor.name, {attempt, nil, nil})}}

          {:unhealthy, reason} ->
            failed = Map.put(done, actor.name, {attempt, nil, reason})
            {:halt, {:unhealthy, failed, unhealthy_reason(actor)}}
        end
      end)

    case controls do
      {:ok, done} ->
        complete(plan, key, baseline, done)

      {:unhealthy, done, reason} ->
        unhealthy(plan, done, reason)
    end
  end

  defp unhealthy_reason(%{access: :allow}), do: "control_unhealthy"
  defp unhealthy_reason(%{access: :deny}), do: "denial_control_unhealthy"

  defp complete(plan, key, baseline, controls) do
    results =
      plan.actors
      |> Enum.reject(& &1.control)
      |> Enum.reduce(controls, fn actor, done ->
        attempt = attempt(plan, actor, key)
        {verdict, reason} = verdict(plan, actor, attempt, baseline)
        Map.put(done, actor.name, {attempt, verdict, reason})
      end)

    entries = entries(plan, results, baseline)
    verdicts = for {_attempt, verdict, _reason} <- Map.values(results), verdict, do: verdict

    outcome =
      cond do
        "confirmed" in verdicts -> "confirmed"
        "not_observed" in verdicts -> "not_observed"
        true -> "not_reproduced"
      end

    truncated = Enum.any?(entries, &get_in(&1, ["response", "truncated"]))

    report(plan, %{
      "completeness" => if(truncated, do: "truncated", else: "complete"),
      "reason" => nil,
      "outcome" => outcome,
      "actors" => entries
    })
  end

  defp unhealthy(plan, results, reason) do
    report(plan, %{
      "completeness" => "infrastructure_failure",
      "reason" => reason,
      "outcome" => "infrastructure_failure",
      "actors" => entries(plan, results, baseline_of(plan, results))
    })
  end

  defp baseline_of(plan, results) do
    [baseline_actor | _rest] = controls(plan.actors)
    {baseline, _verdict, _reason} = Map.fetch!(results, baseline_actor.name)
    baseline
  end

  # One attempt: build a fresh fixture, set up the actor, capture state,
  # perform the request, judge the grant, and capture state again. A failure
  # before the request stops the attempt; a failing request or grant check
  # still captures the final state, because a refused request may have
  # changed it.
  defp attempt(plan, actor, key) do
    with {:ok, fixture} <- guarded("fixture", fn -> plan.fixture.() end),
         {:ok, credential} <- guarded("actor_setup", fn -> actor.as.(fixture) end),
         {:ok, before} <- capture(plan, fixture, key, "state_before") do
      exchange(plan, fixture, credential, before, key)
    else
      {:error, error} -> %{attempted: false, error: error}
    end
  end

  defp exchange(plan, fixture, credential, before, key) do
    {granted, response, error} =
      case guarded("request", fn -> plan.request.(credential, fixture) end) do
        {:ok, response} ->
          case grant(plan.allowed?, response, fixture) do
            {:ok, granted} -> {granted, summary(response, key), nil}
            {:error, error} -> {nil, summary(response, key), error}
          end

        {:error, error} ->
          {nil, nil, error}
      end

    {final, final_error} =
      case capture(plan, fixture, key, "state_after") do
        {:ok, final} -> {final, nil}
        {:error, capture_error} -> {nil, capture_error}
      end

    %{
      attempted: true,
      granted: granted,
      response: response,
      before: before,
      final: final,
      error: error || final_error
    }
  end

  defp grant(check, response, fixture) do
    stage = "allowed_check"

    result =
      if is_function(check, 1),
        do: guarded(stage, fn -> check.(response) end),
        else: guarded(stage, fn -> check.(response, fixture) end)

    case result do
      {:ok, granted} when is_boolean(granted) -> {:ok, granted}
      {:ok, _other} -> {:error, error(stage, "invalid_result", nil)}
      {:error, error} -> {:error, error}
    end
  end

  defp guarded(stage, fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, error(stage, "error", exception.__struct__)}
  catch
    kind, _reason -> {:error, error(stage, Atom.to_string(kind), nil)}
  end

  defp error(stage, kind, exception),
    do: %{"stage" => stage, "kind" => kind, "exception" => exception && inspect(exception)}

  defp capture(%{state: nil}, _fixture, _key, _stage), do: {:ok, %{}}

  defp capture(plan, fixture, key, stage) do
    case guarded(stage, fn -> plan.state.(fixture) end) do
      {:ok, state} -> fingerprints(state, key, stage)
      {:error, error} -> {:error, error}
    end
  end

  defp fingerprints(state, key, stage)
       when is_map(state) and not is_struct(state) and map_size(state) <= @maximum_state_keys do
    pairs = Enum.map(state, fn {name, value} -> {key_name(name), fingerprint(value, key)} end)
    names = Enum.map(pairs, &elem(&1, 0))

    if Enum.all?(names, &is_binary/1) and Enum.uniq(names) == names,
      do: {:ok, Map.new(pairs)},
      else: {:error, error(stage, "invalid_result", nil)}
  end

  defp fingerprints(_state, _key, stage), do: {:error, error(stage, "invalid_result", nil)}

  defp key_name(name) when is_atom(name) and not is_boolean(name) and not is_nil(name),
    do: key_name(Atom.to_string(name))

  defp key_name(name) when is_binary(name),
    do: if(Regex.match?(@identifier, name), do: name, else: nil)

  defp key_name(_name), do: nil

  defp fingerprint(value, key) do
    if within_fingerprint_budget?(
         [value],
         @maximum_fingerprint_terms,
         @maximum_fingerprint_bytes
       ),
       do: :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(value, [:deterministic])),
       else: :unknown
  end

  # Visits at most the term limit before anything sizes or serializes the whole
  # value, so a small term that shares one subterm many times stays cheap. Each
  # container is charged 5 bytes, the largest external-format header, and each
  # leaf its exact external size (O(1) for a leaf), so the estimate never
  # undercounts the serialized size and is exact for a single binary. A
  # function's environment is invisible to this walk, so functions are never
  # fingerprinted.
  defp within_fingerprint_budget?([], _terms, bytes), do: bytes >= 0

  defp within_fingerprint_budget?(_stack, terms, bytes) when terms <= 0 or bytes < 0,
    do: false

  defp within_fingerprint_budget?([[head | tail] | stack], terms, bytes),
    do: within_fingerprint_budget?([head, tail | stack], terms - 1, bytes - 5)

  defp within_fingerprint_budget?([tuple | stack], terms, bytes) when is_tuple(tuple) do
    tuple_size(tuple) < terms and
      within_fingerprint_budget?(Tuple.to_list(tuple) ++ stack, terms - 1, bytes - 5)
  end

  defp within_fingerprint_budget?([map | stack], terms, bytes) when is_map(map) do
    # `:maps.to_list/1`, unlike `Enum`, also walks structs such as money amounts.
    map_size(map) * 2 < terms and
      within_fingerprint_budget?(
        Enum.flat_map(:maps.to_list(map), fn {name, value} -> [name, value] end) ++ stack,
        terms - 1,
        bytes - 5
      )
  end

  defp within_fingerprint_budget?([function | _stack], _terms, _bytes)
       when is_function(function),
       do: false

  defp within_fingerprint_budget?([leaf | stack], terms, bytes),
    do: within_fingerprint_budget?(stack, terms - 1, bytes - :erlang.external_size(leaf))

  ## Health and verdicts

  defp allow_control_health(plan, attempt) do
    cond do
      not attempt.attempted or attempt.error -> {:unhealthy, failure_reason(attempt)}
      attempt.granted != true -> {:unhealthy, "control_refused"}
      effect_changed(plan, attempt) != true -> {:unhealthy, "control_effect_missing"}
      true -> :healthy
    end
  end

  defp control_health(plan, %{access: :allow}, attempt, baseline) do
    with :healthy <- allow_control_health(plan, attempt) do
      case initial_mismatch(attempt, baseline) do
        nil -> :healthy
        mismatch -> {:unhealthy, mismatch}
      end
    end
  end

  defp control_health(_plan, %{access: :deny}, attempt, baseline) do
    cond do
      not attempt.attempted or attempt.error ->
        {:unhealthy, failure_reason(attempt)}

      initial_mismatch(attempt, baseline) != nil ->
        {:unhealthy, initial_mismatch(attempt, baseline)}

      attempt.granted ->
        {:unhealthy, "control_granted"}

      any_changed(attempt) != false ->
        {:unhealthy, "control_changed_state"}

      true ->
        :healthy
    end
  end

  defp verdict(plan, actor, attempt, baseline) do
    cond do
      not attempt.attempted ->
        {"not_observed", failure_reason(attempt)}

      initial_mismatch(attempt, baseline) != nil ->
        {"not_observed", initial_mismatch(attempt, baseline)}

      actor.access == :deny ->
        refused_verdict(attempt)

      true ->
        granted_verdict(plan, attempt)
    end
  end

  defp refused_verdict(attempt) do
    changed = any_changed(attempt)

    cond do
      attempt.granted == true -> {"confirmed", "wrongly_granted"}
      changed == true -> {"confirmed", "state_changed_while_refused"}
      attempt.error -> {"not_observed", failure_reason(attempt)}
      changed == nil -> {"not_observed", "state_not_comparable"}
      true -> {"not_reproduced", "refused_as_declared"}
    end
  end

  defp granted_verdict(plan, attempt) do
    cond do
      attempt.error -> {"not_observed", failure_reason(attempt)}
      attempt.granted == false -> {"confirmed", "wrongly_refused"}
      effect_changed(plan, attempt) == false -> {"confirmed", "granted_without_effect"}
      effect_changed(plan, attempt) == nil -> {"not_observed", "state_not_comparable"}
      true -> {"not_reproduced", "granted_as_declared"}
    end
  end

  defp failure_reason(%{error: %{"stage" => stage}}), do: stage <> "_failed"

  # `true` when every effect key changed, `false` when one is known unchanged
  # or was never captured, `nil` when a comparison is unknown.
  defp effect_changed(%{effect: []}, _attempt), do: true

  defp effect_changed(plan, attempt) do
    changes = Enum.map(plan.effect, &changed(attempt, &1))

    cond do
      false in changes -> false
      nil in changes -> nil
      true -> true
    end
  end

  defp any_changed(attempt) do
    changes = Enum.map(state_keys(attempt), &changed(attempt, &1))

    cond do
      true in changes -> true
      nil in changes -> nil
      true -> false
    end
  end

  defp changed(%{final: nil}, _name), do: nil

  defp changed(attempt, name) do
    case {Map.get(attempt.before, name, :absent), Map.get(attempt.final, name, :absent)} do
      {:absent, :absent} -> false
      {:unknown, _final} -> nil
      {_before, :unknown} -> nil
      {before, final} -> before != final
    end
  end

  defp state_keys(%{before: before, final: nil}), do: before |> Map.keys() |> Enum.sort()

  defp state_keys(%{before: before, final: final}),
    do: (Map.keys(before) ++ Map.keys(final)) |> Enum.uniq() |> Enum.sort()

  # Compares every initial state key with the control's: `nil` when they are
  # equal, otherwise why the actor did not start from the control's state. A
  # value that could not be fingerprinted on either side is never equal.
  defp initial_mismatch(attempt, baseline) do
    names = Enum.uniq(Map.keys(attempt.before) ++ Map.keys(baseline.before))
    results = Enum.map(names, &matches(attempt.before, baseline.before, &1))

    cond do
      false in results -> "initial_state_differs_from_control"
      nil in results -> "initial_state_not_comparable"
      true -> nil
    end
  end

  ## Report

  defp entries(plan, results, baseline) do
    for actor <- plan.actors do
      case Map.fetch(results, actor.name) do
        {:ok, {attempt, verdict, reason}} -> entry(actor, attempt, verdict, reason, baseline)
        :error -> not_attempted(actor)
      end
    end
  end

  defp entry(actor, %{attempted: false} = attempt, verdict, reason, _baseline) do
    actor
    |> not_attempted()
    |> Map.merge(%{"error" => attempt.error, "verdict" => verdict, "reason" => reason})
  end

  defp entry(actor, attempt, verdict, reason, baseline) do
    %{
      "name" => actor.name,
      "access" => Atom.to_string(actor.access),
      "control" => actor.control,
      "attempted" => true,
      "observed_access" => observed_access(attempt.granted),
      "error" => attempt.error,
      "response" => response_entry(attempt.response, baseline),
      "state" => state_entry(attempt, baseline),
      "verdict" => verdict,
      "reason" => reason
    }
  end

  defp not_attempted(actor),
    do: %{
      "name" => actor.name,
      "access" => Atom.to_string(actor.access),
      "control" => actor.control,
      "attempted" => false,
      "observed_access" => nil,
      "error" => nil,
      "response" => nil,
      "state" => nil,
      "verdict" => nil,
      "reason" => nil
    }

  defp observed_access(true), do: "granted"
  defp observed_access(false), do: "refused"
  defp observed_access(nil), do: nil

  defp response_entry(nil, _baseline), do: nil

  defp response_entry(summary, baseline) do
    matches =
      case {summary.fingerprint, baseline[:response]} do
        {fingerprint, %{fingerprint: control}}
        when is_binary(fingerprint) and is_binary(control) ->
          fingerprint == control

        _unknown ->
          nil
      end

    %{
      "shape" => summary.shape,
      "type_names" => summary.type_names,
      "error_codes" => summary.error_codes,
      "error_codes_withheld" => summary.error_codes_withheld,
      "matches_control" => matches,
      "truncated" => summary.truncated
    }
  end

  defp state_entry(attempt, baseline) do
    control_before = Map.get(baseline, :before)
    control_final = Map.get(baseline, :final)

    for name <- state_keys(attempt) do
      %{
        "key" => name,
        "changed" => changed(attempt, name),
        "before_matches_control" => matches(attempt.before, control_before, name),
        "after_matches_control" => matches(attempt.final, control_final, name)
      }
    end
  end

  defp matches(nil, _control, _name), do: nil
  defp matches(_state, nil, _name), do: nil

  defp matches(state, control, name) do
    case {Map.get(state, name, :absent), Map.get(control, name, :absent)} do
      {:unknown, _control} -> nil
      {_state, :unknown} -> nil
      {value, control} -> value == control
    end
  end

  defp invalid(reason, declaration) do
    {operation, context} = echo(declaration)

    base(operation, context)
    |> Map.merge(%{
      "completeness" => "infrastructure_failure",
      "reason" => reason,
      "outcome" => "infrastructure_failure",
      "actors" => []
    })
  end

  defp echo(declaration) do
    case fields(declaration) do
      {:ok, fields} ->
        {valid_label(fields[:operation], @maximum_operation_bytes),
         valid_label(fields[:context], @maximum_context_bytes)}

      {:error, _reason} ->
        {nil, nil}
    end
  end

  defp valid_label(value, maximum), do: if(label?(value, maximum), do: value, else: nil)

  defp report(plan, fields), do: plan.operation |> base(plan.context) |> Map.merge(fields)

  defp base(operation, context),
    do: %{
      "schema" => @schema,
      "operation" => operation,
      "context" => context,
      "limits" => limits(),
      "limitations" => limitations()
    }

  defp limits,
    do: %{
      "actor_limit" => @maximum_actors,
      "operation_byte_limit" => @maximum_operation_bytes,
      "context_byte_limit" => @maximum_context_bytes,
      "state_key_limit" => @maximum_state_keys,
      "shape_path_limit" => @maximum_shape_paths,
      "shape_depth_limit" => @maximum_shape_depth,
      "shape_node_limit" => @maximum_shape_nodes,
      "path_byte_limit" => @maximum_path_bytes,
      "type_name_limit" => @maximum_type_names,
      "error_code_limit" => @maximum_error_codes,
      "fingerprint_value_byte_limit" => @maximum_fingerprint_bytes,
      "fingerprint_term_limit" => @maximum_fingerprint_terms
    }

  defp limitations,
    do: [
      "access_rule_and_grant_check_are_caller_declared",
      "declared_actors_are_not_exhaustive",
      "fixture_is_rebuilt_for_each_actor",
      "state_is_the_caller_projection_only",
      "fingerprints_comparable_within_call_only",
      "attempts_run_in_the_calling_process_under_its_test_timeout",
      "context_is_caller_supplied_and_unverified",
      "caller_must_bind_test_and_revision"
    ]

  ## Response summary

  # Field paths with their kinds, `__typename` values, and `code` values under
  # an `errors` or `extensions` key. Only map keys that are identifiers are
  # named; any other key is `*`. No other value is read into the summary.
  defp summary(response, key) do
    walked =
      walk(response, "$", 0, false, %{
        shape: %{},
        type_names: MapSet.new(),
        error_codes: MapSet.new(),
        error_codes_withheld: 0,
        nodes: 0,
        truncated: false
      })

    %{
      shape:
        Map.new(walked.shape, fn {path, kinds} ->
          {path, kinds |> Enum.sort() |> Enum.join("|")}
        end),
      type_names: Enum.sort(walked.type_names),
      error_codes: Enum.sort(walked.error_codes),
      error_codes_withheld: walked.error_codes_withheld,
      truncated: walked.truncated,
      fingerprint: fingerprint(response, key)
    }
  end

  defp walk(_term, _path, _depth, _in_error, %{nodes: nodes} = acc)
       when nodes >= @maximum_shape_nodes,
       do: %{acc | truncated: true}

  defp walk(term, path, depth, in_error, acc) do
    acc = record(%{acc | nodes: acc.nodes + 1}, path, kind(term))
    descend(term, path, depth, in_error, acc)
  end

  defp descend(map, path, depth, in_error, acc) when is_map(map) and not is_struct(map) do
    cond do
      map_size(map) == 0 ->
        acc

      depth >= @maximum_shape_depth or map_size(map) > @maximum_shape_nodes ->
        %{acc | truncated: true}

      true ->
        map
        |> Enum.map(fn {name, value} -> {segment(name), value} end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce(acc, fn {segment, value}, acc ->
          acc = collect(acc, segment, value, in_error)
          nested_error = in_error or segment in ["errors", "extensions"]
          walk(value, path <> "." <> segment, depth + 1, nested_error, acc)
        end)
    end
  end

  defp descend([], _path, _depth, _in_error, acc), do: acc

  defp descend(list, path, depth, in_error, acc) when is_list(list) do
    if depth >= @maximum_shape_depth,
      do: %{acc | truncated: true},
      else: walk_list(list, path <> "[]", depth + 1, in_error, acc)
  end

  defp descend(_term, _path, _depth, _in_error, acc), do: acc

  # Elements share one path; an improper tail is walked as one more element.
  defp walk_list([], _path, _depth, _in_error, acc), do: acc

  defp walk_list(_list, _path, _depth, _in_error, %{nodes: nodes} = acc)
       when nodes >= @maximum_shape_nodes,
       do: %{acc | truncated: true}

  defp walk_list([head | tail], path, depth, in_error, acc),
    do: walk_list(tail, path, depth, in_error, walk(head, path, depth, in_error, acc))

  defp walk_list(tail, path, depth, in_error, acc), do: walk(tail, path, depth, in_error, acc)

  defp collect(acc, "__typename", value, _in_error) when is_binary(value) do
    cond do
      not Regex.match?(@identifier, value) -> acc
      MapSet.member?(acc.type_names, value) -> acc
      MapSet.size(acc.type_names) >= @maximum_type_names -> %{acc | truncated: true}
      true -> %{acc | type_names: MapSet.put(acc.type_names, value)}
    end
  end

  defp collect(acc, "code", value, true) when is_binary(value) do
    cond do
      not Regex.match?(@identifier, value) ->
        %{acc | error_codes_withheld: acc.error_codes_withheld + 1}

      MapSet.member?(acc.error_codes, value) ->
        acc

      MapSet.size(acc.error_codes) >= @maximum_error_codes ->
        %{acc | truncated: true}

      true ->
        %{acc | error_codes: MapSet.put(acc.error_codes, value)}
    end
  end

  defp collect(acc, _segment, _value, _in_error), do: acc

  defp record(acc, path, kind) do
    case acc.shape do
      %{^path => kinds} ->
        %{acc | shape: %{acc.shape | path => MapSet.put(kinds, kind)}}

      shape
      when byte_size(path) > @maximum_path_bytes or map_size(shape) >= @maximum_shape_paths ->
        %{acc | truncated: true}

      shape ->
        %{acc | shape: Map.put(shape, path, MapSet.new([kind]))}
    end
  end

  defp segment(name) when is_atom(name) and not is_nil(name) and not is_boolean(name),
    do: segment(Atom.to_string(name))

  defp segment(name) when is_binary(name),
    do: if(Regex.match?(@identifier, name), do: name, else: "*")

  defp segment(_name), do: "*"

  defp kind(nil), do: "null"
  defp kind(value) when is_boolean(value), do: "boolean"
  defp kind(value) when is_binary(value), do: "string"
  defp kind(value) when is_number(value), do: "number"
  defp kind(value) when is_atom(value), do: "atom"
  defp kind(value) when is_struct(value), do: "struct"
  defp kind(value) when is_map(value), do: "object"
  defp kind(value) when is_list(value), do: "list"
  defp kind(value) when is_tuple(value), do: "tuple"
  defp kind(_value), do: "other"

  ## Output

  # The leading newline keeps the prefix at the start of a line even when the
  # ExUnit formatter has just printed a progress dot without one.
  defp emit(report), do: IO.puts(["\n", @prefix, :json.encode(json(report))])

  defp json(nil), do: :null
  defp json(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, json(value)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value), do: value
end
