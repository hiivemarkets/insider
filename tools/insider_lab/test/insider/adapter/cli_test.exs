defmodule Insider.Adapter.CLITest do
  # Building the actual escript uses Mix's shared project artifacts.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Insider.Adapter.CLI
  alias Insider.Adapter.CLI.Wire
  alias Insider.Protocol
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Test.CLIDispatcher

  @request %{
    "schema" => "insider.request/v1",
    "protocol" => "insider.protocol/v1",
    "operation" => "runtime.health",
    "request_id" => "cli-test-1"
  }

  setup_all do
    directory = Path.join(System.tmp_dir!(), "insider-cli-#{System.unique_integer([:positive])}")
    escript = Path.join(directory, "insider")
    lab_root = Path.expand("../../..", __DIR__)
    File.mkdir_p!(directory)

    {_output, 0} =
      System.cmd("mix", ["escript.build"],
        cd: lab_root,
        env: [
          {"INSIDER_ESCRIPT_PATH", escript},
          {"MIX_ENV", "test"},
          {"MIX_DEPS_PATH", Path.expand("../../deps", lab_root)},
          {"MIX_BUILD_PATH", Path.expand("../../_build/insider_lab", lab_root)}
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, escript: escript, subprocess_directory: directory}
  end

  test "direct Erlang-term API validates then invokes an injected dispatcher" do
    assert %Result{status: :ok, value: %{healthy: true}} = CLI.invoke(@request, CLIDispatcher)
    assert {:error, %Error{code: :invalid_request}} = CLI.invoke(%{}, CLIDispatcher)

    assert {:ok, request} = Protocol.decode_request(@request)
    assert %Result{status: :ok} = CLI.invoke(request, &Protocol.success(&1, :direct))

    assert {:error, %Error{code: :invalid_request}} =
             @request |> Map.put("surprise", true) |> CLI.invoke(CLIDispatcher)

    assert %Result{status: :unsupported} = CLI.invoke(@request)
  end

  test "direct Request structs are fully revalidated before dispatch" do
    assert {:ok, request} = Protocol.decode_request(@request)
    owner = self()

    dispatcher = fn valid ->
      send(owner, {:dispatched, valid})
      Protocol.success(valid, :ok)
    end

    forged = [
      %{request | schema: "forged.request/v1"},
      %{request | protocol: "forged.protocol/v1"},
      %{request | operation: "runtime.forged"},
      %{request | budget: %{request.budget | max_bytes: 1}},
      %{request | budget: Map.from_struct(request.budget)},
      %{request | params: %{payload: self()}},
      %{request | target: %{node: String.duplicate("n", 257)}},
      %{request | redaction_policy: :forged},
      %{request | deadline_monotonic: :infinity},
      %{
        request
        | deadline_monotonic: System.monotonic_time(:millisecond) + request.timeout_ms * 2
      }
    ]

    for invalid <- forged do
      assert {:error, %Error{code: :invalid_request}} = CLI.invoke(invalid, dispatcher)
    end

    refute Request.valid?(:not_a_request)
    refute_received {:dispatched, _request}
  end

  test "discovery is bounded, portable, and distinguishes vocabulary from availability" do
    discovery = CLI.discovery()

    assert discovery["protocol"] == Protocol.version()
    assert Enum.map(discovery["operations"], & &1.operation) == Protocol.operations()
    snapshot = Enum.find(discovery["operations"], &(&1.operation == "runtime.snapshot"))
    assert snapshot.required_scope == "runtime.observe"
    assert snapshot.runtime_isolation == :unavailable
    assert snapshot.effective_maximums.max_bytes == 16_777_216
    assert discovery["request_schema"] == "insider.request/v1"
    assert discovery["result_schema"] == "insider.result/v1"
    assert discovery["transports"] == ["erlang", "json", "ndjson"]
    assert discovery["default_dispatcher"] == "adapter_discovery_only"

    assert discovery["limits"] == %{
             "buffered_max_input_bytes" => 16_777_216,
             "buffered_max_output_bytes" => 16_777_216,
             "decoder_max_heap_words" => 16_777_216,
             "decoder_timeout_ms" => 5_000,
             "max_dispatcher_heap_words" => 16_777_216,
             "max_frames" => 1_000,
             "max_input_bytes" => 16_777_216,
             "max_json_depth" => 8,
             "max_json_width" => 1_000,
             "max_output_bytes" => 16_777_216,
             "max_stream_output_bytes" => 16_777_218_024,
             "stream_terminal_error_reserve_bytes" => 1_024
           }

    assert discovery["exit_statuses"]["timeout"] == 124
    assert discovery["exit_statuses"]["catastrophic"] == 70
  end

  test "JSON responses are canonical and exit status follows the protocol result" do
    input = Jason.encode!(@request)

    assert {first, 0} = CLI.invoke_json(input, CLIDispatcher)
    assert {second, 0} = CLI.invoke_json(input, CLIDispatcher)
    assert first == second
    assert first == String.trim(first) <> "\n"

    decoded = Jason.decode!(first)
    assert decoded["schema"] == "insider.result/v1"
    assert decoded["status"] == "ok"
    assert decoded["value"] == %{"healthy" => true}

    for {outcome, expected_status, expected_exit} <- [
          {"error", "error", 1},
          {"timeout", "timeout", 124},
          {"cancelled", "cancelled", 130}
        ] do
      request = put_in(@request, ["params"], %{"outcome" => outcome})
      {output, status} = CLI.invoke_json(Jason.encode!(request), CLIDispatcher)
      assert Jason.decode!(output)["status"] == expected_status
      assert status == expected_exit
    end
  end

  test "one-shot runner handles discovery, stdin states, and usage without prose" do
    assert {discovery, 0} = CLI.run_once(["--discover"], fn _maximum -> :eof end)
    assert Jason.decode!(discovery)["schema"] == "insider.cli.discovery/v1"

    input = Jason.encode!(@request)
    assert {result, 3} = CLI.run_once(["--json"], fn _maximum -> input end)
    assert Jason.decode!(result)["status"] == "unsupported"

    assert {empty, 64} = CLI.run_once(["--json"], fn _maximum -> :eof end)
    assert Jason.decode!(empty)["error"]["code"] == "empty_input"

    assert {failed, 64} = CLI.run_once(["--json"], fn _maximum -> {:error, :closed} end)
    assert Jason.decode!(failed)["error"]["code"] == "input_failed"

    assert {usage, 64} = CLI.run_once([], fn _maximum -> :eof end)
    assert Jason.decode!(usage)["error"]["code"] == "usage"
  end

  test "CLI routing returns transport status and contains writer failure" do
    owner = self()
    input = Jason.encode!(@request)
    json_reader = fn _maximum -> input end

    writer = fn output ->
      send(owner, {:cli_output, output})
      :ok
    end

    assert CLI.run_cli(["--json"], fn -> :eof end, json_reader, writer) == 3
    assert_receive {:cli_output, json_output}
    assert Jason.decode!(json_output)["status"] == "unsupported"

    {ndjson_reader, _writer} = stream_io([input <> "\n", :eof])
    assert CLI.run_cli(["--ndjson"], ndjson_reader, json_reader, writer) == 0
    assert_receive {:cli_output, ndjson_output}
    assert Jason.decode!(ndjson_output)["status"] == "unsupported"

    assert CLI.run_cli(["--json"], fn -> :eof end, json_reader, fn _output -> :error end) == 70
  end

  test "default dispatcher honestly reports unavailable execution" do
    capabilities = Map.merge(@request, %{"operation" => "runtime.capabilities"})
    {capabilities_output, 0} = CLI.invoke_json(Jason.encode!(capabilities))
    assert Jason.decode!(capabilities_output)["value"]["schema"] == "insider.capabilities/v1"

    {output, status} = CLI.invoke_json(Jason.encode!(@request))

    assert status == 3
    assert Jason.decode!(output)["status"] == "unsupported"
    assert Jason.decode!(output)["error"]["code"] == "unsupported_capability"
  end

  test "NDJSON preserves one response per frame and aggregate failure status" do
    second = put_in(@request, ["request_id"], "cli-test-2")

    third =
      second
      |> put_in(["request_id"], "cli-test-3")
      |> put_in(["params"], %{"outcome" => "timeout"})

    input = Enum.map_join([@request, second, third], "\n", &Jason.encode!/1) <> "\n"

    assert {output, 0} = CLI.invoke_ndjson(input, CLIDispatcher)
    frames = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(frames, & &1["request_id"]) == ["cli-test-1", "cli-test-2", "cli-test-3"]
    assert Enum.map(frames, & &1["status"]) == ["ok", "ok", "timeout"]

    {blank_output, 0} = CLI.invoke_ndjson(Jason.encode!(@request) <> "\n\n", CLIDispatcher)
    assert blank_output |> String.split("\n", trim: true) |> length() == 2
  end

  test "buffered NDJSON enforces frame and aggregate output limits" do
    assert {"", 0} = CLI.invoke_ndjson("")
    assert {frame_error, 64} = CLI.invoke_ndjson(String.duplicate("\n", 1_001), CLIDispatcher)
    assert Jason.decode!(frame_error)["error"]["code"] == "frame_limit_exceeded"

    request =
      @request
      |> Map.put("budget", %{"max_bytes" => 16_777_216})
      |> Jason.encode!()

    large_dispatcher = fn validated ->
      Protocol.success(validated, %{"payload" => String.duplicate("x", 9_000_000)})
    end

    assert {output, 0} = CLI.invoke_ndjson(request <> "\n" <> request, large_dispatcher)
    assert byte_size(output) <= 16_777_216

    results = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [_, _] = results
    assert Enum.all?(results, &(&1["error"]["code"] == "operation_failed"))
    assert Enum.all?(results, &(&1["cleanup"]["status"] == "uncertain"))
    assert Enum.all?(results, &(&1["uncertainty"] != []))

    assert Enum.all?(results, fn result ->
             result["truncated"] == %{"reason" => "transport_output_limit", "dropped" => 1} and
               result["dropped"] == %{"dispatcher_result_payloads" => 1}
           end)
  end

  test "stream engine handles chunk boundaries, EOF, frame limits, and I/O failures" do
    json = Jason.encode!(@request)
    split_at = div(byte_size(json), 2)
    <<first::binary-size(^split_at), second::binary>> = json

    {reader, writer} = stream_io([first, second <> "\n\n", json, :eof])
    assert CLI.run_ndjson_stream(reader, writer, CLIDispatcher) == 0
    assert_receive {:stream_write, _first}
    assert_receive {:stream_write, blank}
    assert Jason.decode!(blank)["error"]["code"] == "invalid_json"
    assert_receive {:stream_write, _final_eof_frame}

    {limit_reader, _limit_writer} = stream_io([String.duplicate("\n", 1_001), :eof])
    assert CLI.run_ndjson_stream(limit_reader, fn _output -> :ok end, CLIDispatcher) == 64

    assert CLI.run_ndjson_stream(fn -> {:error, :closed} end, fn _output -> :ok end) == 70

    {failing_reader, _writer} = stream_io([json <> "\n", :eof])

    assert CLI.run_ndjson_stream(failing_reader, fn _output -> {:error, :closed} end) == 70

    {unexpected_reader, _writer} = stream_io([json <> "\n", :eof])
    assert CLI.run_ndjson_stream(unexpected_reader, fn _output -> :unexpected end) == 70

    {raising_writer_reader, _writer} = stream_io([json <> "\n", :eof])
    assert CLI.run_ndjson_stream(raising_writer_reader, fn _output -> raise "closed" end) == 70

    {throwing_writer_reader, _writer} = stream_io([json <> "\n", :eof])
    assert CLI.run_ndjson_stream(throwing_writer_reader, fn _output -> throw(:closed) end) == 70

    assert CLI.run_ndjson_stream(fn -> raise "read failed" end, fn _output -> :ok end) == 70
    assert CLI.run_ndjson_stream(fn -> throw(:read_failed) end, fn _output -> :ok end) == 70

    oversized = String.duplicate("x", 16_777_217)
    {oversized_reader, oversized_writer} = stream_io([oversized, "\n", :eof])
    assert CLI.run_ndjson_stream(oversized_reader, oversized_writer) == 0
    assert_receive {:stream_write, oversized_error}
    assert Jason.decode!(oversized_error)["error"]["code"] == "input_limit_exceeded"

    {empty_reader, empty_writer} = stream_io([:eof])
    assert CLI.run_ndjson_stream(empty_reader, empty_writer) == 0

    {final_limit_reader, _writer} =
      stream_io([String.duplicate("\n", 1_000) <> json, :eof])

    assert CLI.run_ndjson_stream(final_limit_reader, fn _output -> :ok end) == 64

    {final_write_reader, _writer} = stream_io([json, :eof])
    assert CLI.run_ndjson_stream(final_write_reader, fn _output -> {:error, :closed} end) == 70
  end

  test "wire projection is deterministic and rejects unsafe or ambiguous residual values" do
    assert {:ok, tuple} = Wire.encode(%{"tuple" => {:known_atom, 1}})
    assert Jason.decode!(tuple) == %{"tuple" => ["known_atom", 1]}
    assert {:ok, float} = Wire.encode(%{"measurement" => 1.25})
    assert Jason.decode!(float) == %{"measurement" => 1.25}

    effect = Effect.new(:probe, "worker", details: %{"count" => 1})
    error = Error.new(:operation_failed, "failed")
    assert {:ok, projected} = Wire.encode(%{"effect" => effect, "error" => error})
    assert Jason.decode!(projected)["effect"]["status"] == "observed"

    assert :error = Wire.encode(%{:collision => true, "collision" => false})
    assert :error = Wire.encode(%{"pid" => self()})
    assert :error = Wire.encode(%{"improper" => [:one | :tail]})
    assert :error = Wire.encode(%{1.5 => "invalid key"})
    assert :error = Wire.encode(%{"binary" => <<255>>})
    assert {:ok, integer_key} = Wire.encode(%{1 => "one"})
    assert Jason.decode!(integer_key) == %{"1" => "one"}
    assert :error = Wire.encode(%{"list" => [self()]})
    assert {:ok, request} = Protocol.decode_request(@request)
    malformed_result = %{Protocol.success(request, :ok) | effects: :not_a_list}
    assert :error = Wire.encode_result(malformed_result)
  end

  test "hostile input is bounded and does not create atoms from external strings" do
    unknown = "attacker.operation.#{System.unique_integer()}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    for suffix <- 1..100 do
      request = Map.put(@request, "operation", unknown <> ".#{suffix}")

      assert {_output, 64} = CLI.invoke_json(Jason.encode!(request), CLIDispatcher)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    oversized = String.duplicate("x", 16_777_217)
    assert {output, 64} = CLI.invoke_json(oversized, CLIDispatcher)
    assert Jason.decode!(output)["error"]["code"] == "input_limit_exceeded"

    assert {ndjson_output, 64} = CLI.invoke_ndjson(oversized, CLIDispatcher)
    assert Jason.decode!(ndjson_output)["error"]["code"] == "input_limit_exceeded"

    duplicate =
      ~s({"schema":"insider.request/v1","protocol":"insider.protocol/v1","operation":"runtime.health","operation":"runtime.capabilities","request_id":"duplicate"})

    assert {duplicate_output, 64} = CLI.invoke_json(duplicate, CLIDispatcher)
    assert Jason.decode!(duplicate_output)["error"]["code"] == "invalid_json"

    deep = String.duplicate("[", 10_000) <> "0" <> String.duplicate("]", 10_000)
    assert {deep_output, 64} = CLI.invoke_json(deep, CLIDispatcher)
    assert Jason.decode!(deep_output)["error"]["code"] == "invalid_json"

    wide = Jason.encode!(Enum.to_list(1..1_001))
    assert {wide_output, 64} = CLI.invoke_json(wide, CLIDispatcher)
    assert Jason.decode!(wide_output)["error"]["code"] == "invalid_json"

    depth_eight = nested_map(7)
    depth_nine = nested_map(8)
    list_params = %{"items" => [1, 2]}

    assert {_accepted, 0} =
             CLI.invoke_json(
               Jason.encode!(Map.put(@request, "params", depth_eight)),
               CLIDispatcher
             )

    assert {_rejected, 64} =
             CLI.invoke_json(
               Jason.encode!(Map.put(@request, "params", depth_nine)),
               CLIDispatcher
             )

    assert {_list_accepted, 0} =
             CLI.invoke_json(
               Jason.encode!(Map.put(@request, "params", list_params)),
               CLIDispatcher
             )

    assert {_nested_list_rejected, 64} =
             CLI.invoke_json(Jason.encode!([nested_map(9)]), CLIDispatcher)
  end

  test "dispatcher exceptions, invalid correlation, and nonportable output fail closed" do
    owner = self()

    assert %Result{
             status: :error,
             error: %Error{code: :operation_failed},
             cleanup: %{status: :uncertain},
             uncertainty: [_reason]
           } =
             CLI.invoke(@request, fn _request ->
               send(owner, :effect)
               raise "boom"
             end)

    assert_received :effect

    assert %Result{
             status: :error,
             error: %Error{message: message},
             cleanup: %{status: :uncertain}
           } =
             CLI.invoke(@request, fn request ->
               %{Protocol.success(request, :ok) | request_id: "wrong-request"}
             end)

    assert message =~ "invalid protocol result"

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             CLI.invoke(@request, fn _request -> throw(:dispatcher_failed) end)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             CLI.invoke(@request, fn _request -> :not_a_result end)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             CLI.invoke(@request, fn _request -> exit(:kill) end)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             CLI.invoke(@request, fn _request -> Process.exit(self(), :kill) end)

    assert {:ok, valid_request} = Protocol.decode_request(@request)
    malformed_deadline = %{valid_request | deadline_monotonic: :not_a_deadline}

    assert {:error, %Error{code: :invalid_request}} =
             CLI.invoke(malformed_deadline, CLIDispatcher)

    assert %Result{status: :error, error: %Error{message: schema_message}} =
             CLI.invoke(@request, fn request ->
               %{Protocol.success(request, :ok) | schema: "forged.result/v1"}
             end)

    assert schema_message =~ "invalid protocol result"

    {output, 1} =
      CLI.invoke_json(Jason.encode!(@request), fn request ->
        Protocol.success(request, %{:collision => true, "collision" => false})
      end)

    decoded_output = Jason.decode!(output)
    assert decoded_output["schema"] == "insider.result/v1"
    assert decoded_output["request_id"] == "cli-test-1"
    assert decoded_output["error"]["code"] == "operation_failed"
    assert decoded_output["cleanup"]["status"] == "uncertain"
    assert decoded_output["uncertainty"] != []
  end

  test "dispatcher work cannot outlive the validated request deadline" do
    request = Map.put(@request, "timeout_ms", 50)

    assert %Result{status: :timeout, cleanup: %{status: :uncertain}, uncertainty: [_reason]} =
             CLI.invoke(request, fn _request -> receive(do: (_message -> :unexpected)) end)

    assert {:ok, decoded} = Protocol.decode_request(@request)
    owner = self()
    expired = %{decoded | deadline_monotonic: System.monotonic_time(:millisecond) - 1}

    assert %Result{status: :timeout, cleanup: %{status: :not_required}} =
             CLI.invoke(expired, fn _request -> send(owner, :dispatched) end)

    refute_received :dispatched
  end

  test "JSON result validation and projection remain inside the request deadline" do
    request =
      @request
      |> Map.put("timeout_ms", 100)
      |> Map.put("budget", %{"max_duration_ms" => 100, "max_bytes" => 16_777_216})

    dispatcher = fn validated ->
      remaining = validated.deadline_monotonic - System.monotonic_time(:millisecond)
      if remaining > 2, do: Process.sleep(remaining - 2)
      Protocol.success(validated, %{"payload" => String.duplicate("x", 8_000_000)})
    end

    assert {output, 124} = CLI.invoke_json(Jason.encode!(request), dispatcher)
    decoded = Jason.decode!(output)
    assert decoded["status"] == "timeout"
    assert decoded["cleanup"]["status"] == "uncertain"
    assert decoded["uncertainty"] != []
  end

  property "arbitrary JSON-sized binaries never raise" do
    check all(input <- binary(max_length: 2_048)) do
      assert {output, status} = CLI.invoke_json(input, CLIDispatcher)
      assert is_binary(output)
      assert status in [0, 1, 3, 64, 124, 130]
      assert {:ok, _decoded} = Jason.decode(output)
    end
  end

  property "the direct term boundary contains arbitrary terms" do
    check all(input <- term()) do
      case CLI.invoke(input, CLIDispatcher) do
        %Result{} -> :ok
        {:error, %Error{}} -> :ok
        other -> flunk("unexpected direct outcome: #{inspect(other)}")
      end
    end
  end

  test "the executable provides discovery and processes stdin in a real subprocess", context do
    {discovery, "", 0} = cli(context, ["--discover"])
    assert Jason.decode!(discovery)["schema"] == "insider.cli.discovery/v1"

    {output, "", 3} = cli(context, ["--json"], Jason.encode!(@request))
    assert Jason.decode!(output)["status"] == "unsupported"

    {error, "", 64} = cli(context, ["--json"], "not-json")
    assert Jason.decode!(error)["error"]["code"] == "invalid_json"

    ndjson = Jason.encode!(@request) <> "\n\n" <> Jason.encode!(@request)
    {stream, "", 0} = cli(context, ["--ndjson"], ndjson)
    assert stream |> String.split("\n", trim: true) |> length() == 3

    oversized = String.duplicate("x", 16_777_217) <> "\n" <> Jason.encode!(@request)
    {recovered, "", 0} = cli(context, ["--ndjson"], oversized)
    recovered_frames = recovered |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(recovered_frames, & &1["status"]) == ["invalid_input", "unsupported"]
  end

  defp cli(context, args, input \\ "") do
    stdin = Path.join(context.subprocess_directory, "stdin")
    stdout = Path.join(context.subprocess_directory, "stdout")
    stderr = Path.join(context.subprocess_directory, "stderr")
    File.write!(stdin, input)

    command =
      ~S["$INSIDER_ESCRIPT" "$INSIDER_CLI_ARG" < "$INSIDER_STDIN" > "$INSIDER_STDOUT" 2> "$INSIDER_STDERR"]

    {_shell_output, status} =
      System.cmd("sh", ["-c", command],
        env: [
          {"INSIDER_ESCRIPT", context.escript},
          {"INSIDER_CLI_ARG", List.first(args)},
          {"INSIDER_STDIN", stdin},
          {"INSIDER_STDOUT", stdout},
          {"INSIDER_STDERR", stderr}
        ]
      )

    {File.read!(stdout), File.read!(stderr), status}
  end

  defp nested_map(0), do: %{"leaf" => true}
  defp nested_map(depth), do: %{"next" => nested_map(depth - 1)}

  defp stream_io(chunks) do
    key = {__MODULE__, make_ref()}
    Process.put(key, chunks)
    owner = self()

    reader = fn ->
      case Process.get(key) do
        [chunk | rest] ->
          Process.put(key, rest)
          chunk

        [] ->
          :eof
      end
    end

    writer = fn output ->
      send(owner, {:stream_write, output})
      :ok
    end

    {reader, writer}
  end
end
