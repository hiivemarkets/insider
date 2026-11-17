defmodule Insider.LoadHarness.SessionSupportTest do
  use ExUnit.Case, async: true

  alias Insider.LoadHarness.SessionSupport

  test "stops a started session when phase execution raises and retains its receipt" do
    parent = self()
    receipt = clean_receipt("stopped")

    assert {:error, :phase_execution_failed, ^receipt} =
             SessionSupport.with_session(
               fn -> {:ok, :handle} end,
               fn :handle -> raise "bounded fault" end,
               stop: fn :handle ->
                 send(parent, :stopped)
                 {:ok, receipt}
               end,
               kill: fn _handle -> flunk("kill must not run after a successful stop") end
             )

    assert_received :stopped
  end

  test "falls back to kill when stop raises and retains the kill receipt" do
    parent = self()
    receipt = clean_receipt("killed")

    assert {:ok, :measured, ^receipt} =
             SessionSupport.with_session(
               fn -> {:ok, :handle} end,
               fn :handle -> :measured end,
               stop: fn :handle -> raise "stop fault" end,
               kill: fn :handle ->
                 send(parent, :killed)
                 {:ok, receipt}
               end
             )

    assert_received :killed
  end

  test "falls back to kill when stop returns an incomplete cleanup receipt" do
    parent = self()
    incomplete = put_in(clean_receipt("stopped"), ["cleanup", "session_timers"], "unavailable")
    killed = clean_receipt("killed")

    assert {:ok, :measured, ^killed} =
             SessionSupport.with_session(
               fn -> {:ok, :handle} end,
               fn :handle -> :measured end,
               stop: fn :handle -> {:ok, incomplete} end,
               kill: fn :handle ->
                 send(parent, :killed_after_incomplete_stop)
                 {:ok, killed}
               end
             )

    assert_received :killed_after_incomplete_stop
  end

  defp clean_receipt(outcome) do
    %{
      "outcome" => outcome,
      "cleanup" => %{
        "components" => %{
          "logger" => "absent",
          "poller" => "absent",
          "recorder" => "absent",
          "telemetry" => "absent"
        },
        "logger_filter" => "absent",
        "monitors" => "dropped",
        "policy_reference" => "dropped",
        "telemetry_handler" => "absent",
        "recorder_ets" => "absent",
        "manager_ownership" => "absent",
        "session_timers" => "none_owned"
      }
    }
  end
end
