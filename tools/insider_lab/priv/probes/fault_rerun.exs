defmodule InsiderLab.FaultRerunOracle do
  @moduledoc false

  # A fault-and-rerun oracle for background workers, loaded into a host's test
  # VM by an agent-written ExUnit probe with `Code.require_file/1`. `run/1`
  # replaces each declared provider function with a recorder, runs the
  # worker once with no fault as a healthy control, then against a fresh
  # fixture once with a fault the caller declares at one provider call and
  # again as the retry. It counts the external effects of each attempt and
  # compares them with the references the committed local state holds: an
  # effect no committed row references is an orphan, and more distinct
  # effects than the control made is a repeat. The control must succeed and
  # make exactly the expected effects, all referenced, or the whole call is an
  # infrastructure failure and the fault run is not attempted.
  #
  # The fixture, the worker invocation, the stub installer, the simulated
  # provider responses, the effect identity, the idempotency key, and the
  # projection of committed references are host adapters supplied by the
  # caller. The engine stubs every exported arity of a declared function, so
  # a call through a default-argument arity cannot bypass the recorder. The
  # report holds call counts per arity, result tags, exception module names,
  # and per-call labels of keyed effect and key fingerprints, never an
  # argument, response, identity, key, or reference value.

  @schema "insider.fault-rerun-oracle/v1"
  @prefix "INSIDER_FAULT_RERUN_ORACLE="
  @maximum_operation_bytes 255
  @maximum_context_bytes 1_024
  @maximum_boundaries 16
  @maximum_arity 12
  @maximum_attempts 8
  @maximum_fault_call 64
  @maximum_expected_effects 64
  @maximum_records 512
  @maximum_replay_bytes 8_388_608
  @replay_wait_milliseconds 2_000
  @maximum_listed_effects 64
  @maximum_references 1_024
  @maximum_fingerprint_bytes 1_048_576
  @maximum_fingerprint_terms 65_536
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
  @boundary_name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @fields [
    :operation,
    :context,
    :fixture,
    :perform,
    :succeeded?,
    :stub,
    :boundaries,
    :fault,
    :references,
    :attempts
  ]
  @required_fields [:operation, :fixture, :perform, :stub, :boundaries, :fault, :references]
  @boundary_fields [:name, :function, :arities, :respond, :effect, :expect, :referenced, :key]
  @fault_fields [:boundary, :call, :attempts, :result, :lost_response]
  @reserved_functions [:module_info, :__info__]

  @doc """
  Runs the declared control and fault run, prints one `#{@prefix}` JSON line,
  and returns the same report as a string-keyed map with `nil` for JSON null.
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
         {:ok, operation} <-
           label(fields.operation, @maximum_operation_bytes, "invalid_operation"),
         {:ok, context} <- context(Map.get(fields, :context)),
         :ok <- function(fields.fixture, [0], "invalid_fixture"),
         :ok <- function(fields.perform, [1, 2], "invalid_perform"),
         :ok <- optional_function(Map.get(fields, :succeeded?), [1], "invalid_succeeded_check"),
         :ok <- function(fields.stub, [3], "invalid_stub"),
         :ok <- function(fields.references, [1], "invalid_references"),
         {:ok, attempts} <- attempts(Map.get(fields, :attempts, 2)),
         {:ok, boundaries} <- boundaries(fields.boundaries),
         {:ok, fault} <- fault(fields.fault, boundaries, attempts) do
      {:ok,
       %{
         operation: operation,
         context: context,
         fixture: fields.fixture,
         perform: fields.perform,
         succeeded?: Map.get(fields, :succeeded?),
         stub: fields.stub,
         references: fields.references,
         attempts: attempts,
         boundaries: boundaries,
         fault: fault
       }}
    end
  end

  defp fields(declaration), do: entry_fields(declaration, nil, "invalid_declaration")

  # A keyword list with unique keys or a plain map with atom keys; with
  # `allowed`, every key must be one of them.
  defp entry_fields(entry, allowed, reason) when is_list(entry) do
    if Keyword.keyword?(entry) and unique_keys?(entry),
      do: entry_fields(Map.new(entry), allowed, reason),
      else: {:error, reason}
  end

  defp entry_fields(entry, allowed, reason) when is_map(entry) and not is_struct(entry) do
    keys = Map.keys(entry)

    if Enum.all?(keys, &is_atom/1) and (allowed == nil or Enum.all?(keys, &(&1 in allowed))),
      do: {:ok, entry},
      else: {:error, reason}
  end

  defp entry_fields(_entry, _allowed, reason), do: {:error, reason}

  defp unique_keys?(keyword),
    do: length(Keyword.keys(keyword)) == length(Enum.uniq(Keyword.keys(keyword)))

  defp known_fields(fields) do
    cond do
      Enum.any?(Map.keys(fields), &(&1 not in @fields)) -> {:error, "unknown_field"}
      Enum.any?(@required_fields, &(not Map.has_key?(fields, &1))) -> {:error, "missing_field"}
      true -> :ok
    end
  end

  defp context(nil), do: {:ok, nil}
  defp context(context), do: label(context, @maximum_context_bytes, "invalid_context")

  defp label(value, maximum, reason),
    do: if(label?(value, maximum), do: {:ok, value}, else: {:error, reason})

  defp label?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      String.printable?(value) and
      not Enum.any?(String.to_charlist(value), &(&1 < 0x20 or &1 == 0x7F))
  end

  defp function(value, arities, reason),
    do: check(Enum.any?(arities, &is_function(value, &1)), reason)

  defp optional_function(nil, _arities, _reason), do: :ok
  defp optional_function(value, arities, reason), do: function(value, arities, reason)

  defp check(true, _reason), do: :ok
  defp check(_false, reason), do: {:error, reason}

  defp attempts(attempts) when is_integer(attempts) and attempts in 2..@maximum_attempts,
    do: {:ok, attempts}

  defp attempts(_attempts), do: {:error, "invalid_attempts"}

  defp proper_list_within?([], _remaining), do: true

  defp proper_list_within?([_head | tail], remaining) when remaining > 0,
    do: proper_list_within?(tail, remaining - 1)

  defp proper_list_within?(_list, _remaining), do: false

  defp boundaries(entries) do
    with :ok <-
           check(
             entries != [] and proper_list_within?(entries, @maximum_boundaries),
             "invalid_boundaries"
           ),
         {:ok, boundaries} <- each(entries, &boundary/1),
         :ok <- unique(Enum.map(boundaries, & &1.name), "duplicate_boundary"),
         :ok <- unique(Enum.map(boundaries, &{&1.module, &1.function}), "duplicate_boundary"),
         :ok <- check(Enum.any?(boundaries, &(&1.expect not in [nil, 0])), "no_expected_effect") do
      {:ok, boundaries}
    end
  end

  defp each(entries, validate) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, valid} ->
      case validate.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | valid]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp unique(values, reason), do: check(Enum.uniq(values) == values, reason)

  defp boundary(entry) do
    with {:ok, fields} <- entry_fields(entry, @boundary_fields, "invalid_boundary"),
         :ok <- check(boundary_shape?(fields), "invalid_boundary"),
         {module, name} = fields.function,
         {:ok, arities} <- arities(module, name, Map.get(fields, :arities)) do
      effect = Map.get(fields, :effect)

      {:ok,
       %{
         name: fields.name,
         module: module,
         function: name,
         arities: arities,
         respond: fields.respond,
         effect: effect,
         expect: Map.get(fields, :expect),
         referenced: effect != nil and Map.get(fields, :referenced, true),
         key: Map.get(fields, :key)
       }}
    end
  end

  # `effect` and `expect` come together, and `referenced` only with them.
  defp boundary_shape?(fields) do
    effect = Map.get(fields, :effect)
    expect = Map.get(fields, :expect)

    is_binary(fields[:name]) and Regex.match?(@boundary_name, fields[:name]) and
      function_reference?(fields[:function]) and is_function(fields[:respond], 2) and
      if(effect == nil,
        do: expect == nil and not Map.has_key?(fields, :referenced),
        else:
          is_function(effect, 2) and is_integer(expect) and expect in 0..@maximum_expected_effects and
            is_boolean(Map.get(fields, :referenced, true))
      ) and
      (Map.get(fields, :key) == nil or is_function(fields.key, 1))
  end

  defp function_reference?({module, name})
       when is_atom(module) and module not in [nil, true, false] and is_atom(name),
       do: name not in @reserved_functions

  defp function_reference?(_function), do: false

  # Every exported arity of the function is stubbed. A declared `arities`
  # list is the caller's statement of what it expects to cover; it must name
  # exactly the exported arities, so a recorder written for `put/4` cannot
  # silently miss the `put/3` calls the code makes.
  defp arities(module, name, declared) do
    exported = exported_arities(module, name)

    cond do
      exported == [] -> {:error, "function_not_exported"}
      Enum.any?(exported, &(&1 > @maximum_arity)) -> {:error, "unsupported_arity"}
      declared == nil -> {:ok, exported}
      not arity_list?(declared) -> {:error, "invalid_boundary"}
      exported -- declared != [] -> {:error, "arity_not_covered"}
      declared -- exported != [] -> {:error, "arity_not_exported"}
      true -> {:ok, exported}
    end
  end

  defp exported_arities(module, name) do
    if Code.ensure_loaded?(module),
      do: for({^name, arity} <- module.module_info(:exports), do: arity) |> Enum.sort(),
      else: []
  end

  defp arity_list?(arities) do
    proper_list_within?(arities, @maximum_arity + 1) and arities != [] and
      Enum.all?(arities, &(is_integer(&1) and &1 >= 0)) and Enum.uniq(arities) == arities
  end

  defp fault(entry, boundaries, attempts) do
    with {:ok, fields} <- entry_fields(entry, @fault_fields, "invalid_fault"),
         :ok <-
           check(
             Map.has_key?(fields, :boundary) and Map.has_key?(fields, :result),
             "invalid_fault"
           ),
         :ok <-
           check(Enum.any?(boundaries, &(&1.name == fields.boundary)), "unknown_fault_boundary"),
         call = Map.get(fields, :call, 1),
         faulted = Map.get(fields, :attempts, 1),
         lost_response = Map.get(fields, :lost_response, false),
         :ok <-
           check(
             is_integer(call) and call in 1..@maximum_fault_call and is_integer(faulted) and
               faulted >= 1 and faulted < attempts and is_boolean(lost_response) and
               fault_result?(fields.result),
             "invalid_fault"
           ) do
      {:ok,
       %{
         boundary: fields.boundary,
         call: call,
         attempts: faulted,
         result: fields.result,
         lost_response: lost_response
       }}
    end
  end

  defp fault_result?({:return, _value}), do: true
  defp fault_result?({:raise, exception}), do: is_exception(exception)
  defp fault_result?(_result), do: false

  ## Execution

  defp execute(plan) do
    table = :ets.new(:insider_fault_rerun_oracle, [:set, :public])
    :ets.insert(table, {:phase, :idle})
    state = %{table: table, key: :crypto.strong_rand_bytes(32), fault: plan.fault}

    try do
      case install(plan, state) do
        :ok -> run_scenarios(plan, state)
        {:error, error} -> failed(plan, "stub_failed", error, nil)
      end
    after
      :ets.delete(table)
    end
  end

  defp install(plan, state) do
    stubs =
      for boundary <- plan.boundaries, arity <- boundary.arities do
        {boundary, wrapper(arity, &boundary_call(state, boundary, &1))}
      end

    Enum.reduce_while(stubs, :ok, fn {boundary, stub}, :ok ->
      case guarded("stub", fn -> plan.stub.(boundary.module, boundary.function, stub) end) do
        {:ok, _installed} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A function of each arity the recorder may need, generated at compile time
  # so that the stub has the stubbed function's exact arity.
  for arity <- 0..@maximum_arity do
    arguments = Macro.generate_arguments(arity, __MODULE__)

    defp wrapper(unquote(arity), handle),
      do: fn unquote_splicing(arguments) -> handle.(unquote(arguments)) end
  end

  defp run_scenarios(plan, state) do
    control = scenario(plan, state, :control, 1)

    case control_health(plan, control) do
      nil ->
        fault_run = scenario(plan, state, :fault, plan.attempts)
        complete(plan, control, fault_run)

      reason ->
        failed(plan, "control_unhealthy", nil, {control, reason})
    end
  end

  # One scenario: build a fresh fixture, run up to `attempts` attempts and stop
  # at the first that succeeds, then project the committed references. The
  # first failing stage names the scenario's error: the fixture, then an
  # adapter inside a stubbed call, then the success check or the projection.
  defp scenario(plan, state, name, attempts) do
    phase(state, {:setup, name})

    {result, later_error} =
      case guarded("fixture", plan.fixture) do
        {:ok, fixture} ->
          tries = attempts(plan, state, name, fixture, attempts)
          phase(state, {:setup, name})
          {references, references_error} = references(plan, state, fixture)

          {%{attempted: true, attempts: tries, references: references, error: nil},
           Enum.find_value(tries, & &1.error) || references_error}

        {:error, error} ->
          {%{attempted: false, attempts: [], references: nil, error: error}, nil}
      end

    # The phase stays on this scenario, so a call from work the worker left
    # running is charged to it until the next scenario's fixture starts.
    recorded = recorded(state, name)

    result
    |> Map.merge(recorded)
    |> Map.put(:error, result.error || recorded.failure || later_error)
  end

  defp attempts(plan, state, name, fixture, attempts) do
    1..attempts
    |> Enum.reduce_while([], fn number, done ->
      phase(state, {:attempt, name, number})
      outcome = invoke(plan.perform, fixture, number)
      phase(state, {:setup, name})

      case judge(plan.succeeded?, outcome) do
        {:ok, succeeded} ->
          tried = %{attempt: number, result: result(outcome), succeeded: succeeded, error: nil}
          if succeeded, do: {:halt, [tried | done]}, else: {:cont, [tried | done]}

        {:error, error} ->
          {:halt,
           [%{attempt: number, result: result(outcome), succeeded: nil, error: error} | done]}
      end
    end)
    |> Enum.reverse()
  end

  # A worker that raises, exits, or throws has failed its attempt, as a job
  # queue would see it; that is an outcome, not an adapter failure.
  defp invoke(perform, fixture, number) do
    if is_function(perform, 1),
      do: {:returned, perform.(fixture)},
      else: {:returned, perform.(fixture, number)}
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, _reason -> {kind, nil}
  end

  defp judge(nil, {:returned, value}), do: {:ok, value == :ok or match?({:ok, _value}, value)}

  defp judge(check, {:returned, value}) do
    case guarded("succeeded_check", fn -> check.(value) end) do
      {:ok, succeeded} when is_boolean(succeeded) -> {:ok, succeeded}
      {:ok, _other} -> {:error, error("succeeded_check", "invalid_result", nil)}
      error -> error
    end
  end

  defp judge(_check, _outcome), do: {:ok, false}

  defp result({:returned, value}),
    do: %{"kind" => "returned", "tag" => tag(value), "exception" => nil}

  defp result({:raised, module}),
    do: %{"kind" => "raised", "tag" => nil, "exception" => inspect(module)}

  defp result({kind, nil}),
    do: %{"kind" => Atom.to_string(kind), "tag" => nil, "exception" => nil}

  # The atom of `:ok`, `{:error, _}`, `{:cancel, _}` and similar, or the
  # value's kind; never the value.
  defp tag(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: identifier(Atom.to_string(value)) || "atom"

  defp tag(value) when is_tuple(value) and tuple_size(value) > 0 and is_atom(elem(value, 0)),
    do: tag(elem(value, 0))

  defp tag(value), do: kind(value)

  defp identifier(name), do: if(Regex.match?(@identifier, name), do: name, else: nil)

  # The projection returns the committed provider ids grouped by the
  # referenced effect boundary that creates them, so equal ids from two
  # providers never stand for each other. Each id is fingerprinted with its
  # boundary name, as effect identities are.
  defp references(plan, state, fixture) do
    case guarded("references", fn -> plan.references.(fixture) end) do
      {:ok, references} ->
        case reference_fingerprints(plan, references, state.key) do
          {:ok, fingerprints} ->
            known = fingerprints |> Enum.filter(&is_binary/1) |> MapSet.new()
            {%{known: known, unknown: Enum.count(fingerprints, &(&1 == :unknown))}, nil}

          :error ->
            {nil, error("references", "invalid_result", nil)}
        end

      {:error, error} ->
        {nil, error}
    end
  end

  defp reference_fingerprints(plan, references, key)
       when is_map(references) and not is_struct(references) and
              map_size(references) <= @maximum_boundaries do
    names = for boundary <- plan.boundaries, boundary.referenced, do: boundary.name

    references
    |> Enum.reduce_while({:ok, [], @maximum_references}, fn {group, ids}, {:ok, done, left} ->
      name = key_name(group)

      if name in names and proper_list_within?(ids, left) do
        fingerprints = for id <- ids, id != nil, do: fingerprint({name, id}, key)
        {:cont, {:ok, fingerprints ++ done, left - length(ids)}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, fingerprints, _left} -> {:ok, fingerprints}
      :error -> :error
    end
  end

  defp reference_fingerprints(_plan, _references, _key), do: :error

  defp key_name(name) when is_atom(name) and not is_boolean(name) and not is_nil(name),
    do: Atom.to_string(name)

  defp key_name(name) when is_binary(name), do: name
  defp key_name(_name), do: nil

  defp guarded(stage, fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, error(stage, "error", exception.__struct__)}
  catch
    kind, _reason -> {:error, error(stage, Atom.to_string(kind), nil)}
  end

  defp error(stage, kind, exception),
    do: %{"stage" => stage, "kind" => kind, "exception" => exception && inspect(exception)}

  ## Recorder

  defp phase(state, phase), do: :ets.insert(state.table, {:phase, phase})

  # Runs in whichever process called the stubbed function.
  defp boundary_call(state, boundary, args) do
    {scenario, attempt} = current_phase(state.table)
    sequence = increment(state.table, {:sequence, boundary.name})
    position = increment(state.table, {:position, scenario, attempt, boundary.name})
    faulted = faulted?(state.fault, boundary.name, scenario, attempt, position)
    key = call_key(state, boundary, scenario, args)
    call = %{identity: nil, key: key, faulted: faulted, replayed: false}

    if faulted, do: :ets.insert(state.table, {{:fault_reached, attempt}, true})

    if faulted and not state.fault.lost_response do
      record(state, scenario, attempt, boundary, length(args), call)
      deliver(state.fault.result)
    else
      {response, replayed} = provide(state, boundary, scenario, args, sequence, key)
      identity = identity(state, boundary, scenario, attempt, args, response)

      record(state, scenario, attempt, boundary, length(args), %{
        call
        | identity: identity,
          replayed: replayed
      })

      if faulted, do: deliver(state.fault.result), else: response
    end
  end

  defp current_phase(table) do
    case :ets.lookup(table, :phase) do
      [{:phase, {:attempt, scenario, attempt}}] -> {scenario, attempt}
      [{:phase, {:setup, scenario}}] -> {scenario, 0}
      [{:phase, :idle}] -> {:idle, 0}
    end
  rescue
    ArgumentError ->
      reraise RuntimeError,
              [
                message: "an InsiderLab.FaultRerunOracle boundary was called after run/1 returned"
              ],
              __STACKTRACE__
  end

  defp increment(table, counter), do: :ets.update_counter(table, counter, 1, {counter, 0})

  defp faulted?(fault, name, :fault, attempt, position),
    do: name == fault.boundary and attempt in 1..fault.attempts//1 and position == fault.call

  defp faulted?(_fault, _name, _scenario, _attempt, _position), do: false

  defp deliver({:return, value}), do: value
  defp deliver({:raise, exception}), do: raise(exception)

  defp call_key(_state, %{key: nil}, _scenario, _args), do: nil

  # A key that cannot be fingerprinted cannot be replayed, so the scenario
  # can no longer tell a repeated create from a replayed one.
  defp call_key(state, boundary, scenario, args) do
    case adapter(state, scenario, boundary, "key", fn -> boundary.key.(args) end) do
      nil ->
        nil

      key ->
        fingerprint = fingerprint(key, state.key)
        if fingerprint == :unknown, do: key_not_comparable(state, scenario)
        fingerprint
    end
  end

  defp key_not_comparable(state, scenario),
    do: :ets.insert(state.table, {{:key_not_comparable, scenario}, true})

  # A repeated non-nil key replays the first response at that boundary within
  # the scenario, as a provider that honours idempotency keys does. The first
  # caller claims the key and responds; a concurrent caller polls the table
  # for that response instead of creating again, and no message is ever sent
  # to a host process. A call that cannot be replayed (the claimant is itself,
  # an ancestor, or dead, the wait times out, the claim limit is spent, or the
  # response was never cached) is answered fresh and makes the scenario not
  # comparable.
  defp provide(state, boundary, scenario, args, sequence, key) when is_binary(key) do
    replay = {:replay, scenario, boundary.name, key}

    case :ets.lookup(state.table, replay) do
      [{^replay, {:cached, response}}] ->
        {response, true}

      [{^replay, :uncached}] ->
        fresh(state, boundary, scenario, args, sequence)

      [{^replay, {:in_flight, owner}}] ->
        if await_replay(state, replay, owner) == :settled,
          do: provide(state, boundary, scenario, args, sequence, key),
          else: fresh(state, boundary, scenario, args, sequence)

      [] ->
        claim(state, boundary, scenario, args, sequence, key, replay)
    end
  end

  defp provide(state, boundary, scenario, args, sequence, _key),
    do: {respond(state, boundary, scenario, args, sequence), false}

  # Every claim is charged before it enters the table, so claims, including
  # those of a caller killed mid-response, never exceed the record limit.
  defp claim(state, boundary, scenario, args, sequence, key, replay) do
    cond do
      increment(state.table, {:claims, scenario}) > @maximum_records ->
        fresh(state, boundary, scenario, args, sequence)

      :ets.insert_new(state.table, {replay, {:in_flight, self()}}) ->
        {claimed(state, boundary, scenario, args, sequence, replay), false}

      true ->
        provide(state, boundary, scenario, args, sequence, key)
    end
  end

  defp fresh(state, boundary, scenario, args, sequence) do
    key_not_comparable(state, scenario)
    {respond(state, boundary, scenario, args, sequence), false}
  end

  defp respond(state, boundary, scenario, args, sequence) do
    adapter(state, scenario, boundary, "respond", fn ->
      boundary.respond.(args, %{sequence: sequence})
    end)
  end

  # The claimant's call. If the responder fails, the claim is withdrawn so a
  # later call with the key may claim it again.
  defp claimed(state, boundary, scenario, args, sequence, replay) do
    response = respond(state, boundary, scenario, args, sequence)
    cache(state, scenario, replay, response)
    response
  after
    :ets.delete_object(state.table, {replay, {:in_flight, self()}})
  end

  defp await_replay(state, replay, owner) do
    if owner == self() or owner in Process.get(:"$callers", []),
      do: :unsettled,
      else: poll_replay(state, replay, owner, deadline())
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @replay_wait_milliseconds

  # The entry is read again before a dead owner or the deadline counts as an
  # abandoned claim, because the owner may have cached its response and
  # exited between the first read and the check.
  defp poll_replay(state, replay, owner, deadline) do
    cond do
      not in_flight?(state, replay, owner) ->
        :settled

      Process.alive?(owner) and System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          1 -> poll_replay(state, replay, owner, deadline)
        end

      in_flight?(state, replay, owner) ->
        :unsettled

      true ->
        :settled
    end
  end

  defp in_flight?(state, replay, owner),
    do: :ets.lookup(state.table, replay) == [{replay, {:in_flight, owner}}]

  # Each cached response is within the fingerprint budget and all are within
  # the replay byte limit, so a response that shares subterms is never copied
  # into the table in full. A response over a limit is marked so a repeat of
  # its key makes the scenario not comparable.
  defp cache(state, scenario, replay, response) do
    bytes =
      if within_fingerprint_budget?(
           [response],
           @maximum_fingerprint_terms,
           @maximum_fingerprint_bytes
         ),
         do: :erlang.external_size(response)

    if bytes != nil and
         :ets.update_counter(
           state.table,
           {:replay_bytes, scenario},
           bytes,
           {{:replay_bytes, scenario}, 0}
         ) <= @maximum_replay_bytes,
       do: :ets.insert(state.table, {replay, {:cached, response}}),
       else: :ets.insert(state.table, {replay, :uncached})
  end

  defp identity(_state, %{effect: nil}, _scenario, _attempt, _args, _response), do: nil

  # An effect outside an attempt (from the fixture, the projection, or work
  # the worker left running) is not attributed to any attempt, so it makes
  # the scenario's counts uncertain rather than silently dropping out.
  defp identity(state, boundary, scenario, attempt, args, response) do
    case adapter(state, scenario, boundary, "effect", fn -> boundary.effect.(args, response) end) do
      nil ->
        nil

      identity ->
        if attempt == 0, do: :ets.insert(state.table, {{:outside_effect, scenario}, true})
        fingerprint({boundary.name, identity}, state.key)
    end
  end

  # An adapter that fails inside a stubbed call is recorded for the scenario
  # and the failure is re-raised to the caller, as a broken stub would be.
  defp adapter(state, scenario, boundary, stage, fun) do
    fun.()
  rescue
    exception ->
      failure(state, scenario, boundary, stage, "error", exception.__struct__)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      failure(state, scenario, boundary, stage, Atom.to_string(kind), nil)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp failure(state, scenario, boundary, stage, kind, exception) do
    entry = Map.put(error(stage, kind, exception), "boundary", boundary.name)
    :ets.insert_new(state.table, {{:failure, scenario}, entry})
  end

  defp record(state, scenario, attempt, boundary, arity, call) do
    order = increment(state.table, {:records, scenario})

    if order <= @maximum_records do
      :ets.insert(
        state.table,
        {{:record, scenario, order}, attempt, boundary.name, arity, call.identity, call.key,
         call.faulted, call.replayed}
      )
    else
      :ets.insert(state.table, {{:truncated, scenario}, true})
    end
  end

  defp recorded(state, scenario) do
    records =
      state.table
      |> :ets.match_object({{:record, scenario, :_}, :_, :_, :_, :_, :_, :_, :_})
      |> Enum.sort_by(fn {{:record, _scenario, order}, _, _, _, _, _, _, _} -> order end)
      |> Enum.map(fn {_order, attempt, name, arity, identity, key, faulted, replayed} ->
        %{
          attempt: attempt,
          boundary: name,
          arity: arity,
          identity: identity,
          key: key,
          faulted: faulted,
          replayed: replayed
        }
      end)

    reached =
      for {{:fault_reached, attempt}, true} <-
            :ets.match_object(state.table, {{:fault_reached, :_}, :_}),
          into: MapSet.new(),
          do: attempt

    failure =
      case :ets.lookup(state.table, {:failure, scenario}) do
        [{_key, entry}] -> entry
        [] -> nil
      end

    %{
      records: records,
      truncated: :ets.member(state.table, {:truncated, scenario}),
      key_not_comparable: :ets.member(state.table, {:key_not_comparable, scenario}),
      outside_effect: :ets.member(state.table, {:outside_effect, scenario}),
      fault_reached: if(scenario == :fault, do: reached, else: MapSet.new()),
      failure: failure
    }
  end

  ## Fingerprints

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
  # undercounts the serialized size. A function's environment is invisible to
  # this walk, so functions are never fingerprinted.
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
    # `:maps.to_list/1`, unlike `Enum`, also walks structs.
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

  # Per boundary: distinct known effect identities in the scenario's attempts,
  # how many the committed references point to, and the idempotency keys.
  defp statistics(plan, scenario) do
    for boundary <- plan.boundaries do
      records = Enum.filter(scenario.records, &(&1.boundary == boundary.name and &1.attempt > 0))
      identities = for record <- records, record.identity != nil, do: record.identity
      known = identities |> Enum.filter(&is_binary/1) |> Enum.uniq()
      keys = for record <- records, record.key != nil, do: record.key

      referenced =
        if boundary.effect != nil and scenario.references,
          do: Enum.count(known, &MapSet.member?(scenario.references.known, &1))

      %{
        boundary: boundary,
        distinct: if(boundary.effect, do: length(known)),
        unknown: Enum.count(identities, &(&1 == :unknown)),
        referenced: referenced,
        orphaned: if(boundary.referenced and referenced, do: length(known) - referenced),
        calls_with_key: if(boundary.key, do: length(keys)),
        distinct_keys:
          if(boundary.key, do: keys |> Enum.filter(&is_binary/1) |> Enum.uniq() |> length())
      }
    end
  end

  defp control_health(plan, control) do
    statistics = statistics(plan, control)

    cond do
      control.error ->
        failure_reason(control.error)

      control.truncated ->
        "recorder_truncated"

      not converged?(control) ->
        "control_did_not_succeed"

      fault_point_calls(plan, control) < plan.fault.call ->
        "control_fault_point_not_reached"

      control.key_not_comparable ->
        "key_not_comparable"

      control.outside_effect ->
        "effect_outside_attempt"

      not_comparable?(control, statistics) ->
        "effect_not_comparable"

      Enum.any?(statistics, &(&1.distinct != &1.boundary.expect)) ->
        "control_effect_count_mismatch"

      Enum.any?(statistics, &(&1.orphaned not in [nil, 0])) ->
        "control_orphaned_effect"

      true ->
        nil
    end
  end

  defp fault_point_calls(plan, control),
    do: Enum.count(control.records, &(&1.attempt == 1 and &1.boundary == plan.fault.boundary))

  defp converged?(%{attempts: []}), do: false
  defp converged?(%{attempts: attempts}), do: List.last(attempts).succeeded == true

  defp not_comparable?(scenario, statistics) do
    Enum.any?(statistics, &(&1.unknown > 0)) or
      (scenario.references != nil and scenario.references.unknown > 0)
  end

  defp failure_reason(%{"stage" => stage}), do: stage <> "_failed"

  defp fault_verdict(plan, run, statistics) do
    confirmed = confirmed_reasons(run, statistics)

    cond do
      run.error -> {"not_observed", [failure_reason(run.error)]}
      fault_unreached?(plan, run) -> {"not_observed", ["fault_not_reached"]}
      # A key that could not be replayed may have manufactured a repeat.
      run.key_not_comparable -> {"not_observed", ["key_not_comparable"]}
      # An effect outside an attempt may be one this run's counts miss.
      run.outside_effect -> {"not_observed", ["effect_outside_attempt"]}
      confirmed != [] -> {"confirmed", confirmed}
      run.truncated -> {"not_observed", ["recorder_truncated"]}
      not_comparable?(run, statistics) -> {"not_observed", ["effect_not_comparable"]}
      not converged?(run) -> {"not_observed", ["retry_did_not_succeed"]}
      true -> {"not_reproduced", ["converged_once"]}
    end
  end

  # Orphans and repeats are lower bounds, so they hold under truncation; a
  # missing effect needs the complete record.
  defp confirmed_reasons(run, statistics) do
    effects = Enum.filter(statistics, &(&1.boundary.effect != nil))

    orphaned = Enum.any?(effects, &(&1.orphaned not in [nil, 0]))
    repeated = Enum.any?(effects, &(&1.distinct > &1.boundary.expect))

    missing =
      converged?(run) and not run.truncated and not not_comparable?(run, statistics) and
        Enum.any?(effects, fn entry ->
          made = if entry.boundary.referenced, do: entry.referenced, else: entry.distinct
          made < entry.boundary.expect
        end)

    for {true, reason} <- [
          {orphaned, "orphaned_effect"},
          {repeated, "repeated_effect"},
          {missing, "missing_effect"}
        ],
        do: reason
  end

  defp fault_unreached?(plan, run) do
    Enum.any?(run.attempts, fn tried ->
      tried.attempt <= plan.fault.attempts and
        not MapSet.member?(run.fault_reached, tried.attempt)
    end)
  end

  ## Report

  defp complete(plan, control, fault_run) do
    statistics = statistics(plan, fault_run)
    {verdict, reasons} = fault_verdict(plan, fault_run, statistics)
    labels = labels([control, fault_run])
    control_entry = scenario_entry(plan, :control, control, labels, nil, [])
    fault_entry = scenario_entry(plan, :fault, fault_run, labels, verdict, reasons)
    truncated = control_entry["truncated"] or fault_entry["truncated"]

    report(plan, %{
      "completeness" => if(truncated, do: "truncated", else: "complete"),
      "outcome" => verdict,
      "reason" => nil,
      "error" => nil,
      "control" => control_entry,
      "fault_run" => fault_entry
    })
  end

  defp failed(plan, reason, error, control) do
    control_entry =
      case control do
        nil ->
          nil

        {scenario, cause} ->
          scenario_entry(plan, :control, scenario, labels([scenario]), nil, [cause])
      end

    report(plan, %{
      "completeness" => "infrastructure_failure",
      "outcome" => "infrastructure_failure",
      "reason" => reason,
      "error" => error,
      "control" => control_entry,
      "fault_run" => nil
    })
  end

  # Per-run labels for effect identity and key fingerprints, in first-seen
  # order: `e1`, `e2`, ... and `k1`, `k2`, ...
  defp labels(scenarios) do
    Enum.reduce(scenarios, {%{}, %{}}, fn scenario, labels ->
      Enum.reduce(scenario.records, labels, fn record, {identities, keys} ->
        {add_label(identities, record.identity, "e"), add_label(keys, record.key, "k")}
      end)
    end)
  end

  defp add_label(labels, value, prefix) when is_binary(value) and not is_map_key(labels, value),
    do: Map.put(labels, value, prefix <> Integer.to_string(map_size(labels) + 1))

  defp add_label(labels, _value, _prefix), do: labels

  defp shown(nil, _labels), do: nil
  defp shown(:unknown, _labels), do: "unknown"
  defp shown(fingerprint, labels), do: Map.fetch!(labels, fingerprint)

  defp scenario_entry(plan, name, scenario, {identities, keys}, verdict, reasons) do
    effects =
      for record <- scenario.records, record.attempt > 0, record.identity != nil do
        %{
          "boundary" => record.boundary,
          "attempt" => record.attempt,
          "effect" => shown(record.identity, identities),
          "key" => shown(record.key, keys),
          "referenced" => referenced(scenario.references, record.identity),
          "replayed" => record.replayed,
          "lost_response" => record.faulted
        }
      end

    listed = Enum.take(effects, @maximum_listed_effects)

    %{
      "attempted" => scenario.attempted,
      "error" => scenario.error,
      "attempts" => Enum.map(scenario.attempts, &attempt_entry(plan, name, scenario, &1)),
      "outside_attempt_calls" => Enum.count(scenario.records, &(&1.attempt == 0)),
      "effects" => listed,
      "boundaries" => Enum.map(statistics(plan, scenario), &statistics_entry/1),
      "references" => references_entry(scenario.references),
      "converged" => converged?(scenario),
      "truncated" => scenario.truncated or length(listed) < length(effects),
      "verdict" => verdict,
      "reasons" => reasons
    }
  end

  defp referenced(nil, _identity), do: nil
  defp referenced(_references, :unknown), do: nil
  defp referenced(references, identity), do: MapSet.member?(references.known, identity)

  defp attempt_entry(plan, name, scenario, tried) do
    faulted = name == :fault and tried.attempt <= plan.fault.attempts

    calls =
      scenario.records
      |> Enum.filter(&(&1.attempt == tried.attempt))
      |> Enum.group_by(& &1.boundary, &Integer.to_string(&1.arity))
      |> Map.new(fn {boundary, arities} -> {boundary, Enum.frequencies(arities)} end)

    %{
      "attempt" => tried.attempt,
      "faulted" => faulted,
      "fault_reached" => if(faulted, do: MapSet.member?(scenario.fault_reached, tried.attempt)),
      "result" => tried.result,
      "succeeded" => tried.succeeded,
      "calls" => calls
    }
  end

  defp statistics_entry(entry) do
    %{
      "boundary" => entry.boundary.name,
      "expected" => entry.boundary.expect,
      "distinct_effects" => entry.distinct,
      "effects_not_comparable" => entry.unknown,
      "referenced_effects" => entry.referenced,
      "orphaned_effects" => entry.orphaned,
      "calls_with_key" => entry.calls_with_key,
      "distinct_keys" => entry.distinct_keys
    }
  end

  defp references_entry(nil), do: nil

  defp references_entry(references),
    do: %{"distinct" => MapSet.size(references.known), "not_comparable" => references.unknown}

  defp invalid(reason, declaration) do
    {operation, context} = echo(declaration)

    base(operation, context)
    |> Map.merge(%{
      "completeness" => "infrastructure_failure",
      "outcome" => "infrastructure_failure",
      "reason" => reason,
      "error" => nil,
      "boundaries" => [],
      "fault" => nil,
      "control" => nil,
      "fault_run" => nil
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

  defp report(plan, fields) do
    plan.operation
    |> base(plan.context)
    |> Map.merge(%{
      "boundaries" => Enum.map(plan.boundaries, &boundary_entry/1),
      "fault" => fault_entry(plan.fault)
    })
    |> Map.merge(fields)
  end

  defp boundary_entry(boundary) do
    %{
      "name" => boundary.name,
      "function" => inspect(boundary.module) <> "." <> Atom.to_string(boundary.function),
      "arities" => boundary.arities,
      "effect" => boundary.effect != nil,
      "expected" => boundary.expect,
      "referenced" => boundary.referenced,
      "key" => boundary.key != nil
    }
  end

  defp fault_entry(fault) do
    {result, exception} =
      case fault.result do
        {:return, _value} -> {"return", nil}
        {:raise, exception} -> {"raise", inspect(exception.__struct__)}
      end

    %{
      "boundary" => fault.boundary,
      "call" => fault.call,
      "attempts" => fault.attempts,
      "result" => result,
      "exception" => exception,
      "lost_response" => fault.lost_response
    }
  end

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
      "operation_byte_limit" => @maximum_operation_bytes,
      "context_byte_limit" => @maximum_context_bytes,
      "boundary_limit" => @maximum_boundaries,
      "arity_limit" => @maximum_arity,
      "attempt_limit" => @maximum_attempts,
      "fault_call_limit" => @maximum_fault_call,
      "expected_effect_limit" => @maximum_expected_effects,
      "record_limit" => @maximum_records,
      "listed_effect_limit" => @maximum_listed_effects,
      "reference_limit" => @maximum_references,
      "replay_byte_limit" => @maximum_replay_bytes,
      "replay_wait_millisecond_limit" => @replay_wait_milliseconds,
      "fingerprint_value_byte_limit" => @maximum_fingerprint_bytes,
      "fingerprint_term_limit" => @maximum_fingerprint_terms
    }

  defp limitations,
    do: [
      "fault_and_expected_effects_are_caller_declared",
      "only_declared_boundaries_are_recorded",
      "provider_responses_are_caller_simulated",
      "retries_are_direct_reruns_without_queue_semantics",
      "references_are_the_caller_projection_only",
      "fingerprints_comparable_within_call_only",
      "attempts_run_in_the_calling_process_under_its_test_timeout",
      "stubs_stay_installed_until_the_test_ends",
      "context_is_caller_supplied_and_unverified",
      "caller_must_bind_test_and_revision"
    ]

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
