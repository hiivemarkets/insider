defmodule Insider.Live.TrendsTest do
  # Pure tests of the trends computation on hand-built summary rows, in the
  # shape `Insider.Live.Digest.read_window/5` returns them.
  use ExUnit.Case, async: true

  alias Insider.Live.Trends

  @unknown_server %{
    "measured_in" => "unknown",
    "declared" => false,
    "emitter" => %{"context" => "otp_server", "module" => "Shop.Pricing"}
  }
  @unknown_process %{
    "measured_in" => "unknown",
    "declared" => false,
    "emitter" => %{"context" => "process", "module" => nil}
  }
  @handler %{
    "measured_in" => "handler",
    "declared" => true,
    "emitter" => %{"context" => "otp_server", "module" => "Shop.Pricing"}
  }
  @caller %{
    "measured_in" => "caller",
    "declared" => true,
    "emitter" => %{"context" => "process", "module" => nil}
  }

  defp window(index, fields) do
    started = DateTime.add(~U[2026-10-22 05:00:00Z], index * 5, :second)

    Map.merge(
      %{
        "wall_time" => DateTime.to_iso8601(DateTime.add(started, 5, :second)),
        "window_started_at" => DateTime.to_iso8601(started),
        "window_ended_at" => DateTime.to_iso8601(DateTime.add(started, 5, :second)),
        "interval_ms" => 5_000,
        "count" => 50,
        "errors" => 0,
        "p50_us" => 1_000,
        "p95_us" => 2_000,
        "max_us" => 2_100,
        "exemplars" => [],
        "exemplars_lost" => 0,
        "first_error_retained" => nil,
        "duration_scope" => nil
      },
      fields
    )
  end

  defp series(kind, scope, p95s) do
    {kind,
     p95s
     |> Enum.with_index()
     |> Enum.map(fn {p95, index} ->
       window(index, %{"p95_us" => p95, "max_us" => p95 + 10, "duration_scope" => scope})
     end)}
  end

  defp document(telemetry, logger) do
    Trends.document(
      %{"session_id" => "live-1", "node" => "shop@host", "window" => %{"cursor" => 0}},
      %{summaries: telemetry, bursts: logger},
      [],
      8
    )
  end

  describe "duration scope" do
    test "series without a declared scope get no scope note and no scope claim" do
      rows = [
        series("shop.pricing.lookup", @unknown_server, [900_000, 905_000]),
        series("shop.checkout.stop", @unknown_process, [5_000_000, 5_010_000])
      ]

      telemetry = Trends.telemetry(rows, 8)

      assert Trends.scope_notes(telemetry) == []

      text = Trends.text(document(rows, []))
      assert text =~ "shop.pricing.lookup"
      assert text =~ "emitted inside OTP server Shop.Pricing; scope not declared"

      for claim <- ["handler time", "caller-observed", "queue", "waiting", "differ"],
          do: refute(text =~ claim, claim)

      pricing = Enum.find(telemetry, &(&1["kind"] == "shop.pricing.lookup"))
      assert pricing["duration_scope"] == @unknown_server
    end

    test "a declared handler series next to a declared caller series gets the conditional note only" do
      rows = [
        series("shop.pricing.lookup", @handler, [900_000, 908_000]),
        series("shop.checkout.stop", @caller, [5_030_000, 5_040_000])
      ]

      telemetry = Trends.telemetry(rows, 8)

      assert [note] = Trends.scope_notes(telemetry)
      assert note =~ "shop.pricing.lookup"
      assert note =~ "declared handler time"
      assert note =~ "shop.checkout.stop"
      assert note =~ "declared caller-observed"

      assert note =~
               "If both describe the same operation, the difference is time outside the handler, such as queueing"

      refute note =~ "is time spent waiting"
      refute note =~ "without the wait in its mailbox"

      text = Trends.text(document(rows, []))
      assert [_before, _after] = String.split(text, "If both describe the same operation")
    end

    test "unrelated series of unknown scope, or one declared scope alone, get no note" do
      for scopes <- [
            [@unknown_server, @unknown_process],
            [@handler, @unknown_process],
            [@caller, @unknown_server],
            [@handler, @handler],
            [nil, @caller]
          ] do
        telemetry =
          scopes
          |> Enum.with_index()
          |> Enum.map(fn {scope, index} -> series("kind.#{index}", scope, [1_000, 2_000]) end)
          |> Trends.telemetry(8)

        assert Trends.scope_notes(telemetry) == [], inspect(scopes)
      end
    end

    # The measured_in value alone is not enough: a scope that is not
    # declared never reads as handler or caller time.
    test "an undeclared scope never claims handler or caller time" do
      forged = %{@handler | "declared" => false}

      rows = [series("a.b", forged, [1_000, 1_000]), series("c.d", @caller, [9_000, 9_000])]
      telemetry = Trends.telemetry(rows, 8)

      assert Trends.scope_notes(telemetry) == []
      refute Trends.text(document(rows, [])) =~ "handler time"
    end
  end

  describe "exemplar loss" do
    test "each window carries exemplars_lost and first_error_retained, and the text says so" do
      rows = [
        window(0, %{"exemplars" => [%{"receipt" => 4, "roles" => ["slowest"]}]}),
        window(1, %{
          "errors" => 2,
          "exemplars" => [%{"receipt" => 9, "roles" => ["slowest"]}],
          "exemplars_lost" => 3,
          "first_error_retained" => false
        }),
        window(2, %{
          "errors" => 1,
          "exemplars" => [%{"receipt" => 14, "roles" => ["first_error"]}],
          "first_error_retained" => true
        })
      ]

      assert [series] = Trends.telemetry([{"shop.checkout.stop", rows}], 8)

      assert Enum.map(series["series"], &{&1["exemplars_lost"], &1["first_error_retained"]}) == [
               {0, nil},
               {3, false},
               {0, true}
             ]

      assert Enum.map(series["series"], & &1["exemplars"]) == [[4], [9], [14]]
      assert series["exemplars_lost"] == 3
      assert series["first_error_lost_windows"] == 1

      text = Trends.text(document([{"shop.checkout.stop", rows}], []))
      assert text =~ "3 exemplar candidates lost"
      assert text =~ "first error not retained in 1 window"
    end

    test "a series without losses says nothing about them" do
      assert [series] = Trends.telemetry([series("a.b", nil, [1_000, 1_000])], 8)
      assert series["exemplars_lost"] == 0
      assert series["first_error_lost_windows"] == 0
      refute Trends.text(document([series("a.b", nil, [1_000, 1_000])], [])) =~ "lost"
    end
  end

  describe "Logger bursts" do
    defp burst(index, fields) do
      started = DateTime.add(~U[2026-10-22 05:00:00Z], index * 5, :second)

      Map.merge(
        %{
          "count" => 10,
          "level" => "error",
          "template" => "checkout failed for N",
          "template_fingerprint" => "aaaaaaaaaaaaaaaa",
          "call_site" => %{"module" => "Shop.Checkout", "function" => "run/2", "line" => 96},
          "call_site_fingerprint" => "cccccccccccccccc",
          "call_sites" => 1,
          "exemplar_receipt" => 100 + index,
          "exemplar_lost" => false,
          "interval_ms" => 5_000,
          "window_started_at" => DateTime.to_iso8601(started),
          "window_ended_at" => DateTime.to_iso8601(DateTime.add(started, 5, :second)),
          "receipt" => 200 + index
        },
        fields
      )
    end

    defp key(row), do: {row["template_fingerprint"], row["call_site_fingerprint"], row["level"]}
    defp keyed(rows), do: rows |> Enum.group_by(&key/1) |> Enum.to_list()

    test "two templates at one call site stay two series; one template across windows is one" do
      unavailable = %{
        "template" => "database unavailable",
        "template_fingerprint" => "bbbbbbbbbbbbbbbb",
        "count" => 2
      }

      rows = [burst(0, %{}), burst(0, unavailable), burst(1, %{"count" => 30})]
      logger = Trends.logger(keyed(rows), 8)

      assert [checkout, database] = logger
      assert checkout["template"] == "checkout failed for N"
      assert checkout["template_fingerprint"] == "aaaaaaaaaaaaaaaa"
      assert checkout["count"] == 40
      assert checkout["windows"] == 2
      assert checkout["peak_count"] == 30
      assert checkout["exemplar_receipts"] == [100, 101]

      assert database["template"] == "database unavailable"
      assert database["template_fingerprint"] == "bbbbbbbbbbbbbbbb"
      assert database["count"] == 2

      assert checkout["call_site_fingerprint"] == database["call_site_fingerprint"]

      text = Trends.text(document([], keyed(rows)))
      assert text =~ ~s(Burst: 40 error "checkout failed for N" from Shop.Checkout.run/2:96)
      assert text =~ ~s(Burst: 2 error "database unavailable" from Shop.Checkout.run/2:96)
    end

    test "the overflow row is its own series and says how many distinctions were folded" do
      overflow =
        burst(0, %{
          "overflow" => true,
          "distinct_lost" => 7,
          "count" => 90,
          "template" => nil,
          "template_fingerprint" => "overflow",
          "call_site" => nil,
          "call_site_fingerprint" => nil,
          "call_sites" => nil,
          "exemplar_receipt" => nil
        })

      rows = [burst(0, %{}), overflow, %{overflow | "distinct_lost" => 3, "count" => 10}]
      logger = Trends.logger(keyed(rows), 8)

      assert [folded, _checkout] = logger
      assert folded["overflow"] == true
      assert folded["distinct_lost"] == 10
      assert folded["count"] == 100
      assert folded["template"] == nil

      assert Enum.map(folded["series"], & &1["distinct_lost"]) == [7, 3]

      text = Trends.text(document([], keyed(rows)))

      assert text =~
               "Burst overflow: 100 error messages beyond the per-interval burst key cap, 10 distinct template and call-site keys folded"
    end

    test "a lost burst exemplar is surfaced" do
      rows = [burst(0, %{"exemplar_receipt" => nil, "exemplar_lost" => true}), burst(1, %{})]
      assert [series] = Trends.logger(keyed(rows), 8)
      assert series["exemplars_lost"] == 1
      assert Enum.map(series["series"], & &1["exemplar_lost"]) == [true, false]
      assert Trends.text(document([], keyed(rows))) =~ "1 exemplar lost"
    end

    test "a strict burst without template or call site is named by its fingerprints" do
      rows = [burst(0, %{"template" => nil, "call_site" => nil})]
      assert [series] = Trends.logger(keyed(rows), 8)
      text = Trends.text(document([], keyed(rows)))
      assert text =~ "template aaaaaaaaaaaaaaaa from call site cccccccccccccccc"
      assert series["template"] == nil
    end
  end

  test "a window of zero milliseconds has no rate, and the change says so" do
    row = %{"count" => 3, "errors" => 0, "interval_ms" => 0, "p95_us" => 10, "exemplars" => []}
    later = %{row | "interval_ms" => 1_000}

    assert [series] = Trends.telemetry([{"k", [row, later]}], 10)
    assert [%{"rate_per_min" => nil}, %{"rate_per_min" => 180}] = series["series"]
    assert series["change"]["rate_per_min"]["direction"] == nil
  end

  test "the document names its schema and the fixed unit of every value" do
    doc = document([series("a.b", nil, [1_000, 1_000])], [])

    assert doc["schema"] == Trends.schema()
    assert Trends.schema() == "insider.live-trends/v1"
    assert doc["units"] == Trends.units()
    assert Trends.units()["duration"] == "us"
    assert Trends.units()["rate"] == "events per minute"
  end

  test "a first error lost in several windows is counted in the text" do
    rows = [
      window(0, %{"errors" => 1, "first_error_retained" => false}),
      window(1, %{"errors" => 1, "first_error_retained" => false})
    ]

    assert Trends.text(document([{"k.v", rows}], [])) =~ "first error not retained in 2 windows"
  end

  test "a window with no events has no error share" do
    rows = [window(0, %{"count" => 0, "errors" => 0}), window(1, %{"count" => 4, "errors" => 1})]
    assert [series] = Trends.telemetry([{"k", rows}], 8)
    assert Enum.map(series["series"], & &1["error_pct"]) == [nil, 25]
    assert series["change"]["error_pct"]["direction"] == nil
  end

  test "a burst with no template, call site, or exemplar still reads as one line" do
    burst = %{
      "level" => "warning",
      "count" => 5,
      "windows" => 1,
      "peak_count" => 5,
      "exemplar_receipts" => [],
      "change" => %{"rate_per_min" => nil}
    }

    assert Trends.lines([], [burst], 1) == [
             "Burst: 5 warning from an unknown call site over 1 windows (peak 5 per window, rate ?)."
           ]

    # A hand-built burst without receipts or change reads the same.
    assert Trends.lines([], [Map.drop(burst, ["exemplar_receipts", "change"])], 1) ==
             Trends.lines([], [burst], 1)
  end

  test "durations read in us, whole ms, or seconds, and an unknown one as ?" do
    assert Trends.us_text(nil) == "?"
    assert Trends.us_text(999) == "999 us"
    assert Trends.us_text(1_999) == "1 ms"
    assert Trends.us_text(2_500_000) == "2.50 s"
  end
end
