defmodule Insider.Collector.AdmissionTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Admission

  test "bounds admitted work and releases capacity without underflow" do
    admission = Admission.new()

    assert :ok = Admission.acquire(admission, 1)
    assert :overloaded = Admission.acquire(admission, 1)
    assert :ok = Admission.release(admission)
    assert :ok = Admission.acquire(admission, 1)
    assert :ok = Admission.release(admission)
    assert :ok = Admission.release(admission)
    assert :ok = Admission.acquire(admission, 1)
  end
end
