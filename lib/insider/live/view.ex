defmodule Insider.Live.View do
  @moduledoc false

  # A per-reader, read-time view over the one recorded stream. Several
  # agents can read the same session through different views: a view only
  # narrows what its own reader is shown, never what is recorded or what
  # another reader sees. Hidden events still advance the reader's cursor, and
  # each batch counts what the view hid, per view filter.
  #
  # A view applies to events after the live disclosure boundary, so it sees
  # exactly what the reader would otherwise receive. `Insider.Live.Batch`
  # applies it event by event, so a read's limits count shown events only.
  #
  # Two kinds of filter read more than an event's source, kind, and
  # severity, always on the event as disclosed (`deep?/1`):
  #
  # - `exclude_signatures` hides events by their error signature, as the
  #   digest names it (`Insider.Live.Digest.signature/1`): a hex prefix of 8
  #   to 64 digits matches the signature's `id` or a supervisor report's
  #   `reason_fingerprint`; a module name matches a signature that names the
  #   module, or a supervisor report's offender.
  # - `services`, `routes`, and `traces` together scope the view to traces:
  #   an event is in scope when it names a listed service or route itself,
  #   or when its trace id is one the owner resolved for the view
  #   (`resolve/2`): a listed trace, or one in which a span named a listed
  #   service or route. An event outside the scope is counted under
  #   `"scope"`.
  #
  # A view matches only on what it is given and what the reader is shown, so
  # it reveals nothing beyond the events it lets through.

  alias Insider.Live.Digest
  alias Insider.Live.Error
  alias Insider.Protocol.Value
  alias Insider.Redaction.Credentials

  @keys [
    "exclude_kinds",
    "exclude_signatures",
    "kinds",
    "min_severity",
    "routes",
    "services",
    "sources",
    "traces"
  ]
  @sources ["calls", "inspect", "logger", "otel", "poller", "telemetry"]
  @severities %{"debug" => 0, "info" => 1, "warning" => 2, "error" => 3, "critical" => 4}
  @max_kinds 32
  @max_signatures 16
  @max_services 8
  @max_routes 8
  @max_traces 32
  @label_bytes 128
  @kind ~r/\A[a-z][a-z0-9_.-]*(\.\*)?\z/
  @hex ~r/\A[0-9a-f]{8,64}\z/
  @module ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @route ~r/\A\/[\x21-\x7E]*\z/
  @trace_id ~r/\A[0-9a-f]{32}\z/

  @type t :: %{
          spec: map(),
          sources: [String.t()] | nil,
          kinds: {MapSet.t(), [String.t()]} | nil,
          exclude_kinds: {MapSet.t(), [String.t()]} | nil,
          min_severity: non_neg_integer() | nil,
          exclude_signatures: {[String.t()], [String.t()]} | nil,
          services: [String.t()] | nil,
          routes: [String.t()] | nil,
          traces: [String.t()] | nil,
          trace_ids: MapSet.t()
        }

  @doc "The view keys, for the welcome document."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The view description, for the welcome document's read options."
  @spec describe() :: map()
  def describe do
    %{
      "type" => "map",
      "default" => nil,
      "keys" => %{
        "sources" => %{"type" => "list of strings", "allowed" => @sources},
        "kinds" => %{
          "type" => "list of strings",
          "max" => @max_kinds,
          "note" => "event kinds to show; \"prefix.*\" matches a dotted prefix"
        },
        "exclude_kinds" => %{
          "type" => "list of strings",
          "max" => @max_kinds,
          "note" => "event kinds to hide; \"prefix.*\" matches a dotted prefix"
        },
        "min_severity" => %{
          "type" => "string",
          "allowed" => @severities |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
        },
        "exclude_signatures" => %{
          "type" => "list of strings",
          "max" => @max_signatures,
          "note" =>
            "error signatures to hide: a hex prefix (8 to 64 digits) of a digest signature's id or of a " <>
              "supervisor report's reason_fingerprint, or a module name (such as MyApp.Worker) the signature " <>
              "or the report's offender names"
        },
        "services" => %{
          "type" => "list of strings",
          "max" => @max_services,
          "note" =>
            "service names (otel.span attributes.service); with routes and traces, keeps whole traces"
        },
        "routes" => %{
          "type" => "list of strings",
          "max" => @max_routes,
          "note" =>
            "route templates or paths starting with /, matched exactly or as a path prefix against a span's " <>
              "http.route or next.route, else its url.path or http.target without the query; known from spans " <>
              "the session ingested in the rich profile"
        },
        "traces" => %{
          "type" => "list of strings",
          "max" => @max_traces,
          "note" => "trace ids (32 lowercase hex digits) whose events to keep"
        }
      },
      "note" =>
        "narrows only this read, never what is recorded; hidden events advance the cursor and are " <>
          "counted in filtered.view, per view filter (services, routes, and traces together as scope). " <>
          "With view_keep and a reader it becomes the reader's stored view for its later reads; " <>
          "an empty view clears the stored view"
    }
  end

  @doc """
  Validates a view. `nil` is no view, and so is an empty one. A label or
  pattern that credential masking would change is refused, so a view, which
  is stored for its reader and echoed in results and `status`, never holds
  a secret-shaped value.
  """
  @spec parse(term()) :: {:ok, t() | nil} | {:error, map()}
  def parse(nil), do: {:ok, nil}
  def parse(view) when view == %{}, do: {:ok, nil}

  def parse(view) when is_map(view) and not is_struct(view) and map_size(view) <= 8 do
    with true <- Enum.all?(Map.keys(view), &(&1 in @keys)),
         {:ok, sources} <- sources(Map.get(view, "sources")),
         {:ok, kinds} <- kinds(Map.get(view, "kinds")),
         {:ok, exclude_kinds} <- kinds(Map.get(view, "exclude_kinds")),
         {:ok, min_severity} <- severity(Map.get(view, "min_severity")),
         {:ok, signatures} <- signatures(Map.get(view, "exclude_signatures")),
         {:ok, services} <- labels(Map.get(view, "services"), @max_services, &label?/1),
         {:ok, routes} <- labels(Map.get(view, "routes"), @max_routes, &route?/1),
         {:ok, traces} <- labels(Map.get(view, "traces"), @max_traces, &trace_id?/1) do
      {:ok,
       %{
         spec: view,
         sources: sources,
         kinds: kinds,
         exclude_kinds: exclude_kinds,
         min_severity: min_severity,
         exclude_signatures: signatures,
         services: services,
         routes: routes,
         traces: traces,
         trace_ids: MapSet.new(traces || [])
       }}
    else
      _invalid -> invalid()
    end
  end

  def parse(_view), do: invalid()

  @doc """
  Whether the view scopes to traces, so the owner must resolve its trace
  ids with `resolve/2`.
  """
  @spec scoped?(t() | nil) :: boolean()
  def scoped?(nil), do: false
  def scoped?(view), do: view.services != nil or view.routes != nil or view.traces != nil

  @doc """
  Adds to the view's trace ids every trace in `index` (trace id => the
  services and routes its spans named) that names one of its services or
  routes.
  """
  #
  # Routes are disclosed only in the rich profile, so they resolve traces
  # only while the session's effective profile is rich (`rich?`): a route
  # learned under rich no longer matches after the host narrows to strict.
  # The index holds credential-masked labels, and a view's labels are never
  # secret-shaped (`parse/1`), so a view never matches on a masked value.
  @spec resolve(
          t() | nil,
          %{String.t() => %{services: MapSet.t(), routes: MapSet.t()}},
          boolean()
        ) ::
          t() | nil
  def resolve(view, index, rich?) do
    if scoped?(view) and (view.services != nil or view.routes != nil) do
      found =
        for {trace_id, trace} <- index,
            Enum.any?(trace.services, &service?(view, &1)) or
              (rich? and Enum.any?(trace.routes, &route_match?(view, &1))),
            into: view.trace_ids,
            do: trace_id

      %{view | trace_ids: found}
    else
      view
    end
  end

  @doc "Whether the view reads more than an event's source, kind, and severity."
  @spec deep?(t() | nil) :: boolean()
  def deep?(nil), do: false
  def deep?(view), do: view.exclude_signatures != nil or scoped?(view)

  @doc """
  The zero count of every filter `view` configures: the shape of
  `"filtered"."view"` for a read that hid nothing.
  """
  @spec counts(t() | nil) :: %{optional(String.t()) => 0}
  def counts(nil), do: %{}

  def counts(view),
    do: for({name, filter} <- filters(view), filter, into: %{}, do: {name, 0})

  @doc """
  The view filter that hides a projected `event` by its source, kind, or
  severity, or `nil`. An event is hidden by the first matching filter, in
  the order sources, kinds, exclude_kinds, min_severity.
  """
  @spec hides(t() | nil, map()) :: String.t() | nil
  def hides(nil, _event), do: nil

  def hides(view, event) do
    cond do
      view.sources != nil and event["source"] not in view.sources -> "sources"
      view.kinds != nil and not kind?(view.kinds, event["kind"]) -> "kinds"
      view.exclude_kinds != nil and kind?(view.exclude_kinds, event["kind"]) -> "exclude_kinds"
      view.min_severity != nil and rank(event["severity"]) < view.min_severity -> "min_severity"
      true -> nil
    end
  end

  @doc """
  The deep filter that hides a disclosed `event`, or `nil`: its signature
  (`"exclude_signatures"`), then its trace scope (`"scope"`).
  """
  @spec hides_deep(t() | nil, map()) :: String.t() | nil
  def hides_deep(nil, _event), do: nil

  def hides_deep(view, event) do
    cond do
      view.exclude_signatures != nil and signature?(view.exclude_signatures, event) ->
        "exclude_signatures"

      scoped?(view) and not in_scope?(view, event) ->
        "scope"

      true ->
        nil
    end
  end

  @doc "Adds two count maps."
  @spec add(map() | nil, map() | nil) :: map()
  def add(left, right),
    do: Map.merge(left || %{}, right || %{}, fn _filter, a, b -> a + b end)

  @doc """
  What a reader's stored view did to a read that gave no view of its own:
  the reader, the stored view's spec, how many events it hid (`nil` when
  the read does not count them), `"source"` `"reader"` (the reader's stored
  view now), and a note that names `--view-clear`. `hidden` is a count map
  (`filtered.view`), a count, or `nil`.
  """
  @spec stored(String.t(), map(), map() | non_neg_integer() | nil) :: map()
  def stored(reader, spec, hidden) do
    hidden = sum(hidden)
    effect = if hidden, do: "hid #{hidden} events from this read", else: "narrows this read"

    %{
      "reader" => reader,
      "view" => spec,
      "hidden" => hidden,
      "source" => "reader",
      "note" =>
        "reader #{reader}'s stored view (#{describe_spec(spec)}, kept with --view-keep) #{effect}; " <>
          "--view-clear clears it"
    }
  end

  @doc """
  The same for a subscription that gave no view of its own: it keeps the
  stored view it inherited when it subscribed (`"source"`
  `"subscription_snapshot"`), whatever later happens to the reader's stored
  view, so its note says that changing it needs a new subscription.
  """
  @spec subscription_snapshot(String.t(), map(), map() | non_neg_integer() | nil) :: map()
  def subscription_snapshot(reader, spec, hidden) do
    hidden = sum(hidden)
    effect = if hidden, do: "hid #{hidden} events from this batch", else: "narrows its pushes"

    %{
      "reader" => reader,
      "view" => spec,
      "hidden" => hidden,
      "source" => "subscription_snapshot",
      "note" =>
        "this subscription reads through reader #{reader}'s stored view as it was when it subscribed " <>
          "(#{describe_spec(spec)}, kept with --view-keep), which #{effect}; it does not follow later " <>
          "changes to that view: subscribe again to read through another"
    }
  end

  defp sum(hidden) when is_map(hidden), do: hidden |> Map.values() |> Enum.sum()
  defp sum(hidden), do: hidden

  @doc """
  Said by a read that kept `spec` (which hid `hidden` events, a count map
  or a count; `nil` when it counted none, as a subscription has not read
  yet) or cleared it (`nil`), because the change reaches the reader's later
  reads, not this one.
  """
  @spec stored_change_note(String.t(), map() | nil, map() | non_neg_integer() | nil) ::
          String.t()
  def stored_change_note(reader, nil, _hidden), do: "reader #{reader}'s stored view is cleared"

  def stored_change_note(reader, _spec, hidden) do
    hidden = sum(hidden)

    "this view is now reader #{reader}'s stored view for its later reads (events, watch, digest, trends, " <>
      "trace, timeline, changes, mutations) until --view-clear" <>
      if(hidden, do: "; it hid #{hidden} events here", else: "")
  end

  defp describe_spec(spec) do
    spec
    |> Enum.sort()
    |> Enum.map_join("; ", fn {key, values} -> "#{key} #{Enum.join(List.wrap(values), ", ")}" end)
  end

  @doc "The trace id an event belongs to, or `nil`."
  @spec trace_id(map()) :: String.t() | nil
  def trace_id(event) do
    candidate =
      get_in_map(event, ["causality", "trace_id"]) ||
        get_in_map(event, ["attributes", "trace_id"])

    if trace_id?(candidate), do: candidate
  end

  @doc "The route a span's attributes name (`Insider.Collector.Otel.Span.route/1`)."
  @spec route(term()) :: String.t() | nil
  defdelegate route(attributes), to: Insider.Collector.Otel.Span

  @doc "Whether `value` is a service name a view or the trace index keeps."
  @spec label?(term()) :: boolean()
  def label?(value),
    do: is_binary(value) and byte_size(value) in 1..@label_bytes and String.valid?(value)

  defp filters(view) do
    [
      {"sources", view.sources},
      {"kinds", view.kinds},
      {"exclude_kinds", view.exclude_kinds},
      {"min_severity", view.min_severity},
      {"exclude_signatures", view.exclude_signatures},
      {"scope", scoped?(view) || nil}
    ]
  end

  defp signature?({hexes, modules}, event) do
    attributes = if is_map(event["attributes"]), do: event["attributes"], else: %{}
    fingerprint = attributes["reason_fingerprint"]
    offender = attributes["offender_id"]
    text = Digest.signature(event)
    id = Digest.signature_id(text)

    Enum.any?(hexes, fn hex ->
      String.starts_with?(id, hex) or
        (is_binary(fingerprint) and String.starts_with?(fingerprint, hex))
    end) or
      Enum.any?(modules, fn module ->
        offender == "atom:Elixir." <> module or names_module?(text, module)
      end)
  end

  # A whole dotted name: the module itself or its last segments, with no
  # identifier character on either side.
  defp names_module?(text, module) do
    Regex.match?(
      ~r/(?<![A-Za-z0-9_.])(?:[A-Z][A-Za-z0-9_]*\.)*#{Regex.escape(module)}(?![A-Za-z0-9_])/,
      text
    )
  end

  defp in_scope?(view, event) do
    attributes = if is_map(event["attributes"]), do: event["attributes"], else: %{}
    span_attributes = get_in_map(event, ["payload", "span_attributes"])

    service?(view, attributes["service"]) or
      route_match?(view, route(span_attributes)) or
      MapSet.member?(view.trace_ids, trace_id(event))
  end

  defp service?(%{services: nil}, _service), do: false
  defp service?(view, service), do: is_binary(service) and service in view.services

  defp route_match?(%{routes: nil}, _route), do: false
  defp route_match?(_view, nil), do: false

  defp route_match?(view, route) do
    Enum.any?(view.routes, fn prefix ->
      route == prefix or
        (String.starts_with?(route, prefix) and
           (String.ends_with?(prefix, "/") or
              String.at(route, String.length(prefix)) == "/"))
    end)
  end

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, value ->
      if is_map(value), do: {:cont, Map.get(value, key)}, else: {:halt, nil}
    end)
  end

  defp kind?({exact, prefixes}, kind) when is_binary(kind),
    do: MapSet.member?(exact, kind) or Enum.any?(prefixes, &String.starts_with?(kind, &1))

  defp kind?(_matcher, _kind), do: false

  defp rank(severity), do: Map.get(@severities, severity, 0)

  defp sources(nil), do: {:ok, nil}

  defp sources(sources) do
    if Value.bounded_list?(sources, length(@sources)) and sources != [] and
         sources == Enum.uniq(sources) and Enum.all?(sources, &(&1 in @sources)),
       do: {:ok, sources},
       else: :error
  end

  defp kinds(nil), do: {:ok, nil}

  defp kinds(kinds) do
    if Value.bounded_list?(kinds, @max_kinds) and kinds != [] and
         Enum.all?(kinds, &(is_binary(&1) and byte_size(&1) <= 128 and String.match?(&1, @kind))) do
      {prefixes, exact} = Enum.split_with(kinds, &String.ends_with?(&1, ".*"))
      {:ok, {MapSet.new(exact), Enum.map(prefixes, &String.trim_trailing(&1, "*"))}}
    else
      :error
    end
  end

  defp signatures(nil), do: {:ok, nil}

  defp signatures(patterns) do
    if Value.bounded_list?(patterns, @max_signatures) and patterns != [] and
         Enum.all?(patterns, &signature_pattern?/1) do
      {:ok, Enum.split_with(patterns, &String.match?(&1, @hex))}
    else
      :error
    end
  end

  defp signature_pattern?(pattern),
    do:
      is_binary(pattern) and byte_size(pattern) <= @label_bytes and
        (String.match?(pattern, @hex) or String.match?(pattern, @module)) and unmasked?(pattern)

  defp labels(nil, _max, _valid?), do: {:ok, nil}

  defp labels(values, max, valid?) do
    if Value.bounded_list?(values, max) and values != [] and
         Enum.all?(values, &(valid?.(&1) and unmasked?(&1))),
       do: {:ok, Enum.uniq(values)},
       else: :error
  end

  defp unmasked?(value), do: Credentials.mask_text(value) == value

  defp route?(value),
    do: is_binary(value) and byte_size(value) <= @label_bytes and String.match?(value, @route)

  defp trace_id?(value),
    do: is_binary(value) and String.match?(value, @trace_id) and String.trim(value, "0") != ""

  defp severity(nil), do: {:ok, nil}
  defp severity(severity) when is_map_key(@severities, severity), do: {:ok, @severities[severity]}
  defp severity(_severity), do: :error

  defp invalid, do: {:error, Error.new("invalid_options", %{"field" => "view"})}
end
