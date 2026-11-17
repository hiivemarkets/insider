defmodule Insider.ReadinessArtifactsTest do
  use ExUnit.Case, async: true

  @worksheet_path "docs/pre-canary-decision-worksheet.json"
  @index_path "docs/production-readiness-evidence-index.json"
  @dossier_path "docs/production-readiness-dossier.md"
  @runbook_path "docs/staged-canary-runbook.md"
  @public_artifact_paths [
    "CHANGELOG.md",
    "README.md",
    "decisions/2026-09-12_readiness_dossier_cannot_self_authorize.md",
    "docs/pre-canary-decision-worksheet.json",
    "docs/production-observation-threat-model.md",
    "docs/production-readiness-dossier.md",
    "docs/production-readiness-evidence-index.json",
    "docs/staged-canary-runbook.md"
  ]

  # An internal product and its services. Three public names are not one: the
  # copyright holder (The Clarity Group Limited), the approved contact address
  # (opensource@clarity.com), and the Hex organization that owns the packages,
  # which hex.pm shows on each package page. The organization is allowed only
  # in the forms the release procedure writes it.
  @company_name ~r/(?<!opensource@)(?<!Hex organization `)(?<!hex\.owner transfer insider )(?<!hex\.owner transfer insider_lab )clarity(?! group limited)/i

  test "readiness artifacts are canonical, non-authoritative, and publicly neutral" do
    bytes = File.read!(@worksheet_path) |> String.trim_trailing("\n")
    assert {:ok, worksheet} = Jason.decode(bytes)
    assert Insider.Event.Canonical.encode(worksheet) == bytes

    assert Enum.sort(Map.keys(worksheet)) ==
             [
               "approval_inputs",
               "authority",
               "candidate",
               "controls",
               "evidence",
               "purpose",
               "schema",
               "uncertainty"
             ]

    assert worksheet["schema"] == "insider.pre-canary-decision-worksheet/v1"
    assert worksheet["authority"] == "none"
    assert worksheet["purpose"] == "non_authoritative_input_checklist"
    refute bytes =~ "authorize_staging"

    assert Enum.all?(
             [
               "expires_at_utc",
               "on_call_approver",
               "privacy_security_approver",
               "service_approver",
               "technical_approver"
             ],
             &(worksheet["approval_inputs"][&1] == nil)
           )

    assert Enum.all?(
             ["configuration_fingerprint", "git_revision", "service"],
             &(worksheet["candidate"][&1] == nil)
           )

    assert worksheet["controls"]["outbound_provider_delivery"] == "off"
    assert worksheet["controls"]["merge_authority"] == "prohibited"
    assert worksheet["controls"]["deploy_authority"] == "prohibited"

    dossier = File.read!(@dossier_path)
    runbook = File.read!(@runbook_path)

    assert dossier =~ "staging and production denied"
    assert dossier =~ "production_capacity: false"
    assert dossier =~ "budget_evaluation: not_approved"
    assert dossier =~ "Agents may assemble or verify evidence. They cannot"

    assert runbook =~ "execution is not authorized"
    assert runbook =~ "contains no deploy command"
    assert runbook =~ "Provider delivery is off"
    assert runbook =~ "A successful staging canary does not authorize production"

    # The README is a synopsis; the reference it replaced lives in docs/.
    public_paths = Enum.uniq(@public_artifact_paths ++ Path.wildcard("docs/**/*.md"))

    for path <- public_paths,
        forbidden <- [
          @company_name,
          ~r/(\/users\/|\/private\/)/i,
          ~r/api_key/i,
          ~r/dsn=/i,
          ~r/authorization:\s*bearer/i,
          ~r/mix\s+deploy/i
        ] do
      refute File.read!(path) =~ forbidden
    end
  end

  # Every tracked file is public with the repository, and part of it ships to
  # Hex. None names an internal company or product, an evaluation round or its
  # report files, a review round, a work-item or ticket id, or a personal
  # path. The patterns name shapes only, so the list itself reveals nothing.
  # A rule's reason is its comment.
  @internal_names [
    # The company name, except in the repository URL.
    company: ~r/hiive(?!markets\/insider)/i,
    # An internal product, with its three public names. See `@company_name`.
    product: @company_name,
    # Evaluation runs and their labels.
    evaluation: ~r/campaign|full-?stack ?(round|\d)|\bux (round|test|friction)|partnered round/i,
    # Rounds of the build and of its reviews.
    round: ~r/\brounds? \d+\b|\breview r\d+\b|\bsol (review|r\d)|\bbatch [a-z] review/i,
    # Report and note files of evaluations and reviews.
    report: ~r/\b(REPORT|SUMMARY|ANSWER_KEY)[\w-]*\.md\b|\bsession_[\w-]+\.md\b|\bNOTES\.md\b/,
    # Work-item ids (`gap-` plus three characters) and tickets.
    work_item: ~r/\bgap-[a-z0-9]{3}\b|\b(PLAT|HB)-\d+\b/,
    # A personal home directory.
    home: ~r/\/Users\//
  ]

  # Files that must keep a match, each with its reason.
  @internal_names_allowed %{
    # Holds the patterns themselves.
    "test/readiness_artifacts_test.exs" => :all,
    # Names the reviewing owner's account.
    ".github/CODEOWNERS" => [:company],
    # The Contributor Covenant uses "clarity" as an ordinary word.
    "CODE_OF_CONDUCT.md" => [:product],
    # The macOS user directory is the behaviour under test.
    "tools/insider_lab/test/insider_lab/live_reports_test.exs" => [:home],
    # Asserts that a report leaks no home path.
    "tools/insider_lab/test/insider/sentinel/repair_report_test.exs" => [:home]
  }

  # The generated welcome is text that every agent reads first, so it is held
  # to the same rule as the files. Binary files are scanned as bytes.
  test "tracked files and the generated welcome name no internal company, product, evaluation, or ticket" do
    # The product-name exceptions are exact forms, not a loophole.
    for line <- [
          "Copyright (c) 2026 The Clarity Group Limited",
          "write to opensource@clarity.com",
          "the Hex organization `clarity` owns both",
          "mix hex.owner transfer insider clarity",
          "mix hex.owner transfer insider_lab clarity"
        ],
        do: refute(line =~ @company_name, line)

    for line <- [
          "Clarity's checkout service",
          "the Clarity Group",
          "the Hex organization clarity",
          "transfer insider to clarity",
          "ops@clarity.com"
        ],
        do: assert(line =~ @company_name, line)

    {listing, 0} = System.cmd("git", ["ls-files", "-z"])

    files =
      for path <- String.split(listing, <<0>>, trim: true),
          File.regular?(path),
          do: {path, File.read!(path)}

    assert List.keymember?(files, "mix.exs", 0)

    welcome = [
      {"welcome quick start", Jason.encode!(Insider.Live.welcome())},
      {"welcome full reference", Jason.encode!(Insider.Live.welcome(%{"full" => true}))}
    ]

    found =
      for {source, bytes} <- files ++ welcome,
          {line, number} <- bytes |> :binary.split("\n", [:global]) |> Enum.with_index(1),
          {label, pattern} <- @internal_names,
          not internal_name_allowed?(source, label),
          Regex.match?(pattern, line),
          do: "#{source}:#{number}: #{label}"

    assert found == []
  end

  defp internal_name_allowed?(source, label) do
    case Map.get(@internal_names_allowed, source, []) do
      :all -> true
      labels -> label in labels
    end
  end

  test "evidence index preserves identity, failures, and portability limits" do
    bytes = File.read!(@index_path) |> String.trim_trailing("\n")
    assert {:ok, index} = Jason.decode(bytes)
    assert Insider.Event.Canonical.encode(index) == bytes

    assert Enum.sort(Map.keys(index)) ==
             ["assessed_revision", "evidence_sets", "limitations", "schema", "storage"]

    assert index["schema"] == "insider.production-readiness-evidence-index/v2"

    assert index["storage"] == %{
             "availability" => "workstation_only_untracked",
             "portable_uri" => nil
           }

    latest = List.last(index["evidence_sets"])

    # Revisions are labels of the pre-release snapshot, whose history is not
    # in this repository.
    assert index["assessed_revision"] == %{
             "relationship_to_latest_evidence" => "same_revision",
             "revision" => latest["revision"],
             "source" => "pre_release_snapshot"
           }

    for evidence <- index["evidence_sets"] do
      assert Enum.map(evidence["lanes"], & &1["otp"]) == ["27", "28", "29"]
      assert Enum.all?(evidence["lanes"], &(&1["outcome"] in ["passed", "failed"]))
    end

    phase_5_6 = Enum.find(index["evidence_sets"], &(&1["revision"] == "phase-5.6"))

    assert Enum.map(phase_5_6["lanes"], & &1["outcome"]) == ["passed", "failed", "passed"]

    latest_sets =
      Enum.filter(index["evidence_sets"], &(&1["revision"] == latest["revision"]))

    assert [_first_run, _second_run] = latest_sets

    assert Enum.any?(
             latest_sets,
             &Enum.any?(&1["lanes"], fn lane -> lane["outcome"] == "failed" end)
           )

    assert Enum.any?(index["limitations"], &(&1 =~ "retained without retry"))

    assert Enum.all?(index["evidence_sets"], fn evidence ->
             Enum.sort(Map.keys(evidence)) == ["lanes", "revision"] and
               String.match?(evidence["revision"], ~r/\Aphase-[0-9.-]+\z/) and
               Enum.all?(evidence["lanes"], &valid_lane_identity?/1)
           end)
  end

  defp valid_lane_identity?(lane) do
    String.match?(lane["report_id"], ~r/\Asha256:[0-9a-f]{64}\z/) and
      Enum.all?(["manifest_sha256", "profile_sha256", "report_sha256"], fn key ->
        String.match?(lane[key], ~r/\A[0-9a-f]{64}\z/)
      end)
  end
end
