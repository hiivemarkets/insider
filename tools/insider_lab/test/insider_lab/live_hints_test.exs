defmodule InsiderLabTest.HintsTarget do
  @moduledoc false

  # GenServer callbacks a hint names.
  def handle_call(request, _from, state), do: {:reply, request, state}
  def handle_cast(_request, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule Insider.Lab.LiveHintsTest do
  # Every command a digest or events hint prints parses with the observer's
  # own parser into exactly the amendment the hint's options describe, and
  # compact output prints it.
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.CLI
  alias Insider.Lab.Live.Format
  alias Insider.Live.Digest
  alias Insider.Live.Hints

  @target "InsiderLabTest.HintsTarget"

  defp arguments(command) do
    [_, rest] = Regex.run(~r/\Amix insider\.live (.*)\z/, command)

    rest
    |> String.replace("\"${N[@]}\"", "--node NAME@HOST --cookie-file PATH")
    |> OptionParser.split()
  end

  defp entry(receipt, event), do: %{"receipt" => receipt, "event" => event}

  defp crash(receipt) do
    entry(receipt, %{
      "source" => "logger",
      "kind" => "process_crashed",
      "severity" => "error",
      "attributes" => %{"domain" => ["otp", "sasl"]},
      "payload" => %{
        "message" =>
          "error_info: {:error, :badarith, [{#{@target}, :handle_call, 3, [line: 5]}]}",
        "metadata" => %{"mfa" => "{#{@target}, :handle_info, 2}"}
      }
    })
  end

  defp message(receipt) do
    entry(receipt, %{
      "source" => "logger",
      "kind" => "logger_message",
      "severity" => "error",
      "attributes" => %{"domain" => ["elixir"]},
      "payload" => %{
        "message" => "boom",
        "metadata" => %{"mfa" => "{#{@target}, :handle_info, 2}"}
      }
    })
  end

  defp telemetry(receipt) do
    entry(receipt, %{
      "source" => "telemetry",
      "kind" => "shop.pricing.lookup",
      "severity" => "info",
      "attributes" => %{"lifecycle_phase" => "event"},
      "payload" => nil
    })
  end

  defp source(evicted, retained, reserved),
    do: %{
      "evicted" => evicted,
      "retained_events" => retained,
      "reserved_events" => reserved,
      "share_percent" => 25
    }

  test "every hint command parses into the amendment its options describe" do
    context =
      Hints.context(
        %{
          "session_id" => "live-7",
          "components" => ["logger", "poller", "telemetry"],
          "max_events" => 1_024,
          "filters" => %{
            "logger_summaries" => [%{"domain" => ["otp", "sasl"]}],
            "telemetry_summaries" => ["shop.checkout.stop"]
          },
          "poller" => %{"interval_ms" => 5_000},
          "recorder" => %{
            "sources" => %{
              "logger" => source(631, 300, 256),
              "telemetry" => source(159, 200, 153),
              "poller" => source(56, 300, 256)
            }
          }
        },
        :ok
      )

    # Crash reports are never summarised; the Logger message is.
    digest =
      [crash(1), crash(2), message(3), telemetry(4), telemetry(5)]
      |> Enum.reduce(Digest.new("live-7", 0, context), fn entry, acc ->
        Digest.add(acc, %{"events" => [entry], "next_cursor" => entry["receipt"], "gaps" => []})
      end)
      |> Digest.finish(nil, "shop@host")

    kinds = Enum.map(digest["hints"], & &1["kind"])

    assert kinds == [
             "trace_calls",
             "reduce_logger",
             "reduce_telemetry",
             "reduce_poller",
             "raise_capacity"
           ]

    for %{"command" => command, "options" => options} <- digest["hints"] do
      assert {:ok, %{operation: "amend", arguments: %{session: "live-7", options: ^options}}} =
               command |> arguments() |> CLI.parse(),
             command
    end
  end

  test "compact output prints a batch's hints after its trailer" do
    hint = %{
      "reason" => "Shop.Inventory crashed",
      "command" =>
        "mix insider.live amend \"${N[@]}\" --session live-7 --calls #{@target}.handle_call/3"
    }

    manual = %{
      "reason" => "needs OTP 28",
      "command" => nil,
      "manual" => ":recon_trace.calls({X, :y, 1}, 10)"
    }

    lines =
      %{
        "cursor" => 0,
        "next_cursor" => 2,
        "events" => [],
        "gaps" => [],
        "hints" => [hint, manual]
      }
      |> Format.batch_lines()
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)

    assert [trailer, first, second] = lines
    assert trailer =~ "# batch cursor=0 next_cursor=2"
    assert first == "# hint: #{hint["command"]}  # Shop.Inventory crashed"
    assert second == "# hint: :recon_trace.calls({X, :y, 1}, 10)  # needs OTP 28"

    assert %{"cursor" => 0, "events" => [], "gaps" => []}
           |> Format.batch_lines()
           |> IO.iodata_to_binary() =~
             ~r/\A# batch [^\n]*\n\z/
  end
end
