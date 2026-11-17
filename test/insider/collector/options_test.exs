defmodule Insider.Collector.OptionsTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Options

  @required [:authority, :boot_id, :clock_id]
  @allowed @required ++ [:node, :rich]
  @valid [authority: "a", boot_id: "b", clock_id: "c"]

  test "common options are an exact keyword list with every required key" do
    assert Options.common?(@valid, @allowed, @required)
    assert Options.common?(@valid ++ [node: "n@h", rich: true], @allowed, @required)

    refute Options.common?(@valid ++ [authority: "again"], @allowed, @required)
    refute Options.common?(@valid ++ [unknown: 1], @allowed, @required)
    refute Options.common?(Keyword.delete(@valid, :clock_id), @allowed, @required)
  end

  test "the session identity strings and the node are bounded UTF-8" do
    for key <- [:authority, :boot_id, :clock_id] do
      refute Options.common?(Keyword.put(@valid, key, ""), @allowed, @required)
      refute Options.common?(Keyword.put(@valid, key, :atom), @allowed, @required)

      refute Options.common?(
               Keyword.put(@valid, key, String.duplicate("x", 129)),
               @allowed,
               @required
             )

      assert Options.common?(
               Keyword.put(@valid, key, String.duplicate("x", 128)),
               @allowed,
               @required
             )
    end

    refute Options.common?(@valid ++ [node: <<0xFF>>], @allowed, @required)
    refute Options.common?(@valid ++ [node: String.duplicate("n", 257)], @allowed, @required)
  end

  test "bounded and positive values" do
    assert Options.bounded?("é", 2)
    refute Options.bounded?("é", 1)
    refute Options.bounded?(<<0xFF>>, 8)
    assert Options.positive?(1) and Options.positive?(1_073_741_824)
    refute Options.positive?(0) or Options.positive?(1_073_741_825) or Options.positive?(1.0)
  end
end
