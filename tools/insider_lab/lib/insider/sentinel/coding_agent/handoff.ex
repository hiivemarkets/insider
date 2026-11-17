defmodule Insider.Sentinel.CodingAgent.Handoff do
  @moduledoc """
  A self-contained, bounded repair request derived from confirmed evidence.

  The handoff contains only canonical evidence and a fixed output contract. It
  grants no execution or repository authority and accepts no caller-authored
  instructions or causal claims. A valid handoff proves that the bound defect
  was reproduced twice; it says nothing about any future candidate repair.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation.Record
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.coding-agent-handoff/v1"
  @maximum_bytes 1_572_864
  @maximum_term_bytes 3_145_728
  @fields [:schema, :id, :kind, :controls, :request, :evidence, :integrity]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @controls %{
    "credentials" => "none",
    "deploy" => "prohibited",
    "merge" => "prohibited",
    "model_invocation" => "none",
    "network_effect" => "none",
    "provider_effect" => "none",
    "repository_mutation" => "none",
    "review_required" => true
  }
  @request %{
    "candidate_status" => "unverified",
    "objective" => "propose_candidate_repair",
    "output_schema" => "insider.verification-candidate/v1",
    "verification" => "required"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(capsule, manifest, regression, confirmation_runs) do
    with {:ok, evidence} <- evidence(capsule, manifest, regression, confirmation_runs) do
      body = %{
        "schema" => @schema,
        "kind" => "confirmed_regression_repair_request",
        "controls" => @controls,
        "request" => @request,
        "evidence" => evidence
      }

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = handoff) do
    wire = to_wire_map(handoff)

    with true <- Enum.sort(Map.keys(Map.from_struct(handoff))) == Enum.sort(@fields),
         true <- handoff.schema == @schema,
         true <- handoff.kind == "confirmed_regression_repair_request",
         true <- handoff.controls == @controls,
         true <- handoff.request == @request,
         {:ok, _evidence} <- validate_embedded_evidence(handoff.evidence),
         true <- bounded_term?(wire),
         true <- valid_integrity?(handoff.integrity),
         true <- handoff.id == "sha256:" <> handoff.integrity["content_digest"],
         true <- handoff.integrity["content_digest"] == Canonical.sha256(content(handoff)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, handoff}
    else
      _other -> invalid(:invalid_handoff)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes the handoff from the exact evidence graph before accepting it."
  @spec validate_with_evidence(term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(handoff, capsule, manifest, regression, confirmation_runs) do
    with {:ok, valid} <- validate(handoff),
         {:ok, expected} <- new(capsule, manifest, regression, confirmation_runs),
         true <- to_wire_map(valid) == to_wire_map(expected) do
      {:ok, valid}
    else
      {:error, %Error{code: :coding_agent_handoff_ineligible} = error} -> {:error, error}
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(handoff) do
    with {:ok, valid} <- validate(handoff), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value) do
    value
    |> Ingress.canonical_decode(@maximum_bytes, &decode_map/1)
    |> normalize_decode()
  end

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    case Map.fetch(wire, "schema") do
      {:ok, @schema} -> decode_current(wire)
      {:ok, schema} -> unsupported_schema(schema)
      :error -> unsupported_schema(nil)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = handoff),
    do: %{
      "schema" => handoff.schema,
      "id" => handoff.id,
      "kind" => handoff.kind,
      "controls" => handoff.controls,
      "request" => handoff.request,
      "evidence" => handoff.evidence,
      "integrity" => handoff.integrity
    }

  defp evidence(capsule, manifest, regression, confirmation_runs) do
    with {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, %{"status" => "ready"}} <- Manifest.readiness(manifest, capsule),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, scenario} <- Scenario.decode_map(regression.scenario),
         {:ok, scenario_descriptor} <- Scenario.descriptor(scenario),
         true <- manifest.prerequisites["scenario"] == scenario_descriptor,
         {:ok, source} <- Record.decode_map(regression.confirmed_record),
         {:ok, rebuilt} <- Regression.materialize(source, scenario),
         true <- Regression.to_wire_map(rebuilt) == Regression.to_wire_map(regression),
         :ok <- correlate(capsule, manifest, regression, source),
         {:ok, runs} <- valid_runs(confirmation_runs),
         {:ok, %{"status" => "failed"} = evaluation} <- Regression.classify(regression, runs) do
      {:ok,
       %{
         "capsule" => Capsule.to_wire_map(capsule),
         "confirmation_runs" => runs |> Enum.sort_by(& &1.id) |> Enum.map(&Record.to_wire_map/1),
         "evaluation" => evaluation,
         "regression" => Regression.to_wire_map(regression),
         "sentinel_manifest" => Manifest.to_wire_map(manifest)
       }}
    else
      _other -> ineligible(:evidence_graph_not_eligible)
    end
  end

  defp validate_embedded_evidence(
         %{
           "capsule" => capsule_wire,
           "confirmation_runs" => run_wires,
           "evaluation" => evaluation,
           "regression" => regression_wire,
           "sentinel_manifest" => manifest_wire
         } = embedded
       )
       when map_size(embedded) == 5 do
    with {:ok, capsule} <- Capsule.decode_map(capsule_wire),
         {:ok, manifest} <- Manifest.decode_map(manifest_wire),
         {:ok, regression} <- Regression.decode_map(regression_wire),
         {:ok, runs} <- decode_runs(run_wires),
         {:ok, rebuilt} <- evidence(capsule, manifest, regression, runs),
         true <- rebuilt["evaluation"] == evaluation,
         true <- rebuilt == embedded do
      {:ok, embedded}
    else
      _other -> invalid(:invalid_evidence_graph)
    end
  end

  defp validate_embedded_evidence(_value), do: invalid(:invalid_evidence_graph)

  defp valid_runs(runs) do
    if Insider.Protocol.Value.bounded_list?(runs, 2) do
      do_validate_runs(runs)
    else
      ineligible(:required_confirmation_runs)
    end
  end

  defp do_validate_runs(runs) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      case Record.validate(run) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        _other -> {:halt, ineligible(:invalid_confirmation_run)}
      end
    end)
  end

  defp decode_runs(wires) do
    if Insider.Protocol.Value.bounded_list?(wires, 2) do
      do_decode_runs(wires)
    else
      invalid(:invalid_confirmation_runs)
    end
  end

  defp do_decode_runs(wires) do
    Enum.reduce_while(wires, {:ok, []}, fn wire, {:ok, acc} ->
      case Record.decode_map(wire) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        _other -> {:halt, invalid(:invalid_confirmation_run)}
      end
    end)
  end

  defp correlate(capsule, manifest, regression, source) do
    expected = capsule.finding["fingerprint"]

    if source.capsule_id == capsule.id and source.manifest_id == manifest.id and
         source.scenario_id == regression.scenario["id"] and
         source.expected_fingerprint == expected and
         regression.expectation["incident_fingerprint"] == expected,
       do: :ok,
       else: ineligible(:evidence_graph_mismatch)
  end

  defp decode_current(wire) do
    if Enum.sort(Map.keys(wire)) == @wire_keys do
      wire
      |> then(fn value ->
        %__MODULE__{
          schema: value["schema"],
          id: value["id"],
          kind: value["kind"],
          controls: value["controls"],
          request: value["request"],
          evidence: value["evidence"],
          integrity: value["integrity"]
        }
      end)
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp content(handoff), do: handoff |> to_wire_map() |> Map.drop(["id", "integrity"])

  # Embedded artifacts have independently validated depth and width limits. A
  # generic recursive shape limit would reject the capsule's valid event tree,
  # so this outer envelope adds only a detached-term byte ceiling.
  defp bounded_term?(value) do
    :erlang.external_size(value) <= @maximum_term_bytes
  rescue
    _error -> false
  end

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = value),
    do: map_size(value) == 2 and digest?(digest)

  defp valid_integrity?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false
  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_coding_agent_handoff, "coding-agent handoff is invalid", %{
         reason: reason
       })}

  defp ineligible(reason),
    do:
      {:error,
       Error.new(
         :coding_agent_handoff_ineligible,
         "evidence cannot form a coding-agent handoff",
         %{
           reason: reason
         }
       )}

  defp integrity_failed,
    do:
      {:error,
       Error.new(:coding_agent_handoff_integrity_failed, "coding-agent handoff evidence differs")}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:coding_agent_handoff_limit_exceeded, "coding-agent handoff exceeds its limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_coding_agent_handoff_schema,
         "coding-agent handoff schema is unsupported",
         %{
           schema: Insider.Protocol.Value.summary(schema)
         }
       )}
end
