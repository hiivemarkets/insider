Code.require_file(Application.app_dir(:insider_lab, "priv/probes/fault_rerun.exs"))

defmodule Insider.Discovery.ExUnit.FaultRerunOracleArtifactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Insider.Test.FaultRerunHost, as: Host
  alias Insider.Test.FaultRerunHost.Provider
  alias Insider.Test.OracleArtifactRunner
  alias InsiderLab.FaultRerunOracle, as: Oracle

  @artifact Application.app_dir(:insider_lab, "priv/probes/fault_rerun.exs")

  @prefix "INSIDER_FAULT_RERUN_ORACLE="

  setup do
    {:ok, store: start_supervised!(Host)}
  end

  describe "verdicts" do
    test "a worker that creates remotely before its local write leaves an orphan on retry",
         %{store: store} do
      {report, _line} = run(declaration(store, &Host.create_then_commit/1))

      assert report["completeness"] == "complete"
      assert report["outcome"] == "confirmed"
      assert report["reason"] == nil

      control = report["control"]
      assert control["reasons"] == [] and control["verdict"] == nil
      assert control["converged"]

      assert [%{"attempt" => 1, "faulted" => false, "fault_reached" => nil, "succeeded" => true}] =
               control["attempts"]

      assert [%{"effect" => "e1", "attempt" => 1, "referenced" => true}] = control["effects"]

      run = report["fault_run"]
      assert run["verdict"] == "confirmed"
      assert run["reasons"] == ["orphaned_effect", "repeated_effect"]
      assert run["converged"]

      assert [first, second] = run["attempts"]

      assert first == %{
               "attempt" => 1,
               "faulted" => true,
               "fault_reached" => true,
               "result" => %{"kind" => "returned", "tag" => "error", "exception" => nil},
               "succeeded" => false,
               "calls" => %{"account_create" => %{"1" => 1}, "category_link" => %{"2" => 1}}
             }

      assert second["faulted"] == false and second["succeeded"]
      assert second["result"]["tag"] == "ok"

      assert Enum.map(run["effects"], &{&1["attempt"], &1["effect"], &1["referenced"]}) == [
               {1, "e2", false},
               {2, "e3", true}
             ]

      assert boundary(run, "account_create") == %{
               "boundary" => "account_create",
               "expected" => 1,
               "distinct_effects" => 2,
               "effects_not_comparable" => 0,
               "referenced_effects" => 1,
               "orphaned_effects" => 1,
               "calls_with_key" => 0,
               "distinct_keys" => 0
             }

      assert run["references"] == %{"distinct" => 1, "not_comparable" => 0}
    end

    test "an idempotent worker that commits before the fallible call is not reproduced",
         %{store: store} do
      {report, _line} = run(declaration(store, &Host.commit_then_link/1))

      assert report["outcome"] == "not_reproduced"
      run = report["fault_run"]
      assert run["verdict"] == "not_reproduced"
      assert run["reasons"] == ["converged_once"]
      assert boundary(run, "account_create")["distinct_effects"] == 1
      assert boundary(run, "account_create")["orphaned_effects"] == 0

      # The retry reuses the committed account and only repeats the category
      # call, through the three-argument arity.
      assert Enum.map(run["attempts"], & &1["calls"]) == [
               %{"account_create" => %{"1" => 1}, "category_link" => %{"3" => 1}},
               %{"category_link" => %{"3" => 1}}
             ]
    end

    test "a provider idempotency key makes the retry replay the first account",
         %{store: store} do
      {report, _line} = run(declaration(store, &Host.keyed/1))

      assert report["outcome"] == "not_reproduced"
      run = report["fault_run"]

      assert Enum.map(run["effects"], &{&1["attempt"], &1["effect"], &1["key"], &1["replayed"]}) ==
               [{1, "e2", "k2", false}, {2, "e2", "k2", true}]

      assert boundary(run, "account_create")["calls_with_key"] == 2
      assert boundary(run, "account_create")["distinct_keys"] == 1
    end

    test "a lost create response with no key orphans the account the provider made",
         %{store: store} do
      fault = %{
        boundary: "account_create",
        result: {:raise, %RuntimeError{message: "SECRET-timeout"}},
        lost_response: true
      }

      {report, line} = run(declaration(store, &Host.create_then_commit/1, fault: fault))

      assert report["outcome"] == "confirmed"
      assert report["fault"]["exception"] == "RuntimeError"
      run = report["fault_run"]
      assert run["reasons"] == ["orphaned_effect", "repeated_effect"]

      assert hd(run["attempts"])["result"] == %{
               "kind" => "raised",
               "tag" => nil,
               "exception" => "RuntimeError"
             }

      assert [%{"lost_response" => true, "referenced" => false}, %{"lost_response" => false}] =
               run["effects"]

      refute line =~ "SECRET"
    end

    test "a lost create response with a key is replayed on retry", %{store: store} do
      fault = %{
        boundary: "account_create",
        result: {:return, {:error, :timeout}},
        lost_response: true
      }

      {report, _line} = run(declaration(store, &Host.keyed/1, fault: fault))

      assert report["outcome"] == "not_reproduced"
      assert boundary(report["fault_run"], "account_create")["distinct_effects"] == 1
    end

    test "a worker that swallows the fault succeeds without its effect", %{store: store} do
      {report, _line} = run(declaration(store, &Host.swallowing/1))

      assert report["outcome"] == "confirmed"
      run = report["fault_run"]
      assert run["reasons"] == ["orphaned_effect", "missing_effect"]
      assert [%{"faulted" => true, "succeeded" => true}] = run["attempts"]
      assert boundary(run, "account_create")["referenced_effects"] == 0
    end

    test "a fault on every attempt but the last repeats once per failed attempt",
         %{store: store} do
      fault = %{boundary: "category_link", attempts: 2, result: {:return, {:error, :invalid}}}

      {report, _line} =
        run(declaration(store, &Host.create_then_commit/1, attempts: 3, fault: fault))

      run = report["fault_run"]
      assert report["outcome"] == "confirmed"
      assert Enum.map(run["attempts"], & &1["faulted"]) == [true, true, false]
      assert boundary(run, "account_create")["distinct_effects"] == 3
      assert boundary(run, "account_create")["orphaned_effects"] == 2
    end

    test "a worker that raises on the failed call is judged from its effects", %{store: store} do
      {report, _line} = run(declaration(store, &Host.raising/1))

      assert report["outcome"] == "confirmed"
      assert hd(report["fault_run"]["attempts"])["result"]["exception"] == "RuntimeError"
    end

    test "calls from a task the worker starts are recorded", %{store: store} do
      {report, _line} = run(declaration(store, &Host.in_task/1))

      assert report["outcome"] == "confirmed"
      assert boundary(report["fault_run"], "account_create")["orphaned_effects"] == 1
    end

    test "a retry that keeps failing without an orphan is not observed", %{store: store} do
      perform = fn fixture, attempt ->
        if attempt == 1, do: Host.commit_then_link(fixture), else: {:error, :still_down}
      end

      {report, _line} = run(declaration(store, perform))

      assert report["outcome"] == "not_observed"
      assert report["fault_run"]["reasons"] == ["retry_did_not_succeed"]
      refute report["fault_run"]["converged"]
    end

    test "a custom success check decides which returns are success", %{store: store} do
      perform = fn fixture -> with :ok <- Host.create_then_commit(fixture), do: :done end

      {report, _line} =
        run(declaration(store, perform, succeeded?: &(&1 == :done)))

      assert report["outcome"] == "confirmed"
      assert List.last(report["fault_run"]["attempts"])["result"]["tag"] == "done"
    end
  end

  describe "controls" do
    test "a control that fails is an infrastructure failure and no fault run is attempted",
         %{store: store} do
      test_pid = self()

      fixture = fn ->
        send(test_pid, :fixture_built)
        Host.fixture(store)
      end

      perform = fn _fixture -> {:error, :down} end
      {report, _line} = run(declaration(store, perform, fixture: fixture))

      assert report["completeness"] == "infrastructure_failure"
      assert report["outcome"] == "infrastructure_failure"
      assert report["reason"] == "control_unhealthy"
      assert report["control"]["reasons"] == ["control_did_not_succeed"]
      assert report["fault_run"] == nil

      assert_received :fixture_built
      refute_received :fixture_built
    end

    test "a control that makes a different number of effects than expected is unhealthy",
         %{store: store} do
      boundaries = boundaries(expect: 2)

      {report, _line} =
        run(declaration(store, &Host.create_then_commit/1, boundaries: boundaries))

      assert report["reason"] == "control_unhealthy"
      assert report["control"]["reasons"] == ["control_effect_count_mismatch"]
    end

    test "a reference projection that misses the control's effect is unhealthy",
         %{store: store} do
      {report, _line} =
        run(declaration(store, &Host.create_then_commit/1, references: fn _fixture -> %{} end))

      assert report["control"]["reasons"] == ["control_orphaned_effect"]
      assert boundary(report["control"], "account_create")["orphaned_effects"] == 1
    end

    test "references not grouped by a referenced effect boundary are refused",
         %{store: store} do
      for references <- [
            fn fixture -> [Host.order(fixture).account] end,
            fn fixture -> %{category_link: [Host.order(fixture).account]} end,
            fn fixture -> %{account_create: Host.order(fixture).account} end,
            fn _fixture -> %{account_create: Enum.to_list(1..1_025)} end
          ] do
        {report, _line} =
          run(declaration(store, &Host.create_then_commit/1, references: references))

        assert report["control"]["reasons"] == ["references_failed"]

        assert report["control"]["error"] == %{
                 "stage" => "references",
                 "kind" => "invalid_result",
                 "exception" => nil
               }
      end
    end

    test "an effect from work the worker left running is not attributed to an attempt",
         %{store: store} do
      # After the injected failure the worker leaves a child behind; the
      # projection releases it and waits, and it opens another account after
      # `perform` has returned.
      test_pid = self()

      perform = fn fixture ->
        with {:error, _reason} = error <- Host.commit_then_link(fixture) do
          child =
            spawn(fn ->
              Process.put(:"$callers", [test_pid])

              receive do
                :go ->
                  Provider.create_account(fixture.order_id)
                  send(test_pid, :child_done)
              end
            end)

          Process.put(:child, child)
          error
        end
      end

      references = fn fixture ->
        with child when is_pid(child) <- Process.delete(:child) do
          send(child, :go)
          assert_receive :child_done
        end

        Host.references(fixture)
      end

      {report, _line} = run(declaration(store, perform, references: references))

      assert report["outcome"] == "not_observed"
      assert report["fault_run"]["reasons"] == ["effect_outside_attempt"]
      assert report["fault_run"]["outside_attempt_calls"] == 1
    end

    test "a fixture that makes a declared effect leaves the control unhealthy",
         %{store: store} do
      fixture = fn ->
        fixture = Host.fixture(store)
        Provider.create_account(fixture.order_id)
        fixture
      end

      {report, _line} =
        run(declaration(store, &Host.commit_then_link/1, fixture: fixture))

      assert report["control"]["reasons"] == ["effect_outside_attempt"]
    end

    test "equal ids from two providers never reference each other", %{store: store} do
      # Both providers number their objects from 1. In the fault run the link
      # provider's reply is lost and the worker swallows it, so only the
      # account id, equal to the lost link's id, is committed.
      perform = fn fixture ->
        {:ok, %{"id" => account}} = Provider.create_account(fixture.order_id)

        case Provider.link(account, "customer_funds") do
          {:ok, link} -> Host.commit(fixture, %{account: account, link: link})
          {:error, _reason} -> Host.commit(fixture, %{account: account})
        end
      end

      boundaries = [
        %{
          name: "account_create",
          function: {Provider, :create_account},
          respond: fn _args, call -> {:ok, %{"id" => Integer.to_string(call.sequence)}} end,
          effect: fn _args, {:ok, %{"id" => id}} -> id end,
          expect: 1
        },
        %{
          name: "category_link",
          function: {Provider, :link},
          respond: fn _args, call -> {:ok, Integer.to_string(call.sequence)} end,
          effect: fn _args, {:ok, id} -> id end,
          expect: 1
        }
      ]

      fault = %{
        boundary: "category_link",
        result: {:return, {:error, :timeout}},
        lost_response: true
      }

      references = fn fixture ->
        order = Host.order(fixture)
        %{account_create: [order.account], category_link: [order[:link]]}
      end

      {report, _line} =
        run(
          declaration(store, perform,
            boundaries: boundaries,
            fault: fault,
            references: references
          )
        )

      assert report["outcome"] == "confirmed"
      assert report["fault_run"]["reasons"] == ["orphaned_effect", "missing_effect"]
      assert boundary(report["fault_run"], "account_create")["referenced_effects"] == 1
      assert boundary(report["fault_run"], "category_link")["referenced_effects"] == 0
      assert boundary(report["fault_run"], "category_link")["orphaned_effects"] == 1
    end

    test "a fault point the control never reaches is unhealthy", %{store: store} do
      fault = %{boundary: "category_link", call: 2, result: {:return, {:error, :unavailable}}}
      {report, _line} = run(declaration(store, &Host.create_then_commit/1, fault: fault))

      assert report["reason"] == "control_unhealthy"
      assert report["control"]["reasons"] == ["control_fault_point_not_reached"]
    end

    test "a control whose fixture raises names only the stage and module", %{store: store} do
      fixture = fn -> raise ArgumentError, "secret-fixture-detail" end

      {report, line} =
        run(declaration(store, &Host.create_then_commit/1, fixture: fixture))

      assert report["control"]["attempted"] == false
      assert report["control"]["reasons"] == ["fixture_failed"]

      assert report["control"]["error"] == %{
               "stage" => "fixture",
               "kind" => "error",
               "exception" => "ArgumentError"
             }

      refute line =~ "secret-fixture-detail"
    end

    test "a responder that raises is unhealthy and named by its boundary", %{store: store} do
      boundaries =
        boundaries(link_respond: fn _args, _call -> raise KeyError, "secret-respond" end)

      {report, line} =
        run(declaration(store, &Host.create_then_commit/1, boundaries: boundaries))

      assert report["control"]["reasons"] == ["respond_failed"]

      assert report["control"]["error"] == %{
               "stage" => "respond",
               "kind" => "error",
               "exception" => "KeyError",
               "boundary" => "category_link"
             }

      refute line =~ "secret-respond"
    end

    test "a stub installer that raises is an infrastructure failure before any fixture",
         %{store: store} do
      test_pid = self()
      stub = fn _module, _name, _fun -> raise "no stubs here" end

      fixture = fn ->
        send(test_pid, :fixture_built)
        Host.fixture(store)
      end

      {report, _line} =
        run(declaration(store, &Host.create_then_commit/1, stub: stub, fixture: fixture))

      assert report["reason"] == "stub_failed"

      assert report["error"] == %{
               "stage" => "stub",
               "kind" => "error",
               "exception" => "RuntimeError"
             }

      assert report["control"] == nil
      refute_received :fixture_built
    end

    test "a fault run that never reaches its fault is not observed", %{store: store} do
      perform = fn fixture ->
        if fixture.order_id == "order-1", do: Host.create_then_commit(fixture), else: :ok
      end

      {report, _line} = run(declaration(store, perform))

      assert report["outcome"] == "not_observed"
      assert report["fault_run"]["reasons"] == ["fault_not_reached"]
      assert [%{"faulted" => true, "fault_reached" => false}] = report["fault_run"]["attempts"]
    end
  end

  describe "idempotency keys" do
    test "concurrent calls sharing a key create once and replay", %{store: store} do
      # Each create waits up to 200 ms for a second caller to arrive, so two
      # callers that both missed the replay would create two accounts.
      {:ok, arrivals} = Agent.start_link(fn -> %{} end)

      respond = fn [owner | _options] = args, call ->
        Agent.update(arrivals, &Map.update(&1, owner, 1, fn count -> count + 1 end))
        await_second(arrivals, owner, 200)
        account(args, call)
      end

      boundaries = boundaries(create_respond: respond)
      {report, _line} = run(declaration(store, &Host.concurrent_keyed/1, boundaries: boundaries))

      assert report["outcome"] == "not_reproduced"
      run = report["fault_run"]
      assert boundary(run, "account_create")["distinct_effects"] == 1
      assert boundary(run, "account_create")["distinct_keys"] == 1
      assert Enum.map(run["effects"], & &1["replayed"]) == [false, true, true, true]
    end

    @tag timeout: 30_000
    test "a keyed response too large to cache makes a repeated key not comparable",
         %{store: store} do
      shared = Enum.reduce(1..30, :leaf, fn _level, inner -> {inner, inner} end)

      respond = fn args, call ->
        {:ok, account} = account(args, call)
        {:ok, Map.put(account, "blob", shared)}
      end

      boundaries = boundaries(create_respond: respond)

      {microseconds, {report, _line}} =
        :timer.tc(fn ->
          run(declaration(store, &Host.keyed/1, boundaries: boundaries))
        end)

      assert microseconds < 2_000_000
      assert report["control"]["reasons"] == []
      assert report["outcome"] == "not_observed"
      assert report["fault_run"]["reasons"] == ["key_not_comparable"]
    end

    test "more distinct keys than the replay limit make the run not comparable",
         %{store: store} do
      # Keys past the limit are not cached, so a repeat of one could not be
      # replayed; the oracle refuses to call the extra accounts repeats.
      perform = fn fixture ->
        if fixture.order_id != "order-1" do
          for number <- 1..513,
              do: Provider.create_account(fixture.order_id, idempotency_key: "key-#{number}")
        end

        Host.keyed(fixture)
      end

      {report, _line} = run(declaration(store, perform))

      assert report["outcome"] == "not_observed"
      assert report["fault_run"]["reasons"] == ["key_not_comparable"]
    end

    test "a responder that calls its own key again is not comparable", %{store: store} do
      respond = fn [owner | _options] = args, call ->
        if call.sequence == 1, do: Provider.create_account(owner, idempotency_key: owner)
        account(args, call)
      end

      boundaries = boundaries(create_respond: respond)
      {report, _line} = run(declaration(store, &Host.keyed/1, boundaries: boundaries))

      assert report["reason"] == "control_unhealthy"
      assert report["control"]["reasons"] == ["key_not_comparable"]
    end

    test "a responder whose child task calls its own key again does not deadlock",
         %{store: store} do
      respond = fn [owner | _options] = args, call ->
        if call.sequence == 1 do
          Task.await(Task.async(fn -> Provider.create_account(owner, idempotency_key: owner) end))
        end

        account(args, call)
      end

      boundaries = boundaries(create_respond: respond)

      {microseconds, {report, _line}} =
        :timer.tc(fn -> run(declaration(store, &Host.keyed/1, boundaries: boundaries)) end)

      assert microseconds < 1_000_000
      assert report["control"]["reasons"] == ["key_not_comparable"]
    end

    test "waiters behind a claimant that settles and exits still replay", %{store: store} do
      # The claimant task holds its response until five waiters are started,
      # then caches it and exits while they poll; that must read as settled,
      # not as an abandoned claim.
      test_pid = self()

      respond = fn args, call ->
        if Process.get(:claimant) do
          send(test_pid, {:claimed, self()})
          receive do: (:release -> :ok)
        end

        account(args, call)
      end

      # The first attempt of each run fans out; the retry replays the cache.
      # Tasks call the installed recorder directly, as a client module whose
      # stub needs no lookup would.
      perform = fn fixture, attempt ->
        recorder = Process.get({Provider, :create_account, 2})
        create = fn -> recorder.(fixture.order_id, idempotency_key: fixture.order_id) end

        if attempt == 1 do
          claimant =
            Task.async(fn ->
              Process.put(:claimant, true)
              create.()
            end)

          assert_receive {:claimed, _pid}

          waiters =
            for number <- 1..8 do
              if number == 6, do: send(claimant.pid, :release)
              Task.async(create)
            end

          Task.await_many([claimant | waiters])
        end

        Host.keyed(fixture)
      end

      boundaries = boundaries(create_respond: respond)
      {report, _line} = run(declaration(store, perform, boundaries: boundaries))

      assert report["outcome"] == "not_reproduced"
      assert boundary(report["fault_run"], "account_create")["distinct_effects"] == 1
    end

    test "a claimant killed mid-response leaves its key not comparable, without a wait",
         %{store: store} do
      # The first create's caller dies inside the responder, so its claim is
      # never settled; the worker's own call with the key cannot replay it.
      respond = fn args, call ->
        if call.sequence == 1, do: Process.exit(self(), :kill)
        account(args, call)
      end

      perform = fn fixture ->
        parent = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            Process.put(:"$callers", [parent])
            Provider.create_account(fixture.order_id, idempotency_key: fixture.order_id)
          end)

        receive do
          {:DOWN, ^monitor, :process, ^pid, :killed} -> Host.keyed(fixture)
        end
      end

      boundaries = boundaries(create_respond: respond)

      {microseconds, {report, _line}} =
        :timer.tc(fn -> run(declaration(store, perform, boundaries: boundaries)) end)

      assert microseconds < 1_000_000
      assert report["control"]["reasons"] == ["key_not_comparable"]
    end

    test "a key too large to fingerprint is not comparable, never unkeyed", %{store: store} do
      boundaries = boundaries(key: fn _args -> String.duplicate("k", 1_048_571) end)

      {report, _line} =
        run(declaration(store, &Host.keyed/1, boundaries: boundaries))

      assert report["reason"] == "control_unhealthy"
      assert report["control"]["reasons"] == ["key_not_comparable"]
      assert hd(report["control"]["effects"])["key"] == "unknown"
    end
  end

  describe "recorder arities" do
    test "a declared arity list that omits an exported arity is refused before anything runs",
         %{store: store} do
      test_pid = self()

      stub = fn module, name, fun ->
        send(test_pid, :stubbed)
        Provider.stub(module, name, fun)
      end

      fixture = fn ->
        send(test_pid, :fixture_built)
        Host.fixture(store)
      end

      boundaries = boundaries(link_arities: [3])

      {report, _line} =
        run(
          declaration(store, &Host.create_then_commit/1,
            boundaries: boundaries,
            stub: stub,
            fixture: fixture
          )
        )

      assert report["outcome"] == "infrastructure_failure"
      assert report["reason"] == "arity_not_covered"
      refute_received :stubbed
      refute_received :fixture_built
    end

    test "every exported arity is stubbed, in any declared order", %{store: store} do
      boundaries = boundaries(link_arities: [3, 2])
      {report, _line} = run(declaration(store, &Host.commit_then_link/1, boundaries: boundaries))

      assert Enum.map(report["boundaries"], &{&1["function"], &1["arities"]}) == [
               {"Insider.Test.FaultRerunHost.Provider.create_account", [1, 2]},
               {"Insider.Test.FaultRerunHost.Provider.link", [2, 3]}
             ]

      assert report["outcome"] == "not_reproduced"
    end

    test "a call through the undeclared default-argument arity is still recorded",
         %{store: store} do
      # The worker calls link/2 once and link/3 once; neither escapes.
      perform = fn fixture ->
        with :ok <- Host.commit_then_link(fixture),
             :ok <- Provider.link("acct", "audit") do
          :ok
        end
      end

      {report, _line} = run(declaration(store, perform))

      assert hd(report["control"]["attempts"])["calls"]["category_link"] == %{"2" => 1, "3" => 1}
    end

    test "a boundary called after run/1 returns raises", %{store: store} do
      {_report, _line} = run(declaration(store, &Host.create_then_commit/1))

      assert_raise RuntimeError, ~r/after run\/1 returned/, fn ->
        Provider.link("acct", "category")
      end
    end
  end

  describe "bounded output" do
    test "argument, response, identity, key, and reference values never reach the line",
         %{store: store} do
      respond = fn [owner | _options], call ->
        {:ok, %{"id" => "CANARY-ID-#{call.sequence}", "owner" => "CANARY-#{owner}"}}
      end

      boundaries =
        boundaries(
          create_respond: respond,
          key: fn _args -> "CANARY-KEY" end,
          link_respond: fn _args, _call -> :ok end
        )

      fault = %{boundary: "category_link", result: {:return, {:error, "CANARY-ERROR"}}}

      {report, line} =
        run(declaration(store, &Host.create_then_commit/1, boundaries: boundaries, fault: fault))

      # The constant key makes the retry replay the first account.
      assert report["outcome"] == "not_reproduced"
      assert hd(report["fault_run"]["attempts"])["result"]["tag"] == "error"
      refute line =~ "CANARY"
      refute line =~ "order-"
    end

    test "a worker that exceeds the record limit is truncated and still confirmed",
         %{store: store} do
      perform = fn fixture ->
        if fixture.order_id == "order-1",
          do: Host.create_then_commit(fixture),
          else: Host.many(fixture, 600)
      end

      {report, line} = run(declaration(store, perform))

      assert report["completeness"] == "truncated"
      assert report["outcome"] == "confirmed"
      run = report["fault_run"]
      assert run["truncated"]
      assert run["reasons"] == ["orphaned_effect", "repeated_effect"]
      assert Enum.count_until(run["effects"], 65) == 64
      assert boundary(run, "account_create")["distinct_effects"] == 512
      assert byte_size(line) < 64 * 1_024
    end

    @tag timeout: 30_000
    test "an identity too large to fingerprint is not comparable and is not serialized",
         %{store: store} do
      # 30 levels of {t, t}: a few hundred words resident, about 2^30 terms
      # when traversed.
      shared = Enum.reduce(1..30, :leaf, fn _level, inner -> {inner, inner} end)
      boundaries = boundaries(effect: fn _args, _response -> shared end)

      {microseconds, {report, _line}} =
        :timer.tc(fn ->
          run(declaration(store, &Host.create_then_commit/1, boundaries: boundaries))
        end)

      assert microseconds < 2_000_000
      assert report["control"]["reasons"] == ["effect_not_comparable"]
      assert hd(report["control"]["effects"])["effect"] == "unknown"
      assert boundary(report["control"], "account_create")["effects_not_comparable"] == 1
    end

    test "the report states its limits and limitations", %{store: store} do
      {report, _line} = run(declaration(store, &Host.commit_then_link/1))

      assert report["schema"] == "insider.fault-rerun-oracle/v1"
      assert report["operation"] == "open the order's provider account"
      assert report["context"] == "fault rerun unit"

      assert report["limits"] == %{
               "operation_byte_limit" => 255,
               "context_byte_limit" => 1_024,
               "boundary_limit" => 16,
               "arity_limit" => 12,
               "attempt_limit" => 8,
               "fault_call_limit" => 64,
               "expected_effect_limit" => 64,
               "record_limit" => 512,
               "listed_effect_limit" => 64,
               "reference_limit" => 1_024,
               "replay_byte_limit" => 8_388_608,
               "replay_wait_millisecond_limit" => 2_000,
               "fingerprint_value_byte_limit" => 1_048_576,
               "fingerprint_term_limit" => 65_536
             }

      assert report["fault"] == %{
               "boundary" => "category_link",
               "call" => 1,
               "attempts" => 1,
               "result" => "return",
               "exception" => nil,
               "lost_response" => false
             }

      assert "retries_are_direct_reruns_without_queue_semantics" in report["limitations"]
      assert "provider_responses_are_caller_simulated" in report["limitations"]
    end

    property "no generated provider value reaches the line" do
      check all(value <- canary_term(), max_runs: 50) do
        {:ok, store} = Host.start_link([])

        respond = fn _args, call ->
          {:ok, %{"id" => {call.sequence, value}, "extra" => value}}
        end

        boundaries =
          boundaries(
            create_respond: respond,
            key: fn _args -> value end,
            effect: fn _args, {:ok, %{"id" => id}} -> id end
          )

        {_report, line} =
          run(declaration(store, &Host.create_then_commit/1, boundaries: boundaries))

        refute line =~ "CANARY"
        Agent.stop(store)
      end
    end
  end

  describe "malformed declarations" do
    test "each is an infrastructure failure that runs no adapter", %{store: store} do
      test_pid = self()

      watched =
        store
        |> declaration(&Host.create_then_commit/1)
        |> Map.merge(%{
          fixture: fn ->
            send(test_pid, :adapter_called)
            Host.fixture(store)
          end,
          stub: fn module, name, fun ->
            send(test_pid, :adapter_called)
            Provider.stub(module, name, fun)
          end
        })

      [create, link] = watched.boundaries
      fault = watched.fault

      with_boundary = fn changes ->
        %{watched | boundaries: [Map.merge(create, changes), link]}
      end

      without_effect = Map.drop(create, [:effect, :expect])

      cases = [
        {"not a map", "invalid_declaration"},
        {%{"operation" => "string keys"}, "invalid_declaration"},
        {[operation: "x", operation: "y"], "invalid_declaration"},
        {Map.put(watched, :retries, 3), "unknown_field"},
        {Map.delete(watched, :perform), "missing_field"},
        {%{watched | operation: ""}, "invalid_operation"},
        {%{watched | operation: "line\nbreak"}, "invalid_operation"},
        {%{watched | operation: String.duplicate("a", 256)}, "invalid_operation"},
        {Map.put(watched, :context, "tab\there"), "invalid_context"},
        {%{watched | fixture: fn _ignored -> :ok end}, "invalid_fixture"},
        {%{watched | perform: fn -> :ok end}, "invalid_perform"},
        {Map.put(watched, :succeeded?, :yes), "invalid_succeeded_check"},
        {%{watched | stub: fn _module, _name -> :ok end}, "invalid_stub"},
        {%{watched | references: fn -> [] end}, "invalid_references"},
        {Map.put(watched, :attempts, 1), "invalid_attempts"},
        {Map.put(watched, :attempts, 9), "invalid_attempts"},
        {%{watched | boundaries: []}, "invalid_boundaries"},
        {%{watched | boundaries: [create | link]}, "invalid_boundaries"},
        {%{watched | boundaries: List.duplicate(link, 17)}, "invalid_boundaries"},
        {%{watched | boundaries: [:not_a_boundary]}, "invalid_boundary"},
        {with_boundary.(%{name: "Account"}), "invalid_boundary"},
        {with_boundary.(%{function: "create_account"}), "invalid_boundary"},
        {with_boundary.(%{function: {Provider, :module_info}}), "invalid_boundary"},
        {with_boundary.(%{respond: fn _args -> :ok end}), "invalid_boundary"},
        {with_boundary.(%{expect: 65}), "invalid_boundary"},
        {with_boundary.(%{expect: nil}), "invalid_boundary"},
        {with_boundary.(%{key: fn _args, _response -> nil end}), "invalid_boundary"},
        {with_boundary.(%{referenced: :yes}), "invalid_boundary"},
        {with_boundary.(%{retries: 1}), "invalid_boundary"},
        {with_boundary.(%{arities: []}), "invalid_boundary"},
        {with_boundary.(%{arities: [1, 1, 2]}), "invalid_boundary"},
        {%{watched | boundaries: [Map.put(without_effect, :expect, 1), link]},
         "invalid_boundary"},
        {%{watched | boundaries: [Map.put(without_effect, :referenced, false), link]},
         "invalid_boundary"},
        {%{watched | boundaries: [create, %{link | name: "account_create"}]},
         "duplicate_boundary"},
        {%{watched | boundaries: [create, %{create | name: "again"}]}, "duplicate_boundary"},
        {with_boundary.(%{function: {Provider, :missing}}), "function_not_exported"},
        {with_boundary.(%{function: {Insider.Test.NoSuchProvider, :create}}),
         "function_not_exported"},
        {with_boundary.(%{function: {Provider, :wide}}), "unsupported_arity"},
        {with_boundary.(%{arities: [1]}), "arity_not_covered"},
        {with_boundary.(%{arities: [1, 2, 3]}), "arity_not_exported"},
        {with_boundary.(%{expect: 0}), "no_expected_effect"},
        {%{watched | fault: :boom}, "invalid_fault"},
        {%{watched | fault: Map.delete(fault, :result)}, "invalid_fault"},
        {%{watched | fault: Map.put(fault, :call, 0)}, "invalid_fault"},
        {%{watched | fault: Map.put(fault, :call, 65)}, "invalid_fault"},
        {%{watched | fault: Map.put(fault, :attempts, 2)}, "invalid_fault"},
        {%{watched | fault: Map.put(fault, :lost_response, "yes")}, "invalid_fault"},
        {%{watched | fault: %{fault | result: {:raise, "not an exception"}}}, "invalid_fault"},
        {%{watched | fault: %{fault | result: :boom}}, "invalid_fault"},
        {%{watched | fault: Map.put(fault, :after, 1)}, "invalid_fault"},
        {%{watched | fault: %{fault | boundary: "missing"}}, "unknown_fault_boundary"}
      ]

      for {declaration, reason} <- cases do
        {report, _line} = run(declaration)

        assert {report["reason"], report["completeness"], report["outcome"], report["control"],
                report["fault_run"]} ==
                 {reason, "infrastructure_failure", "infrastructure_failure", nil, nil},
               "#{inspect(declaration)} should be #{reason}"
      end

      refute_received :adapter_called
    end

    test "an invalid declaration echoes only a valid operation and context", %{store: store} do
      declaration = Map.put(declaration(store, &Host.create_then_commit/1), :retries, 3)
      {report, _line} = run(declaration)
      assert report["operation"] == "open the order's provider account"
      assert report["context"] == "fault rerun unit"
      assert report["boundaries"] == [] and report["fault"] == nil

      {report, _line} = run(%{operation: "line\nbreak", context: "fine", retries: 1})
      assert report["operation"] == nil
      assert report["context"] == "fine"
    end

    test "keyword declarations, boundaries, and faults are accepted", %{store: store} do
      declaration =
        store
        |> declaration(&Host.create_then_commit/1)
        |> Map.update!(:boundaries, fn boundaries -> Enum.map(boundaries, &Map.to_list/1) end)
        |> Map.update!(:fault, &Map.to_list/1)
        |> Map.to_list()

      {report, _line} = run(declaration)
      assert report["outcome"] == "confirmed"
    end
  end

  describe "in a separate ExUnit run" do
    test "a probe that requires the artifact prints one line per run" do
      suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      tmp_dir = Path.join(System.tmp_dir!(), "insider-fault-rerun-fixture-" <> suffix)
      File.mkdir!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      bootstrap = Path.join(tmp_dir, "bootstrap.exs")
      probe = Path.join(tmp_dir, "probe_test.exs")
      File.write!(bootstrap, "ExUnit.start(autorun: true)\n")
      File.write!(probe, probe_source(@artifact))
      executable = System.find_executable("elixir") || flunk("elixir executable unavailable")

      {status, output} =
        OracleArtifactRunner.run_process(
          executable,
          ["-r", bootstrap, probe],
          [],
          tmp_dir,
          120_000
        )

      assert status == 0, output
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 2

      reports =
        output
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, @prefix))
        |> Enum.map(&Jason.decode!(String.replace_prefix(&1, @prefix, "")))
        |> Map.new(&{&1["operation"], &1})

      assert reports["insert after the remote create"]["outcome"] == "confirmed"
      assert reports["insert before the fallible call"]["outcome"] == "not_reproduced"
      refute output =~ "PROBE-SECRET"
    end
  end

  # An ExUnit probe with an ETS table as committed state and a provider
  # module that dispatches to a process-dictionary stub, written the way an
  # agent writes one against a real target.
  defp probe_source(artifact) do
    """
    Code.require_file(#{inspect(artifact)})

    defmodule FaultRerunProbeProvider do
      def stub(__MODULE__, name, fun), do: Process.put({name, :erlang.fun_info(fun)[:arity]}, fun)
      def create(owner), do: Process.get({:create, 1}).(owner)
      def tag(id, label), do: Process.get({:tag, 2}).(id, label)
    end

    defmodule FaultRerunProbeTest do
      use ExUnit.Case

      alias InsiderLab.FaultRerunOracle, as: Oracle

      setup do
        {:ok, table: :ets.new(:rows, [:public])}
      end

      test "insert after the remote create", %{table: table} do
        report =
          Oracle.run(declaration(table, "insert after the remote create", fn row ->
            with {:ok, id} <- FaultRerunProbeProvider.create(row),
                 :ok <- FaultRerunProbeProvider.tag(id, "PROBE-SECRET") do
              :ets.insert(table, {row, id})
              :ok
            end
          end))

        assert report["outcome"] == "confirmed"
      end

      test "insert before the fallible call", %{table: table} do
        report =
          Oracle.run(declaration(table, "insert before the fallible call", fn row ->
            id =
              case :ets.lookup(table, row) do
                [{^row, id}] -> id
                [] -> with {:ok, id} <- FaultRerunProbeProvider.create(row), do: :ets.insert(table, {row, id}) && id
              end

            FaultRerunProbeProvider.tag(id, "PROBE-SECRET")
          end))

        assert report["outcome"] == "not_reproduced"
      end

      defp declaration(table, operation, worker) do
        %{
          operation: operation,
          fixture: fn -> System.unique_integer([:positive]) end,
          perform: worker,
          stub: &FaultRerunProbeProvider.stub/3,
          boundaries: [
            %{
              name: "create",
              function: {FaultRerunProbeProvider, :create},
              respond: fn _args, call -> {:ok, "PROBE-SECRET-\#{call.sequence}"} end,
              effect: fn _args, {:ok, id} -> id end,
              expect: 1
            },
            %{name: "tag", function: {FaultRerunProbeProvider, :tag}, respond: fn _args, _call -> :ok end}
          ],
          fault: %{boundary: "tag", result: {:return, {:error, :unavailable}}},
          references: fn row -> %{create: for({^row, id} <- :ets.lookup(table, row), do: id)} end
        }
      end
    end
    """
  end

  defp declaration(store, perform, overrides \\ []) do
    %{
      operation: "open the order's provider account",
      context: "fault rerun unit",
      fixture: fn -> Host.fixture(store) end,
      perform: perform,
      stub: &Provider.stub/3,
      boundaries: boundaries([]),
      fault: %{boundary: "category_link", result: {:return, {:error, :unavailable}}},
      references: &Host.references/1
    }
    |> Map.merge(Map.new(overrides))
  end

  defp boundaries(options) do
    create =
      %{
        name: "account_create",
        function: {Provider, :create_account},
        respond: Keyword.get(options, :create_respond, &account/2),
        effect: Keyword.get(options, :effect, fn _args, {:ok, %{"id" => id}} -> id end),
        expect: Keyword.get(options, :expect, 1),
        key: Keyword.get(options, :key, &idempotency_key/1)
      }

    link =
      %{
        name: "category_link",
        function: {Provider, :link},
        respond: Keyword.get(options, :link_respond, fn _args, _call -> :ok end)
      }

    link =
      case Keyword.fetch(options, :link_arities) do
        {:ok, arities} -> Map.put(link, :arities, arities)
        :error -> link
      end

    [create, link]
  end

  defp account([owner | _options], call),
    do: {:ok, %{"id" => "acct-#{call.sequence}", "owner" => owner}}

  defp idempotency_key([_owner]), do: nil
  defp idempotency_key([_owner, options]), do: Keyword.get(options, :idempotency_key)

  # A bounded barrier: returns once a second caller for `owner` has arrived,
  # or after `remaining` milliseconds.
  defp await_second(arrivals, owner, remaining) do
    cond do
      Agent.get(arrivals, &Map.get(&1, owner, 0)) >= 2 ->
        :arrived

      remaining <= 0 ->
        :alone

      true ->
        receive do
        after
          5 -> await_second(arrivals, owner, remaining - 5)
        end
    end
  end

  defp boundary(scenario, name), do: Enum.find(scenario["boundaries"], &(&1["boundary"] == name))

  # Runs the oracle, requires exactly one prefixed line, and checks that the
  # line decodes to the returned report.
  defp run(declaration) do
    {report, output} = with_io(fn -> Oracle.run(declaration) end)
    lines = String.split(output, "\n", trim: true)
    assert [line] = lines
    assert String.starts_with?(line, @prefix)
    assert Jason.decode!(String.replace_prefix(line, @prefix, "")) == report
    {report, line}
  end

  defp canary_term do
    leaf =
      one_of([
        map(string(:alphanumeric), &("CANARY" <> &1)),
        integer(),
        boolean(),
        constant(nil)
      ])

    key = member_of(~w(id name amount items node edges total data))

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 4), map_of(key, child, max_length: 4)])
    end)
  end
end
