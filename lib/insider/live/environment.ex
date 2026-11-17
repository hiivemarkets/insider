defmodule Insider.Live.Environment do
  @moduledoc false

  # Live observation trusts only host-level facts about the node it runs in,
  # never a caller-supplied environment. Explicit `:insider, :environment`
  # application configuration wins. Otherwise a node launched by Mix (for
  # example `iex -S mix` or `mix phx.server`) reports its Mix environment. A
  # release without configuration has neither and is denied.

  @known [:development, :test, :ci, :staging, :production]
  @allowed [:development, :test, :ci]
  @mix_environments %{
    dev: :development,
    test: :test,
    ci: :ci,
    staging: :staging,
    prod: :production
  }

  @type environment :: :development | :test | :ci | :staging | :production
  @type resolved :: %{
          environment: environment() | :unconfigured | :unrecognized,
          source: :application_env | :mix_env | :none
        }

  @spec resolve() :: resolved()
  def resolve, do: resolve(Application.started_applications())

  # `started` is the node's running application list; it decides whether a
  # Mix environment exists.
  @spec resolve([tuple()]) :: resolved()
  def resolve(started) when is_list(started) do
    case Application.fetch_env(:insider, :environment) do
      {:ok, value} when value in @known -> %{environment: value, source: :application_env}
      {:ok, _value} -> %{environment: :unrecognized, source: :application_env}
      :error -> mix_environment(started)
    end
  end

  @spec allowed?(resolved()) :: boolean()
  def allowed?(%{environment: environment}), do: environment in @allowed

  @spec describe(resolved()) :: map()
  def describe(%{environment: environment, source: source} = resolved) do
    %{
      "environment" => Atom.to_string(environment),
      "environment_source" => Atom.to_string(source),
      "allowed" => allowed?(resolved)
    }
  end

  # Mix's modules are on the code path of every Elixir node, but its
  # environment exists only while the `:mix` application runs, as under
  # `iex -S mix` or `mix phx.server`. A plain `elixir` node is unconfigured.
  defp mix_environment(started) do
    if List.keymember?(started, :mix, 0) do
      %{environment: Map.get(@mix_environments, Mix.env(), :unrecognized), source: :mix_env}
    else
      %{environment: :unconfigured, source: :none}
    end
  end
end
