defmodule Insider.Lab.LiveReportsTest do
  # Every test has its own reports directory and `gh` runner, and none starts
  # distribution, so these run concurrently. No test contacts GitHub: the
  # runner is always injected.
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Reports
  alias Insider.Live.Report
  alias Insider.Live.Welcome

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-live-reports-" <> suffix)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  # A `gh` stand-in: it records every call and answers from `responses`, a
  # function of the arguments.
  defp gh(responses) do
    owner = self()

    fn arguments ->
      send(owner, {:gh, arguments})
      responses.(arguments)
    end
  end

  defp no_gh do
    fn arguments -> flunk("gh must not run: #{inspect(arguments)}") end
  end

  defp run(arguments, context, options \\ []) do
    owner = self()
    reference = make_ref()

    options =
      Keyword.merge(
        [
          reports_directory: context.directory,
          gh: no_gh(),
          submission: "manual",
          notice: fn bytes -> send(owner, {:notice, IO.iodata_to_binary(bytes)}) end
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

    assert_received {^reference, line}
    refute_received {^reference, _more}
    {status, Jason.decode!(line)}
  end

  defp report(context, category, message),
    do: run(["report", "--category", category, "--message", message], context)

  describe "report" do
    test "files into the observer queue with the last target call and local failure as context",
         context do
      missing = Path.join(context.directory, "no-cookie")

      {64, failed} =
        run(
          ["status", "--node", "app@127.0.0.1", "--cookie-file", missing, "--session", "s"],
          context
        )

      assert failed["error"]["code"] == "cookie_file_unreadable"

      # A command that never reaches a target is the local failure; text that
      # names no operation is not recorded.
      {64, usage} = run(["frobnicate", "--secret-flag"], context)
      assert usage["error"]["code"] == "usage"

      {0, filed} = report(context, "doc_mismatch", "status said X but did Y")

      assert %{"schema" => "insider.live-observer/v1", "operation" => "report"} = filed
      refute Map.has_key?(filed, "target")
      receipt = filed["result"]
      assert receipt["queue"] == "observer"
      assert receipt["duplicate"] == false

      assert receipt["report"]["context"] == %{
               "transport" => "observer",
               "insider_version" => to_string(Application.spec(:insider, :vsn)),
               "insider_commit" => Insider.Live.Revision.commit(),
               "welcome_hash" => nil,
               "node" => "app@127.0.0.1",
               "environment" => nil,
               "last_operation" => "status",
               "last_error_code" => "cookie_file_unreadable",
               "last_local_operation" => nil,
               "last_local_error_code" => "usage",
               "session" => "s"
             }

      refute File.read!(Path.join(context.directory, "observer-state.json")) =~ "frobnicate"

      # A malformed option of a named operation records that operation, and
      # the last target call is kept.
      {64, invalid} = run(["events", "--cursor", "not-a-number"], context)
      {0, again} = report(context, "bug", "events rejected my cursor")

      assert %{
               "last_operation" => "status",
               "last_local_operation" => "events",
               "last_local_error_code" => code
             } = again["result"]["report"]["context"]

      assert code == invalid["error"]["code"]

      {0, listed} = run(["reports"], context)

      assert [%{"message" => "status said X but did Y", "submitted" => nil}, _again] =
               listed["result"]["reports"]
    end

    test "deduplicates by fingerprint and keeps the queue bounded", context do
      {0, _first} = report(context, "bug", "Same   report")
      {0, again} = report(context, "bug", "same report")
      assert again["result"]["duplicate"]
      assert again["result"]["report"]["count"] == 2

      maximum = Report.max_reports()

      for index <- 1..maximum do
        assert {:ok, _receipt} =
                 Reports.file(
                   context.directory,
                   %{category: "bug", message: "filler #{index}"},
                   DateTime.utc_now()
                 )
      end

      {0, listed} = run(["reports"], context)
      reports = listed["result"]["reports"]
      assert length(reports) == maximum
      refute Enum.any?(reports, &(&1["message"] == "Same report"))

      lines = context.directory |> Path.join("observer-reports.jsonl") |> File.read!()
      assert lines |> String.split("\n", trim: true) |> length() == maximum
      mode = File.stat!(Path.join(context.directory, "observer-reports.jsonl")).mode
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "refuses an unknown category, a bad message, and target options", context do
      {64, category} = report(context, "rant", "m")
      assert category["error"]["details"]["option"] == "--category"

      assert category["error"]["details"]["expected"] ==
               Enum.join(Insider.Live.Options.report_categories(), " | ")

      {64, message} = report(context, "bug", String.duplicate("x", 2_049))
      assert message["error"]["details"]["option"] == "--message"
      assert message["error"]["details"]["expected"] =~ "at most 2048 bytes"
      refute Map.has_key?(message["error"]["details"], "value")

      {64, targeted} =
        run(["report", "--category", "bug", "--message", "m", "--node", "a@localhost"], context)

      assert targeted["error"]["details"]["unexpected"] == ["--node"]
      refute File.exists?(Path.join(context.directory, "observer-reports.jsonl"))
    end

    test "an optional target needs both --node and --cookie-file", context do
      {64, document} = run(["reports", "--node", "a@localhost"], context)
      assert document["error"]["details"]["missing"] == ["--cookie-file"]

      {64, document} = run(["reports", "submit", "--timeout-ms", "100"], context)

      assert %{"option" => "--timeout-ms", "problem" => "requires_node"} =
               document["error"]["details"]
    end

    test "a mistyped secret leaves no trace in the error, the context, or the queue", context do
      canary = "Bearer SYNTHETIC_D7S_REPORT_CANARY"

      for arguments <- [
            ["report", "--category", canary, "--message", "m"],
            ["reports", "submit", canary],
            ["reports", "--node", "a@localhost", "--cookie-file", "/nonexistent", "--x", canary]
          ] do
        {64, document} = run(arguments, context)
        refute Jason.encode!(document) =~ ~r/report.canary/i
      end

      {0, filed} = report(context, "bug", "after a mistyped value")
      refute Jason.encode!(filed) =~ ~r/report.canary/i

      for file <- Path.wildcard(Path.join(context.directory, "*")) do
        refute File.read!(file) =~ ~r/report.canary/i, file
      end
    end

    test "a refused host is kept out of the error and the next report's context",
         context do
      # Control: a target command refused after the host check is remembered,
      # so the context path the refused host must skip is the one exercised.
      {64, unreadable} =
        run(
          ["capabilities", "--node", "control@localhost", "--cookie-file", "/nonexistent"],
          context
        )

      assert unreadable["error"]["code"] == "cookie_file_unreadable"
      {0, control} = report(context, "bug", "after an unreadable cookie file")
      assert control["result"]["report"]["context"]["node"] == "control@localhost"

      host = "synthetic-report-canary.example"

      {64, refused} =
        run(["capabilities", "--node", "a@" <> host, "--cookie-file", "/x"], context)

      assert refused["error"]["code"] == "non_loopback_host"
      refute Jason.encode!(refused) =~ host

      {0, filed} = report(context, "bug", "after a refused host")
      refute Jason.encode!(filed["result"]["report"]["context"]) =~ host

      for file <- Path.wildcard(Path.join(context.directory, "*")) do
        refute File.read!(file) =~ host, file
      end
    end
  end

  describe "reports submit" do
    test "without an opt-in prints what it would send and runs nothing", context do
      {0, _filed} = report(context, "doc_mismatch", "welcome says renew renews; it did not")

      {0, document} = run(["reports", "submit"], context)
      result = document["result"]

      assert result["dry_run"]
      assert result["opt_in"] == nil
      assert result["repository"] == "hiivemarkets/insider"
      assert [issue] = result["would_create"]

      assert issue["title"] ==
               "[agent report] doc_mismatch: welcome says renew renews; it did not"

      assert issue["body"] =~ "insider-report-fingerprint: #{issue["fingerprint"]}"
      assert ["issue", "create", "--repo", "hiivemarkets/insider" | _] = issue["command"]
      refute_received {:gh, _arguments}

      {0, listed} = run(["reports"], context)
      assert [%{"submitted" => nil}] = listed["result"]["reports"]
    end

    test "with --confirm files each new fingerprint once", context do
      {0, _filed} = report(context, "bug", "first problem")
      {0, _filed} = report(context, "missing_capability", "second problem")

      runner =
        gh(fn
          ["issue", "list" | _rest] -> {"[]", 0}
          ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/7\n", 0}
        end)

      {0, document} = run(["reports", "submit", "--confirm"], context, gh: runner)
      result = document["result"]

      assert result["dry_run"] == false
      assert result["opt_in"] == "confirm"
      assert Enum.map(result["results"], & &1["action"]) == ["created", "created"]
      assert Enum.all?(result["results"], &(&1["url"] =~ "/issues/7"))

      assert_received {:gh, ["issue", "list", "--repo", "hiivemarkets/insider" | search]}
      assert Enum.any?(search, &(&1 =~ "insider-report-fingerprint:"))
      assert_received {:gh, ["issue", "create" | _arguments]}

      {0, again} = run(["reports", "submit", "--confirm"], context, gh: no_gh())
      assert again["result"]["already_submitted"] == 2
      assert again["result"]["results"] == []
    end

    test "links an issue that already exists upstream instead of creating one", context do
      {0, _filed} = report(context, "bug", "already filed elsewhere")

      runner =
        gh(fn ["issue", "list" | _rest] ->
          {~s([{"url":"https://github.com/hiivemarkets/insider/issues/3"}]), 0}
        end)

      {0, document} = run(["reports", "submit"], context, gh: runner, submission: "github")

      assert document["result"]["opt_in"] == "observer_config"
      assert [%{"action" => "existing", "url" => url}] = document["result"]["results"]
      assert url =~ "/issues/3"
      refute_received {:gh, ["issue", "create" | _]}
    end

    test "a gh failure is reported and leaves the report unsubmitted", context do
      {0, _filed} = report(context, "confusing_output", "unclear gap reason")

      runner =
        gh(fn _arguments ->
          {"gh: To get started with GitHub CLI, please run: gh auth login\n", 4}
        end)

      {1, document} = run(["reports", "submit", "--confirm"], context, gh: runner)

      assert document["error"]["code"] == "report_submit_failed"

      assert [%{"status" => "failed", "exit_status" => 4, "output" => output}] =
               document["error"]["details"]["results"]

      assert output =~ "gh auth login"

      {0, listed} = run(["reports"], context)
      assert [%{"submitted" => nil}] = listed["result"]["reports"]
    end

    test "the issue body carries context but not the node's host name", context do
      {64, _failed} =
        run(
          [
            "status",
            "--node",
            "app@127.0.0.1",
            "--cookie-file",
            "/nonexistent",
            "--session",
            "s"
          ],
          context
        )

      {0, _filed} = report(context, "bug", "body check")
      {0, document} = run(["reports", "submit"], context)
      [issue] = document["result"]["would_create"]

      assert issue["body"] =~ "| Node | `app` |"
      refute issue["body"] =~ "127.0.0.1"
      assert issue["body"] =~ "| Last target error code | `cookie_file_unreadable` |"
      assert issue["body"] =~ "| Last local failure | none |"
    end
  end

  describe "review regressions" do
    test "imports add only a node's new occurrences, independent of local reports", context do
      node_record = fn count ->
        %{category: "bug", message: "shared problem"}
        |> Report.new(%{}, ~U[2026-10-22 10:00:00Z])
        |> Map.put("count", count)
      end

      assert {:ok, %{"new_occurrences" => 1}} =
               Reports.import(context.directory, "a@h", [node_record.(1)])

      {0, _local} = report(context, "bug", "shared problem")

      assert {:ok, %{"new_occurrences" => 1}} =
               Reports.import(context.directory, "a@h", [node_record.(2)])

      assert {:ok, %{"new_occurrences" => 0}} =
               Reports.import(context.directory, "a@h", [node_record.(2)])

      {0, listed} = run(["reports"], context)
      assert [%{"count" => 3}] = listed["result"]["reports"]
    end

    test "a submission in progress blocks a second one before any gh call", context do
      {0, _filed} = report(context, "bug", "only once")
      File.write!(Path.join(context.directory, ".submit.lock"), "")

      {1, document} = run(["reports", "submit", "--confirm"], context, gh: no_gh())

      assert document["error"]["code"] == "report_queue_unavailable"
      assert document["error"]["details"]["reason"] == "locked"
    end

    test "a held queue lock is reported, never broken", context do
      File.mkdir_p!(context.directory)
      lock = Path.join(context.directory, ".lock")
      File.write!(lock, "")
      File.touch!(lock, System.os_time(:second) - 3_600)

      {1, document} = report(context, "bug", "blocked")

      assert document["error"]["details"]["path"] == lock
      assert File.exists?(lock)
    end
  end

  describe "merge and ledger regressions" do
    defp node_record(message, count \\ 1) do
      %{category: "bug", message: message}
      |> Report.new(%{}, ~U[2026-10-22 10:00:00Z])
      |> Map.put("count", count)
    end

    test "a target's opt-in submits only reports that came solely from that target", context do
      {:ok, _} = Reports.import(context.directory, "private@h", [node_record("private secret")])
      {:ok, _} = Reports.import(context.directory, "other@h", [node_record("other only")])
      {:ok, _} = Reports.import(context.directory, "other@h", [node_record("shared")])
      {0, _local} = report(context, "bug", "shared")

      runner =
        gh(fn
          ["issue", "list" | _rest] -> {"[]", 0}
          ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/1", 0}
        end)

      assert {:ok, result} =
               Reports.submit(context.directory, {"target_config", "other@h"}, runner)

      assert result["opt_in"] == "target_config"
      assert [%{"action" => "created"}] = result["results"]
      assert result["not_authorized"] == 2

      assert_received {:gh, ["issue", "create", "--repo", _, "--title", title | _]}
      assert title =~ "other only"
      refute_received {:gh, ["issue", "create" | _]}

      {0, listed} = run(["reports"], context)

      pending =
        for %{"submitted" => nil, "message" => message} <- listed["result"]["reports"],
            do: message

      assert Enum.sort(pending) == ["private secret", "shared"]
    end

    test "malformed persisted rows are counted and never reach submission", context do
      {0, _filed} = report(context, "bug", "good one")
      queue = Path.join(context.directory, "observer-reports.jsonl")
      [good] = queue |> File.read!() |> String.split("\n", trim: true)
      bad = good |> Jason.decode!() |> Map.put("message", 42) |> Jason.encode!()
      File.write!(queue, good <> "\n" <> bad <> "\n")
      File.write!(Path.join(context.directory, "submitted.jsonl"), ~s({"fingerprint":7}\n))

      {0, listed} = run(["reports"], context)
      assert listed["result"]["invalid_lines"] == 2
      assert [%{"message" => "good one", "submitted" => nil}] = listed["result"]["reports"]

      {0, dry_run} = run(["reports", "submit"], context)
      assert [%{"title" => title}] = dry_run["result"]["would_create"]
      assert title =~ "good one"
    end

    test "a queue row from before sources existed is kept with unknown provenance", context do
      File.mkdir_p!(context.directory)
      legacy = node_record("from the first format") |> Canonical.encode()
      File.write!(Path.join(context.directory, "observer-reports.jsonl"), legacy <> "\n")

      {0, listed} = run(["reports"], context)
      assert listed["result"]["invalid_lines"] == 0

      assert [%{"message" => "from the first format", "sources" => ["unknown"]}] =
               listed["result"]["reports"]

      {0, _filed} = report(context, "bug", "a newer one")
      {0, listed} = run(["reports"], context)

      assert [%{"sources" => ["unknown"]}, %{"sources" => ["observer"]}] =
               listed["result"]["reports"]

      # Unknown provenance is never covered by a target's own opt-in.
      assert {:ok, %{"results" => [], "not_authorized" => 2}} =
               Reports.submit(context.directory, {"target_config", "a@h"}, no_gh())

      {0, dry_run} = run(["reports", "submit"], context)
      assert [_legacy, _newer] = dry_run["result"]["would_create"]
    end

    test "a ledger row with a malformed timestamp is counted, not fatal", context do
      {0, filed} = report(context, "bug", "ledger check")
      fingerprint = filed["result"]["report"]["fingerprint"]

      rows =
        for submitted_at <- [%{}, [], 1, nil, "yesterday"] do
          Jason.encode!(%{
            "fingerprint" => fingerprint,
            "action" => "created",
            "url" => "https://github.com/hiivemarkets/insider/issues/1",
            "submitted_at" => submitted_at
          })
        end

      File.write!(Path.join(context.directory, "submitted.jsonl"), Enum.join(rows, "\n") <> "\n")

      {0, listed} = run(["reports"], context)
      assert listed["result"]["invalid_lines"] == 5
      assert [%{"submitted" => nil}] = listed["result"]["reports"]

      {0, dry_run} = run(["reports", "submit"], context)
      assert [_issue] = dry_run["result"]["would_create"]
    end

    test "the ledger keeps only queued fingerprints and upstream lookup covers the rest",
         context do
      created =
        gh(fn
          ["issue", "list" | _rest] -> {"[]", 0}
          ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/5", 0}
        end)

      {0, _filed} = report(context, "bug", "first report")
      {0, _sent} = run(["reports", "submit", "--confirm"], context, gh: created)

      for index <- 1..Report.max_reports() do
        {:ok, _receipt} =
          Reports.file(
            context.directory,
            %{category: "bug", message: "filler #{index}"},
            DateTime.utc_now()
          )
      end

      {0, _sent} = run(["reports", "submit", "--confirm"], context, gh: created)
      ledger = Path.join(context.directory, "submitted.jsonl")

      assert ledger |> File.read!() |> String.split("\n", trim: true) |> length() <=
               Report.max_reports()

      {0, _again} = report(context, "bug", "first report")

      existing =
        gh(fn ["issue", "list" | _rest] ->
          {~s([{"url":"https://github.com/hiivemarkets/insider/issues/5"}]), 0}
        end)

      {0, sent} = run(["reports", "submit", "--confirm"], context, gh: existing)
      assert [%{"action" => "existing"}] = sent["result"]["results"]
      # `existing` has no clause for `issue create`, so a create would fail the command.
      {0, _listed} = run(["reports"], context)
    end
  end

  describe "dry run, authorization, selection and sessions" do
    test "--dry-run previews and overrides every opt-in", context do
      {0, _filed} = report(context, "bug", "dry run preview")

      {0, document} =
        run(["reports", "submit", "--confirm", "--dry-run"], context, submission: "github")

      result = document["result"]
      assert result["dry_run"]
      assert result["opt_in"] == nil
      assert [%{"title" => "[agent report] bug: dry run preview"}] = result["would_create"]

      assert result["authorization"] == %{
               "effective" => "dry_run",
               "target" => nil,
               "opt_ins" => ["confirm", "observer_config"],
               "overridden_by" => "--dry-run"
             }

      refute_received {:gh, _arguments}
      refute_received {:notice, _line}

      {0, plain} = run(["reports", "submit", "--dry-run"], context)
      assert plain["result"]["authorization"]["overridden_by"] == nil
      assert plain["result"]["authorization"]["effective"] == "dry_run"
    end

    test "a real submission prints its authorization before its first gh call", context do
      {0, _filed} = report(context, "bug", "announce first")

      runner =
        gh(fn
          ["issue", "list" | _rest] -> {"[]", 0}
          ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/9", 0}
        end)

      {0, sent} = run(["reports", "submit"], context, gh: runner, submission: "github")
      assert sent["result"]["authorization"]["effective"] == "observer_config"

      assert_received first
      assert {:notice, line} = first
      notice = Jason.decode!(line)
      assert notice["schema"] == "insider.live-authorization/v1"

      assert notice["authorization"] ==
               Map.put(sent["result"]["authorization"], "will_submit", 1)

      assert_received {:gh, ["issue", "list" | _rest]}
    end

    test "the same report from two sessions stays selectable by each",
         context do
      file = fn session ->
        run(
          ["report", "--session", session, "--category", "bug", "--message", "same defect"],
          context
        )
      end

      {0, first} = file.("live-1")
      {0, second} = file.("live-2")
      {0, _again} = file.("live-2")
      assert second["result"]["duplicate"]
      fingerprint = first["result"]["report"]["fingerprint"]

      {0, all} = run(["reports"], context)
      assert [%{"count" => 3} = report] = all["result"]["reports"]

      assert report["occurrences"] == [
               %{"node" => nil, "session" => "live-1", "count" => 1},
               %{"node" => nil, "session" => "live-2", "count" => 2}
             ]

      assert all["result"]["groups"] == [
               %{
                 "node" => nil,
                 "session" => "live-1",
                 "fingerprints" => [fingerprint],
                 "count" => 1
               },
               %{
                 "node" => nil,
                 "session" => "live-2",
                 "fingerprints" => [fingerprint],
                 "count" => 2
               }
             ]

      for {session, count} <- [{"live-1", 1}, {"live-2", 2}] do
        {0, one} = run(["reports", "--session", session], context)

        assert [%{"fingerprint" => ^fingerprint, "count" => 3, "selected_count" => ^count}] =
                 one["result"]["reports"]

        assert [%{"session" => ^session, "count" => ^count}] = one["result"]["groups"]

        # GitHub deduplication stays global: one issue per fingerprint, with
        # the total count, whichever session selected it.
        {0, preview} = run(["reports", "submit", "--dry-run", "--session", session], context)

        assert [%{"fingerprint" => ^fingerprint, "selected_count" => ^count, "body" => body}] =
                 preview["result"]["would_create"]

        assert body =~ "**Reported:** 3 time(s)"
      end

      {0, none} = run(["reports", "--session", "live-3"], context)
      assert none["result"]["reports"] == [] and none["result"]["groups"] == []
    end

    test "occurrences are bounded and old rows read with their context's occurrence",
         context do
      for n <- 1..20 do
        {0, _filed} =
          run(
            ["report", "--session", "s#{n}", "--category", "bug", "--message", "bounded"],
            context
          )
      end

      {0, listed} = run(["reports"], context)
      [%{"count" => 20, "occurrences" => occurrences}] = listed["result"]["reports"]
      assert length(occurrences) == 16
      assert List.last(occurrences)["session"] == "s20"
      assert hd(occurrences)["session"] == "s5"

      # A row written before occurrences existed gets one from its context.
      File.rm_rf!(context.directory)
      File.mkdir_p!(context.directory)

      old =
        %{category: "bug", message: "old row"}
        |> Report.new(%{"node" => "a@h", "session" => "live-9"}, ~U[2026-10-22 10:00:00Z])
        |> Map.put("count", 2)
        |> Map.put("sources", ["observer"])

      File.write!(Path.join(context.directory, "observer-reports.jsonl"), [
        Canonical.encode(old),
        "\n"
      ])

      {0, read} = run(["reports", "--session", "live-9"], context)

      assert [%{"occurrences" => [%{"node" => "a@h", "session" => "live-9", "count" => 2}]}] =
               read["result"]["reports"]

      # A malformed occurrence list makes the row invalid.
      bad = Map.put(old, "occurrences", [%{"node" => 1}])

      File.write!(Path.join(context.directory, "observer-reports.jsonl"), [
        Canonical.encode(bad),
        "\n"
      ])

      {0, invalid} = run(["reports"], context)
      assert invalid["result"]["invalid_lines"] == 1
    end

    test "--fingerprint and --session select what is listed and submitted", context do
      {0, a} =
        run(["report", "--session", "live-1", "--category", "bug", "--message", "a"], context)

      {0, b} =
        run(["report", "--session", "live-2", "--category", "bug", "--message", "b"], context)

      {0, c} = report(context, "bug", "c")
      [fa, fb, fc] = Enum.map([a, b, c], & &1["result"]["report"]["fingerprint"])

      assert a["result"]["report"]["context"]["session"] == "live-1"
      assert c["result"]["report"]["context"]["session"] == nil

      {0, listed} = run(["reports"], context)

      assert listed["result"]["groups"] == [
               %{"node" => nil, "session" => "live-1", "fingerprints" => [fa], "count" => 1},
               %{"node" => nil, "session" => "live-2", "fingerprints" => [fb], "count" => 1},
               %{"node" => nil, "session" => nil, "fingerprints" => [fc], "count" => 1}
             ]

      {0, one} = run(["reports", "--session", "live-2"], context)
      assert [%{"fingerprint" => ^fb}] = one["result"]["reports"]
      assert one["result"]["queued"] == 3

      missing = "0123456789abcdef"

      {0, preview} =
        run(["reports", "submit", "--fingerprint", fa, "--fingerprint", missing], context)

      assert [%{"fingerprint" => ^fa}] = preview["result"]["would_create"]
      assert preview["result"]["selection"]["unmatched_fingerprints"] == [missing]

      runner =
        gh(fn
          ["issue", "list" | _rest] -> {"[]", 0}
          ["issue", "create" | _rest] -> {"https://github.com/hiivemarkets/insider/issues/3", 0}
        end)

      {0, sent} =
        run(["reports", "submit", "--confirm", "--session", "live-1"], context, gh: runner)

      assert [%{"fingerprint" => ^fa, "action" => "created"}] = sent["result"]["results"]

      for bad <- [["--fingerprint", "XYZ"], ["--session", ""]] do
        {64, refused} = run(["reports", "submit" | bad], context)
        assert refused["error"]["code"] == "invalid_options"
      end
    end

    test "a malformed --session is invalid_options for every report command, never echoed",
         context do
      longest = "l" <> String.duplicate("x", 127)

      commands = [
        ["report", "--category", "bug", "--message", "m"],
        ["reports"],
        ["reports", "submit"]
      ]

      for command <- commands,
          bad <- [<<255>>, "live-1\n", "live 1", "-live", "", longest <> "x", "liv\u00e9-1"] do
        {status, refused} = run(command ++ ["--session", bad], context)
        assert status == 64, inspect({command, bad})

        assert %{
                 "code" => "invalid_options",
                 "details" => %{"option" => "--session", "problem" => "malformed"}
               } = refused["error"]

        if bad != "", do: refute(inspect(refused) =~ inspect(bad)), else: :ok
      end

      for command <- commands, good <- ["live-1Z", "a", longest, "live-9.x:y_z"] do
        assert {0, _accepted} = run(command ++ ["--session", good], context)
      end
    end

    test "the session of the last target command carries into the next report", context do
      :ok =
        Reports.remember(context.directory, %{
          "node" => "a@h",
          "operation" => "events",
          "session" => "live-7"
        })

      :ok = Reports.remember(context.directory, %{"node" => "a@h", "operation" => "capabilities"})
      {0, carried} = report(context, "bug", "carried")
      assert carried["result"]["report"]["context"]["session"] == "live-7"

      :ok = Reports.remember(context.directory, %{"node" => "b@h", "operation" => "capabilities"})
      {0, other} = report(context, "bug", "other node")
      assert other["result"]["report"]["context"]["session"] == nil
    end
  end

  describe "durable reports directory" do
    test "is per user and survives reboots, unless INSIDER_LIVE_REPORTS_DIR names one" do
      home = "/home/agent"
      darwin = {:unix, :darwin}
      linux = {:unix, :linux}

      assert Reports.directory_for(%{}, darwin, "/Users/agent") ==
               "/Users/agent/Library/Application Support/insider-live"

      assert Reports.directory_for(%{}, linux, home) == "/home/agent/.local/state/insider-live"

      assert Reports.directory_for(%{"XDG_STATE_HOME" => "/var/state"}, linux, home) ==
               "/var/state/insider-live"

      # The XDG specification ignores a relative path.
      assert Reports.directory_for(%{"XDG_STATE_HOME" => "state"}, linux, home) ==
               "/home/agent/.local/state/insider-live"

      for os <- [darwin, linux] do
        assert Reports.directory_for(%{"INSIDER_LIVE_REPORTS_DIR" => "/q"}, os, home) == "/q"
        assert Reports.directory_for(%{"INSIDER_LIVE_REPORTS_DIR" => ""}, os, home) =~ home
      end

      # The test helper points INSIDER_LIVE_REPORTS_DIR at a scratch directory.
      assert Reports.default_directory() == System.get_env("INSIDER_LIVE_REPORTS_DIR")
    end

    test "records from before the local failure context are read with it as nil", context do
      File.mkdir_p!(context.directory)
      old = old_record("from before local failures")

      refute Report.record?(old)
      assert Report.record?(Report.upgrade(old))

      rows = [old, Map.put(old_record("with sources"), "sources", ["a@h"])]

      File.write!(
        Path.join(context.directory, "observer-reports.jsonl"),
        Enum.map(rows, &[Canonical.encode(&1), "\n"])
      )

      {0, listed} = run(["reports"], context)
      assert listed["result"]["invalid_lines"] == 0

      assert [%{"sources" => ["unknown"]} = first, %{"sources" => ["a@h"]}] =
               listed["result"]["reports"]

      assert %{"last_local_operation" => nil, "last_local_error_code" => nil} = first["context"]

      assert {:ok, %{"records" => 1, "invalid" => 0}} =
               Reports.import(context.directory, "b@h", [old_record("imported")])
    end
  end

  # A node record as written before the local failure context keys existed.
  defp old_record(message) do
    %{category: "bug", message: message}
    |> Report.new(%{}, ~U[2026-10-22 10:00:00Z])
    |> update_in(["context"], &Map.drop(&1, ["last_local_operation", "last_local_error_code"]))
  end

  test "the welcome documents exactly the observer's commands and options" do
    documented =
      Map.new(Welcome.observer_commands(), fn command ->
        {command["name"], {command["target"], command["required"], command["optional"]}}
      end)

    implemented =
      Map.new(CLI.operations(), fn {name, {target, required, optional}} ->
        {name, {Atom.to_string(target), flags(required), flags(optional)}}
      end)

    assert implemented == documented
    assert flags(CLI.target_flags()) == Welcome.observer_target_flags()
    # Every receipt, which never carries the welcome, is an observer command.
    assert Welcome.observer_receipts() -- Map.keys(documented) == []

    assert flags(CLI.repeatable()) ==
             Enum.sort(Welcome.contract()["transports"]["observer"]["repeatable"])
  end

  test "every observer switch has its value syntax in the welcome, and no other" do
    assert flags(Keyword.keys(CLI.switches())) == Enum.sort(Map.keys(Welcome.observer_options()))
  end

  test "every quick start, recipe, and example command parses with the observer's parser" do
    examples = Welcome.example_commands()
    assert length(examples) > 20

    for example <- examples do
      assert {:ok, _command} = example |> arguments() |> CLI.parse(), example
    end

    assert {:ok, %{timeout_ms: 60_000}} =
             CLI.parse(
               arguments("mix insider.live status \"${N[@]}\" --session s --timeout-ms 60000")
             )

    assert Welcome.observer_options()["--timeout-ms"]["value"] =~ "1..60000"
  end

  test "the guard rejects a quick start command that no longer parses" do
    for broken <- [
          # --session now defaults to the active session; a cursor or a mark does not.
          "mix insider.live events \"${N[@]}\" --session SESSION_ID",
          "mix insider.live start \"${N[@]}\" --logger-include Shop.Checkout",
          "mix insider.live start \"${N[@]}\" --telemetry-measurement",
          "mix insider.live tail \"${N[@]}\" --session SESSION_ID"
        ] do
      assert {:error, _code, _details} = broken |> arguments() |> CLI.parse(), broken
    end
  end

  # An example as the shell would pass it, with `"${N[@]}"` expanded to the quick
  # start's own target setup.
  defp arguments(example) do
    [_, target] = Regex.run(~r/\AN=\((.*)\)\z/, Welcome.contract()["quick_start"]["setup"])
    [_, rest] = Regex.run(~r/\A(?:timeout \d+ )?mix insider\.live (.*)\z/, example)
    rest |> String.replace("\"${N[@]}\"", target) |> OptionParser.split()
  end

  defp flags(keys),
    do: keys |> Enum.map(&("--" <> String.replace(Atom.to_string(&1), "_", "-"))) |> Enum.sort()
end
