defmodule Insider.Live.CallsOptions do
  @moduledoc false

  # The call-trace component's live start options: which functions to trace
  # (`"MOD.FUN/ARITY"`), whether their returns and exceptions are recorded,
  # the count and rate limits, and the byte cap of each rendered value. They
  # require the calls component.
  #
  # A function resolves only to atoms that already exist on this node and
  # to a module that is already loaded, so a caller can never create atoms
  # or load code. Preloaded runtime modules (`:erlang`, `:init`, ...) and
  # Insider's own modules are refused: tracing them could trace the tracer.

  alias Insider.Live.Error
  alias Insider.Protocol.Value

  @keys [
    "calls",
    "calls_max",
    "calls_max_bytes",
    "calls_rate_max",
    "calls_rate_ms",
    "calls_results",
    "watch_writes"
  ]
  @max_writes 8
  @max_functions 16
  @spec_bytes 256
  @results %{"all" => :all, "exceptions" => :exceptions, "none" => :none}
  @calls_max %{"default" => 100, "min" => 1, "max" => 10_000}
  @rate_max %{"default" => 50, "min" => 1, "max" => 10_000}
  @rate_ms %{"default" => 1_000, "min" => 1, "max" => 60_000}
  @max_bytes %{"default" => 1_024, "min" => 256, "max" => 2_048}
  @elixir_module ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @erlang_module ~r/\A:[a-z][A-Za-z0-9_@]*\z/
  @function ~r/\A[a-z_][A-Za-z0-9_]*[?!]?\z/

  @type parsed :: %{
          functions: [String.t()],
          mfas: [mfa()],
          results: :none | :exceptions | :all,
          max_calls: pos_integer(),
          rate_max: pos_integer(),
          rate_ms: pos_integer(),
          max_bytes: pos_integer(),
          writes: [mfa()]
        }

  @spec start_keys() :: [String.t()]
  def start_keys, do: @keys

  @doc "The most functions `calls` takes."
  @spec max_functions() :: pos_integer()
  def max_functions, do: @max_functions

  @spec describe() :: map()
  def describe do
    %{
      "calls" => %{
        "type" => "list of strings",
        "default" => nil,
        "required_with_component" => "calls",
        "requires_component" => "calls",
        "max" => @max_functions,
        "note" =>
          "functions to trace as MOD.FUN/ARITY, such as MyApp.Worker.handle_call/3 or :ets.insert/2; the module must be loaded, " <>
            "and runtime-preloaded modules and Insider's own are refused (untraceable_function)"
      },
      "watch_writes" => %{
        "type" => "list of strings",
        "default" => nil,
        "requires_component" => "calls",
        "max" => @max_writes,
        "note" =>
          "write functions of in-memory values to watch, as MOD.FUN/ARITY, such as an app's feature-flag store " <>
            "(MyApp.FlagStore.set/2) or Application.put_env/3; each call is a write of the key in its first argument " <>
            "(app and key for put_env), traced with the calls bounds; changes lists them with their writer's request. " <>
            "Runtime-preloaded functions (:persistent_term.put/2) are refused, as for calls"
      },
      "calls_results" => %{
        "type" => "string",
        "default" => "exceptions",
        "allowed" => Map.keys(@results) |> Enum.sort(),
        "requires_component" => "calls",
        "note" =>
          "none records calls only; exceptions adds a call.exception event for each traced call that raises, exits or throws; " <>
            "all also records each return as call.return"
      },
      "calls_max" =>
        Map.merge(@calls_max, %{
          "type" => "integer",
          "requires_component" => "calls",
          "note" =>
            "calls recorded in total; then no new call is traced, the results of calls already running are still recorded, and a call.stopped event says why"
        }),
      "calls_rate_max" =>
        Map.merge(@rate_max, %{
          "type" => "integer",
          "requires_component" => "calls",
          "note" =>
            "trace messages (calls, returns, exceptions) allowed within calls_rate_ms; more stop the whole trace, like recon_trace's {max, per_ms}"
        }),
      "calls_rate_ms" =>
        Map.merge(@rate_ms, %{
          "type" => "integer",
          "requires_component" => "calls",
          "note" => "the rate window of calls_rate_max, in milliseconds"
        }),
      "calls_max_bytes" =>
        Map.merge(@max_bytes, %{
          "type" => "integer",
          "requires_component" => "calls",
          "note" =>
            "JSON bytes of each rendered value (the arguments, a result, an exception reason) in the rich profile; the strict profile renders none"
        })
    }
  end

  @doc """
  The call-trace options of a start, `nil` without the calls component.
  Each one given without it is `invalid_options`; with it, `"calls"` is
  required.
  """
  @spec start(map(), [String.t()]) :: {:ok, parsed() | nil} | {:error, map()}
  def start(options, components) do
    given = options |> Map.take(@keys) |> Map.keys() |> Enum.sort()

    cond do
      "calls" in components ->
        parse(options)

      "watch_writes" in given ->
        {:error,
         Error.new("invalid_options", %{
           "field" => "watch_writes",
           "requires_component" => "calls"
         })}

      given == [] ->
        {:ok, nil}

      true ->
        invalid(hd(given))
    end
  end

  @doc "The accepted options as the session record shows them."
  @spec echo(parsed() | nil) :: map() | nil
  def echo(nil), do: nil

  def echo(parsed) do
    %{
      "functions" => parsed.functions,
      "results" => Atom.to_string(parsed.results),
      "max" => parsed.max_calls,
      "rate_max" => parsed.rate_max,
      "rate_ms" => parsed.rate_ms,
      "max_bytes" => parsed.max_bytes,
      "writes" =>
        for(
          {mfa, label} <- Enum.zip(parsed.mfas, parsed.functions),
          mfa in parsed.writes,
          do: label
        )
    }
  end

  @doc "The collector options that start the session's call trace."
  @spec collector_options(parsed()) :: keyword()
  def collector_options(parsed) do
    [
      functions: Enum.zip(parsed.mfas, parsed.functions),
      results: parsed.results,
      max_calls: parsed.max_calls,
      rate: {parsed.rate_max, parsed.rate_ms},
      max_bytes: parsed.max_bytes,
      writes: parsed.writes
    ]
  end

  # `calls` may be left out when `watch_writes` names the functions.
  defp parse(options) do
    with {:ok, writes} <- writes(Map.get(options, "watch_writes")),
         {:ok, calls} <- calls(Map.get(options, "calls"), writes),
         {:ok, functions} <- merged(calls, writes),
         {:ok, results} <- results(Map.get(options, "calls_results", "exceptions")),
         {:ok, max_calls} <- bounded(options, "calls_max", @calls_max),
         {:ok, rate_max} <- bounded(options, "calls_rate_max", @rate_max),
         {:ok, rate_ms} <- bounded(options, "calls_rate_ms", @rate_ms),
         {:ok, max_bytes} <- bounded(options, "calls_max_bytes", @max_bytes) do
      {:ok,
       %{
         functions: Enum.map(functions, &elem(&1, 0)),
         mfas: Enum.map(functions, &elem(&1, 1)),
         results: results,
         max_calls: max_calls,
         rate_max: rate_max,
         rate_ms: rate_ms,
         max_bytes: max_bytes,
         writes: Enum.map(writes, &elem(&1, 1))
       }}
    end
  end

  defp writes(nil), do: {:ok, []}

  defp writes(specs) when is_list(specs) and length(specs) <= @max_writes do
    case functions(specs) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, %{"field" => "calls"} = error} -> {:error, Map.put(error, "field", "watch_writes")}
      {:error, _error} = error -> error
    end
  end

  defp writes(_specs), do: invalid("watch_writes")

  defp calls(nil, [_ | _]), do: {:ok, []}
  defp calls(specs, _writes), do: functions(specs)

  defp merged(calls, writes) do
    extra = Enum.reject(writes, fn {_spec, mfa} -> Enum.any?(calls, &(elem(&1, 1) == mfa)) end)

    if length(calls) + length(extra) <= @max_functions,
      do: {:ok, calls ++ extra},
      else: invalid("watch_writes")
  end

  defp results(name) when is_binary(name) and is_map_key(@results, name),
    do: {:ok, Map.fetch!(@results, name)}

  defp results(_name), do: invalid("calls_results")

  defp bounded(options, key, %{"default" => default, "min" => min, "max" => max}) do
    case Map.get(options, key, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _value -> invalid(key)
    end
  end

  defp functions(specs) when is_list(specs) and specs != [] do
    if Value.bounded_list?(specs, @max_functions) and specs == Enum.uniq(specs) do
      specs
      |> Enum.reduce_while({:ok, []}, fn spec, {:ok, parsed} ->
        case function(spec) do
          {:ok, mfa} -> {:cont, {:ok, [{spec, mfa} | parsed]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> unique()
    else
      invalid("calls")
    end
  end

  defp functions(_specs), do: invalid("calls")

  # Two spellings of one function (`Elixir.Mod` and `Mod`) are one function.
  defp unique({:ok, parsed}) do
    mfas = Enum.map(parsed, &elem(&1, 1))
    if mfas == Enum.uniq(mfas), do: {:ok, Enum.reverse(parsed)}, else: invalid("calls")
  end

  defp unique(error), do: error

  @doc """
  Resolves one `"MOD.FUN/ARITY"` to its loaded function, or the error an
  agent sees: `invalid_options` for a malformed spec, `untraceable_function`
  with its reason (`unknown_atom`, `not_loaded`, `not_found`, `protected`).
  """
  @spec function(term()) :: {:ok, mfa()} | {:error, map()}
  def function(spec) when is_binary(spec) and byte_size(spec) <= @spec_bytes do
    with {:ok, module, name, arity} <- split(spec),
         {:ok, module, function} <- atoms(spec, module, name),
         :ok <- traceable(spec, module, function, arity) do
      {:ok, {module, function, arity}}
    end
  end

  def function(_spec), do: invalid("calls")

  defp split(spec) do
    with [head, arity] <- split_last(spec, "/"),
         {arity, ""} when arity in 0..255 <- Integer.parse(arity),
         [module, name] <- split_last(head, "."),
         true <- Regex.match?(@function, name),
         {:ok, module} <- module_name(module) do
      {:ok, module, name, arity}
    else
      _malformed -> invalid("calls")
    end
  end

  defp split_last(text, separator) do
    case String.split(text, separator) do
      [_one] -> :error
      parts -> [parts |> Enum.drop(-1) |> Enum.join(separator), List.last(parts)]
    end
  end

  defp module_name(":" <> _rest = module) do
    if Regex.match?(@erlang_module, module),
      do: {:ok, binary_part(module, 1, byte_size(module) - 1)},
      else: :error
  end

  defp module_name("Elixir." <> rest), do: module_name(rest)

  defp module_name(module) do
    if Regex.match?(@elixir_module, module), do: {:ok, "Elixir." <> module}, else: :error
  end

  defp atoms(spec, module, name) do
    {:ok, String.to_existing_atom(module), String.to_existing_atom(name)}
  rescue
    ArgumentError -> untraceable(spec, "unknown_atom")
  end

  defp traceable(spec, module, function, arity) do
    cond do
      protected?(module) -> untraceable(spec, "protected")
      :code.is_loaded(module) == false -> untraceable(spec, "not_loaded")
      {function, arity} in :erlang.get_module_info(module, :functions) -> :ok
      true -> untraceable(spec, "not_found")
    end
  end

  defp protected?(module) do
    name = Atom.to_string(module)

    module == Insider or String.starts_with?(name, "Elixir.Insider.") or
      :code.is_loaded(module) == {:file, :preloaded}
  end

  defp untraceable(spec, reason),
    do: {:error, Error.new("untraceable_function", %{"function" => spec, "reason" => reason})}

  defp invalid(field), do: {:error, Error.new("invalid_options", %{"field" => field})}
end
