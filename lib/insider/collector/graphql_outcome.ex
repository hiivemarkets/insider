defmodule Insider.Collector.GraphqlOutcome do
  @moduledoc false

  # The value-free outcome of one GraphQL operation, for its Telemetry event
  # (`[:absinthe, :execute, :operation, :stop]`) and its OpenTelemetry span.
  # A GraphQL error is usually inside an HTTP 200 response, so neither the
  # status nor the span status shows it.
  #
  # The outcome names code, never data: the operation's name and type, a
  # result kind, the number of top-level errors with their codes and paths
  # (list indices become `[]`), and, for a payload that reports its own
  # validation errors (an `errors` field of `field`s and `type`s), their
  # number, fields, and types, plus each top-level field's `__typename`.
  # Error messages and every other value are never read. Only names shaped
  # like identifiers are kept; anything else is counted under `"withheld"`.
  # Every list holds at most @max names of at most @name_bytes bytes; a path
  # is checked segment by segment before it is built.
  #
  # Trust: a response key is not structure. An alias gives any field any
  # key (`__typename: password`), so a payload is read only through the
  # operation's own selections, merged by response key as GraphQL merges
  # them (inline fragments and named fragment spreads followed): the
  # `__typename`, `errors`, `field`, and `type` fields are found by their
  # schema names and read by the response key the document gave them, and a
  # top-level error's path is resolved the same way to schema field names.
  # A key that fields of different names share (on mutually exclusive
  # fragment types, `... on A { value: __typename } ... on B { value:
  # password }`) depends on the runtime type, so it is never read. A
  # `__typename` must be a GraphQL name and, when the selection set has
  # fragments, the type condition of one of them. A span's recorded result has no
  # selections, so its payload is never read: from a span only the
  # operation and its top-level errors count, and the result is unknown
  # (`nil`) when there are none.
  #
  # Bounds: this runs in the process that emits the event. At most @visits
  # selection nodes are visited in all, fragments nest at most
  # @fragment_depth deep in one selection set, a fragment spread already
  # expanded in a selection set is not expanded again, and only the first
  # @fragments_max named fragments are read. At most @walk top-level fields
  # and @walk entries of each error list are examined for names; counts are
  # exact up to @count_max, in total. When any bound leaves something
  # unexamined, `"complete"` is false and the result is never `ok` (it is
  # `nil`, unknown, unless an error was found).
  #
  # `"result"` is `"ok"`, `"user_errors"` (no GraphQL error, but a payload
  # reports validation errors), `"partial"` (errors with data), `"errors"`
  # (errors without data, or, from a span, errors), or `nil` (unknown).

  alias Insider.Redaction.Credentials

  @max 6
  @name_bytes 48
  @walk 64
  @count_max 4_096
  # `response_data/1`: levels, values in all, and entries per map or list.
  @data_depth 6
  @data_nodes 2_048
  @data_width 32
  @withheld_value "[WITHHELD:unresolved_field]"
  @masked_value "[REDACTED:credential_key]"
  # The emitting process's work on the document: selection nodes visited in
  # all, fragments nested in one selection set, and named fragments read.
  @visits 2_048
  @fragment_depth 8
  @fragments_max 256
  @json_bytes 65_536
  @name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @code ~r/\A[A-Za-z_][A-Za-z0-9_.:-]*\z/
  @field ~r/\A[A-Za-z_][A-Za-z0-9_.\[\]]*\z/
  @types ["query", "mutation", "subscription"]
  @operation_stop [:absinthe, :execute, :operation, :stop]

  @type t :: %{String.t() => term()}

  @doc "The Telemetry event whose metadata carries an Absinthe blueprint."
  @spec event?([atom()]) :: boolean()
  def event?(name), do: name == @operation_stop

  @doc "The kinds `\"result\"` takes."
  @spec results() :: [String.t()]
  def results, do: ["ok", "user_errors", "partial", "errors"]

  @doc """
  The outcome of an Absinthe operation from its Telemetry metadata (the
  blueprint), or `nil` when the metadata carries none.
  """
  @spec from_metadata(term()) :: t() | nil
  def from_metadata(%{blueprint: %{__struct__: Absinthe.Blueprint} = blueprint}) do
    operation =
      blueprint
      |> Map.get(:operations, [])
      |> Enum.take(@walk)
      |> Enum.find(&(is_map(&1) and Map.get(&1, :current) == true))

    fragments = blueprint |> Map.get(:fragments, []) |> Enum.take(@fragments_max)

    selections = if operation, do: Map.get(operation, :selections, []), else: []

    build(
      operation && Map.get(operation, :name),
      operation && Map.get(operation, :type),
      Map.get(blueprint, :result),
      {selections, fragments}
    )
  rescue
    _error -> nil
  end

  def from_metadata(_metadata), do: nil

  @doc """
  The operation's response `data` as `trace --values` may show it, from its
  Telemetry metadata (the blueprint), or `nil`. A response key is not
  trusted: each is resolved through the operation's merged selections (the
  same rules and bounds as the outcome) to its schema field. A field whose
  schema name or response key is credential-named is masked whole, children
  included; a key no selection made, or that fields of different names
  share (exclusive fragment types), is withheld; past @data_depth levels or
  @data_nodes values, the rest is withheld. Values are then rendered and
  masked by `Insider.Collector.Rich` like any rich value.
  """
  @spec response_data(term()) :: term()
  def response_data(%{
        blueprint: %{__struct__: Absinthe.Blueprint, result: %{data: %{} = data}} = blueprint
      }) do
    operation =
      blueprint
      |> Map.get(:operations, [])
      |> Enum.take(@walk)
      |> Enum.find(&(is_map(&1) and Map.get(&1, :current) == true))

    fragments = blueprint |> Map.get(:fragments, []) |> Enum.take(@fragments_max)
    selections = if operation, do: Map.get(operation, :selections, []), else: []
    {top, walk} = document({selections, fragments})
    {value, _state} = data_map(data, top, {walk, @data_nodes}, 0)
    value
  rescue
    _error -> nil
  end

  def response_data(_metadata), do: nil

  @doc """
  The inputs a mutation received, for `trace --values`: each top-level
  field of the current mutation by its schema name (never the alias the
  client gave it), with its arguments by schema name and their converted
  values (input objects keyed by schema field names, so no client-chosen
  key appears). An argument whose name is credential-named is masked
  whole; `Insider.Collector.Rich` masks credential keys inside. At most
  @walk fields and @walk arguments each; `nil` for a query, a subscription,
  or metadata without a blueprint.
  """
  @spec arguments(term()) :: map() | nil
  def arguments(%{blueprint: %{__struct__: Absinthe.Blueprint} = blueprint}) do
    operation =
      blueprint
      |> Map.get(:operations, [])
      |> Enum.take(@walk)
      |> Enum.find(&(is_map(&1) and Map.get(&1, :current) == true))

    with %{type: :mutation} <- operation do
      fields =
        for %{__struct__: Absinthe.Blueprint.Document.Field, name: name} = field <-
              operation |> Map.get(:selections, []) |> Enum.take(@walk),
            is_binary(name),
            arguments = field_arguments(field),
            arguments != %{},
            into: %{},
            do: {name, arguments}

      if fields == %{}, do: nil, else: fields
    else
      _other -> nil
    end
  rescue
    _error -> nil
  end

  def arguments(_metadata), do: nil

  defp field_arguments(field) do
    for %{__struct__: Absinthe.Blueprint.Input.Argument, name: name} = argument <-
          field |> Map.get(:arguments, []) |> Enum.take(@walk),
        is_binary(name),
        into: %{} do
      value = Map.get(argument, :value)

      {name,
       if(Credentials.credential_key?(name) and value not in [nil, ""],
         do: @masked_value,
         else: value
       )}
    end
  end

  defp data_map(map, level, state, depth) do
    {entries, rest} = map |> Enum.sort_by(&to_string(elem(&1, 0))) |> Enum.split(@data_width)

    {pairs, state} =
      Enum.map_reduce(entries, state, fn {key, value}, state ->
        {value, state} = data_field(key, value, level, state, depth)
        {{key, value}, state}
      end)

    map = Map.new(pairs)
    map = if rest == [], do: map, else: Map.put(map, "$insider_truncated", length(rest))
    {map, state}
  end

  defp data_field(_key, _value, _level, {walk, 0}, _depth), do: {@withheld_value, {walk, 0}}

  defp data_field(key, value, level, {walk, nodes}, depth) do
    state = {walk, nodes - 1}

    case Map.get(level.keys, to_string(key)) do
      %{names: [name]} = entry ->
        cond do
          is_nil(value) ->
            {nil, state}

          Credentials.credential_key?(name) or Credentials.credential_key?(to_string(key)) ->
            {masked(value), state}

          true ->
            data_value(value, entry, state, depth + 1)
        end

      _ambiguous_or_unselected ->
        {@withheld_value, state}
    end
  end

  # A credential-named field is masked whole; a list keeps its shape.
  defp masked(list) when is_list(list), do: list |> Enum.take(@data_width) |> Enum.map(&masked/1)
  defp masked(_value), do: @masked_value

  defp data_value(_value, _entry, state, depth) when depth > @data_depth,
    do: {@withheld_value, state}

  defp data_value(%{} = map, entry, {walk, nodes}, depth) do
    {level, walk} = level(children(entry), walk)
    data_map(map, level, {walk, nodes}, depth)
  end

  defp data_value(list, entry, state, depth) when is_list(list) do
    list
    |> Enum.take(@data_width)
    |> Enum.map_reduce(state, fn
      _item, {walk, 0} -> {@withheld_value, {walk, 0}}
      item, {walk, nodes} -> data_value(item, entry, {walk, nodes - 1}, depth + 1)
    end)
  end

  defp data_value(value, _entry, state, _depth), do: {value, state}

  @doc """
  The outcome from an OpenTelemetry span's attributes (atom or string
  keys), as the opentelemetry_absinthe conventions name them:
  `graphql.operation.name`, `graphql.operation.type`, and, when the
  instrumentation records them, `graphql.response.errors` and
  `graphql.response.result` (JSON text). `nil` when the span has none.
  """
  @spec from_span_attributes(term()) :: t() | nil
  def from_span_attributes(attributes) when is_map(attributes) do
    name = attribute(attributes, "graphql.operation.name")
    type = attribute(attributes, "graphql.operation.type")
    errors = attribute(attributes, "graphql.response.errors")
    result = attribute(attributes, "graphql.response.result")

    if Enum.all?([name, type, errors, result], &is_nil/1) do
      nil
    else
      decoded =
        case json(result) do
          %{} = decoded -> decoded
          _unknown -> %{"errors" => List.wrap(json(errors))}
        end

      build(name, type, decoded, :unresolved)
    end
  rescue
    _error -> nil
  end

  def from_span_attributes(_attributes), do: nil

  @doc "Whether the outcome reports a GraphQL error (severity error)."
  @spec error?(t() | nil) :: boolean()
  def error?(%{"result" => result}), do: result in ["errors", "partial"]
  def error?(_outcome), do: false

  @doc "Whether the outcome reports only payload validation errors."
  @spec user_errors?(t() | nil) :: boolean()
  def user_errors?(%{"result" => "user_errors"}), do: true
  def user_errors?(_outcome), do: false

  @doc """
  A short line for compact output and trace text, such as
  `mutation placeBuyOrder result=user_errors fields=[unitPrice]`.
  """
  @spec text(t() | nil) :: String.t() | nil
  def text(nil), do: nil

  def text(outcome) do
    [
      outcome["operation_type"],
      outcome["operation_name"],
      outcome["result"] && "result=#{outcome["result"]}",
      if(outcome["complete"] == false, do: "incomplete"),
      count("errors", outcome["error_count"]),
      list("codes", outcome["error_codes"]),
      list("paths", outcome["error_paths"]),
      list("types", outcome["typenames"]),
      count("user_errors", outcome["user_error_count"]),
      list("fields", outcome["user_error_fields"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  @doc """
  The outcome as a digest signature: the text without counts or typenames,
  so one failure with different counts is one signature.
  """
  @spec signature(t() | nil) :: String.t() | nil
  def signature(nil), do: nil

  def signature(outcome),
    do:
      outcome
      |> Map.drop(["error_count", "user_error_count", "typenames"])
      |> text()

  defp count(_label, value) when value in [nil, 0], do: nil
  defp count(label, value), do: "#{label}=#{value}"

  defp list(_label, value) when value in [nil, []], do: nil
  defp list(label, values), do: "#{label}=[#{Enum.join(values, ",")}]"

  ## Building

  # `schema` is `{selections, fragments}` of the operation, or `:unresolved`
  # when there is no document (a span): then no payload is read.
  defp build(name, type, result, schema) do
    result = if is_map(result), do: result, else: %{}
    errors = value(result, :errors)
    errors = if is_list(errors), do: errors, else: []
    {error_count, errors_counted?} = count_upto(errors, @count_max)
    examined = Enum.take(errors, @walk)
    data = value(result, :data)

    {top, walk} = document(schema)
    {payloads, walk} = payloads(data, top, walk)
    user_errors = Enum.flat_map(payloads, & &1.errors)

    {user_error_count, user_counted?} =
      Enum.reduce(payloads, {0, true}, fn payload, {total, complete?} ->
        {count, counted?} = count_upto(payload.all_errors, @count_max)

        {min(total + count, @count_max), complete? and counted? and total + count <= @count_max}
      end)

    {paths, walk} = Enum.map_reduce(examined, walk, &path(&1, top, &2))
    complete? = errors_counted? and user_counted? and walk.complete

    {codes, withheld} = names(Enum.map(examined, &code/1), @code, 0)
    {paths, withheld} = names(paths, @field, withheld)
    {typenames, withheld} = names(Enum.map(payloads, & &1.typename), @name, withheld)

    {user_fields, withheld} =
      names(Enum.map(user_errors, &value_at(&1, :field)), @field, withheld)

    {user_types, withheld} = names(Enum.map(user_errors, &value_at(&1, :type)), @code, withheld)
    {operation_name, withheld} = operation_name(name, withheld)

    %{
      "operation_name" => operation_name,
      "operation_type" => operation_type(type),
      "result" => result_kind(error_count, data, user_error_count, schema, complete?),
      "complete" => complete?,
      "error_count" => error_count,
      "error_codes" => codes,
      "error_paths" => paths,
      "typenames" => typenames,
      "user_error_count" => user_error_count,
      "user_error_fields" => user_fields,
      "user_error_types" => user_types,
      "withheld" => withheld
    }
  end

  defp result_kind(errors, data, _user, _schema, _complete?)
       when errors > 0 and data in [nil, %{}],
       do: "errors"

  defp result_kind(errors, _data, _user, _schema, _complete?) when errors > 0, do: "partial"
  defp result_kind(0, _data, _user, :unresolved, _complete?), do: nil
  defp result_kind(0, _data, user, _schema, _complete?) when user > 0, do: "user_errors"
  defp result_kind(0, _data, 0, _schema, true), do: "ok"
  defp result_kind(0, _data, 0, _schema, false), do: nil

  ## The document

  # The traversal's shared budget: the named fragments by name, the visits
  # left, and whether every bound was kept.
  defp document(:unresolved), do: {:unresolved, %{fragments: %{}, visits: 0, complete: true}}

  defp document({selections, fragments}) do
    named =
      for %{__struct__: Absinthe.Blueprint.Document.Fragment.Named, name: name} = fragment <-
            fragments,
          is_binary(name),
          into: %{},
          do: {name, fragment}

    level(selections, %{fragments: named, visits: @visits, complete: true})
  end

  # A selection set merged by response key: each key's schema field names
  # (one unless fragments on exclusive types disagree), its fields' child
  # selection lists, the keys in document order, and the type conditions
  # of the fragments it went through.
  defp level(selections, walk) do
    empty = %{keys: %{}, order: [], conditions: [], spreads: MapSet.new()}
    {level, walk} = collect(selections, 0, empty, walk)
    {%{level | order: Enum.reverse(level.order)}, walk}
  end

  defp collect(selections, depth, level, walk) when is_list(selections) do
    Enum.reduce_while(selections, {level, walk}, fn
      _node, {level, %{visits: 0} = walk} ->
        {:halt, {level, %{walk | complete: false}}}

      node, {level, walk} ->
        {:cont, visit(node, depth, level, %{walk | visits: walk.visits - 1})}
    end)
  end

  defp collect(_selections, _depth, level, walk), do: {level, walk}

  defp visit(
         %{__struct__: Absinthe.Blueprint.Document.Field, name: name} = field,
         _depth,
         level,
         walk
       )
       when is_binary(name) do
    key = Map.get(field, :alias) || name
    children = Map.get(field, :selections, [])

    level =
      case level.keys do
        %{^key => entry} ->
          names = if name in entry.names, do: entry.names, else: [name | entry.names]
          put_in(level, [:keys, key], %{names: names, children: [children | entry.children]})

        _new ->
          %{
            level
            | keys: Map.put(level.keys, key, %{names: [name], children: [children]}),
              order: [key | level.order]
          }
      end

    {level, walk}
  end

  defp visit(
         %{__struct__: Absinthe.Blueprint.Document.Fragment.Inline} = inline,
         depth,
         level,
         walk
       ) do
    level = condition(level, Map.get(inline, :type_condition))
    nested(Map.get(inline, :selections, []), depth, level, walk)
  end

  defp visit(
         %{__struct__: Absinthe.Blueprint.Document.Fragment.Spread, name: name},
         depth,
         level,
         walk
       ) do
    cond do
      MapSet.member?(level.spreads, name) ->
        {level, walk}

      fragment = Map.get(walk.fragments, name) ->
        level =
          condition(%{level | spreads: MapSet.put(level.spreads, name)}, fragment.type_condition)

        nested(Map.get(fragment, :selections, []), depth, level, walk)

      # Past the fragments read, or unknown.
      true ->
        {level, %{walk | complete: false}}
    end
  end

  defp visit(_node, _depth, level, walk), do: {level, walk}

  defp nested(selections, depth, level, walk) when depth + 1 < @fragment_depth,
    do: collect(selections, depth + 1, level, walk)

  defp nested(_selections, _depth, level, walk), do: {level, %{walk | complete: false}}

  defp condition(level, %{name: name}) when is_binary(name),
    do: %{level | conditions: [name | level.conditions]}

  defp condition(level, _condition), do: level

  # The response key of the field with schema name `name`: `{:ok, key,
  # entry}`, `:ambiguous` when its key is shared with fields of other names,
  # or `nil` when none was selected.
  defp key_for(level, name) do
    Enum.reduce_while(level.order, nil, fn key, found ->
      entry = Map.fetch!(level.keys, key)

      cond do
        entry.names == [name] -> {:halt, {:ok, key, entry}}
        name in entry.names -> {:cont, :ambiguous}
        true -> {:cont, found}
      end
    end)
  end

  defp children(level_entry), do: level_entry.children |> Enum.reverse() |> Enum.concat()

  # Each examined top-level field's payload, read through its merged
  # selections: its `__typename` and its `errors` list (the examined maps,
  # `{keys, map}` pairs read by `value_at/2`, and the whole list for the
  # count).
  defp payloads(data, %{order: order} = top, walk) when is_map(data) do
    {examined, rest} = Enum.split(order, @walk)
    walk = if rest == [], do: walk, else: %{walk | complete: false}

    Enum.flat_map_reduce(examined, walk, fn key, walk ->
      entry = Map.fetch!(top.keys, key)

      case {entry.names, Map.get(data, key)} do
        {[_name], %{} = payload} ->
          {payload, walk} = payload(payload, children(entry), walk)
          {[payload], walk}

        # One key for two root fields is not valid GraphQL; read nothing.
        {[_, _ | _], %{}} ->
          {[], %{walk | complete: false}}

        _none ->
          {[], walk}
      end
    end)
  end

  defp payloads(_data, _top, walk), do: {[], walk}

  defp payload(payload, selections, walk) do
    {below, walk} = level(selections, walk)

    typename =
      case key_for(below, "__typename") do
        {:ok, key, _entry} -> typename(Map.get(payload, key), below.conditions)
        :ambiguous -> :withheld
        nil -> nil
      end

    {all, examined, walk} =
      case key_for(below, "errors") do
        {:ok, key, entry} ->
          case Map.get(payload, key) do
            list when is_list(list) ->
              {error_level, walk} = level(children(entry), walk)
              keys = %{field: key_for(error_level, "field"), type: key_for(error_level, "type")}
              {list, for(%{} = error <- Enum.take(list, @walk), do: {keys, error}), walk}

            _none ->
              {[], [], walk}
          end

        # Which field `errors` is depends on the runtime type: unknown.
        :ambiguous ->
          {[], [], %{walk | complete: false}}

        nil ->
          {[], [], walk}
      end

    {%{typename: typename, all_errors: all, errors: examined}, walk}
  end

  # A `__typename` is a GraphQL name, and one of the fragments' types when
  # the selection set has fragments with type conditions.
  defp typename(nil, _conditions), do: nil

  defp typename(value, conditions) do
    if is_binary(value) and byte_size(value) <= @name_bytes and String.match?(value, @name) and
         (conditions == [] or value in conditions),
       do: value,
       else: :withheld
  end

  defp value_at({keys, error}, name) do
    case Map.fetch!(keys, name) do
      {:ok, key, _entry} -> Map.get(error, key)
      :ambiguous -> :withheld
      nil -> nil
    end
  end

  defp count_upto(list, max) do
    Enum.reduce_while(list, {0, true}, fn _entry, {count, _complete?} ->
      if count < max, do: {:cont, {count + 1, true}}, else: {:halt, {count, false}}
    end)
  end

  defp code(error) when is_map(error) do
    extensions = value(error, :extensions)
    (is_map(extensions) && value(extensions, :code)) || value(error, :code)
  end

  defp code(_error), do: nil

  # A top-level error's path in schema field names, each segment checked
  # before it is added: with the operation's selections, a response key
  # resolves to the one field the document selected under it; without, a
  # segment must itself be a name. `:withheld` when it cannot be shown.
  defp path(error, top, walk) when is_map(error) do
    case value(error, :path) do
      [_ | _] = segments ->
        # At most eight segments.
        if match?([_, _, _, _, _, _, _, _, _ | _], segments),
          do: {:withheld, walk},
          else: resolve(segments, top, [], 0, walk)

      _none ->
        {nil, walk}
    end
  end

  defp path(_error, _top, walk), do: {nil, walk}

  defp resolve([], _level, parts, _bytes, walk),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), walk}

  defp resolve([index | rest], level, parts, bytes, walk) when is_integer(index) do
    if bytes + 2 <= @name_bytes,
      do: resolve(rest, level, ["[]" | parts], bytes + 2, walk),
      else: {:withheld, walk}
  end

  defp resolve([segment | rest], level, parts, bytes, walk)
       when is_binary(segment) and byte_size(segment) <= @name_bytes do
    separator = if parts == [], do: "", else: "."

    case step(segment, level, walk) do
      {name, next, walk} ->
        size = bytes + byte_size(separator) + byte_size(name)

        if size <= @name_bytes,
          do: resolve(rest, next, [name, separator | parts], size, walk),
          else: {:withheld, walk}

      {:withheld, walk} ->
        {:withheld, walk}
    end
  end

  defp resolve(_segments, _level, _parts, _bytes, walk), do: {:withheld, walk}

  defp step(segment, :unresolved, walk), do: {segment, :unresolved, walk}

  defp step(segment, level, walk) do
    case Map.get(level.keys, segment) do
      %{names: [name]} = entry ->
        {next, walk} = level(children(entry), walk)
        {name, next, walk}

      _ambiguous_or_unknown ->
        {:withheld, walk}
    end
  end

  # Distinct names in order; a name that is not shaped like one, or too
  # long, is withheld and counted.
  defp names(candidates, pattern, withheld) do
    {kept, withheld} =
      Enum.reduce(candidates, {[], withheld}, fn
        nil, acc ->
          acc

        :withheld, {kept, withheld} ->
          {kept, withheld + 1}

        candidate, {kept, withheld} ->
          text = if is_atom(candidate), do: Atom.to_string(candidate), else: candidate

          if is_binary(text) and byte_size(text) <= @name_bytes and String.match?(text, pattern),
            do: {if(text in kept, do: kept, else: [text | kept]), withheld},
            else: {kept, withheld + 1}
      end)

    kept = Enum.reverse(kept)
    {Enum.take(kept, @max), withheld + max(length(kept) - @max, 0)}
  end

  defp operation_name(nil, withheld), do: {nil, withheld}

  defp operation_name(name, withheld) do
    case names([name], @name, withheld) do
      {[name], withheld} -> {name, withheld}
      {[], withheld} -> {nil, withheld}
    end
  end

  defp operation_type(type) when is_atom(type) and not is_nil(type),
    do: operation_type(Atom.to_string(type))

  defp operation_type(type) when type in @types, do: type
  defp operation_type(_type), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  for key <- [
        "graphql.operation.name",
        "graphql.operation.type",
        "graphql.response.errors",
        "graphql.response.result"
      ] do
    defp attribute(attributes, unquote(key)),
      do: Map.get(attributes, unquote(key), Map.get(attributes, unquote(String.to_atom(key))))
  end

  defp json(text) when is_binary(text) and byte_size(text) <= @json_bytes do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp json(_text), do: nil
end
