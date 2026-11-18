defmodule Insider.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/hiivemarkets/insider"

  # Modules none of whose work can run below OTP 28: they need isolated
  # trace sessions (`:trace.session_create/3`, OTP 28), and on OTP 27 only
  # their refusal (`requires_otp_28`) runs. Below OTP 28 they are left out
  # of the coverage total; OTP 28+ runs count them. A module with a
  # supported OTP 27 mode (the otel collector's ingest-only mode, the
  # system monitor's legacy backend) stays counted everywhere. See
  # decisions/2026-10-23_otp_28_only_modules_count_toward_coverage_on_otp_28_only.md.
  @otp_28_only_modules [
    Insider.Collector.Calls,
    Insider.Collector.Calls.Tracing,
    Insider.Collector.Otel.Tracing
  ]

  def project do
    [
      app: :insider,
      version: @version,
      elixir: ">= 1.17.0 and < 2.0.0",
      description:
        "The BEAM accessory for agents, by agents. A runtime-evidence library that attaches " <>
          "to a running development node and gives a coding agent a bounded, masked window " <>
          "of what the node did: structured events, request traces and process snapshots.",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        tool: Insider.TestSupport.CoverageTool,
        # Reporting runs after the coverage snapshot, so the reporter cannot
        # observe its own main path. It is exercised directly by unit tests.
        ignore_modules: [Insider.TestSupport.CoverageTool | coverage_otp_exclusions()],
        summary: [threshold: 90]
      ],
      # recon is optional at run time: Insider calls it only when a node has it.
      dialyzer: [plt_add_apps: [:mix, :recon]],
      deps: deps(),
      aliases: aliases(),
      name: "Insider",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  @doc false
  def otp_28_only_modules, do: @otp_28_only_modules

  defp coverage_otp_exclusions do
    if String.to_integer(System.otp_release()) < 28, do: @otp_28_only_modules, else: []
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Insider.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The agent-oriented analysis tools currently require Elixir 1.18+.
      # Keep them in the maintainer environment so the Elixir 1.17 runtime
      # compatibility lane exercises only Insider's runtime/test dependency graph.
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_dna, "~> 1.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4.4", only: :dev, runtime: false},
      {:jump_credo_checks, "~> 0.7.1", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      # The OpenTelemetry SDK is test-only and never started in the test
      # node: the otel component's tests start it in a peer node, or call
      # its span functions directly. The core never depends on it.
      {:opentelemetry, "~> 1.7", only: :test, runtime: false},
      {:opentelemetry_api, "~> 1.5", only: :test, runtime: false},
      # Tests run the inspections with recon loaded and without it, and
      # Dialyzer checks the calls. Insider itself never depends on recon; it
      # uses recon when the node has it.
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: :test},
      {:telemetry, "~> 1.3"}
    ]
  end

  # Generated documentation for the root application. The two tool projects
  # are separate Mix projects, so their modules are not compiled here; their
  # READMEs are included as extras and Lab publishes its own API reference.
  # ExDoc resolves relative `.md` links by basename and the last extra with a
  # given basename in the rendered (group) order wins. Relative `README.md`
  # links point at the documentation index, so `docs/README.md` must be the
  # last README.md: it is the last extra of the last group. Links to the root
  # README and the other READMEs use absolute repository URLs. The reference
  # files are listed in the order of the index; a test checks that every
  # file under `docs/` is an extra.
  defp docs do
    people =
      ~w(overview try-it-locally how-a-session-works safety-model what-exists-today)
      |> Enum.map(&"guides/people/#{&1}.md")

    agents =
      ~w(live-observation reading-a-report refusals candidates-cli oracles privacy-corpus
         protocol-and-mix-task sentinel-chain load-harness)
      |> Enum.map(&"guides/agents/#{&1}.md")

    # The listed order is the reading order. A new guide still renders, last.
    guides = people ++ agents ++ (Path.wildcard("guides/**/*.md") -- (people ++ agents))

    tool_readmes =
      for readme <- Path.wildcard("tools/*/README.md") do
        {readme, filename: Path.basename(Path.dirname(readme)) <> "-readme"}
      end

    reference = [
      "docs/getting-started.md",
      "docs/cheat-sheet.md",
      "docs/glossary.md",
      "docs/live/live-api-and-transports.md",
      "docs/live/live-sessions-and-readers.md",
      "docs/live/live-digest-filters-and-trends.md",
      "docs/live/live-runtime-evidence.md",
      "docs/live/live-otel-traces.md",
      "docs/live/live-welcome-and-reports.md",
      "docs/collectors.md",
      "docs/disclosure-and-safety.md",
      "docs/lab-candidates-and-oracles.md",
      "docs/lab-cli.md",
      "docs/architecture.md",
      "docs/sentinel-and-proof-workflow.md",
      "docs/incident-capsules-and-provenance.md",
      "docs/development.md",
      "docs/status-and-roadmap.md"
    ]

    readiness =
      Path.wildcard("docs/*.md") -- ["docs/README.md" | reference]

    [
      main: "readme",
      # Source links point at the release tag, so hexdocs shows the code of
      # the published version.
      source_ref: "v#{@version}",
      assets: %{"docs/assets" => "docs/assets"},
      extras:
        [{"README.md", filename: "readme", title: "Insider"}] ++
          reference ++
          [
            {"guides/people/overview.md", title: "Overview"}
            | guides -- ["guides/people/overview.md"]
          ] ++
          [{"usage-rules.md", filename: "usage-rules"}] ++
          readiness ++
          [{"decisions/README.md", filename: "decisions-readme"}] ++
          tool_readmes ++
          [
            "CHANGELOG.md",
            {"AGENTS.md", filename: "agents"},
            {"docs/README.md", filename: "docs-index", title: "Documentation index"}
          ],
      groups_for_extras: [
        "Getting started": ~r{^(README\.md|docs/(getting-started|cheat-sheet|glossary)\.md)$},
        "Insider Live": ~r{^docs/live/},
        Collectors: ~r{^docs/collectors\.md$},
        "Safety and disclosure": ~r{^docs/disclosure-and-safety\.md$},
        Lab: ~r{^docs/lab-},
        Architecture:
          ~r{^docs/(architecture|sentinel-and-proof-workflow|incident-capsules-and-provenance)\.md$},
        Development: ~r{^docs/(development|status-and-roadmap)\.md$},
        "For people": ~r{^guides/people/},
        "For agents": ~r{^guides/agents/|^usage-rules\.md$},
        "Readiness artifacts (no authority)": ~r{^docs/(production-|staged-canary-)|^decisions/},
        Reference: ~r{^(CHANGELOG|AGENTS)\.md$|^tools/|^docs/README\.md$}
      ],
      groups_for_modules: [
        Facade: [Insider, Insider.Runtime, Insider.Runtime.HostPolicy],
        Live: ~r{^Insider\.Live},
        Protocol: ~r{^Insider\.Protocol},
        Policy: ~r{^Insider\.Policy},
        Collector: ~r{^Insider\.Collector},
        Recorder: ~r{^Insider\.Recorder},
        Detectors: ~r{^Insider\.(Detectors|Finding)},
        "Events and identity": ~r{^Insider\.(Event|Identity|Provenance)},
        Incident: ~r{^Insider\.Incident},
        Redaction: ~r{^Insider\.Redaction},
        Observability: ~r{^Insider\.Observability}
      ],
      # Prose in the moduledocs, `docs/`, the guides, and the CHANGELOG
      # deliberately names internal (`@moduledoc false` or `@doc false`)
      # modules and helpers so a reader can find the code, and the
      # `:telemetry_test` callback; none is a documented entry point.
      skip_code_autolink_to: [
        ":telemetry_test.handle_event/4",
        "Insider.Application",
        "Insider.Collector.Calls.Trace",
        "Insider.Collector.Calls.Tracing",
        "Insider.Collector.Gate",
        "Insider.Collector.Gate.max_bursts/0",
        "Insider.Collector.GraphqlOutcome",
        "Insider.Collector.Logger.Handler",
        "Insider.Collector.ObanJob",
        "Insider.Collector.Otel.Span",
        "Insider.Collector.Otel.Tracing",
        "Insider.Collector.RequestTiming",
        "Insider.Collector.Rich",
        "Insider.Collector.Session.Manager",
        "Insider.Collector.Telemetry.Handler",
        "Insider.Collector.Telemetry.Outcome",
        "Insider.Event.validate_encoded/1",
        "Insider.Live.Anomalies",
        "Insider.Live.Build",
        "Insider.Live.Build.identity/0",
        "Insider.Live.Disclosure.contract/0",
        "Insider.Live.Filters.describe/0",
        "Insider.Live.Gates",
        "Insider.Live.Mutations",
        "Insider.Live.Owner",
        "Insider.Live.QueryShapes",
        "Insider.Live.Reports",
        "Insider.Live.Retention",
        "Insider.Live.View",
        "Insider.Live.View.hides/2"
      ]
    ]
  end

  # The package: the library, its reference documentation, its agent guides,
  # and `usage-rules.md`, which `mix usage_rules.sync` reads from
  # `deps/insider/`. `docs/` ships whole: its readiness artifacts are
  # public-neutral by test. `docs/development.md` "Releasing" has the release
  # procedure.
  defp package do
    [
      files:
        ~w(lib docs guides usage-rules.md mix.exs mix.lock README.md CHANGELOG.md LICENSE LICENSES THIRD_PARTY_NOTICES.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Docs" => "https://hexdocs.pm/insider"
      }
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      # The readiness docs link the JSON evidence next to them. ex_doc copies
      # only `assets` directories, so the JSON is copied beside the pages.
      docs: ["docs", &copy_docs_json/1],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix test",
        "cmd env MIX_ENV=prod mix compile --warnings-as-errors",
        "cmd env INSIDER_ARTIFACT_SKIP_FRESH_BUILD=1 INSIDER_EBIN_DIR=_build/prod/lib/insider/ebin bash scripts/verify-production-artifact",
        "credo --strict"
      ],
      "quality.deep": [
        "quality",
        "ex_dna",
        "dialyzer"
      ]
    ]
  end

  defp copy_docs_json(_args) do
    for path <- Path.wildcard("docs/*.json"),
        do: File.cp!(path, Path.join("doc", Path.basename(path)))
  end
end
