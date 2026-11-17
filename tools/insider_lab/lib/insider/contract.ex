defmodule Insider.Contract do
  @moduledoc """
  Compile-time semantic contracts with bounded, policy-authorized callback execution.

  Discovery returns portable metadata. Invocation results are local evidence and
  must pass through the redaction boundary before they leave the runtime.
  """

  alias Insider.Contract.Definition
  alias Insider.Contract.Executor
  alias Insider.Contract.Invocation
  alias Insider.Event.Canonical
  alias Insider.Event.Value, as: EventValue
  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Value

  @kinds [:identity, :observation, :invariant, :action, :reset]
  @sensitivities [:public, :internal, :confidential, :secret]
  @environments [:development, :test, :ci]
  @maximum_declarations 64
  @maximum_owners 64
  @maximum_arguments 8
  @maximum_input_bytes 65_536
  @default_timeout_ms 100
  @maximum_timeout_ms 5_000
  @cleanup_reserve_ms 50
  # The least time a caller gives the executor to confirm that a runner
  # which sent its final result is gone (`finish_awaited_result/8`).
  @release_floor_ms 500
  @definition_function :__insider_contract__

  defmacro __using__(options) do
    {id, version} = contract_options!(__CALLER__, options)

    quote do
      import Insider.Contract,
        only: [identity: 2, observe: 2, invariant: 2, action: 2, reset: 2, owns: 1]

      Module.register_attribute(__MODULE__, :insider_contract_declarations, accumulate: true)
      Module.register_attribute(__MODULE__, :insider_contract_owners, accumulate: true)
      @insider_contract_id unquote(id)
      @insider_contract_version unquote(version)
      @before_compile Insider.Contract
    end
  end

  defmacro identity(name, options),
    do: declaration!(__CALLER__, :identity, name, options, :from, false)

  defmacro observe(name, options),
    do: declaration!(__CALLER__, :observation, name, options, :with, false)

  defmacro invariant(name, options),
    do: declaration!(__CALLER__, :invariant, name, options, :check, false)

  defmacro action(name, options),
    do: declaration!(__CALLER__, :action, name, options, :with, true)

  defmacro reset(name, options),
    do: declaration!(__CALLER__, :reset, name, options, :with, true)

  defmacro owns(options) do
    env = __CALLER__

    unless is_list(options) and Keyword.keyword?(options) and Keyword.keys(options) == [:modules] do
      compile_error!(env, "owns expects exactly modules: [Module, ...]")
    end

    modules = options |> Keyword.fetch!(:modules) |> expand_modules!(env)

    quote bind_quoted: [modules: modules] do
      Enum.each(modules, &Module.put_attribute(__MODULE__, :insider_contract_owners, &1))
    end
  end

  defmacro __before_compile__(env) do
    reserve_generated_functions!(env)

    declarations =
      env.module
      |> Module.get_attribute(:insider_contract_declarations)
      |> Enum.reverse()

    ownership =
      env.module
      |> Module.get_attribute(:insider_contract_owners)
      |> Enum.reverse()
      |> Enum.uniq()

    validate_counts!(env, declarations, ownership)
    validate_duplicates!(env, declarations)

    id = Module.get_attribute(env.module, :insider_contract_id)
    version = Module.get_attribute(env.module, :insider_contract_version)
    {portable, fingerprint} = portable_definition(id, version, declarations, ownership)

    unless EventValue.valid?(portable, 16_384),
      do: compile_error!(env, "portable contract definition exceeds its bound")

    definition = %Definition{
      module: env.module,
      id: id,
      version: version,
      fingerprint: fingerprint,
      declarations: Enum.map(declarations, &Map.delete(&1, :callback)),
      ownership: ownership,
      portable: portable
    }

    clauses = Enum.map(declarations, &dispatch_clause/1)

    quote do
      @doc false
      def unquote(@definition_function)(), do: unquote(Macro.escape(definition))

      @doc false
      unquote_splicing(clauses)

      @doc false
      def __insider_contract_dispatch__(_kind, _name, _arguments),
        do: raise(ArgumentError, "undeclared contract callback")
    end
  end

  @spec describe(module()) :: {:ok, map()} | {:error, Error.t()}
  def describe(module) when is_atom(module) do
    case definition(module) do
      {:ok, contract} -> {:ok, contract.portable}
      {:error, error} -> {:error, error}
    end
  end

  def describe(_module), do: {:error, invalid_request("contract module is invalid")}

  @spec list([module()]) :: {:ok, [map()]} | {:error, Error.t()}
  def list(modules) do
    with true <- Value.bounded_list?(modules, @maximum_declarations),
         true <- Enum.all?(modules, &is_atom/1),
         {:ok, descriptions} <- map_descriptions(modules),
         true <- unique_contract_identities?(descriptions) do
      {:ok, Enum.sort_by(descriptions, &{&1["id"], &1["version"]})}
    else
      _error ->
        {:error,
         invalid_request("contract list must contain at most 64 modules with unique identities")}
    end
  end

  @spec invoke(module(), atom(), atom() | String.t(), list(), keyword()) :: Invocation.t()
  def invoke(module, kind, name, arguments, options \\ []),
    do: invoke(Executor, module, kind, name, arguments, options)

  @spec invoke(
          Supervisor.supervisor(),
          module(),
          atom(),
          atom() | String.t(),
          list(),
          keyword()
        ) :: Invocation.t()
  def invoke(executor, module, kind, name, arguments, options) do
    started_at = System.monotonic_time(:microsecond)

    with {:ok, contract} <- definition(module),
         {:ok, normalized_name} <- declaration_name(name),
         {:ok, declaration} <- find_declaration(contract, kind, normalized_name),
         :ok <- validate_arguments(arguments, declaration),
         {:ok, request, context, requested_timeout} <- invocation_options(options),
         {:ok, decision} <- authorize(kind, declaration, request, context),
         {:ok, timeout_ms} <- effective_timeout(requested_timeout, decision),
         true <- Policy.dispatchable?(decision),
         {:ok, token} <-
           admit(
             executor,
             contract,
             declaration,
             arguments,
             timeout_ms,
             decision.dispatch_deadline_monotonic,
             started_at
           ) do
      await_result(
        executor,
        token,
        timeout_ms,
        decision.dispatch_deadline_monotonic,
        contract,
        declaration,
        started_at
      )
    else
      {:error, %Invocation{} = result} ->
        result

      {:error, {:executor_unavailable, %Error{} = error}} ->
        preflight_result(module, kind, name, error, started_at, :executor_unavailable)

      {:error, %Error{} = error} ->
        preflight_result(module, kind, name, error, started_at)

      false ->
        preflight_result(module, kind, name, policy_error(), started_at)
    end
  end

  defp admit(
         executor,
         contract,
         declaration,
         arguments,
         timeout_ms,
         dispatch_deadline_monotonic,
         started_at
       ) do
    token = make_ref()

    invocation = %{
      caller: self(),
      token: token,
      module: contract.module,
      contract: contract,
      declaration: declaration,
      kind: declaration.kind,
      name: declaration.name,
      args: arguments,
      timeout_ms: timeout_ms,
      dispatch_deadline_monotonic: dispatch_deadline_monotonic,
      started_at: started_at
    }

    case Executor.admit(executor, invocation) do
      {:ok, runner} ->
        {:ok, {token, runner}}

      {:error, :max_children} ->
        {:error, overload_result(contract, declaration, started_at)}

      {:error, {:max_children, _detail}} ->
        {:error, overload_result(contract, declaration, started_at)}

      {:error, _reason} ->
        {:error, {:executor_unavailable, operation_error("contract executor is unavailable")}}
    end
  catch
    :exit, _reason ->
      {:error, {:executor_unavailable, operation_error("contract executor is unavailable")}}
  end

  defp await_result(
         executor,
         {token, runner},
         timeout_ms,
         dispatch_deadline,
         contract,
         declaration,
         started_at
       ) do
    monitor = Process.monitor(runner)

    receive do
      {^token, %Invocation{} = result} ->
        finish_awaited_result(
          executor,
          runner,
          monitor,
          result,
          dispatch_deadline,
          contract,
          declaration,
          started_at
        )

      {:DOWN, ^monitor, :process, ^runner, _reason} ->
        invocation_result(contract, declaration, :error, started_at,
          reason: :executor_failed,
          error: operation_error("contract executor failed"),
          cleanup: %{status: :uncertain},
          uncertainty:
            ["contract callback worker termination is not confirmed"] ++
              mutation_uncertainty(declaration)
        )
    after
      timeout_ms + 1_000 ->
        Process.exit(runner, :kill)

        invocation_result(contract, declaration, :timeout, started_at,
          reason: :deadline_exceeded,
          error: Error.new(:deadline_exceeded, "contract executor exceeded its deadline"),
          cleanup: %{status: :uncertain},
          uncertainty:
            ["contract runner termination is not confirmed"] ++
              mutation_uncertainty(declaration)
        )
    end
  end

  defp finish_awaited_result(
         _executor,
         _runner,
         monitor,
         %Invocation{cleanup: %{status: :uncertain}} = result,
         _dispatch_deadline,
         _contract,
         _declaration,
         _started_at
       ) do
    Process.demonitor(monitor, [:flush])
    result
  end

  # A runner stops as soon as it has sent its final result. The caller
  # returns only after the executor confirms that the runner is gone, so the
  # runner's capacity is free when the caller returns. The runner's own DOWN
  # is not enough: the executor may not yet have handled the runner's exit.
  # The release has at least @release_floor_ms, also when the caller handles
  # the result after the dispatch deadline (under load, or when it monitored
  # the runner only after its exit). With the time left before the deadline
  # alone, a late caller had 0 ms, and a deadline result became
  # `:executor_failed`.
  defp finish_awaited_result(
         executor,
         runner,
         monitor,
         result,
         dispatch_deadline,
         contract,
         declaration,
         started_at
       ) do
    release_timeout =
      max(@release_floor_ms, dispatch_deadline - System.monotonic_time(:millisecond))

    awaited =
      release(executor, runner, release_timeout, result, contract, declaration, started_at)

    Process.demonitor(monitor, [:flush])
    awaited
  end

  defp release(executor, runner, release_timeout, result, contract, declaration, started_at) do
    case Executor.release(executor, runner, release_timeout) do
      :ok ->
        result

      {:error, _reason} ->
        invocation_result(contract, declaration, :error, started_at,
          reason: :executor_failed,
          error: operation_error("contract executor failed to release completed work"),
          cleanup: %{status: :uncertain},
          uncertainty:
            ["contract runner termination is not confirmed"] ++
              mutation_uncertainty(declaration)
        )
    end
  end

  defp authorize(kind, declaration, %Request{} = request, %Context{} = context) do
    expected_operation = expected_operation(kind)

    cond do
      request.operation not in expected_operation ->
        {:error, policy_error()}

      request.target != %{node: Atom.to_string(node())} ->
        {:error, policy_error()}

      kind in [:action, :reset] and context.environment not in declaration.environments ->
        {:error, policy_error()}

      true ->
        Policy.authorize(request, context)
    end
  end

  defp expected_operation(:identity),
    do: ["contract.observe", "scenario.run", "verification.run"]

  defp expected_operation(:observation),
    do: ["contract.observe", "scenario.run", "verification.run"]

  defp expected_operation(:invariant),
    do: ["contract.check", "scenario.run", "verification.run"]

  defp expected_operation(kind) when kind in [:action, :reset],
    do: ["scenario.run", "verification.run"]

  defp effective_timeout(requested, decision) do
    now = System.monotonic_time(:millisecond)
    remaining = decision.dispatch_deadline_monotonic - now - @cleanup_reserve_ms
    policy_limit = Map.get(decision.effective_limits, :max_duration_ms, requested)
    timeout = min(min(requested, policy_limit), remaining)

    if timeout > 0, do: {:ok, timeout}, else: {:error, policy_error()}
  end

  defp invocation_options(options) do
    valid_keys = [:request, :context, :timeout_ms]

    with true <- is_list(options) and Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- valid_keys,
         %Request{} = request <- Keyword.get(options, :request),
         %Context{} = context <- Keyword.get(options, :context),
         true <- valid_request?(request) and Context.valid?(context),
         timeout when is_integer(timeout) and timeout in 1..@maximum_timeout_ms <-
           Keyword.get(options, :timeout_ms, min(request.timeout_ms, @default_timeout_ms)) do
      {:ok, request, context, timeout}
    else
      _error -> {:error, policy_error()}
    end
  end

  defp valid_request?(%Request{} = request) do
    request.schema == "insider.request/v1" and request.protocol == "insider.protocol/v1" and
      is_binary(request.request_id) and byte_size(request.request_id) in 1..256 and
      request.environment in [:development, :test, :ci, :staging, :production] and
      is_integer(request.timeout_ms) and request.timeout_ms > 0 and
      is_integer(request.deadline_monotonic) and match?(%Budget{}, request.budget) and
      Budget.new(Map.from_struct(request.budget)) == {:ok, request.budget} and
      is_map(request.params) and Value.bounded_data?(request.params, request.budget.max_bytes)
  end

  defp validate_arguments(arguments, declaration) do
    if Value.bounded_list?(arguments, @maximum_arguments) and
         length(arguments) == declaration.arity and
         Value.bounded_data?(arguments, @maximum_input_bytes) do
      :ok
    else
      {:error, invalid_request("contract callback arguments are invalid or oversized")}
    end
  end

  defp find_declaration(contract, kind, name) when kind in @kinds do
    case Enum.find(contract.declarations, &(&1.kind == kind and &1.name == name)) do
      nil -> {:error, invalid_request("contract callback is not declared")}
      declaration -> {:ok, declaration}
    end
  end

  defp find_declaration(_contract, _kind, _name),
    do: {:error, invalid_request("contract callback kind is invalid")}

  defp definition(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, @definition_function, 0) do
      case apply(module, @definition_function, []) do
        %Definition{module: ^module} = definition ->
          if valid_definition?(definition),
            do: {:ok, definition},
            else: {:error, invalid_request("contract definition is invalid")}

        _invalid ->
          {:error, invalid_request("contract definition is invalid")}
      end
    else
      {:error, invalid_request("module does not expose an Insider contract")}
    end
  rescue
    _error -> {:error, invalid_request("contract definition is invalid")}
  end

  defp definition(_module), do: {:error, invalid_request("contract module is invalid")}

  defp valid_definition?(definition) do
    with true <- vocabulary?(definition.id),
         true <- is_integer(definition.version) and definition.version in 1..1_000_000,
         true <- Value.bounded_list?(definition.declarations, @maximum_declarations),
         true <- Enum.all?(definition.declarations, &valid_declaration?/1),
         true <- unique_declarations?(definition.declarations),
         true <- Value.bounded_list?(definition.ownership, @maximum_owners),
         true <- Enum.all?(definition.ownership, &is_atom/1),
         true <- Enum.uniq(definition.ownership) == definition.ownership,
         {portable, fingerprint} <-
           portable_definition(
             definition.id,
             definition.version,
             definition.declarations,
             definition.ownership
           ) do
      definition.fingerprint == fingerprint and definition.portable == portable and
        EventValue.valid?(portable, 16_384)
    else
      _error -> false
    end
  rescue
    _error -> false
  end

  defp valid_declaration?(declaration) when is_map(declaration) do
    Map.keys(declaration) |> Enum.sort() ==
      Enum.sort([:arity, :environments, :kind, :name, :sensitivity]) and
      declaration.kind in @kinds and vocabulary?(declaration.name) and
      is_integer(declaration.arity) and declaration.arity in 0..@maximum_arguments and
      declaration.sensitivity in @sensitivities and
      valid_declaration_environments?(declaration.kind, declaration.environments)
  end

  defp valid_declaration?(_declaration), do: false

  defp unique_declarations?(declarations) do
    declarations
    |> Enum.map(&{declaration_class(&1.kind), &1.name})
    |> then(&(Enum.uniq(&1) == &1))
  end

  defp valid_declaration_environments?(kind, environments) when kind in [:action, :reset],
    do:
      is_list(environments) and environments != [] and Enum.uniq(environments) == environments and
        Enum.all?(environments, &(&1 in @environments))

  defp valid_declaration_environments?(_kind, environments), do: environments == []

  defp map_descriptions(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, descriptions} ->
      case describe(module) do
        {:ok, description} -> {:cont, {:ok, [description | descriptions]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp unique_contract_identities?(descriptions) do
    identities = Enum.map(descriptions, &{&1["id"], &1["version"]})
    Enum.uniq(identities) == identities
  end

  defp preflight_result(module, kind, name, error, started_at, reason \\ nil) do
    contract =
      case definition(module) do
        {:ok, definition} -> definition
        {:error, _error} -> unknown_definition()
      end

    declaration = %{
      kind: if(kind in @kinds, do: kind, else: :observation),
      name: safe_name(name),
      sensitivity: :internal
    }

    invocation_result(contract, declaration, :error, started_at,
      reason: reason || reason_for_error(error),
      error: error
    )
  end

  defp overload_result(contract, declaration, started_at) do
    invocation_result(contract, declaration, :overloaded, started_at,
      reason: :executor_overloaded,
      error:
        Error.new(:operation_failed, "contract executor is at capacity", %{}, retryable: true)
    )
  end

  defp invocation_result(contract, declaration, status, started_at, options) do
    %Invocation{
      schema: "insider.contract-invocation/v1",
      contract: %{
        "id" => contract.id,
        "version" => contract.version,
        "fingerprint" => contract.fingerprint
      },
      kind: declaration.kind,
      name: declaration.name,
      status: status,
      reason: Keyword.get(options, :reason, invocation_reason(status)),
      value: Keyword.get(options, :value),
      sensitivity: declaration.sensitivity,
      error: Keyword.get(options, :error),
      duration_us: max(0, System.monotonic_time(:microsecond) - started_at),
      cleanup: Keyword.get(options, :cleanup, %{status: :not_required}),
      warnings: [],
      uncertainty: Keyword.get(options, :uncertainty, [])
    }
  end

  defp unknown_definition do
    %Definition{
      module: __MODULE__,
      id: "unknown",
      version: 1,
      fingerprint: "unknown",
      declarations: [],
      ownership: [],
      portable: %{}
    }
  end

  defp operation_error(message), do: Error.new(:operation_failed, message)
  defp policy_error, do: Error.new(:policy_denied, "contract invocation is not authorized")
  defp invalid_request(message), do: Error.new(:invalid_request, message)

  defp reason_for_error(%Error{code: :invalid_request}), do: :invalid_request
  defp reason_for_error(%Error{code: :policy_denied}), do: :policy_denied
  defp reason_for_error(_error), do: :executor_unavailable

  defp invocation_reason(:overloaded), do: :executor_overloaded
  defp invocation_reason(:timeout), do: :deadline_exceeded
  defp invocation_reason(_status), do: :executor_failed

  defp mutation_uncertainty(%{kind: kind}) when kind in [:action, :reset],
    do: ["contract mutation may have produced external effects; termination is not rollback"]

  defp mutation_uncertainty(_declaration), do: []

  defp contract_options!(env, options) do
    unless is_list(options) and Keyword.keyword?(options) do
      compile_error!(env, "contract options must be a keyword list")
    end

    option_keys = Keyword.keys(options)

    if option_keys -- [:id, :version] != [] or Enum.uniq(option_keys) != option_keys,
      do: compile_error!(env, "unknown or duplicate contract option")

    id = options |> Keyword.get(:id, default_id(env.module)) |> literal!(env)
    version = options |> Keyword.get(:version, 1) |> literal!(env)

    unless vocabulary?(id), do: compile_error!(env, "contract id is invalid")

    unless is_integer(version) and version in 1..1_000_000,
      do: compile_error!(env, "contract version is invalid")

    {id, version}
  end

  defp declaration!(env, kind, name_ast, options, callback_key, environments?) do
    name = name_ast |> literal!(env) |> normalize_declaration_name!(env)

    unless is_list(options) and Keyword.keyword?(options) do
      compile_error!(env, "contract declaration options must be a keyword list")
    end

    allowed = [callback_key, :sensitivity] ++ if(environments?, do: [:environments], else: [])
    option_keys = Keyword.keys(options)
    unknown = option_keys -- allowed

    if unknown != [] or Enum.uniq(option_keys) != option_keys or
         not Keyword.has_key?(options, callback_key) do
      compile_error!(env, "contract declaration contains unknown, duplicate, or missing options")
    end

    callback = Keyword.fetch!(options, callback_key)
    arity = capture_arity!(env, callback)
    sensitivity = options |> Keyword.get(:sensitivity, :internal) |> literal!(env)

    unless sensitivity in @sensitivities,
      do: compile_error!(env, "contract sensitivity is invalid")

    environments =
      if environments? do
        options |> Keyword.get(:environments) |> literal!(env) |> environments!(env)
      else
        []
      end

    declaration = %{
      kind: kind,
      name: name,
      arity: arity,
      sensitivity: sensitivity,
      environments: environments,
      callback: callback
    }

    quote do
      Module.put_attribute(
        __MODULE__,
        :insider_contract_declarations,
        unquote(Macro.escape(declaration))
      )
    end
  end

  defp capture_arity!(env, {:&, _, [{:/, _, [target, arity]}]})
       when is_integer(arity) and arity in 0..@maximum_arguments do
    if named_capture?(target, env),
      do: arity,
      else: compile_error!(env, "callback must be a named local or remote function capture")
  end

  defp capture_arity!(env, _callback),
    do: compile_error!(env, "callback must be a named local or remote function capture")

  defp named_capture?({name, _metadata, context}, _env)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp named_capture?({{:., _, [module_ast, function]}, _, []}, env) when is_atom(function),
    do: is_atom(Macro.expand(module_ast, env))

  defp named_capture?(_target, _env), do: false

  defp dispatch_clause(declaration) do
    kind = declaration.kind
    name = declaration.name
    callback = declaration.callback

    quote do
      def __insider_contract_dispatch__(unquote(kind), unquote(name), arguments),
        do: apply(unquote(callback), arguments)
    end
  end

  defp portable_definition(id, version, declarations, ownership) do
    base = %{
      "schema" => "insider.contract/v1",
      "id" => id,
      "version" => version,
      "identities" => portable_declarations(declarations, :identity),
      "observations" => portable_declarations(declarations, :observation),
      "invariants" => portable_declarations(declarations, :invariant),
      "actions" => portable_declarations(declarations, :action),
      "resets" => portable_declarations(declarations, :reset),
      "ownership" => ownership |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }

    fingerprint =
      "sha256:" <> (:crypto.hash(:sha256, Canonical.encode(base)) |> Base.encode16(case: :lower))

    {Map.put(base, "fingerprint", fingerprint), fingerprint}
  end

  defp portable_declarations(declarations, kind) do
    declarations
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(fn declaration ->
      base = %{
        "name" => declaration.name,
        "arity" => declaration.arity,
        "sensitivity" => Atom.to_string(declaration.sensitivity)
      }

      if kind in [:action, :reset] do
        Map.put(base, "environments", Enum.map(declaration.environments, &Atom.to_string/1))
      else
        base
      end
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp validate_counts!(env, declarations, ownership) do
    if length(declarations) > @maximum_declarations,
      do: compile_error!(env, "contract may declare at most 64 callbacks")

    if length(ownership) > @maximum_owners,
      do: compile_error!(env, "contract may own at most 64 modules")
  end

  defp reserve_generated_functions!(env) do
    for function <- [{@definition_function, 0}, {:__insider_contract_dispatch__, 3}],
        Module.defines?(env.module, function) do
      {name, arity} = function
      compile_error!(env, "#{name}/#{arity} is reserved by Insider.Contract")
    end
  end

  defp validate_duplicates!(env, declarations) do
    declarations
    |> Enum.group_by(&{declaration_class(&1.kind), &1.name})
    |> Enum.find(fn {_key, values} -> Enum.count_until(values, 2) == 2 end)
    |> case do
      nil -> :ok
      {{kind, _name}, _values} -> compile_error!(env, "duplicate #{kind} declaration")
    end
  end

  defp declaration_class(kind) when kind in [:action, :reset], do: :mutation
  defp declaration_class(kind), do: kind

  defp expand_modules!(modules, env) when is_list(modules) do
    expanded = Enum.map(modules, &Macro.expand(&1, env))

    if length(expanded) <= @maximum_owners and Enum.all?(expanded, &is_atom/1),
      do: expanded,
      else: compile_error!(env, "owned modules must be a literal list of aliases")
  end

  defp expand_modules!(_modules, env),
    do: compile_error!(env, "owned modules must be a literal list of aliases")

  defp environments!(environments, env) when is_list(environments) do
    if environments != [] and Enum.uniq(environments) == environments and
         Enum.all?(environments, &(&1 in @environments)) do
      Enum.sort(environments)
    else
      compile_error!(env, "action environments must be unique development, test, or ci values")
    end
  end

  defp environments!(_environments, env),
    do: compile_error!(env, "action environments must be a literal list")

  defp declaration_name(value) when is_atom(value), do: declaration_name(Atom.to_string(value))

  defp declaration_name(value) when is_binary(value) do
    if vocabulary?(value),
      do: {:ok, value},
      else: {:error, invalid_request("contract callback name is invalid")}
  end

  defp declaration_name(_value),
    do: {:error, invalid_request("contract callback name is invalid")}

  defp normalize_declaration_name!(value, env) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_declaration_name!(env)

  defp normalize_declaration_name!(value, env) when is_binary(value) do
    if vocabulary?(value),
      do: value,
      else: compile_error!(env, "contract callback name is invalid")
  end

  defp normalize_declaration_name!(_value, env),
    do: compile_error!(env, "contract callback name must be a literal atom or string")

  defp safe_name(value) when is_atom(value), do: value |> Atom.to_string() |> safe_name()
  defp safe_name(value) when is_binary(value) and byte_size(value) <= 128, do: value
  defp safe_name(_value), do: "invalid"

  defp literal!(value, _env)
       when is_atom(value) or is_binary(value) or is_integer(value) or is_list(value),
       do: value

  defp literal!(_value, env), do: compile_error!(env, "contract values must be literals")

  defp default_id(module) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join(".")
  end

  defp vocabulary?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp compile_error!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)
end
