defmodule Insider.Live.ReportTest do
  # The in-node queue and its last-operation context are per node, and the
  # environment test changes the `:insider` application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Insider.Live
  alias Insider.Live.Report

  @tick [:insider_report_test, :tick]

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end
    end)

    :ok
  end

  defp record(category, message, at \\ ~U[2026-10-22 10:00:00Z]),
    do: Report.new(%{category: category, message: message}, %{}, at)

  describe "queue rule" do
    test "is bounded: the oldest report is evicted and the eviction is counted" do
      maximum = Report.max_reports()

      {receipts, queue} =
        Enum.map_reduce(1..(maximum + 1), [], fn index, queue ->
          {queue, receipt} = Report.put(queue, record("bug", "report #{index}"))
          {receipt, queue}
        end)

      assert length(queue) == maximum
      assert Enum.map(receipts, & &1["evicted"]) == List.duplicate(0, maximum) ++ [1]
      assert List.last(receipts)["queued"] == maximum
      assert hd(queue)["message"] == "report 2"
      assert List.last(queue)["message"] == "report #{maximum + 1}"
    end

    test "deduplicates by fingerprint, ignoring case and whitespace runs" do
      first = record("doc_mismatch", "The welcome says   X.")
      again = record("doc_mismatch", "the welcome says\nx.", ~U[2026-10-22 11:00:00Z])
      other = record("bug", "The welcome says X.")

      assert first["fingerprint"] == again["fingerprint"]
      refute first["fingerprint"] == other["fingerprint"]

      {queue, %{"duplicate" => false}} = Report.put([], first)
      {queue, %{"duplicate" => false}} = Report.put(queue, other)
      {queue, receipt} = Report.put(queue, again)

      assert receipt["duplicate"]
      assert [^other, merged] = queue
      assert merged["count"] == 2
      assert merged["first_reported_at"] == "2026-10-22T10:00:00Z"
      assert merged["last_reported_at"] == "2026-10-22T11:00:00Z"
    end

    test "keeps only the fixed context keys, as short strings" do
      context = %{
        "node" => "a@b",
        "payload" => "secret",
        "last_operation" => %{"options" => "value"},
        "welcome_hash" => String.duplicate("f", 300)
      }

      report = Report.new(%{category: "bug", message: "m"}, context, DateTime.utc_now())

      assert report["context"] |> Map.keys() |> Enum.sort() == Report.context_keys()
      assert report["context"]["node"] == "a@b"
      assert report["context"]["last_operation"] == nil
      assert report["context"]["welcome_hash"] == nil
      assert Report.record?(report)
    end
  end

  describe "Insider.Live.report/1" do
    test "queues a report with automatic context and lists it" do
      marker = "context check #{System.unique_integer([:positive])}"

      assert {:error, %{"code" => "unknown_session"}} = Live.status("live-none")
      assert {:ok, receipt} = Live.report(%{"category" => "doc_mismatch", "message" => marker})

      assert %{"schema" => "insider.live-report-receipt/v1", "queue" => "node"} = receipt
      report = receipt["report"]
      assert report["message"] == marker

      assert report["context"] == %{
               "transport" => "node",
               "insider_version" => to_string(Application.spec(:insider, :vsn)),
               "insider_commit" => Live.welcome()["insider"]["commit"],
               "welcome_hash" => Live.welcome()["hash"],
               "node" => Atom.to_string(node()),
               "environment" => "test",
               "last_operation" => "status",
               "last_error_code" => "unknown_session",
               # A node has no observer, so no local failure.
               "last_local_operation" => nil,
               "last_local_error_code" => nil,
               "session" => nil
             }

      assert {:ok, %{"schema" => "insider.live-reports/v1", "reports" => reports}} =
               Live.reports()

      assert Enum.any?(reports, &(&1["fingerprint"] == report["fingerprint"]))

      assert %{"ok" => %{"report" => %{"count" => 2}}} =
               Jason.decode!(
                 Live.JSON.report(%{"category" => "doc_mismatch", "message" => marker})
               )
    end

    test "the context never carries event payloads or option values" do
      secret = "payload_marker_#{System.unique_integer([:positive])}"

      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry", "logger"],
                 "telemetry_events" => [["insider_report_test", "tick"]],
                 "telemetry_measurements" => ["count"]
               })

      :telemetry.execute(@tick, %{count: 1}, %{secret: secret})
      _logged = capture_log(fn -> Logger.error("logged #{secret}") end)
      assert {:ok, %{"events" => [_ | _]}} = Live.events_since(id, 0, %{"limit" => 77})
      assert {:ok, %{"state" => "stopped"}} = Live.stop(id)

      assert {:error, %{"code" => "invalid_options"}} =
               Live.start(%{"components" => ["logger"], "lease_ms" => 77_777_777})

      assert {:ok, receipt} = Live.report(%{"category" => "bug", "message" => "context check"})

      encoded = Jason.encode!(receipt)
      refute encoded =~ secret
      refute encoded =~ "77777777"
      assert receipt["report"]["context"]["last_operation"] == "start"
      assert receipt["report"]["context"]["last_error_code"] == "invalid_options"
    end

    test "refuses malformed reports with the closed error vocabulary" do
      for {input, field} <- [
            {%{"category" => "rant", "message" => "m"}, "category"},
            {%{"category" => "bug"}, "message"},
            {%{"category" => "bug", "message" => "   "}, "message"},
            {%{"category" => "bug", "message" => "bell\a"}, "message"},
            {%{"category" => "bug", "message" => <<0xFF>>}, "message"},
            {%{"category" => "bug", "node" => "x"}, "node"},
            {%{"category" => "bug", "message" => "m", "node" => "x"}, "options"},
            {[category: "bug"], "options"}
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => ^field}} = Live.report(input)
      end
    end

    test "is refused outside development, test, and ci" do
      Application.put_env(:insider, :environment, :production)

      for result <- [Live.report(%{"category" => "bug", "message" => "m"}), Live.reports()] do
        assert {:error, %{"code" => "environment_denied", "environment" => "production"}} =
                 result
      end
    end

    test "reports the queue as unavailable while its process is down" do
      :ok = Supervisor.terminate_child(Insider.Supervisor, Insider.Live.Reports)
      on_exit(fn -> Supervisor.restart_child(Insider.Supervisor, Insider.Live.Reports) end)

      assert {:error, %{"code" => "unavailable"}} =
               Live.report(%{"category" => "bug", "message" => "m"})

      assert {:error, %{"code" => "unavailable"}} = Live.reports()
      assert %{"schema" => "insider.live-capabilities/v1"} = Live.capabilities()
    end
  end

  describe "bounded admission and deadlines" do
    setup do
      pid = Process.whereis(Insider.Live.Reports)
      on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
      {:ok, pid: pid}
    end

    test "tracking public calls queues no work in the report process", %{pid: pid} do
      :ok = :sys.suspend(pid)
      for _call <- 1..1_000, do: Live.capabilities()
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      :ok = :sys.resume(pid)

      assert {:error, %{"code" => "unknown_session"}} = Live.status("live-none")
      assert {:ok, receipt} = Live.report(%{"category" => "bug", "message" => "tracked"})
      assert receipt["report"]["context"]["last_operation"] == "status"
    end

    test "a report that times out is never written", %{pid: pid} do
      marker = "late #{System.unique_integer([:positive])}"
      :ok = :sys.suspend(pid)

      assert {:error, %{"code" => "timeout"}} =
               Live.report(%{"category" => "bug", "message" => marker})

      :ok = :sys.resume(pid)
      assert {:ok, %{"reports" => reports}} = Live.reports()
      refute Enum.any?(reports, &(&1["message"] == marker))
      assert {:ok, _receipt} = Live.report(%{"category" => "bug", "message" => "recovered"})
    end

    test "excess concurrent callers are refused as busy before they queue", %{pid: pid} do
      :ok = :sys.suspend(pid)

      results =
        1..40
        |> Enum.map(fn index ->
          Task.async(fn -> Live.report(%{"category" => "bug", "message" => "busy #{index}"}) end)
        end)
        |> Task.await_many(10_000)

      codes = Enum.frequencies_by(results, fn {:error, %{"code" => code}} -> code end)
      assert codes["busy"] > 0
      assert codes["busy"] + Map.get(codes, "timeout", 0) == 40
      assert {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
      assert queued <= Insider.Live.Reports.admitted_calls_max()

      :ok = :sys.resume(pid)
      assert {:ok, _receipt} = Live.report(%{"category" => "bug", "message" => "after busy"})
    end
  end

  describe "record validation" do
    test "a well-formed record round-trips through JSON" do
      record = record("bug", "round trip")
      assert Report.record?(record |> Jason.encode!() |> Jason.decode!())
    end

    test "every malformed persisted field is rejected" do
      valid = Report.new(%{category: "bug", message: "m"}, %{"node" => "a@b"}, DateTime.utc_now())

      malformed = [
        Map.put(valid, "message", 42),
        Map.put(valid, "message", "bell\a"),
        Map.put(valid, "message", String.duplicate("x", 2_049)),
        Map.put(valid, "category", "rant"),
        Map.put(valid, "fingerprint", "0000000000000000"),
        Map.put(valid, "first_reported_at", "yesterday"),
        Map.put(valid, "last_reported_at", "2000-01-01T00:00:00Z"),
        # Fractional, mixed-precision, offset and reversed-instant forms.
        Map.merge(valid, %{
          "first_reported_at" => "2026-10-22T10:00:00.900Z",
          "last_reported_at" => "2026-10-22T10:00:00Z"
        }),
        Map.merge(valid, %{
          "first_reported_at" => "2026-10-22T10:00:00Z",
          "last_reported_at" => "2026-10-22T10:00:01.000Z"
        }),
        Map.merge(valid, %{
          "first_reported_at" => "2026-10-22T10:00:00+00:00",
          "last_reported_at" => "2026-10-22T10:00:00+00:00"
        }),
        Map.merge(valid, %{
          "first_reported_at" => "2026-10-22T10:00:01Z",
          "last_reported_at" => "2026-10-22T10:00:00Z"
        }),
        Map.put(valid, "count", 0),
        put_in(valid, ["context", "node"], 7),
        put_in(valid, ["context", "node"], String.duplicate("n", 257))
      ]

      assert Report.record?(valid)
      for record <- malformed, do: refute(Report.record?(record), inspect(record))
    end

    test "a record from before the local failure or session context is upgraded, nothing else is" do
      valid = record("bug", "upgrade")
      local = ["last_local_error_code", "last_local_operation"]

      for dropped <- [local, ["session"], ["session" | local]] do
        old = update_in(valid, ["context"], &Map.drop(&1, dropped))

        refute Report.record?(old)
        assert Report.upgrade(old) == valid
        assert Report.record?(Report.upgrade(old))
      end

      # A current record, a context missing other keys, and non-records are
      # returned unchanged.
      partial = update_in(valid, ["context"], &Map.drop(&1, ["node" | local]))

      for value <- [valid, partial, %{"context" => nil}, :not_a_record] do
        assert Report.upgrade(value) == value
      end
    end
  end
end
