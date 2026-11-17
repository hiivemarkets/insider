defmodule Insider.Adapter.MixTaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Insider.Adapter.MixTask

  test "the public Mix task writes a successful result" do
    output = capture_io(fn -> Mix.Tasks.Insider.run(["capabilities"]) end)

    assert Jason.decode!(output)["status"] == "ok"
  end

  test "capabilities emits a successful protocol result" do
    assert {output, 0} = MixTask.run(["capabilities"], :dev)
    decoded = Jason.decode!(output)

    assert decoded["status"] == "ok"
    assert decoded["value"]["schema"] == "insider.runtime-capabilities/v1"
    assert decoded["value"]["environment"] == "development"
  end

  test "inspect resolves existing registered names without creating atoms" do
    name = __MODULE__.RegisteredTarget
    target = spawn(fn -> receive(do: (:stop -> :ok)) end)
    Process.register(target, name)

    assert {output, 0} = MixTask.run(["inspect", "--name", Atom.to_string(name)], :test)
    decoded = Jason.decode!(output)
    assert decoded["status"] == "ok"
    assert decoded["value"]["target"]["pid"] == target |> :erlang.pid_to_list() |> to_string()

    send(target, :stop)
  end

  test "unknown names and malformed commands fail with machine-readable usage" do
    unknown = "unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {missing, 64} = MixTask.run(["inspect", "--name", unknown], :test)
    assert Jason.decode!(missing)["error"]["code"] == "process_not_found"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {usage, 64} = MixTask.run([], :test)
    assert Jason.decode!(usage)["error"]["code"] == "usage"

    assert {pid_target, 64} = MixTask.run(["inspect", "--pid", "<0.0.0>"], :test)
    assert Jason.decode!(pid_target)["error"]["code"] == "invalid_target"
  end
end
