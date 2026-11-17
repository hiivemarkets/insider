defmodule Insider.Sentinel.ExternalProcessGroupIntegrationTest do
  use ExUnit.Case, async: false

  @work_timeout_ms 5_000
  @stop_grace_ms 1_000
  @handoff_stop_grace_ms 6_000
  @client_slack_ms 250
  @exit_status_event [
    :insider,
    :sentinel,
    :external_process,
    :exit_status_observed
  ]

  alias Insider.Sentinel.ExternalProcess
  alias Insider.TestSupport.ExternalConfirmationBody
  alias Insider.TestSupport.ExternalLeaseRegistry
  alias Insider.TestSupport.ExternalProcessProfile
  alias Insider.TestSupport.ExternalProcessProfileBlocking
  alias Insider.TestSupport.ExternalProcessProfileLingeringGroup

  test "forced cleanup emits the exit-status observation exactly once" do
    {owner, binding, lease} = armed_lease("2")
    cancellation_reference = make_ref()
    handler_id = {__MODULE__, :forced_exit_status, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @exit_status_event,
        &__MODULE__.forward_exit_status_observation/4,
        %{test_pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {work_deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileBlocking,
          binding,
          lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    cleanup_guard = :atomics.new(1, signed: false)
    :ok = :atomics.put(cleanup_guard, 1, 1)

    on_exit(fn ->
      cleanup_armed_process_group(cleanup_guard, lease.directory, stop_deadline)
    end)

    assert assert_pid_marker(lease.directory, work_deadline) > 0
    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    result = Task.await(task, @stop_grace_ms + @client_slack_ms)
    assert {:error, %Insider.Protocol.Error{details: %{reason: :cancelled}}} = result
    :ok = :atomics.put(cleanup_guard, 1, 0)

    assert_receive {:exit_status_observed, measurements, metadata}, 1_000
    assert measurements == %{count: 1}
    assert metadata == %{owner_fingerprint: binding["owner_fingerprint"]}
    refute_receive {:exit_status_observed, _measurements, _metadata}, 0
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "forced cleanup preserves exit observation across the TERM to KILL handoff" do
    {owner, binding, lease} = armed_lease("3")
    cancellation_reference = make_ref()
    handler_reference = make_ref()
    handler_id = {__MODULE__, :handoff_exit_status, handler_reference}

    :ok =
      :telemetry.attach(
        handler_id,
        @exit_status_event,
        &__MODULE__.block_exit_status_observation/4,
        %{handler_reference: handler_reference, test_pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {work_deadline, stop_deadline} = deadlines(@handoff_stop_grace_ms)

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileBlocking,
          binding,
          lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    cleanup_guard = :atomics.new(1, signed: false)
    :ok = :atomics.put(cleanup_guard, 1, 1)

    on_exit(fn ->
      cleanup_armed_process_group(cleanup_guard, lease.directory, stop_deadline)
    end)

    assert assert_pid_marker(lease.directory, work_deadline) > 0
    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    assert_receive {:exit_status_handler_blocked, ^handler_reference, handler_pid, measurements,
                    metadata},
                   2_000

    assert measurements == %{count: 1}
    assert metadata == %{owner_fingerprint: binding["owner_fingerprint"]}

    # The first forced-cleanup phase owns half the stop grace. Releasing after
    # that boundary makes the second phase depend on the observation retained
    # by the first; the Port emits no second exit-status message.
    Process.send_after(
      handler_pid,
      {:release_exit_status_handler, handler_reference},
      3_100
    )

    assert_receive {:exit_status_handler_released, ^handler_reference}, 3_500

    result = Task.await(task, @handoff_stop_grace_ms + @client_slack_ms)
    assert {:error, %Insider.Protocol.Error{details: %{reason: :cancelled}}} = result
    :ok = :atomics.put(cleanup_guard, 1, 0)

    refute_receive {:exit_status_handler_blocked, ^handler_reference, _handler_pid, _measurements,
                    _metadata},
                   0

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "normal exit emits the exact run-correlated exit-status observation" do
    {owner, binding, lease} = armed_lease("1")
    handler_id = {__MODULE__, :absent_live_group, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @exit_status_event,
        &__MODULE__.forward_exit_status_observation/4,
        %{test_pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {work_deadline, stop_deadline} = deadlines()

    assert {:ok, draft} =
             ExternalProcess.run(
               ExternalProcessProfile,
               binding,
               lease,
               work_deadline,
               stop_deadline,
               make_ref()
             )

    assert {:ok, protocol} =
             ExternalLeaseRegistry.finalize(owner, ExternalConfirmationBody, draft)

    assert {:ok, receipt} = ExternalProcess.finalize(draft, protocol)
    assert receipt["cleanup"] == %{"process" => "down"}

    assert_receive {:exit_status_observed, measurements, metadata}, 1_000
    assert measurements == %{count: 1}
    assert metadata == %{owner_fingerprint: binding["owner_fingerprint"]}
    refute_receive {:exit_status_observed, _measurements, _metadata}, 0
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "normal exit waits for all descendants in the process group" do
    {owner, binding, lease} = armed_lease("0")
    on_exit(fn -> cleanup_fixture_process_group(lease.directory) end)
    handler_id = {__MODULE__, :live_group_exit, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @exit_status_event,
        &__MODULE__.release_lingering_process_group/4,
        %{
          directory: lease.directory,
          owner_fingerprint: binding["owner_fingerprint"],
          test_pid: self()
        }
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.execute(@exit_status_event, %{count: 1}, %{
      owner_fingerprint: "sha256:" <> String.duplicate("f", 64)
    })

    refute_receive {:exit_status_with_live_group_observed, _observation}, 0

    task =
      Task.async(fn ->
        {work_deadline, stop_deadline} = deadlines()

        with {:ok, draft} <-
               ExternalProcess.run(
                 ExternalProcessProfileLingeringGroup,
                 binding,
                 lease,
                 work_deadline,
                 stop_deadline,
                 make_ref()
               ),
             {:ok, protocol} <-
               ExternalLeaseRegistry.finalize(owner, ExternalConfirmationBody, draft) do
          ExternalProcess.finalize(draft, protocol)
        end
      end)

    assert_receive {:exit_status_with_live_group_observed, observation}, 5_250

    assert observation.group_alive_before_release
    assert observation.direct_state in [:zombie, :reaped]
    assert observation.lingering_live_before_release
    assert observation.measurements == %{count: 1}
    assert observation.metadata == %{owner_fingerprint: binding["owner_fingerprint"]}

    assert_linux_process_group_result(
      observation.group_before_release,
      observation.lingering_pid,
      observation.direct_pid
    )

    assert {:ok, receipt} = Task.await(task, @stop_grace_ms + @client_slack_ms)
    assert receipt["cleanup"] == %{"process" => "down"}
    refute_receive {:exit_status_with_live_group_observed, _observation}, 0
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  @doc false
  def release_lingering_process_group(
        @exit_status_event,
        measurements,
        %{owner_fingerprint: owner_fingerprint} = metadata,
        %{
          directory: directory,
          owner_fingerprint: owner_fingerprint,
          test_pid: test_pid
        }
      ) do
    direct_pid = read_pid(directory, ".insider-direct-pid")
    lingering_pid = read_pid(directory, ".insider-lingering-pid")
    lingering_state = fixture_process_state(lingering_pid)

    observation = %{
      direct_pid: direct_pid,
      direct_state: fixture_process_state(direct_pid),
      group_alive_before_release: process_group_alive?(direct_pid),
      group_before_release: linux_process_group(lingering_pid),
      lingering_live_before_release: lingering_state == :live,
      lingering_pid: lingering_pid,
      measurements: measurements,
      metadata: metadata
    }

    signal_process(lingering_pid, "TERM")
    send(test_pid, {:exit_status_with_live_group_observed, observation})
  end

  def release_lingering_process_group(@exit_status_event, _measurements, _metadata, _config),
    do: :ok

  @doc false
  def forward_exit_status_observation(
        @exit_status_event,
        measurements,
        metadata,
        %{test_pid: test_pid}
      ),
      do: send(test_pid, {:exit_status_observed, measurements, metadata})

  @doc false
  def block_exit_status_observation(
        @exit_status_event,
        measurements,
        metadata,
        %{handler_reference: handler_reference, test_pid: test_pid}
      ) do
    send(
      test_pid,
      {:exit_status_handler_blocked, handler_reference, self(), measurements, metadata}
    )

    receive do
      {:release_exit_status_handler, ^handler_reference} ->
        send(test_pid, {:exit_status_handler_released, handler_reference})
    end
  end

  defp armed_lease(character) do
    owner = "external-owner-group-#{character}-#{System.unique_integer([:positive])}"
    target = String.duplicate(character, 64)

    :ok =
      ExternalLeaseRegistry.reserve(owner, %{"fingerprint" => target, "retain_audit" => true})

    state = :persistent_term.get({ExternalLeaseRegistry, :owner, owner})
    on_exit(fn -> ExternalLeaseRegistry.force_purge(state.owner_fingerprint) end)

    binding = %{
      "expected_fingerprint" => target,
      "lease_fingerprint" => state.lease_fingerprint,
      "observer" => %{"id" => "test.external-observer", "version" => 1},
      "owner_fingerprint" => state.owner_fingerprint,
      "scenario_id" => "sha256:" <> target,
      "target_fingerprint" => target
    }

    {:ok, lease} = ExternalLeaseRegistry.arm(owner, ExternalConfirmationBody, binding)
    {owner, binding, lease}
  end

  defp cleanup_and_assert_down(owner, owner_fingerprint) do
    assert :ok = ExternalLeaseRegistry.cleanup(owner, false)
    audit = ExternalLeaseRegistry.audit(owner_fingerprint)
    assert audit["process_down_before_provider_cleanup"]
    assert audit["process_down_after_provider_cleanup"]
    assert audit["root_removed"]
    ExternalLeaseRegistry.purge_audit(owner_fingerprint)
  end

  defp read_pid(directory, marker) do
    directory
    |> Path.join(marker)
    |> File.read!()
    |> String.to_integer()
  end

  defp assert_pid_marker(directory, deadline) do
    marker = Path.join(directory, ".insider-pid")

    case File.read(marker) do
      {:ok, bytes} ->
        case Integer.parse(bytes) do
          {os_pid, "\n"} when os_pid > 0 -> os_pid
          _other -> await_pid_marker(directory, deadline)
        end

      _other ->
        await_pid_marker(directory, deadline)
    end
  end

  defp await_pid_marker(directory, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("child pid marker was not completely written")
    else
      receive do
      after
        5 -> assert_pid_marker(directory, deadline)
      end
    end
  end

  defp cleanup_armed_process_group(cleanup_guard, directory, deadline) do
    if :atomics.get(cleanup_guard, 1) == 1 do
      case complete_pid_marker(directory) do
        {:ok, os_pid} ->
          :ok = :atomics.put(cleanup_guard, 1, 0)
          signal_process_group(os_pid, "KILL")

        :pending ->
          if System.monotonic_time(:millisecond) < deadline do
            receive do
            after
              5 -> cleanup_armed_process_group(cleanup_guard, directory, deadline)
            end
          else
            :ok
          end
      end
    end
  end

  defp complete_pid_marker(directory) do
    case File.read(Path.join(directory, ".insider-pid")) do
      {:ok, bytes} ->
        case Integer.parse(bytes) do
          {os_pid, "\n"} when os_pid > 0 -> {:ok, os_pid}
          _other -> :pending
        end

      _other ->
        :pending
    end
  end

  defp fixture_process_state(os_pid) do
    case linux_process_state(os_pid) do
      :unsupported -> unix_process_state(os_pid)
      state -> state
    end
  end

  defp linux_process_state(os_pid) do
    if File.regular?("/proc/self/stat") do
      case File.read("/proc/#{os_pid}/stat") do
        {:ok, stat} -> parse_linux_process_state(stat)
        {:error, :enoent} -> :reaped
        _other -> :unknown
      end
    else
      :unsupported
    end
  end

  defp unix_process_state(os_pid) do
    case System.cmd(ps_executable(), ["-o", "state=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if output |> String.trim() |> String.starts_with?("Z"), do: :zombie, else: :live

      {_output, _status} ->
        :reaped
    end
  rescue
    _error -> :unknown
  end

  defp parse_linux_process_state(stat) do
    case :binary.matches(stat, ") ") do
      [] ->
        :unknown

      matches ->
        {separator, 2} = List.last(matches)

        case binary_part(stat, separator + 2, 1) do
          "Z" -> :zombie
          <<state>> when state in ?A..?Z -> :live
          _other -> :unknown
        end
    end
  rescue
    ArgumentError -> :unknown
  end

  defp assert_linux_process_group_result({:ok, expected_group}, _os_pid, expected_group), do: :ok
  defp assert_linux_process_group_result(:unsupported, _os_pid, _expected_group), do: :ok

  defp assert_linux_process_group_result(result, os_pid, expected_group) do
    flunk(
      "lingering fixture #{os_pid} did not join owned process group #{expected_group}: " <>
        inspect(result)
    )
  end

  defp linux_process_group(os_pid) do
    if File.regular?("/proc/self/stat") do
      case File.read("/proc/#{os_pid}/stat") do
        {:ok, stat} -> parse_linux_process_group(stat)
        {:error, :enoent} -> :reaped
        _other -> :unknown
      end
    else
      :unsupported
    end
  end

  defp parse_linux_process_group(stat) do
    with matches when matches != [] <- :binary.matches(stat, ") "),
         {separator, 2} <- List.last(matches),
         remainder <- binary_part(stat, separator + 2, byte_size(stat) - separator - 2),
         [_state, _parent, process_group | _rest] <- String.split(remainder),
         {process_group, ""} <- Integer.parse(process_group) do
      {:ok, process_group}
    else
      _other -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp process_group_alive?(os_pid) do
    case System.cmd(kill_executable(), ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp cleanup_fixture_process_group(directory) do
    with {:ok, bytes} <- File.read(Path.join(directory, ".insider-direct-pid")),
         {os_pid, ""} when os_pid > 0 <- Integer.parse(bytes) do
      signal_process_group(os_pid, "KILL")
    else
      _other -> :ok
    end
  end

  defp signal_process_group(os_pid, signal) do
    System.cmd(kill_executable(), ["-#{signal}", "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp signal_process(os_pid, signal) do
    System.cmd(kill_executable(), ["-#{signal}", "--", Integer.to_string(os_pid)],
      stderr_to_stdout: true
    )

    :ok
  end

  defp kill_executable do
    Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) || raise "kill unavailable"
  end

  defp ps_executable do
    Enum.find(["/bin/ps", "/usr/bin/ps"], &File.regular?/1) || raise "ps unavailable"
  end

  defp deadlines(stop_grace_ms \\ @stop_grace_ms) do
    work_deadline = System.monotonic_time(:millisecond) + @work_timeout_ms
    {work_deadline, work_deadline + stop_grace_ms}
  end
end
