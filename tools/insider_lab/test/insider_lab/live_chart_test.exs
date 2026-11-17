defmodule Insider.Lab.LiveChartTest do
  # The chart a partnered programmer reads: one self-contained HTML page
  # with inline SVG, rendered on the observer from what the session's reads
  # disclosed. Fixture sessions only; the served form is tested over a real
  # loopback socket.
  use ExUnit.Case, async: true

  alias Insider.Lab.Live.Chart
  alias Insider.Lab.Live.Chart.Server

  @t0 1_793_000_000_000_000

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp event(fields) do
    Map.merge(
      %{
        "source" => "telemetry",
        "severity" => "info",
        "subject" => %{"kind" => "process", "value" => "<0.1.0>"},
        "attributes" => %{},
        "payload" => nil
      },
      fields
    )
  end

  # A request served at `at_ms` that took `total_ms`, of which the endpoint
  # handled `handler_ms`: the rest is the wait before the endpoint.
  defp request(receipt, at_ms, total_ms, handler_ms, path \\ "/orders") do
    pid = "<0.#{receipt}.0>"
    end_us = @t0 + (at_ms + total_ms) * 1_000

    server = %{
      "role" => "server",
      "server" => "bandit",
      "method" => "POST",
      "status" => 200,
      "total_us" => total_ms * 1_000,
      "response_us" => total_ms * 1_000
    }

    server = if path, do: Map.put(server, "path", path), else: server

    [
      %{
        "receipt" => receipt * 2 + 1,
        "event" =>
          event(%{
            "kind" => "phoenix.endpoint.stop",
            "wall_time" => iso(end_us - 1_000),
            "subject" => %{"kind" => "process", "value" => pid},
            "attributes" => %{
              "request" => %{"role" => "handler", "handler_us" => handler_ms * 1_000}
            }
          })
      },
      %{
        "receipt" => receipt * 2 + 2,
        "event" =>
          event(%{
            "kind" => "bandit.request.stop",
            "wall_time" => iso(end_us),
            "subject" => %{"kind" => "process", "value" => pid},
            "attributes" => %{"request" => server}
          })
      }
    ]
  end

  defp error(receipt, at_ms, message) do
    %{
      "receipt" => receipt,
      "event" =>
        event(%{
          "source" => "logger",
          "kind" => "logger_message",
          "severity" => "error",
          "wall_time" => iso(@t0 + at_ms * 1_000),
          "payload" => %{"message" => message}
        })
    }
  end

  defp vm(receipt, at_ms, total_mb, binary_mb) do
    %{
      "receipt" => receipt,
      "event" =>
        event(%{
          "source" => "poller",
          "kind" => "vm_sample",
          "wall_time" => iso(@t0 + at_ms * 1_000),
          "attributes" => %{
            "metrics" => %{
              "total_bytes" => total_mb * 1_048_576,
              "binary_bytes" => binary_mb * 1_048_576
            }
          }
        })
    }
  end

  defp mailbox(receipt, at_ms, length) do
    %{
      "receipt" => receipt,
      "event" =>
        event(%{
          "source" => "poller",
          "kind" => "process_top",
          "wall_time" => iso(@t0 + at_ms * 1_000),
          "attributes" => %{
            "metrics" => %{
              "by_message_queue_len" => [
                %{"message_queue_len" => length, "registered_name" => "MyApp.Pricing"},
                %{"message_queue_len" => 2, "registered_name" => "MyApp.Other"}
              ]
            }
          }
        })
    }
  end

  defp mark(index, at_ms, label) do
    %{
      "index" => index,
      "label" => label,
      "at" => iso(@t0 + at_ms * 1_000),
      "cursor" => index * 100,
      "reader" => "agent-a"
    }
  end

  # A minute of a busy session: requests every second, a slow wait 2 s
  # after the mark, errors, Poller samples, and an eviction.
  defp rich_input(extra \\ %{}) do
    requests =
      for second <- 0..59,
          do: request(second, second * 1_000, 40, if(second == 32, do: 40, else: 38))

    slow = request(70, 32_000, 8_540, 40)

    entries =
      List.flatten([
        requests,
        slow,
        for(n <- 1..6, do: error(400 + n, 33_000 + n * 100, "checkout failed for order #{n}")),
        for(n <- 0..5, do: vm(500 + n, n * 10_000, 100 + n, 20 + n * 2)),
        for(n <- 0..5, do: mailbox(600 + n, n * 10_000, if(n == 4, do: 870, else: 3)))
      ])

    Map.merge(
      %{
        session_id: "live-6",
        node: "shop@host",
        profile: "rich",
        entries: entries,
        evicted: [%{"at_us" => @t0 + 50_000_000, "count" => 25}],
        marks: [mark(1, 30_000, "about to click Confirm")],
        since_mark: mark(1, 30_000, "about to click Confirm"),
        digest: %{
          "anomalies" => [
            %{
              "kind" => "pre_handler_wait",
              "line" =>
                "Pre-handler wait: slowest 8.5 s POST /orders before Phoenix's endpoint telemetry",
              "command" => "mix insider.live timeline …"
            },
            %{
              "kind" => "error_spike",
              "line" => "Error spike: 6x logger_message checkout failed for order N",
              "command" => "mix insider.live events …"
            }
          ],
          "text" =>
            "Insider digest of live-6 on shop@host (rich disclosure): receipts 1-700, 140 events.\n" <>
              "Anomalies (most important first):\n  1. Pre-handler wait: slowest 8.5 s\n" <>
              "Window: since mark 'about to click Confirm' (14:03:10 UTC, 30.0 s ago), up to receipt 700.\n" <>
              "Severity: 6 error, 134 info.\nTop errors: 6x logger_message checkout failed for order N.\n"
        },
        status: %{"state" => "running", "lease_remaining_ms" => 95_000},
        window: {@t0, @t0 + 60_000_000},
        now_us: @t0 + 60_000_000,
        live: nil
      },
      extra
    )
  end

  defp html(input), do: input |> Chart.html() |> IO.iodata_to_binary()

  describe "the static page" do
    test "shows each recorded series with its unit, the marks, the since-mark window, the anomalies and the digest lines" do
      page = html(rich_input())

      assert page =~ "<!doctype html>"

      assert page =~
               ~r/<h1[^>]*>Request waits rose to 8\.5 s at \d\d:\d\d:\d\d, 2 s after &#39;about to click Confirm&#39; \(mark 1, \d\d:\d\d:\d\d\)<\/h1>/

      for {title, unit} <- [
            {"Requests", "req/s"},
            {"Request latency p50 / p95", "s"},
            {"Wait before the endpoint", "s"},
            {"Errors by signature", "events"},
            {"Longest mailbox", "messages"},
            {"Memory and binary memory", "MiB"},
            {"Evicted events", "events"}
          ] do
        assert page =~ ">#{title} (#{unit})</text>", title
      end

      # The mark reads as written, over the plot, with the window since it shaded.
      assert page =~ ~s(class="mark-label")
      assert page =~ "about to click Confirm"
      assert page =~ ~s(class="since-mark")

      # Each anomaly is a numbered marker and a one-line caption.
      assert page =~ ~s(class="anomaly")
      assert page =~ "Pre-handler wait: slowest 8.5 s POST /orders"
      assert page =~ "Error spike: 6x logger_message checkout failed for order N"

      # The digest's lead lines stand under the chart, so a pasted page stands alone.
      assert page =~ "Insider digest of live-6 on shop@host (rich disclosure)"
      assert page =~ "Window: since mark &#39;about to click Confirm&#39;"
      refute page =~ "Top errors:"

      assert page =~ "local time"
      assert page =~ "rich disclosure"
    end

    test "a series the session does not have is left out, and the legend says so" do
      only_errors = rich_input(%{entries: [error(1, 1_000, "boom")], evicted: [], digest: nil})
      page = html(only_errors)

      assert page =~ ">Errors by signature (events)</text>"
      refute page =~ ">Requests (req/s)</text>"

      assert page =~
               "Not recorded in this window: requests, request latency, waits before the endpoint, " <>
                 "mailbox lengths, memory, evictions."
    end

    test "strict shows only what the strict reads disclosed" do
      # Under strict a request has no path and no timing (timing_withheld),
      # and a Logger message no text.
      withheld =
        for second <- 0..9 do
          request(second, second * 1_000, 40, 38, nil)
          |> Enum.map(fn entry ->
            update_in(entry, ["event", "attributes", "request"], fn request ->
              request
              |> Map.drop(["total_us", "response_us", "handler_us"])
              |> Map.put("timing_withheld", true)
            end)
          end)
        end
        |> List.flatten()

      errors =
        for n <- 1..3,
            do: put_in(error(100 + n, 2_000, "x"), ["event", "payload"], nil)

      page =
        html(
          rich_input(%{
            profile: "strict",
            entries: withheld ++ errors,
            evicted: [],
            digest: nil
          })
        )

      assert page =~ "strict disclosure"
      assert page =~ ">Requests (req/s)</text>"
      refute page =~ "Request latency"
      refute page =~ "/orders"
      assert page =~ "request latency (timing withheld under strict)"
    end

    test "every string is escaped, a hostile label included, and nothing is loaded from elsewhere" do
      hostile = ~S[<script>alert('x')</script> & "quoted" <img src=x onerror=1>]

      page =
        html(
          rich_input(%{
            marks: [mark(1, 30_000, hostile)],
            since_mark: mark(1, 30_000, hostile),
            session_id: "live-<6>"
          })
        )

      refute page =~ "<script"
      refute page =~ "<img"
      refute page =~ "onerror=1>"
      assert page =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quoted&quot;"
      assert page =~ "live-&lt;6&gt;"

      # No URL, font, or stylesheet from anywhere else.
      refute page =~ ~r/https?:/
      # No element has a src or href attribute (attribute values may quote text).
      tags = Regex.replace(~r/"[^"]*"/, page, ~s(""))
      refute tags =~ ~r/<[^>]*\s(src|href)=/
      refute page =~ "@import"
      refute page =~ "url("
    end

    test "a CSP meta tag allows no script, and its style hash is the page's one style block" do
      page = html(rich_input())

      [_, csp] =
        Regex.run(~r/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/, page)

      assert csp =~ "default-src 'none'"
      assert csp =~ "script-src 'none'"
      assert csp =~ "base-uri 'none'"
      assert csp =~ "form-action 'none'"

      [_, style] = Regex.run(~r/<style>(.*?)<\/style>/s, page)
      hash = :crypto.hash(:sha256, style) |> Base.encode64()
      assert csp =~ "style-src 'sha256-#{hash}'"
      assert [_one] = Regex.scan(~r/<style>/, page)
      refute page =~ ~r/ style="/
    end

    test "a request that arrived before the window neither breaks the chart nor hides it" do
      # The session's first event: a request that took 10 s.
      slow = request(1, 10_000, 10_000, 40)

      # The default window starts at the first thing it plots, the request's
      # arrival, not the first event's stop.
      fitted =
        Chart.model(rich_input(%{entries: slow, evicted: [], digest: nil, fit_start: true}))

      assert fitted.from_us == @t0 + 10_000_000
      assert {:latency, latency} = List.keyfind(fitted.series, :latency, 0)
      assert latency.peak.value == 10.0

      # A lone request is a visible point, not a line of length zero.
      page = fitted |> Chart.Html.render() |> IO.iodata_to_binary()
      assert page =~ ~r/<g data-series="latency">.*?<circle class="s0"[^>]* r="4"\/>/s

      # A window from a mark the request straddles leaves it out.
      marked =
        rich_input(%{
          entries: slow,
          evicted: [],
          digest: nil,
          marks: [mark(1, 15_000, "about to click Confirm")],
          since_mark: mark(1, 15_000, "about to click Confirm"),
          window: {@t0 + 15_000_000, @t0 + 60_000_000}
        })

      page = html(marked)
      assert page =~ "request latency"
      refute page =~ ">Request latency p50 / p95"
    end

    test "repeated mark labels are numbered, and the headline names the mark and its time" do
      page =
        html(
          rich_input(%{
            marks: [mark(1, 10_000, "about to retry"), mark(2, 25_000, "about to retry")],
            since_mark: nil
          })
        )

      assert page =~
               ~r/<h1>Request waits rose to 8\.5 s at \d\d:\d\d:\d\d, 7 s after &#39;about to retry&#39; \(mark 2, \d\d:\d\d:\d\d\)<\/h1>/

      assert page =~ "about to retry (#1)"
      assert page =~ "about to retry (#2)"

      # The marks are listed under the chart with their times, as written.
      assert page =~ ~r/<ol class="marks">.*about to retry.*about to retry.*<\/ol>/s
    end

    test "close marks' labels take separate rows, and no mark line crosses a panel title" do
      page =
        html(
          rich_input(%{
            marks: [
              mark(1, 30_000, "about to retry the checkout"),
              mark(2, 30_500, "about to place the order again")
            ],
            since_mark: nil
          })
        )

      labels = Regex.scan(~r/<text class="mark-label" x="([\d.]+)" y="([\d.]+)"/, page)
      assert [[_, _x1, y1], [_, _x2, y2]] = labels
      assert y1 != y2

      titles =
        for [_, y] <- Regex.scan(~r/<text class="title" x="[\d.]+" y="([\d.]+)"/, page),
            do: String.to_integer(y)

      segments =
        for [_, y1, y2] <-
              Regex.scan(
                ~r/<line class="mark" x1="[\d.]+" x2="[\d.]+" y1="([\d.]+)" y2="([\d.]+)"/,
                page
              ),
            do: {String.to_float(y1), String.to_float(y2)}

      assert segments != []

      # A title's text spans about 16 px above its baseline to 4 below.
      for title <- titles, {from, to} <- segments do
        refute from < title + 4 and to > title - 16, "a mark line crosses the title at #{title}"
      end
    end

    test "series keys keep the part of a long signature that tells them apart" do
      prefix = "shop.checkout.stop result=error stage=payment provider=acme reason="

      errors =
        for {reason, n} <- [{"timeout_waiting_for_inventory", 3}, {"card_declined_by_issuer", 2}],
            index <- 1..n,
            do:
              error(
                index + if(reason =~ "card", do: 10, else: 0),
                1_000 * index,
                prefix <> reason
              )

      page = html(rich_input(%{entries: errors, evicted: [], digest: nil}))

      keys = Regex.scan(~r/<text class="key"[^>]*><title>([^<]*)<\/title>([^<]*)<\/text>/, page)
      shown = for [_, _full, shown] <- keys, do: shown

      assert Enum.any?(shown, &(&1 =~ "timeout_waiting")), inspect(shown)
      assert Enum.any?(shown, &(&1 =~ "card_declined")), inspect(shown)
      assert Enum.uniq(shown) == shown
      # The full signature stays in the tooltip.
      assert Enum.any?(keys, fn [_, full, _shown] -> full =~ prefix end)
    end

    test "anomaly markers stay inside the plot area" do
      page =
        html(
          rich_input(%{
            evicted: [%{"at_us" => @t0, "count" => 10_000}],
            digest: %{
              "anomalies" => [%{"kind" => "evicted", "line" => "Evicted: 10000 events"}],
              "text" => ""
            }
          })
        )

      [[_, cx]] = Regex.scan(~r/<circle class="anomaly" cx="([\d.]+)"/, page)
      # The plot starts at x = 96; a marker's radius is 11.
      assert String.to_float(cx) >= 96 + 11

      # Bars (not the keys' swatches) end at the plot's right edge (x = 1168),
      # the newest bucket included.
      for [_, x, width] <-
            Regex.scan(~r/<rect class="s\d" x="(\d+\.\d)" y="[\d.]+" width="(\d+\.\d)"/, page),
          do: assert(String.to_float(x) + String.to_float(width) <= 1168.05)
    end

    test "an incomplete window says so, and why, instead of drawing zeroes" do
      model =
        Chart.model(
          rich_input(%{
            digest: %{
              "anomalies" => [],
              "text" => "",
              "window" => %{"complete" => false, "stopped_by" => "deadline"}
            },
            incomplete: [
              %{
                "reason" => "max_entries",
                "detail" =>
                  "the chart keeps the newest 20000 events; 1500 earlier ones are not drawn"
              }
            ],
            covered_from_us: @t0 + 20_000_000
          })
        )

      assert Enum.map(model.incomplete, & &1["reason"]) == [
               "max_entries",
               "digest_incomplete",
               "evicted"
             ]

      page = model |> Chart.Html.render() |> IO.iodata_to_binary()
      assert page =~ ~s(<p class="incomplete">Incomplete: the chart keeps the newest 20000 events)
      assert page =~ "the digest stopped early (deadline)"
      assert page =~ "25 events were evicted before the chart read them"
      assert page =~ ~s(class="uncovered")

      complete = Chart.model(rich_input(%{evicted: []}))
      assert complete.incomplete == []
      refute complete |> Chart.Html.render() |> IO.iodata_to_binary() =~ "Incomplete:"
    end
  end

  describe "collection bounds" do
    alias Insider.Lab.Live.Chart.Run

    defp entries(receipts), do: for(receipt <- receipts, do: error(receipt, receipt, "x"))

    test "keeps the newest entries up to the cap, and counts what it dropped" do
      assert {kept, 0} = Run.retain(entries(1..3), entries(4..5), 5)
      assert Enum.map(kept, & &1["receipt"]) == [1, 2, 3, 4, 5]

      assert {kept, 2} = Run.retain(entries(1..3), entries(4..6), 4)
      assert Enum.map(kept, & &1["receipt"]) == [3, 4, 5, 6]

      # A batch the chart already read (after a re-read) is not counted twice.
      assert {kept, 0} = Run.retain(entries(1..3), entries(2..4), 5)
      assert Enum.map(kept, & &1["receipt"]) == [1, 2, 3, 4]
    end
  end

  describe "the private file" do
    alias Insider.Lab.Live.Chart.Run

    setup do
      dir = Path.join(System.tmp_dir!(), "insider-chart-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "is created new, mode 0600, and leaves nothing else behind", %{dir: dir} do
      path = Path.join(dir, "chart.html")
      assert :ok = Run.write_private(path, "<p>chart</p>")
      assert File.read!(path) == "<p>chart</p>"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert File.ls!(dir) == ["chart.html"]
    end

    test "never replaces an existing file or follows a symlink", %{dir: dir} do
      existing = Path.join(dir, "existing.html")
      File.write!(existing, "DO NOT CHANGE")
      File.chmod!(existing, 0o644)

      assert {:error, :eexist} = Run.write_private(existing, "<p>chart</p>")
      assert File.read!(existing) == "DO NOT CHANGE"

      link = Path.join(dir, "link.html")
      File.ln_s!(existing, link)
      assert {:error, :eexist} = Run.write_private(link, "<p>chart</p>")
      assert File.read!(existing) == "DO NOT CHANGE"
      assert Bitwise.band(File.stat!(existing).mode, 0o777) == 0o644

      dangling = Path.join(dir, "dangling.html")
      File.ln_s!(Path.join(dir, "missing.html"), dangling)
      assert {:error, :eexist} = Run.write_private(dangling, "<p>chart</p>")
      refute File.exists?(Path.join(dir, "missing.html"))

      assert Enum.sort(File.ls!(dir)) == ["dangling.html", "existing.html", "link.html"]
    end

    test "the default path is new for each chart and unguessable" do
      first = Run.default_path("live-1")
      second = Run.default_path("live-1")
      assert first != second
      assert Path.dirname(first) == System.tmp_dir!() |> Path.expand()
      assert Path.basename(first) =~ ~r/\Ainsider-chart-live-1-\d{8}T\d{6}-[0-9a-f]{16}\.html\z/
    end
  end

  describe "the live page" do
    test "refreshes every second, shows the session's state and lease, and says when the session ended" do
      running = html(rich_input(%{live: %{refresh_s: 1, stopped: nil}}))
      assert running =~ ~s(<meta http-equiv="refresh" content="1">)
      assert running =~ "running"
      assert running =~ "lease 1m 35s left"
      assert running =~ "this page does not renew it"

      ended =
        html(
          rich_input(%{
            status: %{"state" => "expired", "lease_remaining_ms" => 0},
            live: %{refresh_s: 1, stopped: "session_ended"}
          })
        )

      refute ended =~ ~s(http-equiv="refresh")
      assert ended =~ "The session ended (expired). This chart stopped updating."
    end
  end

  describe "the server" do
    setup do
      token = "abcdefghijklmnopqrstuvwxyz012345"
      {:ok, server} = Server.start(%{port: 0, token: token, page: "<!doctype html><p>chart</p>"})
      on_exit(fn -> Server.stop(server) end)
      %{server: server, token: token, port: Server.port(server)}
    end

    defp http(port, request) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, request)
      {:ok, response} = recv_all(socket, "")
      :gen_tcp.close(socket)
      response
    end

    defp recv_all(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_all(socket, acc <> data)
        {:error, :closed} -> {:ok, acc}
      end
    end

    defp get(port, path, host),
      do: http(port, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n\r\n")

    test "binds 127.0.0.1 only and serves the page at its token with a strict policy", context do
      assert {:ok, {{127, 0, 0, 1}, _port}} = Server.address(context.server)

      response = get(context.port, "/#{context.token}/", "127.0.0.1:#{context.port}")
      assert response =~ "HTTP/1.1 200 OK"
      assert response =~ "<p>chart</p>"
      assert response =~ "content-security-policy: default-src 'none'"
      assert response =~ "frame-ancestors 'none'"
      assert response =~ "cache-control: no-store"
      assert response =~ "x-content-type-options: nosniff"
      refute response =~ ~r/access-control-/i

      assert get(context.port, "/#{context.token}/", "localhost:#{context.port}") =~ "200 OK"

      :ok = Server.put(context.server, "<p>updated</p>")
      assert get(context.port, "/#{context.token}/", "127.0.0.1:#{context.port}") =~ "updated"
    end

    test "refuses a wrong token, a wrong Host, and anything but GET", context do
      host = "127.0.0.1:#{context.port}"

      assert get(context.port, "/wrong/", host) =~ "HTTP/1.1 404"
      assert get(context.port, "/", host) =~ "HTTP/1.1 404"

      assert get(context.port, "/#{context.token}/", "evil.example:#{context.port}") =~
               "HTTP/1.1 421"

      assert get(context.port, "/#{context.token}/", "127.0.0.1:1") =~ "HTTP/1.1 421"
      assert http(context.port, "GET /#{context.token}/ HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 421"

      for method <- ["POST", "PUT", "DELETE", "OPTIONS", "HEAD"] do
        response =
          http(
            context.port,
            "#{method} /#{context.token}/ HTTP/1.1\r\nHost: #{host}\r\nContent-Length: 0\r\n\r\n"
          )

        assert response =~ "HTTP/1.1 405", method
        refute response =~ "<p>chart</p>", method
      end
    end
  end
end
