defmodule Insider.Live.QueryShapesTest do
  use ExUnit.Case, async: true

  alias Insider.Live.QueryShapes

  @trace "d2ba1d8800000000000000000000beef"
  @edges "SELECT o0.id, o0.product_id FROM order_items AS o0 WHERE (o0.order_id = $1)"
  @t0 1_761_300_000_000_000

  defp iso(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp span(n, source, statement, parent, us \\ 1_300) do
    %{
      "receipt" => n,
      "event" => %{
        "source" => "otel",
        "kind" => "otel.span",
        "wall_time" => iso(@t0 + n * 2_000),
        "attributes" => %{
          "trace_id" => @trace,
          "span_id" => String.pad_leading(Integer.to_string(n, 16), 16, "0"),
          "parent_span_id" => parent,
          "name" => "app.repo.query:#{source}",
          "span_kind" => "client",
          "duration_us" => us,
          "start_wall_time" => iso(@t0 + n * 2_000 - us)
        },
        "payload" =>
          if(statement,
            do: %{"span_attributes" => %{"source" => source, "db.statement" => statement}}
          )
      }
    }
  end

  defp parent(n, name) do
    %{
      "receipt" => n,
      "event" => %{
        "source" => "otel",
        "kind" => "otel.span",
        "attributes" => %{
          "trace_id" => @trace,
          "span_id" => "00000000000000aa",
          "parent_span_id" => nil,
          "name" => name,
          "span_kind" => "internal",
          "duration_us" => 90_000
        }
      }
    }
  end

  # A repo query Telemetry event of the same trace, with Ecto's stacktrace
  # (the repo's `stacktrace: true`), as the rich profile renders it.
  defp query_event(n, source, frames) do
    %{
      "receipt" => n,
      "event" => %{
        "source" => "telemetry",
        "kind" => "app.repo.query",
        "causality" => %{"trace_id" => @trace},
        "attributes" => %{"durations_us" => %{"total_time" => 1_200}},
        "payload" => %{
          "metadata" => %{
            "source" => source,
            "query" => @edges,
            "params" => ["step-7"],
            "stacktrace" => frames
          }
        }
      }
    }
  end

  @frames [
    "{Ecto.Repo.Supervisor, :tuplet, 2, [file: ~c\"lib/ecto/repo/supervisor.ex\", line: 163]}",
    "{MyApp.Repo, :all, 2, [file: ~c\"lib/my_app/repo.ex\", line: 2]}",
    "{Enum, :\"-map/2-lists^map/1-1-\", 2, [file: ~c\"lib/enum.ex\", line: 1714]}",
    "{MyApp.Orders, :list_order_items, 2, [file: ~c\"lib/my_app/orders.ex\", line: 88]}",
    "{MyAppWeb.Resolvers.Orders, :orders, 3, [file: ~c\"lib/my_app_web/resolvers/orders.ex\", line: 12]}"
  ]

  # Readers had the order_items spans in hand but blamed another
  # repeated query. A run of siblings collapsed as "order_items ×26" sat
  # apart from the others.
  test "a request's queries are grouped by table and shape, with the repo stacktrace's caller and the total time" do
    edges = for n <- 1..25, do: span(n, "order_items", @edges, "00000000000000aa")

    users =
      for n <- 30..32,
          do:
            span(
              n,
              "users",
              "SELECT u0.id FROM users AS u0 WHERE (u0.id = $1)",
              "00000000000000aa"
            )

    entries =
      [parent(0, "resolve orders") | edges ++ users] ++
        [query_event(99, "order_items", @frames)]

    assert [first, second] = QueryShapes.repeated(entries)

    assert %{
             "source" => "order_items",
             "count" => 25,
             "total_us" => 32_500,
             "from" => "MyApp.Orders.list_order_items/2",
             "from_kind" => "stacktrace",
             "counted_from" => "spans"
           } = first

    assert first["shape"] =~ ~r/\A[0-9a-f]{8}\z/
    refute inspect(first) =~ "step-7"

    assert %{
             "source" => "users",
             "count" => 3,
             "from" => "resolve orders",
             "from_kind" => "parent_span"
           } = second

    assert QueryShapes.line(first) ==
             "order_items × 25 from MyApp.Orders.list_order_items/2, 32.5 ms total"

    assert QueryShapes.line(second) ==
             "users × 3 from span \"resolve orders\" (no repo stacktrace recorded), 3.9 ms total"
  end

  test "the same table with two shapes is two groups; parameters never split a shape" do
    a =
      for n <- 1..3, do: span(n, "users", "SELECT u0.id FROM users AS u0 WHERE (u0.id = $1)", nil)

    b =
      for n <- 4..5,
          do:
            span(
              n,
              "users",
              "SELECT u0.email FROM users AS u0 WHERE (u0.org_id = $1) LIMIT 10",
              nil
            )

    literal =
      for n <- 6..7,
          do: span(n, "users", "SELECT u0.id FROM users AS u0 WHERE (u0.id = #{n})", nil)

    # A literal is a parameter too: `u0.id = 6` is the shape of `u0.id = $1`.
    assert [%{"count" => 5} = ids, %{"count" => 2} = emails] =
             QueryShapes.repeated(a ++ b ++ literal)

    assert ids["shape"] != emails["shape"]

    assert QueryShapes.line(emails) =~
             ~r/^users \(shape [0-9a-f]{8}\) × 2 \(caller unknown: no repo stacktrace or parent span recorded\), /
  end

  test "without statements (strict), the span name's table is the shape; once-only queries are not repeats" do
    entries = for n <- 1..4, do: span(n, "order_items", nil, nil)

    assert [%{"source" => "order_items", "count" => 4, "shape" => nil}] =
             QueryShapes.repeated(entries)

    assert QueryShapes.repeated([span(1, "users", nil, nil)]) == []
  end

  test "query events count only when the trace has no query spans" do
    events = for n <- 1..12, do: query_event(n, "order_items", @frames)

    assert [
             %{
               "count" => 12,
               "counted_from" => "repo query events",
               "from" => "MyApp.Orders.list_order_items/2"
             }
           ] =
             QueryShapes.repeated(events)
  end

  test "per trace, the repeats at or above a threshold, for the digest" do
    edges = for n <- 1..11, do: span(n, "order_items", @edges, nil)

    other =
      span(50, "users", nil, nil)
      |> put_in(["event", "attributes", "trace_id"], String.duplicate("1", 32))

    assert [
             %{
               "trace_id" => @trace,
               "groups" => [%{"source" => "order_items", "count" => 11}]
             }
           ] =
             QueryShapes.per_trace(edges ++ [other], 10)
  end

  # Every literal is a parameter; a statement that cannot
  # be read whole gives no shape.
  describe "statement shapes" do
    test "two statements differing only in literals have one shape, and no literal survives" do
      pairs = [
        {"SELECT * FROM t WHERE a = 'alpha'", "SELECT * FROM t WHERE a = 'beta''s'"},
        {"SELECT * FROM t WHERE a = E'al\\'pha'", "SELECT * FROM t WHERE a = E'b'"},
        {"SELECT * FROM t WHERE a = $$alpha$$", "SELECT * FROM t WHERE a = $tag$be$$ta$tag$"},
        {"SELECT * FROM t WHERE a = TRUE", "SELECT * FROM t WHERE a = false"},
        {"SELECT * FROM t WHERE a IS NULL AND b = 1",
         "SELECT * FROM t WHERE a IS NULL AND b = 2"},
        {"SELECT * FROM t WHERE a = 1e10", "SELECT * FROM t WHERE a = -2.5E-3"},
        {"SELECT * FROM t WHERE a = 0x1F", "SELECT * FROM t WHERE a = 42"},
        {"SELECT * FROM t WHERE a IN (1, 2, 3)", "SELECT * FROM t WHERE a IN ($1)"},
        {"SELECT * FROM t WHERE a = ANY(ARRAY[1, 2])",
         "SELECT * FROM t WHERE a = ANY(ARRAY['x'])"},
        {"SELECT * FROM t WHERE a = '7'::integer", "SELECT * FROM t WHERE a = '8'::integer"},
        {"INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y')", "INSERT INTO t (a, b) VALUES ($1, $2)"}
      ]

      for {a, b} <- pairs do
        assert QueryShapes.shape(a) == QueryShapes.shape(b), "#{a} | #{b}"
        assert QueryShapes.shape(a) =~ ~r/\A[0-9a-f]{8}\z/
      end

      {:ok, normal} =
        QueryShapes.normalize(
          "INSERT INTO t (a, b) VALUES (1, 'secret'), (2, $q$hidden$q$) RETURNING id, TRUE, 3.5e2, ARRAY[9]"
        )

      for literal <- ~w(1 2 secret hidden TRUE 3.5e2 9), do: refute(normal =~ literal, normal)

      # Structure stays: a different column or table is a different shape.
      refute QueryShapes.shape("SELECT a FROM t WHERE b = 1") ==
               QueryShapes.shape("SELECT a FROM t WHERE c = 1")

      refute QueryShapes.shape("SELECT a FROM t1") == QueryShapes.shape("SELECT a FROM t2")
    end

    test "an unterminated, truncated, or oversized statement has no shape" do
      assert QueryShapes.shape("SELECT * FROM t WHERE a = 'open") == nil
      assert QueryShapes.shape("SELECT * FROM t WHERE a = $$open") == nil
      assert QueryShapes.shape("SELECT * FROM t WHERE a = 'cut by the renderer…") == nil
      assert QueryShapes.shape("SELECT * FROM t WHERE a = $1 …") == nil
      assert QueryShapes.shape("SELECT " <> String.duplicate("a, ", 10_000) <> "b FROM t") == nil
    end
  end

  # A caller is a query's own shape's, or none.
  test "a caller is taken only from a repo query event of the same shape" do
    email = "SELECT u0.id FROM users AS u0 WHERE (u0.email = $1)"
    spans = for n <- 1..5, do: span(n, "users", email, nil)

    other =
      query_event(9, "users", [
        "{App.Unrelated, :find_by_id, 1, [file: ~c\"lib/app.ex\", line: 1]}"
      ])

    assert [%{"from" => nil, "from_kind" => nil}] = QueryShapes.repeated(spans ++ [other])
  end

  # Under strict a query event names no table; it is not
  # grouped, and says so.
  test "query events without a disclosed table are counted as ungrouped, never grouped" do
    strict = for n <- 1..12, do: query_event(n, "x", []) |> put_in(["event", "payload"], nil)
    assert QueryShapes.repeated(strict) == []
    assert QueryShapes.ungrouped(strict) == 12

    # Strict spans name their table but not their shape: grouped, said so,
    # and never an N+1 (no evidence the statements repeat).
    spans = for n <- 1..12, do: span(n, "order_items", nil, nil)
    assert [%{"shape" => nil} = group] = QueryShapes.repeated(spans)
    assert QueryShapes.line(group) =~ "order_items (shape unknown) × 12"
    assert QueryShapes.per_trace(spans, 10) == []
  end

  test "a query event's duration is its first present measurement" do
    for {key, us} <- [{"total_time", 1_200}, {"query_time", 1_100}, {"duration", 900}] do
      event =
        query_event(1, "users", [])
        |> put_in(["event", "attributes", "durations_us"], %{key => us})

      [twice] = QueryShapes.repeated([event, put_in(event, ["receipt"], 2)])
      assert twice["total_us"] == 2 * us
    end

    zero =
      query_event(1, "users", [])
      |> put_in(["event", "attributes", "durations_us"], %{"total_time" => 0, "query_time" => 5})

    assert [%{"total_us" => 0}] = QueryShapes.repeated([zero, zero])
  end
end
