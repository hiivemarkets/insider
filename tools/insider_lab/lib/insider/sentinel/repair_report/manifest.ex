defmodule Insider.Sentinel.RepairReport.Manifest do
  @moduledoc """
  A bounded, content-addressed summary of completed repair evidence.

  Standalone validation proves structural integrity only. The report becomes
  evidence-bearing only after `validate_with_evidence/4` recomputes it from the
  exact incident capsule, pre-execution Sentinel manifest, and verification
  record named by `sources`.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.Verification.Receipt
  alias Insider.Sentinel.Verification.Record, as: VerificationRecord

  @schema "insider.repair-report-manifest/v1"
  @maximum_bytes 262_144
  @maximum_term_bytes 524_288
  @fields [
    :schema,
    :id,
    :sources,
    :verdict,
    :causal_summary,
    :reproduction,
    :proof,
    :diffs,
    :provenance,
    :redactions,
    :matrix,
    :uncertainty,
    :integrity
  ]
  @wire_keys Enum.map(@fields, &Atom.to_string/1)
  @components ["code", "configuration", "dependencies", "runtime", "target"]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(Capsule.t(), SentinelManifest.t(), VerificationRecord.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(capsule, sentinel_manifest, verification) do
    with {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, sentinel_manifest} <-
           SentinelManifest.validate_with_capsule(sentinel_manifest, capsule),
         {:ok, verification} <- VerificationRecord.validate(verification),
         :ok <- bind_evidence(capsule, sentinel_manifest, verification),
         {:ok, source_refs} <- source_refs(capsule, sentinel_manifest, verification) do
      sections = derive(capsule, sentinel_manifest, verification, source_refs)
      digest = hash(sections)

      sections
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> from_wire()
      |> validate()
    else
      {:error, %Error{code: :sentinel_manifest_integrity_failed}} -> integrity_failed()
      {:error, %Error{} = error} -> {:error, error}
      :error -> integrity_failed()
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = report) do
    with true <- Enum.sort(Map.keys(Map.from_struct(report))) == Enum.sort(@fields),
         true <- report.schema == @schema,
         true <- Value.bounded_data?(to_wire_map(report), @maximum_term_bytes),
         true <- is_map(report.sources) and map_size(report.sources) == 3,
         true <- is_map(report.verdict),
         true <- report.verdict["status"] in ["verified", "invalid"],
         true <- is_list(report.verdict["reasons"]),
         true <- is_map(report.causal_summary),
         true <- is_map(report.reproduction),
         true <- is_map(report.proof),
         true <- is_map(report.diffs),
         true <- is_map(report.provenance),
         true <- is_map(report.redactions),
         [_, _, _, _, _] <- report.matrix,
         true <- Value.bounded_list?(report.uncertainty, 256),
         true <- valid_integrity?(report.integrity),
         true <- report.id == "sha256:" <> report.integrity["content_digest"],
         true <- report.integrity["content_digest"] == hash(content(report)),
         wire <- to_wire_map(report),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, report}
    else
      _other -> invalid(:invalid_manifest)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Validates and recomputes a report from the exact evidence graph."
  @spec validate_with_evidence(term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(report, capsule, sentinel_manifest, verification) do
    with {:ok, valid_report} <- validate(report),
         {:ok, expected} <- new(capsule, sentinel_manifest, verification),
         true <- to_wire_map(valid_report) == to_wire_map(expected) do
      {:ok, valid_report}
    else
      {:error, %Error{code: code}}
      when code in [
             :invalid_repair_report_manifest,
             :repair_report_manifest_limit_exceeded,
             :unsupported_repair_report_manifest_schema
           ] ->
        invalid(:invalid_report)

      _other ->
        integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(report) do
    with {:ok, valid} <- validate(report), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary do
      decode_map(wire)
    else
      false -> invalid(:noncanonical_encoding)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded()
  def decode(_value), do: invalid(:invalid_value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema, do: unsupported_schema(schema)

  def decode_map(%{"schema" => @schema} = wire) when map_size(wire) == length(@wire_keys) do
    if Enum.sort(Map.keys(wire)) == Enum.sort(@wire_keys) do
      wire |> from_wire() |> validate()
    else
      invalid(:invalid_envelope)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)
  def decode_map(value) when is_map(value) and not is_struct(value), do: unsupported_schema(nil)
  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = report) do
    report
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp derive(capsule, _sentinel_manifest, verification, source_refs) do
    regression = verification.regression
    source = regression["confirmed_record"]
    after_attempts = verification.after_attempts
    receipt_context = receipt_context(regression, verification)

    %{
      "schema" => @schema,
      "sources" => source_refs,
      "verdict" => %{"status" => verification.status, "reasons" => verification.reasons},
      "causal_summary" => causal_summary(capsule),
      "reproduction" => %{
        "regression_id" => regression["id"],
        "scenario" => regression["scenario"],
        "expectation" => regression["expectation"],
        "execution_policy" => regression["execution_policy"],
        "source_confirmation_id" => source["id"],
        "target_fingerprint" => source["observed_target_fingerprint"]
      },
      "proof" => %{
        "executor_counts" => verification.executor_counts,
        "source" => [confirmation_projection(source, 1)],
        "before" =>
          verification.before_records
          |> Enum.with_index(1)
          |> Enum.map(fn {record, ordinal} -> confirmation_projection(record, ordinal) end),
        "after" =>
          after_attempts
          |> Enum.with_index(1)
          |> Enum.map(fn {attempt, ordinal} ->
            after_projection(attempt, ordinal, receipt_context)
          end)
      },
      "diffs" => %{
        "candidate" => verification.candidate,
        "code_transition" => code_transition(after_attempts, receipt_context)
      },
      "provenance" => provenance(capsule, after_attempts, receipt_context),
      "redactions" => %{
        "capsule" => capsule.redaction,
        "candidate" => %{
          "bytes_included" => true,
          "coverage" => "not_covered_by_capsule_policy"
        },
        "verification" => %{"coverage" => "not_covered_by_capsule_policy"}
      },
      "matrix" => matrix(source, verification.before_records, after_attempts, receipt_context),
      "uncertainty" => uncertainty(capsule, verification, receipt_context)
    }
  end

  defp causal_summary(capsule) do
    finding = capsule.finding

    ids =
      (finding["evidence_event_ids"] ++ [finding["trigger_event_id"]])
      |> Enum.uniq()

    events =
      capsule.snapshot["events"]
      |> Enum.map(& &1["event"])
      |> Map.new(&{&1["id"], &1})

    %{
      "finding" => %{
        "fingerprint" => finding["fingerprint"],
        "detector" => finding["detector"],
        "detector_version" => finding["detector_version"],
        "confidence" => finding["confidence"],
        "severity" => finding["severity"],
        "trigger_event_id" => finding["trigger_event_id"],
        "evidence_event_ids" => finding["evidence_event_ids"],
        "semantic_identity" => get_in(finding, ["details", "identity"])
      },
      "events" =>
        Enum.map(ids, fn id ->
          event = Map.fetch!(events, id)

          Map.take(event, [
            "id",
            "kind",
            "source",
            "severity",
            "subject",
            "causality",
            "attributes"
          ])
        end)
    }
  end

  defp confirmation_projection(nil, ordinal),
    do: %{
      "ordinal" => ordinal,
      "status" => "missing",
      "cleanup_status" => "unknown",
      "uncertainty" => ["missing_record"]
    }

  defp confirmation_projection(record, ordinal) do
    evidence = record["evidence"]

    %{
      "ordinal" => ordinal,
      "confirmation_id" => record["id"],
      "observation_run_fingerprint" => evidence["observation_run_fingerprint"],
      "owner_fingerprint" => evidence["owner_fingerprint"],
      "operational_status" => record["operational_status"],
      "outcome" => record["outcome"],
      "expected_fingerprint" => record["expected_fingerprint"],
      "observed_fingerprints" => record["observed_fingerprints"],
      "target_fingerprint" => record["observed_target_fingerprint"],
      "evidence" => Map.take(evidence, ["complete", "dropped", "gaps", "status", "truncated"]),
      "cleanup" => record["cleanup"],
      "cleanup_status" => cleanup_status(record["cleanup"]),
      "uncertainty" => record["uncertainty"]
    }
  end

  defp after_projection(attempt, ordinal, receipt_context) do
    {receipt_status, receipt} = receipt_data(attempt, receipt_context)

    %{
      "ordinal" => ordinal,
      "status" => attempt["status"],
      "receipt_status" => receipt_status,
      "owner_fingerprint" => attempt["owner_fingerprint"],
      "target_fingerprint" => attempt["target_fingerprint"],
      "observation_run_fingerprint" => value(receipt, "observation_run_fingerprint"),
      "expected_fingerprint" => value(receipt, "expected_fingerprint"),
      "observed_fingerprints" => value(receipt, "observed_fingerprints"),
      "oracle" => value(receipt, "oracle"),
      "gates" => value(receipt, "gates"),
      "evidence" => value(receipt, "evidence"),
      "pre_provenance_fingerprint" => get_in(receipt || %{}, ["pre_provenance", "fingerprint"]),
      "post_provenance_fingerprint" => get_in(receipt || %{}, ["post_provenance", "fingerprint"]),
      "cleanup" => attempt["cleanup"],
      "cleanup_status" => cleanup_status(attempt["cleanup"]),
      "uncertainty" => attempt["uncertainty"]
    }
  end

  defp code_transition(attempts, receipt_context) do
    receipt = first_bound_receipt(attempts, receipt_context)
    pre = get_in(receipt || %{}, ["pre_provenance", "components"]) || %{}
    post = get_in(receipt || %{}, ["post_provenance", "components"]) || %{}

    comparisons =
      Enum.map(@components, fn name ->
        before = get_in(pre, [name, "fingerprint"])
        after_value = get_in(post, [name, "fingerprint"])

        status =
          cond do
            is_nil(before) or is_nil(after_value) -> "unknown"
            before == after_value -> "unchanged"
            true -> "changed"
          end

        {name, status}
      end)

    %{
      "before_fingerprint" => get_in(pre, ["code", "fingerprint"]),
      "after_fingerprint" => get_in(post, ["code", "fingerprint"]),
      "changed_components" => for({name, "changed"} <- comparisons, do: name),
      "unchanged_components" => for({name, "unchanged"} <- comparisons, do: name),
      "unknown_components" => for({name, "unknown"} <- comparisons, do: name)
    }
  end

  defp provenance(capsule, attempts, receipt_context) do
    receipt = first_bound_receipt(attempts, receipt_context)
    replay = value(receipt, "pre_provenance")
    repaired = value(receipt, "post_provenance")

    %{
      "source_capture" => capsule.provenance,
      "replay_baseline" => replay,
      "repaired_target" => repaired,
      "comparison" => compare_provenance(replay, repaired)
    }
  end

  defp compare_provenance(nil, _repaired), do: unknown_comparison()
  defp compare_provenance(_replay, nil), do: unknown_comparison()

  defp compare_provenance(replay, repaired) do
    Map.new(@components, fn name ->
      before = get_in(replay, ["components", name, "fingerprint"])
      after_value = get_in(repaired, ["components", name, "fingerprint"])

      status =
        cond do
          is_nil(before) or is_nil(after_value) -> "unknown"
          before == after_value -> "same"
          true -> "changed"
        end

      {name, %{"before" => before, "after" => after_value, "status" => status}}
    end)
  end

  defp unknown_comparison,
    do: Map.new(@components, &{&1, %{"before" => nil, "after" => nil, "status" => "unknown"}})

  defp matrix(source, before, after_attempts, receipt_context) do
    [matrix_confirmation(source, "source", 1)] ++
      (before
       |> Enum.with_index(1)
       |> Enum.map(fn {record, ordinal} -> matrix_confirmation(record, "before", ordinal) end)) ++
      (after_attempts
       |> Enum.with_index(1)
       |> Enum.map(fn {attempt, ordinal} -> matrix_after(attempt, ordinal, receipt_context) end))
  end

  defp matrix_confirmation(nil, phase, ordinal) do
    %{
      "phase" => phase,
      "ordinal" => ordinal,
      "run_id" => nil,
      "owner_fingerprint" => nil,
      "target_fingerprint" => nil,
      "operational" => "missing",
      "scenario" => "missing",
      "finding" => "unknown",
      "oracle" => "not_applicable",
      "gates" => "not_applicable",
      "evidence" => "incomplete",
      "cleanup" => "unknown",
      "cleanup_release" => "unknown",
      "cleanup_remaining_count" => nil,
      "cleanup_remaining_fingerprint" => nil,
      "uncertainty" => ["missing_record"]
    }
  end

  defp matrix_confirmation(record, phase, ordinal) do
    evidence = record["evidence"]

    %{
      "phase" => phase,
      "ordinal" => ordinal,
      "run_id" => record["id"],
      "owner_fingerprint" => evidence["owner_fingerprint"],
      "target_fingerprint" => record["observed_target_fingerprint"],
      "operational" => record["operational_status"],
      "scenario" => evidence["scenario_status"],
      "finding" =>
        if(record["outcome"] == "matching_failure", do: "observed", else: "not_observed"),
      "oracle" => "not_applicable",
      "gates" => "not_applicable",
      "evidence" => evidence_status(evidence),
      "uncertainty" => record["uncertainty"]
    }
    |> Map.merge(cleanup_projection(record["cleanup"]))
  end

  defp matrix_after(attempt, ordinal, receipt_context) do
    {_receipt_status, receipt} = receipt_data(attempt, receipt_context)
    observed = value(receipt, "observed_fingerprints")

    %{
      "phase" => "after",
      "ordinal" => ordinal,
      "run_id" => value(receipt, "observation_run_fingerprint"),
      "owner_fingerprint" => attempt["owner_fingerprint"],
      "target_fingerprint" => attempt["target_fingerprint"],
      "operational" => attempt["status"],
      "scenario" => get_in(receipt || %{}, ["evidence", "scenario_status"]),
      "finding" => if(observed == [], do: "absent", else: "observed_or_unknown"),
      "oracle" => get_in(receipt || %{}, ["oracle", "status"]) || "missing",
      "gates" => gates_status(value(receipt, "gates")),
      "evidence" => evidence_status(value(receipt, "evidence")),
      "uncertainty" => attempt["uncertainty"]
    }
    |> Map.merge(cleanup_projection(attempt["cleanup"]))
  end

  defp cleanup_projection(cleanup) do
    %{
      "cleanup" => cleanup_status(cleanup),
      "cleanup_release" => cleanup["release"],
      "cleanup_remaining_count" => cleanup["remaining_count"],
      "cleanup_remaining_fingerprint" => cleanup["remaining_fingerprint"]
    }
  end

  defp cleanup_status(cleanup) do
    if VerificationRecord.complete_cleanup?(cleanup), do: "complete", else: "not_complete"
  end

  defp evidence_status(%{"complete" => true, "dropped" => 0, "gaps" => 0, "truncated" => false}),
    do: "complete"

  defp evidence_status(_evidence), do: "incomplete"

  defp gates_status(gates) when is_map(gates) and map_size(gates) == 3 do
    if Enum.all?(gates, fn {_name, gate} -> gate["status"] == "passed" end),
      do: "passed",
      else: "not_passed"
  end

  defp gates_status(_gates), do: "missing"

  defp uncertainty(capsule, verification, receipt_context) do
    snapshot = capsule.snapshot

    source_uncertainty =
      if snapshot["completeness"] == "complete" do
        []
      else
        [entry("source_snapshot_incomplete", "source_capture", "capsule.snapshot.completeness")]
      end

    gaps =
      Enum.map(snapshot["gaps"], &entry(&1, "source_capture", "capsule.snapshot.gaps"))

    run_uncertainty =
      [verification.regression["confirmed_record"] | verification.before_records]
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {nil, index} ->
          [entry("missing_record", "confirmation:#{index}", "verification.before_records")]

        {record, index} ->
          Enum.map(
            record["uncertainty"],
            &entry(&1, "confirmation:#{index}", "record.uncertainty")
          )
      end)

    after_uncertainty =
      verification.after_attempts
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {attempt, index} ->
        Enum.map(attempt["uncertainty"], &entry(&1, "after:#{index}", "attempt.uncertainty"))
      end)

    receipt_uncertainty =
      verification.after_attempts
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {attempt, index} ->
        case receipt_data(attempt, receipt_context) do
          {"bound", _receipt} -> []
          {status, _receipt} -> [entry("#{status}_receipt", "after:#{index}", "attempt.receipt")]
        end
      end)

    reasons =
      Enum.map(
        verification.reasons,
        &entry(&1, "verification", "verification.reasons")
      )

    constants = [
      entry("candidate_redaction_unattested", "candidate", "report_contract/v1"),
      entry("scenario_scope_only", "verdict", "report_contract/v1"),
      entry("sha256_not_authenticity", "integrity", "report_contract/v1")
    ]

    display =
      if candidate_displayable?(verification.candidate),
        do: [],
        else: [entry("candidate_body_not_rendered", "candidate", "report_contract/v1")]

    (source_uncertainty ++
       gaps ++
       run_uncertainty ++
       after_uncertainty ++ receipt_uncertainty ++ reasons ++ constants ++ display)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["code"], &1["scope"], &1["source"]})
  end

  defp entry(code, scope, source), do: %{"code" => code, "scope" => scope, "source" => source}

  defp source_refs(capsule, sentinel_manifest, verification) do
    with {:ok, capsule_bytes} <- Capsule.canonical_binary(capsule),
         {:ok, manifest_bytes} <- SentinelManifest.canonical_binary(sentinel_manifest),
         {:ok, verification_bytes} <- VerificationRecord.canonical_binary(verification) do
      {:ok,
       %{
         "capsule" => reference(capsule, capsule_bytes),
         "sentinel_manifest" => reference(sentinel_manifest, manifest_bytes),
         "verification_record" => reference(verification, verification_bytes)
       }}
    end
  end

  defp reference(artifact, bytes),
    do: %{
      "schema" => artifact.schema,
      "id" => artifact.id,
      "canonical_sha256" => hash_binary(bytes),
      "byte_size" => byte_size(bytes)
    }

  defp bind_evidence(capsule, sentinel_manifest, verification) do
    regression = verification.regression
    source = regression["confirmed_record"]
    expected = capsule.finding["fingerprint"]
    scenario_id = regression["scenario"]["id"]
    baseline = capsule.provenance["fingerprint"]

    if confirmation_bound?(source, capsule, sentinel_manifest, scenario_id, expected, baseline) and
         regression["expectation"]["incident_fingerprint"] == expected,
       do: :ok,
       else: :error
  end

  defp confirmation_bound?(record, capsule, sentinel_manifest, scenario_id, expected, baseline) do
    record["capsule_id"] == capsule.id and
      record["manifest_id"] == sentinel_manifest.id and
      record["scenario_id"] == scenario_id and
      record["expected_fingerprint"] == expected and
      record["observed_target_fingerprint"] == baseline
  end

  defp candidate_displayable?(%{"format" => "unified-diff/v1", "content_base64" => encoded}) do
    case Base.decode64(encoded) do
      {:ok, content} -> String.valid?(content) and not String.contains?(content, <<0>>)
      :error -> false
    end
  end

  defp candidate_displayable?(_candidate), do: false

  defp first_bound_receipt(attempts, receipt_context) do
    Enum.find_value(attempts, fn attempt ->
      case receipt_data(attempt, receipt_context) do
        {"bound", receipt} -> receipt
        {_status, _receipt} -> nil
      end
    end)
  end

  defp receipt_data(%{"receipt" => nil}, _receipt_context), do: {"missing", nil}

  defp receipt_data(%{"receipt" => receipt} = attempt, receipt_context) do
    case Receipt.validate(receipt) do
      {:ok, valid} ->
        if receipt_bound?(valid, attempt, receipt_context),
          do: {"bound", valid},
          else: {"unbound", nil}

      {:error, %Error{}} ->
        {"invalid", nil}
    end
  end

  defp receipt_context(regression, verification) do
    %{
      baseline: regression["confirmed_record"]["observed_target_fingerprint"],
      candidate: verification.candidate,
      expected: regression["expectation"]["incident_fingerprint"],
      observer: regression["expectation"]["observer"],
      oracle: verification.oracle,
      regression_id: regression["id"],
      scenario_id: regression["scenario"]["id"]
    }
  end

  defp receipt_bound?(receipt, attempt, context) do
    receipt["regression_id"] == context.regression_id and
      receipt["candidate_id"] == context.candidate["id"] and
      receipt["scenario_id"] == context.scenario_id and
      receipt["expected_fingerprint"] == context.expected and
      receipt["observer"] == context.observer and
      receipt["oracle"]["identity"] == context.oracle and
      receipt["owner_fingerprint"] == attempt["owner_fingerprint"] and
      receipt["observation_run_fingerprint"] == attempt["owner_fingerprint"] and
      attempt["target_fingerprint"] == context.baseline and
      receipt["pre_provenance"]["fingerprint"] == context.baseline and
      candidate_provenance_bound?(receipt, context.candidate)
  end

  defp candidate_provenance_bound?(receipt, candidate) do
    case get_in(receipt, [
           "post_provenance",
           "components",
           "code",
           "attributes",
           "candidate_sha256"
         ]) do
      nil -> true
      digest -> digest == candidate["content_sha256"]
    end
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: map[key]

  defp from_wire(wire) do
    struct!(
      __MODULE__,
      Map.new(wire, fn {key, value} -> {String.to_existing_atom(key), value} end)
    )
  end

  defp content(report), do: report |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and digest?(digest)

  defp valid_integrity?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false
  defp hash(value), do: value |> Canonical.encode() |> hash_binary()
  defp hash_binary(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_repair_report_manifest, "repair report manifest is invalid", %{
         reason: reason
       })}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :repair_report_integrity_failed,
         "repair report does not match the supplied evidence"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :repair_report_manifest_limit_exceeded,
         "repair report manifest exceeds its static limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_repair_report_manifest_schema,
         "repair report manifest schema is unsupported",
         %{schema: Insider.Protocol.Value.summary(schema)}
       )}
end
