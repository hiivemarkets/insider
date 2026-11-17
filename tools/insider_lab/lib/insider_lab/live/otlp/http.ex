defmodule Insider.Lab.Live.Otlp.Http do
  @moduledoc false

  # Just enough HTTP/1.1 for one OTLP/HTTP trace export per connection:
  # `POST /v1/traces` with a `Content-Length` body of `application/x-protobuf`
  # or `application/json`, optionally gzip-compressed. Every read is bounded
  # by a per-request deadline, the request line and each header by
  # `@max_line_bytes`, the header count by `@max_headers`, and the body,
  # before and after decompression, by `@max_body_bytes`. Every response
  # closes the connection.

  @max_body_bytes 4 * 1024 * 1024
  @max_headers 64
  @max_line_bytes 8_192

  @reasons %{
    200 => "OK",
    400 => "Bad Request",
    404 => "Not Found",
    405 => "Method Not Allowed",
    408 => "Request Timeout",
    411 => "Length Required",
    413 => "Content Too Large",
    415 => "Unsupported Media Type",
    503 => "Service Unavailable"
  }

  @type format :: :protobuf | :json
  @type refusal :: {:error, 400..599, String.t()}

  @doc "The largest accepted body, compressed or not."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Reads one request from `socket` within `timeout_ms`: `{:ok, format, body}`
  with the decompressed body, or `{:error, status, reason}` to answer with.
  """
  @spec read(:gen_tcp.socket(), pos_integer()) :: {:ok, format(), binary()} | refusal()
  def read(socket, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with :ok <- :inet.setopts(socket, packet: :http_bin, packet_size: @max_line_bytes),
         {:ok, method, path} <- request_line(socket, deadline),
         {:ok, headers} <- headers(socket, deadline, %{}, 0),
         :ok <- route(method, path),
         {:ok, format} <- format(headers["content-type"]),
         {:ok, length} <- content_length(headers),
         {:ok, body} <- body(socket, length, deadline),
         {:ok, body} <- decode_content(headers["content-encoding"], body) do
      {:ok, format, body}
    else
      {:error, status, reason} -> {:error, status, reason}
      {:error, _socket_reason} -> {:error, 400, "malformed_request"}
    end
  end

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> left
      _spent -> 0
    end
  end

  defp request_line(socket, deadline) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} -> {:ok, method, path}
      {:error, :timeout} -> {:error, 408, "timeout"}
      _other -> {:error, 400, "malformed_request"}
    end
  end

  defp headers(_socket, _deadline, _headers, count) when count > @max_headers,
    do: {:error, 400, "too_many_headers"}

  defp headers(socket, deadline, headers, count) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, {:http_header, _number, name, _reserved, value}} ->
        key = name |> to_string() |> String.downcase()
        headers(socket, deadline, Map.put(headers, key, value), count + 1)

      {:ok, :http_eoh} ->
        {:ok, headers}

      {:error, :timeout} ->
        {:error, 408, "timeout"}

      _other ->
        {:error, 400, "malformed_request"}
    end
  end

  defp route(:POST, "/v1/traces"), do: :ok
  defp route(_method, "/v1/traces"), do: {:error, 405, "method_not_allowed"}
  defp route(_method, _path), do: {:error, 404, "not_found"}

  defp format(nil), do: {:error, 415, "unsupported_media_type"}

  defp format(content_type) do
    case content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase() do
      "application/x-protobuf" -> {:ok, :protobuf}
      "application/protobuf" -> {:ok, :protobuf}
      "application/json" -> {:ok, :json}
      _other -> {:error, 415, "unsupported_media_type"}
    end
  end

  defp content_length(%{"transfer-encoding" => _chunked}), do: {:error, 411, "length_required"}

  defp content_length(%{"content-length" => text}) do
    case Integer.parse(text) do
      {length, ""} when length > @max_body_bytes -> {:error, 413, "body_too_large"}
      {length, ""} when length >= 0 -> {:ok, length}
      _malformed -> {:error, 400, "malformed_request"}
    end
  end

  defp content_length(_headers), do: {:error, 411, "length_required"}

  defp body(_socket, 0, _deadline), do: {:ok, ""}

  defp body(socket, length, deadline) do
    :ok = :inet.setopts(socket, packet: :raw)

    case :gen_tcp.recv(socket, length, remaining(deadline)) do
      {:ok, body} -> {:ok, body}
      {:error, :timeout} -> {:error, 408, "timeout"}
      {:error, _closed} -> {:error, 400, "malformed_request"}
    end
  end

  defp decode_content(encoding, body) when encoding in [nil, "identity"], do: {:ok, body}

  defp decode_content(encoding, body) do
    if String.downcase(encoding) == "gzip",
      do: gunzip(body),
      else: {:error, 415, "unsupported_content_encoding"}
  end

  # `:zlib.safeInflate/2` yields at most one chunk at a time, so the inflated
  # size is checked before the next chunk is produced.
  defp gunzip(body) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)
      inflate(stream, :zlib.safeInflate(stream, body), [], 0)
    rescue
      ErlangError -> {:error, 400, "malformed_gzip"}
    after
      :zlib.close(stream)
    end
  end

  defp inflate(stream, {state, output}, acc, size) do
    produced = IO.iodata_length(output)
    size = size + produced

    cond do
      size > @max_body_bytes -> {:error, 413, "body_too_large"}
      # `inflateEnd/1` raises unless the whole gzip member, trailer
      # included, was read: a truncated body is refused, not half-used.
      state == :finished -> finished(stream, [acc, output])
      produced == 0 -> {:error, 400, "malformed_gzip"}
      true -> inflate(stream, :zlib.safeInflate(stream, []), [acc, output], size)
    end
  end

  defp finished(stream, output) do
    :ok = :zlib.inflateEnd(stream)
    {:ok, IO.iodata_to_binary(output)}
  end

  @doc """
  The `ExportTraceServiceResponse` for an accepted export: empty when every
  span was accepted, otherwise with `partial_success` naming the rejected
  count and why.
  """
  @spec export_response(format(), non_neg_integer(), String.t()) :: iodata()
  def export_response(:json, 0, _message), do: "{}"

  def export_response(:json, rejected, message),
    do:
      Jason.encode_to_iodata!(%{
        "partialSuccess" => %{"rejectedSpans" => rejected, "errorMessage" => message}
      })

  def export_response(:protobuf, 0, _message), do: ""

  def export_response(:protobuf, rejected, message) do
    partial = [<<0x08>>, varint(rejected), <<0x12>>, varint(byte_size(message)), message]
    [<<0x0A>>, varint(IO.iodata_length(partial)), partial]
  end

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, value::7, varint(Bitwise.bsr(value, 7))::binary>>

  @doc "Writes a response and closes the connection."
  @spec respond(:gen_tcp.socket(), 200..599, format() | :text, iodata()) :: :ok
  def respond(socket, status, format, body) do
    content_type =
      case format do
        :protobuf -> "application/x-protobuf"
        :json -> "application/json"
        :text -> "text/plain; charset=utf-8"
      end

    _sent =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} #{Map.fetch!(@reasons, status)}\r\n",
        "content-type: #{content_type}\r\n",
        "content-length: #{IO.iodata_length(body)}\r\n",
        "connection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
  end
end
