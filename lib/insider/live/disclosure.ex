defmodule Insider.Live.Disclosure do
  @moduledoc false

  # The live export boundary. The transport caller is not trusted to decide
  # what is disclosed, so the host chooses a disclosure profile and every
  # event leaving `Insider.Live` is projected here.
  #
  # Profiles, richest first. The host sets `config :insider, :live_disclosure`
  # to `:rich` or `:strict`; without it, development and test are `:rich` and
  # ci is `:strict`. Any other configured value, and any environment where
  # live observation is denied, is `:strict`. A session may ask for a
  # stricter profile, never a richer one, and a host that narrows its
  # profile narrows every running session from its next read.
  #
  # `:rich` passes events as the collectors recorded them: Logger message
  # text and metadata, Telemetry metadata and all measurements, rendered and
  # bounded by `Insider.Collector.Rich`, and causality as recorded.
  #
  # `:strict` keeps only opaque, shape-checked values. Each withheld value
  # becomes a `drop` record in the event's `"redactions"` manifest.
  #
  # - Causality: `trace_id` is kept only as 32 and `span_id` only as 16
  #   lowercase hex digits, not all zero (the W3C trace-context shapes).
  #   `parent_event_id`, `logical_operation_id`, and `process_generation` are
  #   free-form and always withheld.
  # - Logger supervisor identities: a `binary:` semantic id is replaced by
  #   `binary-sha256:` and the SHA-256 of the value; atom, integer, pid, and
  #   tuple-digest ids are kept.
  # - Telemetry measurements: only names in the host allowlist, and only
  #   integer or decimal-float values. Telemetry metadata is always empty.
  # - Payloads are always `nil`.
  #
  # In every profile, `Insider.Redaction.Credentials` then masks credential
  # keys and secret-shaped strings anywhere in the event, and each mask
  # becomes a `mask` record with its reason.

  alias Insider.Collector.ObanJob
  alias Insider.Collector.Rich
  alias Insider.Collector.Telemetry.Omitted
  alias Insider.Live.Environment
  alias Insider.Live.Error
  alias Insider.Protocol.Value
  alias Insider.Redaction.Credentials

  @policy_id "insider-live-boundary/v1"
  @selection_policy_id "insider-live-telemetry"
  @profiles [:rich, :strict]
  @default_profiles %{development: :rich, test: :rich, ci: :strict}
  @default_measurements [
    :count,
    :decode_time,
    :duration,
    :idle_time,
    :query_time,
    :queue_time,
    :total_time
  ]
  @max_measurements 16
  @semantic_id_attributes ["offender_id", "supervisor"]
  @trace_id ~r/\A[0-9a-f]{32}\z/
  @span_id ~r/\A[0-9a-f]{16}\z/
  @decimal ~r/\A-?[0-9]+(\.[0-9]+)?(e-?[0-9]+)?\z/
  @measurement_name ~r/\A[a-z][a-z0-9_]*\z/
  # Telemetry time measurements, in the emitting node's native time unit by
  # the Phoenix, Ecto, Oban, and Bandit conventions.
  @time_measurements [
    "decode_time",
    "duration",
    "idle_time",
    "query_time",
    "queue_time",
    "total_time"
  ]

  @doc "The id of the fixed live disclosure boundary."
  @spec policy_id() :: String.t()
  def policy_id, do: @policy_id

  @doc """
  The id of the live sessions' Telemetry collection policy, which names a
  measurement or metadata key the session did not select in its drop record.
  """
  @spec selection_policy_id() :: String.t()
  def selection_policy_id, do: @selection_policy_id

  @doc """
  The Telemetry measurement names read as native-unit durations. Each one a
  disclosed event carries as an integer is repeated in microseconds under
  `attributes.durations_us`.
  """
  @spec time_measurements() :: [String.t()]
  def time_measurements, do: @time_measurements

  @type profile :: :rich | :strict

  @doc "Every disclosure profile name, richest first."
  @spec profiles() :: [String.t()]
  def profiles, do: Enum.map(@profiles, &Atom.to_string/1)

  @doc """
  The host's disclosure profile and where it came from: `"application_env"`,
  `"invalid_application_env"` (fails closed to strict), or
  `"environment_default"`.
  """
  @spec host_profile() :: {profile(), String.t()}
  def host_profile do
    %{environment: environment} = Environment.resolve()

    case {Map.fetch(@default_profiles, environment),
          Application.fetch_env(:insider, :live_disclosure)} do
      {:error, _configured} -> {:strict, "environment_default"}
      {{:ok, _default}, {:ok, profile}} when profile in @profiles -> {profile, "application_env"}
      {{:ok, _default}, {:ok, _invalid}} -> {:strict, "invalid_application_env"}
      {{:ok, default}, :error} -> {default, "environment_default"}
    end
  end

  @doc """
  The host profile and masking policy, as reported by `capabilities/0`.
  """
  @spec describe() :: map()
  def describe do
    {profile, source} = host_profile()

    %{
      "disclosure_profile" => Atom.to_string(profile),
      "disclosure_profile_source" => source,
      "disclosure_profiles" => profiles(),
      "masking_policy_id" => Credentials.policy_id()
    }
  end

  @doc """
  Resolves a session's requested profile (`nil` for the host's) against the
  host profile. A request for a richer profile is `disclosure_denied`.
  """
  @spec session_profile(profile() | nil) :: {:ok, profile()} | {:error, map()}
  def session_profile(requested) do
    {host, _source} = host_profile()

    cond do
      is_nil(requested) ->
        {:ok, host}

      rank(requested) >= rank(host) ->
        {:ok, requested}

      true ->
        {:error,
         Error.new("disclosure_denied", %{
           "requested" => Atom.to_string(requested),
           "disclosure_profile" => Atom.to_string(host)
         })}
    end
  end

  @doc """
  The profile a session discloses with now: its own, or the host's when the
  host has since narrowed.
  """
  @spec effective(profile()) :: profile()
  def effective(session_profile) do
    {host, _source} = host_profile()
    Enum.max_by([session_profile, host], &rank/1)
  end

  defp rank(profile), do: Enum.find_index(@profiles, &(&1 == profile))

  @doc """
  The fixed disclosure contract for the welcome document. The host's current
  profile is runtime state and is reported by `describe/0` instead.
  """
  @spec contract() :: map()
  def contract do
    %{
      "profiles" => profiles(),
      "host_setting" => "config :insider, :live_disclosure, :rich | :strict",
      "defaults" => %{
        "development" => "rich",
        "test" => "rich",
        "ci" => "strict",
        "invalid_setting" => "strict",
        "denied_environments" => "strict"
      },
      "caller_option" => "disclosure",
      "caller_may" => "narrow only: a richer request is disclosure_denied",
      "strict_policy_id" => @policy_id,
      "selection_policy_id" => @selection_policy_id,
      "masking_policy_id" => Credentials.policy_id(),
      "masking_reasons" => Credentials.reasons(),
      "rich_bounds" => Rich.bounds(),
      "rules" => %{
        "rich" => [
          "Logger payload: level, message text, rendered metadata, and the report for report messages; report_cb is never called.",
          "Telemetry payload: every metadata key, rendered; every measurement unless telemetry_measurements selects some.",
          "OpenTelemetry span payload: span_attributes, rendered; attributes.status_message is the span's status description.",
          "Rendering runs no application code: structs render field by field, only Calendar.ISO values as text.",
          "Ecto redact: true fields, collected at session start, become [REDACTED:redacted_field].",
          "Call traces: payload.arguments, payload.result and payload.reason are rendered, each at most calls_max_bytes JSON bytes."
        ],
        "strict" => [
          "Event payloads are always nil.",
          "Logger message text, report fields, and metadata are not collected at all, so they leave no drop record.",
          "Call traces keep the function, call_id, duration_us, class and exception module; arguments never leave the calling process, and results and reasons are not recorded.",
          "Telemetry metadata is always empty; only allowlisted numeric measurements leave the node.",
          "OpenTelemetry spans keep their W3C-shaped ids, name, span_kind, status, service, scope, capture, and timing; " <>
            "span attributes and the status message are not collected, and a status message recorded under rich is withheld.",
          "Causality keeps only W3C-shaped trace_id and span_id; binary supervisor ids are SHA-256 digests.",
          "A summary's duration statistics and its exemplars' duration_us follow its duration_measurements: withheld unless every " <>
            "name is allowlisted, one drop record per value ([key:attributes, key:summary, key:exemplars, index:N, key:duration_us] " <>
            "for an exemplar). duration_scope.emitter.module, and a logger_summary's template and call_site, are withheld; " <>
            "template_fingerprint and call_site_fingerprint are kept.",
          "Every value this boundary withholds from a collected event is a drop record with strict_policy_id in the entry's redactions."
        ],
        "every_profile" => [
          "A Telemetry measurement the session did not select is not collected and leaves a drop record with selection_policy_id " <>
            "in the entry's redactions: path [key:attributes, key:measurements, key:NAME] when NAME is in telemetry_measurements_allowed " <>
            "(restart with telemetry_measurements NAME to collect it), else one record at [key:attributes, key:measurements] counting the rest. " <>
            "In strict, uncollected Telemetry metadata keys leave one record at [key:attributes, key:metadata] with their count.",
          "Without telemetry_measurements, rich collects every measurement and strict collects none.",
          "Credential-named keys and secret-shaped strings are masked at every nesting level.",
          "Every mask is a mask record with its reason in the entry's redactions, never the value."
        ]
      }
    }
  end

  @doc """
  The host-approved Telemetry measurement allowlist, as a name-to-atom map.

  `config :insider, :live_telemetry_measurements` replaces the default with a
  list of up to 16 lowercase atoms. Any other configured value allows none.
  """
  @spec measurement_allowlist() :: %{String.t() => atom()}
  def measurement_allowlist do
    case Application.get_env(:insider, :live_telemetry_measurements, @default_measurements) do
      atoms when is_list(atoms) ->
        if Value.bounded_list?(atoms, @max_measurements) and
             Enum.all?(atoms, &measurement_atom?/1),
           do: Map.new(atoms, &{Atom.to_string(&1), &1}),
           else: %{}

      _invalid ->
        %{}
    end
  end

  @doc """
  Projects one `read_events` entry onto the live disclosure boundary of
  `profile`, then masks credentials. A Telemetry event's collection-time
  omission evidence (`Insider.Collector.Telemetry.Omitted`, a measurement or
  metadata key the session did not select) becomes `drop` records in the
  entry's manifest, so every withheld value is listed in one place.
  """
  @spec project(map(), %{String.t() => atom()}, profile()) :: map()
  def project(%{"event" => event} = entry, allowlist, profile) do
    {event, omitted} = omitted(event)
    {event, withheld} = boundary(event, allowlist, profile)
    event = event |> durations_us() |> oban_args()
    {event, masked} = Credentials.mask(event)
    redactions = Map.get(entry, "redactions", []) ++ omitted ++ manifest(withheld) ++ masked
    %{entry | "event" => event} |> Map.put("redactions", redactions)
  end

  # A rich Oban job event's args, as the payload rendered them, with Oban
  # Pro's `term-` values decoded when read, never in the emitting process
  # (`Insider.Collector.ObanJob`), then rendered within @oban_args_bytes; the
  # credential mask that follows covers them.
  @oban_args_bytes 2_048

  defp oban_args(%{"kind" => kind, "payload" => %{} = payload} = event) do
    {terms, payload} = Map.pop(payload, "oban_terms")

    case get_in(payload, ["metadata", "job", "args"]) do
      args when is_map(args) ->
        if ObanJob.kind?(kind),
          do: %{
            event
            | "payload" =>
                Map.put(
                  payload,
                  "oban_args",
                  Rich.render(ObanJob.decode(args, terms), @oban_args_bytes)
                )
          },
          else: %{event | "payload" => payload}

      _none ->
        %{event | "payload" => payload}
    end
  end

  defp oban_args(event), do: event

  # Well-formed evidence becomes its drop records. Anything else under the
  # key is withheld whole, with one boundary drop record.
  defp omitted(%{"source" => "telemetry", "attributes" => %{} = attributes} = event) do
    case Map.fetch(attributes, Omitted.key()) do
      :error ->
        {event, []}

      {:ok, omitted} ->
        attributes = Map.delete(attributes, Omitted.key())

        records =
          if Omitted.valid?(omitted),
            do: Omitted.drops(omitted),
            else: manifest([["attributes", Omitted.key()]])

        {%{event | "attributes" => attributes}, records}
    end
  end

  defp omitted(event), do: {event, []}

  # Derived from the measurements as disclosed, so it never reveals a value
  # the boundary withheld.
  defp durations_us(%{"source" => "telemetry", "attributes" => %{} = attributes} = event) do
    durations =
      for name <- @time_measurements,
          value = get_in(attributes, ["measurements", name]),
          is_integer(value),
          into: %{},
          do: {name, System.convert_time_unit(value, :native, :microsecond)}

    if map_size(durations) == 0,
      do: event,
      else: %{event | "attributes" => Map.put(attributes, "durations_us", durations)}
  end

  defp durations_us(event), do: event

  defp boundary(event, _allowlist, :rich), do: {event, []}

  defp boundary(event, allowlist, :strict) do
    {causality, withheld} = causality(event["causality"] || %{})
    {attributes, withheld} = attributes(event, allowlist, withheld)

    # A payload recorded under the rich profile and exported under strict
    # (the host narrowed since) is withheld, and says so.
    withheld = if is_nil(event["payload"]), do: withheld, else: [["payload"] | withheld]

    event =
      event
      |> Map.put("causality", causality)
      |> Map.put("attributes", attributes)
      |> Map.put("payload", nil)

    {event, withheld}
  end

  defp causality(causality) do
    Enum.reduce(causality, {%{}, []}, fn {key, value}, {kept, withheld} ->
      if nil == value or opaque_identifier?(key, value),
        do: {Map.put(kept, key, value), withheld},
        else: {Map.put(kept, key, nil), [["causality", key] | withheld]}
    end)
  end

  # Only the two fixed trace-context shapes are opaque; every other
  # causality field is free-form caller metadata and is withheld.
  defp opaque_identifier?("trace_id", value), do: hex_identifier?(value, @trace_id)
  defp opaque_identifier?("span_id", value), do: hex_identifier?(value, @span_id)
  defp opaque_identifier?(_key, _value), do: false

  defp hex_identifier?(value, pattern),
    do: is_binary(value) and String.match?(value, pattern) and String.trim(value, "0") != ""

  defp attributes(%{"source" => "telemetry", "attributes" => attributes}, allowlist, withheld) do
    {measurements, withheld} =
      measurements(attributes["measurements"] || %{}, allowlist, withheld)

    withheld =
      if map_size(attributes["metadata"] || %{}) > 0,
        do: [["attributes", "metadata"] | withheld],
        else: withheld

    {summary, withheld} = summary(attributes["summary"], allowlist, withheld)

    attributes =
      attributes
      |> Map.put("measurements", measurements)
      |> Map.put("metadata", %{})
      |> put_summary(summary)

    graphql(attributes, withheld)
  end

  # A span's structure passes; its ids only in their W3C shapes. The status
  # message is application text and is withheld.
  defp attributes(%{"source" => "otel", "attributes" => attributes}, _allowlist, withheld) do
    shapes = [{"trace_id", @trace_id}, {"span_id", @span_id}, {"parent_span_id", @span_id}]

    {attributes, withheld} =
      Enum.reduce(shapes, {attributes, withheld}, fn {key, pattern}, {attributes, withheld} ->
        value = attributes[key]

        if is_nil(value) or hex_identifier?(value, pattern),
          do: {attributes, withheld},
          else: {Map.put(attributes, key, nil), [["attributes", key] | withheld]}
      end)

    {attributes, withheld} =
      if is_nil(attributes["status_message"]),
        do: {attributes, withheld},
        else:
          {Map.put(attributes, "status_message", nil),
           [["attributes", "status_message"] | withheld]}

    graphql(attributes, withheld)
  end

  # A Logger burst's call site and template come from Logger metadata and
  # message text; its template and call-site fingerprints still tell bursts
  # apart. The overflow row carries neither.
  defp attributes(
         %{"source" => "logger", "kind" => "logger_summary", "attributes" => attributes},
         _allowlist,
         withheld
       ) do
    summary = attributes["summary"] || %{}
    present = Enum.filter(["call_site", "template"], &(summary[&1] != nil))

    {Map.put(attributes, "summary", Map.merge(summary, Map.new(present, &{&1, nil}))),
     Enum.reduce(present, withheld, &[["attributes", "summary", &1] | &2])}
  end

  defp attributes(%{"source" => "logger", "attributes" => attributes}, _allowlist, withheld) do
    Enum.reduce(@semantic_id_attributes, {attributes, withheld}, fn key, {attributes, withheld} ->
      case attributes do
        %{^key => "binary:" <> value} ->
          digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
          {Map.put(attributes, key, "binary-sha256:" <> digest), withheld}

        _other ->
          {attributes, withheld}
      end
    end)
  end

  # Every insider.event/v1 wire map has attributes; Poller events pass as-is.
  defp attributes(%{"attributes" => attributes}, _allowlist, withheld), do: {attributes, withheld}

  # A GraphQL outcome's kind and counts pass; the names it holds (the
  # operation's, error codes and paths, typenames, and payload error fields
  # and types) come from the request and the schema, and its request's
  # client (rich capture only) is the client's: all are withheld.
  @graphql_names ~w(operation_name error_codes error_paths typenames user_error_fields user_error_types client)

  defp graphql(%{"graphql" => %{} = graphql} = attributes, withheld) do
    {graphql, withheld} =
      Enum.reduce(@graphql_names, {graphql, withheld}, fn key, {graphql, withheld} ->
        case graphql[key] do
          empty when empty in [nil, []] ->
            {graphql, withheld}

          names ->
            {Map.put(graphql, key, if(is_list(names), do: [], else: nil)),
             [["attributes", "graphql", key] | withheld]}
        end
      end)

    request(Map.put(attributes, "graphql", graphql), withheld)
  end

  defp graphql(attributes, withheld), do: request(attributes, withheld)

  # A request's method, status, and whether it was traced pass; its path,
  # user agent, and address are the client's and are withheld. Its timings
  # are the `duration` measurement's, so they pass only while the host
  # allowlist names it, as a summary's durations do.
  @request_values ~w(path user_agent remote_ip)
  @request_timings ~w(total_us response_us headers_us handler_us wait_us)

  defp request(%{"request" => %{} = request} = attributes, withheld) do
    timings =
      if Map.has_key?(measurement_allowlist(), "duration"), do: [], else: @request_timings

    present = Enum.filter(@request_values ++ timings, &Map.has_key?(request, &1))

    {Map.put(attributes, "request", Map.drop(request, present)),
     Enum.reduce(present, withheld, &[["attributes", "request", &1] | &2])}
  end

  defp request(attributes, withheld), do: {attributes, withheld}

  # A summary's duration statistics, and its exemplars' durations, are
  # derived from the measurements named in its `"duration_measurements"`, so
  # they are disclosed only when every one of those names is in the host
  # allowlist, exactly as the raw measurement would be. Counts, receipts,
  # and loss evidence are not measurement values and pass. The module an
  # exemplar was emitted in is a process's initial call, withheld like
  # Telemetry metadata; the emitter context and the declared scope pass.
  @summary_durations ["duration_max_us", "duration_p50_us", "duration_p95_us"]

  defp summary(nil, _allowlist, withheld), do: {nil, withheld}

  defp summary(summary, allowlist, withheld) do
    sources = summary["duration_measurements"] || []
    {summary, withheld} = emitter_module(summary, withheld)

    if Enum.all?(sources, &Map.has_key?(allowlist, &1)) do
      {summary, withheld}
    else
      present = Enum.filter(@summary_durations, &(summary[&1] != nil))
      withheld = Enum.reduce(present, withheld, &[["attributes", "summary", &1] | &2])
      {exemplars, withheld} = exemplar_durations(summary["exemplars"], withheld)

      {summary
       |> Map.merge(Map.new(@summary_durations, &{&1, nil}))
       |> put_exemplars(exemplars), withheld}
    end
  end

  defp emitter_module(
         %{"duration_scope" => %{"emitter" => %{"module" => module} = emitter} = scope} = summary,
         withheld
       )
       when module != nil do
    {%{summary | "duration_scope" => %{scope | "emitter" => %{emitter | "module" => nil}}},
     [["attributes", "summary", "duration_scope", "emitter", "module"] | withheld]}
  end

  defp emitter_module(summary, withheld), do: {summary, withheld}

  # One drop record per withheld duration, at its index in the list.
  defp exemplar_durations(exemplars, withheld) when is_list(exemplars) do
    {exemplars, {withheld, _index}} =
      Enum.map_reduce(exemplars, {withheld, 0}, fn
        %{"duration_us" => duration} = exemplar, {withheld, index} when duration != nil ->
          path = ["attributes", "summary", "exemplars", index, "duration_us"]
          {%{exemplar | "duration_us" => nil}, {[path | withheld], index + 1}}

        exemplar, {withheld, index} ->
          {exemplar, {withheld, index + 1}}
      end)

    {exemplars, withheld}
  end

  defp exemplar_durations(exemplars, withheld), do: {exemplars, withheld}

  defp put_exemplars(summary, nil), do: summary
  defp put_exemplars(summary, exemplars), do: Map.put(summary, "exemplars", exemplars)

  defp put_summary(attributes, nil), do: attributes
  defp put_summary(attributes, summary), do: Map.put(attributes, "summary", summary)

  defp measurements(measurements, allowlist, withheld) do
    Enum.reduce(measurements, {%{}, withheld}, fn {name, value}, {kept, withheld} ->
      cond do
        not Map.has_key?(allowlist, name) ->
          {kept, [["attributes", "measurements", name] | withheld]}

        nil == value or numeric?(value) ->
          {Map.put(kept, name, value), withheld}

        true ->
          {Map.put(kept, name, nil), [["attributes", "measurements", name] | withheld]}
      end
    end)
  end

  defp numeric?(value) when is_integer(value), do: true
  defp numeric?(value) when is_binary(value), do: String.match?(value, @decimal)
  defp numeric?(_value), do: false

  # A path segment is a map key, or a list index as an integer.
  defp manifest(withheld) do
    withheld
    |> Enum.reverse()
    |> Enum.map(fn path ->
      %{
        "action" => "drop",
        "count" => 1,
        "path" => Enum.map(path, &segment/1),
        "policy_id" => @policy_id
      }
    end)
  end

  defp segment(index) when is_integer(index), do: "index:" <> Integer.to_string(index)
  defp segment(key), do: "key:" <> key

  defp measurement_atom?(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom) do
    name = Atom.to_string(atom)
    byte_size(name) <= 64 and String.match?(name, @measurement_name)
  end

  defp measurement_atom?(_value), do: false
end
