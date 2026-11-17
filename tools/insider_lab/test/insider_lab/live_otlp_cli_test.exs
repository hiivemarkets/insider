defmodule Insider.Lab.LiveOtlpCliTest do
  # Every command here is refused before the observer connects, so none of
  # them makes this VM distributed.
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.CLI

  defp run(arguments) do
    owner = self()
    reference = make_ref()

    status =
      CLI.run(arguments, fn bytes ->
        send(owner, {reference, IO.iodata_to_binary(bytes)})
        :ok
      end)

    assert_receive {^reference, output}
    {status, output}
  end

  defp refused(extra) do
    {status, output} =
      run(
        [
          "otlp-receive",
          "--node",
          "app@127.0.0.1",
          "--cookie-file",
          "/nonexistent",
          "--session",
          "live-1"
        ] ++
          extra
      )

    {status, Jason.decode!(output)}
  end

  # `::0` is the IPv6 unspecified address; the expected value names `::1`.
  for bind <- ["0.0.0.0", "192.168.1.10", "::0", "2001:db8::1"] do
    test "--bind #{bind} is refused as non-loopback without echoing it" do
      {64, document} = refused(["--bind", unquote(bind)])

      assert %{"source" => "observer", "code" => "non_loopback_bind"} = document["error"]
      assert document["error"]["details"]["option"] == "--bind"
      assert document["error"]["details"]["expected"] =~ "127.0.0.1"
      refute Jason.encode!(document) =~ unquote(bind)
    end
  end

  test "--bind takes an address literal, not a host name" do
    {64, document} = refused(["--bind", "localhost"])
    assert document["error"]["code"] == "invalid_options"
    assert %{"option" => "--bind", "problem" => "malformed"} = document["error"]["details"]
  end

  for port <- ["-1", "65536"] do
    test "--port #{port} is out of range" do
      {64, document} = refused(["--port", unquote(port)])
      assert document["error"]["details"]["option"] == "--port"
      assert document["error"]["details"]["problem"] == "out_of_range"
    end
  end

  test "--session is required" do
    {64, document} =
      run(["otlp-receive", "--node", "app@127.0.0.1", "--cookie-file", "/nonexistent"])
      |> then(fn {status, output} -> {status, Jason.decode!(output)} end)

    assert document["error"]["code"] == "invalid_options"
    assert document["error"]["details"]["option"] == "--session"
  end

  test "help otlp-receive lists its flags with their values" do
    {0, text} = run(["help", "otlp-receive"])

    assert text =~ "mix insider.live otlp-receive:"
    assert text =~ "--session"
    assert text =~ "--port"
    assert text =~ "--bind"
    assert text =~ "4318"
  end
end
