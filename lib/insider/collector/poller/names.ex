defmodule Insider.Collector.Poller.Names do
  @moduledoc false

  # Code identifiers for Poller evidence: a registered name, a process's
  # initial call, and its current function, read with bounded
  # `process_info/2` items only. The only dictionary key ever read is
  # `$initial_call`; messages and the rest of the dictionary never are.
  # Elixir aliases are shown without their `Elixir.` prefix (`Shop.Pricing`,
  # `Shop.Pricing.init/1`), Erlang atoms as they are (`code_server`).

  @alias ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @erlang ~r/\A[a-z][A-Za-z0-9_@]*\z/
  @max_name_bytes 128

  @doc "An atom as an agent writes it: an Elixir alias without `Elixir.`."
  @spec display(atom()) :: String.t()
  def display(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> alias -> alias
      string -> string
    end
  end

  @doc "`Module.function/arity`, or `nil` for anything else."
  @spec mfa(term()) :: String.t() | nil
  def mfa({module, function, arity})
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..255,
      do: "#{display(module)}.#{Atom.to_string(function)}/#{arity}"

  def mfa(_value), do: nil

  @spec pid(pid()) :: String.t()
  def pid(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc """
  The registered name, initial call, and current function of a local
  process, each `nil` when absent or when the process has exited. The
  initial call is `$initial_call` when a `proc_lib` process set it (a
  GenServer's own module), else the call the process was spawned with.
  """
  @spec describe(pid()) :: %{String.t() => String.t() | nil}
  def describe(pid) when is_pid(pid) do
    items = [:registered_name, {:dictionary, :"$initial_call"}, :initial_call, :current_function]

    case :erlang.process_info(pid, items) do
      [
        {:registered_name, name},
        {{:dictionary, :"$initial_call"}, dictionary_call},
        {:initial_call, initial_call},
        {:current_function, current_function}
      ] ->
        %{
          "name" => registered(name),
          "initial_call" => mfa(dictionary_call) || mfa(initial_call),
          "current_function" => mfa(current_function)
        }

      _undefined ->
        %{"name" => nil, "initial_call" => nil, "current_function" => nil}
    end
  end

  @doc """
  Resolves a name an agent wrote (`Shop.Pricing`, `Elixir.Shop.Pricing`, or
  `my_server`) to the atom a process would be registered under, without
  creating an atom. `:unknown` when no such atom exists on this node, so no
  process can be registered under it.
  """
  @spec parse(term()) :: {:ok, atom()} | :unknown | :invalid
  def parse(name) when is_binary(name) and byte_size(name) in 1..@max_name_bytes do
    name = String.replace_prefix(name, "Elixir.", "")

    cond do
      String.match?(name, @alias) -> existing("Elixir." <> name)
      String.match?(name, @erlang) -> existing(name)
      true -> :invalid
    end
  end

  def parse(_name), do: :invalid

  defp existing(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :unknown
  end

  @local_pid ~r/\A<0\.[0-9]{1,10}\.[0-9]{1,10}>\z/

  @doc """
  Resolves a local pid as an agent writes it (`<0.200.0>`), or `:invalid`.
  Only this node's pids (first number 0) are accepted.
  """
  @spec parse_pid(term()) :: {:ok, pid()} | :invalid
  def parse_pid(text) when is_binary(text) and byte_size(text) <= 32 do
    if String.match?(text, @local_pid),
      do: {:ok, text |> String.to_charlist() |> :erlang.list_to_pid()},
      else: :invalid
  rescue
    ArgumentError -> :invalid
  end

  def parse_pid(_text), do: :invalid

  @doc """
  Who owns a table or a port, for the whole-node scans: `:insider` for
  Insider's own processes (the control plane in `insider`, or any process
  whose group leader is Insider's application `master`), else
  `{:owner, name}`. A protected owner is named from the inventory without
  being read; any other is named with `describe/1` (its registered name,
  else its initial call).
  """
  @spec owner_class(pid(), %{
          required(:insider) => MapSet.t(pid()),
          required(:protected) => %{pid() => atom() | nil},
          required(:master) => pid() | nil,
          optional(atom()) => term()
        }) :: :insider | {:owner, String.t() | nil}
  def owner_class(owner, context) do
    cond do
      MapSet.member?(context.insider, owner) ->
        :insider

      is_map_key(context.protected, owner) ->
        {:owner, protected_name(context.protected[owner])}

      insider_leader?(owner, context.master) ->
        :insider

      true ->
        identity = describe(owner)
        {:owner, identity["name"] || identity["initial_call"]}
    end
  end

  defp protected_name(nil), do: nil
  defp protected_name(name), do: display(name)

  @doc "Whether `pid`'s group leader is Insider's application `master`."
  @spec insider_leader?(pid(), pid() | nil) :: boolean()
  def insider_leader?(_pid, nil), do: false

  def insider_leader?(pid, master),
    do: match?({:group_leader, ^master}, :erlang.process_info(pid, :group_leader))

  defp registered(name) when is_atom(name), do: display(name)
  defp registered(_name), do: nil
end
