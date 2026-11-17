defmodule Insider.Sentinel.ExternalProcessTest do
  use ExUnit.Case, async: true

  @work_timeout_ms 5_000
  @stop_grace_ms 1_000
  @client_slack_ms 250

  alias Insider.Protocol.Error
  alias Insider.Sentinel.ExternalProcess
  alias Insider.Sentinel.ExternalProcess.Receipt
  alias Insider.TestSupport.ExternalConfirmationBody
  alias Insider.TestSupport.ExternalLeaseRegistry
  alias Insider.TestSupport.ExternalProcessProfile
  alias Insider.TestSupport.ExternalProcessProfileBlocking
  alias Insider.TestSupport.ExternalProcessProfileControlledDeadlineExit
  alias Insider.TestSupport.ExternalProcessProfileEchoOnly
  alias Insider.TestSupport.ExternalProcessProfileFlood
  alias Insider.TestSupport.ExternalProcessProfileIgnoreTerm
  alias Insider.TestSupport.ExternalProcessProfileLingeringGroup
  alias Insider.TestSupport.ExternalProcessProfileMismatchedLease
  alias Insider.TestSupport.ExternalProcessProfileMismatchedOwner
  alias Insider.TestSupport.ExternalProcessProfileMismatchedTarget
  alias Insider.TestSupport.ExternalProcessProfileSecret

  defmodule InvalidCommandProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.invalid", "version" => 1}

    @impl true
    def command(_binding, _lease),
      do:
        {:ok,
         %{
           executable: "relative-executable",
           arguments: [],
           fingerprint_arguments: [],
           cd: "relative-cwd",
           env: [{"DUPLICATE", "first"}, {"DUPLICATE", "second"}],
           argument_policy: "public-exact/v1"
         }}
  end

  defmodule SecretArgumentProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.secret-argument", "version" => 1}

    @impl true
    def command(binding, lease) do
      {:ok, command} = Insider.TestSupport.ExternalProcessProfile.command(binding, lease)

      {:ok,
       %{
         command
         | arguments: command.arguments ++ ["TOP_SECRET_ARGUMENT"],
           fingerprint_arguments: command.fingerprint_arguments
       }}
    end
  end

  defmodule AlternateSecretProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.secret", "version" => 1}

    @impl true
    def command(binding, lease) do
      {:ok, command} =
        Insider.TestSupport.ExternalProcessProfile.command(binding, lease, "secret")

      env =
        Enum.map(command.env, fn
          {"INSIDER_SECRET_CANARY", _value} -> {"INSIDER_SECRET_CANARY", "A_DIFFERENT_SECRET"}
          pair -> pair
        end)

      {:ok, %{command | env: env}}
    end
  end

  defmodule AlternateSchedulerBoundsProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: Insider.TestSupport.ExternalProcessProfile.identity()

    @impl true
    def command(binding, lease) do
      {:ok, command} = Insider.TestSupport.ExternalProcessProfile.command(binding, lease)
      arguments = List.replace_at(command.arguments, 1, "+S 2:2 +SDcpu 1:1 +SDio 1 +A 1")
      {:ok, %{command | arguments: arguments, fingerprint_arguments: arguments}}
    end
  end

  defmodule AtomErrorProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.atom-error", "version" => 1}

    @impl true
    def command(_binding, _lease), do: {:error, :profile_rejected}
  end

  defmodule TypedErrorProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.typed-error", "version" => 1}

    @impl true
    def command(_binding, _lease),
      do: {:error, Insider.Protocol.Error.new(:operation_failed, "profile rejected command")}
  end

  defmodule LongLingeringProcessGroupProfile do
    @behaviour Insider.Sentinel.ExternalProcess

    @impl true
    def identity, do: %{"id" => "test.external-process.long-lingering-group", "version" => 1}

    @impl true
    def command(binding, lease),
      do: ExternalProcessProfileLingeringGroup.command(binding, lease)
  end

  # A port's os_pid is gone once its program has exited. A program that
  # exited before its runner read the os_pid could not be confirmed down
  # (cleanup_uncertain), and its process group could not be reached: CI
  # "normal exit waits for all descendants in the process group", 1 of 60
  # Lab 1.17 runs. The command now starts held, and runs only after the
  # os_pid is read.
  test "a command that exits at once is held until its os_pid is read" do
    command = %{
      executable: System.find_executable("sh"),
      arguments: ["-c", "exit 7"],
      cd: System.tmp_dir!(),
      env: [{"PATH", System.fetch_env!("PATH")}]
    }

    # Without the hold, the program is gone before the os_pid is read.
    unheld =
      Port.open({:spawn_executable, command.executable}, [
        :binary,
        :exit_status,
        args: command.arguments
      ])

    monitor = :erlang.monitor(:port, unheld)
    assert_receive {^unheld, {:exit_status, 7}}, 5_000
    assert_receive {:DOWN, ^monitor, :port, ^unheld, _reason}, 5_000
    assert Port.info(unheld, :os_pid) == nil

    held = ExternalProcess.open_held(command)
    refute_receive {^held, {:exit_status, _status}}, 300
    assert {:os_pid, os_pid} = Port.info(held, :os_pid)
    assert is_integer(os_pid) and os_pid > 0

    :ok = ExternalProcess.release_held(held)
    assert_receive {^held, {:exit_status, 7}}, 5_000
  end

  test "canonical receipt fixture rejects malformed, unknown, noncanonical, and oversized ingress" do
    bytes =
      File.read!("test/fixtures/external_process_receipt_v1.json")
      |> String.trim_trailing("\n")

    assert {:ok, receipt} = Receipt.decode(bytes)
    assert {:ok, ^bytes} = Receipt.canonical_binary(receipt)

    assert {:error, %Error{code: :invalid_external_process_receipt}} =
             Receipt.decode(bytes <> " ")

    assert {:error, %Error{code: :invalid_external_process_receipt}} =
             receipt |> Map.delete("lease_fingerprint") |> Receipt.decode_map()

    assert {:error, %Error{code: :unsupported_external_process_receipt_schema}} =
             receipt
             |> Map.put("schema", "insider.external-process-receipt/v999")
             |> Receipt.decode_map()

    assert {:error, %Error{code: :external_process_receipt_limit_exceeded}} =
             Receipt.decode(String.duplicate("x", 16_385))

    for index <- 1..100 do
      hostile_key = "hostile-external-key-#{index}-#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(hostile_key) end

      assert {:error, %Error{code: :invalid_external_process_receipt}} =
               receipt
               |> Map.put(hostile_key, true)
               |> Receipt.decode_map()

      assert_raise ArgumentError, fn -> String.to_existing_atom(hostile_key) end
    end

    assert {:error, %Error{code: :invalid_external_process_receipt}} = Receipt.new(:invalid)
    assert {:error, %Error{code: :invalid_external_process_receipt}} = Receipt.validate(:invalid)

    assert {:error, %Error{code: :unsupported_external_process_receipt_schema}} =
             Receipt.decode_map(Map.delete(receipt, "schema"))

    assert {:error, %Error{code: :invalid_external_process_receipt}} = Receipt.decode_map(42)

    for forged <- [
          Map.put(receipt, "lease_protocol", %{}),
          Map.put(receipt, "report", nil),
          put_in(receipt, ["report", "owner_fingerprint"], "sha256:" <> String.duplicate("f", 64))
        ] do
      assert {:error, %Error{code: :invalid_external_process_receipt}} =
               forged |> readdress() |> Receipt.validate()
    end
  end

  test "run and finalize reject malformed authority and preserve typed profile errors" do
    {owner, binding, lease} = armed_lease("7")
    {deadline, stop_deadline} = deadlines()
    reference = make_ref()

    assert {:error, %Error{details: %{reason: :invalid_configuration}}} =
             ExternalProcess.run(
               ExternalProcessProfile,
               %{},
               lease,
               deadline,
               stop_deadline,
               reference
             )

    assert {:error, %Error{details: %{reason: :invalid_configuration}}} =
             ExternalProcess.run(
               ExternalProcessProfile,
               binding,
               %{lease | fingerprint: String.duplicate("f", 64)},
               deadline,
               stop_deadline,
               reference
             )

    assert {:error, %Error{details: %{reason: :invalid_configuration}}} =
             ExternalProcess.run(
               "invalid",
               binding,
               lease,
               deadline,
               stop_deadline,
               :not_a_reference
             )

    assert {:error, %Error{details: %{reason: :invalid_configuration}}} =
             ExternalProcess.run(
               AtomErrorProfile,
               binding,
               lease,
               deadline,
               stop_deadline,
               reference
             )

    assert {:error, %Error{code: :operation_failed}} =
             ExternalProcess.run(
               TypedErrorProfile,
               binding,
               lease,
               deadline,
               stop_deadline,
               reference
             )

    assert {:error, %Error{details: %{reason: :finalization_failed}}} =
             ExternalProcess.finalize(%{}, %{})

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "an exact cancellation pending before finalization rejects the draft" do
    {owner, binding, lease} = armed_lease("8")
    assert {:ok, draft} = run_draft(ExternalProcessProfile, binding, lease)
    send(self(), {:cancel_sandbox_body, draft.cancellation_reference})

    assert {:error, %Error{details: %{reason: :cancelled}}} =
             ExternalProcess.finalize(draft, %{
               "armed" => 1,
               "scenario" => 2,
               "finalized" => 3
             })

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "child reads one owner lease and only sanitized canonical evidence is retained" do
    {owner, binding, lease} = armed_lease("a")

    assert {:ok, receipt} = run_completed(ExternalProcessProfileSecret, owner, binding, lease)
    assert {:ok, ^receipt} = Receipt.validate(receipt)
    refute inspect(receipt) =~ "TOP_SECRET_DO_NOT_RETAIN"
    assert receipt["owner_fingerprint"] == binding["owner_fingerprint"]
    assert receipt["lease_fingerprint"] == binding["lease_fingerprint"]
    assert receipt["target_fingerprint"] == binding["target_fingerprint"]
    assert receipt["lease_protocol"] == %{"armed" => 1, "scenario" => 2, "finalized" => 3}
    assert receipt["cleanup"] == %{"process" => "down"}
    cleanup_and_assert_down(owner, receipt["owner_fingerprint"])

    {other_owner, other_binding, other_lease} = armed_lease("a")

    assert {:ok, alternate} =
             run_completed(AlternateSecretProfile, other_owner, other_binding, other_lease)

    assert alternate["command_fingerprint"] == receipt["command_fingerprint"]
    refute inspect(alternate) =~ "A_DIFFERENT_SECRET"
    cleanup_and_assert_down(other_owner, alternate["owner_fingerprint"])
  end

  test "fixture child scheduler bounds are public, exact, and command-addressed" do
    {owner, binding, lease} = armed_lease("3")
    {:ok, command} = ExternalProcessProfile.command(binding, lease)

    assert ["--erl", "+S 1:1 +SDcpu 1:1 +SDio 1 +A 1", "-e" | _rest] = command.arguments
    assert command.fingerprint_arguments == command.arguments
    assert {:ok, receipt} = run_completed(ExternalProcessProfile, owner, binding, lease)
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])

    {alternate_owner, alternate_binding, alternate_lease} = armed_lease("3")

    assert {:ok, alternate} =
             run_completed(
               AlternateSchedulerBoundsProfile,
               alternate_owner,
               alternate_binding,
               alternate_lease
             )

    refute alternate["command_fingerprint"] == receipt["command_fingerprint"]
    cleanup_and_assert_down(alternate_owner, alternate_binding["owner_fingerprint"])
  end

  test "same-target lease cleanup does not erase another owner's child index" do
    {first_owner, first_binding, _first_lease} = armed_lease("4")
    {second_owner, second_binding, second_lease} = armed_lease("4")
    cancellation_reference = make_ref()
    {work_deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileBlocking,
          second_binding,
          second_lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    assert_pid_marker(second_lease.directory, work_deadline)
    assert ExternalLeaseRegistry.child_started_for_target?(second_binding["target_fingerprint"])

    cleanup_and_assert_down(first_owner, first_binding["owner_fingerprint"])
    assert ExternalLeaseRegistry.child_started_for_target?(second_binding["target_fingerprint"])

    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    assert {:error, %Error{details: %{reason: :cancelled}}} =
             Task.await(task, client_wait(stop_deadline))

    cleanup_and_assert_down(second_owner, second_binding["owner_fingerprint"])
  end

  test "echo-only, output floods, and forged owner or target reports fail closed" do
    for profile <- [
          ExternalProcessProfileEchoOnly,
          ExternalProcessProfileFlood,
          ExternalProcessProfileMismatchedLease,
          ExternalProcessProfileMismatchedOwner,
          ExternalProcessProfileMismatchedTarget
        ] do
      {owner, binding, lease} = armed_lease("b")

      assert {:error, %Error{code: :external_process_failed}} =
               run_draft(profile, binding, lease)

      cleanup_and_assert_down(owner, binding["owner_fingerprint"])
    end
  end

  test "portable authority fields and secret-derived argv cannot alter the fixed command" do
    {owner, binding, lease} = armed_lease("c")
    hostile = Map.merge(binding, %{"executable" => "/bin/rm", "argv" => ["-rf"], "env" => %{}})

    for {profile, input} <- [
          {ExternalProcessProfile, hostile},
          {InvalidCommandProfile, binding},
          {SecretArgumentProfile, binding}
        ] do
      assert {:error,
              %Error{code: :external_process_failed, details: %{reason: :invalid_configuration}}} =
               run_draft(profile, input, lease)
    end

    ExternalLeaseRegistry.cleanup(owner, false)
  end

  test "timeout and exact cancellation prove the direct OS child is down before return" do
    {timeout_owner, timeout_binding, timeout_lease} = armed_lease("d")

    # The stop grace is what the runner has to TERM, KILL, and confirm the
    # group down. 300 ms was too short once on a loaded runner, and the
    # honest result was cleanup_uncertain. The claim here is the timeout.
    assert {:error, %Error{code: :external_process_failed, details: %{reason: :timeout}}} =
             ExternalProcess.run(
               ExternalProcessProfileBlocking,
               timeout_binding,
               timeout_lease,
               System.monotonic_time(:millisecond) + 300,
               System.monotonic_time(:millisecond) + 5_300,
               make_ref()
             )

    cleanup_and_assert_down(timeout_owner, timeout_binding["owner_fingerprint"])

    {cancel_owner, cancel_binding, cancel_lease} = armed_lease("e")
    cancellation_reference = make_ref()
    {work_deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileBlocking,
          cancel_binding,
          cancel_lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    assert_pid_marker(cancel_lease.directory, work_deadline)
    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    assert {:error, %Error{code: :external_process_failed, details: %{reason: :cancelled}}} =
             Task.await(task, client_wait(stop_deadline))

    cleanup_and_assert_down(cancel_owner, cancel_binding["owner_fingerprint"])
  end

  test "caller death terminates and reaps its external process group" do
    {owner, binding, lease} = armed_lease("9")
    parent = self()
    {work_deadline, stop_deadline} = deadlines()

    runner =
      spawn(fn ->
        send(parent, {:external_runner_started, self()})

        ExternalProcess.run(
          ExternalProcessProfileBlocking,
          binding,
          lease,
          work_deadline,
          stop_deadline,
          make_ref()
        )
      end)

    assert_receive {:external_runner_started, ^runner}, 5000
    runner_monitor = Process.monitor(runner)
    os_pid = assert_pid_marker(lease.directory, work_deadline)
    assert process_group_alive?(os_pid)

    on_exit(fn -> signal_process_group(os_pid, "KILL") end)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :killed}, 5000
    assert_process_group_down(os_pid, stop_deadline)

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "cancellation interrupts post-exit process-group cleanup" do
    {owner, binding, lease} = armed_lease("c")
    cancellation_reference = make_ref()
    {work_deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          LongLingeringProcessGroupProfile,
          binding,
          lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    assert_file(Path.join(lease.directory, ".insider-lingering"), work_deadline)

    direct_pid = read_direct_pid(lease.directory)
    on_exit(fn -> signal_process_group(direct_pid, "KILL") end)
    assert_process_down(direct_pid, work_deadline)
    assert process_group_alive?(direct_pid)
    lingering_pid = read_lingering_pid(lease.directory)
    on_exit(fn -> signal_process(lingering_pid, "KILL") end)
    assert_linux_process_group(lingering_pid, direct_pid)
    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    result = Task.await(task, client_wait(stop_deadline))
    assert_post_exit_cancellation(result, lingering_pid)

    signal_process(lingering_pid, "KILL")

    assert_fixture_process_terminated(
      lingering_pid,
      System.monotonic_time(:millisecond) + @stop_grace_ms
    )

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "timeout and cancellation kill a direct child that ignores TERM" do
    {timeout_owner, timeout_binding, timeout_lease} = armed_lease("5")
    {timeout_deadline, timeout_stop_deadline} = deadlines()

    timeout_task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileIgnoreTerm,
          timeout_binding,
          timeout_lease,
          timeout_deadline,
          timeout_stop_deadline,
          make_ref()
        )
      end)

    assert_file(Path.join(timeout_lease.directory, ".insider-term-ignored"), timeout_deadline)

    assert {:error, %Error{details: %{reason: :timeout}}} =
             Task.await(timeout_task, client_wait(timeout_stop_deadline))

    cleanup_and_assert_down(timeout_owner, timeout_binding["owner_fingerprint"])

    {cancel_owner, cancel_binding, cancel_lease} = armed_lease("6")
    cancellation_reference = make_ref()
    {work_deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileIgnoreTerm,
          cancel_binding,
          cancel_lease,
          work_deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    assert_file(Path.join(cancel_lease.directory, ".insider-term-ignored"), work_deadline)
    cancelled_at = System.monotonic_time(:millisecond)
    send(task.pid, {:cancel_sandbox_body, cancellation_reference})

    assert {:error, %Error{details: %{reason: :cancelled}}} =
             Task.await(task, client_wait(stop_deadline))

    assert System.monotonic_time(:millisecond) - cancelled_at <=
             @stop_grace_ms + @client_slack_ms

    cleanup_and_assert_down(cancel_owner, cancel_binding["owner_fingerprint"])
  end

  test "normal output and exit at the work deadline cannot produce a draft" do
    {owner, binding, lease} = armed_lease("1")
    cancellation_reference = make_ref()
    {deadline, stop_deadline} = deadlines()

    task =
      Task.async(fn ->
        ExternalProcess.run(
          ExternalProcessProfileControlledDeadlineExit,
          binding,
          lease,
          deadline,
          stop_deadline,
          cancellation_reference
        )
      end)

    assert_file(Path.join(lease.directory, ".insider-output-ready"), deadline)
    await_deadline(deadline)
    File.write!(Path.join(lease.directory, ".insider-release"), "release", [:exclusive])

    assert {:error, %Error{code: :external_process_failed, details: %{reason: reason}}} =
             Task.await(task, client_wait(stop_deadline))

    assert reason in [:timeout, :cleanup_uncertain]
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "a draft cannot be finalized after its work deadline" do
    {owner, binding, lease} = armed_lease("2")
    {deadline, stop_deadline} = deadlines()

    assert {:ok, draft} =
             ExternalProcess.run(
               ExternalProcessProfile,
               binding,
               lease,
               deadline,
               stop_deadline,
               make_ref()
             )

    await_deadline(deadline)

    assert {:error, %Error{code: :external_process_failed, details: %{reason: :timeout}}} =
             ExternalProcess.finalize(draft, %{
               "armed" => 1,
               "scenario" => 2,
               "finalized" => 3
             })

    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  test "receipt rejects a semantic owner forgery even with recomputed identity" do
    {owner, binding, lease} = armed_lease("f")
    assert {:ok, receipt} = run_completed(ExternalProcessProfile, owner, binding, lease)
    forged_owner = "sha256:" <> String.duplicate("e", 64)
    forged = %{receipt | "owner_fingerprint" => forged_owner} |> readdress()

    assert {:error, %Error{code: :invalid_external_process_receipt}} = Receipt.validate(forged)
    cleanup_and_assert_down(owner, binding["owner_fingerprint"])
  end

  defp armed_lease(character) do
    owner = "external-owner-#{character}-#{System.unique_integer([:positive])}"
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

  defp run_completed(profile, owner, binding, lease) do
    with {:ok, draft} <- run_draft(profile, binding, lease),
         {:ok, protocol} <- ExternalLeaseRegistry.finalize(owner, ExternalConfirmationBody, draft) do
      ExternalProcess.finalize(draft, protocol)
    end
  end

  defp run_draft(profile, binding, lease),
    do: run_draft(profile, binding, lease, deadlines())

  defp run_draft(profile, binding, lease, {deadline, stop_deadline}),
    do:
      ExternalProcess.run(
        profile,
        binding,
        lease,
        deadline,
        stop_deadline,
        make_ref()
      )

  defp cleanup_and_assert_down(owner, owner_fingerprint) do
    assert :ok = ExternalLeaseRegistry.cleanup(owner, false)
    audit = ExternalLeaseRegistry.audit(owner_fingerprint)
    assert audit["process_down_before_provider_cleanup"]
    assert audit["process_down_after_provider_cleanup"]
    assert audit["root_removed"]
    ExternalLeaseRegistry.purge_audit(owner_fingerprint)
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

  defp assert_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected controlled child file #{Path.basename(path)}")

      true ->
        receive do
        after
          5 -> assert_file(path, deadline)
        end
    end
  end

  defp assert_process_group_down(os_pid, deadline) do
    cond do
      not process_group_alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("external process group #{os_pid} survived caller death")

      true ->
        receive do
        after
          5 -> assert_process_group_down(os_pid, deadline)
        end
    end
  end

  defp assert_process_down(os_pid, deadline) do
    cond do
      not process_alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("direct external process #{os_pid} did not exit")

      true ->
        receive do
        after
          5 -> assert_process_down(os_pid, deadline)
        end
    end
  end

  defp read_direct_pid(directory) do
    directory
    |> Path.join(".insider-direct-pid")
    |> File.read!()
    |> String.to_integer()
  end

  defp read_lingering_pid(directory) do
    directory
    |> Path.join(".insider-lingering-pid")
    |> File.read!()
    |> String.to_integer()
  end

  defp process_alive?(os_pid) do
    case System.cmd(kill_executable(), ["-0", "--", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp assert_post_exit_cancellation(
         {:error, %Error{code: :external_process_failed, details: %{reason: :cancelled}}},
         lingering_pid
       ) do
    assert_fixture_process_terminated(
      lingering_pid,
      System.monotonic_time(:millisecond) + @stop_grace_ms
    )
  end

  defp assert_post_exit_cancellation(
         {:error, %Error{code: :external_process_failed, details: %{reason: :cleanup_uncertain}}},
         _lingering_pid
       ),
       do: :ok

  defp assert_post_exit_cancellation(result, _lingering_pid),
    do: flunk("unexpected post-exit cancellation result: #{inspect(result)}")

  defp assert_fixture_process_terminated(os_pid, deadline) do
    case linux_process_state(os_pid) do
      state when state in [:zombie, :reaped] ->
        :ok

      :live ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> assert_fixture_process_terminated(os_pid, deadline)
          end
        else
          flunk("exact fixture descendant stayed live past its cleanup deadline")
        end

      :unsupported ->
        assert_process_down(os_pid, deadline)

      state ->
        flunk("fixture termination could not be verified on Linux: #{inspect(state)}")
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

  defp assert_linux_process_group(os_pid, expected_group) do
    case linux_process_group(os_pid) do
      {:ok, ^expected_group} ->
        :ok

      :unsupported ->
        :ok

      result ->
        flunk("lingering fixture did not join the owned process group: #{inspect(result)}")
    end
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

  defp process_group_alive?(os_pid) do
    case System.cmd(kill_executable(), ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
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

  defp await_deadline(deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
    after
      remaining -> :ok
    end
  end

  defp deadlines(work_timeout_ms \\ @work_timeout_ms) do
    work_deadline = System.monotonic_time(:millisecond) + work_timeout_ms
    {work_deadline, work_deadline + @stop_grace_ms}
  end

  defp client_wait(stop_deadline),
    do: max(0, stop_deadline - System.monotonic_time(:millisecond)) + @client_slack_ms

  defp readdress(wire) do
    content = Map.drop(wire, ["id", "integrity"])
    digest = sha256(Insider.Event.Canonical.encode(content))

    %{
      wire
      | "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
