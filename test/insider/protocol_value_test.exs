defmodule Insider.Protocol.ValueTest do
  use ExUnit.Case, async: true

  alias Insider.Protocol.Value

  test "summarizes values by shape without retaining their contents" do
    assert Value.summary("secret") == %{type: "binary", bytes: 6}
    assert Value.summary(%{secret: true}) == %{type: "map", entries: 1}
    assert Value.summary([:secret]) == %{type: "list"}
    assert Value.summary({:secret, :value}) == %{type: "tuple", elements: 2}
    assert Value.summary(:secret) == %{type: "atom"}
    assert Value.summary(42) == %{type: "integer"}
    assert Value.summary(4.2) == %{type: "float"}
    assert Value.summary(self()) == %{type: "pid"}
    assert Value.summary(make_ref()) == %{type: "reference"}
    assert Value.summary(fn -> :secret end) == %{type: "function"}
    assert Value.summary(<<1::1>>) == %{type: "other"}
  end
end
