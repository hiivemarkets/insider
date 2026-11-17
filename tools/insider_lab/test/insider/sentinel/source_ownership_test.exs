defmodule Insider.Sentinel.SourceOwnershipTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.SourceOwnership
  alias Insider.Sentinel.Verification.Candidate

  @declaration """
  # direct, provider-neutral labels only
  * default-team
  lib/*.ex runtime-team
  /lib/insider/sentinel/** sentinel-team final-review
  test/ test-team
  """

  test "derives canonical declared routing labels from only a simple candidate diff" do
    proposal =
      proposal!(
        modify_diff("lib/insider/sentinel/example.ex") <> modify_diff("test/example_test.exs")
      )

    assert {:ok, ownership} = SourceOwnership.new(proposal, @declaration)

    assert ownership.attributions == [
             %{
               "owners" => ["sentinel-team", "final-review"],
               "path" => "lib/insider/sentinel/example.ex"
             },
             %{"owners" => ["test-team"], "path" => "test/example_test.exs"}
           ]

    assert ownership.kind == "declared_unverified_source_ownership"
    assert ownership.controls["assignment"] == "prohibited"
    assert ownership.controls["authorization"] == "prohibited"
    assert ownership.trust["owners"] == "opaque_declared_labels"

    wire = SourceOwnership.to_wire_map(ownership)

    for forbidden <- ~w(repository provider branch assignee reviewer operation merge deployment) do
      refute Map.has_key?(wire, forbidden)
    end

    assert {:ok, bytes} = SourceOwnership.canonical_binary(ownership)
    assert {:ok, ^ownership} = SourceOwnership.decode(bytes)

    assert {:ok, ^ownership} =
             SourceOwnership.validate_with_proposal(ownership, proposal, @declaration)

    assert {:ok, proposal_bytes} = DraftProposal.canonical_binary(proposal)

    assert {:ok, ^ownership} =
             SourceOwnership.new(proposal_bytes, @declaration)
  end

  test "last matching declaration rule wins and unmatched paths remain unassigned" do
    proposal = proposal!(simple_diff("lib/first.ex", "README.md"))
    declaration = "lib/*.ex first-team\nlib/*.ex final-team\n"

    assert {:ok, ownership} = SourceOwnership.new(proposal, declaration)

    assert ownership.attributions == [
             %{"owners" => [], "path" => "README.md"},
             %{"owners" => ["final-team"], "path" => "lib/first.ex"}
           ]
  end

  test "an empty direct declaration leaves every safe changed path unassigned" do
    proposal = proposal!(simple_diff("lib/first.ex", "README.md"))

    assert {:ok, ownership} = SourceOwnership.new(proposal, "")
    assert Enum.all?(ownership.attributions, &(&1["owners"] == []))
  end

  test "an unrooted single-segment literal basename matches at every safe depth" do
    proposal = proposal!(simple_diff("README.md", "docs/README.md"))

    assert {:ok, ownership} = SourceOwnership.new(proposal, "README.md docs-team\n")
    assert Enum.all?(ownership.attributions, &(&1["owners"] == ["docs-team"]))
  end

  property "canonical output is deterministic across bounded safe declarations" do
    check all(
            owner <- member_of(["alpha", "beta-team", "gamma_2"]),
            path <- member_of(["lib/example.ex", "test/example_test.exs", "README.md"]),
            max_runs: 30
          ) do
      proposal = proposal!(simple_diff(path))
      declaration = "* #{owner}\n"

      assert {:ok, left} = SourceOwnership.new(proposal, declaration)
      assert {:ok, right} = SourceOwnership.new(proposal, declaration)
      assert SourceOwnership.canonical_binary(left) == SourceOwnership.canonical_binary(right)
      assert {:ok, ^left} = SourceOwnership.validate_with_proposal(left, proposal, declaration)
    end
  end

  test "rejects unsafe or ambiguous candidate diffs before attribution" do
    for diff <- [
          "diff --git a/../secret b/../secret\nindex 1111111..2222222 100644\n--- a/../secret\n+++ b/../secret\n@@ -1 +1 @@\n-old\n+new\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\nGIT binary patch\n",
          modify_diff("lib/a.ex") <> modify_diff("lib/a.ex"),
          "diff --git a/lib/a.ex b/lib/b.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/b.ex\n@@ -1 +1 @@\n-old\n+new\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nsimilarity index 100%\nrename from lib/a.ex\nrename to lib/a.ex\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nsimilarity index 100%\ncopy from lib/a.ex\ncopy to lib/a.ex\n",
          "diff --git \"a/lib/a file.ex\" \"b/lib/a file.ex\"\nindex 1111111..2222222 100644\n--- \"a/lib/a file.ex\"\n+++ \"b/lib/a file.ex\"\n@@ -1 +1 @@\n-old\n+new\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n\r\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -99,99 +42,42 @@\n-old\n+new\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n+new\n",
          modify_diff("lib/a.ex") <> "@@ -2 +2 @@\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -0,0 +0,0 @@\n+new\n",
          "diff --git a/lib/new.ex b/lib/new.ex\nnew file mode 100644\nindex 0000000..3e75765\n--- /dev/null\n+++ b/lib/new.ex\n@@ -1 +1 @@\n-old\n+new\n",
          "diff --git a/lib/old.ex b/lib/old.ex\ndeleted file mode 100644\nindex 3367afd..0000000\n--- a/lib/old.ex\n+++ /dev/null\n@@ -1 +1 @@\n-old\n+new\n",
          "diff --git a/lib/a.ex b/lib/a.ex\nindex 1111111..2222222 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -0,1 +1 @@\n-old\n+new\n"
        ] do
      assert {:error, %Error{code: :source_ownership_diff_invalid}} =
               SourceOwnership.new(proposal!(diff), "* team\n")
    end
  end

  test "supports add modify and delete paths but rejects opaque candidates" do
    add = fixture!("source_ownership_add_v1.diff")
    modify = fixture!("source_ownership_modify_v1.diff")
    delete = fixture!("source_ownership_delete_v1.diff")

    assert {:ok, ownership} =
             SourceOwnership.new(proposal!(add <> modify <> delete), "lib/** lab-team\n")

    assert Enum.map(ownership.attributions, & &1["path"]) == [
             "lib/added.ex",
             "lib/deleted.ex",
             "lib/modified.ex"
           ]

    assert {:error, %Error{code: :source_ownership_diff_invalid}} =
             SourceOwnership.new(proposal!("opaque bytes"), "* team\n")

    assert {:error, %Error{code: :source_ownership_diff_invalid}} =
             SourceOwnership.new(proposal!("opaque bytes", "opaque/v1"), "* team\n")
  end

  test "declaration parser fails closed on hostile patterns, labels, bytes, and counts" do
    proposal = proposal!(simple_diff("lib/example.ex"))

    for declaration <- [
          "*.ex @provider-user\n",
          "../* unsafe\n",
          "*.ex team # inline authority\n",
          "*.ex team\r\n",
          "*.ex team\0\n",
          "*.ex duplicated duplicated\n",
          "//lib/*.ex unsafe\n",
          "/lib//*.ex unsafe\n",
          "lib/**/example.ex unsafe\n",
          "lib//** unsafe\n",
          "*.ex " <> String.duplicate("a", 65) <> "\n",
          String.duplicate("*.ex team\n", 129),
          String.duplicate("x", 16_385)
        ] do
      assert {:error, %Error{code: code}} = SourceOwnership.new(proposal, declaration)
      assert code in [:source_ownership_declaration_invalid, :source_ownership_limit_exceeded]
    end
  end

  test "declaration whitespace and simple globs remain provider-neutral" do
    proposal = proposal!(simple_diff("lib/insider/example.ex", "test/example_test.exs"))
    declaration = "  lib/*/*.ex\tcore-team\n\ttest/\t test-team\n"

    assert {:ok, ownership} = SourceOwnership.new(proposal, declaration)

    assert ownership.attributions == [
             %{"owners" => ["core-team"], "path" => "lib/insider/example.ex"},
             %{"owners" => ["test-team"], "path" => "test/example_test.exs"}
           ]
  end

  test "safe leading-dot paths and dotfile patterns are routable without traversal" do
    proposal = proposal!(simple_diff(".env", ".github/CODEOWNERS"))
    declaration = "*.env env-team\n/.github/** hidden-team\n"

    assert {:ok, ownership} = SourceOwnership.new(proposal, declaration)

    assert ownership.attributions == [
             %{"owners" => ["env-team"], "path" => ".env"},
             %{"owners" => ["hidden-team"], "path" => ".github/CODEOWNERS"}
           ]
  end

  test "mismatched add and delete headers or markers fail closed" do
    mismatched_add =
      "diff --git a/lib/new.ex b/lib/new.ex\nnew file mode 100644\nindex 0000000..3e75765\n--- /dev/null\n+++ b/lib/other.ex\n@@ -0,0 +1 @@\n+new\n"

    mismatched_delete =
      "diff --git a/lib/old.ex b/lib/old.ex\ndeleted file mode 100644\nindex 3367afd..0000000\n--- a/lib/other.ex\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"

    for diff <- [mismatched_add, mismatched_delete] do
      assert {:error, %Error{code: :source_ownership_diff_invalid}} =
               SourceOwnership.new(proposal!(diff), "lib/** team\n")
    end
  end

  test "standalone validation cannot turn a readdressed companion into exact proposal evidence" do
    proposal = proposal!(simple_diff("lib/example.ex"))
    declaration = "*.ex platform-team\n"
    assert {:ok, ownership} = SourceOwnership.new(proposal, declaration)

    readdressed =
      ownership
      |> SourceOwnership.to_wire_map()
      |> put_in(["proposal", "id"], "sha256:" <> String.duplicate("f", 64))
      |> readdress()

    assert {:ok, parsed} = SourceOwnership.decode_map(readdressed)

    assert {:error, %Error{code: :source_ownership_integrity_failed}} =
             SourceOwnership.validate_with_proposal(parsed, proposal, declaration)

    assert {:error, %Error{code: :source_ownership_integrity_failed}} =
             SourceOwnership.validate_with_proposal(ownership, proposal, "*.ex other-team\n")
  end

  test "rejects hostile wire input, noncanonical JSON, and bounded ingress overflow" do
    proposal = proposal!(simple_diff("lib/example.ex"))
    assert {:ok, ownership} = SourceOwnership.new(proposal, "*.ex platform-team\n")
    wire = SourceOwnership.to_wire_map(ownership)

    unknown = "source_ownership_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, %Error{code: :invalid_source_ownership}} =
             SourceOwnership.decode_map(Map.put(wire, unknown, "hostile"))

    atom_bearing =
      wire |> put_in(["attributions", Access.at(0), "owners"], [:hostile]) |> readdress()

    assert {:error, %Error{code: :invalid_source_ownership}} =
             SourceOwnership.decode_map(atom_bearing)

    deeply_nested =
      wire
      |> put_in(
        ["trust", "hostile"],
        %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => %{"f" => %{"g" => %{}}}}}}}}
      )
      |> readdress()

    assert {:error, %Error{code: :invalid_source_ownership}} =
             SourceOwnership.decode_map(deeply_nested)

    assert {:ok, bytes} = SourceOwnership.canonical_binary(ownership)

    assert {:error, %Error{code: :invalid_source_ownership}} =
             SourceOwnership.decode(bytes <> "\n")

    assert {:error, %Error{code: :source_ownership_limit_exceeded}} =
             SourceOwnership.decode(String.duplicate("x", 65_537))
  end

  defp proposal!(diff, format \\ "unified-diff/v1") do
    {:ok, candidate} = Candidate.new(diff, format)
    candidate_wire = Candidate.to_wire_map(candidate)
    digest = String.duplicate("a", 64)

    matrix =
      ["source", "before", "before", "after", "after"]
      |> Enum.with_index()
      |> Enum.map(fn {phase, index} ->
        %{
          "cleanup" => "complete",
          "cleanup_release" => "complete",
          "cleanup_remaining_count" => 0,
          "cleanup_remaining_fingerprint" => nil,
          "evidence" => "complete",
          "finding" => if(index < 3, do: "observed", else: "absent"),
          "gates" => "passed",
          "operational" => "completed",
          "phase" => phase
        }
      end)

    sources =
      Map.new(~w(capsule repair_report sentinel_manifest verification_record), fn name ->
        {name,
         %{
           "byte_size" => 1,
           "canonical_sha256" => digest,
           "id" => "sha256:" <> digest,
           "schema" => "test.#{name}/v1"
         }}
      end)

    body = %{
      "schema" => "insider.draft-proposal/v1",
      "kind" => "offline_draft_pr_proposal",
      "controls" => %{
        "draft" => true,
        "merge_prohibited" => true,
        "network_effect" => "none",
        "repository_mutation" => "none",
        "review_required" => true
      },
      "eligibility" => %{
        "evidence" => "eligible",
        "provider_creation" => "blocked",
        "publication" => "blocked",
        "reasons" => ["candidate_disclosure_attestation_missing"]
      },
      "disclosure" => %{
        "attestation_id" => nil,
        "candidate" => "unattested",
        "status" => "missing",
        "verification" => "unattested"
      },
      "sources" => sources,
      "evidence" => %{
        "candidate" => candidate_wire,
        "finding" => %{"fingerprint" => digest},
        "verdict" => %{"reasons" => [], "status" => "verified"}
      },
      "matrix" => matrix
    }

    content_digest = Canonical.sha256(body)

    assert {:ok, proposal} =
             body
             |> Map.merge(%{
               "id" => "sha256:" <> content_digest,
               "integrity" => %{"algorithm" => "sha256", "content_digest" => content_digest}
             })
             |> DraftProposal.decode_map()

    proposal
  end

  defp simple_diff(first, second \\ nil) do
    paths = Enum.reject([first, second], &is_nil/1)

    Enum.map_join(paths, "", &modify_diff/1)
  end

  defp modify_diff(path),
    do:
      "diff --git a/#{path} b/#{path}\nindex 1111111..2222222 100644\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-old\n+new\n"

  defp fixture!(name), do: Path.join([__DIR__, "..", "..", "fixtures", name]) |> File.read!()

  defp readdress(wire) do
    content = Map.drop(wire, ["id", "integrity"])
    digest = Canonical.sha256(content)

    wire
    |> Map.put("id", "sha256:" <> digest)
    |> Map.put("integrity", %{"algorithm" => "sha256", "content_digest" => digest})
  end
end
