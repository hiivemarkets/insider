defmodule Insider.Live.DisclosureRegressionTest do
  # Review regressions for the rich profile, through the Live API. One
  # collector session is global per node, so this module is not async.
  use ExUnit.Case, async: false

  alias Insider.Collector.Rich
  alias Insider.Collector.Session.Manager
  alias Insider.Live

  defmodule BlockingCalendar do
    @moduledoc false
    # A calendar whose callbacks never return: rendering must not call them.
    def date_to_string(_year, _month, _day), do: receive(do: (:never -> ""))
    def naive_datetime_to_string(_, _, _, _, _, _, _), do: receive(do: (:never -> ""))
    def time_to_string(_, _, _, _), do: receive(do: (:never -> ""))
  end

  defmodule Schema do
    @moduledoc false
    # Ecto-shaped: `__schema__(:redact_fields)` is what Ecto generates.
    defstruct [:id, :opaque, :email]
    def __schema__(:redact_fields), do: [:opaque]
    def __schema__(_other), do: nil
  end

  # Hostile schema fixtures act only while this module's tests run, so other
  # test modules that start live sessions are not slowed or burdened.
  @active {__MODULE__, :hostile_schemas}
  @big_reason {__MODULE__, :big_reason}

  defmodule StuckSchema do
    @moduledoc false
    # A schema accessor that never returns must not stall session start.
    defstruct [:id]

    def __schema__(:redact_fields) do
      if :persistent_term.get({Insider.Live.DisclosureRegressionTest, :hostile_schemas}, false),
        do: receive(do: (:never -> [])),
        else: []
    end
  end

  defmodule HugeSchema do
    @moduledoc false
    # A malformed, very large accessor result must not reach the owner.
    defstruct [:id]
    def __schema__(:redact_fields), do: :erlang.make_tuple(4_000_000, :x)
  end

  defmodule WideSchema do
    @moduledoc false
    # One field over the 64-field bound.
    defstruct [:id]
    def __schema__(:redact_fields), do: List.duplicate(:id, 65)
  end

  defmodule ExitSchema do
    @moduledoc false
    # Fails with a huge exit reason that lives off-heap in persistent_term.
    defstruct [:id]
    def __schema__(:redact_fields), do: exit(:persistent_term.get(big_reason(), :small))
    defp big_reason, do: {Insider.Live.DisclosureRegressionTest, :big_reason}
  end

  defmodule KilledSchema do
    @moduledoc false
    # Has another process kill it with a huge exit reason.
    defstruct [:id]

    def __schema__(:redact_fields) do
      worker = self()
      reason = :persistent_term.get({Insider.Live.DisclosureRegressionTest, :big_reason}, :small)
      spawn(fn -> Process.exit(worker, reason) end)
      receive(do: (:never -> [:id]))
    end
  end

  defmodule BinarySchema do
    @moduledoc false
    # Holds a 16 MiB reference-counted binary, then answers.
    defstruct [:id]

    def __schema__(:redact_fields) do
      if :persistent_term.get({Insider.Live.DisclosureRegressionTest, :hostile_schemas}, false) do
        binary = :binary.copy(<<1>>, 16_777_216)
        :erlang.garbage_collect()
        if byte_size(binary) > 0, do: [:id], else: []
      else
        []
      end
    end
  end

  @event [:insider_disclosure_regression, :emitted]
  @options %{
    "components" => ["logger", "telemetry"],
    "telemetry_events" => [["insider_disclosure_regression", "emitted"]]
  }

  setup do
    Application.put_env(:insider, :environment, :development)
    :persistent_term.put(@active, true)
    :persistent_term.put(@big_reason, :erlang.make_tuple(1_000_000, :x))

    on_exit(fn ->
      Application.delete_env(:insider, :environment)
      Application.delete_env(:insider, :live_disclosure)
      :persistent_term.erase(@active)
      :persistent_term.erase(@big_reason)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    {:ok, %{"session_id" => id}} = Live.start(@options)
    {:ok, id: id}
  end

  test "credentials inside tuples are masked whatever the value type", %{id: id} do
    :telemetry.execute(@event, %{count: 1}, %{
      escaped: {:error, ~s({"password": "hunter2-synthetic"})},
      atom_pair: {:password, :hunter2_synthetic},
      number_pair: {:password, 987_654_321},
      header: [{"authorization", "Basic c3ludGhldGlj"}]
    })

    {plain, json, entry} = read(id)

    for output <- [plain, json] do
      refute output =~ "hunter2"
      refute output =~ "987654321"
      refute output =~ "c3ludGhldGlj"
    end

    reasons = entry["redactions"] |> Enum.map(& &1["reason"]) |> Enum.uniq()
    assert "credential_key" in reasons
    assert "credential_assignment" in reasons
  end

  test "charlist credentials are masked, top level and nested", %{id: id} do
    :telemetry.execute(@event, %{count: 1}, %{
      message: ~c"Bearer abcdefghij",
      nested: %{deeper: [~c"password=synthetic-pass"]},
      plain: ~c"ordinary"
    })

    {plain, json, entry} = read(id)
    decoded = Jason.decode!(json)["ok"]["events"] |> hd()

    for output <- [plain, json, inspect(decoded, limit: :infinity, charlists: :as_lists)] do
      refute output =~ "abcdefghij"
      refute output =~ "synthetic-pass"
      refute output =~ "66, 101, 97, 114, 101, 114"
    end

    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["message"] == "[REDACTED:authorization_header]"
    assert metadata["nested"]["deeper"] == ["password=[REDACTED:credential_assignment]"]
    assert Enum.any?(entry["redactions"], &(&1["reason"] == "authorization_header"))
  end

  test "an overlength credential key is masked before it is cut", %{id: id} do
    long = String.duplicate("x", 260) <> "password"
    edge = String.duplicate("y", 120) <> "_token"

    :telemetry.execute(@event, %{count: 1}, %{
      long => "hunter2-synthetic",
      edge => "edge-synthetic",
      "harmless" => "kept"
    })

    {plain, json, entry} = read(id)
    for output <- [plain, json], do: refute(output =~ "synthetic")
    assert entry["event"]["payload"]["metadata"]["harmless"] == "kept"
  end

  test "a report callback that never returns does not block the emitter", %{id: id} do
    parent = self()

    # Insider runs as a primary Logger filter, before any handler. The
    # default handler would call the callback itself, so it is silenced for
    # this test and only Insider could block the emitter.
    {:ok, %{level: level}} = :logger.get_handler_config(:default)
    :ok = :logger.update_handler_config(:default, :level, :none)
    on_exit(fn -> :logger.update_handler_config(:default, :level, level) end)

    {pid, monitor} =
      spawn_monitor(fn ->
        :logger.error(%{label: :stuck, detail: "x"}, %{
          report_cb: fn _report -> receive do: (:never -> :ok) end
        })

        send(parent, :logged)
      end)

    assert_receive :logged, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000

    {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})

    report =
      Enum.find(batch["events"], &(&1["event"]["payload"]["report"]["label"] == "stuck"))

    assert report["event"]["payload"]["report"]["detail"] == "x"
  end

  test "structs render field by field without their Inspect implementation", %{id: id} do
    uri = URI.parse("https://user:synthetic-pass@example.com/path")
    :telemetry.execute(@event, %{count: 1}, %{uri: uri, at: ~D[2026-10-22]})

    {plain, json, entry} = read(id)
    for output <- [plain, json], do: refute(output =~ "synthetic-pass")

    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["uri"]["__struct__"] == "Elixir.URI"
    assert metadata["uri"]["host"] == "example.com"
    assert metadata["at"] == "~D[2026-10-22]"
  end

  test "calendar values with an application calendar never call it", %{id: id} do
    date = %Date{year: 2026, month: 10, day: 22, calendar: BlockingCalendar}
    time = %Time{hour: 1, minute: 2, second: 3, microsecond: {0, 0}, calendar: BlockingCalendar}

    {pid, monitor} =
      spawn_monitor(fn -> :telemetry.execute(@event, %{count: 1}, %{date: date, time: time}) end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000

    {_plain, _json, entry} = read(id)
    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["date"]["calendar"] == Atom.to_string(BlockingCalendar)
    assert metadata["date"]["year"] == 2026
    assert metadata["time"]["hour"] == 1

    # ISO values keep their compact text, formatted without calling Calendar.
    assert Rich.render(%{"d" => ~D[2026-10-22]}, 1_000) == %{"d" => "~D[2026-10-22]"}

    assert Rich.render(%{"t" => ~T[01:02:03.250]}, 1_000) == %{"t" => "~T[01:02:03.250]"}

    assert Rich.render(%{"n" => ~N[2026-10-22 01:02:03]}, 1_000) ==
             %{"n" => "~N[2026-10-22 01:02:03]"}

    assert Rich.render(%{"u" => ~U[2026-10-22 01:02:03.000001Z]}, 1_000) ==
             %{"u" => "~U[2026-10-22 01:02:03.000001Z]"}
  end

  test "ISO calendar structs missing a field render field by field", %{id: id} do
    values = %{
      date: Map.delete(~D[2026-10-22], :year),
      time: Map.delete(~T[01:02:03], :hour),
      naive: Map.delete(~N[2026-10-22 01:02:03], :year),
      utc: Map.delete(~U[2026-10-22 01:02:03Z], :year),
      other: "kept"
    }

    :telemetry.execute(@event, %{count: 1}, values)

    {_plain, _json, entry} = read(id)
    assert entry, "the event was recorded"
    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["other"] == "kept"
    assert metadata["date"]["__struct__"] == "Elixir.Date"
    refute Map.has_key?(metadata["date"], "year")
    assert metadata["time"]["minute"] == 2
    assert metadata["naive"]["month"] == 10
    assert metadata["utc"]["time_zone"] == "Etc/UTC"
  end

  test "an ISO calendar struct with malformed fields never reaches inspect", %{id: id} do
    nested = %Date{year: 2026, month: 1, day: 1, calendar: BlockingCalendar}
    malformed = %{~D[2026-10-22] | year: nested}

    {pid, monitor} =
      spawn_monitor(fn -> :telemetry.execute(@event, %{count: 1}, %{date: malformed}) end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000

    {_plain, _json, entry} = read(id)
    date = entry["event"]["payload"]["metadata"]["date"]
    assert date["__struct__"] == "Elixir.Date"
    assert date["year"]["calendar"] == Atom.to_string(BlockingCalendar)
  end

  test "schema replies are validated in the worker before they are sent", %{id: _id} do
    parent = self()

    collector =
      spawn(fn ->
        receive do
          :go -> send(parent, {:rows, Insider.Live.RedactFields.collect(1_000)})
        end
      end)

    :erlang.trace(collector, true, [:receive])
    send(collector, :go)
    assert_receive {:rows, rows}, 5_000

    # Whatever the schemas did (answer, fail with a huge reason, get killed
    # with one, or hold a huge binary), every message that reached the owner
    # is small and holds no binary. The test's `:go` and the code server's
    # answer to `:code.all_loaded/0` are not schema messages.
    messages =
      collect_trace(collector, [])
      |> Enum.reject(&(&1 == :go or match?({:code_server, _loaded}, &1)))

    assert messages != []

    for message <- messages do
      assert :erts_debug.flat_size(message) < 512, inspect(message, limit: 5)
      refute binary_inside?(message), inspect(message, limit: 5)
    end

    assert {Schema, [:opaque]} in rows

    for module <- [HugeSchema, WideSchema, ExitSchema, KilledSchema, BinarySchema, StuckSchema],
        do: refute(List.keymember?(rows, module, 0), inspect(module))
  end

  test "a schema worker holding a large binary is stopped by its memory cap", %{id: _id} do
    # The 16 MiB binary is reference-counted; only a cap that counts shared
    # binaries stops the worker before it answers.
    rows = Insider.Live.RedactFields.collect(1_000)
    refute List.keymember?(rows, BinarySchema, 0)
    assert {Schema, [:opaque]} in rows
  end

  test "a charlist past the scan bound is still checked for secrets", %{id: id} do
    secret = ~c"Bearer abcdefghij "

    :telemetry.execute(@event, %{count: 1}, %{
      at_bound: secret ++ List.duplicate(?x, 8_192 - length(secret)),
      past_bound: secret ++ List.duplicate(?x, 8_193),
      nested: {:ok, [secret ++ List.duplicate(?x, 9_000)]}
    })

    {plain, json, entry} = read(id)
    decoded = Jason.decode!(json)["ok"]["events"] |> hd()

    for output <- [plain, json, inspect(decoded, limit: :infinity, charlists: :as_lists)] do
      refute output =~ "abcdefghij"
      refute output =~ "66, 101, 97, 114, 101, 114"
    end

    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["at_bound"] =~ "[REDACTED:authorization_header]"
    assert metadata["past_bound"] =~ "[REDACTED:authorization_header]"
  end

  test "rendering work does not grow with the input", %{id: _id} do
    tuple = :erlang.make_tuple(8_000_000, :x)
    map = Map.new(1..1_000_000, &{&1, &1})
    string = String.duplicate("a", 128 * 1_024 * 1_024)
    invalid = :binary.copy(<<255>>, 64 * 1_024 * 1_024)
    Rich.render(%{"warm" => {:ok, "x"}}, 1_000)

    for {name, value} <- [tuple: tuple, map: map, string: string, invalid: invalid] do
      {elapsed, rendered} = :timer.tc(fn -> Rich.render(%{"v" => value}, 7_000) end)
      assert elapsed < 50_000, "#{name} took #{elapsed} µs"
      assert byte_size(Jason.encode!(rendered)) <= 7_000
    end
  end

  test "Ecto-declared redact fields stay hidden, from metadata collected at start", %{id: id} do
    :telemetry.execute(@event, %{count: 1}, %{
      record: %Schema{id: 7, opaque: "synthetic-hidden", email: "a@example.com"},
      wrapped: {:ok, %Schema{id: 8, opaque: "synthetic-wrapped"}}
    })

    {plain, json, entry} = read(id)
    for output <- [plain, json], do: refute(output =~ "synthetic-")

    record = entry["event"]["payload"]["metadata"]["record"]
    assert record["opaque"] == "[REDACTED:redacted_field]"
    assert record["email"] == "a@example.com"
    assert Enum.any?(entry["redactions"], &(&1["reason"] == "redacted_field"))
  end

  defp binary_inside?(term) when is_binary(term), do: true
  defp binary_inside?(term) when is_list(term), do: Enum.any?(term, &binary_inside?/1)

  defp binary_inside?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&binary_inside?/1)

  defp binary_inside?(term) when is_map(term),
    do: Enum.any?(term, fn {key, value} -> binary_inside?(key) or binary_inside?(value) end)

  defp binary_inside?(_term), do: false

  # Every message the traced process received, as reported to this process.
  defp collect_trace(pid, messages) do
    receive do
      {:trace, ^pid, :receive, message} -> collect_trace(pid, [message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  test "format widths and huge integers are bounded before any work is done", %{id: id} do
    # The default handler would format the message itself; only Insider's
    # work in the emitting process is measured.
    {:ok, %{level: level}} = :logger.get_handler_config(:default)
    :ok = :logger.update_handler_config(:default, :level, :none)
    on_exit(fn -> :logger.update_handler_config(:default, :level, level) end)

    parent = self()
    huge = Integer.pow(2, 1_000_000)

    spawn(fn ->
      {:reductions, before} = Process.info(self(), :reductions)
      :logger.warning(~c"wide ~10000000c", [65])
      :logger.warning(~c"star ~*c", [10_000_000, 65])
      :telemetry.execute(@event, %{count: 1}, %{huge: huge, nested: {:ok, huge}})
      {:reductions, spent} = Process.info(self(), :reductions)
      :logger.warning("healthy after the bounded ones")
      send(parent, {:spent, spent - before})
    end)

    assert_receive {:spent, spent}, 10_000
    # Three payloads of at most 2,000,000 reductions each, plus overhead.
    assert spent < 8_000_000, "spent #{spent} reductions"

    {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})

    messages =
      for %{"event" => %{"source" => "logger"} = e} <- batch["events"],
          do: e["payload"]["message"]

    assert "healthy after the bounded ones" in messages
    assert Enum.any?(messages, &(&1 =~ "wide"))
    assert Enum.any?(messages, &(&1 =~ "star"))

    {_plain, _json, entry} = read(id)
    metadata = entry["event"]["payload"]["metadata"]
    assert metadata["huge"] == "<integer over 150 digits>"
    assert metadata["nested"] =~ "integer over 150 digits"
  end

  test "narrowing rich to strict records the withheld payload in reads and pushes", %{id: id} do
    :telemetry.execute(@event, %{count: 1}, %{source: "review-source"})
    {_plain, _json, rich} = read(id)
    assert rich["event"]["payload"]["metadata"]["source"] == "review-source"

    Application.put_env(:insider, :live_disclosure, :strict)
    {plain, _json, strict} = read(id)
    refute plain =~ "review-source"
    assert strict["event"]["payload"] == nil
    assert payload_drop?(strict)

    assert {:ok, _subscription} = Live.subscribe(id, self())
    assert {:ok, _stopped} = Live.stop(id)
    pushed = await_pushed(id, [])
    entry = Enum.find(pushed, &(&1["event"]["kind"] == "insider_disclosure_regression.emitted"))
    assert entry["event"]["payload"] == nil
    assert payload_drop?(entry)
  end

  defp payload_drop?(entry) do
    Enum.any?(
      entry["redactions"],
      &match?(
        %{
          "action" => "drop",
          "path" => ["key:payload"],
          "policy_id" => "insider-live-boundary/v1"
        },
        &1
      )
    )
  end

  # Every event pushed to this subscriber until the terminal batch.
  defp await_pushed(id, events) do
    assert_receive {:insider_live_events, ^id, batch}, 5_000
    events = events ++ batch["events"]
    if batch["state"] == "running", do: await_pushed(id, events), else: events
  end

  defp read(id) do
    {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})

    entry =
      Enum.find(
        batch["events"],
        &(&1["event"]["kind"] == "insider_disclosure_regression.emitted")
      )

    {inspect(batch, limit: :infinity, printable_limit: :infinity),
     Live.JSON.events_since(id, 0, %{"limit" => 500}), entry}
  end

  # Collector cleanup finishes asynchronously in the Manager after a stop.
  # Wait only for that explicit state predicate, under a short bound.
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
