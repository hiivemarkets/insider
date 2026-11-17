defmodule Insider.Discovery.ExUnit.ApplicationEnvOracleArtifactTest do
  use ExUnit.Case, async: true

  alias Insider.Test.OracleArtifactRunner

  @artifact Path.expand(
              "../../../../priv/oracles/application_env_test.exs",
              __DIR__
            )
  @prefix "INSIDER_APPLICATION_ENV_ORACLE="

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-oracle-fixture-" <> suffix)
    File.mkdir!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "reports a changed present value without emitting either value", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("Application.put_env(:logger, :insider_oracle_key, \"secret-before\")"),
        test_module("Application.put_env(:logger, :insider_oracle_key, \"secret-after\")")
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
    assert report["initial_presence"] == "present"
    assert report["final_presence"] == "present"

    assert report["context"] == nil
    refute Map.has_key?(report, "targets")

    assert report["limitations"] == [
             "caller_must_bind_test_and_revision",
             "context_is_caller_supplied_and_unverified",
             "fingerprints_comparable_within_run_only",
             "state_change_does_not_establish_causality"
           ]

    assert String.starts_with?(report["initial_fingerprint"], "hmac-sha256:")
    assert String.starts_with?(report["final_fingerprint"], "hmac-sha256:")
    refute output =~ "secret-before"
    refute output =~ "secret-after"
  end

  test "reports unchanged after a test restores the exact value", %{tmp_dir: tmp_dir} do
    target =
      test_module("""
      original = Application.fetch_env!(:logger, :insider_oracle_key)
      Application.put_env(:logger, :insider_oracle_key, :temporary)
      on_exit(fn -> Application.put_env(:logger, :insider_oracle_key, original) end)
      """)

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("Application.put_env(:logger, :insider_oracle_key, :original)"),
        target
      )

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["unchanged"] == true
    assert report["initial_fingerprint"] == report["final_fingerprint"]
  end

  test "reports a missing target that becomes present", %{tmp_dir: tmp_dir} do
    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module("Application.put_env(:logger, :insider_oracle_missing_key, :created)"),
        key: "insider_oracle_missing_key"
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["initial_presence"] == "missing"
    assert report["final_presence"] == "present"
    assert report["initial_fingerprint"] == nil
  end

  test "reports a target that remains absent as unchanged", %{tmp_dir: tmp_dir} do
    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(":ok"),
        key: "insider_oracle_absent_key"
      )

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["unchanged"] == true
    assert report["initial_presence"] == "missing"
    assert report["final_presence"] == "missing"
  end

  test "reports oversized values as inconclusive without serializing them", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(
          "Application.put_env(:logger, :insider_oracle_key, String.duplicate(\"sensitive\", 140_000))"
        ),
        test_module(":ok")
      )

    assert status == 0
    assert report["status"] == "inconclusive"
    assert report["unchanged"] == nil
    assert report["initial_fingerprint"] == nil
    assert report["final_fingerprint"] == nil
    refute output =~ String.duplicate("sensitive", 2)
  end

  test "emits one structured operational failure for malformed input", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), application: "")

    assert status == 0

    assert report == %{
             "context" => nil,
             "context_byte_limit" => 1_024,
             "key_limit" => 16,
             "limitations" => [
               "caller_must_bind_test_and_revision",
               "context_is_caller_supplied_and_unverified",
               "fingerprints_comparable_within_run_only",
               "state_change_does_not_establish_causality"
             ],
             "reason" => "invalid_target_name",
             "schema" => "insider.application-env-oracle/v1",
             "status" => "operational_failure",
             "value_byte_limit" => 1_048_576
           }

    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "rejects an empty key name", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), key: "")

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "invalid_target_name"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "does not intern an unknown application name", %{tmp_dir: tmp_dir} do
    name = "insider_uninterned_application_#{System.unique_integer([:positive])}"

    target =
      test_module("""
      assert_raise ArgumentError, fn -> String.to_existing_atom(#{inspect(name)}) end
      IO.puts("INSIDER_ATOM_SAFETY_OK")
      """)

    {status, output, report} =
      run_oracle(tmp_dir, bootstrap(""), target, application: name)

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "application_not_loaded"
    assert output =~ "INSIDER_ATOM_SAFETY_OK"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "emits its comparison even when the selected test fails", %{tmp_dir: tmp_dir} do
    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("Application.put_env(:logger, :insider_oracle_key, :before)"),
        test_module(
          "Application.put_env(:logger, :insider_oracle_key, :after)\nflunk(\"fixture\")"
        )
      )

    assert status != 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
  end

  test "test-helper installation brackets test-file loading under Mix", %{tmp_dir: tmp_dir} do
    target = """
    Application.put_env(:logger, :insider_oracle_mix_key, :after_file_load)

    defmodule InsiderOracleMixFixtureTest do
      use ExUnit.Case, async: false
      test "fixture", do: assert(true)
    end
    """

    {status, output} = run_mix_oracle(tmp_dir, target)
    report = OracleArtifactRunner.report(output, @prefix)

    assert status == 0
    assert report["status"] == "changed"
    assert report["initial_presence"] == "present"
    assert report["final_presence"] == "present"
  end

  test "compile failure produces no oracle result and cannot be read as clean", %{
    tmp_dir: tmp_dir
  } do
    {status, output} = run_mix_oracle(tmp_dir, "defmodule Broken do (")

    assert status != 0
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 0
  end

  test "reports a multi-key target set as changed when any key changed", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("""
        Application.put_env(:logger, :insider_oracle_alpha, "secret-alpha")
        Application.put_env(:logger, :insider_oracle_beta, "secret-beta")
        """),
        test_module("Application.put_env(:logger, :insider_oracle_beta, \"secret-gamma\")"),
        keys: "insider_oracle_alpha,insider_oracle_beta,insider_oracle_absent"
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
    assert report["schema"] == "insider.application-env-oracle/v1"
    assert report["application"] == "logger"
    assert report["key_limit"] == 16
    refute Map.has_key?(report, "key")
    refute Map.has_key?(report, "initial_presence")

    assert Enum.map(report["targets"], & &1["key"]) == [
             "insider_oracle_alpha",
             "insider_oracle_beta",
             "insider_oracle_absent"
           ]

    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "changed", "unchanged"]

    [alpha, beta, absent] = report["targets"]
    assert alpha["unchanged"] == true
    assert alpha["initial_fingerprint"] == alpha["final_fingerprint"]
    assert beta["unchanged"] == false
    assert beta["initial_presence"] == "present"
    assert beta["final_presence"] == "present"
    assert beta["initial_fingerprint"] != beta["final_fingerprint"]
    assert absent["initial_presence"] == "missing"
    assert absent["final_presence"] == "missing"

    for target <- report["targets"] do
      assert target |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "final_fingerprint",
                 "final_observed",
                 "final_presence",
                 "initial_fingerprint",
                 "initial_observed",
                 "initial_presence",
                 "key",
                 "status",
                 "unchanged"
               ])
    end

    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    refute output =~ "secret-alpha"
    refute output =~ "secret-beta"
    refute output =~ "secret-gamma"
  end

  test "reports a multi-key target set as unchanged when every key is restored", %{
    tmp_dir: tmp_dir
  } do
    target =
      test_module("""
      original = Application.fetch_env!(:logger, :insider_oracle_alpha)
      Application.put_env(:logger, :insider_oracle_alpha, :temporary)
      on_exit(fn -> Application.put_env(:logger, :insider_oracle_alpha, original) end)
      """)

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("""
        Application.put_env(:logger, :insider_oracle_alpha, :original)
        Application.put_env(:logger, :insider_oracle_beta, :original)
        """),
        target,
        keys: "insider_oracle_alpha,insider_oracle_beta"
      )

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["unchanged"] == true
    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "unchanged"]
  end

  test "reports a multi-key target set as inconclusive only when nothing changed", %{
    tmp_dir: tmp_dir
  } do
    oversized =
      "Application.put_env(:logger, :insider_oracle_large, String.duplicate(\"sensitive\", 140_000))"

    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("Application.put_env(:logger, :insider_oracle_alpha, :stable)\n" <> oversized),
        test_module(":ok"),
        keys: "insider_oracle_alpha,insider_oracle_large"
      )

    assert status == 0
    assert report["status"] == "inconclusive"
    assert report["unchanged"] == nil
    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "inconclusive"]
    refute output =~ String.duplicate("sensitive", 2)

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap("Application.put_env(:logger, :insider_oracle_alpha, :stable)\n" <> oversized),
        test_module("Application.put_env(:logger, :insider_oracle_alpha, :moved)"),
        keys: "insider_oracle_alpha,insider_oracle_large"
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
    assert Enum.map(report["targets"], & &1["status"]) == ["changed", "inconclusive"]
  end

  test "accepts sixteen keys and rejects seventeen", %{tmp_dir: tmp_dir} do
    keys = fn count -> Enum.map_join(1..count, ",", &"insider_oracle_bulk_#{&1}") end

    {status, _output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), keys: keys.(16))

    assert status == 0
    assert report["status"] == "unchanged"
    assert length(report["targets"]) == 16

    {status, output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), keys: keys.(17))

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "too_many_keys"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "rejects duplicate, empty, and oversized key segments", %{tmp_dir: tmp_dir} do
    rejected = [
      {"insider_oracle_alpha,insider_oracle_alpha", "duplicate_key"},
      {"insider_oracle_alpha,,insider_oracle_beta", "invalid_target_name"},
      {"insider_oracle_alpha," <> String.duplicate("k", 256), "invalid_target_name"},
      {"", "invalid_target_name"}
    ]

    for {keys, reason} <- rejected do
      {status, output, report} =
        run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), keys: keys)

      assert status == 0
      assert report["status"] == "operational_failure"
      assert report["reason"] == reason
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    end
  end

  test "rejects setting both the single-key and multi-key selectors", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(":ok"),
        key: "insider_oracle_alpha",
        keys: "insider_oracle_beta"
      )

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "conflicting_key_selectors"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "rejects a run with neither key selector", %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), key: nil)

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "missing_key_selector"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "echoes caller context verbatim without interpreting it", %{tmp_dir: tmp_dir} do
    context = "ticket=INS-7 revision=0123abcd test=\"quoted {json}\" ünïcödé"

    {status, _output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), context: context)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["context"] == context
    assert report["context_byte_limit"] == 1_024

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(":ok"),
        keys: "insider_oracle_alpha,insider_oracle_beta",
        context: context
      )

    assert status == 0
    assert report["context"] == context

    {status, _output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), key: "", context: context)

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "invalid_target_name"
    assert report["context"] == context
  end

  test "rejects oversized, empty, newline, control, and invalid UTF-8 context", %{
    tmp_dir: tmp_dir
  } do
    rejected = [
      String.duplicate("c", 1_025),
      "",
      "line one\nline two",
      "carriage\rreturn",
      "tab\tseparated",
      "escape\e[0m"
    ]

    for context <- rejected do
      {status, output, report} =
        run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), context: context)

      assert status == 0
      assert report["status"] == "operational_failure"
      assert report["reason"] == "invalid_context"
      assert report["context"] == nil
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    end

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(":ok"),
        context: String.duplicate("c", 1_024)
      )

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["context"] == String.duplicate("c", 1_024)

    target =
      test_module("""
      assert {:error, "invalid_context"} =
               InsiderLab.ApplicationEnvOracleArtifact.validate_context_input(<<255>>)

      assert {:error, "invalid_target_name"} =
               InsiderLab.ApplicationEnvOracleArtifact.validate_keys_input("ok,\\xff")

      IO.puts("INSIDER_APPLICATION_ENV_INVALID_UTF8_OK")
      """)

    {status, output, report} = run_oracle(tmp_dir, bootstrap(""), target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert output =~ "INSIDER_APPLICATION_ENV_INVALID_UTF8_OK"
  end

  defp run_oracle(tmp_dir, bootstrap, target, options \\ []) do
    bootstrap_path = Path.join(tmp_dir, "bootstrap.exs")
    target_path = Path.join(tmp_dir, "target.exs")
    File.write!(bootstrap_path, bootstrap)
    File.write!(target_path, target)

    executable = System.find_executable("elixir") || flunk("elixir executable unavailable")

    environment =
      [
        {"INSIDER_ORACLE_APPLICATION", Keyword.get(options, :application, "logger")},
        {"INSIDER_ORACLE_KEY", key_option(options)},
        {"INSIDER_ORACLE_KEYS", Keyword.get(options, :keys)},
        {"INSIDER_ORACLE_CONTEXT", Keyword.get(options, :context)}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map(fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    {status, output} =
      OracleArtifactRunner.run_process(
        executable,
        ["-r", bootstrap_path, "-r", @artifact, target_path],
        environment
      )

    {status, output, OracleArtifactRunner.report(output, @prefix)}
  end

  defp key_option(options) do
    cond do
      Keyword.has_key?(options, :key) -> Keyword.fetch!(options, :key)
      Keyword.has_key?(options, :keys) -> nil
      true -> "insider_oracle_key"
    end
  end

  defp run_mix_oracle(tmp_dir, target) do
    File.mkdir!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule InsiderOracleMixFixture.MixProject do
      use Mix.Project
      def project, do: [app: :insider_oracle_mix_fixture, version: "0.1.0"]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), """
    ExUnit.start()
    Application.put_env(:logger, :insider_oracle_mix_key, :before_file_load)
    Code.require_file(#{inspect(@artifact)})
    """)

    File.write!(Path.join(tmp_dir, "test/target_test.exs"), target)

    executable = System.find_executable("mix") || flunk("mix executable unavailable")

    OracleArtifactRunner.run_process(
      executable,
      ["test", "test/target_test.exs"],
      [
        {~c"MIX_ENV", ~c"test"},
        {~c"INSIDER_ORACLE_APPLICATION", ~c"logger"},
        {~c"INSIDER_ORACLE_KEY", ~c"insider_oracle_mix_key"}
      ],
      tmp_dir
    )
  end

  defp bootstrap(setup) do
    """
    ExUnit.start()
    #{setup}
    """
  end

  defp test_module(body) do
    """
    defmodule InsiderOracleFixtureTest do
      use ExUnit.Case, async: false
      test "fixture" do
        #{body}
      end
    end
    """
  end
end
