defmodule Insider.Collector.Poller.PortCensusTest do
  # The census counts every port on the node, so tests that open ports run
  # one at a time.
  use ExUnit.Case, async: false

  alias Insider.Collector.Poller.Config
  alias Insider.Collector.Poller.Ports
  alias Insider.Live
  alias Insider.Recorder

  defp options(extra) do
    Map.merge(
      %{top: 5, protected: %{}, insider: [], master: nil, budget_bytes: 3_500},
      extra
    )
  end

  # Each fixture program is a shell script under a unique name that echoes
  # its input with shell builtins only. A link to the system's `cat` is not
  # used: `cat` can itself be a link to a multi-call binary that selects the
  # tool by its own name (Ubuntu 26.04's Rust coreutils), and then a renamed
  # link does not run as `cat`.
  @echo_script """
  #!/bin/sh
  while IFS= read -r line; do printf '%s\\n' "$line"; done
  """

  # Ports of a type no other test opens: a program under a unique name, so
  # a type's count and delta are this test's alone while async tests
  # elsewhere open and close their own ports. Each port echoes one line
  # before it is handed to `owner`, so its program is running when the
  # census reads it.
  defp open_cats(owner, count, type) do
    ports =
      for _ <- 1..count do
        port = Port.open({:spawn_executable, executable(type)}, [:binary])
        true = Port.command(port, "ready\n")
        assert_receive {^port, {:data, "ready\n"}}, 5_000
        true = Port.connect(port, owner)
        port
      end

    on_exit(fn -> Enum.each(ports, &close/1) end)
    ports
  end

  defp executable(type) do
    path = Path.join(System.tmp_dir!(), type)

    unless File.exists?(path) do
      File.write!(path, @echo_script)
      File.chmod!(path, 0o755)
      on_exit(fn -> File.rm(path) end)
    end

    path
  end

  defp unique_type, do: "census_cat_#{System.unique_integer([:positive])}"

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Each holder has its own name and is gone before the next test starts.
  defp holder do
    name =
      :"Elixir.Insider.Collector.Poller.PortCensusTest.Shipping#{System.unique_integer([:positive])}"

    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    Process.register(pid, name)

    on_exit(fn ->
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5000
    end)

    {pid, name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")}
  end

  test "types a port by the first word of its name without a directory" do
    assert Ports.type(~c"cat") == "cat"
    assert Ports.type("/bin/cat -u secret") == "cat"
    assert Ports.type(~c"tcp_inet") == "tcp_inet"
    assert Ports.type("sh!x -c run") == "other"
    assert Ports.type([0xD800]) == "other"
    assert Ports.type(:atom) == "other"
  end

  # A type was the basename of the text
  # before the first space, so a tab-separated credential argument became
  # the port's type.
  test "a type is the program's basename only, and other whenever the program is in doubt" do
    assert Ports.type("sh\t-c\tcat\t--password=/review_type_secret") == "sh"
    assert Ports.type("/bin/cat\n--token=/x") == "cat"
    assert Ports.type("\t/bin/cat") == "other"

    for doubtful <- [
          "--password=/review_type_secret",
          "/opt/x/--api-key=/review_secret",
          "a\\b/cat",
          "$HOME/cat",
          "`x`/cat",
          "sh\\\n-c",
          "/opt/token_store/cat"
        ],
        do: assert(Ports.type(doubtful) == "other", inspect(doubtful))
  end

  test "a tab-separated credential argument reaches no census field" do
    {owner, _name} = holder()
    port = Port.open({:spawn, "sh\t-c\tcat\t--password=/review_type_secret"}, [:binary])
    true = Port.command(port, "ready\n")
    assert_receive {^port, {:data, "ready\n"}}, 5_000
    true = Port.connect(port, owner)
    on_exit(fn -> close(port) end)

    assert {:ok, _status, metrics, _unavailable, snapshot} =
             Ports.top(nil, options(%{top: 10}))

    refute metrics |> Jason.encode!() |> String.contains?("review_type_secret")
    refute snapshot |> inspect() |> String.contains?("review_type_secret")

    assert %{"top_type" => "sh"} =
             Enum.find(metrics["by_owner"], &(&1["owner_pid"] == inspect_pid(owner)))
  end

  test "counts by type with growth, names the top owner, and keeps Insider's ports apart" do
    {owner, name} = holder()
    type = unique_type()
    open_cats(owner, 2, type)

    assert {:ok, :partial, first, ["port_count_delta"], snapshot} =
             Ports.top(nil, options(%{top: 10}))

    assert first["port_count_delta"] == nil and first["window_ms"] == nil

    assert %{"count" => 2, "delta" => nil} =
             Enum.find(first["by_type"], &(&1["type"] == type))

    open_cats(owner, 3, type)

    assert {:ok, :complete, second, [], _snapshot} = Ports.top(snapshot, options(%{top: 10}))
    assert is_integer(second["port_count_delta"]) and is_integer(second["window_ms"])

    assert %{"count" => 5, "delta" => 3, "os_process_count" => 5} =
             Enum.find(second["by_type"], &(&1["type"] == type))

    assert %{"count" => 5, "top_type" => ^type} =
             Enum.find(second["by_owner"], &(&1["owner"] == name))

    # The same ports owned by an Insider process are counted apart.
    assert {:ok, _status, apart, _unavailable, _snapshot} =
             Ports.top(snapshot, options(%{insider: [owner], top: 10}))

    assert apart["insider"]["port_count"] == 5
    refute Enum.any?(apart["by_type"], &(&1["type"] == type))
    refute Enum.any?(apart["by_owner"], &(&1["owner_pid"] == inspect_pid(owner)))
  end

  test "a protected owner is named from the inventory and a cut census says so" do
    {owner, _name} = holder()
    open_cats(owner, 1, unique_type())

    assert {:ok, _status, metrics, _unavailable, _snapshot} =
             Ports.top(nil, options(%{protected: %{owner => :protected_holder}}))

    assert Enum.any?(metrics["by_owner"], &(&1["owner"] == "protected_holder"))

    assert {:ok, :partial, cut, unavailable, _snapshot} = Ports.top(nil, options(%{max_scan: 1}))
    assert "scan_limit" in unavailable
    assert cut["scanned"] <= 1
  end

  test "rankings are cut to the event budget and count what was omitted" do
    {owner, _name} = holder()
    open_cats(owner, 1, unique_type())

    assert {:ok, :partial, metrics, unavailable, _} =
             Ports.top(nil, options(%{budget_bytes: 200}))

    assert metrics["omitted"] > 0
    assert "event_bytes" in unavailable
  end

  test "the Poller records port_top only with top_ports, and Live sessions turn it on by default" do
    {:ok, recorder} =
      Recorder.start_link(
        classification: Insider.TestRecorderClassification.binding(),
        max_events: 8
      )

    {:ok, handle} = Recorder.handle(recorder)
    base = [authority: "test", boot_id: "boot", clock_id: "clock"]

    assert {:ok, %Config{top_ports: 0}} = Config.new(handle, base)
    assert {:error, :invalid_options} = Config.new(handle, base ++ [top_ports: 11])

    assert {:ok, %Config{top_ports: 10}} = Config.new(handle, base ++ [top_ports: 10])

    {owner, _name} = holder()
    open_cats(owner, 2, unique_type())

    assert {:ok, %{"session_id" => id, "poller" => %{"top_ports" => 5}}} =
             Live.start(%{"components" => ["poller"], "poller_interval_ms" => 1_000})

    on_exit(fn -> Live.stop(id, %{"force" => true}) end)
    assert {:ok, _subscription} = Live.subscribe(id, self())
    [first, second] = port_tops(id, [])
    assert second["attributes"]["field_set"] == "otp_port_top/v1"
    assert second["attributes"]["metrics"]["window_ms"] >= 900
    assert first["attributes"]["metrics"]["port_count_delta"] == nil
    assert is_integer(second["attributes"]["metrics"]["port_count_delta"])

    assert {:error, %{"code" => "invalid_options", "field" => "top_ports"}} =
             Live.amend(id, %{"top_ports" => 11})
  end

  defp port_tops(_id, [first, second | _rest]), do: [first, second]

  defp port_tops(id, found) do
    assert_receive {:insider_live_events, ^id, batch}, 10_000

    found =
      found ++
        for %{"event" => %{"kind" => "port_top"} = event} <- batch["events"], do: event

    port_tops(id, found)
  end

  defp inspect_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
end
