defmodule Insider.LoadHarness.RuntimeIdentity do
  @moduledoc false

  @spec capture() :: map()
  def capture do
    %{
      "elixir" => System.version(),
      "otp" => system_string(:otp_release),
      "erts" => system_string(:version),
      "os" => os_version(),
      "architecture" => system_string(:system_architecture),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "schedulers_total" => :erlang.system_info(:schedulers)
    }
  end

  defp system_string(key) do
    case :erlang.system_info(key) do
      value when is_list(value) -> List.to_string(value)
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp os_version do
    {family, name} = :os.type()
    version = :os.version() |> Tuple.to_list() |> Enum.join(".")
    Enum.join([family, name, version], "-")
  end
end
