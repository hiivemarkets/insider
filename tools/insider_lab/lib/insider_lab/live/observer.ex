defmodule Insider.Lab.Live.Observer do
  @moduledoc false

  # A short-lived hidden observer node. One invocation parses and checks the
  # target, reads the cookie file, turns this VM into a hidden distributed node
  # that never listens, connects to exactly one loopback target, runs the
  # caller's work and stops distribution again. Every remote call is an :erpc
  # call under an explicit timeout.

  import Bitwise

  @name_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @host_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/
  @cookie_pattern ~r/\A[\x21-\x7E]{1,255}\z/
  @max_cookie_file_bytes 1_024
  @resolve_timeout_ms 2_000

  @type failure :: {:error, String.t(), map()}
  @type target :: %{
          required(:text) => String.t(),
          required(:name) => String.t(),
          required(:host) => String.t(),
          required(:name_domain) => :shortnames | :longnames
        }

  @doc false
  @spec parse_target(String.t()) :: {:ok, target()} | failure()
  def parse_target(text) when is_binary(text) do
    with [name, host] <- String.split(text, "@"),
         true <- Regex.match?(@name_pattern, name),
         true <- Regex.match?(@host_pattern, host) do
      domain = if String.contains?(host, "."), do: :longnames, else: :shortnames
      {:ok, %{text: text, name: name, host: host, name_domain: domain}}
    else
      _invalid -> {:error, "invalid_node", %{}}
    end
  end

  @doc """
  Refuses a target that is not on this machine. The error names the flag
  and its rule, never the host, which may be anything the caller typed.
  """
  @spec ensure_loopback(target()) :: :ok | failure()
  def ensure_loopback(%{host: host}) do
    if local_host?(host),
      do: :ok,
      else:
        {:error, "non_loopback_host",
         %{
           "option" => "--node",
           "expected" => Insider.Live.Welcome.observer_options()["--node"]["value"]
         }}
  end

  # A target is local when its host is a loopback address, this machine's own
  # host name (the `--sname` default), or a name that resolves only to
  # loopback addresses.
  defp local_host?(host) do
    characters = String.to_charlist(host)

    case :inet.parse_strict_address(characters) do
      {:ok, address} -> loopback_address?(address)
      {:error, _reason} -> own_host_name?(host) or resolves_only_to_loopback?(characters)
    end
  end

  defp own_host_name?(host) do
    {:ok, local} = :inet.gethostname()
    String.downcase(host) == local |> List.to_string() |> String.downcase()
  end

  defp resolves_only_to_loopback?(host) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(host, family, @resolve_timeout_ms)],
          address <- found,
          do: address

    addresses != [] and Enum.all?(addresses, &loopback_address?/1)
  end

  @doc "Whether `address` is an IPv4 or IPv6 loopback address (IPv4-mapped included)."
  @spec loopback_address?(:inet.ip_address()) :: boolean()
  def loopback_address?({127, _b, _c, _d}), do: true
  def loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback_address?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: high >>> 8 == 127
  def loopback_address?(_address), do: false

  @doc false
  @spec read_cookie(String.t()) :: {:ok, atom()} | failure()
  def read_cookie(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- stat(path),
         :ok <- owner_only(mode),
         true <- size <= @max_cookie_file_bytes,
         {:ok, contents} <- File.read(path),
         cookie = String.trim_trailing(contents),
         true <- Regex.match?(@cookie_pattern, cookie) do
      # One bounded atom per invocation; the cookie is never echoed.
      {:ok, String.to_atom(cookie)}
    else
      {:error, _code, _details} = failure -> failure
      false -> {:error, "cookie_file_invalid", %{}}
      _unreadable -> {:error, "cookie_file_unreadable", %{}}
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} = found -> found
      _missing -> {:error, "cookie_file_unreadable", %{}}
    end
  end

  defp owner_only(mode) do
    if (mode &&& 0o077) == 0 do
      :ok
    else
      permissions = mode &&& 0o777

      {:error, "cookie_file_permissions",
       %{"mode" => "0" <> Integer.to_string(permissions, 8), "required" => "0600 or stricter"}}
    end
  end

  @doc """
  Runs `work` with a connection to the target and always stops distribution.
  """
  @spec with_target(target(), atom(), pos_integer(), (node() -> result)) :: result | failure()
        when result: term()
  def with_target(target, cookie, timeout_ms, work) when is_function(work, 1) do
    with :ok <- registered(target, timeout_ms),
         :ok <- start_distribution(target) do
      node = String.to_atom(target.text)

      try do
        with :ok <- connect(node, cookie, timeout_ms), do: work.(node)
      after
        stop_distribution(node)
      end
    end
  end

  defp registered(%{name: name, host: host}, timeout_ms) do
    case bounded(fn -> :erl_epmd.names(String.to_charlist(host)) end, timeout_ms) do
      {:ok, {:ok, names}} ->
        if List.keymember?(names, String.to_charlist(name), 0),
          do: :ok,
          else: {:error, "target_not_found", %{"reason" => "not_registered"}}

      {:ok, _unreachable} ->
        {:error, "target_not_found", %{"reason" => "epmd_unreachable"}}

      :timeout ->
        {:error, "connect_timeout", %{"stage" => "epmd"}}
    end
  end

  defp start_distribution(%{host: host, name_domain: domain}) do
    if Node.alive?() do
      {:error, "distribution_unavailable", %{"reason" => "already_distributed"}}
    else
      name =
        :"insider_observer_#{System.pid()}_#{System.unique_integer([:positive])}@#{host}"

      # Hidden, and never listening: the target reaches this node only over
      # the connection the observer opens.
      case :net_kernel.start(name, %{name_domain: domain, hidden: true, dist_listen: false}) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> {:error, "distribution_unavailable", %{"reason" => "start_failed"}}
      end
    end
  end

  defp connect(node, cookie, timeout_ms) do
    true = :erlang.set_cookie(node, cookie)

    case bounded(fn -> :net_kernel.connect_node(node) end, timeout_ms) do
      {:ok, true} ->
        :ok

      {:ok, _refused} ->
        {:error, "connection_failed", %{"reason" => "refused"}}

      :timeout ->
        {:error, "connect_timeout", %{"stage" => "connect"}}
    end
  end

  defp stop_distribution(node) do
    _disconnected = :erlang.disconnect_node(node)
    _stopped = :net_kernel.stop()
    :ok
  end

  defp bounded(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> {:ok, value}
      _timeout -> :timeout
    end
  end

  @doc """
  Calls `module.function(arguments)` on `node` with `:erpc` under `timeout_ms`.
  Remote failures are reduced to a code and the exception module name, so no
  remote value is echoed.
  """
  @spec call(node(), module(), atom(), list(), pos_integer()) :: {:ok, term()} | failure()
  def call(node, module, function, arguments, timeout_ms) do
    {:ok, :erpc.call(node, module, function, arguments, timeout_ms)}
  catch
    :error, {:erpc, :timeout} ->
      {:error, "rpc_timeout", %{"function" => describe_mfa(module, function, arguments)}}

    :error, {:erpc, :noconnection} ->
      {:error, "target_down", %{}}

    :error, {:exception, reason, _stacktrace} ->
      {:error, "remote_exception",
       %{
         "kind" => "error",
         "exception" => exception_name(reason),
         "function" => describe_mfa(module, function, arguments)
       }}

    :exit, {:exception, _reason} ->
      {:error, "remote_exception",
       %{"kind" => "exit", "function" => describe_mfa(module, function, arguments)}}

    :throw, _value ->
      {:error, "remote_exception",
       %{"kind" => "throw", "function" => describe_mfa(module, function, arguments)}}

    :error, {:erpc, reason} ->
      {:error, "remote_exception",
       %{
         "kind" => "erpc",
         "reason" => erpc_reason(reason),
         "function" => describe_mfa(module, function, arguments)
       }}
  end

  defp exception_name(%module{__exception__: true}), do: inspect(module)
  defp exception_name(_reason), do: "erlang_error"

  defp erpc_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp erpc_reason(_reason), do: "other"

  defp describe_mfa(module, function, arguments),
    do: "#{inspect(module)}.#{function}/#{length(arguments)}"
end
