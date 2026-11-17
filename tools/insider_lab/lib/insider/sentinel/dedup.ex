defmodule Insider.Sentinel.Dedup do
  @moduledoc """
  Offline, deterministic, bounded retention for canonical incidents and proposals.

  Capsules enter first. Proposal admission requires the complete exact evidence
  graph and its already-retained capsule. The caller-owned Lab state retains
  bounded canonical evidence bytes so it can revalidate every bucket on every
  use; receipts remain privacy-minimal references only.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Sentinel.Dedup.Receipt
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.RepairReport.Manifest, as: RepairReportManifest
  alias Insider.Sentinel.Verification.Record, as: VerificationRecord

  @maximum_groups 128
  @maximum_artifacts_per_group 32
  @maximum_input_bytes 2_097_152
  @maximum_retained_bytes 16_777_216
  @maximum_receipts 4_096
  @defaults %{
    max_groups: 32,
    max_artifacts_per_group: 8,
    max_input_bytes: @maximum_input_bytes,
    max_retained_bytes: 2_097_152,
    max_receipts: 256
  }

  @enforce_keys [:limits, :groups, :receipt_count, :retained_bytes]
  defstruct [:limits, :groups, :receipt_count, :retained_bytes]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ [])

  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- Keyword.keys(options) == Enum.uniq(Keyword.keys(options)),
         true <- Keyword.keys(options) -- Map.keys(@defaults) == [],
         limits <- Map.merge(@defaults, Map.new(options)),
         true <- valid_limits?(limits) do
      {:ok, %__MODULE__{limits: limits, groups: %{}, receipt_count: 0, retained_bytes: 0}}
    else
      _other -> invalid_state(:invalid_limits)
    end
  rescue
    _error -> invalid_state(:invalid_limits)
  end

  def new(_options), do: invalid_state(:invalid_limits)

  @spec ingest_capsule(term(), term()) :: {:ok, t(), Receipt.t()} | {:error, Error.t()}
  def ingest_capsule(state, capsule_bytes) do
    with {:ok, state} <- validate(state),
         {:ok, input} <- capsule_input(capsule_bytes, state.limits.max_input_bytes) do
      classify(state, input)
    end
  rescue
    _error -> invalid_input(:capsule_submission_failed)
  end

  @doc "Admits a proposal only after exact graph recomputation and capsule binding."
  @spec ingest_proposal(term(), term(), term(), term(), term(), term()) ::
          {:ok, t(), Receipt.t()} | {:error, Error.t()}
  def ingest_proposal(
        state,
        proposal_bytes,
        capsule_bytes,
        manifest_bytes,
        verification_bytes,
        report_bytes
      ) do
    with {:ok, state} <- validate(state),
         {:ok, input} <-
           proposal_input(
             proposal_bytes,
             capsule_bytes,
             manifest_bytes,
             verification_bytes,
             report_bytes,
             state
           ) do
      classify(state, input)
    end
  rescue
    _error -> invalid_input(:proposal_submission_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    with true <-
           Map.keys(Map.from_struct(state)) |> Enum.sort() == [
             :groups,
             :limits,
             :receipt_count,
             :retained_bytes
           ],
         true <- valid_limits?(state.limits),
         true <- is_map(state.groups) and map_size(state.groups) <= state.limits.max_groups,
         true <-
           is_integer(state.receipt_count) and state.receipt_count >= 0 and
             state.receipt_count <= state.limits.max_receipts,
         true <-
           is_integer(state.retained_bytes) and state.retained_bytes >= 0 and
             state.retained_bytes <= state.limits.max_retained_bytes,
         {:ok, bytes, artifacts} <- validate_groups(state.groups, state.limits),
         true <- bytes == state.retained_bytes,
         true <- artifacts == state.receipt_count do
      {:ok, state}
    else
      _other -> invalid_state(:invalid_ledger)
    end
  rescue
    _error -> invalid_state(:invalid_ledger)
  catch
    _kind, _reason -> invalid_state(:invalid_ledger)
  end

  def validate(_value), do: invalid_state(:invalid_ledger)

  defp capsule_input(bytes, maximum_input_bytes) when is_binary(bytes) do
    with true <- byte_size(bytes) <= maximum_input_bytes,
         bytes <- :binary.copy(bytes),
         {:ok, capsule} <- Capsule.decode(bytes),
         {:ok, canonical} <- Capsule.canonical_binary(capsule),
         true <- canonical == bytes do
      ref = reference(capsule, bytes)

      {:ok,
       %{
         kind: :capsule,
         capsule: ref,
         proposal: nil,
         bytes: bytes,
         group: group_id(capsule),
         key: ref["canonical_sha256"],
         retain_bytes: byte_size(bytes),
         evidence_bytes: byte_size(bytes)
       }}
    else
      false -> input_limit_exceeded()
      {:error, %Error{}} -> invalid_input(:invalid_capsule)
    end
  rescue
    _error -> invalid_input(:invalid_capsule)
  end

  defp capsule_input(_bytes, _maximum_input_bytes), do: invalid_input(:invalid_encoding)

  defp proposal_input(
         proposal_bytes,
         capsule_bytes,
         manifest_bytes,
         verification_bytes,
         report_bytes,
         state
       )
       when is_binary(proposal_bytes) and is_binary(capsule_bytes) and is_binary(manifest_bytes) and
              is_binary(verification_bytes) and is_binary(report_bytes) do
    total =
      Enum.sum(
        Enum.map(
          [proposal_bytes, capsule_bytes, manifest_bytes, verification_bytes, report_bytes],
          &byte_size/1
        )
      )

    with true <- total <= state.limits.max_input_bytes,
         [proposal_bytes, capsule_bytes, manifest_bytes, verification_bytes, report_bytes] <-
           Enum.map(
             [proposal_bytes, capsule_bytes, manifest_bytes, verification_bytes, report_bytes],
             &:binary.copy/1
           ),
         {:ok, capsule} <- Capsule.decode(capsule_bytes),
         {:ok, manifest} <- SentinelManifest.decode(manifest_bytes),
         {:ok, verification} <- VerificationRecord.decode(verification_bytes),
         {:ok, report} <- RepairReportManifest.decode(report_bytes),
         {:ok, proposal} <- DraftProposal.decode(proposal_bytes),
         {:ok, _proposal} <-
           DraftProposal.validate_with_evidence(proposal, capsule, manifest, verification, report),
         {:ok, canonical_capsule} <- Capsule.canonical_binary(capsule),
         {:ok, canonical_manifest} <- SentinelManifest.canonical_binary(manifest),
         {:ok, canonical_verification} <- VerificationRecord.canonical_binary(verification),
         {:ok, canonical_report} <- RepairReportManifest.canonical_binary(report),
         {:ok, canonical_proposal} <- DraftProposal.canonical_binary(proposal),
         true <-
           [
             canonical_capsule,
             canonical_manifest,
             canonical_verification,
             canonical_report,
             canonical_proposal
           ] == [capsule_bytes, manifest_bytes, verification_bytes, report_bytes, proposal_bytes],
         capsule_ref <- reference(capsule, capsule_bytes),
         proposal_ref <- reference(proposal, proposal_bytes),
         group <- group_id(capsule),
         true <- retained_capsule?(state.groups, group, capsule_ref) do
      {:ok,
       %{
         kind: :proposal,
         capsule: capsule_ref,
         proposal: proposal_ref,
         bytes: %{
           proposal: proposal_bytes,
           manifest: manifest_bytes,
           verification: verification_bytes,
           report: report_bytes
         },
         group: group,
         key: proposal_ref["canonical_sha256"],
         retain_bytes:
           byte_size(proposal_bytes) + byte_size(manifest_bytes) + byte_size(verification_bytes) +
             byte_size(report_bytes),
         evidence_bytes: total
       }}
    else
      false -> invalid_input(:unbound_or_noncanonical_proposal)
      {:error, %Error{}} -> invalid_input(:invalid_proposal_evidence)
    end
  rescue
    _error -> invalid_input(:invalid_proposal_evidence)
  end

  defp proposal_input(_proposal, _capsule, _manifest, _verification, _report, _state),
    do: invalid_input(:invalid_encoding)

  defp classify(state, input) do
    group = Map.get(state.groups, input.group)

    cond do
      retained?(group, input) ->
        receipt(state, input, "duplicate", "none", group_size(group))

      state.receipt_count >= state.limits.max_receipts ->
        receipt(state, input, "capacity_refused", "receipts", group_size(group))

      is_nil(group) and map_size(state.groups) >= state.limits.max_groups ->
        receipt(state, input, "capacity_refused", "groups", 0)

      group_size(group) >= state.limits.max_artifacts_per_group ->
        receipt(state, input, "capacity_refused", "artifacts_per_group", group_size(group))

      state.retained_bytes + input.retain_bytes > state.limits.max_retained_bytes ->
        receipt(state, input, "capacity_refused", "retained_bytes", group_size(group))

      true ->
        next = add_artifact(state, input)

        receipt(
          next,
          input,
          "new_evidence",
          "none",
          group_size(Map.fetch!(next.groups, input.group))
        )
    end
  end

  defp add_artifact(state, %{kind: :capsule} = input) do
    groups =
      Map.update(
        state.groups,
        input.group,
        %{capsules: %{input.key => input.bytes}, proposals: %{}},
        fn group -> %{group | capsules: Map.put(group.capsules, input.key, input.bytes)} end
      )

    %{
      state
      | groups: groups,
        receipt_count: state.receipt_count + 1,
        retained_bytes: state.retained_bytes + input.retain_bytes
    }
  end

  defp add_artifact(state, %{kind: :proposal} = input) do
    entry = Map.put(input.bytes, :capsule, input.capsule["canonical_sha256"])

    groups =
      Map.update!(state.groups, input.group, fn group ->
        %{group | proposals: Map.put(group.proposals, input.key, entry)}
      end)

    %{
      state
      | groups: groups,
        receipt_count: state.receipt_count + 1,
        retained_bytes: state.retained_bytes + input.retain_bytes
    }
  end

  defp retained?(nil, _input), do: false
  defp retained?(group, %{kind: :capsule, key: key}), do: Map.has_key?(group.capsules, key)
  defp retained?(group, %{kind: :proposal, key: key}), do: Map.has_key?(group.proposals, key)

  defp retained_capsule?(groups, group, ref),
    do: get_in(groups, [group, :capsules, ref["canonical_sha256"]]) != nil

  defp receipt(state, input, outcome, capacity, artifacts_in_group) do
    Receipt.new(
      outcome: outcome,
      capacity: capacity,
      group: input.group,
      artifacts: %{"capsule" => input.capsule, "proposal" => input.proposal},
      evidence_bytes: input.evidence_bytes,
      counts: %{
        "accepted_artifacts" => state.receipt_count,
        "artifacts_in_group" => artifacts_in_group,
        "groups" => map_size(state.groups),
        "retained_bytes" => state.retained_bytes
      }
    )
    |> case do
      {:ok, receipt} -> {:ok, state, receipt}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_groups(groups, limits) do
    Enum.reduce_while(groups, {:ok, 0, 0}, fn {group, contents}, {:ok, bytes, artifacts} ->
      with true <- detached_binary?(group),
           true <- digest_id?(group),
           true <-
             is_map(contents) and Map.keys(contents) |> Enum.sort() == [:capsules, :proposals],
           true <-
             is_map(contents.capsules) and is_map(contents.proposals) and
               map_size(contents.capsules) >= 1,
           true <- group_size(contents) <= limits.max_artifacts_per_group,
           {:ok, capsule_bytes, capsule_count} <-
             validate_capsules(group, contents.capsules, limits.max_input_bytes),
           {:ok, proposal_bytes, proposal_count} <-
             validate_proposals(group, contents.capsules, contents.proposals, limits) do
        {:cont,
         {:ok, bytes + capsule_bytes + proposal_bytes, artifacts + capsule_count + proposal_count}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp validate_capsules(group, capsules, maximum_input_bytes) do
    Enum.reduce_while(capsules, {:ok, 0, 0}, fn {digest, bytes}, {:ok, total, count} ->
      with true <- detached_binary?(digest),
           true <- detached_binary?(bytes),
           {:ok, capsule_input} <- capsule_input(bytes, maximum_input_bytes),
           true <- digest == capsule_input.key and group == capsule_input.group do
        {:cont, {:ok, total + byte_size(bytes), count + 1}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp validate_proposals(group, capsules, proposals, limits) do
    Enum.reduce_while(proposals, {:ok, 0, 0}, fn {digest, entry}, {:ok, total, count} ->
      with true <- detached_binary?(digest),
           true <-
             is_map(entry) and
               Map.keys(entry) |> Enum.sort() == [
                 :capsule,
                 :manifest,
                 :proposal,
                 :report,
                 :verification
               ],
           capsule_digest when is_binary(capsule_digest) <- entry.capsule,
           true <- detached_binary?(capsule_digest),
           capsule_bytes when is_binary(capsule_bytes) <- capsules[capsule_digest],
           true <-
             Enum.all?(
               [capsule_bytes, entry.proposal, entry.manifest, entry.verification, entry.report],
               &detached_binary?/1
             ),
           {:ok, input} <-
             proposal_input(
               entry.proposal,
               capsule_bytes,
               entry.manifest,
               entry.verification,
               entry.report,
               %__MODULE__{
                 limits: limits,
                 groups: %{group => %{capsules: capsules, proposals: %{}}},
                 receipt_count: 0,
                 retained_bytes: 0
               }
             ),
           true <- input.key == digest and input.group == group do
        bytes =
          Enum.sum(
            Enum.map(
              [entry.proposal, entry.manifest, entry.verification, entry.report],
              &byte_size/1
            )
          )

        {:cont, {:ok, total + bytes, count + 1}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp valid_limits?(limits) when is_map(limits) and map_size(limits) == map_size(@defaults) do
    limits.max_groups in 1..@maximum_groups and
      limits.max_artifacts_per_group in 1..@maximum_artifacts_per_group and
      limits.max_input_bytes in 1..@maximum_input_bytes and
      limits.max_retained_bytes in 1..@maximum_retained_bytes and
      limits.max_receipts in 1..@maximum_receipts
  end

  defp valid_limits?(_limits), do: false

  defp detached_binary?(value) when is_binary(value),
    do: :binary.referenced_byte_size(value) == byte_size(value)

  defp detached_binary?(_value), do: false
  defp group_size(nil), do: 0
  defp group_size(group), do: map_size(group.capsules) + map_size(group.proposals)

  defp group_id(capsule),
    do:
      "sha256:" <>
        Canonical.sha256(%{
          "schema" => "insider.dedup-group/v1",
          "finding" => capsule.finding["fingerprint"]
        })

  defp reference(artifact, bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => Canonical.sha256_binary(bytes),
      "id" => artifact.id,
      "schema" => artifact.schema
    }

  defp digest_id?("sha256:" <> digest), do: Input.digest?(digest)
  defp digest_id?(_value), do: false

  defp invalid_state(reason),
    do: {:error, Error.new(:invalid_dedup_state, "dedup state is invalid", %{reason: reason})}

  defp invalid_input(reason),
    do: {:error, Error.new(:invalid_dedup_input, "dedup input is invalid", %{reason: reason})}

  defp input_limit_exceeded,
    do: {:error, Error.new(:dedup_input_limit_exceeded, "dedup input exceeds its static limit")}
end
