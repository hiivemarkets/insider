defmodule Insider.Sentinel.MinimizerTest do
  use ExUnit.Case, async: true

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Minimizer
  alias Insider.Sentinel.Minimizer.Record
  alias Insider.Sentinel.Minimizer.Result, as: MinimizationResult
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.ConfirmationProvider
  alias Insider.TestSupport.MinimizerBaselineNondeterministicBody
  alias Insider.TestSupport.MinimizerBlockingBody
  alias Insider.TestSupport.MinimizerConfirmationBody
  alias Insider.TestSupport.MinimizerNondeterministicBody

  @observer %{"id" => "test.confirmation-observer", "version" => 1}

  # The provider release of a sandbox run gets the cleanup budget minus the
  # registry's 50 ms inventory reserve. A busy CI node can stall the release
  # for longer than the rest of a small budget.
  @blocker_cleanup_timeout_ms 1_000

  setup do
    executor =
      start_supervised!(
        {Executor,
         name: nil,
         providers: [ConfirmationProvider],
         bodies: [
           MinimizerConfirmationBody,
           MinimizerBaselineNondeterministicBody,
           MinimizerBlockingBody,
           MinimizerNondeterministicBody
         ]}
      )

    %{executor: executor}
  end

  test "shrinks a live incident scenario to a one-step minimum with fresh evidence", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-complete")

    assert {:ok, %MinimizationResult{record: %Record{} = record} = result} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    assert record.status == "completed"
    assert record.reason == "one_step_minimal"
    assert record.minimality == "one_step_minimal_under_policy"
    assert record.baseline["decision"] == "failed"
    assert [_, _] = record.baseline["record_ids"]
    assert Enum.map(record.trials, & &1["decision"]) == ["preserved", "rejected", "preserved"]

    assert Enum.map(record.trials, & &1["removed_step_id"]) == [
             "redundant-before",
             "required",
             "redundant-after"
           ]

    assert record.usage == %{
             "accepted_candidates" => 2,
             "confirmation_runs" => 11,
             "duration_us" => record.usage["duration_us"],
             "evaluated_candidates" => 3,
             "rejected_candidates" => 1
           }

    assert record.usage["duration_us"] >= 0
    assert record.usage["duration_us"] <= record.policy["max_duration_ms"] * 1_000
    assert record.policy["duration_scope"] == "execution_search"

    assert record.policy["max_total_bytes"] ==
             record.policy["per_run_max_bytes"] * record.policy["max_confirmation_runs"]

    assert record.policy["max_total_events"] ==
             record.policy["per_run_max_events"] * record.policy["max_confirmation_runs"]

    assert record.cleanup == %{"active" => 0, "quarantined" => 0, "status" => "complete"}
    assert record.uncertainty == []

    assert {:ok, minimized} = Regression.decode_map(record.minimized_regression)
    assert {:ok, minimized_scenario} = Scenario.decode_map(minimized.scenario)
    assert Enum.map(minimized_scenario.steps, & &1["id"]) == ["required"]
    assert minimized_scenario.steps == [Enum.at(inputs.scenario.steps, 1)]

    all_record_ids =
      record.baseline["record_ids"] ++ Enum.flat_map(record.trials, & &1["record_ids"])

    assert [_, _, _, _, _, _, _, _, _, _, _] = all_record_ids
    assert Enum.uniq(all_record_ids) == all_record_ids
    assert Enum.map(result.confirmation_records, & &1.id) == all_record_ids

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               result.confirmation_records
             )

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               Enum.reverse(result.confirmation_records)
             )

    assert {:ok, bytes} = Record.canonical_binary(record)
    assert {:ok, ^record} = Record.decode(bytes)
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "stops on mixed candidate outcomes instead of claiming a minimum", %{executor: executor} do
    inputs = inputs!(executor, "minimizer-nondeterministic")
    counter = :atomics.new(1, signed: false)
    key = {MinimizerNondeterministicBody, inputs.scenario.seed}
    :persistent_term.put(key, counter)
    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:ok, %MinimizationResult{record: %Record{} = record, confirmation_records: evidence}} =
             minimize(executor, inputs, MinimizerNondeterministicBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    assert record.status == "inconclusive"
    assert record.reason == "candidate_nondeterministic"
    assert record.minimality == "not_proven"
    assert Enum.map(record.trials, & &1["decision"]) == ["nondeterministic"]

    assert hd(record.trials)["outcomes"] == [
             "matching_failure",
             "nonreproduced",
             "matching_failure"
           ]

    assert record.usage["confirmation_runs"] == 5
    assert record.cleanup["status"] == "complete"
    assert record.uncertainty == ["candidate reproduction was nondeterministic"]

    for {cleanup, reason, uncertainty} <- [
          {%{"active" => 0, "quarantined" => 1, "status" => "incomplete"}, "executor_not_clean",
           "sandbox executor retained active or quarantined work"},
          {%{"active" => nil, "quarantined" => nil, "status" => "unknown"},
           "executor_state_unknown", "sandbox executor cleanup state could not be established"}
        ] do
      wire =
        record
        |> Record.to_wire_map()
        |> Map.merge(%{
          "reason" => reason,
          "cleanup" => cleanup,
          "uncertainty" => [uncertainty]
        })
        |> readdress_map()

      assert {:ok, graph} = Record.decode_map(wire)
      assert graph.trials == record.trials

      assert {:ok, ^graph} =
               Record.validate_with_evidence(
                 graph,
                 inputs.regression,
                 inputs.capsule,
                 inputs.manifest,
                 inputs.target,
                 evidence
               )
    end
  end

  test "labels mixed baseline outcomes as nondeterministic before candidate search", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-baseline-nondeterministic")
    counter = :atomics.new(1, signed: false)
    key = {MinimizerBaselineNondeterministicBody, inputs.scenario.seed}
    :persistent_term.put(key, counter)
    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:ok, %MinimizationResult{record: %Record{} = record, confirmation_records: evidence}} =
             minimize(executor, inputs, MinimizerBaselineNondeterministicBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    assert record.status == "inconclusive"
    assert record.reason == "baseline_nondeterministic"
    assert record.baseline["decision"] == "nondeterministic"
    assert record.baseline["outcomes"] == ["matching_failure", "nonreproduced"]
    assert record.trials == []
    assert record.usage["confirmation_runs"] == 2
    assert record.uncertainty == ["baseline reproduction was nondeterministic"]

    for {cleanup, reason, uncertainty} <- [
          {%{"active" => 1, "quarantined" => 0, "status" => "incomplete"}, "executor_not_clean",
           "sandbox executor retained active or quarantined work"},
          {%{"active" => nil, "quarantined" => nil, "status" => "unknown"},
           "executor_state_unknown", "sandbox executor cleanup state could not be established"}
        ] do
      wire =
        record
        |> Record.to_wire_map()
        |> Map.merge(%{
          "reason" => reason,
          "cleanup" => cleanup,
          "uncertainty" => [uncertainty]
        })
        |> readdress_map()

      assert {:ok, graph} = Record.decode_map(wire)
      assert graph.baseline == record.baseline

      assert {:ok, ^graph} =
               Record.validate_with_evidence(
                 graph,
                 inputs.regression,
                 inputs.capsule,
                 inputs.manifest,
                 inputs.target,
                 evidence
               )
    end
  end

  test "returns the best known regression without a minimality claim at the candidate bound", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-exhausted")

    assert {:ok, %MinimizationResult{record: %Record{} = record}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 1,
               max_duration_ms: 30_000
             )

    assert record.status == "exhausted"
    assert record.reason == "max_candidates_exhausted"
    assert record.minimality == "not_proven"
    assert Enum.map(record.trials, & &1["decision"]) == ["preserved"]
    assert record.usage["confirmation_runs"] == 5
    assert record.usage["evaluated_candidates"] == 1

    assert {:ok, minimized} = Regression.decode_map(record.minimized_regression)
    assert {:ok, minimized_scenario} = Scenario.decode_map(minimized.scenario)
    assert Enum.map(minimized_scenario.steps, & &1["id"]) == ["required", "redundant-after"]
    assert record.uncertainty == ["candidate bound exhausted before minimality"]
  end

  test "exhausts the total duration before dispatch when fresh evidence cannot fit", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-duration-bound")

    assert {:ok, %MinimizationResult{record: %Record{} = record}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 1_000
             )

    assert record.status == "exhausted"
    assert record.reason == "total_deadline_exhausted"

    assert record.baseline == %{
             "attempt_count" => 0,
             "decision" => "exhausted",
             "outcomes" => [],
             "record_ids" => []
           }

    assert record.trials == []
    assert record.usage["confirmation_runs"] == 0
    assert record.uncertainty == ["duration bound exhausted before minimality"]
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "a one-step source is unchanged only after two fresh baseline confirmations", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-one-step", :one_step)

    assert {:ok, %MinimizationResult{record: %Record{} = record}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    assert record.status == "completed"
    assert record.reason == "unchanged_one_step_minimal"
    assert record.minimized_regression == Regression.to_wire_map(inputs.regression)
    assert record.baseline["decision"] == "failed"
    assert record.baseline["attempt_count"] == 2
    assert record.trials == []
    assert record.usage["confirmation_runs"] == 2
  end

  test "refuses to dispatch into an executor that already owns active work", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-dirty-executor")
    key = {MinimizerBlockingBody, inputs.scenario.seed}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)
    {request, context} = authority!(inputs.target, "minimizer-blocker", 10_000)

    assert {:ok, handle} =
             Sandbox.start_run(executor, inputs.target,
               request: request,
               context: context,
               cleanup_timeout_ms: @blocker_cleanup_timeout_ms,
               body: {MinimizerBlockingBody, %{"seed" => inputs.scenario.seed}, 100}
             )

    assert_receive {:minimizer_blocking_body_started, body}, 5_000

    assert {:ok,
            %MinimizationResult{
              record: %Record{
                status: "inconclusive",
                reason: "executor_not_clean",
                cleanup: %{"status" => "incomplete"},
                usage: %{"confirmation_runs" => 0}
              },
              confirmation_records: []
            }} = minimize(executor, inputs, MinimizerConfirmationBody, max_duration_ms: 5_000)

    send(body, :unexpected_release)

    assert %Insider.Protocol.Result{cleanup: %{remaining_count: 0}} =
             Sandbox.await(handle, @blocker_cleanup_timeout_ms + 4_000)

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "reports unknown executor state without attempting confirmation", %{executor: executor} do
    inputs = inputs!(executor, "minimizer-executor-unavailable")
    assert :ok = Supervisor.stop(executor)

    assert {:ok,
            %MinimizationResult{
              record: %Record{
                status: "inconclusive",
                reason: "executor_state_unknown",
                cleanup: %{"status" => "unknown"},
                usage: %{"confirmation_runs" => 0}
              },
              confirmation_records: []
            }} = minimize(executor, inputs, MinimizerConfirmationBody, max_duration_ms: 5_000)
  end

  test "an error after confirmation admission carries the bounded final cleanup state", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-admitted-error")
    key = {MinimizerBlockingBody, inputs.scenario.seed}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    task =
      Task.async(fn ->
        minimize(executor, inputs, MinimizerBlockingBody,
          max_candidates: 8,
          max_duration_ms: 10_000
        )
      end)

    assert_receive {:minimizer_blocking_body_started, _body}, 5_000
    assert :ok = Supervisor.stop(executor)

    assert {:error,
            %Error{
              code: :operation_failed,
              details: %{
                "minimizer_cleanup" => %{
                  "active" => nil,
                  "quarantined" => nil,
                  "status" => "unknown"
                },
                "minimizer_confirmation_runs" => 1
              }
            }} = Task.await(task, 5_000)
  end

  test "rejects mismatched orchestration inputs before dispatch", %{executor: executor} do
    inputs = inputs!(executor, "minimizer-mismatch")
    {request, context} = authority!(inputs.target, "wrong-operation", 30_000, "scenario.run")

    assert {:error, %Error{code: :minimization_input_mismatch}} =
             Minimizer.run(
               executor,
               inputs.regression,
               inputs.manifest,
               inputs.capsule,
               inputs.target,
               request: request,
               context: context,
               body: MinimizerConfirmationBody,
               observer: @observer
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "rejects invalid minimization bounds and option sets before dispatch", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-invalid-options")
    {request, context} = authority!(inputs.target, "invalid-minimizer-options", 30_000)

    for options <- [
          [max_candidates: 0],
          [max_candidates: 65],
          [max_duration_ms: 0],
          [max_duration_ms: 600_001],
          [unknown: true],
          [max_candidates: 2, max_candidates: 3]
        ] do
      assert {:error, %Error{code: :minimization_input_mismatch}} =
               Minimizer.run(
                 executor,
                 inputs.regression,
                 inputs.manifest,
                 inputs.capsule,
                 inputs.target,
                 [
                   request: request,
                   context: context,
                   body: MinimizerConfirmationBody,
                   observer: @observer
                 ] ++
                   options
               )
    end

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "canonical validation rejects a forged minimization trial sequence", %{executor: executor} do
    inputs = inputs!(executor, "minimizer-forgery")

    assert {:ok, %MinimizationResult{record: record, confirmation_records: records}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    forged =
      record
      |> Record.to_wire_map()
      |> put_in(
        ["trials", Access.at(0), "candidate_scenario_id"],
        "sha256:" <> String.duplicate("f", 64)
      )
      |> readdress_map()

    assert {:error, %Error{code: :invalid_minimization_record}} = Record.decode_map(forged)

    forged_integrity = put_in(forged, ["integrity", "extra"], true)

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.decode_map(forged_integrity)

    zero_evidence =
      record
      |> Record.to_wire_map()
      |> Map.put("baseline", %{
        "attempt_count" => 0,
        "decision" => "failed",
        "outcomes" => [],
        "record_ids" => []
      })
      |> update_in(["usage", "confirmation_runs"], &(&1 - 2))
      |> readdress_map()

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.decode_map(zero_evidence)

    over_duration =
      record
      |> Record.to_wire_map()
      |> put_in(["usage", "duration_us"], record.policy["max_duration_ms"] * 1_000 + 1)
      |> readdress_map()

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.decode_map(over_duration)

    wrong_source =
      record
      |> Record.to_wire_map()
      |> put_in(["source", "regression_id"], "sha256:" <> String.duplicate("e", 64))
      |> readdress_map()

    assert {:ok, standalone} = Record.decode_map(wrong_source)

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.validate_with_evidence(
               standalone,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               records
             )

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.decode(" " <> (Record.canonical_binary(record) |> elem(1)))

    assert {:error, %Error{code: :unsupported_minimization_record_schema}} =
             Record.decode_map(%{"schema" => "insider.minimization-record/v2"})

    assert {:error, %Error{code: :minimization_record_limit_exceeded}} =
             Record.decode(String.duplicate("x", 524_289))
  end

  test "evidence validation rejects an inconclusive verdict contradicted by complete evidence", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-inconclusive-forgery")

    assert {:ok, %MinimizationResult{record: record, confirmation_records: records}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    assert record.status == "completed"
    assert record.baseline["decision"] == "failed"
    assert hd(record.trials)["decision"] == "preserved"

    trial =
      record.trials
      |> hd()
      |> Map.put("decision", "inconclusive")

    forged =
      record
      |> Record.to_wire_map()
      |> Map.merge(%{
        "status" => "inconclusive",
        "reason" => "candidate_inconclusive",
        "minimality" => "not_proven",
        "minimized_regression" => Regression.to_wire_map(inputs.regression),
        "trials" => [trial],
        "uncertainty" => ["candidate evidence was inconclusive"]
      })
      |> Map.put(
        "usage",
        Map.merge(record.usage, %{
          "accepted_candidates" => 0,
          "confirmation_runs" => 5,
          "evaluated_candidates" => 1,
          "rejected_candidates" => 0
        })
      )
      |> readdress_map()

    assert {:ok, standalone} = Record.decode_map(forged)

    assert {:error, %Error{code: :invalid_minimization_record}} =
             Record.validate_with_evidence(
               standalone,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               Enum.take(records, 5)
             )
  end

  test "partial baseline and candidate exhaustion retain verifiable best-known evidence", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-partial-exhaustion")

    assert {:ok, %MinimizationResult{record: record, confirmation_records: records}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    [baseline_first, _baseline_second, candidate_first | _remaining] = records

    baseline_wire =
      record
      |> Record.to_wire_map()
      |> Map.merge(%{
        "status" => "exhausted",
        "reason" => "total_deadline_exhausted",
        "minimality" => "not_proven",
        "minimized_regression" => Regression.to_wire_map(inputs.regression),
        "baseline" => %{
          "attempt_count" => 1,
          "decision" => "exhausted",
          "outcomes" => [baseline_first.outcome],
          "record_ids" => [baseline_first.id]
        },
        "trials" => [],
        "uncertainty" => ["duration bound exhausted before minimality"]
      })
      |> Map.put(
        "usage",
        Map.merge(record.usage, %{
          "accepted_candidates" => 0,
          "confirmation_runs" => 1,
          "evaluated_candidates" => 0,
          "rejected_candidates" => 0
        })
      )
      |> readdress_map()

    assert {:ok, baseline_record} = Record.decode_map(baseline_wire)

    assert {:ok, ^baseline_record} =
             Record.validate_with_evidence(
               baseline_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               [baseline_first]
             )

    incomplete_wire =
      baseline_wire
      |> Map.merge(%{
        "status" => "inconclusive",
        "reason" => "executor_not_clean",
        "baseline" => baseline_wire["baseline"],
        "cleanup" => %{"active" => 0, "quarantined" => 1, "status" => "incomplete"},
        "uncertainty" => ["sandbox executor retained active or quarantined work"]
      })
      |> readdress_map()

    assert {:ok, incomplete_record} = Record.decode_map(incomplete_wire)

    assert {:ok, ^incomplete_record} =
             Record.validate_with_evidence(
               incomplete_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               [baseline_first]
             )

    candidate_trial =
      record.trials
      |> hd()
      |> Map.merge(%{
        "attempt_count" => 1,
        "decision" => "exhausted",
        "outcomes" => [candidate_first.outcome],
        "record_ids" => [candidate_first.id]
      })

    candidate_wire =
      record
      |> Record.to_wire_map()
      |> Map.merge(%{
        "status" => "exhausted",
        "reason" => "total_deadline_exhausted",
        "minimality" => "not_proven",
        "minimized_regression" => Regression.to_wire_map(inputs.regression),
        "trials" => [candidate_trial],
        "uncertainty" => ["duration bound exhausted before minimality"]
      })
      |> Map.put(
        "usage",
        Map.merge(record.usage, %{
          "accepted_candidates" => 0,
          "confirmation_runs" => 3,
          "evaluated_candidates" => 1,
          "rejected_candidates" => 0
        })
      )
      |> readdress_map()

    assert {:ok, candidate_record} = Record.decode_map(candidate_wire)

    assert {:ok, ^candidate_record} =
             Record.validate_with_evidence(
               candidate_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.target,
               Enum.take(records, 3)
             )
  end

  test "late cleanup preserves partial terminal evidence without a minimality claim", %{
    executor: executor
  } do
    inputs = inputs!(executor, "minimizer-late-cleanup-graph")

    assert {:ok, %MinimizationResult{record: completed, confirmation_records: evidence}} =
             minimize(executor, inputs, MinimizerConfirmationBody,
               max_candidates: 8,
               max_duration_ms: 30_000
             )

    [baseline_first, baseline_second, candidate_first | _] = evidence

    for {cleanup, reason, uncertainty} <- [
          {%{"active" => 0, "quarantined" => 1, "status" => "incomplete"}, "executor_not_clean",
           "sandbox executor retained active or quarantined work"},
          {%{"active" => nil, "quarantined" => nil, "status" => "unknown"},
           "executor_state_unknown", "sandbox executor cleanup state could not be established"}
        ] do
      for attempts <- 0..1 do
        baseline_records = Enum.take([baseline_first], attempts)

        wire =
          completed
          |> Record.to_wire_map()
          |> Map.merge(%{
            "status" => "inconclusive",
            "reason" => reason,
            "minimality" => "not_proven",
            "minimized_regression" => Regression.to_wire_map(inputs.regression),
            "baseline" => %{
              "attempt_count" => attempts,
              "decision" => "exhausted",
              "outcomes" => Enum.map(baseline_records, & &1.outcome),
              "record_ids" => Enum.map(baseline_records, & &1.id)
            },
            "trials" => [],
            "cleanup" => cleanup,
            "uncertainty" => [uncertainty]
          })
          |> Map.put(
            "usage",
            Map.merge(completed.usage, %{
              "accepted_candidates" => 0,
              "confirmation_runs" => attempts,
              "evaluated_candidates" => 0,
              "rejected_candidates" => 0
            })
          )
          |> readdress_map()

        assert {:ok, graph} = Record.decode_map(wire)
        assert graph.baseline["decision"] == "exhausted"
        assert graph.baseline["record_ids"] == Enum.map(baseline_records, & &1.id)

        assert {:ok, ^graph} =
                 Record.validate_with_evidence(
                   graph,
                   inputs.regression,
                   inputs.capsule,
                   inputs.manifest,
                   inputs.target,
                   baseline_records
                 )
      end

      for attempts <- 0..1 do
        trial_records = Enum.take([candidate_first], attempts)

        trial =
          completed.trials
          |> hd()
          |> Map.merge(%{
            "attempt_count" => attempts,
            "decision" => "exhausted",
            "outcomes" => Enum.map(trial_records, & &1.outcome),
            "record_ids" => Enum.map(trial_records, & &1.id)
          })

        wire =
          completed
          |> Record.to_wire_map()
          |> Map.merge(%{
            "status" => "inconclusive",
            "reason" => reason,
            "minimality" => "not_proven",
            "minimized_regression" => Regression.to_wire_map(inputs.regression),
            "trials" => [trial],
            "cleanup" => cleanup,
            "uncertainty" => [uncertainty]
          })
          |> Map.put(
            "usage",
            Map.merge(completed.usage, %{
              "accepted_candidates" => 0,
              "confirmation_runs" => 2 + attempts,
              "evaluated_candidates" => 1,
              "rejected_candidates" => 0
            })
          )
          |> readdress_map()

        assert {:ok, graph} = Record.decode_map(wire)
        assert hd(graph.trials)["decision"] == "exhausted"
        assert hd(graph.trials)["record_ids"] == Enum.map(trial_records, & &1.id)

        assert {:ok, ^graph} =
                 Record.validate_with_evidence(
                   graph,
                   inputs.regression,
                   inputs.capsule,
                   inputs.manifest,
                   inputs.target,
                   [baseline_first, baseline_second | trial_records]
                 )
      end
    end
  end

  defp inputs!(executor, suffix, shape \\ :three_steps) do
    capsule = capsule!(suffix)
    expected = capsule.finding["fingerprint"]
    scenario = scenario!(expected, suffix, shape)
    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)

    {:ok, target} =
      Target.new(ConfirmationProvider.identity(), capsule.provenance)

    {request, context} = authority!(target, "source-#{suffix}", 5_000)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: MinimizerConfirmationBody,
        observer: @observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)

    %{
      capsule: capsule,
      context: context,
      manifest: manifest,
      regression: regression,
      scenario: scenario,
      target: target
    }
  end

  defp minimize(executor, inputs, body, options) do
    {request, context} = authority!(inputs.target, "minimize-#{inputs.scenario.seed}", 30_000)

    Minimizer.run(
      executor,
      inputs.regression,
      inputs.manifest,
      inputs.capsule,
      inputs.target,
      [request: request, context: context, body: body, observer: @observer] ++ options
    )
  end

  defp scenario!(expected, suffix, shape) do
    {:ok, contract} = Contract.describe(ConfirmationContract)

    steps = [
      %{
        "id" => "redundant-before",
        "type" => "observation",
        "name" => "echo",
        "arguments" => ["before"]
      },
      %{
        "id" => "required",
        "type" => "observation",
        "name" => "echo",
        "arguments" => ["required"]
      },
      %{
        "id" => "redundant-after",
        "type" => "observation",
        "name" => "echo",
        "arguments" => ["after"]
      }
    ]

    steps = if shape == :one_step, do: [Enum.at(steps, 1)], else: steps

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "#{suffix}-seed",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: steps,
        expected_incident_fingerprints: [expected],
        limits: %{"cleanup_timeout_ms" => 500, "max_duration_ms" => 2_000}
      )

    scenario
  end

  defp capsule!(suffix) do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json") |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"revision" => suffix}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    wire =
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire =
      wire
      |> Map.put("id", "sha256:" <> digest)
      |> put_in(["integrity", "content_digest"], digest)

    {:ok, capsule} = Capsule.decode_map(wire)
    capsule
  end

  defp authority!(target, request_id, timeout_ms, operation \\ "verification.run") do
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}

    scope =
      if operation == "verification.run", do: "verification.execute", else: "scenario.execute"

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 10, max_bytes: 65_536)

    {:ok, request} =
      Request.new(operation,
        request_id: request_id,
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "minimizer-grant",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "minimizer-grant",
        audit_id: "minimizer-audit",
        scopes: [scope],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "minimizer-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          operation => %{
            available: true,
            provider: "minimizer-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp readdress_map(wire) do
    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
