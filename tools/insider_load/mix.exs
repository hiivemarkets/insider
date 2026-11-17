defmodule InsiderLoad.MixProject do
  use Mix.Project

  def project do
    [
      app: :insider_load,
      version: "0.1.0-dev",
      elixir: ">= 1.17.0 and < 2.0.0",
      build_path: "../../_build/insider_load",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:insider, path: "../.."},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"}
    ]
  end
end
