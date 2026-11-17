defmodule Insider.Sentinel.SourceOwnership do
  @moduledoc """
  A canonical, offline source-ownership routing companion for a draft proposal.

  This artifact reads only caller-supplied declaration bytes and the exact
  proposal candidate. Its owner labels are opaque, declared, and unverified;
  they are routing hints, never identities, permissions, or assignments.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.source-ownership/v1"
  @maximum_bytes 65_536
  @maximum_term_bytes 131_072
  @maximum_declaration_bytes 16_384
  @maximum_lines 256
  @maximum_line_bytes 512
  @maximum_rules 128
  @maximum_paths 64
  @maximum_path_bytes 256
  @maximum_pattern_bytes 256
  @maximum_owner_bytes 64
  @maximum_owners_per_rule 16
  @fields [
    :schema,
    :id,
    :kind,
    :controls,
    :trust,
    :proposal,
    :candidate,
    :declaration,
    :attributions,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @controls %{
    "assignment" => "prohibited",
    "authorization" => "prohibited",
    "mutation" => "none",
    "network_effect" => "none"
  }
  @trust %{
    "attribution" => "routing_only",
    "declaration" => "caller_supplied_unverified",
    "owners" => "opaque_declared_labels"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Builds routing hints from an exact proposal and direct declaration bytes."
  @spec new(term(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def new(proposal, declaration) do
    with {:ok, proposal, proposal_bytes} <- canonical_proposal(proposal),
         {:ok, candidate, candidate_bytes} <- proposal_candidate(proposal),
         {:ok, diff} <- Candidate.content(candidate),
         {:ok, paths} <- changed_paths(diff),
         {:ok, rules} <- parse_declaration(declaration),
         {:ok, attributions} <- attribute(paths, rules) do
      body = %{
        "schema" => @schema,
        "kind" => "declared_unverified_source_ownership",
        "controls" => @controls,
        "trust" => @trust,
        "proposal" => reference(proposal, proposal_bytes),
        "candidate" => reference(candidate, candidate_bytes),
        "declaration" => declaration_reference(declaration),
        "attributions" => attributions
      }

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:construction_failed)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @doc "Validates standalone canonical structure and content identity only."
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = ownership) do
    wire = to_wire_map(ownership)

    with true <- Enum.sort(Map.keys(Map.from_struct(ownership))) == Enum.sort(@fields),
         true <- ownership.schema == @schema,
         true <- ownership.kind == "declared_unverified_source_ownership",
         true <- ownership.controls == @controls,
         true <- ownership.trust == @trust,
         true <- valid_reference?(ownership.proposal, "insider.draft-proposal/v1"),
         true <- valid_reference?(ownership.candidate, "insider.verification-candidate/v1"),
         true <- valid_declaration?(ownership.declaration),
         true <- valid_attributions?(ownership.attributions),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         true <- valid_integrity?(ownership.integrity),
         true <- ownership.id == "sha256:" <> ownership.integrity["content_digest"],
         true <- ownership.integrity["content_digest"] == Canonical.sha256(content(ownership)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, ownership}
    else
      _other -> invalid(:invalid_ownership)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes routing from the exact proposal and exact declaration bytes."
  @spec validate_with_proposal(term(), term(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def validate_with_proposal(ownership, proposal, declaration) do
    with {:ok, valid} <- validate(ownership),
         {:ok, expected} <- new(proposal, declaration),
         true <- to_wire_map(valid) == to_wire_map(expected) do
      {:ok, valid}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(ownership) do
    with {:ok, valid} <- validate(ownership), do: {:ok, Canonical.encode(to_wire_map(valid))}
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
  def to_wire_map(%__MODULE__{} = ownership) do
    %{
      "schema" => ownership.schema,
      "id" => ownership.id,
      "kind" => ownership.kind,
      "controls" => ownership.controls,
      "trust" => ownership.trust,
      "proposal" => ownership.proposal,
      "candidate" => ownership.candidate,
      "declaration" => ownership.declaration,
      "attributions" => ownership.attributions,
      "integrity" => ownership.integrity
    }
  end

  defp canonical_proposal(binary) when is_binary(binary) do
    with {:ok, proposal} <- DraftProposal.decode(binary), do: {:ok, proposal, binary}
  end

  defp canonical_proposal(proposal) do
    with {:ok, proposal} <- DraftProposal.validate(proposal),
         {:ok, bytes} <- DraftProposal.canonical_binary(proposal),
         do: {:ok, proposal, bytes}
  end

  defp proposal_candidate(proposal) do
    with candidate_wire when is_map(candidate_wire) <- get_in(proposal.evidence, ["candidate"]),
         {:ok, candidate} <- Candidate.decode_map(candidate_wire),
         true <- candidate.format == "unified-diff/v1",
         {:ok, bytes} <- Candidate.canonical_binary(candidate) do
      {:ok, candidate, bytes}
    else
      false -> diff_invalid(:unsupported_candidate_format)
      {:error, %Error{}} -> diff_invalid(:invalid_candidate)
      _other -> diff_invalid(:invalid_candidate)
    end
  end

  defp changed_paths(diff) when is_binary(diff) and byte_size(diff) in 1..16_384 do
    lines = String.split(diff, "\n", trim: false)

    if String.valid?(diff) and length(lines) <= @maximum_lines and
         Enum.all?(lines, &(byte_size(&1) <= @maximum_line_bytes)) do
      parse_diff(lines, [], MapSet.new())
    else
      diff_invalid(:unsafe_diff)
    end
  end

  defp changed_paths(_value), do: diff_invalid(:unsafe_diff)

  defp parse_diff([], [], _seen), do: diff_invalid(:missing_file_patch)
  defp parse_diff([], paths, _seen), do: {:ok, Enum.sort(paths)}

  defp parse_diff([""], paths, seen), do: parse_diff([], paths, seen)

  defp parse_diff(["diff --git " <> header | rest], paths, seen) do
    with {:ok, old_path, new_path} <- parse_git_header(header),
         {:ok, metadata, marker_old, marker_new, remaining} <- patch_preamble(rest),
         {:ok, path, patch_type} <-
           patch_path(old_path, new_path, metadata, marker_old, marker_new),
         false <- MapSet.member?(seen, path),
         true <- length(paths) < @maximum_paths,
         {:ok, body} <- patch_body(remaining, patch_type),
         {:ok, next} <- parse_diff(body, [path | paths], MapSet.put(seen, path)) do
      {:ok, next}
    else
      true -> diff_invalid(:duplicate_path)
      false -> diff_invalid(:too_many_paths)
      {:error, %Error{} = error} -> {:error, error}
      _other -> diff_invalid(:malformed_diff)
    end
  end

  defp parse_diff(_lines, _paths, _seen), do: diff_invalid(:malformed_diff)

  defp parse_git_header(header) do
    case String.split(header, " ", parts: 2) do
      ["a/" <> old_path, "b/" <> new_path] when old_path != "" and new_path != "" ->
        if safe_path?(old_path) and safe_path?(new_path),
          do: {:ok, old_path, new_path},
          else: diff_invalid(:unsafe_path)

      _other ->
        diff_invalid(:malformed_header)
    end
  end

  defp patch_preamble(lines),
    do: consume_metadata(lines, %{index: nil, new_file: nil, deleted_file: nil})

  defp consume_metadata(["index " <> value | rest], %{index: nil} = metadata) do
    case parse_index(value) do
      {:ok, index} -> consume_metadata(rest, %{metadata | index: index})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp consume_metadata(["new file mode " <> mode | rest], %{new_file: nil} = metadata) do
    if regular_mode?(mode),
      do: consume_metadata(rest, %{metadata | new_file: mode}),
      else: diff_invalid(:unsafe_mode)
  end

  defp consume_metadata(["deleted file mode " <> mode | rest], %{deleted_file: nil} = metadata) do
    if regular_mode?(mode),
      do: consume_metadata(rest, %{metadata | deleted_file: mode}),
      else: diff_invalid(:unsafe_mode)
  end

  defp consume_metadata(["--- " <> old_marker, "+++ " <> new_marker | rest], metadata),
    do: {:ok, metadata, old_marker, new_marker, rest}

  defp consume_metadata(_lines, _metadata), do: diff_invalid(:unsupported_metadata)

  defp parse_index(value) do
    case Regex.run(~r/\A([0-9a-f]{7,64})\.\.([0-9a-f]{7,64})(?: ([0-7]{6}))?\z/, value) do
      [_, old, new] -> {:ok, %{old: old, new: new, mode: nil}}
      [_, old, new, mode] -> {:ok, %{old: old, new: new, mode: mode}}
      _other -> diff_invalid(:malformed_index)
    end
  end

  defp regular_mode?(mode), do: mode in ["100644", "100755"]
  defp null_hash?(hash), do: String.match?(hash, ~r/\A0+\z/)

  defp patch_path(old_path, new_path, metadata, marker_old, marker_new) do
    case {marker_old, marker_new} do
      {"/dev/null", "b/" <> marker} when marker == new_path and old_path == new_path ->
        validate_add(metadata, new_path)

      {"a/" <> marker, "/dev/null"} when marker == old_path and old_path == new_path ->
        validate_delete(metadata, old_path)

      {"a/" <> old_marker, "b/" <> new_marker}
      when old_marker == old_path and new_marker == new_path and old_path == new_path ->
        validate_modify(metadata, old_path)

      _other ->
        diff_invalid(:unsafe_path)
    end
  end

  defp validate_add(%{new_file: mode, deleted_file: nil, index: index}, path)
       when not is_nil(mode) and not is_nil(index) do
    if null_hash?(index.old) and not null_hash?(index.new) and index.mode in [nil, mode],
      do: {:ok, path, :add},
      else: diff_invalid(:incoherent_add)
  end

  defp validate_add(_metadata, _path), do: diff_invalid(:incoherent_add)

  defp validate_delete(%{new_file: nil, deleted_file: mode, index: index}, path)
       when not is_nil(mode) and not is_nil(index) do
    if not null_hash?(index.old) and null_hash?(index.new) and index.mode in [nil, mode],
      do: {:ok, path, :delete},
      else: diff_invalid(:incoherent_delete)
  end

  defp validate_delete(_metadata, _path), do: diff_invalid(:incoherent_delete)

  defp validate_modify(%{new_file: nil, deleted_file: nil, index: index}, path)
       when not is_nil(index) do
    if not null_hash?(index.old) and not null_hash?(index.new) and index.old != index.new and
         index.mode in [nil, "100644", "100755"],
       do: {:ok, path, :modify},
       else: diff_invalid(:incoherent_modify)
  end

  defp validate_modify(_metadata, _path), do: diff_invalid(:incoherent_modify)

  defp patch_body(lines, patch_type) do
    {body, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "diff --git ")))

    if coherent_hunks?(body, patch_type),
      do: {:ok, rest},
      else: diff_invalid(:unsafe_patch_body)
  end

  defp coherent_hunks?(lines, patch_type) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.reduce_while(%{current: nil}, fn line, %{current: current} = state ->
      parsed_hunk = parse_hunk_header(line)

      cond do
        not String.valid?(line) or byte_size(line) > @maximum_line_bytes or
            String.contains?(line, ["\r", "\0"]) ->
          {:halt, :invalid}

        match?({:ok, _hunk}, parsed_hunk) ->
          {:ok, hunk} = parsed_hunk

          case finish_hunk(current) do
            :ok -> {:cont, %{state | current: Map.put(hunk, :patch_type, patch_type)}}
            :error -> {:halt, :invalid}
          end

        not is_nil(current) and String.starts_with?(line, "+") ->
          {:cont, %{state | current: %{current | new_seen: current.new_seen + 1, changed?: true}}}

        not is_nil(current) and String.starts_with?(line, "-") ->
          {:cont, %{state | current: %{current | old_seen: current.old_seen + 1, changed?: true}}}

        not is_nil(current) and String.starts_with?(line, " ") ->
          {:cont,
           %{
             state
             | current: %{
                 current
                 | old_seen: current.old_seen + 1,
                   new_seen: current.new_seen + 1
               }
           }}

        not is_nil(current) and line == "\\ No newline at end of file" ->
          {:cont, state}

        true ->
          {:halt, :invalid}
      end
    end)
    |> case do
      %{current: current} when not is_nil(current) -> finish_hunk(current) == :ok
      _other -> false
    end
  end

  defp parse_hunk_header(line) do
    case Regex.named_captures(
           ~r/\A@@ -(?<old_start>\d+)(?:,(?<old_count>\d+))? \+(?<new_start>\d+)(?:,(?<new_count>\d+))? @@(?: .*)?\z/,
           line
         ) do
      %{
        "old_start" => old_start,
        "old_count" => old_count,
        "new_start" => new_start,
        "new_count" => new_count
      } ->
        with {:ok, old_start} <- hunk_number(old_start),
             {:ok, old_count} <- hunk_count(old_start, old_count),
             {:ok, new_start} <- hunk_number(new_start),
             {:ok, new_count} <- hunk_count(new_start, new_count),
             true <- valid_hunk_range?(old_start, old_count),
             true <- valid_hunk_range?(new_start, new_count) do
          {:ok,
           %{
             old_start: old_start,
             old_count: old_count,
             old_seen: 0,
             new_start: new_start,
             new_count: new_count,
             new_seen: 0,
             changed?: false
           }}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp hunk_number(value) when byte_size(value) in 1..7 do
    case Integer.parse(value) do
      {number, ""} when number in 0..1_000_000 -> {:ok, number}
      _other -> :error
    end
  end

  defp hunk_number(_value), do: :error

  defp hunk_count(0, nil), do: :error
  defp hunk_count(0, ""), do: :error
  defp hunk_count(_start, nil), do: {:ok, 1}
  defp hunk_count(_start, ""), do: {:ok, 1}
  defp hunk_count(_start, value), do: hunk_number(value)

  defp valid_hunk_range?(0, 0), do: true
  defp valid_hunk_range?(0, _positive_count), do: false
  defp valid_hunk_range?(_positive_start, _count), do: true

  defp finish_hunk(nil), do: :ok

  defp finish_hunk(%{
         old_count: old_count,
         old_seen: old_count,
         new_count: new_count,
         new_seen: new_count,
         changed?: true,
         patch_type: patch_type
       }) do
    if coherent_patch_type?(patch_type, old_count, new_count), do: :ok, else: :error
  end

  defp finish_hunk(_hunk), do: :error

  defp coherent_patch_type?(:add, 0, _new_count), do: true
  defp coherent_patch_type?(:delete, _old_count, 0), do: true
  defp coherent_patch_type?(:modify, _old_count, _new_count), do: true
  defp coherent_patch_type?(_type, _old_count, _new_count), do: false

  defp parse_declaration(declaration)
       when is_binary(declaration) and byte_size(declaration) <= @maximum_declaration_bytes do
    if String.valid?(declaration) and not String.contains?(declaration, ["\r", "\0"]) do
      lines = String.split(declaration, "\n", trim: false)

      if length(lines) <= @maximum_lines and
           Enum.all?(lines, &(byte_size(&1) <= @maximum_line_bytes)) do
        lines
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, rules} ->
          case parse_rule(line) do
            :skip ->
              {:cont, {:ok, rules}}

            {:ok, rule} when length(rules) < @maximum_rules ->
              {:cont, {:ok, [rule | rules]}}

            {:ok, _rule} ->
              {:halt, declaration_invalid(:too_many_rules)}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, rules} -> {:ok, Enum.reverse(rules)}
          error -> error
        end
      else
        declaration_invalid(:unsafe_declaration)
      end
    else
      declaration_invalid(:unsafe_declaration)
    end
  end

  defp parse_declaration(declaration) when is_binary(declaration), do: limit_exceeded()
  defp parse_declaration(_value), do: declaration_invalid(:invalid_declaration)

  defp parse_rule(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        :skip

      String.contains?(trimmed, "#") ->
        declaration_invalid(:inline_comment)

      true ->
        case String.split(trimmed, ~r/[\t ]+/, trim: true) do
          [pattern | owners] when owners != [] ->
            with {:ok, pattern} <- parse_pattern(pattern),
                 true <- length(owners) <= @maximum_owners_per_rule,
                 true <- Enum.uniq(owners) == owners,
                 true <- Enum.all?(owners, &owner_label?/1) do
              {:ok, %{pattern: pattern, owners: owners}}
            else
              false -> declaration_invalid(:invalid_owner)
              {:error, %Error{} = error} -> {:error, error}
            end

          _other ->
            declaration_invalid(:malformed_rule)
        end
    end
  end

  defp parse_pattern(pattern)
       when is_binary(pattern) and byte_size(pattern) in 1..@maximum_pattern_bytes do
    rooted? = String.starts_with?(pattern, "/")
    raw = if rooted?, do: String.replace_prefix(pattern, "/", ""), else: pattern

    {raw, recursive?} =
      cond do
        String.ends_with?(raw, "/**") -> {String.replace_suffix(raw, "/**", ""), true}
        String.ends_with?(raw, "/") -> {String.replace_suffix(raw, "/", ""), true}
        true -> {raw, false}
      end

    with true <- raw != "" and safe_pattern_chars?(raw),
         false <- String.contains?(pattern, "//"),
         false <- String.starts_with?(raw, "/"),
         false <- String.contains?(raw, "**"),
         segments <- String.split(raw, "/", trim: false),
         true <- Enum.all?(segments, &safe_pattern_segment?/1) do
      {:ok,
       %{
         rooted?: rooted?,
         recursive?: recursive?,
         segments: segments
       }}
    else
      _other -> declaration_invalid(:unsafe_pattern)
    end
  end

  defp parse_pattern(_value), do: declaration_invalid(:unsafe_pattern)

  defp safe_pattern_chars?(value), do: String.match?(value, ~r/\A[a-zA-Z0-9_.*\/-]+\z/)

  defp safe_pattern_segment?(segment),
    do: segment not in ["", ".", ".."] and byte_size(segment) <= @maximum_path_bytes

  defp owner_label?(owner),
    do:
      is_binary(owner) and byte_size(owner) in 1..@maximum_owner_bytes and
        String.match?(owner, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp attribute(paths, rules) do
    {:ok,
     Enum.map(paths, fn path ->
       owners =
         rules
         |> Enum.filter(&matches?(&1.pattern, path))
         |> List.last()
         |> case do
           nil -> []
           rule -> rule.owners
         end

       %{"owners" => owners, "path" => path}
     end)}
  end

  defp matches?(
         %{segments: pattern, rooted?: rooted?, recursive?: recursive?},
         path
       ) do
    segments = String.split(path, "/")

    cond do
      recursive? ->
        length(segments) > length(pattern) and prefix_matches?(pattern, segments)

      not rooted? and length(pattern) == 1 ->
        segment_matches?(hd(pattern), List.last(segments))

      true ->
        length(pattern) == length(segments) and prefix_matches?(pattern, segments)
    end
  end

  defp prefix_matches?(pattern, path),
    do:
      Enum.zip(pattern, path) |> Enum.all?(fn {left, right} -> segment_matches?(left, right) end)

  defp segment_matches?(pattern, value) do
    pattern
    |> String.split("*", trim: false)
    |> match_star_parts(value)
  end

  defp match_star_parts([part], value), do: part == value

  defp match_star_parts([first | rest], value) do
    if String.starts_with?(value, first),
      do: match_star_tail(rest, String.replace_prefix(value, first, "")),
      else: false
  end

  defp match_star_tail([], _value), do: true
  defp match_star_tail([last], value), do: String.ends_with?(value, last)

  defp match_star_tail([part | rest], value) do
    case :binary.match(value, part) do
      {index, length} ->
        match_star_tail(
          rest,
          binary_part(value, index + length, byte_size(value) - index - length)
        )

      :nomatch ->
        false
    end
  end

  defp safe_path?(path) do
    is_binary(path) and byte_size(path) in 1..@maximum_path_bytes and String.valid?(path) and
      String.match?(path, ~r/\A[a-zA-Z0-9.][a-zA-Z0-9_.\/-]*\z/) and
      not String.contains?(path, "//") and
      Enum.all?(String.split(path, "/", trim: false), &safe_path_segment?/1)
  end

  defp safe_path_segment?(segment),
    do: segment not in ["", ".", ".."] and byte_size(segment) <= @maximum_path_bytes

  defp reference(artifact, bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => Canonical.sha256_binary(bytes),
      "id" => artifact.id,
      "schema" => artifact.schema
    }

  defp declaration_reference(declaration),
    do: %{"byte_size" => byte_size(declaration), "sha256" => Canonical.sha256_binary(declaration)}

  defp valid_reference?(
         %{
           "byte_size" => bytes,
           "canonical_sha256" => digest,
           "id" => "sha256:" <> id_digest,
           "schema" => schema
         } = ref,
         expected_schema
       ) do
    map_size(ref) == 4 and is_integer(bytes) and bytes > 0 and Input.digest?(digest) and
      Input.digest?(id_digest) and schema == expected_schema
  end

  defp valid_reference?(_value, _expected_schema), do: false

  defp valid_declaration?(%{"byte_size" => bytes, "sha256" => digest} = declaration),
    do:
      map_size(declaration) == 2 and is_integer(bytes) and bytes in 0..@maximum_declaration_bytes and
        Input.digest?(digest)

  defp valid_declaration?(_value), do: false

  defp valid_attributions?(attributions)
       when is_list(attributions) and length(attributions) in 1..@maximum_paths do
    paths = Enum.map(attributions, &Map.get(&1, "path"))

    paths == Enum.sort(paths) and Enum.uniq(paths) == paths and
      Enum.all?(attributions, &valid_attribution?/1)
  end

  defp valid_attributions?(_value), do: false

  defp valid_attribution?(%{"owners" => owners, "path" => path} = attribution),
    do:
      map_size(attribution) == 2 and safe_path?(path) and is_list(owners) and
        length(owners) <= @maximum_owners_per_rule and Enum.uniq(owners) == owners and
        Enum.all?(owners, &owner_label?/1)

  defp valid_attribution?(_value), do: false

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = value),
    do: map_size(value) == 2 and Input.digest?(digest)

  defp valid_integrity?(_value), do: false

  defp content(ownership), do: to_wire_map(ownership) |> Map.drop(["id", "integrity"])

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys do
      %__MODULE__{
        schema: wire["schema"],
        id: wire["id"],
        kind: wire["kind"],
        controls: wire["controls"],
        trust: wire["trust"],
        proposal: wire["proposal"],
        candidate: wire["candidate"],
        declaration: wire["declaration"],
        attributions: wire["attributions"],
        integrity: wire["integrity"]
      }
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_source_ownership, "source ownership is invalid", %{reason: reason})}

  defp diff_invalid(reason),
    do:
      {:error,
       Error.new(:source_ownership_diff_invalid, "candidate diff is unsafe or malformed", %{
         reason: reason
       })}

  defp declaration_invalid(reason),
    do:
      {:error,
       Error.new(
         :source_ownership_declaration_invalid,
         "ownership declaration is unsafe or malformed",
         %{reason: reason}
       )}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :source_ownership_integrity_failed,
         "source ownership does not match the supplied proposal and declaration"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:source_ownership_limit_exceeded, "source ownership exceeds its static limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_source_ownership_schema,
         "source ownership schema is unsupported",
         %{schema: Value.summary(schema)}
       )}
end
