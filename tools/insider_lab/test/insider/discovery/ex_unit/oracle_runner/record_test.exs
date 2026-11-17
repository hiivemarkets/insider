defmodule Insider.Discovery.ExUnit.OracleRunner.RecordTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Record
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy
  alias Insider.Event.Canonical

  @fixture Path.expand("../../../../fixtures/oracle_run_v1.json", __DIR__)

  setup do
    bytes = File.read!(@fixture)
    {:ok, record} = Record.decode(bytes)
    {:ok, bytes: bytes, record: record}
  end

  test "the committed v1 fixture decodes and re-encodes to the same canonical bytes", %{
    bytes: bytes,
    record: record
  } do
    assert record["schema"] == "insider.oracle-run/v1"
    assert record["status"] == "confirmed"
    assert {:ok, encoded} = Record.encode(record)
    assert encoded <> "\n" == bytes
    assert Record.decode(encoded) == {:ok, record}
  end

  test "exit status distinguishes every completeness state and complete outcome", %{
    record: record
  } do
    assert Record.exit_status(record) == 2
    assert Record.exit_status(%{record | "outcome" => "not_reproduced"}) == 0
    assert Record.exit_status(%{record | "outcome" => "not_observed"}) == 6
    assert Record.exit_status(%{"completeness" => "empty_selection"}) == 3
    assert Record.exit_status(%{"completeness" => "unsupported_source"}) == 4
    assert Record.exit_status(%{"completeness" => "truncated"}) == 5
    assert Record.exit_status(%{"completeness" => "infrastructure_failure"}) == 70

    assert Enum.sort(Record.completeness_states()) ==
             ~w(complete empty_selection infrastructure_failure truncated unsupported_source)
  end

  test "status names the completeness state unless the run is complete" do
    assert Record.status("complete", "confirmed") == "confirmed"
    assert Record.status("truncated", "confirmed") == "truncated"
  end

  # record.ex runner_assignments/3 joins a decoded record's file names into
  # paths, so each must be a plain relative name.
  test "rejects a record whose recorded file names are not plain relative names", %{
    record: record
  } do
    fields = [
      ["oracle", "source_file"],
      ["command", "runner_files", "bootstrap", "file"],
      ["command", "runner_files", "overlay", "file"]
    ]

    for field <- fields,
        unsafe <- ["../x", "/etc/passwd", "runner/../../x", "oracle/../../escape.exs"] do
      candidate = put_in(record, field, unsafe)
      assert Record.validate(candidate) == {:error, "unsafe_path"}, "#{inspect(field)} #{unsafe}"
      assert Record.decode(Jason.encode!(candidate)) == {:error, "unsafe_path"}
    end
  end

  test "rejects malformed and unsupported input" do
    assert Record.decode("not json") == {:error, "invalid_json"}
    assert Record.decode("[]") == {:error, "invalid_record"}
    assert Record.decode(~s({"schema":"insider.oracle-run/v2"})) == {:error, "unsupported_schema"}
    assert Record.decode(String.duplicate(" ", 262_145)) == {:error, "record_too_large"}
    assert Record.decode(nil) == {:error, "invalid_record"}
    assert Record.validate([]) == {:error, "invalid_record"}
  end

  test "rejects structural and coherence violations", %{record: record} do
    invalid = [
      Map.delete(record, "cleanup"),
      Map.put(record, "extra", true),
      %{record | "run_id" => "short"},
      %{record | "status" => "complete"},
      %{record | "outcome" => "contract_disproved", "status" => "contract_disproved"},
      %{
        record
        | "completeness" => "infrastructure_failure",
          "status" => "infrastructure_failure"
      },
      %{record | "completeness_reason" => "target_changed"},
      %{record | "oracle_result" => nil},
      %{record | "limitations" => Enum.drop(record["limitations"], 1)},
      %{record | "started_at" => "2999-01-01T00:00:00Z"},
      %{record | "duration_ms" => -1},
      put_in(record, ["target", "root"], "relative/root"),
      put_in(record, ["target", "git_revision"], "HEAD"),
      put_in(record, ["profile", "sha256"], String.duplicate("0", 64)),
      put_in(record, ["oracle", "source_file"], "oracle/other_test.exs"),
      put_in(record, ["command", "environment", "set", "lower_case"], "value"),
      put_in(record, ["exit"], %{"status" => nil, "termination" => "exited"}),
      put_in(record, ["output", "truncated"], true),
      put_in(record, ["output", "withheld"], "too_many_lines"),
      put_in(record, ["output", "withheld"], nil),
      record
      |> put_in(["output", "withheld"], "secret_count_exceeded")
      |> put_in(["output", "redactions"], 1),
      put_in(record, ["cleanup", "verdict"], "clean"),
      put_in(record, ["suite", "total"], -1),
      put_in(record, ["target", "changed_path_count"], 1),
      put_in(record, ["target", "changed_paths"], nil),
      put_in(record, ["target", "fingerprint_after"], nil)
    ]

    for candidate <- invalid, do: assert(Record.validate(candidate) == {:error, "invalid_record"})
  end

  test "an output withheld by a redaction bound validates under either policy", %{record: record} do
    for policy <- ~w(allowlisted redacted) do
      withheld =
        update_in(record["output"], fn output ->
          Map.merge(output, %{
            "policy" => policy,
            "withheld" => "secret_bytes_exceeded",
            "lines_withheld" => 4,
            "redactions" => 0
          })
        end)

      assert Record.validate(withheld) == {:ok, withheld}
    end
  end

  @tag :tmp_dir
  test "every withholding reason survives a write, read back, and decode", %{
    record: record,
    tmp_dir: tmp_dir
  } do
    for reason <- OutputPolicy.withheld_reasons(), policy <- OutputPolicy.policies() do
      withheld =
        update_in(record["output"], fn output ->
          Map.merge(output, %{
            "policy" => policy,
            "withheld" => reason,
            "lines_withheld" => 3,
            "redactions" => 0
          })
        end)

      path = Path.join(tmp_dir, "#{reason}-#{policy}.json")
      assert {:ok, encoded} = Record.encode(withheld)
      File.write!(path, encoded <> "\n")

      assert {:ok, decoded} = path |> File.read!() |> Record.decode()
      assert decoded == withheld
      assert decoded["output"]["withheld"] == reason
    end
  end

  test "a complete verdict must be backed by its own evidence", %{record: record} do
    reviewed_contradiction = %{
      record
      | "oracle_result" => %{},
        "suite" => nil,
        "runtime" => nil,
        "exit" => %{"termination" => "spawn_failed", "status" => nil},
        "cleanup" => %{"process" => "not_started", "verdict" => "unchanged"}
    }

    result = record["oracle_result"]

    contradictions = [
      reviewed_contradiction,
      %{record | "oracle_result" => %{}},
      %{record | "oracle_result" => Map.delete(result, "key")},
      %{record | "oracle_result" => %{result | "status" => "unchanged"}},
      %{record | "oracle_result" => %{result | "context" => "insider-oracle-run:other"}},
      %{record | "oracle_result" => %{result | "key" => "other_key"}},
      %{record | "oracle_result" => %{result | "application" => "kernel"}},
      put_in(record, ["oracle", "inputs", "INSIDER_ORACLE_KEY"], "other_key"),
      %{
        record
        | "oracle_result" => %{result | "initial_fingerprint" => nil, "final_fingerprint" => nil}
      },
      %{record | "outcome" => "not_reproduced", "status" => "not_reproduced"},
      %{record | "suite" => nil},
      %{record | "suite" => %{record["suite"] | "failures" => 1}},
      %{record | "suite" => %{record["suite"] | "excluded" => 1}},
      %{record | "runtime" => nil},
      %{record | "exit" => %{"termination" => "exited", "status" => 1}},
      %{record | "exit" => %{"termination" => "deadline_exceeded", "status" => nil}},
      put_in(record, ["cleanup", "process"], "uncertain"),
      put_in(record, ["cleanup", "verdict"], "unverified"),
      put_in(record, ["oracle", "id"], "otel_global_state"),
      put_in(record, ["oracle", "result_prefix"], "OTHER="),
      %{
        record
        | "completeness" => "truncated",
          "completeness_reason" => "output_truncated",
          "status" => "truncated"
      }
    ]

    for candidate <- contradictions do
      assert Record.validate(candidate) == {:error, "invalid_record"}
    end
  end

  # Each modification alone must make the record invalid.
  test "a complete verdict must agree with its recorded command and environment", %{
    record: record
  } do
    profile = record["profile"]
    other_schema = %{profile["document"] | "schema" => "not-an-oracle-profile"}

    contradictions = %{
      "no executable" => put_in(record, ["command", "executable"], nil),
      "other executable" => put_in(record, ["command", "executable"], "/usr/local/bin/elixir"),
      "cwd is not the target" => put_in(record, ["command", "cwd"], "/elsewhere"),
      "child selects another key" =>
        put_in(record, ["command", "environment", "set", "INSIDER_ORACLE_KEY"], "other_key"),
      "child lacks the key" =>
        update_in(
          record,
          ["command", "environment", "set"],
          &Map.delete(&1, "INSIDER_ORACLE_KEY")
        ),
      "child has another context" =>
        put_in(record, ["command", "environment", "set", "INSIDER_ORACLE_CONTEXT"], "other"),
      "conflicting selectors in the child" =>
        put_in(record, ["command", "environment", "set", "INSIDER_ORACLE_KEYS"], "a,b"),
      "conflicting selectors in the inputs" =>
        put_in(record, ["oracle", "inputs", "INSIDER_ORACLE_KEYS"], "a,b"),
      "empty selection" => put_in(record, ["command", "test_arguments"], []),
      "options only" => put_in(record, ["command", "test_arguments"], ["--seed", "0"]),
      "escaping selection" => put_in(record, ["command", "test_arguments"], ["../x_test.exs"]),
      "unsupported test option" =>
        put_in(
          record,
          ["command", "test_arguments"],
          record["command"]["test_arguments"] ++ ["--cover"]
        ),
      "arguments do not run tests" => put_in(record, ["command", "arguments"], ["--help"]),
      "arguments disagree with the selection" =>
        put_in(record, ["command", "arguments"], ["test", "test/other_test.exs"]),
      "invalid nested profile" =>
        put_in(record, ["profile"], %{
          profile
          | "document" => other_schema,
            "sha256" => Canonical.sha256(other_schema)
        })
    }

    for {name, candidate} <- contradictions do
      assert Record.validate(candidate) == {:error, "invalid_record"}, name
    end
  end

  @bootstrap_keys ~w(MIX_ENV MIX_EXS INSIDER_ORACLE_RUNNER_HOST_MIX_EXS INSIDER_ORACLE_RUNNER_ORACLE
                     INSIDER_ORACLE_RUNNER_OVERLAY INSIDER_ORACLE_RUNNER_TEST_ALIAS)

  # Each substitution alone must make the record invalid.
  test "the recorded child environment must be exactly what the runner assigns", %{
    record: record
  } do
    contradictions = %{
      "MIX_ENV prod" => set(record, "MIX_ENV", "prod"),
      "MIX_EXS is the target's mix.exs" => set(record, "MIX_EXS", "/work/target/mix.exs"),
      "MIX_EXS removed" => unset(record, ["MIX_EXS"]),
      "all bootstrap assignments removed" => unset(record, @bootstrap_keys),
      "alias mode contradicts the profile" =>
        set(record, "INSIDER_ORACLE_RUNNER_TEST_ALIAS", "absent"),
      "oracle path elsewhere" =>
        set(record, "INSIDER_ORACLE_RUNNER_ORACLE", "/tmp/unrelated.exs"),
      "overlay elsewhere" => set(record, "INSIDER_ORACLE_RUNNER_OVERLAY", "/tmp/overlay"),
      "host mix.exs elsewhere" =>
        set(record, "INSIDER_ORACLE_RUNNER_HOST_MIX_EXS", "/elsewhere/mix.exs"),
      "bootstrap paths under different run directories" =>
        set(record, "MIX_EXS", "/work/runs/other/runner/mix.exs"),
      "undeclared value retained" => set(record, "UNDECLARED_SECRET", "value"),
      "suffix without a declared suffix" => set(record, "DB_SUFFIX", "_x"),
      "undeclared passthrough name" =>
        put_in(record, ["command", "environment", "passthrough_present"], ["UNDECLARED"]),
      "inherited beyond HOME and PATH" =>
        put_in(record, ["command", "environment", "inherited"], ["HOME", "PATH", "AWS_SECRET"])
    }

    for {name, candidate} <- contradictions do
      assert Record.validate(candidate) == {:error, "invalid_record"}, name
    end
  end

  test "passthrough lists partition the profile's names and the suffix matches it", %{
    record: record
  } do
    declared =
      record
      |> with_profile(%{
        "passthrough_env" => ["ALPHA", "BETA", "GAMMA"],
        "db_suffix" => %{"variable" => "DB_SUFFIX", "value" => "_slot"}
      })
      |> set("DB_SUFFIX", "_slot")
      |> put_in(["command", "environment", "passthrough_present"], ["ALPHA", "GAMMA"])
      |> put_in(["command", "environment", "passthrough_absent"], ["BETA"])

    assert {:ok, _record} = Record.validate(declared)

    contradictions = %{
      "duplicate present name" => passthrough(declared, ["ALPHA", "ALPHA", "GAMMA"], ["BETA"]),
      "name both present and absent" =>
        passthrough(declared, ["ALPHA", "GAMMA"], ["BETA", "GAMMA"]),
      "declared name missing" => passthrough(declared, ["ALPHA"], ["BETA"]),
      "order differs from the profile" => passthrough(declared, ["GAMMA", "ALPHA"], ["BETA"]),
      "suffix value differs from the literal" => set(declared, "DB_SUFFIX", "_other"),
      "declared suffix missing" => unset(declared, ["DB_SUFFIX"]),
      "passthrough name assigned a value" => set(declared, "ALPHA", "secret")
    }

    for {name, candidate} <- contradictions do
      assert Record.validate(candidate) == {:error, "invalid_record"}, name
    end
  end

  defp set(record, name, value),
    do: put_in(record, ["command", "environment", "set", name], value)

  defp unset(record, names),
    do: update_in(record, ["command", "environment", "set"], &Map.drop(&1, names))

  defp passthrough(record, present, absent) do
    record
    |> put_in(["command", "environment", "passthrough_present"], present)
    |> put_in(["command", "environment", "passthrough_absent"], absent)
  end

  defp with_profile(record, changes) do
    document = Map.merge(record["profile"]["document"], changes)

    put_in(record, ["profile"], %{
      record["profile"]
      | "document" => document,
        "sha256" => Canonical.sha256(document)
    })
  end

  test "accepts the documented non-complete shapes", %{record: record} do
    infrastructure = %{
      record
      | "completeness" => "infrastructure_failure",
        "completeness_reason" => "result_line_missing",
        "outcome" => "infrastructure_failure",
        "status" => "infrastructure_failure",
        "oracle_result" => nil,
        "suite" => nil,
        "runtime" => nil
    }

    unsupported = %{
      infrastructure
      | "completeness" => "unsupported_source",
        "completeness_reason" => "test_alias_present",
        "outcome" => "not_observed",
        "status" => "unsupported_source",
        "exit" => %{"status" => nil, "termination" => "not_started"},
        "cleanup" => %{"process" => "not_started", "verdict" => "unverified"}
    }

    assert {:ok, _record} = Record.validate(infrastructure)
    assert {:ok, _record} = Record.validate(unsupported)
    assert {:error, _reason} = Record.validate(%{unsupported | "outcome" => "confirmed"})
  end
end
