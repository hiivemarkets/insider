defmodule Insider.Adapter.MixTask do
  @moduledoc false

  alias Insider.Adapter.CLI
  alias Insider.Adapter.CLI.Wire
  alias Insider.Runtime

  @request_timeout_ms 1_000

  @spec run([String.t()], atom()) :: {binary(), non_neg_integer()}
  def run(arguments, mix_environment) do
    run_in_environment(arguments, runtime_environment(mix_environment))
  end

  defp run_in_environment(["capabilities"], environment),
    do: invoke("runtime.capabilities", %{}, environment)

  defp run_in_environment(["inspect" | arguments], environment) do
    with {:ok, pid} <- target(arguments) do
      invoke("process.describe", %{"pid" => pid_string(pid)}, environment,
        capability: Runtime.observation_capability()
      )
    else
      {:error, code} -> input_error(code)
    end
  end

  defp run_in_environment(_arguments, _environment), do: input_error("usage")

  defp invoke(operation, params, environment, extra \\ []) do
    request = %{
      "schema" => "insider.request/v1",
      "protocol" => "insider.protocol/v1",
      "operation" => operation,
      "request_id" => request_id(),
      "environment" => Atom.to_string(environment),
      "timeout_ms" => @request_timeout_ms,
      "budget" => %{
        "max_duration_ms" => @request_timeout_ms,
        "max_events" => 1,
        "max_bytes" => 65_536,
        "max_targets" => 1
      },
      "params" => params
    }

    request =
      Enum.reduce(extra, request, fn {key, value}, result ->
        Map.put(result, to_string(key), value)
      end)

    {:ok, host_policy} = Runtime.bind_host_policy(host_protected_targets: [])

    CLI.invoke_json(
      Jason.encode!(request),
      &Runtime.dispatch(&1, [environment: environment], host_policy)
    )
  end

  defp target(arguments) do
    case OptionParser.parse(arguments,
           strict: [name: :string],
           aliases: [n: :name]
         ) do
      {[name: value], [], []} -> registered_process(value)
      _other -> {:error, "invalid_target"}
    end
  end

  defp registered_process(value) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, name} <- existing_atom(value),
         pid when is_pid(pid) <- Process.whereis(name) do
      {:ok, pid}
    else
      _missing -> {:error, "process_not_found"}
    end
  end

  defp registered_process(_value), do: {:error, "invalid_name"}

  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp input_error(code) do
    {:ok, json} =
      Wire.encode(%{
        "schema" => "insider.mix-task.error/v1",
        "status" => "invalid_input",
        "error" => %{"code" => code},
        "usage" => [
          "mix insider capabilities",
          "mix insider inspect --name Elixir.MyApp.Supervisor"
        ]
      })

    {json <> "\n", 64}
  end

  defp runtime_environment(:dev), do: :development
  defp runtime_environment(environment), do: environment

  defp request_id, do: "mix-" <> Integer.to_string(System.unique_integer([:positive]))
  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> to_string()
end
