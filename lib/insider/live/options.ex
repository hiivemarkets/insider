defmodule Insider.Live.Options do
  @moduledoc false

  # Validates the plain, string-keyed option maps accepted by `Insider.Live`.
  # Telemetry names resolve only to atoms that already exist on this node, so
  # a caller can never create atoms.

  alias Insider.Collector.Otel.Tracing
  alias Insider.Collector.Calls.Tracing, as: CallsTracing
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Live.CallsOptions
  alias Insider.Live.Disclosure
  alias Insider.Live.Discovery
  alias Insider.Live.Error
  alias Insider.Live.Filters
  alias Insider.Live.Inspect
  alias Insider.Live.InspectOptions
  alias Insider.Live.Marks
  alias Insider.Live.PollerOptions
  alias Insider.Live.View
  alias Insider.Protocol.Value

  @components %{
    "calls" => :calls,
    "logger" => :logger,
    "otel" => :otel,
    "poller" => :poller,
    "telemetry" => :telemetry
  }
  @start_keys [
    "components",
    "disclosure",
    "lease_ms",
    "max_events",
    "retain_traces",
    "telemetry_events",
    "telemetry_measurements"
  ]
  @read_keys ["limit", "max_bytes", "reader", "renew", "scan_limit", "upto", "view"]
  @welcome_keys ["full"]
  @discover_keys ["prefix"]
  @subscribe_keys ["cursor", "max_events", "reader", "view"]
  @stop_keys ["force", "reader"]
  @report_keys ["category", "message"]
  # Every read names its reader and may pass a view (`reading/1`).
  @reading_keys ["reader", "view"]
  @digest_keys ["human", "reader", "show_baseline", "since", "view"]
  @baseline_keys ["clear", "human", "reader", "show", "since", "view"]
  @baseline_since "latest-5m"
  @trends_keys ["human", "kinds", "reader", "since", "view", "windows"]
  @trends_windows %{"default" => 60, "max" => 500, "min" => 1}
  @trends_kinds_max 64
  # A digest reads its window in a few full-size reads within one budget,
  # kept below the observer's default 5,000 ms remote-call timeout.
  @digest_budget_ms 3_000
  # A digest without "since" covers the last minute (`"latest-60s"`); a
  # time window is 1 s to 24 h.
  @digest_since "latest-60s"
  @recent_ms %{min: 1_000, max: 86_400_000}
  @units %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}
  # `"mark"` reads since the newest pairing mark, `"mark:LABEL"` since the
  # newest with that label (`Insider.Live.Marks`).
  @type since ::
          {:cursor, non_neg_integer()}
          | {:last, pos_integer()}
          | {:recent, pos_integer()}
          | {:mark, String.t() | nil}
  @mark_keys ["label", "reader"]
  @marks_keys ["human"]
  # A reader's name: who is reading, in `status`, and who stops or amends.
  @reader ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,31}\z/
  @trace_keys [
    "collapse",
    "hide",
    "human",
    "limit",
    "max_bytes",
    "reader",
    "retain",
    "values",
    "values_paths",
    "view"
  ]
  @retain_traces %{"default" => 0, "min" => 0, "max" => 64}
  @values_paths_max 8
  @values_path ~r/\A[A-Za-z0-9_$*.\[\]-]{1,128}\z/
  @fold_rules_max 8
  @fold_rule ~r/\A[^\s\x00-\x1f\x7f]{1,64}\z/u
  @timeline_keys ["human", "limit", "max_bytes", "pid", "reader", "request_id", "since", "view"]
  @correlated_limit %{"default" => 200, "max" => 1_000, "min" => 1}
  @correlated_max_bytes %{"default" => 262_144, "max" => 1_048_576, "min" => 1_024}
  @correlated_budget_ms 4_000
  @trace_id ~r/\A[0-9a-f]{32}\z/
  @pid_text ~r/\A<\d+\.\d+\.\d+>\z/
  @report_categories ["bug", "confusing_output", "doc_mismatch", "missing_capability"]
  @report_message_max_bytes 2_048
  @lease_ms %{"default" => 120_000, "max" => 900_000, "min" => 1_000}
  @max_events %{"default" => 4_096, "max" => 4_096, "min" => 16}
  @limit %{"default" => 50, "max" => 500, "min" => 1}
  @max_bytes %{"default" => 65_536, "max" => 1_048_576, "min" => 1_024}
  @scan_limit %{"default" => 1_000, "max" => 1_000, "min" => 1}
  @subscription_events %{"default" => "unlimited", "max" => 1_000_000, "min" => 1}
  @max_telemetry_events 64
  @max_event_segments 8
  @max_measurements 16
  @segment ~r/\A[a-z][a-z0-9_]*\z/
  @control ~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u

  @type start :: %{
          components: [:calls | :logger | :otel | :poller | :telemetry],
          disclosure: Disclosure.profile(),
          lease_ms: pos_integer(),
          max_events: pos_integer(),
          retain_traces: non_neg_integer(),
          telemetry_events: [[String.t()]],
          telemetry_skipped_defaults: [[String.t()]],
          telemetry_measurements: [String.t()],
          telemetry_policy: TelemetryPolicy.t() | nil,
          filters: Filters.parsed(),
          poller: PollerOptions.parsed() | nil,
          calls: CallsOptions.parsed() | nil
        }

  @spec bounds() :: map()
  def bounds do
    %{
      "lease_ms" => @lease_ms,
      "recorder_events" => @max_events,
      "events_per_read" => @limit,
      "bytes_per_read" => @max_bytes,
      "scanned_per_read" => @scan_limit,
      "digest_budget_ms" => @digest_budget_ms,
      "telemetry_events_max" => @max_telemetry_events,
      "telemetry_event_segments_max" => @max_event_segments,
      "telemetry_measurements_max" => @max_measurements,
      "discovery" => Discovery.bounds(),
      "inspect" => Inspect.bounds()
    }
  end

  @spec components() :: [String.t()]
  def components, do: @components |> Map.keys() |> Enum.sort()

  # The filter options (`Insider.Live.Filters`), the poller options
  # (`Insider.Live.PollerOptions`), and the call-trace options
  # (`Insider.Live.CallsOptions`) are start options too.
  @spec start_keys() :: [String.t()]
  def start_keys,
    do:
      Enum.sort(
        @start_keys ++
          Filters.start_keys() ++ PollerOptions.start_keys() ++ CallsOptions.start_keys()
      )

  @spec read_keys() :: [String.t()]
  def read_keys, do: @read_keys

  @spec report_keys() :: [String.t()]
  def report_keys, do: @report_keys

  @spec stop_keys() :: [String.t()]
  def stop_keys, do: @stop_keys

  # `amend/2` takes every start option and the amending reader's name.
  @spec amend_keys() :: [String.t()]
  def amend_keys, do: Enum.sort(["reader" | start_keys()])

  @spec welcome_keys() :: [String.t()]
  def welcome_keys, do: @welcome_keys

  @spec discover_keys() :: [String.t()]
  def discover_keys, do: @discover_keys

  @spec digest_keys() :: [String.t()]
  def digest_keys, do: @digest_keys

  @doc "How long one digest may read before it returns what it has."
  @spec digest_budget_ms() :: pos_integer()
  def digest_budget_ms, do: @digest_budget_ms

  @spec mark_keys() :: [String.t()]
  def mark_keys, do: @mark_keys

  @spec marks_keys() :: [String.t()]
  def marks_keys, do: @marks_keys

  @spec trace_keys() :: [String.t()]
  def trace_keys, do: @trace_keys

  @spec timeline_keys() :: [String.t()]
  def timeline_keys, do: @timeline_keys

  @doc "How long `trace` and `timeline` read the session before they answer."
  @spec correlated_budget_ms() :: pos_integer()
  def correlated_budget_ms, do: @correlated_budget_ms

  @doc "The largest `limit` and `max_bytes` of `trace` and `timeline`, for their text."
  @spec correlated_bounds() :: %{limit: pos_integer(), max_bytes: pos_integer()}
  def correlated_bounds,
    do: %{limit: @correlated_limit["max"], max_bytes: @correlated_max_bytes["max"]}

  @spec trends_keys() :: [String.t()]
  def trends_keys, do: @trends_keys

  # Every option `start/1`, `read/1`, and `report/1` accept, with its default
  # and bounds, for the welcome document. An absent option takes its
  # `"default"`; a `nil` default marks one that is required (the report
  # fields). The filter options come from `Insider.Live.Filters` and the view
  # from `Insider.Live.View`. Defaults that depend on the node (the quiet
  # default events) are described, not listed, so the contract hash does not
  # change from node to node; the node's own list is in the welcome runtime.
  @spec describe() :: map()
  def describe do
    %{
      "start" =>
        Map.merge(
          %{
            "components" => %{
              "type" => "list of strings",
              "default" => ["logger", "telemetry"],
              "default_without_quiet_events" => ["logger"],
              "allowed" => components(),
              "max" => map_size(@components)
            },
            "disclosure" => %{
              "type" => "string",
              "default" => "host_profile",
              "allowed" => Disclosure.profiles()
            },
            "lease_ms" => Map.put(@lease_ms, "type", "integer"),
            "max_events" => Map.put(@max_events, "type", "integer"),
            "retain_traces" =>
              Map.merge(@retain_traces, %{
                "type" => "integer",
                "note" =>
                  "keeps the events of the N most recently active traces apart from the Recorder, so they " <>
                    "survive its eviction (Insider.Live.Retention bounds); trace reports them as retention"
              }),
            "telemetry_events" => %{
              "type" => "list of segment lists",
              "default" => "quiet_defaults",
              "skipped_defaults" =>
                "a default whose application or atoms this node lacks is skipped, and the start result lists it " <>
                  "under telemetry_skipped_defaults (reason not_on_target); when none is left the session runs " <>
                  "without the telemetry component and the result carries telemetry_hint, and telemetry alone " <>
                  "is refused; a name given here must already be an atom",
              "requires_component" => "telemetry",
              "max" => @max_telemetry_events,
              "segments_max" => @max_event_segments,
              "segment_pattern" => Regex.source(@segment),
              "prefix" =>
                "a list whose last segment is \"*\", such as [\"shop\", \"*\"], stands for every event name " <>
                  "discover finds below that prefix when the session starts; max counts the names after expansion"
            },
            "telemetry_measurements" => %{
              "type" => "list of strings",
              "default" => [],
              "requires_component" => "telemetry",
              "allowed" => Disclosure.measurement_allowlist() |> Map.keys() |> Enum.sort(),
              "max" => @max_measurements
            }
          },
          Filters.describe_options()
          |> Map.merge(PollerOptions.describe())
          |> Map.merge(CallsOptions.describe())
        ),
      "report" => %{
        "category" => %{
          "type" => "string",
          "default" => nil,
          "allowed" => @report_categories
        },
        "message" => %{
          "type" => "string",
          "default" => nil,
          "max_bytes" => @report_message_max_bytes,
          "note" => "trimmed UTF-8; no control characters except newline and tab"
        }
      },
      "read" => %{
        "limit" => Map.merge(@limit, %{"type" => "integer", "note" => "events returned"}),
        "max_bytes" =>
          Map.merge(@max_bytes, %{
            "type" => "integer",
            "note" =>
              "canonical JSON bytes of the events returned; the first event is always returned"
          }),
        "scan_limit" =>
          Map.merge(@scan_limit, %{
            "type" => "integer",
            "note" =>
              "retained events examined, shown or hidden by the view; truncated_by says which bound ended a read"
          }),
        "upto" => %{
          "type" => "integer or null",
          "default" => nil,
          "note" =>
            "the newest receipt the read may return, from the read's starting cursor (after \"latest\" resolves) to the newest receipt, " <>
              "else invalid_options field upto; losses are counted only up to it, and the read is complete (truncated false, " <>
              "truncated_by null) when next_cursor reaches it (a digest reads its window this way)"
        },
        "renew" => %{
          "type" => "boolean",
          "default" => true,
          "note" =>
            "false reads without renewing the lease, for a viewer such as chart --serve that must never keep a session alive"
        },
        "reader" =>
          reader_option("names this reader in status, with its cursor and when it last read"),
        "view" => View.describe()
      },
      "subscribe" => %{
        "cursor" => %{
          "type" => "integer or \"latest\"",
          "default" => 0,
          "note" => "where the subscription starts; \"latest\" is the newest receipt"
        },
        "max_events" =>
          Map.merge(@subscription_events, %{
            "type" => "integer",
            "note" => "events pushed to this subscriber in total; then it is sent nothing more"
          }),
        "reader" => reader_option("names this subscriber's reader in status, marked subscribed"),
        "view" => View.describe()
      },
      "discover" => %{
        "prefix" => %{
          "type" => "list of segment strings",
          "default" => nil,
          "segments_max" => @max_event_segments - 1,
          "segment_pattern" => Regex.source(@segment),
          "note" =>
            "lists only the event names that start with these segments; without it, every discovered name"
        }
      },
      "digest" =>
        %{
          "since" => %{
            "type" => "integer, \"latest-N\", \"latest-DURATION\", \"mark\", or \"mark:LABEL\"",
            "default" => @digest_since,
            "last_max" => @max_events["max"],
            "duration_min_ms" => @recent_ms.min,
            "duration_max_ms" => @recent_ms.max,
            "note" =>
              "the window: \"latest-DURATION\" (a whole number of ms, s, m or h, 1 s to 24 h, such as latest-60s, the default) " <>
                "starts at the first event the Recorder admitted that recently (its admission clock, not the events' wall times); " <>
                "an integer cursor starts after that receipt (0 is the session start); " <>
                "\"latest-N\" is the newest N receipts (N 1..#{@max_events["max"]}); " <>
                "\"mark\" starts at the newest pairing mark (see mark), \"mark:LABEL\" at the newest with that label. " <>
                "The window ends at the newest receipt when the digest starts."
          },
          "human" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "true adds \"text\", a short plain-text summary to paste for the developer"
          },
          "show_baseline" => %{
            "type" => "boolean",
            "default" => false,
            "note" =>
              "true lists the known-normal anomalies the session's baseline hid after the new ones in \"text\" " <>
                "(\"anomalies_known\" always has them)"
          }
        }
        |> Map.merge(reading_describe()),
      "baseline" =>
        %{
          "since" => %{
            "type" => "integer, \"latest-N\", \"latest-DURATION\", \"mark\", or \"mark:LABEL\"",
            "default" => @baseline_since,
            "note" => "the window whose anomalies are marked normal, as digest's since"
          },
          "show" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "true returns the baseline without changing it"
          },
          "clear" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "true removes the baseline; not with show"
          },
          "human" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "true adds \"text\": what was marked, shown, or cleared"
          }
        }
        |> Map.merge(reading_describe()),
      "trends" =>
        %{
          "since" => %{
            "type" => "integer, \"latest-N\", \"latest-DURATION\", \"mark\", or \"mark:LABEL\"",
            "default" => 0,
            "last_max" => @max_events["max"],
            "note" =>
              "the window, as for digest (including latest-DURATION and mark); the default is the session start"
          },
          "kinds" => %{
            "type" => "list of strings",
            "default" => [],
            "max" => @trends_kinds_max,
            "note" =>
              "the summarised Telemetry kinds to show, logger_summary for the Logger bursts, and vm_sample, port_top, " <>
                "process_top or process_watch for the Poller series; [] shows all"
          },
          "windows" =>
            Map.merge(@trends_windows, %{
              "type" => "integer",
              "note" =>
                "the most recent summary windows listed per series; change still compares the first and last read"
            }),
          "human" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "true adds \"text\", one line per series to paste for the developer"
          }
        }
        |> Map.merge(reading_describe()),
      "stop" => %{
        "reader" =>
          reader_option(
            "who stops: that reader's own recent reads do not count as another reader's"
          ),
        "force" => %{
          "type" => "boolean",
          "default" => false,
          "note" =>
            "true stops even while another reader was active within reader_active_ms or is subscribed"
        }
      },
      "amend" => %{
        "reader" =>
          reader_option("who amends, named in the session_amended event every reader sees"),
        "start_options" => %{
          "type" => "the start options",
          "default" => "the session's current values",
          "note" =>
            "every start option; each one given replaces the session's value (a list replaces the whole list), null returns it to its default, " <>
              "and the rest keep theirs, except that the poller options return to their defaults when the components leave the poller out, " <>
              "and telemetry_events and telemetry_measurements when they leave telemetry out"
        }
      },
      "trace" =>
        correlated_describe(
          Map.merge(reading_describe(), %{
            "collapse" =>
              fold_describe(
                "folds each run of sibling items in a category into one counted text line"
              ),
            "hide" =>
              fold_describe(
                "drops matching spans and events from items and text; what was under a hidden span moves up to its nearest shown ancestor"
              ),
            "retain" => %{
              "type" => "boolean",
              "default" => false,
              "note" =>
                "pins this trace: its events the Recorder still holds and every later one are kept apart from the " <>
                  "Recorder and survive its eviction; result retention reports what was kept, restored, and lost"
            },
            "values" => %{
              "type" => "boolean",
              "default" => false,
              "note" =>
                "rich profile only (strict refuses with disclosure_denied): adds values, the response data of the " <>
                  "trace's GraphQL operations as path = value lines, credential-masked and bounded"
            },
            "values_paths" => %{
              "type" => "list of strings",
              "default" => [],
              "max_items" => @values_paths_max,
              "max_bytes" => 128,
              "note" =>
                "keeps only the value paths matching one of these patterns (* matches any text, as in " <>
                  "buyOrderV2.buyOrder.total*); implies values"
            }
          })
        ),
      "timeline" =>
        correlated_describe(
          Map.merge(reading_describe(), %{
            "pid" => %{
              "type" => "string",
              "default" => nil,
              "pattern" => Regex.source(@pid_text),
              "note" =>
                "a process as events name it in subject.value; exactly one of pid and request_id"
            },
            "request_id" => %{
              "type" => "string",
              "default" => nil,
              "max_bytes" => 128,
              "note" =>
                "Plug's request id (Logger metadata request_id or an x-request-id header); exactly one of pid and request_id"
            },
            "since" => %{
              "type" => "integer, \"mark\", or \"mark:LABEL\"",
              "default" => 0,
              "note" =>
                "reads only receipts after this cursor, or after the newest pairing mark (\"mark\") or the newest with that label; " <>
                  "0 reads the whole session"
            }
          })
        ),
      "mark" => %{
        "label" => %{
          "type" => "string",
          "default" => nil,
          "max_bytes" => Marks.bounds()["mark_label_max_bytes"],
          "input_max_bytes" => Marks.bounds()["mark_label_input_max_bytes"],
          "note" =>
            "required: what is about to happen, such as about to click Confirm; one line (control characters become spaces), " <>
              "credential-masked in every profile, then cut to max_bytes; more than input_max_bytes is refused (invalid_options) before any work, " <>
              "and a lookup label (since or cursor mark:LABEL) follows the same rules"
        },
        "reader" => reader_option("who made the mark, listed with it")
      },
      "marks" => %{
        "human" => %{
          "type" => "boolean",
          "default" => false,
          "note" => "adds text: one line per mark with its time, age, label, reader and receipt"
        }
      },
      "mutations" =>
        Map.merge(reading_describe(), %{
          "id" => %{
            "type" => "string",
            "default" => nil,
            "max_bytes" => 64,
            "note" =>
              "a record id among a mutation's arguments (fields named id or ending in Id or _id; rich only); " <>
                "without it, every kept record"
          },
          "human" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "adds text: one line per kept record"
          }
        }),
      "changes" =>
        Map.merge(reading_describe(), %{
          "key" => %{
            "type" => "string",
            "default" => nil,
            "max_bytes" => 128,
            "note" => "one watched key (watch_writes); without it, every key's writes"
          },
          "human" => %{
            "type" => "boolean",
            "default" => false,
            "note" => "adds text: one line per write with its value (rich) and its writer"
          }
        }),
      "welcome" => %{
        "full" => %{
          "type" => "boolean",
          "default" => false,
          "note" => "false returns the agent quick start; true returns the whole reference"
        }
      }
    }
    |> Map.merge(InspectOptions.describe())
  end

  defp reader_option(note) do
    %{
      "type" => "string",
      "default" => nil,
      "pattern" => Regex.source(@reader),
      "note" => note <> "; optional"
    }
  end

  defp reading_describe do
    %{
      "reader" =>
        reader_option(
          "names this reader in status; without view, the reader's own view applies, else the view given becomes it"
        ),
      "view" => View.describe()
    }
  end

  @doc """
  A read's `"reader"` and `"view"`: the reader's name (`nil` when unnamed)
  and the view, `:keep` when none was given (a named reader's own view
  then applies) or the validated view spec given (`nil` clears it).
  """
  @spec reading(map()) ::
          {:ok, %{reader: String.t() | nil, view: :keep | map() | nil}} | {:error, map()}
  def reading(options) when is_map(options) and not is_struct(options) do
    with {:ok, reader} <- reader(options) do
      case Map.fetch(options, "view") do
        :error ->
          {:ok, %{reader: reader, view: :keep}}

        {:ok, spec} ->
          with {:ok, view} <- View.parse(spec),
               do: {:ok, %{reader: reader, view: view && view.spec}}
      end
    end
  end

  def reading(_options), do: invalid("options")

  @doc "The keys every read operation takes."
  @spec reading_keys() :: [String.t()]
  def reading_keys, do: @reading_keys

  @spec subscribe_keys() :: [String.t()]
  def subscribe_keys, do: @subscribe_keys

  @spec welcome(term()) :: {:ok, boolean()} | {:error, map()}
  def welcome(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @welcome_keys) do
      case Map.get(options, "full", false) do
        full when is_boolean(full) -> {:ok, full}
        _full -> invalid("full")
      end
    end
  end

  def welcome(_options), do: invalid("options")

  # The discovery prefix: `nil` lists every discovered name.
  @spec discover(term()) :: {:ok, [String.t()] | nil} | {:error, map()}
  def discover(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @discover_keys) do
      case Map.get(options, "prefix") do
        nil -> {:ok, nil}
        prefix -> if Discovery.valid_prefix?(prefix), do: {:ok, prefix}, else: invalid("prefix")
      end
    end
  end

  def discover(_options), do: invalid("options")

  # A digest's window start: an integer cursor, `"latest-N"`, the newest N
  # receipts, or `"latest-DURATION"`, the events that recent; the caller
  # resolves the last two. The default is the last minute, so a long
  # session's old history neither hides nor delays fresh activity.
  @spec digest(term(), String.t() | non_neg_integer()) ::
          {:ok,
           %{
             since: since(),
             human: boolean(),
             show_baseline: boolean(),
             reader: String.t() | nil,
             view: :keep | map() | nil
           }}
          | {:error, map()}
  def digest(options, default \\ @digest_since)

  def digest(options, default) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @digest_keys),
         {:ok, since} <- since(Map.get(options, "since", default)),
         {:ok, reading} <- reading(options) do
      case {Map.get(options, "human", false), Map.get(options, "show_baseline", false)} do
        {human, show} when is_boolean(human) and is_boolean(show) ->
          {:ok, Map.merge(reading, %{since: since, human: human, show_baseline: show})}

        {human, _show} when is_boolean(human) ->
          invalid("show_baseline")

        _human ->
          invalid("human")
      end
    end
  end

  def digest(_options, _default), do: invalid("options")

  @doc """
  The options of `baseline`: mark the anomalies of the window `"since"`
  (default #{@baseline_since}) normal, or `"show"` or `"clear"` the
  baseline (at most one of them).
  """
  @spec baseline(term()) :: {:ok, map()} | {:error, map()}
  def baseline(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @baseline_keys),
         {:ok, digest} <-
           digest(Map.take(options, ["human", "reader", "since", "view"]), @baseline_since) do
      case {Map.get(options, "clear", false), Map.get(options, "show", false)} do
        {true, true} -> invalid("clear")
        {true, false} -> {:ok, Map.put(digest, :action, :clear)}
        {false, true} -> {:ok, Map.put(digest, :action, :show)}
        {false, false} -> {:ok, Map.put(digest, :action, :set)}
        {clear, _show} when not is_boolean(clear) -> invalid("clear")
        _show -> invalid("show")
      end
    end
  end

  def baseline(_options), do: invalid("options")

  # A trends window is a digest window; `"kinds"` narrows the series shown.
  @spec trends(term()) ::
          {:ok,
           %{
             since: since(),
             human: boolean(),
             show_baseline: boolean(),
             kinds: [String.t()],
             windows: pos_integer(),
             reader: String.t() | nil,
             view: :keep | map() | nil
           }}
          | {:error, map()}
  def trends(options) when is_map(options) and not is_struct(options) do
    %{"min" => min, "max" => max, "default" => default} = @trends_windows

    with :ok <- known_keys(options, @trends_keys),
         {:ok, digest} <- digest(Map.take(options, @digest_keys), 0),
         {:ok, kinds} <- trend_kinds(Map.get(options, "kinds", [])) do
      case Map.get(options, "windows", default) do
        windows when is_integer(windows) and windows >= min and windows <= max ->
          {:ok, Map.merge(digest, %{kinds: kinds, windows: windows})}

        _windows ->
          invalid("windows")
      end
    end
  end

  def trends(_options), do: invalid("options")

  defp trend_kinds(kinds) do
    if Value.bounded_list?(kinds, @trends_kinds_max) and
         Enum.all?(kinds, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1))),
       do: {:ok, Enum.uniq(kinds)},
       else: invalid("kinds")
  end

  defp since(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, {:cursor, cursor}}

  defp since("latest-" <> count) do
    max = @max_events["max"]

    case Regex.run(~r/\A([1-9][0-9]{0,8})(ms|s|m|h)?\z/, count) do
      [_match, last] -> receipts(String.to_integer(last), max)
      [_match, amount, unit] -> recent(String.to_integer(amount) * Map.fetch!(@units, unit))
      nil -> invalid("since")
    end
  end

  defp since("mark"), do: {:ok, {:mark, nil}}
  # A label is looked up as a mark keeps it (`Insider.Live.Marks.label/1`):
  # one bounded normalisation here, before the owner compares it.
  defp since("mark:" <> label) do
    case Marks.label(label) do
      {:ok, label, _truncated} -> {:ok, {:mark, label}}
      :error -> invalid("since")
    end
  end

  defp since(_since), do: invalid("since")

  @doc """
  A read cursor given as a pairing mark: `"mark"` (the newest mark) or
  `"mark:LABEL"` (the newest with that label, normalised as a mark keeps
  it) is `{:mark, label}`, a malformed or oversized label is `:invalid`, and
  any other cursor is `:cursor`.
  """
  @spec mark_cursor(term()) :: {:mark, String.t() | nil} | :invalid | :cursor
  def mark_cursor("mark" <> _rest = cursor) do
    case since(cursor) do
      {:ok, {:mark, label}} -> {:mark, label}
      {:error, _invalid} -> :invalid
    end
  end

  def mark_cursor(_cursor), do: :cursor

  @doc """
  A pairing mark: its `"label"` (required: one line, at most
  `Insider.Live.Marks` bytes, credential-masked) and the `"reader"` that
  made it.
  """
  @spec mark(term()) ::
          {:ok, %{label: String.t(), truncated: boolean(), reader: String.t() | nil}}
          | {:error, map()}
  def mark(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @mark_keys),
         {:ok, reader} <- reader(options) do
      case Marks.label(Map.get(options, "label")) do
        {:ok, label, truncated} -> {:ok, %{label: label, truncated: truncated, reader: reader}}
        :error -> invalid("label")
      end
    end
  end

  def mark(_options), do: invalid("options")

  @spec marks(term()) :: {:ok, %{human: boolean()}} | {:error, map()}
  def marks(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @marks_keys) do
      case Map.get(options, "human", false) do
        human when is_boolean(human) -> {:ok, %{human: human}}
        _human -> invalid("human")
      end
    end
  end

  def marks(_options), do: invalid("options")

  defp receipts(last, max) when last <= max, do: {:ok, {:last, last}}
  defp receipts(_last, _max), do: invalid("since")

  defp recent(ms) when ms >= @recent_ms.min and ms <= @recent_ms.max, do: {:ok, {:recent, ms}}
  defp recent(_ms), do: invalid("since")

  @spec start(term()) :: {:ok, start()} | {:error, map()}
  def start(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, start_keys()),
         {:ok, components} <-
           components(Map.get_lazy(options, "components", &Filters.default_components/0)),
         {:ok, lease_ms} <- bounded_integer(options, "lease_ms", @lease_ms),
         {:ok, max_events} <- bounded_integer(options, "max_events", @max_events),
         {:ok, retain_traces} <- bounded_integer(options, "retain_traces", @retain_traces),
         {:ok, events, skipped_defaults} <- telemetry_events(options, components),
         {:ok, measurements} <- telemetry_measurements(options, components),
         {:ok, components, measurements} <-
           without_idle_telemetry(components, measurements, events, skipped_defaults),
         {:ok, policy} <- telemetry_policy(events, measurements),
         atoms = Enum.map(components, &Map.fetch!(@components, &1)),
         :ok <- available(atoms),
         {:ok, filters} <- Filters.start(options, atoms, events),
         {:ok, poller} <- PollerOptions.start(options, components),
         {:ok, calls} <- CallsOptions.start(options, components),
         {:ok, requested} <- disclosure(Map.get(options, "disclosure")),
         {:ok, profile} <- Disclosure.session_profile(requested) do
      {:ok,
       %{
         components: atoms,
         disclosure: profile,
         lease_ms: lease_ms,
         max_events: max_events,
         retain_traces: retain_traces,
         telemetry_events: Enum.map(events, &elem(&1, 0)),
         telemetry_skipped_defaults: skipped_defaults,
         telemetry_measurements: Enum.map(measurements, &elem(&1, 1)),
         telemetry_policy: policy,
         filters: filters,
         poller: poller,
         calls: calls
       }}
    end
  end

  def start(_options), do: invalid("options")

  # The otel and calls components each need an isolated trace session (OTP
  # 28 and later), otel the SDK too; an unavailable one is refused before
  # anything starts.
  defp available(components) do
    with :ok <- otel_available(components), do: calls_available(components)
  end

  defp calls_available(components) do
    with true <- :calls in components,
         {:error, reason} <- CallsTracing.preflight() do
      {:error,
       Error.new("component_unavailable", %{
         "component" => "calls",
         "reason" => Atom.to_string(reason)
       })}
    else
      _available -> :ok
    end
  end

  # The caller may name a disclosure profile no richer than the host's;
  # `Disclosure.session_profile/1` decides.
  defp disclosure(nil), do: {:ok, nil}
  defp disclosure("rich"), do: {:ok, :rich}
  defp disclosure("strict"), do: {:ok, :strict}
  defp disclosure(_profile), do: invalid("disclosure")

  # The otel component observes the OpenTelemetry SDK's span end in an
  # isolated trace session, so it needs the SDK and OTP 28 or later.
  defp otel_available(components) do
    with true <- :otel in components,
         {:error, reason} <- Tracing.preflight() do
      reason =
        if reason == :sdk_absent, do: "opentelemetry_sdk_absent", else: Atom.to_string(reason)

      {:error, Error.new("component_unavailable", %{"component" => "otel", "reason" => reason})}
    else
      _available -> :ok
    end
  end

  # `"view"` and `"reader"` are popped by the owner; the rest bounds the read.
  @spec read(term()) :: {:ok, keyword()} | {:error, map()}
  def read(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @read_keys),
         {:ok, limit} <- bounded_integer(options, "limit", @limit),
         {:ok, max_bytes} <- bounded_integer(options, "max_bytes", @max_bytes),
         {:ok, scan_limit} <- bounded_integer(options, "scan_limit", @scan_limit),
         {:ok, upto} <- upto(Map.get(options, "upto")),
         {:ok, renew} <- renew(Map.get(options, "renew", true)),
         {:ok, reader} <- reader(options),
         {:ok, view} <- View.parse(Map.get(options, "view")) do
      {:ok,
       [
         limit: limit,
         max_bytes: max_bytes,
         scan_limit: scan_limit,
         upto: upto,
         view: view,
         reader: reader,
         renew: renew
       ]}
    end
  end

  def read(_options), do: invalid("options")

  defp renew(renew) when is_boolean(renew), do: {:ok, renew}
  defp renew(_renew), do: invalid("renew")

  defp upto(nil), do: {:ok, nil}
  defp upto(upto) when is_integer(upto) and upto >= 0, do: {:ok, upto}
  defp upto(_upto), do: invalid("upto")

  @doc """
  The options of `stop/2`: the stopping `reader` (`nil` when unnamed) and
  `force`.
  """
  @spec stop(term()) :: {:ok, %{reader: String.t() | nil, force: boolean()}} | {:error, map()}
  def stop(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @stop_keys),
         {:ok, reader} <- reader(options) do
      case Map.get(options, "force", false) do
        force when is_boolean(force) -> {:ok, %{reader: reader, force: force}}
        _force -> invalid("force")
      end
    end
  end

  def stop(_options), do: invalid("options")

  @doc """
  The options of `amend/2`: the amending `reader` and the start options to
  replace, at least one. The owner merges them over the session's own and
  validates the result with `start/1`.
  """
  @spec amend(term()) :: {:ok, String.t() | nil, map()} | {:error, map()}
  def amend(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, amend_keys()),
         {:ok, reader} <- reader(options) do
      case Map.delete(options, "reader") do
        changes when map_size(changes) == 0 -> invalid("options")
        changes -> {:ok, reader, changes}
      end
    end
  end

  def amend(_options), do: invalid("options")

  defp reader(options) do
    case Map.get(options, "reader") do
      nil ->
        {:ok, nil}

      name when is_binary(name) ->
        if Regex.match?(@reader, name), do: {:ok, name}, else: invalid("reader")

      _name ->
        invalid("reader")
    end
  end

  @doc """
  A read cursor: an integer of at least 0, or `"latest"` for the newest
  receipt (`:latest`).
  """
  @spec cursor(term()) :: {:ok, non_neg_integer() | :latest} | :error
  def cursor("latest"), do: {:ok, :latest}
  def cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  def cursor(_cursor), do: :error

  # An agent report: one category from the closed list and a bounded,
  # printable message. Both are required; context is added by the caller.
  @spec report(term()) :: {:ok, %{category: String.t(), message: String.t()}} | {:error, map()}
  def report(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @report_keys),
         {:ok, category} <- report_category(Map.get(options, "category")),
         {:ok, message} <- report_message(Map.get(options, "message")) do
      {:ok, %{category: category, message: message}}
    end
  end

  def report(_options), do: invalid("options")

  @spec report_categories() :: [String.t()]
  def report_categories, do: @report_categories

  # `trace` and `timeline` share their bounds; the trace id is the
  # operation's argument, a W3C trace id.
  @spec trace(term(), term()) ::
          {:ok,
           %{
             trace_id: String.t(),
             limit: pos_integer(),
             max_bytes: pos_integer(),
             human: boolean(),
             collapse: [String.t()],
             hide: [String.t()],
             reader: String.t() | nil,
             view: :keep | map() | nil,
             retain: boolean(),
             values: boolean(),
             values_paths: [String.t()]
           }}
          | {:error, map()}
  def trace(trace_id, options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @trace_keys),
         {:ok, trace_id} <- trace_id(trace_id),
         {:ok, bounds} <- correlated(options),
         {:ok, collapse} <- fold_rules(options, "collapse"),
         {:ok, hide} <- fold_rules(options, "hide"),
         {:ok, reading} <- reading(options),
         {:ok, retain} <- flag(options, "retain"),
         {:ok, values} <- values(options) do
      {:ok,
       bounds
       |> Map.merge(reading)
       |> Map.merge(values)
       |> Map.merge(%{trace_id: trace_id, collapse: collapse, hide: hide, retain: retain})}
    end
  end

  def trace(_trace_id, _options), do: invalid("options")

  defp flag(options, key) do
    case Map.get(options, key, false) do
      value when is_boolean(value) -> {:ok, value}
      _value -> invalid(key)
    end
  end

  # `values_paths` filters the values shown and implies `values`.
  defp values(options) do
    with {:ok, values} <- flag(options, "values") do
      case Map.get(options, "values_paths", []) do
        paths when is_list(paths) and length(paths) <= @values_paths_max ->
          if Enum.all?(paths, &(is_binary(&1) and String.match?(&1, @values_path))),
            do: {:ok, %{values: values or paths != [], values_paths: Enum.uniq(paths)}},
            else: invalid("values_paths")

        _paths ->
          invalid("values_paths")
      end
    end
  end

  @spec timeline(term()) :: {:ok, map()} | {:error, map()}
  def timeline(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @timeline_keys),
         {:ok, subject} <- timeline_subject(options),
         {:ok, bounds} <- correlated(options),
         {:ok, since} <- timeline_since(Map.get(options, "since")),
         {:ok, reading} <- reading(options) do
      {:ok, bounds |> Map.merge(subject) |> Map.merge(reading) |> Map.put(:since, since)}
    end
  end

  def timeline(_options), do: invalid("options")

  # A timeline reads the whole session, or what came after a cursor or a
  # pairing mark.
  defp timeline_since(nil), do: {:ok, {:cursor, 0}}

  defp timeline_since(since) do
    case since(since) do
      {:ok, {kind, _value} = since} when kind in [:cursor, :mark] -> {:ok, since}
      _other -> invalid("since")
    end
  end

  @changes_keys ["human", "key", "reader", "view"]

  @doc "The options of `changes`: one key (at most 128 bytes), or every key."
  @spec changes(term()) :: {:ok, map()} | {:error, map()}
  def changes(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @changes_keys),
         {:ok, reading} <- reading(options) do
      key = Map.get(options, "key")
      human = Map.get(options, "human", false)

      cond do
        not (is_nil(key) or (is_binary(key) and byte_size(key) in 1..128 and String.valid?(key))) ->
          invalid("key")

        not is_boolean(human) ->
          invalid("human")

        true ->
          {:ok, Map.merge(reading, %{key: key, human: human})}
      end
    end
  end

  def changes(_options), do: invalid("options")

  @spec changes_keys() :: [String.t()]
  def changes_keys, do: @changes_keys

  @mutations_keys ["human", "id", "reader", "view"]

  @doc "The options of `mutations`: one record id among the arguments (at most 64 bytes), or every record."
  @spec mutations(term()) :: {:ok, map()} | {:error, map()}
  def mutations(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @mutations_keys),
         {:ok, reading} <- reading(options) do
      id = Map.get(options, "id")
      human = Map.get(options, "human", false)

      cond do
        not (is_nil(id) or (is_binary(id) and byte_size(id) in 1..64 and String.valid?(id))) ->
          invalid("id")

        not is_boolean(human) ->
          invalid("human")

        true ->
          {:ok, Map.merge(reading, %{id: id, human: human})}
      end
    end
  end

  def mutations(_options), do: invalid("options")

  # `collapse` and `hide`: up to eight categories (`sql`, `auth`) or span
  # name and event kind prefixes.
  defp fold_rules(options, key) do
    case Map.get(options, key, []) do
      rules when is_list(rules) and length(rules) <= @fold_rules_max ->
        if Enum.all?(rules, &(is_binary(&1) and String.match?(&1, @fold_rule))),
          do: {:ok, Enum.uniq(rules)},
          else: invalid(key)

      _rules ->
        invalid(key)
    end
  end

  defp trace_id(trace_id) when is_binary(trace_id) do
    if String.match?(trace_id, @trace_id) and String.trim(trace_id, "0") != "",
      do: {:ok, trace_id},
      else: invalid("trace_id")
  end

  defp trace_id(_trace_id), do: invalid("trace_id")

  defp timeline_subject(%{"pid" => _pid, "request_id" => _request_id}), do: invalid("pid")

  defp timeline_subject(%{"pid" => pid}) do
    if is_binary(pid) and String.match?(pid, @pid_text),
      do: {:ok, %{pid: pid}},
      else: invalid("pid")
  end

  defp timeline_subject(%{"request_id" => request_id}) do
    if is_binary(request_id) and byte_size(request_id) in 1..128 and String.valid?(request_id) and
         String.printable?(request_id),
       do: {:ok, %{request_id: request_id}},
       else: invalid("request_id")
  end

  defp timeline_subject(_options), do: invalid("pid")

  defp correlated(options) do
    with {:ok, limit} <- bounded_integer(options, "limit", @correlated_limit),
         {:ok, max_bytes} <- bounded_integer(options, "max_bytes", @correlated_max_bytes) do
      case Map.get(options, "human", false) do
        human when is_boolean(human) -> {:ok, %{limit: limit, max_bytes: max_bytes, human: human}}
        _human -> invalid("human")
      end
    end
  end

  defp fold_describe(effect) do
    %{
      "type" => "list of strings",
      "default" => [],
      "max_items" => @fold_rules_max,
      "max_bytes" => 64,
      "note" =>
        "#{effect}; sql (database spans and repo query events) and auth (authorization and authentication) " <>
          "are categories, any other text is a span name or event kind prefix; result omitted counts them"
    }
  end

  defp correlated_describe(extra) do
    Map.merge(
      %{
        "limit" =>
          Map.merge(@correlated_limit, %{"type" => "integer", "note" => "items returned"}),
        "max_bytes" =>
          Map.merge(@correlated_max_bytes, %{
            "type" => "integer",
            "note" =>
              "canonical JSON bytes of the items returned; the first item is always returned"
          }),
        "human" => %{
          "type" => "boolean",
          "default" => false,
          "note" =>
            "adds text: an indented, time-ordered plain-text rendering; a trace's text is its span tree with each span's duration and outcome"
        }
      },
      extra
    )
  end

  defp report_category(category) when category in @report_categories, do: {:ok, category}
  defp report_category(_category), do: invalid("category")

  # Control characters other than newline and tab are refused, so a message
  # cannot carry terminal escapes into a listing or an issue.
  defp report_message(message)
       when is_binary(message) and byte_size(message) <= @report_message_max_bytes do
    trimmed =
      if String.valid?(message) and not String.match?(message, @control),
        do: String.trim(message)

    if trimmed in [nil, ""], do: invalid("message"), else: {:ok, trimmed}
  end

  defp report_message(_message), do: invalid("message")

  # The subscription's starting cursor, `nil` when not given (the owner
  # checks it against the Recorder with `cursor/1`), its total event budget
  # (`nil` is unlimited), its reader, and its view.
  @spec subscribe(term()) ::
          {:ok,
           %{
             cursor: term(),
             max_events: pos_integer() | nil,
             reader: String.t() | nil,
             view: View.t() | nil
           }}
          | {:error, map()}
  def subscribe(options) when is_map(options) and not is_struct(options) do
    with :ok <- known_keys(options, @subscribe_keys),
         {:ok, max_events} <- subscription_events(Map.get(options, "max_events")),
         {:ok, reader} <- reader(options),
         {:ok, view} <- View.parse(Map.get(options, "view")) do
      {:ok,
       %{cursor: Map.get(options, "cursor"), max_events: max_events, reader: reader, view: view}}
    end
  end

  def subscribe(_options), do: invalid("options")

  defp subscription_events(nil), do: {:ok, nil}

  defp subscription_events(events) do
    %{"min" => min, "max" => max} = @subscription_events

    if is_integer(events) and events >= min and events <= max,
      do: {:ok, events},
      else: invalid("max_events")
  end

  # Only a valid UTF-8 key of bounded size is echoed; anything else could not
  # be encoded as JSON or could carry caller bytes into the error. Unknown keys
  # are collected rather than searched for, so a `nil` key cannot read as
  # "none found".
  defp known_keys(options, allowed) when map_size(options) <= length(allowed) do
    case Enum.reject(Map.keys(options), &(&1 in allowed)) do
      [] -> :ok
      [key | _rest] when is_binary(key) and byte_size(key) <= 64 -> invalid_key(key)
      [_key | _rest] -> invalid("options")
    end
  end

  defp known_keys(_options, _allowed), do: invalid("options")

  defp invalid_key(key) do
    if String.valid?(key) and String.printable?(key), do: invalid(key), else: invalid("options")
  end

  defp components(components) when is_list(components) and components != [] do
    if Value.bounded_list?(components, map_size(@components)) and
         components == Enum.uniq(components) and
         Enum.all?(components, &(is_binary(&1) and is_map_key(@components, &1))),
       do: {:ok, Enum.sort(components)},
       else: invalid("components")
  end

  defp components(_components), do: invalid("components")

  @doc """
  The integer option `key` of `options` within the documented bounds
  (`"default"` when absent), else `invalid_options` for `key`. Shared by
  the start, read, filter, and Poller option parsers.
  """
  @spec bounded_integer(map(), String.t(), map()) :: {:ok, integer()} | {:error, map()}
  def bounded_integer(options, key, %{"default" => default, "min" => min, "max" => max}) do
    case Map.get(options, key, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _value -> invalid(key)
    end
  end

  # Without `"telemetry_events"`, the telemetry component records the quiet
  # default events this node has (`Insider.Live.Filters.telemetry_defaults/0`)
  # and reports the rest as skipped. Explicit names are never skipped: each
  # must already be an atom.
  defp telemetry_events(options, components) do
    events = Map.get(options, "telemetry_events")

    cond do
      "telemetry" not in components and is_nil(events) ->
        {:ok, [], []}

      "telemetry" not in components ->
        invalid("telemetry_events")

      is_nil(events) ->
        {recorded, skipped} = Filters.telemetry_defaults()
        with {:ok, mapped} <- map_all(recorded, &telemetry_event/1), do: {:ok, mapped, skipped}

      events != [] and Value.bounded_list?(events, @max_telemetry_events) ->
        with {:ok, mapped} <- map_all(events, &telemetry_event/1), do: {:ok, mapped, []}

      true ->
        invalid("telemetry_events")
    end
  end

  # A telemetry component the defaults left without an event would record
  # nothing, and the Telemetry collector needs at least one event, so the
  # session runs without it and the start result says why
  # (`telemetry_hint`). Alone, it leaves nothing to record: refused, with
  # the same hint.
  defp without_idle_telemetry(components, _measurements, [], [_ | _] = skipped) do
    case List.delete(components, "telemetry") do
      [] ->
        {:error,
         Error.new("invalid_options", %{
           "field" => "telemetry_events",
           "telemetry_skipped_defaults" => Filters.skipped_defaults(skipped),
           "hint" => Filters.no_defaults_hint()
         })}

      components ->
        {:ok, components, []}
    end
  end

  defp without_idle_telemetry(components, measurements, _events, _skipped),
    do: {:ok, components, measurements}

  defp telemetry_event(segments) when is_list(segments) and segments != [] do
    if Value.bounded_list?(segments, @max_event_segments) and Enum.all?(segments, &segment?/1) do
      case existing_atoms(segments) do
        {:ok, atoms} -> {:ok, {segments, atoms}}
        :error -> {:error, Error.new("unknown_telemetry_event", %{"event" => segments})}
      end
    else
      invalid("telemetry_events")
    end
  end

  defp telemetry_event(_segments), do: invalid("telemetry_events")

  # Measurement names come only from the host allowlist in
  # `Insider.Live.Disclosure`; the caller may select a subset of it.
  defp telemetry_measurements(options, components) do
    measurements = Map.get(options, "telemetry_measurements")
    allowlist = Disclosure.measurement_allowlist()

    cond do
      is_nil(measurements) ->
        {:ok, []}

      "telemetry" in components and Value.bounded_list?(measurements, @max_measurements) and
        measurements == Enum.uniq(measurements) and
          Enum.all?(measurements, &(is_binary(&1) and is_map_key(allowlist, &1))) ->
        {:ok, Enum.map(measurements, &{Map.fetch!(allowlist, &1), &1})}

      true ->
        invalid("telemetry_measurements")
    end
  end

  defp telemetry_policy([], _measurements), do: {:ok, nil}

  defp telemetry_policy(events, measurements) do
    rules =
      Enum.map(events, fn {segments, atoms} ->
        [name: atoms, kind: Enum.join(segments, "."), lifecycle: "insider-live", phase: :event]
      end)

    case TelemetryPolicy.new(
           id: Disclosure.selection_policy_id(),
           events: rules,
           measurements: measurements
         ) do
      {:ok, policy} -> {:ok, policy}
      {:error, :invalid_policy} -> invalid("telemetry_events")
    end
  end

  defp segment?(value),
    do: is_binary(value) and byte_size(value) in 1..64 and String.match?(value, @segment)

  defp existing_atoms(strings) do
    {:ok, Enum.map(strings, &String.to_existing_atom/1)}
  rescue
    ArgumentError -> :error
  end

  defp map_all(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, mapped} ->
      case mapper.(value) do
        {:ok, item} -> {:cont, {:ok, [item | mapped]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end

  defp invalid(field), do: {:error, Error.new("invalid_options", %{"field" => field})}
end
