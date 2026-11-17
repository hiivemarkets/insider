defmodule Insider.Discovery.ExUnit.OracleRunner.OracleTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Oracle
  alias Insider.Test.OracleReports

  @statuses %{
    "application_env" => ~w(changed unchanged inconclusive operational_failure),
    "telemetry_dead_handlers" =>
      ~w(increased unchanged decreased inconclusive operational_failure),
    "otel_global_state" => ~w(changed unchanged inconclusive operational_failure)
  }

  test "accepts every status of every oracle in the artifact's exact shape" do
    for {oracle, statuses} <- @statuses, status <- statuses do
      assert Oracle.valid_report?(oracle, OracleReports.report(oracle, status, nil)),
             "#{oracle} #{status}"

      assert Oracle.valid_report?(oracle, OracleReports.report(oracle, status, "ctx"))
    end
  end

  test "rejects a report of another oracle, an extra or missing field, or changed limits" do
    for {oracle, _statuses} <- @statuses do
      [status | _rest] = @statuses[oracle]
      report = OracleReports.report(oracle, status, nil)
      other = Enum.find(Oracle.ids(), &(&1 != oracle))

      refute Oracle.valid_report?(other, report)
      refute Oracle.valid_report?(oracle, Map.put(report, "value", "secret"))
      refute Oracle.valid_report?(oracle, Map.delete(report, "limitations"))
      refute Oracle.valid_report?(oracle, Map.put(report, "context_byte_limit", 1))
      refute Oracle.valid_report?(oracle, %{report | "limitations" => []})
      refute Oracle.valid_report?("unknown", report)
      refute Oracle.valid_report?(oracle, nil)
    end
  end

  test "rejects a status that contradicts the report's own evidence" do
    changed = OracleReports.report("application_env", "changed", nil)
    refute Oracle.valid_report?("application_env", %{changed | "status" => "unchanged"})
    refute Oracle.valid_report?("application_env", %{changed | "unchanged" => true})
    refute Oracle.valid_report?("application_env", %{changed | "initial_presence" => "other"})
    refute Oracle.valid_report?("application_env", %{changed | "final_fingerprint" => "plain"})

    unobserved = %{changed | "final_observed" => false}
    refute Oracle.valid_report?("application_env", unobserved)

    # The artifact's own rules: two observed, present captures without
    # comparable fingerprints are inconclusive, never changed or unchanged.
    no_fingerprints = %{changed | "initial_fingerprint" => nil, "final_fingerprint" => nil}
    refute Oracle.valid_report?("application_env", no_fingerprints)

    assert Oracle.valid_report?("application_env", %{
             no_fingerprints
             | "status" => "inconclusive",
               "unchanged" => nil
           })

    refute Oracle.valid_report?("application_env", %{changed | "initial_presence" => "unknown"})

    refute Oracle.valid_report?("application_env", %{
             changed
             | "initial_presence" => "missing",
               "final_presence" => "missing",
               "status" => "unchanged",
               "unchanged" => true
           })

    missing_to_present = %{
      changed
      | "initial_presence" => "missing",
        "initial_fingerprint" => nil
    }

    assert Oracle.valid_report?("application_env", missing_to_present)
    refute Oracle.valid_report?("application_env", %{missing_to_present | "unchanged" => nil})

    increased = OracleReports.report("telemetry_dead_handlers", "increased", nil)
    refute Oracle.valid_report?("telemetry_dead_handlers", %{increased | "delta" => 5})
    refute Oracle.valid_report?("telemetry_dead_handlers", %{increased | "status" => "decreased"})
    refute Oracle.valid_report?("telemetry_dead_handlers", %{increased | "event" => []})

    otel = OracleReports.report("otel_global_state", "changed", nil)
    refute Oracle.valid_report?("otel_global_state", %{otel | "status" => "unchanged"})

    refute Oracle.valid_report?("otel_global_state", %{
             otel
             | "targets" => Enum.drop(otel["targets"], 1)
           })

    [tracer | others] = otel["targets"]
    blind = %{tracer | "initial_fingerprint" => nil, "final_fingerprint" => nil}
    refute Oracle.valid_report?("otel_global_state", %{otel | "targets" => [blind | others]})

    refute Oracle.valid_report?("otel_global_state", %{
             otel
             | "targets" => [%{tracer | "initial_observed" => false} | others]
           })

    failure = OracleReports.report("otel_global_state", "operational_failure", nil)
    refute Oracle.valid_report?("otel_global_state", %{failure | "reason" => "made_up"})
  end

  test "accepts a multi-key application report only with a consistent aggregate" do
    single = OracleReports.report("application_env", "changed", nil)
    unchanged = OracleReports.report("application_env", "unchanged", nil)
    fields = ~w(status unchanged initial_presence final_presence initial_observed final_observed
                initial_fingerprint final_fingerprint)

    targets = [
      single |> Map.take(fields) |> Map.put("key", "a"),
      unchanged |> Map.take(fields) |> Map.put("key", "b")
    ]

    multi =
      single
      |> Map.drop(["key" | fields])
      |> Map.merge(%{"status" => "changed", "unchanged" => false, "targets" => targets})

    assert Oracle.valid_report?("application_env", multi)

    refute Oracle.valid_report?("application_env", %{
             multi
             | "status" => "unchanged",
               "unchanged" => true
           })

    refute Oracle.valid_report?("application_env", %{
             multi
             | "targets" => [hd(targets), hd(targets)]
           })
  end

  test "binds a report's identity to the requested inputs" do
    single = OracleReports.report("application_env", "changed", nil)

    request = %{
      "INSIDER_ORACLE_APPLICATION" => "logger",
      "INSIDER_ORACLE_KEY" => "default_handler"
    }

    assert Oracle.bound?("application_env", single, request)
    refute Oracle.bound?("application_env", %{single | "key" => "other_key"}, request)
    refute Oracle.bound?("application_env", %{single | "application" => "kernel"}, request)
    refute Oracle.bound?("application_env", single, %{request | "INSIDER_ORACLE_KEY" => "other"})

    keys_request = %{"INSIDER_ORACLE_APPLICATION" => "logger", "INSIDER_ORACLE_KEYS" => "a,b"}
    refute Oracle.bound?("application_env", single, keys_request)
    target = single |> Map.drop(["application", "key", "context", "limitations", "schema"])

    multi = fn keys ->
      Map.merge(
        Map.take(
          single,
          ~w(application context limitations schema context_byte_limit key_limit value_byte_limit)
        ),
        %{
          "status" => "changed",
          "unchanged" => false,
          "targets" => Enum.map(keys, &Map.put(target, "key", &1))
        }
      )
    end

    assert Oracle.bound?("application_env", multi.(["a", "b"]), keys_request)
    refute Oracle.bound?("application_env", multi.(["b", "a"]), keys_request)
    refute Oracle.bound?("application_env", multi.(["a"]), keys_request)
    refute Oracle.bound?("application_env", multi.(["a", "b"]), request)

    telemetry = OracleReports.report("telemetry_dead_handlers", "increased", nil)
    event = %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "insider,example"}
    assert Oracle.bound?("telemetry_dead_handlers", telemetry, event)

    refute Oracle.bound?("telemetry_dead_handlers", telemetry, %{
             "INSIDER_ORACLE_TELEMETRY_EVENT" => "insider,other"
           })

    assert Oracle.bound?(
             "otel_global_state",
             OracleReports.report("otel_global_state", "changed", nil),
             %{}
           )

    # An operational failure names no target and observes nothing.
    failure = OracleReports.report("application_env", "operational_failure", nil)
    assert Oracle.bound?("application_env", failure, request)
  end
end
