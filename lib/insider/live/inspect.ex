defmodule Insider.Live.Inspect do
  @moduledoc false

  # The one-shot inspections behind `Insider.Live.process/1`, `bin_leak/1`,
  # `ports/1`, and `alloc/1`. Each runs in a worker process under a
  # deadline and a heap guard, and at most two run at once (`busy` beyond
  # that); the caller receives only the plain result the worker built.
  #
  # recon is used only where it reads no process and no more than Insider's
  # own bounds allow: `alloc` needs `recon_alloc`. `process`, `bin_leak`,
  # and `ports` are Insider's own: `recon:info/1` reads the process
  # dictionary, `recon:bin_leak/1` reads and collects every process,
  # protected ones included, and `recon:port_types/0` reads every port
  # whatever the scan bound. Protected processes (the host's declarations
  # and the fixed OTP inventory) are never read; Insider's own processes are
  # summed apart in the node-wide inspections.
  #
  # The exported result, with its masks, metadata, and session status, is
  # at most `max_result_bytes` of canonical JSON: `fit/3` cuts its lists,
  # longest first, and counts what it dropped in `"omitted"`. Free-form
  # strings (file paths, port names, shapes) are bounded where they are
  # read, so the fixed fields always fit.

  alias Insider.Event.Canonical
  alias Insider.Live.Inspect.Alloc
  alias Insider.Live.Inspect.BinLeak
  alias Insider.Live.Inspect.Ports
  alias Insider.Live.Inspect.Process, as: ProcessInspect
  alias Insider.Live.SlotWorker
  alias Insider.Policy.ProtectedTargets

  @deadline_ms 3_000
  @await_margin_ms 300
  @max_result_bytes 65_536
  # The session status added after the fit.
  @session_reserve_bytes 256
  @event_budget_bytes 3_500
  # 64 MiB on a 64-bit VM for the worker; it holds one process's binary
  # list or one census at a time.
  @max_worker_heap_words 8_388_608
  @slots [Insider.Live.Inspect.Slot1, Insider.Live.Inspect.Slot2]
  @kinds %{
    "process" => ProcessInspect,
    "bin_leak" => BinLeak,
    "ports" => Ports,
    "alloc" => Alloc
  }

  @type context :: %{
          profile: :rich | :strict,
          protected: %{pid() => atom() | nil},
          master: pid() | nil,
          recon: boolean(),
          max_scan: pos_integer() | nil,
          deadline: integer()
        }

  @doc "The fixed bounds of one inspection."
  @spec bounds() :: map()
  def bounds do
    %{
      "deadline_ms" => @deadline_ms,
      "result_bytes_max" => @max_result_bytes,
      "event_bytes_max" => @event_budget_bytes,
      "concurrent_max" => length(@slots),
      "mailbox_read_max" => ProcessInspect.mailbox_read_max(),
      "processes_scanned_max" => BinLeak.max_scan(),
      "ports_scanned_max" => Ports.max_scan()
    }
  end

  @doc """
  Runs inspection `kind` (`"process"`, `"bin_leak"`, `"ports"`, or
  `"alloc"`) with its parsed options under the disclosure `profile`, with
  `protection` the host's protected-target policy. Returns the result, or
  an error map. `test_options` are for tests only: `:recon` (whether recon
  is used), `:max_scan` (a smaller scan bound), and `:deadline_ms`.
  """
  @spec run(String.t(), map(), :rich | :strict, ProtectedTargets.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def run(kind, parsed, profile, protection, test_options \\ []) do
    module = Map.fetch!(@kinds, kind)
    deadline_ms = Keyword.get(test_options, :deadline_ms, @deadline_ms)

    context = %{
      profile: profile,
      protected: ProtectedTargets.scan_inventory(protection).protected,
      master: insider_master(),
      recon: Keyword.get_lazy(test_options, :recon, &recon/0),
      max_scan: Keyword.get(test_options, :max_scan),
      deadline: System.monotonic_time(:millisecond) + deadline_ms
    }

    SlotWorker.run(fn -> module.inspect(parsed, context) end,
      slots: @slots,
      heap_words: @max_worker_heap_words,
      include_shared_binaries: false,
      await_ms: deadline_ms + @await_margin_ms
    )
  end

  @doc """
  Cuts an exported `kind` result to `max_result_bytes`, less the room its
  session status takes, and returns `{:ok, result}`, or `:too_large` when
  its fixed fields alone exceed it.
  """
  @spec fit_result(String.t(), map()) :: {:ok, map()} | :too_large
  def fit_result(kind, result),
    do: fit(result, Map.fetch!(@kinds, kind).lists(), @max_result_bytes - @session_reserve_bytes)

  @doc """
  The attributes of the `inspect.KIND` session event for `result`: the
  kind's compact projection, cut to the event attribute bound.
  """
  @spec event_attributes(String.t(), map()) :: map()
  def event_attributes(kind, result) do
    module = Map.fetch!(@kinds, kind)
    {attributes, lists} = module.event(result)

    case fit(Map.put(attributes, "operation", kind), Enum.map(lists, &[&1]), @event_budget_bytes) do
      {:ok, attributes} -> attributes
      :too_large -> %{"operation" => kind, "omitted" => nil, "too_large" => true}
    end
  end

  @doc """
  Drops entries from the end of the longest list at `paths` (key paths into
  `map`) until `map` encodes to at most `budget` canonical JSON bytes, and
  records how many were dropped under `"omitted"`. `:too_large` when every
  list is empty and it still does not fit.
  """
  @spec fit(map(), [[String.t()]], pos_integer()) :: {:ok, map()} | :too_large
  def fit(map, paths, budget), do: fit(map, paths, budget, 0)

  defp fit(map, paths, budget, omitted) do
    map = Map.put(map, "omitted", omitted)

    cond do
      map |> Canonical.encode() |> byte_size() <= budget ->
        {:ok, map}

      longest = longest(map, paths) ->
        map |> update_in(longest, &Enum.drop(&1, -1)) |> fit(paths, budget, omitted + 1)

      true ->
        :too_large
    end
  end

  defp longest(map, paths) do
    paths
    |> Enum.filter(&match?([_ | _], get_in(map, &1)))
    |> Enum.max_by(&length(get_in(map, &1)), fn -> nil end)
  end

  @doc """
  `text` cut to at most `bytes` bytes of valid UTF-8, keeping its `:head`
  or its `:tail`, with `...` where it was cut.
  """
  @spec bound_text(String.t(), pos_integer(), :head | :tail) :: String.t()
  def bound_text(text, bytes, _keep) when byte_size(text) <= bytes, do: text

  def bound_text(text, bytes, :head),
    do: text |> binary_part(0, bytes - 3) |> valid_head() |> Kernel.<>("...")

  def bound_text(text, bytes, :tail) do
    kept = bytes - 3
    "..." <> (text |> binary_part(byte_size(text) - kept, kept) |> valid_tail())
  end

  defp valid_head(text) do
    if String.valid?(text), do: text, else: valid_head(binary_part(text, 0, byte_size(text) - 1))
  end

  defp valid_tail(text) do
    if String.valid?(text), do: text, else: valid_tail(binary_part(text, 1, byte_size(text) - 1))
  end

  @doc "Whether recon and recon_alloc are loaded or loadable on this node."
  @spec recon() :: boolean()
  def recon, do: Code.ensure_loaded?(:recon) and Code.ensure_loaded?(:recon_alloc)

  @doc "Milliseconds left before the context's deadline, at least 0."
  @spec remaining(context()) :: non_neg_integer()
  def remaining(context), do: max(context.deadline - System.monotonic_time(:millisecond), 0)

  @doc "Whether a process is Insider's own, by its group leader."
  @spec insider?(pid(), context()) :: boolean()
  def insider?(pid, context),
    do: Insider.Collector.Poller.Names.insider_leader?(pid, context.master)

  defp insider_master do
    case :application_controller.get_master(:insider) do
      master when is_pid(master) -> master
      :undefined -> nil
    end
  end
end
