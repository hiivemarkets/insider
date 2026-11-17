defmodule Insider.Lab.PrivacyCorpusTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Lab.PrivacyCorpus

  @schema "insider.privacy-corpus/v1"
  @report_schema "insider.privacy-corpus-report/v1"
  @start [:insider, :fixture, :operation, :start]
  @stop [:insider, :fixture, :operation, :stop]
  @start_wire Enum.map(@start, &Atom.to_string/1)
  @structural_logger_fields [
    "attributes.ingress_profile",
    "attributes.message_semantics",
    "kind",
    "severity",
    "source"
  ]

  test "denied profiles suppress every canary outside the exact allowlists and report names only" do
    corpus =
      corpus(
        [
          logger_item("info", string("login for CANARY-MAIL"), %{
            "domain" => ["example_app"],
            "request_id" => "CANARY-REQ",
            "trace_id" => "CANARY-TRACE",
            "logical_operation_id" => "CANARY-OP"
          }),
          logger_item(
            "error",
            report(%{"card_number" => "CANARY-CARD", "label" => "checkout"}),
            %{
              "time" => 1_700_000_000_000_000
            }
          ),
          logger_item("warning", format("declined ~s", ["CANARY-ACCOUNT"]), %{}),
          telemetry_item(@start_wire, %{"duration" => 7, "amount" => "CANARY-AMOUNT"}, %{
            "run_id" => "op-1",
            "scenario" => "checkout",
            "email" => "CANARY-MAIL",
            "token" => "CANARY-TOKEN"
          }),
          telemetry_item(["example_app", "users", "created"], %{}, %{"email" => "CANARY-MAIL"})
        ],
        [
          "CANARY-MAIL",
          "CANARY-REQ",
          "CANARY-TRACE",
          "CANARY-OP",
          "CANARY-CARD",
          "CANARY-ACCOUNT",
          "CANARY-AMOUNT",
          "CANARY-TOKEN"
        ]
      )

    for environment <- [:staging, :production] do
      assert {:ok, report} =
               PrivacyCorpus.run(corpus, environment: environment, telemetry_policy: policy())

      assert report["schema"] == @report_schema
      assert report["status"] == "no_canary_hits"
      assert report["canary_hits"] == []
      assert report["canary_hit_count"] == 0
      assert report["environment"] == Atom.to_string(environment)
      assert report["item_count"] == 5
      assert report["canary_token_count"] == 8

      assert report["logger_settings"] == %{
               "include_message_semantics" => false,
               "include_payload" => false,
               "structural_only" => true
             }

      assert report["telemetry_policy"] == %{
               "id" => policy().id,
               "fingerprint" => policy().fingerprint
             }

      [string_item, report_item, format_item, allowlisted, unconfigured] = report["items"]

      for item <- [string_item, report_item, format_item] do
        assert item["source"] == "logger"
        assert item["disposition"] == "recorded"
        assert item["kind"] == "logger_structural"
        assert item["retained_fields"] == @structural_logger_fields
        assert item["suppressed"]["payload"] == 1
        assert item["suppressed"]["message_semantics"] == 1
      end

      assert string_item["suppressed"]["metadata"] == 4
      assert report_item["suppressed"]["metadata"] == 1
      assert format_item["suppressed"]["metadata"] == 0

      assert allowlisted["disposition"] == "recorded"
      assert allowlisted["kind"] == "operation.start"

      # The omission evidence carries counts and the policy id, never the
      # withheld names or values.
      assert allowlisted["retained_fields"] == [
               "attributes.event_name",
               "attributes.lifecycle_phase",
               "attributes.measurements.duration",
               "attributes.metadata.scenario",
               "attributes.omitted.measurements",
               "attributes.omitted.metadata",
               "attributes.omitted.policy_id",
               "attributes.projection",
               "causality.logical_operation_id",
               "kind",
               "severity",
               "source",
               "subject.namespace",
               "subject.scope",
               "subject.value",
               "wall_time"
             ]

      assert allowlisted["suppressed"] == %{
               "handler_failures" => 0,
               "invalid" => 0,
               "measurements" => 1,
               "metadata" => 2
             }

      assert unconfigured == %{
               "index" => 4,
               "source" => "telemetry",
               "disposition" => "dropped",
               "kind" => nil,
               "retained_fields" => [],
               "suppressed" => %{
                 "handler_failures" => 0,
                 "invalid" => 1,
                 "measurements" => 0,
                 "metadata" => 0
               }
             }

      assert report["suppressed_totals"]["logger"]["metadata"] == 5
      assert report["suppressed_totals"]["telemetry"]["invalid"] == 1

      encoded = Jason.encode!(report)
      refute encoded =~ "CANARY"
      refute encoded =~ "checkout"
      refute encoded =~ "op-1"
      refute encoded =~ "example_app"
    end
  end

  test "a canary in an allowlisted Telemetry field is located by index and field without its value" do
    corpus =
      corpus(
        [
          logger_item("info", string("clean"), %{}),
          telemetry_item(@start_wire, %{"duration" => 1}, %{
            "run_id" => "CANARY-OPERATION",
            "scenario" => "CANARY-SCENARIO"
          })
        ],
        ["CANARY-OPERATION", "CANARY-SCENARIO"]
      )

    assert {:ok, report} =
             PrivacyCorpus.run(corpus, environment: :production, telemetry_policy: policy())

    assert report["status"] == "canary_hits"
    assert report["canary_hit_count"] == 2

    assert report["canary_hits"] == [
             %{"index" => 1, "field" => "attributes.metadata.scenario"},
             %{"index" => 1, "field" => "causality.logical_operation_id"}
           ]

    [_logger, telemetry] = report["items"]

    for %{"field" => field} <- report["canary_hits"] do
      assert field in telemetry["retained_fields"]
    end

    encoded = Jason.encode!(report)
    refute encoded =~ "CANARY-OPERATION"
    refute encoded =~ "CANARY-SCENARIO"
  end

  test "a token that occurs only as a boolean or atom is unused, while its text form hits" do
    boolean_only =
      corpus(
        [
          logger_item("info", string("clean"), %{}),
          telemetry_item(@start_wire, %{"duration" => 1}, %{"scenario" => true})
        ],
        ["true"]
      )

    assert {:error, :canary_token_unused} =
             PrivacyCorpus.run(boolean_only, environment: :production, telemetry_policy: policy())

    atom_only =
      corpus(
        [telemetry_item(@start, %{duration: 1}, %{scenario: :checkout})],
        ["checkout"]
      )

    assert {:error, :canary_token_unused} =
             PrivacyCorpus.run(atom_only, environment: :production, telemetry_policy: policy())

    text =
      corpus(
        [telemetry_item(@start_wire, %{"duration" => 1}, %{"scenario" => "true"})],
        ["true"]
      )

    assert {:ok, report} =
             PrivacyCorpus.run(text, environment: :production, telemetry_policy: policy())

    assert report["status"] == "canary_hits"
    assert report["canary_hits"] == [%{"index" => 0, "field" => "attributes.metadata.scenario"}]
  end

  test "denied profiles retain no free-text Logger field that the development profile exposes" do
    metadata = %{
      "domain" => ["example_app"],
      "trace_id" => "CANARY-TRACE",
      "span_id" => "CANARY-SPAN",
      "parent_event_id" => "CANARY-PARENT",
      "logical_operation_id" => "CANARY-OP",
      "process_generation" => "CANARY-GEN",
      "time" => 1_700_000_000_000_000
    }

    corpus =
      corpus(
        [
          logger_item("info", string("CANARY-TEXT"), metadata),
          logger_item("error", report(%{"CANARY-KEY" => "CANARY-VALUE"}), metadata),
          logger_item("notice", format("~s", ["CANARY-ARG"]), metadata)
        ],
        [
          "CANARY-TRACE",
          "CANARY-SPAN",
          "CANARY-PARENT",
          "CANARY-OP",
          "CANARY-GEN",
          "CANARY-TEXT",
          "CANARY-KEY",
          "CANARY-VALUE",
          "CANARY-ARG"
        ]
      )

    assert {:ok, denied} = PrivacyCorpus.run(corpus, environment: :staging)
    assert denied["canary_hits"] == []
    assert denied["retained_fields_union"] == @structural_logger_fields
    assert Enum.all?(denied["items"], &(&1["suppressed"]["metadata"] == 7))

    assert {:ok, exposed} = PrivacyCorpus.run(corpus, environment: :development)
    assert exposed["status"] == "canary_hits"

    hits = MapSet.new(exposed["canary_hits"], &{&1["index"], &1["field"]})

    assert MapSet.subset?(
             MapSet.new([
               {0, "causality.trace_id"},
               {0, "causality.span_id"},
               {0, "causality.parent_event_id"},
               {0, "causality.logical_operation_id"},
               {0, "causality.process_generation"},
               {0, "payload.items"},
               {1, "payload.items.CANARY-KEY"},
               {2, "payload.items"}
             ]),
             hits
           )

    for %{"index" => index, "field" => field} <- exposed["canary_hits"] do
      retained = Enum.at(exposed["items"], index)["retained_fields"]
      assert Enum.any?(retained, &String.starts_with?(&1, field))
    end
  end

  test "reports are deterministic across runs" do
    corpus =
      corpus(
        [
          logger_item("info", string("CANARY-ONE"), %{"trace_id" => "CANARY-ONE"}),
          telemetry_item(@start_wire, %{"duration" => 1}, %{"run_id" => "op", "k" => "CANARY-ONE"})
        ],
        ["CANARY-ONE"]
      )

    runs =
      for _run <- 1..3 do
        {:ok, report} =
          PrivacyCorpus.run(corpus, environment: :production, telemetry_policy: policy())

        Jason.encode!(report)
      end

    assert Enum.uniq(runs) |> length() == 1
  end

  test "unknown item shapes, missing policies, and bounds fail closed" do
    canaries = ["CANARY-X"]
    clean = logger_item("info", string("CANARY-X"), %{})

    invalid_items = [
      %{"source" => "metrics", "value" => "CANARY-X"},
      %{"source" => "logger", "level" => "info", "message" => string("x"), "extra" => true},
      %{"source" => "logger", "level" => "loud", "message" => string("x")},
      %{
        "source" => "logger",
        "level" => "info",
        "message" => %{"type" => "binary", "value" => "x"}
      },
      %{"source" => "logger", "level" => "info", "message" => string("x"), "metadata" => []},
      %{"source" => "telemetry", "event_name" => [], "metadata" => %{}},
      %{"source" => "telemetry", "event_name" => "not.a.list"},
      %{"source" => "telemetry", "event_name" => ["a"], "measurements" => "x"},
      "not a map"
    ]

    for invalid <- invalid_items do
      assert {:error, {:invalid_item, 1}} =
               PrivacyCorpus.run(corpus([clean, invalid], canaries),
                 environment: :production,
                 telemetry_policy: policy()
               )
    end

    assert {:error, :telemetry_policy_required} =
             PrivacyCorpus.run(
               corpus([clean, telemetry_item(@start_wire, %{}, %{})], canaries),
               environment: :production
             )

    oversized = logger_item("info", string(String.duplicate("x", 65_537)), %{})

    assert {:error, {:item_limit_exceeded, 1}} =
             PrivacyCorpus.run(corpus([clean, oversized], canaries), environment: :production)

    assert {:error, :corpus_limit_exceeded} =
             PrivacyCorpus.run(corpus(List.duplicate(clean, 4_097), canaries),
               environment: :production
             )

    assert {:ok, %{"item_count" => 4_096}} =
             PrivacyCorpus.run(corpus(List.duplicate(clean, 4_096), canaries),
               environment: :production
             )

    many_tokens = Enum.map(1..33, &"CANARY-#{&1}")

    assert {:error, :corpus_limit_exceeded} =
             PrivacyCorpus.run(corpus([clean], many_tokens), environment: :production)

    assert {:error, :canary_token_unused} =
             PrivacyCorpus.run(corpus([clean], ["CANARY-X", "CANARY-UNUSED"]),
               environment: :production
             )

    for tokens <- [["", "CANARY-X"], ["CANARY-X", "CANARY-X"], [:atom], "CANARY-X", nil] do
      assert {:error, :invalid_corpus} =
               PrivacyCorpus.run(corpus([clean], tokens), environment: :production)
    end

    assert {:error, :invalid_corpus} =
             PrivacyCorpus.run(Map.put(corpus([clean], canaries), "schema", "other/v1"),
               environment: :production
             )

    assert {:error, :invalid_corpus} =
             PrivacyCorpus.run(Map.put(corpus([clean], canaries), "notes", "x"),
               environment: :production
             )

    assert {:error, :invalid_corpus} =
             PrivacyCorpus.run(Map.put(corpus([clean], canaries), "items", %{}),
               environment: :production
             )

    assert {:error, :invalid_options} = PrivacyCorpus.run(corpus([clean], canaries), [])

    assert {:error, :invalid_options} =
             PrivacyCorpus.run(corpus([clean], canaries), environment: :galaxy)

    assert {:error, :invalid_options} =
             PrivacyCorpus.run(corpus([clean], canaries),
               environment: :production,
               telemetry_policy: :not_a_policy
             )

    assert {:error, :invalid_options} =
             PrivacyCorpus.run(
               Map.put(corpus([clean], canaries), "telemetry_policy", policy_wire()),
               environment: :production,
               telemetry_policy: policy()
             )

    assert {:error, :invalid_options} =
             PrivacyCorpus.run(corpus([clean], canaries), environment: :production, extra: 1)

    assert {:error, :invalid_options} = PrivacyCorpus.run(:corpus, environment: :production)

    # Presence is checked against the supplied items, so a token that only
    # occurs in a format string (a charlist after normalization) still counts.
    assert {:ok, %{"status" => "no_canary_hits"}} =
             PrivacyCorpus.run(
               corpus([logger_item("info", format("CANARY-X ~s", ["x"]), %{})], canaries),
               environment: :production
             )
  end

  test "embedded wire policies resolve only existing atoms and the run creates none" do
    missing_segment = "privacy_corpus_missing_#{System.unique_integer([:positive])}"
    missing_source = "privacy_corpus_source_#{System.unique_integer([:positive])}"
    hostile_key = "privacy_corpus_key_#{System.unique_integer([:positive])}"
    hostile_segment = "privacy_corpus_event_#{System.unique_integer([:positive])}"

    for name <- [missing_segment, missing_source, hostile_key, hostile_segment] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    assert {:ok, policy} = PrivacyCorpus.telemetry_policy(policy_wire())
    assert policy == policy()

    assert {:error, :telemetry_policy_atom_missing} =
             PrivacyCorpus.telemetry_policy(
               put_in(policy_wire(), ["events", Access.at(0), "name"], [
                 "insider",
                 missing_segment
               ])
             )

    assert {:error, :telemetry_policy_atom_missing} =
             PrivacyCorpus.telemetry_policy(
               Map.put(policy_wire(), "metadata", %{missing_source => "output"})
             )

    assert {:error, :telemetry_policy_atom_missing} =
             PrivacyCorpus.telemetry_policy(
               Map.put(policy_wire(), "correlation", %{"trace_id" => missing_source})
             )

    for wire <- [
          Map.put(policy_wire(), "correlation", %{"unknown_target" => "run_id"}),
          Map.put(policy_wire(), "events", []),
          put_in(policy_wire(), ["events", Access.at(0), "phase"], "begin"),
          Map.put(policy_wire(), "metadata", %{"scenario" => 1}),
          Map.put(policy_wire(), "surprise", true),
          Map.delete(policy_wire(), "id"),
          :not_a_map
        ] do
      assert {:error, :invalid_telemetry_policy} = PrivacyCorpus.telemetry_policy(wire)
    end

    corpus =
      corpus(
        [
          logger_item("info", string("CANARY-Z"), %{hostile_key => "CANARY-Z"}),
          telemetry_item([hostile_segment, "start"], %{}, %{hostile_key => "CANARY-Z"}),
          telemetry_item(@start_wire, %{}, %{hostile_key => "CANARY-Z", "run_id" => "op"})
        ],
        ["CANARY-Z"]
      )
      |> Map.put("telemetry_policy", policy_wire())

    assert {:ok, report} = PrivacyCorpus.run(corpus, environment: :production)
    assert report["status"] == "no_canary_hits"
    assert Enum.map(report["items"], & &1["disposition"]) == ["recorded", "dropped", "recorded"]

    for name <- [missing_segment, missing_source, hostile_key, hostile_segment] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "Elixir callers may pass native OTP terms for full fidelity" do
    corpus =
      corpus(
        [
          %{
            "source" => "logger",
            "level" => "error",
            "message" =>
              {:report,
               %{
                 label: {:supervisor, :child_terminated},
                 report: %{
                   supervisor: :example_supervisor,
                   offender: %{id: "CANARY-ID", pid: self(), restart_type: :permanent},
                   reason: {:failure, "CANARY-REASON"}
                 }
               }},
            "metadata" => %{domain: [:otp, :sasl], pid: self()}
          },
          %{
            "source" => "telemetry",
            "event_name" => @start,
            "measurements" => %{duration: 2.5},
            "metadata" => %{run_id: "op", scenario: :checkout, secret: "CANARY-ID"}
          }
        ],
        ["CANARY-ID", "CANARY-REASON"]
      )

    assert {:ok, production} =
             PrivacyCorpus.run(corpus, environment: :production, telemetry_policy: policy())

    assert production["canary_hits"] == []
    assert hd(production["items"])["retained_fields"] == @structural_logger_fields

    assert {:ok, development} =
             PrivacyCorpus.run(corpus, environment: :development, telemetry_policy: policy())

    [supervisor_report, _telemetry] = development["items"]
    assert supervisor_report["kind"] == "supervisor_child_terminated"
    assert "attributes.offender_id" in supervisor_report["retained_fields"]
    assert "attributes.reason_fingerprint" in supervisor_report["retained_fields"]
    assert %{"index" => 0, "field" => "attributes.offender_id"} in development["canary_hits"]

    refute Enum.any?(
             development["canary_hits"],
             &(&1["field"] == "attributes.reason_fingerprint")
           )

    refute Jason.encode!(development) =~ "CANARY"
  end

  defp corpus(items, canaries),
    do: %{"schema" => @schema, "canary_tokens" => canaries, "items" => items}

  defp logger_item(level, message, metadata),
    do: %{"source" => "logger", "level" => level, "message" => message, "metadata" => metadata}

  defp telemetry_item(name, measurements, metadata),
    do: %{
      "source" => "telemetry",
      "event_name" => name,
      "measurements" => measurements,
      "metadata" => metadata
    }

  defp string(value), do: %{"type" => "string", "value" => value}
  defp report(value), do: %{"type" => "report", "report" => value}

  defp format(format, arguments),
    do: %{"type" => "format", "format" => format, "arguments" => arguments}

  defp policy do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "privacy-corpus-test",
        events: [
          [name: @start, kind: "operation.start", lifecycle: "operation", phase: :start],
          [name: @stop, kind: "operation.stop", lifecycle: "operation", phase: :stop]
        ],
        metadata: [scenario: "scenario"],
        measurements: [duration: "duration"],
        correlation: [logical_operation_id: :run_id]
      )

    policy
  end

  defp policy_wire do
    %{
      "id" => "privacy-corpus-test",
      "events" => [
        %{
          "name" => @start_wire,
          "kind" => "operation.start",
          "lifecycle" => "operation",
          "phase" => "start"
        },
        %{
          "name" => Enum.map(@stop, &Atom.to_string/1),
          "kind" => "operation.stop",
          "lifecycle" => "operation",
          "phase" => "stop"
        }
      ],
      "metadata" => %{"scenario" => "scenario"},
      "measurements" => %{"duration" => "duration"},
      "correlation" => %{"logical_operation_id" => "run_id"}
    }
  end
end
