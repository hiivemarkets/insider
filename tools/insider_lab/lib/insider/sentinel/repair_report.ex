defmodule Insider.Sentinel.RepairReport do
  @moduledoc """
  Deterministically renders a human review document from a bound repair report.

  Rendering accepts no caller-authored narrative. Every displayed claim comes
  from the machine manifest after it is recomputed from its exact source
  evidence.
  """

  alias Insider.Protocol.Error
  alias Insider.Sentinel.RepairReport.Manifest

  @maximum_markdown_bytes 131_072
  @components ["code", "configuration", "dependencies", "runtime", "target"]

  @spec render_markdown(term(), term(), term(), term()) ::
          {:ok, binary()} | {:error, Error.t()}
  def render_markdown(report, capsule, sentinel_manifest, verification) do
    with {:ok, report} <-
           Manifest.validate_with_evidence(report, capsule, sentinel_manifest, verification),
         {:ok, candidate_body} <- candidate_body(report.diffs["candidate"]) do
      markdown =
        [
          "# Insider repair report\n\n",
          "Verdict: **",
          escape(report.verdict["status"]),
          "**\n\n",
          verdict_reasons(report.verdict),
          causal_summary(report.causal_summary),
          reproduction(report.reproduction),
          proof(report.proof),
          candidate_diff(report.diffs, candidate_body),
          provenance(report.provenance),
          redactions(report.redactions),
          matrix(report.matrix),
          uncertainty(report.uncertainty),
          identities(report)
        ]
        |> IO.iodata_to_binary()

      if byte_size(markdown) <= @maximum_markdown_bytes,
        do: {:ok, markdown},
        else: render_limit_exceeded()
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error -> invalid_render(:rendering_failed)
  catch
    _kind, _reason -> invalid_render(:rendering_failed)
  end

  defp verdict_reasons(%{"reasons" => []}), do: "Reasons: none\n"

  defp verdict_reasons(%{"reasons" => reasons}),
    do: ["Reasons: ", Enum.map_join(reasons, ", ", &code/1), "\n"]

  defp causal_summary(%{"finding" => finding, "events" => events}) do
    identity = finding["semantic_identity"] || %{}

    [
      "\n## Causal summary\n\n",
      "- Finding: `",
      code(finding["fingerprint"]),
      "`\n",
      "- Detector: `",
      code(finding["detector"]),
      "/",
      code(finding["detector_version"]),
      "`\n",
      "- Confidence / severity: `",
      code(finding["confidence"]),
      "` / `",
      code(finding["severity"]),
      "`\n",
      "- Declared invariant: `",
      code(identity["invariant"] || "unavailable"),
      "`\n",
      "- Contract: `",
      code(identity["contract_id"] || "unavailable"),
      "` v",
      escape(to_string(identity["contract_version"] || "?")),
      "\n",
      "- Trigger: `",
      code(finding["trigger_event_id"]),
      "`\n\n",
      "Referenced causal events:\n\n",
      Enum.map(events, fn event ->
        [
          "- `",
          code(event["id"]),
          "` — `",
          code(event["source"]),
          "/",
          code(event["kind"]),
          "`; subject `",
          code(canonical(event["subject"])),
          "`\n"
        ]
      end)
    ]
  end

  defp reproduction(reproduction) do
    [
      "\n## Reproduction\n\n",
      "- Regression: `",
      code(reproduction["regression_id"]),
      "`\n",
      "- Source confirmation: `",
      code(reproduction["source_confirmation_id"]),
      "`\n",
      "- Target provenance: `",
      code(reproduction["target_fingerprint"]),
      "`\n",
      "- Scenario: `",
      code(get_in(reproduction, ["scenario", "id"])),
      "`\n",
      "- Seed: `",
      code(get_in(reproduction, ["scenario", "seed"])),
      "`\n\n",
      "The scenario is declarative evidence, not an executable shell command:\n\n",
      fenced(canonical(reproduction["scenario"]), "json")
    ]
  end

  defp proof(proof) do
    counts = proof["executor_counts"]

    rows =
      proof["source"]
      |> Enum.map(&proof_row("source", &1))
      |> Kernel.++(Enum.map(proof["before"], &proof_row("before", &1)))
      |> Kernel.++(Enum.map(proof["after"], &proof_row("after", &1)))

    [
      "\n## Before/after proof\n\n",
      "Executor counts: active `",
      escape(to_string(counts["active"])),
      "`; quarantined `",
      escape(to_string(counts["quarantined"])),
      "`\n\n",
      "| Phase | Run | Operational | Finding | Receipt | Evidence | Cleanup | Release | Remaining |\n",
      "| --- | ---: | --- | --- | --- | --- | --- | --- | ---: |\n",
      rows
    ]
  end

  defp proof_row(phase, row) do
    cleanup = row["cleanup"] || %{}

    finding =
      cond do
        row["outcome"] == "matching_failure" -> "observed"
        row["observed_fingerprints"] == [] -> "absent"
        true -> "unknown"
      end

    [
      "| ",
      cell(phase),
      " | ",
      cell(row["ordinal"]),
      " | ",
      cell(row["operational_status"] || row["status"]),
      " | ",
      cell(finding),
      " | ",
      cell(row["receipt_status"] || "not_applicable"),
      " | ",
      cell(evidence_label(row["evidence"])),
      " | ",
      cell(row["cleanup_status"] || "unknown"),
      " | ",
      cell(cleanup["release"] || "unknown"),
      " | ",
      cell(cleanup["remaining_count"]),
      " |\n"
    ]
  end

  defp candidate_diff(%{"candidate" => candidate, "code_transition" => transition}, body) do
    rendered_body =
      case body do
        {:display, content} ->
          fenced(normalize_blank_diff_lines(content), "diff")

        :not_renderable ->
          "Candidate bytes are not safely displayable; inspect the bound machine artifact.\n"
      end

    [
      "\n## Candidate diff\n\n",
      "- Candidate: `",
      code(candidate["id"]),
      "`\n",
      "- Format: `",
      code(candidate["format"]),
      "`\n",
      "- Bytes / SHA-256: `",
      escape(to_string(candidate["byte_size"])),
      "` / `",
      code(candidate["content_sha256"]),
      "`\n",
      "- Changed components: `",
      code(component_list(transition["changed_components"])),
      "`\n",
      "- Unchanged components: `",
      code(component_list(transition["unchanged_components"])),
      "`\n",
      "- Unknown components: `",
      code(component_list(transition["unknown_components"])),
      "`\n",
      "- Display note: whitespace-only diff lines are normalized; the machine manifest retains the exact candidate bytes.\n\n",
      rendered_body
    ]
  end

  defp provenance(provenance) do
    comparison = provenance["comparison"]

    rows =
      Enum.map(@components, fn name ->
        item = comparison[name]

        [
          "| ",
          cell(name),
          " | ",
          cell(item["status"]),
          " | `",
          code(item["before"]),
          "` | `",
          code(item["after"]),
          "` |\n"
        ]
      end)

    [
      "\n## Provenance\n\n",
      "Source capture, replay baseline, and repaired target are distinct stages. SHA-256 binds bytes; it does not authenticate their origin.\n\n",
      "| Component | Transition | Replay baseline | Repaired target |\n",
      "| --- | --- | --- | --- |\n",
      rows
    ]
  end

  defp redactions(redactions) do
    capsule = redactions["capsule"]

    [
      "\n## Redaction boundary\n\n",
      "- Capsule policy: `",
      code(capsule["policy_id"]),
      "` / `",
      code(capsule["policy_fingerprint"]),
      "`\n",
      "- Export policy: `",
      code(capsule["export_policy_fingerprint"]),
      "`\n",
      "- Redaction records: `",
      escape(to_string(length(capsule["manifest"]))),
      "`\n",
      "- Candidate coverage: **",
      escape(redactions["candidate"]["coverage"]),
      "**\n",
      "- Verification coverage: **",
      escape(redactions["verification"]["coverage"]),
      "**\n\n",
      "Candidate bytes are included for review but have no capsule-policy redaction attestation. Treat this report as an internal artifact.\n"
    ]
  end

  defp matrix(rows) do
    rendered =
      Enum.map(rows, fn row ->
        [
          "| ",
          cell(row["phase"]),
          " | ",
          cell(row["ordinal"]),
          " | `",
          code(row["owner_fingerprint"]),
          "` | ",
          cell(row["operational"]),
          " | ",
          cell(row["scenario"]),
          " | ",
          cell(row["finding"]),
          " | ",
          cell(row["oracle"]),
          " | ",
          cell(row["gates"]),
          " | ",
          cell(row["evidence"]),
          " | ",
          cell(row["cleanup"]),
          " | ",
          cell(row["cleanup_release"]),
          " | ",
          cell(row["cleanup_remaining_count"]),
          " |\n"
        ]
      end)

    [
      "\n## Verification matrix\n\n",
      "| Phase | # | Owner | Operational | Scenario | Finding | Oracle | Gates | Evidence | Cleanup | Release | Remaining |\n",
      "| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: |\n",
      rendered
    ]
  end

  defp uncertainty(entries) do
    [
      "\n## Uncertainty and limits\n\n",
      Enum.map(entries, fn entry ->
        [
          "- `",
          code(entry["code"]),
          "` — ",
          escape(entry["scope"]),
          " (",
          escape(entry["source"]),
          ")\n"
        ]
      end)
    ]
  end

  defp identities(report) do
    [
      "\n## Evidence identities\n\n",
      "- Report: `",
      code(report.id),
      "`\n",
      Enum.map(["capsule", "sentinel_manifest", "verification_record"], fn name ->
        source = report.sources[name]

        [
          "- ",
          escape(name),
          ": `",
          code(source["id"]),
          "`; canonical SHA-256 `",
          code(source["canonical_sha256"]),
          "`; ",
          escape(to_string(source["byte_size"])),
          " bytes\n"
        ]
      end)
    ]
  end

  defp candidate_body(%{"format" => "unified-diff/v1", "content_base64" => encoded}) do
    case Base.decode64(encoded) do
      {:ok, content} ->
        if String.valid?(content) and not String.contains?(content, <<0>>),
          do: {:ok, {:display, content}},
          else: {:ok, :not_renderable}

      :error ->
        invalid_render(:invalid_candidate_encoding)
    end
  end

  defp candidate_body(_candidate), do: {:ok, :not_renderable}

  defp component_list([]), do: "none"
  defp component_list(components), do: Enum.join(components, ", ")

  defp normalize_blank_diff_lines(content),
    do: String.replace(content, ~r/^[\t ]+$/m, "")

  defp evidence_label(%{"complete" => true, "dropped" => 0, "gaps" => 0, "truncated" => false}),
    do: "complete"

  defp evidence_label(_evidence), do: "incomplete"

  defp fenced(content, language) do
    longest =
      Regex.scan(~r/`+/, content)
      |> Enum.map(fn [ticks] -> String.length(ticks) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))

    [
      fence,
      language,
      "\n",
      content,
      if(String.ends_with?(content, "\n"), do: "", else: "\n"),
      fence,
      "\n"
    ]
  end

  defp canonical(value), do: Insider.Event.Canonical.encode(value)

  defp cell(nil), do: "missing"

  defp cell(value) do
    value
    |> to_string()
    |> escape()
    |> String.replace("|", "&#124;")
    |> String.replace(["\r", "\n"], " ")
  end

  defp code(nil), do: "missing"

  defp code(value) do
    value
    |> to_string()
    |> escape()
    |> String.replace("`", "&#96;")
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp invalid_render(reason),
    do:
      {:error,
       Error.new(:invalid_repair_report_render, "repair report could not be rendered", %{
         reason: reason
       })}

  defp render_limit_exceeded,
    do:
      {:error,
       Error.new(
         :repair_report_render_limit_exceeded,
         "repair report Markdown exceeds its static limit"
       )}
end
