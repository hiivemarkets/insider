defmodule Insider.Collector.Rich do
  @moduledoc false

  # Bounded, JSON-compatible rendering of arbitrary terms for the rich live
  # disclosure profile. It runs in the emitting process (a Logger or
  # Telemetry handler), only when a collector was started with `rich: true`,
  # so it never runs application code and every step is bounded:
  #
  # - No application hooks: Logger `report_cb` callbacks, struct `Inspect`
  #   implementations, and calendar callbacks are never invoked. Structs
  #   render field by field; only ISO calendar values use their `inspect`
  #   text. Ecto `redact: true` fields come from `Insider.Live.RedactFields`,
  #   collected by the live owner at session start. Inspect text is produced
  #   only for already sanitized terms, with `structs: false`.
  # - Masking before rendering: `sanitize/1` walks the original term first.
  #   A value under a credential-named key (in a map, a keyword list, or a
  #   two-element tuple such as `{"authorization", _}`) is masked whatever
  #   its type, strings and printable charlists are masked by
  #   `Insider.Redaction.Credentials`, and binaries that are not UTF-8 are
  #   withheld, so later escaping or cutting can never expose a secret.
  # - A key longer than 128 bytes fails closed: its value is masked before
  #   the key is cut.
  # - Bounds: strings 2,048 bytes, 32 entries per map, list, or tuple,
  #   containers nested 5 deep, 2,048 visited nodes, an encoded byte budget
  #   per payload, and a work budget of 2,000,000 reductions per payload
  #   (about 40 ms of one scheduler; counted in reductions so it does not
  #   depend on load). What does not fit is
  #   counted under `"$insider_truncated"` or replaced by a `…[…_limit]`
  #   marker.

  alias Insider.Collector.GraphqlOutcome
  alias Insider.Live.RedactFields
  alias Insider.Redaction.Credentials

  @string_bytes 2_048
  @message_bytes 3_072
  @scan_bytes 8_192
  @width 32
  @depth 5
  @nodes 2_048
  @reduction_budget 2_000_000
  @key_bytes 128
  @payload_bytes 7_168
  @measurement_bytes 1_024
  @graphql_metadata_bytes 1_024
  @graphql_arguments_bytes 2_048
  # Integers this large are never printed: decimal conversion costs grow
  # faster than their size.
  @max_big_integer Integer.pow(10, 150)
  @big_integer_marker "<integer over 150 digits>"
  @max_format_width 256
  @truncated_key "$insider_truncated"
  @truncated_suffix "…[truncated]"
  @depth_marker "…[depth_limit]"
  @time_marker "…[time_limit]"
  @masked "[REDACTED:credential_key]"
  @redacted "[REDACTED:redacted_field]"
  @truncation_reserve 32
  @min_entry_bytes 24
  @deadline_key {__MODULE__, :deadline}
  @calendar_structs [Date, DateTime, NaiveDateTime, Time]
  @inspect_options [
    limit: 25,
    printable_limit: @scan_bytes,
    width: :infinity,
    pretty: false,
    structs: false
  ]
  @format_options [chars_limit: @scan_bytes]
  @token_tail ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+/=."

  @doc "The rendering bounds, for documentation and tests."
  @spec bounds() :: map()
  def bounds do
    %{
      "string_bytes" => @string_bytes,
      "message_bytes" => @message_bytes,
      "width" => @width,
      "depth" => @depth,
      "nodes" => @nodes,
      "reduction_budget" => @reduction_budget,
      "key_bytes" => @key_bytes,
      "payload_bytes" => @payload_bytes,
      "measurement_bytes" => @measurement_bytes
    }
  end

  @doc """
  The rich Logger payload: the level, the masked message text, the rendered
  report for report messages, and the rendered metadata. A report's
  `report_cb` is never called; its message text is the sanitized report.
  """
  @spec logger_payload(atom(), term(), map()) :: map()
  def logger_payload(level, message, metadata) do
    within_deadline(fn ->
      # The message is bounded by its JSON encoding, which escaping can make
      # several times longer than the text.
      {text, _size} =
        message |> message_text() |> bounded_text(@message_bytes) |> fit(@message_bytes)

      head = %{"level" => Atom.to_string(level), "message" => text}

      head =
        case message do
          {:report, report} ->
            budget = div(@payload_bytes - json_size(head), 2)
            Map.put(head, "report", rendered(report, budget))

          _other ->
            head
        end

      # Only the first entries are read; the omission count still comes from
      # the whole map.
      metadata = Map.delete(metadata, :report_cb)
      pairs = metadata |> take_map(@width) |> Enum.map(&top_level_charlist/1)

      {rendered, _size} =
        entries(pairs, map_size(metadata), 0, @payload_bytes - json_size(head) - 12)

      Map.put(head, "metadata", rendered)
    end)
  end

  # As in Logger's own formatter, a top-level printable charlist (such as
  # `file`) is text.
  defp top_level_charlist({key, [_head | _tail] = value}) do
    if printable_charlist?(value), do: {key, List.to_string(value)}, else: {key, value}
  end

  defp top_level_charlist(entry), do: entry

  @doc "The rich Telemetry payload: the rendered event metadata."
  @spec telemetry_payload(map()) :: map()
  def telemetry_payload(metadata), do: %{"metadata" => render(metadata, @payload_bytes - 14)}

  @doc """
  The rich payload of an Absinthe operation stop: the rendered metadata
  without the blueprint (a document and schema walk that would fill the
  payload with structure), and `"graphql_data"`, the operation's response
  `data` as `Insider.Collector.GraphqlOutcome.response_data/1` resolves it
  (and, for a mutation, `"graphql_arguments"`, the inputs it received, by
  `Insider.Collector.GraphqlOutcome.arguments/1`)
  through the operation's selections (credential fields masked by schema
  name, unresolved keys withheld), rendered and masked like any rich value,
  for `trace --values`.
  """
  @spec graphql_payload(map()) :: map()
  def graphql_payload(metadata) do
    payload = %{
      "metadata" => render(Map.delete(metadata, :blueprint), @graphql_metadata_bytes),
      "graphql_data" =>
        render(
          GraphqlOutcome.response_data(metadata),
          @payload_bytes - @graphql_metadata_bytes - @graphql_arguments_bytes
        )
    }

    # A mutation's inputs (`GraphqlOutcome.arguments/1`), when it has any.
    case GraphqlOutcome.arguments(metadata) do
      nil ->
        payload

      arguments ->
        Map.put(payload, "graphql_arguments", render(arguments, @graphql_arguments_bytes))
    end
  end

  @doc """
  Renders Telemetry measurements: every measurement when `selection` is
  empty, otherwise only the selected sources under their output names.
  """
  @spec measurements(map(), %{optional(atom()) => String.t()}) :: map()
  def measurements(measurements, selection) when map_size(selection) == 0,
    do: render(measurements, @measurement_bytes)

  def measurements(measurements, selection) do
    selection
    |> Enum.filter(fn {source, _output} -> Map.has_key?(measurements, source) end)
    |> Map.new(fn {source, output} -> {output, Map.fetch!(measurements, source)} end)
    |> render(@measurement_bytes)
  end

  @doc """
  Renders `term` as a JSON-compatible value whose encoding fits `budget`
  bytes, within the per-payload deadline.
  """
  @spec render(term(), pos_integer()) :: term()
  def render(term, budget), do: within_deadline(fn -> rendered(term, budget) end)

  defp rendered(term, budget) do
    {value, _size} = render(term, 0, budget)
    value
  end

  # The deadline lives in the emitting process's dictionary only for the
  # length of one payload, so the recursive walk need not thread it.
  defp within_deadline(fun) do
    case Process.get(@deadline_key) do
      nil ->
        # Pattern compilation is a one-time, fixed cost outside the budget;
        # the live owner already warms it when a rich session starts.
        :ok = Credentials.warm()
        Process.put(@deadline_key, reductions() + @reduction_budget)

        try do
          fun.()
        after
          Process.delete(@deadline_key)
        end

      _outer ->
        fun.()
    end
  end

  defp expired? do
    case Process.get(@deadline_key) do
      nil -> false
      limit -> reductions() > limit
    end
  end

  defp reductions do
    {:reductions, count} = Process.info(self(), :reductions)
    count
  end

  defp render(value, depth, budget) do
    if expired?(), do: string(@time_marker, budget), else: render_term(value, depth, budget)
  end

  defp render_term(nil, _depth, _budget), do: {nil, 4}
  defp render_term(true, _depth, _budget), do: {true, 4}
  defp render_term(false, _depth, _budget), do: {false, 5}

  defp render_term(value, _depth, _budget)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: {value, value |> Integer.to_string() |> byte_size()}

  defp render_term(value, _depth, budget) when is_integer(value),
    do: string(big_integer_text(value), budget)

  defp render_term(value, _depth, budget) when is_float(value),
    do: string(:erlang.float_to_binary(value, [:short]), budget)

  defp render_term(value, _depth, budget) when is_atom(value),
    do: string(Atom.to_string(value), budget)

  defp render_term(value, _depth, budget) when is_binary(value),
    do: string(text_or_withheld(value), budget)

  # ISO calendar values whose fields are all in-range scalars render as their
  # sigil text, formatted here without `inspect` or any `Calendar` call. Any
  # other calendar, or any field out of shape, renders field by field.
  defp render_term(%module{calendar: Calendar.ISO} = value, depth, budget)
       when module in @calendar_structs do
    case iso_text(value) do
      {:ok, text} -> string(text, budget)
      :error -> render_struct(value, module, depth, budget)
    end
  end

  # A Decimal (a money amount) renders as its text, from its fields alone:
  # no Decimal code runs, and a coefficient too large to print is marked.
  defp render_term(%{__struct__: Decimal, sign: sign, coef: coef, exp: exp}, _depth, budget)
       when sign in [1, -1] and is_integer(coef) and coef >= 0 and coef < @max_big_integer and
              is_integer(exp) and exp > -160 and exp < 160,
       do: string(decimal_text(sign, coef, exp), budget)

  defp render_term(value, depth, budget)
       when depth >= @depth and (is_map(value) or is_list(value)),
       do: string(@depth_marker, budget)

  defp render_term(%module{} = value, depth, budget),
    do: render_struct(value, module, depth, budget)

  defp render_term(value, depth, budget) when is_map(value),
    do: entries(take_map(value, @width), map_size(value), depth, budget)

  defp render_term([], _depth, _budget), do: {[], 2}

  defp render_term(value, depth, budget) when is_list(value) do
    # A list whose leading characters hold a secret shape is masked text;
    # any other stays a list.
    case masked_charlist(value, min(@scan_bytes, budget + 512)) do
      {:masked, text} -> string(text, budget)
      :clean -> list(value, depth, budget)
    end
  end

  # Tuples, pids, references, ports, and functions: inspect text of the
  # sanitized term, so no secret can hide behind escaping.
  defp render_term(value, _depth, budget), do: inspected(value, budget)

  defp decimal_text(sign, coef, exp) do
    digits = Integer.to_string(coef)

    text =
      cond do
        exp >= 0 ->
          digits <> String.duplicate("0", exp)

        String.length(digits) > -exp ->
          {whole, fraction} = String.split_at(digits, String.length(digits) + exp)
          whole <> "." <> fraction

        true ->
          "0." <> String.duplicate("0", -exp - String.length(digits)) <> digits
      end

    if sign == -1, do: "-" <> text, else: text
  end

  defp render_struct(value, module, depth, budget) do
    pairs = [{"__struct__", Atom.to_string(module)} | struct_pairs(value, module)]
    entries(pairs, map_size(value), depth, budget)
  end

  defp iso_text(%Date{year: year, month: month, day: day}) do
    with {:ok, date} <- iso_date(year, month, day), do: {:ok, "~D[" <> date <> "]"}
  end

  defp iso_text(%Time{} = time) do
    with {:ok, text} <- iso_time(time), do: {:ok, "~T[" <> text <> "]"}
  end

  defp iso_text(%NaiveDateTime{year: year, month: month, day: day} = value) do
    with {:ok, date} <- iso_date(year, month, day),
         {:ok, time} <- iso_time(value),
         do: {:ok, "~N[" <> date <> " " <> time <> "]"}
  end

  defp iso_text(%DateTime{year: year, month: month, day: day} = value) do
    with {:ok, date} <- iso_date(year, month, day),
         {:ok, time} <- iso_time(value),
         {:ok, zone} <- iso_zone(value) do
      case zone do
        :utc -> {:ok, "~U[" <> date <> " " <> time <> "Z]"}
        zone -> {:ok, "#DateTime<" <> date <> " " <> time <> zone <> ">"}
      end
    end
  end

  # A field is missing, so the struct is not a calendar value we can trust.
  defp iso_text(_value), do: :error

  defp iso_date(year, month, day)
       when is_integer(year) and year in 0..9_999 and is_integer(month) and month in 1..12 and
              is_integer(day) and day in 1..31,
       do: {:ok, pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2)}

  defp iso_date(_year, _month, _day), do: :error

  defp iso_time(%{hour: hour, minute: minute, second: second, microsecond: {micro, precision}})
       when is_integer(hour) and hour in 0..23 and is_integer(minute) and minute in 0..59 and
              is_integer(second) and second in 0..59 and is_integer(micro) and
              micro in 0..999_999 and is_integer(precision) and precision in 0..6 do
    fraction =
      if precision == 0, do: "", else: "." <> binary_part(pad(micro, 6), 0, precision)

    {:ok, pad(hour, 2) <> ":" <> pad(minute, 2) <> ":" <> pad(second, 2) <> fraction}
  end

  defp iso_time(_value), do: :error

  defp iso_zone(%{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: {:ok, :utc}

  defp iso_zone(%{time_zone: zone, zone_abbr: abbr, utc_offset: utc, std_offset: std})
       when is_binary(zone) and byte_size(zone) <= 64 and is_binary(abbr) and
              byte_size(abbr) <= 16 and is_integer(utc) and utc in -86_400..86_400 and
              is_integer(std) and std in -86_400..86_400 do
    if String.valid?(zone) and String.valid?(abbr) do
      offset = utc + std
      sign = if offset < 0, do: "-", else: "+"
      minutes = div(abs(offset), 60)

      {:ok,
       sign <>
         pad(div(minutes, 60), 2) <>
         ":" <>
         pad(rem(minutes, 60), 2) <>
         " " <>
         abbr <>
         " " <> zone}
    else
      :error
    end
  end

  defp iso_zone(_value), do: :error

  defp pad(integer, width), do: integer |> Integer.to_string() |> String.pad_leading(width, "0")

  # Struct fields, at most the width bound, never the whole map: Ecto
  # `redact: true` fields recorded at session start are masked, and URI
  # keeps credentials in its userinfo and authority.
  defp struct_pairs(%URI{userinfo: userinfo} = uri, URI) when is_binary(userinfo) do
    authority = uri.authority && String.replace(uri.authority, userinfo <> "@", @masked <> "@")

    uri
    |> Map.from_struct()
    |> Map.merge(%{userinfo: @masked, authority: authority})
    |> Map.to_list()
  end

  defp struct_pairs(value, module) do
    redacted = RedactFields.fields(module)

    value
    |> take_map(@width + 1)
    |> Enum.flat_map(fn
      {:__struct__, _module} -> []
      {field, nil} -> [{field, nil}]
      {field, field_value} -> [{field, if(field in redacted, do: @redacted, else: field_value)}]
    end)
  end

  # Up to `count` entries of a map, without converting the whole map.
  defp take_map(map, count), do: take_entries(:maps.iterator(map), count, [])

  defp take_entries(_iterator, 0, entries), do: Enum.reverse(entries)

  defp take_entries(iterator, count, entries) do
    case :maps.next(iterator) do
      :none -> Enum.reverse(entries)
      {key, value, next} -> take_entries(next, count - 1, [{key, value} | entries])
    end
  end

  # Reads at most `limit` leading elements of a list as text, with any
  # element that is not a character read as a space, and masks it. An
  # incomplete scan never fails open: masked text replaces the whole list.
  defp masked_charlist(list, limit) do
    {text, complete?} = charlist_text(list, limit, [])

    case Credentials.mask_text(text) do
      ^text -> :clean
      masked when complete? -> {:masked, masked}
      masked -> {:masked, masked <> @truncated_suffix}
    end
  end

  defp charlist_text([], _limit, chars), do: {chars |> Enum.reverse() |> List.to_string(), true}
  defp charlist_text(_list, 0, chars), do: {chars |> Enum.reverse() |> List.to_string(), false}

  defp charlist_text([char | rest], limit, chars)
       when is_integer(char) and char in 0..0x10FFFF and char not in 0xD800..0xDFFF,
       do: charlist_text(rest, limit - 1, [char | chars])

  defp charlist_text([_other | rest], limit, chars),
    do: charlist_text(rest, limit - 1, [?\s | chars])

  defp charlist_text(_improper, _limit, chars),
    do: {chars |> Enum.reverse() |> List.to_string(), false}

  defp list(value, depth, budget) do
    {head, rest} = split(value, @width)

    if keyword?(head) and rest == [] and unique_keys?(head) do
      entries(head, length(head), depth, budget)
    else
      items =
        if keyword?(head),
          do: Enum.map(head, &{:entry, &1}),
          else: head

      items(items, length(head) + rest_count(rest), depth, budget)
    end
  end

  # A map or keyword list: credential keys are masked, the cheapest values
  # are placed first, and entries that do not fit are counted.
  defp entries(pairs, total, depth, budget) do
    {result, size, count} =
      pairs
      |> Enum.take(@width)
      |> Enum.map(fn {key, value} -> {key(key), key, value} end)
      |> Enum.sort_by(fn {name, _key, value} ->
        {cost_rank(value), byte_size_hint(value), name}
      end)
      |> Enum.reduce_while({%{}, 2, 0}, fn {name, key, value}, {result, size, count} ->
        key_size = json_size(name) + 2
        available = budget - size - key_size - @truncation_reserve

        if available < @min_entry_bytes do
          {:halt, {result, size, count}}
        else
          {rendered, value_size} = entry_value(key, value, depth, available)
          {:cont, {Map.put(result, name, rendered), size + key_size + value_size, count + 1}}
        end
      end)

    truncated(result, size, total - count)
  end

  defp entry_value(key, value, depth, available) do
    if masked_key?(key) and value not in [nil, ""],
      do: string(@masked, available),
      else: render(value, depth + 1, available)
  end

  # Fails closed: a key too long to keep whole might lose the part that
  # names a credential when it is cut.
  defp masked_key?(key) when is_binary(key) and byte_size(key) > @key_bytes, do: true

  defp masked_key?(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: key |> Atom.to_string() |> masked_key?()

  defp masked_key?(key), do: Credentials.credential_key?(key)

  defp truncated(result, size, 0), do: {result, size}

  defp truncated(result, size, omitted) do
    marker_size = json_size(@truncated_key) + 2 + byte_size(Integer.to_string(omitted))
    {Map.put(result, @truncated_key, omitted), size + marker_size}
  end

  defp items(items, total, depth, budget) do
    {result, size, count} =
      Enum.reduce_while(items, {[], 2, 0}, fn item, {result, size, count} ->
        available = budget - size - 1 - @truncation_reserve

        if available < @min_entry_bytes do
          {:halt, {result, size, count}}
        else
          {rendered, item_size} = item(item, depth, available)
          {:cont, {[rendered | result], size + 1 + item_size, count + 1}}
        end
      end)

    case total - count do
      0 ->
        {Enum.reverse(result), size}

      omitted ->
        marker = %{@truncated_key => omitted}
        {Enum.reverse([marker | result]), size + 1 + json_size(marker)}
    end
  end

  defp item({:entry, {key, value}}, depth, available),
    do: entries([{key, value}], 1, depth + 1, available)

  defp item(value, depth, available), do: render(value, depth + 1, available)

  # Scalars first, then strings by size, then containers and inspect text,
  # so short facts such as a query source survive a long statement.
  defp cost_rank(value) when is_binary(value), do: 1
  defp cost_rank(value) when is_number(value) or is_atom(value), do: 0
  defp cost_rank(_value), do: 2

  defp byte_size_hint(value) when is_binary(value), do: byte_size(value)
  defp byte_size_hint(_value), do: 0

  defp inspected(value, budget) do
    {sanitized, _nodes} = sanitize(value, 0, @nodes)

    sanitized
    |> inspect(@inspect_options)
    |> string(budget)
  end

  # Returns `term` with every credential replaced by a marker, within the
  # depth, width, node, and time bounds. Structs become plain maps, so
  # `inspect` with `structs: false` never reaches an Inspect implementation.
  defp sanitize(_term, _depth, nodes) when nodes <= 0, do: {:"…", 0}

  defp sanitize(term, depth, nodes) do
    cond do
      expired?() ->
        {@time_marker, 0}

      depth > @depth and (is_map(term) or is_list(term) or is_tuple(term)) ->
        {@depth_marker, nodes - 1}

      true ->
        sanitize_term(term, depth, nodes - 1)
    end
  end

  defp sanitize_term(term, _depth, nodes) when is_binary(term),
    do: {term |> text_or_withheld() |> bounded_text(@string_bytes), nodes}

  defp sanitize_term(%module{} = term, depth, nodes) do
    pairs = [{"__struct__", Atom.to_string(module)} | struct_pairs(term, module)]
    sanitize_pairs(pairs, map_size(term), depth, nodes)
  end

  defp sanitize_term(term, depth, nodes) when is_map(term),
    do: sanitize_pairs(take_map(term, @width), map_size(term), depth, nodes)

  defp sanitize_term([_head | _tail] = term, depth, nodes) do
    case masked_charlist(term, @string_bytes + 512) do
      {:masked, text} -> {text, nodes}
      :clean -> sanitize_list(term, depth, nodes, @width, [])
    end
  end

  defp sanitize_term({key, value}, depth, nodes) do
    {{key, value}, nodes} = sanitize_pair(key, value, depth, nodes)
    {{key, value}, nodes}
  end

  # At most the width bound of elements is read, by index.
  defp sanitize_term(term, depth, nodes) when is_tuple(term) do
    size = tuple_size(term)
    items = for index <- 0..(min(size, @width) - 1)//1, do: elem(term, index)
    {items, nodes} = sanitize_list(items, depth, nodes, @width, [])
    items = if size > @width, do: items ++ [:"…"], else: items
    {List.to_tuple(items), nodes}
  end

  # An integer too large to print cheaply is never converted to decimal.
  defp sanitize_term(term, _depth, nodes)
       when is_integer(term) and (term >= @max_big_integer or term <= -@max_big_integer),
       do: {@big_integer_marker, nodes}

  defp sanitize_term(term, _depth, nodes), do: {term, nodes}

  defp sanitize_pairs(pairs, total, depth, nodes) do
    {pairs, nodes} =
      pairs
      |> Enum.take(@width)
      |> Enum.map_reduce(nodes, fn {key, value}, nodes ->
        sanitize_pair(key, value, depth, nodes)
      end)

    map = Map.new(pairs)

    map =
      if total > map_size(map),
        do: Map.put(map, @truncated_key, total - map_size(map)),
        else: map

    {map, nodes}
  end

  defp sanitize_pair(key, value, depth, nodes) do
    {key, nodes} = sanitize(key, depth + 1, nodes)

    if credential_name?(key) and value not in [nil, ""],
      do: {{key, @masked}, nodes},
      else:
        then(sanitize(value, depth + 1, nodes), fn {value, nodes} -> {{key, value}, nodes} end)
  end

  defp credential_name?([_head | _tail] = key),
    do: printable_charlist?(key) and key |> List.to_string() |> masked_key?()

  defp credential_name?(key) when is_binary(key) or is_atom(key), do: masked_key?(key)
  defp credential_name?(_key), do: false

  defp sanitize_list([], _depth, nodes, _width, items), do: {Enum.reverse(items), nodes}

  defp sanitize_list(_rest, _depth, nodes, 0, items),
    do: {Enum.reverse([:"…" | items]), nodes}

  defp sanitize_list([head | tail], depth, nodes, width, items) do
    {head, nodes} = sanitize(head, depth + 1, nodes)
    sanitize_list(tail, depth, nodes, width - 1, [head | items])
  end

  defp sanitize_list(improper, depth, nodes, _width, items) do
    {tail, nodes} = sanitize(improper, depth + 1, nodes)
    {Enum.reverse([{:improper_tail, tail} | items]), nodes}
  end

  # Binaries that are not UTF-8 are withheld: their byte rendering could
  # spell out a secret that text masking never sees. Only the first `limit`
  # bytes are validated, so the check costs no more than the output.
  defp text_or_withheld(value), do: text_or_withheld(value, @scan_bytes)

  defp text_or_withheld(value, limit) when byte_size(value) <= limit do
    if String.valid?(value), do: value, else: withheld(value)
  end

  defp text_or_withheld(value, limit) do
    case value |> binary_part(0, limit) |> valid_prefix() do
      "" -> withheld(value)
      _prefix -> cut_text(value)
    end
  end

  defp big_integer_text(value)
       when value >= @max_big_integer or value <= -@max_big_integer,
       do: @big_integer_marker

  defp big_integer_text(value), do: Integer.to_string(value)

  defp withheld(value), do: "<<" <> Integer.to_string(byte_size(value)) <> " bytes, not UTF-8>>"

  defp printable_charlist?(list),
    do: bounded_list?(list, @scan_bytes) and :io_lib.printable_unicode_list(list)

  defp bounded_list?([], _limit), do: true
  defp bounded_list?(_list, 0), do: false
  defp bounded_list?([_head | tail], limit), do: bounded_list?(tail, limit - 1)
  defp bounded_list?(_improper, _limit), do: false

  defp string(text, budget) do
    text = bounded_text(text, min(@string_bytes, max(budget - 2, 0)))
    fit(text, budget)
  end

  # Escaping can make the encoding longer than the text; cut until it fits.
  defp fit(text, budget) do
    size = json_size(text)

    cond do
      size <= budget ->
        {text, size}

      budget < 2 + byte_size(@truncated_suffix) ->
        {nil, 4}

      true ->
        excess = size - budget
        limit = max(byte_size(text) - excess - byte_size(@truncated_suffix), 0)
        text |> cut(limit) |> Kernel.<>(@truncated_suffix) |> fit(budget)
    end
  end

  @doc """
  A short text field of at most `limit` bytes, for evidence outside a rich
  payload (a request's path or user agent): only a bounded prefix of
  `value` is read, it is credential-masked before it is cut, a secret on the
  scan boundary is dropped rather than half shown, and a cut ends in
  `…[truncated]`. A value that is not text, or whose scanned part is not
  UTF-8, is `nil`.
  """
  @spec text_field(term(), pos_integer()) :: String.t() | nil
  def text_field(value, limit) when is_binary(value) do
    scanned? = byte_size(value) > min(@scan_bytes, limit + 512)

    if scanned? or String.valid?(value) do
      case bounded_text(value, limit) do
        "" when value != "" -> nil
        text -> text
      end
    end
  end

  def text_field(_value, _limit), do: nil

  # Masks the scanned prefix before cutting to `limit` bytes. The scan is a
  # little longer than the limit, so masking work follows the output budget,
  # and it is cut at a token boundary, so a secret that straddles the scan
  # limit is dropped rather than half shown.
  defp bounded_text(text, limit) do
    scan = min(@scan_bytes, limit + 512)

    scanned =
      if byte_size(text) > scan,
        do: text |> cut(scan) |> drop_token_tail(),
        else: text

    masked = Credentials.mask_text(scanned)

    if byte_size(masked) <= limit and byte_size(scanned) == byte_size(text),
      do: masked,
      else: cut(masked, max(limit - byte_size(@truncated_suffix), 0)) <> @truncated_suffix
  end

  defp drop_token_tail(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @token_tail))
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp cut(text, limit) when byte_size(text) <= limit, do: text
  defp cut(text, limit), do: text |> binary_part(0, limit) |> valid_prefix()

  # A cut can split one UTF-8 character, which is at most 3 dangling bytes;
  # anything else invalid yields "".
  defp valid_prefix(text), do: valid_prefix(text, 3)

  defp valid_prefix(text, tries) do
    cond do
      String.valid?(text) -> text
      tries == 0 or text == "" -> ""
      true -> valid_prefix(binary_part(text, 0, byte_size(text) - 1), tries - 1)
    end
  end

  # The first `@scan_bytes` of a longer text, cut at a token boundary so a
  # secret on the cut is dropped rather than half shown. A text that is one
  # long token keeps nothing.
  defp cut_text(text) do
    case text |> binary_part(0, min(byte_size(text), @scan_bytes)) |> valid_prefix() do
      "" ->
        withheld(text)

      prefix ->
        case drop_token_tail(prefix) do
          "" -> @truncated_suffix
          kept -> kept <> @truncated_suffix
        end
    end
  end

  # The leading text of chardata, without walking more than `nodes` parts
  # or collecting more than `limit` bytes.
  defp chardata_prefix(_stack, limit, nodes, parts) when limit <= 0 or nodes <= 0,
    do: {:cut, parts}

  defp chardata_prefix([], _limit, _nodes, parts), do: {:done, parts}

  defp chardata_prefix([[] | rest], limit, nodes, parts),
    do: chardata_prefix(rest, limit, nodes - 1, parts)

  defp chardata_prefix([[head | tail] | rest], limit, nodes, parts),
    do: chardata_prefix([head, tail | rest], limit, nodes - 1, parts)

  defp chardata_prefix([binary | rest], limit, nodes, parts) when is_binary(binary) do
    part = if byte_size(binary) > limit, do: binary_part(binary, 0, limit), else: binary
    chardata_prefix(rest, limit - byte_size(part), nodes - 1, [part | parts])
  end

  defp chardata_prefix([char | rest], limit, nodes, parts)
       when is_integer(char) and char in 0..0x10FFFF and char not in 0xD800..0xDFFF,
       do: chardata_prefix(rest, limit - 1, nodes - 1, [<<char::utf8>> | parts])

  defp chardata_prefix(_stack, _limit, _nodes, _parts), do: :error

  defp bounded_format?(format) when is_binary(format),
    do: byte_size(format) <= @scan_bytes and format_widths_ok?(:binary.bin_to_list(format))

  defp bounded_format?(format),
    do: bounded_list?(format, @scan_bytes) and format_widths_ok?(format)

  # `io_lib` pads to a directive's field width and precision before any
  # output bound applies, so they are checked first: no `*` (a width taken
  # from the arguments), no number above 256, and at most `@scan_bytes` in
  # total across the format.
  defp format_widths_ok?(chars), do: format_widths(chars, 0)

  defp format_widths([], total), do: total <= @scan_bytes
  defp format_widths([?~, ?~ | rest], total), do: format_widths(rest, total)
  defp format_widths([?~ | rest], total), do: directive_widths(rest, total, 0)
  defp format_widths([_char | rest], total), do: format_widths(rest, total)

  defp directive_widths([digit | rest], total, number) when digit in ?0..?9 do
    number = number * 10 + digit - ?0
    number <= @max_format_width and directive_widths(rest, total, number)
  end

  defp directive_widths([?* | _rest], _total, _number), do: false

  defp directive_widths([separator | rest], total, number) when separator in [?., ?-],
    do: directive_widths(rest, total + number, 0)

  defp directive_widths([control | rest], total, number)
       when control in ?a..?z or control in ?A..?Z,
       do: format_widths(rest, total + number)

  # A pad character.
  defp directive_widths([_pad | rest], total, number),
    do: directive_widths(rest, total, number)

  defp directive_widths(_end, total, number), do: total + number <= @scan_bytes

  defp key(""), do: "$empty_key"

  defp key(key) when is_binary(key) do
    case key |> cut(@key_bytes) |> text_or_withheld(@key_bytes) do
      "<<" <> _withheld -> "$binary_key"
      text -> text
    end
  end

  defp key(key) when is_atom(key), do: key |> Atom.to_string() |> key()

  defp key(key) do
    {sanitized, _nodes} = sanitize(key, @depth, 8)
    sanitized |> inspect(@inspect_options) |> key()
  end

  defp keyword?([]), do: false
  defp keyword?(items), do: Enum.all?(items, &match?({key, _value} when is_atom(key), &1))

  defp unique_keys?(pairs), do: length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs)

  defp split(list, count), do: split(list, count, [])
  defp split(rest, 0, taken), do: {Enum.reverse(taken), rest}
  defp split([], _count, taken), do: {Enum.reverse(taken), []}
  defp split([head | tail], count, taken), do: split(tail, count - 1, [head | taken])
  # An improper tail is shown as one more inspected item.
  defp split(improper, _count, taken),
    do: {Enum.reverse([{:improper_tail, improper} | taken]), []}

  defp rest_count(rest), do: rest_count(rest, 0)
  # Counting what was left out is itself bounded; beyond the cap the count
  # is a lower bound.
  defp rest_count([_head | tail], count) when count < 10_000, do: rest_count(tail, count + 1)
  defp rest_count(_rest, count), do: count

  # Message text never calls application code: `report_cb` is ignored, and
  # format arguments are sanitized before OTP's own `io_lib` formats them.
  defp message_text({:string, chardata}) do
    case chardata_prefix([chardata], @scan_bytes, 65_536, []) do
      {:done, parts} -> parts |> Enum.reverse() |> IO.iodata_to_binary() |> text_or_withheld()
      {:cut, parts} -> parts |> Enum.reverse() |> IO.iodata_to_binary() |> cut_text()
      :error -> "[unprintable message]"
    end
  end

  defp message_text({:report, report}), do: sanitized_text(report)

  defp message_text({format, arguments})
       when is_list(arguments) and (is_binary(format) or is_list(format)) do
    if bounded_format?(format) do
      {arguments, _nodes} = sanitize_list(arguments, 0, @nodes, @width, [])

      format
      |> :io_lib.format(arguments, @format_options)
      |> IO.chardata_to_string()
    else
      sanitized_text({format, arguments})
    end
  rescue
    _error -> sanitized_text({format, arguments})
  end

  defp message_text(message), do: sanitized_text(message)

  defp sanitized_text(term) do
    {sanitized, _nodes} = sanitize(term, 0, @nodes)
    inspect(sanitized, @inspect_options)
  end

  defp json_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
