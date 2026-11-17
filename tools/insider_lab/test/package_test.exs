defmodule InsiderLab.PackageTest do
  # The Lab is published to Hex next to the core. Its package holds only files
  # below this directory, depends on the core from Hex, and builds as an
  # escript from the unpacked package.
  use ExUnit.Case, async: true

  @lab Path.expand("..", __DIR__)
  @root Path.expand("../../..", __DIR__)

  test "the package ships only files below the Lab, with its license and recon's notice" do
    package = Mix.Project.config()[:package]

    assert package[:name] == "insider_lab"
    assert package[:licenses] == ["MIT"]

    assert ~w(lib priv mix.exs README.md LICENSE LICENSES THIRD_PARTY_NOTICES.md) --
             package[:files] == []

    for file <- package[:files] do
      path = Path.expand(file, @lab)
      assert String.starts_with?(path, @lab <> "/"), "#{file} is outside the Lab"
      assert File.exists?(path), "#{file} is missing"
    end

    assert File.read!(Path.join(@lab, "LICENSE")) == File.read!(Path.join(@root, "LICENSE"))

    assert File.read!(Path.join(@lab, "LICENSES/BSD-3-Clause-recon.txt")) ==
             File.read!(Path.join(@root, "LICENSES/BSD-3-Clause-recon.txt"))

    assert File.read!(Path.join(@lab, "THIRD_PARTY_NOTICES.md")) =~
             "LICENSES/BSD-3-Clause-recon.txt"

    assert Map.keys(package[:links]) |> Enum.sort() == ["Changelog", "Docs", "GitHub"]
  end

  test "in this repository the Lab builds against the core by path, with the shared paths" do
    config = Mix.Project.config()

    refute InsiderLab.MixProject.hex_form?(nil, @lab)
    assert {:insider, path: "../.."} in config[:deps]
    assert config[:lockfile] == "../../mix.lock"
    assert config[:deps_path] == "../../deps"
  end

  test "the Hex form names the core on Hex at the Lab's version and drops the shared paths" do
    assert InsiderLab.MixProject.hex_form?("1", @lab)
    assert InsiderLab.MixProject.repository_paths(true) == []

    assert {:insider, requirement} = InsiderLab.MixProject.insider_dependency(true)
    assert is_binary(requirement)

    version = Mix.Project.config()[:version]
    assert to_string(Application.spec(:insider, :vsn)) == version
    assert Version.match?(version, requirement)
    refute Version.match?(next_minor(version), requirement)
  end

  test "outside this repository, as in the unpacked package, the Hex form is the only one" do
    unpacked = Path.join([System.tmp_dir!(), "mix-local-installer", "deps", "insider_lab"])
    lookalike = Path.join([System.tmp_dir!(), "elsewhere", "tools", "insider_lab"])

    assert InsiderLab.MixProject.hex_form?(nil, unpacked)
    assert InsiderLab.MixProject.hex_form?(nil, lookalike)
    assert InsiderLab.MixProject.hex_form?("0", unpacked)
    refute InsiderLab.MixProject.hex_form?("0", @lab)
  end

  test "the escript's name and default path agree, so mix escript.install finds the file it built" do
    escript = Mix.Project.config()[:escript]

    assert escript[:name] == "insider-lab"
    assert escript[:path] in [escript[:name], System.get_env("INSIDER_ESCRIPT_PATH")]
  end

  test "hexdocs source links point at the release tag" do
    docs = Mix.Project.config()[:docs]
    tag = "v" <> Mix.Project.config()[:version]

    assert docs[:source_ref] == tag
    assert docs[:source_url_pattern] =~ "/blob/#{tag}/tools/insider_lab/"
  end

  defp next_minor(version) do
    %Version{major: major, minor: minor} = Version.parse!(version)
    "#{major}.#{minor + 1}.0"
  end
end
