defmodule Insider.Discovery.ExUnit.OracleRunner.ProfileTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.OracleRunner.Profile

  @valid %{
    "schema" => "insider.oracle-host-profile/v1",
    "name" => "example-host",
    "mix_command" => ["/usr/bin/env", "mix"],
    "test_alias" => "bypass",
    "passthrough_env" => ["DB_USER", "DB_PASSWORD"],
    "db_suffix" => %{"variable" => "DB_SUFFIX", "source" => "environment"}
  }

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-oracle-profile-" <> suffix)
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "loads a valid profile with a stable content fingerprint", %{tmp_dir: tmp_dir} do
    path = write(tmp_dir, Jason.encode!(@valid))
    reordered = write(tmp_dir, Jason.encode!(@valid, pretty: true))

    assert {:ok, %{document: @valid, path: ^path, sha256: digest}} = Profile.load(path)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert {:ok, %{sha256: ^digest}} = Profile.load(reordered)
  end

  test "rejects unreadable, oversized, non-JSON, and unsupported profiles", %{tmp_dir: tmp_dir} do
    assert Profile.load(Path.join(tmp_dir, "missing.json")) == {:error, "profile_unreadable"}
    assert Profile.load(tmp_dir) == {:error, "profile_unreadable"}

    assert Profile.load(write(tmp_dir, String.duplicate(" ", 16_385))) ==
             {:error, "profile_unreadable"}

    assert Profile.load(write(tmp_dir, "{")) == {:error, "profile_invalid_json"}
    assert Profile.load(write(tmp_dir, "[]")) == {:error, "profile_invalid"}

    assert Profile.validate(%{@valid | "schema" => "insider.oracle-host-profile/v2"}) ==
             {:error, "profile_schema_unsupported"}
  end

  test "rejects every out-of-contract field" do
    cases = [
      {Map.put(@valid, "credentials", "x"), "profile_invalid"},
      {Map.delete(@valid, "db_suffix"), "profile_invalid"},
      {%{@valid | "name" => "Example Host"}, "profile_invalid_name"},
      {%{@valid | "mix_command" => []}, "profile_invalid_mix_command"},
      {%{@valid | "mix_command" => ["mix\n"]}, "profile_invalid_mix_command"},
      {%{@valid | "mix_command" => List.duplicate("mix", 9)}, "profile_invalid_mix_command"},
      {%{@valid | "test_alias" => "run"}, "profile_invalid_test_alias"},
      {%{@valid | "passthrough_env" => ["PATH"]}, "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["MIX_ENV"]}, "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["INSIDER_ORACLE_KEY"]},
       "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["lower"]}, "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["A", "A"]}, "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => Enum.map(1..65, &"V#{&1}")},
       "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["DB_SUFFIX"]}, "profile_invalid_db_suffix"},
      {%{@valid | "passthrough_env" => ["MIX_EXS"]}, "profile_invalid_passthrough_env"},
      {%{@valid | "passthrough_env" => ["INSIDER_ORACLE_RUNNER_OVERLAY"]},
       "profile_invalid_passthrough_env"},
      {%{@valid | "db_suffix" => %{"variable" => "MIX_EXS", "value" => "_a"}},
       "profile_invalid_db_suffix"},
      {%{@valid | "db_suffix" => %{"variable" => "MIX_ENV", "source" => "environment"}},
       "profile_invalid_db_suffix"},
      {%{@valid | "db_suffix" => %{"variable" => "DB_SUFFIX"}}, "profile_invalid_db_suffix"},
      {%{@valid | "db_suffix" => %{"variable" => "DB_SUFFIX", "value" => "bad-suffix"}},
       "profile_invalid_db_suffix"},
      {%{
         @valid
         | "db_suffix" => %{
             "variable" => "DB_SUFFIX",
             "value" => "_a",
             "source" => "environment"
           }
       }, "profile_invalid_db_suffix"},
      {%{@valid | "db_suffix" => "DB_SUFFIX"}, "profile_invalid_db_suffix"}
    ]

    for {profile, reason} <- cases, do: assert(Profile.validate(profile) == {:error, reason})
  end

  test "resolves only declared names and records presence without values" do
    environment = %{
      "DB_USER" => "user",
      "DB_SUFFIX" => "_slot1",
      "AWS_SECRET_ACCESS_KEY" => "undeclared"
    }

    assert Profile.resolve(@valid, environment) ==
             {:ok,
              %{
                absent: ["DB_PASSWORD"],
                db_suffix: {"DB_SUFFIX", "_slot1"},
                passthrough: [{"DB_USER", "user"}],
                present: ["DB_USER"]
              }}
  end

  test "requires an environment-sourced suffix to be present and well formed" do
    assert Profile.resolve(@valid, %{}) == {:error, "db_suffix_unavailable"}

    assert Profile.resolve(@valid, %{"DB_SUFFIX" => "x;drop"}) ==
             {:error, "db_suffix_invalid"}

    literal = %{@valid | "db_suffix" => %{"variable" => "DB_SUFFIX", "value" => "_fixed"}}

    assert {:ok, %{db_suffix: {"DB_SUFFIX", "_fixed"}}} =
             Profile.resolve(literal, %{"DB_SUFFIX" => "_other"})

    assert {:ok, %{db_suffix: nil}} = Profile.resolve(%{@valid | "db_suffix" => nil}, %{})
  end

  defp write(tmp_dir, contents) do
    path = Path.join(tmp_dir, "profile-#{System.unique_integer([:positive])}.json")
    File.write!(path, contents)
    path
  end
end
