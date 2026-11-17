defmodule Insider.Sentinel.DraftCreation.Executor do
  @moduledoc """
  A fail-closed, bounded gate for draft-only provider effects.

  Provider and disclosure-authority modules come only from host configuration;
  wire identities select among that allowlist and never resolve modules. Calls
  are serialized so concurrent retries for one intent observe one cached local
  receipt. Durable exactly-once behavior remains the provider's responsibility.
  """

  use GenServer

  alias Insider.Protocol.Error
  alias Insider.Sentinel.CodingAgent.CandidateSubmission
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.DraftCreation.DisclosureAuthority
  alias Insider.Sentinel.DraftCreation.DisclosureDecision
  alias Insider.Sentinel.DraftCreation.Identity
  alias Insider.Sentinel.DraftCreation.Provider
  alias Insider.Sentinel.DraftCreation.Receipt
  alias Insider.Sentinel.DraftCreation.Request
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Sandbox.ProviderCall
  alias Insider.Sentinel.Verification.Candidate

  @default_timeout_ms 1_000
  @maximum_timeout_ms 10_000
  @default_max_receipts 32
  @maximum_receipts 1_024
  @default_max_pending 32
  @maximum_pending 1_024
  @maximum_admission_bytes 8_388_608
  @maximum_admission_options_bytes 16_384
  @maximum_modules 16
  @identity_timeout_ms 1_000
  @allowed_start_keys [
    :name,
    :providers,
    :disclosure_authorities,
    :effects_enabled,
    :max_receipts,
    :max_pending
  ]
  @allowed_create_keys [:provider, :disclosure_authority, :timeout_ms]
  @required_start_keys [:providers, :disclosure_authorities]
  @required_create_keys [:provider, :disclosure_authority]
  @evidence_keys [
    :capsule,
    :handoff,
    :manifest,
    :proposal,
    :repair_report,
    :submission,
    :verification
  ]

  @type evidence :: %{
          required(:capsule) => term(),
          required(:handoff) => term(),
          required(:manifest) => term(),
          required(:proposal) => term(),
          required(:repair_report) => term(),
          required(:submission) => term(),
          required(:verification) => term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, server_options} <- server_options(options) do
      GenServer.start_link(__MODULE__, options, server_options)
    end
  end

  @spec create(GenServer.server(), evidence(), keyword()) ::
          {:ok, Receipt.t()} | {:error, Error.t()}
  def create(server, evidence, options) do
    timeout_ms = requested_timeout(options)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with :ok <- validate_admission(evidence, options),
         {:ok, pid, admission} <- admission(server),
         :ok <- acquire_admission(admission) do
      GenServer.call(pid, {:create, evidence, options, deadline, admission}, timeout_ms + 250)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  catch
    :exit, {:timeout, _call} -> deadline_exceeded(:executor_call)
    :exit, _reason -> operation_failed(:executor_unavailable)
  end

  @impl true
  def init(options) do
    with {:ok, config} <- validate_start_options(options),
         {:ok, providers} <- configured_modules(config.providers, :provider),
         {:ok, authorities} <- configured_modules(config.authorities, :authority) do
      admission = :atomics.new(1, signed: false)
      Process.put({__MODULE__, :admission}, {admission, config.max_pending})

      {:ok,
       %{
         providers: providers,
         authorities: authorities,
         effects_enabled: config.effects_enabled,
         max_receipts: config.max_receipts,
         admission: {admission, config.max_pending},
         receipts: %{}
       }}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(
        {:create, evidence, options, deadline, admission},
        _from,
        %{admission: admission} = state
      ) do
    try do
      handle_create(evidence, options, deadline, state)
    after
      release_admission(admission)
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, invalid_configuration(:invalid_internal_request), state}

  defp handle_create(_evidence, _options, _deadline, %{effects_enabled: false} = state),
    do: {:reply, policy_denied(:effects_disabled), state}

  defp handle_create(evidence, options, deadline, state) do
    with true <- live_deadline?(deadline),
         {:ok, request_options} <- validate_create_options(options),
         {:ok, graph} <- validate_graph(evidence),
         {:ok, provider} <- resolve(state.providers, request_options.provider, :provider),
         {:ok, authority} <-
           resolve(state.authorities, request_options.disclosure_authority, :authority),
         {:ok, payload_reference} <-
           Request.payload_reference(
             graph.proposal,
             graph.submission,
             graph.handoff,
             request_options.provider
           ) do
      case Map.fetch(state.receipts, payload_reference["canonical_sha256"]) do
        {:ok, cached} ->
          cached_result(
            cached,
            payload_reference,
            request_options.disclosure_authority,
            state
          )

        :error ->
          create_uncached(
            graph,
            request_options,
            provider,
            authority,
            payload_reference,
            deadline,
            state
          )
      end
    else
      false -> {:reply, deadline_exceeded(:admission), state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  defp create_uncached(_graph, _options, _provider, _authority, _payload, _deadline, state)
       when map_size(state.receipts) >= state.max_receipts,
       do: {:reply, capacity_exceeded(), state}

  defp create_uncached(
         graph,
         options,
         provider,
         authority,
         payload_reference,
         deadline,
         state
       ) do
    with {:ok, decision_reference} <-
           authorize(authority, payload_reference, options.provider, deadline),
         {:ok, decision} <-
           DisclosureDecision.new(
             payload_reference,
             options.provider,
             options.disclosure_authority,
             decision_reference
           ),
         {:ok, request} <-
           Request.new(
             graph.proposal,
             graph.submission,
             graph.handoff,
             options.provider,
             decision
           ),
         {:ok, request} <-
           Request.validate_with(
             request,
             graph.proposal,
             graph.submission,
             graph.handoff,
             options.provider
           ) do
      {result, next_state} =
        invoke_provider(provider, request, payload_reference, deadline, state)

      {:reply, result, next_state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  defp validate_graph(%{} = evidence)
       when map_size(evidence) == length(@evidence_keys) do
    if Enum.sort(Map.keys(evidence)) == @evidence_keys do
      with {:ok, proposal} <-
             DraftProposal.validate_with_evidence(
               evidence.proposal,
               evidence.capsule,
               evidence.manifest,
               evidence.verification,
               evidence.repair_report
             ),
           {:ok, handoff} <- Handoff.validate(evidence.handoff),
           {:ok, submission} <- CandidateSubmission.validate(evidence.submission),
           {:ok, candidate} <- CandidateSubmission.candidate(submission),
           {:ok, expected_submission} <- CandidateSubmission.new(handoff, candidate),
           true <-
             CandidateSubmission.to_wire_map(submission) ==
               CandidateSubmission.to_wire_map(expected_submission),
           true <- proposal.evidence["candidate"] == Candidate.to_wire_map(candidate) do
        {:ok, %{proposal: proposal, handoff: handoff, submission: submission}}
      else
        _other -> input_mismatch()
      end
    else
      input_mismatch()
    end
  rescue
    _error -> input_mismatch()
  catch
    _kind, _reason -> input_mismatch()
  end

  defp validate_graph(_evidence), do: input_mismatch()

  defp authorize(authority, payload_reference, provider_identity, deadline) do
    outcome =
      ProviderCall.call(
        authority,
        :authorize,
        [payload_reference, provider_identity, deadline],
        deadline
      )

    case outcome do
      %{
        result: {:approved, decision_reference},
        termination: {:observed, :normal}
      } ->
        if DisclosureAuthority.decision_reference?(decision_reference),
          do: {:ok, decision_reference},
          else: operation_failed(:invalid_disclosure_authority_output)

      %{result: {:denied, reason}, termination: {:observed, :normal}} when is_atom(reason) ->
        policy_denied(:disclosure_denied)

      %{result: {:error, reason}}
      when reason in [:provider_timeout, :provider_deadline_expired] ->
        deadline_exceeded(:disclosure_authority)

      %{result: {:insider_provider_call, :not_started, :provider_deadline_expired}} ->
        deadline_exceeded(:disclosure_authority)

      _other ->
        operation_failed(:disclosure_authority_failed)
    end
  end

  defp invoke_provider(provider, request, payload_reference, deadline, state) do
    outcome =
      ProviderCall.call(
        provider,
        :create,
        [Request.to_wire_map(request), request.idempotency_key, deadline],
        deadline
      )

    receipt_result = provider_receipt(request, outcome)

    case receipt_result do
      {:ok, receipt} ->
        key = payload_reference["canonical_sha256"]

        entry = %{
          authority: request.disclosure_decision["authority"],
          payload_reference: payload_reference,
          receipt: receipt
        }

        {{:ok, receipt}, put_in(state, [:receipts, key], entry)}

      {:error, %Error{} = error} ->
        {{:error, error}, state}
    end
  end

  defp provider_receipt(request, %{
         result: {:ok, response},
         termination: {:observed, :normal}
       }) do
    case validate_provider_response(response, request) do
      {:ok, outcome, reference} -> Receipt.new(request, outcome, reference)
      :error -> Receipt.new(request, "provider_output_invalid", nil)
    end
  end

  defp provider_receipt(request, %{
         result: {:error, :rejected},
         termination: {:observed, :normal}
       }),
       do: Receipt.new(request, "provider_reported_rejected", nil)

  defp provider_receipt(_request, %{
         result: {:insider_provider_call, :not_started, :provider_deadline_expired}
       }),
       do: deadline_exceeded(:draft_provider)

  defp provider_receipt(_request, %{
         result: {:error, :provider_deadline_expired},
         termination: :not_started
       }),
       do: deadline_exceeded(:draft_provider)

  defp provider_receipt(request, %{result: {:error, reason}})
       when reason in [:provider_timeout, :provider_cancelled, :provider_failed],
       do: Receipt.new(request, "provider_outcome_unknown", nil)

  defp provider_receipt(request, %{
         result: {:error, reason},
         termination: {:observed, :normal}
       })
       when is_atom(reason),
       do: Receipt.new(request, "provider_outcome_unknown", nil)

  defp provider_receipt(request, _outcome),
    do: Receipt.new(request, "provider_output_invalid", nil)

  defp validate_provider_response(
         %{
           "draft" => true,
           "draft_reference" => reference,
           "idempotency_key" => idempotency_key,
           "intent_id" => intent_id,
           "outcome" => outcome,
           "review_required" => true
         } = response,
         request
       ) do
    if map_size(response) == 6 and Provider.response?(response) and
         idempotency_key == request.idempotency_key and intent_id == request.intent_id and
         outcome in ["created", "existing"] and is_binary(reference) and
         byte_size(reference) in 1..1_024 and String.valid?(reference) do
      {:ok, "provider_reported_" <> outcome, reference}
    else
      :error
    end
  end

  defp validate_provider_response(_response, _request), do: :error

  defp cached_result(cached, payload_reference, authority, state) do
    if cached.payload_reference == payload_reference and cached.authority == authority do
      {:reply, {:ok, cached.receipt}, state}
    else
      {:reply, conflict(), state}
    end
  end

  defp validate_start_options(options) do
    with true <- exact_keyword?(options, @allowed_start_keys, @required_start_keys),
         providers <- Keyword.fetch!(options, :providers),
         true <- is_list(providers),
         authorities <- Keyword.fetch!(options, :disclosure_authorities),
         true <- is_list(authorities),
         true <- length(providers) in 1..@maximum_modules,
         true <- length(authorities) in 1..@maximum_modules,
         effects_enabled when is_boolean(effects_enabled) <-
           Keyword.get(options, :effects_enabled, false),
         max_receipts when is_integer(max_receipts) and max_receipts in 1..@maximum_receipts <-
           Keyword.get(options, :max_receipts, @default_max_receipts),
         max_pending when is_integer(max_pending) and max_pending in 1..@maximum_pending <-
           Keyword.get(options, :max_pending, @default_max_pending),
         true <- valid_name?(Keyword.get(options, :name)) do
      {:ok,
       %{
         providers: providers,
         authorities: authorities,
         effects_enabled: effects_enabled,
         max_receipts: max_receipts,
         max_pending: max_pending
       }}
    else
      _other -> invalid_configuration(:invalid_options)
    end
  end

  defp validate_create_options(options) do
    with true <- exact_keyword?(options, @allowed_create_keys, @required_create_keys),
         provider <- Keyword.fetch!(options, :provider),
         true <- Identity.provider?(provider),
         authority <- Keyword.fetch!(options, :disclosure_authority),
         true <- Identity.disclosure_authority?(authority),
         timeout_ms when is_integer(timeout_ms) and timeout_ms in 1..@maximum_timeout_ms <-
           Keyword.get(options, :timeout_ms, @default_timeout_ms) do
      {:ok, %{provider: provider, disclosure_authority: authority, timeout_ms: timeout_ms}}
    else
      _other -> invalid_configuration(:invalid_request_options)
    end
  end

  defp configured_modules(modules, kind) do
    deadline = System.monotonic_time(:millisecond) + @identity_timeout_ms

    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, configured} ->
      case configured_module(module, kind, deadline) do
        {:ok, identity} ->
          key = identity_key(identity, kind)

          if Map.has_key?(configured, key),
            do: {:halt, invalid_configuration(:duplicate_identity)},
            else: {:cont, {:ok, Map.put(configured, key, module)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp configured_module(module, kind, deadline) when is_atom(module) do
    behaviour = if kind == :provider, do: Provider, else: DisclosureAuthority

    if Code.ensure_loaded?(module) and function_exported?(module, :identity, 0) and
         implements?(module, behaviour) do
      case ProviderCall.call(module, :identity, [], deadline) do
        %{result: identity, termination: {:observed, :normal}} ->
          case validate_identity(identity, kind) do
            {:ok, valid} -> {:ok, valid}
            {:error, %Error{}} -> invalid_configuration(:invalid_identity)
          end

        _other ->
          invalid_configuration(:identity_callback_failed)
      end
    else
      invalid_configuration(:invalid_module)
    end
  end

  defp configured_module(_module, _kind, _deadline),
    do: invalid_configuration(:invalid_module)

  defp implements?(module, behaviour) do
    attributes = module.module_info(:attributes)
    behaviour in (attributes |> Keyword.get_values(:behaviour) |> List.flatten())
  rescue
    _error -> false
  end

  defp validate_identity(identity, :provider), do: Identity.validate_provider(identity)

  defp validate_identity(identity, :authority),
    do: Identity.validate_disclosure_authority(identity)

  defp resolve(configured, identity, kind) do
    case Map.fetch(configured, identity_key(identity, kind)) do
      {:ok, module} -> {:ok, module}
      :error -> policy_denied(:identity_not_allowlisted)
    end
  end

  defp identity_key(identity, :provider),
    do: {identity["id"], identity["version"], identity["destination_fingerprint"]}

  defp identity_key(identity, :authority), do: {identity["id"], identity["version"]}

  defp exact_keyword?(options, allowed, required) do
    is_list(options) and Keyword.keyword?(options) and
      Keyword.keys(options) == Enum.uniq(Keyword.keys(options)) and
      Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
      Enum.all?(required, &Keyword.has_key?(options, &1))
  end

  defp valid_name?(nil), do: true
  defp valid_name?(name) when is_atom(name), do: true
  defp valid_name?({:global, _term}), do: true
  defp valid_name?({:via, module, _term}) when is_atom(module), do: true
  defp valid_name?(_name), do: false

  defp server_options(options) when is_list(options) do
    names = Keyword.get_values(options, :name)

    case names do
      [] ->
        {:ok, []}

      [name] ->
        if valid_name?(name), do: {:ok, [name: name]}, else: invalid_configuration(:invalid_name)

      _other ->
        invalid_configuration(:duplicate_name)
    end
  end

  defp server_options(_options), do: invalid_configuration(:invalid_options)

  defp requested_timeout(options) when is_list(options) do
    case Keyword.get(options, :timeout_ms, @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout in 1..@maximum_timeout_ms -> timeout
      _other -> @default_timeout_ms
    end
  end

  defp requested_timeout(_options), do: @default_timeout_ms

  defp admission(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} ->
            case List.keyfind(dictionary, {__MODULE__, :admission}, 0) do
              {{__MODULE__, :admission}, {counter, maximum}} ->
                {:ok, pid, {counter, maximum}}

              _other ->
                operation_failed(:executor_unavailable)
            end

          _other ->
            operation_failed(:executor_unavailable)
        end

      _other ->
        operation_failed(:executor_unavailable)
    end
  end

  defp acquire_admission({counter, maximum}) do
    if :atomics.add_get(counter, 1, 1) <= maximum do
      :ok
    else
      :atomics.sub(counter, 1, 1)
      capacity_exceeded()
    end
  rescue
    _error -> operation_failed(:executor_unavailable)
  end

  defp release_admission({counter, _maximum}) do
    :atomics.sub(counter, 1, 1)
    :ok
  rescue
    _error -> :ok
  end

  defp admissible_evidence?(evidence) do
    is_map(evidence) and not is_struct(evidence) and
      :erlang.external_size(evidence) <= @maximum_admission_bytes
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp validate_admission(evidence, options) do
    cond do
      not admissible_evidence?(evidence) ->
        input_mismatch()

      not admissible_options?(options) ->
        invalid_configuration(:request_options_exceed_admission_limit)

      true ->
        :ok
    end
  end

  defp admissible_options?(options) do
    is_list(options) and
      :erlang.external_size(options) <= @maximum_admission_options_bytes
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp live_deadline?(deadline),
    do: is_integer(deadline) and deadline > System.monotonic_time(:millisecond)

  defp invalid_configuration(reason),
    do:
      {:error,
       Error.new(
         :invalid_draft_creation_configuration,
         "draft-creation configuration is invalid",
         %{
           reason: reason
         }
       )}

  defp input_mismatch,
    do: {:error, Error.new(:draft_creation_input_mismatch, "draft-creation evidence differs")}

  defp capacity_exceeded,
    do:
      {:error,
       Error.new(
         :draft_creation_capacity_exceeded,
         "draft-creation receipt capacity is exhausted"
       )}

  defp conflict,
    do: {:error, Error.new(:draft_creation_conflict, "draft-creation intent conflicts")}

  defp policy_denied(reason),
    do: {:error, Error.new(:policy_denied, "draft creation is denied", %{reason: reason})}

  defp deadline_exceeded(stage),
    do:
      {:error,
       Error.new(:deadline_exceeded, "draft-creation deadline expired", %{stage: stage},
         retryable: true
       )}

  defp operation_failed(reason),
    do:
      {:error, Error.new(:operation_failed, "draft-creation operation failed", %{reason: reason})}
end
