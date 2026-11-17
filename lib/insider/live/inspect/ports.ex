defmodule Insider.Live.Inspect.Ports do
  @moduledoc false

  # `Insider.Live.ports/1`: the node's ports counted by type, after
  # `recon:port_types/0` but from Insider's own capped read of at most
  # `max_scan` ports, and the ports of one type or one owner listed with
  # their owner, OS pid, and I/O counters. Every field comes from that one
  # read, so nothing reads more ports than the bound. A port's type is the
  # first word of its name without a directory (`cat`, `tcp_inet`); its
  # full name, a spawn command line, is returned only in the rich profile,
  # at most `@name_bytes` bytes. A command line cannot be parsed with
  # confidence (quotes, escapes, line continuations, expansions, nested
  # shell commands, values that look like flags, tabs as separators), so
  # masking is structural and fails closed. The command is split once, at
  # its first whitespace or control character, into the program and the
  # rest. The rest is masked whole when the command names a credential
  # anywhere (`password`, `token`, `api_key`, ... as
  # `Insider.Redaction.Credentials` defines them, quotes ignored) or holds
  # anything a shell may rewrite (a backslash, any control character, `$`,
  # or a backtick). When the program itself names one or holds such a
  # character, or the command starts with a separator, the boundary is in
  # doubt and the whole command is masked. Nothing after the program is
  # ever kept once the command is masked. The result's credential
  # masking then runs over what is left. Ports owned by Insider's processes
  # are counted apart.

  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ports, as: Census
  alias Insider.Collector.Poller.Ranking
  alias Insider.Live.Error
  alias Insider.Live.Inspect

  @schema "insider.live-ports/v1"
  @max_scan 50_000
  @name_bytes 256
  @marker "[REDACTED:credential_key]"

  @spec max_scan() :: pos_integer()
  def max_scan, do: @max_scan

  @spec lists() :: [[String.t()]]
  def lists, do: [["ports"], ["owners"], ["types"]]

  @spec inspect(map(), Inspect.context()) :: {:ok, map()} | {:error, map()}
  def inspect(%{type: type, owner: owner, top: top}, context) do
    with {:ok, owner_pid} <- resolve(owner) do
      max_scan = Map.get(context, :max_scan) || @max_scan
      all = :erlang.ports()
      ports = Enum.take(all, max_scan)
      read = for port <- ports, {_, _, _} = info <- [Census.read(port)], do: {port, info}
      naming = %{insider: MapSet.new(), protected: context.protected, master: context.master}

      classes =
        read
        |> Enum.map(fn {_port, {_name, pid, _os}} -> pid end)
        |> Enum.uniq()
        |> classify(naming)

      {insider, application} =
        Enum.split_with(read, fn {_port, {_name, pid, _os}} -> classes[pid] == :insider end)

      matched =
        Enum.filter(application, fn {_port, {name, pid, _os}} ->
          (type == nil or Census.type(name) == type) and (owner_pid == nil or pid == owner_pid)
        end)

      {:ok,
       %{
         "schema" => @schema,
         "implementation" => "native",
         "port_count" => length(all),
         "scanned" => length(read),
         "os_process_count" => Enum.count(application, &os_process?/1),
         "types" => types(application, top),
         "filter" => %{"type" => type, "owner" => owner_pid && Names.pid(owner_pid)},
         "matched" => length(matched),
         "matched_os_process_count" => Enum.count(matched, &os_process?/1),
         "owners" => owners(matched, classes, top),
         "ports" => matched |> Enum.take(top) |> Enum.map(&row(&1, classes, context.profile)),
         "insider" => %{"port_count" => length(insider)},
         "truncated_by" => if(length(all) > max_scan, do: ["scan_limit"], else: [])
       }}
    end
  end

  defp resolve(nil), do: {:ok, nil}

  defp resolve({:name, name}) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _absent -> {:error, Error.new("process_not_found", %{"name" => Names.display(name)})}
    end
  end

  # An owner that has exited owns no ports, so it lists none.
  defp resolve({:pid, pid}), do: {:ok, pid}

  defp classify(pids, naming), do: Map.new(pids, &{&1, Names.owner_class(&1, naming)})

  defp os_process?({_port, {_name, _pid, os_pid}}), do: is_integer(os_pid)

  defp types(application, top) do
    application
    |> Enum.reduce(%{}, fn {_port, {name, _pid, os_pid}}, types ->
      os = if is_integer(os_pid), do: 1, else: 0

      Map.update(types, Census.type(name), {1, os}, fn {count, with_os} ->
        {count + 1, with_os + os}
      end)
    end)
    |> Enum.sort_by(fn {type, {count, _os}} -> {-count, type} end)
    |> Enum.take(top)
    |> Enum.map(fn {type, {count, os}} ->
      %{"type" => type, "count" => count, "os_process_count" => os}
    end)
  end

  defp owners(matched, classes, top) do
    matched
    |> Enum.frequencies_by(fn {_port, {_name, pid, _os}} -> pid end)
    |> Enum.reduce([], fn {pid, count}, ranked ->
      Ranking.insert(ranked, count, {pid, count}, top)
    end)
    |> Ranking.rows()
    |> Enum.map(fn {pid, count} ->
      {:owner, name} = classes[pid]
      %{"owner" => name, "owner_pid" => Names.pid(pid), "count" => count}
    end)
  end

  defp row({port, {name, pid, os_pid}}, classes, profile) do
    {:owner, owner} = classes[pid]

    %{
      "port" => port |> :erlang.port_to_list() |> List.to_string(),
      "type" => Census.type(name),
      "owner" => owner,
      "owner_pid" => Names.pid(pid),
      "os_pid" => if(is_integer(os_pid), do: os_pid),
      "input_bytes" => counter(port, :input),
      "output_bytes" => counter(port, :output),
      "queue_bytes" => counter(port, :queue_size)
    }
    |> put_name(name, profile)
  end

  defp put_name(row, name, :rich), do: Map.put(row, "name", bounded_name(name))
  defp put_name(row, _name, :strict), do: row

  defp bounded_name(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) ->
        binary |> mask_command() |> Inspect.bound_text(@name_bytes, :head)

      _invalid ->
        nil
    end
  end

  @doc """
  A command line masked structurally: split once at its first whitespace
  or control character, the rest is masked whole when the command names a
  credential anywhere or holds anything a shell may rewrite, and the whole
  command is masked when the program itself is in doubt.
  """
  @spec mask_command(String.t()) :: String.t()
  def mask_command(command) do
    # The trigger is checked on the whole command, so the separator that
    # ends the program (a sole tab, newline, or carriage return) still counts.
    case Census.program(command) do
      :doubtful -> @marker
      {:ok, program} -> if Census.doubtful?(command), do: program <> " " <> @marker, else: command
    end
  end

  defp counter(port, item) do
    case :erlang.port_info(port, item) do
      {^item, value} when is_integer(value) -> value
      _closed -> nil
    end
  end

  @spec event(map()) :: {map(), [String.t()]}
  def event(result) do
    {result
     |> Map.take([
       "implementation",
       "port_count",
       "os_process_count",
       "filter",
       "matched",
       "matched_os_process_count",
       "insider",
       "truncated_by"
     ])
     |> Map.merge(%{
       "types" => Enum.take(result["types"], 5),
       "owners" => Enum.take(result["owners"], 5)
     }), ["owners", "types"]}
  end
end
