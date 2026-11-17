defmodule Insider.Sentinel.ExternalProcess.PredicateTest do
  use ExUnit.Case, async: true

  alias Insider.Sentinel.ExternalProcess.Predicate

  test "accepts only bounded external-process identities" do
    maximum_id = "a" <> String.duplicate("b", 127)

    assert Predicate.identity?(%{"id" => "test.external-process", "version" => 1})
    assert Predicate.identity?(%{"id" => maximum_id, "version" => 1_000_000})
    refute Predicate.identity?(%{"id" => maximum_id <> "b", "version" => 1})
    refute Predicate.identity?(%{"id" => "test.external-process", "version" => 1_000_001})
    refute Predicate.identity?(%{"id" => "test.external-process", "version" => 0})
    refute Predicate.identity?(%{"id" => "", "version" => 1})
    refute Predicate.identity?(%{"id" => "Test.ExternalProcess", "version" => 1})

    refute Predicate.identity?(%{
             "id" => "test.external-process",
             "version" => 1,
             "extra" => true
           })

    refute Predicate.identity?(:not_an_identity)
  end

  test "accepts only lowercase SHA-256 digests" do
    digest = String.duplicate("a", 64)

    assert Predicate.digest?(digest)
    refute Predicate.digest?(String.upcase(digest))
    refute Predicate.digest?(String.duplicate("a", 63))
    refute Predicate.digest?(String.duplicate("a", 65))
  end

  test "accepts only SHA-256-prefixed identifiers" do
    digest = String.duplicate("a", 64)

    assert Predicate.id?("sha256:" <> digest)
    refute Predicate.id?(digest)
    refute Predicate.id?(:not_an_id)
  end
end
