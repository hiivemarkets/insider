defmodule Insider.Live.DiscoveryTest do
  # Discovery reads every loaded module and the tests start the node's one
  # collector session and change the `:insider` application environment.
  use ExUnit.Case, async: false

  alias Insider.Collector.Session.Manager
  alias Insider.Live
  alias Insider.Live.Discovery

  defmodule Backend do
    @moduledoc false
    # A debug-info backend named by a fixture module: discovery must never
    # call it.
    def debug_info(_format, _module, _data, _options) do
      send(:insider_discovery_test, :backend_called)
      {:error, :unsupported}
    end
  end

  @shop """
  defmodule InsiderDiscoveryFixture.Shop do
    @lookup [:insider_disc_shop, :pricing, :lookup]
    def lookup(duration), do: :telemetry.execute(@lookup, %{duration: duration}, %{})
    def checkout(fun), do: :telemetry.span([:insider_disc_shop, :checkout], %{}, fun)
    def dynamic(prefix), do: :telemetry.execute(prefix ++ [:done], %{}, %{})
  end
  """

  @many """
  defmodule InsiderDiscoveryFixture.Many do
    for index <- 1..65 do
      def unquote(:"event_\#{index}")(),
        do: :telemetry.execute([:insider_disc_many, unquote(:"event_\#{index}")], %{}, %{})
    end
  end
  """

  @session_event [:insider_disc_session, :only]

  @erlang ~S"""
    -module(insider_disc_erl).
    -export([go/0]).
    go() -> telemetry:execute([insider_disc_erl, cache, miss], #{}, #{}).
  """
  @bare ~S"""
    -module(insider_disc_bare).
    -export([go/0]).
    go() -> telemetry:execute([insider_disc_bare, hidden], #{}, #{}).
  """
  @custom ~S"""
    -module(insider_disc_custom).
    -export([go/0]).
    go() -> telemetry:execute([insider_disc_custom, hidden], #{}, #{}).
  """
  @stale_v1 ~S"""
    -module(insider_disc_stale).
    -export([go/0]).
    go() -> telemetry:execute([insider_disc_stale, old], #{}, #{}).
  """
  @stale_v2 ~S"""
    -module(insider_disc_stale).
    -export([go/0]).
    go() -> telemetry:execute([insider_disc_stale, new], #{}, #{}).
  """

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "insider_discovery_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    # Test compilation omits debug info; these fixtures stand for a dev build.
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      for source <- [@shop, @many],
          {module, binary} <- Code.compile_string(source),
          do: load(directory, module, binary)
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end

    erlang(directory, @erlang, [:debug_info])
    erlang(directory, @bare, [])
    erlang(directory, @custom, [{:debug_info, {Backend, :data}}])
    erlang(directory, @stale_v1, [:debug_info])

    # The file now holds other code than the loaded module.
    {:ok, :insider_disc_stale, newer} = compile_erlang(directory, @stale_v2, [:debug_info])
    File.write!(Path.join(directory, "insider_disc_stale.beam"), newer)

    on_exit(fn -> File.rm_rf!(directory) end)
    :ok
  end

  setup do
    Process.register(self(), :insider_discovery_test)

    on_exit(fn ->
      Application.delete_env(:insider, :environment)
      :telemetry.detach("insider-discovery-test")
      :telemetry.detach("insider-discovery-test-unsupported")
      for index <- 1..9, do: :telemetry.detach("insider-discovery-test-#{index}")

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id)
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)

    :ok
  end

  describe "discover" do
    test "finds literal execute and span names in loaded modules, with their sources" do
      assert {:ok, result} = Live.discover(%{"prefix" => ["insider_disc_shop"]})
      assert result["schema"] == "insider.live-telemetry-discovery/v1"
      assert result["prefix"] == ["insider_disc_shop"]
      assert result["truncated"] == false and result["truncated_by"] == []

      shop = %{"source" => "execute", "module" => "InsiderDiscoveryFixture.Shop"}
      span = %{"source" => "span", "module" => "InsiderDiscoveryFixture.Shop"}

      assert result["events"] == [
               %{
                 "event" => "insider_disc_shop.checkout.exception",
                 "sources" => [span],
                 "sources_truncated" => false
               },
               %{
                 "event" => "insider_disc_shop.checkout.start",
                 "sources" => [span],
                 "sources_truncated" => false
               },
               %{
                 "event" => "insider_disc_shop.checkout.stop",
                 "sources" => [span],
                 "sources_truncated" => false
               },
               %{
                 "event" => "insider_disc_shop.pricing.lookup",
                 "sources" => [shop],
                 "sources_truncated" => false
               }
             ]

      assert result["events_total"] == 4
    end

    test "reads Erlang abstract code and reports what it could not read" do
      assert {:ok, %{"events" => events, "modules" => modules}} = Live.discover()
      names = Map.new(events, &{&1["event"], &1["sources"]})

      assert names["insider_disc_erl.cache.miss"] == [
               %{"source" => "execute", "module" => "insider_disc_erl"}
             ]

      # A name built at run time is not a literal list.
      refute Enum.any?(Map.keys(names), &String.ends_with?(&1, ".done"))
      # No debug info, an unknown backend, and a file newer than the loaded code.
      refute Map.has_key?(names, "insider_disc_bare.hidden")
      refute Map.has_key?(names, "insider_disc_custom.hidden")
      refute Map.has_key?(names, "insider_disc_stale.old")
      refute Map.has_key?(names, "insider_disc_stale.new")
      assert modules["without_debug_info"] >= 2
      assert modules["stale"] >= 1
      assert modules["calling_telemetry"] >= 6
      assert modules["scanned"] == modules["candidates"]
      assert modules["loaded"] > modules["candidates"]
    end

    test "never calls the debug-info backend a module names" do
      assert {:ok, _result} = Live.discover()
      refute_received :backend_called
    end

    test "lists handler event names but not Insider's own session handlers" do
      :ok =
        :telemetry.attach(
          "insider-discovery-test",
          [:insider_disc_dyn, :done],
          &__MODULE__.handle/4,
          nil
        )

      :ok =
        :telemetry.attach(
          "insider-discovery-test-unsupported",
          [:"Insider-Disc", :done],
          &__MODULE__.handle/4,
          nil
        )

      assert {:ok, _session} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [Enum.map(@session_event, &Atom.to_string/1)]
               })

      assert {:ok, %{"events" => events, "modules" => modules}} = Live.discover()
      names = Map.new(events, &{&1["event"], &1["sources"]})

      assert names["insider_disc_dyn.done"] == [
               %{"source" => "handler", "module" => "Insider.Live.DiscoveryTest"}
             ]

      refute Map.has_key?(names, "insider_disc_session.only")
      assert modules["unsupported_names"] >= 1
    end

    test "bounds concurrent scans, validates the prefix, and needs an allowed environment" do
      holders =
        for slot <- [Insider.Live.Discovery.Slot1, Insider.Live.Discovery.Slot2] do
          holder = spawn(fn -> receive(do: (:stop -> :ok)) end)
          Process.register(holder, slot)
          holder
        end

      assert {:error, %{"code" => "busy"}} = Live.discover()
      Enum.each(holders, &send(&1, :stop))

      for prefix <- [[], ["Shop"], ["a", "b", "c", "d", "e", "f", "g", "h"], "shop", [:shop]] do
        assert {:error, %{"code" => "invalid_options", "field" => "prefix"}} =
                 Live.discover(%{"prefix" => prefix})
      end

      assert {:error, %{"field" => "other"}} = Live.discover(%{"other" => 1})
      assert {:error, %{"field" => "options"}} = Live.discover([])

      Application.put_env(:insider, :environment, :staging)
      assert {:error, %{"code" => "environment_denied"}} = Live.discover()

      assert {:error, %{"code" => "environment_denied"}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [["insider_disc_shop", "*"]]
               })
    end

    test "the JSON twin returns the same result as canonical JSON" do
      assert %{"ok" => %{"events" => [%{"event" => "insider_disc_erl.cache.miss"}]}} =
               Jason.decode!(Live.JSON.discover(%{"prefix" => ["insider_disc_erl"]}))

      assert %{"error" => %{"code" => "invalid_options"}} =
               Jason.decode!(Live.JSON.discover(%{"prefix" => 1}))
    end

    test "a malformed prefix list is invalid_options, never a crash" do
      for prefix <- [["a" | "tail"], ["a", "b" | :tail]] do
        assert {:error, %{"code" => "invalid_options", "field" => "prefix"}} =
                 Live.discover(%{"prefix" => prefix})
      end
    end

    test "release layout: application modules beside OTP and Elixir are read" do
      # In a release, OTP, Elixir, and the application share one lib
      # directory under the release root; only the system applications' own
      # ebin directories and Insider's modules are left out.
      release = "/srv/shop_release"
      ebin = &"#{release}/lib/#{&1}/ebin"
      system = [ebin.("elixir-1.17.3"), ebin.("stdlib-6.2")]

      loaded = [
        {Shop.Checkout, ~c"#{ebin.("shop-0.1.0")}/Elixir.Shop.Checkout.beam"},
        {Shop.Pricing, ~c"#{ebin.("shop-0.1.0")}/../ebin/Elixir.Shop.Pricing.beam"},
        {Enum, ~c"#{ebin.("elixir-1.17.3")}/Elixir.Enum.beam"},
        {:lists, ~c"#{ebin.("stdlib-6.2")}/lists.beam"},
        {Insider.Live, ~c"#{ebin.("insider-0.1.0")}/Elixir.Insider.Live.beam"},
        {:erlang, :preloaded},
        {:from_binary, []}
      ]

      assert Insider.Live.Discovery.candidates(loaded, system) |> Enum.map(&elem(&1, 0)) ==
               [Shop.Checkout, Shop.Pricing]

      # On this node the defaults are the real system applications' ebins.
      system = Insider.Live.Discovery.system_ebins()
      assert Path.dirname(Path.expand(List.to_string(:code.which(Enum)))) in system
      assert Path.dirname(Path.expand(List.to_string(:code.which(:lists)))) in system
      refute Path.dirname(Path.expand(List.to_string(:code.which(:telemetry)))) in system
    end

    test "a source beyond the per-name bound is reported as truncated" do
      modules =
        for index <- 1..9 do
          module = Module.concat(InsiderDiscoveryFixture, "Handler#{index}")

          [{^module, _binary}] =
            Code.compile_string(
              "defmodule #{inspect(module)} do\n def handle(_, _, _, _), do: :ok\nend"
            )

          :ok =
            :telemetry.attach(
              "insider-discovery-test-#{index}",
              [:insider_disc_crowd, :done],
              Function.capture(module, :handle, 4),
              nil
            )

          module
        end

      assert {:ok, result} = Live.discover(%{"prefix" => ["insider_disc_crowd"]})
      assert [%{"sources" => sources, "sources_truncated" => true}] = result["events"]
      assert Enum.count(sources) == 8
      assert "sources" in result["truncated_by"]
      assert result["truncated"]

      Enum.each(modules, &:code.purge/1)
    end

    test "a module whose walk exhausts its node budget is reported, and prefixes are incomplete" do
      # Debug info whose definitions hold a list larger than the walk budget
      # before the call, so the call is never reached.
      call =
        {{:., [], [:telemetry, :execute]}, [],
         [[:insider_disc_walk, :hidden], {:%{}, [], []}, {:%{}, [], []}]}

      data = {:elixir_v1, %{definitions: [List.duplicate(0, 1_000_001), call]}, []}

      directory =
        Path.join(
          System.tmp_dir!(),
          "insider_discovery_walk_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      source = ~S"""
      -module(insider_disc_walk).
      -export([go/0]).
      go() -> telemetry:execute([insider_disc_walk, hidden], #{}, #{}).
      """

      erlang(directory, source, [{:debug_info, {:elixir_erl, data}}])

      try do
        assert {:ok, result} = Live.discover()
        refute Enum.any?(result["events"], &(&1["event"] == "insider_disc_walk.hidden"))
        assert "walk" in result["truncated_by"]
        assert result["modules"]["walk_truncated"] == 1

        assert {:ok, %{"telemetry_event_prefixes" => [%{"complete" => false}]}} =
                 Live.start(%{
                   "components" => ["telemetry"],
                   "telemetry_events" => [["insider_disc_shop", "*"]]
                 })
      after
        :code.purge(:insider_disc_walk)
        :code.delete(:insider_disc_walk)
        :code.purge(:insider_disc_walk)
      end
    end
  end

  describe "bounds that cut a module's evidence" do
    # The scan options are test-only and never reachable from a caller.
    defp attach_handler(event) do
      :ok = :telemetry.attach("insider-discovery-test", event, &__MODULE__.handle/4, nil)
    end

    defp prefix_start(prefix),
      do: %{"components" => ["telemetry"], "telemetry_events" => [prefix ++ ["*"]]}

    test "a reader killed by its heap guard is too_large and makes the result incomplete" do
      # A handler keeps the prefix matchable once the module's names are lost.
      attach_handler([:insider_disc_many, :event_1])
      options = [modules: [InsiderDiscoveryFixture.Many], reader_heap_words: 300]

      assert {:ok, result} = Discovery.discover(["insider_disc_many"], options)
      assert result["modules"]["scanned"] == 1
      assert result["modules"]["too_large"] == 1
      assert result["truncated_by"] == ["too_large"]
      assert result["truncated"]

      assert [%{"event" => "insider_disc_many.event_1", "sources" => [%{"source" => "handler"}]}] =
               result["events"]

      assert {:ok, _options, [%{"events" => ["insider_disc_many.event_1"], "complete" => false}]} =
               Discovery.expand_prefixes(prefix_start(["insider_disc_many"]), options)

      # The same module with the default guard is read in full.
      assert {:ok, %{"events_total" => 65, "truncated_by" => []}} =
               Discovery.discover(["insider_disc_many"], modules: [InsiderDiscoveryFixture.Many])
    end

    test "a reader that meets the deadline in the last module marks the scan deadline-cut" do
      attach_handler([:insider_disc_shop, :pricing, :lookup])

      options = [
        modules: [InsiderDiscoveryFixture.Shop],
        hold_readers: self(),
        deadline_ms: 200
      ]

      assert {:ok, result} = Discovery.discover(["insider_disc_shop"], options)
      assert_received {:insider_discovery_reader, _reader}
      assert result["modules"]["scanned"] == result["modules"]["candidates"]
      assert result["modules"]["candidates"] == 1
      assert result["truncated_by"] == ["deadline"]
      # Only the handler's name: the module's static names were not read.
      assert Enum.map(result["events"], & &1["event"]) == ["insider_disc_shop.pricing.lookup"]

      assert {:ok, _options, [%{"complete" => false}]} =
               Discovery.expand_prefixes(prefix_start(["insider_disc_shop"]), options)
    end

    test "a zero deadline reads no module and says so" do
      assert {:ok, result} = Discovery.discover(nil, deadline_ms: 0)
      assert result["modules"]["scanned"] == 0
      assert result["truncated_by"] == ["deadline"]
    end
  end

  describe "prefix subscription" do
    test "a prefix subscribes to every discovered name below it, and they are recorded" do
      assert {:ok, started} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [
                   ["insider_disc_shop", "pricing", "lookup"],
                   ["insider_disc_shop", "*"]
                 ],
                 "telemetry_min_duration_ms" => 0
               })

      expected = [
        "insider_disc_shop.pricing.lookup",
        "insider_disc_shop.checkout.exception",
        "insider_disc_shop.checkout.start",
        "insider_disc_shop.checkout.stop"
      ]

      assert Enum.map(started["telemetry_events"], &Enum.join(&1, ".")) == expected

      assert started["telemetry_event_prefixes"] == [
               %{
                 "prefix" => "insider_disc_shop.*",
                 "events" => expected |> tl() |> Kernel.++([hd(expected)]),
                 "complete" => true
               }
             ]

      apply(InsiderDiscoveryFixture.Shop, :lookup, [5])
      apply(InsiderDiscoveryFixture.Shop, :checkout, [fn -> {:ok, %{}} end])

      assert {:ok, %{"events" => events}} = Live.events_since(started["session_id"], 0)

      assert Enum.map(events, & &1["event"]["kind"]) == [
               "insider_disc_shop.pricing.lookup",
               "insider_disc_shop.checkout.start",
               "insider_disc_shop.checkout.stop"
             ]
    end

    test "an amendment expands a prefix as a start does, and an unmatched one changes nothing" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [["insider_disc_shop", "pricing", "lookup"]],
                 "telemetry_min_duration_ms" => 0
               })

      assert {:error, %{"code" => "unknown_telemetry_event", "discovered" => 0}} =
               Live.amend(id, %{"telemetry_events" => [["insider_disc_nothing", "*"]]})

      assert {:ok, %{"telemetry_events" => [["insider_disc_shop", "pricing", "lookup"]]}} =
               Live.status(id)

      assert {:ok, amended} =
               Live.amend(id, %{"telemetry_events" => [["insider_disc_shop", "*"]]})

      expected = [
        "insider_disc_shop.checkout.exception",
        "insider_disc_shop.checkout.start",
        "insider_disc_shop.checkout.stop",
        "insider_disc_shop.pricing.lookup"
      ]

      assert Enum.map(amended["telemetry_events"], &Enum.join(&1, ".")) == expected

      assert amended["telemetry_event_prefixes"] == [
               %{"prefix" => "insider_disc_shop.*", "events" => expected, "complete" => true}
             ]

      apply(InsiderDiscoveryFixture.Shop, :checkout, [fn -> {:ok, %{}} end])
      marker = amended["amendment"]["marker_receipt"]
      assert {:ok, %{"events" => events}} = Live.events_since(id, marker)

      assert Enum.map(events, & &1["event"]["kind"]) == [
               "insider_disc_shop.checkout.start",
               "insider_disc_shop.checkout.stop"
             ]
    end

    test "a start without a prefix echoes no expansion" do
      assert {:ok, %{"telemetry_event_prefixes" => []}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [["insider_disc_shop", "pricing", "lookup"]]
               })
    end

    test "an unmatched, malformed, or oversized prefix starts nothing" do
      telemetry = &%{"components" => ["telemetry"], "telemetry_events" => &1}

      assert {:error,
              %{
                "code" => "unknown_telemetry_event",
                "event" => ["insider_disc_nothing", "*"],
                "discovered" => 0,
                "complete" => true
              }} = Live.start(telemetry.([["insider_disc_nothing", "*"]]))

      for prefix <- [["*"], ["Shop", "*"], ["a", "b", "c", "d", "e", "f", "g", "h", "*"]] do
        assert {:error, %{"code" => "invalid_options", "field" => "telemetry_events"}} =
                 Live.start(telemetry.([prefix]))
      end

      assert {:error,
              %{
                "code" => "invalid_options",
                "field" => "telemetry_events",
                "expanded" => 65,
                "max" => 64
              }} = Live.start(telemetry.([["insider_disc_many", "*"]]))

      assert Live.capabilities()["active_session_id"] == nil
    end

    test "malformed or oversized event lists are invalid_options before any scan" do
      telemetry = &%{"components" => ["telemetry"], "telemetry_events" => &1}
      prefix = ["insider_disc_shop", "*"]

      for events <- [
            [["a" | "tail"]],
            [["insider_disc_shop" | "*"]],
            [prefix | "tail"],
            [prefix, ["a", "b" | :tail]],
            List.duplicate(prefix, 65)
          ] do
        assert {:error, %{"code" => "invalid_options", "field" => "telemetry_events"}} =
                 Live.start(telemetry.(events))
      end

      # Repeated prefixes are expanded once.
      assert {:ok, %{"telemetry_events" => events, "telemetry_event_prefixes" => [_one]}} =
               Live.start(telemetry.(List.duplicate(prefix, 64)))

      assert Enum.map(events, &Enum.join(&1, ".")) == [
               "insider_disc_shop.checkout.exception",
               "insider_disc_shop.checkout.start",
               "insider_disc_shop.checkout.stop",
               "insider_disc_shop.pricing.lookup"
             ]
    end
  end

  describe "status" do
    test "telemetry_subscriptions tells a silent subscribed event from a filtered or detached one" do
      assert {:ok, %{"session_id" => id}} =
               Live.start(%{
                 "components" => ["telemetry"],
                 "telemetry_events" => [["insider_disc_shop", "*"]]
               })

      # Below the default 100 ms minimum: filtered, but seen.
      apply(InsiderDiscoveryFixture.Shop, :lookup, [1])

      assert {:ok, %{"telemetry_subscriptions" => subscriptions}} = Live.status(id)

      assert Map.new(subscriptions, &{&1["event"], {&1["state"], &1["seen"]}}) == %{
               "insider_disc_shop.checkout.exception" => {"subscribed", 0},
               "insider_disc_shop.checkout.start" => {"subscribed", 0},
               "insider_disc_shop.checkout.stop" => {"subscribed", 0},
               "insider_disc_shop.pricing.lookup" => {"subscribed", 1}
             }

      assert {:ok, %{"events" => [], "filtered" => filtered}} = Live.events_since(id, 0)
      assert filtered["telemetry"]["insider_disc_shop.pricing.lookup"]["min_duration"] == 1

      [%{id: handler_id}] =
        for handler <- :telemetry.list_handlers([:insider_disc_shop, :pricing, :lookup]),
            handler.function == (&Insider.Collector.Telemetry.Handler.handle_event/4),
            do: handler

      :ok = :telemetry.detach(handler_id)

      assert {:ok, %{"telemetry_subscriptions" => subscriptions}} = Live.status(id)
      assert Enum.all?(subscriptions, &(&1["state"] == "detached"))
    end
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok

  defp load(directory, module, binary) do
    path = Path.join(directory, Atom.to_string(module) <> ".beam")
    File.write!(path, binary)
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), binary)
  end

  defp erlang(directory, source, options) do
    {:ok, module, binary} = compile_erlang(directory, source, options)
    load(directory, module, binary)
  end

  defp compile_erlang(directory, source, options) do
    path = Path.join(directory, "source_#{System.unique_integer([:positive])}.erl")
    File.write!(path, source)
    :compile.file(String.to_charlist(path), [:binary, :return_errors | options])
  end

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
end
