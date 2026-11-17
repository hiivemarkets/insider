defmodule Insider.Sentinel.ExternalProcess do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.ExternalProcess.Predicate
  alias Insider.Sentinel.ExternalProcess.Receipt

  @output_limit 65_536
  @report_limit 12_288
  @prefix "INSIDER_REPORT "
  @terminal_file ".insider-terminal"
  @exit_status_event [
    :insider,
    :sentinel,
    :external_process,
    :exit_status_observed
  ]

  @callback identity() :: map()
  @callback command(map(), map()) ::
              {:ok,
               %{
                 executable: binary(),
                 arguments: [binary()],
                 fingerprint_arguments: [binary()],
                 cd: binary(),
                 env: list(),
                 argument_policy: binary()
               }}
              | {:error, atom()}

  @spec run(module(), map(), map(), integer(), integer(), reference()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(profile, binding, lease, deadline, stop_deadline, cancellation_reference)
      when is_atom(profile) and is_integer(deadline) and is_integer(stop_deadline) and
             is_reference(cancellation_reference) do
    caller = self()
    result_reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          run_owned(
            profile,
            binding,
            lease,
            deadline,
            stop_deadline,
            cancellation_reference,
            caller
          )

        send(caller, {result_reference, result})
      end)

    await_result(worker, monitor, result_reference, cancellation_reference)
  rescue
    _error -> invalid(:execution_failed)
  end

  def run(_profile, _binding, _lease, _deadline, _stop_deadline, _cancellation_reference),
    do: invalid(:invalid_configuration)

  defp run_owned(
         profile,
         binding,
         lease,
         deadline,
         stop_deadline,
         cancellation_reference,
         caller
       ) do
    owner_monitor = Process.monitor(caller)

    with true <- valid_binding?(binding),
         true <- valid_lease?(lease, binding),
         true <- Predicate.identity?(profile.identity()),
         {:ok, command} <- profile.command(binding, lease),
         true <- valid_command?(command, lease),
         true <- deadline > System.monotonic_time(:millisecond) and stop_deadline >= deadline,
         true <- Process.alive?(caller) do
      port = open_held(command)

      # The program runs only after its os_pid is read and its port is
      # monitored, so a program that exits at once cannot take its os_pid,
      # and with it its process group, out of reach.
      with {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 <- Port.info(port, :os_pid),
           monitor = :erlang.monitor(:port, port),
           :ok <- release_held(port) do
        collect(%{
          binding: binding,
          cancellation_reference: cancellation_reference,
          command_fingerprint: command_fingerprint(profile, command),
          deadline: deadline,
          lease: Map.drop(lease, [:token]),
          monitor: monitor,
          os_pid: os_pid,
          owner: caller,
          owner_monitor: owner_monitor,
          output: <<>>,
          output_bytes: 0,
          port: port,
          stop_deadline: stop_deadline
        })
      else
        _other ->
          close_without_claim(port)
          invalid(:cleanup_uncertain)
      end
    else
      false -> invalid(:invalid_configuration)
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> invalid(:invalid_configuration)
    end
  rescue
    _error -> invalid(:execution_failed)
  end

  defp await_result(worker, monitor, result_reference, cancellation_reference) do
    receive do
      {^result_reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:cancel_sandbox_body, ^cancellation_reference} = cancellation ->
        send(worker, cancellation)
        await_result(worker, monitor, result_reference, cancellation_reference)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        invalid(:execution_failed)
    end
  end

  @doc false
  @spec finalize(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def finalize(
        %{
          cancellation_reference: cancellation_reference,
          deadline: deadline,
          receipt_fields: fields
        },
        %{"armed" => 1, "finalized" => 3, "scenario" => 2} = protocol
      )
      when is_integer(deadline) and is_reference(cancellation_reference) and
             map_size(protocol) == 3 do
    with :active <- work_status(deadline, cancellation_reference),
         result <- fields |> Map.put("lease_protocol", protocol) |> Receipt.new(),
         :active <- work_status(deadline, cancellation_reference) do
      result
    else
      :timeout -> invalid(:timeout)
      :cancelled -> invalid(:cancelled)
    end
  rescue
    _error -> invalid(:finalization_failed)
  end

  def finalize(_draft, _protocol), do: invalid(:finalization_failed)

  defp collect(state) do
    if work_expired?(state) do
      stop_with(:timeout, state)
    else
      receive do
        {port, {:data, bytes}} when port == state.port and is_binary(bytes) ->
          if work_expired?(state) do
            stop_with(:timeout, state)
          else
            next_count = state.output_bytes + byte_size(bytes)

            if next_count <= @output_limit do
              collect(%{state | output: state.output <> bytes, output_bytes: next_count})
            else
              stop_with(:output_limit_exceeded, state)
            end
          end

        {port, {:exit_status, status}} when port == state.port ->
          state = observe_exit_status(state)

          if work_expired?(state),
            do: stop_with(:timeout, state),
            else: await_normal_down(status, state)

        {:cancel_sandbox_body, reference} when reference == state.cancellation_reference ->
          stop_with(:cancelled, state)

        {:DOWN, monitor, :process, owner, _reason}
        when monitor == state.owner_monitor and owner == state.owner ->
          stop_with(:owner_down, state)
      after
        work_remaining(state) -> stop_with(:timeout, state)
      end
    end
  end

  defp await_normal_down(exit_status, state) do
    if work_expired?(state) do
      stop_with(:timeout, state)
    else
      receive do
        {:DOWN, monitor, :port, port, _reason}
        when monitor == state.monitor and port == state.port ->
          state = Map.put(state, :port_down_observed, true)

          case await_process_group_down(state, state.deadline) do
            :down -> build_draft(exit_status, state)
            :deadline -> stop_with(:timeout, state)
            {:stop, reason} -> stop_with(reason, state)
          end

        {port, {:data, bytes}} when port == state.port and is_binary(bytes) ->
          if work_expired?(state) do
            stop_with(:timeout, state)
          else
            next_count = state.output_bytes + byte_size(bytes)

            if next_count <= @output_limit,
              do:
                await_normal_down(exit_status, %{
                  state
                  | output: state.output <> bytes,
                    output_bytes: next_count
                }),
              else: stop_with(:output_limit_exceeded, state)
          end

        {:cancel_sandbox_body, reference} when reference == state.cancellation_reference ->
          stop_with(:cancelled, state)

        {:DOWN, monitor, :process, owner, _reason}
        when monitor == state.owner_monitor and owner == state.owner ->
          stop_with(:owner_down, state)
      after
        work_remaining(state) -> stop_with(:timeout, state)
      end
    end
  end

  defp build_draft(exit_status, state) do
    with false <- work_expired?(state),
         {:ok, report} <- extract_report(state.output),
         true <- report_matches?(report, state.binding),
         :ok <- terminal_observed(state.lease.directory, report),
         false <- work_expired?(state) do
      {:ok,
       %{
         cancellation_reference: state.cancellation_reference,
         deadline: state.deadline,
         receipt_fields: %{
           "arm_fingerprint" => state.lease.arm_fingerprint,
           "cleanup" => %{"process" => "down"},
           "command_fingerprint" => state.command_fingerprint,
           "exit_status" => exit_status,
           "lease_fingerprint" => state.lease.fingerprint,
           "machine_output_digest" => hash(report),
           "owner_fingerprint" => state.binding["owner_fingerprint"],
           "report" => report,
           "status" => "exited",
           "target_fingerprint" => state.binding["target_fingerprint"]
         }
       }}
    else
      true ->
        stop_with(:timeout, state)

      _other ->
        if work_expired?(state),
          do: stop_with(:timeout, state),
          else: invalid(:invalid_machine_report)
    end
  end

  defp stop_with(reason, state) do
    if terminate_and_confirm(state), do: invalid(reason), else: invalid(:cleanup_uncertain)
  end

  defp terminate_and_confirm(state) do
    if cleanup_confirmed?(state) do
      true
    else
      now = System.monotonic_time(:millisecond)
      stop_budget = max(0, state.stop_deadline - state.deadline)
      termination_deadline = min(state.stop_deadline, now + stop_budget)
      remaining = max(0, termination_deadline - now)
      term_deadline = now + div(remaining, 2)

      signal(state.os_pid, "TERM")

      case await_forced_down(state, term_deadline) do
        {:confirmed, _state} ->
          true

        {:pending, state} ->
          signal(state.os_pid, "KILL")

          case await_forced_down(state, termination_deadline) do
            {:confirmed, _state} ->
              true

            {:pending, state} ->
              close_without_claim(state.port)
              false
          end
      end
    end
  end

  defp cleanup_confirmed?(state),
    do:
      Map.get(state, :exit_observed, false) and Map.get(state, :port_down_observed, false) and
        process_group_down?(state.os_pid)

  defp await_forced_down(state, deadline) do
    cond do
      cleanup_confirmed?(state) ->
        {:confirmed, state}

      System.monotonic_time(:millisecond) >= deadline ->
        {:pending, state}

      true ->
        receive do
          {port, {:exit_status, _status}} when port == state.port ->
            state |> observe_exit_status() |> await_forced_down(deadline)

          {port, {:data, _bytes}} when port == state.port ->
            await_forced_down(state, deadline)

          {:DOWN, monitor, :port, port, _reason}
          when monitor == state.monitor and port == state.port ->
            state |> Map.put(:port_down_observed, true) |> await_forced_down(deadline)
        after
          5 -> await_forced_down(state, deadline)
        end
    end
  end

  defp observe_exit_status(%{exit_observed: true} = state), do: state

  defp observe_exit_status(state) do
    :telemetry.execute(@exit_status_event, %{count: 1}, %{
      owner_fingerprint: state.binding["owner_fingerprint"]
    })

    Map.put(state, :exit_observed, true)
  end

  defp await_process_group_down(state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :deadline
    else
      case pending_stop(state) do
        {:stop, reason} ->
          {:stop, reason}

        :active ->
          if process_group_down?(state.os_pid) do
            case pending_stop(state) do
              {:stop, reason} -> {:stop, reason}
              :active -> :down
            end
          else
            receive do
              {:cancel_sandbox_body, reference}
              when reference == state.cancellation_reference ->
                {:stop, :cancelled}

              {:DOWN, monitor, :process, owner, _reason}
              when monitor == state.owner_monitor and owner == state.owner ->
                {:stop, :owner_down}

              {port, {:data, _bytes}} when port == state.port ->
                await_process_group_down(state, deadline)
            after
              5 -> await_process_group_down(state, deadline)
            end
          end
      end
    end
  end

  defp pending_stop(state) do
    receive do
      {:cancel_sandbox_body, reference} when reference == state.cancellation_reference ->
        {:stop, :cancelled}

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.owner_monitor and owner == state.owner ->
        {:stop, :owner_down}
    after
      0 -> :active
    end
  end

  # The fixed shell waits for one line on its standard input, then execs the
  # command in its own process, so the command keeps the os_pid (and the
  # process group) the port reports. Its arguments, directory, and
  # environment are the command's own.
  @hold_script ~S(read -r _ && exec "$0" "$@")

  @doc false
  @spec open_held(map()) :: port()
  def open_held(command),
    do:
      Port.open({:spawn_executable, hold_shell()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-c", @hold_script, command.executable | command.arguments],
        cd: command.cd,
        env: port_environment(command.env)
      ])

  @doc false
  @spec release_held(port()) :: :ok | :error
  def release_held(port) do
    true = Port.command(port, "\n")
    :ok
  rescue
    ArgumentError -> :error
  end

  defp hold_shell do
    Enum.find(["/bin/sh", "/usr/bin/sh"], &File.regular?/1) ||
      raise "fixed shell executable unavailable"
  end

  defp terminal_observed(directory, report) do
    case File.read(Path.join(directory, @terminal_file)) do
      {:ok, terminal} ->
        if terminal ==
             Canonical.encode(%{
               "phase" => "scenario",
               "report_digest" => hash(report),
               "seq" => 2
             }),
           do: :ok,
           else: :error

      _other ->
        :error
    end
  end

  defp extract_report(output) do
    reports =
      output
      |> :binary.split("\n", [:global])
      |> Enum.filter(&String.starts_with?(&1, @prefix))

    with [line] <- reports,
         encoded <- binary_part(line, byte_size(@prefix), byte_size(line) - byte_size(@prefix)),
         true <- byte_size(encoded) <= @report_limit,
         {:ok, report} <- Jason.decode(encoded),
         true <- Canonical.encode(report) == encoded,
         true <- Receipt.valid_report?(report) do
      {:ok, report}
    else
      _other -> :error
    end
  end

  defp report_matches?(report, binding),
    do:
      report["owner_fingerprint"] == binding["owner_fingerprint"] and
        report["target_fingerprint"] == binding["target_fingerprint"] and
        report["scenario_id"] == binding["scenario_id"] and
        report["expected_fingerprint"] == binding["expected_fingerprint"] and
        report["observer"] == binding["observer"] and
        report["lease_fingerprint"] == binding["lease_fingerprint"]

  defp valid_binding?(
         %{
           "expected_fingerprint" => expected,
           "lease_fingerprint" => lease,
           "observer" => observer,
           "owner_fingerprint" => owner,
           "scenario_id" => scenario,
           "target_fingerprint" => target
         } = binding
       ),
       do:
         map_size(binding) == 6 and Predicate.digest?(expected) and Predicate.digest?(lease) and
           Predicate.identity?(observer) and Predicate.id?(owner) and Predicate.id?(scenario) and
           Predicate.digest?(target) and Value.bounded_data?(binding, 4_096)

  defp valid_binding?(_binding), do: false

  defp valid_lease?(
         %{arm_fingerprint: arm, directory: directory, fingerprint: fingerprint, token: token} =
           lease,
         binding
       ),
       do:
         map_size(lease) == 4 and Predicate.digest?(arm) and absolute_path?(directory) and
           Predicate.digest?(fingerprint) and fingerprint == binding["lease_fingerprint"] and
           is_binary(token) and byte_size(token) in 16..256

  defp valid_lease?(_lease, _binding), do: false

  defp valid_command?(
         %{
           executable: executable,
           arguments: arguments,
           fingerprint_arguments: fingerprint_arguments,
           cd: cd,
           env: env,
           argument_policy: "public-exact/v1"
         } = command,
         lease
       ) do
    map_size(command) == 6 and absolute_path?(executable) and cd == lease.directory and
      valid_arguments?(arguments) and arguments == fingerprint_arguments and
      Value.bounded_list?(env, 32) and valid_environment?(env) and
      Value.bounded_data?({arguments, env}, 24_576)
  end

  defp valid_command?(_command, _lease), do: false

  defp valid_arguments?(arguments),
    do:
      Value.bounded_list?(arguments, 32) and
        Enum.all?(arguments, &(is_binary(&1) and byte_size(&1) <= 4_096 and String.valid?(&1)))

  defp valid_environment?(environment) do
    names = Enum.map(environment, &elem(&1, 0))

    Enum.all?(environment, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        byte_size(name) in 1..128 and byte_size(value) <= 4_096 and String.valid?(value) and
          String.match?(name, ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/) and
          not String.contains?(value, <<0>>)

      _other ->
        false
    end) and names == Enum.uniq(names)
  rescue
    _error -> false
  end

  defp command_fingerprint(profile, command),
    do:
      hash(%{
        "argument_policy" => command.argument_policy,
        "arguments" => command.fingerprint_arguments,
        "cd_policy" => "provider-owner-lease/v1",
        "env_names" => command.env |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
        "env_policy" => "clear-ambient-then-exact/v1",
        "executable" => command.executable,
        "profile" => profile.identity()
      })

  defp absolute_path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..4_096 and Path.type(path) == :absolute and
        not String.contains?(path, <<0>>)

  defp port_environment(configured) do
    configured
    |> Enum.reduce(
      Map.new(System.get_env(), fn {name, _value} -> {name, false} end),
      fn {name, value}, environment -> Map.put(environment, name, value) end
    )
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp process_group_down?(os_pid), do: process_group_status(os_pid) == :down

  defp process_group_status(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd(kill_executable(), ["-0", "--", "-#{os_pid}"],
           env: [{"LANG", "C"}, {"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :alive
      {output, _status} -> if absent_process_group?(output), do: :down, else: :unknown
    end
  rescue
    _error -> :unknown
  end

  defp absent_process_group?(output) when is_binary(output),
    do: String.contains?(output, "No such process")

  defp signal(os_pid, signal) do
    System.cmd(kill_executable(), ["-" <> signal, "--", "-#{os_pid}"], stderr_to_stdout: true)

    :ok
  rescue
    _error -> :error
  end

  defp kill_executable do
    Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) ||
      raise "fixed process-control executable unavailable"
  end

  defp close_without_claim(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp work_remaining(state),
    do: max(0, state.deadline - System.monotonic_time(:millisecond))

  defp work_expired?(state),
    do: System.monotonic_time(:millisecond) >= state.deadline

  defp work_status(deadline, cancellation_reference) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      receive do
        {:cancel_sandbox_body, ^cancellation_reference} -> :cancelled
      after
        0 -> :active
      end
    end
  end

  defp hash(value),
    do: :crypto.hash(:sha256, Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:external_process_failed, "external process execution failed", %{reason: reason})}
end
