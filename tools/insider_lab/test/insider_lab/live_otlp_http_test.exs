defmodule Insider.Lab.LiveOtlpHttpTest do
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.Otlp.Http

  # One loopback connection per test: the client side writes raw bytes, the
  # server side is read with `Http.read/2` and answered with `Http.respond/4`.
  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen, 1_000)
    :gen_tcp.close(listen)
    on_exit(fn -> :gen_tcp.close(client) end)
    {:ok, client: client, server: server}
  end

  defp request(headers, body, path \\ "/v1/traces", method \\ "POST") do
    [
      "#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "\r\n",
      body
    ]
  end

  defp exchange(context, bytes, timeout_ms \\ 1_000) do
    :ok = :gen_tcp.send(context.client, bytes)
    Http.read(context.server, timeout_ms)
  end

  defp response(%{client: client}) do
    {:ok, bytes} = recv_all(client, "")
    [head, body] = String.split(bytes, "\r\n\r\n", parts: 2)
    [status_line | headers] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _reason] = String.split(status_line, " ")

    headers =
      Map.new(headers, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {name, value}
      end)

    {String.to_integer(status), headers, body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, bytes} -> recv_all(socket, acc <> bytes)
      {:error, :closed} -> {:ok, acc}
    end
  end

  test "reads a protobuf export with its exact body", context do
    body = <<10, 0>>
    headers = [{"Content-Type", "application/x-protobuf"}, {"Content-Length", "2"}]
    assert exchange(context, request(headers, body)) == {:ok, :protobuf, body}
  end

  test "reads a JSON export, ignoring media type parameters and header case", context do
    headers = [{"content-type", "Application/JSON; charset=utf-8"}, {"content-length", "2"}]
    assert exchange(context, request(headers, "{}")) == {:ok, :json, "{}"}
  end

  test "an empty body is an empty export", context do
    headers = [{"content-type", "application/x-protobuf"}, {"content-length", "0"}]
    assert exchange(context, request(headers, "")) == {:ok, :protobuf, ""}
  end

  test "decompresses a gzip body", context do
    body = :zlib.gzip("{\"resourceSpans\":[]}")

    headers = [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"content-length", byte_size(body)}
    ]

    assert exchange(context, request(headers, body)) == {:ok, :json, "{\"resourceSpans\":[]}"}
  end

  test "refuses a gzip body that inflates past the bound", context do
    body = :zlib.gzip(:binary.copy(<<0>>, Http.max_body_bytes() + 1))

    headers = [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"content-length", byte_size(body)}
    ]

    assert exchange(context, request(headers, body)) == {:error, 413, "body_too_large"}
  end

  test "refuses truncated or corrupt gzip", context do
    body = binary_part(:zlib.gzip(:crypto.strong_rand_bytes(4_096)), 0, 100)

    headers = [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"content-length", byte_size(body)}
    ]

    assert exchange(context, request(headers, body)) == {:error, 400, "malformed_gzip"}
  end

  test "refuses a declared body past the bound before reading it", context do
    headers = [
      {"content-type", "application/x-protobuf"},
      {"content-length", Http.max_body_bytes() + 1}
    ]

    assert exchange(context, request(headers, "")) == {:error, 413, "body_too_large"}
  end

  for {name, headers, path, method, expected} <- [
        {"another path", [{"content-length", "0"}], "/v1/metrics", "POST", {404, "not_found"}},
        {"another method", [], "/v1/traces", "GET", {405, "method_not_allowed"}},
        {"no content type", [{"content-length", "0"}], "/v1/traces", "POST",
         {415, "unsupported_media_type"}},
        {"another content type", [{"content-type", "text/plain"}, {"content-length", "0"}],
         "/v1/traces", "POST", {415, "unsupported_media_type"}},
        {"another content encoding",
         [
           {"content-type", "application/json"},
           {"content-encoding", "br"},
           {"content-length", "0"}
         ], "/v1/traces", "POST", {415, "unsupported_content_encoding"}},
        {"a chunked body",
         [{"content-type", "application/json"}, {"transfer-encoding", "chunked"}], "/v1/traces",
         "POST", {411, "length_required"}},
        {"no content length", [{"content-type", "application/json"}], "/v1/traces", "POST",
         {411, "length_required"}},
        {"a malformed content length",
         [{"content-type", "application/json"}, {"content-length", "1x"}], "/v1/traces", "POST",
         {400, "malformed_request"}}
      ] do
    test "refuses #{name}", context do
      {status, reason} = unquote(Macro.escape(expected))

      assert exchange(context, request(unquote(headers), "", unquote(path), unquote(method))) ==
               {:error, status, reason}
    end
  end

  test "refuses more than 64 headers", context do
    headers = for index <- 1..65, do: {"x-h#{index}", "v"}
    assert exchange(context, request(headers, "")) == {:error, 400, "too_many_headers"}
  end

  test "refuses a request line longer than the line bound", context do
    assert {:error, 400, "malformed_request"} =
             exchange(context, request([], "", "/" <> String.duplicate("a", 9_000)))
  end

  test "refuses a request that is not HTTP", context do
    assert exchange(context, "\x16\x03\x01 not http\r\n\r\n") ==
             {:error, 400, "malformed_request"}
  end

  test "times out a client that stops sending", context do
    headers = [{"content-type", "application/json"}, {"content-length", "10"}]
    assert exchange(context, request(headers, "{"), 100) == {:error, 408, "timeout"}
  end

  test "times out a client that never finishes its headers", context do
    assert exchange(context, "POST /v1/traces HTTP/1.1\r\n", 100) == {:error, 408, "timeout"}
  end

  describe "responses" do
    test "a full success is an empty ExportTraceServiceResponse and closes the connection",
         context do
      :ok = Http.respond(context.server, 200, :protobuf, Http.export_response(:protobuf, 0, ""))

      assert {200, headers, ""} = response(context)
      assert headers["content-type"] == "application/x-protobuf"
      assert headers["content-length"] == "0"
      assert headers["connection"] == "close"
    end

    test "a partial success names the rejected spans, in protobuf", context do
      body = Http.export_response(:protobuf, 300, "rejected")
      :ok = Http.respond(context.server, 200, :protobuf, body)

      # partial_success (1) { rejected_spans (1) = 300, error_message (2) = "rejected" }
      assert {200, _headers, <<0x0A, 13, 0x08, 0xAC, 0x02, 0x12, 8, "rejected">>} =
               response(context)
    end

    test "a partial success names the rejected spans, in JSON", context do
      :ok = Http.respond(context.server, 200, :json, Http.export_response(:json, 2, "why"))
      assert {200, %{"content-type" => "application/json"}, body} = response(context)

      assert Jason.decode!(body) == %{
               "partialSuccess" => %{"rejectedSpans" => 2, "errorMessage" => "why"}
             }
    end

    test "a full JSON success is an empty object", context do
      :ok = Http.respond(context.server, 200, :json, Http.export_response(:json, 0, ""))
      assert {200, _headers, "{}"} = response(context)
    end

    test "a refusal is plain text with its reason", context do
      :ok = Http.respond(context.server, 415, :text, "unsupported_media_type")

      assert {415, %{"content-type" => "text/plain; charset=utf-8"}, "unsupported_media_type"} =
               response(context)
    end
  end
end
