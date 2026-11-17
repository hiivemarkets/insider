defmodule Insider.Incident.Capsule do
  @moduledoc """
  A bounded, redacted, content-addressed incident artifact that validates offline.

  Assembly accepts only a sealed recorder snapshot, a supported normalized
  finding, validated provenance, trusted export policy, audit identifiers, and
  digest-only artifact references. It invokes redaction itself for every root
  and rejects preexisting Event redaction claims.
  """

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Incident.ExportPolicy
  alias Insider.Incident.Source
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue
  alias Insider.Provenance
  alias Insider.Recorder.Classification
  alias Insider.Redaction
  alias Insider.Redaction.Outcome

  @schema "insider.incident-capsule/v1"
  @chain_schema "insider.incident-event-chain/v1"
  @chain_entry_schema "insider.incident-event-chain-entry/v1"
  @required_option_keys [:export_policy, :authority, :artifacts]
  @option_keys @required_option_keys ++ [:deadline_monotonic_us]
  @wire_keys [
    "artifacts",
    "authority",
    "finding",
    "id",
    "integrity",
    "provenance",
    "redaction",
    "schema",
    "snapshot"
  ]
  @maximum_bytes 1_048_576
  @maximum_manifest_records 512
  @maximum_consumption_input_bytes 72_351_744
  @maximum_consumption_nodes 1_130_496
  @maximum_consumption_output_bytes 72_351_744
  @maximum_integer 9_223_372_036_854_775_807
  @zero_digest String.duplicate("0", 64)

  @enforce_keys [
    :schema,
    :id,
    :finding,
    :snapshot,
    :provenance,
    :authority,
    :redaction,
    :artifacts,
    :integrity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: String.t(),
          id: String.t(),
          finding: map(),
          snapshot: map(),
          provenance: map(),
          authority: map(),
          redaction: map(),
          artifacts: [map()],
          integrity: map()
        }

  @spec assemble(term(), term(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def assemble(snapshot, finding, provenance, options) when is_list(options) do
    started_at = System.monotonic_time(:microsecond)

    with :ok <- exact_options(options),
         %ExportPolicy{} = export_policy <- Keyword.fetch!(options, :export_policy),
         true <- ExportPolicy.valid?(export_policy),
         deadline <-
           min(
             started_at + export_policy.max_duration_ms * 1_000,
             Keyword.get(options, :deadline_monotonic_us, 9_223_372_036_854_775_807)
           ),
         {:ok, source} <-
           Source.normalize(
             snapshot,
             finding,
             provenance,
             Keyword.fetch!(options, :authority),
             Keyword.fetch!(options, :artifacts),
             deadline
           ),
         {:ok, sanitized, manifests, consumption} <-
           redact_source(source, export_policy, deadline),
         {:ok, capsule} <- build(sanitized, manifests, consumption, export_policy, deadline),
         :ok <- before_deadline(deadline) do
      {:ok, capsule}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :deadline_exceeded} -> deadline_exceeded()
      {:error, reason} -> invalid(reason)
      false -> invalid(:invalid_export_policy)
      _other -> invalid(:invalid_source)
    end
  rescue
    _error -> invalid(:assembly_failed)
  catch
    _kind, _reason -> invalid(:assembly_failed)
  end

  def assemble(_snapshot, _finding, _provenance, _options), do: invalid(:invalid_options)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = capsule), do: do_validate(capsule, nil)

  def validate(value), do: invalid_value(value)

  defp do_validate(capsule, deadline) do
    with :ok <- before_optional_deadline(deadline),
         true <- exact_struct?(capsule),
         true <- capsule.schema == @schema,
         true <- Source.valid_finding?(capsule.finding),
         true <- valid_final_snapshot?(capsule.snapshot),
         {:ok, _provenance} <- Provenance.decode_map(capsule.provenance),
         true <- Source.valid_authority?(capsule.authority),
         true <- Source.valid_artifacts?(capsule.artifacts),
         true <- valid_redaction?(capsule.redaction, capsule.snapshot),
         true <- redacted_provenance_bound?(capsule.provenance, capsule.redaction),
         :ok <- before_optional_deadline(deadline),
         :ok <- Source.correlate(capsule.finding, snapshot_without_chain(capsule.snapshot)),
         :ok <- before_optional_deadline(deadline),
         :ok <- verify_integrity(capsule, deadline),
         encoded <- Canonical.encode(to_wire_map(capsule)),
         :ok <- before_optional_deadline(deadline),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, capsule}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :integrity} -> integrity_failed()
      _other -> invalid(:invalid_capsule)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, payload} <- Jason.decode(binary),
         {:ok, capsule} <- decode_map(payload),
         true <- Canonical.encode(payload) == binary do
      {:ok, capsule}
    else
      false -> invalid(:noncanonical_encoding)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded(:capsule_bytes)
  def decode(value), do: invalid_value(value)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(payload) when is_map(payload) and not is_struct(payload) do
    cond do
      Map.get(payload, "schema") != @schema ->
        unsupported_schema(Map.get(payload, "schema"))

      map_size(payload) != length(@wire_keys) or Enum.sort(Map.keys(payload)) != @wire_keys ->
        invalid(:invalid_envelope)

      true ->
        payload
        |> then(&struct!(__MODULE__, map_to_struct_fields(&1)))
        |> validate()
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(value), do: invalid_value(value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(%__MODULE__{} = capsule) do
    with {:ok, valid_capsule} <- validate(capsule) do
      {:ok, valid_capsule |> to_wire_map() |> Canonical.encode()}
    end
  end

  def canonical_binary(value), do: invalid_value(value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = capsule) do
    %{
      "schema" => capsule.schema,
      "id" => capsule.id,
      "finding" => capsule.finding,
      "snapshot" => capsule.snapshot,
      "provenance" => capsule.provenance,
      "authority" => capsule.authority,
      "redaction" => capsule.redaction,
      "artifacts" => capsule.artifacts,
      "integrity" => capsule.integrity
    }
  end

  defp redact_source(source, export_policy, deadline) do
    initial = {:ok, %{}, [], zero_consumption()}

    with {:ok, sanitized, manifests, consumption} <-
           redact_named(initial, :finding, source.finding, export_policy, deadline),
         {:ok, sanitized, manifests, consumption} <-
           redact_named(
             {:ok, sanitized, manifests, consumption},
             :snapshot,
             Map.delete(source.snapshot, "events"),
             export_policy,
             deadline
           ),
         {:ok, sanitized, manifests, consumption} <-
           redact_events(
             source.snapshot["events"],
             {:ok, sanitized, manifests, consumption},
             export_policy,
             deadline
           ),
         {:ok, sanitized, manifests, consumption} <-
           redact_named(
             {:ok, sanitized, manifests, consumption},
             :provenance,
             source.provenance,
             export_policy,
             deadline
           ),
         {:ok, sanitized, manifests, consumption} <-
           redact_named(
             {:ok, sanitized, manifests, consumption},
             :authority,
             source.authority,
             export_policy,
             deadline
           ),
         {:ok, sanitized, manifests, consumption} <-
           redact_named(
             {:ok, sanitized, manifests, consumption},
             :artifacts,
             source.artifacts,
             export_policy,
             deadline
           ),
         :ok <- before_deadline(deadline),
         :ok <- manifest_bound(manifests) do
      snapshot =
        sanitized.snapshot
        |> Map.put("events", sanitized.events)
        |> Map.put("retained_count", length(sanitized.events))
        |> Map.put("retained_bytes", Source.event_bytes(sanitized.events))

      sanitized = sanitized |> Map.put(:snapshot, snapshot) |> Map.delete(:events)

      with :ok <- before_deadline(deadline) do
        sorted_manifests = Enum.sort_by(manifests, &Canonical.encode/1)

        with :ok <- before_deadline(deadline) do
          {:ok, sanitized, sorted_manifests, consumption}
        end
      end
    end
  end

  defp redact_events(events, state, export_policy, deadline) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while(state, fn {entry, index}, state ->
      case redact_event(state, entry, index, export_policy, deadline) do
        {:ok, _sanitized, _manifests, _consumption} = next -> {:cont, next}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp redact_event({:ok, sanitized, manifests, consumption}, entry, index, policy, deadline) do
    with :ok <- before_deadline(deadline),
         {:ok, event} <- Event.decode_map(entry["event"]),
         {:ok, classification} <-
           Classification.decode_map(entry["classification"], event),
         true <- classification.policy_id == policy.redaction_policy.id,
         true <- classification.policy_fingerprint == policy.redaction_policy.fingerprint,
         true <- classification.sensitivity == policy.sensitivities.event,
         {:ok, %Outcome{} = outcome} <-
           Redaction.redact(entry["event"], classification.sensitivity, policy.redaction_policy,
             deadline_monotonic_us: deadline
           ),
         {:ok, redacted_event} <- Event.decode_map(outcome.value),
         true <- redacted_event.redactions == [],
         {:ok, manifests} <-
           append_manifests(manifests, outcome.manifest, "event:" <> Integer.to_string(index)),
         :ok <- before_deadline(deadline) do
      sanitized_entry =
        entry
        |> Map.delete("classification")
        |> Map.put("event", Event.to_wire_map(redacted_event))

      events = Map.get(sanitized, :events, []) ++ [sanitized_entry]

      sanitized = Map.put(sanitized, :events, events)

      {:ok, sanitized, manifests, add_consumption(consumption, outcome)}
    else
      false ->
        invalid(:event_classification_mismatch)

      {:error, %Error{code: :redaction_failed, details: %{reason: "deadline_exceeded"}}} ->
        deadline_exceeded()

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :invalid_classification} ->
        invalid(:invalid_event_classification)
    end
  end

  defp redact_named({:ok, sanitized, manifests, consumption}, root, value, policy, deadline) do
    with :ok <- before_deadline(deadline),
         {:ok, %Outcome{} = outcome} <-
           Redaction.redact(value, policy.sensitivities[root], policy.redaction_policy,
             deadline_monotonic_us: deadline
           ),
         :ok <- validate_sanitized(root, outcome.value),
         {:ok, manifests} <-
           append_manifests(manifests, outcome.manifest, Atom.to_string(root)),
         :ok <- before_deadline(deadline) do
      {:ok, Map.put(sanitized, root, outcome.value), manifests,
       add_consumption(consumption, outcome)}
    else
      {:error, %Error{code: :redaction_failed, details: %{reason: "deadline_exceeded"}}} ->
        deadline_exceeded()

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        invalid(reason)
    end
  end

  defp validate_sanitized(:finding, value),
    do: truth(Source.valid_finding?(value), :invalid_finding)

  defp validate_sanitized(:snapshot, value), do: valid_snapshot_metadata(value)

  defp validate_sanitized(:provenance, value) do
    case Provenance.decode_map(value) do
      {:ok, _provenance} -> :ok
      _error -> {:error, :invalid_provenance}
    end
  end

  defp validate_sanitized(:authority, value),
    do: truth(Source.valid_authority?(value), :invalid_authority)

  defp validate_sanitized(:artifacts, value),
    do: truth(Source.valid_artifacts?(value), :invalid_artifacts)

  defp build(source, manifests, consumption, export_policy, deadline) do
    with :ok <- before_deadline(deadline),
         :ok <- manifest_bound(manifests),
         :ok <- truth(Source.valid_snapshot?(source.snapshot), :invalid_snapshot),
         :ok <- before_deadline(deadline),
         :ok <- Source.correlate(source.finding, source.snapshot),
         :ok <- before_deadline(deadline),
         :ok <-
           truth(
             redacted_provenance_bound?(source.provenance, export_policy.redaction_policy),
             :redacted_provenance_policy_mismatch
           ),
         {:ok, snapshot} <- put_event_chain(source.snapshot, deadline),
         :ok <- before_deadline(deadline) do
      redaction = %{
        "policy_id" => export_policy.redaction_policy.id,
        "policy_fingerprint" => export_policy.redaction_policy.fingerprint,
        "export_policy_fingerprint" => export_policy.fingerprint,
        "root_sensitivities" =>
          export_policy.sensitivities
          |> Map.new(fn {root, sensitivity} ->
            {Atom.to_string(root), Atom.to_string(sensitivity)}
          end),
        "manifest" => manifests,
        "consumption" => Map.put(consumption, "manifest_records", length(manifests))
      }

      content = %{
        "schema" => @schema,
        "finding" => source.finding,
        "snapshot" => snapshot,
        "provenance" => source.provenance,
        "authority" => source.authority,
        "redaction" => redaction,
        "artifacts" => source.artifacts
      }

      with :ok <- before_deadline(deadline),
           content_digest <- digest(content),
           :ok <- before_deadline(deadline) do
        capsule = %__MODULE__{
          schema: @schema,
          id: "sha256:" <> content_digest,
          finding: source.finding,
          snapshot: snapshot,
          provenance: source.provenance,
          authority: source.authority,
          redaction: redaction,
          artifacts: source.artifacts,
          integrity: %{
            "algorithm" => "sha256",
            "content_digest" => content_digest,
            "event_chain_head" => event_chain_head(snapshot)
          }
        }

        do_validate(capsule, deadline)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :manifest_limit} -> limit_exceeded(:manifest_records)
      {:error, reason} -> invalid(reason)
    end
  end

  defp put_event_chain(snapshot, deadline) do
    genesis =
      digest(%{
        "freeze_id" => snapshot["freeze_id"],
        "instance_id" => snapshot["instance_id"],
        "schema" => @chain_schema
      })

    result =
      Enum.reduce_while(snapshot["events"], {:ok, [], genesis}, fn entry,
                                                                   {:ok, events, previous} ->
        case before_deadline(deadline) do
          :ok ->
            chain_digest = chain_digest(entry, previous)
            {:cont, {:ok, [Map.put(entry, "chain_digest", chain_digest) | events], chain_digest}}

          {:error, %Error{}} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, events, _head} -> {:ok, Map.put(snapshot, "events", Enum.reverse(events))}
      {:error, %Error{}} = error -> error
    end
  end

  defp verify_integrity(capsule, deadline) do
    with true <- valid_integrity_shape?(capsule.integrity),
         true <- capsule.id == "sha256:" <> capsule.integrity["content_digest"],
         true <- capsule.integrity["event_chain_head"] == event_chain_head(capsule.snapshot),
         :ok <- before_optional_deadline(deadline),
         true <- valid_chain?(capsule.snapshot),
         :ok <- before_optional_deadline(deadline),
         true <- capsule.integrity["content_digest"] == digest(content(capsule)),
         :ok <- before_optional_deadline(deadline) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, :integrity}
    end
  end

  defp valid_chain?(snapshot) do
    genesis =
      digest(%{
        "freeze_id" => snapshot["freeze_id"],
        "instance_id" => snapshot["instance_id"],
        "schema" => @chain_schema
      })

    {_head, valid} =
      Enum.reduce(snapshot["events"], {genesis, true}, fn entry, {previous, valid} ->
        expected = chain_digest(Map.delete(entry, "chain_digest"), previous)
        {entry["chain_digest"], valid and entry["chain_digest"] == expected}
      end)

    valid
  end

  defp chain_digest(entry, previous) do
    digest(%{
      "entry" => entry,
      "previous_digest" => previous,
      "schema" => @chain_entry_schema
    })
  end

  defp event_chain_head(snapshot) do
    case List.last(snapshot["events"]) do
      nil -> @zero_digest
      entry -> entry["chain_digest"]
    end
  end

  defp content(capsule) do
    %{
      "schema" => capsule.schema,
      "finding" => capsule.finding,
      "snapshot" => capsule.snapshot,
      "provenance" => capsule.provenance,
      "authority" => capsule.authority,
      "redaction" => capsule.redaction,
      "artifacts" => capsule.artifacts
    }
  end

  defp valid_final_snapshot?(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    events = Map.get(snapshot, "events")

    bounded_event_list?(events) and
      Enum.all?(events, fn entry ->
        is_map(entry) and map_size(entry) == 5 and digest?(entry["chain_digest"])
      end) and Source.valid_snapshot?(snapshot_without_chain(snapshot))
  end

  defp valid_final_snapshot?(_snapshot), do: false

  defp snapshot_without_chain(snapshot),
    do:
      Map.update(
        snapshot,
        "events",
        [],
        &Enum.map(&1, fn entry -> Map.delete(entry, "chain_digest") end)
      )

  defp valid_snapshot_metadata(metadata) when is_map(metadata) and not is_struct(metadata) do
    required = [
      "closing_receipt",
      "completeness",
      "counters",
      "freeze_id",
      "freeze_status",
      "gaps",
      "instance_id",
      "opening_receipt",
      "recorder_started_at_us",
      "retained_bytes",
      "retained_count",
      "trigger_event_id"
    ]

    if map_size(metadata) == length(required) and Enum.sort(Map.keys(metadata)) == required and
         is_integer(metadata["retained_count"]) and metadata["retained_count"] >= 0 and
         is_integer(metadata["retained_bytes"]) and metadata["retained_bytes"] >= 0 do
      # Full receipt/event coherence is checked after the separately redacted
      # event roots are reattached.
      :ok
    else
      {:error, :invalid_snapshot}
    end
  end

  defp valid_snapshot_metadata(_metadata), do: {:error, :invalid_snapshot}

  defp valid_redaction?(
         %{
           "consumption" => consumption,
           "export_policy_fingerprint" => export_fingerprint,
           "manifest" => manifest,
           "policy_fingerprint" => policy_fingerprint,
           "policy_id" => policy_id,
           "root_sensitivities" => sensitivities
         } = redaction,
         snapshot
       )
       when map_size(redaction) == 6 do
    bounded_id?(policy_id, 48) and digest?(policy_fingerprint) and digest?(export_fingerprint) and
      valid_sensitivities?(sensitivities) and
      valid_manifest?(manifest, policy_id, policy_fingerprint, length(snapshot["events"])) and
      valid_consumption?(consumption, length(manifest))
  rescue
    _error -> false
  end

  defp valid_redaction?(_redaction, _snapshot), do: false

  defp valid_sensitivities?(sensitivities)
       when is_map(sensitivities) and not is_struct(sensitivities) do
    keys = ["artifacts", "authority", "event", "finding", "provenance", "snapshot"]

    map_size(sensitivities) == length(keys) and Enum.sort(Map.keys(sensitivities)) == keys and
      Enum.all?(sensitivities, fn {_root, value} ->
        value in ["public", "internal", "confidential", "secret"]
      end)
  end

  defp valid_sensitivities?(_sensitivities), do: false

  defp valid_manifest?(manifest, policy_id, fingerprint, event_count) do
    Value.valid_list?(manifest, @maximum_manifest_records, 131_072) and
      Enum.all?(manifest, fn
        %{"action" => action, "count" => count, "path" => [root | rest], "policy_id" => bound} =
            record
        when map_size(record) == 4 ->
          action in ["drop", "mask"] and is_integer(count) and count in 1..@maximum_integer and
            valid_manifest_root?(root, event_count) and valid_manifest_path?(rest) and
            bound == policy_id <> ":" <> fingerprint

        _record ->
          false
      end) and manifest == Enum.sort_by(manifest, &Canonical.encode/1) and
      Enum.uniq_by(manifest, &{&1["action"], &1["path"], &1["policy_id"]}) == manifest
  end

  defp valid_manifest_root?(root, _event_count)
       when root in [
              "root:finding",
              "root:snapshot",
              "root:provenance",
              "root:authority",
              "root:artifacts"
            ],
       do: true

  defp valid_manifest_root?("root:event:" <> index, event_count) do
    case Integer.parse(index) do
      {value, ""} -> value >= 0 and value < event_count and Integer.to_string(value) == index
      _error -> false
    end
  end

  defp valid_manifest_root?(_root, _event_count), do: false

  defp valid_manifest_path?(path) do
    Value.valid_list?(path, 8, 2_048) and
      path
      |> Enum.with_index()
      |> Enum.all?(fn
        {"each:*", index} -> index == length(path) - 1
        {segment, _index} -> valid_manifest_segment?(segment)
      end)
  end

  defp valid_manifest_segment?("key:" <> key),
    do: byte_size(key) in 1..128 and String.valid?(key)

  defp valid_manifest_segment?("index:" <> index) do
    case Integer.parse(index) do
      {value, ""} -> value in 0..127 and Integer.to_string(value) == index
      _error -> false
    end
  end

  defp valid_manifest_segment?(_segment), do: false

  defp valid_consumption?(
         %{
           "input_bytes" => input,
           "manifest_records" => records,
           "nodes" => nodes,
           "output_bytes" => output
         } = consumption,
         expected_records
       )
       when map_size(consumption) == 4,
       do:
         is_integer(input) and input in 0..@maximum_consumption_input_bytes and
           is_integer(records) and records in 0..@maximum_manifest_records and
           is_integer(nodes) and nodes in 0..@maximum_consumption_nodes and
           is_integer(output) and output in 0..@maximum_consumption_output_bytes and
           records == expected_records

  defp valid_consumption?(_consumption, _expected_records), do: false

  defp redacted_provenance_bound?(provenance, %{"policy_fingerprint" => fingerprint}),
    do: redacted_provenance_bound?(provenance, fingerprint)

  defp redacted_provenance_bound?(provenance, %{fingerprint: fingerprint}),
    do: redacted_provenance_bound?(provenance, fingerprint)

  defp redacted_provenance_bound?(provenance, fingerprint) when is_binary(fingerprint) do
    provenance["components"]
    |> Enum.all?(fn {_name, component} ->
      component["status"] != "redacted" or component["policy_fingerprint"] == fingerprint
    end)
  rescue
    _error -> false
  end

  defp rooted(manifest, root) do
    Enum.map(manifest, fn record ->
      Map.update!(record, "path", &["root:" <> root | &1])
    end)
  end

  defp append_manifests(existing, manifest, root) do
    remaining = @maximum_manifest_records - length(existing)

    if ProtocolValue.bounded_list?(manifest, remaining) do
      {:ok, existing ++ rooted(manifest, root)}
    else
      limit_exceeded(:manifest_records)
    end
  end

  defp zero_consumption,
    do: %{"nodes" => 0, "input_bytes" => 0, "output_bytes" => 0}

  defp add_consumption(consumption, outcome) do
    %{
      "nodes" => consumption["nodes"] + outcome.consumption.nodes,
      "input_bytes" => consumption["input_bytes"] + outcome.consumption.input_bytes,
      "output_bytes" => consumption["output_bytes"] + outcome.consumption.output_bytes
    }
  end

  defp bounded_event_list?(value), do: bounded_event_list?(value, 0)
  defp bounded_event_list?([], _count), do: true
  defp bounded_event_list?(_value, count) when count >= 64, do: false
  defp bounded_event_list?([_head | tail], count), do: bounded_event_list?(tail, count + 1)
  defp bounded_event_list?(_value, _count), do: false

  defp exact_options(options) do
    if ProtocolValue.bounded_list?(options, length(@option_keys)) and Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      deadline = Keyword.get(options, :deadline_monotonic_us)

      if keys == Enum.uniq(keys) and keys -- @option_keys == [] and
           Enum.all?(@required_option_keys, &(&1 in keys)) and
           (is_nil(deadline) or
              (is_integer(deadline) and
                 deadline in -9_223_372_036_854_775_808..9_223_372_036_854_775_807)) do
        :ok
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp map_to_struct_fields(payload) do
    [
      schema: payload["schema"],
      id: payload["id"],
      finding: payload["finding"],
      snapshot: payload["snapshot"],
      provenance: payload["provenance"],
      authority: payload["authority"],
      redaction: payload["redaction"],
      artifacts: payload["artifacts"],
      integrity: payload["integrity"]
    ]
  end

  defp exact_struct?(capsule),
    do:
      map_size(capsule) == map_size(struct(__MODULE__)) and
        Enum.sort(Map.keys(capsule)) == Enum.sort(Map.keys(struct(__MODULE__)))

  defp valid_integrity_shape?(
         %{
           "algorithm" => "sha256",
           "content_digest" => content_digest,
           "event_chain_head" => event_chain_head
         } = integrity
       )
       when map_size(integrity) == 3,
       do: digest?(content_digest) and digest?(event_chain_head)

  defp valid_integrity_shape?(_integrity), do: false

  defp digest(value) do
    :sha256
    |> :crypto.hash(Canonical.encode(value))
    |> Base.encode16(case: :lower)
  end

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp bounded_id?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp truth(true, _reason), do: :ok
  defp truth(false, reason), do: {:error, reason}

  defp manifest_bound(manifests) do
    if length(manifests) <= @maximum_manifest_records,
      do: :ok,
      else: {:error, :manifest_limit}
  end

  defp before_deadline(deadline) do
    if System.monotonic_time(:microsecond) <= deadline,
      do: :ok,
      else: deadline_exceeded()
  end

  defp before_optional_deadline(nil), do: :ok
  defp before_optional_deadline(deadline), do: before_deadline(deadline)

  defp deadline_exceeded,
    do: {:error, Error.new(:deadline_exceeded, "capsule assembly deadline expired")}

  defp unsupported_schema(schema) do
    {:error,
     Error.new(:unsupported_capsule_schema, "capsule schema is unsupported", %{
       received: ProtocolValue.summary(schema)
     })}
  end

  defp integrity_failed,
    do: {:error, Error.new(:capsule_integrity_failed, "capsule integrity validation failed")}

  defp limit_exceeded(limit),
    do:
      {:error,
       Error.new(:capsule_limit_exceeded, "capsule limit exceeded", %{
         limit: Atom.to_string(limit)
       })}

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_capsule, "capsule is invalid", %{reason: Atom.to_string(reason)})}

  defp invalid_value(value),
    do:
      {:error,
       Error.new(:invalid_capsule, "capsule is invalid", %{received: ProtocolValue.summary(value)})}
end
