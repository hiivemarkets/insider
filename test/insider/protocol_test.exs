defmodule Insider.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Insider.Protocol
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Protocol.StrictOptions
  alias Insider.Protocol.Value

  @request_id "req-018f6f24"

  describe "requests" do
    test "builds a bounded v1 request for a known operation" do
      assert {:ok, %Request{} = request} =
               Protocol.request("runtime.capabilities",
                 request_id: @request_id,
                 environment: :development,
                 timeout_ms: 200,
                 budget: [max_duration_ms: 250, max_events: 20, max_bytes: 16_384]
               )

      assert request.schema == "insider.request/v1"
      assert request.protocol == "insider.protocol/v1"
      assert request.operation == "runtime.capabilities"
      assert request.request_id == @request_id
      assert request.timeout_ms == 200
      assert is_integer(request.deadline_monotonic)
      assert request.budget.max_duration_ms == 250
      assert request.budget.max_events == 20
      assert request.budget.max_bytes == 16_384
      assert request.budget.max_targets == 1
    end

    test "rejects an unknown protocol version without creating atoms" do
      payload = %{
        "schema" => "insider.request/v99",
        "protocol" => "insider.protocol/v99",
        "operation" => "runtime.capabilities",
        "request_id" => @request_id
      }

      assert {:error, %Error{code: :unsupported_protocol_version} = error} =
               Protocol.decode_request(payload)

      assert error.details == %{
               received: %{type: "binary", bytes: 20},
               supported: ["insider.protocol/v1"]
             }
    end

    test "rejects an unknown request schema" do
      payload = %{
        "schema" => "insider.request/v2",
        "protocol" => Protocol.version(),
        "operation" => "runtime.capabilities",
        "request_id" => @request_id
      }

      assert {:error, %Error{code: :unsupported_protocol_version} = error} =
               Protocol.decode_request(payload)

      assert error.details.received == %{type: "binary", bytes: 18}
      assert error.details.supported == ["insider.request/v1"]
    end

    test "malformed external fields always return typed errors" do
      base = %{
        "schema" => "insider.request/v1",
        "protocol" => Protocol.version(),
        "operation" => "runtime.capabilities",
        "request_id" => @request_id
      }

      assert {:error, %Error{code: :invalid_budget}} =
               Protocol.decode_request(Map.put(base, "budget", "unbounded"))

      assert {:error, %Error{code: :invalid_budget}} =
               Protocol.decode_request(Map.put(base, "budget", %{"surprise" => 1}))

      assert {:error, %Error{code: :invalid_request, details: %{received: %{type: "binary"}}}} =
               Protocol.decode_request(Map.put(base, "environment", "prod"))

      assert {:error, %Error{code: :invalid_budget}} =
               Protocol.decode_request(Map.put(base, "budget", nil))
    end

    test "rejects an unsupported operation as typed evidence" do
      assert {:error, %Error{code: :unsupported_operation} = error} =
               Protocol.request("runtime.evaluate", request_id: @request_id)

      assert error.details.received == %{type: "binary", bytes: 16}
      assert Enum.all?(Protocol.operations(), &is_binary/1)
    end

    test "requires identity and validates request fields" do
      assert {:error, %Error{code: :invalid_request, details: %{received: %{type: "atom"}}}} =
               Protocol.request("runtime.health")

      assert {:error, %Error{code: :invalid_request, details: %{received: %{type: "atom"}}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 environment: :unknown
               )

      assert {:error, %Error{code: :invalid_request, details: %{field: :params}}} =
               Protocol.request("runtime.health", request_id: @request_id, params: [])

      assert {:error, %Error{code: :invalid_request, details: %{received: %{type: "binary"}}}} =
               Protocol.request("runtime.health", request_id: @request_id, target: "local")

      assert {:error, %Error{code: :invalid_request}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 timeout_ms: :infinity
               )
    end

    test "rejects attempts to forge library-owned envelope versions" do
      assert {:error, %Error{code: :invalid_request}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 schema: "attacker.schema/v1"
               )

      assert {:error, %Error{code: :invalid_request}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 protocol: "attacker.protocol/v1"
               )
    end

    test "derives a local monotonic deadline from a relative timeout" do
      before_deadline = System.monotonic_time(:millisecond) + 75

      assert {:ok, request} =
               Protocol.request("runtime.health", request_id: @request_id, timeout_ms: 75)

      after_deadline = System.monotonic_time(:millisecond) + 75

      assert request.timeout_ms == 75
      assert request.deadline_monotonic in before_deadline..after_deadline
    end

    test "validates reconstructed request structs and rejects forged optional fields" do
      assert {:ok, request} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 environment: :ci,
                 timeout_ms: 100,
                 budget: [max_duration_ms: 100, max_events: 2, max_bytes: 16_384],
                 params: %{"safe" => true},
                 target: %{node: "node-a"},
                 caller: "host",
                 capability: "runtime.observe",
                 idempotency_key: "once"
               )

      assert Request.valid?(request)

      for forged <- [
            %{request | operation: "runtime.evaluate"},
            %{request | deadline_monotonic: :not_a_deadline},
            %{request | deadline_monotonic: System.monotonic_time(:millisecond) + 10_000},
            %{request | target: %{node: "node-a", extra: true}},
            %{request | caller: ""},
            %{request | capability: ""},
            %{request | idempotency_key: ""},
            %{request | redaction_policy: :untrusted}
          ] do
        refute Request.valid?(forged)
      end
    end

    test "rejects invalid and unbounded budgets" do
      assert {:error, %Error{code: :invalid_budget, details: %{field: :max_events}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 budget: [max_events: 0]
               )

      assert {:error, %Error{code: :invalid_budget, details: %{field: :max_duration_ms}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 budget: [max_duration_ms: :infinity]
               )

      assert {:error, %Error{code: :invalid_budget, details: %{field: :max_bytes}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 budget: [max_bytes: Budget.maximum(:max_bytes) + 1]
               )

      assert {:error, %Error{code: :invalid_budget, details: %{field: :max_bytes}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 budget: [max_bytes: Budget.minimum(:max_bytes) - 1]
               )

      assert {:error, %Error{code: :invalid_budget, details: %{unknown_field_count: 1}}} =
               Budget.new(surprise: 1)

      assert {:ok, %Budget{max_duration_ms: 5_000}} = Budget.new()
    end

    test "duration budgets and request timeouts enforce the ten-minute ceiling exactly" do
      maximum = 600_000
      assert Budget.maximum(:max_duration_ms) == maximum
      assert {:ok, %Budget{max_duration_ms: ^maximum}} = Budget.new(max_duration_ms: maximum)

      assert {:error,
              %Error{
                code: :invalid_budget,
                details: %{field: :max_duration_ms, maximum: ^maximum}
              }} = Budget.new(max_duration_ms: maximum + 1)

      assert {:ok, %Request{timeout_ms: ^maximum, budget: %Budget{max_duration_ms: ^maximum}}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 timeout_ms: maximum,
                 budget: [max_duration_ms: maximum]
               )

      assert {:error, %Error{code: :invalid_request}} =
               Protocol.request("runtime.health",
                 request_id: @request_id,
                 timeout_ms: maximum + 1,
                 budget: [max_duration_ms: maximum]
               )
    end

    property "accepts positive finite budget values" do
      check all(
              duration <- integer(1..Budget.maximum(:max_duration_ms)),
              events <- integer(1..Budget.maximum(:max_events)),
              bytes <- integer(Budget.minimum(:max_bytes)..Budget.maximum(:max_bytes)),
              targets <- integer(1..Budget.maximum(:max_targets))
            ) do
        assert {:ok, %Budget{} = budget} =
                 Budget.new(
                   max_duration_ms: duration,
                   max_events: events,
                   max_bytes: bytes,
                   max_targets: targets
                 )

        assert budget.max_duration_ms == duration
        assert budget.max_events == events
        assert budget.max_bytes == bytes
        assert budget.max_targets == targets
      end
    end

    property "the external decoder never raises for arbitrary terms" do
      check all(payload <- term()) do
        result = Protocol.decode_request(payload)

        case result do
          {:ok, %Request{}} -> :ok
          {:error, %Error{}} -> :ok
          other -> flunk("unexpected decoder result: #{inspect(other)}")
        end
      end
    end

    property "hostile external fields remain typed and bounded" do
      base = %{
        "schema" => "insider.request/v1",
        "protocol" => Protocol.version(),
        "operation" => "runtime.capabilities",
        "request_id" => @request_id
      }

      check all(
              field <-
                member_of([
                  "request_id",
                  "environment",
                  "timeout_ms",
                  "budget",
                  "params",
                  "caller",
                  "capability",
                  "idempotency_key",
                  "redaction_policy",
                  "target"
                ]),
              hostile <- term()
            ) do
        case Protocol.decode_request(Map.put(base, field, hostile)) do
          {:ok, %Request{}} -> :ok
          {:error, %Error{details: details}} -> assert Value.bounded_data?(details, 4_096)
          other -> flunk("unexpected decoder result: #{inspect(other)}")
        end
      end
    end

    test "does not retain a large secret in diagnostics" do
      secret = String.duplicate("do-not-retain-this-secret", 10_000)

      assert {:error, %Error{} = error} = Protocol.decode_request(secret)
      refute inspect(error.details) =~ "do-not-retain-this-secret"
      assert Value.bounded_data?(error.details, 4_096)
    end

    test "the data boundary rejects unsafe, malformed, deep, wide, and oversized terms" do
      refute Value.bounded_data?(self(), 4_096)
      refute Value.bounded_data?(fn -> :unsafe end, 4_096)
      refute Value.bounded_data?([:valid | :improper], 4_096)
      refute Value.bounded_data?(deeply_nested_map(10), 4_096)
      refute Value.bounded_data?(Map.new(1..1_001, &{&1, true}), 65_536)
      refute Value.bounded_data?(String.duplicate("x", 4_096), 128)
      refute Value.bounded_data?(%{{:unsafe, :key} => true}, 4_096)
      assert Value.bounded_data?(%{"safe" => [1, true, nil]}, 4_096)
      assert Value.bounded_list?([:one, :two], 2)
      refute Value.bounded_list?([:one, :two, :three], 2)
      refute Value.bounded_list?([:one | :improper], 2)
    end

    test "typed error and effect constructors enforce their own bounds" do
      for code <- [
            :invalid_dedup_state,
            :invalid_dedup_input,
            :dedup_input_limit_exceeded,
            :invalid_dedup_receipt,
            :dedup_receipt_limit_exceeded,
            :unsupported_dedup_receipt_schema,
            :invalid_bisection_record,
            :bisection_record_limit_exceeded,
            :unsupported_bisection_record_schema,
            :bisection_input_mismatch
          ] do
        assert %Error{code: ^code} = Error.new(code, "bounded typed failure")
      end

      assert_raise ArgumentError, ~r/invalid protocol error/, fn ->
        apply(Error, :new, [:not_declared, "unknown"])
      end

      assert_raise ArgumentError, ~r/invalid protocol error/, fn ->
        Error.new(:operation_failed, String.duplicate("x", 513))
      end

      assert_raise ArgumentError, ~r/invalid effect/, fn ->
        Effect.new(:probe, "probe", details: %{secret: String.duplicate("x", 4_096)})
      end
    end

    test "decodes every closed external environment without atom conversion" do
      base = %{
        "schema" => "insider.request/v1",
        "protocol" => Protocol.version(),
        "operation" => "runtime.capabilities",
        "request_id" => @request_id
      }

      for {external, internal} <- [
            {"development", :development},
            {"test", :test},
            {"ci", :ci},
            {"staging", :staging},
            {"production", :production}
          ] do
        assert {:ok, %Request{environment: ^internal} = request} =
                 Protocol.decode_request(Map.put(base, "environment", external))

        assert request.budget.max_events == 1_000
        assert is_integer(request.deadline_monotonic)
      end
    end
  end

  describe "strict options" do
    test "bounds before traversal and routes validation and construction failures" do
      builder = fn options -> {:ok, options} end
      invalid = fn reason -> {:error, reason} end

      assert {:ok, [required: true]} =
               StrictOptions.build([required: true], [:required], builder, invalid)

      assert {:error, :invalid_options} =
               StrictOptions.build([required: true, extra: true], [:required], builder, invalid)

      assert {:error, :invalid_options} =
               StrictOptions.build([{:required, true} | :hostile], [:required], builder, invalid)

      assert {:error, :construction_failed} =
               StrictOptions.build(
                 [required: true],
                 [:required],
                 fn _ -> raise "boom" end,
                 invalid
               )
    end
  end

  describe "effect-honest results" do
    setup do
      {:ok, request} =
        Protocol.request("runtime.health",
          request_id: @request_id,
          timeout_ms: 200
        )

      %{request: request}
    end

    test "represents success independently from cleanup", %{request: request} do
      result = Protocol.success(request, %{status: :healthy}, duration_us: 120)

      assert %Result{status: :ok, value: %{status: :healthy}} = result
      assert result.cleanup == %{status: :not_required}
      assert result.duration_us == 120
      assert result.error == nil
      assert %Result{status: :ok, value: nil} = Result.new(request, :ok)
      assert result.target == request.target
      assert result.requested_limits.max_duration_ms == request.budget.max_duration_ms
      assert result.effective_limits == result.requested_limits
      assert result.stdout == []
      assert result.stderr == []
      assert result.logger_events == []
      assert result.compiler_events == []
      assert result.trace_events == []
      assert result.redactions == []
    end

    test "represents a typed operation error", %{request: request} do
      error = Error.new(:operation_failed, "health probe crashed", %{exception: "badarg"})

      result =
        Protocol.failure(request, error,
          value: %{"partial_evidence" => true},
          cleanup: %{status: :complete}
        )

      assert result.status == :error
      assert result.error == error
      assert result.value == %{"partial_evidence" => true}
      assert result.cleanup.status == :complete
      assert Protocol.failure(request, error).cleanup == %{status: :not_required}
    end

    test "timeout preserves partial effects and uncertainty", %{request: request} do
      effect =
        Effect.new(:process_started, "probe-7",
          status: :partial,
          details: %{cleanup_observed: false}
        )

      result =
        Protocol.timeout(request,
          value: %{"partial_evidence" => true},
          effects: [effect],
          cleanup: %{status: :uncertain},
          uncertainty: ["probe termination was requested but not observed"]
        )

      assert result.status == :timeout
      assert result.value == %{"partial_evidence" => true}
      assert result.error.code == :deadline_exceeded
      assert result.effects == [effect]
      assert result.cleanup.status == :uncertain
      assert result.uncertainty != []
      assert Protocol.timeout(request).status == :timeout
    end

    test "cancellation never claims rollback of observed effects", %{request: request} do
      effect = Effect.new(:telemetry_handler_attached, "handler-1", status: :observed)

      result =
        Protocol.cancelled(request, value: %{"partial_evidence" => true}, effects: [effect])

      assert result.status == :cancelled
      assert result.effects == [effect]
      assert result.value == %{"partial_evidence" => true}
      assert result.cleanup == %{status: :unknown}
      assert "cancellation does not roll back observed effects" in result.warnings
      assert Protocol.cancelled(request).cleanup == %{status: :unknown}
    end

    test "reports an unsupported capability", %{request: request} do
      result = Protocol.unsupported(request, :isolated_system_events)

      assert result.status == :unsupported
      assert result.error.code == :unsupported_capability
      assert result.error.details.capability == :isolated_system_events
      assert result.confidence == :certain

      partial =
        Result.new(request, :unsupported, error: result.error, value: %{"probe" => "seen"})

      assert partial.value == %{"probe" => "seen"}
    end

    test "reports truncation and dropped evidence separately from success", %{request: request} do
      result =
        request
        |> Protocol.success([:first, :second])
        |> Result.truncate(:event_limit, 17)

      assert result.status == :ok
      assert result.truncated == %{reason: :event_limit, dropped: 17}
      assert result.value == [:first, :second]
    end

    test "truncation cannot push a near-limit result over its byte budget", %{request: request} do
      largest_value_size = largest_success_value(request, 0, request.budget.max_bytes)
      result = Protocol.success(request, String.duplicate("x", largest_value_size))
      truncated = Result.truncate(result, :event_limit, 1)

      assert Value.bounded_data?(result_payload(truncated), request.budget.max_bytes)
    end

    test "rejects invalid effect status" do
      assert_raise ArgumentError, ~r/invalid effect/, fn ->
        Effect.new(:process_started, "probe-7", status: :complete)
      end

      assert %Effect{status: :observed, details: %{}} =
               Effect.new(:process_started, "probe-7")
    end

    test "rejects contradictory and unbounded results", %{request: request} do
      error = Error.new(:operation_failed, "failed")

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Protocol.success(request, :ok, error: error)
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, effects: :not_a_list)
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, duration_us: -1)
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Protocol.success(request, String.duplicate("x", request.budget.max_bytes + 1))
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Protocol.failure(request, error,
          value: String.duplicate("x", request.budget.max_bytes + 1)
        )
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, stdout: Enum.to_list(1..(request.budget.max_events + 1)))
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :error, error: %Error{code: :bogus, message: 123, retryable: :maybe})
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, effects: [%Effect{kind: :probe, target: "", status: :bogus}])
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, requested_limits: %{max_events: request.budget.max_events + 1})
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok,
          effective_limits:
            request.budget
            |> Map.from_struct()
            |> Map.put(:max_events, request.budget.max_events + 1)
        )
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, target: %{unexpected: true})
      end
    end

    test "total result validation rejects malformed residual fields", %{request: request} do
      result = Protocol.success(request, :ok)

      refute Result.valid?(:not_a_result, request)
      refute Result.valid?(%{result | stdout: :not_a_stream}, request)
      refute Result.valid?(%{result | warnings: :not_a_list}, request)
      refute Result.valid?(%{result | uncertainty: :not_a_list}, request)
      refute Result.valid?(%{result | cleanup: :not_a_cleanup}, request)
      refute Result.valid?(result, %{request | budget: %{}})
    end

    test "rejects truncation metadata whose count exceeds the byte budget" do
      {:ok, request} =
        Protocol.request("runtime.health",
          request_id: "small-truncation-budget",
          budget: [max_bytes: 16_384]
        )

      result = Protocol.success(request, :ok)
      hostile_count = Integer.pow(10, 200_000)

      assert_raise ArgumentError, ~r/truncation metadata exceeds/, fn ->
        Result.truncate(result, :event_limit, hostile_count)
      end
    end

    test "enforces lower effective limits rather than merely reporting them", %{request: request} do
      effective_limits =
        request.budget
        |> Map.from_struct()
        |> Map.merge(%{max_events: 1, max_bytes: Budget.minimum(:max_bytes)})

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok,
          effective_limits: effective_limits,
          stdout: [:one, :two]
        )
      end

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok,
          effective_limits: effective_limits,
          value: String.duplicate("x", Budget.minimum(:max_bytes))
        )
      end
    end

    test "enforces the event ceiling across effects and every stream" do
      {:ok, request} =
        Protocol.request("runtime.health",
          request_id: @request_id,
          budget: [max_events: 2]
        )

      effect = Effect.new(:probe, "probe-1")

      assert %Result{} = Result.new(request, :ok, effects: [effect], stdout: ["one"])

      assert_raise ArgumentError, ~r/invalid protocol result/, fn ->
        Result.new(request, :ok, effects: [effect], stdout: ["one"], stderr: ["two"])
      end
    end

    test "the minimum byte budget can always return baseline typed outcomes" do
      {:ok, request} =
        Protocol.request("runtime.health",
          request_id: @request_id,
          budget: [max_bytes: Budget.minimum(:max_bytes)]
        )

      error = Error.new(:operation_failed, "failed")

      assert %Result{status: :ok} = Protocol.success(request, nil)
      assert %Result{status: :error} = Protocol.failure(request, error)
      assert %Result{status: :timeout} = Protocol.timeout(request)
      assert %Result{status: :cancelled} = Protocol.cancelled(request)
      assert %Result{status: :unsupported} = Protocol.unsupported(request, :trace)
    end
  end

  defp deeply_nested_map(0), do: %{"leaf" => true}
  defp deeply_nested_map(depth), do: %{"next" => deeply_nested_map(depth - 1)}

  defp largest_success_value(_request, low, high) when low >= high, do: low

  defp largest_success_value(request, low, high) do
    candidate = div(low + high + 1, 2)

    if valid_success_size?(request, candidate) do
      largest_success_value(request, candidate, high)
    else
      largest_success_value(request, low, candidate - 1)
    end
  end

  defp valid_success_size?(request, size) do
    Protocol.success(request, String.duplicate("x", size))
    true
  rescue
    ArgumentError -> false
  end

  defp result_payload(result) do
    result
    |> Map.from_struct()
    |> Map.drop([:schema, :protocol, :request_id, :operation, :status])
  end
end
