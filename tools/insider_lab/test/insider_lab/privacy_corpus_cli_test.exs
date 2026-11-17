defmodule Insider.Lab.PrivacyCorpus.CLITest do
  use ExUnit.Case, async: true

  alias Insider.Lab.PrivacyCorpus.CLI

  @example Path.expand("../../priv/privacy_corpus/example.json", __DIR__)

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    directory = Path.join(System.tmp_dir!(), "insider-privacy-corpus-" <> suffix)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "the committed example corpus is clean under both denied profiles" do
    for environment <- ["staging", "production"] do
      assert {output, 0} = CLI.run(["--corpus", @example, "--environment", environment])
      assert {:ok, report} = Jason.decode(output)
      assert report["schema"] == "insider.privacy-corpus-report/v1"
      assert report["status"] == "no_canary_hits"
      assert report["environment"] == environment
      assert report["item_count"] == 6
      assert report["canary_token_count"] == 7
      assert report["telemetry_policy"]["id"] == "example-telemetry"
      assert "causality.logical_operation_id" in report["retained_fields_union"]
      assert "attributes.metadata.scenario" in report["retained_fields_union"]
      refute output =~ "CANARY"
      refute output =~ "203.0.113.10"
    end

    assert {reordered, 0} = CLI.run(["--environment", "production", "--corpus", @example])
    assert {output, 0} = CLI.run(["--corpus", @example, "--environment", "production"])
    assert reordered == output
  end

  test "a corpus whose canary survives projection exits 2 and names only the field",
       %{directory: directory} do
    corpus = Jason.decode!(File.read!(@example))

    leaking =
      update_in(corpus, ["items"], fn items ->
        Enum.map(items, fn
          %{"source" => "telemetry", "metadata" => %{"scenario" => _} = metadata} = item ->
            %{item | "metadata" => Map.put(metadata, "scenario", "CANARY-TOKEN-0007")}

          item ->
            item
        end)
      end)

    path = Path.join(directory, "leaking.json")
    File.write!(path, Jason.encode!(leaking))

    assert {output, 2} = CLI.run(["--corpus", path, "--environment", "production"])
    assert {:ok, report} = Jason.decode(output)
    assert report["status"] == "canary_hits"

    assert report["canary_hits"] == [
             %{"index" => 3, "field" => "attributes.metadata.scenario"},
             %{"index" => 4, "field" => "attributes.metadata.scenario"}
           ]

    refute output =~ "CANARY"
  end

  test "invalid arguments, unreadable files, malformed JSON, and invalid corpora exit 64",
       %{directory: directory} do
    invalid_arguments = [
      [],
      ["--corpus", @example],
      ["--environment", "production"],
      ["--corpus", @example, "--environment", "development"],
      ["--corpus", @example, "--environment", "production", "--environment", "staging"],
      ["--corpus", @example, "--corpus", @example, "--environment", "production"],
      ["--corpus", @example, "--environment", "production", "extra"],
      ["--corpus", @example, "--environment", "production", "--verbose"]
    ]

    for arguments <- invalid_arguments do
      assert {output, 64} = CLI.run(arguments)

      assert Jason.decode!(output) == %{
               "schema" => "insider.privacy-corpus-error/v1",
               "status" => "invalid_input",
               "reason" => "invalid_arguments"
             }
    end

    missing = Path.join(directory, "missing.json")
    assert {output, 64} = CLI.run(["--corpus", missing, "--environment", "production"])
    assert %{"reason" => "corpus_unreadable"} = Jason.decode!(output)

    assert {output, 64} = CLI.run(["--corpus", directory, "--environment", "production"])
    assert %{"reason" => "corpus_unreadable"} = Jason.decode!(output)

    malformed = Path.join(directory, "malformed.json")
    File.write!(malformed, "{\"schema\": ")
    assert {output, 64} = CLI.run(["--corpus", malformed, "--environment", "production"])
    assert %{"reason" => "invalid_json"} = Jason.decode!(output)

    list = Path.join(directory, "list.json")
    File.write!(list, "[]")
    assert {output, 64} = CLI.run(["--corpus", list, "--environment", "production"])
    assert %{"reason" => "invalid_json"} = Jason.decode!(output)

    corpus = Jason.decode!(File.read!(@example))
    invalid_item = Path.join(directory, "invalid_item.json")

    File.write!(
      invalid_item,
      Jason.encode!(update_in(corpus, ["items"], &(&1 ++ [%{"source" => "metrics"}])))
    )

    assert {output, 64} = CLI.run(["--corpus", invalid_item, "--environment", "production"])

    assert Jason.decode!(output) == %{
             "schema" => "insider.privacy-corpus-error/v1",
             "status" => "invalid_input",
             "reason" => "invalid_item",
             "index" => 6
           }

    no_policy = Path.join(directory, "no_policy.json")
    File.write!(no_policy, Jason.encode!(Map.delete(corpus, "telemetry_policy")))
    assert {output, 64} = CLI.run(["--corpus", no_policy, "--environment", "production"])
    assert %{"reason" => "telemetry_policy_required"} = Jason.decode!(output)

    unused = Path.join(directory, "unused.json")

    File.write!(
      unused,
      Jason.encode!(update_in(corpus, ["canary_tokens"], &["CANARY-NEVER" | &1]))
    )

    assert {output, 64} = CLI.run(["--corpus", unused, "--environment", "production"])
    assert %{"reason" => "canary_token_unused"} = Jason.decode!(output)
  end

  test "policy names that are not existing atoms fail closed without creating atoms",
       %{directory: directory} do
    missing = "privacy_corpus_cli_missing_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(missing) end

    corpus = Jason.decode!(File.read!(@example))
    path = Path.join(directory, "missing_atom.json")

    File.write!(
      path,
      Jason.encode!(put_in(corpus, ["telemetry_policy", "metadata"], %{missing => "output"}))
    )

    assert {output, 64} = CLI.run(["--corpus", path, "--environment", "production"])
    assert %{"reason" => "telemetry_policy_atom_missing"} = Jason.decode!(output)
    refute output =~ missing
    assert_raise ArgumentError, fn -> String.to_existing_atom(missing) end
  end
end
