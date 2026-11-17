defmodule Insider.Redaction.Credentials do
  @moduledoc """
  Credential masking for values that leave the node.

  Development data is anonymized before it reaches a developer machine, but a
  development node still holds real provider credentials from its
  environment. Every value an observer can read therefore passes this mask,
  whatever else its disclosure profile allows:

  - a non-empty value under a credential-named key (`password`, `secret`,
    `token`, `api_key`, `authorization`, `cookie`, `private_key`, and similar,
    matched case-insensitively within the key) becomes
    `"[REDACTED:credential_key]"`, whatever its type;
  - a secret-shaped span inside a string (an HTTP `Bearer` or `Basic`
    credential, a JWT, a PEM block, a well-known provider key format such as
    `sk_live_…`, the password in a URL, the value of a `password=…` style
    assignment, or a long high-entropy token) becomes `"[REDACTED:<reason>]"`
    and the rest of the string stays readable.

  `mask/1` returns one manifest record per masked path and reason, with a
  count and never the value.
  """

  @policy_id "insider-credential-masking/v1"
  @max_records 32
  @max_path_segments 8
  @max_key_bytes 64
  @min_entropy_bits 4.0
  @max_authority_bytes 2_048

  # Lowercase, `-` and space folded to `_`, matched as substrings of a key.
  @key_terms [
    "access_key",
    "api_key",
    "apikey",
    "authorization",
    "bearer",
    "client_key",
    "cookie",
    "credential",
    "encryption_key",
    "jwt",
    "passphrase",
    "passwd",
    "password",
    "private_key",
    "privatekey",
    "secret",
    "session_key",
    "signing_key",
    "token"
  ]

  @key_pattern "[A-Za-z0-9_.-]*(?:password|passwd|passphrase|secret|token|api[_-]?key|" <>
                 "authorization|cookie|private[_-]?key|access[_-]?key|credential|" <>
                 "signing[_-]?key|encryption[_-]?key|session[_-]?key|client[_-]?key|jwt)" <>
                 "[A-Za-z0-9_.-]*+"
  @quoted ~S/"(?:[^"\\]|\\.)*(?:"|\z)|'(?:[^'\\]|\\.)*(?:'|\z)/
  # A balanced (or cut-off) inspect container: `%{…}`, `%Name{…}`, `{…}`, or
  # `[…]`, so a credential-named field holding a map or list is masked whole.
  @container ~S/%?[A-Za-z0-9_.]*(?<brace>\{(?:[^{}"]++|"(?:[^"\\]|\\.)*+"|(?&brace))*+(?:\}|\z))/ <>
               ~S/|(?<bracket>\[(?:[^\[\]"]++|"(?:[^"\\]|\\.)*+"|(?&bracket))*+(?:\]|\z))/
  @not_masked ~S/(?!\[REDACTED:|"\[REDACTED:|'\[REDACTED:|\$\d|\?)/

  # Ordered: the specific shapes run first, so an assignment whose value is
  # already a marker is left alone. Each entry is `{reason, source, options,
  # scope}`; `:value` patterns keep the first capture (the key and separator)
  # and replace the second, `:whole` patterns replace the whole match, and
  # the `:url` pattern finds candidates that `mask_urls/3` decides.
  # Inputs are up to 8 KiB of arbitrary text, so token runs use possessive
  # quantifiers and key matches start only at a token boundary: no pattern
  # backtracks quadratically over a long run.
  @pattern_sources [
    {"pem_block", ~S/-----BEGIN [A-Z0-9 ]{1,64}-----.*?(?:-----END [A-Z0-9 ]{1,64}-----|\z)/, "s",
     :whole},
    {"jwt", ~S/\beyJ[A-Za-z0-9_-]{4,}+\.eyJ[A-Za-z0-9_-]{4,}+(?:\.[A-Za-z0-9_-]*+)?/, "", :whole},
    # HTTP authentication schemes are case-insensitive. Any non-empty Bearer
    # token is masked; the shortest Basic credential (`a:b`) is 4 base64
    # characters.
    {"authorization_header",
     ~S'\b(?i:bearer)\s+[A-Za-z0-9\-._~+/]++=*+|\b(?i:basic|digest)\s+[A-Za-z0-9\-._~+/]{4,}+=*+',
     "", :whole},
    {"provider_key",
     ~S'\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9+/=]{8,}' <>
       ~S/|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}/ <>
       ~S/|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,}/ <>
       ~S/|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}/ <>
       ~S/|npm_[A-Za-z0-9]{30,}|shp(?:at|ss|ca|pa)_[A-Fa-f0-9]{32})/, "", :whole},
    # URL userinfo is decided by `mask_urls/3`, not by a regex: this pattern
    # only finds each `scheme://` and, without consuming it, the candidate
    # authority after it (see `url_mask_range/1`).
    {"url_credentials",
     ~S'\b[a-zA-Z][a-zA-Z0-9+.-]{1,31}://(?=((?:\[REDACTED:[a-z_]{1,32}\]|[^\s/"\]}<>\\])*+))',
     "", :url},
    # The separator is atomic: after `=>` the regex may not fall back to `=`
    # and take `>` as the value of an already masked assignment.
    {"credential_assignment",
     "((?<![A-Za-z0-9_.-])[\"']?" <>
       @key_pattern <>
       "[\"']?(?>\\s*(?:=>|=|:)\\s*))" <>
       @not_masked <>
       "(~[a-zA-Z](?:" <>
       @quoted <>
       ")|" <> @quoted <> "|" <> @container <> "|[^\\s\"',;&)}\\]>]+)", "i", :value},
    {"credential_assignment",
     "((?::|[\"'])" <>
       @key_pattern <>
       "[\"']?(?>\\s*,\\s*))" <>
       @not_masked <>
       "(~[a-zA-Z](?:" <> @quoted <> ")|" <> @quoted <> "|" <> @container <> ")", "i", :value},
    {"high_entropy", ~S'(?<![A-Za-z0-9_\-+/=])[A-Za-z0-9_\-+/]{32,}+={0,2}+(?![A-Za-z0-9_\-+/=])',
     "", :whole}
  ]
  @marker_source ~S/\[REDACTED:([a-z_]+)\]/

  @reasons [
    "authorization_header",
    "credential_assignment",
    "credential_key",
    "high_entropy",
    "jwt",
    "pem_block",
    "provider_key",
    "redacted_field",
    "url_credentials"
  ]

  @doc "The masking policy id carried by every mask record."
  @spec policy_id() :: String.t()
  def policy_id, do: @policy_id

  @doc false
  # The longest URL authority candidate that is classified rather than
  # masked whole.
  @spec max_url_authority_bytes() :: pos_integer()
  def max_url_authority_bytes, do: @max_authority_bytes

  @doc "Every reason a mask record or marker can carry."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc false
  # The compiled masking patterns as `{reason, regex}`, so tests can bound
  # their matching cost on adversarial input.
  @spec patterns() :: [{String.t(), Regex.t()}]
  def patterns,
    do: Enum.map(compiled().patterns, fn {reason, regex, _scope} -> {reason, regex} end)

  @doc """
  Compiles the masking patterns once for this module version, so a later
  caller with a time budget does not pay for it.
  """
  @spec warm() :: :ok
  def warm do
    _compiled = compiled()
    :ok
  end

  @doc """
  Whether `key` names a credential. Binary and atom keys are checked; any
  other term is not a credential name.
  """
  @spec credential_key?(term()) :: boolean()
  def credential_key?(key) when is_atom(key) and not is_boolean(key) and not is_nil(key),
    do: key |> Atom.to_string() |> credential_key?()

  def credential_key?(key) when is_binary(key) and byte_size(key) <= 256 do
    folded = key |> String.downcase() |> String.replace(["-", " "], "_")
    String.contains?(folded, @key_terms)
  end

  # Fails closed: a key too long to classify cheaply is treated as one.
  def credential_key?(key) when is_binary(key), do: true

  def credential_key?(_key), do: false

  @doc """
  Replaces every secret-shaped span of `text` with `"[REDACTED:<reason>]"`.
  """
  @spec mask_text(String.t()) :: String.t()
  def mask_text(text) when is_binary(text) do
    Enum.reduce(compiled().patterns, text, fn
      {reason, pattern, :url}, text ->
        mask_urls(text, pattern, reason)

      {reason, pattern, scope}, text ->
        Regex.replace(pattern, text, fn whole, prefix, _value ->
          if scope == :value, do: prefix <> marker(reason), else: mask_whole(reason, whole)
        end)
    end)
  end

  # URL userinfo. The pattern yields, for each `scheme://`, the candidate
  # authority after it: the bytes up to the first character that can end a
  # URL value and can never be part of userinfo (whitespace, `/`, `"`, `]`,
  # `}`, `<`, `>`, `\`). A marker an earlier pattern left (`[REDACTED:…]`)
  # is one opaque token of the candidate, so its `]` never ends it: a
  # provider key or JWT inside userinfo cannot hide the rest of the
  # credential. The delimiter is always found, never a scan limit,
  # so a candidate is never cut inside a credential or a UTF-8 character.
  # Candidates never overlap, since each stops before the next `//`, so
  # finding them is linear in the text. Only a candidate of at most
  # `@max_authority_bytes` is classified; a longer one is masked whole up to
  # its last `@` (or its end), so no unexamined text survives. Their mask ranges are merged
  # and replaced in one pass. A second URL inside a masked range is still
  # decided: `http://a:b,postgres://u:p@h` masks both passwords.
  defp mask_urls(text, pattern, reason) do
    ranges =
      for [_whole, {start, length}] <- Regex.scan(pattern, text, return: :index),
          {from, to} <- [url_mask_range(binary_part(text, start, length))],
          do: {start + from, start + to}

    case ranges do
      [] -> text
      ranges -> replace_ranges(text, merge_ranges(Enum.sort(ranges)), marker(reason))
    end
  end

  # When unsure, mask: a leaked credential is worse than a masked port.
  #
  # - A candidate starting with `[` that is not a marker is an IP literal host
  #   (`[::1]:4000`), so it has no userinfo to mask.
  # - The authority proper ends at the first `?` or `#`. If it holds an `@`,
  #   everything before the last one is userinfo: the part after its first
  #   `:` is masked, or all of it when it has no `:` (a bare token).
  # - Otherwise, if the authority has a `:`, what follows is a port only when
  #   it is one to five digits followed by a query, a fragment, or nothing
  #   but closing `'`, `,`, `;`, `)` to the end of the candidate. Anything
  #   else is a password, possibly cut short, masked up to the candidate's
  #   last `@` or its end. Residual risk: a cut that leaves exactly an
  #   all-digit password of at most five digits at the end of a value, or a
  #   password holding a raw `?` or `#` (invalid in userinfo) right after
  #   such digits, reads as a port and stays visible.
  # - So an ambiguous unquoted list such as `http://h:4100,a@b` is masked as
  #   `user:password@`.
  #
  # Classification reads the candidate with each marker replaced by as many
  # `x` bytes, so a marker's `:` is never taken for the userinfo separator,
  # its `]` never for an IP literal, and a marker in a password is masked
  # with the rest of it. Offsets are unchanged, since markers are ASCII.
  defp url_mask_range(candidate) do
    view =
      Regex.replace(compiled().marker, candidate, fn marker, _reason ->
        String.duplicate("x", byte_size(marker))
      end)

    classify_authority(view)
  end

  # An IP literal host such as `[::1]:4000`.
  defp classify_authority("[" <> _ip_literal), do: nil

  defp classify_authority(candidate) when byte_size(candidate) > @max_authority_bytes,
    do: {0, last_at(candidate) || byte_size(candidate)}

  defp classify_authority(candidate) do
    authority =
      case :binary.match(candidate, ["?", "#"]) do
        {end_at, _length} -> binary_part(candidate, 0, end_at)
        :nomatch -> candidate
      end

    case last_at(authority) do
      nil -> password_range(candidate, authority)
      at -> userinfo_range(binary_part(authority, 0, at))
    end
  end

  defp userinfo_range(""), do: nil

  defp userinfo_range(userinfo) do
    case :binary.match(userinfo, ":") do
      {colon, 1} when colon + 1 < byte_size(userinfo) -> {colon + 1, byte_size(userinfo)}
      {_colon, 1} -> nil
      :nomatch -> {0, byte_size(userinfo)}
    end
  end

  defp password_range(candidate, authority) do
    with {colon, 1} <- :binary.match(authority, ":"),
         rest = binary_part(candidate, colon + 1, byte_size(candidate) - colon - 1),
         false <- Regex.match?(compiled().port, rest),
         to = last_at(candidate) || byte_size(candidate),
         true <- to > colon + 1 do
      {colon + 1, to}
    else
      _no_password -> nil
    end
  end

  defp last_at(binary) do
    case :binary.matches(binary, "@") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp merge_ranges([{from, to}, {next_from, next_to} | rest]) when next_from <= to,
    do: merge_ranges([{from, max(to, next_to)} | rest])

  defp merge_ranges([range | rest]), do: [range | merge_ranges(rest)]
  defp merge_ranges([]), do: []

  defp replace_ranges(text, ranges, marker) do
    {parts, last} =
      Enum.reduce(ranges, {[], 0}, fn {from, to}, {parts, at} ->
        {[marker, binary_part(text, at, from - at) | parts], to}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, last, byte_size(text) - last) | parts]))
  end

  @doc """
  Masks a plain, JSON-compatible value (string-keyed maps, lists, and
  scalars) and returns it with its manifest records.

  Each record is `%{"action" => "mask", "count", "path", "policy_id",
  "reason"}`. `path` uses `key:` and `index:` segments, at most eight. A
  marker already present in a string (from masking at capture) is reported
  as well. At most 32 records are returned: beyond that, paths are cut short
  and counts summed, so every reason stays visible.
  """
  @spec mask(term()) :: {term(), [map()]}
  def mask(value) do
    {masked, counts} = walk(value, [], %{})
    {masked, records(counts)}
  end

  defp walk(value, path, counts) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, {%{}, counts}, fn {key, item}, {masked, counts} ->
      item_path = [segment(key) | path]

      {item, counts} =
        if credential_key?(key) and item not in [nil, ""],
          do: {marker("credential_key"), count(counts, item_path, "credential_key", 1)},
          else: walk(item, item_path, counts)

      {Map.put(masked, key, item), counts}
    end)
  end

  defp walk(value, path, counts) when is_list(value) do
    {items, {counts, _index}} =
      Enum.map_reduce(value, {counts, 0}, fn item, {counts, index} ->
        {item, counts} = walk(item, ["index:" <> Integer.to_string(index) | path], counts)
        {item, {counts, index + 1}}
      end)

    {items, counts}
  end

  defp walk(value, path, counts) when is_binary(value) do
    if String.valid?(value) do
      masked = mask_text(value)

      counts =
        compiled().marker
        |> Regex.scan(masked, capture: :all_but_first)
        |> Enum.reduce(counts, fn [reason], counts ->
          # Only the policy's own reasons count; other bracketed text is data.
          if reason in @reasons, do: count(counts, path, reason, 1), else: counts
        end)

      {masked, counts}
    else
      {value, counts}
    end
  end

  defp walk(value, _path, counts), do: {value, counts}

  defp segment(key) when is_binary(key), do: "key:" <> bounded_key(key)
  defp segment(key), do: "key:" <> bounded_key(inspect(key))

  defp bounded_key(key) when byte_size(key) <= @max_key_bytes, do: key
  defp bounded_key(key), do: valid_prefix(binary_part(key, 0, @max_key_bytes))

  defp valid_prefix(""), do: ""

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  defp count(counts, reversed_path, reason, amount) do
    path = reversed_path |> Enum.reverse() |> Enum.take(@max_path_segments)
    Map.update(counts, {path, reason}, amount, &(&1 + amount))
  end

  defp records(counts) do
    counts
    |> bounded([@max_path_segments, 1, 0])
    |> Enum.sort()
    |> Enum.map(fn {{path, reason}, count} ->
      %{
        "action" => "mask",
        "count" => count,
        "path" => path,
        "policy_id" => @policy_id,
        "reason" => reason
      }
    end)
  end

  defp bounded(counts, _depths) when map_size(counts) <= @max_records, do: counts
  defp bounded(counts, [_depth]), do: counts

  defp bounded(counts, [_depth, next | rest]) do
    counts
    |> Enum.reduce(%{}, fn {{path, reason}, count}, cut ->
      Map.update(cut, {Enum.take(path, next), reason}, count, &(&1 + count))
    end)
    |> bounded([next | rest])
  end

  defp marker(reason), do: "[REDACTED:" <> reason <> "]"

  defp mask_whole("high_entropy", whole) do
    if high_entropy?(whole), do: marker("high_entropy"), else: whole
  end

  defp mask_whole(reason, _whole), do: marker(reason)

  # A long token from a base64 or base64url alphabet that mixes upper case,
  # lower case, and digits and carries at least 4 bits per character.
  # Lowercase hex digests, trace ids, and UUIDs never qualify.
  defp high_entropy?(token) do
    bytes = :binary.bin_to_list(token)

    Enum.any?(bytes, &(&1 in ?A..?Z)) and Enum.any?(bytes, &(&1 in ?a..?z)) and
      Enum.any?(bytes, &(&1 in ?0..?9)) and entropy(bytes) >= @min_entropy_bits
  end

  defp entropy(bytes) do
    total = length(bytes)

    bytes
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_byte, count}, sum ->
      probability = count / total
      sum - probability * :math.log2(probability)
    end)
  end

  # Compiled once per loaded module version. Regex sigils in module
  # attributes are recompiled on every use on OTP 28 and later.
  defp compiled do
    key = {__MODULE__, __MODULE__.module_info(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = %{
          marker: Regex.compile!(@marker_source),
          port: Regex.compile!(~S/\A\d{1,5}+(?:[?#]|[',;)]*+\z)/),
          patterns:
            Enum.map(@pattern_sources, fn {reason, source, options, scope} ->
              {reason, Regex.compile!(source, options), scope}
            end)
        }

        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end
end
