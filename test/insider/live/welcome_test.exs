defmodule Insider.Live.WelcomeTest do
  # The hash test changes the `:insider` application environment and the
  # runtime test starts the node's one collector session.
  use ExUnit.Case, async: false

  alias Insider.Collector.Gate
  alias Insider.Collector.Telemetry.Outcome
  alias Insider.Event.Canonical
  alias Insider.Live
  alias Insider.Live.Options
  alias Insider.Live.Welcome

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :live_telemetry_measurements)
      Application.delete_env(:insider, :live_report_submission)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end
    end)

    :ok
  end

  defp full, do: Live.welcome(%{"full" => true})

  defp calls_available?, do: Insider.Collector.Calls.Tracing.preflight() == :ok

  describe "drift guard" do
    # usage-rules.md once said payloads never leave the node, which
    # holds only in the strict profile, while the welcome made rich the
    # development default. Every agent document must scope that prohibition
    # to strict, state the welcome's defaults, and point at the effective
    # profile.
    test "usage-rules.md and the agent guide state the welcome's disclosure rules" do
      %{"defaults" => defaults, "profiles" => profiles} = full()["disclosure"]
      assert defaults["development"] == defaults["test"]

      for path <- ["usage-rules.md", "guides/agents/live-observation.md"] do
        text = File.read!(path)
        flat = String.replace(text, ~r/\s+/, " ")

        assert flat =~ "Development and test default to `#{defaults["development"]}`", path
        assert flat =~ "`#{defaults["ci"]}` profile (the ci default", path
        assert flat =~ "`effective_disclosure", path
        for profile <- profiles, do: assert(flat =~ "`#{profile}`", "#{path} #{profile}")

        # Each paragraph or bullet that withholds payloads names the profile
        # that withholds them.
        for block <- String.split(text, ~r/\n(?:\s*\n|- )/),
            block =~ ~r/never\s+leave/i do
          assert block =~ "`strict`", "#{path}: unscoped prohibition: #{block}"
        end
      end
    end

    test "the welcome states the effective disclosure profile prominently" do
      for welcome <- [Live.welcome(), full()] do
        runtime = welcome["runtime"]

        assert %{"profile" => "rich", "source" => "environment_default", "means" => means} =
                 welcome["effective_disclosure"]

        assert runtime["disclosure_profile"] == "rich"
        assert means =~ "payloads"
      end

      hash = full()["hash"]
      Application.put_env(:insider, :live_disclosure, :strict)

      try do
        assert %{"profile" => "strict", "source" => "application_env", "means" => means} =
                 Live.welcome()["effective_disclosure"]

        assert means =~ "never leave the node"
        assert full()["hash"] == hash
      after
        Application.delete_env(:insider, :live_disclosure)
      end
    end

    test "the welcome lists exactly the operations Insider.Live and Insider.Live.JSON export" do
      welcome = full()
      documented = MapSet.new(welcome["operations"], &{&1["name"], &1["elixir"], &1["json"]})

      for module <- [Live, Live.JSON] do
        exported =
          module.__info__(:functions)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> MapSet.new(fn {name, arities} ->
            name = Atom.to_string(name)
            arity = Enum.max(arities)
            {name, "Insider.Live.#{name}/#{arity}", "Insider.Live.JSON.#{name}/#{arity}"}
          end)

        assert exported == documented, "#{inspect(module)} differs from the welcome operations"
      end
    end

    test "the welcome lists exactly the error codes the live code can return" do
      sources = Path.wildcard("lib/insider/live/**/*.ex") ++ ["lib/insider/live.ex"]

      returned =
        for source <- sources,
            [_, code] <- Regex.scan(~r/Error\.new\(\s*"([a-z_]+)"/, File.read!(source)),
            into: MapSet.new(),
            do: code

      documented = full()["errors"]["codes"]

      assert MapSet.new(Map.keys(documented)) == returned
      assert Enum.all?(documented, fn {_code, message} -> message != "" end)
    end

    test "every documented start, read, and report option behaves as documented" do
      options = full()["options"]

      assert options["welcome"] |> Map.keys() |> Enum.sort() == Options.welcome_keys()
      assert {:ok, false} = Options.welcome(%{})
      assert {:ok, true} = Options.welcome(%{"full" => true})
      assert {:error, %{"field" => "full"}} = Options.welcome(%{"full" => "yes"})
      assert {:error, %{"field" => "other"}} = Options.welcome(%{"other" => true})
      assert {:error, %{"field" => "options"}} = Options.welcome([])

      discover = options["discover"]
      assert discover |> Map.keys() |> Enum.sort() == Options.discover_keys()
      assert {:ok, nil} = Options.discover(%{})
      assert {:ok, ["phoenix"]} = Options.discover(%{"prefix" => ["phoenix"]})
      too_deep = List.duplicate("a", discover["prefix"]["segments_max"] + 1)
      assert {:ok, _prefix} = Options.discover(%{"prefix" => tl(too_deep)})
      assert {:error, %{"field" => "prefix"}} = Options.discover(%{"prefix" => too_deep})
      assert {:error, %{"field" => "other"}} = Options.discover(%{"other" => true})
      assert {:error, %{"field" => "options"}} = Options.discover([])

      assert options["start"] |> Map.keys() |> Enum.sort() == Enum.sort(Options.start_keys())
      assert options["read"] |> Map.keys() |> Enum.sort() == Enum.sort(Options.read_keys())
      assert options["report"] |> Map.keys() |> Enum.sort() == Enum.sort(Options.report_keys())

      assert options["subscribe"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Options.subscribe_keys())

      for {group, validate} <- [
            {"start", &Options.start/1},
            {"read", &Options.read/1},
            {"subscribe", &Options.subscribe/1}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "undocumented"}} =
                 validate.(%{"undocumented" => 1})

        # On OTP 27 the otel component is refused, so its options are checked
        # through Filters there.
        for {key, %{"type" => "integer", "min" => min, "max" => max} = option} <- options[group],
            option["requires_component"] != "otel" or
              Insider.Collector.Otel.Tracing.preflight() == :ok do
          # An option that needs a component is tried with that component
          # (and the calls component with a function to trace).
          base =
            case option do
              %{"requires_component" => "calls"} ->
                %{"components" => ["calls"], "calls" => ["Enum.member?/2"]}

              %{"requires_component" => component} ->
                %{"components" => [component]}

              _option ->
                %{}
            end

          if base["components"] == ["calls"] and not calls_available?() do
            # On OTP 27 the component is refused before its options are read.
            assert {:error, %{"code" => "component_unavailable", "reason" => "requires_otp_28"}} =
                     validate.(Map.put(base, key, min))
          else
            assert {:ok, _accepted} = validate.(Map.put(base, key, min)), "#{group} #{key} min"
            assert {:ok, _accepted} = validate.(Map.put(base, key, max)), "#{group} #{key} max"

            for outside <- [min - 1, max + 1] do
              assert {:error, %{"code" => "invalid_options", "field" => ^key}} =
                       validate.(Map.put(base, key, outside))
            end
          end
        end
      end

      # trace and timeline share their bounds.
      assert options["trace"] |> Map.keys() |> Enum.sort() == Enum.sort(Options.trace_keys())

      assert options["timeline"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Options.timeline_keys())

      trace_id = "0af7651916cd43dd8448eb211c80319c"

      for {group, validate} <- [
            {"trace", &Options.trace(trace_id, &1)},
            {"timeline", &Options.timeline(Map.put(&1, "pid", "<0.1.0>"))}
          ] do
        assert {:error, %{"field" => "undocumented"}} = validate.(%{"undocumented" => 1})
        assert {:ok, defaults} = validate.(%{})
        assert defaults.limit == options[group]["limit"]["default"]
        assert defaults.max_bytes == options[group]["max_bytes"]["default"]
        assert defaults.human == options[group]["human"]["default"]

        for {key, %{"type" => "integer", "min" => min, "max" => max}} <- options[group] do
          assert {:ok, _accepted} = validate.(%{key => min})
          assert {:ok, _accepted} = validate.(%{key => max})

          for outside <- [min - 1, max + 1] do
            assert {:error, %{"field" => ^key}} = validate.(%{key => outside})
          end
        end
      end

      assert {:error, %{"field" => "trace_id"}} = Options.trace("ABC", %{})
      assert {:error, %{"field" => "trace_id"}} = Options.trace(String.duplicate("0", 32), %{})
      assert {:error, %{"field" => "pid"}} = Options.timeline(%{})
      assert {:error, %{"field" => "pid"}} = Options.timeline(%{"pid" => "0.1.0"})

      assert {:error, %{"field" => "pid"}} =
               Options.timeline(%{"pid" => "<0.1.0>", "request_id" => "r"})

      assert {:error, %{"field" => "request_id"}} = Options.timeline(%{"request_id" => ""})

      assert {:error, %{"field" => "human"}} =
               Options.timeline(%{"request_id" => "r", "human" => 1})

      assert {:ok, %{request_id: "r"}} = Options.timeline(%{"request_id" => "r"})
      assert {:error, %{"field" => "options"}} = Options.trace(trace_id, [])
      assert {:error, %{"field" => "options"}} = Options.timeline([])

      start = options["start"]
      assert {:ok, defaults} = Options.start(%{})
      assert defaults.lease_ms == start["lease_ms"]["default"]
      assert defaults.max_events == start["max_events"]["default"]

      # This test node has no quiet default Telemetry events.
      assert Live.welcome()["runtime"]["quiet_default_telemetry_events"] == []

      assert Enum.map(defaults.components, &Atom.to_string/1) ==
               start["components"]["default_without_quiet_events"]

      assert defaults.telemetry_measurements == start["telemetry_measurements"]["default"]

      # Every documented filter default is the one a session gets.
      for key <- [
            "logger_level",
            "logger_include",
            "logger_exclude",
            "exclude_origins",
            "telemetry_min_duration_ms",
            "telemetry_summaries",
            "telemetry_summary_interval_ms",
            "telemetry_duration_scopes",
            "logger_summaries",
            "logger_summary_interval_ms"
          ] do
        assert defaults.filters.config[key] == start[key]["default"], key
      end

      # Every documented poller default is the one a poller session gets.
      assert {:ok, %{poller: poller}} = Options.start(%{"components" => ["poller"]})
      assert poller.interval_ms == start["poller_interval_ms"]["default"]
      assert poller.top_processes == start["top_processes"]["default"]
      assert poller.top_ets_tables == start["top_ets_tables"]["default"]
      assert poller.watch_processes == start["watch_processes"]["default"]

      assert {:ok,
              [
                limit: limit,
                max_bytes: max_bytes,
                scan_limit: scan_limit,
                upto: nil,
                view: nil,
                reader: nil,
                renew: true
              ]} =
               Options.read(%{})

      assert limit == options["read"]["limit"]["default"]
      assert max_bytes == options["read"]["max_bytes"]["default"]
      assert scan_limit == options["read"]["scan_limit"]["default"]
      assert options["read"]["upto"]["default"] == nil
      assert {:ok, [_l, _b, _s, {:upto, 15}, _v, _r, _n]} = Options.read(%{"upto" => 15})
      assert options["read"]["renew"]["default"] == true
      assert {:ok, read} = Options.read(%{"renew" => false})
      assert read[:renew] == false
      assert {:error, %{"field" => "renew"}} = Options.read(%{"renew" => "no"})

      for upto <- [-1, "15", 1.5],
          do: assert({:error, %{"field" => "upto"}} = Options.read(%{"upto" => upto}))

      assert {:ok, %{cursor: nil, max_events: nil, reader: nil, view: nil}} =
               Options.subscribe(%{})

      assert options["subscribe"]["cursor"]["default"] == 0
      assert options["subscribe"]["max_events"]["default"] == "unlimited"

      # Stop takes a reader and force; amend takes a reader and every start
      # option, at least one of them.
      assert options["stop"] |> Map.keys() |> Enum.sort() == Options.stop_keys()
      assert {:ok, %{reader: nil, force: false}} = Options.stop(%{})

      assert {:ok, %{reader: "agent-a", force: true}} =
               Options.stop(%{"reader" => "agent-a", "force" => true})

      assert options["amend"]["reader"]["pattern"] == options["read"]["reader"]["pattern"]
      assert options["subscribe"]["reader"]["pattern"] == options["read"]["reader"]["pattern"]
      assert Options.amend_keys() == Enum.sort(["reader" | Options.start_keys()])

      for key <- Options.start_keys() do
        assert {:ok, nil, %{^key => _value}} = Options.amend(%{key => :any})
      end

      assert {:error, %{"field" => "options"}} = Options.amend(%{"reader" => "agent-a"})

      for cursor <- [0, 7, "latest"],
          do: assert({:ok, _cursor} = Options.cursor(cursor))

      for cursor <- [-1, 1.0, "newest", nil], do: assert(:error = Options.cursor(cursor))

      for key <- Map.keys(options["read"]["view"]["keys"]) do
        assert {:error, %{"field" => "view"}} = Options.read(%{"view" => %{key => :invalid}})
      end

      assert {:error, %{"field" => "view"}} =
               Options.subscribe(%{"view" => %{"undocumented" => 1}})

      for component <- start["components"]["allowed"], component not in ["telemetry", "calls"] do
        case {component, Insider.Collector.Otel.Tracing.preflight()} do
          {"otel", {:error, reason}} ->
            assert {:error, %{"code" => "component_unavailable", "reason" => reason_text}} =
                     Options.start(%{"components" => [component]})

            assert reason_text == Atom.to_string(reason)

          _available ->
            assert {:ok, _accepted} = Options.start(%{"components" => [component]})
        end
      end

      # The calls component needs a function to trace, and OTP 28.
      calls = %{"components" => ["calls"], "calls" => ["Enum.member?/2"]}

      if calls_available?() do
        assert {:error, %{"field" => "calls"}} = Options.start(%{"components" => ["calls"]})
        assert {:ok, %{calls: %{functions: ["Enum.member?/2"]}}} = Options.start(calls)
      else
        assert {:error, %{"code" => "component_unavailable"}} = Options.start(calls)
      end

      assert {:error, %{"field" => "components"}} = Options.start(%{"components" => ["other"]})

      telemetry = %{"components" => ["telemetry"], "telemetry_events" => [["telemetry"]]}

      assert {:ok, %{telemetry_measurements: measurements}} =
               Options.start(
                 Map.put(
                   telemetry,
                   "telemetry_measurements",
                   start["telemetry_measurements"]["allowed"]
                 )
               )

      assert measurements == start["telemetry_measurements"]["allowed"]

      report = options["report"]
      message = String.duplicate("a", report["message"]["max_bytes"])

      for category <- report["category"]["allowed"] do
        assert {:ok, %{category: ^category}} =
                 Options.report(%{"category" => category, "message" => message})
      end

      assert {:error, %{"field" => "message"}} =
               Options.report(%{"category" => "bug", "message" => message <> "a"})

      assert {:error, %{"field" => "category"}} =
               Options.report(%{"category" => "other", "message" => "text"})
    end

    test "the digest options behave as documented" do
      digest = full()["options"]["digest"]
      last_max = digest["since"]["last_max"]

      assert digest |> Map.keys() |> Enum.sort() == Options.digest_keys()
      # The default window is the last minute, not the session start.
      assert {:ok, %{since: {:recent, 60_000}, human: false}} = Options.digest(%{})
      assert digest["since"]["default"] == "latest-60s" and digest["human"]["default"] == false
      assert {:ok, %{since: {:cursor, 0}}} = Options.digest(%{"since" => 0})

      for {text, ms} <- [
            {"latest-1s", 1_000},
            {"latest-90s", 90_000},
            {"latest-5m", 300_000},
            {"latest-24h", 86_400_000},
            {"latest-1500ms", 1_500}
          ] do
        assert {:ok, %{since: {:recent, ^ms}}} = Options.digest(%{"since" => text}), text
      end

      # Pairing: since the newest mark, or the newest mark with a label.
      assert {:ok, %{since: {:mark, nil}}} = Options.digest(%{"since" => "mark"})

      assert {:ok, %{since: {:mark, "open cart"}}} =
               Options.digest(%{"since" => "mark:open cart"})

      assert digest["since"]["note"] =~ "\"mark\""

      # Trends read the whole session unless told otherwise.
      assert {:ok, %{since: {:cursor, 0}}} = Options.trends(%{})

      assert {:ok, %{since: {:cursor, 7}, human: true}} =
               Options.digest(%{"since" => 7, "human" => true})

      assert {:ok, %{since: {:last, 1}}} = Options.digest(%{"since" => "latest-1"})

      assert {:ok, %{since: {:last, ^last_max}}} =
               Options.digest(%{"since" => "latest-#{last_max}"})

      for since <- [
            -1,
            "latest-0",
            "latest-#{last_max + 1}",
            "latest",
            "latest-x",
            "7",
            1.0,
            "latest-0s",
            "latest-999ms",
            "latest-25h",
            "latest-1d",
            "latest-s",
            "mark:",
            "marks"
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "since"}} =
                 Options.digest(%{"since" => since}),
               inspect(since)
      end

      assert {:error, %{"field" => "human"}} = Options.digest(%{"human" => "yes"})
      assert {:error, %{"field" => "other"}} = Options.digest(%{"other" => 1})
      assert {:error, %{"field" => "options"}} = Options.digest([])
      assert full()["bounds"]["digest_budget_ms"] == Options.digest_budget_ms()
    end

    test "the time table names every source's wall time and the duration units" do
      time = full()["time"]

      assert Map.keys(time["wall_time"]) |> Enum.sort() ==
               Enum.sort([
                 "format" | full()["options"]["read"]["view"]["keys"]["sources"]["allowed"]
               ])

      assert time["monotonic_time"] =~ "sequence number"

      for name <- Insider.Live.Disclosure.time_measurements(),
          do: assert(time["durations"] =~ name)

      assert time["durations"] =~ "attributes.durations_us"
    end

    test "bounds and allowed measurements agree with capabilities" do
      welcome = full()
      capabilities = Live.capabilities()

      assert welcome["bounds"] == capabilities["bounds"]
      assert welcome["components"] == capabilities["components"]

      assert welcome["telemetry_measurements_allowed"] ==
               capabilities["telemetry_measurements_allowed"]
    end

    test "the severity table is the collectors' own rule" do
      severity = full()["severity"]
      allowed = full()["options"]["read"]["view"]["keys"]["min_severity"]["allowed"]

      assert severity["order"] == allowed
      assert Map.keys(severity["logger"]) |> Enum.sort() == Enum.sort(Gate.levels())
      assert severity["logger"] |> Map.values() |> Enum.all?(&(&1 in allowed))
      assert severity["poller"] in allowed
      assert severity["inspect"] in allowed

      assert Enum.take(severity["telemetry"], length(Outcome.rules())) == Outcome.rules()

      assert Enum.map(severity["telemetry"], & &1["severity"]) ==
               List.duplicate("error", length(Outcome.rules())) ++ ["warning", "warning", "info"]

      assert severity["otel"] |> Map.values() |> Enum.sort() == ["error", "info", "warning"]
    end

    test "transport examples use only documented functions and observer commands" do
      transports = full()["transports"]
      exported = Live.JSON.__info__(:functions) |> Keyword.keys() |> MapSet.new(&to_string/1)

      for example <- transports["tidewave"]["examples"] do
        assert [[_, name]] = Regex.scan(~r/\AInsider\.Live\.JSON\.([a-z_]+)\(/, example)
        assert name in exported, example
      end

      commands = MapSet.new(transports["observer"]["commands"], & &1["name"])

      for example <- Welcome.example_commands() do
        assert [_, rest] = Regex.run(~r/\A(?:timeout \d+ )?mix insider\.live (.*)\z/, example)

        words =
          rest
          |> String.split()
          |> Enum.take_while(&(not String.starts_with?(&1, ["-", "$", ~S("$)])))

        assert Enum.join(words, " ") in commands, example
      end
    end

    test "every observer flag has its value syntax, and each sets a documented option" do
      observer = full()["transports"]["observer"]
      options = full()["options"]

      flags =
        Enum.flat_map(observer["commands"], &(&1["required"] ++ &1["optional"])) ++
          observer["target_flags"]

      assert MapSet.new(flags) == MapSet.new(Map.keys(observer["options"]))

      # Every flag a command takes resolves, for that command, to its syntax:
      # the flag's own, or the command's override (watch --max-events).
      for command <- observer["commands"],
          flag <- command["required"] ++ command["optional"] ++ observer["target_flags"] do
        row = observer["options"][flag]
        assert %{"value" => value} = Welcome.observer_option(command["name"], flag)
        assert value == (get_in(row, ["commands", command["name"], "value"]) || row["value"])
      end

      assert Welcome.observer_option("start", "--max-events")["sets"] == "start.max_events"
      assert Welcome.observer_option("watch", "--max-events")["sets"] == "subscribe.max_events"
      assert Welcome.observer_option("start", "--frobnicate") == nil
      # One --pid flag serves two commands: the
      # inspected process on process, the event subject on timeline.
      assert Welcome.observer_option("process", "--pid")["sets"] == "process.pid"
      assert Welcome.observer_option("process", "--pid")["value"] =~ "give --name or --pid"
      assert Welcome.observer_option("timeline", "--pid")["sets"] == "timeline.pid"
      assert Welcome.observer_option("timeline", "--pid")["value"] =~ "event.subject.value"

      assert Enum.sort(observer["repeatable"]) ==
               Enum.sort(for {f, %{"repeatable" => true}} <- observer["options"], do: f)

      for {flag, %{"value" => value, "sets" => sets}} <- observer["options"] do
        assert is_binary(value) and value != "", flag

        case sets && String.split(sets, ".") do
          nil -> :ok
          [argument] -> assert argument in ["session_id", "cursor", "trace_id"], flag
          ["view", key] -> assert Map.has_key?(options["read"]["view"]["keys"], key), flag
          [group, key] -> assert Map.has_key?(options[group], key), flag
        end
      end
    end

    test "the observer's error codes carry their status and exit code" do
      observer = full()["errors"]["observer"]

      for {code, %{"status" => status, "exit" => exit, "message" => message}} <- observer["codes"] do
        assert observer["exit_statuses"][status] == exit, code
        assert message != "", code
      end

      # One name for malformed options, from the target and the observer.
      assert Map.has_key?(observer["codes"], "invalid_options")
      refute Map.has_key?(observer["codes"], "invalid_option")
      assert Map.has_key?(full()["errors"]["codes"], "invalid_options")

      # No remedy says --load replaces another Insider;
      # replacing one is --force-load, after saving the session's evidence.
      for {code, %{"message" => message}} <- observer["codes"] do
        refute message =~ ~r/--load (replaces|reloads)/, code
      end

      for code <- ["insider_version_mismatch", "load_build_differs"] do
        assert observer["codes"][code]["message"] =~ "--force-load", code
        assert observer["codes"][code]["message"] =~ "save what you need", code
      end

      quick_start = Enum.join(Live.welcome()["quick_start"]["steps"], "\n")
      assert quick_start =~ "--load never replaces another Insider"
      assert quick_start =~ "insider_version_mismatch and load_build_differs need --force-load"

      # Every text that recommends --force-load (an
      # observer error, the flag's own value, a step, a runtime note) also
      # tells the agent to save the session's evidence first, because
      # force-loading ends the session and its evidence does not survive.
      advice =
        for document <- [full(), Live.welcome()],
            text <- strings(document),
            text =~ "--force-load" and text != "--force-load",
            uniq: true,
            do: text

      assert Enum.count_until(advice, 5) == 5

      for text <- advice,
          do: assert(text =~ "(events, digest, handoff)", "no evidence warning: " <> text)
    end
  end

  describe "quick start" do
    test "the default welcome is the agent quick start with a pointer to the full reference" do
      welcome = Live.welcome()
      full = full()

      assert welcome |> Map.keys() |> Enum.sort() ==
               ~w(effective_disclosure full_reference hash hash_covers insider pairs_with quick_start recipes runtime schema summary tandem)

      # Each form has its own schema id, so a consumer never guesses from the
      # fields present: the quick start is new, and the full reference is v2
      # because the default `welcome` no longer returns it.
      assert welcome["schema"] == "insider.live-welcome-quick-start/v1"
      assert full["schema"] == "insider.live-welcome/v2"
      assert welcome["full_reference"]["schema"] == full["schema"]
      # A pointer advertises the schema its read commands return: read_with
      # gets the quick start, full_reference the full reference. The hash is
      # the full reference's in both.
      pointer = Live.capabilities()["welcome"]
      assert pointer["read_with"]["elixir"] == "Insider.Live.welcome()"
      assert pointer["schema"] == welcome["schema"]
      assert pointer["full_reference"]["elixir"] == ~s|Insider.Live.welcome(%{"full" => true})|
      assert pointer["full_reference"]["schema"] == full["schema"]
      assert pointer["hash"] == full["hash"]
      assert welcome["hash_covers"] =~ full["schema"]
      assert welcome["hash"] == full["hash"]
      assert welcome["runtime"] == full["runtime"]
      assert welcome["quick_start"] == full["quick_start"]
      assert welcome["recipes"] == full["recipes"]
      assert byte_size(Jason.encode!(welcome)) * 2 < byte_size(Jason.encode!(full))

      assert welcome["full_reference"]["observer"] ==
               "mix insider.live welcome --node NAME@HOST --cookie-file PATH --full"

      assert welcome["full_reference"]["json"] == ~s|Insider.Live.JSON.welcome(%{"full" => true})|
    end

    test "the quick start gives the steps in order, six core commands, --load, opt-in measurements, and stop" do
      %{"steps" => steps, "commands" => commands, "load" => load, "setup" => setup} =
        Live.welcome()["quick_start"]

      assert length(steps) + length(commands) + 2 <= 20
      assert steps == Enum.sort_by(steps, &(&1 |> Integer.parse() |> elem(0)))

      assert Enum.map(commands, &operation/1) ==
               ["start", "digest", "events", "watch", "stop", "report"]

      # An array, so the target flags split into words in zsh as in bash.
      assert setup == "N=(--node NAME@HOST --cookie-file PATH)"
      assert load == "mix insider.live capabilities \"${N[@]}\" --load"

      text = Enum.join(steps, "\n")
      assert text =~ "--load"
      # Opt-in holds for the strict profile; rich returns every measurement.
      assert text =~ "Measurements are opt-in in the strict profile"
      assert text =~ "The rich profile returns every measurement"
      assert text =~ "--telemetry-measurement duration"
      assert text =~ "Stop when you are done"
      assert text =~ "digest the session"
      assert text =~ "--format compact"
      # Pairing: mark before the programmer acts, then digest since the mark.
      assert text =~ "mark \"${N[@]}\" --session SESSION_ID --label"
      assert text =~ "digest \"${N[@]}\" --session SESSION_ID --since-mark --human"
    end

    # The observer is installed from Hex as well as run from a checkout. The
    # quick start, the escript notes, and the observer transport name both
    # routes, with the same install command the README and the guides teach.
    test "the welcome names the Hex install of the escript and the checkout route" do
      welcome = full()
      [first_step | _rest] = Live.welcome()["quick_start"]["steps"]
      escript = welcome["tandem"]["escript"]
      observer = welcome["transports"]["observer"]

      for text <- [first_step, escript["install"], observer["escript_install"]] do
        assert text =~ "mix escript.install hex insider_lab"
      end

      assert first_step =~ "insider-lab live"
      assert first_step =~ "mix insider.live from tools/insider_lab"
      assert first_step =~ "./insider-lab live"
      refute first_step =~ "Run every command from tools/insider_lab"

      assert escript["build"] =~ "mix escript.build"
      assert escript["run"] =~ "insider-lab live OPERATION"
      assert escript["freshness"] =~ "installed from Hex"
      assert observer["run_from"] =~ "any directory"
      assert observer["run_from"] =~ "tools/insider_lab"
      assert observer["escript"] == "insider-lab live"

      for path <- ["README.md", "docs/getting-started.md", "usage-rules.md"] do
        assert File.read!(path) =~ "mix escript.install hex insider_lab", path
      end
    end

    # The core and the CLI are two Hex packages. An agent in an app that
    # depends only on `insider` finds no `mix insider.live` there, so the
    # welcome, and every entry-point document, names the package that has
    # it and says the core has no Mix tasks.
    test "the welcome and the entry-point documents name both packages" do
      [first_step | _rest] = Live.welcome()["quick_start"]["steps"]
      observer = full()["transports"]["observer"]

      for text <- [first_step, observer["package"]] do
        assert text =~ "insider_lab"
        assert text =~ "The insider package, the library in"
        assert text =~ "has no Mix tasks"
      end

      assert observer["package"] =~ "same version"

      for path <- [
            "README.md",
            "usage-rules.md",
            "docs/README.md",
            "docs/getting-started.md",
            "docs/glossary.md",
            "docs/cheat-sheet.md"
          ] do
        text = String.replace(File.read!(path), ~r/\s+/, " ")
        assert text =~ "insider_lab", path
        assert text =~ "no Mix tasks", path
      end

      for module <- [Insider, Insider.Live] do
        {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(module)
        [first_paragraph | _rest] = String.split(moduledoc, "\n\n")
        assert first_paragraph =~ "insider_lab", inspect(module)
        assert first_paragraph =~ "mix escript.install hex insider_lab", inspect(module)
      end
    end

    # A host app that does not depend on Insider answers every observer
    # command with insider_missing until one carries --load. Followed in
    # order, each entry point's first command against a node must load it.
    test "the first command against a node in each entry point carries --load" do
      [_get_observer, first_contact | _rest] = Live.welcome()["quick_start"]["steps"]
      assert first_contact =~ ~s(capabilities "${N[@]}" --load)
      assert Live.welcome()["quick_start"]["load"] =~ ~s(capabilities "${N[@]}" --load)

      command = ~r{(?:insider-lab live|mix insider\.live) ([a-z][a-z-]*)([^\n`]*)}

      for path <- [
            "README.md",
            "usage-rules.md",
            "docs/getting-started.md",
            "docs/cheat-sheet.md",
            "guides/agents/live-observation.md",
            "lib/insider.ex",
            "tools/insider_lab/README.md",
            "tools/insider_lab/lib/mix/tasks/insider.live.ex"
          ] do
        first =
          Regex.scan(command, File.read!(path))
          |> Enum.find(fn [_line, _operation, rest] ->
            rest =~ "--node" or rest =~ ~s("${N[@]}")
          end)

        assert [line, "capabilities", rest] = first, "#{path}: #{inspect(first)}"
        assert rest =~ ~r/--load\b/, "#{path}: #{line}"
      end
    end

    test "the recipes start with a digest and cover latency, log floods, crash loops, 5xx, mailboxes, memory, binary and port leaks, amendments, agents, unknown event names, frontend actions, and failing calls" do
      [first | _rest] = all = Live.welcome()["recipes"]
      recipes = Map.new(all, &{&1["symptom"] |> String.split(":") |> hd(), &1})

      assert Map.keys(recipes) |> Enum.sort() ==
               [
                 "5xx",
                 "GraphQL error in a 200",
                 "app hangs",
                 "binary leak",
                 "crash loop",
                 "failing call",
                 "follow a frontend action",
                 "growing mailbox",
                 "growth over time",
                 "latency",
                 "log flood",
                 "lost events",
                 "memory growth",
                 "missing values",
                 "pairing",
                 "port leak",
                 "several agents",
                 "slow request",
                 "triage",
                 "unknown event names"
               ]

      # Hangs name the wait before the endpoint, bursts, and
      # inspection over distribution.
      hangs = recipes["app hangs"]
      assert hangs["look_for"] =~ "Pre-handler waits"
      assert hangs["look_for"] =~ "Request burst"
      assert hangs["look_for"] =~ "over Erlang distribution, not through the HTTP request path"

      assert List.last(hangs["commands"]) =~
               "process \"${N[@]}\" --name Phoenix.CodeReloader.Server"

      # Pairing: mark, ask the programmer to act, then digest since the mark.
      pairing = recipes["pairing"]
      # The chart comes first: the programmer gets its URL before the first mark.
      assert Enum.map(pairing["commands"], &operation/1) == ["chart", "mark", "digest", "marks"]
      assert hd(pairing["commands"]) =~ "chart \"${N[@]}\" --session SESSION_ID --serve"
      assert pairing["look_for"] =~ "give the programmer the URL"
      assert Enum.at(pairing["commands"], 2) =~ "--since-mark --human"
      assert pairing["look_for"] =~ "ask the programmer"

      # Errors inside a 200 have their own recipe.
      graphql = recipes["GraphQL error in a 200"]
      assert hd(graphql["commands"]) =~ "--telemetry-event absinthe.execute.operation.stop"
      assert List.last(graphql["commands"]) =~ "--collapse sql --hide auth"
      assert graphql["look_for"] =~ "user_error_fields"

      # Triage comes first and is a digest; every symptom recipe that reads
      # what the application did reads with a digest before it reads events.
      assert first["symptom"] =~ "triage"
      assert Enum.all?(first["commands"], &(operation(&1) == "digest"))
      assert Enum.any?(first["commands"], &(&1 =~ "--human"))

      for name <- [
            "latency",
            "crash loop",
            "5xx",
            "slow request",
            "growing mailbox",
            "memory growth",
            "binary leak",
            "port leak",
            "failing call",
            "growth over time"
          ] do
        operations = Enum.map(recipes[name]["commands"], &operation/1)
        digest = Enum.find_index(operations, &(&1 == "digest"))
        events = Enum.find_index(operations, &(&1 == "events"))
        assert digest && events && digest < events, name
      end

      assert recipes["crash loop"]["look_for"] =~ "period_ms"

      # The crash recipe leads with the call trace: its look_for starts with
      # it, and the amend --calls command comes right after the digest whose
      # hints name the function.
      assert recipes["crash loop"]["look_for"] =~ ~r/\ATrace the crashing function/
      crash_commands = recipes["crash loop"]["commands"]
      amend = Enum.find_index(crash_commands, &(&1 =~ "amend \"${N[@]}\""))
      assert Enum.at(crash_commands, amend - 1) =~ "digest \"${N[@]}\""
      assert Enum.at(crash_commands, amend) =~ "--component calls --calls MOD.FUN/ARITY"
      assert recipes["crash loop"]["look_for"] =~ "recon_trace"

      # The call.exception read starts at
      # the amendment's marker receipt, never at latest (an empty batch).
      exceptions = Enum.find(crash_commands, &(&1 =~ "--view-kind call.exception"))
      assert exceptions =~ ~r/--cursor \d+ /
      refute exceptions =~ "--cursor latest"
      assert recipes["crash loop"]["look_for"] =~ "amendment.marker_receipt"

      assert Enum.map(recipes["lost events"]["commands"], &operation/1) ==
               ["digest", "amend", "status"]

      assert recipes["lost events"]["look_for"] =~ "reduce_logger"

      # The per-sample Poller series in trends.
      growth = recipes["growth over time"]

      assert Enum.any?(
               growth["commands"],
               &(operation(&1) == "trends" and &1 =~ "--kind port_top")
             )

      for field <- [
            "per_min",
            "coverage ranked",
            "coverage watched",
            "binary_bytes",
            "--format compact"
          ],
          do: assert(growth["look_for"] =~ field)

      assert recipes["latency"]["look_for"] =~ "durations_us"

      assert Enum.join(recipes["missing values"]["commands"], " ") =~
               "amend \"${N[@]}\" --session SESSION_ID --telemetry-measurement duration"

      assert recipes["several agents"]["look_for"] =~ "readers_active"

      frontend = recipes["follow a frontend action"]
      assert hd(frontend["commands"]) =~ "--component otel"
      assert Enum.at(frontend["commands"], 1) =~ "otlp-receive \"${N[@]}\" --session SESSION_ID"

      assert List.last(frontend["commands"]) =~
               "trace \"${N[@]}\" --session SESSION_ID --trace-id"

      assert frontend["look_for"] =~ "INSIDER_OTLP_ENDPOINT=http://127.0.0.1:4318/v1/traces"
      assert frontend["look_for"] =~ "trace id"

      assert Enum.join(recipes["latency"]["commands"], " ") =~
               "--telemetry-summary phoenix.endpoint.stop"

      assert recipes["latency"]["look_for"] =~ "duration_p95_us"

      # The latency recipe opens an exemplar and reads the trends.
      for field <- [
            "exemplars",
            "events --cursor 41 --limit 1",
            "duration_scope",
            "trends",
            "exemplars_lost",
            "first_error_retained",
            "telemetry_exemplar_lost",
            "--telemetry-duration-scope KIND=handler"
          ],
          do: assert(recipes["latency"]["look_for"] =~ field)

      # Process identity is not a duration's
      # scope, and a handler-caller difference is queueing only if both
      # describe the same operation.
      refute recipes["latency"]["look_for"] =~ "server_callback"
      refute recipes["latency"]["look_for"] =~ "is time spent queued"
      assert recipes["latency"]["look_for"] =~ "describe the same operation"

      assert Enum.any?(recipes["latency"]["commands"], &(operation(&1) == "trends"))

      flood = recipes["log flood"]
      assert hd(flood["commands"]) =~ "--logger-summary module:"
      assert Enum.map(flood["commands"], &operation/1) == ["start", "digest", "trends"]

      for field <- [
            "logger_summary",
            "exemplar_receipt",
            "call_site",
            "template_fingerprint",
            "per message template",
            "At most 64 bursts",
            "logger_summary_overflow",
            "logger_exemplar_lost",
            "filtered.logger.summarized"
          ],
          do: assert(flood["look_for"] =~ field)

      assert Enum.join(recipes["crash loop"]["commands"], " ") =~
               "--view-kind supervisor_child_terminated"

      assert recipes["crash loop"]["look_for"] =~ "offender_id"
      assert recipes["crash loop"]["look_for"] =~ "period"

      for event <- ["phoenix.endpoint.stop", "phoenix.router_dispatch.exception"] do
        assert Enum.join(recipes["5xx"]["commands"], " ") =~ "--telemetry-event #{event}"
      end

      assert Enum.at(recipes["5xx"]["commands"], 2) =~ "--view-min-severity error"
      # A failing request's trace id leads to its span tree and log lines.
      assert List.last(recipes["5xx"]["commands"]) =~
               "trace \"${N[@]}\" --session SESSION_ID --trace-id"

      assert hd(recipes["5xx"]["commands"]) =~ "--component otel"

      slow = Enum.join(recipes["slow request"]["commands"], " ")
      assert slow =~ "--component otel"
      assert slow =~ "trace \"${N[@]}\""
      assert slow =~ "timeline \"${N[@]}\" --session SESSION_ID --request-id"
      assert recipes["slow request"]["look_for"] =~ "duration_us"

      refute Map.has_key?(recipes["growing mailbox"], "status")
      assert Enum.join(recipes["growing mailbox"]["commands"], " ") =~ "--view-kind process_top"
      assert Enum.join(recipes["growing mailbox"]["commands"], " ") =~ "--watch-process"
      assert recipes["growing mailbox"]["look_for"] =~ "by_message_queue_len"
      assert recipes["memory growth"]["look_for"] =~ "insider_ets_bytes"

      assert Enum.join(recipes["growing mailbox"]["commands"], " ") =~
               "process \"${N[@]}\" --name NAME"

      assert recipes["growing mailbox"]["look_for"] =~ "callers_exited"

      binary = recipes["binary leak"]
      assert Enum.join(binary["commands"], " ") =~ "bin_leak \"${N[@]}\""
      assert Enum.join(binary["commands"], " ") =~ "--view-kind inspect.bin_leak"

      for field <- ["by_retained_bytes", "freed_bytes", "sub-binaries"],
          do: assert(binary["look_for"] =~ field)

      port = recipes["port leak"]
      assert Enum.join(port["commands"], " ") =~ "--top-ports"
      assert Enum.join(port["commands"], " ") =~ "--view-kind port_top"
      assert Enum.join(port["commands"], " ") =~ "ports \"${N[@]}\" --type TYPE"

      for field <- ["by_type", "delta", "port_count_delta", "by_owner", "owner_pid", "os_pid"],
          do: assert(port["look_for"] =~ field)

      unknown = recipes["unknown event names"]
      refute Map.has_key?(unknown, "status")
      assert [discover, start, status] = unknown["commands"]
      assert discover =~ "discover \"${N[@]}\" --prefix"
      assert start =~ "--telemetry-event 'my_app.*'"
      assert status =~ "status \"${N[@]}\""

      for field <- [
            "telemetry_event_prefixes",
            "telemetry_subscriptions",
            "seen 0",
            "check filtered"
          ],
          do: assert(unknown["look_for"] =~ field)

      assert Map.has_key?(full()["bounds"], "telemetry_events_max")
      assert unknown["look_for"] =~ "bounds.telemetry_events_max"

      failing = recipes["failing call"]
      assert hd(failing["commands"]) =~ "--component calls --calls MyApp.Worker.handle_call/3"
      assert List.last(failing["commands"]) =~ "stop \"${N[@]}\""

      for field <- [
            "call.exception",
            "payload.arguments",
            "traced_after 0",
            "calls_max_bytes",
            "call.stopped"
          ],
          do: assert(failing["look_for"] =~ field)
    end

    test "welcome refuses unknown options, and its JSON twin takes the same options" do
      assert {:error, %{"code" => "invalid_options", "field" => "full"}} =
               Live.welcome(%{"full" => 1})

      assert %{"error" => %{"code" => "invalid_options"}} =
               Jason.decode!(Live.JSON.welcome(%{"other" => true}))

      assert %{"ok" => full} = Jason.decode!(Live.JSON.welcome(%{"full" => true}))
      assert full == full()
    end

    test "capabilities report the node's quiet default Telemetry events" do
      assert Live.capabilities()["quiet_default_telemetry_events"] ==
               Live.welcome()["runtime"]["quiet_default_telemetry_events"]
    end
  end

  describe "pairs well with" do
    @tools ["argus", "credo", "observer_cli", "recon", "tidewave"]

    test "both forms name the tools to reach for, when, and how to tell they are there" do
      pairs = Live.welcome()["pairs_with"]
      assert pairs == full()["pairs_with"]
      assert pairs |> Enum.map(& &1["tool"]) |> Enum.sort() == @tools

      for pair <- pairs do
        assert pair["use_for"] =~ ~r/\w/, pair["tool"]
        assert pair["detect"] =~ ~r/\w/, pair["tool"]
      end

      tools = Map.new(pairs, &{&1["tool"], &1})
      assert tools["credo"]["detect"] =~ "mix.lock"
      assert tools["argus"]["detect"] =~ "PATH"
      # The command runs every analysis the row advertises: Argus's default
      # set leaves out effects, ets and exposure.
      assert tools["argus"]["run"] =~ "argus analyze --project beams"
      assert tools["argus"]["run"] =~ "--analyses default,effects,ets,exposure"

      # The agent guide gives the same command.
      guide = File.read!("guides/agents/live-observation.md")
      assert guide =~ "--analyses default,effects,ets,exposure"
      assert tools["argus"]["use_for"] =~ "static"
      assert tools["recon"]["use_for"] =~ "process"
      assert tools["tidewave"]["use_for"] =~ "evaluat"
      assert tools["observer_cli"]["for_agents"] == false
      assert Enum.all?(Map.delete(tools, "observer_cli"), fn {_, t} -> t["for_agents"] end)
    end

    test "the runtime reports which are available on this node, from its code path and PATH" do
      directory =
        Path.join(System.tmp_dir!(), "insider-pairs-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      path = System.get_env("PATH")

      on_exit(fn ->
        Code.delete_path(directory)
        System.put_env("PATH", path)
        File.rm_rf!(directory)
      end)

      # With an empty PATH, only what the test VM's code path holds is
      # available: recon is a test dependency; Credo (dev only), Tidewave
      # and observer_cli are not.
      System.put_env("PATH", directory)
      before = Live.welcome()["runtime"]["pairs_with_available"]

      assert before == %{
               "argus" => false,
               "credo" => false,
               "observer_cli" => false,
               "recon" => true,
               "tidewave" => false
             }

      # A beam on the code path, or an executable on PATH, is detected
      # without loading or running it.
      File.write!(Path.join(directory, "Elixir.Tidewave.beam"), "not loaded")
      argus = Path.join(directory, "argus")
      File.write!(argus, "#!/bin/sh\nexit 1\n")
      File.chmod!(argus, 0o755)
      true = Code.prepend_path(directory)

      now = Live.welcome()["runtime"]["pairs_with_available"]
      assert now == %{before | "argus" => true, "tidewave" => true}
      refute :code.is_loaded(Tidewave)
      assert Live.welcome(%{"full" => true})["runtime"]["pairs_with_available"] == now
    end

    test "a module loaded from a binary counts, as Insider's own --load installs recon" do
      on_exit(fn ->
        :code.purge(:observer_cli)
        :code.delete(:observer_cli)
        :code.purge(:observer_cli)
      end)

      refute Live.welcome()["runtime"]["pairs_with_available"]["observer_cli"]

      # Loaded from a binary, as `:code.load_binary/3` does: no directory on
      # the code path holds its beam.
      [{:observer_cli, binary}] = Code.compile_string("defmodule :observer_cli, do: nil")
      :code.purge(:observer_cli)
      {:module, :observer_cli} = :code.load_binary(:observer_cli, ~c"pushed", binary)
      assert :code.where_is_file(~c"observer_cli.beam") == :non_existing

      assert Live.welcome()["runtime"]["pairs_with_available"]["observer_cli"]
    end
  end

  defp operation(command) do
    [_, operation] = Regex.run(~r/mix insider\.live ([a-z]+)/, command)
    operation
  end

  describe "hash" do
    test "is the SHA-256 of every key except hash, runtime and effective_disclosure" do
      welcome = full()

      assert welcome["schema"] == "insider.live-welcome/v2"

      assert welcome["hash"] ==
               Canonical.sha256(Map.drop(welcome, ["hash", "runtime", "effective_disclosure"]))

      assert Live.capabilities()["welcome"]["hash"] == welcome["hash"]
    end

    test "changes when the documented content changes and not with runtime state" do
      before = full()

      Application.put_env(:insider, :live_telemetry_measurements, [:duration])
      narrowed = full()
      assert narrowed["telemetry_measurements_allowed"] == ["duration"]
      refute narrowed["hash"] == before["hash"]

      Application.put_env(:insider, :live_report_submission, :github)
      submitting = full()
      assert submitting["reports"]["submission"] == "github"
      refute submitting["hash"] == narrowed["hash"]

      Application.delete_env(:insider, :live_telemetry_measurements)
      Application.delete_env(:insider, :live_report_submission)
      assert full()["hash"] == before["hash"]
      assert Live.welcome()["hash"] == before["hash"]

      assert {:ok, %{"session_id" => id}} = Live.start(%{})
      running = Live.welcome()
      assert running["runtime"]["active_session_id"] == id
      assert running["hash"] == before["hash"]
    end
  end

  test "the welcome is plain data, carries the runtime facts, and the JSON form matches" do
    welcome = Live.welcome()

    assert %{
             "node" => node,
             "environment" => "test",
             "allowed" => true,
             "owner_running" => true,
             "active_session_id" => nil
           } = welcome["runtime"]

    assert node == Atom.to_string(node())
    assert welcome["insider"]["version"] == to_string(Application.spec(:insider, :vsn))

    # The suite runs from a Git checkout, so the compiled commit is known.
    assert welcome["insider"]["commit"] == Insider.Live.Revision.commit()
    assert welcome["insider"]["commit"] =~ ~r/\A[0-9a-f]{40}\z/

    assert %{"ok" => decoded} = Jason.decode!(Live.JSON.welcome())
    assert decoded == welcome
  end

  test "the guide gives the exact report commands for both transports" do
    guide = full()["guide"]
    report = Enum.join(guide["report"], "\n")

    assert report =~ "mix insider.live report --category doc_mismatch --message"
    assert report =~ ~s|Insider.Live.JSON.report(%{"category" => "doc_mismatch"|
    assert Enum.all?(["first", "loop", "stop", "report"], &(guide[&1] != []))
  end

  # Every string in a welcome document, map values and list items alike.
  defp strings(text) when is_binary(text), do: [text]
  defp strings(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(_other), do: []
end
