defmodule Insider.Load.Failure do
  @moduledoc "Canonical bounded envelope for a harness failure that occurs before a report exists."

  alias Insider.Event.Canonical

  @schema "insider.load-failure/v1"
  @reasons ~w(artifact_contract_mismatch artifact_limit_exceeded artifact_write_failed dirty_revision internal_failure invalid_options invalid_profile invalid_report load_run_failed revision_unavailable)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, :invalid_failure}
  def canonical_binary(reason) when is_atom(reason) do
    normalized = reason |> Atom.to_string() |> normalize_reason()

    body = %{
      "schema" => @schema,
      "outcome" => "infrastructure_failed",
      "reason" => normalized,
      "production_capacity" => false,
      "budget_evaluation" => "not_approved"
    }

    digest = Canonical.sha256(body)

    envelope =
      Map.merge(body, %{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })

    {:ok, Canonical.encode(envelope)}
  rescue
    _error -> {:error, :invalid_failure}
  end

  def canonical_binary(_reason), do: {:error, :invalid_failure}

  @spec decode(binary()) :: {:ok, map()} | {:error, :invalid_failure}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= 4_096 do
    with {:ok, envelope} <- Jason.decode(bytes),
         true <- Canonical.encode(envelope) == bytes,
         true <- exact_envelope?(envelope),
         content <- Map.drop(envelope, ["id", "integrity"]),
         digest <- Canonical.sha256(content),
         true <- envelope["id"] == "sha256:" <> digest,
         true <-
           envelope["integrity"] == %{
             "algorithm" => "sha256",
             "content_digest" => digest
           } do
      {:ok, envelope}
    else
      _other -> {:error, :invalid_failure}
    end
  rescue
    _error -> {:error, :invalid_failure}
  end

  def decode(_bytes), do: {:error, :invalid_failure}

  defp exact_envelope?(envelope) when is_map(envelope) do
    Enum.sort(Map.keys(envelope)) ==
      ~w(budget_evaluation id integrity outcome production_capacity reason schema) and
      envelope["schema"] == @schema and envelope["outcome"] == "infrastructure_failed" and
      envelope["reason"] in @reasons and envelope["production_capacity"] == false and
      envelope["budget_evaluation"] == "not_approved"
  end

  defp exact_envelope?(_envelope), do: false
  defp normalize_reason(reason) when reason in @reasons, do: reason
  defp normalize_reason(_reason), do: "internal_failure"
end
