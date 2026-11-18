defmodule Insider.ProductionArtifactBoundaryTest do
  use ExUnit.Case, async: true
  # Each test runs the artifact gate in nested Mix builds. Under `mix test --cover`
  # on 2-vCPU CI runners one test can exceed ExUnit's 60 s default.
  @moduletag timeout: 600_000

  @root Path.expand("..", __DIR__)
  @gate Path.join(@root, "scripts/verify-production-artifact")
  # The package metadata names the Lab, so hex.pm sends a reader to the CLI:
  # the description's last sentence and the "CLI (insider_lab)" link. Each
  # permitted source line must match in full, and no other line may name the
  # Lab, so a Lab path cannot hide on a permitted line.
  @description "The BEAM accessory for agents, by agents. A runtime-evidence library that " <>
                 "attaches to a running development node and gives a coding agent a bounded, " <>
                 "masked window of what the node did. The command-line observer and its Mix " <>
                 "tasks ship separately as insider_lab."
  @lab_metadata_lines [
    ~s{"as insider_lab.",},
    ~s{"CLI (insider_lab)" => "https://hex.pm/packages/insider_lab"}
  ]

  @lab_entries [
    {"lib/insider/sentinel/injected.ex", "Elixir.Insider.Sentinel.Injected"},
    {"lib/insider/sentinel/source_ownership.ex", "Elixir.Insider.Sentinel.SourceOwnership"},
    {"lib/insider/sentinel/coding_agent/handoff.ex",
     "Elixir.Insider.Sentinel.CodingAgent.Handoff"},
    {"lib/insider/sentinel/coding_agent/candidate_submission.ex",
     "Elixir.Insider.Sentinel.CodingAgent.CandidateSubmission"},
    {"lib/insider/sentinel/draft_creation/executor.ex",
     "Elixir.Insider.Sentinel.DraftCreation.Executor"},
    {"lib/insider/sentinel/draft_creation/request.ex",
     "Elixir.Insider.Sentinel.DraftCreation.Request"},
    {"lib/insider/sentinel/draft_creation/receipt.ex",
     "Elixir.Insider.Sentinel.DraftCreation.Receipt"},
    {"lib/insider/fixtures/injected.ex", "Elixir.Insider.Fixtures.Injected"},
    {"lib/insider/scenario/injected.ex", "Elixir.Insider.Scenario.Injected"},
    {"lib/insider/contract/injected.ex", "Elixir.Insider.Contract.Injected"},
    {"lib/insider/invariant.ex", "Elixir.Insider.Invariant"},
    {"lib/insider/adapter/cli/injected.ex", "Elixir.Insider.Adapter.CLI.Injected"},
    {"lib/insider/adapter/mix_task.ex", "Elixir.Insider.Adapter.MixTask"},
    {"lib/insider/incident/restart_capture/injected.ex",
     "Elixir.Insider.Incident.RestartCapture.Injected"},
    {"lib/insider/lab/injected.ex", "Elixir.Insider.Lab.Injected"},
    {"lib/insider_lab/application.ex", "Elixir.Insider.Lab.Application"},
    {"lib/mix/tasks/insider.ex", "Elixir.Mix.Tasks.Insider"}
  ]

  test "the core application adds the live owner and report queue only where live observation is allowed" do
    root = Insider.Collector.Session.RootSupervisor

    for environment <- [:staging, :production, :unconfigured, :unrecognized] do
      assert Insider.Application.children(%{environment: environment, source: :none}) == [root]
    end

    for environment <- [:development, :test, :ci] do
      assert Insider.Application.children(%{environment: environment, source: :mix_env}) ==
               [root, Insider.Live.Gates, Insider.Live.Owner, Insider.Live.Reports]
    end
  end

  test "source and compiled inventories exclude Lab-only capabilities" do
    assert {_, 0} = run_gate()

    assert {output, 1} =
             run_gate(%{
               "INSIDER_ARTIFACT_NETWORK_SOURCE_ENTRY" => ":httpc.request(:get, request, [], [])",
               "INSIDER_ARTIFACT_NETWORK_IMPORT_ENTRY" => "httpc"
             })

    assert output =~ "network authority"

    for dynamic_dispatch <- [
          "apply(:httpc, :request, args)",
          ":erlang.apply(\n  :ssl,\n  :connect,\n  args\n)",
          "Kernel.apply(Req, :get, args)",
          "transport = :httpc\napply(transport, :request, args)",
          "dispatch = &apply/3\ndispatch.(:httpc, :request, args)",
          "Function.capture(:httpc, :request, 4)",
          "apply((:httpc), :request, args)",
          ~S|apply(:"httpc", :request, args)|,
          "apply(\n  # selected client\n  :httpc,\n  :request,\n  args\n)"
        ] do
      assert {dynamic_output, 1} =
               run_gate(%{"INSIDER_ARTIFACT_NETWORK_SOURCE_ENTRY" => dynamic_dispatch})

      assert dynamic_output =~ "network authority"
    end

    assert {duplicate_output, 1} =
             run_gate(%{
               "INSIDER_ARTIFACT_DYNAMIC_DISPATCH_MATCH_ENTRY" =>
                 "lib/insider/collector/poller.ex:999:    apply(provider, function, arguments)"
             })

    assert duplicate_output =~ "network authority"

    assert {compiled_output, 1} =
             run_gate(%{"INSIDER_ARTIFACT_NETWORK_IMPORT_ENTRY" => "httpc"})

    assert compiled_output =~ "compiled imports expose network authority"

    assert {_, 0} =
             run_gate(%{
               "INSIDER_ARTIFACT_NETWORK_SOURCE_ENTRY" => "ordinary pure mapping",
               "INSIDER_ARTIFACT_NETWORK_IMPORT_ENTRY" => "Elixir.Enum"
             })
  end

  test "every excluded Lab namespace fails each source and compiled inventory" do
    for {source_entry, module_entry} <- @lab_entries do
      assert {source_output, 1} =
               run_gate(%{"INSIDER_ARTIFACT_SOURCE_ENTRY" => source_entry})

      assert source_output =~ "source inventory"

      assert {compiled_output, 1} =
               run_gate(%{"INSIDER_ARTIFACT_MODULE_ENTRY" => module_entry})

      assert compiled_output =~ "compiled inventory"
    end
  end

  test "the source inventory gate fails closed for an injected linked Lab entry" do
    assert {output, 1} =
             run_gate(%{"INSIDER_ARTIFACT_SOURCE_LINK_ENTRY" => "tools/insider_lab/lib"})

    assert output =~ "linked source"
  end

  test "the structural application and release inventories fail closed for injected Lab modules" do
    for {_source_entry, module_entry} <- @lab_entries do
      assert {app_output, 1} =
               run_gate(%{"INSIDER_ARTIFACT_APP_MODULE_ENTRY" => module_entry})

      assert app_output =~ "application inventory"

      assert {release_output, 1} =
               run_gate(%{"INSIDER_ARTIFACT_RELEASE_MODULE_ENTRY" => module_entry})

      assert release_output =~ "release compiled inventory"
    end

    assert {release_application_output, 1} =
             run_gate(%{"INSIDER_ARTIFACT_RELEASE_APPLICATION_ENTRY" => "insider_lab-0.1.0"})

    assert release_application_output =~ "release contains the Lab application"
  end

  test "the production package does not declare an escript or Lab-only dependency" do
    assert Insider.Application.children(%{environment: :production, source: :none}) ==
             [Insider.Collector.Session.RootSupervisor]

    project = File.read!(Path.join(@root, "mix.exs"))

    refute project =~ "escript:"
    refute project =~ "{:insider_lab"
    refute project =~ "tools/insider_lab"
    refute Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == :insider_lab))
    assert lab_mentions_are_metadata_only?(project)

    config = Mix.Project.config()
    assert config[:description] == @description

    assert Enum.filter(config[:package][:links], fn {_name, url} -> url =~ "insider_lab" end) ==
             [{"CLI (insider_lab)", "https://hex.pm/packages/insider_lab"}]

    for dependency <- ["sentry", "datadog", "req", "finch", "tesla", "hackney"] do
      refute project =~ ~s({:#{dependency},)
    end
  end

  test "a Lab mention anywhere but the two metadata lines fails the boundary check" do
    project = File.read!(Path.join(@root, "mix.exs"))
    [description_line, link_line] = @lab_metadata_lines

    extra_expression_on_description =
      String.replace(
        project,
        description_line,
        ~s{"as insider_lab." <> Path.join(["tools", "insider_lab", "lib"]),}
      )

    extra_expression_on_link =
      String.replace(
        project,
        link_line,
        link_line <> ~s{, "Lab" => Path.join(["tools", "insider_lab", "lib"])}
      )

    lab_source_path =
      String.replace(
        project,
        "elixirc_paths: elixirc_paths(Mix.env()),",
        ~s{elixirc_paths: [Path.join(["tools", "insider_lab", "lib"])],}
      )

    for variant <- [extra_expression_on_description, extra_expression_on_link, lab_source_path] do
      refute variant == project
      refute lab_mentions_are_metadata_only?(variant)
    end
  end

  defp lab_mentions_are_metadata_only?(project) do
    mentions =
      project
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ "insider_lab"))
      |> Enum.map(&String.trim/1)

    mentions == @lab_metadata_lines
  end

  test "mock provider mappings expose no delivery implementation or network dependency" do
    modules = Application.spec(:insider, :modules)

    assert Insider.Observability.MockEvent in modules
    assert Insider.Observability.Sentry in modules
    assert Insider.Observability.Datadog in modules
    assert Insider.Observability.MockHostClient in modules

    assert Insider.Observability.MockHostClient.behaviour_info(:callbacks) == [handoff: 1]
    assert Enum.all?(modules, &Code.ensure_loaded?/1)

    refute Enum.any?(modules, fn module ->
             module != Insider.Observability.MockHostClient and
               function_exported?(module, :handoff, 1)
           end)
  end

  defp run_gate(extra_environment \\ %{}) do
    ebin_dir = Path.join([Mix.Project.build_path(), "lib", "insider", "ebin"])

    environment =
      extra_environment
      |> Map.put("INSIDER_EBIN_DIR", ebin_dir)
      |> Map.put("INSIDER_ARTIFACT_SKIP_FRESH_BUILD", "1")
      |> Map.to_list()

    System.cmd("bash", [@gate], cd: @root, env: environment, stderr_to_stdout: true)
  end
end
