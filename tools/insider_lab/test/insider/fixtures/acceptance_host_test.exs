defmodule Insider.Fixtures.AcceptanceHostTest do
  use ExUnit.Case, async: true

  alias Insider.Adapter.CLI
  alias Insider.Adapter.CLI.Wire
  alias Insider.Fixtures.Observation
  alias Insider.Protocol
  alias Insider.Protocol.Result
  alias Insider.TestSupport.AcceptanceHost
  alias Insider.TestSupport.AcceptanceTimeoutRunner

  @capability "phase-a-fixture-observation"
  @base_request %{
    "schema" => "insider.request/v1",
    "protocol" => "insider.protocol/v1",
    "environment" => "test",
    "target" => %{"node" => Atom.to_string(node())},
    "budget" => %{
      "max_duration_ms" => 5_000,
      "max_events" => 1,
      "max_bytes" => 16_384,
      "max_targets" => 1
    }
  }

  defmodule ControlledRunner do
    @behaviour Insider.TestSupport.AcceptanceRunner

    @impl true
    def minimum_duration_ms({_owner, _outcome}), do: 1
    def minimum_duration_ms(:invalid), do: 0
    def minimum_duration_ms(:raise), do: raise("invalid runner configuration")
    def minimum_duration_ms(:throw), do: throw(:invalid_runner_configuration)

    @impl true
    def run(variant, _deadline, _dispatcher, {owner, outcome}) do
      case outcome do
        :invalid -> :invalid_runner_result
        :raise -> raise "runner failed"
        :throw -> throw(:runner_failed)
        :incomplete -> observation(variant, cleanup: %{status: :partial})
        :too_many_events -> observation(variant, events: [event(1), event(2)])
        :live_resource -> live_resource_observation(owner, variant)
      end
    end

    defp live_resource_observation(owner, variant) do
      resource = spawn(fn -> receive do: (:stop -> :ok) end)
      send(owner, {:controlled_resource, resource})
      observation(variant, resources: [resource])
    end

    defp observation(variant, overrides) do
      defaults = [
        run_id: System.unique_integer([:positive]),
        scenario: :leaked_task,
        variant: variant,
        events: [event(1)],
        samples: %{"live_tasks" => 0},
        settled: %{"live_tasks" => 0},
        resources: [],
        cleanup: %{status: :complete}
      ]

      struct!(Observation, Keyword.merge(defaults, overrides))
      |> then(&{:ok, &1})
    end

    defp event(sequence) do
      %{
        sequence: sequence,
        kind: :scenario_completed,
        monotonic_time: sequence,
        metadata: %{"live_tasks" => 0}
      }
    end
  end

  setup do
    host = start_host(capability_reference: @capability)
    %{dispatch: AcceptanceHost.dispatcher(host), host: host}
  end

  test "a client discovers and observes the real faulty fixture", %{dispatch: dispatch} do
    capabilities = invoke!(request("runtime.capabilities", "discover"), dispatch)

    assert capabilities["schema"] == "insider.capabilities/v1"

    assert %{
             "operation" => "scenario.run",
             "runtime_available" => true,
             "runtime_provider" => "insider.test_support.acceptance_host",
             "runtime_isolation" => "session_local",
             "policy_disposition" => "grant_required"
           } = operation!(capabilities, "scenario.run")

    assert capabilities["fixture_observation"] == %{
             "operation" => "scenario.run",
             "params" => %{
               "fixture" => ["leaked_task"],
               "variant" => ["faulty", "healthy"]
             },
             "requires_capability" => true
           }

    result =
      "scenario.run"
      |> request("observe-faulty", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> invoke_result!(dispatch)

    assert result["status"] == "ok"
    assert result["schema"] == "insider.result/v1"
    assert result["operation"] == "scenario.run"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["effective_limits"]["max_events"] == 1
    assert result["effective_limits"]["max_bytes"] == 16_384
    assert result["consumption"]["events"] == 1
    assert result["consumption"]["targets"] == 1
    assert result["consumption"]["evidence_bytes"] <= 16_384

    assert %{
             "kind" => "fixture_observation",
             "fixture" => "leaked_task",
             "variant" => "faulty",
             "samples" => %{"live_tasks" => 1},
             "settled" => %{"live_tasks" => 0},
             "resources" => %{"observed" => 1, "alive_after_cleanup" => 0},
             "events" => [
               %{
                 "kind" => "scenario_completed",
                 "metadata" => %{"live_tasks" => 1},
                 "monotonic_time" => monotonic_time,
                 "sequence" => 1
               }
             ]
           } = result["value"]

    assert is_integer(monotonic_time)
    assert is_integer(result["value"]["run_id"])
    refute inspect(result) =~ "#PID<"

    direct_request =
      "scenario.run"
      |> request("observe-faulty-term", fixture_params("faulty"))
      |> Map.put("capability", @capability)

    assert {:ok, decoded_request} = Protocol.decode_request(direct_request)
    assert %Result{} = direct_result = CLI.invoke(decoded_request, dispatch)
    assert Result.valid?(direct_result, decoded_request)
    assert {:ok, encoded_result} = Wire.encode_result(direct_result)
    assert byte_size(encoded_result) <= direct_result.effective_limits.max_bytes
  end

  test "the nearby healthy control stays distinct and cleans up", %{dispatch: dispatch} do
    result =
      "scenario.run"
      |> request("observe-healthy", fixture_params("healthy"))
      |> Map.put("capability", @capability)
      |> invoke_result!(dispatch)

    assert result["status"] == "ok"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["value"]["variant"] == "healthy"
    assert result["value"]["samples"] == %{"live_tasks" => 0}
    assert result["value"]["settled"] == %{"live_tasks" => 0}

    assert result["value"]["resources"] == %{
             "observed" => 1,
             "alive_after_cleanup" => 0
           }

    assert get_in(result, ["value", "events", Access.at(0), "metadata", "live_tasks"]) == 0
  end

  test "trusted policy denies missing authority before fixture execution", %{dispatch: dispatch} do
    result =
      "scenario.run"
      |> request("denied", fixture_params("faulty"))
      |> invoke_result!(dispatch)

    assert result["status"] == "error"
    assert result["error"]["code"] == "policy_denied"
    assert result["error"]["details"]["reason"] == "grant_required"
    assert result["cleanup"] == %{"status" => "not_required"}
    assert result["value"] == nil
    assert result["consumption"] == %{}

    mismatched =
      "scenario.run"
      |> request("wrong-environment", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> Map.put("environment", "development")
      |> invoke_result!(dispatch)

    assert mismatched["status"] == "error"
    assert mismatched["error"]["details"]["reason"] == "environment_mismatch"
    assert mismatched["cleanup"] == %{"status" => "not_required"}
  end

  test "a short deadline times out before starting the fixture", %{dispatch: dispatch} do
    request =
      "scenario.run"
      |> request("short-deadline", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> put_in(["budget", "max_duration_ms"], 100)
      |> Map.put("timeout_ms", 100)

    result = invoke_result!(request, dispatch)

    assert result["status"] == "timeout"
    assert result["error"]["code"] == "deadline_exceeded"
    assert result["cleanup"] == %{"status" => "not_required"}
    assert result["effects"] == []
    assert result["consumption"] == %{}

    assert result["uncertainty"] == [
             "fixture was not started because its cleanup budget did not fit"
           ]
  end

  test "started work outlives a killed dispatcher and cleans up by its deadline" do
    host =
      start_host(
        capability_reference: @capability,
        runner: {AcceptanceTimeoutRunner, self()}
      )

    dispatch = AcceptanceHost.dispatcher(host)

    request =
      "scenario.run"
      |> request("started-timeout", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> put_in(["budget", "max_duration_ms"], 100)
      |> Map.put("timeout_ms", 100)

    invocation = Task.async(fn -> CLI.invoke_json(Jason.encode!(request), dispatch) end)

    assert_receive {:acceptance_work_started, ^host, dispatcher_worker, resource}, 1_000
    dispatcher_monitor = Process.monitor(dispatcher_worker)
    resource_monitor = Process.monitor(resource)

    assert {output, 124} = Task.await(invocation, 1_000)
    timed_out = Jason.decode!(output)
    assert timed_out["status"] == "timeout"
    assert timed_out["cleanup"] == %{"status" => "uncertain"}

    assert timed_out["uncertainty"] == [
             "dispatcher worker stopped; escaped runtime effects are unknown"
           ]

    assert_receive {:DOWN, ^dispatcher_monitor, :process, ^dispatcher_worker, :killed}, 1_000
    assert_receive {:acceptance_work_cleaned, ^host, ^resource, :complete}, 1_000
    assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :killed}, 1_000
    refute Process.alive?(resource)
    assert Process.alive?(host)

    capabilities = invoke!(request("runtime.capabilities", "after-timeout"), dispatch)
    assert operation!(capabilities, "scenario.run")["runtime_available"]
  end

  test "an in-flight resource self-terminates if its supervised host dies" do
    host =
      start_host(
        capability_reference: @capability,
        runner: {AcceptanceTimeoutRunner, self()}
      )

    dispatch = AcceptanceHost.dispatcher(host)

    request =
      "scenario.run"
      |> request("host-shutdown", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> put_in(["budget", "max_duration_ms"], 1_000)
      |> Map.put("timeout_ms", 1_000)

    invocation = Task.async(fn -> CLI.invoke_json(Jason.encode!(request), dispatch) end)

    assert_receive {:acceptance_work_started, ^host, _dispatcher_worker, resource}, 1_000
    resource_monitor = Process.monitor(resource)
    host_monitor = Process.monitor(host)
    Process.exit(host, :kill)

    assert_receive {:DOWN, ^host_monitor, :process, ^host, :killed}, 1_000
    assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :normal}, 1_000
    refute Process.alive?(resource)

    assert {output, 1} = Task.await(invocation, 1_000)
    result = Jason.decode!(output)
    assert result["status"] == "error"
    assert result["cleanup"] == %{"status" => "uncertain"}
  end

  test "the host rejects undeclared fixture input as a bounded typed result", %{
    dispatch: dispatch
  } do
    result =
      "scenario.run"
      |> request("invalid-fixture", %{"fixture" => "restart_storm", "variant" => "faulty"})
      |> Map.put("capability", @capability)
      |> invoke_result!(dispatch)

    assert result["status"] == "error"
    assert result["error"]["code"] == "invalid_request"
    assert result["cleanup"] == %{"status" => "not_required"}
    assert result["value"] == nil
  end

  test "invalid host and runner configurations fail closed" do
    assert {:error, :invalid_acceptance_host} = isolated_start_result([])

    assert {:error, :invalid_acceptance_host} =
             isolated_start_result(capability_reference: @capability, extra: true)

    for runner <- [
          :not_a_runner,
          {NotLoaded, nil},
          {ControlledRunner, :invalid},
          {ControlledRunner, :raise},
          {ControlledRunner, :throw}
        ] do
      assert {:error, :invalid_acceptance_host} =
               isolated_start_result(
                 capability_reference: @capability,
                 runner: runner
               )
    end
  end

  test "the supervised host rejects malformed calls and absorbs stale runner deadlines", %{
    host: host
  } do
    assert GenServer.call(host, :not_a_protocol_request) == :invalid_request
    send(host, {:acceptance_runner_deadline, make_ref()})
    assert GenServer.call(host, :not_a_protocol_request) == :invalid_request
    assert Process.alive?(host)
  end

  test "invalid, raised, and thrown runner failures become uncertain typed results" do
    for outcome <- [:invalid, :raise, :throw] do
      result = invoke_controlled(outcome, "runner-#{outcome}")

      assert result["status"] == "error"
      assert result["error"]["code"] == "operation_failed"
      assert result["cleanup"] == %{"status" => "uncertain"}

      assert result["uncertainty"] == [
               "fixture cleanup could not be independently confirmed"
             ]
    end
  end

  test "incomplete cleanup and live resources fail closed with measured consumption" do
    incomplete = invoke_controlled(:incomplete, "incomplete-cleanup")
    assert incomplete["status"] == "error"
    assert incomplete["cleanup"] == %{"status" => "partial"}
    assert incomplete["consumption"]["events"] == 1

    live = invoke_controlled(:live_resource, "live-resource")
    assert_receive {:controlled_resource, resource}
    assert live["status"] == "error"
    assert live["cleanup"] == %{"status" => "partial"}
    assert live["value"] == nil
    assert live["uncertainty"] == ["one or more fixture resources may remain alive"]

    monitor = Process.monitor(resource)
    send(resource, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^resource, :normal}
  end

  test "fixture evidence that exceeds the authorized event bound fails closed" do
    result = invoke_controlled(:too_many_events, "too-many-events")

    assert result["status"] == "error"
    assert result["error"]["code"] == "operation_failed"
    assert result["error"]["message"] == "fixture evidence exceeded limits"
    assert result["cleanup"] == %{"status" => "complete"}
    assert result["consumption"]["events"] == 2
  end

  test "the lifecycle runner cleans up at its own deadline while its caller remains alive" do
    host =
      start_host(
        capability_reference: @capability,
        runner: {AcceptanceTimeoutRunner, self()}
      )

    payload =
      "scenario.run"
      |> request("runner-deadline", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> put_in(["budget", "max_duration_ms"], 100)
      |> Map.put("timeout_ms", 100)

    assert {:ok, decoded} = Protocol.decode_request(payload)
    result = AcceptanceHost.dispatcher(host).(decoded)

    assert_receive {:acceptance_work_started, ^host, dispatcher, resource}
    assert dispatcher == self()
    assert_receive {:acceptance_work_cleaned, ^host, ^resource, :complete}
    assert result.status == :timeout
    assert result.cleanup == %{status: :complete}
    assert Process.alive?(host)
  end

  test "the lifecycle runner accepts cooperative resource shutdown before timeout" do
    host =
      start_host(
        capability_reference: @capability,
        runner: {AcceptanceTimeoutRunner, self()}
      )

    request =
      "scenario.run"
      |> request("cooperative-shutdown", fixture_params("faulty"))
      |> Map.put("capability", @capability)
      |> put_in(["budget", "max_duration_ms"], 100)
      |> Map.put("timeout_ms", 100)

    invocation =
      Task.async(fn ->
        CLI.invoke_json(Jason.encode!(request), AcceptanceHost.dispatcher(host))
      end)

    assert_receive {:acceptance_work_started, ^host, _dispatcher, resource}
    monitor = Process.monitor(resource)
    send(resource, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^resource, :normal}

    assert {_output, 124} = Task.await(invocation)
    assert_receive {:acceptance_work_cleaned, ^host, ^resource, :complete}
    assert Process.alive?(host)
  end

  defp request(operation, request_id, params \\ %{}) do
    Map.merge(@base_request, %{
      "operation" => operation,
      "params" => params,
      "request_id" => request_id
    })
  end

  defp fixture_params(variant),
    do: %{"fixture" => "leaked_task", "variant" => variant}

  defp invoke!(payload, dispatch), do: invoke_result!(payload, dispatch)["value"]

  defp invoke_result!(payload, dispatch) do
    {output, status} = CLI.invoke_json(Jason.encode!(payload), dispatch)
    result = Jason.decode!(output)
    assert status == expected_exit(result["status"])
    result
  end

  defp expected_exit("ok"), do: 0
  defp expected_exit("error"), do: 1
  defp expected_exit("timeout"), do: 124

  defp operation!(capabilities, name),
    do: Enum.find(capabilities["operations"], &(&1["operation"] == name))

  defp invoke_controlled(outcome, request_id) do
    host =
      start_host(
        capability_reference: @capability,
        runner: {ControlledRunner, {self(), outcome}}
      )

    "scenario.run"
    |> request(request_id, fixture_params("faulty"))
    |> Map.put("capability", @capability)
    |> invoke_result!(AcceptanceHost.dispatcher(host))
  end

  defp isolated_start_result(options) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)
      AcceptanceHost.start_link(options)
    end)
    |> Task.await()
  end

  defp start_host(options) do
    start_supervised!(%{
      id: {AcceptanceHost, make_ref()},
      restart: :temporary,
      start: {AcceptanceHost, :start_link, [options]}
    })
  end
end
