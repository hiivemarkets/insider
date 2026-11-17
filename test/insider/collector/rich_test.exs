defmodule Insider.Collector.RichTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Rich
  alias Insider.Event.Value

  defmodule Account do
    @moduledoc false
    defstruct [:email, :password]
  end

  @stripe "sk_" <> "live_" <> "51SyntheticKey0000AbCdEf"

  test "terms keep their JSON structure, and the rest is bounded inspect text" do
    pid = self()

    rendered =
      Rich.render(
        %{
          :atom => :value,
          "string" => "text",
          :integer => 42,
          :huge => 1_000_000_000_000_000_000_000,
          :float => 1.5,
          :booleans => [true, false, nil],
          :charlist => ~c"hello",
          :empty => [],
          :keyword => [timeout: 15_000, mode: :read],
          :duplicate => [a: 1, a: 2],
          :tuple => {:ok, 1},
          :pid => pid,
          :struct => %Account{email: "a@example.com", password: "hidden-synthetic"},
          :binary => <<255, 0>>,
          {:tuple, :key} => 1
        },
        4_096
      )

    assert rendered["atom"] == "value"
    assert rendered["string"] == "text"
    assert rendered["integer"] == 42
    assert rendered["huge"] == "1000000000000000000000"
    assert rendered["float"] == "1.5"
    assert rendered["booleans"] == [true, false, nil]
    assert rendered["charlist"] == [104, 101, 108, 108, 111]
    assert rendered["empty"] == []
    assert rendered["keyword"] == %{"timeout" => 15_000, "mode" => "read"}
    assert rendered["duplicate"] == [%{"a" => 1}, %{"a" => 2}]
    assert rendered["tuple"] == "{:ok, 1}"
    assert rendered["pid"] == inspect(pid)
    # Structs render field by field, never through an Inspect
    # implementation; credential fields are masked.
    assert rendered["struct"] == %{
             "__struct__" => "Elixir.Insider.Collector.RichTest.Account",
             "email" => "a@example.com",
             "password" => "[REDACTED:credential_key]"
           }

    # Bytes that are not UTF-8 are withheld, never spelled out.
    assert rendered["binary"] == "<<2 bytes, not UTF-8>>"
    assert rendered["{:tuple, :key}"] == 1
    assert Value.valid?(rendered, 4_096)
  end

  test "credential keys and secret-shaped text are masked before anything is cut" do
    secret = "Bearer " <> String.duplicate("A1b2", 600)

    rendered =
      Rich.render(
        %{
          password: "hunter2-synthetic",
          headers: [{"authorization", "Basic c3ludGhldGljOnN5bnRoZXRpYw=="}],
          options: [api_key: @stripe, pool_size: 10],
          nested: %{"deeper" => %{"Client-Secret" => %{"x" => "synthetic"}}},
          message: "calling with " <> secret,
          tail: String.duplicate("x", 2_040) <> @stripe
        },
        8_192
      )

    assert rendered["password"] == "[REDACTED:credential_key]"
    assert rendered["options"] == %{"api_key" => "[REDACTED:credential_key]", "pool_size" => 10}
    assert rendered["nested"] == %{"deeper" => %{"Client-Secret" => "[REDACTED:credential_key]"}}
    assert rendered["message"] == "calling with [REDACTED:authorization_header]"
    refute inspect(rendered) =~ "synthetic"
    refute inspect(rendered) =~ "c3ludGhldGlj"
    refute inspect(rendered) =~ "sk_live"
    refute inspect(rendered) =~ "A1b2A1b2"
  end

  test "work past the payload deadline or node budget fails closed to a marker" do
    # An emitter whose payload work budget is spent renders markers, not values.
    Process.put({Rich, :deadline}, 0)

    try do
      assert Rich.render(%{"a" => "secret-free text"}, 1_000) == "…[time_limit]"
    after
      Process.delete({Rich, :deadline})
    end

    assert Rich.render(%{"a" => "kept"}, 1_000) == %{"a" => "kept"}
    assert Process.get({Rich, :deadline}) == nil

    # A huge nested tuple stays within the node budget.
    wide = List.to_tuple(for i <- 1..32, do: List.to_tuple(for j <- 1..32, do: {i, j, [i, j]}))
    {elapsed, rendered} = :timer.tc(fn -> Rich.render(%{"t" => wide}, 7_000) end)
    assert String.starts_with?(rendered["t"], "{{{1, 1, [1, 1]}, {1, 2, [1, 2]}")
    assert byte_size(rendered["t"]) <= Rich.bounds()["string_bytes"]
    assert elapsed < 1_000_000

    # A struct inside a tuple is sanitized to a plain map, field by field.
    tuple = Rich.render(%{"t" => {:ok, %URI{host: "h", userinfo: "u:synthetic"}}}, 2_000)
    assert tuple["t"] =~ ~s("__struct__" => "Elixir.URI")
    refute tuple["t"] =~ "synthetic"
  end

  test "strings, width, depth, and the byte budget are bounded" do
    long = String.duplicate("é", 3_000)
    wide = Map.new(1..100, &{"k#{String.pad_leading(Integer.to_string(&1), 3, "0")}", &1})
    deep = Enum.reduce(1..10, "leaf", fn _level, acc -> %{"level" => acc} end)

    rendered = Rich.render(%{"long" => long, "wide" => wide, "deep" => deep}, 7_000)

    assert byte_size(rendered["long"]) <= Rich.bounds()["string_bytes"]
    assert String.ends_with?(rendered["long"], "…[truncated]")
    assert String.valid?(rendered["long"])

    assert map_size(rendered["wide"]) == Rich.bounds()["width"] + 1
    assert rendered["wide"]["$insider_truncated"] == 100 - Rich.bounds()["width"]

    assert depth(rendered["deep"]) <= Rich.bounds()["depth"] + 1
    assert Value.valid?(rendered, 7_000)

    for budget <- [64, 256, 1_000, 3_000, 7_168] do
      huge = Map.new(1..200, &{"key#{&1}", String.duplicate(~s("q"), 300)})
      bounded = Rich.render(huge, budget)
      assert Value.valid?(bounded, budget), "budget #{budget}"
      assert bounded["$insider_truncated"] > 0
    end
  end

  test "Logger metadata omission counts come from the whole metadata map" do
    for {count, omitted} <- [{32, nil}, {33, 1}, {100, 68}] do
      metadata =
        Map.new(1..count, &{:"k#{String.pad_leading(Integer.to_string(&1), 3, "0")}", &1})

      payload = Rich.logger_payload(:info, {:string, "m"}, Map.put(metadata, :report_cb, & &1))
      rendered = payload["metadata"]
      assert rendered["$insider_truncated"] == omitted, "#{count} entries"
      assert map_size(Map.delete(rendered, "$insider_truncated")) == min(count, 32)
    end
  end

  test "Logger payloads carry the rendered message text, level, and metadata" do
    metadata = %{
      time: 1,
      mfa: {Foo, :bar, 2},
      file: ~c"lib/foo.ex",
      ids: [1, 2],
      nested: %{path: ~c"lib/bar.ex"},
      request_id: "F-req-1",
      user_token: "synthetic",
      report_cb: &inspect/1
    }

    assert %{
             "level" => "info",
             "message" => "user 42 signed in",
             "metadata" => rendered
           } = Rich.logger_payload(:info, {:string, ["user ", ~c"42", " signed in"]}, metadata)

    assert rendered["request_id"] == "F-req-1"
    assert rendered["mfa"] == "{Foo, :bar, 2}"
    # Top-level printable charlists are text, as in Logger's formatter.
    assert rendered["file"] == "lib/foo.ex"
    assert rendered["ids"] == [1, 2]
    assert rendered["nested"] == %{"path" => ~c"lib/bar.ex"}
    assert rendered["user_token"] == "[REDACTED:credential_key]"
    refute Map.has_key?(rendered, "report_cb")

    assert Rich.logger_payload(:warning, {~c"~p items", [3]}, %{})["message"] == "3 items"

    # A report's callback is never called; the message is the sanitized
    # report, and the report is also rendered field by field.
    report = %{label: :custom, detail: "x", api_key: "synthetic"}
    callback = fn _report -> raise "must not be called" end
    payload = Rich.logger_payload(:error, {:report, report}, %{report_cb: callback})
    assert payload["message"] =~ ~s(detail: "x")
    assert payload["message"] =~ "api_key: \"[REDACTED:credential_key]\""
    assert payload["report"]["label"] == "custom"
    assert payload["report"]["api_key"] == "[REDACTED:credential_key]"
    refute inspect(payload) =~ "synthetic"

    assert Rich.logger_payload(:notice, {:report, [answer: 42]}, %{})["message"] =~ "42"

    # Format arguments are sanitized before OTP formats them, so escaping
    # cannot hide a secret.
    escaped = Rich.logger_payload(:info, {~c"~p", [~s({"password": "synthetic"})]}, %{})
    refute escaped["message"] =~ "synthetic"

    # Malformed chardata yields a fixed marker.
    assert Rich.logger_payload(:error, {:string, [:not_chardata]}, %{})["message"] ==
             "[unprintable message]"

    # Escaping cannot push the payload past its encoded bound.
    escaped = Rich.logger_payload(:info, {:string, String.duplicate(<<0>>, 2_000)}, %{a: 1})
    assert Value.valid?(escaped, Rich.bounds()["payload_bytes"])
    assert escaped["metadata"] == %{"a" => 1}

    # A credential inside a long inspected term is masked before it is cut.
    url = "postgres://u:" <> String.duplicate("a", 1_100) <> "@localhost/db"
    rendered = Rich.render(%{result: {:error, url}}, 7_000)
    refute rendered["result"] =~ "aaaaaaaa"

    big = Rich.logger_payload(:info, {:string, String.duplicate("word ", 5_000)}, metadata)
    assert byte_size(big["message"]) <= Rich.bounds()["message_bytes"]
    assert Value.valid?(big, Rich.bounds()["payload_bytes"])
  end

  test "Logger format messages are formatted only when every directive's width is bounded" do
    message = fn format, arguments ->
      Rich.logger_payload(:info, {format, arguments}, %{})["message"]
    end

    # `~~` is a literal tilde; widths and precisions are summed per directive.
    assert message.("100~~ of ~p", [3]) == "100~ of 3"
    assert message.(~c"~8.3f|~-6s|", [1.5, "ab"]) == "   1.500|ab    |"
    # A width over 256 is never padded: the message is the sanitized term.
    assert message.("~300p", [1]) == ~s({"~300p", [1]})
    # A format the formatter rejects is the sanitized term too.
    assert message.("ends in a width ~5", []) == ~s({"ends in a width ~5", []})
    # A message that is no string, report, or format is its sanitized term.
    assert Rich.logger_payload(:info, {:not_a_format, []}, %{})["message"] ==
             "{:not_a_format, []}"
  end

  test "a long message whose first bytes are not UTF-8 is withheld by size" do
    payload = Rich.logger_payload(:info, {:string, :binary.copy(<<0xFF>>, 9_000)}, %{})
    assert payload["message"] == "<<8192 bytes, not UTF-8>>"
  end

  test "format arguments are sanitized within the width bound before OTP formats them" do
    format = fn argument -> Rich.logger_payload(:info, {"~p", [argument]}, %{})["message"] end

    # A list keeps its first 32 items and marks the cut.
    list = format.(Enum.to_list(1..40))
    assert list =~ "31,32,"
    refute list =~ "33"
    assert String.ends_with?(list, "]")

    # A map keeps 32 entries and counts the rest.
    assert format.(Map.new(1..40, &{&1, &1})) =~ ~s(<<"$insider_truncated">> => 8)
  end

  test "empty, non-UTF-8, and non-text keys get stable names" do
    rendered = Rich.render(%{"" => 1, <<0xFF>> => 2, {:pair, 1} => 3}, 1_000)
    assert rendered == %{"$empty_key" => 1, "$binary_key" => 2, "{:pair, 1}" => 3}
  end

  test "improper and overlong lists render without walking past their bound" do
    assert Rich.render(%{"l" => [1, 2 | 3]}, 1_000) == %{"l" => [1, 2, "{:improper_tail, 3}"]}

    assert Rich.render(%{"c" => [?a, ?b | :x]}, 1_000) == %{
             "c" => [97, 98, "{:improper_tail, :x}"]
           }

    # A charlist too long to scan is not taken for text: it stays a list,
    # cut to the width bound.
    long = List.duplicate(?a, 9_000)
    rendered = Rich.logger_payload(:info, {:string, "m"}, %{long: long})["metadata"]["long"]
    assert [?a | _rest] = rendered
    assert length(rendered) <= Rich.bounds()["width"] + 1
  end

  test "a DateTime in another zone renders as its inspect text; a forged zone field by field" do
    zoned = %{
      ~U[2026-10-22 05:01:02Z]
      | time_zone: "America/Vancouver",
        zone_abbr: "PDT",
        utc_offset: -28_800,
        std_offset: 3_600
    }

    assert Rich.render(%{"t" => zoned}, 1_000) ==
             %{"t" => "#DateTime<2026-10-22 05:01:02-07:00 PDT America/Vancouver>"}

    forged = %{zoned | utc_offset: 999_999}

    assert %{"t" => %{"__struct__" => "Elixir.DateTime", "utc_offset" => 999_999}} =
             Rich.render(%{"t" => forged}, 1_000)
  end

  test "Telemetry payloads keep the short facts when the long ones do not fit" do
    query =
      "SELECT " <> Enum.map_join(1..400, ", ", &~s(u0."column_#{&1}")) <> ~s( FROM "users" AS u0)

    payload =
      Rich.telemetry_payload(%{
        repo: MyApp.Repo,
        source: "users",
        query: query,
        params: [1, "a"],
        result: {:ok, %{num_rows: 1, rows: [[1]]}},
        stacktrace:
          for(index <- 1..50, do: {Foo, :bar, index, [file: ~c"lib/foo.ex", line: index]}),
        options: [password: "synthetic", timeout: 15_000]
      })

    metadata = payload["metadata"]
    assert metadata["source"] == "users"
    assert metadata["repo"] == "Elixir.MyApp.Repo"
    assert String.starts_with?(metadata["query"], ~s(SELECT u0."column_1"))
    assert metadata["params"] == [1, "a"]
    assert metadata["options"]["password"] == "[REDACTED:credential_key]"
    assert Value.valid?(payload, Rich.bounds()["payload_bytes"])
  end

  test "measurements keep numbers and render the rest, optionally selected" do
    measurements = %{
      duration: 930,
      ratio: 0.5,
      label: :fast,
      api_key: "synthetic",
      nested: %{a: 1}
    }

    assert Rich.measurements(measurements, %{}) == %{
             "duration" => 930,
             "ratio" => "0.5",
             "label" => "fast",
             "api_key" => "[REDACTED:credential_key]",
             "nested" => %{"a" => 1}
           }

    assert Rich.measurements(measurements, %{duration: "duration", missing: "missing"}) ==
             %{"duration" => 930}
  end

  defp depth(value) when is_map(value),
    do: 1 + (value |> Map.values() |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  defp depth(_value), do: 0
end
