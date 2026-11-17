defmodule Insider.Discovery.ExUnit.OracleRunner.CommandTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Command

  @prefix "RESULT="
  @other "MARKER="

  defp collected(chunks, max_output_bytes \\ 1_024) do
    state = Command.new_state(%{max_output_bytes: max_output_bytes, prefixes: [@prefix, @other]})
    chunks |> Enum.reduce(state, &Command.scan(&2, &1)) |> Command.finish("exited", 0, "exited")
  end

  test "reassembles prefixed lines split across chunks and strips carriage returns" do
    result = collected(["noise\nRES", "ULT={\"a\"", ":1}\r\nMARKER=x\n", "RESULT=tail"])

    assert result.counts == %{@prefix => 2, @other => 1}
    assert result.lines[@prefix] == [~s({"a":1}), "tail"]
    assert result.lines[@other] == ["x"]
    assert result.overlong == []
  end

  test "counts every prefixed line but retains only the first two" do
    result = collected(Enum.map(1..5, &"RESULT=#{&1}\n"))

    assert result.counts[@prefix] == 5
    assert result.lines[@prefix] == ["1", "2"]
  end

  test "a prefix in the middle of a line is not a result line" do
    result = collected(["....RESULT={}\n"])
    assert result.counts[@prefix] == 0
  end

  test "marks a prefixed line over the line limit whether it arrives whole or in pieces" do
    long = @prefix <> String.duplicate("x", Command.line_limit())
    whole = collected([long <> "\nRESULT=after\n"], 4_096)

    # 70 pieces of 1,000 bytes after the prefix: no single chunk is overlong.
    chunks = [@prefix | List.duplicate(String.duplicate("x", 1_000), 70)]
    pieces = collected(chunks ++ ["\nRESULT=after\n"], 4_096)

    for result <- [whole, pieces] do
      assert result.overlong == [@prefix]
      assert result.lines[@prefix] == ["after"]
      assert result.counts[@prefix] == 1
    end
  end

  test "keeps a bounded head and tail and accounts for every omitted byte" do
    output =
      Enum.map_join(1..100, fn index ->
        String.pad_leading(Integer.to_string(index), 9, "0") <> "\n"
      end)

    result = collected([output], 100)

    assert result.bytes_total == 1_000
    assert result.bytes_omitted == 900
    assert result.head == binary_part(output, 0, 50)
    assert result.tail == binary_part(output, 950, 50)

    small = collected(["short\n"], 100)
    assert {small.head, small.tail, small.bytes_omitted} == {"short\n", "", 0}
  end

  test "retained state stays bounded however many chunks and overlong lines arrive" do
    state = Command.new_state(%{max_output_bytes: 4_096, prefixes: [@prefix]})
    long = @prefix <> String.duplicate("y", Command.line_limit() + 1) <> "\n"
    chunks = List.duplicate("ab", 10_000) ++ List.duplicate(long, 20)
    state = Enum.reduce(chunks, state, &Command.scan(&2, &1))

    assert is_binary(state.head) and byte_size(state.head) == 2_048
    assert byte_size(state.tail) == 2_048
    assert state.overlong == [@prefix]
    assert :erts_debug.flat_size(state) < 1_000
  end

  test "passes only the configured environment, including empty values" do
    result =
      Command.run(%{
        executable: System.find_executable("sh"),
        arguments: [
          "-c",
          ~s(printf 'RESULT=%s|%s|%s\\n' "${DECLARED-unset}" "${EMPTY-unset}" "${HOME-unset}")
        ],
        cd: System.tmp_dir!(),
        environment: [{"DECLARED", "value"}, {"EMPTY", ""}],
        timeout_ms: 10_000,
        max_output_bytes: 4_096,
        prefixes: [@prefix]
      })

    assert result.termination == "exited"
    assert result.status == 0
    # This leader exits at once, so its group id may be unreadable and cleanup
    # `uncertain` (see the immediate-exit test); cleanup itself is asserted by
    # the descendant and deadline tests. This test is about the environment.
    assert result.process in ["exited", "uncertain"]
    assert result.lines[@prefix] == ["value||unset"]
  end

  # Explicit barriers, no scheduling assumptions:
  # 1. the child writes its pid to `ready` once it runs, so the port is open and
  #    (since the deadline is fixed before the spawn) the deadline exists;
  # 2. the collector is then suspended and the test waits until the monotonic
  #    clock is past `ready + timeout`, so the deadline has certainly expired;
  # 3. the test releases the child through a FIFO and waits until the child is
  #    gone and its output and exit status are in the collector's mailbox.
  # Only then does the collector resume, with the deadline expired and the
  # messages queued.
  test "an expired deadline wins over output and exit messages already queued" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "insider-deadline-" <> Base.encode16(:crypto.strong_rand_bytes(6))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    fifo = Path.join(dir, "release")
    ready = Path.join(dir, "ready")
    {_output, 0} = System.cmd("mkfifo", [fifo])
    timeout_ms = 200

    collector =
      Task.async(fn ->
        Command.run(%{
          executable: System.find_executable("sh"),
          arguments: [
            "-c",
            "printf '%s' $$ > ready; read line < release; printf 'RESULT=late\\n'"
          ],
          cd: dir,
          environment: [{"PATH", System.get_env("PATH")}],
          timeout_ms: timeout_ms,
          max_output_bytes: 4_096,
          prefixes: [@prefix]
        })
      end)

    child =
      await_until(fn -> File.exists?(ready) and File.read!(ready) != "" and File.read!(ready) end)

    ready_at = System.monotonic_time(:millisecond)
    true = :erlang.suspend_process(collector.pid)
    await_until(fn -> System.monotonic_time(:millisecond) > ready_at + timeout_ms end)

    File.write!(fifo, "go\n")

    await_until(fn ->
      match?(
        {_output, status} when status != 0,
        System.cmd("/bin/kill", ["-0", child], stderr_to_stdout: true)
      )
    end)

    await_until(fn ->
      Process.info(collector.pid, :message_queue_len) >= {:message_queue_len, 2}
    end)

    true = :erlang.resume_process(collector.pid)
    result = Task.await(collector, 15_000)

    assert result.termination == "deadline_exceeded"
    assert result.status == nil
  end

  # Polls an observable condition with a fixed bound; it never decides a verdict.
  defp await_until(condition, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      value = condition.() -> value
      System.monotonic_time(:millisecond) > deadline -> flunk("barrier condition not reached")
      true -> await_until(condition, deadline)
    end
  end

  test "terminates the whole process group at the deadline" do
    result =
      Command.run(%{
        executable: System.find_executable("sh"),
        arguments: ["-c", "sleep 60 & printf 'RESULT=%s\\n' $!; wait"],
        cd: System.tmp_dir!(),
        environment: [{"PATH", System.get_env("PATH")}],
        timeout_ms: 1_000,
        max_output_bytes: 4_096,
        prefixes: [@prefix]
      })

    assert result.termination == "deadline_exceeded"
    assert result.status == nil
    assert result.process == "group_terminated"
    [child] = result.lines[@prefix]
    assert {_output, status} = System.cmd("/bin/kill", ["-0", child], stderr_to_stdout: true)
    assert status != 0
  end

  # The leader lives one second so that its group id is read before it exits;
  # a leader that exits sooner is covered by the next test.
  test "reaps a descendant left in the group after the leader exits" do
    result =
      Command.run(%{
        executable: System.find_executable("sh"),
        arguments: [
          "-c",
          "(exec sleep 60) </dev/null >/dev/null 2>&1 & printf 'RESULT=%s\\n' $!; sleep 1"
        ],
        cd: System.tmp_dir!(),
        environment: [{"PATH", System.get_env("PATH")}],
        timeout_ms: 10_000,
        max_output_bytes: 4_096,
        prefixes: [@prefix]
      })

    assert result.termination == "exited"
    assert result.process == "group_terminated"
    [child] = result.lines[@prefix]
    assert {_output, status} = System.cmd("/bin/kill", ["-0", child], stderr_to_stdout: true)
    assert status != 0
  end

  test "a leader that exits at once is still collected, never reported as a spawn failure" do
    for _attempt <- 1..20 do
      result =
        Command.run(%{
          executable: System.find_executable("sh"),
          arguments: ["-c", "printf 'RESULT=done\\n'"],
          cd: System.tmp_dir!(),
          environment: [],
          timeout_ms: 10_000,
          max_output_bytes: 4_096,
          prefixes: [@prefix]
        })

      assert {result.termination, result.status, result.lines[@prefix]} == {"exited", 0, ["done"]}
      assert result.process in ["exited", "uncertain"]
    end
  end

  test "reports a spawn failure without starting anything" do
    result =
      Command.run(%{
        executable: "/nonexistent/insider-oracle-runner",
        arguments: [],
        cd: System.tmp_dir!(),
        environment: [],
        timeout_ms: 1_000,
        max_output_bytes: 4_096,
        prefixes: [@prefix]
      })

    assert result.termination == "spawn_failed"
    assert result.process == "not_started"
    assert result.status == nil
  end
end
