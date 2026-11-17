defmodule Insider.Live.InspectOptions do
  @moduledoc false

  # The options of the one-shot inspections (`Insider.Live.process/1`,
  # `bin_leak/1`, `ports/1`, and `alloc/1`). A process is named by a
  # registered name, which resolves only to an atom that already exists on
  # this node, or by a local pid written `<0.200.0>`; a caller can never
  # create atoms.

  alias Insider.Collector.Poller.Names
  alias Insider.Live.Error
  alias Insider.Live.Options

  @frames %{"default" => 10, "min" => 1, "max" => 32}
  @messages %{"default" => 10, "min" => 0, "max" => 50}
  @bin_leak_top %{"default" => 10, "min" => 1, "max" => 50}
  @ports_top %{"default" => 20, "min" => 1, "max" => 200}
  @alloc_top %{"default" => 8, "min" => 1, "max" => 32}
  @type_pattern ~r/\A[A-Za-z0-9_.+@-]{1,64}\z/

  @keys %{
    "process" => ["frames", "messages", "name", "pid"],
    "bin_leak" => ["human", "top"],
    "ports" => ["owner", "top", "type"],
    "alloc" => ["top"]
  }

  @type target :: {:name, atom()} | {:pid, pid()}

  @doc "Each inspection's option keys."
  @spec keys(String.t()) :: [String.t()]
  def keys(operation), do: Map.fetch!(@keys, operation)

  @doc "The inspections' option groups for `Insider.Live.Options.describe/0`."
  @spec describe() :: map()
  def describe do
    process_name = %{
      "type" => "string",
      "default" => nil,
      "note" => "a registered name such as MyApp.Worker or my_server; give name or pid, not both"
    }

    %{
      "process" => %{
        "name" => process_name,
        "pid" => %{
          "type" => "string",
          "default" => nil,
          "pattern" => "<0.N.N>",
          "note" =>
            "a local pid such as <0.200.0>, as Insider's events write it; give name or pid"
        },
        "frames" =>
          Map.merge(@frames, %{
            "type" => "integer",
            "note" => "stacktrace frames returned, innermost first"
          }),
        "messages" =>
          Map.merge(@messages, %{
            "type" => "integer",
            "note" =>
              "the shapes of the first N queued messages, oldest first; never a message's values"
          })
      },
      "bin_leak" => %{
        "top" =>
          Map.merge(@bin_leak_top, %{
            "type" => "integer",
            "note" => "processes in each ranking (by_retained_bytes, by_freed_bytes)"
          }),
        "human" => %{
          "type" => "boolean",
          "default" => false,
          "note" =>
            "true adds \"text\", a short plain-text summary that names the biggest holder first"
        }
      },
      "ports" => %{
        "type" => %{
          "type" => "string",
          "default" => nil,
          "pattern" => Regex.source(@type_pattern),
          "note" =>
            "lists only ports of this type: the port's program name without a directory, such as cat or tcp_inet"
        },
        "owner" =>
          Map.merge(process_name, %{
            "note" =>
              "lists only ports owned (connected) by this process: a registered name such as MyApp.Worker, or a pid such as <0.200.0>"
          }),
        "top" =>
          Map.merge(@ports_top, %{
            "type" => "integer",
            "note" => "ports listed, and entries in types and owners"
          })
      },
      "alloc" => %{
        "top" =>
          Map.merge(@alloc_top, %{
            "type" => "integer",
            "note" => "allocator instances in fragmentation, largest multiblock carriers first"
          })
      }
    }
  end

  @doc "The `process/1` options: the target and the frame and message counts."
  @spec process(term()) ::
          {:ok, %{target: target(), frames: pos_integer(), messages: non_neg_integer()}}
          | {:error, map()}
  def process(options) when is_map(options) and not is_struct(options) do
    with :ok <- known(options, "process"),
         {:ok, target} <- target(options),
         {:ok, frames} <- Options.bounded_integer(options, "frames", @frames),
         {:ok, messages} <- Options.bounded_integer(options, "messages", @messages) do
      {:ok, %{target: target, frames: frames, messages: messages}}
    end
  end

  def process(_options), do: invalid("options")

  @doc "The `bin_leak/1` options."
  @spec bin_leak(term()) :: {:ok, %{top: pos_integer(), human: boolean()}} | {:error, map()}
  def bin_leak(options) when is_map(options) and not is_struct(options) do
    with :ok <- known(options, "bin_leak"),
         {:ok, top} <- Options.bounded_integer(options, "top", @bin_leak_top) do
      case Map.get(options, "human", false) do
        human when is_boolean(human) -> {:ok, %{top: top, human: human}}
        _human -> invalid("human")
      end
    end
  end

  def bin_leak(_options), do: invalid("options")

  @doc "The `ports/1` options: the type and owner filters and the list bound."
  @spec ports(term()) ::
          {:ok, %{type: String.t() | nil, owner: target() | nil, top: pos_integer()}}
          | {:error, map()}
  def ports(options) when is_map(options) and not is_struct(options) do
    with :ok <- known(options, "ports"),
         {:ok, type} <- port_type(Map.get(options, "type")),
         {:ok, owner} <- owner(Map.get(options, "owner")),
         {:ok, top} <- Options.bounded_integer(options, "top", @ports_top) do
      {:ok, %{type: type, owner: owner, top: top}}
    end
  end

  def ports(_options), do: invalid("options")

  @doc "The `alloc/1` options."
  @spec alloc(term()) :: {:ok, %{top: pos_integer()}} | {:error, map()}
  def alloc(options) when is_map(options) and not is_struct(options) do
    with :ok <- known(options, "alloc"),
         {:ok, top} <- Options.bounded_integer(options, "top", @alloc_top),
         do: {:ok, %{top: top}}
  end

  def alloc(_options), do: invalid("options")

  defp known(options, operation) do
    case options |> Map.keys() |> Enum.reject(&(&1 in Map.fetch!(@keys, operation))) do
      [] -> :ok
      [key | _rest] when is_binary(key) and byte_size(key) <= 64 -> invalid(key)
      _other -> invalid("options")
    end
  end

  defp target(%{"name" => _name, "pid" => _pid}), do: invalid("pid")
  defp target(%{"name" => name}), do: name(name, "name")
  defp target(%{"pid" => pid}), do: pid(pid, "pid")
  defp target(_options), do: invalid("name")

  defp owner(nil), do: {:ok, nil}
  defp owner("<" <> _rest = pid), do: pid(pid, "owner")
  defp owner(name), do: name(name, "owner")

  defp name(name, field) do
    case Names.parse(name) do
      {:ok, atom} -> {:ok, {:name, atom}}
      :unknown -> {:error, Error.new("unknown_process_name", %{"name" => name})}
      :invalid -> invalid(field)
    end
  end

  defp pid(text, field) do
    case Names.parse_pid(text) do
      {:ok, pid} -> {:ok, {:pid, pid}}
      :invalid -> invalid(field)
    end
  end

  defp port_type(nil), do: {:ok, nil}

  defp port_type(type) when is_binary(type),
    do: if(String.match?(type, @type_pattern), do: {:ok, type}, else: invalid("type"))

  defp port_type(_type), do: invalid("type")

  defp invalid(field), do: {:error, Error.new("invalid_options", %{"field" => field})}
end
