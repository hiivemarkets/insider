defmodule Insider.EventTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Event.Ordering
  alias Insider.Protocol.Error

  test "constructs a bounded event with explicit source-stream ordering" do
    assert {:ok, %Event{} = event} = Event.new(valid_options())

    assert event.schema == "insider.event/v1"
    assert event.monotonic_time == -42
    assert event.source_sequence == 7

    assert Ordering.stream_key(event) ==
             {"node-sha256", "boot-01", "clock-monotonic", "logger", "logger-primary"}
  end

  test "validate_encoded returns the same bytes and event as the separate calls" do
    event = Event.new!(valid_options())

    assert {:ok, valid_event, canonical} = Event.validate_encoded(event)
    assert {:ok, ^valid_event} = Event.validate(event)
    assert {:ok, ^canonical} = Event.canonical_binary(event)
  end

  test "validate_encoded rejects non-events exactly as validate and canonical_binary do" do
    for value <- [
          %{},
          :not_an_event,
          nil,
          "event",
          Event.new!(valid_options()) |> Map.from_struct()
        ] do
      assert {:error, %Error{code: :invalid_event} = error} = Event.validate_encoded(value)
      assert Event.validate(value) == {:error, error}
      assert Event.canonical_binary(value) == {:error, error}
    end
  end

  test "validate_encoded enforces the aggregate byte bound after per-field bounds pass" do
    # Every field below is individually within its own bound; only the encoded
    # total exceeds the 16 KiB event limit, so this reaches the aggregate check
    # rather than failing earlier in valid_fields?/1.
    oversized = %{
      Event.new!(valid_options())
      | attributes: %{"a" => String.duplicate("x", 2_000), "b" => String.duplicate("x", 2_000)},
        payload: [String.duplicate("y", 4_000), String.duplicate("y", 4_000)],
        extensions: %{"vendor.big" => String.duplicate("z", 2_000)},
        redactions:
          Enum.map(1..24, fn index ->
            %{
              "action" => "mask",
              "count" => 1,
              "path" => [String.duplicate("p", 100)],
              "policy_id" => "policy-#{index}"
            }
          end)
    }

    assert {:error, %Error{code: :invalid_event} = error} = Event.validate_encoded(oversized)
    assert error.message == "event exceeds its aggregate byte bound"
    assert Event.validate(oversized) == {:error, error}
    assert Event.canonical_binary(oversized) == {:error, error}
  end

  test "canonical bytes are independent of map insertion order and round trip" do
    left_attributes = Map.new([{"z", 1}, {"a", %{"y" => 2, "b" => true}}])
    right_attributes = Map.new([{"a", Map.new([{"b", true}, {"y", 2}])}, {"z", 1}])

    left = Event.new!(valid_options(attributes: left_attributes))
    right = Event.new!(valid_options(attributes: right_attributes))

    assert {:ok, left_bytes} = Event.canonical_binary(left)
    assert {:ok, right_bytes} = Event.canonical_binary(right)
    assert left_bytes == right_bytes
    assert {:ok, decoded} = Jason.decode(left_bytes)
    assert {:ok, round_tripped} = Event.decode_map(decoded)
    assert Event.canonical_binary(round_tripped) == {:ok, left_bytes}
  end

  test "canonical bytes pin UTF-8 key ordering and scalar escaping" do
    event =
      Event.new!(
        valid_options(
          id: "evt-golden",
          node: "node",
          boot_id: "boot",
          source: "fixture",
          kind: "fixture.escaped",
          severity: :warning,
          monotonic_time: -1,
          clock_id: "clock",
          source_instance_id: "source",
          source_sequence: 1,
          wall_time: nil,
          subject: nil,
          attributes: %{"é" => "line\nquote\"", "z" => true},
          payload: nil,
          authority: "policy"
        )
      )

    expected =
      [
        ~S({"attributes":{"z":true,"é":"line\nquote\""},"authority":"policy",),
        ~S("boot_id":"boot","causality":{"logical_operation_id":null,),
        ~S("parent_event_id":null,"process_generation":null,"span_id":null,),
        ~S("trace_id":null},"clock_id":"clock","extensions":{},"id":"evt-golden",),
        ~S("kind":"fixture.escaped","monotonic_time":-1,"node":"node","payload":null,),
        ~S("redactions":[],"schema":"insider.event/v1","severity":"warning",),
        ~S("source":"fixture","source_instance_id":"source","source_sequence":1,),
        ~S("subject":null,"wall_time":null})
      ]
      |> IO.iodata_to_binary()

    assert Event.canonical_binary(event) == {:ok, expected}
  end

  test "canonical SHA-256 helpers bind exact canonical and already-binary inputs" do
    assert Canonical.sha256(%{"b" => 2, "a" => 1}) ==
             "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777"

    assert Canonical.sha256_binary("insider") ==
             "9279f4a7c1c145d5ae930fda23ef386168f6720b4e0f0d3dee383c5ad8535737"
  end

  test "wire maps use strings while closed enums decode through fixed clauses" do
    event = Event.new!(valid_options(severity: :warning))
    wire = Event.to_wire_map(event)

    assert wire["severity"] == "warning"
    assert Enum.all?(Map.keys(wire), &is_binary/1)
    assert {:ok, %Event{severity: :warning}} = Event.decode_map(wire)

    assert {:error, %Error{code: :invalid_event}} =
             Event.decode_map(Map.put(wire, "severity", "surprising"))
  end

  test "unknown valid source and kind strings plus namespaced extensions round trip" do
    wire =
      valid_options(
        source: "vendor.future_collector",
        kind: "vendor.future.signal",
        extensions: %{"vendor.feature" => %{"revision" => 2}}
      )
      |> Event.new!()
      |> Event.to_wire_map()

    assert {:ok, event} = Event.decode_map(wire)
    assert event.source == "vendor.future_collector"
    assert event.kind == "vendor.future.signal"
    assert event.extensions == %{"vendor.feature" => %{"revision" => 2}}
  end

  test "unknown schemas and top-level fields fail with bounded typed evidence" do
    wire = valid_options() |> Event.new!() |> Event.to_wire_map()

    assert {:error, %Error{code: :unsupported_event_schema}} =
             Event.decode_map(Map.put(wire, "schema", "insider.event/v99"))

    assert {:error, %Error{code: :invalid_event} = error} =
             Event.decode_map(Map.put(wire, "typo", String.duplicate("secret", 10_000)))

    refute inspect(error) =~ "secretsecret"

    Enum.each(Map.keys(wire) -- ["schema"], fn required_key ->
      assert {:error, %Error{code: :invalid_event}} =
               Event.decode_map(Map.delete(wire, required_key))
    end)
  end

  test "wire envelope and extension namespaces are exact" do
    wire = valid_options() |> Event.new!() |> Event.to_wire_map()

    assert Enum.sort(Map.keys(wire)) ==
             Enum.sort([
               "attributes",
               "authority",
               "boot_id",
               "causality",
               "clock_id",
               "extensions",
               "id",
               "kind",
               "monotonic_time",
               "node",
               "payload",
               "redactions",
               "schema",
               "severity",
               "source",
               "source_instance_id",
               "source_sequence",
               "subject",
               "wall_time"
             ])

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(extensions: %{"insider.private" => true}))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(extensions: %{"unqualified" => true}))
  end

  test "strict portable values reject unsafe and non-JSON BEAM terms" do
    for value <- [self(), make_ref(), {:tuple}, :atom, 1.5, %{atom_key: true}] do
      assert {:error, %Error{code: :invalid_event}} =
               Event.new(valid_options(payload: value))
    end

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(attributes: %{"too_deep" => nested(10)}))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(source: <<255>>))

    forged = %{Event.new!(valid_options()) | source: :logger}
    assert {:error, %Error{code: :invalid_event}} = Event.canonical_binary(forged)

    hidden = Map.put(Event.new!(valid_options()), :hidden, self())
    assert {:error, %Error{code: :invalid_event}} = Event.validate(hidden)

    unbounded_wall_time = %{
      ~U[2026-09-05 00:00:00Z]
      | time_zone: String.duplicate("x", 1_000_000),
        zone_abbr: String.duplicate("y", 1_000_000)
    }

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(wall_time: unbounded_wall_time))

    negative_year = %{~U[2026-09-05 00:00:00Z] | year: -1}

    assert {:ok, %Event{wall_time: %DateTime{year: -1}}} =
             Event.new(valid_options(wall_time: negative_year))

    forged_wall_time = %{~U[2026-09-05 00:00:00Z] | year: :erlang.bsl(1, 750_000)}
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :validate ->
            send(
              parent,
              {:hostile_wall_time_result, self(),
               Event.new(valid_options(wall_time: forged_wall_time))}
            )
        end
      end)

    :erlang.trace_pattern({DateTime, :to_iso8601, 2}, true, [])
    :erlang.trace(pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({DateTime, :to_iso8601, 2}, false, []) end)
    send(pid, :validate)

    assert_receive {:hostile_wall_time_result, ^pid, {:error, %Error{code: :invalid_event}}}

    refute_receive {:trace, ^pid, :call, {DateTime, :to_iso8601, _arguments}}

    oversized_options = List.duplicate({:id, "duplicate"}, 100_000)
    assert {:error, %Error{code: :invalid_event}} = Event.new(oversized_options)
  end

  test "field and aggregate bounds reject one-over inputs" do
    assert {:ok, %Event{}} =
             Event.new(valid_options(payload: [String.duplicate("x", 4_000), "safe"]))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(
               valid_options(
                 payload: [String.duplicate("x", 4_096), String.duplicate("y", 4_096)]
               )
             )

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(attributes: Map.new(1..65, &{"key#{&1}", &1})))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(redactions: List.duplicate(redaction(), 65)))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(
               valid_options(
                 attributes: %{"a" => String.duplicate("a", 4_000)},
                 payload: [String.duplicate("p", 4_000), String.duplicate("q", 4_000)],
                 extensions: %{"vendor.large" => String.duplicate("e", 2_000)},
                 redactions: List.duplicate(redaction(), 24)
               )
             )
  end

  test "ordering uses stream sequence and explicit parentage, never wall time" do
    earlier = Event.new!(valid_options(id: "evt-1", source_sequence: 7, wall_time: nil))

    later =
      Event.new!(
        valid_options(id: "evt-2", source_sequence: 8, monotonic_time: -41, wall_time: nil)
      )

    other_stream =
      Event.new!(
        valid_options(
          id: "evt-3",
          source_instance_id: "telemetry-secondary",
          source_sequence: 1,
          causality: causality(parent_event_id: "evt-2")
        )
      )

    assert Ordering.compare(earlier, later) == :before
    assert Ordering.compare(later, earlier) == :after
    assert Ordering.compare(later, other_stream) == :before
    assert Ordering.compare(earlier, other_stream) == :concurrent
  end

  test "ordering reports contradictory time and sequence evidence" do
    left = Event.new!(valid_options(id: "evt-left", source_sequence: 7, monotonic_time: 10))
    right = Event.new!(valid_options(id: "evt-right", source_sequence: 8, monotonic_time: 9))
    identical = Event.new!(valid_options())

    assert Ordering.compare(left, right) == :conflict
    assert Ordering.compare(identical, identical) == :equal

    same_sequence = Event.new!(valid_options(id: "evt-other", monotonic_time: 11))
    assert Ordering.compare(left, same_sequence) == :conflict

    colliding_instance =
      Event.new!(valid_options(id: "evt-telemetry", source: "telemetry", monotonic_time: 11))

    assert Ordering.compare(left, colliding_instance) == :concurrent
  end

  test "same stream positions and self-parenting evidence are rejected" do
    event = Event.new!(valid_options())
    conflict = Event.new!(valid_options(id: "evt-conflict"))
    reused_id = Event.new!(valid_options(source_sequence: 8, monotonic_time: -41))

    assert Ordering.compare(event, conflict) == :same_position
    assert Ordering.compare(event, reused_id) == :conflict

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(causality: causality(parent_event_id: "evt-0007")))
  end

  test "identity and ordering integer bounds are explicit" do
    assert {:ok, %Event{}} = Event.new(valid_options(id: String.duplicate("i", 128)))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(id: String.duplicate("i", 129)))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(source_sequence: 9_223_372_036_854_775_808))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(monotonic_time: -9_223_372_036_854_775_809))
  end

  test "decoding untrusted vocabulary never creates atoms" do
    warm = valid_options() |> Event.new!() |> Event.to_wire_map()
    assert {:ok, _event} = Event.decode_map(warm)
    before_count = :erlang.system_info(:atom_count)

    Enum.each(1..1_000, fn index ->
      wire =
        warm
        |> Map.put("source", "vendor.source_#{index}")
        |> Map.put("kind", "vendor.kind_#{index}")

      assert {:ok, %Event{}} = Event.decode_map(wire)
    end)

    assert :erlang.system_info(:atom_count) == before_count
  end

  property "external decoding is total for arbitrary BEAM terms" do
    check all(payload <- term()) do
      case Event.decode_map(payload) do
        {:ok, %Event{}} -> :ok
        {:error, %Error{} = error} -> refute inspect(error) =~ String.duplicate("x", 1_000)
        other -> flunk("unexpected event decoder result: #{inspect(other)}")
      end
    end
  end

  test "construction rejects non-keyword options and new! raises on any invalid event" do
    assert {:error, %Error{code: :invalid_event, message: "event options must be a keyword list"}} =
             Event.new(%{id: "evt-0007"})

    assert_raise ArgumentError, "invalid event", fn -> Event.new!(valid_options(id: "")) end
  end

  test "critical severity round trips through the wire map" do
    event = Event.new!(valid_options(severity: :critical))
    wire = Event.to_wire_map(event)

    assert wire["severity"] == "critical"
    assert {:ok, ^event} = Event.decode_map(wire)
  end

  test "an envelope with the right field count but a renamed field is rejected" do
    wire = valid_options() |> Event.new!() |> Event.to_wire_map()
    renamed = wire |> Map.delete("node") |> Map.put("nodes", wire["node"])

    assert {:error,
            %Error{
              code: :invalid_event,
              message: "event envelope contains unknown or non-string fields"
            }} = Event.decode_map(renamed)

    atom_keyed = wire |> Map.delete("node") |> Map.put(:node, wire["node"])

    assert {:error, %Error{message: "event envelope contains unknown or non-string fields"}} =
             Event.decode_map(atom_keyed)
  end

  test "wire wall time must be bounded UTC RFC3339 or null" do
    wire = valid_options() |> Event.new!() |> Event.to_wire_map()

    assert {:ok, %Event{wall_time: nil}} = Event.decode_map(Map.put(wire, "wall_time", nil))

    for value <- [
          "yesterday",
          "2026-09-05T18:00:00+01:00",
          1_788_000_000,
          String.duplicate("2", 65)
        ] do
      assert {:error, %Error{code: :invalid_event, message: "wall_time must be UTC RFC3339"}} =
               Event.decode_map(Map.put(wire, "wall_time", value))
    end
  end

  test "wire causality must be an object with exactly the five causality fields" do
    wire = valid_options() |> Event.new!() |> Event.to_wire_map()

    assert {:error, %Error{message: "event causality must be an object"}} =
             Event.decode_map(Map.put(wire, "causality", "trace-1"))

    renamed = wire["causality"] |> Map.delete("span_id") |> Map.put("span", nil)

    assert {:error, %Error{message: "event causality fields are invalid"}} =
             Event.decode_map(Map.put(wire, "causality", renamed))
  end

  test "wall time options must be canonical, calendar-valid UTC DateTimes" do
    assert {:error, %Error{message: "wall_time must be a canonical UTC DateTime"}} =
             Event.new(valid_options(wall_time: "2026-09-05T18:00:00Z"))

    # Every scalar is in range, but February has no 31st: the parse rejects it.
    assert {:error, %Error{message: "wall_time must be a canonical UTC DateTime"}} =
             Event.new(valid_options(wall_time: %{~U[2026-02-28 18:00:00Z] | day: 31}))

    # A forged microsecond field fails the scalar bounds before formatting.
    assert {:error, %Error{message: "wall_time must be a canonical UTC DateTime"}} =
             Event.new(valid_options(wall_time: %{~U[2026-02-28 18:00:00Z] | microsecond: 5}))

    # Construction normalises precision; validation of a struct built around
    # it requires the normalised form and a DateTime.
    event = Event.new!(valid_options(wall_time: ~U[2026-09-05 18:00:00.123Z]))
    assert event.wall_time.microsecond == {123_000, 6}

    assert {:error, %Error{message: "event contains invalid or unbounded fields"}} =
             Event.validate(%{event | wall_time: ~U[2026-09-05 18:00:00.123Z]})

    assert {:error, %Error{message: "event contains invalid or unbounded fields"}} =
             Event.validate(%{event | wall_time: "2026-09-05T18:00:00Z"})
  end

  test "causality needs its exact keys and redactions their exact shape" do
    wrong_keys = %{a: nil, b: nil, c: nil, d: nil, e: nil}

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(causality: wrong_keys))

    assert {:error, %Error{code: :invalid_event}} =
             Event.new(valid_options(redactions: [%{"action" => "mask"}]))

    assert {:ok, %Event{}} = Event.new(valid_options(redactions: [redaction()]))
  end

  defp valid_options(overrides \\ []) do
    Keyword.merge(
      [
        id: "evt-0007",
        node: "node-sha256",
        boot_id: "boot-01",
        source: "logger",
        kind: "logger.event",
        severity: :info,
        monotonic_time: -42,
        clock_id: "clock-monotonic",
        source_instance_id: "logger-primary",
        source_sequence: 7,
        wall_time: ~U[2026-09-05 18:00:00.123456Z],
        subject: %{"namespace" => "process", "scope" => nil, "value" => "worker-7"},
        causality: causality(),
        attributes: %{"message" => "started"},
        payload: %{"count" => 1},
        authority: "policy-sha256",
        redactions: [],
        extensions: %{}
      ],
      overrides
    )
  end

  defp causality(overrides \\ []) do
    Map.merge(
      %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      Map.new(overrides)
    )
  end

  defp nested(0), do: "value"
  defp nested(depth), do: %{"next" => nested(depth - 1)}

  defp redaction do
    %{"action" => "mask", "count" => 1, "path" => ["payload", "secret"], "policy_id" => "default"}
  end
end
