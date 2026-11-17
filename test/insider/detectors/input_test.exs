defmodule Insider.Detectors.InputTest do
  use ExUnit.Case, async: true

  alias Insider.Detectors.Input

  test "bounded identifiers and digests accept only canonical portable values" do
    assert Input.bounded_id?("event-1")
    assert Input.bounded_string?("node@example", 256)
    assert Input.digest?(String.duplicate("a", 64))

    refute Input.bounded_id?("")
    refute Input.bounded_id?(String.duplicate("x", 129))
    refute Input.bounded_string?(<<255>>, 256)
    refute Input.digest?(String.duplicate("A", 64))
    refute Input.digest?(String.duplicate("a", 63))
  end

  test "process PIDs and Poller cycle IDs require canonical encodings" do
    assert Input.canonical_pid?("<0.10.0>")
    refute Input.canonical_pid?("process-10")
    refute Input.canonical_pid?(String.duplicate("1", 129))

    assert Input.cycle_sequence("1") == {:ok, 1}
    assert Input.cycle_sequence("Z") == {:ok, 35}
    refute match?({:ok, _sequence}, Input.cycle_sequence("01"))
    refute match?({:ok, _sequence}, Input.cycle_sequence("z"))
    refute match?({:ok, _sequence}, Input.cycle_sequence("0"))
    assert Input.cycle_sequence(:cycle) == {:error, :invalid_cycle}
  end
end
