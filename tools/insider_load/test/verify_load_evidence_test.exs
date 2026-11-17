defmodule Insider.LoadHarness.VerifyLoadEvidenceTest do
  use ExUnit.Case, async: true

  alias Insider.Load.Report
  alias Insider.LoadHarness.ArtifactStore
  alias Insider.LoadHarness.LoadReportFixture
  alias Insider.LoadHarness.Profile

  @script Path.expand("../../../scripts/verify-load-evidence", __DIR__)

  unless System.find_executable("elixir") do
    @moduletag skip: "scripts/verify-load-evidence requires elixir on PATH"
  end

  setup do
    parent =
      Path.join(
        System.tmp_dir!(),
        "insider-load-verify-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(parent) end)
    evidence = Path.join(parent, "evidence")

    {:ok, profile} = Profile.load("config/load.json")

    attributes =
      LoadReportFixture.attributes()
      |> put_in(["inputs", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["baseline", "profile_sha256"], profile.canonical_sha256)
      |> put_in(["instrumented", "profile_sha256"], profile.canonical_sha256)

    {:ok, report} = Report.new(attributes)
    {:ok, _result} = ArtifactStore.write(evidence, report, profile)
    %{evidence: evidence}
  end

  test "a pristine evidence directory verifies with recomputed identities", %{evidence: evidence} do
    assert {%{"ok" => true, "id_recomputed" => true, "mismatches" => []} = line, 0} =
             verify(evidence)

    assert line["report_id"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert line["directory"] == evidence
  end

  test "a report that is not byte-identical to its canonical encoding fails closed",
       %{evidence: evidence} do
    File.write!(Path.join(evidence, "report.json"), "\n", [:append])

    assert {%{"ok" => false, "id_recomputed" => false} = line, 1} = verify(evidence)
    assert "report_not_canonical" in line["mismatches"]
  end

  test "a manifest with substituted identity and digest fails even when they agree",
       %{evidence: evidence} do
    path = Path.join(evidence, "manifest.json")
    manifest = path |> File.read!() |> Jason.decode!()
    forged = String.duplicate("f", 64)

    substituted =
      manifest
      |> Map.put("id", "sha256:" <> forged)
      |> put_in(["integrity", "content_digest"], forged)

    File.write!(path, Insider.Event.Canonical.encode(substituted))
    assert {%{"ok" => false, "id_recomputed" => true} = line, 1} = verify(evidence)
    assert line["mismatches"] == ["manifest_id_recomputation"]

    File.write!(path, Insider.Event.Canonical.encode(substituted) <> "\n")
    assert {%{"ok" => false, "id_recomputed" => false} = line, 1} = verify(evidence)
    assert line["mismatches"] == ["manifest_not_canonical"]
  end

  test "a flipped byte in the profile breaks the manifest and report bindings",
       %{evidence: evidence} do
    path = Path.join(evidence, "profile.json")
    <<prefix::binary-size(10), byte, rest::binary>> = File.read!(path)
    File.write!(path, <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>)

    assert {%{"ok" => false, "id_recomputed" => true} = line, 1} = verify(evidence)

    assert Enum.sort(line["mismatches"]) ==
             ["artifact_sha256_profile", "report_profile_binding"]
  end

  test "a missing artifact fails the directory", %{evidence: evidence} do
    File.rm!(Path.join(evidence, "report.json"))

    assert {%{"ok" => false, "id_recomputed" => false} = line, 1} = verify(evidence)
    assert "missing_report" in line["mismatches"]
    assert "artifact_unreadable_report" in line["mismatches"]
  end

  defp verify(evidence) do
    {output, status} = System.cmd("bash", [@script, evidence], stderr_to_stdout: true)
    [line] = String.split(String.trim(output), "\n")
    {Jason.decode!(line), status}
  end
end
