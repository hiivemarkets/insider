defmodule Insider.Lab.LiveOtlpDecodeTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Insider.Lab.Live.Otlp.Decode

  # Recorded from a Next.js frontend's own exporters: the protobuf export is
  # what `registerVercelOtel` with a development `localTracesEndpoint` sent
  # (sanitized, `OTLPHttpProtoTraceExporter`); the JSON export is what
  # `@vercel/otel`'s `OTLPHttpJsonTraceExporter` sent for the same child span;
  # the page render is what `next dev` (Next.js 16) sent
  # for one load of a guest page with `INSIDER_OTLP_ENDPOINT` set.
  @fixtures Path.expand("../fixtures/otlp", __DIR__)
  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "a recorded export from the frontend" do
    test "protobuf: every span with its service, scope, parentage, kind and status" do
      assert {:ok, %{spans: spans, rejected: 0}} =
               Decode.protobuf(fixture("next_vercel_otel_export_v1.pb"))

      assert [child, root] = spans

      assert %{
               "trace_id" => @trace_id,
               "parent_span_id" => "00f067aa0ba902b7",
               "name" => "GET /order-invitation/[token]",
               "span_kind" => "server",
               "status" => "unset",
               "status_message" => nil,
               "service" => "example-marketplace",
               "scope" => "next.js",
               "pid" => nil
             } = root

      assert root["attributes"]["http.status_code"] == 200
      assert root["attributes"]["http.route"] == "/order-invitation/[token]"
      assert root["span_id"] =~ ~r/\A[0-9a-f]{16}\z/

      assert %{
               "trace_id" => @trace_id,
               "span_kind" => "client",
               "status" => "error",
               "status_message" => "fetch failed with 500",
               "service" => "example-marketplace"
             } = child

      assert child["parent_span_id"] == root["span_id"]
      assert child["attributes"]["next.tags"] == ["a", "b"]
      assert child["attributes"]["net.peer.port"] == 4000

      for span <- spans do
        assert is_integer(span["start_time_us"]) and span["start_time_us"] > 1_700_000_000_000_000
        assert is_integer(span["duration_us"]) and span["duration_us"] >= 0
      end
    end

    test "JSON: the same mapping, with times from 64-bit decimal strings" do
      assert {:ok, %{spans: [span], rejected: 0}} =
               Decode.json(fixture("next_otlp_json_export_v1.json"))

      assert %{
               "trace_id" => @trace_id,
               "span_id" => "30039b77fb13f902",
               "parent_span_id" => "c18f893a4a4d9879",
               "name" => "fetch POST http://localhost:4000/graphql",
               "span_kind" => "client",
               "status" => "error",
               "status_message" => "fetch failed with 500",
               "scope" => "next.js",
               "start_time_us" => 1_792_685_131_645_000,
               "duration_us" => 66
             } = span

      assert span["service"] =~ "unknown_service:"
      assert span["attributes"]["next.tags"] == ["a", "b"]
      assert span["attributes"]["http.status_code"] == 500
    end

    test "protobuf from next dev: one page render is one trace under its request span" do
      assert {:ok, %{spans: spans, rejected: 0}} =
               Decode.protobuf(fixture("next_dev_page_render_v1.pb"))

      assert length(spans) == 11
      assert [trace_id] = spans |> Enum.map(& &1["trace_id"]) |> Enum.uniq()
      assert [root] = Enum.filter(spans, &is_nil(&1["parent_span_id"]))

      assert %{"name" => "GET /order-invitation/[token]", "span_kind" => "server"} = root
      assert root["trace_id"] == trace_id
      ids = MapSet.new(spans, & &1["span_id"])
      assert Enum.all?(spans -- [root], &MapSet.member?(ids, &1["parent_span_id"]))
      assert Enum.all?(spans, &(&1["service"] == "example-marketplace"))
    end
  end

  describe "protobuf values" do
    test "flattens key-value lists, keeps scalar lists, and renders other lists as JSON" do
      attributes = [
        key_value("nested", {6, message([{1, key_value("inner", {1, "x"}), :bytes}])}),
        key_value("scalars", {5, message([{1, any({3, 1}), :bytes}, {1, any({2, 1}), :bytes}])}),
        key_value(
          "mixed",
          {5, message([{1, any({6, message([{1, key_value("k", {1, "v"}), :bytes}])}), :bytes}])}
        ),
        key_value("negative", {3, (1 <<< 64) - 5}),
        key_value("ratio", {4, 0.5}),
        key_value("raw", {7, <<0xCA, 0xFE>>}),
        key_value("empty", nil)
      ]

      assert {:ok, %{spans: [span]}} =
               Decode.protobuf(request([span_fields(attributes: attributes)]))

      assert span["attributes"] == %{
               "nested.inner" => "x",
               "scalars" => [1, true],
               "mixed" => ~s([{"k":"v"}]),
               "negative" => -5,
               "ratio" => 0.5,
               "raw" => "cafe",
               "empty" => nil
             }
    end

    test "maps SPAN_KIND_UNSPECIFIED to internal and an absent status to unset" do
      assert {:ok, %{spans: [span]}} = Decode.protobuf(request([span_fields(kind: 0)]))
      assert %{"span_kind" => "internal", "status" => "unset", "parent_span_id" => nil} = span
      assert %{"service" => nil, "scope" => nil} = span
    end

    test "rejects a span whose ids are malformed or all zero, and keeps the rest" do
      spans = [
        span_fields(),
        span_fields(trace_id: <<0::128>>),
        span_fields(span_id: <<1, 2, 3>>),
        span_fields(parent_span_id: <<0::64>>)
      ]

      assert {:ok, %{spans: [_valid], rejected: 3}} = Decode.protobuf(request(spans))
    end

    test "an end before the start is a zero duration" do
      assert {:ok, %{spans: [span]}} =
               Decode.protobuf(request([span_fields(start: 2_000_000, end: 1_000_000)]))

      assert %{"start_time_us" => 2_000, "duration_us" => 0} = span
    end

    test "refuses a malformed body instead of guessing" do
      valid = request([span_fields()])

      assert Decode.protobuf(binary_part(valid, 0, byte_size(valid) - 3)) == {:error, "truncated"}
      assert Decode.protobuf(<<0x0B>>) == {:error, "unsupported_wire_type"}
      # resource_spans (field 1) as a varint instead of a message
      assert Decode.protobuf(<<0x08, 0x01>>) == {:error, "wrong_wire_type"}
      assert Decode.protobuf(request([span_fields(name: <<0xFF>>)])) == {:error, "invalid_utf8"}

      assert Decode.protobuf(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>) ==
               {:error, "truncated"}
    end

    test "refuses values nested deeper than four levels" do
      deep =
        Enum.reduce(1..5, {1, "x"}, fn _level, value ->
          {5, message([{1, any(value), :bytes}])}
        end)

      assert Decode.protobuf(request([span_fields(attributes: [key_value("deep", deep)])])) ==
               {:error, "value_too_deep"}
    end

    test "an empty export has no spans" do
      assert Decode.protobuf("") == {:ok, %{spans: [], rejected: 0}}
    end
  end

  describe "JSON" do
    test "refuses malformed JSON and malformed OTLP shapes" do
      assert Decode.json("{") == {:error, "malformed_json"}
      assert Decode.json("[]") == {:error, "malformed_json"}
      assert Decode.json(~s({"resourceSpans":{}})) == {:error, "malformed_request"}
      assert Decode.json(~s({"resourceSpans":[1]})) == {:error, "malformed_request"}

      assert Decode.json(json_request(%{"startTimeUnixNano" => "12x"})) ==
               {:error, "malformed_request"}
    end

    test "rejects a span with a malformed hex id" do
      assert {:ok, %{spans: [], rejected: 1}} = Decode.json(json_request(%{"traceId" => "zz"}))
    end

    # A malformed parentSpanId became "" and so a valid root.
    for {name, parent} <- [
          {"non-hex", "zz"},
          {"wrong-width", "0102"},
          {"wrong-type", 42},
          {"all-zero", "0000000000000000"}
        ] do
      test "rejects a span with a #{name} parent id" do
        assert {:ok, %{spans: [], rejected: 1}} =
                 Decode.json(json_request(%{"parentSpanId" => unquote(Macro.escape(parent))}))
      end
    end

    test "an absent or empty parent id is a root" do
      assert {:ok, %{spans: [%{"parent_span_id" => nil}], rejected: 0}} =
               Decode.json(json_request(%{}))

      assert {:ok, %{spans: [%{"parent_span_id" => nil}], rejected: 0}} =
               Decode.json(json_request(%{"parentSpanId" => ""}))

      assert {:ok, %{spans: [%{"parent_span_id" => "0a0b0c0d0e0f1011"}]}} =
               Decode.json(json_request(%{"parentSpanId" => "0a0b0c0d0e0f1011"}))
    end

    test "a non-string trace or span id rejects the span" do
      assert {:ok, %{spans: [], rejected: 1}} = Decode.json(json_request(%{"traceId" => 7}))
      assert {:ok, %{spans: [], rejected: 1}} = Decode.json(json_request(%{"spanId" => []}))
    end

    # A 401-digit doubleValue raised ArithmeticError and killed
    # the receiver.
    test "refuses numbers outside OTLP's 64-bit range instead of raising" do
      huge = String.to_integer("1" <> String.duplicate("0", 400))
      double = [%{"key" => "d", "value" => %{"doubleValue" => huge}}]
      integer = [%{"key" => "i", "value" => %{"intValue" => Integer.to_string(huge)}}]

      assert Decode.json(json_request(%{"attributes" => double})) == {:error, "malformed_request"}

      assert Decode.json(json_request(%{"attributes" => integer})) ==
               {:error, "malformed_request"}

      assert Decode.json(json_request(%{"endTimeUnixNano" => Integer.to_string(huge)})) ==
               {:error, "malformed_request"}

      edge = [%{"key" => "d", "value" => %{"doubleValue" => 18_446_744_073_709_551_615}}]
      assert {:ok, %{spans: [span]}} = Decode.json(json_request(%{"attributes" => edge}))
      assert span["attributes"]["d"] == 18_446_744_073_709_551_615 / 1
    end

    # An integer-spelled doubleValue above the 64-bit integer
    # range was refused, although ProtoJSON allows it and its exponent
    # spelling decoded.
    test "a doubleValue is valid in either spelling, above and below the 64-bit range" do
      for {integer, float} <- [
            {100_000_000_000_000_000_000, 1.0e20},
            {-100_000_000_000_000_000_000, -1.0e20},
            {12, 12.0},
            {-9_223_372_036_854_775_809, -9.223372036854775809e18}
          ],
          value <- [integer, float] do
        attributes = [%{"key" => "d", "value" => %{"doubleValue" => value}}]
        assert {:ok, %{spans: [span]}} = Decode.json(json_request(%{"attributes" => attributes}))
        assert span["attributes"]["d"] == float
      end

      # The largest integer a double holds is valid; one beyond any double is not.
      max = trunc(1.7976931348623157e308)
      at_max = [%{"key" => "d", "value" => %{"doubleValue" => max}}]
      past_max = [%{"key" => "d", "value" => %{"doubleValue" => max * 2}}]
      assert {:ok, %{spans: [_span]}} = Decode.json(json_request(%{"attributes" => at_max}))

      assert Decode.json(json_request(%{"attributes" => past_max})) ==
               {:error, "malformed_request"}

      # An intValue stays a 64-bit integer.
      too_big = [%{"key" => "i", "value" => %{"intValue" => 100_000_000_000_000_000_000}}]

      assert Decode.json(json_request(%{"attributes" => too_big})) ==
               {:error, "malformed_request"}
    end

    test "decodes every attribute value form" do
      attributes = [
        %{"key" => "s", "value" => %{"stringValue" => "v"}},
        %{"key" => "b", "value" => %{"boolValue" => false}},
        %{"key" => "i", "value" => %{"intValue" => "-3"}},
        %{"key" => "d", "value" => %{"doubleValue" => 2}},
        %{"key" => "a", "value" => %{"arrayValue" => %{"values" => [%{"intValue" => 1}]}}},
        %{
          "key" => "m",
          "value" => %{
            "kvlistValue" => %{"values" => [%{"key" => "k", "value" => %{"stringValue" => "v"}}]}
          }
        },
        %{"key" => "y", "value" => %{"bytesValue" => Base.encode64(<<1, 2>>)}},
        %{"key" => "n", "value" => %{}}
      ]

      assert {:ok, %{spans: [span]}} = Decode.json(json_request(%{"attributes" => attributes}))

      assert span["attributes"] == %{
               "s" => "v",
               "b" => false,
               "i" => -3,
               "d" => 2.0,
               "a" => [1],
               "m.k" => "v",
               "y" => "0102",
               "n" => nil
             }
    end
  end

  ## A minimal protobuf writer for hand-built requests.

  defp request(spans) do
    scope_spans = message(Enum.map(spans, &{2, &1, :bytes}))
    resource_spans = message([{2, scope_spans, :bytes}])
    message([{1, resource_spans, :bytes}])
  end

  defp span_fields(overrides \\ []) do
    fields =
      Keyword.merge(
        [
          trace_id: <<1::128>>,
          span_id: <<2::64>>,
          name: "span",
          kind: 1,
          start: 1_000,
          end: 3_000
        ],
        overrides
      )

    message(
      [
        {1, fields[:trace_id], :bytes},
        {2, fields[:span_id], :bytes},
        {5, fields[:name], :bytes},
        {6, fields[:kind], :varint},
        {7, fields[:start], :fixed64},
        {8, fields[:end], :fixed64}
      ] ++
        if(fields[:parent_span_id], do: [{4, fields[:parent_span_id], :bytes}], else: []) ++
        Enum.map(Keyword.get(fields, :attributes, []), &{9, &1, :bytes})
    )
  end

  defp key_value(key, nil), do: message([{1, key, :bytes}])
  defp key_value(key, value), do: message([{1, key, :bytes}, {2, any(value), :bytes}])

  defp any({1, text}), do: message([{1, text, :bytes}])
  defp any({2, flag}), do: message([{2, flag, :varint}])
  defp any({3, integer}), do: message([{3, integer, :varint}])
  defp any({4, float}), do: message([{4, <<float::little-float-64>>, :raw64}])
  defp any({number, bytes}) when number in [5, 6, 7], do: message([{number, bytes, :bytes}])

  defp message(fields), do: IO.iodata_to_binary(Enum.map(fields, &field/1))

  defp field({number, value, :bytes}),
    do: [varint(number <<< 3 ||| 2), varint(byte_size(value)), value]

  defp field({number, value, :varint}), do: [varint(number <<< 3), varint(value)]
  defp field({number, value, :fixed64}), do: [varint(number <<< 3 ||| 1), <<value::little-64>>]
  defp field({number, value, :raw64}), do: [varint(number <<< 3 ||| 1), value]

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, value::7, varint(value >>> 7)::binary>>

  defp json_request(span_overrides) do
    span =
      Map.merge(
        %{
          "traceId" => "0102030405060708090a0b0c0d0e0f10",
          "spanId" => "0102030405060708",
          "name" => "s",
          "startTimeUnixNano" => "1000",
          "endTimeUnixNano" => 2000
        },
        span_overrides
      )

    Jason.encode!(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]})
  end
end
