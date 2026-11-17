defmodule Insider.Incident.Source do
  @moduledoc false

  alias Insider.Detectors.Input
  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Finding
  alias Insider.Incident.ArtifactReference
  alias Insider.Provenance
  alias Insider.Recorder.Classification
  alias Insider.Recorder.Snapshot

  @minimum_integer -9_223_372_036_854_775_808
  @maximum_integer 9_223_372_036_854_775_807
  @maximum_events 64
  @maximum_artifacts 32
  @counter_names [
    :offered,
    :accepted,
    :evicted,
    :duplicate,
    :freeze_idempotent,
    :already_frozen,
    :recovered_owner_death,
    :invalid_event,
    :classification_failed,
    :contended,
    :rate_limited,
    :rate_key_capacity,
    :oversized,
    :frozen,
    :event_id_conflict,
    :priority_protected,
    :eviction_limit,
    :unavailable,
    :internal_error
  ]
  @legacy_counter_names @counter_names -- [:classification_failed]
  @gap_names [
    :prehistory_unavailable,
    :evicted_evidence,
    :recovered_after_owner_death,
    :dropped_evidence
  ]

  @legacy_restart_finding_keys [
    "confidence",
    "count",
    "detector",
    "detector_version",
    "evidence_event_ids",
    "fingerprint",
    "identity",
    "occurred_at_us",
    "reason_fingerprints",
    "schema",
    "severity",
    "trigger_event_id",
    "window_ms"
  ]
  @snapshot_keys [
    "closing_receipt",
    "completeness",
    "counters",
    "events",
    "freeze_id",
    "freeze_status",
    "gaps",
    "instance_id",
    "opening_receipt",
    "recorder_started_at_us",
    "retained_bytes",
    "retained_count",
    "trigger_event_id"
  ]
  @entry_keys ["event", "priority", "receipt", "received_at_us"]
  @classified_entry_keys ["classification" | @entry_keys]

  @spec normalize(Snapshot.t(), term(), Provenance.t(), term(), term(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def normalize(snapshot, finding, provenance, authority, artifacts, deadline) do
    with :ok <- before_deadline(deadline),
         {:ok, finding_wire} <- finding_to_wire(finding),
         :ok <- before_deadline(deadline),
         {:ok, snapshot_wire} <- snapshot_to_wire(snapshot, deadline),
         :ok <- before_deadline(deadline),
         {:ok, valid_provenance} <- Provenance.validate(provenance),
         :ok <- before_deadline(deadline),
         {:ok, authority_wire} <- authority_to_wire(authority),
         :ok <- before_deadline(deadline),
         {:ok, artifact_wires} <- artifacts_to_wire(artifacts, deadline),
         :ok <- correlate(finding_wire, snapshot_wire) do
      {:ok,
       %{
         finding: finding_wire,
         snapshot: snapshot_wire,
         provenance: Provenance.to_wire_map(valid_provenance),
         authority: authority_wire,
         artifacts: artifact_wires
       }}
    else
      {:error, _reason} = failure -> failure
      _other -> {:error, :invalid_source}
    end
  rescue
    _error -> {:error, :invalid_source}
  catch
    _kind, _reason -> {:error, :invalid_source}
  end

  @spec valid_finding?(term()) :: boolean()
  def valid_finding?(finding) when is_map(finding) and not is_struct(finding) do
    Finding.valid_wire?(finding) or valid_legacy_restart_finding?(finding)
  rescue
    _error -> false
  end

  def valid_finding?(_finding), do: false

  defp valid_legacy_restart_finding?(finding) do
    exact_keys?(finding, @legacy_restart_finding_keys) and
      finding["schema"] == "insider.finding/v1" and
      finding["detector"] == "restart_recurrence" and finding["detector_version"] == "1" and
      finding["confidence"] in ["medium"] and finding["severity"] in ["error"] and
      finding["count"] in 2..32 and finding["window_ms"] in 1..60_000 and
      signed_integer?(finding["occurred_at_us"]) and
      Input.bounded_id?(finding["trigger_event_id"]) and
      valid_identity?(finding["identity"]) and Input.digest?(finding["fingerprint"]) and
      valid_digest_list?(finding["reason_fingerprints"], 32) and
      valid_id_list?(finding["evidence_event_ids"], 32) and
      finding["count"] == length(finding["evidence_event_ids"]) and
      List.last(finding["evidence_event_ids"]) == finding["trigger_event_id"] and
      finding["fingerprint"] == legacy_restart_fingerprint(finding)
  end

  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    exact_keys?(snapshot, @snapshot_keys) and Input.bounded_id?(snapshot["instance_id"]) and
      signed_integer?(snapshot["recorder_started_at_us"]) and
      Input.bounded_id?(snapshot["freeze_id"]) and
      Input.bounded_id?(snapshot["trigger_event_id"]) and
      positive_integer?(snapshot["opening_receipt"]) and
      positive_integer?(snapshot["closing_receipt"]) and
      snapshot["closing_receipt"] >= snapshot["opening_receipt"] and
      snapshot["freeze_status"] == "complete" and
      snapshot["completeness"] in ["complete", "incomplete"] and valid_gaps?(snapshot["gaps"]) and
      valid_counters?(snapshot["counters"]) and non_negative_integer?(snapshot["retained_count"]) and
      non_negative_integer?(snapshot["retained_bytes"]) and valid_entries?(snapshot["events"]) and
      snapshot["retained_count"] == length(snapshot["events"]) and
      snapshot["retained_bytes"] == event_bytes(snapshot["events"]) and
      coherent_completeness?(snapshot) and coherent_receipts?(snapshot)
  rescue
    _error -> false
  end

  def valid_snapshot?(_snapshot), do: false

  @spec valid_authority?(term()) :: boolean()
  def valid_authority?(
        %{
          "capture_audit_id" => capture_id,
          "export_audit_id" => export_id
        } = authority
      )
      when map_size(authority) == 2,
      do: Input.bounded_id?(capture_id) and Input.bounded_id?(export_id)

  def valid_authority?(_authority), do: false

  @spec valid_artifacts?(term()) :: boolean()
  def valid_artifacts?(artifacts) when is_list(artifacts) do
    bounded_list?(artifacts, @maximum_artifacts) and
      Enum.all?(artifacts, &match?({:ok, _reference}, ArtifactReference.decode_map(&1))) and
      artifacts == Enum.sort_by(artifacts, &{&1["role"], &1["sha256"]}) and
      Enum.uniq_by(artifacts, &{&1["role"], &1["sha256"]}) == artifacts
  rescue
    _error -> false
  end

  def valid_artifacts?(_artifacts), do: false

  @spec correlate(map(), map()) :: :ok | {:error, atom()}
  def correlate(finding, snapshot) do
    with true <- valid_finding?(finding),
         true <- valid_snapshot?(snapshot),
         {:ok, evidence, trigger} <- correlated_entries(finding, snapshot),
         true <- detector_correlated?(finding, evidence, trigger, snapshot) do
      :ok
    else
      _other -> {:error, :uncorrelated_evidence}
    end
  rescue
    _error -> {:error, :uncorrelated_evidence}
  end

  defp correlated_entries(finding, snapshot) do
    event_ids = MapSet.new(snapshot["events"], & &1["event"]["id"])
    trigger = Enum.find(snapshot["events"], &(&1["receipt"] == snapshot["opening_receipt"]))
    evidence_ids = finding["evidence_event_ids"]
    evidence_set = MapSet.new(evidence_ids)
    evidence = Enum.filter(snapshot["events"], &MapSet.member?(evidence_set, &1["event"]["id"]))

    valid =
      snapshot["trigger_event_id"] == finding["trigger_event_id"] and trigger != nil and
        trigger["event"]["id"] == snapshot["trigger_event_id"] and
        trigger["received_at_us"] == finding["occurred_at_us"] and
        Enum.all?(evidence_ids, &MapSet.member?(event_ids, &1)) and
        Enum.map(evidence, & &1["event"]["id"]) == evidence_ids

    if valid, do: {:ok, evidence, trigger}, else: {:error, :uncorrelated_evidence}
  end

  defp detector_correlated?(
         %{"detector" => "restart_recurrence", "detector_version" => "1", "details" => details} =
           finding,
         evidence,
         trigger,
         _snapshot
       ),
       do: restart_correlated?(finding, details, evidence, trigger)

  defp detector_correlated?(
         %{"detector" => "restart_recurrence", "detector_version" => "1"} = finding,
         evidence,
         trigger,
         _snapshot
       ),
       do: restart_correlated?(finding, finding, evidence, trigger)

  defp detector_correlated?(
         %{"detector" => "mailbox_growth", "detector_version" => "1", "details" => details} =
           finding,
         evidence,
         trigger,
         snapshot
       ),
       do: mailbox_correlated?(finding, details, evidence, trigger, snapshot)

  defp detector_correlated?(
         %{"detector" => "semantic_invariant", "detector_version" => "1", "details" => details},
         evidence,
         trigger,
         _snapshot
       ),
       do: semantic_invariant_correlated?(details, evidence, trigger)

  defp detector_correlated?(_finding, _evidence, _trigger, _snapshot), do: false

  defp restart_correlated?(finding, details, evidence, trigger) do
    occurred_at = finding["occurred_at_us"]
    window_start = occurred_at - details["window_ms"] * 1_000

    Enum.all?(evidence, &semantic_restart_event?(&1, details["identity"])) and
      distinct_offender_pids?(evidence) and
      matching_reason_fingerprints?(evidence, details["reason_fingerprints"]) and
      Enum.all?(evidence, &(&1["received_at_us"] in window_start..occurred_at)) and
      trigger == List.last(evidence)
  end

  defp semantic_restart_event?(entry, identity) do
    event = entry["event"]
    attributes = event["attributes"]

    event["source"] == "logger" and event["kind"] == "supervisor_child_terminated" and
      event["node"] == identity["node"] and event["boot_id"] == identity["boot_id"] and
      attributes["semantic_projection"] == "otp_supervisor/v1" and
      Enum.any?(attributes["domain"], &(&1 in ["otp", "sasl"])) and
      attributes["termination_context"] == "child_terminated" and
      attributes["restart_type"] in ["permanent", "transient"] and
      attributes["reason_class"] == "abnormal" and
      attributes["supervisor"] == identity["supervisor"] and
      attributes["offender_id"] == identity["offender_id"] and
      Input.canonical_pid?(attributes["offender_pid"])
  rescue
    _error -> false
  end

  defp distinct_offender_pids?(evidence) do
    pids = Enum.map(evidence, & &1["event"]["attributes"]["offender_pid"])
    Enum.uniq(pids) == pids
  end

  defp matching_reason_fingerprints?(evidence, expected) do
    evidence
    |> Enum.map(& &1["event"]["attributes"]["reason_fingerprint"])
    |> Enum.uniq()
    |> Kernel.==(expected)
  end

  defp mailbox_correlated?(finding, details, evidence, trigger, snapshot) do
    occurred_at = finding["occurred_at_us"]
    window_start = occurred_at - details["window_ms"] * 1_000
    identity = details["identity"]

    Enum.all?(evidence, &semantic_mailbox_event?(&1, identity)) and
      one_source_instance?(evidence) and increasing_source_sequences?(evidence) and
      consecutive_cycle_ids?(evidence) and strictly_growing_queues?(evidence) and
      constant_reductions?(evidence) and first_last_metrics_match?(evidence, details) and
      no_intervening_mailbox_gap?(snapshot, evidence, identity) and
      Enum.all?(evidence, &(&1["received_at_us"] in window_start..occurred_at)) and
      trigger == List.last(evidence)
  end

  defp semantic_mailbox_event?(entry, identity) do
    event = entry["event"]
    attributes = event["attributes"]

    event["source"] == "poller" and event["kind"] == "process_sample" and
      event["node"] == identity["node"] and event["boot_id"] == identity["boot_id"] and
      event["subject"] == %{
        "namespace" => "process",
        "scope" => identity["node"],
        "value" => identity["process_pid"]
      } and event["causality"]["process_generation"] == identity["process_generation"] and
      attributes["field_set"] == "otp_process_scalar/v1" and
      attributes["probe_status"] == "complete" and attributes["unavailable"] == [] and
      non_negative_integer?(attributes["metrics"]["message_queue_len"]) and
      non_negative_integer?(attributes["metrics"]["reductions_total"])
  rescue
    _error -> false
  end

  defp one_source_instance?(evidence),
    do: evidence |> Enum.map(& &1["event"]["source_instance_id"]) |> Enum.uniq() |> length() == 1

  defp increasing_source_sequences?(evidence) do
    sequences = Enum.map(evidence, & &1["event"]["source_sequence"])

    sequences
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> right > left end)
  end

  defp consecutive_cycle_ids?(evidence) do
    cycle_ids = Enum.map(evidence, & &1["event"]["attributes"]["cycle_id"])
    parsed = Enum.map(cycle_ids, &Input.cycle_sequence/1)

    Enum.all?(parsed, &match?({:ok, _cycle}, &1)) and
      parsed |> Enum.map(&elem(&1, 1)) |> consecutive_integers?()
  rescue
    _error -> false
  end

  defp consecutive_integers?(values),
    do:
      values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [left, right] -> right == left + 1 end)

  defp no_intervening_mailbox_gap?(snapshot, evidence, identity) do
    first = hd(evidence)
    last = List.last(evidence)
    source_instance = first["event"]["source_instance_id"]
    evidence_ids = MapSet.new(evidence, & &1["event"]["id"])

    snapshot["events"]
    |> Enum.filter(&(&1["receipt"] in first["receipt"]..last["receipt"]))
    |> Enum.reject(&MapSet.member?(evidence_ids, &1["event"]["id"]))
    |> Enum.all?(fn entry -> benign_intervening_event?(entry, identity, source_instance) end)
  end

  defp benign_intervening_event?(entry, identity, source_instance) do
    event = entry["event"]

    cond do
      event["source"] != "poller" or event["source_instance_id"] != source_instance ->
        true

      event["kind"] == "poll_cycle" ->
        event["attributes"]["probe_status"] != "truncated"

      event["kind"] == "process_sample" ->
        not same_mailbox_identity?(event, identity)

      true ->
        true
    end
  rescue
    _error -> false
  end

  defp same_mailbox_identity?(event, identity) do
    event["node"] == identity["node"] and event["boot_id"] == identity["boot_id"] and
      event["subject"] == %{
        "namespace" => "process",
        "scope" => identity["node"],
        "value" => identity["process_pid"]
      } and event["causality"]["process_generation"] == identity["process_generation"]
  end

  defp strictly_growing_queues?(evidence) do
    queues = Enum.map(evidence, & &1["event"]["attributes"]["metrics"]["message_queue_len"])
    Enum.chunk_every(queues, 2, 1, :discard) |> Enum.all?(fn [left, right] -> right > left end)
  end

  defp constant_reductions?(evidence) do
    evidence
    |> Enum.map(& &1["event"]["attributes"]["metrics"]["reductions_total"])
    |> Enum.uniq()
    |> length() == 1
  end

  defp first_last_metrics_match?(evidence, details) do
    first = hd(evidence)["event"]["attributes"]["metrics"]
    last = List.last(evidence)["event"]["attributes"]["metrics"]

    first["message_queue_len"] == details["queue_start"] and
      last["message_queue_len"] == details["queue_end"] and
      first["reductions_total"] == details["reductions_start"] and
      last["reductions_total"] == details["reductions_end"]
  end

  defp semantic_invariant_correlated?(details, evidence, trigger) when evidence != [] do
    entry = List.last(evidence)
    event = entry["event"]
    attributes = event["attributes"]
    identity = details["identity"]

    semantic_evidence_bound?(details, evidence) and trigger == entry and
      event["source"] == "contract" and event["kind"] == "invariant_failed" and
      event["severity"] == "error" and event["payload"] == false and
      attributes["semantic_projection"] == "application_invariant/v1" and
      attributes["contract_id"] == identity["contract_id"] and
      attributes["contract_version"] == identity["contract_version"] and
      attributes["contract_fingerprint"] == identity["contract_fingerprint"] and
      attributes["invariant"] == identity["invariant"] and
      attributes["invocation_status"] == "violation" and
      attributes["invocation_reason"] == "invariant_violated" and
      attributes["cleanup"] == "complete" and
      attributes["verdict"] == "violation" and attributes["execution"] == "complete" and
      attributes["disclosure"] == "clear"
  rescue
    _error -> false
  end

  defp semantic_invariant_correlated?(_details, _evidence, _trigger), do: false

  defp semantic_evidence_bound?(%{"identity" => identity} = details, [_trigger])
       when map_size(details) == 1 and is_map(identity),
       do: true

  defp semantic_evidence_bound?(
         %{"identity" => identity, "evidence_event_fingerprints" => fingerprints} = details,
         evidence
       )
       when map_size(details) == 2 and is_map(identity) and is_list(fingerprints) do
    length(evidence) == length(fingerprints) and
      Enum.zip(evidence, fingerprints)
      |> Enum.all?(fn {entry, expected} ->
        Finding.evidence_event_fingerprint(entry["event"]) == {:ok, expected}
      end)
  end

  defp semantic_evidence_bound?(_details, _evidence), do: false

  defp finding_to_wire(%Finding{} = finding) do
    case Finding.validate(finding) do
      {:ok, valid} -> {:ok, Finding.to_wire_map(valid)}
      {:error, _error} -> {:error, :invalid_finding}
    end
  end

  defp finding_to_wire(_finding), do: {:error, :invalid_finding}

  defp snapshot_to_wire(%Snapshot{} = snapshot, deadline) do
    expected = struct(Snapshot)

    if map_size(snapshot) == map_size(expected) and
         Enum.sort(Map.keys(snapshot)) == Enum.sort(Map.keys(expected)) and
         bounded_list?(snapshot.events, @maximum_events) do
      with {:ok, events} <- entries_to_wire(snapshot.events, deadline),
           {:ok, counters} <- counters_to_wire(snapshot.counters),
           {:ok, gaps} <- gaps_to_wire(snapshot.gaps),
           true <- snapshot.retained_bytes == event_bytes(events),
           true <- snapshot.classification_bytes == classification_bytes(events) do
        wire = %{
          "instance_id" => snapshot.instance_id,
          "recorder_started_at_us" => snapshot.recorder_started_at,
          "freeze_id" => snapshot.freeze_id,
          "trigger_event_id" => snapshot.trigger_event_id,
          "opening_receipt" => snapshot.opening_receipt,
          "closing_receipt" => snapshot.closing_receipt,
          "freeze_status" => Atom.to_string(snapshot.freeze_status),
          "completeness" => Atom.to_string(snapshot.completeness),
          "gaps" => gaps,
          "counters" => counters,
          "retained_count" => snapshot.retained_count,
          "retained_bytes" => snapshot.retained_bytes,
          "events" => events
        }

        if valid_snapshot?(wire), do: {:ok, wire}, else: {:error, :invalid_snapshot}
      end
    else
      {:error, :invalid_snapshot}
    end
  end

  defp snapshot_to_wire(_snapshot, _deadline), do: {:error, :invalid_snapshot}

  defp entries_to_wire(entries, deadline) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, output} ->
      with :ok <- before_deadline(deadline),
           {:ok, wire} <- entry_to_wire(entry) do
        {:cont, {:ok, [wire | output]}}
      else
        {:error, _reason} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, output} -> {:ok, Enum.reverse(output)}
      failure -> failure
    end
  end

  defp entry_to_wire(
         %{
           receipt: receipt,
           received_at: received_at,
           priority: priority,
           event: event,
           classification: classification
         } = entry
       )
       when map_size(entry) == 5 and priority in [:normal, :protected] do
    with {:ok, valid_event, canonical} <- Event.validate_encoded(event),
         true <- valid_event.redactions == [],
         {:ok, valid_classification} <-
           Classification.validate(classification, valid_event, canonical) do
      {:ok, classification_wire} =
        Classification.to_wire_map(valid_classification, valid_event)

      {:ok,
       %{
         "receipt" => receipt,
         "received_at_us" => received_at,
         "priority" => Atom.to_string(priority),
         "event" => Event.to_wire_map(valid_event),
         "classification" => classification_wire
       }}
    else
      _other -> {:error, :invalid_event_entry}
    end
  end

  defp entry_to_wire(_entry), do: {:error, :invalid_event_entry}

  defp counters_to_wire(counters) when is_map(counters) and not is_struct(counters) do
    if map_size(counters) == length(@counter_names) and
         Enum.sort(Map.keys(counters)) == Enum.sort(@counter_names) and
         Enum.all?(counters, fn {_name, value} -> non_negative_integer?(value) end) do
      {:ok, Map.new(counters, fn {name, value} -> {Atom.to_string(name), value} end)}
    else
      {:error, :invalid_counters}
    end
  end

  defp counters_to_wire(_counters), do: {:error, :invalid_counters}

  defp gaps_to_wire(gaps) do
    if bounded_list?(gaps, length(@gap_names)) and Enum.all?(gaps, &(&1 in @gap_names)) and
         Enum.uniq(gaps) == gaps do
      {:ok, Enum.map(gaps, &Atom.to_string/1)}
    else
      {:error, :invalid_gaps}
    end
  end

  defp authority_to_wire(authority) when is_list(authority) do
    if bounded_list?(authority, 2) and Keyword.keyword?(authority) and
         Enum.sort(Keyword.keys(authority)) == [:capture_audit_id, :export_audit_id] do
      wire = %{
        "capture_audit_id" => Keyword.fetch!(authority, :capture_audit_id),
        "export_audit_id" => Keyword.fetch!(authority, :export_audit_id)
      }

      if valid_authority?(wire), do: {:ok, wire}, else: {:error, :invalid_authority}
    else
      {:error, :invalid_authority}
    end
  end

  defp authority_to_wire(_authority), do: {:error, :invalid_authority}

  defp artifacts_to_wire(artifacts, deadline) do
    if bounded_list?(artifacts, @maximum_artifacts) do
      Enum.reduce_while(artifacts, {:ok, []}, fn reference, {:ok, output} ->
        with :ok <- before_deadline(deadline),
             {:ok, valid} <- ArtifactReference.validate(reference) do
          {:cont, {:ok, [ArtifactReference.to_wire_map(valid) | output]}}
        else
          {:error, :deadline_exceeded} = failure -> {:halt, failure}
          _error -> {:halt, {:error, :invalid_artifacts}}
        end
      end)
      |> case do
        {:ok, output} ->
          wires = Enum.sort_by(output, &{&1["role"], &1["sha256"]})

          if Enum.uniq_by(wires, &{&1["role"], &1["sha256"]}) == wires,
            do: {:ok, wires},
            else: {:error, :duplicate_artifacts}

        failure ->
          failure
      end
    else
      {:error, :invalid_artifacts}
    end
  end

  defp valid_entries?(entries) do
    bounded_list?(entries, @maximum_events) and Enum.all?(entries, &valid_entry?/1) and
      receipts(entries) == Enum.sort(receipts(entries)) and
      Enum.uniq(receipts(entries)) == receipts(entries) and
      entries |> Enum.map(& &1["event"]["id"]) |> Enum.uniq() |> length() == length(entries)
  end

  defp valid_entry?(entry) when is_map(entry) and not is_struct(entry) do
    (exact_keys?(entry, @entry_keys) and valid_entry_fields?(entry)) or
      (exact_keys?(entry, @classified_entry_keys) and valid_classified_entry?(entry))
  end

  defp valid_entry?(_entry), do: false

  defp valid_entry_fields?(entry),
    do:
      positive_integer?(entry["receipt"]) and signed_integer?(entry["received_at_us"]) and
        entry["priority"] in ["normal", "protected"] and
        match?({:ok, _event}, Event.decode_map(entry["event"]))

  defp valid_classified_entry?(entry) do
    with true <- valid_entry_fields?(entry),
         {:ok, event} <- Event.decode_map(entry["event"]),
         {:ok, _classification} <- Classification.decode_map(entry["classification"], event) do
      true
    else
      _other -> false
    end
  end

  defp valid_identity?(
         %{
           "boot_id" => boot_id,
           "node" => node,
           "offender_id" => offender_id,
           "supervisor" => supervisor
         } = identity
       )
       when map_size(identity) == 4,
       do:
         Input.bounded_id?(boot_id) and Input.bounded_string?(node, 256) and
           Input.bounded_string?(offender_id, 320) and Input.bounded_string?(supervisor, 320)

  defp valid_identity?(_identity), do: false

  defp valid_digest_list?(values, maximum),
    do:
      bounded_list?(values, maximum) and Enum.all?(values, &Input.digest?/1) and
        Enum.uniq(values) == values

  defp valid_id_list?(values, maximum),
    do:
      bounded_list?(values, maximum) and values != [] and
        Enum.all?(values, &Input.bounded_id?/1) and
        Enum.uniq(values) == values

  defp valid_gaps?(gaps) do
    names = Enum.map(@gap_names, &Atom.to_string/1)

    bounded_list?(gaps, length(names)) and Enum.all?(gaps, &(&1 in names)) and
      Enum.uniq(gaps) == gaps
  end

  defp valid_counters?(counters) when is_map(counters) and not is_struct(counters) do
    names = Enum.map(@counter_names, &Atom.to_string/1)
    legacy_names = Enum.map(@legacy_counter_names, &Atom.to_string/1)
    keys = Enum.sort(Map.keys(counters))

    (keys == Enum.sort(names) or keys == Enum.sort(legacy_names)) and
      Enum.all?(counters, fn {_name, value} -> non_negative_integer?(value) end)
  end

  defp valid_counters?(_counters), do: false

  @doc false
  @spec coherent_completeness?(term()) :: boolean()
  def coherent_completeness?(%{"completeness" => "complete", "gaps" => []}), do: true
  def coherent_completeness?(%{"completeness" => "incomplete", "gaps" => [_ | _]}), do: true
  def coherent_completeness?(_snapshot), do: false

  defp coherent_receipts?(snapshot) do
    receipts = receipts(snapshot["events"])

    receipts != [] and hd(receipts) >= 1 and List.last(receipts) <= snapshot["closing_receipt"] and
      snapshot["opening_receipt"] in receipts
  end

  @spec event_bytes([map()]) :: non_neg_integer()
  def event_bytes(entries) do
    Enum.reduce(entries, 0, fn entry, total ->
      {:ok, event} = Event.decode_map(entry["event"])
      {:ok, canonical} = Event.canonical_binary(event)

      total + byte_size(canonical)
    end)
  end

  defp classification_bytes(entries) do
    Enum.reduce(entries, 0, fn entry, total ->
      case Map.fetch(entry, "classification") do
        {:ok, classification} -> total + byte_size(Canonical.encode(classification))
        :error -> total
      end
    end)
  end

  defp receipts(entries), do: Enum.map(entries, & &1["receipt"])

  defp legacy_restart_fingerprint(finding) do
    %{
      "detector" => finding["detector"],
      "version" => finding["detector_version"],
      "identity" => finding["identity"]
    }
    |> Insider.Event.Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == keys

  defp bounded_list?(value, maximum), do: bounded_list?(value, maximum, 0)
  defp bounded_list?([], _maximum, _count), do: true
  defp bounded_list?(_value, maximum, count) when count >= maximum, do: false
  defp bounded_list?([_head | tail], maximum, count), do: bounded_list?(tail, maximum, count + 1)
  defp bounded_list?(_value, _maximum, _count), do: false

  defp positive_integer?(value),
    do: is_integer(value) and value in 1..@maximum_integer

  defp non_negative_integer?(value),
    do: is_integer(value) and value in 0..@maximum_integer

  defp signed_integer?(value),
    do: is_integer(value) and value in @minimum_integer..@maximum_integer

  defp before_deadline(deadline) do
    if is_integer(deadline) and System.monotonic_time(:microsecond) <= deadline,
      do: :ok,
      else: {:error, :deadline_exceeded}
  end
end
