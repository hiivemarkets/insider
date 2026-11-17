defmodule Insider.Load.FailureTest do
  use ExUnit.Case, async: true

  alias Insider.Load.Failure

  test "round-trips a bounded fail-closed envelope without a production claim" do
    assert {:ok, bytes} = Failure.canonical_binary(:revision_unavailable)
    assert {:ok, failure} = Failure.decode(bytes)
    assert failure["reason"] == "revision_unavailable"
    assert failure["production_capacity"] == false
    assert failure["budget_evaluation"] == "not_approved"

    assert {:error, :invalid_failure} = Failure.decode(bytes <> "\n")

    assert {:error, :invalid_failure} =
             Failure.decode(String.replace(bytes, "revision", "changed"))
  end

  test "preserves dirty revision as a typed pre-report failure" do
    assert {:ok, bytes} = Failure.canonical_binary(:dirty_revision)
    assert {:ok, failure} = Failure.decode(bytes)
    assert failure["reason"] == "dirty_revision"
    assert failure["outcome"] == "infrastructure_failed"
  end

  test "bounds unknown internal reasons to a fixed vocabulary" do
    assert {:ok, bytes} = Failure.canonical_binary(:private_internal_detail)
    assert {:ok, %{"reason" => "internal_failure"}} = Failure.decode(bytes)
  end
end
