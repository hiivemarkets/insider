defmodule Insider.Sentinel.Verification do
  @moduledoc "Runs bounded live failing-before and passing-after verification on disposable targets."

  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Manifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Sandbox
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Ingress
  alias Insider.Sentinel.Verification.Record

  @option_keys [:request, :context, :confirmation_body, :verification_body, :repair_oracle]

  @spec run(Supervisor.supervisor(), term(), term(), term(), term(), term(), keyword()) ::
          {:ok, Record.t()} | {:error, Error.t()}
  def run(executor, regression, manifest, capsule, target, candidate, options) do
    with :ok <- valid_options(options),
         {:ok, regression} <- Regression.validate(regression),
         {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, manifest} <- Manifest.validate_with_capsule(manifest, capsule),
         {:ok, target} <- Target.validate(target),
         {:ok, candidate} <- Candidate.validate(candidate),
         {:ok, scenario} <- Scenario.decode_map(regression.scenario),
         :ok <- correlated(regression, manifest, capsule, target, scenario),
         %Request{} = request <- Keyword.fetch!(options, :request),
         %Context{} = context <- Keyword.fetch!(options, :context),
         true <- Request.valid?(request),
         true <- Context.valid?(context) do
      observer = regression.expectation["observer"]
      confirmation_body = Keyword.fetch!(options, :confirmation_body)
      oracle = Keyword.fetch!(options, :repair_oracle)

      before =
        for _attempt <- 1..2 do
          case Confirmation.run(executor, manifest, capsule, scenario, target,
                 request: request,
                 context: context,
                 body: confirmation_body,
                 observer: observer,
                 repair_oracle: nil
               ) do
            {:ok, %ConfirmationRecord{} = record} -> record
            _error -> nil
          end
        end

      after_attempts =
        if failed_before?(regression, before) do
          for _attempt <- 1..2 do
            run_after(executor, regression, scenario, target, candidate, oracle, options)
          end
        else
          [not_run_attempt(), not_run_attempt()]
        end

      counts =
        case Executor.counts(executor) do
          {:ok, counts} -> counts
          _ -> %{active: 1, quarantined: 1}
        end

      Record.new(regression, candidate, oracle, before, after_attempts, counts)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> mismatch()
    end
  rescue
    _error -> mismatch()
  catch
    _kind, _reason -> mismatch()
  end

  defp run_after(executor, regression, scenario, target, candidate, oracle, options) do
    input = %{
      "candidate" => Candidate.to_wire_map(candidate),
      "expected_fingerprint" => regression.expectation["incident_fingerprint"],
      "observer" => regression.expectation["observer"],
      "oracle" => oracle,
      "regression_id" => regression.id,
      "scenario" => Scenario.to_wire_map(scenario)
    }

    result =
      Sandbox.run(executor, target,
        request: Keyword.fetch!(options, :request),
        context: Keyword.fetch!(options, :context),
        cleanup_timeout_ms: scenario.limits["cleanup_timeout_ms"],
        body:
          {Keyword.fetch!(options, :verification_body), input,
           scenario.limits["cleanup_timeout_ms"]}
      )

    case result do
      %Insider.Protocol.Result{} = result -> attempt(result)
      _ -> not_run_attempt()
    end
  end

  defp attempt(result) do
    %{
      "cleanup" => stringify_cleanup(result.cleanup),
      "owner_fingerprint" => get_in(result.value || %{}, ["owner_fingerprint"]),
      "receipt" => get_in(result.value || %{}, ["body_receipt"]),
      "status" => operational_status(result.status),
      "target_fingerprint" => result.target_fingerprint,
      "uncertainty" => result.uncertainty
    }
  end

  defp not_run_attempt do
    %{
      "cleanup" => %{
        "release" => "not_attempted",
        "remaining_count" => 0,
        "remaining_fingerprint" => nil,
        "status" => "unknown"
      },
      "owner_fingerprint" => nil,
      "receipt" => nil,
      "status" => "error",
      "target_fingerprint" => nil,
      "uncertainty" => ["after run not executed"]
    }
  end

  defp stringify_cleanup(cleanup),
    do: %{
      "release" => cleanup |> Map.get(:release, :not_attempted) |> Atom.to_string(),
      "remaining_count" => Map.get(cleanup, :remaining_count, 0),
      "remaining_fingerprint" => Map.get(cleanup, :remaining_fingerprint),
      "status" => cleanup |> Map.get(:status, :unknown) |> Atom.to_string()
    }

  defp operational_status(:ok), do: "completed"
  defp operational_status(status), do: Atom.to_string(status)

  defp failed_before?(regression, [%ConfirmationRecord{} = first, %ConfirmationRecord{} = second]) do
    match?({:ok, %{"status" => "failed"}}, Regression.classify(regression, [first, second]))
  end

  defp failed_before?(_regression, _before), do: false

  defp correlated(regression, manifest, capsule, target, scenario) do
    source = regression.confirmed_record

    if source["manifest_id"] == manifest.id and source["capsule_id"] == capsule.id and
         source["scenario_id"] == scenario.id and
         source["observed_target_fingerprint"] == Target.target_fingerprint(target),
       do: :ok,
       else: mismatch()
  end

  defp valid_options(options) do
    with true <- Insider.Protocol.Value.bounded_list?(options, length(@option_keys)),
         true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- Enum.sort(keys) == Enum.sort(@option_keys),
         true <- is_atom(Keyword.get(options, :confirmation_body)),
         true <- is_atom(Keyword.get(options, :verification_body)),
         true <- valid_identity?(Keyword.get(options, :repair_oracle)) do
      :ok
    else
      _ -> mismatch()
    end
  end

  defp valid_identity?(value), do: Ingress.identity?(value)

  defp mismatch,
    do: {:error, Error.new(:verification_input_mismatch, "verification inputs do not match")}
end
