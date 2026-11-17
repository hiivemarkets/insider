defmodule Insider.Discovery.ExUnit.TelemetryDeadHandlersOracleArtifactTest do
  use ExUnit.Case, async: true

  alias Insider.Test.OracleArtifactRunner

  @artifact Path.expand(
              "../../../../priv/oracles/telemetry_dead_handlers_test.exs",
              __DIR__
            )
  @prefix "INSIDER_TELEMETRY_DEAD_HANDLERS_ORACLE="
  @event "insider_phase7,telemetry_event"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-telemetry-oracle-fixture-" <> suffix)
    File.mkdir!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "reports an increase when a test leaves a handler with a dead destination", context do
    target =
      test_module("""
      :telemetry_test.attach_event_handlers(self(), [[:insider_phase7, :telemetry_event]])
      """)

    {status, output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "increased"
    assert report["initial_dead_handler_count"] == 0
    assert report["final_dead_handler_count"] == 1
    assert report["delta"] == 1
    assert report["initial_observed"]
    assert report["final_observed"]
    assert report["schema"] == "insider.telemetry-dead-handlers-oracle/v1"
    assert report["event"] == ["insider_phase7", "telemetry_event"]
    assert report["context"] == nil
    assert report["event_byte_limit"] == 2_048
    assert report["event_segment_limit"] == 16
    assert report["event_segment_byte_limit"] == 255
    assert report["context_byte_limit"] == 1_024
    assert report["handler_limit"] == 1_024
    assert report["capture_timeout_ms"] == 1_000
    assert report["capture_heap_words"] == 262_144

    assert report["limitations"] == [
             "caller_must_bind_test_and_revision",
             "context_is_caller_supplied_and_unverified",
             "only_telemetry_test_dead_destinations_are_counted",
             "prefix_lookup_descendants_affect_bounds",
             "handler_snapshot_is_not_atomic",
             "count_change_does_not_establish_causality"
           ]

    assert report |> Map.keys() |> Enum.sort() ==
             Enum.sort([
               "capture_heap_words",
               "capture_timeout_ms",
               "context",
               "context_byte_limit",
               "delta",
               "event",
               "event_byte_limit",
               "event_segment_byte_limit",
               "event_segment_limit",
               "final_dead_handler_count",
               "final_observed",
               "final_reason",
               "final_truncated",
               "handler_limit",
               "initial_dead_handler_count",
               "initial_observed",
               "initial_reason",
               "initial_truncated",
               "limitations",
               "schema",
               "status"
             ])

    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    refute output =~ "#PID"
    refute output =~ "#Reference"
  end

  test "reports unchanged when cleanup detaches the selected handler", context do
    target =
      test_module("""
      reference =
        :telemetry_test.attach_event_handlers(self(), [
          [:insider_phase7, :telemetry_event]
        ])

      on_exit(fn -> :telemetry.detach(reference) end)
      """)

    {status, _output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["delta"] == 0
    assert report["initial_dead_handler_count"] == 0
    assert report["final_dead_handler_count"] == 0
  end

  test "reports a decrease when a pre-existing dead handler is removed", context do
    bootstrap = """
    destination = spawn(fn -> :ok end)
    monitor = Process.monitor(destination)
    receive do
      {:DOWN, ^monitor, :process, ^destination, _reason} -> :ok
    end

    :ok =
      :telemetry.attach(
        :insider_phase7_dead_handler,
        [:insider_phase7, :telemetry_event],
        &:telemetry_test.handle_event/4,
        %{dest_pid: destination, ref: make_ref()}
      )
    """

    target = test_module(":telemetry.detach(:insider_phase7_dead_handler)")
    {status, _output, report} = run_oracle(context.tmp_dir, bootstrap, target)

    assert status == 0
    assert report["status"] == "decreased"
    assert report["initial_dead_handler_count"] == 1
    assert report["final_dead_handler_count"] == 0
    assert report["delta"] == -1
  end

  test "does not intern event segments that never become loaded", context do
    segment = "insider_uninterned_event_#{System.unique_integer([:positive])}"

    target =
      test_module("""
      assert_raise ArgumentError, fn -> String.to_existing_atom(#{inspect(segment)}) end
      IO.puts("INSIDER_TELEMETRY_ATOM_SAFETY_OK")
      """)

    {status, output, report} =
      run_oracle(context.tmp_dir, "", target, event: segment <> ",missing")

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["initial_dead_handler_count"] == 0
    assert report["final_dead_handler_count"] == 0
    assert output =~ "INSIDER_TELEMETRY_ATOM_SAFETY_OK"
  end

  test "ignores live destinations and handlers for descendant events", context do
    target =
      test_module("""
      live_destination = spawn(fn -> receive do: (:stop -> :ok) end)

      :telemetry_test.attach_event_handlers(live_destination, [
        [:insider_phase7, :telemetry_event]
      ])

      :telemetry_test.attach_event_handlers(self(), [
        [:insider_phase7, :telemetry_event, :child]
      ])
      """)

    {status, _output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["initial_dead_handler_count"] == 0
    assert report["final_dead_handler_count"] == 0
  end

  test "ignores a different callback and does not expose its function environment", context do
    target =
      test_module("""
      sentinel = "function-environment-must-not-escape"
      callback = fn _event, _measurements, _metadata, _config -> sentinel end

      :ok =
        :telemetry.attach(
          :insider_phase7_other_callback,
          [:insider_phase7, :telemetry_event],
          callback,
          %{dest_pid: self()}
        )
      """)

    {status, output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["final_dead_handler_count"] == 0
    refute output =~ "function-environment-must-not-escape"
  end

  test "ignores the exact callback without a PID-valued destination", context do
    target =
      test_module("""
      :ok =
        :telemetry.attach(
          :insider_phase7_missing_destination,
          [:insider_phase7, :telemetry_event],
          &:telemetry_test.handle_event/4,
          %{ref: make_ref()}
        )

      :ok =
        :telemetry.attach(
          :insider_phase7_non_pid_destination,
          [:insider_phase7, :telemetry_event],
          &:telemetry_test.handle_event/4,
          %{dest_pid: :not_a_pid, ref: make_ref()}
        )
      """)

    {status, _output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["final_dead_handler_count"] == 0
  end

  test "emits one operational failure for a malformed event", context do
    {status, output, report} =
      run_oracle(context.tmp_dir, "", test_module(":ok"), event: "one,,three")

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "invalid_event_name"
    assert "context_is_caller_supplied_and_unverified" in report["limitations"]
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "rejects invalid UTF-8 and event bounds without loading target atoms", context do
    invalid_events = [
      String.duplicate("a", 2_049),
      String.duplicate("a", 256),
      Enum.join(List.duplicate("a", 17), ",")
    ]

    for event <- invalid_events do
      {status, output, report} =
        run_oracle(context.tmp_dir, "", test_module(":ok"), event: event)

      assert status == 0
      assert report["status"] == "operational_failure"
      assert report["reason"] == "invalid_event_name"
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    end

    target =
      test_module("""
      assert {:error, "invalid_event_name"} =
               InsiderLab.TelemetryDeadHandlersOracleArtifact.validate_event_input(<<255>>)

      IO.puts("INSIDER_TELEMETRY_INVALID_UTF8_OK")
      """)

    {status, output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert output =~ "INSIDER_TELEMETRY_INVALID_UTF8_OK"
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
  end

  test "echoes caller context verbatim without interpreting it", context do
    echoed = "ticket=INS-7 revision=0123abcd test=\"quoted {json}\" ünïcödé"

    {status, _output, report} =
      run_oracle(context.tmp_dir, "", test_module(":ok"), context: echoed)

    assert status == 0
    assert report["status"] == "unchanged"
    assert report["context"] == echoed

    {status, _output, report} =
      run_oracle(context.tmp_dir, "", test_module(":ok"), event: "one,,three", context: echoed)

    assert status == 0
    assert report["status"] == "operational_failure"
    assert report["reason"] == "invalid_event_name"
    assert report["context"] == echoed
  end

  test "rejects oversized, empty, newline, control, and invalid UTF-8 context", context do
    rejected = [
      String.duplicate("c", 1_025),
      "",
      "line one\nline two",
      "carriage\rreturn",
      "tab\tseparated"
    ]

    for echoed <- rejected do
      {status, output, report} =
        run_oracle(context.tmp_dir, "", test_module(":ok"), context: echoed)

      assert status == 0
      assert report["status"] == "operational_failure"
      assert report["reason"] == "invalid_context"
      assert report["context"] == nil
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    end

    target =
      test_module("""
      assert {:error, "invalid_context"} =
               InsiderLab.TelemetryDeadHandlersOracleArtifact.validate_context_input(<<255>>)

      IO.puts("INSIDER_TELEMETRY_INVALID_CONTEXT_UTF8_OK")
      """)

    {status, output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "unchanged"
    assert output =~ "INSIDER_TELEMETRY_INVALID_CONTEXT_UTF8_OK"
  end

  test "accepts the maximum encoded size and maximum segment count", context do
    maximum_bytes =
      Enum.join(
        List.duplicate(String.duplicate("a", 255), 7) ++ [String.duplicate("b", 254), "c"],
        ","
      )

    maximum_segments = Enum.join(List.duplicate("d", 16), ",")
    assert byte_size(maximum_bytes) == 2_048

    for event <- [maximum_bytes, maximum_segments] do
      {status, output, report} =
        run_oracle(context.tmp_dir, "", test_module(":ok"), event: event)

      assert status == 0
      assert report["status"] == "unchanged"
      assert report["initial_dead_handler_count"] == 0
      assert report["final_dead_handler_count"] == 0
      assert OracleArtifactRunner.prefix_count(output, @prefix) == 1
    end
  end

  test "reports inconclusive when the exact-event handler bound is exceeded", context do
    bootstrap = """
    event = [:insider_phase7, :telemetry_event]

    for _index <- 1..1_025 do
      :ok =
        :telemetry.attach(
          make_ref(),
          event,
          &:telemetry_test.handle_event/4,
          %{dest_pid: self(), ref: make_ref()}
        )
    end
    """

    {status, _output, report} =
      run_oracle(context.tmp_dir, bootstrap, test_module(":ok"))

    assert status == 0
    assert report["status"] == "inconclusive"
    assert report["delta"] == nil
    refute report["initial_observed"]
    assert report["initial_reason"] == "handler_limit_exceeded"
  end

  test "reports inconclusive when descendant handlers exceed the prefix bound", context do
    bootstrap = """
    event = [:insider_phase7, :telemetry_event, :child]

    for _index <- 1..1_025 do
      :ok =
        :telemetry.attach(
          make_ref(),
          event,
          &:telemetry_test.handle_event/4,
          %{dest_pid: self(), ref: make_ref()}
        )
    end
    """

    {status, _output, report} =
      run_oracle(context.tmp_dir, bootstrap, test_module(":ok"))

    assert status == 0
    assert report["status"] == "inconclusive"
    assert report["initial_reason"] == "handler_limit_exceeded"
    assert report["initial_dead_handler_count"] == nil
  end

  test "emits a comparison even when the selected test fails", context do
    target =
      test_module("""
      :telemetry_test.attach_event_handlers(self(), [[:insider_phase7, :telemetry_event]])
      flunk("fixture")
      """)

    {status, _output, report} = run_oracle(context.tmp_dir, "", target)

    assert status != 0
    assert report["status"] == "increased"
    assert report["delta"] == 1
  end

  test "output excludes handler identities and arbitrary configuration", context do
    target =
      test_module("""
      destination = self()

      :ok =
        :telemetry.attach(
          :sensitive_handler_identity,
          [:insider_phase7, :telemetry_event],
          &:telemetry_test.handle_event/4,
          %{dest_pid: destination, ref: make_ref(), secret: "must-not-escape"}
        )
      """)

    {status, output, report} = run_oracle(context.tmp_dir, "", target)

    assert status == 0
    assert report["status"] == "increased"
    refute output =~ "sensitive_handler_identity"
    refute output =~ "must-not-escape"
  end

  test "test-helper installation brackets top-level test-file attachment under Mix", context do
    target = """
    destination = spawn(fn -> :ok end)
    monitor = Process.monitor(destination)
    receive do: ({:DOWN, ^monitor, :process, ^destination, _reason} -> :ok)

    :ok =
      :telemetry.attach(
        :insider_phase7_top_level,
        [:insider_phase7, :telemetry_event],
        &:telemetry_test.handle_event/4,
        %{dest_pid: destination, ref: make_ref()}
      )

    defmodule InsiderTelemetryOracleMixFixtureTest do
      use ExUnit.Case, async: false
      test "fixture", do: assert(true)
    end
    """

    {status, output} = run_mix_oracle(context.tmp_dir, target)
    report = OracleArtifactRunner.report(output, @prefix)

    assert status == 0
    assert report["status"] == "increased"
    assert report["initial_dead_handler_count"] == 0
    assert report["final_dead_handler_count"] == 1
  end

  test "compile failure produces no oracle result and cannot be read as clean", context do
    {status, output} = run_mix_oracle(context.tmp_dir, "defmodule Broken do (")

    assert status != 0
    assert OracleArtifactRunner.prefix_count(output, @prefix) == 0
  end

  defp run_oracle(tmp_dir, bootstrap, target, options \\ []) do
    bootstrap_path = Path.join(tmp_dir, "bootstrap.exs")
    target_path = Path.join(tmp_dir, "target.exs")

    File.write!(
      bootstrap_path,
      "ExUnit.start()\nApplication.ensure_all_started(:telemetry)\n" <> bootstrap
    )

    File.write!(target_path, target)

    executable = System.find_executable("elixir") || flunk("elixir executable unavailable")
    event = Keyword.get(options, :event, @event)

    environment =
      [
        {"INSIDER_ORACLE_TELEMETRY_EVENT", event},
        {"INSIDER_ORACLE_CONTEXT", Keyword.get(options, :context)}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map(fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    {status, output} =
      OracleArtifactRunner.run_process(
        executable,
        ["-pa", telemetry_ebin(), "-r", bootstrap_path, "-r", @artifact, target_path],
        environment
      )

    {status, output, OracleArtifactRunner.report(output, @prefix)}
  end

  defp run_mix_oracle(tmp_dir, target) do
    File.mkdir!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule InsiderTelemetryOracleMixFixture.MixProject do
      use Mix.Project
      def project,
        do: [app: :insider_telemetry_oracle_fixture, version: "0.1.0", deps: deps()]
      def application, do: [extra_applications: [:logger, :telemetry]]
      defp deps, do: [{:telemetry, path: #{inspect(telemetry_dependency())}}]
    end
    """)

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), """
    ExUnit.start()
    Code.require_file(#{inspect(@artifact)})
    """)

    File.write!(Path.join(tmp_dir, "test/target_test.exs"), target)
    executable = System.find_executable("mix") || flunk("mix executable unavailable")

    OracleArtifactRunner.run_process(
      executable,
      ["test", "test/target_test.exs"],
      [
        {~c"MIX_ENV", ~c"test"},
        {~c"INSIDER_ORACLE_TELEMETRY_EVENT", to_charlist(@event)}
      ],
      tmp_dir
    )
  end

  defp telemetry_ebin,
    do: Path.join([Mix.Project.build_path(), "lib", "telemetry", "ebin"])

  defp telemetry_dependency,
    do: Path.expand("../../../../../../deps/telemetry", __DIR__)

  defp test_module(body) do
    """
    defmodule InsiderTelemetryOracleFixtureTest do
      use ExUnit.Case, async: false
      test "fixture" do
        #{body}
      end
    end
    """
  end
end
