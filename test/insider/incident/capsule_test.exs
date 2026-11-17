defmodule Insider.Incident.CapsuleTest do
  use ExUnit.Case, async: true

  alias Insider.Detectors.RestartRecurrence
  alias Insider.Detectors.RestartRecurrence.Finding, as: LegacyRestartFinding
  alias Insider.Detectors.MailboxGrowth
  alias Insider.Collector.Poller
  alias Insider.Collector.Telemetry, as: TelemetryCollector
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Event
  alias Insider.Finding
  alias Insider.Incident.ArtifactReference
  alias Insider.Incident.Capsule
  alias Insider.Incident.ExportPolicy
  alias Insider.Incident.Source
  alias Insider.Protocol.Error
  alias Insider.Provenance
  alias Insider.Recorder
  alias Insider.Recorder.Classification
  alias Insider.Redaction.Policy

  defmodule MailboxProvider do
    @behaviour Poller.Provider

    @impl true
    def vm_sample, do: {:ok, :complete, %{"process_count" => 1}, []}

    @impl true
    def process_sample(agent) do
      {queue, reductions} =
        Agent.get_and_update(agent, fn
          [sample] -> {sample, [sample]}
          [sample | rest] -> {sample, rest}
        end)

      {:ok, :complete, %{"message_queue_len" => queue, "reductions_total" => reductions}, []}
    end
  end

  test "mailbox findings assemble and round trip with detector-dispatched correlation" do
    fixture = mailbox_fixture!()

    assert {:ok, capsule} = assemble(fixture)
    assert capsule.finding["detector"] == "mailbox_growth"
    assert capsule.finding["details"]["queue_growth"] == 2
    assert {:ok, canonical} = Capsule.canonical_binary(capsule)
    assert {:ok, ^capsule} = Capsule.decode(canonical)

    GenServer.stop(fixture.recorder)
  end

  test "frozen legacy restart capsule bytes and digest remain valid" do
    bytes =
      "test/fixtures/legacy_restart_capsule_v1.json"
      |> File.read!()
      |> String.trim_trailing("\n")

    assert {:ok, decoded} = Capsule.decode(bytes)
    refute Map.has_key?(decoded.finding, "details")
    assert decoded.finding["count"] == 3

    assert decoded.integrity["content_digest"] ==
             "f6bf9e1650b2e2a494e5a2b5eb2d56f827eda66a1a44d5e253c07e5379736d45"

    assert {:ok, ^bytes} = Capsule.canonical_binary(decoded)
  end

  test "legacy restart structs are decode-only and cannot assemble new capsules" do
    fixture = fixture!()
    details = fixture.finding.details

    legacy =
      struct!(LegacyRestartFinding,
        schema: fixture.finding.schema,
        detector: fixture.finding.detector,
        detector_version: fixture.finding.detector_version,
        fingerprint: fixture.finding.fingerprint,
        occurred_at_us: fixture.finding.occurred_at_us,
        count: details["count"],
        window_ms: details["window_ms"],
        identity: details["identity"],
        reason_fingerprints: details["reason_fingerprints"],
        confidence: fixture.finding.confidence,
        severity: fixture.finding.severity,
        trigger_event_id: fixture.finding.trigger_event_id,
        evidence_event_ids: fixture.finding.evidence_event_ids
      )

    assert {:error, %Error{code: :invalid_capsule}} = assemble(%{fixture | finding: legacy})
    GenServer.stop(fixture.recorder)
  end

  test "mailbox correlation rejects an intervening truncated Poller cycle" do
    fixture = mailbox_fixture!()

    gap_snapshot =
      inject_mailbox_gap(
        fixture.snapshot,
        fixture.finding,
        fixture.export_policy.redaction_policy
      )

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | snapshot: gap_snapshot})

    GenServer.stop(fixture.recorder)
  end

  test "assembles a redacted deterministic capsule that round trips offline" do
    fixture = fixture!()

    assert {:ok, capsule} = assemble(fixture)
    assert capsule.schema == "insider.incident-capsule/v1"
    assert capsule.id == "sha256:" <> capsule.integrity["content_digest"]
    assert capsule.provenance["fingerprint"] == fixture.provenance.fingerprint
    assert [%{"role" => "vm-crash-dump"}] = capsule.artifacts

    payloads = Enum.map(capsule.snapshot["events"], & &1["event"]["payload"])
    assert payloads == List.duplicate(%{"token" => "[REDACTED]"}, 3)

    assert Enum.map(capsule.redaction["manifest"], &{&1["path"], &1["count"]}) == [
             {["root:event:0", "key:payload", "key:token"], 1},
             {["root:event:1", "key:payload", "key:token"], 1},
             {["root:event:2", "key:payload", "key:token"], 1}
           ]

    assert {:ok, canonical} = Capsule.canonical_binary(capsule)
    assert {:ok, repeated} = assemble(fixture)
    assert Capsule.canonical_binary(repeated) == {:ok, canonical}

    GenServer.stop(fixture.recorder)
    assert {:ok, ^capsule} = Capsule.decode(canonical)
    assert {:ok, ^capsule} = canonical |> Jason.decode!() |> Capsule.decode_map()
  end

  test "a Telemetry event recorded with withheld fields still assembles and round trips" do
    # The control records nothing withheld; the other withholds an
    # unselected measurement and metadata keys. Collection-time omission
    # evidence must not turn into an export manifest the capsule refuses.
    for {measurements, metadata} <- [
          {%{duration: 1}, %{}},
          {%{duration: 1, queue_time: 2, unknown: 3}, %{unselected: true, other: "value"}}
        ] do
      fixture = fixture!(telemetry: {measurements, metadata})

      telemetry =
        Enum.find(fixture.snapshot.events, &(&1.event.source == "telemetry"))

      assert telemetry.event.redactions == []
      assert {:ok, capsule} = assemble(fixture)

      assert Enum.any?(capsule.snapshot["events"], &(&1["event"]["source"] == "telemetry"))
      assert {:ok, canonical} = Capsule.canonical_binary(capsule)
      GenServer.stop(fixture.recorder)
      assert {:ok, ^capsule} = Capsule.decode(canonical)
    end
  end

  test "rejects event, chain, content, and envelope corruption" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)

    event_tamper =
      put_in(capsule.snapshot["events"] |> hd(), ["event", "payload"], %{"token" => "changed"})

    events = [event_tamper | tl(capsule.snapshot["events"])]
    tampered = %{capsule | snapshot: Map.put(capsule.snapshot, "events", events)}
    assert {:error, %Error{code: code}} = Capsule.validate(tampered)
    assert code in [:invalid_capsule, :capsule_integrity_failed]

    chain_tamper =
      put_in(
        capsule.snapshot,
        ["events", Access.at(1), "chain_digest"],
        String.duplicate("0", 64)
      )

    assert_integrity_failure(Capsule.validate(%{capsule | snapshot: chain_tamper}))

    assert_integrity_failure(
      Capsule.validate(%{capsule | id: "sha256:" <> String.duplicate("f", 64)})
    )

    wire = Capsule.to_wire_map(capsule)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.decode_map(Map.put(wire, "inline_blob", "secret"))

    assert {:error, %Error{code: :unsupported_capsule_schema}} =
             Capsule.decode_map(Map.put(wire, "schema", "insider.incident-capsule/v99"))
  end

  test "canonical decoder rejects alternate JSON encodings and oversized input" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)
    wire = Capsule.to_wire_map(capsule)
    noncanonical = "\n" <> Jason.encode!(wire)
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.decode(noncanonical)

    assert {:error, %Error{code: :capsule_limit_exceeded}} =
             Capsule.decode(String.duplicate("x", 1_048_577))
  end

  test "rejects caller-asserted Event redaction manifests before export" do
    redaction = %{
      "action" => "mask",
      "count" => 1,
      "path" => ["key:payload"],
      "policy_id" => "caller-claim"
    }

    fixture = fixture!(event_redactions: [redaction])
    assert {:error, %Error{code: :invalid_capsule}} = assemble(fixture)
  end

  test "new assembly fails closed for missing hostile and mismatched recorder classifications" do
    fixture = fixture!()
    [first | rest] = fixture.snapshot.events

    missing = %{fixture.snapshot | events: [Map.delete(first, :classification) | rest]}
    assert {:error, %Error{code: :invalid_capsule}} = assemble(%{fixture | snapshot: missing})

    hostile_classification = %{first.classification | event_id: <<255>>}

    hostile = %{
      fixture.snapshot
      | events: [%{first | classification: hostile_classification} | rest]
    }

    assert {:error, %Error{code: :invalid_capsule}} = assemble(%{fixture | snapshot: hostile})

    second = Enum.at(fixture.snapshot.events, 1)

    moved = %{
      fixture.snapshot
      | events: [%{first | classification: second.classification} | rest]
    }

    assert {:error, %Error{code: :invalid_capsule}} = assemble(%{fixture | snapshot: moved})

    assert {:ok, mismatched_classification} =
             Classification.new(first.event, :secret, fixture.export_policy.redaction_policy)

    mismatched_events = [%{first | classification: mismatched_classification} | rest]

    mismatched = classified_snapshot(fixture.snapshot, mismatched_events)

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | snapshot: mismatched})

    assert {:ok, mixed} =
             Classification.new(
               second.event,
               :confidential,
               fixture.export_policy.redaction_policy
             )

    mixed_events = [first, %{second | classification: mixed} | tl(rest)]
    mixed_snapshot = classified_snapshot(fixture.snapshot, mixed_events)

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | snapshot: mixed_snapshot})

    assert {:ok, other_policy} =
             Policy.new(id: "other-capsule-policy", maximum_sensitivity: :internal, rules: [])

    assert {:ok, other_policy_classification} =
             Classification.new(first.event, :internal, other_policy)

    other_policy_events = [%{first | classification: other_policy_classification} | rest]
    other_policy_snapshot = classified_snapshot(fixture.snapshot, other_policy_events)

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | snapshot: other_policy_snapshot})
  end

  test "capsule export consumes and strips the trusted recorder companion" do
    fixture = fixture!()

    assert Enum.all?(fixture.snapshot.events, &Map.has_key?(&1, :classification))
    assert fixture.snapshot.classification_bytes > 0
    assert {:ok, capsule} = assemble(fixture)

    assert capsule.redaction["root_sensitivities"]["event"] == "internal"

    refute Enum.any?(capsule.snapshot["events"], fn entry ->
             Map.has_key?(entry, "classification") or
               Map.has_key?(entry["event"], "event_digest")
           end)

    assert {:ok, canonical} = Capsule.canonical_binary(capsule)
    refute canonical =~ "insider.recorder-classification"
    refute canonical =~ "event_digest"
  end

  test "required roots fail closed when policy classification would remove them" do
    fixture = fixture!(finding_sensitivity: :secret)
    assert {:error, %Error{code: :invalid_capsule}} = assemble(fixture)
  end

  test "artifacts are digest-only, sorted as a set, and duplicate references fail" do
    fixture = fixture!()
    second = artifact!("compiler-trace", "c")

    assert {:ok, capsule} =
             assemble(%{fixture | artifacts: [fixture.artifact, second]})

    assert Enum.map(capsule.artifacts, & &1["role"]) == ["compiler-trace", "vm-crash-dump"]

    assert Enum.all?(
             capsule.artifacts,
             &(Map.keys(&1) -- ["byte_size", "media_type", "role", "sha256"] == [])
           )

    assert {:ok, reordered} =
             assemble(%{fixture | artifacts: [second, fixture.artifact]})

    assert reordered == capsule

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | artifacts: [fixture.artifact, fixture.artifact]})
  end

  test "capsule event cardinality is hard bounded without silent truncation" do
    within = fixture!(event_count: 64)
    assert {:ok, capsule} = assemble(within)

    assert Enum.map(capsule.snapshot["events"], & &1["event"]["id"]) ==
             Enum.map(1..64, &"event-#{&1}")

    over = fixture!(event_count: 65)
    assert {:error, %Error{code: :invalid_capsule}} = assemble(over)
  end

  test "malformed public inputs return bounded typed failures" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)

    assert {:error, %Error{code: :invalid_capsule}} = Capsule.decode(:not_bytes)
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.decode("{")
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.decode_map([])
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.validate(%{})
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.canonical_binary(%{})

    hidden = Map.put(capsule, :hidden, true)
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.validate(hidden)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(fixture.snapshot, fixture.finding, fixture.provenance, :invalid)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(fixture.snapshot, fixture.finding, fixture.provenance,
               export_policy: fixture.export_policy,
               authority: [],
               artifacts: [],
               unknown: true
             )

    forged_policy = %{fixture.export_policy | fingerprint: String.duplicate("0", 64)}

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(fixture, export_policy: forged_policy)
  end

  test "source normalization rejects wrong component shapes without traversal failures" do
    fixture = fixture!()

    base_options = [
      export_policy: fixture.export_policy,
      authority: [capture_audit_id: "capture-1", export_audit_id: "export-1"],
      artifacts: fixture.artifacts
    ]

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(
               :invalid_snapshot,
               fixture.finding,
               fixture.provenance,
               base_options
             )

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(
               fixture.snapshot,
               :invalid_finding,
               fixture.provenance,
               base_options
             )

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(
               fixture.snapshot,
               fixture.finding,
               fixture.provenance,
               Keyword.put(base_options, :authority, :invalid)
             )

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(
               %{fixture.snapshot | counters: :invalid},
               fixture.finding,
               fixture.provenance,
               base_options
             )

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.assemble(
               %{fixture.snapshot | events: [:invalid_entry]},
               fixture.finding,
               fixture.provenance,
               base_options
             )

    refute Source.valid_finding?([])
    refute Source.valid_snapshot?([])
    refute Source.valid_authority?([])
    refute Source.valid_artifacts?(:invalid)
    assert Source.correlate(%{}, %{}) == {:error, :uncorrelated_evidence}

    GenServer.stop(fixture.recorder)
  end

  test "semantic lies and well-shaped digest changes are rejected" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)

    bad_finding = update_in(capsule.finding, ["details", "count"], &(&1 + 1))

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | finding: bad_finding})

    reversed_events = Enum.reverse(capsule.snapshot["events"])
    reversed_snapshot = Map.put(capsule.snapshot, "events", reversed_events)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | snapshot: reversed_snapshot})

    integrity = Map.put(capsule.integrity, "algorithm", "sha512")
    assert_integrity_failure(Capsule.validate(%{capsule | integrity: integrity}))

    consumption = Map.put(capsule.redaction["consumption"], "manifest_records", 99)
    redaction = Map.put(capsule.redaction, "consumption", consumption)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: redaction})

    [first, second, trigger] = capsule.finding["evidence_event_ids"]

    permuted_finding =
      Map.put(capsule.finding, "evidence_event_ids", [second, first, trigger])

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | finding: permuted_finding})

    false_identity =
      Map.put(capsule.finding["details"]["identity"], "offender_id", "invented-worker")

    false_finding =
      capsule.finding
      |> put_in(["details", "identity"], false_identity)
      |> Map.put("fingerprint", finding_fingerprint(false_identity))

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | finding: false_finding})

    false_time = Map.update!(capsule.finding, "occurred_at_us", &(&1 + 20_000))

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | finding: false_time})

    [manifest | rest] = capsule.redaction["manifest"]
    impossible = Map.put(manifest, "path", ["root:event:999", "key:payload"])
    bad_redaction = Map.put(capsule.redaction, "manifest", [impossible | rest])

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: bad_redaction})

    nonterminal_wildcard =
      Map.put(manifest, "path", ["root:event:0", "each:*", "key:token"])

    wildcard_redaction = Map.put(capsule.redaction, "manifest", [nonterminal_wildcard | rest])

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: wildcard_redaction})

    duplicate = Map.update!(manifest, "count", &(&1 + 1))

    duplicate_manifest =
      Enum.sort_by([manifest, duplicate | rest], &Insider.Event.Canonical.encode/1)

    duplicate_consumption =
      Map.put(
        capsule.redaction["consumption"],
        "manifest_records",
        length(duplicate_manifest)
      )

    duplicate_redaction =
      capsule.redaction
      |> Map.put("manifest", duplicate_manifest)
      |> Map.put("consumption", duplicate_consumption)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: duplicate_redaction})

    unsupported_provenance = Map.put(capsule.provenance, "schema", "insider.provenance/v99")

    assert {:error, %Error{code: :unsupported_provenance_schema}} =
             Capsule.validate(%{capsule | provenance: unsupported_provenance})

    invalid_wire =
      capsule
      |> Capsule.to_wire_map()
      |> put_in(["finding", "details", "count"], 99)

    invalid_binary = Insider.Event.Canonical.encode(invalid_wire)
    assert {:error, %Error{code: :invalid_capsule}} = Capsule.decode(invalid_binary)
  end

  test "findings retain strict ordered evidence and a distinct trigger" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)

    events =
      Enum.map(capsule.snapshot["events"], &Map.drop(&1, ["classification", "chain_digest"]))

    snapshot =
      capsule.snapshot
      |> Map.put("events", events)
      |> Map.put("retained_bytes", Source.event_bytes(events))

    trigger_id = capsule.finding["trigger_event_id"]

    precursor_ids =
      snapshot["events"]
      |> Enum.reject(&(&1["event"]["id"] == trigger_id))
      |> Enum.take(2)
      |> Enum.map(& &1["event"]["id"])

    assert [_, _] = precursor_ids

    assert :ok = Source.correlate(capsule.finding, snapshot)

    duplicate =
      Map.put(
        capsule.finding,
        "evidence_event_ids",
        [hd(precursor_ids) | precursor_ids] ++ [trigger_id]
      )

    reordered =
      Map.put(
        capsule.finding,
        "evidence_event_ids",
        Enum.reverse(capsule.finding["evidence_event_ids"])
      )

    missing =
      Map.put(
        capsule.finding,
        "evidence_event_ids",
        precursor_ids ++ ["missing-event", trigger_id]
      )

    for invalid <- [duplicate, reordered, missing] do
      assert {:error, :uncorrelated_evidence} = Source.correlate(invalid, snapshot)
    end

    GenServer.stop(fixture.recorder)
  end

  test "semantic invariant evidence binds one exact completed violation event" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)
    identity = semantic_identity()

    trigger =
      Enum.find(
        capsule.snapshot["events"],
        &(&1["receipt"] == capsule.snapshot["opening_receipt"])
      )

    event = semantic_invariant_event("semantic-invariant-1", trigger["received_at_us"], identity)

    finding =
      Finding.new!(
        detector: "semantic_invariant",
        detector_version: "1",
        occurred_at_us: trigger["received_at_us"],
        confidence: "high",
        severity: "error",
        trigger_event_id: event.id,
        evidence_event_ids: [event.id],
        details: %{"identity" => identity}
      )

    events =
      Enum.map(capsule.snapshot["events"], fn entry ->
        entry = Map.take(entry, ["receipt", "received_at_us", "priority", "event"])

        if entry["receipt"] == trigger["receipt"],
          do: %{entry | "event" => Event.to_wire_map(event)},
          else: entry
      end)

    snapshot =
      capsule.snapshot
      |> Map.put("events", events)
      |> Map.put("retained_bytes", Source.event_bytes(events))
      |> Map.put("trigger_event_id", event.id)

    finding_wire = Finding.to_wire_map(finding)
    assert Source.valid_finding?(finding_wire)
    assert Source.valid_snapshot?(snapshot)
    assert :ok = Source.correlate(finding_wire, snapshot)

    invalid =
      put_in(
        events,
        [
          Access.at(Enum.find_index(events, &(&1["receipt"] == trigger["receipt"]))),
          "event",
          "attributes",
          "disclosure"
        ],
        "blocked"
      )

    invalid_snapshot = %{
      snapshot
      | "events" => invalid,
        "retained_bytes" => Source.event_bytes(invalid)
    }

    assert Source.valid_snapshot?(invalid_snapshot)

    assert {:error, :uncorrelated_evidence} =
             Source.correlate(finding_wire, invalid_snapshot)

    GenServer.stop(fixture.recorder)
  end

  test "restart findings must remain inside the detector domain" do
    fixture = fixture!()

    one_event = %{
      fixture.finding
      | details: Map.put(fixture.finding.details, "count", 1),
        evidence_event_ids: [fixture.finding.trigger_event_id]
    }

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | finding: one_event})

    impossible_window = %{
      fixture.finding
      | details: Map.put(fixture.finding.details, "window_ms", 60_001)
    }

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | finding: impossible_window})

    invalid_pid_entries =
      fixture.snapshot.events
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} ->
        attributes = Map.put(entry.event.attributes, "offender_pid", "worker-pid-#{index}")
        event = %{entry.event | attributes: attributes}
        reclassified_entry(entry, event, fixture.export_policy.redaction_policy)
      end)

    invalid_pid_snapshot = classified_snapshot(fixture.snapshot, invalid_pid_entries)

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | snapshot: invalid_pid_snapshot})
  end

  test "direct hostile event lists are cardinality-checked before entry traversal" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)
    huge_snapshot = Map.put(capsule.snapshot, "events", List.duplicate(%{}, 100_000))

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | snapshot: huge_snapshot})
  end

  test "direct validation rejects hostile bignum counters before integrity hashing" do
    fixture = fixture!()
    assert {:ok, capsule} = assemble(fixture)
    hostile_integer = :erlang.bsl(1, 1_000_000)

    consumption = Map.put(capsule.redaction["consumption"], "input_bytes", hostile_integer)
    redaction = Map.put(capsule.redaction, "consumption", consumption)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: redaction})

    [first | rest] = capsule.redaction["manifest"]
    manifest = [Map.put(first, "count", hostile_integer) | rest]
    redaction = Map.put(capsule.redaction, "manifest", manifest)

    assert {:error, %Error{code: :invalid_capsule}} =
             Capsule.validate(%{capsule | redaction: redaction})
  end

  test "an already-expired outer deadline deterministically stops normalization" do
    fixture = fixture!()
    expired = System.monotonic_time(:microsecond) - 1

    assert {:error, %Error{code: :deadline_exceeded}} =
             assemble(fixture, deadline_monotonic_us: expired)
  end

  test "artifact reference count rejects one over the hard limit" do
    fixture = fixture!()
    artifacts = Enum.map(1..33, &artifact!("artifact-#{&1}", digest_character(&1)))
    assert {:error, %Error{code: :invalid_capsule}} = assemble(%{fixture | artifacts: artifacts})
  end

  test "redacted provenance must bind the active export policy" do
    fixture = fixture!()

    {:ok, mismatched} =
      Provenance.new(
        code: {:available, %{"commit" => "abc123"}},
        configuration: {:redacted, String.duplicate("f", 64)},
        dependencies: {:available, %{"lock" => "def456"}},
        runtime: {:available, %{"otp" => "29"}},
        target: {:available, %{"class" => "test"}}
      )

    assert {:error, %Error{code: :invalid_capsule}} =
             assemble(%{fixture | provenance: mismatched})
  end

  defp fixture!(options \\ []) do
    policy = redaction_policy!()
    event_redactions = Keyword.get(options, :event_redactions, [])
    event_count = Keyword.get(options, :event_count, 3)
    payload_size = Keyword.get(options, :payload_size, 13)
    events = Enum.map(1..event_count, &event(&1, event_redactions, payload_size))
    {:ok, detector} = RestartRecurrence.new(threshold: 3, window_ms: 10)

    {detector, []} = RestartRecurrence.observe(detector, Enum.at(events, 0), 1_000)
    {detector, []} = RestartRecurrence.observe(detector, Enum.at(events, 1), 2_000)

    {_detector, [{:incident, finding}]} =
      RestartRecurrence.observe(detector, Enum.at(events, 2), 3_000)

    clock = fn -> 3_000 end

    {:ok, recorder} =
      Recorder.start_link(
        classification: {:internal, policy},
        clock: clock,
        post_trigger_ms: 0
      )

    {:ok, handle} = Recorder.handle(recorder)
    Enum.each(events, &assert(:ok = Recorder.record(handle, &1)))
    record_telemetry(handle, Keyword.get(options, :telemetry))
    assert {:ok, _freeze_id} = Recorder.freeze(handle, Enum.at(events, 2))
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"commit" => "abc123"}},
        configuration: {:redacted, policy.fingerprint},
        dependencies: {:available, %{"lock" => "def456"}},
        runtime: {:available, %{"otp" => "29"}},
        target: {:available, %{"class" => "test"}}
      )

    sensitivities = [
      finding: Keyword.get(options, :finding_sensitivity, :internal),
      snapshot: :internal,
      event: :internal,
      provenance: :internal,
      authority: :internal,
      artifacts: :internal
    ]

    {:ok, export_policy} =
      ExportPolicy.new(policy, sensitivities,
        max_duration_ms: Keyword.get(options, :export_duration_ms, 10_000)
      )

    %{
      recorder: recorder,
      snapshot: snapshot,
      finding: finding,
      provenance: provenance,
      export_policy: export_policy,
      artifact: artifact!("vm-crash-dump", "a"),
      artifacts: [artifact!("vm-crash-dump", "a")]
    }
  end

  # Records one event through the real Telemetry collector, whose policy
  # selects only `duration`; `queue_time` is nameable, `unknown` is not.
  defp record_telemetry(_handle, nil), do: :ok

  defp record_telemetry(handle, {measurements, metadata}) do
    name = [:insider_capsule_test, :operation, :done]
    handler_id = "insider-capsule-telemetry-#{System.unique_integer([:positive])}"

    {:ok, policy} =
      TelemetryPolicy.new(
        id: "capsule-telemetry",
        events: [[name: name, kind: "capsule.operation.done", lifecycle: "op", phase: :event]],
        measurements: [duration: "duration"]
      )

    {:ok, collector} =
      TelemetryCollector.start_link(handle, policy,
        authority: "test-policy",
        boot_id: "boot-a",
        clock_id: "telemetry-order",
        environment: :test,
        handler_id: handler_id,
        nameable_measurements: [:duration, :queue_time]
      )

    :telemetry.execute(name, measurements, metadata)
    assert {:ok, %{recorded: 1, invalid: 0}} = TelemetryCollector.flush(collector)
    assert {:ok, _cleanup} = TelemetryCollector.stop(collector)
  end

  defp mailbox_fixture! do
    policy = redaction_policy!()
    {:ok, samples} = Agent.start_link(fn -> [{10, 100}, {11, 100}, {12, 100}] end)

    {:ok, recorder} =
      Recorder.start_link(
        classification: {:internal, policy},
        max_events: 64,
        post_trigger_ms: 0
      )

    {:ok, handle} = Recorder.handle(recorder)

    {:ok, poller} =
      Poller.start_link(handle,
        authority: "test-policy",
        boot_id: "boot-a",
        clock_id: "monotonic-us",
        initial_delay_ms: 0,
        interval_ms: 10,
        source_instance_id: "poller-a",
        targets: [samples],
        provider: MailboxProvider,
        probe_timeout_ms: 100,
        cleanup_timeout_ms: 10,
        cycle_timeout_ms: 110
      )

    assert_eventually(fn ->
      match?({:ok, %{cycles_completed: completed}} when completed >= 3, Poller.status(poller))
    end)

    GenServer.stop(poller)

    freeze_trigger = %{
      mailbox_event(999, 0)
      | source: "agent",
        kind: "invariant_failed",
        subject: nil
    }

    assert {:ok, _freeze_id} = Recorder.freeze(handle, freeze_trigger)
    assert {:ok, snapshot} = Recorder.snapshot(handle)

    process_entries =
      snapshot.events
      |> Enum.filter(&(&1.event.source == "poller" and &1.event.kind == "process_sample"))
      |> Enum.sort_by(& &1.receipt)

    {:ok, detector} = MailboxGrowth.new(sample_count: 3, window_ms: 1_000)

    {_detector, [{:finding, finding}]} =
      Enum.reduce(process_entries, {detector, []}, fn entry, {detector, outputs} ->
        {detector, emitted} = MailboxGrowth.observe(detector, entry.event, entry.received_at)
        {detector, outputs ++ emitted}
      end)

    finding_entry = Enum.find(snapshot.events, &(&1.event.id == finding.trigger_event_id))

    snapshot = %{
      snapshot
      | trigger_event_id: finding.trigger_event_id,
        opening_receipt: finding_entry.receipt
    }

    assert Enum.map(process_entries, & &1.event.source_sequence) |> Enum.take(3) == [2, 4, 6]
    Agent.stop(samples)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"commit" => "abc123"}},
        configuration: {:redacted, policy.fingerprint},
        dependencies: {:available, %{"lock" => "def456"}},
        runtime: {:available, %{"otp" => "29"}},
        target: {:available, %{"class" => "test"}}
      )

    {:ok, export_policy} =
      ExportPolicy.new(policy,
        finding: :internal,
        snapshot: :internal,
        event: :internal,
        provenance: :internal,
        authority: :internal,
        artifacts: :internal
      )

    %{
      recorder: recorder,
      snapshot: snapshot,
      finding: finding,
      provenance: provenance,
      export_policy: export_policy,
      artifacts: [artifact!("vm-crash-dump", "a")]
    }
  end

  defp inject_mailbox_gap(snapshot, finding, policy) do
    [first_id, _middle_id, last_id] = finding.evidence_event_ids
    first_receipt = Enum.find(snapshot.events, &(&1.event.id == first_id)).receipt
    last_receipt = Enum.find(snapshot.events, &(&1.event.id == last_id)).receipt

    events =
      Enum.map(snapshot.events, fn entry ->
        if entry.receipt in first_receipt..last_receipt and entry.event.kind == "vm_sample" do
          attributes = %{
            "cleanup" => "not_started",
            "cycle_id" => "2",
            "field_set" => "poll_cycle/v1",
            "metrics" => %{"skipped_probes" => 1},
            "observer_effect" => "none",
            "probe_status" => "truncated",
            "provider" => "Elixir.Insider.Collector.Poller.Erlang",
            "sample_duration_us" => 0,
            "timeout_cancellation" => "not_applicable",
            "unavailable" => ["cycle_deadline"]
          }

          event = %{entry.event | kind: "poll_cycle", attributes: attributes}
          reclassified_entry(entry, event, policy)
        else
          entry
        end
      end)

    classified_snapshot(snapshot, events)
  end

  defp retained_event_bytes(entries) do
    Enum.reduce(entries, 0, fn entry, total ->
      {:ok, bytes} = Event.canonical_binary(entry.event)
      total + byte_size(bytes)
    end)
  end

  defp classified_snapshot(snapshot, events) do
    classification_bytes =
      Enum.reduce(events, 0, fn entry, total ->
        {:ok, bytes} = Classification.canonical_binary(entry.classification, entry.event)
        total + byte_size(bytes)
      end)

    %{
      snapshot
      | events: events,
        retained_bytes: retained_event_bytes(events),
        classification_bytes: classification_bytes
    }
  end

  defp reclassified_entry(entry, event, policy) do
    {:ok, classification} = Classification.new(event, entry.classification.sensitivity, policy)
    %{entry | event: event, classification: classification}
  end

  defp assert_eventually(assertion, attempts \\ 1_000)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      receive after: (1 -> assert_eventually(assertion, attempts - 1))
    end
  end

  defp assemble(fixture, overrides \\ []) do
    options =
      [
        export_policy: fixture.export_policy,
        authority: [capture_audit_id: "capture-1", export_audit_id: "export-1"],
        artifacts: fixture.artifacts
      ]
      |> Keyword.merge(overrides)

    Capsule.assemble(fixture.snapshot, fixture.finding, fixture.provenance, options)
  end

  defp redaction_policy! do
    assert {:ok, policy} =
             Policy.new(
               id: "capsule-policy",
               maximum_sensitivity: :internal,
               rules: [
                 [
                   id: "event-token",
                   path: ["payload", "token"],
                   sensitivity: :secret,
                   action: :mask
                 ]
               ],
               max_nodes: 16_384,
               max_input_bytes: 1_048_576,
               max_output_bytes: 1_048_576,
               max_duration_ms: 10_000
             )

    policy
  end

  defp artifact!(role, digest_character) do
    assert {:ok, artifact} =
             ArtifactReference.new(
               role: role,
               media_type: "application/octet-stream",
               byte_size: 4_096,
               sha256: String.duplicate(digest_character, 64)
             )

    artifact
  end

  defp semantic_identity do
    %{
      "contract_fingerprint" => "sha256:" <> String.duplicate("c", 64),
      "contract_id" => "checkout",
      "contract_version" => 1,
      "invariant" => "total_matches_items"
    }
  end

  defp semantic_invariant_event(id, monotonic_time, identity) do
    Event.new!(
      id: id,
      node: "node-a",
      boot_id: "boot-a",
      source: "contract",
      kind: "invariant_failed",
      severity: :error,
      monotonic_time: monotonic_time,
      clock_id: "contract-clock",
      source_instance_id: "contract-a",
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
      attributes: %{
        "semantic_projection" => "application_invariant/v1",
        "contract_id" => identity["contract_id"],
        "contract_version" => identity["contract_version"],
        "contract_fingerprint" => identity["contract_fingerprint"],
        "invariant" => identity["invariant"],
        "invocation_status" => "violation",
        "invocation_reason" => "invariant_violated",
        "cleanup" => "complete",
        "verdict" => "violation",
        "execution" => "complete",
        "disclosure" => "clear"
      },
      payload: false,
      authority: "test-policy",
      redactions: [],
      extensions: %{}
    )
  end

  defp event(sequence, redactions, payload_size) do
    Event.new!(
      id: "event-#{sequence}",
      node: "node-a",
      boot_id: "boot-a",
      source: "logger",
      kind: "supervisor_child_terminated",
      severity: :error,
      monotonic_time: sequence,
      clock_id: "logger-sequence",
      source_instance_id: "logger-a",
      source_sequence: sequence,
      wall_time: nil,
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{
        "domain" => ["otp", "sasl"],
        "label" => "supervisor.child_terminated",
        "message_type" => "report",
        "semantic_projection" => "otp_supervisor/v1",
        "supervisor" => "supervisor-a",
        "termination_context" => "child_terminated",
        "offender_id" => "worker-a",
        "offender_pid" => "<0.#{sequence}.0>",
        "restart_type" => "permanent",
        "reason_class" => "abnormal",
        "reason_fingerprint" => String.duplicate("d", 64)
      },
      payload: %{"token" => String.duplicate("s", payload_size)},
      authority: "test-policy",
      redactions: redactions,
      extensions: %{}
    )
  end

  defp mailbox_event(sequence, queue) do
    Event.new!(
      id: "mailbox-#{sequence}",
      node: "node-a",
      boot_id: "boot-a",
      source: "poller",
      kind: "process_sample",
      severity: :debug,
      monotonic_time: sequence,
      clock_id: "monotonic-us",
      source_instance_id: "poller-a",
      source_sequence: sequence,
      wall_time: nil,
      subject: Insider.Identity.Subject.new!("process", "<0.10.0>", "node-a"),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{
        "cleanup" => "observed",
        "cycle_id" => Integer.to_string(sequence, 36),
        "field_set" => "otp_process_scalar/v1",
        "metrics" => %{"message_queue_len" => queue, "reductions_total" => 100},
        "observer_effect" => "synchronous_runtime_inspection",
        "probe_status" => "complete",
        "provider" => "Elixir.Insider.Collector.Poller.Erlang",
        "sample_duration_us" => 1,
        "timeout_cancellation" => "not_applicable",
        "unavailable" => []
      },
      payload: nil,
      authority: "test-policy",
      redactions: [],
      extensions: %{}
    )
  end

  defp assert_integrity_failure(result),
    do: assert({:error, %Error{code: :capsule_integrity_failed}} = result)

  defp finding_fingerprint(identity) do
    %{"detector" => "restart_recurrence", "version" => "1", "identity" => identity}
    |> Insider.Event.Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest_character(index),
    do: index |> rem(16) |> Integer.to_string(16) |> String.downcase()
end
