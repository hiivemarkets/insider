defmodule Insider.Live.MarksTest do
  # Pairing: the agent (or the programmer) marks the moment before an action
  # ("about to click Confirm"), then reads what happened since the mark
  # instead of guessing a time or a cursor. One collector session is global
  # per node, so this module cannot run in parallel with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Insider.Collector.Session.Manager
  alias Insider.Live

  @tick [:insider_live_marks_test, :tick]
  @telemetry %{
    "components" => ["telemetry"],
    "telemetry_events" => [["insider_live_marks_test", "tick"]],
    "telemetry_measurements" => ["count"]
  }

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  defp tick(range), do: for(count <- range, do: :telemetry.execute(@tick, %{count: count}, %{}))

  defp counts(events) do
    for %{"event" => %{"kind" => "insider_live_marks_test.tick"} = event} <- events,
        do: event["attributes"]["measurements"]["count"]
  end

  test "a mark records the moment and the label, and reads since it see only what came after" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    tick(1..3)

    assert {:ok, marked} =
             Live.mark(id, %{"label" => "about to click Confirm", "reader" => "agent-a"})

    assert %{
             "schema" => "insider.live-mark/v1",
             "session_id" => ^id,
             "recorded" => true,
             "marks" => 1,
             "mark" =>
               %{
                 "index" => 1,
                 "label" => "about to click Confirm",
                 "reader" => "agent-a",
                 "cursor" => 3,
                 "label_truncated" => false
               } = mark
           } = marked

    assert {:ok, _at, 0} = DateTime.from_iso8601(mark["at"])
    # The reply says what to run once the programmer has acted.
    assert marked["next"] =~ "digest"
    assert marked["next"] =~ "--since-mark"

    tick(4..5)

    # The mark itself is an event in the session, then what came after.
    assert {:ok, batch} = Live.events_since(id, "mark")
    assert [%{"event" => %{"kind" => "live.mark"} = event} | _rest] = batch["events"]
    assert event["attributes"]["label"] == "about to click Confirm"
    assert counts(batch["events"]) == [4, 5]
    assert batch["mark"]["index"] == 1

    assert {:ok, digest} = Live.digest(id, %{"since" => "mark", "human" => true})

    assert %{"since" => "mark", "cursor" => 3, "mark" => %{"label" => "about to click Confirm"}} =
             digest["window"]

    assert digest["counts"]["by_kind"]["insider_live_marks_test.tick"] == 2

    window_line =
      digest["text"] |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Window:"))

    assert window_line =~
             ~r/^Window: since mark 'about to click Confirm' \(\d\d:\d\d:\d\d UTC, [\d.]+ s ago\), up to receipt \d+; newest event [\d.]+ s ago\.$/
  end

  test "a named mark is found by its label; the newest otherwise; an unknown one names the marks there are" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

    assert {:error, %{"code" => "mark_not_found", "marks" => 0, "labels" => []}} =
             Live.digest(id, %{"since" => "mark"})

    assert {:ok, _first} = Live.mark(id, %{"label" => "open cart"})
    tick(1..2)
    assert {:ok, _second} = Live.mark(id, %{"label" => "click Confirm"})
    tick(3..3)

    assert {:ok, from_first} = Live.events_since(id, "mark:open cart")
    assert counts(from_first["events"]) == [1, 2, 3]
    assert {:ok, from_newest} = Live.events_since(id, "mark")
    assert counts(from_newest["events"]) == [3]

    assert {:ok, %{"window" => %{"mark" => %{"label" => "open cart"}}}} =
             Live.digest(id, %{"since" => "mark:open cart"})

    assert {:error,
            %{
              "code" => "mark_not_found",
              "label" => "checkout",
              "marks" => 2,
              "labels" => ["click Confirm", "open cart"]
            }} = Live.digest(id, %{"since" => "mark:checkout"})

    assert {:error, %{"code" => "mark_not_found"}} = Live.events_since(id, "mark:checkout")

    assert {:ok,
            %{"schema" => "insider.live-marks/v1", "marks" => marks, "dropped" => 0} = listed} =
             Live.marks(id, %{"human" => true})

    assert Enum.map(marks, & &1["label"]) == ["open cart", "click Confirm"]
    assert Enum.all?(marks, &(is_integer(&1["age_ms"]) and &1["age_ms"] >= 0))

    assert [_header, first, second] = String.split(listed["text"], "\n", trim: true)
    assert first =~ ~r/^#1 \d\d:\d\d:\d\d UTC \([\d.]+ s ago\) 'open cart', after receipt 0$/
    assert second =~ ~r/^#2 .*'click Confirm', after receipt 3$/
  end

  test "labels are one line, at most 120 bytes, credential-masked, and required" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

    long = String.duplicate("é", 70)
    assert {:ok, %{"mark" => mark}} = Live.mark(id, %{"label" => "  " <> long <> "\n"})
    assert byte_size(mark["label"]) == 120 and mark["label_truncated"]
    assert String.valid?(mark["label"])

    assert {:ok, %{"mark" => %{"label" => "line one line two"}}} =
             Live.mark(id, %{"label" => "line one\nline two"})

    secret = "ghp_" <> String.duplicate("a", 36)

    assert {:ok, %{"mark" => %{"label" => masked}}} =
             Live.mark(id, %{"label" => "token #{secret}"})

    refute masked =~ secret
    assert {:ok, batch} = Live.events_since(id, 0)
    refute Jason.encode!(batch) =~ secret

    for label <- [nil, "", "   ", 7, <<0xFF>>] do
      options = if label, do: %{"label" => label}, else: %{}

      assert {:error, %{"code" => "invalid_options", "field" => "label"}} =
               Live.mark(id, options),
             inspect(label)
    end

    assert {:error, %{"code" => "invalid_options", "field" => "reader"}} =
             Live.mark(id, %{"label" => "x", "reader" => "bad name"})

    assert {:error, %{"code" => "invalid_options", "field" => "other"}} =
             Live.mark(id, %{"label" => "x", "other" => 1})

    assert {:error, %{"code" => "unknown_session"}} = Live.mark("live-none", %{"label" => "x"})
  end

  # A label is refused past 1,024 input bytes before any
  # work, on a mark and on a lookup, so no reader can stall the owner.
  test "an oversized label is refused before any work, and lookups leave other callers alone" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    big = String.duplicate("a", 1_025)

    assert {:error, %{"code" => "invalid_options", "field" => "label"}} =
             Live.mark(id, %{"label" => big})

    assert {:error, %{"code" => "invalid_options", "field" => "since"}} =
             Live.digest(id, %{"since" => "mark:" <> big})

    assert {:error, %{"code" => "invalid_options", "field" => "cursor"}} =
             Live.events_since(id, "mark:" <> big)

    for index <- 1..256, do: {:ok, _mark} = Live.mark(id, %{"label" => "m#{index}"})

    # The largest label accepted, missing from 256 marks, again and again,
    # while another caller asks for the status.
    largest = "mark:" <> String.duplicate("b", 1_024)

    lookups =
      Task.async(fn ->
        for _round <- 1..20, do: Live.events_since(id, largest)
      end)

    assert {:ok, %{"state" => "running"}} = Live.status(id)

    assert Enum.all?(
             Task.await(lookups, 30_000),
             &match?({:error, %{"code" => "mark_not_found"}}, &1)
           )
  end

  # A malformed lookup label is refused like a malformed
  # mark label, and never echoed.
  test "a lookup label that is not valid UTF-8 is refused without echoing it" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    bad = "password=review-secret" <> <<255>>

    assert {:error, %{"code" => "invalid_options", "field" => "since"} = error} =
             Live.digest(id, %{"since" => "mark:" <> bad})

    refute inspect(error) =~ "review-secret"

    assert {:error, %{"code" => "invalid_options", "field" => "cursor"} = error} =
             Live.events_since(id, "mark:" <> bad)

    refute inspect(error) =~ "review-secret"

    json = Insider.Live.JSON.digest(id, %{"since" => "mark:" <> bad})
    assert %{"error" => %{"field" => "since"}} = Jason.decode!(json)
    refute json =~ "review-secret"

    # A credential-shaped label that is valid is looked up masked.
    assert {:error, %{"code" => "mark_not_found", "label" => label}} =
             Live.digest(id, %{"since" => "mark:password=review-secret"})

    refute label =~ "review-secret"
  end

  # Only Insider's own marks are left out of a digest.
  test "an application Telemetry event named live.mark is counted" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["telemetry"],
               "telemetry_events" => [["live", "mark"]],
               "telemetry_measurements" => ["count"]
             })

    :telemetry.execute([:live, :mark], %{count: 7}, %{})
    assert {:ok, %{"next_cursor" => 1}} = Live.events_since(id, "latest")

    assert {:ok, digest} = Live.digest(id, %{"since" => 0})
    assert digest["window"]["events"] == 1
    assert digest["counts"]["by_source"] == %{"telemetry" => 1}
  end

  test "a session keeps its newest 256 marks and counts the ones it let go" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    for index <- 1..260, do: assert({:ok, _mark} = Live.mark(id, %{"label" => "m#{index}"}))

    assert {:ok, %{"marks" => marks, "dropped" => 4, "max" => 256}} = Live.marks(id)
    assert Enum.count_until(marks, 257) == 256
    assert hd(marks)["label"] == "m5" and List.last(marks)["index"] == 260

    assert {:error, %{"code" => "mark_not_found"}} = Live.events_since(id, "mark:m1")
  end

  test "the strict profile keeps marks and masks labels by the same rules" do
    assert {:ok, %{"session_id" => id, "disclosure_profile" => "strict"}} =
             Live.start(Map.put(@telemetry, "disclosure", "strict"))

    secret = "ghp_" <> String.duplicate("b", 36)
    assert {:ok, %{"mark" => %{"label" => label}}} = Live.mark(id, %{"label" => "pay #{secret}"})
    assert label =~ "pay " and not (label =~ secret)
    tick(1..1)

    assert {:ok, batch} = Live.events_since(id, "mark")

    assert [%{"event" => %{"kind" => "live.mark", "attributes" => %{"label" => ^label}}} | _] =
             batch["events"]

    assert Enum.count(batch["events"], &(&1["event"]["kind"] == "insider_live_marks_test.tick")) ==
             1
  end

  test "marks survive an amendment and a stop, and a stopped session reads since them" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    tick(1..2)
    assert {:ok, %{"mark" => %{"cursor" => 2}}} = Live.mark(id, %{"label" => "before amend"})
    assert {:ok, _amended} = Live.amend(id, %{"lease_ms" => 120_000})
    tick(3..4)

    assert {:ok, batch} = Live.events_since(id, "mark")
    assert counts(batch["events"]) == [3, 4]

    assert {:ok, _stopped} = Live.stop(id, %{"force" => true})

    assert {:ok, %{"marks" => [%{"label" => "before amend"}]}} = Live.marks(id)

    assert {:ok, %{"window" => %{"cursor" => 2, "mark" => %{"label" => "before amend"}}} = digest} =
             Live.digest(id, %{"since" => "mark"})

    assert digest["counts"]["by_kind"]["insider_live_marks_test.tick"] == 2
    assert {:error, %{"code" => "session_terminal"}} = Live.mark(id, %{"label" => "late"})
  end

  test "a timeline since a mark leaves out the request's earlier events, and says so" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "info"})

    capture_log(fn -> Logger.error("before", request_id: "req-mark") end)
    assert {:ok, %{"next_cursor" => 1}} = Live.events_since(id, "latest")
    assert {:ok, _mark} = Live.mark(id, %{"label" => "about to retry"})
    capture_log(fn -> Logger.error("after", request_id: "req-mark") end)

    assert {:ok, whole} = Live.timeline(id, %{"request_id" => "req-mark"})
    assert [_before, _after] = whole["items"]

    assert {:ok, since} =
             Live.timeline(id, %{"request_id" => "req-mark", "since" => "mark", "human" => true})

    assert [item] = since["items"]
    assert item["event"]["payload"]["message"] =~ "after"
    assert %{"label" => "about to retry", "cursor" => 1} = since["mark"]
    assert since["scan"]["complete"]
    refute Enum.any?(since["gaps"], &(&1["reason"] == "scan_truncated"))
    assert since["text"] =~ ~r/\nSince mark 'about to retry' \(\d\d:\d\d:\d\d UTC, [\d.]+ s ago\)/

    assert {:error, %{"code" => "mark_not_found"}} =
             Live.timeline(id, %{"request_id" => "req-mark", "since" => "mark:nope"})
  end

  # Integration: a pairing window and a known-normal baseline
  # together. The noise marked normal before the mark recurs after it, and
  # the click fails: the digest since the mark leads with the failure, folds
  # the noise into one line, and its window names the mark.
  test "digest since a mark with a baseline leads with what is new, folds the known noise, and names the mark" do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{"components" => ["logger"], "logger_level" => "error"})

    noise = fn ->
      capture_log(fn ->
        for _ <- 1..6, do: Logger.error("key fetch failed: unsupported scheme")
      end)
    end

    noise.()

    assert_eventually(fn ->
      match?({:ok, %{"next_cursor" => 6}}, Live.events_since(id, "latest"))
    end)

    assert {:ok, %{"baseline" => %{"entries" => [%{"kind" => "error_spike"}]}}} =
             Live.baseline(id, %{"since" => 0})

    assert {:ok, %{"mark" => %{"cursor" => 6}}} =
             Live.mark(id, %{"label" => "about to click Confirm"})

    noise.()
    capture_log(fn -> for i <- 1..8, do: Logger.error("checkout failed for order #{i}") end)

    assert_eventually(fn ->
      match?({:ok, %{"next_cursor" => 21}}, Live.events_since(id, "latest"))
    end)

    assert {:ok, digest} = Live.digest(id, %{"since" => "mark", "human" => true})

    assert [%{"kind" => "error_spike", "line" => new}] = digest["anomalies"]
    assert new =~ "checkout failed for order N"
    assert [%{"kind" => "error_spike", "line" => known}] = digest["anomalies_known"]
    assert known =~ "key fetch failed"

    assert %{"since" => "mark", "cursor" => 6, "mark" => %{"label" => "about to click Confirm"}} =
             digest["window"]

    assert digest["counts"]["by_severity"] == %{"error" => 14}

    lines = String.split(digest["text"], "\n")

    anomalies =
      Enum.find_index(lines, &String.starts_with?(&1, "Anomalies (new first; 1 known-normal"))

    assert Enum.at(lines, anomalies) =~
             ~r/^Anomalies \(new first; 1 known-normal anomaly hidden, baseline set \d\d:\d\d; --show-baseline\):$/

    assert Enum.at(lines, anomalies + 1) =~ "1. Error spike: 8x"
    window = Enum.find_index(lines, &String.starts_with?(&1, "Window:"))
    assert window > anomalies

    assert Enum.at(lines, window) =~
             ~r/^Window: since mark 'about to click Confirm' \(\d\d:\d\d:\d\d UTC, [\d.]+ s ago\), up to receipt 21; /

    # The baseline can also be set from a mark's window.
    assert {:ok, %{"baseline" => %{"entries" => [_ | _]}}} =
             Live.baseline(id, %{"since" => "mark"})
  end

  test "describe gives baseline the same since forms as digest, marks included" do
    described = Insider.Live.Options.describe()

    assert described["baseline"]["since"]["type"] == described["digest"]["since"]["type"]
    assert described["baseline"]["since"]["type"] =~ ~s("mark:LABEL")
  end

  # chart --serve watches for a programmer and must never keep a session
  # alive: its reads pass "renew" => false.
  test "a read with renew false leaves the lease as it was" do
    assert {:ok, %{"session_id" => id}} = Live.start(Map.put(@telemetry, "lease_ms", 60_000))
    tick(1..2)

    assert {:ok, %{"lease_remaining_ms" => before}} = Live.status(id)
    assert {:ok, %{"events" => [_ | _]}} = Live.events_since(id, 0, %{"renew" => false})
    assert {:ok, %{"lease_remaining_ms" => after_read}} = Live.status(id)
    assert after_read <= before

    assert {:error, %{"code" => "invalid_options", "field" => "renew"}} =
             Live.events_since(id, 0, %{"renew" => "no"})
  end

  test "a digest since a mark with nothing after it says the action may not have happened yet" do
    assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
    tick(1..2)
    assert {:ok, _mark} = Live.mark(id, %{"label" => "about to click Confirm"})

    assert {:ok, digest} = Live.digest(id, %{"since" => "mark", "human" => true})

    assert digest["text"] =~
             "Nothing recorded since the mark: the action may not have happened yet, " <>
               "or this session does not record it (see filtered)."
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("expected state was not reached")
end
