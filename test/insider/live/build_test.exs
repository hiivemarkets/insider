defmodule Insider.Live.BuildTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Build

  # The cross-node behaviour (another build is detected and replaced) is
  # tested by the Lab observer against a peer node.
  test "the identity names this build's version, commit and a stable hash of its loaded modules" do
    identity = Build.identity()

    assert identity["version"] == to_string(Application.spec(:insider, :vsn))
    assert identity["commit"] == Insider.Live.Revision.commit()
    assert identity["beams_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert Build.identity() == identity
  end
end
