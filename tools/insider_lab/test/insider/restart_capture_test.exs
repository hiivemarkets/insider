defmodule Insider.Incident.RestartCaptureTest do
  use ExUnit.Case, async: true

  alias Insider.Adapter.CLI
  alias Insider.Fixtures
  alias Insider.Incident.Capsule
  alias Insider.Incident.ExportPolicy
  alias Insider.Incident.RestartCapture
  alias Insider.Incident.RestartCapture.Owner
  alias Insider.Protocol.Error
  alias Insider.TestSupport.RestartCaptureFixtureRunner
  alias Insider.TestSupport.RestartCaptureHost
  alias Insider.TestSupport.RestartCaptureImmediateRunner

  @capability "phase-b-capture-capability"
  @capture_setup_deadline_ms 1_000
  # Mirrors RestartCapture.Owner's bounded owner-cleanup confirmation window.
  @owner_cleanup_timeout_ms 1_000
  @scheduler_slack_ms 250

  # Owner work such as starting a recorder or loading code on first use has no
  # fixed duration. Tests that drive RestartCapture.Owner directly therefore
  # synchronise on the owner rather than on a wall-clock window. The owner is a
  # GenServer, so :sys.get_state/1 returns only after it has handled every
  # message this process sent before the call. Messages between two processes
  # keep their order, so anything the owner sent while handling those messages
  # is already in the mailbox for assert_received. An owner sends whatever it
  # reports before it exits, so its DOWN plays the same role.

  setup do
    host = start_supervised!({RestartCaptureHost, capability_reference: @capability})
    %{host: host}
  end

  @tag capture_log: true
  test "one authorized command emits one offline-valid redacted capsule for the real faulty fixture",
       %{
         host: host
       } do
    result = invoke!(request("faulty-capture", "faulty"), host)

    assert result["status"] == "ok"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["value"]["fixed_budgets"] == fixed_budgets()
    assert result["value"]["authorization"]["capture_audit_id"] == "phase-b-capture"
    assert result["value"]["authorization"]["export_audit_id"] == "phase-b-export"

    refute result["value"]["authorization"]["capture_decision_id"] ==
             result["value"]["authorization"]["export_decision_id"]

    assert [capsule_bytes] = result["value"]["capsules"]
    assert [capsule_id] = result["value"]["capsule_ids"]
    assert {:ok, capsule} = Capsule.decode(capsule_bytes)
    assert capsule.id == capsule_id

    assert capsule.authority == %{
             "capture_audit_id" => "phase-b-capture",
             "export_audit_id" => "phase-b-export"
           }

    assert capsule.id == "sha256:" <> capsule.integrity["content_digest"]
    assert capsule.finding["detector"] == "restart_recurrence"
    assert capsule.finding["details"]["count"] == 3
    assert capsule.snapshot["retained_count"] == 3
    assert capsule.snapshot["counters"]["accepted"] == 3
    assert capsule.snapshot["counters"]["duplicate"] == 1
    assert capsule.snapshot["gaps"] == ["prehistory_unavailable"]

    assert capsule.provenance["components"]["configuration"]["attributes"][
             "observer_effect"
           ] == "synchronous_fixture_lifecycle_projection"

    target = capsule.provenance["components"]["target"]["attributes"]
    assert target["fixture_cleanup"] == "complete"
    assert target["alive_after_fixture_cleanup"] == 0
    assert target["fixture_resources_observed"] <= fixed_budgets()["max_resources"]
    refute capsule_bytes =~ "must-not-export"
    assert capsule_bytes =~ "[REDACTED]"
    assert {:ok, ^capsule} = Capsule.validate(capsule)

    evidence = result["value"]["evidence"]
    assert evidence["cleanup"] == %{"status" => "complete"}
    assert evidence["truncation"] == %{"dropped_events" => 0, "status" => "none"}
    assert evidence["loss"]["gaps"] == ["prehistory_unavailable"]
    assert evidence["consumption"]["events"] == 3
    assert evidence["consumption"]["capsule_bytes"] == byte_size(capsule_bytes)
    assert evidence["consumption"]["resources"] == 10
    assert evidence["consumption"]["duration_us"] > 0
    assert result["consumption"]["resources"] == 10
  end

  @tag capture_log: true
  test "the identical healthy control remains quiet", %{host: host} do
    result = invoke!(request("healthy-capture", "healthy"), host)

    assert result["status"] == "ok"
    assert result["value"]["capsules"] == []
    assert result["value"]["capsule_ids"] == []
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["consumption"]["resources"] == 7
    assert result["consumption"]["duration_us"] > 0
  end

  test "trusted policy denies the command before the fixture runs" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    denied = request("denied", "faulty") |> Map.delete("capability") |> invoke!(host)
    assert denied["status"] == "error"
    assert denied["error"]["code"] == "policy_denied"
    assert denied["consumption"] == %{}
    refute_received {:capture_work_started, _request_id, _lease, _owner, _resources}

    undeclared = invoke!(request("undeclared", "unknown"), host)
    assert undeclared["error"]["code"] == "invalid_request"
    refute_received {:capture_work_started, _request_id, _lease, _owner, _resources}

    insufficient_request = put_in(request("insufficient", "faulty"), ["budget", "max_events"], 15)
    insufficient = invoke!(insufficient_request, host)
    assert insufficient["status"] == "timeout"
    assert insufficient["cleanup"] == %{"status" => "not_required"}
    assert insufficient["consumption"] == %{}
    refute_received {:capture_work_started, _request_id, _lease, _owner, _resources}

    assert GenServer.call(host, :undeclared_message) == :invalid_request
  end

  test "started timeout and cancellation terminate their observed resources" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    # The fixture starts its worker asynchronously, and the work is not
    # begun here, so the capture always ends at its deadline. Its budget
    # must leave the worker time to start (30 ms did not, 2 of about 9 CI
    # runs) and must end well before the fixture owner's own 1 s deadline:
    # at 1 s the owner sometimes stopped first, and the capture reported the
    # fixture failed (`:error`). 300 ms meets both.
    timeout_task = Task.async(fn -> invoke!(request("timeout", "faulty", 300), host) end)

    assert_receive {:capture_work_started, "timeout", timeout_lease, timeout_owner,
                    timeout_initial},
                   5000

    assert_receive {:capture_resource, ^timeout_lease, timeout_worker, :worker}, 5000
    timeout_resources = [timeout_owner, timeout_worker | timeout_initial]
    timeout_monitors = monitor_resources(timeout_resources)
    timeout = Task.await(timeout_task, 5_000)
    assert timeout["status"] == "timeout", inspect(timeout)
    assert timeout["error"]["code"] == "deadline_exceeded"
    assert timeout["cleanup"] == %{"status" => "uncertain"}
    assert_receive {:capture_work_cleaned, ^timeout_lease, timeout_cleaned, :complete}, 1_000
    assert MapSet.new(timeout_cleaned) == MapSet.new(timeout_resources)
    assert_resources_down(timeout_monitors)
    assert_receive {:capture_lease_released, "timeout"}, 5000

    cancelled_task = Task.async(fn -> invoke!(request("cancelled", "faulty"), host) end)

    assert_receive {:capture_work_started, "cancelled", cancel_lease, cancel_owner,
                    cancel_initial},
                   5000

    assert_receive {:capture_resource, ^cancel_lease, cancel_worker, :worker}, 5000
    cancel_monitors = monitor_resources([cancel_owner, cancel_worker | cancel_initial])
    send(host, {:cancel_capture, "cancelled"})
    assert Task.yield(cancelled_task, 0) == nil
    send(host, {:cancel_capture, cancel_lease})
    cancelled = Task.await(cancelled_task, 1_000)
    assert cancelled["status"] == "cancelled"
    assert cancelled["cleanup"] == %{"status" => "complete"}
    assert cancelled["consumption"]["resources"] == 4
    assert cancelled["consumption"]["duration_us"] > 0
    assert cancelled["warnings"] == ["cancellation does not roll back observed effects"]
    assert_receive {:capture_work_cleaned, ^cancel_lease, cancel_cleaned, :complete}, 5000

    assert MapSet.new(cancel_cleaned) ==
             MapSet.new([cancel_owner, cancel_worker | cancel_initial])

    assert_resources_down(cancel_monitors)
    assert_receive {:capture_lease_released, "cancelled"}, 5000

    owned_timeout_task =
      Task.async(fn ->
        GenServer.call(
          host,
          {:dispatch, request_term("owned-timeout", "faulty", 300)},
          :infinity
        )
      end)

    assert_receive {:capture_work_started, "owned-timeout", owned_lease, owned_owner,
                    owned_initial},
                   5000

    assert_receive {:capture_resource, ^owned_lease, owned_worker, :worker}, 5000
    owned_monitors = monitor_resources([owned_owner, owned_worker | owned_initial])
    owned_timeout = Task.await(owned_timeout_task, 5_000)
    assert owned_timeout.status == :timeout, inspect(owned_timeout)
    assert owned_timeout.cleanup == %{status: :complete}
    assert owned_timeout.consumption.resources == 4
    assert owned_timeout.consumption.duration_us > 0
    assert_receive {:capture_work_cleaned, ^owned_lease, owned_cleaned, :complete}, 5000
    assert MapSet.new(owned_cleaned) == MapSet.new([owned_owner, owned_worker | owned_initial])
    assert_resources_down(owned_monitors)
    assert_receive {:capture_lease_released, "owned-timeout"}, 5000
  end

  test "cancellation after fixture completion cleans the admitted capture lifecycle" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    {task, lease, resources, _capture_owner} = admit_faulty_capture(host, "capture-cancel")
    monitors = monitor_resources(resources)
    send(host, {:cancel_capture, lease})
    result = Task.await(task, 1_000)
    assert result["status"] == "cancelled"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["consumption"]["resources"] == 10
    assert result["consumption"]["duration_us"] > 0
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :complete}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "capture-cancel"}, 5000
  end

  test "capture owner death after fixture completion reports exact observed uncertainty" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    {task, lease, resources, capture_owner} = admit_faulty_capture(host, "capture-owner-death")
    monitors = monitor_resources(resources)
    Process.exit(capture_owner, :kill)
    result = Task.await(task, 1_000)
    assert result["status"] == "error"
    assert result["error"]["code"] == "operation_failed"
    assert result["cleanup"] == %{"status" => "uncertain"}
    assert result["consumption"]["resources"] == 10
    assert result["consumption"]["duration_us"] > 0
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :uncertain}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "capture-owner-death"}, 5000
  end

  test "a recorder reservation accounts owner death before readiness" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    task = Task.async(fn -> invoke!(request("recorder-admission-death", "faulty"), host) end)

    {lease, resources, capture_owner} =
      observe_recorder_admission(host, "recorder-admission-death")

    monitors = monitor_resources(resources)
    Process.exit(capture_owner, :kill)

    result = Task.await(task, 1_000)
    assert result["status"] == "error"
    assert result["cleanup"] == %{"status" => "uncertain"}
    assert result["consumption"]["resource_pids"] == 9
    assert result["consumption"]["resources"] == 9
    assert result["consumption"]["unmaterialized_resource_slots"] == 0
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :uncertain}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "recorder-admission-death"}, 5000
  end

  test "fixture owner death reports the observed command resources and releases admission" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    task = Task.async(fn -> invoke!(request("fixture-owner-death", "faulty"), host) end)

    assert_receive {:capture_work_started, "fixture-owner-death", lease, fixture_owner, initial},
                   5000

    assert_receive {:capture_resource, ^lease, fixture_worker, :worker}, 5000
    resources = [fixture_owner, fixture_worker | initial]
    monitors = monitor_resources(resources)
    Process.exit(fixture_owner, :kill)

    result = Task.await(task, 1_000)
    assert result["status"] == "error"
    assert result["error"]["code"] == "operation_failed"
    assert result["cleanup"] == %{"status" => "uncertain"}
    assert result["consumption"]["resources"] == 4
    assert result["consumption"]["duration_us"] > 0
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :uncertain}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "fixture-owner-death"}, 5000
    assert GenServer.call(host, :undeclared_message) == :invalid_request
  end

  test "dispatcher death after capture admission cleans all real resources" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    caller =
      spawn(fn ->
        GenServer.call(
          host,
          {:dispatch, request_term("dispatcher-death", "faulty")},
          :infinity
        )
      end)

    caller_monitor = Process.monitor(caller)
    {lease, resources, _capture_owner} = observe_faulty_capture(host, "dispatcher-death")
    resource_monitors = monitor_resources(resources)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 5000
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :complete}, 1_000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(resource_monitors)
    assert_receive {:capture_lease_released, "dispatcher-death"}, 5000
    assert GenServer.call(host, :undeclared_message) == :invalid_request
  end

  test "a deadline after capture admission cancels only after real resource cleanup" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    task =
      Task.async(fn ->
        GenServer.call(
          host,
          {:dispatch, request_term("capture-deadline", "faulty", 500)},
          :infinity
        )
      end)

    {lease, resources, _capture_owner} = observe_faulty_capture(host, "capture-deadline")
    monitors = monitor_resources(resources)
    result = Task.await(task, 1_000)

    assert result.status == :timeout
    assert result.cleanup == %{status: :complete}
    assert result.consumption.resources == 10
    assert result.consumption.duration_us > 0
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :complete}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "capture-deadline"}, 5000
  end

  test "the correlated dispatcher-down signal cleans either admitted lifecycle phase" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    fixture_task =
      Task.async(fn ->
        GenServer.call(
          host,
          {:dispatch, request_term("fixture-dispatcher-down", "faulty")},
          :infinity
        )
      end)

    assert_receive {:capture_work_started, "fixture-dispatcher-down", fixture_lease,
                    fixture_owner, fixture_initial},
                   5000

    assert_receive {:capture_resource, ^fixture_lease, fixture_worker, :worker}, 5000
    fixture_resources = [fixture_owner, fixture_worker | fixture_initial]
    fixture_monitors = monitor_resources(fixture_resources)
    fixture_runner = :sys.get_state(host).lease.worker
    send(fixture_runner, {:dispatcher_down, fixture_lease})

    fixture_result = Task.await(fixture_task, 1_000)
    assert fixture_result.status == :timeout
    assert fixture_result.cleanup == %{status: :complete}
    assert fixture_result.consumption.resources == 4
    assert_receive {:capture_work_cleaned, ^fixture_lease, fixture_cleaned, :complete}, 5000
    assert MapSet.new(fixture_cleaned) == MapSet.new(fixture_resources)
    assert_resources_down(fixture_monitors)
    assert_receive {:capture_lease_released, "fixture-dispatcher-down"}, 5000

    capture_task =
      Task.async(fn ->
        GenServer.call(
          host,
          {:dispatch, request_term("capture-dispatcher-down", "faulty")},
          :infinity
        )
      end)

    {capture_lease, capture_resources, _capture_owner} =
      observe_faulty_capture(host, "capture-dispatcher-down")

    capture_monitors = monitor_resources(capture_resources)
    capture_runner = :sys.get_state(host).lease.worker
    send(capture_runner, {:dispatcher_down, capture_lease})

    capture_result = Task.await(capture_task, 1_000)
    assert capture_result.status == :timeout
    assert capture_result.cleanup == %{status: :complete}
    assert capture_result.consumption.resources == 10
    assert_receive {:capture_work_cleaned, ^capture_lease, capture_cleaned, :complete}, 5000
    assert MapSet.new(capture_cleaned) == MapSet.new(capture_resources)
    assert_resources_down(capture_monitors)
    assert_receive {:capture_lease_released, "capture-dispatcher-down"}, 5000
    assert GenServer.call(host, :undeclared_message) == :invalid_request
  end

  test "the observed async boundary executes only after its correlated continuation" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    {task, lease, resources, _capture_owner} = admit_faulty_capture(host, "capture-continue")
    monitors = monitor_resources(resources)
    assert Task.yield(task, 0) == nil
    send(host, {:continue_capture, lease})
    result = Task.await(task, 1_000)
    assert result["status"] == "ok"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["consumption"]["resources"] == 10
    assert_receive {:capture_work_cleaned, ^lease, cleaned, :complete}, 5000
    assert MapSet.new(cleaned) == MapSet.new(resources)
    assert_resources_down(monitors)
    assert_receive {:capture_lease_released, "capture-continue"}, 5000
  end

  @tag capture_log: true
  test "a real started capture preserves typed export rejection and cleanup" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, :reject_export}}
      )

    failed = invoke!(request("export-failure", "faulty"), host)
    assert failed["status"] == "error"
    assert failed["error"]["code"] == "invalid_capsule"
    assert failed["cleanup"] == %{"status" => "complete"}
  end

  test "fixed-capacity admission rejects overload without starting another capture" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    dispatcher = RestartCaptureHost.dispatcher(host)
    first = Task.async(fn -> CLI.invoke(request_term("first", "faulty"), dispatcher) end)
    assert_receive {:capture_work_started, "first", first_lease, first_owner, first_initial}, 5000
    assert_receive {:capture_resource, ^first_lease, first_worker, :worker}, 5000
    first_monitors = monitor_resources([first_owner, first_worker | first_initial])

    overloaded = CLI.invoke(request_term("second", "faulty"), dispatcher)
    assert overloaded.status == :error

    assert %Error{code: :operation_failed, details: %{reason: "overloaded"}, retryable: true} =
             overloaded.error

    assert overloaded.cleanup == %{status: :not_required}
    refute_received {:capture_work_started, "second", _lease, _owner, _resources}

    send(host, {:cancel_capture, first_lease})
    assert Task.await(first).status == :cancelled
    assert_receive {:capture_work_cleaned, ^first_lease, _resources, :complete}, 5000
    assert_resources_down(first_monitors)
    assert_receive {:capture_lease_released, "first"}, 5000

    third = Task.async(fn -> CLI.invoke(request_term("third", "faulty"), dispatcher) end)
    assert_receive {:capture_work_started, "third", third_lease, third_owner, third_initial}, 5000
    assert_receive {:capture_resource, ^third_lease, third_worker, :worker}, 5000
    third_monitors = monitor_resources([third_owner, third_worker | third_initial])
    send(host, {:cancel_capture, third_lease})
    assert Task.await(third).status == :cancelled
    assert_receive {:capture_work_cleaned, ^third_lease, _resources, :complete}, 5000
    assert_resources_down(third_monitors)
    assert_receive {:capture_lease_released, "third"}, 5000
  end

  test "host shutdown cascades through its active lease and resource" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureFixtureRunner, self()}}
      )

    caller = spawn(fn -> invoke!(request("host-shutdown", "faulty"), host) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:capture_work_started, "host-shutdown", lease, fixture_owner, initial}, 5000
    assert_receive {:capture_resource, ^lease, worker, :worker}, 5000
    resource_monitors = monitor_resources([fixture_owner, worker | initial])
    stop_supervised!(RestartCaptureHost)
    assert_resources_down(resource_monitors)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _reason}, 5000
  end

  @tag capture_log: true
  test "a retry is served from the bounded idempotency cache without rerunning the fixture", %{
    host: host
  } do
    first = invoke!(request("retry-1", "faulty", 3_000, "same-intent"), host)
    second = invoke!(request("retry-2", "faulty", 3_000, "same-intent"), host)

    assert first["value"]["deduplicated_retry"] == false
    assert second["value"]["deduplicated_retry"] == true
    assert first["value"]["capsules"] == second["value"]["capsules"]
    assert first["value"]["capsule_ids"] == second["value"]["capsule_ids"]
    assert second["effects"] == []
    assert second["cleanup"] == %{"status" => "not_required"}
    assert second["consumption"]["events"] == 0
    assert second["consumption"]["resources"] == 0
  end

  test "idempotency conflicts and fixed cache capacity fail closed while hits remain available" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability, runner: {RestartCaptureImmediateRunner, self()}}
      )

    first = invoke!(request("conflict-first", "healthy", 3_000, "conflict"), host)
    assert first["status"] == "ok"
    assert_receive {:immediate_capture_run, "conflict"}, 5000

    conflict = invoke!(request("conflict-second", "faulty", 3_000, "conflict"), host)
    assert conflict["error"]["code"] == "invalid_request"
    refute_received {:immediate_capture_run, "conflict"}

    for index <- 1..31 do
      key = "cache-#{index}"
      assert invoke!(request("fill-#{index}", "healthy", 3_000, key), host)["status"] == "ok"
      assert_receive {:immediate_capture_run, ^key}, 5000
    end

    full = invoke!(request("cache-full", "healthy", 3_000, "cache-32"), host)
    assert full["status"] == "error"
    assert full["error"]["details"] == %{"reason" => "overloaded"}
    assert full["error"]["retryable"] == true
    refute_received {:immediate_capture_run, "cache-32"}

    hit = invoke!(request("cache-hit", "healthy", 3_000, "cache-1"), host)
    assert hit["status"] == "ok"
    assert hit["value"]["deduplicated_retry"] == true
    refute_received {:immediate_capture_run, "cache-1"}
  end

  test "a crashed host lease returns typed uncertainty and releases admission" do
    stop_supervised!(RestartCaptureHost)

    host =
      start_supervised!(
        {RestartCaptureHost,
         capability_reference: @capability,
         runner: {RestartCaptureImmediateRunner, {self(), :crash}}}
      )

    first = invoke!(request("lease-crash-1", "healthy"), host)
    assert_receive {:immediate_capture_crash, "lease-crash-1"}, 5000
    assert first["status"] == "error"
    assert first["error"]["code"] == "operation_failed"
    assert first["cleanup"] == %{"status" => "uncertain"}

    second = invoke!(request("lease-crash-2", "healthy"), host)
    assert_receive {:immediate_capture_crash, "lease-crash-2"}, 5000
    assert second["status"] == "error"
  end

  @tag capture_log: true
  test "the real seam types pre-start lifecycle limits and an assembly rejection" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "seam-errors")

    assert {:timeout, %{cleanup: %{status: :not_required}}} =
             RestartCapture.capture(
               events,
               Keyword.put(options, :deadline_monotonic_ms, System.monotonic_time(:millisecond))
             )

    assert {:cancelled, %{cleanup: %{status: :not_required}}} =
             RestartCapture.capture(events, Keyword.put(options, :cancelled, true))

    assert {:error, %Error{code: :operation_failed, details: %{reason: "event_budget"}},
            %{cleanup: %{status: :not_required}}} =
             RestartCapture.capture(events, Keyword.put(options, :max_events, 2))

    export_policy = Keyword.fetch!(options, :export_policy)

    {:ok, rejecting_export_policy} =
      ExportPolicy.new(
        export_policy.redaction_policy,
        [
          finding: :secret,
          snapshot: :internal,
          event: :internal,
          provenance: :internal,
          authority: :internal,
          artifacts: :internal
        ],
        max_duration_ms: export_policy.max_duration_ms
      )

    assert {:error, %Error{code: :invalid_capsule}, %{cleanup: %{status: :complete}}} =
             RestartCapture.capture(
               events,
               Keyword.put(options, :export_policy, rejecting_export_policy)
             )

    assert {:error, %Error{details: %{reason: "capsule_bytes"}}, %{cleanup: %{status: :complete}}} =
             RestartCapture.capture(events, Keyword.put(options, :max_bytes, 7_000))

    assert {:error, %Error{details: %{reason: "capture_worker_failed"}}, overloaded_accounting} =
             RestartCapture.capture(events, Keyword.put(options, :max_bytes, 1))

    assert overloaded_accounting.cleanup == %{status: :complete}
    assert overloaded_accounting.truncation == %{dropped_events: 1, status: :observed}
    assert overloaded_accounting.loss.counters.oversized == 1
    assert overloaded_accounting.consumption.resources == 3

    assert {:ok, [], quiet_sync_accounting} = RestartCapture.capture([], options)
    assert quiet_sync_accounting.cleanup == %{status: :complete}
    assert quiet_sync_accounting.consumption.resources == 3
    assert quiet_sync_accounting.consumption.events == 0

    async_started = System.monotonic_time(:microsecond)

    assert {:error, %Error{details: %{reason: "invalid_capture_input"}}, invalid_accounting} =
             RestartCapture.start_async(:not_a_list, options, async_started)

    assert invalid_accounting.consumption.resources == 0

    assert {:cancelled, %{cleanup: %{status: :not_required}}} =
             RestartCapture.start_async(
               events,
               Keyword.put(options, :cancelled, true),
               async_started
             )

    assert {:timeout, %{cleanup: %{status: :not_required}}} =
             RestartCapture.start_async(events, expired_options(options), async_started)

    assert {:error, %Error{details: %{reason: "event_budget"}}, async_limited_accounting} =
             RestartCapture.start_async(
               events,
               Keyword.put(options, :max_events, 2),
               async_started
             )

    assert async_limited_accounting.cleanup == %{status: :not_required}
    assert async_limited_accounting.consumption.resources == 0

    assert {:error, %Error{details: %{reason: "invalid_normalized_observation"}},
            async_improper_accounting} =
             RestartCapture.start_async([hd(events) | :improper], options, async_started)

    assert async_improper_accounting.consumption.resources == 0

    assert {:error, %Error{details: %{reason: "invalid_capture_input"}},
            invalid_options_accounting} =
             RestartCapture.start_async([], :not_options, async_started)

    assert invalid_options_accounting.observer_effect == "unavailable"
    assert invalid_options_accounting.consumption.resources == 0

    {:ok, cancelled_owner, cancelled_reference} =
      RestartCapture.start_async([], options, async_started)

    cancelled_owner_monitor = Process.monitor(cancelled_owner)
    cancelled_recorder = admit_capture_owner(cancelled_owner, cancelled_reference)

    cancelled_recorder_monitor = Process.monitor(cancelled_recorder)
    Owner.cancel(cancelled_owner, cancelled_reference)
    assert_owner_exited(cancelled_owner, cancelled_owner_monitor, deadline)

    assert_received {:capture_result, ^cancelled_reference,
                     {:cancelled, %{cleanup: %{status: :complete}} = cancelled_accounting}}

    assert cancelled_accounting.consumption.resources == 2

    assert_receive {:DOWN, ^cancelled_recorder_monitor, :process, ^cancelled_recorder, :normal},
                   5000

    {:ok, quiet_owner, quiet_reference} =
      RestartCapture.start_async([], options, async_started)

    quiet_owner_monitor = Process.monitor(quiet_owner)
    quiet_recorder = admit_capture_owner(quiet_owner, quiet_reference)
    quiet_recorder_monitor = Process.monitor(quiet_recorder)
    Owner.begin(quiet_owner, quiet_reference)
    assert %{phase: :worker_published} = :sys.get_state(quiet_owner)
    assert_received {:capture_resource, ^quiet_reference, quiet_worker, :worker}
    quiet_worker_monitor = Process.monitor(quiet_worker)
    Owner.execute(quiet_owner, quiet_reference)
    assert_owner_exited(quiet_owner, quiet_owner_monitor, deadline)

    assert_received {:capture_result, ^quiet_reference,
                     {:ok, [], %{cleanup: %{status: :complete}} = quiet_accounting}}

    assert quiet_accounting.consumption.resources == 3
    assert_receive {:DOWN, ^quiet_worker_monitor, :process, ^quiet_worker, _reason}, 5000
    assert_receive {:DOWN, ^quiet_recorder_monitor, :process, ^quiet_recorder, :normal}, 5000
  end

  @tag capture_log: true
  test "observation admission is bounded and the lifecycle owner contains resource failures" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "crash")
    repeated = List.duplicate(hd(events), 17)

    execute_started = System.monotonic_time(:microsecond)

    {:ok, execute_owner, execute_reference} =
      Owner.start(
        events,
        options,
        owner_accounting(options, execute_started),
        execute_started
      )

    execute_recorder = admit_capture_owner(execute_owner, execute_reference)

    execute_state = :sys.get_state(execute_owner)

    assert {:timeout, execute_accounting} =
             RestartCapture.execute(
               execute_state.handle,
               execute_state.clock,
               events,
               expired_options(options),
               owner_accounting(options, execute_started),
               execute_started
             )

    assert execute_accounting.cleanup == %{status: :not_required}
    assert execute_accounting.consumption.recorder_status.retained_count == 0
    execute_owner_monitor = Process.monitor(execute_owner)
    execute_recorder_monitor = Process.monitor(execute_recorder)
    Owner.cancel(execute_owner, execute_reference)
    assert_owner_exited(execute_owner, execute_owner_monitor, deadline)

    assert_received {:capture_result, ^execute_reference,
                     {:cancelled, %{cleanup: %{status: :complete}}}}

    assert_receive {:DOWN, ^execute_recorder_monitor, :process, ^execute_recorder, :normal}, 5000

    assert {:error, %Error{details: %{reason: "event_budget"}}, _accounting} =
             RestartCapture.capture(repeated, options)

    expired = Keyword.put(options, :deadline_monotonic_ms, System.monotonic_time(:millisecond))

    assert {:timeout, %{cleanup: %{status: :not_required}}} =
             RestartCapture.capture(repeated, expired)

    improper = [hd(events) | :improper]

    assert {:error, %Error{details: %{reason: "invalid_normalized_observation"}}, _accounting} =
             RestartCapture.capture(improper, options)

    [{first_event, first_time}, {second_event, _second_time} | _rest] = events

    assert {:error, %Error{details: %{reason: "receipt_time_regressed"}}, _accounting} =
             RestartCapture.capture(
               [{first_event, first_time}, {second_event, first_time - 1}],
               options
             )

    assert {:error, %Error{details: %{reason: "invalid_normalized_observation"}}, _accounting} =
             RestartCapture.capture([{Map.put(first_event, :id, nil), first_time}], options)

    assert {:error, %Error{details: %{reason: "invalid_capture_input"}}, _accounting} =
             RestartCapture.capture(:not_a_list, options)

    improper_after_limit = Enum.reduce(1..16, self(), fn _, tail -> [hd(events) | tail] end)

    assert {:error, %Error{details: %{reason: "event_budget"}}, _accounting} =
             RestartCapture.capture(improper_after_limit, options)

    started_at = System.monotonic_time(:microsecond)

    {:ok, capture_owner, reference} =
      Owner.start(events, options, owner_accounting(options, started_at), started_at)

    recorder = admit_capture_owner(capture_owner, reference)
    assert recorder in elem(Process.info(capture_owner, :links), 1)
    recorder_monitor = Process.monitor(recorder)
    owner_monitor = Process.monitor(capture_owner)
    Process.exit(recorder, :kill)
    assert_owner_exited(capture_owner, owner_monitor, deadline)
    assert_receive {:DOWN, ^recorder_monitor, :process, ^recorder, :killed}, 5000

    assert_received {:capture_result, ^reference,
                     {:error, %Error{code: :operation_failed}, accounting}}

    assert accounting.cleanup == %{status: :complete}
    assert accounting.loss.gaps == [:recorder_unavailable]
    assert accounting.consumption.resources == 2

    short_deadline = System.monotonic_time(:millisecond) + 20
    deadline_options = Keyword.put(options, :deadline_monotonic_ms, short_deadline)
    deadline_started = System.monotonic_time(:microsecond)

    {:ok, deadline_owner, deadline_reference} =
      Owner.start(
        events,
        deadline_options,
        owner_accounting(deadline_options, deadline_started),
        deadline_started
      )

    deadline_owner_monitor = Process.monitor(deadline_owner)
    deadline_recorder = admit_recorder(deadline_owner, deadline_reference)
    deadline_recorder_monitor = Process.monitor(deadline_recorder)
    # No barrier after this acknowledgement: the deadline may stop a ready owner.
    Owner.acknowledge(deadline_owner, deadline_reference, :recorder, deadline_recorder)
    assert_owner_exited(deadline_owner, deadline_owner_monitor, short_deadline)
    assert_received {:capture_owner_ready, ^deadline_reference, ^deadline_owner}
    assert_received {:capture_result, ^deadline_reference, {:timeout, deadline_accounting}}
    assert deadline_accounting.cleanup == %{status: :complete}
    assert deadline_accounting.consumption.resources == 2

    assert_receive {:DOWN, ^deadline_recorder_monitor, :process, ^deadline_recorder, :normal},
                   5000

    crash_started = System.monotonic_time(:microsecond)

    {:ok, worker_crash_owner, worker_crash_reference} =
      Owner.start(
        [hd(events) | :hostile_tail],
        options,
        owner_accounting(options, crash_started),
        crash_started
      )

    worker_crash_recorder = admit_capture_owner(worker_crash_owner, worker_crash_reference)

    worker_crash_recorder_monitor = Process.monitor(worker_crash_recorder)
    worker_crash_owner_monitor = Process.monitor(worker_crash_owner)
    Owner.begin(worker_crash_owner, worker_crash_reference)
    assert %{phase: :worker_published} = :sys.get_state(worker_crash_owner)
    assert_received {:capture_resource, ^worker_crash_reference, crash_worker, :worker}
    crash_worker_monitor = Process.monitor(crash_worker)
    Owner.execute(worker_crash_owner, worker_crash_reference)
    assert_owner_exited(worker_crash_owner, worker_crash_owner_monitor, deadline)

    assert_received {:capture_result, ^worker_crash_reference,
                     {:error, %Error{code: :operation_failed}, worker_crash_accounting}}

    assert worker_crash_accounting.cleanup == %{status: :complete}
    assert worker_crash_accounting.consumption.events == 1
    assert worker_crash_accounting.consumption.resources == 3

    assert_receive {:DOWN, ^worker_crash_recorder_monitor, :process, ^worker_crash_recorder,
                    :normal},
                   5000

    assert_receive {:DOWN, ^crash_worker_monitor, :process, ^crash_worker, _reason}, 5000

    parent = self()

    caller =
      spawn(fn ->
        caller_started = System.monotonic_time(:microsecond)

        {:ok, owner, caller_reference} =
          Owner.start(events, options, owner_accounting(options, caller_started), caller_started)

        receive do
          {:capture_owner_started, ^caller_reference, ^owner} ->
            Owner.admit(owner, caller_reference)

            receive do
              {:capture_resource_reserved, ^caller_reference, :recorder} -> :ok
            end

            receive do
              {:capture_resource, ^caller_reference, recorder, :recorder} ->
                Owner.acknowledge(owner, caller_reference, :recorder, recorder)
            end

            receive do
              {:capture_owner_ready, ^caller_reference, ^owner} -> :ok
            end

            send(parent, {:caller_owned_capture, self(), owner, caller_reference})

            receive do
              :hold -> :ok
            end
        end
      end)

    assert_receive {:caller_owned_capture, ^caller, caller_owner, _caller_reference},
                   owner_report_ms(deadline) + @scheduler_slack_ms

    %{inventory: %{recorder: %{pid: caller_recorder}}} = :sys.get_state(caller_owner)
    caller_monitor = Process.monitor(caller)
    caller_owner_monitor = Process.monitor(caller_owner)
    caller_recorder_monitor = Process.monitor(caller_recorder)
    Process.exit(caller, :kill)
    assert_owner_exited(caller_owner, caller_owner_monitor, deadline)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 5000
    assert_receive {:DOWN, ^caller_recorder_monitor, :process, ^caller_recorder, :normal}, 5000
  end

  @tag capture_log: true
  test "an abandoned capture drains its correlated result and owner DOWN" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + @capture_setup_deadline_ms
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "abandon")
    parent = self()

    caller =
      spawn(fn ->
        receive do
          :run ->
            started_at = System.monotonic_time(:microsecond)

            result =
              Owner.capture(events, options, owner_accounting(options, started_at), started_at)

            send(parent, {:abandoned_capture, result, Process.info(self(), :messages)})
        end
      end)

    :erlang.trace(caller, true, [:receive])
    send(caller, :run)

    assert_receive {:trace, ^caller, :receive, {:capture_owner_started, reference, owner}},
                   1_000

    assert is_reference(reference)

    assert_receive {:trace, ^caller, :receive, {:capture_owner_ready, ^reference, ^owner}},
                   1_000

    assert_receive {:trace, ^caller, :receive, {:capture_resource, ^reference, _worker, :worker}},
                   1_000

    assert :erlang.suspend_process(owner)

    client_wait =
      max(0, deadline - System.monotonic_time(:millisecond)) + @owner_cleanup_timeout_ms +
        @scheduler_slack_ms

    accounting =
      receive do
        {:abandoned_capture, {:timeout, accounting}, {:messages, []}} -> accounting
      after
        client_wait -> flunk("abandoned capture did not finish within its cleanup contract")
      end

    assert accounting.cleanup == %{status: :uncertain}
    assert accounting.consumption.resources == 3
    assert accounting.consumption.duration_us > 0
    refute Process.alive?(owner)
  end

  @tag capture_log: true
  test "a deadline before owner readiness returns its timeout and drains terminal messages" do
    observation = Fixtures.run!(:restart_storm, :healthy)
    events = RestartCaptureFixtureRunner.project(observation)
    parent = self()

    caller =
      spawn(fn ->
        deadline = System.monotonic_time(:millisecond)
        options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "pre-ready")
        started_at = System.monotonic_time(:microsecond)
        accounting = owner_accounting(options, started_at)
        result = Owner.capture(events, options, accounting, started_at)
        send(parent, {:pre_ready_deadline, result, Process.info(self(), :messages)})
      end)

    monitor = Process.monitor(caller)

    assert_receive {:pre_ready_deadline, {:timeout, accounting}, {:messages, []}}, 2_000
    assert accounting.cleanup == %{status: :complete}
    assert accounting.consumption.duration_us > 0
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5000
  end

  @tag capture_log: true
  test "the capture owner types recorder admission failure without starting work" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "bad-recorder")
    started_at = System.monotonic_time(:microsecond)
    accounting = owner_accounting(options, started_at)

    assert {:ok, owner, reference} =
             Owner.start(events, Keyword.put(options, :max_events, 0), accounting, started_at)

    owner_monitor = Process.monitor(owner)
    assert_receive {:capture_owner_started, ^reference, ^owner}, 5000
    Owner.admit(owner, reference)
    assert_owner_exited(owner, owner_monitor, deadline)
    assert_received {:capture_resource_reserved, ^reference, :recorder}

    assert_received {:capture_result, ^reference,
                     {:error,
                      %Error{code: :operation_failed, details: %{reason: "recorder_failed"}},
                      failed_accounting}}

    assert failed_accounting.cleanup == %{status: :complete}
    assert failed_accounting.consumption.resources == 2
    assert failed_accounting.consumption.resource_pids == 1
    assert failed_accounting.consumption.unmaterialized_resource_slots == 1
    assert failed_accounting.consumption.duration_us > 0
  end

  @tag capture_log: true
  test "duplicate correct admission publishes and cleans exactly one recorder" do
    observation = Fixtures.run!(:restart_storm, :healthy)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000

    options =
      RestartCaptureFixtureRunner.capture_options(observation, deadline, "duplicate-admit")

    started_at = System.monotonic_time(:microsecond)

    {:ok, owner, reference} =
      Owner.start(events, options, owner_accounting(options, started_at), started_at)

    owner_monitor = Process.monitor(owner)
    assert_receive {:capture_owner_started, ^reference, ^owner}, 5000
    Owner.admit(owner, reference)
    Owner.admit(owner, reference)
    assert %{phase: :recorder_published, inventory: inventory} = :sys.get_state(owner)
    assert_received {:capture_resource_reserved, ^reference, :recorder}
    assert_received {:capture_resource, ^reference, recorder, :recorder}
    recorder_monitor = Process.monitor(recorder)
    assert %{owner: %{pid: ^owner}, recorder: %{pid: ^recorder}} = inventory
    assert map_size(inventory) == 2
    refute_received {:capture_resource_reserved, ^reference, :recorder}
    refute_received {:capture_resource, ^reference, _other_recorder, :recorder}

    Owner.acknowledge(owner, reference, :recorder, recorder)
    assert %{phase: :ready} = :sys.get_state(owner)
    assert_received {:capture_owner_ready, ^reference, ^owner}
    Owner.cancel(owner, reference)
    assert_owner_exited(owner, owner_monitor, deadline)

    assert_received {:capture_result, ^reference, {:cancelled, accounting}}
    assert accounting.cleanup == %{status: :complete}
    assert accounting.consumption.resource_pids == 2
    assert accounting.consumption.resources == 2
    assert accounting.consumption.unmaterialized_resource_slots == 0
    assert_receive {:DOWN, ^recorder_monitor, :process, ^recorder, :normal}, 5000
  end

  @tag capture_log: true
  test "a capture owner death tears down its admitted recorder and gated worker" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "owner-death")
    started_at = System.monotonic_time(:microsecond)

    {:ok, owner, reference} =
      Owner.start(events, options, owner_accounting(options, started_at), started_at)

    recorder = admit_recorder(owner, reference)
    Owner.acknowledge(owner, make_ref(), :recorder, recorder)
    Owner.acknowledge(owner, reference, :recorder, self())
    assert %{phase: :recorder_published, handle: nil} = :sys.get_state(owner)
    refute_received {:capture_owner_ready, ^reference, ^owner}
    Owner.acknowledge(owner, reference, :recorder, recorder)
    assert %{phase: :ready} = :sys.get_state(owner)
    assert_received {:capture_owner_ready, ^reference, ^owner}
    Owner.begin(owner, make_ref())
    Owner.execute(owner, make_ref())
    Owner.cancel(owner, make_ref())
    send(owner, :arbitrary)
    assert %{phase: :ready, inventory: inventory} = :sys.get_state(owner)
    refute Map.has_key?(inventory, :worker)
    Owner.begin(owner, reference)
    assert %{phase: :worker_published} = :sys.get_state(owner)
    assert_received {:capture_resource, ^reference, worker, :worker}
    recorder_monitor = Process.monitor(recorder)
    worker_monitor = Process.monitor(worker)
    owner_monitor = Process.monitor(owner)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^recorder_monitor, :process, ^recorder, _reason}, 5000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 5000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5000
    refute_received {:capture_result, ^reference, _result}
  end

  @tag capture_log: true
  test "direct cancellation after execute cleans all admitted capture resources" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "execute-cancel")
    started_at = System.monotonic_time(:microsecond)

    {:ok, owner, reference} =
      Owner.start(events, options, owner_accounting(options, started_at), started_at)

    recorder = admit_capture_owner(owner, reference)
    Owner.begin(owner, reference)
    assert %{phase: :worker_published} = :sys.get_state(owner)
    assert_received {:capture_resource_reserved, ^reference, :worker}
    assert_received {:capture_resource, ^reference, worker, :worker}
    assert :erlang.suspend_process(worker)
    Owner.execute(owner, reference)
    :sys.get_state(owner)
    assert Process.info(worker, :messages) == {:messages, [{:capture_execute, reference}]}

    resources = [owner, recorder, worker]
    monitors = monitor_resources(resources)
    Owner.cancel(owner, reference)
    assert_resources_down(monitors)

    assert_received {:capture_result, ^reference, {:cancelled, accounting}}
    assert accounting.cleanup == %{status: :complete}
    assert accounting.consumption.resource_pids == 3
    assert accounting.consumption.resources == 3
    assert accounting.consumption.unmaterialized_resource_slots == 0
  end

  @tag capture_log: true
  test "the synchronous facade types owner death and accounts every resource it observed" do
    observation = Fixtures.run!(:restart_storm, :faulty)
    events = RestartCaptureFixtureRunner.project(observation)
    deadline = System.monotonic_time(:millisecond) + 3_000
    options = RestartCaptureFixtureRunner.capture_options(observation, deadline, "facade-death")
    parent = self()

    caller =
      spawn(fn ->
        receive do
          :capture ->
            started_at = System.monotonic_time(:microsecond)

            send(
              parent,
              {:facade_result,
               Owner.capture(
                 events,
                 options,
                 owner_accounting(options, started_at),
                 started_at
               )}
            )
        end
      end)

    :erlang.trace(caller, true, [:receive])
    send(caller, :capture)

    assert_receive {:trace, ^caller, :receive, {:capture_owner_started, reference, owner}},
                   1_000

    assert_receive {:trace, ^caller, :receive,
                    {:capture_resource, ^reference, recorder, :recorder}},
                   1_000

    assert_receive {:trace, ^caller, :receive, {:capture_owner_ready, ^reference, ^owner}},
                   1_000

    assert :erlang.suspend_process(caller)
    owner_state = :sys.get_state(owner)
    resources = [owner, recorder, owner_state.inventory.worker.pid]
    monitors = monitor_resources(resources)
    Process.exit(owner, :kill)
    assert_resources_down(monitors)
    assert :erlang.resume_process(caller)

    assert_receive {:facade_result,
                    {:error, %Error{details: %{reason: "owner_failed"}}, accounting}},
                   1_000

    assert accounting.cleanup == %{status: :uncertain}
    assert accounting.consumption.resources == length(resources)
    assert accounting.consumption.duration_us > 0
  end

  defp admit_faulty_capture(host, request_id) do
    task = Task.async(fn -> invoke!(request(request_id, "faulty"), host) end)

    {lease, resources, capture_owner} = observe_faulty_capture(host, request_id)

    {task, lease, resources, capture_owner}
  end

  defp observe_faulty_capture(host, request_id) do
    {lease, admitted, capture_owner} = observe_recorder_admission(host, request_id)
    send(host, {:continue_capture, lease})
    assert_receive {:capture_resource_reserved, ^lease, {:capture, :worker}}, 1_000
    assert_receive {:capture_resource, ^lease, capture_worker, {:capture, :worker}}, 1_000
    {lease, admitted ++ [capture_worker], capture_owner}
  end

  defp observe_recorder_admission(host, request_id) do
    assert_receive {:capture_work_started, ^request_id, lease, fixture_owner,
                    [supervisor, counter]},
                   1_000

    assert_receive {:capture_resource, ^lease, worker_1, :worker}, 1_000
    send(host, {:continue_capture, lease})
    assert_receive {:capture_resource, ^lease, worker_2, :worker}, 1_000
    assert_receive {:capture_resource, ^lease, worker_3, :worker}, 1_000
    assert_receive {:capture_resource, ^lease, worker_4, :worker}, 1_000
    assert_receive {:capture_resource, ^lease, capture_owner, {:capture, :owner}}, 1_000
    assert_receive {:capture_resource_reserved, ^lease, {:capture, :recorder}}, 1_000
    assert_receive {:capture_resource, ^lease, recorder, {:capture, :recorder}}, 1_000

    resources = [
      fixture_owner,
      supervisor,
      counter,
      worker_1,
      worker_2,
      worker_3,
      worker_4,
      capture_owner,
      recorder
    ]

    {lease, resources, capture_owner}
  end

  defp invoke!(payload, host) do
    {json, _status} = CLI.invoke_json(Jason.encode!(payload), RestartCaptureHost.dispatcher(host))
    Jason.decode!(json)
  end

  defp request(id, variant, duration \\ 3_000, idempotency_key \\ nil) do
    %{
      "schema" => "insider.request/v1",
      "protocol" => "insider.protocol/v1",
      "operation" => "incident.capture",
      "request_id" => id,
      "environment" => "test",
      "capability" => @capability,
      "idempotency_key" => idempotency_key || id,
      "params" => %{"fixture" => "restart_storm", "variant" => variant},
      "budget" => %{
        "max_bytes" => 262_144,
        "max_duration_ms" => duration,
        "max_events" => 16,
        "max_targets" => 1
      }
    }
  end

  defp request_term(id, variant, duration \\ 3_000) do
    {:ok, request} = request(id, variant, duration) |> Insider.Protocol.decode_request()
    request
  end

  defp expired_options(options),
    do: Keyword.put(options, :deadline_monotonic_ms, System.monotonic_time(:millisecond))

  defp admit_capture_owner(owner, reference) do
    recorder = admit_recorder(owner, reference)
    Owner.acknowledge(owner, reference, :recorder, recorder)
    assert %{phase: :ready} = :sys.get_state(owner)
    assert_received {:capture_owner_ready, ^reference, ^owner}
    recorder
  end

  defp admit_recorder(owner, reference) do
    assert_receive {:capture_owner_started, ^reference, ^owner}, 5000
    Owner.admit(owner, reference)
    assert %{phase: :recorder_published} = :sys.get_state(owner)
    assert_received {:capture_resource_reserved, ^reference, :recorder}
    assert_received {:capture_resource, ^reference, recorder, :recorder}
    recorder
  end

  # The DOWN is the synchronisation point. The bound is the one Owner.capture/4
  # gives an owner before abandoning it: until it reports, then one cleanup
  # window more for it to exit.
  defp assert_owner_exited(owner, monitor, deadline) do
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal},
                   owner_report_ms(deadline) + @owner_cleanup_timeout_ms + @scheduler_slack_ms
  end

  # Owner.capture/4 waits this long for each owner report: until the capture
  # deadline plus one cleanup window, and never less than one window.
  defp owner_report_ms(deadline) do
    max(
      @owner_cleanup_timeout_ms,
      deadline - System.monotonic_time(:millisecond) + @owner_cleanup_timeout_ms
    )
  end

  defp fixed_budgets do
    %{
      "max_bytes" => 262_144,
      "max_duration_ms" => 3_000,
      "max_events" => 16,
      "max_resources" => 10,
      "max_idempotency_entries" => 32
    }
  end

  defp owner_accounting(options, started_at) do
    %{
      cleanup: %{status: :not_required},
      consumption: %{capsule_bytes: 0, duration_us: 0, events: 0, resources: 0},
      loss: %{counters: %{}, gaps: []},
      observer_effect: Keyword.fetch!(options, :observer_effect),
      truncation: %{dropped_events: 0, status: :none},
      started_at_us: started_at
    }
  end

  defp monitor_resources(resources), do: Enum.map(resources, &{&1, Process.monitor(&1)})

  defp assert_resources_down(monitors) do
    Enum.each(monitors, fn {resource, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^resource, _reason}, 1_000
    end)
  end
end
