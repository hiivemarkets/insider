defmodule Insider.PackageContentsTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "the package ships usage-rules.md, the guides, and every guide the rules name" do
    files = Mix.Project.config()[:package][:files]

    assert "usage-rules.md" in files
    assert "guides" in files
    assert Enum.all?(files, &File.exists?(Path.join(@root, &1)))

    rules = File.read!(Path.join(@root, "usage-rules.md"))
    named = Regex.scan(~r{guides/[a-z_/-]+\.md}, rules) |> List.flatten() |> Enum.uniq()

    assert "guides/agents/live-observation.md" in named
    assert Enum.reject(named, &File.regular?(Path.join(@root, &1))) == []
  end

  test "the package ships the reference documentation that the usage rules point to" do
    files = Mix.Project.config()[:package][:files]
    rules = File.read!(Path.join(@root, "usage-rules.md"))

    assert "docs" in files
    assert rules =~ "deps/insider/docs/README.md"
    assert File.regular?(Path.join(@root, "docs/README.md"))
  end

  test "the package names its license, ships it, and links the source, changelog, docs, and CLI" do
    config = Mix.Project.config()
    package = config[:package]

    assert is_binary(config[:description]) and config[:description] != ""
    assert package[:licenses] == ["MIT"]
    assert "LICENSE" in package[:files]
    assert File.read!(Path.join(@root, "LICENSE")) =~ "MIT License"

    assert package[:links] == %{
             "GitHub" => config[:source_url],
             "Changelog" => config[:source_url] <> "/blob/main/CHANGELOG.md",
             "Docs" => "https://hexdocs.pm/insider",
             "CLI (insider_lab)" => "https://hex.pm/packages/insider_lab"
           }
  end

  # The hex.pm page shows the description and the links, never the README.
  # Someone who adds `insider` and looks for `mix insider.live` learns there
  # that the observer and its Mix tasks are the other package.
  test "the description names insider_lab as the command-line observer" do
    description = Mix.Project.config()[:description]

    assert description =~ "The command-line observer and its Mix tasks ship separately"
    assert description =~ "insider_lab"
    assert String.length(description) <= 300
  end

  test "hexdocs source links point at the release tag" do
    config = Mix.Project.config()

    assert config[:docs][:source_ref] == "v" <> config[:version]
  end

  test "the core and the Lab release together, at one version" do
    lab = File.read!(Path.join(@root, "tools/insider_lab/mix.exs"))

    assert [_whole, lab_version] = Regex.run(~r/@version "([^"]+)"/, lab)
    assert lab_version == Mix.Project.config()[:version]
  end
end
