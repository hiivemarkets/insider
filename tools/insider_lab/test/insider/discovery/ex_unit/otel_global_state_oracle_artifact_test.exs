defmodule Insider.Discovery.ExUnit.OtelGlobalStateOracleArtifactTest do
  use ExUnit.Case, async: true

  alias Insider.Test.OracleArtifactRunner

  @artifact Path.expand(
              "../../../../priv/oracles/otel_global_state_test.exs",
              __DIR__
            )
  @prefix "INSIDER_OTEL_GLOBAL_STATE_ORACLE="
  @globals ["default_tracer", "text_map_injector", "text_map_extractor"]
  @limitations [
    "caller_must_bind_test_and_revision",
    "context_is_caller_supplied_and_unverified",
    "fingerprints_comparable_within_run_only",
    "global_state_change_does_not_establish_causality",
    "only_default_tracer_and_text_map_propagator_are_observed"
  ]
  # Module names the child VM's default and fixture globals resolve to. None
  # may appear in the emitted report line.
  @module_names [
    "otel_tracer_noop",
    "otel_tracer_default",
    "otel_propagator_text_map_noop",
    "otel_propagator_text_map",
    "otel_propagator_trace_context"
  ]

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-otel-oracle-fixture-" <> suffix)
    File.mkdir!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "reports every global unchanged when the suite leaves them alone", %{tmp_dir: tmp_dir} do
    {status, output, report} = run_oracle(tmp_dir, bootstrap(""), test_module(":ok"))

    assert status == 0
    assert report["schema"] == "insider.otel-global-state-oracle/v1"
    assert report["status"] == "unchanged"
    assert report["unchanged"] == true
    assert report["context"] == nil
    assert report["limitations"] == @limitations
    assert report["api_application"] == "opentelemetry_api"
    assert report["sdk_application"] == "opentelemetry"
    assert report["initial_sdk_loaded"] == false
    assert report["initial_sdk_started"] == false
    assert report["final_sdk_loaded"] == false
    assert report["final_sdk_started"] == false
    assert report["value_byte_limit"] == 1_048_576
    assert report["context_byte_limit"] == 1_024

    assert Enum.map(report["targets"], & &1["global"]) == @globals

    for target <- report["targets"] do
      assert target["status"] == "unchanged"
      assert target["unchanged"] == true
      assert target["initial_observed"] == true
      assert target["final_observed"] == true
      assert String.starts_with?(target["initial_fingerprint"], "hmac-sha256:")
      assert target["initial_fingerprint"] == target["final_fingerprint"]

      assert target |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "final_fingerprint",
                 "final_observed",
                 "global",
                 "initial_fingerprint",
                 "initial_observed",
                 "status",
                 "unchanged"
               ])
    end

    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    refute_module_names(output)
  end

  test "reports changed when a test replaces the propagator and does not restore it", %{
    tmp_dir: tmp_dir
  } do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(":opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)")
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "changed", "changed"]

    [tracer, injector, extractor] = report["targets"]
    assert tracer["initial_fingerprint"] == tracer["final_fingerprint"]
    assert injector["initial_fingerprint"] != injector["final_fingerprint"]
    assert extractor["initial_fingerprint"] != extractor["final_fingerprint"]
    refute_module_names(output)
  end

  test "reports changed when a test replaces the default tracer without emitting its config",
       %{tmp_dir: tmp_dir} do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module(
          "assert :opentelemetry.set_default_tracer({:otel_tracer_noop, \"secret-tracer-config\"})"
        )
      )

    assert status == 0
    assert report["status"] == "changed"
    assert Enum.map(report["targets"], & &1["status"]) == ["changed", "unchanged", "unchanged"]
    refute output =~ "secret-tracer-config"
    refute_module_names(output)
  end

  test "reports unchanged when a test restores every global it replaced", %{tmp_dir: tmp_dir} do
    target =
      test_module("""
      tracer = :opentelemetry.get_tracer()
      injector = :opentelemetry.get_text_map_injector()
      extractor = :opentelemetry.get_text_map_extractor()
      assert :opentelemetry.set_default_tracer({:otel_tracer_noop, :temporary})
      :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)

      on_exit(fn ->
        :opentelemetry.set_default_tracer(tracer)
        :opentelemetry.set_text_map_injector(injector)
        :opentelemetry.set_text_map_extractor(extractor)
      end)
      """)

    {status, _output, report} = run_oracle(tmp_dir, bootstrap(""), target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["unchanged"] == true
    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "unchanged", "unchanged"]
  end

  test "reports an oversized global as inconclusive only when nothing else changed", %{
    tmp_dir: tmp_dir
  } do
    oversized =
      "true = :opentelemetry.set_default_tracer({:otel_tracer_noop, String.duplicate(\"sensitive\", 140_000)})"

    {status, output, report} = run_oracle(tmp_dir, bootstrap(oversized), test_module(":ok"))

    assert status == 0
    assert report["status"] == "inconclusive"
    assert report["unchanged"] == nil

    assert Enum.map(report["targets"], & &1["status"]) == [
             "inconclusive",
             "unchanged",
             "unchanged"
           ]

    [tracer | _rest] = report["targets"]
    assert tracer["initial_observed"] == true
    assert tracer["initial_fingerprint"] == nil
    assert tracer["final_fingerprint"] == nil
    refute output =~ String.duplicate("sensitive", 2)

    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(oversized),
        test_module(":opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)")
      )

    assert status == 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
    assert Enum.map(report["targets"], & &1["status"]) == ["inconclusive", "changed", "changed"]
  end

  test "records whether the SDK application is loaded and started", %{tmp_dir: tmp_dir} do
    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module("""
        :ok = Application.load(:opentelemetry)
        refute :opentelemetry in Enum.map(Application.started_applications(), &elem(&1, 0))
        """),
        extra_bootstrap: fake_sdk_app(tmp_dir)
      )

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["initial_sdk_loaded"] == false
    assert report["initial_sdk_started"] == false
    assert report["final_sdk_loaded"] == true
    assert report["final_sdk_started"] == false
  end

  test "emits one structured operational failure when the API application is not loaded", %{
    tmp_dir: tmp_dir
  } do
    target =
      test_module("""
      refute Code.ensure_loaded?(:opentelemetry)
      IO.puts("INSIDER_OTEL_API_ABSENT_OK")
      """)

    {status, output, report} = run_oracle(tmp_dir, "ExUnit.start()\n", target, api: false)

    assert status == 0
    assert output =~ "INSIDER_OTEL_API_ABSENT_OK"

    assert report == %{
             "api_application" => "opentelemetry_api",
             "context" => nil,
             "context_byte_limit" => 1_024,
             "limitations" => @limitations,
             "reason" => "opentelemetry_api_not_loaded",
             "schema" => "insider.otel-global-state-oracle/v1",
             "sdk_application" => "opentelemetry",
             "status" => "operational_failure",
             "value_byte_limit" => 1_048_576
           }

    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "treats an API on the code path but not loaded as an operational failure", %{
    tmp_dir: tmp_dir
  } do
    {status, output, report} =
      run_oracle(
        tmp_dir,
        "ExUnit.start()\n",
        test_module("assert Code.ensure_loaded?(:opentelemetry)")
      )

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "opentelemetry_api_not_loaded"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "emits its comparison even when the selected test fails", %{tmp_dir: tmp_dir} do
    {status, _output, report} =
      run_oracle(
        tmp_dir,
        bootstrap(""),
        test_module("""
        :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)
        flunk("fixture")
        """)
      )

    assert status != 0
    assert report["status"] == "changed"
    assert report["unchanged"] == false
  end

  test "test-helper installation brackets test-file loading under Mix", %{tmp_dir: tmp_dir} do
    target = """
    :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)

    defmodule InsiderOtelOracleMixFixtureTest do
      use ExUnit.Case, async: false
      test "fixture", do: assert(true)
    end
    """

    {status, output} = run_mix_oracle(tmp_dir, target)
    report = OracleArtifactRunner.report(output, @prefix)

    assert status == 0
    assert report["status"] == "changed"
    assert Enum.map(report["targets"], & &1["status"]) == ["unchanged", "changed", "changed"]
  end

  test "compile failure produces no oracle result and cannot be read as clean", %{
    tmp_dir: tmp_dir
  } do
    {status, output} = run_mix_oracle(tmp_dir, "defmodule Broken do (")

    assert status != 0
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 0
  end

  test "echoes caller context verbatim without interpreting it", %{tmp_dir: tmp_dir} do
    context = "ticket=INS-7 revision=0123abcd test=\"quoted {json}\" ünïcödé"

    {status, _output, report} =
      run_oracle(tmp_dir, bootstrap(""), test_module(":ok"), context: context)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["context"] == context

    {status, _output, report} =
      run_oracle(tmp_dir, "ExUnit.start()\n", test_module(":ok"), api: false, context: context)

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "opentelemetry_api_not_loaded"
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
               InsiderLab.OtelGlobalStateOracleArtifact.validate_context_input(<<255>>)

      IO.puts("INSIDER_OTEL_INVALID_UTF8_OK")
      """)

    {status, output, report} = run_oracle(tmp_dir, bootstrap(""), target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert output =~ "INSIDER_OTEL_INVALID_UTF8_OK"
  end

  defp refute_module_names(output) do
    line =
      output
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, @prefix))

    for name <- @module_names, do: refute(line =~ name)
  end

  # The child VM receives the Lab test build's `opentelemetry_api` ebin on its
  # code path only when `api: true`; the bootstrap then loads the application
  # exactly as an adopter's `mix test` would.
  defp run_oracle(tmp_dir, bootstrap, target, options \\ []) do
    bootstrap_path = Path.join(tmp_dir, "bootstrap.exs")
    target_path = Path.join(tmp_dir, "target.exs")
    File.write!(bootstrap_path, Keyword.get(options, :extra_bootstrap, "") <> bootstrap)
    File.write!(target_path, target)

    executable = System.find_executable("elixir") || flunk("elixir executable unavailable")

    code_path =
      if Keyword.get(options, :api, true), do: ["-pa", api_ebin()], else: []

    environment =
      case Keyword.fetch(options, :context) do
        {:ok, context} -> [{~c"INSIDER_ORACLE_CONTEXT", to_charlist(context)}]
        :error -> []
      end

    {status, output} =
      OracleArtifactRunner.run_process(
        executable,
        code_path ++ ["-r", bootstrap_path, "-r", @artifact, target_path],
        environment
      )

    {status, output, OracleArtifactRunner.report(output, @prefix)}
  end

  defp api_ebin do
    case :code.lib_dir(:opentelemetry_api) do
      {:error, reason} -> flunk("opentelemetry_api is not on the Lab test code path: #{reason}")
      directory -> Path.join(List.to_string(directory), "ebin")
    end
  end

  # A loadable `opentelemetry` application resource with no modules, so a
  # fixture can load the SDK application name without the SDK dependency.
  defp fake_sdk_app(tmp_dir) do
    ebin = Path.join(tmp_dir, "fake_sdk/ebin")
    File.mkdir_p!(ebin)

    File.write!(Path.join(ebin, "opentelemetry.app"), """
    {application, opentelemetry,
     [{description, "fixture"}, {vsn, "0.0.0"}, {modules, []}, {registered, []},
      {applications, [kernel, stdlib]}]}.
    """)

    "true = Code.prepend_path(#{inspect(ebin)})\n"
  end

  defp run_mix_oracle(tmp_dir, target) do
    File.mkdir!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule InsiderOtelOracleMixFixture.MixProject do
      use Mix.Project
      def project, do: [app: :insider_otel_oracle_mix_fixture, version: "0.1.0"]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), """
    ExUnit.start()
    true = Code.prepend_path(#{inspect(api_ebin())})
    {:ok, _started} = Application.ensure_all_started(:opentelemetry_api)
    Code.require_file(#{inspect(@artifact)})
    """)

    File.write!(Path.join(tmp_dir, "test/target_test.exs"), target)

    executable = System.find_executable("mix") || flunk("mix executable unavailable")

    OracleArtifactRunner.run_process(
      executable,
      ["test", "test/target_test.exs"],
      [{~c"MIX_ENV", ~c"test"}],
      tmp_dir
    )
  end

  defp bootstrap(setup) do
    """
    ExUnit.start()
    {:ok, _started} = Application.ensure_all_started(:opentelemetry_api)
    #{setup}
    """
  end

  defp test_module(body) do
    """
    defmodule InsiderOtelOracleFixtureTest do
      use ExUnit.Case, async: false
      test "fixture" do
        #{body}
      end
    end
    """
  end
end
