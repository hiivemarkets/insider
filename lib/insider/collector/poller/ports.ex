defmodule Insider.Collector.Poller.Ports do
  @moduledoc false

  # The Poller's port census (`port_top`), in the manner of
  # `recon:port_types/0`: every local port counted by type, the processes
  # that own the most ports, how many ports have an OS process, and how
  # each count changed since the previous census. A port's type is its
  # program's name without a directory (`cat` for `/bin/cat -u`,
  # `tcp_inet` for a socket): the name is split once at its first
  # whitespace or control character, and when that program names a
  # credential or holds anything a shell may rewrite (a backslash, a
  # control character, `$`, a backtick), or the name starts with a
  # separator, the type is `other`. A spawn command's arguments are never
  # recorded. Only `:erlang.port_info/2` items are read for ports; an owner
  # is named like an ETS table's owner (`Insider.Collector.Poller.Names`).
  # Ports owned by Insider's own processes are counted under `"insider"`
  # and never ranked.

  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ranking
  alias Insider.Redaction.Credentials

  @max_scan 50_000
  @max_types 512
  @other_type "other"
  @type_pattern ~r/\A[A-Za-z0-9_.+@-]{1,64}\z/
  # Quoting that could split a credential name, the characters with which
  # a shell may rewrite a word, and the separators that end a program.
  @quoting ["\"", "'"]
  @rewritable ~r/[\\$`\p{Cc}]/u
  @separator ~r/[\s\p{Cc}]/u
  @lists ["by_type", "by_owner"]

  @type snapshot :: %{
          at_us: integer(),
          port_count: non_neg_integer(),
          types: %{String.t() => non_neg_integer()}
        }
  @type options :: %{
          required(:top) => pos_integer(),
          required(:protected) => %{pid() => atom() | nil},
          required(:insider) => [pid()],
          required(:master) => pid() | nil,
          required(:budget_bytes) => pos_integer(),
          optional(:insider_protected) => [pid()],
          optional(:host_declared) => [pid()],
          optional(:max_scan) => pos_integer()
        }

  @doc "The most ports one census reads; the rest are reported as not scanned."
  @spec max_scan() :: pos_integer()
  def max_scan, do: @max_scan

  @doc "The most distinct port types a census keeps; the rest count as `other`."
  @spec max_types() :: pos_integer()
  def max_types, do: @max_types

  @doc """
  A port's type: its program's name without a directory, such as `cat` for
  `/bin/cat -u`, or `other` when the program is in doubt (see
  `program/1`) or its name is not a plain word.
  """
  @spec type(term()) :: String.t()
  def type(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> type(binary)
      _invalid -> @other_type
    end
  end

  def type(name) when is_binary(name) do
    with {:ok, program} <- program(name),
         word = Path.basename(program),
         true <- String.match?(word, @type_pattern) do
      word
    else
      _doubtful -> @other_type
    end
  end

  def type(_name), do: @other_type

  @doc """
  The program of a command line: the text before its first whitespace or
  control character, or `:doubtful` when that is empty, names a credential,
  or holds anything a shell may rewrite.
  """
  @spec program(String.t()) :: {:ok, String.t()} | :doubtful
  def program(command) when is_binary(command) do
    [program | _rest] = Regex.split(@separator, command, parts: 2)
    if program == "" or doubtful?(program), do: :doubtful, else: {:ok, program}
  end

  @doc """
  Whether `text` names a credential (as `Insider.Redaction.Credentials`
  defines them, quotes ignored) or holds anything a shell may rewrite (a
  backslash, a control character, `$`, a backtick).
  """
  @spec doubtful?(String.t()) :: boolean()
  def doubtful?(text) when is_binary(text) do
    Regex.match?(@rewritable, text) or
      text |> String.replace(@quoting, "") |> Credentials.credential_key?()
  end

  @doc """
  The census: `previous` is the snapshot the last census returned (`nil`
  before the first), from which each type's `delta` and the window's
  `port_count_delta` are taken. Returns the metrics and the next snapshot.
  """
  @spec top(snapshot() | nil, options()) ::
          {:ok, :complete | :partial, map(), [String.t()], snapshot()}
  def top(previous, options) do
    at_us = System.monotonic_time(:microsecond)
    ports = :erlang.ports()

    context = %{
      insider: MapSet.new(options.insider ++ Map.get(options, :insider_protected, [])),
      protected: options.protected,
      master: options.master
    }

    scan =
      census(
        ports,
        Map.get(options, :max_scan, @max_scan),
        %{
          scanned: 0,
          truncated: false,
          os_processes: 0,
          types: %{},
          owners: %{},
          classes: %{},
          insider: %{"port_count" => 0, "os_process_count" => 0}
        },
        context
      )

    port_count = length(ports)

    metrics =
      %{
        "by_type" => by_type(scan.types, previous, options.top),
        "by_owner" => by_owner(scan, options.top, options.protected),
        "port_count" => port_count,
        "scanned" => scan.scanned,
        "os_process_count" => scan.os_processes,
        "type_count" => map_size(scan.types),
        "port_count_delta" => previous && port_count - previous.port_count,
        "window_ms" => previous && div(at_us - previous.at_us, 1_000),
        "insider" => scan.insider
      }
      |> Ranking.fit(@lists, options.budget_bytes)

    unavailable =
      [
        {scan.truncated, "scan_limit"},
        {is_nil(previous), "port_count_delta"},
        {metrics["omitted"] > 0, "event_bytes"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    status = if unavailable == [], do: :complete, else: :partial

    snapshot = %{
      at_us: at_us,
      port_count: port_count,
      types: Map.new(scan.types, fn {type, %{count: count}} -> {type, count} end)
    }

    {:ok, status, metrics, unavailable, snapshot}
  end

  defp census([], _max, scan, _context), do: scan
  defp census(_ports, 0, scan, _context), do: %{scan | truncated: true}

  defp census([port | rest], remaining, scan, context),
    do: census(rest, remaining - 1, visit(port, scan, context), context)

  defp visit(port, scan, context) do
    case read(port) do
      {name, owner, os_pid} ->
        {class, classes} = classify(owner, scan.classes, context)
        scan = %{scan | scanned: scan.scanned + 1, classes: classes}
        os = if is_integer(os_pid), do: 1, else: 0

        case class do
          :insider ->
            insider =
              scan.insider
              |> Map.update!("port_count", &(&1 + 1))
              |> Map.update!("os_process_count", &(&1 + os))

            %{scan | insider: insider}

          {:owner, _name} ->
            type = bounded_type(scan.types, type(name))

            %{
              scan
              | os_processes: scan.os_processes + os,
                types:
                  Map.update(scan.types, type, %{count: 1, os: os}, fn entry ->
                    %{count: entry.count + 1, os: entry.os + os}
                  end),
                owners: Map.update(scan.owners, owner, {1, %{type => 1}}, &own(&1, type))
            }
        end

      nil ->
        scan
    end
  end

  defp own({count, types}, type), do: {count + 1, Map.update(types, type, 1, &(&1 + 1))}

  # A port that closed after `:erlang.ports/0` is skipped.
  @doc false
  @spec read(port()) :: {charlist() | binary(), pid(), integer() | :undefined | nil} | nil
  def read(port) do
    with {:name, name} <- :erlang.port_info(port, :name),
         {:connected, owner} when is_pid(owner) <- :erlang.port_info(port, :connected),
         {:os_pid, os_pid} <- :erlang.port_info(port, :os_pid) do
      {name, owner, os_pid}
    else
      _closed -> nil
    end
  end

  defp classify(owner, classes, context) do
    case classes do
      %{^owner => class} ->
        {class, classes}

      _unseen ->
        class = classify(owner, context)
        {class, Map.put(classes, owner, class)}
    end
  end

  # Only whether the owner is Insider's is decided while scanning; the
  # ranked owners are named afterwards.
  defp classify(owner, context) do
    cond do
      MapSet.member?(context.insider, owner) -> :insider
      is_map_key(context.protected, owner) -> {:owner, :protected}
      Names.insider_leader?(owner, context.master) -> :insider
      true -> {:owner, :unnamed}
    end
  end

  defp bounded_type(types, type) do
    if is_map_key(types, type) or map_size(types) < @max_types - 1,
      do: type,
      else: @other_type
  end

  defp by_type(types, previous, top) do
    types
    |> Enum.reduce([], fn {type, %{count: count, os: os}}, ranked ->
      delta = previous && count - Map.get(previous.types, type, 0)

      Ranking.insert(
        ranked,
        count,
        %{"type" => type, "count" => count, "os_process_count" => os, "delta" => delta},
        top
      )
    end)
    |> Ranking.rows()
  end

  # A protected owner is named from the inventory, never read.
  defp by_owner(scan, top, protected) do
    naming = %{insider: MapSet.new(), protected: protected, master: nil}

    scan.owners
    |> Enum.reduce([], fn {owner, {count, types}}, ranked ->
      Ranking.insert(ranked, count, {owner, count, types}, top)
    end)
    |> Ranking.rows()
    |> Enum.map(fn {owner, count, types} ->
      {:owner, name} = Names.owner_class(owner, naming)
      {top_type, _count} = Enum.max_by(types, &elem(&1, 1))

      %{
        "owner" => name,
        "owner_pid" => Names.pid(owner),
        "count" => count,
        "top_type" => top_type
      }
    end)
  end
end
