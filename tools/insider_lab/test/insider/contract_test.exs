defmodule Insider.ContractTest do
  use ExUnit.Case, async: true

  alias Insider.Contract
  alias Insider.Contract.Executor
  alias Insider.Contract.Invocation
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.TestSupport.ExampleContract

  describe "contract discovery" do
    test "describes a versioned contract without exposing modules or callbacks" do
      assert {:ok, description} = Contract.describe(ExampleContract)

      assert %{
               "schema" => "insider.contract/v1",
               "id" => "test.checkout",
               "version" => 2,
               "fingerprint" => "sha256:" <> _digest,
               "identities" => [
                 %{
                   "name" => "checkout",
                   "arity" => 1,
                   "sensitivity" => "internal"
                 }
               ],
               "observations" => [
                 %{
                   "name" => "summary",
                   "arity" => 1,
                   "sensitivity" => "confidential"
                 }
               ],
               "invariants" => [
                 %{
                   "name" => "positive_total",
                   "arity" => 1,
                   "sensitivity" => "internal"
                 }
               ],
               "actions" => [
                 %{
                   "name" => "echo",
                   "arity" => 1,
                   "environments" => ["development", "test"],
                   "sensitivity" => "internal"
                 }
               ],
               "resets" => [
                 %{
                   "name" => "fixture",
                   "arity" => 0,
                   "environments" => ["test"],
                   "sensitivity" => "internal"
                 }
               ],
               "ownership" => ["Elixir.Insider.TestSupport.ExampleContract"]
             } = description

      refute inspect(description) =~ "checkout_id"
      refute inspect(description) =~ "#Function"
    end

    test "lists only explicit modules in deterministic order" do
      assert {:ok, [description]} = Contract.list([ExampleContract])
      assert description["id"] == "test.checkout"

      assert {:error, %Error{code: :invalid_request}} =
               Contract.list(List.duplicate(ExampleContract, 65))

      assert {:error, %Error{code: :invalid_request}} = Contract.list(["not-a-module"])
      assert {:error, %Error{code: :invalid_request}} = Contract.list([String])
      assert {:ok, []} = Contract.list([])
      assert {:error, %Error{code: :invalid_request}} = Contract.describe("not-a-module")
    end

    test "rejects invalid and ambiguous declarations at compile time" do
      assert {:ok, _description} = Contract.describe(ExampleContract)

      assert_raise CompileError, ~r/named local or remote function capture/, fn ->
        Code.compile_string("""
        defmodule Insider.ContractTest.AnonymousCapture do
          use Insider.Contract
          observe :bad, with: fn value -> value end
        end
        """)
      end

      assert_raise CompileError, ~r/duplicate observation declaration/, fn ->
        Code.compile_string("""
        defmodule Insider.ContractTest.DuplicateDeclaration do
          use Insider.Contract
          observe :same, with: &one/0
          observe :same, with: &two/0
          defp one, do: nil
          defp two, do: nil
        end
        """)
      end

      assert_raise CompileError, ~r/unknown or duplicate contract option/, fn ->
        Code.compile_string("""
        defmodule Insider.ContractTest.UnknownOption do
          use Insider.Contract, surprise: true
        end
        """)
      end
    end

    test "applies safe defaults and supports literal remote captures" do
      [{module, _binary}] =
        Code.compile_string("""
        defmodule Insider.ContractTest.DefaultContract do
          use Insider.Contract
          observe :trim, with: &String.trim/1
        end
        """)

      assert {:ok, description} = Contract.describe(module)
      assert description["id"] == "insider.contract_test.default_contract"
      assert description["version"] == 1

      assert [%{"name" => "trim", "arity" => 1}] =
               Enum.map(description["observations"], &Map.take(&1, ["name", "arity"]))
    end

    test "rejects unsafe declaration bounds and vocabularies" do
      assert {:ok, _description} = Contract.describe(ExampleContract)

      for {body, message} <- [
            {"use Insider.Contract, id: \"Bad ID\"", "contract id is invalid"},
            {"use Insider.Contract, version: 0", "contract version is invalid"},
            {"use Insider.Contract\nobserve :bad, with: &bad/9", "named local or remote"},
            {"use Insider.Contract\nobserve :bad, with: &bad/0, sensitivity: :password",
             "sensitivity is invalid"},
            {"use Insider.Contract\naction :bad, with: &bad/0, environments: [:production]",
             "action environments"},
            {"use Insider.Contract\nobserve :bad, with: &bad/0, with: &bad/0",
             "unknown, duplicate, or missing"}
          ] do
        assert_raise CompileError, ~r/#{message}/, fn ->
          Code.compile_string("""
          defmodule Insider.ContractTest.Invalid#{System.unique_integer([:positive])} do
            #{body}
            defp bad(_a, _b, _c, _d, _e, _f, _g, _h, _i), do: nil
            defp bad, do: nil
          end
          """)
        end
      end
    end

    test "reserves generated functions and rejects colliding semantic identities" do
      assert_raise CompileError, ~r/__insider_contract_dispatch__\/3 is reserved/, fn ->
        Code.compile_string("""
        defmodule Insider.ContractTest.ShadowedDispatch do
          use Insider.Contract
          observe :real, with: &real/0
          def __insider_contract_dispatch__(_kind, _name, _arguments), do: "shadowed"
          defp real, do: "real"
        end
        """)
      end

      {:module, first, _binary, _bindings} =
        compile_contract("Collision", "observe :first, with: &first/0", """
        defp first, do: "first"
        """)

      {:module, second, _binary, _bindings} =
        compile_contract("Collision", "observe :second, with: &second/0", """
        defp second, do: "second"
        """)

      assert {:error, %Error{code: :invalid_request}} = Contract.list([first, second])
    end
  end

  describe "bounded isolated invocation" do
    setup context do
      # Ordinary callback assertions use normal executor capacity; lifecycle and
      # overload boundaries explicitly opt into a one-slot executor below.
      max_concurrency = Map.get(context, :executor_capacity, 8)

      start_supervised!({Contract.Executor, name: nil, max_concurrency: max_concurrency})
      |> then(&%{executor: &1})
    end

    test "normalizes identity and distinguishes invariant violations", %{executor: executor} do
      assert %Invocation{status: :ok, reason: :completed, value: subject} =
               invoke(executor, ExampleContract, :identity, :checkout, [
                 %{"id" => "checkout-1"}
               ])

      assert subject == %{
               "namespace" => "test.checkout.checkout.v2",
               "scope" => "tenant-1",
               "value" => "checkout-1"
             }

      assert %Invocation{status: :ok, reason: :completed, value: true} =
               invoke(executor, ExampleContract, :invariant, :positive_total, [
                 %{"total" => 1}
               ])

      assert %Invocation{
               status: :violation,
               reason: :invariant_violated,
               value: false,
               error: nil
             } =
               invoke(executor, ExampleContract, :invariant, :positive_total, [
                 %{"total" => 0}
               ])

      assert %Invocation{status: :ok, value: %{"summary" => "ready"}} =
               invoke(executor, ExampleContract, :observation, :summary, ["ready"])

      assert %Invocation{status: :ok, value: %{"reset" => true}} =
               invoke(executor, ExampleContract, :reset, :fixture, [], environment: :test)
    end

    @tag executor_capacity: 1
    test "completed callbacks release executor capacity before returning", %{executor: executor} do
      Enum.each(1..10_000, fn iteration ->
        assert %Invocation{status: :ok, value: %{"summary" => value}} =
                 invoke(executor, ExampleContract, :observation, :summary, [iteration])

        assert value == iteration
        assert %{active: 0} = DynamicSupervisor.count_children(executor)
      end)
    end

    @tag executor_capacity: 1
    test "completed-runner release is bounded by the caller deadline", %{executor: executor} do
      child_spec =
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}

      {:ok, child} = DynamicSupervisor.start_child(executor, child_spec)

      :ok = :sys.suspend(executor)

      try do
        assert {:error, :release_timeout} = Executor.release(executor, child, 0)
      after
        :ok = :sys.resume(executor)
      end

      assert :ok = Executor.release(executor, child, 1_000)
      assert %{active: 0} = DynamicSupervisor.count_children(executor)
    end

    test "rejects undeclared callbacks, arity mismatches, and oversized input", %{
      executor: executor
    } do
      assert %Invocation{
               status: :error,
               reason: :invalid_request,
               error: %Error{code: :invalid_request}
             } =
               invoke(executor, ExampleContract, :observation, :missing, [])

      assert %Invocation{status: :error, error: %Error{code: :invalid_request}} =
               invoke(executor, ExampleContract, :observation, :summary, [])

      assert %Invocation{status: :error, error: %Error{code: :invalid_request}} =
               invoke(executor, ExampleContract, :observation, :summary, [
                 String.duplicate("x", 65_536)
               ])
    end

    test "returns fixed errors without leaking callback exceptions or oversized output", %{
      executor: executor
    } do
      {:module, failure_contract, _binary, _bindings} =
        compile_contract("Failure", "observe :explode, with: &explode/0", """
        defp explode, do: raise("do-not-leak-secret")
        """)

      assert %Invocation{
               status: :error,
               reason: :callback_exception,
               error: %Error{code: :operation_failed} = error
             } = invoke(executor, failure_contract, :observation, :explode, [])

      refute inspect(error) =~ "do-not-leak-secret"

      {:module, large_contract, _binary, _bindings} =
        compile_contract("Large", "observe :large, with: &large/0", """
        defp large, do: %{"value" => String.duplicate("x", 20_000)}
        """)

      assert %Invocation{
               status: :error,
               reason: :invalid_callback_output,
               error: %Error{code: :operation_failed}
             } =
               invoke(executor, large_contract, :observation, :large, [])

      {:module, invalid_invariant, _binary, _bindings} =
        compile_contract("InvalidInvariant", "invariant :bad, check: &bad/0", """
        defp bad, do: "not-a-boolean"
        """)

      assert %Invocation{
               status: :error,
               reason: :invalid_callback_output,
               error: %Error{code: :operation_failed}
             } =
               invoke(executor, invalid_invariant, :invariant, :bad, [])

      {:module, identity_contract, _binary, _bindings} =
        compile_contract("Identity", "identity :plain, from: &plain/1", """
        defp plain(value), do: value
        """)

      assert %Invocation{status: :ok, value: %{"scope" => nil, "value" => "plain-1"}} =
               invoke(executor, identity_contract, :identity, :plain, ["plain-1"])

      assert %Invocation{status: :error, error: %Error{code: :operation_failed}} =
               invoke(executor, identity_contract, :identity, :plain, [123])

      {:module, failed_action, _binary, _bindings} =
        compile_contract(
          "FailedAction",
          "action :explode, with: &explode/0, environments: [:test]",
          """
          defp explode, do: raise("mutation-secret")
          """
        )

      assert %Invocation{
               status: :error,
               uncertainty: ["contract mutation may have produced external effects" <> _rest]
             } = invoke(executor, failed_action, :action, :explode, [], environment: :test)
    end

    test "ordinary callback tests are independent of the overload boundary", %{
      executor: executor
    } do
      Process.register(self(), :insider_contract_capacity_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract("Capacity", "observe :block, with: &block/0", """
        defp block do
          send(Process.whereis(:insider_contract_capacity_receiver), {:capacity_started, self()})

          receive do
            :release -> "released"
          end
        end
        """)

      first =
        Task.async(fn ->
          invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 5_000)
        end)

      assert_receive {:capacity_started, first_worker}, 1_000

      second =
        Task.async(fn ->
          invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 5_000)
        end)

      assert_receive {:capacity_started, second_worker}, 1_000
      refute first_worker == second_worker

      send(first_worker, :release)
      send(second_worker, :release)

      assert %Invocation{status: :ok, value: "released"} = Task.await(first)
      assert %Invocation{status: :ok, value: "released"} = Task.await(second)
    end

    @tag executor_capacity: 1
    test "times out a callback and immediately sheds excess concurrent work", %{
      executor: executor
    } do
      Process.register(self(), :insider_contract_test_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract(
          "Blocking",
          "action :block, with: &block/0, environments: [:test]",
          """
          defp block do
            send(Process.whereis(:insider_contract_test_receiver), {:callback_started, self()})
            receive do
              :release -> %{"released" => true}
            end
          end
          """
        )

      task =
        Task.async(fn ->
          invoke(executor, blocking_contract, :action, :block, [],
            environment: :test,
            timeout_ms: 250
          )
        end)

      assert_receive {:callback_started, worker}, 1_000

      assert %Invocation{
               status: :overloaded,
               reason: :executor_overloaded,
               error: %Error{retryable: true}
             } =
               invoke(executor, ExampleContract, :observation, :summary, ["later"])

      assert %Invocation{
               status: :timeout,
               reason: :deadline_exceeded,
               cleanup: %{status: :complete},
               error: %Error{code: :deadline_exceeded},
               uncertainty: ["contract mutation may have produced external effects" <> _rest]
             } = Task.await(task)

      refute Process.alive?(worker)
    end

    # Under load the caller handled the runner's deadline result after
    # the dispatch deadline, so releasing the already-stopped runner had no
    # time left and the deadline was reported as `:executor_failed`. Here the
    # caller is suspended until the runner has replied and exited and the
    # dispatch deadline has passed.
    @tag executor_capacity: 1
    test "a deadline result handled after the dispatch deadline stays a deadline", %{
      executor: executor
    } do
      Process.register(self(), :insider_contract_test_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract("LateCaller", "observe :block, with: &block/0", """
        defp block do
          send(Process.whereis(:insider_contract_test_receiver), {:callback_started, self()})
          receive do
            :never -> nil
          end
        end
        """)

      task =
        Task.async(fn ->
          invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 1_000)
        end)

      assert_receive {:callback_started, _worker}, 5_000
      [{_id, runner, :worker, _modules}] = DynamicSupervisor.which_children(executor)
      deadline = :sys.get_state(runner).dispatch_deadline_monotonic
      true = :erlang.suspend_process(task.pid)

      monitor = Process.monitor(runner)
      assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 5_000

      # The condition under test is the dispatch deadline having passed; this
      # waits for exactly that instant, read from the runner above.
      receive after: (max(0, deadline - System.monotonic_time(:millisecond) + 1) -> :ok)

      true = :erlang.resume_process(task.pid)

      assert %Invocation{
               status: :timeout,
               reason: :deadline_exceeded,
               cleanup: %{status: :complete},
               error: %Error{code: :deadline_exceeded}
             } = Task.await(task, 10_000)
    end

    # A CI failure of the test above: the caller was still
    # inside its admit call when it was suspended, so it monitored the
    # runner only after the runner had exited. The DOWN (`:noproc`) of
    # such a monitor is not always delivered by the time a `receive ...
    # after 0` looks for it. The caller then asked the executor to release
    # the stopped runner with the 0 ms left before the dispatch deadline,
    # and reported `:executor_failed`. Here the executor is held so that the
    # caller is suspended inside its admit call. The interleaving is the
    # same each time, so a few repetitions are enough.
    #
    # The runner starts the callback only while more than its 50 ms cleanup
    # reserve is left before the dispatch deadline. The 1 s timeout keeps
    # that true on a slow runner, where holding and resuming the executor can
    # take longer than 50 ms. Every wait is explicit and long; the test tag
    # lets a slow runner reach them.
    @tag executor_capacity: 1
    @tag timeout: 180_000
    test "a late caller that monitors the runner only after its exit still reports the deadline",
         %{executor: executor} do
      Process.register(self(), :insider_contract_test_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract("LateMonitor", "observe :block, with: &block/0", """
        defp block do
          send(Process.whereis(:insider_contract_test_receiver), {:callback_started, self()})
          receive do
            :never -> nil
          end
        end
        """)

      for _attempt <- 1..5 do
        :ok = :sys.suspend(executor)

        task =
          Task.async(fn ->
            invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 1_000)
          end)

        caller = task.pid
        await_queued_call(executor, fn {from, _tag}, _request -> from == caller end)
        true = :erlang.suspend_process(caller)
        :ok = :sys.resume(executor)

        assert_receive {:callback_started, _worker}, 5_000
        [{_id, runner, :worker, _modules}] = DynamicSupervisor.which_children(executor)
        deadline = :sys.get_state(runner).dispatch_deadline_monotonic
        monitor = Process.monitor(runner)
        assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 5_000
        receive after: (max(0, deadline - System.monotonic_time(:millisecond) + 1) -> :ok)

        true = :erlang.resume_process(caller)

        assert %Invocation{
                 status: :timeout,
                 reason: :deadline_exceeded,
                 cleanup: %{status: :complete},
                 error: %Error{code: :deadline_exceeded}
               } = Task.await(task, 10_000)

        assert %{active: 0} = DynamicSupervisor.count_children(executor)
      end
    end

    # The runner exits right after it replies, and its DOWN reaches the caller
    # before the executor has handled the runner's exit. Here the executor is
    # suspended at that point. The caller must not return until the executor
    # has removed the runner, so that its capacity is free on return.
    @tag executor_capacity: 1
    @tag timeout: 120_000
    test "a caller returns only after the executor has removed its finished runner", %{
      executor: executor
    } do
      Process.register(self(), :insider_contract_test_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract("HeldExecutor", "observe :block, with: &block/0", """
        defp block do
          send(Process.whereis(:insider_contract_test_receiver), {:callback_started, self()})
          receive do
            :release -> "released"
          end
        end
        """)

      task =
        Task.async(fn ->
          invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 5_000)
        end)

      assert_receive {:callback_started, worker}, 5_000
      [{_id, runner, :worker, _modules}] = DynamicSupervisor.which_children(executor)
      :ok = :sys.suspend(executor)

      monitor = Process.monitor(runner)
      send(worker, :release)
      assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 5_000

      # The caller asks the held executor to remove the runner, and waits.
      await_queued_call(executor, fn _from, request -> request == {:terminate_child, runner} end)
      assert Task.yield(task, 0) == nil

      :ok = :sys.resume(executor)
      assert %Invocation{status: :ok, value: "released"} = Task.await(task, 10_000)
      assert %{active: 0} = DynamicSupervisor.count_children(executor)
    end

    test "kills callback work when the invoking caller dies", %{executor: executor} do
      Process.register(self(), :insider_contract_test_receiver)

      {:module, blocking_contract, _binary, _bindings} =
        compile_contract("CallerDeath", "observe :block, with: &block/0", """
        defp block do
          send(Process.whereis(:insider_contract_test_receiver), {:callback_started, self()})
          receive do
            :never -> nil
          end
        end
        """)

      caller =
        spawn(fn ->
          invoke(executor, blocking_contract, :observation, :block, [], timeout_ms: 5_000)
        end)

      assert_receive {:callback_started, worker}, 1_000
      monitor = Process.monitor(worker)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 1_000
      assert reason in [:killed, :noproc]
    end

    test "requires a live mutation decision and declared environment for actions", %{
      executor: executor
    } do
      assert %Invocation{
               status: :error,
               reason: :policy_denied,
               error: %Error{code: :policy_denied}
             } =
               Contract.invoke(executor, ExampleContract, :action, :echo, ["value"], [])

      assert %Invocation{
               status: :ok,
               value: "value",
               uncertainty: ["contract mutation may have produced external effects" <> _rest]
             } =
               invoke(executor, ExampleContract, :action, :echo, ["value"], environment: :test)

      assert %Invocation{status: :error, error: %Error{code: :policy_denied}} =
               invoke(executor, ExampleContract, :action, :echo, ["value"], environment: :ci)
    end

    test "fails closed for mismatched operations, remote targets, and unavailable executors", %{
      executor: executor
    } do
      assert %Invocation{status: :error, error: %Error{code: :policy_denied}} =
               invoke(executor, ExampleContract, :observation, :summary, ["value"],
                 operation: "contract.check"
               )

      assert %Invocation{status: :error, error: %Error{code: :policy_denied}} =
               invoke(executor, ExampleContract, :observation, :summary, ["value"],
                 target: %{node: "remote@node"}
               )

      options = authorization_options(:observation, environment: :test)

      assert %Invocation{
               status: :error,
               reason: :executor_unavailable,
               error: %Error{code: :operation_failed}
             } =
               Contract.invoke(
                 self(),
                 ExampleContract,
                 :observation,
                 :summary,
                 ["value"],
                 options
               )

      assert %Invocation{status: :error, error: %Error{code: :invalid_request}} =
               Contract.invoke(executor, ExampleContract, :unknown, :summary, ["value"], options)

      assert %Invocation{status: :ok, value: %{"summary" => "global"}} =
               Contract.invoke(
                 ExampleContract,
                 :observation,
                 :summary,
                 ["global"],
                 authorization_options(:observation, [])
               )
    end
  end

  # Waits until a call for which `queued?.(from, request)` holds is queued at
  # the suspended `server`.
  defp await_queued_call(server, queued?),
    do: await_queued_call(server, queued?, System.monotonic_time(:millisecond) + 10_000)

  defp await_queued_call(server, queued?, deadline) do
    {:messages, messages} = Process.info(server, :messages)

    cond do
      Enum.any?(messages, fn
        {:"$gen_call", from, request} -> queued?.(from, request)
        _other -> false
      end) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the expected call did not reach the suspended server")

      true ->
        Process.sleep(1)
        await_queued_call(server, queued?, deadline)
    end
  end

  defp compile_contract(suffix, declaration, functions) do
    module = "Insider.ContractTest.#{suffix}#{System.unique_integer([:positive])}"

    [{compiled, binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Insider.Contract, id: "test.dynamic.#{String.downcase(suffix)}", version: 1
        #{declaration}
        #{functions}
      end
      """)

    {:module, compiled, binary, []}
  end

  defp invoke(executor, module, kind, name, arguments, options \\ []) do
    Contract.invoke(executor, module, kind, name, arguments, authorization_options(kind, options))
  end

  defp authorization_options(kind, options) do
    environment = Keyword.get(options, :environment, :test)
    default_operation = if kind in [:action, :reset], do: "scenario.run", else: operation(kind)
    request_operation = Keyword.get(options, :operation, default_operation)
    timeout_ms = Keyword.get(options, :timeout_ms, 1_000)
    scope = operation_scope(request_operation)
    target = Keyword.get(options, :target, %{node: Atom.to_string(node())})
    now = System.monotonic_time(:millisecond)

    {:ok, grant} =
      Grant.new(
        reference: "contract-test-grant",
        audit_id: "contract-test-audit",
        scopes: [scope],
        target: target,
        expires_at_monotonic: now + timeout_ms + 1_000
      )

    {:ok, request} =
      Request.new(request_operation,
        request_id: "contract-test-request",
        environment: environment,
        target: target,
        capability: grant.reference,
        timeout_ms: timeout_ms,
        budget: %{max_duration_ms: timeout_ms, max_bytes: 65_536}
      )

    {:ok, context} =
      Context.new(
        environment: environment,
        actor: "contract-test",
        target_class: if(request_operation == "scenario.run", do: :disposable, else: :host),
        grants: [grant],
        features: %{
          request_operation => %{available: true, provider: "test", isolation: :session_local}
        }
      )

    [
      request: request,
      context: context,
      timeout_ms: timeout_ms
    ]
  end

  defp operation(:identity), do: "contract.observe"
  defp operation(:observation), do: "contract.observe"
  defp operation(:invariant), do: "contract.check"

  defp operation_scope("scenario.run"), do: "scenario.execute"
  defp operation_scope("verification.run"), do: "verification.execute"
  defp operation_scope(_operation), do: "contract.observe"
end
