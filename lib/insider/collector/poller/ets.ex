defmodule Insider.Collector.Poller.Ets do
  @moduledoc false

  # The Poller's ETS scan: the top tables by memory and by object count,
  # each with its name and owner, plus Insider's own tables. Only
  # `:ets.info/2` metadata is read, never an object. A table's owner is
  # named from the protected-target inventory when it is protected, so a
  # protected process is never read; any other owner is named with
  # `Insider.Collector.Poller.Names`. Tables owned by Insider's processes
  # are summed under `"insider"` and never ranked.

  alias Insider.Collector.Poller.Names
  alias Insider.Collector.Poller.Ranking

  @lists ["by_memory", "by_size"]

  @type options :: %{
          top: pos_integer(),
          protected: %{pid() => atom() | nil},
          insider: [pid()],
          master: pid() | nil,
          budget_bytes: pos_integer()
        }

  @spec top(options()) :: {:ok, :complete | :partial, map(), [String.t()]}
  def top(options) do
    word_bytes = :erlang.system_info(:wordsize)
    tables = :ets.all()

    context = %{
      top: options.top,
      protected: options.protected,
      # A control-plane owner a host also protects is still Insider's; the
      # policy says so, so it is never read.
      insider: MapSet.new(options.insider ++ Map.get(options, :insider_protected, [])),
      master: options.master
    }

    initial = %{
      memory: [],
      size: [],
      owners: %{},
      insider: %{"table_count" => 0, "memory_bytes" => 0, "size" => 0}
    }

    scan =
      Enum.reduce(tables, initial, fn table, scan ->
        case info(table) do
          {name, size, words, owner} ->
            visit(scan, name, size, words * word_bytes, owner, context)

          nil ->
            scan
        end
      end)

    metrics =
      %{
        "by_memory" => Ranking.rows(scan.memory),
        "by_size" => Ranking.rows(scan.size),
        "table_count" => length(tables),
        "insider" => scan.insider
      }
      |> Ranking.fit(@lists, options.budget_bytes)

    if metrics["omitted"] > 0,
      do: {:ok, :partial, metrics, ["event_bytes"]},
      else: {:ok, :complete, metrics, []}
  end

  # A table deleted after `:ets.all/0` returns `:undefined`.
  defp info(table) do
    with name when is_atom(name) <- :ets.info(table, :name),
         size when is_integer(size) <- :ets.info(table, :size),
         words when is_integer(words) <- :ets.info(table, :memory),
         owner when is_pid(owner) <- :ets.info(table, :owner) do
      {name, size, words, owner}
    else
      _deleted -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp visit(scan, name, size, bytes, owner, context) do
    {class, owners} = owner_class(owner, scan.owners, context)
    scan = %{scan | owners: owners}

    case class do
      :insider ->
        insider =
          scan.insider
          |> Map.update!("table_count", &(&1 + 1))
          |> Map.update!("memory_bytes", &(&1 + bytes))
          |> Map.update!("size", &(&1 + size))

        %{scan | insider: insider}

      {:owner, owner_name} ->
        entry = %{
          "table" => Names.display(name),
          "owner" => owner_name,
          "owner_pid" => Names.pid(owner),
          "memory_bytes" => bytes,
          "size" => size
        }

        %{
          scan
          | memory: Ranking.insert(scan.memory, bytes, entry, context.top),
            size:
              if(size > 0,
                do: Ranking.insert(scan.size, size, entry, context.top),
                else: scan.size
              )
        }
    end
  end

  defp owner_class(owner, owners, context) do
    case owners do
      %{^owner => class} ->
        {class, owners}

      _unseen ->
        class = Names.owner_class(owner, context)
        {class, Map.put(owners, owner, class)}
    end
  end
end
