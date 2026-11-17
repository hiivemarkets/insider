defmodule Insider.Live.DisclosureTest do
  # One collector session is global per node, and these tests change the
  # `:insider` application environment, so this module cannot run in parallel
  # with other session users.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Insider.Collector.Rich
  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Disclosure

  @query [:insider_disclosure_test, :query]
  @telemetry %{
    "components" => ["logger", "telemetry"],
    "telemetry_events" => [["insider_disclosure_test", "query"]]
  }
  @statement ~s[SELECT u0."id", u0."email" FROM "users" AS u0 WHERE (u0."id" = $1)]

  # Synthetic, provider-shaped credentials, split so no literal appears whole.
  @stripe "sk_" <> "live_" <> "51SyntheticKey0000AbCdEf"
  @bearer "Bearer " <> "synthBearerToken0123456789"
  @jwt "eyJhbGciOiJIUzI1NiJ9" <> "." <> "eyJzdWIiOiJzeW50aGV0aWMifQ" <> "." <> "c2lnbmF0dXJl"
  @password "hunter2-" <> "synthetic"
  @secrets [@stripe, "synthBearerToken", @jwt, @password, "c2lnbmF0dXJl"]

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)
      Application.delete_env(:insider, :live_disclosure)
      Application.delete_env(:insider, :live_telemetry_measurements)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  describe "host profile" do
    test "development and test default to rich, ci to strict, and the host can choose" do
      for {environment, profile} <- [development: "rich", test: "rich", ci: "strict"] do
        Application.put_env(:insider, :environment, environment)

        assert %{
                 "disclosure_profile" => ^profile,
                 "disclosure_profile_source" => "environment_default",
                 "disclosure_profiles" => ["rich", "strict"],
                 "masking_policy_id" => "insider-credential-masking/v1"
               } = Live.capabilities()
      end

      Application.put_env(:insider, :live_disclosure, :rich)
      assert %{"disclosure_profile" => "rich"} = Live.capabilities()
      assert Live.capabilities()["disclosure_profile_source"] == "application_env"
      assert "disclosure" in Live.capabilities()["start_options"]

      Application.put_env(:insider, :environment, :development)
      Application.put_env(:insider, :live_disclosure, :strict)
      assert %{"disclosure_profile" => "strict"} = Live.capabilities()

      # An unknown configured value fails closed.
      Application.put_env(:insider, :live_disclosure, :verbose)

      assert %{
               "disclosure_profile" => "strict",
               "disclosure_profile_source" => "invalid_application_env"
             } = Live.capabilities()

      # Where live observation is denied, rich is never the profile.
      Application.put_env(:insider, :live_disclosure, :rich)

      for environment <- [:staging, :production] do
        Application.put_env(:insider, :environment, environment)
        assert %{"disclosure_profile" => "strict"} = Live.capabilities()
      end
    end
  end

  describe "rich profile" do
    test "in development returns Logger text and metadata and Telemetry metadata with the query" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, started} = Live.start(@telemetry)
      id = started["session_id"]

      assert %{
               "disclosure_profile" => "rich",
               "masking_policy_id" => "insider-credential-masking/v1"
             } = started

      capture_log(fn ->
        Logger.warning("listing 42 published", request_id: "req-synthetic-1", listing_id: 42)
      end)

      :telemetry.execute(
        @query,
        %{query_time: 930, decode_time: 12, idle_time: 5},
        %{
          repo: MyApp.Repo,
          source: "users",
          query: @statement,
          params: [42],
          result: {:ok, %{num_rows: 1}},
          options: [timeout: 15_000]
        }
      )

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      assert plain?(batch)
      assert batch["gaps"] == []

      log = find(batch, &(&1["source"] == "logger" and &1["payload"]["level"] == "warning"))
      assert log["payload"]["message"] == "listing 42 published"
      assert log["payload"]["metadata"]["request_id"] == "req-synthetic-1"
      assert log["payload"]["metadata"]["listing_id"] == 42
      assert log["payload"]["metadata"]["mfa"] =~ "Insider.Live.DisclosureTest"

      query = find(batch, &(&1["kind"] == "insider_disclosure_test.query"))
      metadata = query["payload"]["metadata"]
      assert metadata["source"] == "users"
      assert metadata["query"] == @statement
      assert metadata["repo"] == "Elixir.MyApp.Repo"
      assert metadata["params"] == [42]
      assert metadata["options"] == %{"timeout" => 15_000}
      assert metadata["result"] == "{:ok, %{num_rows: 1}}"
      assert query["attributes"]["projection"] == "telemetry.rich/v1"

      assert query["attributes"]["measurements"] == %{
               "query_time" => 930,
               "decode_time" => 12,
               "idle_time" => 5
             }

      json = Live.JSON.events_since(id, 0, %{"limit" => 500})
      assert json =~ ~s(listing 42 published)
      assert json =~ ~s(\\"users\\")

      assert {:ok, %{"disclosure_profile" => "rich", "masking_policy_id" => _}} = Live.status(id)
    end

    test "a selected measurement list narrows a rich session's measurements, with a drop record each" do
      Application.put_env(:insider, :environment, :development)

      assert {:ok, %{"session_id" => id}} =
               Live.start(Map.put(@telemetry, "telemetry_measurements", ["query_time"]))

      :telemetry.execute(@query, %{query_time: 7, decode_time: 1, rows_seen: 3}, %{
        source: "users"
      })

      assert {:ok, batch} = Live.events_since(id, 0)

      entry =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      query = entry["event"]
      assert query["attributes"]["measurements"] == %{"query_time" => 7}
      assert query["payload"]["metadata"] == %{"source" => "users"}

      # decode_time is in the host allowlist, so its record names it; the
      # unknown rows_seen is counted without its name.
      assert entry["redactions"] == [
               selection_drop(["key:attributes", "key:measurements", "key:decode_time"], 1),
               selection_drop(["key:attributes", "key:measurements"], 1)
             ]

      assert query["redactions"] == []
      refute Jason.encode!(entry) =~ "rows_seen"
    end

    test "without a selection a rich session collects every measurement and drops nothing" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)
      :telemetry.execute(@query, %{query_time: 7, rows_seen: 3}, %{source: "users"})

      assert {:ok, batch} = Live.events_since(id, 0)

      entry =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      assert entry["event"]["attributes"]["measurements"] == %{
               "query_time" => 7,
               "rows_seen" => 3
             }

      assert entry["redactions"] == []
    end

    test "values are bounded so a large event is still recorded" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

      capture_log(fn ->
        Logger.warning(String.duplicate("long line ", 20_000),
          blob: Map.new(1..500, &{"k#{&1}", String.duplicate("v", 500)})
        )
      end)

      :telemetry.execute(@query, %{query_time: 1}, %{
        source: "users",
        query: String.duplicate("SELECT 1; ", 10_000),
        rows: Enum.to_list(1..5_000)
      })

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500, "max_bytes" => 1_048_576})
      assert batch["gaps"] == []

      log = find(batch, &(&1["source"] == "logger" and &1["payload"]["level"] == "warning"))
      bounds = Rich.bounds()
      assert byte_size(log["payload"]["message"]) <= bounds["message_bytes"]
      assert String.ends_with?(log["payload"]["message"], "…[truncated]")
      assert log["payload"]["metadata"]["blob"]["$insider_truncated"] > 0
      assert byte_size(Jason.encode!(log["payload"])) <= bounds["payload_bytes"]

      query = find(batch, &(&1["kind"] == "insider_disclosure_test.query"))
      metadata = query["payload"]["metadata"]
      assert metadata["source"] == "users"
      assert byte_size(metadata["query"]) <= bounds["string_bytes"]
      assert Enum.count(metadata["rows"]) == bounds["width"] + 1
      assert List.last(metadata["rows"]) == %{"$insider_truncated" => 5_000 - bounds["width"]}
      assert byte_size(Jason.encode!(query["payload"])) <= bounds["payload_bytes"]
    end
  end

  describe "strict profile" do
    test "in ci matches the boundary: no Logger content, no Telemetry metadata" do
      Application.put_env(:insider, :environment, :ci)

      assert {:ok, %{"session_id" => id, "disclosure_profile" => "strict"}} =
               Live.start(Map.put(@telemetry, "telemetry_measurements", ["query_time"]))

      capture_log(fn -> Logger.warning("listing 42 published", request_id: "req-1") end)

      :telemetry.execute(@query, %{query_time: 930, other: 1}, %{
        source: "users",
        query: @statement
      })

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      events = Enum.map(batch["events"], & &1["event"])
      assert Enum.all?(events, &is_nil(&1["payload"]))
      refute Jason.encode!(batch) =~ "listing 42"
      refute Jason.encode!(batch) =~ "users"

      entry =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      query = entry["event"]
      assert query["attributes"]["metadata"] == %{}
      assert query["attributes"]["measurements"] == %{"query_time" => 930}
      assert query["attributes"]["projection"] == "telemetry.allowlist/v1"

      # The unselected measurement and the two metadata keys were never
      # collected; each leaves a counted drop record, never the key.
      assert entry["redactions"] == [
               selection_drop(["key:attributes", "key:measurements"], 1),
               selection_drop(["key:attributes", "key:metadata"], 2)
             ]
    end

    test "an unselected allowlisted measurement is named in its drop record" do
      Application.put_env(:insider, :environment, :ci)
      # A minimum of 0 keeps this short query; the quiet default would drop it.
      assert {:ok, %{"session_id" => id}} =
               Live.start(Map.put(@telemetry, "telemetry_min_duration_ms", 0))

      :telemetry.execute(@query, %{query_time: 930, total_time: 1_000}, %{})

      assert {:ok, batch} = Live.events_since(id, 0)

      entry =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      assert entry["event"]["attributes"]["measurements"] == %{}

      assert entry["redactions"] == [
               selection_drop(["key:attributes", "key:measurements", "key:query_time"], 1),
               selection_drop(["key:attributes", "key:measurements", "key:total_time"], 1)
             ]
    end
  end

  # A withheld exemplar duration is
  # addressed by its index in the exemplars list, one record per value.
  describe "summaries in strict" do
    defp summary_event(exemplars, scope) do
      %{
        "source" => "telemetry",
        "kind" => "shop.checkout.stop",
        "causality" => %{},
        "payload" => nil,
        "attributes" => %{
          "lifecycle_phase" => "summary",
          "measurements" => %{},
          "metadata" => %{},
          "summary" => %{
            "count" => 3,
            "errors" => 1,
            "duration_measurements" => ["duration"],
            "duration_p50_us" => 10,
            "duration_p95_us" => 900,
            "duration_max_us" => 910,
            "exemplars" => exemplars,
            "exemplars_lost" => 0,
            "first_error_retained" => true,
            "duration_scope" => scope
          }
        }
      }
    end

    @exemplars [
      %{"receipt" => 7, "roles" => ["slowest"], "duration_us" => 910, "error" => false},
      %{"receipt" => 8, "roles" => ["first_error"], "duration_us" => nil, "error" => true},
      %{"receipt" => 9, "roles" => ["slowest"], "duration_us" => 900, "error" => false}
    ]
    @server_scope %{
      "measured_in" => "unknown",
      "declared" => false,
      "emitter" => %{"context" => "otp_server", "module" => "Shop.Pricing"}
    }

    defp boundary_drop(path),
      do: %{
        "action" => "drop",
        "count" => 1,
        "path" => path,
        "policy_id" => Disclosure.policy_id()
      }

    test "each withheld exemplar duration is one drop record at its index" do
      entry = %{"event" => summary_event(@exemplars, @server_scope), "redactions" => []}
      projected = Disclosure.project(entry, %{}, :strict)
      summary = projected["event"]["attributes"]["summary"]

      assert Enum.map(summary["exemplars"], & &1["duration_us"]) == [nil, nil, nil]
      assert Enum.map(summary["exemplars"], & &1["receipt"]) == [7, 8, 9]
      assert summary["duration_p95_us"] == nil
      assert summary["count"] == 3 and summary["exemplars_lost"] == 0
      assert summary["first_error_retained"] == true

      assert summary["duration_scope"] == %{
               "measured_in" => "unknown",
               "declared" => false,
               "emitter" => %{"context" => "otp_server", "module" => nil}
             }

      prefix = ["key:attributes", "key:summary"]

      assert Enum.sort(projected["redactions"]) ==
               Enum.sort([
                 boundary_drop(prefix ++ ["key:duration_scope", "key:emitter", "key:module"]),
                 boundary_drop(prefix ++ ["key:duration_max_us"]),
                 boundary_drop(prefix ++ ["key:duration_p50_us"]),
                 boundary_drop(prefix ++ ["key:duration_p95_us"]),
                 boundary_drop(prefix ++ ["key:exemplars", "index:0", "key:duration_us"]),
                 boundary_drop(prefix ++ ["key:exemplars", "index:2", "key:duration_us"])
               ])

      # Allowlisted durations pass; the emitting module is still withheld.
      allowed = Disclosure.project(entry, %{"duration" => :duration}, :strict)
      summary = allowed["event"]["attributes"]["summary"]
      assert Enum.map(summary["exemplars"], & &1["duration_us"]) == [910, nil, 900]

      assert allowed["redactions"] == [
               boundary_drop(prefix ++ ["key:duration_scope", "key:emitter", "key:module"])
             ]

      # Rich passes the summary as recorded.
      rich = Disclosure.project(entry, %{}, :rich)
      assert rich["event"]["attributes"]["summary"] == entry["event"]["attributes"]["summary"]
      assert rich["redactions"] == []
    end

    test "a Logger burst's template and call site are withheld, its fingerprints kept" do
      burst = %{
        "count" => 12,
        "level" => "error",
        "template" => "checkout failed for N",
        "template_fingerprint" => "aaaaaaaaaaaaaaaa",
        "call_site" => %{"module" => "Shop.Checkout", "function" => "run/2", "line" => 96},
        "call_site_fingerprint" => "cccccccccccccccc",
        "call_sites" => 1,
        "exemplar_receipt" => 4,
        "exemplar_lost" => false
      }

      event = fn summary ->
        %{
          "source" => "logger",
          "kind" => "logger_summary",
          "causality" => %{},
          "payload" => nil,
          "attributes" => %{"summary" => summary}
        }
      end

      projected =
        Disclosure.project(%{"event" => event.(burst), "redactions" => []}, %{}, :strict)

      summary = projected["event"]["attributes"]["summary"]

      assert summary == %{burst | "template" => nil, "call_site" => nil}

      assert projected["redactions"] == [
               boundary_drop(["key:attributes", "key:summary", "key:call_site"]),
               boundary_drop(["key:attributes", "key:summary", "key:template"])
             ]

      # The overflow row carries neither, so nothing is withheld.
      overflow = %{
        burst
        | "template" => nil,
          "call_site" => nil,
          "template_fingerprint" => "overflow",
          "call_site_fingerprint" => nil
      }

      overflow = Map.merge(overflow, %{"overflow" => true, "distinct_lost" => 5})

      projected =
        Disclosure.project(%{"event" => event.(overflow), "redactions" => []}, %{}, :strict)

      assert projected["event"]["attributes"]["summary"] == overflow
      assert projected["redactions"] == []
    end

    test "a summary recorded under rich and read after the host narrows withholds each exemplar duration" do
      Application.put_env(:insider, :environment, :development)
      kind = "insider_disclosure_test.query"

      assert {:ok, %{"session_id" => id, "disclosure_profile" => "rich"}} =
               Live.start(
                 Map.merge(@telemetry, %{
                   "telemetry_min_duration_ms" => 0,
                   "telemetry_summaries" => [kind],
                   "telemetry_summary_interval_ms" => 60_000
                 })
               )

      # A summary's durations come from a duration or total_time measurement.
      native = &System.convert_time_unit(&1, :millisecond, :native)
      :telemetry.execute(@query, %{duration: native.(2)}, %{source: "users"})
      :telemetry.execute(@query, %{duration: native.(40)}, %{source: "users"})
      end_summary_window()

      assert {:ok, rich} = Live.events_since(id, 0, %{"limit" => 500})
      rich_summary = find(rich, &(&1["attributes"]["lifecycle_phase"] == "summary"))
      exemplars = rich_summary["attributes"]["summary"]["exemplars"]
      assert [_ | _] = exemplars
      assert Enum.all?(exemplars, &is_integer(&1["duration_us"]))

      Application.put_env(:insider, :live_disclosure, :strict)
      Application.put_env(:insider, :live_telemetry_measurements, [:count])

      assert {:ok, strict} = Live.events_since(id, 0, %{"limit" => 500})

      entry =
        Enum.find(
          strict["events"],
          &(&1["event"]["attributes"]["lifecycle_phase"] == "summary")
        )

      summary = entry["event"]["attributes"]["summary"]
      assert Enum.all?(summary["exemplars"], &is_nil(&1["duration_us"]))

      exemplar_records =
        Enum.filter(entry["redactions"], fn record ->
          match?(["key:attributes", "key:summary", "key:exemplars" | _], record["path"])
        end)

      assert Enum.sort_by(exemplar_records, & &1["path"]) ==
               for(
                 index <- 0..(length(exemplars) - 1),
                 do:
                   boundary_drop([
                     "key:attributes",
                     "key:summary",
                     "key:exemplars",
                     "index:#{index}",
                     "key:duration_us"
                   ])
               )
    end
  end

  describe "caller narrowing" do
    test "a caller can ask for strict on a rich host but never for rich on a strict host" do
      Application.put_env(:insider, :environment, :development)

      assert {:ok, %{"session_id" => id, "disclosure_profile" => "strict"}} =
               Live.start(Map.put(@telemetry, "disclosure", "strict"))

      capture_log(fn -> Logger.warning("narrowed text") end)
      :telemetry.execute(@query, %{query_time: 1}, %{source: "users"})

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      assert Enum.all?(batch["events"], &is_nil(&1["event"]["payload"]))
      refute Jason.encode!(batch) =~ "narrowed text"
      assert {:ok, %{"disclosure_profile" => "strict"}} = Live.status(id)
      assert {:ok, _stopped} = Live.stop(id)

      Application.put_env(:insider, :environment, :ci)

      assert {:error, error} = Live.start(Map.put(@telemetry, "disclosure", "rich"))
      assert plain?(error)

      assert %{
               "code" => "disclosure_denied",
               "requested" => "rich",
               "disclosure_profile" => "strict"
             } = error

      assert Live.JSON.start(Map.put(@telemetry, "disclosure", "rich")) =~ "disclosure_denied"
      assert Live.capabilities()["active_session_id"] == nil

      for invalid <- ["loose", :rich, 1] do
        assert {:error, %{"code" => "invalid_options", "field" => "disclosure"}} =
                 Live.start(Map.put(@telemetry, "disclosure", invalid))
      end
    end

    test "a host that narrows its profile narrows a running session from its next read" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, %{"session_id" => id, "disclosure_profile" => "rich"}} = Live.start(@telemetry)

      :telemetry.execute(@query, %{query_time: 1}, %{source: "users"})
      assert {:ok, rich} = Live.events_since(id, 0)
      assert find(rich, &(&1["kind"] == "insider_disclosure_test.query"))["payload"]

      Application.put_env(:insider, :live_disclosure, :strict)
      assert {:ok, strict} = Live.events_since(id, 0)
      assert Enum.all?(strict["events"], &is_nil(&1["event"]["payload"]))
      refute Jason.encode!(strict) =~ "users"
      assert {:ok, %{"disclosure_profile" => "strict"}} = Live.status(id)
    end
  end

  describe "credential masking" do
    test "rich output masks URL userinfo, apostrophes included, and keeps host:port" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

      capture_log(fn ->
        Logger.warning(
          "db postgres://u:pa'ss-synth@localhost/db via http://127.0.0.1:4100?x=1 " <>
            "and postgres://u:ghp_12345678901234567890:synth-tail@localhost/db",
          url: "postgres://o'brien:synth-pass@localhost/db",
          endpoint: "http://[::1]:4100",
          body: ~s({"url":"http://localhost:4100","email":"a@b.example"}),
          redis: "redis://u:123,synth@h",
          cut: ~s({"url":"postgres://u:cut-synth"}),
          query: "postgres://u:?synth@h",
          provider_user: "https://ghp_12345678901234567890:synth-pass@localhost/db",
          long: "postgres://u:" <> String.duplicate("a", 2_050) <> "é-synth-tail@h"
        )
      end)

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      refute Live.JSON.events_since(id, 0, %{"limit" => 500}) =~ "synth"

      log = find(batch, &(&1["source"] == "logger" and &1["payload"]["level"] == "warning"))

      assert log["payload"]["message"] ==
               "db postgres://u:[REDACTED:url_credentials]@localhost/db via http://127.0.0.1:4100?x=1 " <>
                 "and postgres://u:[REDACTED:url_credentials]@localhost/db"

      assert log["payload"]["metadata"]["url"] ==
               "postgres://o'brien:[REDACTED:url_credentials]@localhost/db"

      assert log["payload"]["metadata"]["endpoint"] == "http://[::1]:4100"

      assert log["payload"]["metadata"]["body"] ==
               ~s({"url":"http://localhost:4100","email":"a@b.example"})

      assert log["payload"]["metadata"]["redis"] == "redis://u:[REDACTED:url_credentials]@h"

      assert log["payload"]["metadata"]["cut"] ==
               ~s({"url":"postgres://u:[REDACTED:url_credentials]"})

      entry =
        Enum.find(
          batch["events"],
          &(&1["event"]["source"] == "logger" and
              &1["event"]["payload"]["level"] == "warning")
        )

      assert log["payload"]["metadata"]["query"] == "postgres://u:[REDACTED:url_credentials]@h"

      assert log["payload"]["metadata"]["provider_user"] ==
               "https://[REDACTED:provider_key]:[REDACTED:url_credentials]@localhost/db"

      assert log["payload"]["metadata"]["long"] == "postgres://[REDACTED:url_credentials]@h"

      for key <- ["key:url", "key:redis", "key:cut", "key:query", "key:long", "key:provider_user"] do
        path = ["key:payload", "key:metadata", key]
        reasons = for %{"path" => ^path, "reason" => reason} <- entry["redactions"], do: reason
        assert "url_credentials" in reasons, key
      end

      # The message's leaked tail is reported as a URL credential too.
      message =
        for %{"path" => ["key:payload", "key:message"], "reason" => r} <- entry["redactions"],
            do: r

      assert "url_credentials" in message
    end

    test "rich output masks credential keys and secret-shaped values at every level" do
      Application.put_env(:insider, :environment, :development)
      assert {:ok, %{"session_id" => id}} = Live.start(@telemetry)

      capture_log(fn ->
        Logger.warning("calling provider with Authorization: #{@bearer}",
          provider: %{"client" => %{"api_key" => @stripe, "tokens" => [@jwt]}},
          password: @password
        )
      end)

      :telemetry.execute(@query, %{query_time: 1}, %{
        source: "users",
        query: "UPDATE users SET token = '#{@jwt}'",
        params: [@stripe, %{"nested" => [%{"secret" => @password}]}],
        conn: %{headers: [{"authorization", @bearer}], cookies: %{"_app" => "s"}}
      })

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      json = Live.JSON.events_since(id, 0, %{"limit" => 500})

      for output <- [inspect(batch, limit: :infinity, printable_limit: :infinity), json],
          secret <- @secrets do
        refute output =~ secret
      end

      refute json =~ "Bearer"

      log = find(batch, &(&1["source"] == "logger" and &1["payload"]["level"] == "warning"))

      assert log["payload"]["message"] ==
               "calling provider with Authorization: [REDACTED:authorization_header]"

      assert log["payload"]["metadata"]["password"] == "[REDACTED:credential_key]"

      assert log["payload"]["metadata"]["provider"] == %{
               "client" => %{
                 "api_key" => "[REDACTED:credential_key]",
                 "tokens" => "[REDACTED:credential_key]"
               }
             }

      query = find(batch, &(&1["kind"] == "insider_disclosure_test.query"))
      metadata = query["payload"]["metadata"]

      assert metadata["params"] == [
               "[REDACTED:provider_key]",
               %{"nested" => [%{"secret" => "[REDACTED:credential_key]"}]}
             ]

      assert metadata["conn"]["cookies"] == "[REDACTED:credential_key]"

      entry =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      masks = Enum.filter(entry["redactions"], &(&1["action"] == "mask"))

      assert %{"reason" => "provider_key", "count" => 1} =
               record(masks, ["key:payload", "key:metadata", "key:params", "index:0"])

      assert %{"reason" => "jwt"} = record(masks, ["key:payload", "key:metadata", "key:query"])
      assert metadata["query"] == "UPDATE users SET token = '[REDACTED:jwt]'"

      assert Enum.all?(masks, &(&1["policy_id"] == "insider-credential-masking/v1"))
      refute inspect(masks) =~ "synth"
    end

    test "strict output masks credential keys and secret-shaped values too" do
      Application.put_env(:insider, :environment, :ci)
      Application.put_env(:insider, :live_telemetry_measurements, [:count, :api_token])

      options =
        @telemetry
        |> Map.put("telemetry_measurements", ["count", "api_token"])
        |> Map.put("components", ["logger", "telemetry"])

      assert {:ok, %{"session_id" => id, "disclosure_profile" => "strict"}} = Live.start(options)
      :telemetry.execute(@query, %{count: 1, api_token: 99}, %{})

      supervisor = String.to_atom(@stripe)

      capture_log(fn ->
        :logger.error(
          %{
            label: {:supervisor, :child_terminated},
            report: [
              supervisor: {:local, supervisor},
              errorContext: :child_terminated,
              reason: :boom,
              offender: [pid: self(), id: String.to_atom(@bearer), restart_type: :temporary]
            ]
          },
          %{domain: [:otp, :sasl]}
        )
      end)

      assert {:ok, batch} = Live.events_since(id, 0, %{"limit" => 500})
      json = Live.JSON.events_since(id, 0, %{"limit" => 500})

      for output <- [inspect(batch, limit: :infinity, printable_limit: :infinity), json],
          secret <- [@stripe, "synthBearerToken"] do
        refute output =~ secret
      end

      query =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "insider_disclosure_test.query"))

      assert query["event"]["attributes"]["measurements"] == %{
               "count" => 1,
               "api_token" => "[REDACTED:credential_key]"
             }

      assert %{"reason" => "credential_key"} =
               record(query["redactions"], ["key:attributes", "key:measurements", "key:api_token"])

      terminated =
        Enum.find(batch["events"], &(&1["event"]["kind"] == "supervisor_child_terminated"))

      assert terminated["event"]["attributes"]["offender_id"] ==
               "atom:[REDACTED:authorization_header]"

      assert %{"reason" => "authorization_header"} =
               record(terminated["redactions"], ["key:attributes", "key:offender_id"])
    end

    test "collection-time omission evidence becomes drop records; malformed evidence is withheld" do
      omitted = %{
        "policy_id" => Disclosure.selection_policy_id(),
        "measurements" => 2,
        "measurement_names" => ["duration"],
        "metadata" => 1
      }

      event = fn value ->
        %{
          "source" => "telemetry",
          "causality" => %{},
          "attributes" => %{"measurements" => %{}, "metadata" => %{}, "omitted" => value},
          "payload" => nil
        }
      end

      for profile <- [:rich, :strict] do
        entry =
          Disclosure.project(%{"event" => event.(omitted), "redactions" => []}, %{}, profile)

        refute Map.has_key?(entry["event"]["attributes"], "omitted")

        assert entry["redactions"] == [
                 selection_drop(["key:attributes", "key:measurements", "key:duration"], 1),
                 selection_drop(["key:attributes", "key:measurements"], 1),
                 selection_drop(["key:attributes", "key:metadata"], 1)
               ]

        for malformed <- [
              %{omitted | "measurement_names" => ["a", "a"]},
              %{omitted | "measurements" => -1},
              Map.put(omitted, "extra", 1),
              "not evidence",
              nil
            ] do
          entry =
            Disclosure.project(%{"event" => event.(malformed), "redactions" => []}, %{}, profile)

          refute Map.has_key?(entry["event"]["attributes"], "omitted")

          assert [%{"path" => ["key:attributes", "key:omitted"], "policy_id" => policy_id}] =
                   entry["redactions"]

          assert policy_id == Disclosure.policy_id()
        end
      end
    end

    test "the boundary masks synthetic entries at every nesting level in both profiles" do
      event = %{
        "source" => "logger",
        "causality" => %{},
        "attributes" => %{
          "domain" => ["elixir"],
          "a" => %{"b" => %{"c" => [%{"d" => %{"private_key" => "x"}}, "#{@bearer}"]}}
        },
        "payload" => %{"message" => "token=#{@password}"}
      }

      for profile <- [:rich, :strict] do
        projected = Disclosure.project(%{"event" => event, "redactions" => []}, %{}, profile)
        attributes = projected["event"]["attributes"]

        assert attributes["a"]["b"]["c"] == [
                 %{"d" => %{"private_key" => "[REDACTED:credential_key]"}},
                 "[REDACTED:authorization_header]"
               ]

        refute Jason.encode!(projected) =~ "synth"

        assert %{"reason" => "credential_key"} =
                 record(projected["redactions"], [
                   "key:attributes",
                   "key:a",
                   "key:b",
                   "key:c",
                   "index:0",
                   "key:d",
                   "key:private_key"
                 ])
      end
    end
  end

  # Ends the Telemetry collector's summary interval now, as its timer would,
  # and waits until the collector has handled it.
  defp end_summary_window do
    session = :sys.get_state(Manager).active.pid
    pid = Map.fetch!(:sys.get_state(session).components, :telemetry)
    %{summaries: %{token: {_timer, token}}} = :sys.get_state(pid)
    send(pid, {:summary, token})
    _state = :sys.get_state(pid)
    :ok
  end

  defp find(batch, predicate) do
    batch["events"] |> Enum.map(& &1["event"]) |> Enum.find(predicate)
  end

  defp record(records, path), do: Enum.find(records, &(&1["path"] == path))

  defp selection_drop(path, count),
    do: %{
      "action" => "drop",
      "count" => count,
      "path" => path,
      "policy_id" => Disclosure.selection_policy_id()
    }

  # Collector cleanup finishes asynchronously in the Manager after a stop.
  # Wait only for that explicit state predicate, under a short bound; this
  # does not retry a failed operation.
  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("expected state was not reached")

  defp plain?({:ok, value}), do: plain?(value)
  defp plain?({:error, value}), do: plain?(value)

  defp plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and plain?(item) end)

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  defp plain?(value),
    do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)
end
