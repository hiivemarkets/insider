defmodule Insider.Collector.RequestTimingTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.RequestTiming

  @ms System.convert_time_unit(1, :millisecond, :native)
  # Rich collection records everything; strict, the selected `duration`.
  @rich %{rich: true, timed: true}
  @t0 1_761_300_000_000_000
  @strict %{rich: false, timed: true}

  defp conn(fields) do
    Map.merge(
      %{
        __struct__: Plug.Conn,
        method: "POST",
        request_path: "/api/graphql",
        status: 200,
        remote_ip: {127, 0, 0, 1},
        req_headers: [{"user-agent", "sync-client/1.4"}, {"authorization", "Bearer s3cret"}]
      },
      fields
    )
  end

  describe "from/4" do
    test "a Bandit request stop gives its total, time to response, and source; strict keeps no source" do
      start = 1_000 * @ms

      measurements = %{
        monotonic_time: start + 3_100 * @ms,
        duration: 3_100 * @ms,
        req_header_end_time: start + 1 * @ms,
        resp_start_time: start + 3_090 * @ms
      }

      metadata = %{conn: conn(%{}), plug: {MyAppWeb.Endpoint, []}}

      assert RequestTiming.from([:bandit, :request, :stop], measurements, metadata, @rich) == %{
               "role" => "server",
               "server" => "bandit",
               "method" => "POST",
               "status" => 200,
               "total_us" => 3_100_000,
               "response_us" => 3_090_000,
               "headers_us" => 1_000,
               "traced" => false,
               "path" => "/api/graphql",
               "user_agent" => "sync-client/1.4",
               "remote_ip" => "127.0.0.1"
             }

      strict = RequestTiming.from([:bandit, :request, :stop], measurements, metadata, @strict)
      refute Map.has_key?(strict, "user_agent")
      refute Map.has_key?(strict, "path")
      refute inspect(strict) =~ "s3cret"

      traced =
        conn(%{req_headers: [{"traceparent", "00-" <> String.duplicate("a", 32) <> "-x-01"}]})

      assert %{"traced" => true, "user_agent" => nil} =
               RequestTiming.from(
                 [:bandit, :request, :stop],
                 measurements,
                 %{conn: traced},
                 @rich
               )
    end

    test "Phoenix's endpoint stop gives the handler's time; Cowboy's stop its total; others nothing" do
      assert %{"role" => "handler", "handler_us" => 4_000, "status" => 200} =
               RequestTiming.from(
                 [:phoenix, :endpoint, :stop],
                 %{duration: 4 * @ms},
                 %{conn: conn(%{})},
                 @strict
               )

      req = %{
        method: "GET",
        path: "/x",
        headers: %{"user-agent" => "curl/8"},
        peer: {{10, 0, 0, 2}, 5}
      }

      assert %{
               "server" => "cowboy",
               "total_us" => 9_000,
               "user_agent" => "curl/8",
               "remote_ip" => "10.0.0.2"
             } =
               RequestTiming.from(
                 [:cowboy, :request, :stop],
                 %{duration: 9 * @ms},
                 %{req: req, resp_status: 200},
                 @rich
               )

      assert RequestTiming.from([:other, :stop], %{}, %{}, @rich) == nil
      assert RequestTiming.from([:bandit, :request, :stop], %{}, :not_a_map, @rich) == nil
      assert RequestTiming.event?([:bandit, :request, :stop])
    end

    # Production code calls no network module (scripts/verify-production-artifact
    # refuses `:inet.`), so RequestTiming builds the address text itself. The
    # text must be the same as the text of `:inet.ntoa/1`.
    test "a remote address reads as :inet.ntoa/1 writes it; a malformed one gives no text" do
      addresses = [
        {127, 0, 0, 1},
        {0, 0, 0, 0},
        {255, 255, 255, 255},
        {0, 0, 0, 0, 0, 0, 0, 0},
        {0, 0, 0, 0, 0, 0, 0, 1},
        {0, 0, 0, 0, 0, 0, 0, 2},
        {0, 0, 0, 0, 0, 0, 0x0A00, 2},
        {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 2},
        {0, 0, 0, 0, 0, 0xFFFF, 0, 0},
        {0, 0, 0, 0, 0, 0xFFFE, 1, 2},
        {0, 0, 0, 0, 0xFFFF, 0, 1, 2},
        {0x2001, 0xDB8, 0, 0, 1, 0, 0, 1},
        {0x2001, 0xDB8, 0, 1, 1, 1, 1, 1},
        {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0},
        {1, 0, 0, 0, 0, 0, 0, 0},
        {0, 0, 1, 0, 0, 0, 0, 0},
        {1, 0, 0, 2, 0, 0, 0, 3},
        {1, 0, 0, 1, 0, 0, 1, 1},
        {0xFE80, 0, 0, 0, 0x0202, 0xB3FF, 0xFE1E, 0x8329},
        {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      ]

      for address <- addresses do
        assert remote_ip(address) == address |> :inet.ntoa() |> List.to_string(),
               inspect(address)
      end

      for malformed <-
            [{256, 0, 0, 1}, {1, 2, 3}, {-1, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0x10000, 1}] ++
              [{:a, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1.0}, "127.0.0.1"] do
        assert remote_ip(malformed) == nil, inspect(malformed)
      end
    end
  end

  defp remote_ip(address) do
    assert %{"remote_ip" => text} =
             RequestTiming.from(
               [:bandit, :request, :stop],
               %{duration: @ms},
               %{conn: conn(%{remote_ip: address})},
               @rich
             )

    text
  end

  describe "record-time bounds" do
    defp bandit(agent, path \\ "/api/graphql") do
      RequestTiming.from(
        [:bandit, :request, :stop],
        %{duration: 5 * @ms},
        %{conn: conn(%{req_headers: [{"user-agent", agent}], request_path: path})},
        @rich
      )
    end

    # (1) A cut before masking left `ghp_` and part of the token.
    test "a value is masked before it is cut, so a credential across the cut never shows" do
      token = "ghp_" <> String.duplicate("A1b2C3d4E5", 4)

      for dots <- [90, 100, 105, 110, 120] do
        agent = String.duplicate(".", dots) <> token
        request = bandit(agent)
        refute request["user_agent"] =~ "ghp_", "#{dots}: #{request["user_agent"]}"
        refute request["user_agent"] =~ "A1b2C3", "#{dots}"
        assert byte_size(request["user_agent"]) <= 128
        assert request["total_us"] == 5_000
      end
    end

    # (5) 129-131 bytes raised and dropped the whole request.
    test "every length near the bound keeps the request and cuts at a character boundary" do
      for size <- 125..134, filler <- ["a", "é", "€"] do
        agent =
          filler |> String.duplicate(size) |> binary_part(0, size) |> String.chunk(:valid) |> hd()

        request = bandit(agent)
        assert request["total_us"] == 5_000, "#{size} #{filler}"
        assert String.valid?(request["user_agent"])
        assert byte_size(request["user_agent"]) <= 128
      end

      # An invalid value is withheld, the request kept.
      assert %{"user_agent" => nil, "total_us" => 5_000} = bandit(<<0xFF, 0xFE>>)
    end

    # (2) The work in the emitting process does not grow with the input.
    test "a 10 MB user agent, path, or header name costs what a short one does" do
      big = String.duplicate("x", 10_000_000)
      header = {String.duplicate("y", 10_000_000), "v"}

      reductions = fn fun ->
        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)
          fun.()
          {:reductions, later} = Process.info(self(), :reductions)
          later - before
        end)
        |> Task.await()
      end

      short = reductions.(fn -> bandit("Mozilla/5.0") end)

      large =
        reductions.(fn ->
          RequestTiming.from(
            [:bandit, :request, :stop],
            %{duration: 5 * @ms},
            %{
              conn:
                conn(%{
                  request_path: "/" <> big,
                  req_headers: List.duplicate(header, 63) ++ [{"user-agent", big}]
                })
            },
            @rich
          )
        end)

      assert large < short * 10 + 20_000, "short #{short}, large #{large}"
    end
  end

  # (3) Strict collection records timings only when `duration` is selected.
  test "without the duration measurement, a request keeps its method and status but no timings" do
    untimed =
      RequestTiming.from(
        [:bandit, :request, :stop],
        %{duration: 5 * @ms},
        %{conn: conn(%{})},
        %{rich: false, timed: false}
      )

    assert %{"method" => "POST", "status" => 200, "timing_withheld" => true} = untimed
    refute Map.has_key?(untimed, "total_us")

    assert %{"timing_withheld" => true} =
             RequestTiming.from(
               [:phoenix, :endpoint, :stop],
               %{duration: @ms},
               %{conn: conn(%{})},
               %{rich: false, timed: false}
             )
  end

  # (4) Under Cowboy the endpoint runs in the stream's request process and
  # the stop is emitted from the connection's: they pair by connection
  # and stream.
  test "Cowboy requests pair with their endpoint stop by connection and stream, not process" do
    connection = self() |> :erlang.pid_to_list() |> to_string()
    adapter = fn stream -> {Plug.Cowboy.Conn, %{pid: self(), streamid: stream}} end

    handler =
      RequestTiming.from(
        [:phoenix, :endpoint, :stop],
        %{duration: 4 * @ms},
        %{conn: conn(%{adapter: adapter.(3)})},
        @rich
      )

    server =
      RequestTiming.from(
        [:cowboy, :request, :stop],
        %{duration: 900 * @ms},
        %{
          pid: self(),
          streamid: 3,
          req: %{method: "GET", path: "/x", headers: %{}},
          resp_status: 200
        },
        @rich
      )

    assert handler["stream"] == connection <> "/3"
    assert server["stream"] == connection <> "/3"

    entries = [
      entry(1, "<0.20.0>", @t0 + 890_000, handler),
      # Another stream on the same connection, emitted from yet another process.
      entry(2, "<0.21.0>", @t0 + 895_000, %{
        handler
        | "stream" => connection <> "/5",
          "handler_us" => 1_000
      }),
      entry(3, connection, @t0 + 900_000, server),
      entry(4, connection, @t0 + 905_000, %{
        server
        | "stream" => connection <> "/5",
          "total_us" => 905_000
      })
    ]

    assert [%{"receipt" => 3, "wait_us" => 896_000}, %{"receipt" => 4, "wait_us" => 904_000}] =
             RequestTiming.pair(entries)
  end

  # Disclosed events as `events_since/3` returns them.
  defp entry(receipt, pid, end_us, request),
    do: %{
      "receipt" => receipt,
      "event" => %{
        "source" => "telemetry",
        "kind" => "k",
        "wall_time" => end_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
        "subject" => %{"namespace" => "process", "value" => pid},
        "attributes" => %{"request" => request}
      }
    }

  defp server(receipt, pid, end_us, total_ms, extra \\ %{}),
    do:
      entry(
        receipt,
        pid,
        end_us,
        Map.merge(
          %{
            "role" => "server",
            "method" => "POST",
            "path" => "/api/graphql",
            "status" => 200,
            "total_us" => total_ms * 1_000,
            "traced" => false
          },
          extra
        )
      )

  defp handler(receipt, pid, end_us, ms),
    do: entry(receipt, pid, end_us, %{"role" => "handler", "handler_us" => ms * 1_000})

  describe "pair/1" do
    test "the wait is the time to response less the endpoint's time, paired by process and time" do
      entries = [
        # A request that waited 3 s before the endpoint.
        handler(1, "<0.1.0>", @t0 + 3_095_000, 5),
        server(2, "<0.1.0>", @t0 + 3_100_000, 3_100, %{"response_us" => 3_096_000}),
        # The same connection's next request, fast.
        handler(3, "<0.1.0>", @t0 + 3_200_000, 9),
        server(4, "<0.1.0>", @t0 + 3_210_000, 12),
        # Served before Plug.Telemetry (no endpoint event).
        server(5, "<0.2.0>", @t0 + 3_300_000, 40)
      ]

      assert [first, second, third] = RequestTiming.pair(entries)
      assert %{"receipt" => 2, "wait_us" => 3_091_000, "handler_us" => 5_000} = first
      assert first["arrival_us"] == @t0
      assert %{"receipt" => 4, "wait_us" => 3_000} = second
      assert %{"receipt" => 5, "wait_us" => nil, "handler_us" => nil} = third

      annotated = RequestTiming.annotate(entries)

      assert get_in(Enum.at(annotated, 1), ["event", "attributes", "request", "wait_us"]) ==
               3_091_000
    end
  end

  describe "summary/1" do
    test "a burst over the usual rate, its sources, and the waits it overlaps" do
      # Quiet: a few requests a second for 20 s.
      quiet =
        for second <- 0..19, n <- 0..1 do
          server(
            second * 10 + n,
            "<0.9.#{second}>",
            @t0 + second * 1_000_000 + n * 1_000 + 20_000,
            20,
            %{
              "user_agent" => "Mozilla/5.0",
              "traced" => true
            }
          )
        end

      # 120 requests from another client arrive in one second at t0 + 30 s,
      # and wait up to 6 s; a browser request overlapping them waits 5.9 s.
      burst =
        for n <- 1..120 do
          total = 1_000 + n * 50

          [
            handler(
              1_000 + 2 * n,
              "<0.5.#{n}>",
              @t0 + 30_000_000 + n * 1_000 + total * 1_000 - 2_000,
              2
            ),
            server(
              1_001 + 2 * n,
              "<0.5.#{n}>",
              @t0 + 30_000_000 + n * 1_000 + total * 1_000,
              total,
              %{
                "user_agent" => "sync-client/1.4"
              }
            )
          ]
        end
        |> List.flatten()

      mine = [
        # Arrived just before the burst, ended inside it.
        handler(5_000, "<0.7.0>", @t0 + 35_490_000, 90),
        server(5_001, "<0.7.0>", @t0 + 35_500_000, 6_000, %{
          "user_agent" => "Mozilla/5.0",
          "traced" => true
        })
      ]

      summary = RequestTiming.summary(quiet ++ burst ++ mine)

      assert %{"requests" => 161, "with_handler" => 121} = summary
      assert [slowest | _] = summary["slowest_waits"]
      assert slowest["user_agent"] == "sync-client/1.4"
      assert slowest["wait_us"] > 6_900_000

      assert [burst_row] = summary["bursts"]

      assert %{
               "requests" => 120,
               "seconds" => 1,
               "baseline_per_s" => 2,
               "sources" => [
                 %{"source" => "user agent sync-client/1.4", "requests" => 120, "traced" => 0}
               ],
               "others_overlapping" => 1
             } = burst_row

      assert burst_row["others_max_wait_us"] == 5_910_000
      assert burst_row["max_wait_us"] > 6_900_000

      # A quiet window has no burst and no slow wait (the digest's text is
      # `Insider.Live.Anomalies`).
      assert %{"bursts" => [], "waited_100ms" => 0} = RequestTiming.summary(quiet)
    end

    # A burst straddled a second boundary (107 + 13). The
    # stragglers belong to it, not to the requests it overlapped.
    test "a burst takes in the elevated seconds next to it" do
      quiet = for n <- 1..10, do: server(100 + n, "<0.6.#{n}>", @t0 + n * 1_000_000 + 20_000, 20)

      burst =
        for n <- 1..120 do
          arrival = @t0 + 30_900_000 + n * 1_000
          server(n, "<0.5.#{n}>", arrival + 5_000, 5, %{"user_agent" => "sync-client/1.4"})
        end

      assert [%{"requests" => 120, "seconds" => 2, "others_overlapping" => 0}] =
               RequestTiming.summary(quiet ++ burst)["bursts"]
    end

    # An observer's own requests (Tidewave's MCP calls) read as the app's
    # anomalies.
    test "an observer's own requests are left out of the waits and bursts, and counted" do
      quiet = for n <- 1..10, do: server(100 + n, "<0.6.#{n}>", @t0 + n * 1_000_000 + 20_000, 20)

      observer =
        for n <- 1..40,
            do:
              server(n, "<0.5.#{n}>", @t0 + 30_000_000 + n * 1_000, 9_000, %{
                "path" => "/tidewave/mcp"
              })

      summary = RequestTiming.summary(quiet ++ observer)
      assert %{"requests" => 10, "bursts" => [], "waited_100ms" => 0} = summary
      assert summary["observer"] == %{"requests" => 40, "paths" => ["/tidewave"]}
      assert RequestTiming.summary(quiet)["observer"] == %{"requests" => 0, "paths" => []}
    end

    test "without a source, a burst is counted by traced and untraced requests" do
      quiet = for n <- 1..10, do: server(100 + n, "<0.6.#{n}>", @t0 + n * 1_000_000 + 20_000, 20)

      burst =
        for n <- 1..40,
            do: server(n, "<0.5.#{n}>", @t0 + 30_000_000 + n * 1_000, 1, %{"traced" => n > 30})

      assert [%{"sources" => sources}] = RequestTiming.summary(quiet ++ burst)["bursts"]

      assert sources == [
               %{"source" => "untraced", "requests" => 30, "traced" => 0},
               %{"source" => "traced", "requests" => 10, "traced" => 10}
             ]
    end
  end
end
