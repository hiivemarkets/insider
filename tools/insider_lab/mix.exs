defmodule InsiderLab.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hiivemarkets/insider"

  def project do
    hex? = hex_form?(System.get_env("INSIDER_LAB_HEX"), __DIR__)

    [
      app: :insider_lab,
      version: @version,
      elixir: ">= 1.17.0 and < 2.0.0",
      description:
        "The Insider observer CLI and Mix tasks: attach to a running development BEAM node, " <>
          "load Insider into it, and read a bounded, masked window of what it did. " <>
          "Also the development-only test oracles, candidate inventory and Sentinel.",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Insider.Adapter.CLI,
        # `mix escript.install` reads the escript from the file that `name`
        # names, so the default path and the name agree.
        name: "insider-lab",
        path: System.get_env("INSIDER_ESCRIPT_PATH", "insider-lab"),
        # A command does little work. With one scheduler per core, each
        # busy-waiting, a call on a loaded host spent 10-17 s booting the VM
        # before main ran; two schedulers that sleep instead of spinning boot
        # in well under a second there.
        emu_args: "+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none"
      ],
      deps: deps(hex?),
      aliases: machine_output_aliases(),
      name: "Insider Lab",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ] ++ repository_paths(hex?)
  end

  # The Lab depends on the core. In this repository it builds against the
  # core next to it, by path, and shares the root's build, dependency and lock
  # paths. A Hex package cannot carry a path dependency, so the package names
  # the core on Hex, at the Lab's own version. `INSIDER_LAB_HEX=1` selects the
  # Hex form here, to build or publish the package. Outside this repository
  # (the unpacked package that `mix escript.install hex insider_lab` builds,
  # or a dependency of another project) the Hex form is the only one. See
  # decisions/2026-11-16_insider_and_the_lab_publish_to_hex_under_an_organization.md.
  @doc false
  def hex_form?(switch, directory), do: switch == "1" or not in_repository?(directory)

  defp in_repository?(directory) do
    Path.expand("../../tools/insider_lab", directory) == Path.expand(directory) and
      File.regular?(Path.expand("../../lib/insider.ex", directory))
  end

  @doc false
  def insider_dependency(true), do: {:insider, "~> " <> @version}
  def insider_dependency(false), do: {:insider, path: "../.."}

  @doc false
  def repository_paths(true), do: []

  def repository_paths(false),
    do: [
      build_path: "../../_build/insider_lab",
      deps_path: "../../deps",
      lockfile: "../../mix.lock"
    ]

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Insider.Lab.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Mix compiles the project before running any of its tasks and prints the
  # compiler's progress on standard output, ahead of the task's JSON document.
  # Each task that writes a machine-readable document on standard output
  # compiles first under a shell that sends that progress to standard error.
  @machine_output_tasks ~w(insider insider.candidates insider.live insider.oracle insider.privacy_corpus)

  defp machine_output_aliases do
    for task <- @machine_output_tasks,
        do: {String.to_atom(task), [&compile_to_stderr/1, task]}
  end

  defp compile_to_stderr(_arguments) do
    shell = Mix.shell()
    Mix.shell(InsiderLab.MixProject.StderrShell)

    try do
      Mix.Task.run("compile")
    after
      Mix.shell(shell)
    end
  end

  defp deps(hex?) do
    [
      insider_dependency(hex?),
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:opentelemetry_api, "~> 1.5", only: :test},
      # On a live peer's code path only (`LivePeer.start/2`, `otel: true`),
      # never started here: the otel component needs the SDK's modules.
      {:opentelemetry, "~> 1.7", only: :test, runtime: false},
      # BSD-3-Clause. Pushed into a development target by `--load` when it
      # lacks recon, so `alloc` works there.
      {:recon, "~> 2.5"},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end

  # The package: the Lab's code, its fixed oracles, runner and probes in
  # `priv/`, and its license. The Lab's escript and `--load` carry recon, so
  # the package also ships recon's BSD-3-Clause notice. `LICENSE` and
  # `LICENSES/` are copies of the root files, because a package holds only
  # files below its own directory. A test keeps them equal. Changes are in the
  # root CHANGELOG, which the package links.
  defp package do
    [
      name: "insider_lab",
      files: ~w(lib priv mix.exs README.md LICENSE LICENSES THIRD_PARTY_NOTICES.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Docs" => "https://hexdocs.pm/insider_lab"
      }
    ]
  end

  # API reference for Lab-only modules. The guides live in the root project
  # (`mix docs` at the repository root); this output is deliberately limited
  # to the modules the root cannot compile. Source links point at the release
  # tag, so hexdocs shows the code of the published version.
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tools/insider_lab/%{path}#L%{line}",
      extras: ["README.md"],
      groups_for_modules: [
        "Mix tasks and CLI": ~r{^(Mix\.Tasks\.Insider|Insider\.Adapter|Insider\.Lab\.Output)},
        Discovery: ~r{^Insider\.Discovery},
        "Privacy corpus": ~r{^Insider\.Lab\.PrivacyCorpus},
        "Contracts, scenarios, fixtures": ~r{^Insider\.(Contract|Invariant|Scenario|Fixtures)},
        "Incident capture": ~r{^Insider\.Incident},
        "Sentinel: sandbox and confirmation":
          ~r{^Insider\.Sentinel\.(Sandbox|Confirmation|ExternalProcess|Manifest)},
        "Sentinel: regression, minimizer, bisection":
          ~r{^Insider\.Sentinel\.(Regression|Minimizer|Bisection)},
        "Sentinel: repair orchestration": ~r{^Insider\.Sentinel}
      ],
      # The privacy corpus runner names the internal ingress handler functions
      # it drives; they are not documented entry points.
      skip_code_autolink_to: [
        "Insider.Collector.Logger.Handler.log/2",
        "Insider.Collector.Telemetry.Handler.handle_event/4"
      ]
    ]
  end
end

defmodule InsiderLab.MixProject.StderrShell do
  @moduledoc false
  # Mix.Shell.IO with every message, and the output of commands it runs, on
  # standard error.
  @behaviour Mix.Shell

  @impl Mix.Shell
  def info(message), do: IO.puts(:stderr, IO.ANSI.format(message))

  @impl Mix.Shell
  def error(message), do: Mix.Shell.IO.error(message)

  @impl Mix.Shell
  def print_app do
    if name = Mix.Shell.printable_app_name(), do: info("==> #{name}")
    :ok
  end

  @impl Mix.Shell
  def cmd(command, options \\ []),
    do: Mix.Shell.cmd(command, options, &IO.write(:stderr, &1))

  @impl Mix.Shell
  def prompt(message), do: Mix.Shell.IO.prompt(message)

  @impl Mix.Shell
  def yes?(message, options \\ []), do: Mix.Shell.IO.yes?(message, options)
end
