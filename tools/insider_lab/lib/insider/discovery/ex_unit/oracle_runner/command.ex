defmodule Insider.Discovery.ExUnit.OracleRunner.Command do
  @moduledoc false

  # Runs one child command with an exact environment, a deadline, a bounded
  # head-and-tail output capture, and a line scanner for fixed marker prefixes.
  # Erlang starts each port program as its own process-group leader, so the
  # deadline and post-exit cleanup signal the whole group.

  @line_limit 65_536
  @retained_lines 2
  @kill_grace_ms 5_000
  @poll_ms 50

  @type result :: %{
          termination: String.t(),
          status: non_neg_integer() | nil,
          head: binary(),
          tail: binary(),
          bytes_total: non_neg_integer(),
          bytes_omitted: non_neg_integer(),
          lines: %{String.t() => [binary()]},
          counts: %{String.t() => non_neg_integer()},
          overlong: [String.t()],
          process: String.t()
        }

  @spec line_limit() :: pos_integer()
  def line_limit, do: @line_limit

  @spec run(%{
          executable: String.t(),
          arguments: [String.t()],
          cd: String.t(),
          environment: [{String.t(), String.t()}],
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          prefixes: [String.t()]
        }) :: result()
  # The deadline is fixed before the child is spawned, so no delay of the
  # collector after the spawn can extend it.
  def run(spec) do
    state = new_state(spec)
    deadline = System.monotonic_time(:millisecond) + spec.timeout_ms

    case open(spec) do
      {:ok, port, os_pid} ->
        collect(%{state | port: port, os_pid: os_pid}, deadline)

      :error ->
        finish(state, "spawn_failed", nil, "not_started")
    end
  end

  defp open(spec) do
    {executable, arguments, environment} = with_empty_values(spec)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: arguments,
        cd: spec.cd,
        env: port_environment(environment)
      ])

    # A leader that exits before this call closes the port, so its group id is
    # unknown; its buffered output and exit status still arrive as messages.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {:ok, port, os_pid}
      nil -> {:ok, port, nil}
    end
  rescue
    _error -> :error
  end

  @doc false
  @spec scan(map(), binary()) :: map()
  def scan(state, data) do
    state = capture(state, data)
    pieces = :binary.split(state.partial <> data, "\n", [:global])
    {complete, [partial]} = Enum.split(pieces, -1)
    state = Enum.reduce(complete, %{state | partial: <<>>}, &complete_line/2)

    if byte_size(partial) > @line_limit do
      %{mark_overlong(state, partial) | partial: <<>>, discarding: true}
    else
      %{state | partial: partial}
    end
  end

  @doc false
  @spec new_state(%{max_output_bytes: pos_integer(), prefixes: [String.t()]}) :: map()
  def new_state(spec) do
    head_limit = div(spec.max_output_bytes, 2)

    %{
      port: nil,
      os_pid: nil,
      prefixes: spec.prefixes,
      head: <<>>,
      head_limit: head_limit,
      tail: <<>>,
      tail_limit: spec.max_output_bytes - head_limit,
      total: 0,
      partial: <<>>,
      discarding: false,
      lines: Map.new(spec.prefixes, &{&1, []}),
      counts: Map.new(spec.prefixes, &{&1, 0}),
      overlong: []
    }
  end

  @doc false
  @spec finish(map(), String.t(), non_neg_integer() | nil, String.t()) :: result()
  def finish(state, termination, status, process) do
    state = if state.discarding, do: state, else: complete_line(state.partial, state)

    %{
      termination: termination,
      status: status,
      head: state.head,
      tail: state.tail,
      bytes_total: state.total,
      bytes_omitted: state.total - byte_size(state.head) - byte_size(state.tail),
      lines: Map.new(state.lines, fn {prefix, lines} -> {prefix, Enum.reverse(lines)} end),
      counts: state.counts,
      overlong: Enum.reverse(state.overlong),
      process: process
    }
  end

  # The deadline is checked before each message is taken, so output or an exit
  # status already queued when the deadline passes cannot win over it. An exit
  # observed at or after the deadline is still a deadline verdict.
  defp collect(state, deadline) do
    port = state.port
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      terminate(state)
    else
      receive do
        {^port, {:data, data}} ->
          collect(scan(state, data), deadline)

        {^port, {:exit_status, status}} ->
          if System.monotonic_time(:millisecond) >= deadline,
            do: finish(state, "deadline_exceeded", nil, reap_group(state.os_pid)),
            else: finish(state, "exited", status, reap_group(state.os_pid))
      after
        remaining -> terminate(state)
      end
    end
  end

  defp terminate(%{os_pid: nil} = state) do
    close(state.port)
    finish(state, "deadline_exceeded", nil, "uncertain")
  end

  defp terminate(state) do
    signal(state.os_pid, "TERM")

    case drain(state, System.monotonic_time(:millisecond) + @kill_grace_ms) do
      {:exited, state} ->
        finish(state, "deadline_exceeded", nil, reap_group(state.os_pid, "group_terminated"))

      {:running, state} ->
        signal(state.os_pid, "KILL")

        case drain(state, System.monotonic_time(:millisecond) + @kill_grace_ms) do
          {:exited, state} ->
            finish(state, "deadline_exceeded", nil, reap_group(state.os_pid, "group_terminated"))

          {:running, state} ->
            close(state.port)
            finish(state, "deadline_exceeded", nil, "uncertain")
        end
    end
  end

  # A port whose program already exited is closed, and `Port.close/1` raises on
  # it. That happens when the leader exits before its pid could be read.
  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> true
  end

  defp drain(state, deadline) do
    port = state.port
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:running, state}
    else
      receive do
        {^port, {:data, data}} -> drain(scan(state, data), deadline)
        {^port, {:exit_status, _status}} -> {:exited, state}
      after
        remaining -> {:running, state}
      end
    end
  end

  # The leader has exited; a descendant that stayed in its group is still ours.
  # Without the leader's id the group cannot be inspected, so cleanup is unknown.
  defp reap_group(os_pid, clean \\ "exited")
  defp reap_group(nil, _clean), do: "uncertain"

  defp reap_group(os_pid, clean) do
    cond do
      not group_alive?(os_pid) -> clean
      stop_group(os_pid, "TERM") -> "group_terminated"
      stop_group(os_pid, "KILL") -> "group_terminated"
      true -> "uncertain"
    end
  end

  defp stop_group(os_pid, name) do
    signal(os_pid, name)
    await_group_exit(os_pid, System.monotonic_time(:millisecond) + @kill_grace_ms)
  end

  defp await_group_exit(os_pid, deadline) do
    cond do
      not group_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        await_group_exit(os_pid, deadline)
    end
  end

  defp group_alive?(os_pid) do
    match?(
      {_output, 0},
      System.cmd(kill_executable(), ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true)
    )
  end

  defp signal(os_pid, name),
    do: System.cmd(kill_executable(), ["-" <> name, "--", "-#{os_pid}"], stderr_to_stdout: true)

  defp kill_executable do
    Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) ||
      raise "fixed process-control executable unavailable"
  end

  # The head is one binary that stops growing at its limit, and the tail keeps
  # only its last bytes, so retained state is bounded by `max_output_bytes`
  # however many chunks arrive.
  defp capture(state, data) do
    size = byte_size(data)
    taken = min(state.head_limit - byte_size(state.head), size)
    head = if taken > 0, do: state.head <> binary_part(data, 0, taken), else: state.head
    tail = state.tail <> binary_part(data, taken, size - taken)
    excess = byte_size(tail) - state.tail_limit
    tail = if excess > 0, do: binary_part(tail, excess, state.tail_limit), else: tail

    %{state | head: head, tail: tail, total: state.total + size}
  end

  defp complete_line(line, %{discarding: true} = state) when is_binary(line),
    do: %{state | discarding: false}

  defp complete_line(line, state) when byte_size(line) > @line_limit,
    do: mark_overlong(state, line)

  defp complete_line(line, state) do
    line = String.trim_trailing(line, "\r")

    case Enum.find(state.prefixes, &String.starts_with?(line, &1)) do
      nil ->
        state

      prefix ->
        retain(
          state,
          prefix,
          binary_part(line, byte_size(prefix), byte_size(line) - byte_size(prefix))
        )
    end
  end

  defp retain(state, prefix, payload) do
    count = state.counts[prefix] + 1

    lines =
      if count <= @retained_lines, do: [payload | state.lines[prefix]], else: state.lines[prefix]

    %{
      state
      | counts: Map.put(state.counts, prefix, count),
        lines: Map.put(state.lines, prefix, lines)
    }
  end

  defp mark_overlong(%{discarding: true} = state, _partial), do: state

  defp mark_overlong(state, partial) do
    case Enum.find(state.prefixes, &String.starts_with?(partial, &1)) do
      nil ->
        state

      prefix ->
        if prefix in state.overlong,
          do: state,
          else: %{state | overlong: [prefix | state.overlong]}
    end
  end

  @doc false
  @spec kill_group(pos_integer()) :: :ok
  def kill_group(os_pid) do
    signal(os_pid, "KILL")
    :ok
  end

  # Erlang ports drop environment entries whose value is empty, so those are
  # assigned by env(1) in front of the executable. Only empty values reach argv.
  defp with_empty_values(spec) do
    case Enum.split_with(spec.environment, fn {_name, value} -> value == "" end) do
      {[], environment} ->
        {spec.executable, spec.arguments, environment}

      {empty, present} ->
        env =
          Enum.find(["/usr/bin/env", "/bin/env"], &File.regular?/1) ||
            raise "fixed env executable unavailable"

        assignments = Enum.map(empty, fn {name, ""} -> name <> "=" end)
        {env, assignments ++ [spec.executable | spec.arguments], present}
    end
  end

  # Every variable of the invoking VM is removed unless the caller set it.
  defp port_environment(configured) do
    configured = Map.new(configured)

    System.get_env()
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(configured, &1))
    |> Enum.map(&{String.to_charlist(&1), false})
    |> Kernel.++(
      Enum.map(configured, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)
    )
  end
end
