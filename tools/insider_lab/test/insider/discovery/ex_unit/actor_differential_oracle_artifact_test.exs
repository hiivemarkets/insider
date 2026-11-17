Code.require_file(Application.app_dir(:insider_lab, "priv/probes/actor_differential.exs"))

defmodule Insider.Discovery.ExUnit.ActorDifferentialOracleArtifactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Insider.Test.ActorDifferentialHost, as: Host
  alias Insider.Test.OracleArtifactRunner
  alias InsiderLab.ActorDifferentialOracle, as: Oracle

  @artifact Application.app_dir(:insider_lab, "priv/probes/actor_differential.exs")

  @prefix "INSIDER_ACTOR_DIFFERENTIAL_ORACLE="

  setup do
    {:ok, store: start_supervised!(Host)}
  end

  describe "verdicts" do
    test "an actor the host wrongly lets withdraw the bid is confirmed", %{store: store} do
      {report, _line} = run(declaration(store, &Host.any_party/2))

      assert report["completeness"] == "complete"
      assert report["outcome"] == "confirmed"
      assert report["reason"] == nil

      [bidder, seller, stranger] = report["actors"]
      assert bidder["control"] and bidder["observed_access"] == "granted"
      assert bidder["verdict"] == nil

      assert seller["observed_access"] == "granted"
      assert seller["verdict"] == "confirmed"
      assert seller["reason"] == "wrongly_granted"
      assert seller["response"]["type_names"] == ["WithdrawBidSuccess"]
      assert seller["response"]["shape"]["$.data.withdrawBid"] == "object"
      assert seller["response"]["shape"]["$.data.withdrawBid.withdrawnBidId"] == "string"

      assert seller["state"] == [
               %{
                 "key" => "amount",
                 "changed" => false,
                 "before_matches_control" => true,
                 "after_matches_control" => true
               },
               %{
                 "key" => "status",
                 "changed" => true,
                 "before_matches_control" => true,
                 "after_matches_control" => true
               }
             ]

      assert stranger["observed_access"] == "refused"
      assert stranger["verdict"] == "not_reproduced"
      assert stranger["reason"] == "refused_as_declared"
      assert stranger["response"]["error_codes"] == ["UNAUTHORIZED"]
      assert stranger["response"]["shape"]["$.data.withdrawBid"] == "null"
    end

    test "a host that scopes every actor correctly is not reproduced", %{store: store} do
      {report, _line} = run(declaration(store, &Host.bidder_only/2))

      assert report["completeness"] == "complete"
      assert report["outcome"] == "not_reproduced"

      assert Enum.map(report["actors"], &{&1["name"], &1["verdict"], &1["reason"]}) == [
               {"bidder", nil, nil},
               {"seller", "not_reproduced", "refused_as_declared"},
               {"stranger", "not_reproduced", "refused_as_declared"}
             ]

      refute Enum.any?(tl(report["actors"]), fn actor ->
               Enum.any?(actor["state"], & &1["changed"])
             end)
    end

    test "an entitled non-control actor that is refused is confirmed", %{store: store} do
      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "seller", access: :allow, as: & &1.seller}
      ]

      {report, _line} = run(declaration(store, &Host.bidder_only/2, actors: actors))

      assert report["outcome"] == "confirmed"
      assert List.last(report["actors"])["reason"] == "wrongly_refused"
    end

    test "a granted response that leaves the declared effect undone is confirmed",
         %{store: store} do
      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "seller", access: :allow, as: & &1.seller}
      ]

      request = fn user, fixture ->
        write = if user == fixture.bidder, do: :on_grant, else: :never
        Host.withdraw(fixture, user, &Host.any_party/2, write)
      end

      {report, _line} = run(declaration(store, nil, actors: actors, request: request))

      assert report["outcome"] == "confirmed"
      assert List.last(report["actors"])["reason"] == "granted_without_effect"
    end
  end

  describe "controls" do
    test "a refused control is an infrastructure failure and nobody else is attempted",
         %{store: store} do
      test_pid = self()

      fixture = fn ->
        send(test_pid, :fixture_built)
        Host.fixture(store)
      end

      {report, _line} = run(declaration(store, &Host.nobody/2, fixture: fixture))

      assert report["completeness"] == "infrastructure_failure"
      assert report["outcome"] == "infrastructure_failure"
      assert report["reason"] == "control_unhealthy"

      [bidder, seller, stranger] = report["actors"]
      assert bidder["attempted"] and bidder["reason"] == "control_refused"
      assert bidder["verdict"] == nil

      for actor <- [seller, stranger] do
        assert actor["attempted"] == false
        assert actor["verdict"] == nil
        assert actor["response"] == nil
      end

      assert_received :fixture_built
      refute_received :fixture_built
    end

    test "a granted control without the declared effect is unhealthy", %{store: store} do
      request = fn user, fixture -> Host.withdraw(fixture, user, &Host.bidder_only/2, :never) end

      {report, _line} = run(declaration(store, nil, request: request))

      assert report["reason"] == "control_unhealthy"
      assert hd(report["actors"])["reason"] == "control_effect_missing"
    end

    test "a control whose fixture raises is unhealthy and names only the stage and module",
         %{store: store} do
      fixture = fn -> raise ArgumentError, "secret-fixture-detail" end

      {report, line} = run(declaration(store, &Host.bidder_only/2, fixture: fixture))

      assert report["outcome"] == "infrastructure_failure"
      [bidder | _rest] = report["actors"]
      assert bidder["attempted"] == false
      assert bidder["reason"] == "fixture_failed"

      assert bidder["error"] == %{
               "stage" => "fixture",
               "kind" => "error",
               "exception" => "ArgumentError"
             }

      refute line =~ "secret-fixture-detail"
    end

    test "a refusal control that is granted is unhealthy", %{store: store} do
      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "stranger", access: :deny, control: true, as: & &1.stranger},
        %{name: "seller", access: :deny, as: & &1.seller}
      ]

      {report, _line} = run(declaration(store, &Host.everybody/2, actors: actors))

      assert report["outcome"] == "infrastructure_failure"
      assert report["reason"] == "denial_control_unhealthy"

      assert Enum.map(report["actors"], &{&1["name"], &1["attempted"], &1["reason"]}) == [
               {"bidder", true, nil},
               {"stranger", true, "control_granted"},
               {"seller", false, nil}
             ]
    end

    test "a refusal control that holds lets compared actors receive verdicts",
         %{store: store} do
      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "stranger", access: :deny, control: true, as: & &1.stranger},
        %{name: "seller", access: :deny, as: & &1.seller}
      ]

      {report, _line} = run(declaration(store, &Host.any_party/2, actors: actors))

      assert report["outcome"] == "confirmed"

      assert Enum.map(report["actors"], &{&1["name"], &1["verdict"]}) == [
               {"bidder", nil},
               {"stranger", nil},
               {"seller", "confirmed"}
             ]
    end
  end

  describe "database state" do
    test "a refused request that still changes state is confirmed", %{store: store} do
      request = fn user, fixture -> Host.withdraw(fixture, user, &Host.bidder_only/2, :always) end

      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "seller", access: :deny, as: & &1.seller}
      ]

      {report, _line} = run(declaration(store, nil, request: request, actors: actors))

      seller = List.last(report["actors"])
      assert seller["observed_access"] == "refused"
      assert seller["verdict"] == "confirmed"
      assert seller["reason"] == "state_changed_while_refused"
      assert Enum.find(seller["state"], &(&1["key"] == "status"))["changed"]
    end

    test "an actor whose fixture starts from a different state is not observed",
         %{store: store} do
      fixture = fn ->
        fixture = Host.fixture(store)

        if fixture.bid_id != "bid-1" do
          Agent.update(store, &put_in(&1, [:bids, fixture.bid_id, :amount], 10))
        end

        fixture
      end

      {report, _line} = run(declaration(store, &Host.any_party/2, fixture: fixture))

      assert report["outcome"] == "not_observed"

      for actor <- tl(report["actors"]) do
        assert actor["verdict"] == "not_observed"
        assert actor["reason"] == "initial_state_differs_from_control"

        assert Enum.find(actor["state"], &(&1["key"] == "amount"))["before_matches_control"] ==
                 false
      end
    end

    test "a failing state capture after the request is not observed", %{store: store} do
      # The seller's request is refused but writes; the final capture then fails,
      # so the oracle cannot say whether the refusal left state alone.
      request = fn user, fixture -> Host.withdraw(fixture, user, &Host.bidder_only/2, :always) end

      state = fn fixture ->
        if fixture.bid_id == "bid-2" and Host.bid(fixture).status == :withdrawn,
          do: exit(:state_unavailable),
          else: Host.state(fixture)
      end

      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "seller", access: :deny, as: & &1.seller}
      ]

      {report, _line} =
        run(declaration(store, nil, state: state, request: request, actors: actors))

      seller = List.last(report["actors"])
      assert report["outcome"] == "not_observed"
      assert seller["observed_access"] == "refused"
      assert seller["verdict"] == "not_observed"
      assert seller["reason"] == "state_after_failed"
      assert seller["error"] == %{"stage" => "state_after", "kind" => "exit", "exception" => nil}
      assert Enum.all?(seller["state"], &is_nil(&1["changed"]))
    end

    test "a request that raises for a compared actor is not observed", %{store: store} do
      request = fn user, fixture ->
        if user == fixture.seller,
          do: raise(RuntimeError, "boom"),
          else: Host.withdraw(fixture, user, &Host.bidder_only/2)
      end

      {report, _line} = run(declaration(store, nil, request: request))

      assert report["outcome"] == "not_observed"
      seller = Enum.at(report["actors"], 1)
      assert seller["reason"] == "request_failed"
      assert seller["response"] == nil
      assert seller["error"]["exception"] == "RuntimeError"
    end

    test "a read without state compares only the response", %{store: store} do
      request = fn user, fixture ->
        bid = Host.bid(fixture)

        if user in [bid.bidder, bid.seller],
          do: %{"data" => %{"bid" => %{"amount" => bid.amount, "status" => "OPEN"}}},
          else: %{"data" => %{"bid" => nil}, "errors" => [%{"code" => "NOT_FOUND"}]}
      end

      allowed? = &match?(%{"data" => %{"bid" => %{}}}, &1)

      {report, line} =
        run(
          declaration(store, nil,
            request: request,
            allowed?: allowed?,
            state: nil,
            effect: []
          )
        )

      [_bidder, seller, stranger] = report["actors"]
      assert report["outcome"] == "confirmed"
      assert seller["response"]["matches_control"] == true
      assert seller["state"] == []
      assert stranger["response"]["matches_control"] == false
      assert stranger["response"]["error_codes"] == ["NOT_FOUND"]
      refute line =~ "OPEN"
    end
  end

  describe "fingerprint bounds" do
    # The fingerprint limit is 1,048,576 bytes of external term format; a
    # binary costs its size plus 6 bytes, so 1,048,570 bytes is exactly at it.
    @at_limit 1_048_570

    test "a struct state value, such as a money amount or date, is fingerprinted",
         %{store: store} do
      state = fn fixture -> Map.put(Host.state(fixture), :listed_on, ~D[2026-10-21]) end

      {report, _line} = run(declaration(store, &Host.any_party/2, state: state))

      assert report["outcome"] == "confirmed"
      assert state_key(Enum.at(report["actors"], 1), "listed_on")["before_matches_control"]
    end

    test "different initial values exactly at the byte limit are compared",
         %{store: store} do
      {report, _line} = run(content_declaration(store, @at_limit))

      assert report["outcome"] == "not_observed"

      for actor <- tl(report["actors"]) do
        assert actor["reason"] == "initial_state_differs_from_control"
        assert state_key(actor, "content")["before_matches_control"] == false
      end
    end

    test "different initial values over the byte limit are not comparable, never equal",
         %{store: store} do
      {report, _line} = run(content_declaration(store, @at_limit + 1))

      assert report["completeness"] == "complete"
      assert report["outcome"] == "not_observed"

      for actor <- tl(report["actors"]) do
        assert actor["verdict"] == "not_observed"
        assert actor["reason"] == "initial_state_not_comparable"
        assert state_key(actor, "content")["before_matches_control"] == nil
      end
    end

    test "a refusal control whose initial state is not comparable is unhealthy",
         %{store: store} do
      actors = [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "stranger", access: :deny, control: true, as: & &1.stranger},
        %{name: "seller", access: :deny, as: & &1.seller}
      ]

      {report, _line} = run(content_declaration(store, @at_limit + 1, actors: actors))

      assert report["reason"] == "denial_control_unhealthy"

      assert Enum.map(report["actors"], &{&1["name"], &1["attempted"], &1["reason"]}) == [
               {"bidder", true, nil},
               {"stranger", true, "initial_state_not_comparable"},
               {"seller", false, nil}
             ]
    end

    @tag timeout: 30_000
    test "a shared term whose external size explodes is not sized or serialized",
         %{store: store} do
      # 30 levels of {t, t}: a few hundred words resident, about 2^30 terms
      # when traversed, which `:erlang.external_size/1` would walk in full.
      shared = Enum.reduce(1..30, :leaf, fn _level, inner -> {inner, inner} end)

      request = fn user, fixture ->
        Map.put(Host.withdraw(fixture, user, &Host.bidder_only/2), "blob", shared)
      end

      state = fn fixture -> Map.put(Host.state(fixture), :blob, shared) end

      {microseconds, {report, _line}} =
        :timer.tc(fn -> run(declaration(store, nil, request: request, state: state)) end)

      assert microseconds < 2_000_000
      assert report["outcome"] == "not_observed"

      for actor <- tl(report["actors"]) do
        assert actor["reason"] == "initial_state_not_comparable"
        assert actor["response"]["matches_control"] == nil
        assert state_key(actor, "blob")["changed"] == nil
      end
    end

    test "a value with more terms than the node limit is not comparable", %{store: store} do
      many = Enum.to_list(1..70_000)

      request = fn user, fixture ->
        Map.put(Host.withdraw(fixture, user, &Host.bidder_only/2), "many", many)
      end

      {report, _line} = run(declaration(store, nil, request: request))

      assert report["outcome"] == "not_reproduced"
      assert Enum.all?(report["actors"], &(&1["response"]["matches_control"] == nil))
      assert report["limits"]["fingerprint_term_limit"] == 65_536
    end
  end

  # The control's fixture (bid-1) projects `a` bytes, every later fixture `b`
  # bytes of the same length, next to the comparable bid status.
  defp content_declaration(store, bytes, overrides \\ []) do
    state = fn fixture ->
      letter = if fixture.bid_id == "bid-1", do: "a", else: "b"
      Map.put(Host.state(fixture), :content, String.duplicate(letter, bytes))
    end

    declaration(store, &Host.any_party/2, Keyword.put(overrides, :state, state))
  end

  defp state_key(actor, key), do: Enum.find(actor["state"], &(&1["key"] == key))

  describe "bounded output" do
    test "a large response is summarized within the limits and never echoes values",
         %{store: store} do
      wide = Map.new(1..500, &{"field_#{&1}", "CANARY-VALUE-#{&1}"})
      deep = Enum.reduce(1..20, "CANARY-DEEP", fn _level, inner -> %{"next" => inner} end)
      long = List.duplicate(%{"item" => "CANARY-ITEM"}, 10_000)
      opaque = %{"CANARY KEY with spaces" => 1, "0leading" => 2}

      codes =
        Enum.map(1..20, &%{"code" => "CODE_#{&1}"}) ++
          [%{"code" => "CANARY CODE"}, %{"extensions" => %{"code" => "EXT_CODE"}}]

      request = fn user, fixture ->
        base = Host.withdraw(fixture, user, &Host.bidder_only/2)

        Map.merge(base, %{
          "wide" => wide,
          "deep" => deep,
          "long" => long,
          "opaque" => opaque,
          "errors" => codes
        })
      end

      allowed? = &match?(%{"data" => %{"withdrawBid" => %{}}}, &1)
      {report, line} = run(declaration(store, nil, request: request, allowed?: allowed?))

      assert report["completeness"] == "truncated"
      assert report["outcome"] == "not_reproduced"

      for actor <- report["actors"] do
        response = actor["response"]
        assert response["truncated"]
        assert map_size(response["shape"]) <= 64
        assert Enum.count_until(response["error_codes"], 17) <= 16
        assert response["error_codes_withheld"] == 1
        assert Enum.all?(Map.keys(response["shape"]), &(byte_size(&1) <= 255))
      end

      refute line =~ "CANARY"
      assert byte_size(line) < 64 * 1_024
    end

    test "the report states its limits and limitations", %{store: store} do
      {report, _line} = run(declaration(store, &Host.bidder_only/2))

      assert report["schema"] == "insider.actor-differential-oracle/v1"
      assert report["operation"] == "withdraw the bidder's bid"
      assert report["context"] == "actor differential unit"

      assert report["limits"] == %{
               "actor_limit" => 16,
               "operation_byte_limit" => 255,
               "context_byte_limit" => 1_024,
               "state_key_limit" => 16,
               "shape_path_limit" => 64,
               "shape_depth_limit" => 8,
               "shape_node_limit" => 4_096,
               "path_byte_limit" => 255,
               "type_name_limit" => 16,
               "error_code_limit" => 16,
               "fingerprint_value_byte_limit" => 1_048_576,
               "fingerprint_term_limit" => 65_536
             }

      assert "declared_actors_are_not_exhaustive" in report["limitations"]
      assert "fixture_is_rebuilt_for_each_actor" in report["limitations"]
    end

    property "no generated response value reaches the line" do
      check all(response <- response_term(), max_runs: 50) do
        {:ok, store} = Host.start_link([])

        request = fn user, fixture ->
          Map.put(Host.withdraw(fixture, user, &Host.bidder_only/2), "extra", response)
        end

        {_report, line} = run(declaration(store, nil, request: request))
        refute line =~ "CANARY"
        Agent.stop(store)
      end
    end
  end

  describe "malformed declarations" do
    test "each is an infrastructure failure that runs no adapter", %{store: store} do
      test_pid = self()
      valid = declaration(store, &Host.bidder_only/2)

      watched =
        Map.put(valid, :fixture, fn ->
          send(test_pid, :adapter_called)
          Host.fixture(store)
        end)

      control = %{name: "bidder", access: :allow, control: true, as: & &1.bidder}
      compared = %{name: "seller", access: :deny, as: & &1.seller}

      cases = [
        {"not a map", "invalid_declaration"},
        {%{"operation" => "string keys"}, "invalid_declaration"},
        {[operation: "x", operation: "y"], "invalid_declaration"},
        {Map.put(watched, :retries, 3), "unknown_field"},
        {Map.delete(watched, :request), "missing_field"},
        {%{watched | operation: ""}, "invalid_operation"},
        {%{watched | operation: "line\nbreak"}, "invalid_operation"},
        {%{watched | operation: String.duplicate("a", 256)}, "invalid_operation"},
        {Map.put(watched, :context, "tab\there"), "invalid_context"},
        {%{watched | fixture: fn _ignored -> :ok end}, "invalid_fixture"},
        {%{watched | request: fn _one -> :ok end}, "invalid_request"},
        {%{watched | allowed?: :yes}, "invalid_allowed_check"},
        {%{watched | state: fn -> %{} end}, "invalid_state"},
        {%{watched | state: nil}, "invalid_effect"},
        {%{watched | effect: [:status, "status"]}, "invalid_effect"},
        {%{watched | effect: ["not an identifier"]}, "invalid_effect"},
        {%{watched | effect: [:status | :invalid]}, "invalid_effect"},
        {%{watched | effect: Enum.map(1..17, &"key_#{&1}")}, "invalid_effect"},
        {%{watched | actors: [control]}, "invalid_actors"},
        {%{watched | actors: List.duplicate(compared, 17)}, "invalid_actors"},
        {%{watched | actors: [control, %{compared | access: :maybe}]}, "invalid_actor"},
        {%{watched | actors: [control, %{compared | name: "Seller"}]}, "invalid_actor"},
        {%{watched | actors: [control, Map.put(compared, :role, "x")]}, "invalid_actor"},
        {%{watched | actors: [control, %{compared | as: fn -> :ok end}]}, "invalid_actor"},
        {%{watched | actors: [control, %{compared | name: "bidder"}]}, "duplicate_actor"},
        {%{watched | actors: [%{control | control: false}, compared]}, "missing_allow_control"},
        {%{watched | actors: [Map.put(compared, :control, true), control]}, "no_compared_actor"}
      ]

      for {declaration, reason} <- cases do
        {report, _line} = run(declaration)

        assert {report["reason"], report["completeness"], report["outcome"], report["actors"]} ==
                 {reason, "infrastructure_failure", "infrastructure_failure", []},
               "#{inspect(declaration)} should be #{reason}"
      end

      refute_received :adapter_called
    end

    test "an invalid declaration echoes only a valid operation and context", %{store: store} do
      {report, _line} = run(Map.put(declaration(store, &Host.bidder_only/2), :retries, 3))
      assert report["operation"] == "withdraw the bidder's bid"
      assert report["context"] == "actor differential unit"

      {report, _line} = run(%{operation: "line\nbreak", context: "fine", retries: 1})
      assert report["operation"] == nil
      assert report["context"] == "fine"
    end

    test "keyword declarations and actors are accepted", %{store: store} do
      declaration =
        store
        |> declaration(&Host.any_party/2)
        |> Map.update!(:actors, fn actors -> Enum.map(actors, &Map.to_list/1) end)
        |> Map.to_list()

      {report, _line} = run(declaration)
      assert report["outcome"] == "confirmed"
    end
  end

  describe "in a separate ExUnit run" do
    test "a probe that requires the artifact prints one line per differential" do
      suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      tmp_dir = Path.join(System.tmp_dir!(), "insider-actor-differential-fixture-" <> suffix)
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

      assert reports["withdraw as any party"]["outcome"] == "confirmed"
      assert reports["withdraw as the bidder only"]["outcome"] == "not_reproduced"
      refute output =~ "PROBE-SECRET"
    end
  end

  # An ExUnit probe with an ETS bid table as its host, written the way an
  # agent writes one against a real target.
  defp probe_source(artifact) do
    """
    Code.require_file(#{inspect(artifact)})

    defmodule ActorDifferentialProbeTest do
      use ExUnit.Case

      alias InsiderLab.ActorDifferentialOracle, as: Oracle

      setup do
        {:ok, table: :ets.new(:bids, [:public])}
      end

      test "withdraw as any party", %{table: table} do
        report = Oracle.run(declaration(table, "withdraw as any party", &(&1 in [&2.bidder, &2.seller])))
        assert report["outcome"] == "confirmed"
      end

      test "withdraw as the bidder only", %{table: table} do
        report = Oracle.run(declaration(table, "withdraw as the bidder only", &(&1 == &2.bidder)))
        assert report["outcome"] == "not_reproduced"
      end

      defp declaration(table, operation, policy) do
        %{
          operation: operation,
          fixture: fn ->
            id = System.unique_integer([:positive])
            :ets.insert(table, {id, :open})
            %{id: id, bidder: {:bidder, id}, seller: {:seller, id}, stranger: {:stranger, id}}
          end,
          actors: [
            %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
            %{name: "seller", access: :deny, as: & &1.seller},
            %{name: "stranger", access: :deny, as: & &1.stranger}
          ],
          request: fn user, fixture ->
            if policy.(user, fixture) do
              :ets.insert(table, {fixture.id, :withdrawn})
              %{"data" => %{"withdrawBid" => %{"note" => "PROBE-SECRET"}}}
            else
              %{"data" => %{"withdrawBid" => nil}, "errors" => [%{"code" => "UNAUTHORIZED"}]}
            end
          end,
          allowed?: &match?(%{"data" => %{"withdrawBid" => %{}}}, &1),
          state: fn fixture ->
            [{_id, status}] = :ets.lookup(table, fixture.id)
            %{status: status}
          end,
          effect: [:status]
        }
      end
    end
    """
  end

  defp declaration(store, policy, overrides \\ []) do
    %{
      operation: "withdraw the bidder's bid",
      context: "actor differential unit",
      fixture: fn -> Host.fixture(store) end,
      actors: [
        %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
        %{name: "seller", access: :deny, as: & &1.seller},
        %{name: "stranger", access: :deny, as: & &1.stranger}
      ],
      request: fn user, fixture -> Host.withdraw(fixture, user, policy) end,
      allowed?: &Host.granted?/1,
      state: &Host.state/1,
      effect: [:status]
    }
    |> Map.merge(Map.new(overrides))
  end

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

  defp response_term do
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
