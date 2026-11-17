defmodule Insider.Live.PollerOptions do
  @moduledoc false

  # The Poller's live start options: its interval, the process and ETS
  # rankings, and the registered names to watch. They require the poller
  # component. A watched name resolves only to an atom that already exists
  # on the node, so a caller can never create atoms; a name that is not an
  # atom here can name no process, and is refused with
  # `unknown_process_name`.

  alias Insider.Collector.Poller.Config
  alias Insider.Collector.Poller.Names
  alias Insider.Live.Error
  alias Insider.Live.Options
  alias Insider.Protocol.Value

  @keys ["poller_interval_ms", "top_ets_tables", "top_ports", "top_processes", "watch_processes"]
  @interval_ms %{"default" => 5_000, "min" => 1_000, "max" => 60_000}
  @top_processes %{"default" => 5, "min" => 0, "max" => Config.maximum_top_processes()}
  @top_ets_tables %{"default" => 5, "min" => 0, "max" => Config.maximum_top_ets_tables()}
  @top_ports %{"default" => 5, "min" => 0, "max" => Config.maximum_top_ports()}
  @max_watch Config.maximum_watch_names()
  # A scan reads every process once, so its probe may take longer than a
  # targeted one; the cycle bound still stops a slow cycle.
  @probe_timeout_ms 1_000
  @cycle_timeout_ms 5_000

  @type parsed :: %{
          interval_ms: pos_integer(),
          top_processes: non_neg_integer(),
          top_ets_tables: non_neg_integer(),
          top_ports: non_neg_integer(),
          watch_processes: [String.t()],
          watch_names: [atom()]
        }

  @spec start_keys() :: [String.t()]
  def start_keys, do: @keys

  @spec describe() :: map()
  def describe do
    %{
      "poller_interval_ms" =>
        Map.merge(@interval_ms, %{
          "type" => "integer",
          "requires_component" => "poller",
          "note" => "how often the poller samples; reductions_delta covers one interval"
        }),
      "top_processes" =>
        Map.merge(@top_processes, %{
          "type" => "integer",
          "requires_component" => "poller",
          "note" =>
            "entries in each process ranking (by message_queue_len, memory, reductions_delta); 0 scans no processes"
        }),
      "top_ets_tables" =>
        Map.merge(@top_ets_tables, %{
          "type" => "integer",
          "requires_component" => "poller",
          "note" => "entries in each ETS ranking (by memory, size); 0 scans no tables"
        }),
      "top_ports" =>
        Map.merge(@top_ports, %{
          "type" => "integer",
          "requires_component" => "poller",
          "note" =>
            "entries in each port_top ranking (port types by count, owners by ports held), with each type's growth " <>
              "since the previous census; 0 counts no ports"
        }),
      "watch_processes" => %{
        "type" => "list of strings",
        "default" => [],
        "max" => @max_watch,
        "requires_component" => "poller",
        "note" =>
          "registered names such as MyApp.Worker or my_server; each is sampled every interval as process_watch"
      }
    }
  end

  @doc """
  The poller options of a start, `nil` without the poller component. Each
  one given without it is `invalid_options`.
  """
  @spec start(map(), [String.t()]) :: {:ok, parsed() | nil} | {:error, map()}
  def start(options, components) do
    given = options |> Map.take(@keys) |> Map.keys() |> Enum.sort()

    cond do
      "poller" in components -> parse(options)
      given == [] -> {:ok, nil}
      true -> invalid(hd(given))
    end
  end

  @doc "The accepted options as the session record shows them."
  @spec echo(parsed() | nil) :: map() | nil
  def echo(nil), do: nil

  def echo(parsed) do
    %{
      "interval_ms" => parsed.interval_ms,
      "top_processes" => parsed.top_processes,
      "top_ets_tables" => parsed.top_ets_tables,
      "top_ports" => parsed.top_ports,
      "watch_processes" => parsed.watch_processes
    }
  end

  @doc "The collector options that start the session's Poller."
  @spec collector_options(parsed()) :: keyword()
  def collector_options(parsed) do
    [
      initial_delay_ms: 0,
      interval_ms: parsed.interval_ms,
      top_processes: parsed.top_processes,
      top_ets_tables: parsed.top_ets_tables,
      top_ports: parsed.top_ports,
      watch_names: parsed.watch_names,
      probe_timeout_ms: @probe_timeout_ms,
      cycle_timeout_ms: @cycle_timeout_ms
    ]
  end

  defp parse(options) do
    with {:ok, interval_ms} <-
           Options.bounded_integer(options, "poller_interval_ms", @interval_ms),
         {:ok, top_processes} <-
           Options.bounded_integer(options, "top_processes", @top_processes),
         {:ok, top_ets_tables} <-
           Options.bounded_integer(options, "top_ets_tables", @top_ets_tables),
         {:ok, top_ports} <- Options.bounded_integer(options, "top_ports", @top_ports),
         {:ok, names} <- watch_names(Map.get(options, "watch_processes", [])) do
      {:ok,
       %{
         interval_ms: interval_ms,
         top_processes: top_processes,
         top_ets_tables: top_ets_tables,
         top_ports: top_ports,
         watch_processes: Enum.map(names, &Names.display/1),
         watch_names: names
       }}
    end
  end

  defp watch_names(names) do
    if Value.bounded_list?(names, @max_watch) do
      names
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, atoms} ->
        case Names.parse(name) do
          {:ok, atom} -> {:cont, {:ok, [atom | atoms]}}
          :unknown -> {:halt, {:error, Error.new("unknown_process_name", %{"name" => name})}}
          :invalid -> {:halt, invalid("watch_processes")}
        end
      end)
      |> unique()
    else
      invalid("watch_processes")
    end
  end

  defp unique({:ok, atoms}) do
    if atoms == Enum.uniq(atoms),
      do: {:ok, Enum.reverse(atoms)},
      else: invalid("watch_processes")
  end

  defp unique(error), do: error

  defp invalid(field), do: {:error, Error.new("invalid_options", %{"field" => field})}
end
