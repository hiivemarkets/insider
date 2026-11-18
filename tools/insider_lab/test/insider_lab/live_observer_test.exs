defmodule Insider.Lab.LiveObserverTest do
  # The observer turns this VM into a hidden distributed node for the length
  # of one command, and a VM has exactly one distribution identity, so these
  # tests cannot overlap with each other.
  use ExUnit.Case, async: false

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Help
  alias Insider.Lab.Live.Watch
  alias Insider.Lab.LivePeer

  @moduletag timeout: 120_000
  @logger_session ["--component", "logger"]

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-live-observer-" <> suffix)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    cookie = :"observer_test_#{System.unique_integer([:positive])}"
    {:ok, cookie: cookie, cookie_file: LivePeer.cookie_file(directory, cookie)}
  end

  # Distribution is checked only through what each test started: every
  # observer that connected to this test's peer has left it again (checked
  # on the peer, before it stops), and each command leaves this VM's node as
  # it found it. Neither depends on what another test does with distribution.
  defp start_peer(cookie, options) do
    {peer, node} = LivePeer.start(cookie, options)
    on_exit(fn -> LivePeer.stop(peer) end)
    on_exit(fn -> assert LivePeer.observers_left(peer) == [] end)
    {peer, node}
  end

  defp observe(arguments) do
    owner = self()
    reference = make_ref()
    before = node()

    status =
      CLI.run(arguments, fn bytes ->
        send(owner, {reference, IO.iodata_to_binary(bytes)})
        :ok
      end)

    assert node() == before, "the command left this VM distributed as #{node()}"
    {status, collect(reference)}
  end

  defp collect(reference, lines \\ []) do
    receive do
      {^reference, line} -> collect(reference, [line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.map(&decode_line/1)
    end
  end

  defp decode_line(line) do
    assert String.ends_with?(line, "\n")
    Jason.decode!(line)
  end

  defp single(arguments) do
    {status, [document]} = observe(arguments)
    {status, document}
  end

  # A command whose output is text: everything it wrote, unparsed.
  defp observe_raw(arguments) do
    owner = self()
    reference = make_ref()

    status =
      CLI.run(arguments, fn bytes ->
        send(owner, {reference, IO.iodata_to_binary(bytes)})
        :ok
      end)

    {status, reference |> drain_raw([]) |> Enum.join()}
  end

  defp drain_raw(reference, chunks) do
    receive do
      {^reference, chunk} -> drain_raw(reference, [chunk | chunks])
    after
      0 -> Enum.reverse(chunks)
    end
  end

  defp target(node, cookie_file, extra \\ []),
    do: ["--node", node, "--cookie-file", cookie_file] ++ extra

  # The installation fields every observer document carries; the whole
  # report only on capabilities, a load, or another build.
  defp short_installation, do: ["insider_commit", "insider_version", "same_build"]

  describe "against a peer running Insider" do
    setup %{cookie: cookie} do
      {peer, node} = start_peer(cookie, insider: :started, environment: :development)
      {:ok, peer: peer, node: node}
    end

    test "connects as a hidden observer and reports the target's live capabilities", context do
      {status, document} = single(["capabilities" | target(context.node, context.cookie_file)])

      assert status == 0
      assert document["schema"] == "insider.live-observer/v1"
      assert document["status"] == "ok"
      assert document["target"] == context.node
      # capabilities carries the whole installation report.
      assert %{"action" => "none", "same_build" => true, "pushed_applications" => []} =
               document["installation"]

      assert document["installation"]["observer_build"] ==
               document["installation"]["target_build"]

      assert document["result"]["schema"] == "insider.live-capabilities/v1"
      assert document["result"]["environment"] == "development"
      assert document["result"]["insider_version"] == document["installation"]["insider_version"]

      # The observer joined hidden and left: the target saw no visible node.
      assert :peer.call(context.peer, Node, :list, []) == []
      assert :peer.call(context.peer, Node, :list, [:hidden]) == []
    end

    test "starts a session, reads its events after a cursor, and stops it", context do
      {0, started} =
        single(["start" | target(context.node, context.cookie_file, @logger_session)])

      session = started["result"]["session_id"]
      assert started["result"]["state"] == "running"
      assert started["result"]["components"] == ["logger"]

      :ok = :peer.call(context.peer, :logger, :error, ["observer round trip marker"])

      {0, read} =
        single([
          "events"
          | target(context.node, context.cookie_file, ["--session", session, "--cursor", "0"])
        ])

      events = read["result"]["events"]
      assert read["result"]["session_id"] == session
      assert read["result"]["next_cursor"] > 0
      assert Enum.any?(events, &logged_error?/1)

      # Reading past the returned cursor yields nothing older.
      {0, again} =
        single([
          "events"
          | target(context.node, context.cookie_file, [
              "--session",
              session,
              "--cursor",
              Integer.to_string(read["result"]["next_cursor"])
            ])
        ])

      refute Enum.any?(again["result"]["events"], &logged_error?/1)

      {0, stopped} =
        single(["stop" | target(context.node, context.cookie_file, ["--session", session])])

      assert stopped["result"]["state"] == "stopped"
      assert %{"schema" => "insider.collector-session-receipt/v1"} = stopped["result"]["receipt"]

      {0, after_stop} =
        single(["status" | target(context.node, context.cookie_file, ["--session", session])])

      assert after_stop["result"]["state"] == "stopped"
      assert after_stop["result"]["subscribers"] == 0
    end

    test "a target error keeps the target's own code", context do
      {1, document} =
        single([
          "status" | target(context.node, context.cookie_file, ["--session", "no-such-session"])
        ])

      assert document["status"] == "error"
      assert document["error"]["source"] == "target"
      assert document["error"]["schema"] == "insider.live-error/v1"
      assert document["error"]["code"] == "unknown_session"
    end

    test "watch prints pushed batches and ends cleanly when the target dies", context do
      session = start_session(context)
      {_watcher, reference} = start_watch(context, session)

      assert_receive {^reference, %{"kind" => "subscribed"}}, 10_000

      :ok = :peer.call(context.peer, :logger, :error, ["observer watch marker"])
      assert_receive {^reference, %{"kind" => "batch"} = batch}, 10_000
      assert batch["result"]["session_id"] == session
      assert batch["result"]["state"] == "running"
      assert Enum.any?(batch["result"]["events"], &logged_error?/1)

      LivePeer.stop(context.peer)

      assert_receive {^reference, %{"status" => "error", "error" => %{"code" => "target_down"}}},
                     15_000

      assert_receive {^reference, {:exit, 1}}, 1_000
    end

    test "watch unsubscribes when interrupted", context do
      session = start_session(context)
      {watcher, reference} = start_watch(context, session)

      assert_receive {^reference, %{"kind" => "subscribed"}}, 10_000

      assert {:ok, %{"subscribers" => 1}} =
               :peer.call(context.peer, Insider.Live, :status, [session])

      send(watcher, Watch.stop_message())

      assert_receive {^reference, %{"kind" => "stopped", "reason" => "interrupted"}}, 15_000
      assert_receive {^reference, {:exit, 0}}, 1_000

      assert {:ok, %{"subscribers" => 0}} =
               :peer.call(context.peer, Insider.Live, :status, [session])

      {0, _stopped} =
        single(["stop" | target(context.node, context.cookie_file, ["--session", session])])
    end

    test "watch ends with the session and keeps a short lease alive until then", context do
      session = start_session(context, ["--lease-ms", "1000"])
      {_watcher, reference} = start_watch(context, session)

      assert_receive {^reference, %{"kind" => "subscribed"}}, 10_000

      # Real time must pass for a lease to lapse: three lease lengths later
      # the session is still running only because the watcher renewed it.
      Process.sleep(3_000)

      assert {:ok, %{"state" => "running"}} =
               :peer.call(context.peer, Insider.Live, :status, [session])

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])

      assert_receive {^reference, %{"kind" => "batch", "result" => %{"state" => "stopped"}}},
                     15_000

      assert_receive {^reference, %{"kind" => "stopped", "reason" => "session_ended"} = final},
                     1_000

      assert final["state"] == "stopped"
      assert_receive {^reference, {:exit, 0}}, 1_000
    end

    # Watch once replayed from cursor 0, had no bound, and
    # repeated the installation block on every line; nothing named the
    # newest receipt to tail from.
    test "watch tails from the newest receipt, sends the envelope once, and stops at --max-events",
         context do
      session = start_session(context)
      for index <- 1..2, do: :peer.call(context.peer, :logger, :error, ["history #{index}"])

      {0, tail} =
        single([
          "events"
          | target(context.node, context.cookie_file, ["--session", session, "--cursor", "latest"])
        ])

      latest = tail["result"]["next_cursor"]
      assert latest > 0
      assert %{"cursor" => ^latest, "events" => []} = tail["result"]

      {0, status} =
        single(["status" | target(context.node, context.cookie_file, ["--session", session])])

      assert status["result"]["next_receipt"] == latest
      assert %{"retained_events" => retained} = status["result"]["recorder"]
      assert retained >= 2

      {_watcher, reference} =
        start_watch(context, session, [
          "--from-cursor",
          "latest",
          "--max-events",
          "2",
          "--view-min-severity",
          "error"
        ])

      assert_receive {^reference, %{"kind" => "subscribed"} = subscribed}, 10_000

      assert %{"schema" => "insider.live-observer/v1", "installation" => installation} =
               subscribed

      # The envelope carries only the installation summary and, after delivery, no welcome.
      assert Enum.sort(Map.keys(installation)) == short_installation()
      refute Map.has_key?(subscribed, "welcome")
      assert %{"cursor" => ^latest, "max_events" => 2} = subscribed["subscription"]

      for index <- 1..3, do: :peer.call(context.peer, :logger, :error, ["live #{index}"])

      {batches, stopped} = await_stopped(reference)
      assert %{"reason" => "max_events", "events" => 2} = stopped

      # The stream keeps the shape the decision record fixes, pinned by the
      # serialized fixture: the envelope on the first line only. The fixture
      # is itself a complete stream: contiguous batches whose events and end
      # are what its stopped line reports.
      [fixture_subscribed, fixture_batch, fixture_stopped] = watch_stream_fixture()
      assert fixture_batch["result"]["cursor"] == fixture_subscribed["subscription"]["cursor"]
      assert length(fixture_batch["result"]["events"]) == fixture_stopped["events"]
      assert fixture_batch["result"]["next_cursor"] == fixture_stopped["next_cursor"]
      assert fixture_stopped["events"] == fixture_subscribed["subscription"]["max_events"]

      # Its events are complete `insider.event/v1` envelopes that decode and
      # round-trip through `Insider.Event`.
      for %{"event" => event} <- fixture_batch["result"]["events"] do
        assert {:ok, decoded} = Insider.Event.decode_map(event)
        assert Insider.Event.to_wire_map(decoded) == event
      end

      covered = fixture_stopped["next_cursor"] - fixture_batch["result"]["cursor"]
      hidden = Enum.sum(Map.values(fixture_batch["result"]["filtered"]["view"]))
      assert covered == fixture_stopped["events"] + hidden

      assert keys(subscribed) == keys(fixture_subscribed)
      assert keys(subscribed["subscription"]) == keys(fixture_subscribed["subscription"])
      assert keys(subscribed["installation"]) == keys(fixture_subscribed["installation"])
      assert keys(stopped) == keys(fixture_stopped)

      for batch <- batches do
        assert keys(batch) == keys(fixture_batch)
        assert keys(batch["result"]) == keys(fixture_batch["result"])
      end

      results = Enum.map(batches, & &1["result"])
      assert hd(results)["cursor"] == latest

      for {previous, batch} <- Enum.zip(results, tl(results)),
          do: assert(batch["cursor"] == previous["next_cursor"])

      assert results |> Enum.flat_map(& &1["events"]) |> Enum.count(&logged_error?/1) == 2
      assert stopped["next_cursor"] == List.last(results)["next_cursor"]
      assert_receive {^reference, {:exit, 0}}, 1_000

      assert {:ok, %{"subscribers" => 0}} =
               :peer.call(context.peer, Insider.Live, :status, [session])
    end

    test "watch --for ends at the deadline and reports where to resume", context do
      session = start_session(context)
      {_watcher, reference} = start_watch(context, session, ["--for", "300ms"])

      assert_receive {^reference, %{"kind" => "subscribed"} = subscribed}, 10_000
      assert subscribed["subscription"]["cursor"] == 0

      {batches, stopped} = await_stopped(reference)
      assert %{"reason" => "duration", "events" => 0} = stopped

      resume =
        case batches do
          [] -> 0
          _sent -> List.last(batches)["result"]["next_cursor"]
        end

      assert stopped["next_cursor"] == resume
      assert_receive {^reference, {:exit, 0}}, 1_000

      {0, _stopped} =
        single(["stop" | target(context.node, context.cookie_file, ["--session", session])])
    end

    test "events prints a lean envelope by default, every field with --format full, and one line per event with compact",
         context do
      session = start_session(context)
      :ok = :peer.call(context.peer, :logger, :error, ["format marker"])

      read = [
        "events"
        | target(context.node, context.cookie_file, ["--session", session, "--cursor", "0"])
      ]

      {0, lean} = single(read)
      {0, full} = single(read ++ ["--format", "full"])

      assert [%{"event" => lean_event} | _rest] =
               Enum.filter(lean["result"]["events"], &logged_error?/1)

      assert [%{"event" => full_event} | _rest] =
               Enum.filter(full["result"]["events"], &logged_error?/1)

      for field <- [
            "schema",
            "boot_id",
            "clock_id",
            "authority",
            "monotonic_time",
            "causality",
            "extensions"
          ] do
        refute Map.has_key?(lean_event, field), field
        assert Map.has_key?(full_event, field), field
      end

      assert lean_event["wall_time"] == full_event["wall_time"]
      assert lean["result"]["next_cursor"] == full["result"]["next_cursor"]
      assert full["result"]["disclosure_profile"] == "rich"

      {0, text} = observe_raw(read ++ ["--format", "compact", "--view-min-severity", "error"])
      lines = String.split(text, "\n", trim: true)

      assert Enum.any?(
               lines,
               &(&1 =~
                   ~r/^\d+ \d\d:\d\d:\d\d\.\d{3} logger logger_message error <[\d.]+> .*"format marker"/)
             )

      assert List.last(lines) =~
               ~r/^# batch cursor=0 next_cursor=\d+ .*disclosure=rich gaps=none filtered=/

      {64, invalid} = single(read ++ ["--format", "yaml"])
      assert %{"option" => "--format", "problem" => "malformed"} = invalid["error"]["details"]
      assert invalid["error"]["details"]["expected"] =~ "json | compact | full"
    end

    test "digest summarises the session as JSON, and --human as plain text for the developer",
         context do
      session = start_session(context)

      for index <- 1..3,
          do: :peer.call(context.peer, :logger, :error, ["checkout failed for order #{index}"])

      digest = ["digest" | target(context.node, context.cookie_file, ["--session", session])]

      {0, document} = single(digest)

      assert %{"schema" => "insider.live-digest/v1", "session_id" => ^session} =
               document["result"]

      assert document["result"]["counts"]["by_severity"]["error"] >= 3
      # Without --since the window is the last minute, and says so.
      assert %{"since" => "latest-60s", "age_ms" => age} = document["result"]["window"]
      assert is_integer(age) and age < 60_000
      # One signature for the three messages that differ only in a number.
      signatures = document["result"]["error_signatures"]

      assert {"logger_message checkout failed for order N", 3} in Enum.map(
               signatures,
               &{&1["signature"], &1["count"]}
             )

      {0, text} = observe_raw(digest ++ ["--since", "latest-2", "--human"])
      assert text =~ "Insider digest of #{session} on #{context.node} (rich disclosure): receipts"
      assert text =~ "Top errors: "
      assert text =~ "\nWindow: the newest 2 receipts, up to receipt "
      refute String.starts_with?(text, "{")

      {0, recent} = observe_raw(digest ++ ["--since", "latest-5m", "--human"])

      assert recent =~
               ~r/\nWindow: the last 5 min \(since \d\d:\d\d:\d\d UTC\), up to receipt \d+; newest event [\d.]+ s ago\.\n/

      {1, invalid} = single(digest ++ ["--since", "latest-0"])

      assert %{"source" => "target", "code" => "invalid_options", "option" => "--since"} =
               invalid["error"]

      assert invalid["error"]["expected"] =~ "latest-N"
      assert invalid["error"]["expected"] =~ "latest-DURATION"
    end

    # Agents read without --session and got "no default session". A read
    # without --session reads the node's one active session. With none, it
    # says so.
    test "without --session a read uses the node's active session, and says when there is none",
         context do
      session = start_session(context)

      {0, status} =
        single(["status" | target(context.node, context.cookie_file, ["--reader", "agent-a"])])

      assert status["result"]["session_id"] == session

      {0, text} = observe_raw(["digest" | target(context.node, context.cookie_file, ["--human"])])
      assert text =~ "Insider digest of #{session}"

      # An owner that cannot answer is not "no session".
      owner = :peer.call(context.peer, Process, :whereis, [Insider.Live.Owner])
      :ok = :peer.call(context.peer, :sys, :suspend, [owner])

      try do
        {1, unknown} = single(["status" | target(context.node, context.cookie_file)])

        assert %{
                 "source" => "target",
                 "code" => "unavailable",
                 "reason" => "active_session_unknown"
               } =
                 unknown["error"]
      after
        :ok = :peer.call(context.peer, :sys, :resume, [owner])
      end

      {0, _stopped} =
        single([
          "stop" | target(context.node, context.cookie_file, ["--session", session, "--force"])
        ])

      {64, missing} = single(["status" | target(context.node, context.cookie_file)])

      assert %{"code" => "invalid_options", "details" => %{"option" => "--session"} = details} =
               missing["error"]

      assert details["active_session_id"] == nil
      assert details["expected"] =~ "no session is active on the node"
    end

    # The chart for the partnered programmer: one self-contained page, read
    # with its own reader.
    test "chart writes one private self-contained page and moves no other reader's cursor",
         context do
      session = start_session(context)

      on = fn extra ->
        target(context.node, context.cookie_file, ["--session", session | extra])
      end

      {0, _joined} = single(["events" | on.(["--cursor", "latest", "--reader", "agent-a"])])
      {0, before} = single(["status" | on.([])])
      agent = Enum.find(before["result"]["readers"], &(&1["name"] == "agent-a"))

      {0, _marked} = single(["mark" | on.(["--label", "about to <click> Confirm"])])

      for index <- 1..3,
          do: :peer.call(context.peer, :logger, :error, ["checkout failed for order #{index}"])

      path =
        Path.join(
          System.tmp_dir!(),
          "insider-chart-test-#{System.unique_integer([:positive])}.html"
        )

      on_exit(fn -> File.rm(path) end)

      {0, written} = single(["chart" | on.(["--since-mark", "--out", path])])

      assert %{"schema" => "insider.live-chart/v1", "path" => ^path, "session_id" => ^session} =
               written["result"]

      assert "errors" in written["result"]["series"]
      assert String.starts_with?(written["result"]["reader"], "chart-")
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      page = File.read!(path)
      assert page =~ "<!doctype html>"
      assert page =~ "about to &lt;click&gt; Confirm"
      assert page =~ ">Errors by signature (events)</text>"
      assert page =~ "Content-Security-Policy"
      refute page =~ ~r/https?:|<script/

      {0, after_chart} = single(["status" | on.([])])
      readers = after_chart["result"]["readers"]
      assert Enum.find(readers, &(&1["name"] == "agent-a"))["cursor"] == agent["cursor"]
      assert Enum.any?(readers, &(&1["name"] == written["result"]["reader"]))

      # Without --out the page goes under the system temp directory.
      {0, default} = single(["chart" | on.([])])
      on_exit(fn -> File.rm(default["result"]["path"]) end)
      assert String.starts_with?(default["result"]["path"], System.tmp_dir!())
      assert Bitwise.band(File.stat!(default["result"]["path"]).mode, 0o777) == 0o600
    end

    test "chart --serve serves the page on loopback until --for, shows new marks, and stops when the session ends",
         context do
      session = start_session(context)

      reference = start_chart(context, session, ["--for", "4s"])
      assert_receive {^reference, %{"kind" => "serving", "url" => url} = serving}, 30_000
      assert serving["renews_lease"] == false

      %URI{scheme: "http", host: "127.0.0.1", port: port, path: path} = URI.parse(url)
      host = "127.0.0.1:#{port}"

      page = http_get(port, path, host)
      assert page =~ "HTTP/1.1 200 OK"
      assert page =~ ~s(<meta http-equiv="refresh" content="1">)
      assert http_get(port, path, "evil.example:#{port}") =~ "HTTP/1.1 421"
      assert http_get(port, "/not-the-token/", host) =~ "HTTP/1.1 404"

      # While the chart runs, this process is its observer node: act on the
      # target directly.
      {:ok, _marked} =
        :peer.call(context.peer, Insider.Live, :mark, [session, %{"label" => "while serving"}])

      assert_eventually(fn -> http_get(port, path, host) =~ "while serving" end)

      assert_receive {^reference, %{"kind" => "stopped", "reason" => "duration"}}, 30_000
      assert_receive {^reference, {:exit, 0}}, 5_000
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary])

      # The session ends: the chart says so and stops.
      ended = start_chart(context, session, ["--for", "10m"])
      assert_receive {^ended, %{"kind" => "serving", "url" => url}}, 30_000
      %URI{port: port, path: path} = URI.parse(url)

      {:ok, _stopped} =
        :peer.call(context.peer, Insider.Live, :stop, [session, %{"force" => true}])

      assert_eventually(fn ->
        http_get(port, path, "127.0.0.1:#{port}") =~ "This chart stopped updating."
      end)

      assert_receive {^ended, %{"kind" => "stopped", "reason" => "session_ended"}}, 30_000
      assert_receive {^ended, {:exit, 0}}, 5_000
    end

    test "chart --serve renews no lease, starting included, and redraws under a narrower profile",
         context do
      session = start_session(context, ["--lease-ms", "60000"])
      :peer.call(context.peer, :logger, :error, ["private detail for the chart"])

      {:ok, %{"lease_remaining_ms" => before}} =
        :peer.call(context.peer, Insider.Live, :status, [session])

      reference = start_chart(context, session, ["--since", "0", "--for", "1m"])
      assert_receive {^reference, %{"kind" => "serving", "url" => url}}, 30_000

      {:ok, %{"lease_remaining_ms" => after_start}} =
        :peer.call(context.peer, Insider.Live, :status, [session])

      assert after_start <= before

      %URI{port: port, path: path} = URI.parse(url)
      host = "127.0.0.1:#{port}"
      assert http_get(port, path, host) =~ "private detail for the chart"

      # The host narrows the session to strict: the next pages are redrawn
      # from strict reads, without the text the rich ones disclosed.
      :ok = :peer.call(context.peer, Application, :put_env, [:insider, :live_disclosure, :strict])

      assert_eventually(fn ->
        page = http_get(port, path, host)
        page =~ "strict disclosure" and not (page =~ "private detail")
      end)

      {:ok, %{"lease_remaining_ms" => serving}} =
        :peer.call(context.peer, Insider.Live, :status, [session])

      assert serving <= after_start

      {:ok, _stopped} =
        :peer.call(context.peer, Insider.Live, :stop, [session, %{"force" => true}])

      assert_receive {^reference, %{"kind" => "stopped", "reason" => "session_ended"}}, 30_000
    end

    test "chart --serve stops at --for even when the session ends just before it", context do
      session = start_session(context)

      reference = start_chart(context, session, ["--for", "2s"])
      assert_receive {^reference, %{"kind" => "serving", "url" => url}}, 30_000
      serving_at = System.monotonic_time(:millisecond)
      %URI{port: port} = URI.parse(url)

      {:ok, _stopped} =
        :peer.call(context.peer, Insider.Live, :stop, [session, %{"force" => true}])

      assert_receive {^reference, %{"kind" => "stopped", "reason" => "session_ended"}}, 30_000
      assert_receive {^reference, {:exit, 0}}, 5_000

      # The final page stays up for at most the rest of --for, not the
      # five-second grace.
      assert System.monotonic_time(:millisecond) - serving_at < 4_000
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary])
    end

    test "chart --out refuses a path that exists, a symlink included", context do
      session = start_session(context)

      dir =
        Path.join(System.tmp_dir!(), "insider-chart-out-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      target_file = Path.join(dir, "notes.txt")
      File.write!(target_file, "DO NOT CHANGE")
      link = Path.join(dir, "chart.html")
      File.ln_s!(target_file, link)

      for path <- [target_file, link] do
        {64, refused} =
          single([
            "chart"
            | target(context.node, context.cookie_file, ["--session", session, "--out", path])
          ])

        assert refused["error"]["code"] == "invalid_options"
        assert %{"option" => "--out", "problem" => "exists"} = refused["error"]["details"]
      end

      assert File.read!(target_file) == "DO NOT CHANGE"
    end

    # Pairing: mark right before the programmer acts, then read since it.
    test "mark, then digest and events --since-mark read what came after it, and marks lists them",
         context do
      session = start_session(context)

      on = fn extra ->
        target(context.node, context.cookie_file, ["--session", session | extra])
      end

      :peer.call(context.peer, :logger, :error, ["before the click"])

      {0, marked} =
        single(["mark" | on.(["--label", "about to click Confirm", "--reader", "agent-a"])])

      assert %{"schema" => "insider.live-mark/v1", "recorded" => true} = marked["result"]
      assert %{"index" => 1, "label" => "about to click Confirm"} = marked["result"]["mark"]

      assert marked["result"]["next"] =~
               "digest \"${N[@]}\" --session #{session} --since-mark --human"

      for index <- 1..2,
          do: :peer.call(context.peer, :logger, :error, ["checkout failed for order #{index}"])

      {0, text} = observe_raw(["digest" | on.(["--since-mark", "--human"])])

      assert text =~
               ~r/\nWindow: since mark 'about to click Confirm' \(\d\d:\d\d:\d\d UTC, [\d.]+ s ago\), up to receipt \d+; /

      assert text =~ "2x logger_message checkout failed for order N"
      refute text =~ "before the click"

      {0, named} = single(["digest" | on.(["--since-mark", "about to click Confirm"])])
      assert named["result"]["window"]["mark"]["label"] == "about to click Confirm"

      {0, events} = observe_raw(["events" | on.(["--since-mark", "--format", "compact"])])
      assert events =~ "live.mark"
      assert events =~ "checkout failed for order 2"
      refute events =~ "before the click"

      {0, listed} = observe_raw(["marks" | on.(["--human"])])

      assert listed =~
               ~r/#1 \d\d:\d\d:\d\d UTC \([\d.]+ s ago\) 'about to click Confirm' by agent-a, after receipt \d+/

      {1, missing} = single(["digest" | on.(["--since-mark", "nope"])])
      assert %{"source" => "target", "code" => "mark_not_found"} = missing["error"]
      assert missing["error"]["labels"] == ["about to click Confirm"]
    end

    test "a GraphQL error inside a 200 shows in compact events, digest, and the trace tree, which prints as text",
         context do
      trace_id = "6bf92f3577b34da6a3ce929d0e0e4738"
      # The event's atoms exist on a node that runs Absinthe.
      :peer.call(context.peer, Code, :eval_string, ["[:absinthe, :execute, :operation, :stop]"])

      session =
        start_session(context, [
          "--component",
          "telemetry",
          "--telemetry-event",
          "absinthe.execute.operation.stop",
          "--telemetry-min-duration-ms",
          "0"
        ])

      # Absinthe's operation stop in a request process under a trace
      # context; the blueprint is a map with Absinthe's struct name.
      :peer.call(context.peer, Code, :eval_string, [
        """
        Task.async(fn ->
          Logger.metadata(otel_trace_id: "#{trace_id}", otel_span_id: "00f067aa0ba902b9")

          :telemetry.execute([:absinthe, :execute, :operation, :stop], %{duration: 1_000}, %{
            blueprint: %{
              __struct__: Absinthe.Blueprint,
              operations: [
                %{
                  name: "placeBuyOrder",
                  type: :mutation,
                  current: true,
                  selections: [
                    %{
                      __struct__: Absinthe.Blueprint.Document.Field,
                      name: "placeBuyOrder",
                      alias: nil,
                      selections: [
                        %{
                          __struct__: Absinthe.Blueprint.Document.Field,
                          name: "errors",
                          alias: nil,
                          selections: [
                            %{__struct__: Absinthe.Blueprint.Document.Field, name: "field", alias: nil, selections: []}
                          ]
                        }
                      ]
                    }
                  ]
                }
              ],
              fragments: [],
              result: %{
                data: %{
                  "placeBuyOrder" => %{
                    "errors" => [%{"field" => "unitPrice", "message" => "at least 1.00"}]
                  }
                }
              }
            }
          })
        end)
        |> Task.await()
        """
      ])

      base = target(context.node, context.cookie_file, ["--session", session])

      {0, compact} = observe_raw(["events" | base] ++ ["--cursor", "0", "--format", "compact"])

      assert compact =~ "absinthe.execute.operation.stop warning <"

      assert compact =~
               "graphql=mutation:placeBuyOrder result=user_errors user_errors=1 fields=[unitPrice]"

      refute compact =~ "at least 1.00"

      {0, digest} = observe_raw(["digest" | base] ++ ["--since", "latest-10", "--human"])
      assert digest =~ "mutation placeBuyOrder result=user_errors fields=[unitPrice]"

      trace = ["trace" | base] ++ ["--trace-id", trace_id, "--human"]
      {0, text} = observe_raw(trace)
      assert text =~ "trace #{trace_id}: 0 spans, 1 items\n"

      assert text =~
               ~r/\n\+0\.000ms telemetry absinthe\.execute\.operation\.stop [\d.]+ms warning mutation placeBuyOrder result=user_errors/

      refute String.starts_with?(text, "{")

      {0, hidden} = observe_raw(trace ++ ["--hide", "absinthe,auth", "--collapse", "sql"])
      assert hidden =~ "trace #{trace_id}: 0 spans, 0 items; hidden absinthe 1\n"

      {0, json} = single(["trace" | base] ++ ["--trace-id", trace_id, "--collapse", "sql"])
      assert json["result"]["omitted"] == %{"hidden" => %{}, "collapsed" => %{}}

      {1, invalid} = single(trace ++ ["--hide", ""])

      assert %{"source" => "target", "code" => "invalid_options", "option" => "--hide"} =
               invalid["error"]

      # A pinned trace says so, and --values shows the response
      # values (this peer runs the rich profile).
      {0, retained} = observe_raw(trace ++ ["--retain"])
      assert retained =~ "\nRetained: pinned with --retain; 1 events kept.\n"

      {0, values} = observe_raw(trace ++ ["--values-path", "placeBuyOrder.errors*"])
      assert values =~ "\nValues (rich profile, credential-masked):\n"
      assert values =~ ~s(\n    placeBuyOrder.errors[0].field = "unitPrice")

      {1, bad} = single(trace ++ ["--values-path", "has space"])

      assert %{"code" => "invalid_options", "option" => "--values-path"} = bad["error"]
    end

    test "watch --format compact prints the subscription, events, and end as text lines",
         context do
      session = start_session(context)
      for index <- 1..2, do: :peer.call(context.peer, :logger, :error, ["watch compact #{index}"])

      watch =
        ["watch" | target(context.node, context.cookie_file, ["--session", session])] ++
          ["--format", "compact", "--max-events", "2", "--view-min-severity", "error"]

      {0, text} = observe_raw(watch)
      [subscribed | rest] = String.split(text, "\n", trim: true)

      assert subscribed =~
               ~r/^# subscribed session=#{session} target=\S+ disclosure=rich cursor=0 max_events=2$/

      assert Enum.count(rest, &(&1 =~ ~r/^\d+ \S+ logger logger_message error/)) == 2
      assert Enum.any?(rest, &String.starts_with?(&1, "# batch cursor=0 "))
      [stopped, more] = Enum.take(rest, -2)
      assert stopped =~ ~r/^# stopped events=2 next_cursor=\d+ reason=max_events$/

      assert more =~
               ~r/^# more: watch stopped at its --max-events; continue with watch --from-cursor \d+ \(and a larger --max-events\), or events --cursor \d+$/

      refute Enum.any?(rest, &(&1 =~ ~r/^# more: this read/))
    end

    test "start accepts repeated --component and --telemetry-event options", context do
      # Telemetry segments must already be atoms on the target.
      for segment <- ["insider_lab", "observer", "one", "two"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      {status, started} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "logger",
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab.observer.one",
              "--telemetry-event",
              "insider_lab.observer.two"
            ])
        ])

      assert status == 0
      assert Enum.sort(started["result"]["components"]) == ["logger", "telemetry"]

      assert started["result"]["telemetry_events"] == [
               ["insider_lab", "observer", "one"],
               ["insider_lab", "observer", "two"]
             ]

      {:ok, _stopped} =
        :peer.call(context.peer, Insider.Live, :stop, [started["result"]["session_id"]])
    end

    # The quick start's start on a node without Phoenix, Oban, Absinthe,
    # Bandit, Cowboy or a repository: every default is skipped and reported,
    # never refused, and the session runs Logger alone. Explicit names are
    # still checked.
    test "start with logger and telemetry on a plain node skips the defaults it lacks", context do
      {0, started} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "logger",
              "--component",
              "telemetry"
            ])
        ])

      result = started["result"]
      assert result["components"] == ["logger"]
      assert result["telemetry_events"] == []

      assert %{"event" => "phoenix.endpoint.stop", "reason" => "not_on_target"} in result[
               "telemetry_skipped_defaults"
             ]

      assert result["telemetry_hint"] ==
               "no default Telemetry events exist on this node; pass --telemetry-event or use discover"

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [result["session_id"]])

      {1, refused} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab_never_an_atom_q9z.stop"
            ])
        ])

      assert refused["error"]["code"] == "unknown_telemetry_event"
    end

    test "discover lists the target's events and start subscribes to a discovered prefix",
         context do
      for segment <- ["insider_lab", "discover", "one", "two"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      # Handlers are a discovery source. `:telemetry_test.handle_event/4`
      # forwards each event to a sink process on the peer.
      sink = :peer.call(context.peer, :erlang, :spawn, [:timer, :sleep, [:infinity]])

      for name <- [:one, :two] do
        :ok =
          :peer.call(context.peer, :telemetry, :attach, [
            "insider-lab-discover-#{name}",
            [:insider_lab, :discover, name],
            &:telemetry_test.handle_event/4,
            %{dest_pid: sink, ref: make_ref()}
          ])
      end

      {status, discovered} =
        single([
          "discover"
          | target(context.node, context.cookie_file, ["--prefix", "insider_lab.discover"])
        ])

      assert status == 0
      handler = [%{"source" => "handler", "module" => "telemetry_test"}]

      assert discovered["result"]["events"] == [
               %{
                 "event" => "insider_lab.discover.one",
                 "sources" => handler,
                 "sources_truncated" => false
               },
               %{
                 "event" => "insider_lab.discover.two",
                 "sources" => handler,
                 "sources_truncated" => false
               }
             ]

      {status, started} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab.discover.*"
            ])
        ])

      assert status == 0
      id = started["result"]["session_id"]

      assert started["result"]["telemetry_events"] == [
               ["insider_lab", "discover", "one"],
               ["insider_lab", "discover", "two"]
             ]

      assert [%{"prefix" => "insider_lab.discover.*", "complete" => true}] =
               started["result"]["telemetry_event_prefixes"]

      {0, status_document} =
        single(["status" | target(context.node, context.cookie_file, ["--session", id])])

      assert status_document["result"]["telemetry_subscriptions"] == [
               %{"event" => "insider_lab.discover.one", "state" => "subscribed", "seen" => 0},
               %{"event" => "insider_lab.discover.two", "state" => "subscribed", "seen" => 0}
             ]

      # The fixture handler stays valid when the event is emitted.
      :ok =
        :peer.call(context.peer, :telemetry, :execute, [[:insider_lab, :discover, :one], %{}, %{}])

      assert [%{id: "insider-lab-discover-one"}] =
               :peer.call(context.peer, :telemetry, :list_handlers, [
                 [:insider_lab, :discover, :one]
               ])
               |> Enum.filter(&(&1.id == "insider-lab-discover-one"))

      {0, status_document} =
        single(["status" | target(context.node, context.cookie_file, ["--session", id])])

      assert [%{"seen" => 1}, %{"seen" => 0}] =
               status_document["result"]["telemetry_subscriptions"]

      {status, refused} =
        single(["discover" | target(context.node, context.cookie_file, ["--prefix", "Shop"])])

      assert status == 1

      assert %{"code" => "invalid_options", "field" => "prefix", "option" => "--prefix"} =
               refused["error"]

      assert refused["error"]["expected"] =~ "PREFIX"

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [id])
    end

    test "start passes record-time filters and events and watch pass a reader's view", context do
      for segment <- ["insider_lab", "observer", "fast", "summed"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      {0, started} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "logger",
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab.observer.fast",
              "--telemetry-event",
              "insider_lab.observer.summed",
              "--logger-level",
              "error",
              "--logger-exclude",
              "domain:insider_lab.observer",
              "--logger-include",
              "application:insider",
              "--logger-include",
              "module:Insider.Live",
              "--exclude-origin",
              "none",
              "--telemetry-min-duration-ms",
              "0",
              "--telemetry-event-min-duration",
              "insider_lab.observer.fast=5",
              "--telemetry-summary",
              "insider_lab.observer.summed",
              "--telemetry-summary-interval-ms",
              "60000",
              "--logger-summary",
              "module:Insider.Live.Owner",
              "--logger-summary-interval-ms",
              "30000",
              "--telemetry-duration-scope",
              "insider_lab.observer.summed=handler"
            ])
        ])

      id = started["result"]["session_id"]

      assert started["result"]["filters"] == %{
               "logger_level" => "error",
               "logger_include" => [%{"application" => "insider"}, %{"module" => "Insider.Live"}],
               "logger_exclude" => [%{"domain" => ["insider_lab", "observer"]}],
               "exclude_origins" => [],
               "telemetry_min_duration_ms" => 0,
               "telemetry_event_min_duration_ms" => %{
                 "insider_lab.observer.fast" => 5,
                 "insider_lab.observer.summed" => 0
               },
               "telemetry_summaries" => ["insider_lab.observer.summed"],
               "telemetry_summary_interval_ms" => 60_000,
               "logger_summaries" => [%{"module" => "Insider.Live.Owner"}],
               "logger_summary_interval_ms" => 30_000,
               "telemetry_duration_scopes" => %{"insider_lab.observer.summed" => "handler"}
             }

      one_ms = :peer.call(context.peer, :erlang, :convert_time_unit, [1, :millisecond, :native])
      ten_ms = 10 * one_ms

      for {event, duration} <- [{:fast, one_ms}, {:fast, ten_ms}, {:summed, one_ms}] do
        :peer.call(context.peer, :telemetry, :execute, [
          [:insider_lab, :observer, event],
          %{duration: duration},
          %{}
        ])
      end

      {0, read} =
        single([
          "events"
          | target(context.node, context.cookie_file, [
              "--session",
              id,
              "--cursor",
              "0",
              "--view-kind",
              "other.*",
              "--view-source",
              "telemetry",
              "--view-min-severity",
              "info"
            ])
        ])

      assert read["result"]["events"] == []

      assert read["result"]["filtered"]["view"] == %{
               "kinds" => 1,
               "sources" => 0,
               "min_severity" => 0
             }

      assert read["result"]["filtered"]["telemetry"] == %{
               "insider_lab.observer.fast" => %{
                 "min_duration" => 1,
                 "origin" => 0,
                 "summarized" => 0
               },
               "insider_lab.observer.summed" => %{
                 "min_duration" => 0,
                 "origin" => 0,
                 "summarized" => 1
               }
             }

      {1, refused} =
        single([
          "watch"
          | target(context.node, context.cookie_file, ["--session", id, "--view-source", "disk"])
        ])

      assert refused["error"]["source"] == "target"
      assert refused["error"]["field"] == "view"

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [id])
    end

    test "an allowlisted --telemetry-measurement returns its numeric value", context do
      for segment <- ["insider_lab", "observer", "measured"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      {0, started} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab.observer.measured",
              "--telemetry-measurement",
              "count",
              "--telemetry-measurement",
              "duration",
              # 42 native units is far below the default slow threshold.
              "--telemetry-min-duration-ms",
              "0"
            ])
        ])

      session = started["result"]["session_id"]
      assert started["result"]["telemetry_measurements"] == ["count", "duration"]

      :ok =
        :peer.call(context.peer, :telemetry, :execute, [
          [:insider_lab, :observer, :measured],
          %{count: 7, duration: 42},
          %{}
        ])

      {0, read} =
        single([
          "events"
          | target(context.node, context.cookie_file, ["--session", session, "--cursor", "0"])
        ])

      assert [event] = read["result"]["events"]
      assert event["event"]["attributes"]["measurements"] == %{"count" => 7, "duration" => 42}

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])
    end

    test "two named readers share a session: amend, a protected stop, a drain, and handoff",
         context do
      for segment <- ["insider_lab", "observer", "tandem"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      emit = fn count, measurements ->
        :ok =
          :peer.call(context.peer, :telemetry, :execute, [
            [:insider_lab, :observer, :tandem],
            Map.put(measurements, :count, count),
            %{}
          ])
      end

      run = fn arguments -> single(arguments ++ target(context.node, context.cookie_file)) end

      {0, started} =
        run.([
          "start",
          "--component",
          "telemetry",
          "--telemetry-event",
          "insider_lab.observer.tandem",
          "--telemetry-measurement",
          "count",
          "--telemetry-min-duration-ms",
          "0"
        ])

      session = started["result"]["session_id"]
      assert started["result"]["scope"]["filters"] =~ "every reader"
      assert started["installation"]["insider_commit"] == Insider.Live.Revision.commit()

      emit.(1, %{duration: 5})
      emit.(2, %{duration: 5})

      {0, read_a} = run.(["events", "--session", session, "--cursor", "0", "--reader", "agent-a"])

      assert Enum.map(read_a["result"]["events"], &measurements/1) == [
               %{"count" => 1},
               %{"count" => 2}
             ]

      # agent-a needs durations: amend instead of a restart.
      {0, amended} =
        run.([
          "amend",
          "--session",
          session,
          "--telemetry-measurement",
          "count",
          "--telemetry-measurement",
          "duration",
          "--reader",
          "agent-a"
        ])

      assert %{"marker_receipt" => 3, "changed" => ["telemetry_measurements"], "by" => "agent-a"} =
               amended["result"]["amendment"]

      emit.(3, %{duration: 5})

      {0, read_b} =
        run.([
          "events",
          "--session",
          session,
          "--cursor",
          "0",
          "--reader",
          "agent-b",
          "--limit",
          "3"
        ])

      assert [_one, _two, %{"event" => %{"kind" => "live.session_amended"}}] =
               read_b["result"]["events"]

      {0, status} = run.(["status", "--session", session])
      assert ["agent-a", "agent-b"] == Enum.map(status["result"]["readers"], & &1["name"])

      {0, handoff} = run.(["handoff", "--session", session])

      assert %{"schema" => "insider.live-handoff/v1", "session_id" => ^session} =
               handoff["result"]

      # agent-a's stop waits for agent-b; --force stops, and agent-b drains.
      {1, refused} = run.(["stop", "--session", session, "--reader", "agent-a"])
      assert %{"source" => "target", "code" => "readers_active"} = refused["error"]
      assert [%{"name" => "agent-b", "cursor" => 3}] = refused["error"]["readers"]

      {0, stopped} = run.(["stop", "--session", session, "--reader", "agent-a", "--force"])
      assert stopped["result"]["state"] == "stopped"
      assert is_binary(stopped["result"]["readable_until"])

      {0, drained} =
        run.(["events", "--session", session, "--cursor", "3", "--reader", "agent-b"])

      assert drained["result"]["state"] == "stopped"

      assert [%{"count" => 3, "duration" => 5}] =
               Enum.map(drained["result"]["events"], &measurements/1)
    end

    test "a --telemetry-measurement outside the host allowlist surfaces the target's error",
         context do
      for segment <- ["insider_lab", "observer", "refused"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      {1, document} =
        single([
          "start"
          | target(context.node, context.cookie_file, [
              "--component",
              "telemetry",
              "--telemetry-event",
              "insider_lab.observer.refused",
              "--telemetry-measurement",
              "api_key"
            ])
        ])

      assert document["error"]["source"] == "target"
      assert document["error"]["code"] == "invalid_options"
      assert document["error"]["field"] == "telemetry_measurements"
      # The observer names the flag that set the field and its value syntax.
      assert document["error"]["option"] == "--telemetry-measurement"
      assert document["error"]["expected"] =~ "telemetry_measurements_allowed"
    end

    test "--disclosure narrows the session and the target refuses a richer profile", context do
      for segment <- ["insider_lab", "observer", "disclosed"],
          do: :peer.call(context.peer, :erlang, :binary_to_atom, [segment])

      telemetry = [
        "--component",
        "telemetry",
        "--telemetry-event",
        "insider_lab.observer.disclosed"
      ]

      {0, capabilities} = single(["capabilities" | target(context.node, context.cookie_file)])
      assert capabilities["result"]["disclosure_profile"] == "rich"

      {0, started} =
        single(["start" | target(context.node, context.cookie_file, telemetry)])

      session = started["result"]["session_id"]
      assert started["result"]["disclosure_profile"] == "rich"

      :ok =
        :peer.call(context.peer, :telemetry, :execute, [
          [:insider_lab, :observer, :disclosed],
          %{count: 1},
          %{source: "users", api_key: "synthetic-observer-secret"}
        ])

      {0, read} =
        single([
          "events"
          | target(context.node, context.cookie_file, ["--session", session, "--cursor", "0"])
        ])

      assert [event] = read["result"]["events"]

      assert event["event"]["payload"]["metadata"] == %{
               "source" => "users",
               "api_key" => "[REDACTED:credential_key]"
             }

      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])

      {0, narrowed} =
        single([
          "start"
          | target(context.node, context.cookie_file, telemetry ++ ["--disclosure", "strict"])
        ])

      assert narrowed["result"]["disclosure_profile"] == "strict"

      {:ok, _stopped} =
        :peer.call(context.peer, Insider.Live, :stop, [narrowed["result"]["session_id"]])

      :ok = :peer.call(context.peer, Application, :put_env, [:insider, :live_disclosure, :strict])

      {1, refused} =
        single([
          "start"
          | target(context.node, context.cookie_file, telemetry ++ ["--disclosure", "rich"])
        ])

      assert refused["error"]["source"] == "target"
      assert refused["error"]["code"] == "disclosure_denied"
      assert refused["error"]["requested"] == "rich"
    end

    test "watch attached near lease expiry keeps the session alive", context do
      session = start_session(context, ["--lease-ms", "3000"])

      # Attach with well under a third of the lease left, as the review did.
      Process.sleep(2_500)
      {_watcher, reference} = start_watch(context, session)
      assert_receive {^reference, %{"kind" => "subscribed"}}, 10_000

      # Past the original expiry, the session is still running.
      Process.sleep(1_500)

      assert {:ok, %{"state" => "running"}} =
               :peer.call(context.peer, Insider.Live, :status, [session])

      refute_received {^reference, %{"kind" => "stopped"}}
      {:ok, _stopped} = :peer.call(context.peer, Insider.Live, :stop, [session])
      assert_receive {^reference, {:exit, 0}}, 15_000
    end
  end

  # The peer logs nothing else at error level, so an error-severity Logger
  # event in the session is the one the test emitted, whatever the
  # disclosure profile returns of its message.
  defp logged_error?(%{"event" => %{"kind" => "logger_message", "severity" => "error"}}),
    do: true

  defp logged_error?(_event), do: false

  defp start_session(context, extra \\ []) do
    {0, started} =
      single(["start" | target(context.node, context.cookie_file, @logger_session ++ extra)])

    started["result"]["session_id"]
  end

  # Runs `chart --serve` in an unlinked process: each decoded output line,
  # then `{:exit, status}`, arrives as a message; a test that fails first
  # stops it the way SIGTERM does.
  defp start_chart(context, session, extra) do
    owner = self()
    reference = make_ref()

    arguments = [
      "chart"
      | target(context.node, context.cookie_file, ["--session", session, "--serve" | extra])
    ]

    server =
      spawn(fn ->
        status =
          CLI.run(arguments, fn bytes ->
            send(owner, {reference, bytes |> IO.iodata_to_binary() |> Jason.decode!()})
            :ok
          end)

        send(owner, {reference, {:exit, status}})
      end)

    on_exit(fn ->
      monitor = Process.monitor(server)
      send(server, Watch.stop_message())

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
      after
        15_000 -> flunk("chart did not stop")
      end
    end)

    reference
  end

  defp http_get(port, path, host) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false]) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n\r\n")
        response = receive_all(socket, "")
        :gen_tcp.close(socket)
        response

      {:error, reason} ->
        "connect failed: #{reason}"
    end
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_all(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  # A served page changes on the server's own schedule; poll it, bounded.
  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(100)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("expected state was not reached")

  # Runs `watch` in an unlinked process: each decoded output line, then
  # `{:exit, status}`, arrives as a message. If a test fails first, the
  # watcher is stopped the way SIGTERM stops it. Its lines are written while
  # it is distributed, so it records the observer node it started, and the
  # test checks that this node is gone once the watcher has ended.
  defp start_watch(context, session, extra \\ []) do
    owner = self()
    reference = make_ref()
    {:ok, started} = Agent.start(fn -> nil end)

    arguments = [
      "watch" | target(context.node, context.cookie_file, ["--session", session] ++ extra)
    ]

    watcher =
      spawn(fn ->
        status =
          CLI.run(arguments, fn bytes ->
            if Node.alive?(), do: Agent.update(started, &(&1 || node()))
            send(owner, {reference, bytes |> IO.iodata_to_binary() |> Jason.decode!()})
            :ok
          end)

        send(owner, {reference, {:exit, status}})
      end)

    on_exit(fn ->
      monitor = Process.monitor(watcher)
      send(watcher, Watch.stop_message())

      receive do
        {:DOWN, ^monitor, :process, ^watcher, _reason} -> :ok
      after
        15_000 -> flunk("watcher did not stop")
      end

      observer = Agent.get(started, & &1)
      Agent.stop(started)
      assert observer, "the watch never ran distributed"
      refute node() == observer, "the watch's observer node #{observer} is still up"
    end)

    {watcher, reference}
  end

  defp watch_stream_fixture do
    Path.expand("../fixtures/live_watch_stream_v1.ndjson", __DIR__)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  # The batch lines of a watch up to its `stopped` line, and that line.
  defp await_stopped(reference, batches \\ []) do
    assert_receive {^reference, line}, 15_000

    case line do
      %{"kind" => "batch"} -> await_stopped(reference, batches ++ [line])
      %{"kind" => "stopped"} -> {batches, line}
    end
  end

  describe "the cleanup check" do
    # The check itself must not pass when it cannot tell: a watcher that does
    # not answer fails it, and only a stopped peer has no observers left.
    setup %{cookie: cookie} do
      {peer, node} = LivePeer.start(cookie)
      on_exit(fn -> LivePeer.stop(peer) end)
      {:ok, peer: peer, node: String.to_atom(node)}
    end

    test "reports a connected observer, and fails when the watcher never replies", context do
      {:ok, _pid} =
        :net_kernel.start(:"cleanup_check_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames,
          hidden: true
        })

      # With a connection still up, :net_kernel.stop/0 can return before
      # node() is cleared (9 of 80 times in a local probe), and the next test
      # then reads a distributed node. Disconnect first, as the observer
      # does, and wait until this VM is no longer distributed.
      on_exit(fn ->
        _disconnected = :erlang.disconnect_node(context.node)
        _stopped = :net_kernel.stop()
        await_not_distributed(System.monotonic_time(:millisecond) + 5_000)
      end)

      true = :erlang.set_cookie(context.node, context.cookie)
      true = Node.connect(context.node)

      assert LivePeer.observers_left(context.peer, 200) == [node()]

      # Replace the watcher with a process that never replies.
      silent = :peer.call(context.peer, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      true = :peer.call(context.peer, :erlang, :unregister, [LivePeer.NodeWatch])
      true = :peer.call(context.peer, :erlang, :register, [LivePeer.NodeWatch, silent])

      assert {kind, _reason} = unverified(fn -> LivePeer.observers_left(context.peer, 200) end)
      assert kind in [:error, :exit]
    end

    test "finds no observers left on a stopped peer", context do
      LivePeer.stop(context.peer)
      assert LivePeer.observers_left(context.peer, 200) == []
    end
  end

  defp unverified(check) do
    flunk("the check returned #{inspect(check.())} instead of failing")
  catch
    kind, reason when kind in [:error, :exit] and not is_struct(reason, ExUnit.AssertionError) ->
      {kind, reason}
  end

  defp await_not_distributed(deadline) do
    cond do
      not Node.alive?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("this VM is still distributed as #{node()}")

      true ->
        Process.sleep(10)
        await_not_distributed(deadline)
    end
  end

  describe "refusals before any connection" do
    test "a host that is not loopback is refused without echoing it", context do
      {status, document} =
        single(["capabilities" | target("app@synthetic-my6-canary.example", context.cookie_file)])

      assert status == 64
      assert document["status"] == "invalid_input"
      assert document["error"]["code"] == "non_loopback_host"

      # The error names the flag and its rule, never the value.
      assert %{"option" => "--node", "expected" => expected} = document["error"]["details"]
      assert expected =~ "loopback or this machine"
      refute Jason.encode!(document) =~ "my6-canary"
    end

    test "a cookie file other users can read is refused without echoing the cookie", context do
      File.chmod!(context.cookie_file, 0o644)
      {status, output} = observe(["capabilities" | target("app@localhost", context.cookie_file)])

      assert status == 64
      assert [%{"error" => %{"code" => "cookie_file_permissions", "details" => details}}] = output
      assert details["mode"] == "0644"
      refute inspect(output) =~ Atom.to_string(context.cookie)
    end

    test "an unregistered node name is reported as not found", context do
      {status, document} =
        single(["capabilities" | target("nobody_here@localhost", context.cookie_file)])

      assert status == 1
      assert document["error"]["code"] == "target_not_found"
    end

    test "a --prefix with an empty segment is malformed", context do
      {status, document} =
        single(["discover" | target("app@localhost", context.cookie_file, ["--prefix", "a..b"])])

      assert status == 64

      assert %{"option" => "--prefix", "problem" => "malformed"} =
               document["error"]["details"]
    end
  end

  describe "targets without this Insider" do
    test "a target without Insider fails with insider_missing", context do
      {_peer, node} = start_peer(context.cookie, insider: :absent, environment: :development)

      {status, document} = single(["capabilities" | target(node, context.cookie_file)])

      assert status == 3
      assert document["status"] == "unsupported"
      assert document["error"]["code"] == "insider_missing"
    end

    test "a target with a different Insider version fails with insider_version_mismatch",
         context do
      {peer, node} = start_peer(context.cookie, insider: :absent, environment: :development)

      :ok =
        :peer.call(peer, :application, :load, [
          {:application, :insider,
           [
             description: ~c"other insider",
             vsn: ~c"0.0.0-other",
             modules: [],
             applications: [:kernel, :stdlib]
           ]}
        ])

      {status, document} = single(["capabilities" | target(node, context.cookie_file)])

      assert status == 3
      assert document["error"]["code"] == "insider_version_mismatch"
      assert document["error"]["details"]["reason"] == "version"

      # The remedy names --force-load and the evidence it
      # ends, and never says --load replaces another Insider.
      message = document["error"]["message"]
      assert message =~ "--load never replaces it"
      assert message =~ "--force-load"
      assert message =~ "save what you need"
      refute message =~ "--load replaces"
    end

    for environment <- [:staging, :production] do
      test "--load is refused when the target reports #{environment}", context do
        {peer, node} =
          start_peer(context.cookie, insider: :absent, environment: unquote(environment))

        {status, document} =
          single(["capabilities", "--load" | target(node, context.cookie_file)])

        assert status == 3
        assert document["error"]["code"] == "load_refused"
        assert document["error"]["details"]["environment"] == Atom.to_string(unquote(environment))
        assert :peer.call(peer, :application, :get_key, [:insider, :vsn]) == :undefined
        assert :peer.call(peer, :code, :is_loaded, [Insider.Live]) == false
      end
    end

    test "--load is refused when the target reports no environment at all", context do
      {_peer, node} = start_peer(context.cookie, insider: :absent)

      {3, document} = single(["capabilities", "--load" | target(node, context.cookie_file)])

      assert document["error"]["code"] == "load_refused"
      assert document["error"]["details"]["environment"] == "unconfigured"
    end

    test "--load pushes Insider and its missing dependencies into a development target",
         context do
      {peer, node} = start_peer(context.cookie, insider: :absent, environment: :development)

      {status, document} = single(["capabilities", "--load" | target(node, context.cookie_file)])

      assert status == 0
      assert document["installation"]["action"] == "loaded"
      assert "insider" in document["installation"]["pushed_applications"]
      assert "telemetry" in document["installation"]["pushed_applications"]
      assert "recon" in document["installation"]["pushed_applications"]
      assert {:file, _loaded} = :peer.call(peer, :code, :is_loaded, [:recon_alloc])
      assert document["result"]["owner_running"] == true
      assert {:ok, _version} = :peer.call(peer, :application, :get_key, [:insider, :vsn])

      # The next call finds the same Insider and needs no flag.
      {0, again} = single(["capabilities" | target(node, context.cookie_file)])
      assert again["installation"]["action"] == "none"
    end

    test "--load refuses a partial install: an Insider module loaded without the application",
         context do
      {peer, node} = start_peer(context.cookie, insider: :absent, environment: :development)
      {module, binary, file} = :code.get_object_code(Insider.Live.Build)
      {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, file, binary])

      {3, refused} = single(["capabilities", "--load" | target(node, context.cookie_file)])

      assert refused["error"]["code"] == "load_build_differs"
      assert refused["error"]["details"]["target_build"] == nil
      assert refused["error"]["details"]["remedy"] =~ "--force-load"
      assert refused["error"]["details"]["remedy"] =~ "(events, digest, handoff)"

      # Nothing was pushed.
      assert :peer.call(peer, :application, :get_key, [:insider, :vsn]) == :undefined
      assert :peer.call(peer, :code, :is_loaded, [Insider.Live]) == false
    end

    test "--load refuses a different Insider; --force-load replaces it and keeps the target's configuration",
         context do
      {peer, node} = start_peer(context.cookie, insider: :absent, environment: :development)
      target = target(node, context.cookie_file)

      :ok =
        :peer.call(peer, :application, :load, [
          {:application, :insider,
           [
             description: ~c"other insider",
             vsn: ~c"0.0.0-other",
             modules: [],
             applications: [:kernel, :stdlib]
           ]}
        ])

      {3, refused} = single(["capabilities", "--load" | target])
      assert refused["error"]["code"] == "load_build_differs"
      assert refused["error"]["details"]["target_build"] == nil
      assert {:ok, ~c"0.0.0-other"} = :peer.call(peer, :application, :get_key, [:insider, :vsn])

      {0, document} = single(["capabilities", "--force-load" | target])

      assert document["installation"]["action"] == "loaded"
      assert document["result"]["environment"] == "development"
      assert document["result"]["environment_source"] == "application_env"
    end

    test "--load pushes only recon into a target that runs this Insider without it, and alloc then works",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      target = target(node, context.cookie_file)

      {1, missing} = single(["alloc" | target])
      assert missing["error"]["code"] == "component_unavailable"
      assert missing["error"]["component"] == "recon"
      assert :peer.call(peer, :code, :is_loaded, [:recon]) == false

      {0, loaded} = single(["alloc", "--load" | target])
      # A load carries the whole installation report.
      assert loaded["installation"]["action"] == "loaded"
      assert loaded["installation"]["pushed_applications"] == ["recon"]
      assert loaded["installation"]["observer_build"] == loaded["installation"]["target_build"]
      assert loaded["result"]["schema"] == "insider.live-alloc/v1"
      assert loaded["result"]["implementation"] == "recon"

      # recon is now resolvable there, so a second --load pushes nothing.
      {0, again} = single(["alloc", "--load", "--top", "1" | target])
      # Nothing loaded and the same build: only the summary.
      assert again["installation"] == Map.take(loaded["installation"], short_installation())
      assert again["result"]["implementation"] == "recon"

      # ports never uses recon: its census stays within its own scan bound.
      {0, ports} = single(["ports", "--type", "tcp_inet" | target])
      assert ports["result"]["implementation"] == "native"

      {1, protected} = single(["process", "--name", "code_server" | target])
      assert protected["error"]["code"] == "protected_process"
    end
  end

  describe "--load and the target's Insider build" do
    # Another build of the same Insider version: the target's
    # `Insider.Live.Revision` compiled from another commit, as a target
    # started from an older checkout of this repository runs it.
    @other_commit "0123456789abcdef0123456789abcdef01234567"

    defp run_other_build(peer) do
      [{Insider.Live.Revision, _binary}] =
        compile_in_peer(peer, """
        defmodule Insider.Live.Revision do
          @moduledoc false
          def commit, do: "#{@other_commit}"
        end
        """)

      :ok
    end

    defp compile_in_peer(peer, source) do
      :ok = :peer.call(peer, Code, :put_compiler_option, [:ignore_module_conflict, true])
      :peer.call(peer, Code, :compile_string, [source], 60_000)
    end

    # Suspends `pid` in the VM until `release/2`. A VM-level suspension ends
    # with the process that made it, so a process in the peer holds it.
    defp hang(peer, pid) do
      [{Hang, _binary}] =
        compile_in_peer(peer, """
        defmodule Hang do
          def start(pid) do
            caller = self()
            holder = spawn(fn -> true = :erlang.suspend_process(pid); send(caller, :held); receive(do: (:release -> :ok)) end)
            receive(do: (:held -> holder))
          end
        end
        """)

      :peer.call(peer, Hang, :start, [pid])
    end

    # The holder exits, which ends the suspension.
    defp release(peer, holder), do: :peer.call(peer, Kernel, :send, [holder, :release])

    # This observer's own build: its Insider's commit, and the hash of the
    # Insider modules it would push.
    defp observer_build do
      build = Insider.Live.Build.identity()
      assert build["commit"] == Insider.Live.Revision.commit()
      assert build["beams_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      build
    end

    test "a target running this build is reported as the same build, and --load pushes nothing",
         context do
      {_peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      target = target(node, context.cookie_file)

      for arguments <- [["capabilities" | target], ["capabilities", "--load" | target]] do
        {0, document} = single(arguments)
        installation = document["installation"]

        assert installation["action"] == "none" or
                 installation["pushed_applications"] == ["recon"]

        refute "insider" in installation["pushed_applications"]
        assert installation["observer_build"] == observer_build()
        assert installation["target_build"] == observer_build()
        assert installation["same_build"] == true
      end
    end

    test "without --load, another build of the same version is reported with the remedy",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      :ok = run_other_build(peer)

      {0, document} = single(["capabilities" | target(node, context.cookie_file)])
      installation = document["installation"]

      assert installation["action"] == "none"
      assert installation["same_build"] == false
      assert installation["observer_build"] == observer_build()
      assert installation["target_build"]["commit"] == @other_commit
      refute installation["target_build"]["beams_sha256"] == observer_build()["beams_sha256"]
      assert installation["remedy"] =~ "--force-load"

      # Another build keeps the whole report, remedy included, on every command.
      {0, discovered} = single(["discover" | target(node, context.cookie_file)])
      assert discovered["installation"] == installation
    end

    test "--load refuses another build that is loaded but not started, and changes nothing",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      :ok = run_other_build(peer)
      :ok = :peer.call(peer, :application, :stop, [:insider])

      {3, refused} = single(["capabilities", "--load" | target(node, context.cookie_file)])

      assert refused["error"]["code"] == "load_build_differs"
      details = refused["error"]["details"]
      assert details["target_build"]["commit"] == @other_commit
      assert details["observer_build"] == observer_build()
      assert details["remedy"] =~ "--force-load"

      assert :peer.call(peer, Insider.Live.Revision, :commit, []) == @other_commit
      refute List.keymember?(:peer.call(peer, :application, :which_applications, []), :insider, 0)
    end

    test "--load refuses a started target running another build, with no session, and says how to replace it",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      :ok = run_other_build(peer)

      {3, refused} = single(["capabilities", "--load" | target(node, context.cookie_file)])

      assert refused["error"]["code"] == "load_build_differs"
      details = refused["error"]["details"]
      assert details["target_build"]["commit"] == @other_commit
      assert details["observer_build"] == observer_build()
      assert details["session_active"] == false
      assert details["session_id"] == nil
      assert details["remedy"] =~ "--force-load"

      # Nothing was replaced: Insider still runs the other build.
      assert :peer.call(peer, Insider.Live.Revision, :commit, []) == @other_commit
      assert List.keymember?(:peer.call(peer, :application, :which_applications, []), :insider, 0)
    end

    test "--load refuses a started target running another build with a session; --force-load replaces it",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      target = target(node, context.cookie_file)
      {0, started} = single(["start" | target ++ @logger_session])
      session = started["result"]["session_id"]
      :ok = run_other_build(peer)

      {3, refused} = single(["capabilities", "--load" | target])

      assert refused["error"]["code"] == "load_build_differs"
      details = refused["error"]["details"]
      assert details["session_active"] == true
      assert details["session_id"] == session
      assert details["remedy"] =~ "session #{session}"
      assert details["remedy"] =~ "events, digest, handoff"
      assert details["remedy"] =~ "--force-load"

      assert :peer.call(peer, Insider.Live.Revision, :commit, []) == @other_commit
      {0, status} = single(["status", "--session", session | target])
      assert status["result"]["state"] == "running"

      {0, forced} = single(["capabilities", "--force-load" | target])
      assert forced["installation"]["action"] == "loaded"
      assert forced["installation"]["target_build"] == observer_build()
      assert forced["result"]["active_session_id"] == nil
    end

    test "--load refuses a started target that runs the same modules under another version",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      target = target(node, context.cookie_file)

      # The same compiled modules, loaded under another application version.
      :ok = :peer.call(peer, :application, :stop, [:insider])
      {:ok, keys} = :peer.call(peer, :application, :get_all_key, [:insider])
      :ok = :peer.call(peer, :application, :unload, [:insider])
      spec = {:application, :insider, Keyword.put(keys, :vsn, ~c"0.0.0-other")}
      :ok = :peer.call(peer, :application, :load, [spec])
      {:ok, _started} = :peer.call(peer, :application, :ensure_all_started, [:insider])
      # The observer refuses this version without --load, so start in place.
      {:ok, %{"session_id" => session}} =
        :peer.call(peer, Insider.Live, :start, [%{"components" => ["logger"]}])

      {3, refused} = single(["capabilities", "--load" | target])

      assert refused["error"]["code"] == "load_build_differs"
      details = refused["error"]["details"]
      assert details["target_build"]["version"] == "0.0.0-other"
      assert details["target_build"]["beams_sha256"] == observer_build()["beams_sha256"]
      assert details["observer_build"] == observer_build()
      assert details["session_active"] == true

      assert {:ok, %{"state" => "running"}} = :peer.call(peer, Insider.Live, :status, [session])
    end

    test "--load reports an owner that does not answer as an unknown session and replaces nothing",
         context do
      {peer, node} = start_peer(context.cookie, insider: :started, environment: :development)
      target = target(node, context.cookie_file)
      {0, started} = single(["start" | target ++ @logger_session])
      session = started["result"]["session_id"]
      :ok = run_other_build(peer)

      # A hung owner: the VM does not schedule it, so it answers nothing.
      owner = :peer.call(peer, Process, :whereis, [Insider.Live.Owner])
      holder = hang(peer, owner)

      {3, refused} = single(["capabilities", "--load" | target])

      assert refused["error"]["code"] == "load_build_differs"
      assert refused["error"]["details"]["session_active"] == "unknown"
      assert refused["error"]["details"]["remedy"] =~ "--force-load"

      :release = release(peer, holder)

      assert :peer.call(peer, Insider.Live.Revision, :commit, []) == @other_commit
      {0, status} = single(["status", "--session", session | target])
      assert status["result"]["state"] == "running"
    end
  end

  test "the docs document every observer error code with its exit status", _context do
    documented =
      File.read!(Path.expand("../../../../docs/live/live-api-and-transports.md", __DIR__))

    for {code, {status, _message}} <- CLI.codes() do
      exit_status = Map.fetch!(CLI.exit_statuses(), status)

      row =
        Enum.find(
          String.split(documented, "\n"),
          &String.starts_with?(&1, "| `#{exit_status}` | `#{status}` |")
        )

      assert row, "no docs/live/live-api-and-transports.md row for #{status}"
      assert row =~ "`#{code}`", "#{code} is missing from the #{status} row"
    end
  end

  describe "arguments" do
    test "an unknown operation, or none, prints usage that points to --help", _context do
      for arguments <- [["frobnicate"], [], ["help", "frobnicate"]] do
        {64, document} = single(arguments)
        assert document["error"]["code"] == "usage"
        assert document["error"]["message"] =~ "mix insider.live --help"
        assert document["error"]["details"]["help"] == "mix insider.live --help"
        assert "start" in document["error"]["details"]["operations"]
      end
    end

    test "--help prints usage with the quick start and every operation, and exits 0", _context do
      for arguments <- [["--help"], ["-h"], ["help"]] do
        {0, text} = help(arguments)

        assert text =~ "Usage:"
        assert text =~ "mix insider.live capabilities \"${N[@]}\" --load"

        # Followed in order, the first core command loads Insider into a
        # node without it.
        assert [_before, core] = String.split(text, "Core commands:\n", parts: 2)
        assert [first_core | _rest] = String.split(core, "\n")
        assert first_core =~ "mix insider.live capabilities \"${N[@]}\" --load"
        assert text =~ "Measurements are opt-in"
        assert text =~ "--telemetry-measurement duration"
        assert text =~ "mix insider.live stop \"${N[@]}\" --session SESSION_ID"

        for {operation, _spec} <- CLI.operations(), do: assert(text =~ "\n  #{operation} ")
      end
    end

    test "--help names both packages, the Hex install of the escript and the checkout route",
         _context do
      {0, text} = help(["--help"])
      flat = String.replace(text, ~r/\s+/, " ")

      assert flat =~ "This observer is the insider_lab package."
      assert flat =~ "The insider package, the library it loads into the node, has no Mix tasks."

      assert flat =~
               "Install from Hex: mix escript.install hex insider_lab, then run insider-lab live OPERATION"

      assert flat =~ "In an Insider checkout: run mix insider.live from tools/insider_lab"
      assert flat =~ "./insider-lab live OPERATION"
      refute flat =~ "Run from tools/insider_lab in the Insider checkout"
    end

    test "--help names the tools that pair well with Insider, each with its use", _context do
      {0, text} = help(["--help"])
      assert [_, section] = String.split(text, "Pairs well with:\n", parts: 2)

      for %{"tool" => tool, "use_for" => use_for} <-
            Insider.Live.Welcome.contract()["pairs_with"] do
        assert section =~ ~r/^  #{tool} +#{Regex.escape(use_for)}/m, tool
      end

      assert section =~ "observer_cli"
      assert section =~ "not for agents"
    end

    test "help OPERATION and OPERATION --help print its flags with values and examples",
         context do
      {0, text} = help(["help", "start"])
      assert {0, ^text} = help(["start", "--help"])
      assert {0, ^text} = help(["start" | target("app@localhost", context.cookie_file, ["-h"])])

      assert text =~ "--logger-include"
      assert text =~ "module:NAME"
      assert text =~ "--telemetry-event-min-duration"
      assert text =~ "KIND=MS"
      assert text =~ "mix insider.live start \"${N[@]}\" --component logger"

      {0, submit} = help(["help", "reports", "submit"])
      assert submit =~ "--confirm"
      assert submit =~ "mix insider.live reports submit --confirm"
    end

    test "a JSON logger rule names the option and the CLI rule syntax", context do
      {64, document} =
        single([
          "start"
          | target("app@localhost", context.cookie_file, [
              "--logger-include",
              ~s({"module":"Shop.Checkout"})
            ])
        ])

      assert %{"code" => "invalid_options", "details" => details} = document["error"]
      assert details["option"] == "--logger-include"
      assert details["problem"] == "malformed"
      refute Map.has_key?(details, "value")
      assert details["expected"] =~ "module:NAME"
      assert details["help"] == "mix insider.live help start"
    end

    for {arguments, option, problem, expected} <- [
          {["events", "--session", "s", "--cursor", "abc"], "--cursor", "malformed",
           "INTEGER >= 0"},
          {["events", "--session", "s", "--cursor", "-1"], "--cursor", "out_of_range",
           "INTEGER >= 0"},
          {["events", "--session", "s", "--cursor", "0", "--limit", "0"], "--limit",
           "out_of_range", "INTEGER 1..500"},
          {["start", "--frobnicate"], "--frobnicate", "unknown", "--logger-include"},
          {["start", "--Bearer-Abc123"], nil, "unknown", "--logger-include"},
          {["status", "--cursor", "0"], "--cursor", "not_accepted", "--session"},
          {["status", "live-6"], nil, "positional_argument", "--session"},
          {["start", "--timeout-ms", "60001"], "--timeout-ms", "out_of_range", "1..60000"},
          {["start", "--telemetry-event", "a..b"], "--telemetry-event", "malformed",
           "dotted event name"},
          {["start", "--lease-ms", "0"], "--lease-ms", "out_of_range", "INTEGER 1000..900000"}
        ] do
      test "#{Enum.join(arguments, " ")} names #{option || "the argument"} and its syntax",
           context do
        [operation | rest] = unquote(arguments)
        {64, document} = single([operation | target("app@localhost", context.cookie_file, rest)])

        assert %{"code" => "invalid_options", "details" => details} = document["error"]
        assert details["option"] == unquote(option)
        assert details["problem"] == unquote(problem)
        assert details["expected"] =~ unquote(expected)
        assert details["help"] == "mix insider.live help #{operation}"
      end
    end

    # A value typed into the wrong place may be a secret: errors name the flag
    # and its syntax, never the value, and nothing of it reaches the report
    # context.
    @canary "Bearer SYNTHETIC_D7S_CANARY_9f3a"
    for arguments <- [
          ["start", "--logger-include", ~s({"authorization":"#{@canary}"})],
          ["start", "--logger-exclude", @canary],
          ["start", "--exclude-origin", "domain:#{@canary}"],
          ["start", "--exclude-origin", "none", "--exclude-origin", @canary],
          ["start", "--telemetry-event-min-duration", "#{@canary}=fast"],
          ["start", "--telemetry-event", "a..#{@canary}"],
          ["start", "--lease-ms", @canary],
          ["events", "--session", "s", "--cursor", @canary],
          ["events", "--session", "s", "--cursor", "0", "--scan-limit", @canary],
          ["watch", "--session", "s", "--from-cursor", @canary],
          ["watch", "--session", "s", "--for", @canary],
          ["status", @canary],
          ["status", "--session", "s", @canary],
          ["start", "--" <> String.replace(@canary, " ", "-")]
        ] do
      test "no error echoes a mistyped value: #{Enum.join(arguments, " ") |> String.slice(0, 60)}",
           context do
        [operation | rest] = unquote(arguments)

        {status, output} =
          observe([operation | target("app@localhost", context.cookie_file, rest)])

        assert status == 64
        assert [%{"error" => %{"code" => "invalid_options", "details" => details}}] = output
        assert details["expected"] != ""
        refute Jason.encode!(output) =~ "SYNTHETIC_D7S_CANARY"
      end
    end

    test "a target flag without --node is refused for an optional target", context do
      {64, document} = single(["reports", "--cookie-file", context.cookie_file])

      assert %{"option" => "--cookie-file", "problem" => "requires_node", "expected" => expected} =
               document["error"]["details"]

      assert expected =~ "mode 0600"
    end

    for {flag, value} <- [
          {"--logger-include", "oban"},
          {"--logger-exclude", "domain"},
          {"--exclude-origin", "domain:otp"},
          {"--telemetry-event-min-duration", "kind"},
          {"--telemetry-event-min-duration", "kind=fast"},
          {"--telemetry-duration-scope", "kind"},
          {"--telemetry-duration-scope", "kind=server_callback"},
          {"--telemetry-duration-scope", "=handler"}
        ] do
      test "#{flag} #{value} is refused before connecting", context do
        {64, document} =
          single([
            "start"
            | target("app@localhost", context.cookie_file, [unquote(flag), unquote(value)])
          ])

        assert document["error"]["code"] == "invalid_options"
        assert document["error"]["details"]["option"] == unquote(flag)
        assert document["error"]["details"]["expected"] == Help.value("start", unquote(flag))
        refute Map.has_key?(document["error"]["details"], "value")
      end
    end

    test "--exclude-origin none cannot be combined with an origin", context do
      {64, document} =
        single([
          "start"
          | target("app@localhost", context.cookie_file, [
              "--exclude-origin",
              "none",
              "--exclude-origin",
              "oban"
            ])
        ])

      assert document["error"]["details"]["option"] == "--exclude-origin"
    end

    test "a repeated --telemetry-event-min-duration kind is refused", context do
      {64, document} =
        single([
          "start"
          | target("app@localhost", context.cookie_file, [
              "--telemetry-event-min-duration",
              "a.b=1",
              "--telemetry-event-min-duration",
              "a.b=2"
            ])
        ])

      assert document["error"]["details"]["option"] == "--telemetry-event-min-duration"
    end

    test "--telemetry-duration-scope declares each kind's scope once, as a map", _context do
      target = ~w(--node app@localhost --cookie-file /x)

      assert {:ok, %{arguments: start}} =
               CLI.parse(
                 ~w(start --telemetry-summary a.b --telemetry-summary c.d --telemetry-duration-scope a.b=handler --telemetry-duration-scope c.d=caller) ++
                   target
               )

      assert start["telemetry_duration_scopes"] == %{"a.b" => "handler", "c.d" => "caller"}

      assert {:error, "invalid_options",
              %{"option" => "--telemetry-duration-scope", "problem" => "malformed"}} =
               CLI.parse(
                 ~w(start --telemetry-duration-scope a.b=handler --telemetry-duration-scope a.b=caller) ++
                   target
               )

      assert {:ok, %{arguments: %{options: amend}}} =
               CLI.parse(~w(amend --session s --reset telemetry-duration-scope) ++ target)

      assert amend == %{"telemetry_duration_scopes" => nil}
    end

    # Command lines that agents tried and the parser refused.
    test "flags agents tried: --reader anywhere a session is read, --trace for --trace-id, help with target flags",
         _context do
      target = ~w(--node app@localhost --cookie-file /x)

      for arguments <- [
            ~w(status --session s --reader me),
            ~w(status --reader me),
            ~w(welcome --reader me),
            ~w(capabilities --reader me),
            ~w(handoff --session s --reader me),
            ~w(renew --session s --reader me),
            ~w(marks --session s --reader me)
          ] do
        assert {:ok, _command} = CLI.parse(arguments ++ target), inspect(arguments)
      end

      # Reads default to the node's active session; stop and amend do not.
      assert {:ok, %{arguments: %{session: :active}}} = CLI.parse(~w(status) ++ target)
      assert {:ok, %{arguments: %{session: :active}}} = CLI.parse(~w(digest --human) ++ target)

      assert {:ok, %{arguments: %{session: :active, cursor: "mark"}}} =
               CLI.parse(~w(events --since-mark) ++ target)

      assert {:error, "invalid_options", %{"option" => "--session", "problem" => "missing"}} =
               CLI.parse(~w(stop) ++ target)

      assert {:error, "invalid_options", %{"option" => "--session", "problem" => "missing"}} =
               CLI.parse(~w(amend --lease-ms 60000) ++ target)

      trace_id = String.duplicate("a", 32)

      for arguments <- [["--trace", trace_id], ["--trace=" <> trace_id]] do
        assert {:ok, %{arguments: %{trace_id: ^trace_id}}} =
                 CLI.parse(["trace", "--session", "s" | arguments] ++ target)
      end

      assert {:help, help} = CLI.parse(~w(help trace) ++ target)
      assert help == elem(CLI.parse(~w(help trace)), 1)

      # A flag an operation does not take names the operations that do.
      assert {:error, "invalid_options",
              %{"option" => "--view-clear", "accepted_by" => by} = details} =
               CLI.parse(~w(mark --session s --label x --view-clear) ++ target)

      assert "events" in by and "digest" in by and "mark" not in by
      assert details["expected"] =~ "--view-clear is not a mark flag; it works on "
    end

    test "chart takes a window, an output path, or --serve with a port and a duration",
         _context do
      target = ~w(--node app@localhost --cookie-file /x)

      assert {:ok, %{operation: "chart", arguments: static}} =
               CLI.parse(~w(chart --session s --since-mark --out /tmp/c.html) ++ target)

      assert %{session: "s", since: "mark", out: "/tmp/c.html", serve?: false} = static
      assert String.match?(static.reader, ~r/\Achart-[0-9a-f]{8}\z/)

      assert {:ok, %{arguments: %{since: "latest-5m", out: nil}}} =
               CLI.parse(~w(chart --since latest-5m) ++ target)

      assert {:ok, %{arguments: %{serve?: true, port: 0, for_ms: 1_800_000, session: :active}}} =
               CLI.parse(~w(chart --serve) ++ target)

      assert {:ok,
              %{arguments: %{serve?: true, port: 8123, for_ms: 300_000, reader: "pair-view"}}} =
               CLI.parse(~w(chart --serve --port 8123 --for 5m --reader pair-view) ++ target)

      for {arguments, flag} <- [
            {~w(chart --serve --out /tmp/c.html), "--out"},
            {~w(chart --for 5m), "--for"},
            {~w(chart --port 8123), "--port"},
            {~w(chart --since 0 --since-mark), "--since-mark"}
          ] do
        assert {:error, "invalid_options", %{"option" => ^flag, "problem" => "not_accepted"}} =
                 CLI.parse(arguments ++ target),
               inspect(arguments)
      end
    end

    test "mark takes a label; --since-mark takes an optional label on digest, trends, events and timeline",
         _context do
      target = ~w(--node app@localhost --cookie-file /x)

      assert {:ok, %{operation: "mark", arguments: mark}} =
               CLI.parse(
                 ["mark", "--session", "s", "--label", "about to click Confirm", "--reader", "me"] ++
                   target
               )

      assert mark == %{
               session: "s",
               options: %{"label" => "about to click Confirm", "reader" => "me"}
             }

      assert {:ok,
              %{
                operation: "marks",
                arguments: %{session: "s", options: %{"human" => true}, human?: true}
              }} =
               CLI.parse(~w(marks --session s --human) ++ target)

      # Bare: the newest mark, whether another flag or nothing follows.
      for arguments <- [
            ~w(digest --session s --since-mark --human),
            ~w(digest --session s --human --since-mark)
          ] do
        assert {:ok, %{arguments: %{options: %{"since" => "mark", "human" => true}}}} =
                 CLI.parse(arguments ++ target),
               inspect(arguments)
      end

      assert {:ok, %{arguments: %{options: %{"since" => "mark:about to click Confirm"}}}} =
               CLI.parse(
                 ["digest", "--session", "s", "--since-mark", "about to click Confirm"] ++ target
               )

      assert {:ok, %{arguments: %{options: %{"since" => "mark"}}}} =
               CLI.parse(~w(trends --session s --since-mark) ++ target)

      assert {:ok, %{arguments: %{options: %{"since" => "mark:open cart"}}}} =
               CLI.parse(["baseline", "--session", "s", "--since-mark", "open cart"] ++ target)

      assert {:ok, %{arguments: %{cursor: "mark:open cart"}}} =
               CLI.parse(["events", "--session", "s", "--since-mark", "open cart"] ++ target)

      assert {:ok, %{arguments: %{options: %{"since" => "mark", "request_id" => "r1"}}}} =
               CLI.parse(~w(timeline --session s --request-id r1 --since-mark) ++ target)

      # events reads from exactly one of --cursor and --since-mark; digest
      # from one of --since and --since-mark.
      for arguments <- [
            ~w(events --session s),
            ~w(events --session s --cursor 0 --since-mark),
            ~w(digest --session s --since 0 --since-mark)
          ] do
        assert {:error, "invalid_options", %{"option" => option, "problem" => problem}} =
                 CLI.parse(arguments ++ target),
               inspect(arguments)

        assert option in ["--cursor", "--since-mark"]
        assert problem in ["missing", "not_accepted"]
      end

      assert {:error, "invalid_options", %{"option" => "--label", "problem" => "missing"}} =
               CLI.parse(~w(mark --session s) ++ target)
    end

    test "--watch-write repeats into watch_writes, and changes takes a key, human text and a reader",
         _context do
      target = ~w(--node app@localhost --cookie-file /x)

      assert {:ok, %{arguments: start}} =
               CLI.parse(
                 ~w(start --component calls --watch-write A.set/2 --watch-write Application.put_env/3) ++
                   target
               )

      assert start["watch_writes"] == ["A.set/2", "Application.put_env/3"]

      assert {:ok, %{operation: "changes", arguments: changes}} =
               CLI.parse(~w(changes --session s --key flag-x --human --reader me) ++ target)

      assert changes == %{
               session: "s",
               options: %{"key" => "flag-x", "human" => true, "reader" => "me"},
               human?: true
             }

      assert {:ok, %{operation: "mutations", arguments: mutations}} =
               CLI.parse(~w(mutations --session s --id so-123 --human) ++ target)

      assert mutations == %{
               session: "s",
               options: %{"id" => "so-123", "human" => true},
               human?: true
             }

      assert {:ok, %{operation: "baseline", arguments: baseline}} =
               CLI.parse(~w(baseline --session s --since latest-5m --human) ++ target)

      assert baseline == %{
               session: "s",
               options: %{"since" => "latest-5m", "human" => true},
               human?: true
             }

      assert {:ok, %{arguments: %{options: %{"clear" => true}}}} =
               CLI.parse(~w(baseline --session s --clear) ++ target)

      assert {:ok, %{arguments: %{options: %{"show_baseline" => true}}}} =
               CLI.parse(~w(digest --session s --show-baseline) ++ target)
    end

    # --session defaults to the node's active session.
    test "events requires a cursor or a mark", context do
      {64, document} = single(["events" | target("app@localhost", context.cookie_file)])
      assert document["error"]["code"] == "invalid_options"
      assert document["error"]["details"]["option"] == "--cursor"

      {64, document} =
        single(["events" | target("app@localhost", context.cookie_file, ["--session", "s"])])

      assert document["error"]["details"]["missing"] == ["--cursor", "--since-mark"]
      assert document["error"]["details"]["expected"] =~ "or latest"
    end

    for {operation, base, flag, value, problem, expected} <- [
          {"events", [], "--cursor", "-1", "out_of_range", "or latest"},
          {"events", [], "--cursor", "newest", "malformed", "or latest"},
          {"events", ["--cursor", "0"], "--scan-limit", "0", "out_of_range", "INTEGER 1..1000"},
          {"watch", [], "--from-cursor", "1.5", "malformed", "or latest"},
          {"watch", [], "--for", "10", "malformed", "ms, s, m, or h"},
          {"watch", [], "--for", "0s", "malformed", "ms, s, m, or h"},
          {"watch", [], "--for", "25h", "out_of_range", "at most 24h"},
          {"watch", [], "--max-events", "0", "out_of_range", "events watch prints in total"}
        ] do
      test "#{operation} #{flag} #{value} is refused before connecting", context do
        options = ["--session", "live-1"] ++ unquote(base) ++ [unquote(flag), unquote(value)]

        {64, document} =
          single([unquote(operation) | target("app@localhost", context.cookie_file, options)])

        assert %{"code" => "invalid_options", "details" => details} = document["error"]
        assert details["option"] == unquote(flag)
        assert details["problem"] == unquote(problem)
        assert details["expected"] =~ unquote(expected)
        assert details["help"] == "mix insider.live help #{unquote(operation)}"
        refute Jason.encode!(document) =~ ~s("#{unquote(value)}")
      end
    end

    test "watch --for takes up to 24 hours and --max-events is the subscription budget",
         _context do
      assert {:ok, %{arguments: %{for_ms: 86_400_000, options: %{"max_events" => 5}}}} =
               CLI.parse(
                 ~w(watch --node app@localhost --cookie-file /x --session s --for 24h --max-events 5)
               )

      assert {:ok, %{arguments: %{options: %{"cursor" => "latest"}}}} =
               CLI.parse(
                 ~w(watch --node app@localhost --cookie-file /x --session s --from-cursor latest)
               )
    end

    # `digest --reader agent-a` used to be refused as not_accepted.
    test "every read takes --reader and the view flags, and --view-clear clears the view",
         _context do
      target = ~w(--node app@localhost --cookie-file /x --session s)

      view = ~w(--reader agent-a --view-exclude-signature 8083727a2588 --view-service web-a
                --view-route /marketplace --view-trace #{String.duplicate("a", 32)})

      expected = %{
        "exclude_signatures" => ["8083727a2588"],
        "services" => ["web-a"],
        "routes" => ["/marketplace"],
        "traces" => [String.duplicate("a", 32)]
      }

      for arguments <- [
            ~w(events --cursor 0),
            ~w(watch),
            ~w(digest --since latest-60s --human),
            ~w(trends),
            ["trace", "--trace-id", String.duplicate("b", 32)],
            ~w(timeline --pid <0.1.0>),
            ~w(changes),
            ~w(mutations),
            ~w(baseline)
          ] do
        # A view narrows only the read that gives it.
        assert {:ok,
                %{arguments: %{options: %{"reader" => "agent-a", "view" => ^expected} = options}}} =
                 CLI.parse(arguments ++ view ++ target),
               inspect(arguments)

        refute Map.has_key?(options, "view_keep")

        # --view-keep makes it the reader's stored view.
        assert {:ok, %{arguments: %{options: %{"view" => ^expected, "view_keep" => true}}}} =
                 CLI.parse(arguments ++ view ++ ["--view-keep"] ++ target),
               inspect(arguments)
      end

      assert {:ok, %{arguments: %{options: %{"reader" => "agent-a", "view" => %{}} = options}}} =
               CLI.parse(~w(digest --reader agent-a --view-clear) ++ target)

      refute Map.has_key?(options, "view_keep")

      # --view-clear with other view flags replaces the stored view with them.
      assert {:ok,
              %{
                arguments: %{
                  options: %{"view" => %{"kinds" => ["phoenix.*"]}, "view_keep" => true}
                }
              }} =
               CLI.parse(~w(digest --reader agent-a --view-clear --view-kind phoenix.*) ++ target)

      assert {:ok, %{arguments: %{options: options}}} =
               CLI.parse(~w(digest --reader agent-a) ++ target)

      refute Map.has_key?(options, "view")
    end

    # A view that silently became the reader's stored view hid 1,071 events
    # from a later trace; keeping one now takes --view-keep, which needs a
    # reader to keep it for and a view to keep.
    test "--view-keep needs --reader and a view flag", _context do
      target = ~w(--node app@localhost --cookie-file /x --session s)

      assert {:error, "invalid_options",
              %{"option" => "--view-keep", "problem" => "missing", "missing" => ["--reader"]} =
                details} =
               CLI.parse(~w(events --cursor 0 --view-min-severity warning --view-keep) ++ target)

      assert details["expected"] =~ "--reader"

      assert {:error, "invalid_options",
              %{"option" => "--view-keep", "problem" => "missing", "missing" => missing}} =
               CLI.parse(
                 ~w(trace --trace-id #{String.duplicate("b", 32)} --reader a --view-keep) ++
                   target
               )

      assert "--view-min-severity" in missing and "--view-kind" in missing
      refute "--view-clear" in missing

      assert {:error, "invalid_options", %{"option" => "--view-keep", "problem" => "missing"}} =
               CLI.parse(~w(digest --reader a --view-clear --view-keep) ++ target)

      assert {:error, "invalid_options", %{"option" => "--view-keep", "accepted_by" => by}} =
               CLI.parse(~w(mark --label x --view-keep) ++ target)

      assert "events" in by and "watch" in by
    end

    test "--reader, --force, and amend's recording flags reach the target's options", _context do
      target = ~w(--node app@localhost --cookie-file /x --session s)

      assert {:ok, %{arguments: %{options: %{"reader" => "agent-a", "limit" => 5}}}} =
               CLI.parse(~w(events --cursor 0 --limit 5 --reader agent-a) ++ target)

      assert {:ok, %{arguments: %{options: %{"reader" => "w"}}}} =
               CLI.parse(~w(watch --reader w) ++ target)

      assert {:ok, %{arguments: %{options: %{"reader" => "a", "force" => true}}}} =
               CLI.parse(~w(stop --reader a --force) ++ target)

      assert {:ok, %{arguments: %{options: options}}} = CLI.parse(["stop" | target])
      assert options == %{}

      assert {:ok, %{arguments: %{session: "s", options: amend}}} =
               CLI.parse(
                 ~w(amend --telemetry-event a.b --telemetry-measurement duration --logger-level debug --reader a) ++
                   target
               )

      assert amend == %{
               "telemetry_events" => [["a", "b"]],
               "telemetry_measurements" => ["duration"],
               "logger_level" => "debug",
               "reader" => "a"
             }

      assert {:ok, %{arguments: %{session: "s"}}} = CLI.parse(["handoff" | target])

      assert {:error, "invalid_options", %{"option" => "--force", "problem" => "not_accepted"}} =
               CLI.parse(~w(events --cursor 0 --force) ++ target)

      assert {:error, "invalid_options", %{"option" => "--session", "problem" => "missing"}} =
               CLI.parse(~w(amend --logger-level debug --node app@localhost --cookie-file /x))
    end

    test "the inspections pass their flags to the target's options and refuse others", _context do
      target = ~w(--node app@localhost --cookie-file /x)

      assert {:ok, %{operation: "process", arguments: process}} =
               CLI.parse(~w(process --name Shop.Pricing --frames 3 --messages 5) ++ target)

      assert process == %{"name" => "Shop.Pricing", "frames" => 3, "messages" => 5}

      assert {:ok, %{arguments: %{"pid" => "<0.200.0>"}}} =
               CLI.parse(["process", "--pid", "<0.200.0>" | target])

      assert {:ok, %{arguments: %{"type" => "cat", "owner" => "Shop.Shipping", "top" => 50}}} =
               CLI.parse(~w(ports --type cat --owner Shop.Shipping --top 50) ++ target)

      assert {:ok, %{arguments: %{}}} = CLI.parse(["ports" | target])

      assert {:ok, %{arguments: %{options: %{"top" => 5}, human?: false}}} =
               CLI.parse(~w(bin_leak --top 5) ++ target)

      assert {:ok, %{arguments: %{options: %{"human" => true}, human?: true}}} =
               CLI.parse(~w(bin_leak --human) ++ target)

      assert {:ok, %{arguments: %{"top" => 2}}} = CLI.parse(~w(alloc --top 2) ++ target)

      assert {:ok, %{arguments: %{"top_ports" => 3, "components" => ["poller"]}}} =
               CLI.parse(~w(start --component poller --top-ports 3) ++ target)

      assert {:error, "invalid_options", %{"option" => "--type", "problem" => "not_accepted"}} =
               CLI.parse(~w(bin_leak --type cat) ++ target)

      assert {:error, "invalid_options", %{"option" => "--top", "problem" => "repeated"}} =
               CLI.parse(~w(ports --top 1 --top 2) ++ target)

      assert {:error, "invalid_options", %{"option" => "--node", "problem" => "missing"}} =
               CLI.parse(~w(process --name Shop.Pricing))
    end

    # An amendment can return a recording
    # option to its default, the target's `nil`.
    test "amend --reset sends a recording option back to its default", _context do
      target = ~w(--node app@localhost --cookie-file /x --session s)

      assert {:ok, %{arguments: %{options: amend}}} =
               CLI.parse(
                 ~w(amend --reset watch-process --reset poller-interval-ms --reset telemetry-event-min-duration --reset otel-min-duration-ms --top-processes 3) ++
                   target
               )

      assert amend == %{
               "watch_processes" => nil,
               "poller_interval_ms" => nil,
               "telemetry_event_min_duration_ms" => nil,
               "otel_min_duration_ms" => nil,
               "top_processes" => 3
             }

      for value <- ["session", "reader", "--watch-process", "nothing"] do
        assert {:error, "invalid_options", %{"option" => "--reset", "problem" => "malformed"}} =
                 CLI.parse(["amend", "--reset", value] ++ target)
      end

      # A flag is either set or reset.
      assert {:error, "invalid_options", %{"option" => "--reset", "problem" => "malformed"}} =
               CLI.parse(~w(amend --reset top-processes --top-processes 3) ++ target)

      assert {:error, "invalid_options", %{"option" => "--reset", "problem" => "not_accepted"}} =
               CLI.parse(~w(start --reset top-processes --node app@localhost --cookie-file /x))
    end

    for {option, first, second} <- [
          {"--node", "app@203.0.113.7", "app@localhost"},
          {"--cookie-file", "/nonexistent/one", :cookie_file},
          {"--timeout-ms", "1000", "2000"},
          {"--lease-ms", "10000", "1000"},
          {"--load", nil, nil}
        ] do
      test "a repeated #{option} is refused before connecting", context do
        repeated =
          case {unquote(option), unquote(first), unquote(second)} do
            {flag, nil, nil} -> [flag, flag]
            {flag, value, :cookie_file} -> [flag, value, flag, context.cookie_file]
            {flag, one, two} -> [flag, one, flag, two]
          end

        # Every required option once, except the one under test.
        base =
          case unquote(option) do
            "--node" -> ["--cookie-file", context.cookie_file]
            "--cookie-file" -> ["--node", "app@localhost"]
            _other -> ["--node", "app@localhost", "--cookie-file", context.cookie_file]
          end

        {64, document} = single(["start" | base ++ repeated])
        assert document["error"]["code"] == "invalid_options"
        assert document["error"]["details"]["repeated"] == [unquote(option)]
        assert document["error"]["details"]["option"] == unquote(option)
        assert document["error"]["details"]["problem"] == "repeated"
      end
    end
  end

  defp help(arguments) do
    owner = self()
    reference = make_ref()

    status =
      CLI.run(arguments, fn bytes ->
        send(owner, {reference, IO.iodata_to_binary(bytes)})
        :ok
      end)

    assert_received {^reference, text}
    refute_received {^reference, _more}
    {status, text}
  end

  defp measurements(entry), do: entry["event"]["attributes"]["measurements"]
end
