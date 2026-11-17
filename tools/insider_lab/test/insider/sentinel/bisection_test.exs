defmodule Insider.Sentinel.BisectionTest do
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
  alias Insider.Sentinel.Bisection
  alias Insider.Sentinel.Bisection.Record
  alias Insider.Sentinel.Bisection.Result, as: BisectionResult
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.TestSupport.BisectionBody
  alias Insider.TestSupport.BisectionProviders
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.MinimizerBlockingBody

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @controls %{
    "checkout" => "none",
    "git_authority" => "none",
    "network_effect" => "none",
    "repository_read" => "none",
    "source_mutation" => "prohibited"
  }

  setup do
    executor =
      start_supervised!(
        {Executor,
         name: nil,
         providers: BisectionProviders.modules(),
         bodies: [BisectionBody, MinimizerBlockingBody]}
      )

    %{executor: executor}
  end

  test "isolates one adjacent boundary pair with fresh bracketing evidence", %{
    executor: executor
  } do
    # Seven declared targets; provider versions 6 and 7 (indices 5 and 6) reproduce.
    inputs = inputs!(executor, "bisection-complete", 7, flip_version: 6)

    assert {:ok, %BisectionResult{record: %Record{} = record} = result} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "completed"
    assert record.reason == "adjacent_boundary_isolated"
    assert record.limitations == Record.limitations()
    assert "outcome_monotonicity_is_a_host_assumption" in record.limitations
    assert "indices_off_the_search_path_are_not_probed" in record.limitations
    assert record.controls == @controls
    assert record.uncertainty == []
    assert record.cleanup == %{"active" => 0, "quarantined" => 0, "status" => "complete"}

    assert Enum.map(record.trials, &{&1["index"], &1["role"], &1["decision"]}) == [
             {0, "oldest_endpoint", "nonreproduced"},
             {6, "newest_endpoint", "reproduced"},
             {3, "midpoint", "nonreproduced"},
             {4, "midpoint", "nonreproduced"},
             {5, "midpoint", "reproduced"}
           ]

    culprit_target = Enum.at(inputs.targets, 5)

    assert record.culprit == %{
             "boundary_nonreproduced_index" => 4,
             "boundary_reproducing_index" => 5,
             "proof" => "adjacent_boundary_isolated",
             "target_fingerprint" => Target.target_fingerprint(culprit_target),
             "target_id" => culprit_target.id
           }

    probe_bound = 2 * (ceil_log2(7) + 2)
    assert record.usage["confirmation_runs"] == 10
    assert record.usage["confirmation_runs"] <= probe_bound
    assert record.usage["probed_indices"] == 5
    assert record.usage["duration_us"] <= record.policy["max_duration_ms"] * 1_000
    assert record.policy["target_count"] == 7
    assert record.policy["required_probes_per_index"] == 2

    assert record.policy["max_total_bytes"] ==
             record.policy["per_run_max_bytes"] * record.policy["max_probes"]

    assert record.targets == Record.declared_targets(inputs.targets)
    assert Enum.map(record.targets, & &1["index"]) == Enum.to_list(0..6)

    all_record_ids = Enum.flat_map(record.trials, & &1["record_ids"])
    assert length(all_record_ids) == 10
    assert Enum.uniq(all_record_ids) == all_record_ids
    assert Enum.map(result.confirmation_records, & &1.id) == all_record_ids

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               result.confirmation_records
             )

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               Enum.reverse(result.confirmation_records)
             )

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               Enum.reverse(inputs.targets),
               result.confirmation_records
             )

    assert {:ok, bytes} = Record.canonical_binary(record)
    assert {:ok, ^record} = Record.decode(bytes)
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "reports the adjacent boundary on the search path, never an earlier unprobed index",
       %{executor: executor} do
    # Seven declared targets; provider versions 2 and 7 (indices 1 and 6)
    # reproduce. Index 1 lies off the binary-search path and is never probed,
    # so completion isolates the adjacent pair [5, 6] under the host's
    # monotonicity assumption rather than the earliest reproducing index.
    inputs =
      inputs!(executor, "bisection-nonmonotonic", 7, reproducing_versions: [2, 7])

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "completed"
    assert record.reason == "adjacent_boundary_isolated"
    assert record.uncertainty == []

    assert Enum.map(record.trials, &{&1["index"], &1["decision"]}) == [
             {0, "nonreproduced"},
             {6, "reproduced"},
             {3, "nonreproduced"},
             {4, "nonreproduced"},
             {5, "nonreproduced"}
           ]

    refute 1 in Enum.map(record.trials, & &1["index"])

    boundary_target = Enum.at(inputs.targets, 6)

    assert record.culprit == %{
             "boundary_nonreproduced_index" => 5,
             "boundary_reproducing_index" => 6,
             "proof" => "adjacent_boundary_isolated",
             "target_fingerprint" => Target.target_fingerprint(boundary_target),
             "target_id" => boundary_target.id
           }

    assert "outcome_monotonicity_is_a_host_assumption" in record.limitations
    assert "indices_off_the_search_path_are_not_probed" in record.limitations

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "stops on mixed outcomes at one declared target instead of narrowing further", %{
    executor: executor
  } do
    inputs =
      inputs!(executor, "bisection-nondeterministic", 5,
        flip_version: 4,
        nondeterministic_version: 3
      )

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "inconclusive"
    assert record.reason == "probe_nondeterministic"
    assert record.uncertainty == ["one declared target reproduced nondeterministically"]

    assert Enum.map(record.trials, &{&1["index"], &1["decision"]}) == [
             {0, "nonreproduced"},
             {4, "reproduced"},
             {2, "nondeterministic"}
           ]

    assert Enum.sort(List.last(record.trials)["outcomes"]) == [
             "matching_failure",
             "nonreproduced"
           ]

    assert record.culprit == %{
             "boundary_nonreproduced_index" => 0,
             "boundary_reproducing_index" => 4,
             "proof" => "not_proven",
             "target_fingerprint" => nil,
             "target_id" => nil
           }

    assert record.usage["confirmation_runs"] == 6
    assert length(evidence) == 6

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "returns best-known bounds without a culprit claim at the probe bound", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-exhausted", 5, flip_version: 4)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 4, max_duration_ms: 60_000)

    assert record.status == "exhausted"
    assert record.reason == "max_probes_exhausted"
    assert Enum.map(record.trials, & &1["role"]) == ["oldest_endpoint", "newest_endpoint"]
    assert record.usage["confirmation_runs"] == 4

    assert record.culprit == %{
             "boundary_nonreproduced_index" => 0,
             "boundary_reproducing_index" => 4,
             "proof" => "not_proven",
             "target_fingerprint" => nil,
             "target_id" => nil
           }

    assert record.uncertainty == ["probe bound exhausted before isolating one declared target"]

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "an oldest declared target that reproduces leaves the failure unbracketed", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-unbracketed", 5, flip_version: 1)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "inconclusive"
    assert record.reason == "baseline_not_bracketed"
    assert Enum.map(record.trials, &{&1["index"], &1["decision"]}) == [{0, "reproduced"}]
    assert record.usage["confirmation_runs"] == 2

    assert record.culprit == %{
             "boundary_nonreproduced_index" => nil,
             "boundary_reproducing_index" => nil,
             "proof" => "not_proven",
             "target_fingerprint" => nil,
             "target_id" => nil
           }

    assert record.uncertainty == [
             "oldest and newest declared targets did not bracket the failure"
           ]

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "exhausts the total duration before dispatch when fresh probes cannot fit", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-duration-bound", 5, flip_version: 4)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: []}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 1_000)

    assert record.status == "exhausted"
    assert record.reason == "total_deadline_exhausted"

    assert record.trials == [
             %{
               "attempt_count" => 0,
               "decision" => "exhausted",
               "index" => 0,
               "outcomes" => [],
               "record_ids" => [],
               "role" => "oldest_endpoint",
               "target_fingerprint" => Target.target_fingerprint(hd(inputs.targets)),
               "target_id" => hd(inputs.targets).id
             }
           ]

    assert record.usage["confirmation_runs"] == 0
    assert record.culprit["proof"] == "not_proven"
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "exhausts the total duration mid-search once fresh probes no longer fit", %{
    executor: executor
  } do
    # Two fresh runs need 2 * (2_750 + 1_000) ms of clock. Holding each oldest
    # endpoint run for a known 300 ms consumes more than the 500 ms of slack
    # that an 8_000 ms bound leaves, so the newest endpoint cannot be dispatched.
    inputs =
      inputs!(executor, "bisection-mid-search-duration", 5, flip_version: 4, hold_ms: {1, 300})

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 8_000)

    assert record.status == "exhausted"
    assert record.reason == "total_deadline_exhausted"
    assert record.cleanup == %{"active" => 0, "quarantined" => 0, "status" => "complete"}

    assert Enum.map(
             record.trials,
             &{&1["index"], &1["role"], &1["decision"], &1["attempt_count"]}
           ) ==
             [{0, "oldest_endpoint", "nonreproduced", 2}, {4, "newest_endpoint", "exhausted", 0}]

    assert List.last(record.trials)["record_ids"] == []
    assert record.usage["confirmation_runs"] == 2
    assert [_first, _second] = evidence

    assert record.culprit == %{
             "boundary_nonreproduced_index" => 0,
             "boundary_reproducing_index" => nil,
             "proof" => "not_proven",
             "target_fingerprint" => nil,
             "target_id" => nil
           }

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "probe evidence that neither reproduces nor clears stops as inconclusive", %{
    executor: executor
  } do
    # Two clean unrelated failures exhaust the index's probes; one incomplete
    # observation is already inconclusive and gets no second probe.
    for {mode, outcomes} <- [
          {:unrelated, ["unrelated_failure", "unrelated_failure"]},
          {:incomplete, ["infrastructure_failure"]}
        ] do
      inputs =
        inputs!(executor, "bisection-inconclusive-#{mode}", 5,
          flip_version: 4,
          inconclusive: {3, mode}
        )

      assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
               bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

      assert record.status == "inconclusive"
      assert record.reason == "probe_inconclusive"
      assert record.uncertainty == ["probe evidence was inconclusive"]
      assert record.cleanup == %{"active" => 0, "quarantined" => 0, "status" => "complete"}

      assert Enum.map(record.trials, &{&1["index"], &1["decision"], &1["attempt_count"]}) == [
               {0, "nonreproduced", 2},
               {4, "reproduced", 2},
               {2, "inconclusive", length(outcomes)}
             ]

      assert List.last(record.trials)["outcomes"] == outcomes
      probes = Enum.drop(evidence, 4)

      assert Enum.map(probes, & &1.cleanup["status"]) ==
               Enum.map(outcomes, fn _ -> "complete" end)

      assert record.culprit == %{
               "boundary_nonreproduced_index" => 0,
               "boundary_reproducing_index" => 4,
               "proof" => "not_proven",
               "target_fingerprint" => nil,
               "target_id" => nil
             }

      assert record.usage["confirmation_runs"] == 4 + length(outcomes)
      assert length(evidence) == 4 + length(outcomes)

      assert {:ok, ^record} =
               Record.validate_with_evidence(
                 record,
                 inputs.regression,
                 inputs.capsule,
                 inputs.manifest,
                 inputs.targets,
                 evidence
               )

      assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
    end
  end

  test "a single-probe inconclusive stop cannot be forged from clean evidence", %{
    executor: executor
  } do
    inputs =
      inputs!(executor, "bisection-single-probe-forgery", 5,
        flip_version: 4,
        inconclusive: {3, :unrelated}
      )

    assert {:ok, %BisectionResult{record: record, confirmation_records: records}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    wire = Record.to_wire_map(record)
    [oldest, newest, midpoint] = wire["trials"]
    assert midpoint["attempt_count"] == 2

    # A clean unrelated probe referenced once is not an inconclusive stop.
    truncated_midpoint =
      Map.merge(midpoint, %{
        "attempt_count" => 1,
        "outcomes" => Enum.take(midpoint["outcomes"], 1),
        "record_ids" => Enum.take(midpoint["record_ids"], 1)
      })

    truncated =
      wire
      |> Map.put("trials", [oldest, newest, truncated_midpoint])
      |> Map.put("usage", Map.merge(wire["usage"], %{"confirmation_runs" => 5}))
      |> readdress_map()

    assert {:ok, truncated_record} = Record.decode_map(truncated)

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               truncated_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               Enum.take(records, 5)
             )

    # One record counted twice never stands for two probes.
    [first_id, _second_id] = midpoint["record_ids"]

    duplicated =
      wire
      |> put_in(["trials", Access.at(2), "record_ids"], [first_id, first_id])
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(duplicated)
  end

  test "a provider exception inside a probe is contained as inconclusive evidence", %{
    executor: executor
  } do
    # Regression: a probe that fails before observation yields a record with no
    # run identity, so a second such probe repeated the same content-addressed
    # record id and the search could not build a record at all.
    inputs = inputs!(executor, "bisection-provider-raise", 5, flip_version: 4)
    raising = Enum.at(inputs.targets, 2)
    BisectionProviders.raise_on_acquire(raising.id)
    on_exit(fn -> BisectionProviders.disarm(raising.id) end)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: evidence}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "inconclusive"
    assert record.reason == "probe_inconclusive"
    assert record.cleanup == %{"active" => 0, "quarantined" => 0, "status" => "complete"}

    assert Enum.map(record.trials, &{&1["index"], &1["decision"], &1["attempt_count"]}) == [
             {0, "nonreproduced", 2},
             {4, "reproduced", 2},
             {2, "inconclusive", 1}
           ]

    assert List.last(record.trials)["outcomes"] == ["infrastructure_failure"]
    assert record.usage["confirmation_runs"] == 5
    assert [probe] = Enum.drop(evidence, 4)
    assert probe.operational_status == "error"
    assert probe.outcome_reason == "evidence_unavailable"
    assert probe.cleanup["status"] == "complete"
    assert is_nil(probe.evidence["observation_run_fingerprint"])
    refute probe.confirmed
    assert record.culprit["proof"] == "not_proven"

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               evidence
             )

    # The executor stays clean and keeps serving fresh confirmations.
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
    newest = List.last(inputs.targets)
    {request, context} = authority!(newest, "bisection-provider-raise-after", 5_000)

    assert {:ok, %Confirmation.Record{confirmed: true}} =
             Confirmation.run(executor, inputs.manifest, inputs.capsule, inputs.scenario, newest,
               request: request,
               context: context,
               body: BisectionBody,
               observer: @observer,
               repair_oracle: nil
             )
  end

  test "refuses to dispatch into an executor that already owns active work", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-dirty-executor", 5, flip_version: 4)
    key = {MinimizerBlockingBody, inputs.scenario.seed}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)
    {request, context} = authority!(List.last(inputs.targets), "bisection-blocker", 5_000)

    assert {:ok, handle} =
             Executor.start_run(executor, List.last(inputs.targets),
               request: request,
               context: context,
               cleanup_timeout_ms: 100,
               body: {MinimizerBlockingBody, %{"seed" => inputs.scenario.seed}, 100}
             )

    assert_receive {:minimizer_blocking_body_started, body}, 1_000

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: []}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 5_000)

    assert record.status == "inconclusive"
    assert record.reason == "executor_not_clean"
    assert record.cleanup == %{"active" => 1, "quarantined" => 0, "status" => "incomplete"}
    assert record.uncertainty == ["sandbox executor retained active or quarantined work"]
    assert record.trials == []
    assert record.usage["confirmation_runs"] == 0
    assert record.usage["probed_indices"] == 0

    assert record.culprit == %{
             "boundary_nonreproduced_index" => nil,
             "boundary_reproducing_index" => nil,
             "proof" => "not_proven",
             "target_fingerprint" => nil,
             "target_id" => nil
           }

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               []
             )

    send(body, :unexpected_release)

    assert %Insider.Protocol.Result{cleanup: %{remaining_count: 0}} =
             Executor.await(handle, 2_000)

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  @tag :capture_log
  test "a lease quarantined by a probe stops the search with the observed counts", %{
    executor: executor
  } do
    inputs =
      inputs!(executor, "bisection-quarantined-probe", 5, flip_version: 4, crash_version: 1)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: [probe]}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    assert record.status == "inconclusive"
    assert record.reason == "executor_not_clean"
    assert record.cleanup == %{"active" => 0, "quarantined" => 1, "status" => "incomplete"}
    assert record.uncertainty == ["sandbox executor retained active or quarantined work"]

    assert record.trials == [
             %{
               "attempt_count" => 1,
               "decision" => "inconclusive",
               "index" => 0,
               "outcomes" => [probe.outcome],
               "record_ids" => [probe.id],
               "role" => "oldest_endpoint",
               "target_fingerprint" => Target.target_fingerprint(hd(inputs.targets)),
               "target_id" => hd(inputs.targets).id
             }
           ]

    assert probe.outcome == "infrastructure_failure"
    assert probe.cleanup["status"] == "uncertain"
    assert record.usage["confirmation_runs"] == 1
    assert record.culprit["proof"] == "not_proven"

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               [probe]
             )

    # The executor reports the retained quarantine honestly afterwards.
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "reports unknown executor state without attempting a probe", %{executor: executor} do
    inputs = inputs!(executor, "bisection-executor-unavailable", 5, flip_version: 4)
    assert :ok = Supervisor.stop(executor)

    assert {:ok, %BisectionResult{record: %Record{} = record, confirmation_records: []}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 5_000)

    assert record.status == "inconclusive"
    assert record.reason == "executor_state_unknown"
    assert record.cleanup == %{"active" => nil, "quarantined" => nil, "status" => "unknown"}
    assert record.uncertainty == ["sandbox executor cleanup state could not be established"]
    assert record.trials == []
    assert record.usage["confirmation_runs"] == 0
    assert record.culprit["proof"] == "not_proven"

    assert {:ok, ^record} =
             Record.validate_with_evidence(
               record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               []
             )
  end

  test "an error after probe admission carries the bounded final cleanup state", %{
    executor: executor
  } do
    inputs =
      inputs!(executor, "bisection-admitted-error", 5, flip_version: 4, gate: {1, self()})

    task = Task.async(fn -> bisect(executor, inputs, max_probes: 16, max_duration_ms: 10_000) end)

    assert_receive {:bisection_probe_started, 1, _body}, 1_000
    assert :ok = Supervisor.stop(executor)

    assert {:error,
            %Error{
              code: :operation_failed,
              details: %{
                "bisection_cleanup" => %{
                  "active" => nil,
                  "quarantined" => nil,
                  "status" => "unknown"
                },
                "bisection_confirmation_runs" => 1
              }
            }} = Task.await(task, 2_000)
  end

  test "rejects mismatched declared targets, authority, and bounds before dispatch", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-mismatch", 5, flip_version: 4)
    newest = List.last(inputs.targets)
    {request, context} = authority!(newest, "bisection-mismatch-authority", 30_000)
    options = [request: request, context: context, body: BisectionBody, observer: @observer]

    {:ok, foreign_provenance} =
      Provenance.new(
        code: {:available, %{"revision" => "elsewhere"}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    {:ok, foreign_target} = Target.new(BisectionProviders.identity(1), foreign_provenance)
    {wrong_request, _context} = authority!(hd(inputs.targets), "bisection-wrong-target", 30_000)

    for {targets, run_options} <- [
          {[newest], options},
          {inputs.targets ++ [newest], options},
          {List.replace_at(inputs.targets, 0, foreign_target), options},
          {Enum.reverse(inputs.targets), options},
          {inputs.targets, Keyword.put(options, :request, wrong_request)},
          {inputs.targets, options ++ [max_probes: 0]},
          {inputs.targets, options ++ [max_probes: 129]},
          {inputs.targets, options ++ [max_duration_ms: 0]},
          {inputs.targets, options ++ [unknown: true]}
        ] do
      assert {:error, %Error{code: :bisection_input_mismatch}} =
               Bisection.run(
                 executor,
                 inputs.regression,
                 inputs.manifest,
                 inputs.capsule,
                 targets,
                 run_options
               )
    end

    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "canonical validation rejects forged, reordered, or relabelled trial paths", %{
    executor: executor
  } do
    inputs = inputs!(executor, "bisection-forgery", 7, flip_version: 6)

    assert {:ok, %BisectionResult{record: record, confirmation_records: records}} =
             bisect(executor, inputs, max_probes: 16, max_duration_ms: 60_000)

    wire = Record.to_wire_map(record)
    [oldest, newest, first_midpoint, second_midpoint, third_midpoint] = wire["trials"]

    reordered =
      wire
      |> Map.put("trials", [oldest, newest, second_midpoint, first_midpoint, third_midpoint])
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(reordered)

    relabelled_midpoint =
      Map.merge(first_midpoint, %{
        "decision" => "reproduced",
        "outcomes" => ["matching_failure", "matching_failure"]
      })

    relabelled =
      wire
      |> Map.put("trials", [oldest, newest, relabelled_midpoint, second_midpoint, third_midpoint])
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(relabelled)

    wrong_index =
      wire
      |> put_in(["trials", Access.at(2), "index"], 2)
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(wrong_index)

    wrong_culprit =
      wire
      |> put_in(["culprit", "boundary_reproducing_index"], 4)
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(wrong_culprit)

    causal_claim =
      wire
      |> put_in(["culprit", "proof"], "cause")
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(causal_claim)

    relaxed_controls =
      wire
      |> put_in(["controls", "repository_read"], "allowed")
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.decode_map(relaxed_controls)

    relaxed_limitations =
      wire
      |> Map.put("limitations", ["target_causality_is_not_claimed"])
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.decode_map(relaxed_limitations)

    truncated_path =
      wire
      |> Map.put("trials", [oldest, newest, first_midpoint, second_midpoint])
      |> Map.put(
        "usage",
        Map.merge(wire["usage"], %{"confirmation_runs" => 8, "probed_indices" => 4})
      )
      |> readdress_map()

    assert {:error, %Error{code: :invalid_bisection_record}} = Record.decode_map(truncated_path)

    wrong_source =
      wire
      |> put_in(["source", "regression_id"], "sha256:" <> String.duplicate("e", 64))
      |> readdress_map()

    assert {:ok, standalone} = Record.decode_map(wrong_source)

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               standalone,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               records
             )

    # Swapping reference lists between two same-outcome trials still replays as
    # one path; only the retained evidence order exposes it.
    swapped_references =
      wire
      |> put_in(["trials", Access.at(0), "record_ids"], first_midpoint["record_ids"])
      |> put_in(["trials", Access.at(2), "record_ids"], oldest["record_ids"])
      |> readdress_map()

    assert {:ok, swapped_record} = Record.decode_map(swapped_references)

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               swapped_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               records
             )

    # Relabelling the last midpoint moves the culprit to the newest target with a
    # coherent standalone path; the referenced records contradict it.
    newest_declared = List.last(wire["targets"])

    contradicted =
      wire
      |> Map.put("trials", [
        oldest,
        newest,
        first_midpoint,
        second_midpoint,
        Map.merge(third_midpoint, %{
          "decision" => "nonreproduced",
          "outcomes" => ["nonreproduced", "nonreproduced"]
        })
      ])
      |> Map.put("culprit", %{
        "boundary_nonreproduced_index" => 5,
        "boundary_reproducing_index" => 6,
        "proof" => "adjacent_boundary_isolated",
        "target_fingerprint" => newest_declared["target_fingerprint"],
        "target_id" => newest_declared["target_id"]
      })
      |> readdress_map()

    assert {:ok, contradicted_record} = Record.decode_map(contradicted)

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.validate_with_evidence(
               contradicted_record,
               inputs.regression,
               inputs.capsule,
               inputs.manifest,
               inputs.targets,
               records
             )

    assert {:error, %Error{code: :invalid_bisection_record}} =
             Record.decode(" " <> (Record.canonical_binary(record) |> elem(1)))

    assert {:error, %Error{code: :unsupported_bisection_record_schema}} =
             Record.decode_map(%{"schema" => "insider.bisection-record/v2"})

    assert {:error, %Error{code: :bisection_record_limit_exceeded}} =
             Record.decode(String.duplicate("x", 262_145))
  end

  defp inputs!(executor, suffix, target_count, plan) do
    capsule = capsule!(suffix)
    expected = capsule.finding["fingerprint"]
    scenario = scenario!(expected, suffix)
    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = Manifest.new(capsule, descriptor)

    targets =
      for version <- 1..target_count do
        {:ok, target} = Target.new(BisectionProviders.identity(version), capsule.provenance)
        target
      end

    plan =
      Map.merge(
        %{
          flip_version: nil,
          reproducing_versions: nil,
          nondeterministic_version: nil,
          counter: :atomics.new(1, signed: false)
        },
        Map.new(plan)
      )

    key = {BisectionBody, scenario.seed}
    :persistent_term.put(key, plan)
    on_exit(fn -> :persistent_term.erase(key) end)

    newest = List.last(targets)
    {request, context} = authority!(newest, "source-#{suffix}", 5_000)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule, scenario, newest,
        request: request,
        context: context,
        body: BisectionBody,
        observer: @observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)

    %{
      capsule: capsule,
      manifest: manifest,
      regression: regression,
      scenario: scenario,
      targets: targets
    }
  end

  defp bisect(executor, inputs, options) do
    newest = List.last(inputs.targets)
    {request, context} = authority!(newest, "bisect-#{inputs.scenario.seed}", 60_000)

    Bisection.run(
      executor,
      inputs.regression,
      inputs.manifest,
      inputs.capsule,
      inputs.targets,
      [request: request, context: context, body: BisectionBody, observer: @observer] ++ options
    )
  end

  defp scenario!(expected, suffix) do
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "#{suffix}-seed",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: [
          %{
            "id" => "required",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["required"]
          }
        ],
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

  defp authority!(target, request_id, timeout_ms) do
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 10, max_bytes: 65_536)

    {:ok, request} =
      Request.new("verification.run",
        request_id: request_id,
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "bisection-grant",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "bisection-grant",
        audit_id: "bisection-audit",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "bisection-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "bisection-test",
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

  defp ceil_log2(count), do: count |> :math.log2() |> Float.ceil() |> trunc()

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
