defmodule Insider.Protocol.Error do
  @moduledoc """
  A typed protocol failure containing bounded, non-secret metadata.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}, retryable: false]

  @type code ::
          :invalid_request
          | :invalid_event
          | :invalid_identity
          | :invalid_artifact_reference
          | :invalid_capsule
          | :capsule_integrity_failed
          | :capsule_limit_exceeded
          | :invalid_provenance
          | :invalid_budget
          | :unsupported_protocol_version
          | :unsupported_operation
          | :unsupported_event_schema
          | :unsupported_capsule_schema
          | :unsupported_provenance_schema
          | :invalid_sentinel_manifest
          | :sentinel_manifest_integrity_failed
          | :sentinel_manifest_limit_exceeded
          | :unsupported_sentinel_manifest_schema
          | :invalid_scenario
          | :scenario_integrity_failed
          | :scenario_limit_exceeded
          | :unsupported_scenario_schema
          | :scenario_contract_mismatch
          | :invalid_sandbox_target
          | :sandbox_target_integrity_failed
          | :sandbox_target_limit_exceeded
          | :unsupported_sandbox_target_schema
          | :sandbox_provider_mismatch
          | :sandbox_body_mismatch
          | :invalid_confirmation_record
          | :invalid_confirmation_receipt
          | :confirmation_record_limit_exceeded
          | :unsupported_confirmation_record_schema
          | :confirmation_input_mismatch
          | :invalid_external_process_receipt
          | :external_process_receipt_limit_exceeded
          | :unsupported_external_process_receipt_schema
          | :external_process_failed
          | :invalid_regression
          | :regression_ineligible
          | :regression_limit_exceeded
          | :unsupported_regression_schema
          | :invalid_regression_runs
          | :invalid_minimization_record
          | :minimization_record_limit_exceeded
          | :unsupported_minimization_record_schema
          | :minimization_input_mismatch
          | :invalid_bisection_record
          | :bisection_record_limit_exceeded
          | :unsupported_bisection_record_schema
          | :bisection_input_mismatch
          | :invalid_verification_candidate
          | :verification_candidate_limit_exceeded
          | :unsupported_verification_candidate_schema
          | :invalid_verification_receipt
          | :verification_receipt_limit_exceeded
          | :unsupported_verification_receipt_schema
          | :invalid_verification_record
          | :verification_record_limit_exceeded
          | :unsupported_verification_record_schema
          | :verification_input_mismatch
          | :invalid_repair_report_manifest
          | :repair_report_integrity_failed
          | :repair_report_manifest_limit_exceeded
          | :unsupported_repair_report_manifest_schema
          | :invalid_repair_report_render
          | :repair_report_render_limit_exceeded
          | :invalid_draft_proposal
          | :draft_proposal_ineligible
          | :draft_proposal_integrity_failed
          | :draft_proposal_limit_exceeded
          | :unsupported_draft_proposal_schema
          | :invalid_source_ownership
          | :source_ownership_diff_invalid
          | :source_ownership_declaration_invalid
          | :source_ownership_integrity_failed
          | :source_ownership_limit_exceeded
          | :unsupported_source_ownership_schema
          | :invalid_dedup_state
          | :invalid_dedup_input
          | :dedup_input_limit_exceeded
          | :invalid_dedup_receipt
          | :dedup_receipt_limit_exceeded
          | :unsupported_dedup_receipt_schema
          | :invalid_coding_agent_handoff
          | :coding_agent_handoff_ineligible
          | :coding_agent_handoff_integrity_failed
          | :coding_agent_handoff_limit_exceeded
          | :unsupported_coding_agent_handoff_schema
          | :invalid_candidate_submission
          | :candidate_submission_integrity_failed
          | :candidate_submission_limit_exceeded
          | :unsupported_candidate_submission_schema
          | :invalid_draft_creation_request
          | :draft_creation_request_integrity_failed
          | :draft_creation_request_limit_exceeded
          | :unsupported_draft_creation_request_schema
          | :invalid_draft_creation_receipt
          | :draft_creation_receipt_integrity_failed
          | :draft_creation_receipt_limit_exceeded
          | :unsupported_draft_creation_receipt_schema
          | :invalid_draft_creation_configuration
          | :draft_creation_input_mismatch
          | :draft_creation_capacity_exceeded
          | :draft_creation_conflict
          | :invalid_observability_export
          | :observability_export_integrity_failed
          | :observability_export_limit_exceeded
          | :unsupported_observability_export_schema
          | :invalid_observability_mock_event
          | :observability_mock_event_integrity_failed
          | :observability_mock_event_limit_exceeded
          | :unsupported_observability_mock_event_schema
          | :unsupported_capability
          | :policy_denied
          | :redaction_failed
          | :deadline_exceeded
          | :operation_failed

  @codes [
    :invalid_request,
    :invalid_event,
    :invalid_identity,
    :invalid_artifact_reference,
    :invalid_capsule,
    :capsule_integrity_failed,
    :capsule_limit_exceeded,
    :invalid_provenance,
    :invalid_budget,
    :unsupported_protocol_version,
    :unsupported_operation,
    :unsupported_event_schema,
    :unsupported_capsule_schema,
    :unsupported_provenance_schema,
    :invalid_sentinel_manifest,
    :sentinel_manifest_integrity_failed,
    :sentinel_manifest_limit_exceeded,
    :unsupported_sentinel_manifest_schema,
    :invalid_scenario,
    :scenario_integrity_failed,
    :scenario_limit_exceeded,
    :unsupported_scenario_schema,
    :scenario_contract_mismatch,
    :invalid_sandbox_target,
    :sandbox_target_integrity_failed,
    :sandbox_target_limit_exceeded,
    :unsupported_sandbox_target_schema,
    :sandbox_provider_mismatch,
    :sandbox_body_mismatch,
    :invalid_confirmation_record,
    :invalid_confirmation_receipt,
    :confirmation_record_limit_exceeded,
    :unsupported_confirmation_record_schema,
    :confirmation_input_mismatch,
    :invalid_external_process_receipt,
    :external_process_receipt_limit_exceeded,
    :unsupported_external_process_receipt_schema,
    :external_process_failed,
    :invalid_regression,
    :regression_ineligible,
    :regression_limit_exceeded,
    :unsupported_regression_schema,
    :invalid_regression_runs,
    :invalid_minimization_record,
    :minimization_record_limit_exceeded,
    :unsupported_minimization_record_schema,
    :minimization_input_mismatch,
    :invalid_bisection_record,
    :bisection_record_limit_exceeded,
    :unsupported_bisection_record_schema,
    :bisection_input_mismatch,
    :invalid_verification_candidate,
    :verification_candidate_limit_exceeded,
    :unsupported_verification_candidate_schema,
    :invalid_verification_receipt,
    :verification_receipt_limit_exceeded,
    :unsupported_verification_receipt_schema,
    :invalid_verification_record,
    :verification_record_limit_exceeded,
    :unsupported_verification_record_schema,
    :verification_input_mismatch,
    :invalid_repair_report_manifest,
    :repair_report_integrity_failed,
    :repair_report_manifest_limit_exceeded,
    :unsupported_repair_report_manifest_schema,
    :invalid_repair_report_render,
    :repair_report_render_limit_exceeded,
    :invalid_draft_proposal,
    :draft_proposal_ineligible,
    :draft_proposal_integrity_failed,
    :draft_proposal_limit_exceeded,
    :unsupported_draft_proposal_schema,
    :invalid_source_ownership,
    :source_ownership_diff_invalid,
    :source_ownership_declaration_invalid,
    :source_ownership_integrity_failed,
    :source_ownership_limit_exceeded,
    :unsupported_source_ownership_schema,
    :invalid_dedup_state,
    :invalid_dedup_input,
    :dedup_input_limit_exceeded,
    :invalid_dedup_receipt,
    :dedup_receipt_limit_exceeded,
    :unsupported_dedup_receipt_schema,
    :invalid_coding_agent_handoff,
    :coding_agent_handoff_ineligible,
    :coding_agent_handoff_integrity_failed,
    :coding_agent_handoff_limit_exceeded,
    :unsupported_coding_agent_handoff_schema,
    :invalid_candidate_submission,
    :candidate_submission_integrity_failed,
    :candidate_submission_limit_exceeded,
    :unsupported_candidate_submission_schema,
    :invalid_draft_creation_request,
    :draft_creation_request_integrity_failed,
    :draft_creation_request_limit_exceeded,
    :unsupported_draft_creation_request_schema,
    :invalid_draft_creation_receipt,
    :draft_creation_receipt_integrity_failed,
    :draft_creation_receipt_limit_exceeded,
    :unsupported_draft_creation_receipt_schema,
    :invalid_draft_creation_configuration,
    :draft_creation_input_mismatch,
    :draft_creation_capacity_exceeded,
    :draft_creation_conflict,
    :invalid_observability_export,
    :observability_export_integrity_failed,
    :observability_export_limit_exceeded,
    :unsupported_observability_export_schema,
    :invalid_observability_mock_event,
    :observability_mock_event_integrity_failed,
    :observability_mock_event_limit_exceeded,
    :unsupported_observability_mock_event_schema,
    :unsupported_capability,
    :policy_denied,
    :redaction_failed,
    :deadline_exceeded,
    :operation_failed
  ]

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          details: map(),
          retryable: boolean()
        }

  @spec new(code(), String.t(), map(), keyword()) :: t()
  def new(code, message, details \\ %{}, options \\ [])
      when is_atom(code) and is_binary(message) and is_map(details) do
    retryable = Keyword.get(options, :retryable, false)

    error = %__MODULE__{
      code: code,
      message: message,
      details: details,
      retryable: retryable
    }

    unless valid?(error) do
      raise ArgumentError, "invalid protocol error"
    end

    error
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{code: code, message: message, details: details, retryable: retryable}) do
    code in @codes and is_binary(message) and byte_size(message) <= 512 and is_map(details) and
      is_boolean(retryable) and Insider.Protocol.Value.bounded_data?(details, 4_096)
  end

  def valid?(_value), do: false
end
