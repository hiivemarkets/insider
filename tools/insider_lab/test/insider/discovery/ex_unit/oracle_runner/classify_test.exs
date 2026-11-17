defmodule Insider.Discovery.ExUnit.OracleRunner.ClassifyTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner
  alias Insider.Discovery.ExUnit.OracleRunner.Command
  alias Insider.Discovery.ExUnit.OracleRunner.Oracle
  alias Insider.Test.OracleReports

  @context "insider-oracle-run:0123"
  @fingerprint {:ok, %{"files" => 1, "sha256" => String.duplicate("a", 64)}}
  @helpers ~s(INSIDER_ORACLE_RUNNER_HELPERS={"elixir":"1.20.1","host_helpers":1,"otp":"29"}\n)
  @suite ~s(INSIDER_ORACLE_RUNNER_SUITE={"excluded":0,"failures":0,"skipped":0,"total":1}\n)
  @inputs %{
    "application_env" => %{
      "INSIDER_ORACLE_APPLICATION" => "logger",
      "INSIDER_ORACLE_KEY" => "default_handler"
    },
    "telemetry_dead_handlers" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "insider,example"},
    "otel_global_state" => %{}
  }

  test "maps every oracle status to a shared outcome" do
    expectations = [
      {"application_env", "changed", "confirmed"},
      {"application_env", "unchanged", "not_reproduced"},
      {"application_env", "inconclusive", "not_observed"},
      {"application_env", "operational_failure", "not_observed"},
      {"telemetry_dead_handlers", "increased", "confirmed"},
      {"telemetry_dead_handlers", "unchanged", "not_reproduced"},
      {"telemetry_dead_handlers", "decreased", "not_reproduced"},
      {"telemetry_dead_handlers", "inconclusive", "not_observed"},
      {"telemetry_dead_handlers", "operational_failure", "not_observed"},
      {"otel_global_state", "changed", "confirmed"},
      {"otel_global_state", "unchanged", "not_reproduced"},
      {"otel_global_state", "inconclusive", "not_observed"},
      {"otel_global_state", "operational_failure", "not_observed"}
    ]

    for {oracle, status, outcome} <- expectations do
      classification = classify(oracle, [result(oracle, status), @helpers, @suite])
      assert {classification.completeness, classification.outcome} == {"complete", outcome}
      assert classification.oracle_result["status"] == status
    end
  end

  test "never accepts a missing, repeated, oversized, malformed, foreign, or unbound result line" do
    line = result("application_env", "changed")
    prefix = "INSIDER_APPLICATION_ENV_ORACLE="
    oversized = prefix <> String.duplicate("x", Command.line_limit()) <> "\n"

    foreign =
      prefix <>
        Jason.encode!(%{"schema" => "other/v1", "status" => "changed", "context" => @context}) <>
        "\n"

    unbound = String.replace(line, @context, "insider-oracle-run:other")

    incomplete =
      prefix <> Jason.encode!(Map.delete(report("application_env", "changed"), "key")) <> "\n"

    contradictory =
      prefix <>
        Jason.encode!(%{report("application_env", "changed") | "status" => "unchanged"}) <> "\n"

    other_key =
      prefix <>
        Jason.encode!(%{report("application_env", "changed") | "key" => "other_key"}) <> "\n"

    cases = [
      {[@helpers, @suite], "result_line_missing"},
      {[line, line, @helpers, @suite], "duplicate_result_line"},
      {[oversized, @helpers, @suite], "result_line_too_long"},
      {[prefix <> "not json\n", @helpers, @suite], "result_line_invalid"},
      {[foreign, @helpers, @suite], "result_line_invalid"},
      {[incomplete, @helpers, @suite], "result_line_invalid"},
      {[contradictory, @helpers, @suite], "result_line_invalid"},
      {[unbound, @helpers, @suite], "context_mismatch"},
      {[other_key, @helpers, @suite], "result_identity_mismatch"},
      {[line, @suite], "helpers_not_loaded"},
      {[line, @helpers, @helpers, @suite], "duplicate_runner_marker"},
      {[line, @helpers], "suite_not_completed"},
      {[line, @helpers, ~s(INSIDER_ORACLE_RUNNER_SUITE={"total":"one"}\n)],
       "runner_marker_invalid"},
      {[~s(INSIDER_ORACLE_RUNNER_REFUSED={"reason":"made_up"}\n)], "runner_marker_invalid"}
    ]

    for {chunks, reason} <- cases do
      classification = classify("application_env", chunks)

      assert {classification.completeness, classification.reason} ==
               {"infrastructure_failure", reason}

      assert classification.outcome == "infrastructure_failure"
    end
  end

  test "runner-owned variables cannot be overridden by passthrough or inherited entries" do
    {:ok, paths} =
      OracleRunner.runner_paths("/runs/one", "/target", Oracle.fetch!("application_env"))

    request = %{
      paths: paths,
      profile: %{document: %{"test_alias" => "bypass"}},
      inputs: [{"INSIDER_ORACLE_CONTEXT", @context}],
      resolved: %{
        db_suffix: nil,
        passthrough: [
          {"MIX_EXS", "/target/mix.exs"},
          {"INSIDER_ORACLE_RUNNER_OVERLAY", "/elsewhere"},
          {"DECLARED", "value"}
        ]
      },
      inherited: [{"MIX_ENV", "dev"}, {"PATH", "/bin"}]
    }

    environment = OracleRunner.child_environment(request)

    assert Enum.count(environment, &(elem(&1, 0) == "MIX_EXS")) == 1
    assert List.keyfind(environment, "MIX_EXS", 0) == {"MIX_EXS", "/runs/one/runner/mix.exs"}
    assert List.keyfind(environment, "MIX_ENV", 0) == {"MIX_ENV", "test"}

    assert List.keyfind(environment, "INSIDER_ORACLE_RUNNER_OVERLAY", 0) ==
             {"INSIDER_ORACLE_RUNNER_OVERLAY", "/runs/one/runner/overlay"}

    assert {"DECLARED", "value"} in environment
    assert {"PATH", "/bin"} in environment
    assert length(environment) == length(Enum.uniq_by(environment, &elem(&1, 0)))
  end

  test "a known refusal is an unsupported source" do
    refusal = ~s(INSIDER_ORACLE_RUNNER_REFUSED={"reason":"umbrella_project"}\n)
    classification = classify("application_env", [refusal], status: 1)

    assert {classification.completeness, classification.reason} ==
             {"unsupported_source", "umbrella_project"}

    assert classification.outcome == "not_observed"
  end

  test "target, budget, process, and command failures take precedence over a valid result" do
    chunks = [result("application_env", "changed"), @helpers, @suite]
    changed = {:ok, %{"files" => 1, "sha256" => String.duplicate("b", 64)}}

    assert %{reason: "target_changed", verdict: "changed"} =
             classify("application_env", chunks, after: changed)

    assert %{reason: "target_fingerprint_unavailable", verdict: "unverified"} =
             classify("application_env", chunks, after: {:error, "target_listing_failed"})

    assert %{reason: "target_fingerprint_budget_exceeded"} =
             classify("application_env", chunks, after: {:error, "target_fingerprint_timeout"})

    assert %{reason: "deadline_exceeded"} =
             classify("application_env", chunks, termination: "deadline_exceeded")

    assert %{reason: "process_cleanup_uncertain"} =
             classify("application_env", chunks, process: "uncertain")

    assert %{reason: "test_command_failed", oracle_result: %{}} =
             classify("application_env", chunks, status: 2)
  end

  defp classify(oracle, chunks, options \\ []) do
    spec = Oracle.fetch!(oracle)

    command =
      %{
        max_output_bytes: 1_048_576,
        prefixes: [
          spec.prefix | Enum.map(~w(REFUSED HELPERS SUITE), &"INSIDER_ORACLE_RUNNER_#{&1}=")
        ]
      }
      |> Command.new_state()
      |> then(&Enum.reduce(chunks, &1, fn chunk, state -> Command.scan(state, chunk) end))
      |> Command.finish(
        Keyword.get(options, :termination, "exited"),
        Keyword.get(options, :status, 0),
        Keyword.get(options, :process, "exited")
      )

    OracleRunner.classify(%{
      oracle: spec,
      inputs: Map.fetch!(@inputs, oracle),
      context: @context,
      preflight: nil,
      command: command,
      before: @fingerprint,
      after: Keyword.get(options, :after, @fingerprint)
    })
  end

  defp report(oracle, status), do: OracleReports.report(oracle, status, @context)

  defp result(oracle, status),
    do: Oracle.fetch!(oracle).prefix <> Jason.encode!(report(oracle, status)) <> "\n"
end
