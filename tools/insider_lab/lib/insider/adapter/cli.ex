defmodule Insider.Adapter.CLI do
  @moduledoc """
  Bounded Erlang-term, JSON, and NDJSON transport over `Insider.Protocol`.

  This module deliberately does not implement runtime operations. Hosts inject
  an `Insider.Adapter.CLI.Dispatcher`; the standalone executable uses a closed
  dispatcher that returns `unsupported`.
  """

  alias Insider.Adapter.CLI.UnavailableDispatcher
  alias Insider.Adapter.CLI.Wire
  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Protocol
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result

  @max_transport_bytes 16_777_216
  @max_frames 1_000
  @max_json_depth 8
  @max_json_width 1_000
  @decode_timeout_ms 5_000
  @decode_max_heap_words 16_777_216
  @dispatcher_max_heap_words 16_777_216
  @terminal_error_reserve_bytes 1_024

  @exit_ok 0
  @exit_error 1
  @exit_unsupported 3
  @exit_input 64
  @exit_catastrophic 70
  @exit_timeout 124
  @exit_cancelled 130

  # The escript's own help: `insider-lab` alone, `--help`, `-h` or `help`.
  # The observer's help is `insider-lab live --help`.
  @help """
  insider-lab: the command-line observer for Insider. It attaches to a running
  BEAM node on this machine over Erlang distribution and reads what the node
  is doing: its events, digests, traces and processes.

  Usage:
    insider-lab live OPERATION [--node NAME@HOST --cookie-file PATH] [OPTIONS]
        Observe a node. insider-lab live --help lists every operation.
    insider-lab --discover
        Print the protocol's discovery document (insider.cli.discovery/v1).
    insider-lab --json
        Read one insider.request/v1 JSON request on stdin and print its result.
    insider-lab --ndjson
        Read one request per line on stdin and print one result per line.
    insider-lab --help
        Print this text.

  --json and --ndjson answer runtime.capabilities and report every other
  protocol operation unsupported: this executable runs no operations itself.

  Next:
    insider-lab live --help
    N=(--node "my_app@$(hostname -s)" --cookie-file "$HOME/.my_app.cookie")
    insider-lab live capabilities "${N[@]}" --load   # first contact
  """

  @request_fields [
    "budget",
    "caller",
    "capability",
    "environment",
    "idempotency_key",
    "operation",
    "params",
    "protocol",
    "redaction_policy",
    "request_id",
    "schema",
    "target",
    "timeout_ms"
  ]

  @type dispatcher :: module() | (Request.t() -> Result.t())

  @spec discovery() :: map()
  def discovery do
    %{
      "schema" => "insider.cli.discovery/v1",
      "protocol" => Protocol.version(),
      "request_schema" => "insider.request/v1",
      "result_schema" => "insider.result/v1",
      "operations" => operation_discovery(),
      "transports" => ["erlang", "json", "ndjson"],
      "framing" => %{"json" => "single", "ndjson" => "one_line_per_request"},
      "request_fields" => %{
        "required" => ["schema", "protocol", "operation", "request_id"],
        "optional" => @request_fields -- ["schema", "protocol", "operation", "request_id"]
      },
      "limits" => %{
        "buffered_max_input_bytes" => @max_transport_bytes,
        "buffered_max_output_bytes" => @max_transport_bytes,
        "decoder_max_heap_words" => @decode_max_heap_words,
        "decoder_timeout_ms" => @decode_timeout_ms,
        "max_dispatcher_heap_words" => @dispatcher_max_heap_words,
        "max_frames" => @max_frames,
        "max_input_bytes" => @max_transport_bytes,
        "max_json_depth" => @max_json_depth,
        "max_json_width" => @max_json_width,
        "max_output_bytes" => @max_transport_bytes,
        "max_stream_output_bytes" =>
          @max_frames * (@max_transport_bytes + 1) + @terminal_error_reserve_bytes,
        "stream_terminal_error_reserve_bytes" => @terminal_error_reserve_bytes
      },
      "default_dispatcher" => "adapter_discovery_only",
      "exit_statuses" => %{
        "ok" => @exit_ok,
        "error" => @exit_error,
        "invalid_input" => @exit_input,
        "timeout" => @exit_timeout,
        "cancelled" => @exit_cancelled,
        "catastrophic" => @exit_catastrophic,
        "unsupported" => @exit_unsupported
      }
    }
  end

  @spec capabilities() :: map()
  def capabilities do
    discovery()
    |> Map.put("schema", "insider.capabilities/v1")
  end

  defp operation_discovery do
    {:ok, context} =
      Context.new(
        environment: :development,
        actor: "insider-cli-discovery",
        features: %{
          "runtime.capabilities" => %{
            available: true,
            provider: "insider.adapter.cli",
            isolation: :read_only
          }
        },
        deployment_limits: %{
          max_duration_ms: Budget.maximum(:max_duration_ms),
          max_events: Budget.maximum(:max_events),
          max_bytes: Budget.maximum(:max_bytes),
          max_targets: 1
        }
      )

    capabilities = Map.new(Policy.capabilities(context), &{&1.operation, &1})
    Enum.map(Protocol.operations(), &Map.fetch!(capabilities, &1))
  end

  @doc "Invokes one already-decoded request or one string-keyed request map."
  @spec invoke(Request.t() | map(), dispatcher()) :: Result.t() | {:error, Error.t()}
  def invoke(input, dispatcher \\ UnavailableDispatcher)

  def invoke(%Request{} = request, dispatcher) do
    if Request.valid?(request),
      do: dispatch(request, dispatcher, :term),
      else: {:error, Error.new(:invalid_request, "invalid decoded request")}
  end

  def invoke(input, dispatcher) do
    with {:ok, request} <- decode_input(input) do
      dispatch(request, dispatcher, :term)
    end
  end

  @spec invoke_json(binary(), dispatcher()) :: {binary(), non_neg_integer()}
  def invoke_json(bytes, dispatcher \\ UnavailableDispatcher) when is_binary(bytes) do
    if byte_size(bytes) <= @max_transport_bytes do
      case decode_json(bytes) do
        {:ok, payload} ->
          case decode_input(payload) do
            {:ok, request} -> request |> dispatch(dispatcher, :json) |> encode_outcome(request)
            {:error, %Error{} = error} -> encode_outcome({:error, error}, nil)
          end

        :error ->
          transport_error("invalid_json")
      end
    else
      transport_error("input_limit_exceeded")
    end
  end

  @spec invoke_ndjson(binary(), dispatcher()) :: {binary(), non_neg_integer()}
  def invoke_ndjson(bytes, dispatcher \\ UnavailableDispatcher) when is_binary(bytes) do
    if byte_size(bytes) > @max_transport_bytes do
      transport_error("input_limit_exceeded")
    else
      frames = ndjson_frames(bytes)

      if length(frames) > @max_frames do
        transport_error("frame_limit_exceeded")
      else
        encode_frames(frames, dispatcher)
      end
    end
  end

  @doc false
  @spec main([String.t()]) :: no_return()
  def main(["live" | args]) do
    System.halt(
      Insider.Lab.Live.CLI.run(args, &Insider.Lab.Output.write/1, invocation: "insider-lab live")
    )
  end

  def main(args) do
    ndjson_reader = fn -> IO.binread(:stdio, 4_096) end
    json_reader = fn maximum -> IO.binread(:stdio, maximum) end
    System.halt(run_cli(args, ndjson_reader, json_reader, &Insider.Lab.Output.write/1))
  end

  @doc false
  @spec run_cli([String.t()], (-> term()), (pos_integer() -> term()), (iodata() -> term())) ::
          non_neg_integer()
  def run_cli(["--ndjson"], ndjson_reader, _json_reader, writer) do
    run_ndjson_stream(ndjson_reader, writer)
  end

  def run_cli(args, _ndjson_reader, json_reader, writer) do
    {output, status} = run_once(args, json_reader)
    if safe_write(writer, output) == :ok, do: status, else: @exit_catastrophic
  end

  @doc false
  @spec run_once([String.t()], (pos_integer() -> binary() | :eof | {:error, term()})) ::
          {binary(), non_neg_integer()}
  def run_once(arguments, _reader) when arguments in [[], ["--help"], ["-h"], ["help"]],
    do: {@help, @exit_ok}

  def run_once(["--discover"], _reader) do
    {:ok, bytes} = Wire.encode(discovery())
    {bytes <> "\n", @exit_ok}
  end

  def run_once(["--json"], reader) do
    case reader.(@max_transport_bytes + 1) do
      data when is_binary(data) -> invoke_json(data)
      :eof -> transport_error("empty_input")
      {:error, _reason} -> transport_error("input_failed")
    end
  end

  def run_once(_args, _reader) do
    "usage"
    |> adapter_error()
    |> Map.put("help", "insider-lab --help")
    |> bounded_encode(@exit_input)
  end

  defp dispatch(request, dispatcher, projection),
    do: execute_bounded(dispatcher, request, projection)

  defp execute(dispatcher, request) when is_function(dispatcher, 1), do: dispatcher.(request)
  defp execute(dispatcher, request) when is_atom(dispatcher), do: dispatcher.dispatch(request)

  defp execute_bounded(dispatcher, request, projection) do
    remaining = request.deadline_monotonic - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Protocol.timeout(request, cleanup: %{status: :not_required})
    else
      execute_before_deadline(dispatcher, request, remaining, projection)
    end
  end

  defp execute_before_deadline(dispatcher, request, remaining, projection) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {ref, safe_execute(dispatcher, request, projection)}) end,
        [
          :monitor,
          {:max_heap_size, %{size: @dispatcher_max_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        if deadline_open?(request), do: result, else: timed_out(request)

      {^ref, {:error, message}} ->
        Process.demonitor(monitor, [:flush])

        if deadline_open?(request),
          do: dispatch_failure(request, message),
          else: timed_out(request)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        if deadline_open?(request),
          do: dispatch_failure(request, "dispatcher terminated"),
          else: timed_out(request)
    after
      remaining ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        timed_out(request)
    end
  end

  defp deadline_open?(request),
    do: System.monotonic_time(:millisecond) < request.deadline_monotonic

  defp timed_out(request) do
    Protocol.timeout(request,
      cleanup: %{status: :uncertain},
      uncertainty: ["dispatcher worker stopped; escaped runtime effects are unknown"]
    )
  end

  defp safe_execute(dispatcher, request, projection) do
    case execute(dispatcher, request) do
      %Result{} = result ->
        if correlated?(result, request) do
          {:ok, project_result(result, request, projection)}
        else
          {:error, "dispatcher returned an invalid protocol result"}
        end

      _other ->
        {:error, "dispatcher returned an invalid protocol result"}
    end
  rescue
    _error -> {:error, "dispatcher raised"}
  catch
    _kind, _reason -> {:error, "dispatcher terminated"}
  end

  defp project_result(result, _request, :term), do: result
  defp project_result(result, request, :json), do: encode_result_outcome(result, request)

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp correlated?(%Result{} = result, request) do
    result.protocol == request.protocol and result.request_id == request.request_id and
      result.operation == request.operation and result.target == request.target and
      Result.valid?(result, request)
  end

  defp dispatch_failure(request, message) do
    Protocol.failure(request, Error.new(:operation_failed, message),
      cleanup: %{status: :uncertain},
      uncertainty: ["dispatcher started; escaped runtime effects are unknown"]
    )
  end

  defp encode_outcome({:error, %Error{} = error}, _request) do
    error
    |> adapter_error()
    |> bounded_encode(@exit_input)
  end

  defp encode_outcome({:encoded, output, status}, _request), do: {output, status}

  defp encode_outcome(%Result{} = result, request) do
    encode_result_outcome(result, request)
    |> case do
      {:encoded, output, status} -> {output, status}
    end
  end

  defp encode_result_outcome(%Result{} = result, request) do
    case Wire.encode_result(result) do
      {:ok, bytes}
      when byte_size(bytes) <= @max_transport_bytes and
             byte_size(bytes) <= result.effective_limits.max_bytes ->
        {:encoded, bytes <> "\n", exit_status(result.status)}

      _error ->
        {output, status} = output_failure(request, "dispatcher result is not portable JSON")
        {:encoded, output, status}
    end
  end

  defp encode_frames([], _dispatcher), do: {"", @exit_ok}

  defp encode_frames(frames, dispatcher) do
    per_frame_budget = div(@max_transport_bytes, length(frames))

    output =
      Enum.reduce(frames, [], fn frame, output ->
        {encoded, _status} = invoke_frame(frame, dispatcher)

        selected =
          if byte_size(encoded) <= per_frame_budget,
            do: encoded,
            else: output_limit_frame(encoded)

        [selected | output]
      end)

    {output |> Enum.reverse() |> IO.iodata_to_binary(), @exit_ok}
  end

  defp output_limit_frame(frame) do
    {:ok, %{"schema" => "insider.result/v1"} = result} = Jason.decode(frame)

    limited = %{
      "schema" => "insider.result/v1",
      "protocol" => result["protocol"],
      "request_id" => result["request_id"],
      "operation" => result["operation"],
      "status" => "error",
      "value" => nil,
      "error" => %{
        "code" => "operation_failed",
        "message" => "NDJSON aggregate output limit exceeded",
        "details" => %{},
        "retryable" => false
      },
      "effects" => [],
      "stdout" => [],
      "stderr" => [],
      "logger_events" => [],
      "compiler_events" => [],
      "trace_events" => [],
      "redactions" => [],
      "warnings" => [],
      "truncated" => %{"reason" => "transport_output_limit", "dropped" => 1},
      "dropped" => %{"dispatcher_result_payloads" => 1},
      "duration_us" => 0,
      "requested_limits" => result["requested_limits"],
      "effective_limits" => result["effective_limits"],
      "consumption" => %{},
      "target" => result["target"],
      "target_fingerprint" => nil,
      "code_fingerprint" => nil,
      "dependency_fingerprint" => nil,
      "runtime_fingerprint" => nil,
      "policy_fingerprint" => nil,
      "cleanup" => %{"status" => "uncertain"},
      "confidence" => "certain",
      "uncertainty" => ["dispatcher result exceeded buffered output share; effects omitted"]
    }

    {:ok, bytes} = Wire.encode(limited)
    bytes <> "\n"
  end

  defp output_failure(request, message) do
    result =
      Protocol.failure(request, Error.new(:operation_failed, message),
        cleanup: %{status: :uncertain},
        uncertainty: ["dispatcher completed; serialized runtime effects are unavailable"]
      )

    case Wire.encode_result(result) do
      {:ok, bytes} -> {bytes <> "\n", @exit_error}
    end
  end

  defp ndjson_frames(bytes) do
    frames = String.split(bytes, "\n")
    if List.last(frames) == "", do: List.delete_at(frames, -1), else: frames
  end

  defp invoke_frame(frame, dispatcher) do
    invoke_json(frame, dispatcher)
  end

  defp validate_envelope_fields(input) when is_map(input) and not is_struct(input) do
    keys = Map.keys(input)

    if Enum.all?(keys, &is_binary/1) and keys -- @request_fields == [] do
      :ok
    else
      {:error,
       Error.new(:invalid_request, "request envelope contains unknown fields", %{
         field_count: map_size(input)
       })}
    end
  end

  defp validate_envelope_fields(input) do
    {:error,
     Error.new(:invalid_request, "request envelope must be an object", %{
       received: Insider.Protocol.Value.summary(input)
     })}
  end

  defp decode_input(input) do
    with :ok <- validate_envelope_fields(input), do: Protocol.decode_request(input)
  end

  defp decode_json(bytes) do
    owner = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + @decode_timeout_ms

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {ref, decode_json_isolated(bytes)}) end,
        [
          :monitor,
          {:max_heap_size, %{size: @decode_max_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        if System.monotonic_time(:millisecond) < deadline, do: result, else: :error

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :error
    after
      @decode_timeout_ms ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        :error
    end
  end

  defp decode_json_isolated(bytes) do
    with {:ok, value} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, value} <- normalize_json(value, -1) do
      {:ok, value}
    else
      _error -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize_json(_value, depth) when depth > @max_json_depth, do: :error

  defp normalize_json(%Jason.OrderedObject{values: entries}, depth) do
    keys = Enum.map(entries, &elem(&1, 0))

    if length(keys) <= @max_json_width and length(keys) == MapSet.size(MapSet.new(keys)) do
      Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, output} ->
        case normalize_json(value, depth + 1) do
          {:ok, value} -> {:cont, {:ok, Map.put(output, key, value)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp normalize_json(value, depth) when is_list(value) do
    if length(value) <= @max_json_width do
      case Enum.reduce_while(value, {:ok, []}, fn item, {:ok, output} ->
             case normalize_json(item, depth + 1) do
               {:ok, item} -> {:cont, {:ok, [item | output]}}
               :error -> {:halt, :error}
             end
           end) do
        {:ok, output} -> {:ok, Enum.reverse(output)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp normalize_json(value, _depth)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_integer(value) or
              is_float(value),
       do: {:ok, value}

  @doc false
  @spec run_ndjson_stream(
          (-> binary() | :eof | {:error, term()}),
          (binary() -> term()),
          dispatcher()
        ) ::
          non_neg_integer()
  def run_ndjson_stream(reader, writer, dispatcher \\ UnavailableDispatcher)
      when is_function(reader, 0) and is_function(writer, 1) do
    try do
      case stream_chunks(reader, writer, dispatcher) do
        :ok -> @exit_ok
        :frame_limit -> @exit_input
        :input_failed -> @exit_catastrophic
      end
    rescue
      _error -> @exit_catastrophic
    catch
      _kind, _reason -> @exit_catastrophic
    end
  end

  defp stream_chunks(
         reader,
         writer,
         dispatcher,
         chunks \\ [],
         size \\ 0,
         oversized \\ false,
         count \\ 0
       ) do
    case reader.() do
      data when is_binary(data) ->
        consume_chunk(data, reader, writer, dispatcher, chunks, size, oversized, count)

      :eof ->
        finish_stream(writer, dispatcher, chunks, size, oversized, count)

      {:error, _reason} ->
        :input_failed
    end
  end

  defp consume_chunk(data, reader, writer, dispatcher, chunks, size, oversized, count) do
    case :binary.match(data, "\n") do
      {position, 1} ->
        segment = binary_part(data, 0, position)
        rest = binary_part(data, position + 1, byte_size(data) - position - 1)
        frame_size = size + byte_size(segment)
        too_large = oversized or frame_size > @max_transport_bytes

        frame =
          if too_large,
            do: "",
            else: [segment | chunks] |> Enum.reverse() |> IO.iodata_to_binary()

        with {:ok, count} <- emit_stream_frame(frame, too_large, count, writer, dispatcher) do
          consume_chunk(rest, reader, writer, dispatcher, [], 0, false, count)
        end

      :nomatch when oversized or size + byte_size(data) > @max_transport_bytes ->
        stream_chunks(reader, writer, dispatcher, [], 0, true, count)

      :nomatch ->
        stream_chunks(
          reader,
          writer,
          dispatcher,
          [data | chunks],
          size + byte_size(data),
          false,
          count
        )
    end
  end

  defp finish_stream(_writer, _dispatcher, [], 0, false, _count), do: :ok

  defp finish_stream(writer, dispatcher, chunks, _size, oversized, count) do
    frame = if oversized, do: "", else: chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case emit_stream_frame(frame, oversized, count, writer, dispatcher) do
      {:ok, _count} -> :ok
      :frame_limit -> :frame_limit
      :input_failed -> :input_failed
    end
  end

  defp emit_stream_frame(_frame, _oversized, count, writer, _dispatcher)
       when count >= @max_frames do
    {output, _status} = transport_error("frame_limit_exceeded")
    if safe_write(writer, output) == :ok, do: :frame_limit, else: :input_failed
  end

  defp emit_stream_frame(frame, oversized, count, writer, dispatcher) do
    {output, _status} =
      if oversized or byte_size(frame) > @max_transport_bytes,
        do: transport_error("input_limit_exceeded"),
        else: invoke_json(frame, dispatcher)

    if safe_write(writer, output) == :ok, do: {:ok, count + 1}, else: :input_failed
  end

  defp safe_write(writer, output) do
    case writer.(output) do
      :ok -> :ok
      {:error, _reason} -> :error
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp transport_error(code), do: bounded_encode(adapter_error(code), @exit_input)

  defp adapter_error(%Error{} = error) do
    %{
      "schema" => "insider.cli.error/v1",
      "status" => "invalid_input",
      "error" => %{
        "code" => Atom.to_string(error.code),
        "message" => error.message,
        "details" => error.details,
        "retryable" => error.retryable
      }
    }
  end

  defp adapter_error(code) do
    %{
      "schema" => "insider.cli.error/v1",
      "status" => "invalid_input",
      "error" => %{"code" => code}
    }
  end

  defp bounded_encode(map, status) do
    case Wire.encode(map) do
      {:ok, bytes} when byte_size(bytes) <= @max_transport_bytes ->
        {bytes <> "\n", status}

      _error ->
        {"{\"error\":{\"code\":\"encoding_failed\"},\"schema\":\"insider.cli.error/v1\",\"status\":\"invalid_input\"}\n",
         @exit_input}
    end
  end

  defp exit_status(:ok), do: @exit_ok
  defp exit_status(:error), do: @exit_error
  defp exit_status(:timeout), do: @exit_timeout
  defp exit_status(:cancelled), do: @exit_cancelled
  defp exit_status(:unsupported), do: @exit_unsupported
end
