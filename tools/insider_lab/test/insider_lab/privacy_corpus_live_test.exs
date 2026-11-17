defmodule Insider.Lab.PrivacyCorpusLiveTest do
  # The real Telemetry collector attaches a VM-global handler to the fixture
  # event names shared with other collector tests.
  use ExUnit.Case, async: false

  alias Insider.Collector.Telemetry, as: TelemetryCollector
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Event
  alias Insider.Lab.PrivacyCorpus
  alias Insider.Recorder
  alias Insider.Redaction.Policy, as: RedactionPolicy

  @start [:insider, :fixture, :operation, :start]
  @envelope [
    "authority",
    "boot_id",
    "clock_id",
    "extensions",
    "id",
    "monotonic_time",
    "node",
    "redactions",
    "schema",
    "source_instance_id",
    "source_sequence"
  ]

  test "corpus projection reports exactly the fields a live Telemetry collector records" do
    policy = policy()
    measurements = %{duration: 3, secret_measurement: "CANARY-MEASURE"}

    metadata = %{
      run_id: "op-live",
      scenario: :checkout,
      trace_id: <<7::128>>,
      email: "CANARY-MAIL"
    }

    corpus = %{
      "schema" => "insider.privacy-corpus/v1",
      "canary_tokens" => ["CANARY-MEASURE", "CANARY-MAIL"],
      "items" => [
        %{
          "source" => "telemetry",
          "event_name" => @start,
          "measurements" => measurements,
          "metadata" => metadata
        }
      ]
    }

    assert {:ok, report} =
             PrivacyCorpus.run(corpus, environment: :production, telemetry_policy: policy)

    assert [%{"disposition" => "recorded", "retained_fields" => retained}] = report["items"]

    {recorder, collector} = start_pipeline(policy)
    :telemetry.execute(@start, measurements, metadata)
    assert {:ok, %{recorded: 1}} = TelemetryCollector.flush(collector)

    assert {:ok, _freeze_id} = Recorder.freeze(recorder, trigger())
    assert {:ok, snapshot} = Recorder.snapshot(recorder)
    assert [entry] = Enum.filter(snapshot.events, &(&1.event.source == "telemetry"))

    live_paths =
      entry.event
      |> Event.to_wire_map()
      |> Map.drop(@envelope)
      |> leaf_paths(nil)
      |> Enum.uniq()
      |> Enum.sort()

    assert retained == live_paths
    assert "causality.trace_id" in retained
    assert "attributes.metadata.scenario" in retained
    refute Enum.any?(retained, &String.contains?(&1, "secret"))
    refute Enum.any?(retained, &String.contains?(&1, "email"))
  end

  defp leaf_paths(value, prefix) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> leaf_paths(item, join(prefix, key)) end)

  defp leaf_paths(value, prefix) when is_list(value),
    do: Enum.flat_map(value, &leaf_paths(&1, prefix))

  defp leaf_paths(nil, _prefix), do: []
  defp leaf_paths(_value, prefix), do: [prefix]

  defp join(nil, key), do: key
  defp join(prefix, key), do: prefix <> "." <> key

  defp start_pipeline(policy) do
    handler_id = "privacy-corpus-live-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, redaction_policy} =
      RedactionPolicy.new(id: "live", maximum_sensitivity: :internal, rules: [])

    {:ok, recorder_pid} =
      Recorder.start_link(
        classification: {:internal, redaction_policy},
        max_events: 16,
        post_trigger_ms: 0
      )

    Process.unlink(recorder_pid)
    on_exit(fn -> if Process.alive?(recorder_pid), do: GenServer.stop(recorder_pid) end)
    {:ok, recorder} = Recorder.handle(recorder_pid)

    {:ok, collector} =
      TelemetryCollector.start_link(recorder, policy,
        authority: "live",
        boot_id: "boot-live",
        clock_id: "live",
        environment: :test,
        handler_id: handler_id,
        source_instance_id: "telemetry-live"
      )

    Process.unlink(collector)

    on_exit(fn ->
      if Process.alive?(collector), do: TelemetryCollector.stop(collector)
      :telemetry.detach(handler_id)
    end)

    {recorder, collector}
  end

  defp policy do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "privacy-corpus-live",
        events: [[name: @start, kind: "operation.start", lifecycle: "operation", phase: :start]],
        metadata: [scenario: "scenario"],
        measurements: [duration: "duration"],
        correlation: [logical_operation_id: :run_id, trace_id: :trace_id]
      )

    policy
  end

  defp trigger do
    Event.new!(
      id: "privacy-corpus-live-trigger",
      node: "node-live",
      boot_id: "boot-live",
      source: "fixture",
      kind: "invariant_failed",
      severity: :error,
      monotonic_time: 1,
      clock_id: "live",
      source_instance_id: "fixture-live",
      source_sequence: 1,
      wall_time: nil,
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{},
      payload: nil,
      authority: "live",
      redactions: [],
      extensions: %{}
    )
  end
end
