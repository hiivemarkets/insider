defmodule Insider.Sentinel.DraftCreationExecutorTest do
  # The provider fixtures use one process-independent state cell because their
  # callbacks execute in isolated processes. Serial execution keeps those
  # deliberately global observations attributable to one test.
  use ExUnit.Case, async: false

  alias Insider.Contract
  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request, as: ProtocolRequest
  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.CodingAgent.CandidateSubmission
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.Confirmation
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.DraftCreation.DisclosureDecision
  alias Insider.Sentinel.DraftCreation.Executor, as: DraftExecutor
  alias Insider.Sentinel.DraftCreation.Receipt
  alias Insider.Sentinel.DraftCreation.Request
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.RepairReport.Manifest, as: RepairManifest
  alias Insider.Sentinel.Sandbox.Executor, as: SandboxExecutor
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.Sentinel.Verification
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.TestSupport.ConfirmationBodyMatching
  alias Insider.TestSupport.ConfirmationContract
  alias Insider.TestSupport.DraftCreationProvider, as: Provider
  alias Insider.TestSupport.DraftCreationProvider.Alternate, as: AlternateProvider
  alias Insider.TestSupport.DraftCreationProvider.AlternateAuthority
  alias Insider.TestSupport.DraftCreationProvider.DisclosureAuthority, as: Authority
  alias Insider.TestSupport.DraftCreationProvider.Duplicate, as: DuplicateProvider
  alias Insider.TestSupport.DraftCreationProvider.DuplicateAuthority
  alias Insider.TestSupport.DraftCreationProvider.InvalidIdentity
  alias Insider.TestSupport.VerificationBody
  alias Insider.TestSupport.VerificationBodySuccess
  alias Insider.TestSupport.VerificationProvider

  @observer %{"id" => "test.confirmation-observer", "version" => 1}
  @oracle %{"id" => "test.repair-oracle", "version" => 1}
  @concurrent_call_timeout_ms 5_000
  @callback_outcome_timeout_ms 2_000

  setup_all do
    for module <- [
          Provider,
          Authority,
          AlternateProvider,
          AlternateAuthority,
          DuplicateProvider,
          DuplicateAuthority,
          InvalidIdentity
        ] do
      {:module, ^module} = Code.ensure_loaded(module)
    end

    graph = graph!("base")
    other = graph!("other")
    %{graph: graph, other: other}
  end

  setup do
    Provider.reset()
    on_exit(&Provider.reset/0)
    :ok
  end

  test "effects are disabled by default before either callback", %{graph: graph} do
    executor = executor!(effects_enabled: false)

    assert {:error, %Error{code: :policy_denied, details: %{reason: :effects_disabled}}} =
             create(executor, graph)

    assert Provider.authority_calls() == []
    assert Provider.provider_calls() == []
  end

  test "an exact approval creates a canonical provider-reported draft receipt", %{graph: graph} do
    executor = executor!()
    assert {:ok, receipt} = create(executor, graph)

    assert receipt.outcome == "provider_reported_created"

    assert receipt.draft == %{
             "provider_reported" => true,
             "reference" => "draft://test/42",
             "state" => "created"
           }

    assert receipt.controls == %{
             "deploy" => "prohibited",
             "draft" => true,
             "merge" => "prohibited",
             "review_required" => true
           }

    assert receipt.trust["remote_state"] == "not_independently_verified"
    assert receipt.trust["exactly_once"] == "requires_provider_native_idempotency"

    assert [{:authority, payload_reference, provider_identity}] = Provider.authority_calls()
    assert provider_identity == Provider.identity()
    assert payload_reference["schema"] == "insider.draft-creation-payload/v1"

    assert [{:provider, request_wire, idempotency_key}] = Provider.provider_calls()
    assert request_wire["idempotency_key"] == idempotency_key
    assert request_wire["provider"] == Provider.identity()
    assert request_wire["disclosure_decision"]["payload"] == payload_reference

    assert {:ok, request} = Request.decode_map(request_wire)
    assert {:ok, request_bytes} = Request.canonical_binary(request)
    assert {:ok, ^request} = Request.decode(request_bytes)
    assert {:ok, receipt_bytes} = Receipt.canonical_binary(receipt)
    assert {:ok, ^receipt} = Receipt.decode(receipt_bytes)
    assert {:ok, ^receipt} = Receipt.validate_with(receipt, request)
  end

  test "provider, destination, and authority identities must be host-allowlisted", %{graph: graph} do
    executor = executor!()

    unlisted_destination = %{
      Provider.identity()
      | "destination_fingerprint" => String.duplicate("b", 64)
    }

    for options <- [
          [provider: AlternateProvider.identity(), disclosure_authority: Authority.identity()],
          [provider: unlisted_destination, disclosure_authority: Authority.identity()],
          [provider: Provider.identity(), disclosure_authority: AlternateAuthority.identity()]
        ] do
      assert {:error, %Error{code: :policy_denied, details: %{reason: :identity_not_allowlisted}}} =
               DraftExecutor.create(executor, evidence(graph), options)
    end

    assert Provider.authority_calls() == []
    assert Provider.provider_calls() == []
  end

  test "cross-graph and candidate substitutions fail before callbacks", %{
    graph: graph,
    other: other
  } do
    executor = executor!()
    cross_graph = %{evidence(graph) | capsule: other.capsule}

    assert {:error, %Error{code: :draft_creation_input_mismatch}} =
             DraftExecutor.create(executor, cross_graph, create_options())

    {:ok, substituted_candidate} = Candidate.new("different candidate", "opaque/v1")
    {:ok, substituted_submission} = CandidateSubmission.new(graph.handoff, substituted_candidate)
    substituted = %{evidence(graph) | submission: substituted_submission}

    assert {:error, %Error{code: :draft_creation_input_mismatch}} =
             DraftExecutor.create(executor, substituted, create_options())

    assert Provider.authority_calls() == []
    assert Provider.provider_calls() == []
  end

  test "denied, timed out, invalid, and failed disclosure decisions prevent provider calls", %{
    graph: graph
  } do
    for {mode, expected_code} <- [
          denied: :policy_denied,
          timeout: :deadline_exceeded,
          invalid: :operation_failed,
          crash: :operation_failed
        ] do
      Provider.reset()
      Provider.set_authority_mode(mode)
      executor = executor!()

      assert {:error, %Error{code: ^expected_code}} =
               create(executor, graph, timeout_ms: @callback_outcome_timeout_ms)

      assert length(Provider.authority_calls()) == 1
      assert Provider.provider_calls() == []
    end
  end

  test "sequential identical calls invoke authority and provider once and reuse exact receipt", %{
    graph: graph
  } do
    executor = executor!()
    assert {:ok, first} = create(executor, graph)
    assert {:ok, second} = create(executor, graph)
    assert first == second
    assert Receipt.to_wire_map(first) == Receipt.to_wire_map(second)
    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "a different authority for the same intent is a visible conflict", %{graph: graph} do
    executor = executor!(disclosure_authorities: [Authority, AlternateAuthority])
    assert {:ok, _receipt} = create(executor, graph)

    assert {:error, %Error{code: :draft_creation_conflict}} =
             create(executor, graph, disclosure_authority: AlternateAuthority.identity())

    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "concurrent identical calls serialize to one provider effect", %{graph: graph} do
    executor = executor!()

    results =
      1..12
      |> Task.async_stream(
        fn _index ->
          create(executor, graph, timeout_ms: @concurrent_call_timeout_ms)
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: @concurrent_call_timeout_ms + 1_000
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> Receipt.to_wire_map(receipt) end)

    assert length(Enum.uniq(results)) == 1
    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "queue delay consumes the caller deadline and cannot cause a late provider effect", %{
    graph: graph,
    other: other
  } do
    executor = executor!()
    Provider.set_provider_mode({:block, self()})

    first = Task.async(fn -> create(executor, graph, timeout_ms: 1_000) end)
    assert_receive {:draft_provider_blocked, blocked_provider}, 1_000

    second = Task.async(fn -> create(executor, other, timeout_ms: 25) end)

    assert {:error, %Error{code: :deadline_exceeded, details: %{stage: :executor_call}}} =
             Task.await(second, 500)

    Provider.set_provider_mode(:created)
    send(blocked_provider, :release_draft_provider)
    assert {:ok, _receipt} = Task.await(first, 1_000)

    # This request is handled after the already-queued second call, proving the
    # executor had a chance to reject it before this assertion is evaluated.
    :sys.get_state(executor)
    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "renewed disclosure approval does not change intent or idempotency", %{graph: graph} do
    assert {:ok, payload_reference} =
             Request.payload_reference(
               graph.proposal,
               graph.submission,
               graph.handoff,
               Provider.identity()
             )

    assert {:ok, first_decision} =
             DisclosureDecision.new(
               payload_reference,
               Provider.identity(),
               Authority.identity(),
               "policy-decision-one"
             )

    assert {:ok, second_decision} =
             DisclosureDecision.new(
               payload_reference,
               Provider.identity(),
               Authority.identity(),
               "policy-decision-two"
             )

    assert {:ok, first} =
             Request.new(
               graph.proposal,
               graph.submission,
               graph.handoff,
               Provider.identity(),
               first_decision
             )

    assert {:ok, second} =
             Request.new(
               graph.proposal,
               graph.submission,
               graph.handoff,
               Provider.identity(),
               second_decision
             )

    assert first.intent_id == second.intent_id
    assert first.idempotency_key == second.idempotency_key
    refute first.id == second.id
  end

  test "only exact created and existing provider responses become success receipts", %{
    graph: graph
  } do
    for {mode, outcome, state} <- [
          {:created, "provider_reported_created", "created"},
          {:existing, "provider_reported_existing", "existing"}
        ] do
      Provider.reset()
      Provider.set_provider_mode(mode)
      executor = executor!()

      assert {:ok, receipt} = create(executor, graph)
      assert receipt.outcome == outcome
      assert receipt.draft["state"] == state
      assert receipt.draft["provider_reported"]
    end

    for mode <- [:malformed, :wrong_key, :wrong_intent, :not_draft, :review_optional] do
      Provider.reset()
      Provider.set_provider_mode(mode)
      executor = executor!()

      assert {:ok, receipt} = create(executor, graph)
      assert receipt.outcome == "provider_output_invalid"
      refute receipt.draft["provider_reported"]
      assert receipt.draft["reference"] == nil
    end
  end

  test "provider timeout, crash, malformed output, and rejection are cached without success claims",
       %{
         graph: graph
       } do
    for {mode, outcome} <- [
          {:timeout, "provider_outcome_unknown"},
          {:crash, "provider_outcome_unknown"},
          {:rate_limited, "provider_outcome_unknown"},
          {:malformed, "provider_output_invalid"},
          {:rejected, "provider_reported_rejected"}
        ] do
      Provider.reset()
      Provider.set_provider_mode(mode)
      executor = executor!()

      assert {:ok, first} =
               create(executor, graph, timeout_ms: @callback_outcome_timeout_ms)

      assert {:ok, second} =
               create(executor, graph, timeout_ms: @callback_outcome_timeout_ms)

      assert first == second
      assert first.outcome == outcome
      refute first.draft["provider_reported"]
      assert first.draft["reference"] == nil
      assert length(Provider.authority_calls()) == 1
      assert length(Provider.provider_calls()) == 1
    end
  end

  test "pending admission is bounded before evidence enters the executor mailbox", %{graph: graph} do
    executor = executor!(max_pending: 1)
    Provider.set_provider_mode({:block, self()})

    first = Task.async(fn -> create(executor, graph, timeout_ms: 1_000) end)
    assert_receive {:draft_provider_blocked, blocked_provider}, 1_000

    assert {:error, %Error{code: :draft_creation_capacity_exceeded}} =
             create(executor, graph, timeout_ms: 1_000)

    send(blocked_provider, :release_draft_provider)
    assert {:ok, _receipt} = Task.await(first, 1_000)
    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "request and receipt ingress reject malformed and substituted evidence", %{graph: graph} do
    request = request!(graph, "policy-decision-original")
    {:ok, receipt} = Receipt.new(request, "provider_reported_created", "draft://test/42")
    {:ok, request_bytes} = Request.canonical_binary(request)
    {:ok, receipt_bytes} = Receipt.canonical_binary(receipt)
    unknown = "hostile_draft_creation_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, %Error{code: :invalid_draft_creation_request}} =
             request |> Request.to_wire_map() |> Map.put(unknown, true) |> Request.decode_map()

    assert {:error, %Error{code: :invalid_draft_creation_receipt}} =
             receipt |> Receipt.to_wire_map() |> Map.put(unknown, true) |> Receipt.decode_map()

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, %Error{code: :invalid_draft_creation_request}} =
             Request.decode(request_bytes <> "\n")

    assert {:error, %Error{code: :invalid_draft_creation_receipt}} =
             Receipt.decode(receipt_bytes <> "\n")

    assert {:error, %Error{code: :draft_creation_request_limit_exceeded}} =
             Request.decode(String.duplicate("x", 262_145))

    assert {:error, %Error{code: :draft_creation_receipt_limit_exceeded}} =
             Receipt.decode(String.duplicate("x", 16_385))

    renewed = request!(graph, "policy-decision-renewed")

    assert {:error, %Error{code: :draft_creation_receipt_integrity_failed}} =
             Receipt.validate_with(receipt, renewed)
  end

  test "capacity rejects a second intent before disclosure or provider callbacks", %{
    graph: graph,
    other: other
  } do
    executor = executor!(max_receipts: 1)
    assert {:ok, _receipt} = create(executor, graph)

    assert {:error, %Error{code: :draft_creation_capacity_exceeded}} =
             create(executor, other)

    assert length(Provider.authority_calls()) == 1
    assert length(Provider.provider_calls()) == 1
  end

  test "the request and provider contract expose draft review but no merge or deploy", %{
    graph: graph
  } do
    executor = executor!()
    assert {:ok, _receipt} = create(executor, graph)
    [{:provider, request, _key}] = Provider.provider_calls()

    assert request["controls"]["draft"]
    assert request["controls"]["review_required"]
    assert request["controls"]["merge"] == "prohibited"
    assert request["controls"]["deploy"] == "prohibited"
    assert request["controls"]["credentials"] == "none"
    refute function_exported?(DraftExecutor, :merge, 2)
    refute function_exported?(DraftExecutor, :deploy, 2)
    refute function_exported?(Provider, :merge, 2)
    refute function_exported?(Provider, :deploy, 2)
  end

  test "invalid modules and duplicate identities fail executor startup" do
    Process.flag(:trap_exit, true)

    for options <- [
          [providers: [String], disclosure_authorities: [Authority]],
          [providers: [InvalidIdentity], disclosure_authorities: [Authority]],
          [providers: [Provider, DuplicateProvider], disclosure_authorities: [Authority]],
          [providers: [Provider], disclosure_authorities: [Authority, DuplicateAuthority]],
          [providers: [], disclosure_authorities: [Authority]],
          [providers: [Provider], disclosure_authorities: []]
        ] do
      assert {:error, %Error{code: :invalid_draft_creation_configuration}} =
               DraftExecutor.start_link(options)
    end
  end

  defp executor!(options \\ []) do
    child =
      Supervisor.child_spec(
        {DraftExecutor,
         [
           providers: [Provider],
           effects_enabled: Keyword.get(options, :effects_enabled, true),
           max_receipts: Keyword.get(options, :max_receipts, 32),
           max_pending: Keyword.get(options, :max_pending, 32),
           disclosure_authorities: Keyword.get(options, :disclosure_authorities, [Authority])
         ]},
        id: make_ref()
      )

    start_supervised!(child)
  end

  defp create(executor, graph, options \\ []) do
    DraftExecutor.create(
      executor,
      evidence(graph),
      Keyword.merge(create_options(), options)
    )
  end

  defp create_options,
    do: [provider: Provider.identity(), disclosure_authority: Authority.identity()]

  defp request!(graph, decision_reference) do
    {:ok, payload_reference} =
      Request.payload_reference(
        graph.proposal,
        graph.submission,
        graph.handoff,
        Provider.identity()
      )

    {:ok, decision} =
      DisclosureDecision.new(
        payload_reference,
        Provider.identity(),
        Authority.identity(),
        decision_reference
      )

    {:ok, request} =
      Request.new(graph.proposal, graph.submission, graph.handoff, Provider.identity(), decision)

    request
  end

  defp evidence(graph),
    do: %{
      capsule: graph.capsule,
      handoff: graph.handoff,
      manifest: graph.manifest,
      proposal: graph.proposal,
      repair_report: graph.repair_report,
      submission: graph.submission,
      verification: graph.verification
    }

  defp graph!(suffix) do
    sandbox =
      SandboxExecutor.start_link(
        name: nil,
        providers: [VerificationProvider],
        bodies: [ConfirmationBodyMatching, VerificationBodySuccess]
      )
      |> elem(1)

    {regression, manifest, capsule, target} = verification_inputs!(sandbox, suffix)
    candidate = candidate!(suffix)
    {request, context} = authority!(target, suffix)

    {:ok, verification} =
      Verification.run(sandbox, regression, manifest, capsule, target, candidate,
        request: request,
        context: context,
        confirmation_body: ConfirmationBodyMatching,
        verification_body: VerificationBodySuccess,
        repair_oracle: @oracle
      )

    Supervisor.stop(sandbox)
    VerificationBody.reset(candidate.id)

    {:ok, repair_report} = RepairManifest.new(capsule, manifest, verification)
    {:ok, proposal} = DraftProposal.new(capsule, manifest, verification, repair_report)
    {:ok, regression} = Regression.decode_map(verification.regression)
    {:ok, candidate} = Candidate.decode_map(verification.candidate)

    before_records =
      Enum.map(verification.before_records, fn wire ->
        {:ok, record} = ConfirmationRecord.decode_map(wire)
        record
      end)

    {:ok, handoff} = Handoff.new(capsule, manifest, regression, before_records)
    {:ok, submission} = CandidateSubmission.new(handoff, candidate)

    %{
      capsule: capsule,
      handoff: handoff,
      manifest: manifest,
      proposal: proposal,
      repair_report: repair_report,
      submission: submission,
      verification: verification
    }
  end

  defp verification_inputs!(executor, suffix) do
    capsule = capsule!(suffix)
    expected = capsule.finding["fingerprint"]
    {:ok, contract} = Contract.describe(ConfirmationContract)

    {:ok, scenario} =
      Scenario.new(contract,
        seed: "draft-creation-#{suffix}",
        reset: %{"name" => "fixture", "arguments" => []},
        steps: [
          %{
            "id" => "observe",
            "type" => "observation",
            "name" => "echo",
            "arguments" => ["baseline"]
          }
        ],
        expected_incident_fingerprints: [expected],
        limits: %{"cleanup_timeout_ms" => 500, "max_duration_ms" => 2_000}
      )

    {:ok, descriptor} = Scenario.descriptor(scenario)
    {:ok, manifest} = SentinelManifest.new(capsule, descriptor)
    {:ok, target} = Target.new(VerificationProvider.identity(), capsule.provenance)
    {request, context} = authority!(target, suffix)

    {:ok, source} =
      Confirmation.run(executor, manifest, capsule, scenario, target,
        request: request,
        context: context,
        body: ConfirmationBodyMatching,
        observer: @observer,
        repair_oracle: nil
      )

    {:ok, regression} = Regression.materialize(source, scenario)
    {regression, manifest, capsule, target}
  end

  defp capsule!(suffix) do
    bytes =
      File.read!("test/fixtures/legacy_restart_capsule_v1.json")
      |> String.trim_trailing("\n")

    {:ok, legacy} = Capsule.decode(bytes)

    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => suffix}},
        configuration: {:available, %{"config" => suffix}},
        dependencies: {:available, %{"lock" => suffix}},
        runtime: {:available, %{"otp" => suffix}},
        target: {:available, %{"class" => "fixture", "name" => suffix}}
      )

    wire =
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))

    digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.sha256()

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> put_in(["integrity", "content_digest"], digest)
    |> Capsule.decode_map()
    |> elem(1)
  end

  defp authority!(target, suffix) do
    timeout_ms = 8_000
    now = System.monotonic_time(:millisecond)
    runtime_target = %{node: Atom.to_string(node())}
    unique = System.unique_integer([:positive])

    {:ok, budget} =
      Budget.new(max_duration_ms: timeout_ms, max_events: 20, max_bytes: 262_144)

    {:ok, request} =
      ProtocolRequest.new("verification.run",
        request_id: "draft-creation-#{suffix}-#{unique}",
        environment: :test,
        target: runtime_target,
        timeout_ms: timeout_ms,
        budget: Map.from_struct(budget),
        capability: "draft-creation-grant-#{suffix}-#{unique}",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "draft-creation-grant-#{suffix}-#{unique}",
        audit_id: "draft-creation-audit-#{suffix}-#{unique}",
        scopes: ["verification.execute"],
        target: runtime_target,
        expires_at_monotonic: now + timeout_ms
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "draft-creation-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "draft-creation-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp candidate!(suffix) do
    {:ok, candidate} =
      Candidate.new(
        "diff --git a/example b/example\n-#{suffix}\n+fixed-#{suffix}\n",
        "unified-diff/v1"
      )

    VerificationBody.reset(candidate.id)
    candidate
  end
end
