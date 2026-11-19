defmodule Insider.Lab.LiveWelcomeObserverTest do
  # The observer turns this VM into a hidden distributed node for the length
  # of one command, and a VM has one distribution identity, so these tests
  # cannot overlap with each other or with `Insider.Lab.LiveObserverTest`.
  use ExUnit.Case, async: false

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.LivePeer

  @moduletag timeout: 120_000

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-live-welcome-" <> suffix)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    cookie = :"welcome_test_#{System.unique_integer([:positive])}"
    {peer, node} = start_peer(cookie)

    {:ok,
     peer: peer,
     node: node,
     cookie_file: LivePeer.cookie_file(directory, cookie),
     reports: Path.join(directory, "reports")}
  end

  # Distribution is checked only through what each test started: every
  # observer that connected to this test's peer has left it again (checked
  # on the peer, before it stops), and each command leaves this VM's node as
  # it found it. Neither depends on what another test does with distribution.
  defp start_peer(cookie, options \\ []) do
    {peer, node} =
      LivePeer.start(
        cookie,
        Keyword.merge([insider: :started, environment: :development], options)
      )

    on_exit(fn -> LivePeer.stop(peer) end)
    on_exit(fn -> assert LivePeer.observers_left(peer) == [] end)
    {peer, node}
  end

  defp run(arguments, context, options \\ []) do
    owner = self()
    reference = make_ref()
    before = node()

    options =
      Keyword.merge(
        [
          reports_directory: context.reports,
          gh: fn arguments -> flunk("gh must not run: #{inspect(arguments)}") end,
          submission: "manual"
        ],
        options
      )

    status =
      CLI.run(
        arguments,
        fn bytes ->
          send(owner, {reference, IO.iodata_to_binary(bytes)})
          :ok
        end,
        options
      )

    assert node() == before, "the command left this VM distributed as #{node()}"
    assert_received {^reference, line}
    {status, Jason.decode!(line)}
  end

  defp target(context), do: ["--node", context.node, "--cookie-file", context.cookie_file]

  # A quick start command as the shell would pass it, `"${N[@]}"` expanded.
  defp arguments(command) do
    [_, rest] = Regex.run(~r/\A(?:timeout \d+ )?mix insider\.live (.*)\z/, command)

    rest
    |> String.replace("\"${N[@]}\"", "--node NAME@HOST --cookie-file PATH")
    |> OptionParser.split()
  end

  test "trace takes --retain, --values and repeated --values-path; start takes --retain-traces 0" do
    target = ["--node", "n@h", "--cookie-file", "PATH", "--session", "live-1"]

    assert {:ok, %{operation: "trace", arguments: %{options: options}}} =
             CLI.parse(
               ["trace" | target] ++
                 ["--trace-id", String.duplicate("a", 32), "--retain", "--values"] ++
                 ["--values-path", "a.*", "--values-path", "b"]
             )

    assert Map.take(options, ["retain", "values", "values_paths"]) ==
             %{"retain" => true, "values" => true, "values_paths" => ["a.*", "b"]}

    start = ["start", "--node", "n@h", "--cookie-file", "PATH", "--component", "logger"]

    assert {:ok, %{arguments: %{"retain_traces" => 0}}} =
             CLI.parse(start ++ ["--retain-traces", "0"])

    assert {:error, "invalid_options",
            %{"option" => "--retain-traces", "problem" => "out_of_range"}} =
             CLI.parse(start ++ ["--retain-traces", "-1"])
  end

  test "the 5xx recipe's read shows the failing request's events and hides a 2xx", context do
    for segment <- ["phoenix", "endpoint", "stop", "router_dispatch", "exception"],
        do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

    recipe = Enum.find(Insider.Live.Welcome.contract()["recipes"], &(&1["symptom"] =~ "5xx"))
    # The recipe ends with a trace read; this peer has no OpenTelemetry SDK,
    # so the otel component is left out here (the root suite's peer test
    # covers it).
    [start, digest, read, trace] = recipe["commands"]
    assert {:ok, %{operation: "trace"}} = trace |> arguments() |> CLI.parse()
    assert {:ok, %{arguments: start}} = start |> arguments() |> CLI.parse()

    assert {:ok, %{operation: "digest", arguments: %{options: digest}}} =
             digest |> arguments() |> CLI.parse()

    assert {:ok, %{arguments: %{options: view}}} = read |> arguments() |> CLI.parse()
    start = Map.update!(start, "components", &List.delete(&1, "otel"))

    {:ok, %{"session_id" => id}} = :peer.call(context.peer, Insider.Live, :start, [start])

    try do
      emit = fn event, metadata ->
        :ok =
          :peer.call(context.peer, :telemetry, :execute, [event, %{duration: 1_000}, metadata])
      end

      emit.([:phoenix, :endpoint, :stop], %{conn: %{status: 200}})
      emit.([:phoenix, :router_dispatch, :exception], %{kind: :error, reason: :boom})
      emit.([:phoenix, :endpoint, :stop], %{conn: %{status: 500}})

      {:ok, batch} = :peer.call(context.peer, Insider.Live, :events_since, [id, 0, view])

      shown = Enum.map(batch["events"], &{&1["event"]["kind"], &1["event"]["severity"]})

      assert shown == [
               {"phoenix.router_dispatch.exception", "error"},
               {"phoenix.endpoint.stop", "error"}
             ]

      assert batch["filtered"]["view"]["min_severity"] == 1

      # The recipe's digest groups the two failures by kind and status.
      {:ok, digested} = :peer.call(context.peer, Insider.Live, :digest, [id, digest])
      signatures = Enum.map(digested["error_signatures"], & &1["signature"])
      assert "phoenix.endpoint.stop status=500" in signatures

      assert Enum.any?(
               signatures,
               &String.starts_with?(&1, "phoenix.router_dispatch.exception error")
             ),
             inspect(signatures)

      assert digested["counts"]["by_severity"] == %{"error" => 2, "info" => 1}
    after
      :peer.call(context.peer, Insider.Live, :stop, [id])
    end
  end

  test "the quick start's start and watch commands show an ordinary recorded duration event",
       context do
    for segment <- ["insider_lab", "quickstart", "stop"],
        do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

    [start, digest, _events, watch | _rest] =
      Insider.Live.Welcome.contract()["quick_start"]["commands"]

    assert {:ok, %{operation: "digest", arguments: %{options: digest}}} =
             digest |> arguments() |> CLI.parse()

    assert {:ok, %{arguments: start}} =
             start
             |> String.replace("EVENT", "insider_lab.quickstart.stop")
             |> arguments()
             |> CLI.parse()

    assert {:ok, %{operation: "watch", arguments: %{options: view}}} =
             watch |> arguments() |> CLI.parse()

    {:ok, %{"session_id" => id}} = :peer.call(context.peer, Insider.Live, :start, [start])

    try do
      duration = System.convert_time_unit(200, :millisecond, :native)

      :ok =
        :peer.call(context.peer, :telemetry, :execute, [
          [:insider_lab, :quickstart, :stop],
          %{duration: duration},
          %{}
        ])

      {:ok, batch} = :peer.call(context.peer, Insider.Live, :events_since, [id, 0, view])

      assert [%{"event" => event}] =
               Enum.filter(
                 batch["events"],
                 &(&1["event"]["kind"] == "insider_lab.quickstart.stop")
               )

      assert event["severity"] == "info"
      assert event["attributes"]["measurements"]["duration"] == duration
      assert batch["filtered"]["view"] == %{}

      # The quick start's digest reports the event's duration in microseconds.
      {:ok, digested} = :peer.call(context.peer, Insider.Live, :digest, [id, digest])

      assert [%{"kind" => "insider_lab.quickstart.stop", "count" => 1, "p95_us" => 200_000}] =
               digested["latency"]
    after
      :peer.call(context.peer, Insider.Live, :stop, [id])
    end
  end

  # After the growing-mailbox recipe set
  # Poller options, the missing-values recipe's amendment, which names the
  # components it wants, still applies; and an amendment around the Poller
  # can return its options to their defaults with --reset.
  test "the missing-values amendment applies after the growing-mailbox recipe", context do
    for segment <- ["insider_lab", "recipes", "stop"],
        do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

    recipes = Insider.Live.Welcome.contract()["recipes"]
    mailbox = Enum.find(recipes, &(&1["symptom"] =~ "growing mailbox"))
    missing = Enum.find(recipes, &(&1["symptom"] =~ "missing values"))
    parse = &(&1 |> String.replace("NAME", "code_server") |> arguments() |> CLI.parse())

    [start, _digest, _events, amend_watch, _watch_events, _process] = mailbox["commands"]
    assert {:ok, %{arguments: start}} = parse.(start)
    {:ok, %{"session_id" => id}} = :peer.call(context.peer, Insider.Live, :start, [start])

    try do
      amend = fn command ->
        {:ok, %{operation: "amend", arguments: %{options: options}}} = parse.(command)
        :peer.call(context.peer, Insider.Live, :amend, [id, options])
      end

      assert {:ok, %{"poller" => %{"watch_processes" => ["code_server"], "interval_ms" => 1_000}}} =
               amend.(amend_watch)

      assert {:ok, %{"poller" => %{"watch_processes" => [], "interval_ms" => 5_000}}} =
               amend.(
                 "mix insider.live amend \"${N[@]}\" --session S --reset watch-process --reset poller-interval-ms"
               )

      assert {:ok, _watching} = amend.(amend_watch)

      # --reset component returns the components to
      # their defaults, without the poller, and the kept poller options go
      # with it; adding the poller back starts from its defaults.
      assert {:ok, %{"components" => components, "poller" => nil}} =
               amend.("mix insider.live amend \"${N[@]}\" --session S --reset component")

      refute "poller" in components

      assert {:ok, %{"poller" => %{"watch_processes" => [], "interval_ms" => 5_000}}} =
               amend.(
                 "mix insider.live amend \"${N[@]}\" --session S --component logger --component poller"
               )

      assert {:ok, _watching} = amend.(amend_watch)

      [_measurement, components, _read] = missing["commands"]

      assert {:ok, amended} =
               components |> String.replace("EVENT", "insider_lab.recipes.stop") |> amend.()

      assert %{"components" => ["logger", "telemetry"], "poller" => nil} = amended
      assert amended["amendment"]["applied"]
    after
      :peer.call(context.peer, Insider.Live, :stop, [id, %{"force" => true}])
    end
  end

  test "a welcome that could not be written is delivered again by the next command", context do
    options = [
      reports_directory: context.reports,
      gh: fn _ -> flunk("gh") end,
      submission: "manual"
    ]

    assert 70 = CLI.run(["capabilities" | target(context)], fn _bytes -> :error end, options)

    {0, next} = run(["capabilities" | target(context)], context)

    assert %{"schema" => "insider.live-welcome-quick-start/v1", "quick_start" => %{}} =
             next["welcome"]

    {0, after_delivery} = run(["capabilities" | target(context)], context)
    assert after_delivery["welcome"]["delivered"] == true
  end

  test "the first command against a target carries the quick start, later ones none",
       context do
    {0, first} = run(["capabilities" | target(context)], context)

    assert first["result"]["schema"] == "insider.live-capabilities/v1"

    assert %{
             "schema" => "insider.live-welcome-quick-start/v1",
             "quick_start" => %{"steps" => [_ | _], "commands" => [_ | _]},
             "recipes" => [_ | _],
             "full_reference" => %{"observer" => full},
             "runtime" => %{"node" => node, "quiet_default_telemetry_events" => []}
           } = first["welcome"]

    assert full =~ "welcome --node NAME@HOST --cookie-file PATH --full"
    assert node == context.node
    refute Map.has_key?(first["welcome"], "operations")
    assert first["welcome"]["hash"] == first["result"]["welcome"]["hash"]
    assert first["result"]["quiet_default_telemetry_events"] == []

    {1, second} = run(["status", "--session", "live-none" | target(context)], context)
    assert second["error"]["code"] == "unknown_session"
    refute Map.has_key?(second, "welcome")

    # Only capabilities, the discovery command, keeps a pointer with the
    # delivered hash.
    {0, third} = run(["capabilities" | target(context)], context)

    assert %{"delivered" => true, "hash" => hash, "read_with" => %{"observer" => _}} =
             third["welcome"]

    assert hash == first["welcome"]["hash"]
    # The pointer advertises the schema its read command returns.
    assert third["welcome"]["schema"] == first["welcome"]["schema"]
    assert third["welcome"]["full_reference"]["schema"] == "insider.live-welcome/v2"
    refute Map.has_key?(third["welcome"], "quick_start")

    {0, explicit} = run(["welcome" | target(context)], context)
    refute Map.has_key?(explicit, "welcome")
  end

  test "receipts neither carry nor deliver the quick start, and carry a short installation",
       context do
    {:ok, %{"session_id" => id}} =
      :peer.call(context.peer, Insider.Live, :start, [%{"components" => ["logger"]}])

    try do
      session = ["--session", id | target(context)]

      # A receipt as the first command: no welcome, and nothing delivered.
      for receipt <- [["mark", "--label", "first"], ["renew"], ["amend", "--component", "logger"]] do
        {0, document} = run(receipt ++ session, context)
        refute Map.has_key?(document, "welcome"), "#{hd(receipt)} carried a welcome"
        assert_short_installation(document)
      end

      # The next command that needs it carries the quick start.
      {0, read} = run(["events", "--cursor", "0" | session], context)

      assert %{"schema" => "insider.live-welcome-quick-start/v1", "quick_start" => _} =
               read["welcome"]

      assert_short_installation(read)

      # After delivery, neither receipts nor reads carry a welcome or a pointer.
      for later <- [
            ["mark", "--label", "after"],
            ["amend", "--component", "logger"],
            ["events", "--cursor", "latest"]
          ] do
        {0, document} = run(later ++ session, context)
        refute Map.has_key?(document, "welcome"), "#{hd(later)} carried a welcome"
        assert_short_installation(document)
      end

      # capabilities keeps its pointer and the full installation.
      {0, capabilities} = run(["capabilities" | target(context)], context)
      assert %{"delivered" => true, "hash" => hash} = capabilities["welcome"]
      assert hash == read["welcome"]["hash"]

      assert %{"action" => "none", "same_build" => true, "observer_build" => _} =
               capabilities["installation"]

      {0, stopped} = run(["stop" | session], context)
      refute Map.has_key?(stopped, "welcome")
      assert_short_installation(stopped)
    after
      :peer.call(context.peer, Insider.Live, :stop, [id, %{"force" => true}])
    end
  end

  # Every observer document but capabilities, a load, or another build
  # carries only this summary of the installation.
  defp assert_short_installation(document) do
    installation = document["installation"]

    assert Enum.sort(Map.keys(installation)) == [
             "insider_commit",
             "insider_version",
             "same_build"
           ]

    assert installation["same_build"] == true
    assert installation["insider_commit"] == Insider.Live.Revision.commit()
  end

  test "after welcome, the next command carries only a pointer", context do
    {0, printed} = run(["welcome" | target(context)], context)
    assert %{"quick_start" => _, "hash" => hash} = printed["result"]

    {0, next} = run(["capabilities" | target(context)], context)
    assert %{"delivered" => true, "hash" => ^hash} = next["welcome"]
    refute Map.has_key?(next["welcome"], "quick_start")
  end

  test "welcome --full prints the whole reference and counts as delivery", context do
    {0, printed} = run(["welcome", "--full" | target(context)], context)
    full = printed["result"]

    assert %{"schema" => "insider.live-welcome/v2", "operations" => [_ | _], "guide" => _} = full
    assert full["hash"] == :peer.call(context.peer, Insider.Live.Welcome, :hash, [])

    options = full["transports"]["observer"]["options"]
    assert options["--logger-include"]["value"] =~ "module:NAME"
    assert options["--logger-include"]["sets"] == "start.logger_include"
    assert full["errors"]["observer"]["codes"]["invalid_options"]["exit"] == 64

    {0, next} = run(["capabilities" | target(context)], context)
    assert next["welcome"]["delivered"] == true
  end

  test "each target node gets its own first delivery, and so does a restarted one", context do
    {0, first} = run(["capabilities" | target(context)], context)
    assert %{"quick_start" => _} = first["welcome"]

    other_cookie = :"welcome_other_#{System.unique_integer([:positive])}"

    {other_peer, other} = start_peer(other_cookie)

    other_directory = Path.dirname(context.cookie_file) |> Path.join("other")
    File.mkdir_p!(other_directory)

    other_target = [
      "--node",
      other,
      "--cookie-file",
      LivePeer.cookie_file(other_directory, other_cookie)
    ]

    {0, elsewhere} = run(["capabilities" | other_target], context)
    assert %{"quick_start" => _, "runtime" => %{"node" => ^other}} = elsewhere["welcome"]

    # The same name after a restart is a new incarnation and is welcomed again.
    [name, _host] = String.split(other, "@")
    LivePeer.stop(other_peer)

    {_again_peer, ^other} = start_peer(other_cookie, name: String.to_atom(name))

    {0, restarted} = run(["capabilities" | other_target], context)
    assert %{"quick_start" => _} = restarted["welcome"]

    {0, later} = run(["capabilities" | other_target], context)
    assert later["welcome"]["delivered"] == true
  end

  test "a delivery record without the node's incarnation is welcomed again", context do
    File.mkdir_p!(context.reports)

    File.write!(
      Path.join(context.reports, "welcomed.json"),
      Jason.encode!(%{"node" => context.node, "hash" => String.duplicate("a", 64)}) <> "\n"
    )

    {0, first} = run(["capabilities" | target(context)], context)
    assert %{"quick_start" => _} = first["welcome"]
  end

  test "welcome prints the target's document, and capabilities point to it", context do
    {0, document} = run(["welcome" | target(context)], context)

    welcome = document["result"]
    assert document["operation"] == "welcome"
    assert welcome["schema"] == "insider.live-welcome-quick-start/v1"
    assert welcome["runtime"]["node"] == context.node
    assert welcome["runtime"]["environment"] == "development"
    assert welcome["hash"] == :peer.call(context.peer, Insider.Live.Welcome, :hash, [])

    {0, capabilities} = run(["capabilities" | target(context)], context)
    pointer = capabilities["result"]["welcome"]

    assert pointer["hash"] == welcome["hash"]
    assert pointer["read_with"]["observer"] =~ "mix insider.live welcome"
    assert pointer["full_reference"]["observer"] =~ "--full"

    # The printed welcome was the delivery: capabilities carry only a pointer.
    assert %{"delivered" => true} = capabilities["welcome"]

    {0, filed} =
      run(["report", "--category", "doc_mismatch", "--message", "after welcome"], context)

    assert %{
             "welcome_hash" => hash,
             "node" => node,
             "environment" => "development",
             "last_operation" => "capabilities",
             "last_error_code" => nil
           } = filed["result"]["report"]["context"]

    assert hash == welcome["hash"]
    assert node == context.node
  end

  # The target writes its commands as `mix insider.live …`; the escript prints
  # them as `insider-lab live …`, and leaves the sentences about the Mix task.
  test "the escript prints the target's commands in the form it was run with", context do
    escript = [invocation: "insider-lab live"]

    {0, document} = run(["welcome" | target(context)], context, escript)
    quick_start = document["result"]["quick_start"]

    assert String.starts_with?(quick_start["load"], "insider-lab live capabilities ")

    for command <- quick_start["commands"] do
      assert command =~ "insider-lab live ", command
      refute command =~ "mix insider.live", command
    end

    [step | _steps] = quick_start["steps"]
    assert step =~ "then run insider-lab live in place of mix insider.live, from any directory"
    assert step =~ "In an Insider checkout: run mix insider.live from tools/insider_lab"

    {0, capabilities} = run(["capabilities" | target(context)], context, escript)
    pointer = capabilities["result"]["welcome"]
    assert String.starts_with?(pointer["read_with"]["observer"], "insider-lab live welcome ")

    {:ok, %{"session_id" => id}} =
      :peer.call(context.peer, Insider.Live, :start, [%{"components" => ["logger"]}])

    mark = ["mark" | target(context)] ++ ["--session", id, "--label", "before"]

    {0, marked} = run(mark, context, escript)

    assert marked["result"]["next"] ==
             ~s(insider-lab live digest "${N[@]}" --session #{id} --since-mark --human)

    {0, marked} = run(mark, context)

    assert marked["result"]["next"] ==
             ~s(mix insider.live digest "${N[@]}" --session #{id} --since-mark --human)
  end

  test "the escript leaves a mark label, captured events and keys as the node wrote them",
       context do
    escript = [invocation: "insider-lab live"]
    captured = "mix insider.live start"

    {:ok, %{"session_id" => id}} =
      :peer.call(context.peer, Insider.Live, :start, [%{"components" => ["logger"]}])

    session = target(context) ++ ["--session", id]

    {0, marked} = run(["mark" | session] ++ ["--label", captured], context, escript)
    assert marked["result"]["mark"]["label"] == captured
    assert "insider-lab live digest " <> _ = marked["result"]["next"]

    :ok = :peer.call(context.peer, :logger, :error, [captured, %{captured => "metadata value"}])

    # The label the mark returned finds it again.
    {0, digest} = run(["digest" | session] ++ ["--since-mark", captured], context, escript)
    assert digest["status"] == "ok"
    assert digest["result"]["window"]["mark"]["label"] == captured

    {0, read} = run(["events" | session] ++ ["--cursor", "0"], context, escript)
    [event] = Enum.filter(read["result"]["events"], &(&1["event"]["severity"] == "error"))
    assert event["event"]["payload"]["message"] == captured
  end

  test "reports with a target copies the node's queue, and its config can opt in", context do
    :ok =
      :peer.call(context.peer, Application, :put_env, [:insider, :live_report_submission, :github])

    {:ok, receipt} =
      :peer.call(context.peer, Insider.Live, :report, [
        %{"category" => "missing_capability", "message" => "filed from a project_eval"}
      ])

    assert receipt["report"]["context"]["transport"] == "node"

    {0, listed} = run(["reports" | target(context)], context)
    result = listed["result"]

    assert result["imported_from_target"] == %{
             "records" => 1,
             "new_occurrences" => 1,
             "invalid" => 0
           }

    assert result["target_submission"] == "github"

    assert [%{"message" => "filed from a project_eval", "context" => %{"transport" => "node"}}] =
             result["reports"]

    # Copying again does not count the same report twice.
    {0, again} = run(["reports" | target(context)], context)
    assert [%{"count" => 1}] = again["result"]["reports"]
    assert again["result"]["imported_from_target"]["new_occurrences"] == 0

    owner = self()

    gh = fn arguments ->
      send(owner, {:gh, arguments})

      case arguments do
        ["issue", "list" | _rest] -> {"[]", 0}
        ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/9", 0}
      end
    end

    {0, submitted} = run(["reports", "submit" | target(context)], context, gh: gh)
    assert submitted["result"]["opt_in"] == "target_config"
    assert [%{"action" => "created"}] = submitted["result"]["results"]
    assert_received {:gh, ["issue", "create" | _arguments]}
  end
end
