defmodule Insider.Collector.SessionTest do
  use ExUnit.Case, async: false

  alias Insider.Collector.Admission
  alias Insider.Collector.Session
  alias Insider.Collector.Session.Handle
  alias Insider.Collector.Session.Manager
  alias Insider.Collector.Session.StartupGuard
  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Runtime.HostPolicy
  alias Insider.Test.Eventually

  defmodule SessionProvider do
    @behaviour Insider.Collector.Poller.Provider

    def vm_sample, do: {:ok, :complete, %{"process_count" => 1}, []}
    def process_sample(_pid), do: {:ok, :complete, %{"message_queue_len" => 0}, []}
  end

  setup do
    manager_ready!(System.monotonic_time(:millisecond) + 5_000)

    _ = :logger.remove_primary_filter(:insider_logger)
    :telemetry.detach("insider-session-telemetry")

    on_exit(fn ->
      _ = :logger.remove_primary_filter(:insider_logger)
      :telemetry.detach("insider-session-telemetry")
    end)

    :ok
  end

  test "host-owned session has bounded lifecycle, idempotent terminal receipt, and no residual handler" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-lifecycle", [:logger]))

    assert {:ok, health} = Session.health(handle)
    assert health["state"] == "running"
    assert health["correctness"] == "not_proven_by_liveness"
    assert health["components"]["logger"] == "running"
    assert health["components"]["recorder"] == "running"

    assert {:error, :session_already_active} =
             Session.start(host_policy, options("session-duplicate", [:logger]))

    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["outcome"] == "stopped"
    assert receipt["cleanup"]["logger_filter"] == "absent"
    assert receipt["cleanup"]["telemetry_handler"] == "absent"

    refute Enum.any?(:logger.get_primary_config().filters, fn {id, _} -> id == :insider_logger end)

    assert {:ok, ^receipt} = Session.kill(handle)
    assert {:ok, terminal_health} = Session.health(handle)
    assert terminal_health["terminal"]
  end

  test "staging and malformed starts have no session child or handler side effect" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    assert {:ok, default_host_policy} = HostPolicy.new()
    assert HostPolicy.valid?(default_host_policy)
    assert {:error, :invalid_policy} = HostPolicy.new(:invalid)
    refute HostPolicy.valid?(:invalid)

    assert {:error, :environment_denied} =
             Session.start(
               host_policy,
               Keyword.put(options("session-stage", [:logger]), :environment, :staging)
             )

    assert {:error, :invalid_options} =
             Session.start(
               host_policy,
               Keyword.put(options("session-invalid", [:logger]), :components, [:system_monitor])
             )

    assert [] = DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor)

    refute Enum.any?(:logger.get_primary_config().filters, fn {id, _} -> id == :insider_logger end)
  end

  test "startup failures roll back every previously owned component without taking a foreign filter" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    :ok = :logger.add_primary_filter(:insider_logger, {&__MODULE__.passthrough/2, %{}})

    on_exit(fn -> _ = :logger.remove_primary_filter(:insider_logger) end)

    assert {:error, _reason} =
             Session.start(host_policy, options("session-rollback-logger", [:logger]))

    assert [] = DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor)

    assert Enum.any?(:logger.get_primary_config().filters, fn
             {:insider_logger, {function, %{}}} -> function == (&__MODULE__.passthrough/2)
             _other -> false
           end)
  end

  test "later Telemetry and Poller startup failures roll back all prior session ownership" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    telemetry_policy = telemetry_policy!()

    :ok =
      :telemetry.attach(
        "insider-session-telemetry",
        [:session, :event],
        &__MODULE__.telemetry_ignore/4,
        %{}
      )

    assert {:error, _reason} =
             Session.start(
               host_policy,
               options("session-rollback-telemetry", [:logger, :telemetry])
               |> Keyword.put(:telemetry_policy, telemetry_policy)
             )

    :ok = :telemetry.detach("insider-session-telemetry")
    assert_no_session_resources()

    assert {:error, _reason} =
             Session.start(
               host_policy,
               options("session-rollback-poller", [:logger, :telemetry, :poller])
               |> Keyword.put(:telemetry_policy, telemetry_policy)
               |> Keyword.put(:poller_options,
                 initial_delay_ms: 1,
                 interval_ms: 0,
                 targets: [],
                 provider: SessionProvider
               )
             )

    assert_no_session_resources()
  end

  test "collector crash terminates the session, reclaims its stale filter, and permits the next session" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-degraded", [:logger]))
    session = :sys.get_state(Manager).active.pid
    logger = :sys.get_state(session).components.logger
    monitor = Process.monitor(logger)

    Process.exit(logger, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^logger, :killed}, 1_000

    assert_eventually(fn -> not logger_filter_present?() end)
    assert {:ok, health} = Session.health(handle)
    assert health["terminal"]

    assert {:ok, next_handle} =
             Session.start(host_policy, options("session-after-crash", [:logger]))

    assert {:ok, _receipt} = Session.stop(next_handle)
  end

  test "health marks malformed or unavailable component status as degraded without retaining it" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-malformed-status", [:logger]))
    session = :sys.get_state(Manager).active.pid
    original_state = :sys.get_state(session)

    unresponsive =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(session), do: :sys.replace_state(session, fn _state -> original_state end)
      if Process.alive?(unresponsive), do: send(unresponsive, :stop)
      _ = Session.kill(handle)
    end)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, unresponsive)}
    end)

    assert {:ok, health} = Session.health(handle)
    assert health["state"] == "degraded"
    assert health["components"]["logger"] == "unavailable"
    assert health["component_evidence"]["logger"] == "malformed_or_unavailable"

    :sys.replace_state(session, fn _state -> original_state end)
    send(unresponsive, :stop)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "composes the permitted Logger Telemetry and Poller collectors under one host policy" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    telemetry_policy =
      telemetry_policy!()

    options =
      options("session-composed", [:logger, :telemetry, :poller])
      |> Keyword.put(:telemetry_policy, telemetry_policy)
      |> Keyword.put(:poller_options,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        targets: [self()],
        provider: SessionProvider
      )

    {:ok, handle} = Session.start(host_policy, options)
    assert {:ok, health} = Session.health(handle)

    assert health["components"] == %{
             "logger" => "running",
             "poller" => "running",
             "recorder" => "running",
             "telemetry" => "running"
           }

    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["outcome"] == "stopped"
    assert receipt["cleanup"]["telemetry_handler"] == "absent"
    refute telemetry_handler_present?()
  end

  test "flush evidence exposes fixed scalar accounting and bounded quiescence claims" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    session_options =
      options("session-flush-evidence", [:logger, :telemetry, :poller])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())
      |> Keyword.put(:poller_options,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        targets: [self()],
        provider: SessionProvider
      )

    {:ok, handle} = Session.start(host_policy, session_options)
    marker = "private-event-content-must-not-escape"
    :logger.notice(marker)
    :telemetry.execute([:session, :event], %{duration: 1}, %{private: marker})

    assert {:ok, evidence} = Session.flush_evidence(handle, 500)
    assert evidence["schema"] == "insider.collector-session-evidence/v1"
    assert evidence["state"] == "running"
    assert evidence["event_content_included"] == false
    assert evidence["cleanup_evidence"] == "terminal_receipt_required"
    assert evidence["producer_quiescence"] == "poller_proven_external_emitters_not_proven"
    assert evidence["external_emitter_quiescence"] == "not_proven"
    assert evidence["visible_inboxes_empty"]
    assert evidence["poller_idle"]
    assert evidence["logger"]["evidence"] == "bounded_status"
    assert evidence["logger"]["inbox_count"] == 0
    assert evidence["logger"]["recorded"] >= 1
    assert evidence["telemetry"]["evidence"] == "bounded_status"
    assert evidence["telemetry"]["inbox_count"] == 0
    assert evidence["telemetry"]["recorded"] == 1
    assert evidence["poller"]["evidence"] == "bounded_quiescence"
    assert evidence["poller"]["quiesced"]
    refute evidence["poller"]["timer_scheduled"]
    assert evidence["recorder"]["evidence"] == "bounded_status"
    assert evidence["recorder"]["counters"]["accepted"] >= 2
    assert scalar_tree?(evidence)
    refute Jason.encode!(evidence) =~ marker

    poller = :sys.get_state(:sys.get_state(Manager).active.pid).components.poller
    send(poller, {:scheduled_poll, make_ref()})
    assert {:ok, after_race} = Session.flush_evidence(handle, 500)
    assert after_race["recorder"] == evidence["recorder"]

    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["outcome"] == "stopped"
    assert receipt["cleanup"]["recorder_ets"] == "absent"

    {:ok, fresh_handle} =
      Session.start(host_policy, options("session-flush-evidence-fresh", [:logger]))

    assert {:ok, fresh_receipt} = Session.stop(fresh_handle)
    assert fresh_receipt["outcome"] == "stopped"
  end

  test "flush ingress evidence drains source inboxes without inspecting or quiescing Poller" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    session_options =
      options("session-flush-ingress-evidence", [:logger, :telemetry, :poller])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())
      |> Keyword.put(:poller_options,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        targets: [self()],
        provider: SessionProvider
      )

    {:ok, handle} = Session.start(host_policy, session_options)
    marker = "private-ingress-content-must-not-escape"
    :logger.notice(marker)
    :telemetry.execute([:session, :event], %{duration: 1}, %{private: marker})

    assert {:ok, evidence} = Session.flush_ingress_evidence(handle, 500)
    assert evidence["schema"] == "insider.collector-session-ingress-evidence/v1"
    assert evidence["state"] == "running"
    assert evidence["external_emitter_quiescence"] == "not_proven"
    assert evidence["poller_quiescence"] == "not_requested"
    assert evidence["event_content_included"] == false
    assert evidence["visible_inboxes_empty"]
    assert evidence["logger"]["evidence"] == "bounded_status"
    assert evidence["logger"]["inbox_count"] == 0
    assert evidence["logger"]["recorded"] >= 1
    assert evidence["telemetry"]["evidence"] == "bounded_status"
    assert evidence["telemetry"]["inbox_count"] == 0
    assert evidence["telemetry"]["recorded"] == 1
    refute Map.has_key?(evidence, "poller")
    refute Map.has_key?(evidence, "recorder")
    assert scalar_tree?(evidence)
    refute Jason.encode!(evidence) =~ marker

    session = :sys.get_state(Manager).active.pid
    poller = :sys.get_state(session).components.poller

    assert {:ok, %{quiesced: false, timer_scheduled: true}} =
             Insider.Collector.Poller.status(poller)

    %{timer: {_timer, token}} = :sys.get_state(poller)
    send(poller, {:scheduled_poll, token})

    assert_eventually(fn ->
      {:ok, status} = Insider.Collector.Poller.status(poller)
      status.cycles_completed == 1 and not status.quiesced
    end)

    assert {:ok, %{"outcome" => "stopped"}} = Session.stop(handle)
  end

  test "sealing ingress records everything admitted, then nothing, and keeps the Recorder readable" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    session_options =
      options("session-seal-ingress", [:logger, :telemetry])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())

    {:ok, handle} = Session.start(host_policy, session_options)

    # Admitted to the inboxes, never read before the seal.
    :logger.notice("before seal")
    for count <- 1..3, do: :telemetry.execute([:session, :event], %{duration: count}, %{})

    assert {:ok, sealed} = Session.seal_ingress(handle, 1_000)
    assert sealed["schema"] == "insider.collector-session-seal/v1"
    assert sealed["components"] == %{"logger" => "absent", "telemetry" => "absent"}
    assert :telemetry.list_handlers([:session, :event]) == []
    refute Enum.any?(:logger.get_primary_config().filters, &(elem(&1, 0) == :insider_logger))

    # Nothing after the seal is recorded; the session is still running.
    :logger.notice("after seal")
    :telemetry.execute([:session, :event], %{duration: 9}, %{})

    assert {:ok, read} = Session.read_events(handle, 0, limit: 100)
    kinds = Enum.map(read["events"], & &1["event"]["kind"])
    assert Enum.count(kinds, &(&1 == "session.event")) == 3
    assert Enum.count(kinds, &(&1 == "logger_message")) >= 1
    assert read["next_receipt"] == length(read["events"])
    # The sealed Telemetry collector reports the status it was sealed with.
    assert %{"configured" => true, "evidence" => "bounded_status", "recorded" => 3} =
             read["telemetry"]

    # A second seal stops nothing more; the receipt keeps the seal's cleanup.
    assert {:ok, %{"components" => %{"telemetry" => "absent"}}} =
             Session.seal_ingress(handle, 500)

    assert {:error, :invalid_options} = Session.seal_ingress(handle, 0)
    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["outcome"] == "stopped"
    assert %{"logger" => "absent", "telemetry" => "absent"} = receipt["cleanup"]["components"]
    assert {:error, :expired_or_unknown_session} = Session.seal_ingress(handle, 500)
  end

  test "an event recorded from outside the collectors lands before the seal and never after it" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])
    {:ok, handle} = Session.start(host_policy, options("session-record-event", [:logger]))

    assert :ok = Session.record_event(handle, outside_event(1), 1_000)
    assert {:error, :invalid_options} = Session.record_event(handle, outside_event(2), 0)
    assert {:error, :invalid_options} = Session.record_event(handle, :not_an_event, 1_000)
    assert {:error, :invalid_handle} = Session.record_event(:nope, outside_event(2), 1_000)

    assert {:ok, _sealed} = Session.seal_ingress(handle, 1_000)
    assert {:error, :sealed} = Session.record_event(handle, outside_event(3), 1_000)

    assert {:ok, read} = Session.read_events(handle, 0, limit: 100)

    assert [%{"event" => %{"kind" => "inspect.test", "source_sequence" => 1}}] =
             Enum.filter(read["events"], &(&1["event"]["source"] == "inspect"))

    assert {:ok, _receipt} = Session.stop(handle)

    assert {:error, :expired_or_unknown_session} =
             Session.record_event(handle, outside_event(4), 1_000)
  end

  # A queued record_event outlived its
  # caller's timeout and was still recorded after the caller saw a failure.
  test "a record_event that waited past its deadline is never recorded" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])
    {:ok, handle} = Session.start(host_policy, options("session-record-expired", [:logger]))
    session = :sys.get_state(Manager).active.pid

    :ok = :sys.suspend(session)
    # Long enough for the Manager to pass the request on to the suspended
    # session, which then holds it past its deadline. The caller cannot
    # tell whether a write it timed out on happened, so it says unknown.
    assert {:error, :outcome_unknown} = Session.record_event(handle, outside_event(1), 500)
    :ok = :sys.resume(session)

    # A later request is served after the expired one, so it is gone by now.
    assert :ok = Session.record_event(handle, outside_event(2), 1_000)
    assert {:ok, read} = Session.read_events(handle, 0, limit: 100)

    assert [%{"event" => %{"source_sequence" => 2}}] =
             Enum.filter(read["events"], &(&1["event"]["source"] == "inspect"))

    assert {:ok, _receipt} = Session.stop(handle)
  end

  # A record already handed to the Recorder
  # may wait for its admission lock and complete after its caller's
  # deadline. The caller cannot know, so it reports the outcome as unknown,
  # never as not recorded.
  test "a record_event still waiting for the Recorder lock at its deadline reports an unknown outcome" do
    test = self()

    # The clock runs under the Recorder's admission lock; a writer that
    # carries a gate in its dictionary holds the lock until released.
    clock = fn ->
      case Process.get(:recorder_gate) do
        nil ->
          System.monotonic_time(:microsecond)

        gate ->
          # One hold per writer: later clock reads under the same lock pass.
          Process.delete(:recorder_gate)
          send(gate, {:holding, self()})
          receive do: (:release -> System.monotonic_time(:microsecond))
      end
    end

    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    session_options =
      options("session-record-contended", [:logger])
      |> Keyword.update!(:recorder_options, &Keyword.put(&1, :clock, clock))

    {:ok, handle} = Session.start(host_policy, session_options)
    session = :sys.get_state(Manager).active.pid
    recorder = :sys.get_state(session).recorder_handle

    holder =
      spawn(fn ->
        Process.put(:recorder_gate, test)
        send(test, {:held, Insider.Recorder.record(recorder, outside_event(1))})
      end)

    assert_receive {:holding, ^holder}, 5000

    # Queued behind the held lock past its caller's deadline; the lock is
    # released well inside the Recorder's own stall bound.
    assert {:error, :outcome_unknown} = Session.record_event(handle, outside_event(2), 200)
    send(holder, :release)
    assert_receive {:held, :ok}, 5000

    # The session served the late write before this one: it did complete,
    # which is why its caller could only say unknown.
    assert :ok = Session.record_event(handle, outside_event(3), 1_000)
    assert {:ok, read} = Session.read_events(handle, 0, limit: 100)

    assert [1, 2, 3] =
             read["events"]
             |> Enum.filter(&(&1["event"]["source"] == "inspect"))
             |> Enum.map(& &1["event"]["source_sequence"])

    assert {:ok, _receipt} = Session.stop(handle)
  end

  defp outside_event(sequence) do
    Insider.Event.new!(
      id: "inspect-#{sequence}",
      node: Atom.to_string(node()),
      boot_id: "boot-test",
      source: "inspect",
      kind: "inspect.test",
      severity: :info,
      monotonic_time: System.monotonic_time(:microsecond),
      clock_id: "clock-test",
      source_instance_id: "inspect",
      source_sequence: sequence,
      wall_time: nil,
      subject: nil,
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: %{"operation" => "test"},
      payload: nil,
      authority: "session-test",
      redactions: [],
      extensions: %{}
    )
  end

  # Losses counted up to the seal were dropped with
  # the collector, so the last read reported none.
  test "a seal keeps the ingress loss counters the collectors reached" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [self()])

    session_options =
      options("session-seal-counters", [:telemetry])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())

    {:ok, handle} = Session.start(host_policy, session_options)
    collector = :sys.get_state(:sys.get_state(Manager).active.pid).components.telemetry

    # The inbox holds 256; with the collector suspended the rest are shed.
    :ok = :sys.suspend(collector)
    for count <- 1..300, do: :telemetry.execute([:session, :event], %{duration: count}, %{})
    :ok = :sys.resume(collector)

    assert {:ok, _sealed} = Session.seal_ingress(handle, 1_000)
    assert {:ok, read} = Session.read_events(handle, 0, limit: 1_000)
    assert %{"evidence" => "bounded_status", "shed" => 44, "recorded" => 256} = read["telemetry"]
    assert Enum.map(read["events"], & &1["receipt"]) == Enum.to_list(1..256)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "read events returns redacted events after a cursor and exact loss accounting" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    session_options =
      options("session-read-events", [:telemetry])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())

    {:ok, handle} = Session.start(host_policy, session_options)
    marker = "private-read-metadata-must-not-escape"
    :telemetry.execute([:session, :event], %{duration: 1}, %{private: marker})
    :telemetry.execute([:session, :event], %{duration: 2}, %{})

    assert {:ok, read} = Session.read_events(handle, 0, limit: 10)
    assert read["schema"] == "insider.collector-session-events/v1"
    assert %{"cursor" => 0, "next_cursor" => 2, "next_receipt" => 2, "truncated" => false} = read
    assert %{"evicted" => 0, "redaction_withheld" => 0} = read
    assert Enum.map(read["events"], & &1["receipt"]) == [1, 2]
    assert Enum.all?(read["events"], &(&1["event"]["kind"] == "session.event"))
    assert Enum.all?(read["events"], &(&1["redactions"] == []))
    assert hd(read["events"])["event"]["attributes"]["metadata"] == %{}
    assert read["telemetry"]["evidence"] == "bounded_status"
    assert read["logger"] == %{"configured" => false, "evidence" => "not_configured"}
    assert read["recorder_counters"]["rate_limited"] == 0
    refute Jason.encode!(read) =~ marker

    assert {:ok, %{"events" => [], "next_cursor" => 2}} = Session.read_events(handle, 2)
    assert {:error, :invalid_cursor} = Session.read_events(handle, 3)
    assert {:error, :invalid_cursor} = Session.read_events(handle, -1)
    assert {:error, :invalid_options} = Session.read_events(handle, 0, limit: 0)
    assert {:error, :invalid_options} = Session.read_events(handle, 0, unknown: true)
    assert {:error, :invalid_handle} = Session.read_events(:forged, 0)

    assert {:ok, %{"outcome" => "stopped"}} = Session.stop(handle)
    assert {:error, :expired_or_unknown_session} = Session.read_events(handle, 0)
  end

  test "read events withholds an event its trusted policy cannot redact and still advances" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    {:ok, tight_policy} =
      Insider.Redaction.Policy.new(
        id: "tight-read-policy",
        maximum_sensitivity: :internal,
        rules: [],
        max_input_bytes: 64
      )

    session_options =
      options("session-read-withheld", [:telemetry])
      |> Keyword.put(:telemetry_policy, telemetry_policy!())
      |> Keyword.put(:recorder_options, classification: {:internal, tight_policy})

    {:ok, handle} = Session.start(host_policy, session_options)
    :telemetry.execute([:session, :event], %{}, %{})

    assert {:ok, read} = Session.read_events(handle, 0)
    assert %{"events" => [], "redaction_withheld" => 1, "evicted" => 0, "next_cursor" => 1} = read

    assert {:ok, %{"outcome" => "stopped"}} = Session.stop(handle)
  end

  test "flush evidence routes an accepted timeout above one second to the Session" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    {:ok, handle} =
      Session.start(host_policy, options("session-long-evidence-timeout", [:logger]))

    session = :sys.get_state(Manager).active.pid
    original = :sys.get_state(session)
    parent = self()
    delayed = spawn(fn -> delayed_flush_loop(parent) end)

    on_exit(fn ->
      if Process.alive?(session), do: :sys.replace_state(session, fn _state -> original end)
      if Process.alive?(delayed), do: send(delayed, :stop)
      _ = Session.kill(handle)
    end)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, delayed)}
    end)

    task = Task.async(fn -> Session.flush_evidence(handle, 2_000) end)
    assert_receive {:delayed_flush_called, ^delayed}, 1_000
    Process.send_after(delayed, :release, 1_100)
    assert {:ok, %{"logger" => %{"evidence" => "bounded_status"}}} = Task.await(task, 3_000)

    :sys.replace_state(session, fn _state -> original end)
    send(delayed, :stop)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "flush evidence expires within its bound and leaves health responsive" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-evidence-timeout", [:logger]))
    session = :sys.get_state(Manager).active.pid
    original = :sys.get_state(session)

    unresponsive =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(session), do: :sys.replace_state(session, fn _state -> original end)
      if Process.alive?(unresponsive), do: send(unresponsive, :stop)
      _ = Session.kill(handle)
    end)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, unresponsive)}
    end)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :request_expired} = Session.flush_evidence(handle, 25)
    assert System.monotonic_time(:millisecond) - started_at < 150

    :sys.replace_state(session, fn _state -> original end)
    send(unresponsive, :stop)
    assert {:ok, %{"state" => "running"}} = Session.health(handle)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "flush evidence reduces malformed component output to a fixed unavailable marker" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-evidence-malformed", [:logger]))
    session = :sys.get_state(Manager).active.pid
    original = :sys.get_state(session)

    malformed = spawn(&malformed_status_loop/0)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, malformed)}
    end)

    assert {:ok, evidence} = Session.flush_evidence(handle, 200)

    assert evidence["logger"] == %{
             "configured" => true,
             "evidence" => "malformed_or_unavailable"
           }

    refute Jason.encode!(evidence) =~ "private"
    refute evidence["visible_inboxes_empty"]
    assert scalar_tree?(evidence)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, :invalid_owner)}
    end)

    assert {:ok, nonprocess_evidence} = Session.flush_ingress_evidence(handle, 200)
    assert nonprocess_evidence["logger"]["evidence"] == "malformed_or_unavailable"

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :poller, :invalid_owner)}
    end)

    assert {:error, :producer_quiescence_unavailable} = Session.flush_evidence(handle, 200)

    :sys.replace_state(session, fn _state -> original end)
    send(malformed, :stop)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "flush evidence rejects malformed requests and cannot inspect a dead session" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-evidence-dead", [:logger]))
    admission = Admission.new()

    assert {:ok, _evidence} = Session.flush_ingress_evidence(handle)
    assert {:ok, _evidence} = Session.flush_evidence(handle)

    assert {:error, :invalid_options} = Session.flush_evidence(handle, 0)
    assert {:error, :invalid_options} = Session.flush_evidence(handle, 5_001)
    assert {:error, :invalid_handle} = Session.flush_evidence(:invalid, 100)
    assert {:error, :invalid_options} = Session.flush_evidence(self(), admission, 0)
    assert {:error, :unavailable} = Session.flush_evidence(:invalid, admission, 100)
    assert {:error, :invalid_options} = Session.flush_ingress_evidence(handle, 0)
    assert {:error, :invalid_options} = Session.flush_ingress_evidence(handle, 5_001)
    assert {:error, :invalid_handle} = Session.flush_ingress_evidence(:invalid, 100)

    assert {:error, :invalid_options} =
             Session.flush_ingress_evidence(self(), admission, 0)

    assert {:error, :unavailable} =
             Session.flush_ingress_evidence(:invalid, admission, 100)

    invalid_admission = %Admission{counter: :invalid}
    assert {:error, :unavailable} = Session.health(self(), invalid_admission, 100)
    assert {:error, :unavailable} = Session.flush_evidence(self(), invalid_admission, 100)
    assert {:error, :unavailable} = Session.health(:invalid, Admission.new(), 100)

    overloaded_admission = Admission.new()

    Enum.each(1..256, fn _iteration ->
      assert :ok = Admission.acquire(overloaded_admission, 256)
    end)

    assert {:error, :mailbox_overloaded} =
             Session.flush_ingress_evidence(self(), overloaded_admission, 100)

    silent = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:error, :request_expired} =
             Session.flush_ingress_evidence(silent, Admission.new(), 25)

    send(silent, :stop)

    dead = spawn(fn -> receive do: (:stop -> :ok) end)
    dead_monitor = Process.monitor(dead)
    send(dead, :stop)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead, :normal}, 5000
    assert {:error, :unavailable} = Session.flush_evidence(dead, Admission.new(), 100)

    assert {:error, :expired_or_unknown_session} =
             Session.flush_evidence(%{handle | token: make_ref()}, 100)

    assert {:error, :expired_or_unknown_session} =
             Session.flush_ingress_evidence(%{handle | token: make_ref()}, 100)

    assert {:ok, _receipt} = Session.stop(handle)
    assert {:error, :expired_or_unknown_session} = Session.flush_evidence(handle, 100)

    assert {:error, :expired_or_unknown_session} =
             Session.flush_ingress_evidence(handle, 100)
  end

  test "Poller denies every session control-plane process before provider work" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    control_targets = [
      Process.whereis(Insider.Collector.Session.RootSupervisor),
      Process.whereis(Manager),
      Process.whereis(Insider.Collector.Session.Supervisor)
    ]

    session_options =
      options("session-control-plane-protection", [:poller])
      |> Keyword.put(:poller_options,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        targets: control_targets,
        provider: SessionProvider
      )

    {:ok, handle} = Session.start(host_policy, session_options)
    session = :sys.get_state(Manager).active.pid
    poller = :sys.get_state(session).components.poller
    %{timer: {_timer, token}} = :sys.get_state(poller)

    send(poller, {:scheduled_poll, token})

    assert_eventually(fn ->
      {:ok, status} = Insider.Collector.Poller.status(poller)

      status.probes_protected == length(control_targets) and status.probes_started == 1 and
        status.cycles_completed == 1
    end)

    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "owner death stops a session and retains only its bounded terminal health" do
    parent = self()
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    owner =
      spawn(fn ->
        {:ok, handle} = Session.start(host_policy, options("session-owner", [:logger]))
        send(parent, {:session_handle, handle})
      end)

    owner_monitor = Process.monitor(owner)
    assert_receive {:session_handle, handle}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000

    assert_eventually(fn -> match?({:ok, _health}, Session.health(handle)) end)
    assert {:ok, health} = Session.health(handle)
    assert health["terminal"]
    assert health["state"] in ["stopped", "cleanup_incomplete"]
  end

  test "manager failure resets the one_for_all session root and drops active ownership" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-manager-root-reset", [:logger]))
    old_manager = Process.whereis(Manager)
    old_dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    session = :sys.get_state(old_manager).active.pid
    session_monitor = Process.monitor(session)

    Process.exit(old_manager, :kill)
    assert_receive {:DOWN, ^session_monitor, :process, ^session, _reason}, 1_000

    assert_eventually(fn ->
      Process.whereis(Manager) not in [nil, old_manager] and
        Process.whereis(Insider.Collector.Session.Supervisor) not in [nil, old_dynamic] and
        DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor) == [] and
        not logger_filter_present?()
    end)

    assert {:error, :expired_or_unknown_session} = Session.health(handle)
  end

  # A repeated CI run found it: a start that
  # reached a restarted Manager before the root had restarted the session
  # DynamicSupervisor lost its worker to :noproc. The Manager kept that
  # start quarantined with no child and no worker, so every later start on
  # the node was refused as session_already_active (about 100 failures in
  # one run). The root now starts the DynamicSupervisor first, so it is
  # registered before the Manager admits any call.
  test "a restarted Manager admits calls only when the session supervisor is up" do
    old_manager = Process.whereis(Manager)
    parent = self()

    watcher =
      spawn_link(fn ->
        send(parent, {:watching, self()})
        send(parent, {:first_admission, await_admission(old_manager)})
      end)

    assert_receive {:watching, ^watcher}, 5_000
    Process.exit(old_manager, :kill)

    assert_receive {:first_admission, supervisor}, 5_000
    assert is_pid(supervisor), "the Manager admitted calls before the session supervisor started"

    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    assert {:ok, handle} = Session.start(host_policy, options("session-root-order", [:logger]))
    assert {:ok, _receipt} = Session.stop(handle)
  end

  # Spins until a new Manager has put its admission, and returns the session
  # supervisor's pid (or nil) at that instant.
  defp await_admission(old_manager) do
    case Process.whereis(Manager) do
      pid when is_pid(pid) and pid != old_manager ->
        if :persistent_term.get({Manager, pid}, :missing) == :missing,
          do: await_admission(old_manager),
          else: Process.whereis(Insider.Collector.Session.Supervisor)

      _other ->
        await_admission(old_manager)
    end
  end

  @tag capture_log: true
  test "dynamic supervisor failure resets Manager and reclaims only a dead owned Logger filter" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, _handle} = Session.start(host_policy, options("session-dynamic-root-reset", [:logger]))
    old_manager = Process.whereis(Manager)
    old_dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    manager_monitor = Process.monitor(old_manager)

    Process.exit(old_dynamic, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^old_manager, _reason}, 1_000

    assert_eventually(fn ->
      Process.whereis(Manager) not in [nil, old_manager] and
        Process.whereis(Insider.Collector.Session.Supervisor) not in [nil, old_dynamic] and
        DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor) == [] and
        not logger_filter_present?()
    end)
  end

  test "terminal receipts are capability-bound, retained only to the bounded history limit" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    {handles, receipts} =
      Enum.reduce(1..33, {[], []}, fn index, {handles, receipts} ->
        {:ok, handle} =
          Session.start(host_policy, options("session-history-#{index}", [:logger]))

        {:ok, receipt} = Session.stop(handle)
        {[handle | handles], [receipt | receipts]}
      end)

    [newest_handle | _] = handles
    [newest_receipt | _] = receipts
    oldest_handle = List.last(handles)

    assert {:ok, ^newest_receipt} = Session.kill(newest_handle)
    assert {:error, :expired_or_unknown_session} = Session.health(oldest_handle)

    forged = %{newest_handle | token: make_ref()}
    assert {:error, :expired_or_unknown_session} = Session.stop(forged)
  end

  # A session whose start runs past its budget is cancelled inside its own
  # init/1 (`:startup_cancelled`). The Manager returned that bare reason, so
  # Live reported start_failed with no receipt, or, when its start worker
  # died, a receipt with startup "other". Here the start is held until its
  # deadline has passed, the Manager is suspended so that the session's
  # cancelled result reaches it before its own timer, and then resumed.
  test "a start cancelled past its budget reports a timeout with its budget and elapsed time" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    manager = Process.whereis(Manager)
    parent = self()

    %{start_child_fun: real_start_child, startup_guard: %StartupGuard{table: table}} =
      :sys.get_state(manager)

    :sys.replace_state(manager, fn state ->
      %{
        state
        | start_child_fun: fn supervisor, spec ->
            send(parent, {:start_child_called, self()})
            receive do: (:go -> real_start_child.(supervisor, spec))
          end
      }
    end)

    # A suspension ends with the process that made it, so a failed test
    # leaves the Manager running; only its start function is restored.
    on_exit(fn ->
      if Process.alive?(manager),
        do: :sys.replace_state(manager, &%{&1 | start_child_fun: real_start_child})
    end)

    task =
      Task.async(fn -> Session.start(host_policy, options("session-slow-start", [:logger])) end)

    assert_receive {:start_child_called, worker}, 5_000

    # This start's authorization is the one whose deadline is still ahead.
    now = System.monotonic_time(:millisecond)
    [deadline] = for {_token, deadline} <- :ets.tab2list(table), deadline > now, do: deadline
    true = :erlang.suspend_process(manager)
    receive after: (max(0, deadline - System.monotonic_time(:millisecond) + 5) -> :ok)
    send(worker, :go)

    Eventually.await(
      fn ->
        {:messages, messages} = Process.info(manager, :messages)
        Enum.any?(messages, &match?({:session_start_result, ^worker, _result}, &1))
      end,
      5_000,
      "the cancelled start's result did not reach the Manager"
    )

    true = :erlang.resume_process(manager)
    assert {:error, receipt} = Task.await(task, 5_000)
    assert %{"outcome" => "startup_failed", "cleanup" => cleanup} = receipt
    assert cleanup["startup"] == "timeout"
    assert cleanup["start_budget_ms"] in 1..1_000
    assert cleanup["start_elapsed_ms"] >= cleanup["start_budget_ms"]
    assert :sys.get_state(manager).active == nil
  end

  test "a timed-out queued start cannot create late collector side effects" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    :ok = :sys.suspend(dynamic)

    on_exit(fn ->
      if Process.alive?(dynamic), do: :sys.resume(dynamic)
    end)

    assert {:error, receipt} =
             Session.start(host_policy, options("session-start-timeout", [:logger]))

    assert receipt["outcome"] == "startup_failed"
    assert receipt["cleanup"]["startup"] == "timeout"
    assert receipt["cleanup"]["start_budget_ms"] in 1..1_000
    assert receipt["cleanup"]["start_elapsed_ms"] >= receipt["cleanup"]["start_budget_ms"]

    :ok = :sys.resume(dynamic)

    # DynamicSupervisor may process the already queued call after the worker
    # dies. The Manager's removed authorization makes that late child stop
    # before `Session.init/1` can create a collector-owned resource.
    assert_eventually(fn ->
      DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor) == [] and
        not logger_filter_present?() and :sys.get_state(Manager).active == nil
    end)
  end

  test "a worker lost after child admission keeps the start slot quarantined until root cleanup" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    manager = Process.whereis(Manager)
    dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    parent = self()

    :sys.replace_state(manager, fn state ->
      start_child_fun = fn supervisor, child_spec ->
        {:ok, child} = result = DynamicSupervisor.start_child(supervisor, child_spec)
        send(parent, {:child_admitted_before_result, self(), child})

        receive do
          :deliver_start_result -> result
        end
      end

      %{state | start_child_fun: start_child_fun}
    end)

    on_exit(fn ->
      if Process.alive?(manager), do: Process.exit(manager, :kill)
    end)

    caller =
      spawn(fn ->
        send(
          parent,
          {:lost_worker_start_result,
           Session.start(host_policy, options("session-worker-down", [:logger]))}
        )

        receive do: (:startup_test_done -> :ok)
      end)

    on_exit(fn -> send(caller, :startup_test_done) end)

    assert_receive {:child_admitted_before_result, worker, child}, 1_000
    child_monitor = Process.monitor(child)

    Process.exit(worker, :kill)
    assert_receive {:lost_worker_start_result, {:error, receipt}}, 1_000
    assert receipt["outcome"] == "startup_failed"
    assert receipt["cleanup"]["startup"] == "killed"
    assert Process.alive?(child)
    assert [{:undefined, ^child, :worker, _modules}] = DynamicSupervisor.which_children(dynamic)

    # The worker's result is irrevocably lost; even an admitted child must not
    # become a new session or release the sole start slot by inferred absence.
    assert %{phase: :quarantined, worker: ^worker} = :sys.get_state(manager).active

    assert {:error, :session_already_active} =
             Session.start(host_policy, options("session-blocked-by-worker", [:logger]))

    manager_monitor = Process.monitor(manager)
    dynamic_monitor = Process.monitor(dynamic)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, :killed}, 1_000
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _reason}, 1_000
    assert_receive {:DOWN, ^dynamic_monitor, :process, ^dynamic, _reason}, 1_000

    assert_eventually(fn ->
      Process.whereis(Manager) not in [nil, manager] and
        Process.whereis(Insider.Collector.Session.Supervisor) not in [nil, dynamic] and
        DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor) == [] and
        not logger_filter_present?() and not telemetry_handler_present?()
    end)

    children = Supervisor.which_children(Insider.Collector.Session.RootSupervisor)

    assert Enum.any?(children, fn {_id, pid, _type, _modules} ->
             pid == Process.whereis(Manager) and pid != manager
           end)

    assert_no_session_resources()

    assert {:ok, healthy_handle} =
             Session.start(host_policy, options("session-after-worker-root-reset", [:logger]))

    assert {:ok, %{"state" => "running"}} = Session.health(healthy_handle)
    assert {:ok, _receipt} = Session.stop(healthy_handle)
    send(caller, :startup_test_done)
  end

  test "a Session admitted by DynamicSupervisor is not adopted without its ownership inventory" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    manager = Process.whereis(Manager)
    dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    parent = self()
    original_ownership_fun = :sys.get_state(manager).ownership_fun

    :sys.replace_state(manager, fn state ->
      ownership_fun = fn pid, _admission, _timeout ->
        send(parent, {:ownership_requested, pid})

        receive do
          :reject_ownership ->
            send(parent, {:ownership_rejected, pid})
            {:error, :unavailable}
        end
      end

      %{state | ownership_fun: ownership_fun}
    end)

    on_exit(fn ->
      if Process.whereis(Manager) == manager do
        :sys.replace_state(manager, fn state ->
          %{state | ownership_fun: original_ownership_fun}
        end)
      end

      if Process.alive?(dynamic), do: :sys.resume(dynamic)
    end)

    caller =
      spawn(fn ->
        send(
          parent,
          {:ownership_start_result,
           Session.start(host_policy, options("session-ownership-required", [:logger]))}
        )

        receive do: (:ownership_test_done -> :ok)
      end)

    assert_receive {:ownership_requested, session}, 1_000
    assert Process.alive?(session)

    # Holding the injected inventory provider proves the child has already
    # been admitted by DynamicSupervisor while no caller can obtain a handle.
    assert_receive {:ownership_start_result, {:error, :unavailable}}, 2_000

    :ok = :sys.suspend(dynamic)
    send(manager, :reject_ownership)
    assert_receive {:ownership_rejected, ^session}, 1_000

    pending = :sys.get_state(manager).active
    assert pending.pid == session
    assert pending.phase == :terminal_pending
    assert pending.pending_receipt["outcome"] == "startup_failed"
    assert pending.pending_receipt["cleanup"]["manager_ownership"] == "pending_manager_removal"

    :ok = :sys.resume(dynamic)
    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)

    [terminal | _history] = :sys.get_state(Manager).history
    assert terminal.receipt["outcome"] == "startup_failed"
    assert terminal.receipt["cleanup"]["manager_ownership"] == "absent"
    send(caller, :ownership_test_done)
  end

  test "Manager root restart does not block when Logger's stale-filter lock is contended" do
    parent = self()

    holder =
      spawn(fn ->
        :global.trans(
          {{LoggerCollector, :insider_logger, node()}, self()},
          fn ->
            send(parent, :logger_filter_lock_held)
            receive do: (:release_logger_filter_lock -> :ok)
          end,
          [node()],
          0
        )
      end)

    assert_receive :logger_filter_lock_held, 1_000
    old_manager = Process.whereis(Manager)
    Process.exit(old_manager, :kill)

    assert_eventually(fn -> Process.whereis(Manager) not in [nil, old_manager] end)
    send(holder, :release_logger_filter_lock)
  end

  test "a Manager-suspended request expires before it can create session side effects" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    manager = Process.whereis(Manager)
    :ok = :sys.suspend(manager)
    on_exit(fn -> resume_if_alive(manager) end)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:manager_queued_result,
         Session.start(host_policy, options("session-manager-queued", [:logger]))}
      )
    end)

    assert_receive {:manager_queued_result, {:error, :unavailable}}, 2_000
    :ok = :sys.resume(manager)

    assert_eventually(fn ->
      DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor) == [] and
        :sys.get_state(Manager).active == nil and not logger_filter_present?()
    end)
  end

  test "a suspended session is killed through the supervisor and verified absent after control timeout" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-suspended-control", [:logger]))
    session = :sys.get_state(Manager).active.pid
    monitor = Process.monitor(session)
    :ok = :sys.suspend(session)

    assert {:ok, receipt} = Session.kill(handle)
    assert receipt["outcome"] == "cleanup_incomplete"
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}, 1_000
    assert reason in [:shutdown, :killed]
    assert [] = DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor)
    assert :sys.get_state(Manager).active == nil
  end

  test "unavailable health for a live suspended Session retains kill authority" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-health-timeout-kill", [:logger]))
    session = :sys.get_state(Manager).active.pid
    :ok = :sys.suspend(session)

    assert {:error, :unavailable} = Session.health(handle)
    assert :running == :sys.get_state(Manager).active.phase

    assert {:ok, receipt} = Session.kill(handle)
    assert receipt["outcome"] == "cleanup_incomplete"
    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)
  end

  test "unexpected Session kill retains full forced cleanup until supervisor absence is proven" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    policy = telemetry_policy!()

    {:ok, handle} =
      Session.start(
        host_policy,
        options("session-unexpected-kill", [:logger, :telemetry])
        |> Keyword.put(:telemetry_policy, policy)
      )

    session = :sys.get_state(Manager).active.pid
    Process.exit(session, :kill)

    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)
    assert {:ok, receipt} = Session.kill(handle)
    assert receipt["outcome"] == "cleanup_incomplete"

    cleanup = receipt["cleanup"]

    assert Map.keys(cleanup) |> Enum.sort() ==
             [
               "components",
               "logger_filter",
               "manager_ownership",
               "monitors",
               "policy_reference",
               "recorder_ets",
               "session_timers",
               "telemetry_handler"
             ]

    assert cleanup["manager_ownership"] == "absent"
    refute logger_filter_present?()
    refute telemetry_handler_present?()

    assert {:ok, next} =
             Session.start(host_policy, options("session-unexpected-kill-next", [:logger]))

    assert {:ok, _receipt} = Session.stop(next)
  end

  test "forced kill with both Session and DynamicSupervisor suspended finalizes after supervisor recovery" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    policy = telemetry_policy!()

    {:ok, handle} =
      Session.start(
        host_policy,
        options("session-forced-cleanup", [:logger, :telemetry, :poller])
        |> Keyword.put(:telemetry_policy, policy)
        |> Keyword.put(:poller_options,
          initial_delay_ms: 60_000,
          interval_ms: 60_000,
          targets: [],
          provider: SessionProvider
        )
      )

    active = :sys.get_state(Manager).active
    dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    :ok = :sys.suspend(active.pid)
    :ok = :sys.suspend(dynamic)

    on_exit(fn ->
      if Process.alive?(dynamic), do: :sys.resume(dynamic)
    end)

    assert {:error, :cleanup_in_progress} = Session.kill(handle)
    assert :terminal_pending == :sys.get_state(Manager).active.phase

    :ok = :sys.resume(dynamic)
    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)

    assert {:ok, receipt} = Session.kill(handle)
    cleanup = receipt["cleanup"]

    assert Map.keys(cleanup) |> Enum.sort() ==
             [
               "components",
               "logger_filter",
               "manager_ownership",
               "monitors",
               "policy_reference",
               "recorder_ets",
               "session_timers",
               "telemetry_handler"
             ]

    assert Map.keys(cleanup["components"]) |> Enum.sort() ==
             ["logger", "poller", "recorder", "telemetry"]

    assert Enum.all?(cleanup["components"], fn {_component, status} ->
             status in ["absent", "residual", "unavailable"]
           end)

    assert Enum.all?(
             [
               "logger_filter",
               "telemetry_handler",
               "recorder_ets",
               "monitors",
               "session_timers",
               "policy_reference",
               "manager_ownership"
             ],
             &(cleanup[&1] in ["absent", "residual", "unavailable"])
           )

    assert {:ok, next} = Session.start(host_policy, options("session-forced-next", [:logger]))
    assert {:ok, _receipt} = Session.stop(next)
  end

  test "near-deadline control reserves observation time and never reports success after its deadline" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-control-deadline", [:logger]))
    session = :sys.get_state(Manager).active.pid
    :ok = :sys.suspend(session)
    started_at = System.monotonic_time(:millisecond)

    result = Session.kill(handle)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed <= 1_500

    case result do
      {:ok, _receipt} -> assert elapsed < 1_400
      {:error, :request_expired} -> :ok
      {:error, :cleanup_in_progress} -> :ok
    end

    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)
  end

  test "a suspended DynamicSupervisor keeps normal stop quarantined past the caller deadline" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    {:ok, handle} =
      Session.start(host_policy, options("session-stop-dynamic-suspended", [:logger]))

    dynamic = Process.whereis(Insider.Collector.Session.Supervisor)
    :ok = :sys.suspend(dynamic)

    on_exit(fn ->
      if Process.alive?(dynamic), do: :sys.resume(dynamic)
    end)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :cleanup_in_progress} = Session.stop(handle)
    assert System.monotonic_time(:millisecond) - started_at < 1_400

    pending = :sys.get_state(Manager).active
    assert pending.phase == :terminal_pending
    assert pending.pending_receipt["cleanup"]["manager_ownership"] == "pending_manager_removal"

    # The sole absence query is blocked in the suspended supervisor. Manager
    # remains responsive and does not manufacture a terminal receipt.
    assert {:error, :cleanup_in_progress} = Session.health(handle)

    Process.send_after(self(), :resume_dynamic_after_outer_timeout, 1_600)
    assert_receive :resume_dynamic_after_outer_timeout, 2_000
    :ok = :sys.resume(dynamic)

    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)
    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["cleanup"]["manager_ownership"] == "absent"
  end

  test "forged and stale handles never send a GenServer call to their embedded manager" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-forged-handle", [:logger]))
    parent = self()

    foreign =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _message} -> send(parent, :foreign_called)
        after
          100 -> send(parent, :foreign_idle)
        end
      end)

    forged = %{handle | manager: foreign}
    assert {:error, :expired_or_unknown_session} = Session.health(forged)
    assert_receive :foreign_idle, 1_000

    old_manager = Process.whereis(Manager)
    Process.exit(old_manager, :kill)
    assert_eventually(fn -> Process.whereis(Manager) not in [nil, old_manager] end)
    assert {:error, :expired_or_unknown_session} = Session.stop(handle)
  end

  test "a killed Telemetry component reclaims only its stale owned handler and permits the next session" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    policy = telemetry_policy!()

    {:ok, handle} =
      Session.start(
        host_policy,
        options("session-telemetry-crash", [:telemetry]) |> Keyword.put(:telemetry_policy, policy)
      )

    session = :sys.get_state(Manager).active.pid
    telemetry = :sys.get_state(session).components.telemetry
    Process.exit(telemetry, :kill)

    assert_eventually(fn -> not telemetry_handler_present?() end)
    assert {:ok, health} = Session.health(handle)
    assert health["terminal"]

    assert {:ok, next} =
             Session.start(
               host_policy,
               options("session-telemetry-next", [:telemetry])
               |> Keyword.put(:telemetry_policy, policy)
             )

    assert {:ok, _receipt} = Session.stop(next)
  end

  test "health is degraded when a configured component is absent before its DOWN is handled" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-absent-health", [:logger]))
    session = :sys.get_state(Manager).active.pid
    original = :sys.get_state(session)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.delete(state.components, :logger)}
    end)

    assert {:ok, health} = Session.health(handle)
    assert health["state"] == "degraded"
    assert health["components"]["logger"] == "absent"

    :sys.replace_state(session, fn _state -> original end)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "public Manager and Session calls reject recognized-call floods before their mailboxes grow" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    manager = Process.whereis(Manager)
    :ok = :sys.suspend(manager)
    on_exit(fn -> resume_if_alive(manager) end)

    {manager_tasks, manager_gate} =
      gated_tasks(300, fn ->
        Session.start(
          host_policy,
          options("session-manager-flood", [:logger]) |> Keyword.put(:environment, :staging)
        )
      end)

    assert_overloaded_results(manager_gate, 44)

    assert_eventually(fn ->
      Process.info(manager, :message_queue_len) == {:message_queue_len, 256}
    end)

    :ok = :sys.resume(manager)
    manager_results = Enum.map(manager_tasks, &Task.await(&1, 2_000))
    assert {:error, :mailbox_overloaded} in manager_results

    assert_eventually(fn -> :sys.get_state(Manager).active == nil end)
    {:ok, handle} = Session.start(host_policy, options("session-session-flood", [:logger]))
    active = :sys.get_state(Manager).active
    :ok = :sys.suspend(active.pid)

    on_exit(fn ->
      resume_if_alive(active.pid)
      _ = Session.kill(handle)
    end)

    {session_tasks, session_gate} =
      gated_tasks(300, fn ->
        Session.health(active.pid, active.session_admission, 1_000)
      end)

    assert_overloaded_results(session_gate, 44)

    assert_eventually(fn ->
      Process.info(active.pid, :message_queue_len) == {:message_queue_len, 256}
    end)

    :ok = :sys.resume(active.pid)
    session_results = Enum.map(session_tasks, &Task.await(&1, 2_000))
    assert {:error, :mailbox_overloaded} in session_results
    assert {:ok, _receipt} = Session.kill(handle)
  end

  test "internal admission envelopes require the exact acquired capability" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-admission-capability", [:logger]))
    manager = Process.whereis(Manager)
    session = :sys.get_state(manager).active.pid
    deadline = System.monotonic_time(:millisecond) + 1_000
    forged_manager_admission = Admission.new()
    forged_session_admission = Admission.new()

    assert {:error, :invalid_request} =
             GenServer.call(
               manager,
               {:admitted, forged_manager_admission, deadline, {:health, handle}}
             )

    assert {:error, :invalid_request} =
             GenServer.call(session, {:admitted, forged_session_admission, :health})

    assert {:ok, health} = Session.health(handle)
    assert health["state"] == "running"
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "active-session health and termination reject a capability-mismatched handle" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-active-forgery", [:logger]))
    forged = %{handle | token: make_ref()}

    assert {:error, :expired_or_unknown_session} = Session.health(forged)
    assert {:error, :expired_or_unknown_session} = Session.stop(forged)
    assert {:ok, %{"state" => "running"}} = Session.health(handle)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "health bounds malformed component identities and status values" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-malformed-component", [:logger]))
    session = :sys.get_state(Manager).active.pid
    original = :sys.get_state(session)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, :invalid)}
    end)

    assert {:ok, health} = Session.health(handle)
    assert health["components"]["logger"] == "unavailable"

    malformed =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :status} -> GenServer.reply(from, {:ok, %{nested: []}})
        end
      end)

    :sys.replace_state(session, fn state ->
      %{state | components: Map.put(state.components, :logger, malformed)}
    end)

    assert {:ok, health} = Session.health(handle)
    assert health["components"]["logger"] == "unavailable"

    :sys.replace_state(session, fn _state -> original end)
    assert {:ok, _receipt} = Session.stop(handle)
  end

  test "public and internal lifecycle entry points reject malformed values" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])

    assert {:error, :invalid_options} = Session.start(:invalid_policy, [])
    assert {:error, :invalid_options} = Session.start(host_policy, :invalid_options)
    assert {:error, :invalid_options} = Session.prepare(self(), :invalid_policy, [])

    assert {:error, :invalid_options} =
             Session.prepare(
               self(),
               host_policy,
               Keyword.put(options("invalid-profile", [:logger]), :environment, :unknown)
             )

    assert {:error, :invalid_options} =
             Session.prepare(
               self(),
               host_policy,
               Keyword.put(options("invalid-recorder", [:logger]), :recorder_options, [])
             )

    assert {:error, :invalid_options} = Manager.start(host_policy, :invalid_options)
    assert {:error, :invalid_handle} = Manager.health(:invalid_handle)
    assert {:error, :invalid_handle} = Manager.stop(:invalid_handle)
    assert {:error, :invalid_handle} = Manager.kill(:invalid_handle)
    assert {:error, :unavailable} = Session.health(:invalid_pid, make_ref(), 1)
    assert {:error, :unavailable} = Session.ownership(self(), :invalid_admission, 1)

    assert %{restart: :temporary, type: :worker} = Session.child_spec(:arguments)

    assert {:error, {:already_started, _pid}} =
             Insider.Collector.Session.RootSupervisor.start_link()

    start_link_task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        Session.start_link({self(), %{startup_guard: :invalid}, make_ref(), "s-cancelled-link"})
      end)

    assert {:error, :startup_cancelled} = Task.await(start_link_task)

    task =
      Task.async(fn ->
        Session.init({self(), %{startup_guard: :invalid}, make_ref(), "s-cancelled"})
      end)

    assert {:stop, :startup_cancelled} = Task.await(task)

    manager_admission_key = {Manager, self()}
    :persistent_term.put(manager_admission_key, Insider.Collector.Admission.new())
    on_exit(fn -> :persistent_term.erase(manager_admission_key) end)
    assert :ok = Manager.terminate(:normal, %{})
    assert :missing = :persistent_term.get(manager_admission_key, :missing)

    malformed_handle = %Handle{id: nil, incarnation: nil, manager: nil, token: nil}
    assert {:error, :invalid_handle} = Manager.health(malformed_handle)

    manager = Process.whereis(Manager)
    admission = :sys.get_state(manager).admission
    assert :ok = Insider.Collector.Admission.acquire(admission, 256)

    assert {:error, :invalid_request} =
             GenServer.call(
               manager,
               {:admitted, admission, System.monotonic_time(:millisecond) + 1_000, :unsupported}
             )
  end

  test "unknown system messages are ignored and a raw mailbox overload shuts down conservatively" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-raw-mailbox-bound", [:logger]))
    session = :sys.get_state(Manager).active.pid

    send(session, {:DOWN, make_ref(), :process, self(), :synthetic})
    send(session, {:EXIT, self(), :synthetic})
    assert {:ok, %{"state" => "running"}} = Session.health(handle)

    monitor = Process.monitor(session)
    :ok = :sys.suspend(session)
    Enum.each(1..258, fn _ -> send(session, :unsupported_raw_message) end)
    :ok = :sys.resume(session)

    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    assert_eventually(fn -> match?({:ok, %{"terminal" => true}}, Session.health(handle)) end)
    assert {:ok, receipt} = Session.kill(handle)
    assert receipt["outcome"] == "cleanup_incomplete"
  end

  test "an exact monitored-component DOWN signal produces conservative terminal evidence" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-component-down", [:logger]))
    session = :sys.get_state(Manager).active.pid
    state = :sys.get_state(session)
    logger = state.components.logger

    {monitor, :logger} = Enum.find(state.monitors, fn {_monitor, owner} -> owner == :logger end)
    send(session, {:DOWN, monitor, :process, logger, :synthetic})

    assert_eventually(fn -> match?({:ok, %{"terminal" => true}}, Session.health(handle)) end)
    assert {:ok, receipt} = Session.stop(handle)
    assert receipt["outcome"] == "cleanup_incomplete"
  end

  test "supplemental receipt constructors remain bounded and causal" do
    active = %{id: "receipt-session", incarnation: "s-receipt"}

    unexpected = Session.unexpected_receipt(active, :synthetic_exit, :absent)
    assert unexpected["outcome"] == "cleanup_incomplete"
    assert unexpected["cleanup"]["manager_child"] == "absent"
    assert unexpected["cleanup"]["session_exit"] == "other"

    startup = Session.startup_cleanup_receipt(active, %{"logger_filter" => "absent"})
    assert startup["outcome"] == "startup_failed"
    assert startup["cleanup"]["startup"] == "inventory_unavailable"
  end

  test "a late successful start result is quarantined and removed before retention" do
    {:ok, host_policy} = HostPolicy.new(host_protected_targets: [])
    {:ok, handle} = Session.start(host_policy, options("session-late-result", [:logger]))
    manager_state = :sys.get_state(Manager)
    worker = spawn(fn -> Process.sleep(:infinity) end)
    late_child = manager_state.active.pid

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      _ = Session.kill(handle)
    end)

    replay_active =
      manager_state.active
      |> Map.put(:worker, worker)
      |> Map.put(:worker_monitor, Process.monitor(worker))

    assert {:noreply, replayed_state} =
             Manager.handle_info(
               {:session_start_result, worker, {:ok, late_child}},
               %{manager_state | active: replay_active}
             )

    refute Process.alive?(late_child)
    assert replayed_state.active == nil
    assert [%{receipt: %{"outcome" => "startup_failed"}} | _] = replayed_state.history

    worker_monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert_eventually(fn -> match?({:ok, %{"terminal" => true}}, Session.health(handle)) end)
  end

  def passthrough(event, _config), do: event
  def telemetry_ignore(_event, _measurements, _metadata, _config), do: :ok

  defp assert_no_session_resources do
    assert [] = DynamicSupervisor.which_children(Insider.Collector.Session.Supervisor)

    refute logger_filter_present?()

    refute telemetry_handler_present?()
  end

  defp logger_filter_present? do
    Enum.any?(:logger.get_primary_config().filters, fn {id, _filter} -> id == :insider_logger end)
  end

  defp telemetry_handler_present? do
    Enum.any?(:telemetry.list_handlers([:session, :event]), fn row ->
      row.id == "insider-session-telemetry"
    end)
  end

  # Supervision transitions and gated caller enqueueing are asynchronous to
  # their observer. Wait only for an explicit state predicate; this is not
  # used to retry a failed operation. The bound was 20 polls (200 ms), too
  # short for a supervised restart on a loaded 2-vCPU runner.
  defp assert_eventually(predicate),
    do: Eventually.await(predicate, 5_000, "supervision transition did not complete")

  # Some tests kill the Manager or the session root, then wait only until a
  # new Manager is registered. GenServer registers the name before init/1
  # runs, and init/1 reclaims a stale Logger filter before it admits calls.
  # Until then, Session.start/2 correctly gives {:error, :unavailable}. So
  # each test starts only after the Manager has completed init/1.
  defp manager_ready!(deadline) do
    cond do
      manager_ready?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the session Manager did not complete init/1")

      true ->
        Process.sleep(10)
        manager_ready!(deadline)
    end
  end

  # :sys.get_state/2 replies only after init/1 returns, and init/1 puts the
  # admission before it returns.
  defp manager_ready? do
    case Process.whereis(Manager) do
      nil -> false
      pid -> match?(%{admission: %Admission{}}, :sys.get_state(pid, 1_000))
    end
  catch
    :exit, _reason -> false
  end

  defp gated_tasks(count, call) do
    parent = self()
    gate = make_ref()

    tasks =
      Enum.map(1..count, fn _index ->
        Task.async(fn ->
          send(parent, {:flood_ready, gate, self()})

          receive do
            {:start_flood, ^gate} -> :ok
          end

          result = call.()
          send(parent, {:flood_result, gate, result})
          result
        end)
      end)

    ready =
      Enum.map(tasks, fn _task ->
        receive do
          {:flood_ready, ^gate, pid} -> pid
        after
          2_000 -> flunk("flood worker did not reach the start gate")
        end
      end)

    assert MapSet.new(ready) == MapSet.new(tasks, & &1.pid)
    Enum.each(tasks, &send(&1.pid, {:start_flood, gate}))
    {tasks, gate}
  end

  defp assert_overloaded_results(gate, count) do
    Enum.each(1..count, fn _index ->
      assert_receive {:flood_result, ^gate, {:error, :mailbox_overloaded}}, 2_000
    end)
  end

  defp resume_if_alive(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp options(id, components) do
    [
      id: id,
      environment: :test,
      authority: "session-test",
      boot_id: "boot-test",
      clock_id: "session-clock",
      recorder_options: [classification: Insider.TestRecorderClassification.binding()],
      components: components,
      logger_options: [drain_interval_ms: 1_000]
    ]
  end

  defp telemetry_policy! do
    {:ok, policy} =
      TelemetryPolicy.new(
        id: "session-telemetry",
        events: [
          [name: [:session, :event], kind: "session.event", lifecycle: "session", phase: :event]
        ]
      )

    policy
  end

  defp scalar_tree?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, child} ->
        is_binary(key) and byte_size(key) <= 128 and scalar_tree?(child)
      end)

  defp scalar_tree?(value), do: is_binary(value) or is_integer(value) or is_boolean(value)

  defp delayed_flush_loop(parent) do
    receive do
      {:"$gen_call", from, :flush} ->
        send(parent, {:delayed_flush_called, self()})

        receive do
          :release -> GenServer.reply(from, {:ok, logger_evidence_status()})
        end

        delayed_flush_loop(parent)

      :stop ->
        :ok
    end
  end

  defp logger_evidence_status do
    %{
      received: 0,
      enqueued: 0,
      shed: 0,
      invalid: 0,
      recorded: 0,
      recorder_dropped: 0,
      payload_suppressed: 0,
      message_semantics_suppressed: 0,
      metadata_suppressed: 0,
      exemplars_shed: 0,
      exemplars_invalid: 0,
      exemplars_late: 0,
      exemplars_unrecorded: 0,
      inbox_count: 0,
      inbox_capacity: 1
    }
  end

  defp malformed_status_loop do
    receive do
      {:"$gen_call", from, :flush} ->
        GenServer.reply(from, {:ok, :private_status})
        malformed_status_loop()

      :stop ->
        :ok
    end
  end
end
