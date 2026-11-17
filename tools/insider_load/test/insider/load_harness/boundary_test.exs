defmodule Insider.LoadHarness.BoundaryTest do
  use ExUnit.Case, async: false

  require Logger

  alias Insider.Collector.Session
  alias Insider.Load.Failure
  alias Insider.Load.Manifest
  alias Insider.Load.Report
  alias Insider.LoadHarness.ArtifactStore
  alias Insider.LoadHarness.LoadReportFixture
  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.Revision
  alias Insider.LoadHarness.Runner
  alias Insider.LoadHarness.RuntimeIdentity
  alias Insider.LoadHarness.SessionSupport
  alias Insider.LoadHarness.Workload

  test "scheduled operation counts are deterministic and preserve fractional rates" do
    assert Enum.map(0..9, &Workload.scheduled_operations(150, &1)) ==
             [1, 2, 1, 2, 1, 2, 1, 2, 1, 2]

    assert Enum.sum(Enum.map(0..99, &Workload.scheduled_operations(1_001, &1))) == 1_001
  end

  # Tests that run git, or read a repository through it, carry :git_fixture;
  # GitIsolationTest runs them with hook git variables set.
  @tag :git_fixture
  test "runtime and Git identities are bounded to the current project" do
    root = Path.expand("../..", File.cwd!())
    assert {:ok, captured} = Revision.capture(root)
    assert byte_size(captured["revision"]["git_sha"]) in [40, 64]
    assert byte_size(captured["revision"]["tree_sha"]) in [40, 64]
    assert byte_size(captured["mix_lock_sha256"]) == 64
    assert {:error, :revision_unavailable} = Revision.capture("/path/that/does/not/exist")

    identity = RuntimeIdentity.capture()

    assert Enum.sort(Map.keys(identity)) ==
             ~w(architecture elixir erts os otp schedulers_online schedulers_total)

    assert identity["schedulers_online"] <= identity["schedulers_total"]
  end

  @tag :git_fixture
  test "revision capture preserves committed identity while disclosing uncommitted code" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-revision-#{System.unique_integer([:positive, :monotonic])}"
      )

    project_root = initialize_clean_repository!(Path.join(parent, "project"))
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:ok, clean} = Revision.capture(project_root)
    assert clean["revision"]["clean"]

    File.write!(Path.join(project_root, "measured.ex"), "defmodule Measured, do: :changed\n")

    assert {:ok, dirty} = Revision.capture(project_root)
    refute dirty["revision"]["clean"]

    assert Map.take(dirty["revision"], ~w(git_sha tree_sha)) ==
             Map.take(clean["revision"], ~w(git_sha tree_sha))
  end

  @tag :git_fixture
  test "revision capture rejects lockfiles beyond its bounded input" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-lock-limit-#{System.unique_integer([:positive, :monotonic])}"
      )

    project_root = initialize_clean_repository!(Path.join(parent, "project"))
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:ok, :ok} =
             File.open(Path.join(project_root, "mix.lock"), [:write, :binary], fn file ->
               assert {:ok, _position} = :file.position(file, 8 * 1_024 * 1_024)
               IO.binwrite(file, "x")
             end)

    assert {:error, :revision_unavailable} = Revision.capture(project_root)
  end

  test "artifact output is canonical, complete, verified, and never overwritten" do
    assert {:ok, profile} = Profile.load("config/load.json")

    attributes =
      LoadReportFixture.attributes()
      |> put_in(["inputs", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["baseline", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["instrumented", "profile_sha256"], profile.canonical_sha256)

    assert {:ok, report} = Report.new(attributes)

    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:ok, result} = ArtifactStore.write(output, report, profile)
    assert File.regular?(Path.join(output, "report.json"))
    assert File.ls!(parent) == ["evidence"]
    assert File.regular?(Path.join(output, "profile.json"))
    assert File.regular?(Path.join(output, "manifest.json"))

    assert File.read!(Path.join(output, "profile.json")) ==
             Insider.Event.Canonical.encode(Profile.to_wire_map(profile))

    assert {:error, :output_exists} = ArtifactStore.write(output, report, profile)
    assert [_, _] = result.manifest.artifacts

    assert %{"sha256" => profile_sha256} =
             Enum.find(result.manifest.artifacts, &(&1["path"] == "profile.json"))

    assert profile_sha256 == report.inputs["profile_sha256"]
  end

  test "a partial report write publishes only a verified typed failure without replacing existing output" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("partial-write")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      if Path.basename(path) == "report.json" do
        :ok = IO.binwrite(file, binary_part(bytes, 0, 8))
        {:error, :eio}
      else
        IO.binwrite(file, bytes)
      end
    end

    assert {:error, {:failure_published, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert_verified_failure(output, "artifact_write_failed")
    assert File.ls!(parent) == ["evidence"]
    before_retry = File.read!(Path.join(output, "failure.json"))
    assert {:error, :output_exists} = ArtifactStore.write(output, report, profile)
    assert File.read!(Path.join(output, "failure.json")) == before_retry
  end

  test "report verification failure publishes a verified failure instead of report evidence" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("verification")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      :ok = IO.binwrite(file, bytes)

      if Path.basename(path) == "report.json" do
        :ok = IO.binwrite(file, "corrupted")
      end

      :ok
    end

    assert {:error, {:failure_published, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert_verified_failure(output, "artifact_write_failed")
  end

  test "a foreign entry prevents safe replacement and reports publication failure" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("contended-output")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      if Path.basename(path) == "report.json" do
        File.write!(Path.join(output, "foreign"), "untouched")
        {:error, :eio}
      else
        IO.binwrite(file, bytes)
      end
    end

    assert {:error, {:failure_publication_failed, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert File.read!(Path.join(output, "foreign")) == "untouched"
    refute File.exists?(Path.join(output, "failure.json"))
  end

  test "a competing writer's expected artifact name is never removed after reservation fails" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("same-name-collision")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      :ok = IO.binwrite(file, bytes)

      for name <- ["manifest.json", "profile.json", "report.json"],
          name != Path.basename(path) do
        File.write!(Path.join(output, name), "competitor")
      end

      :ok
    end

    assert {:error, {:failure_publication_failed, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert {:ok, names} = File.ls(output)

    assert Enum.sort(names) == ["manifest.json", "profile.json", "report.json"]
    assert Enum.all?(names, fn name -> File.read!(Path.join(output, name)) == "competitor" end)

    refute File.exists?(Path.join(output, "failure.json"))
  end

  test "a competing public replacement survives failed staged publication" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("public-path-replaced")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn _path, _bytes, _file ->
      File.write!(Path.join(output, "report.json"), "replacement")
      {:error, :eio}
    end

    assert {:error, {:failure_publication_failed, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert File.ls!(output) == ["report.json"]
    assert File.read!(Path.join(output, "report.json")) == "replacement"
    refute File.exists?(Path.join(output, "failure.json"))
  end

  test "a new empty directory cannot inherit another writer's reservation" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("replaced-output-directory")
    output = Path.join(parent, "evidence")
    displaced = Path.join(parent, "displaced")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn _path, _bytes, _file ->
      :ok = File.rename(output, displaced)
      :ok = File.mkdir(output)
      {:error, :eio}
    end

    assert {:error, {:failure_publication_failed, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert File.ls!(output) == []
    assert File.ls!(displaced) == []
  end

  @tag timeout: 5_000
  test "verification rejects a substituted staging symlink without opening its device target" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("symlink-device")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      :ok = IO.binwrite(file, bytes)

      if Path.basename(path) == "report.json" do
        [staging] = File.ls!(parent) -- ["evidence"]
        staged_path = Path.join([parent, staging, Path.basename(path)])
        File.rm!(staged_path)
        File.ln_s!("/dev/zero", staged_path)
      end

      :ok
    end

    assert {:error, {:failure_published, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert_verified_failure(output, "artifact_write_failed")
    [staging] = File.ls!(parent) -- ["evidence"]

    assert {:ok, %File.Stat{type: :symlink}} =
             File.lstat(Path.join([parent, staging, "report.json"]))
  end

  test "a public symlink replacement is preserved without opening its device target" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("public-symlink")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn path, bytes, file ->
      :ok = IO.binwrite(file, bytes)

      if Path.basename(path) == "report.json" do
        File.write!(path, "interim")
        File.rm!(path)
        File.ln_s!("/dev/zero", path)
        {:error, :eio}
      else
        :ok
      end
    end

    assert {:error, {:failure_publication_failed, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert {:ok, %File.Stat{type: :symlink}} =
             File.lstat(Path.join(output, "report.json"))

    assert File.read_link!(Path.join(output, "report.json")) == "/dev/zero"
    assert File.ls!(parent) == ["evidence"]
  end

  test "foreign staging entries are retained rather than recursively deleted" do
    {profile, report} = artifact_inputs()
    parent = temporary_artifact_parent("foreign-staging")
    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    writer = fn _path, _bytes, _file ->
      [staging] = File.ls!(parent) -- ["evidence"]
      File.write!(Path.join([parent, staging, "foreign"]), "untouched")
      {:error, :eio}
    end

    assert {:error, {:failure_published, :artifact_write_failed}} =
             ArtifactStore.write(output, report, profile, writer)

    assert_verified_failure(output, "artifact_write_failed")
    [staging] = File.ls!(parent) -- ["evidence"]
    assert Bitwise.band(File.stat!(Path.join(parent, staging)).mode, 0o777) == 0o700
    assert File.read!(Path.join([parent, staging, "foreign"])) == "untouched"
  end

  test "artifact output rejects a profile mutated after canonical identity was cached" do
    assert {:ok, profile} = Profile.load("config/load.json")

    attributes =
      LoadReportFixture.attributes()
      |> put_in(["inputs", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["baseline", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["instrumented", "profile_sha256"], profile.canonical_sha256)

    assert {:ok, report} = Report.new(attributes)
    mutated_profile = %{profile | rate_per_second: profile.rate_per_second + 1}

    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-mutated-profile-#{System.unique_integer([:positive, :monotonic])}"
      )

    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:error, :artifact_contract_mismatch} =
             ArtifactStore.write(output, report, mutated_profile)

    refute File.exists?(output)
  end

  test "collector session support composes and cleans the real scalar-only boundary" do
    assert {:ok, profile} = Profile.load("config/load.json")
    id = "load-boundary-#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, handle} = SessionSupport.start(profile, [self()], id)

    :telemetry.execute(SessionSupport.telemetry_event(), %{duration: 1}, %{})
    Logger.info("insider load boundary test")

    assert {:ok, evidence} = Session.flush_evidence(handle)
    assert evidence["event_content_included"] == false
    assert evidence["recorder"]["counters"]["offered"] >= 1
    assert {:ok, %{"outcome" => "stopped"}} = Session.stop(handle)
  end

  test "comparison includes explicit missed-operation evidence and signed deltas" do
    attributes = LoadReportFixture.attributes()

    comparison = Runner.comparison(attributes["baseline"], attributes["instrumented"])

    assert comparison["throughput_change_basis_points"] == -200
    assert comparison["missed_operations_delta"] == 0

    assert Enum.sort(Map.keys(comparison)) ==
             ~w(cpu_time_change_basis_points error_delta garbage_collections_delta latency_p99_change_basis_points memory_change_bytes missed_operations_delta port_count_delta process_count_delta scheduler_change_basis_points throughput_change_basis_points)
  end

  test "a typed pre-report failure still emits a canonical manifested artifact" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-failure-#{System.unique_integer([:positive, :monotonic])}"
      )

    output = Path.join(parent, "evidence")
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:error, :invalid_profile} = Runner.run("missing-profile.json", output)

    assert {:ok, failure} =
             output |> Path.join("failure.json") |> File.read!() |> Insider.Load.Failure.decode()

    assert failure["reason"] == "invalid_profile"
    assert File.regular?(Path.join(output, "manifest.json"))
  end

  test "runner exposes failed failure publication and preserves another writer's output" do
    parent = temporary_artifact_parent("publication")
    File.mkdir_p!(parent)
    File.write!(Path.join(parent, "blocked"), "not a directory")
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:error, {:failure_publication_failed, :invalid_profile}} =
             Runner.run("missing-profile.json", Path.join(parent, "blocked/evidence"))

    output = Path.join(parent, "existing")
    File.mkdir!(output)
    File.write!(Path.join(output, "keep"), "untouched")

    assert {:error, :output_exists} = Runner.run("missing-profile.json", output)
    assert File.ls!(output) == ["keep"]
    assert File.read!(Path.join(output, "keep")) == "untouched"
  end

  @tag :git_fixture
  test "runner refuses to label uncommitted measured code as passed" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-dirty-runner-#{System.unique_integer([:positive, :monotonic])}"
      )

    project_root = initialize_clean_repository!(Path.join(parent, "project"))
    profile_path = Path.join(parent, "profile.json")
    output = Path.join(parent, "evidence")
    File.write!(profile_path, Insider.Event.Canonical.encode(minimum_profile()))
    File.write!(Path.join(project_root, "measured.ex"), "defmodule Measured, do: :changed\n")
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:error, :dirty_revision} =
             Runner.run(profile_path, output, project_root: project_root)

    assert {:ok, failure} =
             output |> Path.join("failure.json") |> File.read!() |> Insider.Load.Failure.decode()

    assert failure["reason"] == "dirty_revision"
    refute File.exists?(Path.join(output, "report.json"))
    refute File.exists?(Path.join(output, "profile.json"))
    assert File.regular?(Path.join(output, "manifest.json"))
  end

  @tag :git_fixture
  @tag timeout: 15_000
  test "runner retains a passing report for the complete bounded gate" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-runner-#{System.unique_integer([:positive, :monotonic])}"
      )

    profile_path = Path.join(parent, "profile.json")
    output = Path.join(parent, "evidence")
    project_root = initialize_clean_repository!(Path.join(parent, "project"))
    File.mkdir_p!(parent)
    File.write!(profile_path, Insider.Event.Canonical.encode(minimum_profile()))
    on_exit(fn -> File.rm_rf(parent) end)

    assert {:ok, result} = Runner.run(profile_path, output, project_root: project_root)

    assert result.report.outcome == "passed",
           inspect(%{baseline: result.report.baseline, instrumented: result.report.instrumented},
             limit: :infinity
           )

    assert result.report.instrumented["summary"]["overload"]["observed"]
    assert result.report.instrumented["summary"]["collector"]["conservation_complete"]
    assert result.report.instrumented["summary"]["cleanup"]["complete"]
    assert File.regular?(Path.join(output, "manifest.json"))
  end

  defp artifact_inputs do
    {:ok, profile} = Profile.load("config/load.json")

    attributes =
      LoadReportFixture.attributes()
      |> put_in(["inputs", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["baseline", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["instrumented", "profile_sha256"], profile.canonical_sha256)

    {:ok, report} = Report.new(attributes)
    {profile, report}
  end

  defp temporary_artifact_parent(label) do
    Path.join(
      System.tmp_dir!(),
      "insider-load-#{label}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp assert_verified_failure(output, reason) do
    assert {:ok, names} = File.ls(output)
    assert Enum.sort(names) == ["failure.json", "manifest.json"]
    failure_bytes = File.read!(Path.join(output, "failure.json"))
    assert {:ok, %{"reason" => ^reason}} = Failure.decode(failure_bytes)

    assert {:ok, manifest} =
             output |> Path.join("manifest.json") |> File.read!() |> Manifest.decode()

    assert {:ok, ^manifest} =
             Manifest.validate_with_artifacts(manifest, %{"failure.json" => failure_bytes})
  end

  defp initialize_clean_repository!(project_root) do
    File.mkdir_p!(project_root)
    File.write!(Path.join(project_root, "mix.lock"), "%{}\n")
    File.write!(Path.join(project_root, "measured.ex"), "defmodule Measured, do: :original\n")
    git!(project_root, ["init", "--quiet"])
    git!(project_root, ["add", "mix.lock", "measured.ex"])

    git!(project_root, [
      "-c",
      "commit.gpgsign=false",
      "-c",
      "user.name=Insider Test",
      "-c",
      "user.email=insider@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    project_root
  end

  defp git!(project_root, arguments) do
    case System.cmd("git", ["-C", project_root | arguments],
           stderr_to_stdout: true,
           env: Insider.Test.GitIsolation.clean()
         ) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git fixture command failed (#{status}): #{output}")
    end
  end

  defp minimum_profile do
    %{
      "inbox_size" => 64,
      "logger_every" => 1,
      "max_artifact_bytes" => 1_048_576,
      "max_samples" => 4,
      "mode" => "load",
      "overload_ms" => 50,
      "overload_rate_per_second" => 1_000,
      "rate_per_second" => 10,
      "recorder_bytes" => 1_048_576,
      "recorder_events" => 1_000,
      "recovery_ms" => 1_000,
      "sample_interval_ms" => 1_000,
      "schema" => "insider.load-profile/v1",
      "seed" => 42,
      "steady_ms" => 1_000,
      "target_count" => 0,
      "telemetry_every" => 1,
      "warmup_ms" => 0
    }
  end
end
