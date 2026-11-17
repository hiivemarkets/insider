defmodule Insider.FindingTest do
  use ExUnit.Case, async: true

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Finding
  alias Insider.Protocol.Error

  test "restart and mailbox findings round trip through the exact shared envelope" do
    for finding <- [restart_finding(), mailbox_finding()] do
      wire = Finding.to_wire_map(finding)

      assert Map.keys(wire) |> Enum.sort() == [
               "confidence",
               "details",
               "detector",
               "detector_version",
               "evidence_event_ids",
               "fingerprint",
               "occurred_at_us",
               "schema",
               "severity",
               "trigger_event_id"
             ]

      assert {:ok, ^finding} = Finding.decode_map(wire)
      assert {:ok, ^finding} = Finding.validate(finding)
    end
  end

  test "detector details cannot be substituted across detector boundaries" do
    restart = restart_finding()
    mailbox = mailbox_finding()

    assert_invalid(%{restart | details: mailbox.details})
    assert_invalid(%{mailbox | details: restart.details})
  end

  test "semantic findings bind a bounded causal event set and retain one-event compatibility" do
    one_event = semantic_finding(["invariant-1"])
    evidence_ids = ["writer-1", "observation-1", "exception-1", "invariant-1"]
    fingerprints = Enum.map(1..4, &String.duplicate(Integer.to_string(&1), 64))
    causal = semantic_finding(evidence_ids, fingerprints)

    assert {:ok, ^one_event} = Finding.validate(one_event)
    assert {:ok, ^causal} = Finding.validate(causal)
    assert causal.fingerprint == one_event.fingerprint

    wire = Finding.to_wire_map(causal)
    assert_invalid(Map.put(wire, "evidence_event_ids", ["writer-1", "writer-1", "invariant-1"]))
    assert_invalid(Map.put(wire, "evidence_event_ids", ["writer-1", "observation-1"]))
    assert_invalid(Map.put(wire, "evidence_event_ids", List.duplicate("event", 33)))

    assert_invalid(
      wire
      |> Map.put("evidence_event_ids", evidence_ids)
      |> put_in(["details", "evidence_event_fingerprints"], Enum.take(fingerprints, 3))
    )

    assert_invalid(%{causal | details: %{"identity" => causal.details["identity"]}})
  end

  test "fingerprints, exact keys, arithmetic, and bounds fail closed" do
    finding = mailbox_finding()
    wire = Finding.to_wire_map(finding)

    assert_invalid(Map.put(wire, "fingerprint", String.duplicate("0", 64)))
    assert_invalid(Map.put(wire, "extra", true))
    assert_invalid(put_in(wire, ["details", "queue_growth"], 99))
    assert_invalid(Map.put(wire, "evidence_event_ids", []))
    assert_invalid(Map.put(wire, "occurred_at_us", :erlang.bsl(1, 1_000)))
  end

  test "unknown detector versions and hostile terms do not create atoms or escape" do
    wire = Finding.to_wire_map(restart_finding())

    for value <- [
          Map.put(wire, "detector_version", "999"),
          Map.put(wire, "details", self()),
          Map.put(wire, "evidence_event_ids", List.duplicate("event", 100_000))
        ] do
      assert_invalid(value)
    end

    for sequence <- 1..1_000 do
      assert_invalid(Map.put(wire, "detector", "external_#{sequence}"))
    end

    unknown = "finding_unknown_#{System.unique_integer([:positive, :monotonic])}"
    assert_invalid(Map.put(wire, "detector", unknown))
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "constructor bounds hostile details before fingerprinting" do
    valid = restart_finding()

    options =
      valid
      |> Map.from_struct()
      |> Map.drop([:schema, :fingerprint])
      |> Enum.to_list()

    for details <- [
          Map.new(1..100_000, &{"key-#{&1}", &1}),
          %{"identity" => List.duplicate("unbounded", 100_000)},
          %{"identity" => deeply_nested(20)}
        ] do
      assert {:error, %Error{code: :invalid_capsule}} =
               Finding.new(Keyword.put(options, :details, details))
    end
  end

  test "all public entry points fail closed on wrong shapes" do
    finding = restart_finding()

    assert {:error, %Error{code: :invalid_capsule}} = Finding.new(:not_options)
    assert {:error, %Error{code: :invalid_capsule}} = Finding.new([])
    assert_raise ArgumentError, fn -> Finding.new!([]) end
    assert {:error, %Error{code: :invalid_capsule}} = Finding.validate(%{})
    assert {:error, %Error{code: :invalid_capsule}} = Finding.decode_map([])
    refute Finding.valid_wire?([])

    forged = Map.put(finding, :hidden, true)
    assert {:error, %Error{code: :invalid_capsule}} = Finding.validate(forged)
  end

  test "detector-specific identity and counter variants reject independently" do
    restart = Finding.to_wire_map(restart_finding())
    mailbox = Finding.to_wire_map(mailbox_finding())

    assert_invalid(put_in(restart, ["details", "identity", "boot_id"], ""))
    assert_invalid(put_in(restart, ["details", "identity"], "not-an-identity"))
    assert_invalid(put_in(restart, ["details", "reason_fingerprints"], ["bad-digest"]))
    assert_invalid(put_in(mailbox, ["details", "identity", "process_pid"], "pid-10"))
    assert_invalid(put_in(mailbox, ["details", "identity"], []))
    assert_invalid(put_in(mailbox, ["details", "identity", "process_generation"], ""))
    assert_invalid(put_in(mailbox, ["details", "queue_start"], -1))
    assert_invalid(put_in(mailbox, ["details", "reductions_end"], 101))

    options =
      restart_finding()
      |> Map.from_struct()
      |> Map.drop([:schema, :fingerprint])
      |> Enum.to_list()

    assert {:error, %Error{code: :invalid_capsule}} =
             Finding.new(Keyword.put(options, :occurred_at_us, :invalid))
  end

  test "an evidence event fingerprint is the SHA-256 of its canonical wire map" do
    event =
      Event.new!(
        id: "evt-0001",
        node: "node-sha256",
        boot_id: "boot-01",
        source: "logger",
        kind: "logger.event",
        severity: :error,
        monotonic_time: 1,
        clock_id: "clock-monotonic",
        source_instance_id: "logger-primary",
        source_sequence: 1,
        wall_time: nil,
        subject: nil,
        causality: %{
          trace_id: nil,
          span_id: nil,
          parent_event_id: nil,
          logical_operation_id: nil,
          process_generation: nil
        },
        attributes: %{},
        payload: %{"count" => 1},
        authority: "policy-sha256",
        redactions: [],
        extensions: %{}
      )

    wire = Event.to_wire_map(event)
    expected = :sha256 |> :crypto.hash(Canonical.encode(wire)) |> Base.encode16(case: :lower)

    assert Finding.evidence_event_fingerprint(event) == {:ok, expected}
    assert Finding.evidence_event_fingerprint(wire) == {:ok, expected}

    # Any changed byte of evidence changes the binding.
    assert {:ok, other} =
             Finding.evidence_event_fingerprint(Map.put(wire, "payload", %{"count" => 2}))

    refute other == expected

    # Only a decodable event is fingerprinted.
    assert {:error, %Error{code: :invalid_capsule}} =
             Finding.evidence_event_fingerprint(Map.put(wire, "severity", "loud"))

    assert {:error, %Error{code: :invalid_capsule}} = Finding.evidence_event_fingerprint(:event)

    assert {:error, %Error{code: :invalid_capsule}} =
             Finding.evidence_event_fingerprint(restart_finding())
  end

  test "semantic findings require an exact identity with a sha256 contract fingerprint" do
    options = fn identity ->
      [
        detector: "semantic_invariant",
        detector_version: "1",
        occurred_at_us: 3_000,
        confidence: "high",
        severity: "error",
        trigger_event_id: "invariant-1",
        evidence_event_ids: ["invariant-1"],
        details: %{"identity" => identity}
      ]
    end

    identity = %{
      "contract_fingerprint" => "sha256:" <> String.duplicate("a", 64),
      "contract_id" => "test.semantic-contract",
      "contract_version" => 1,
      "invariant" => "causal-chain-complete"
    }

    assert {:ok, %Finding{}} = Finding.new(options.(identity))

    assert {:error, %Error{code: :invalid_capsule}} =
             Finding.new(options.(Map.delete(identity, "invariant")))

    assert {:error, %Error{code: :invalid_capsule}} =
             Finding.new(
               options.(%{
                 identity
                 | "contract_fingerprint" => "md5:" <> String.duplicate("a", 64)
               })
             )
  end

  defp restart_finding do
    Finding.new!(
      detector: "restart_recurrence",
      detector_version: "1",
      occurred_at_us: 3_000,
      confidence: "medium",
      severity: "error",
      trigger_event_id: "restart-3",
      evidence_event_ids: ["restart-1", "restart-2", "restart-3"],
      details: %{
        "count" => 3,
        "window_ms" => 10,
        "identity" => %{
          "node" => "node-a",
          "boot_id" => "boot-a",
          "supervisor" => "supervisor-a",
          "offender_id" => "worker-a"
        },
        "reason_fingerprints" => [String.duplicate("a", 64)]
      }
    )
  end

  defp mailbox_finding do
    Finding.new!(
      detector: "mailbox_growth",
      detector_version: "1",
      occurred_at_us: 3_000,
      confidence: "medium",
      severity: "warning",
      trigger_event_id: "mailbox-3",
      evidence_event_ids: ["mailbox-1", "mailbox-2", "mailbox-3"],
      details: %{
        "sample_count" => 3,
        "window_ms" => 10,
        "identity" => %{
          "node" => "node-a",
          "boot_id" => "boot-a",
          "process_pid" => "<0.10.0>",
          "process_generation" => nil
        },
        "queue_start" => 10,
        "queue_end" => 12,
        "queue_growth" => 2,
        "reductions_start" => 100,
        "reductions_end" => 100
      }
    )
  end

  defp semantic_finding(evidence_event_ids, fingerprints \\ nil) do
    details =
      %{
        "identity" => %{
          "contract_fingerprint" => "sha256:" <> String.duplicate("a", 64),
          "contract_id" => "test.semantic-contract",
          "contract_version" => 1,
          "invariant" => "causal-chain-complete"
        }
      }
      |> maybe_put_evidence_fingerprints(fingerprints)

    Finding.new!(
      detector: "semantic_invariant",
      detector_version: "1",
      occurred_at_us: 3_000,
      confidence: "high",
      severity: "error",
      trigger_event_id: "invariant-1",
      evidence_event_ids: evidence_event_ids,
      details: details
    )
  end

  defp maybe_put_evidence_fingerprints(details, nil), do: details

  defp maybe_put_evidence_fingerprints(details, fingerprints),
    do: Map.put(details, "evidence_event_fingerprints", fingerprints)

  defp assert_invalid(value) do
    result =
      if is_struct(value, Finding), do: Finding.validate(value), else: Finding.decode_map(value)

    assert {:error, %Error{code: :invalid_capsule}} = result
  end

  defp deeply_nested(0), do: "value"
  defp deeply_nested(depth), do: %{"next" => deeply_nested(depth - 1)}
end
