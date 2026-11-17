defmodule Insider.Lab.Live.Chart.Server do
  @moduledoc false

  # The live chart's web server: `GET /TOKEN/` on 127.0.0.1 only, serving
  # the latest page the observer rendered. Read-only, with OTP's `:gen_tcp`
  # and no dependency.
  #
  # - It binds the IPv4 loopback address, on a random port unless one is
  #   given, so only this machine can connect.
  # - The page lives at an unguessable token (32 random bytes, URL-safe
  #   Base64); any other path is 404, so another local process or a web page
  #   that guesses the port finds nothing.
  # - The `Host` header must name the loopback address or `localhost` with
  #   this port (421 otherwise), so a DNS-rebinding page served under
  #   another name cannot read it.
  # - Only GET is served (405 otherwise, with no body). It sends no CORS
  #   header, and a Content-Security-Policy that allows no script and no
  #   framing.
  #
  # The page is in a public ETS table the acceptor owns, so a new page is
  # served from the next request on. One acceptor serves one connection at a
  # time, each bounded by
  # `@request_timeout_ms`, `@max_line_bytes` per line and `@max_headers`
  # headers, and closes it after the response.

  alias Insider.Lab.Live.Chart.Html

  @request_timeout_ms 5_000
  @max_line_bytes 8_192
  @max_headers 64

  @type t :: %{pid: pid(), listen: :gen_tcp.socket(), port: :inet.port_number(), page: :ets.tid()}

  @doc "A new random token for the page's path."
  @spec token() :: String.t()
  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc """
  Listens on 127.0.0.1:`port` (0 for a random port) and serves `page` at
  `/TOKEN/` until `stop/1`.
  """
  @spec start(%{port: :inet.port_number(), token: String.t(), page: iodata()}) ::
          {:ok, t()} | {:error, String.t(), map()}
  def start(%{port: port, token: token, page: page}) do
    case :gen_tcp.listen(port, [
           :binary,
           :inet,
           ip: {127, 0, 0, 1},
           active: false,
           reuseaddr: true,
           backlog: 16
         ]) do
      {:ok, listen} ->
        {:ok, {_address, bound}} = :inet.sockname(listen)
        table = :ets.new(:insider_live_chart_page, [:set, :public, read_concurrency: true])
        true = :ets.insert(table, {:page, IO.iodata_to_binary(page)})
        state = %{token: token, port: bound, page: table}
        pid = spawn(fn -> serve(listen, state) end)
        :ok = :gen_tcp.controlling_process(listen, pid)
        # The acceptor owns the table, so it goes when the server stops.
        true = :ets.give_away(table, pid, nil)
        {:ok, %{pid: pid, listen: listen, port: bound, page: table}}

      {:error, :eaddrinuse} ->
        {:error, "port_unavailable", %{"reason" => "in_use"}}

      {:error, _reason} ->
        {:error, "port_unavailable", %{"reason" => "listen_failed"}}
    end
  end

  @doc "The port the server listens on."
  @spec port(t()) :: :inet.port_number()
  def port(%{port: port}), do: port

  @doc "The address the server listens on."
  @spec address(t()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def address(%{listen: listen}), do: :inet.sockname(listen)

  @doc "Replaces the page served."
  @spec put(t(), iodata()) :: :ok
  def put(%{page: table}, page) do
    true = :ets.insert(table, {:page, IO.iodata_to_binary(page)})
    :ok
  end

  @doc "Stops serving and closes the port."
  @spec stop(t()) :: :ok
  def stop(%{pid: pid, listen: listen}) do
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    end

    _closed = :gen_tcp.close(listen)
    :ok
  end

  ## Acceptor

  defp serve(listen, state) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _result = respond(socket, request(socket), state)
        :gen_tcp.close(socket)
        serve(listen, state)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        serve(listen, state)
    end
  end

  defp request(socket) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    with :ok <- :inet.setopts(socket, packet: :http_bin, packet_size: @max_line_bytes),
         {:ok, method, path} <- request_line(socket, deadline),
         {:ok, headers} <- headers(socket, deadline, %{}, 0) do
      {:ok, method, path, headers}
    end
  end

  defp request_line(socket, deadline) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} -> {:ok, method, path}
      {:error, :timeout} -> {:error, 408}
      _other -> {:error, 400}
    end
  end

  defp headers(_socket, _deadline, _headers, count) when count > @max_headers, do: {:error, 400}

  defp headers(socket, deadline, headers, count) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, {:http_header, _number, name, _reserved, value}} ->
        key = name |> to_string() |> String.downcase()
        headers(socket, deadline, Map.put(headers, key, value), count + 1)

      {:ok, :http_eoh} ->
        {:ok, headers}

      {:error, :timeout} ->
        {:error, 408}

      _other ->
        {:error, 400}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp respond(socket, {:error, status}, _state), do: send_response(socket, status, "")

  defp respond(socket, {:ok, method, path, headers}, state) do
    cond do
      not host?(headers["host"], state.port) -> send_response(socket, 421, "")
      path not in ["/#{state.token}/", "/#{state.token}"] -> send_response(socket, 404, "")
      method != :GET -> send_response(socket, 405, "")
      true -> send_response(socket, 200, :ets.lookup_element(state.page, :page, 2))
    end
  end

  defp host?(host, port) when is_binary(host),
    do: host in ["127.0.0.1:#{port}", "localhost:#{port}"]

  defp host?(_host, _port), do: false

  @reasons %{
    200 => "OK",
    400 => "Bad Request",
    404 => "Not Found",
    405 => "Method Not Allowed",
    408 => "Request Timeout",
    421 => "Misdirected Request"
  }

  defp send_response(socket, status, body) do
    headers = [
      {"content-type", "text/html; charset=utf-8"},
      {"content-length", Integer.to_string(byte_size(body))},
      {"content-security-policy", Html.csp() <> "; frame-ancestors 'none'"},
      {"cache-control", "no-store"},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"},
      {"connection", "close"}
    ]

    headers = if status == 405, do: [{"allow", "GET"} | headers], else: headers

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{Map.fetch!(@reasons, status)}\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ])
  end
end
