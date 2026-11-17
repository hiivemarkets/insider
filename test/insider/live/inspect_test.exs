defmodule Insider.Live.InspectTest do
  # The inspections read the node's one live owner and record into its one
  # session, so these tests run one at a time.
  use ExUnit.Case, async: false

  alias Insider.Event.Canonical
  alias Insider.Live
  alias Insider.Live.Inspect
  alias Insider.Live.Inspect.BinLeak
  alias Insider.Live.Inspect.Process, as: ProcessInspect
  alias Insider.Policy.ProtectedTargets

  defmodule Server do
    use GenServer

    @impl true
    def init(test), do: {:ok, %{test: test, held: []}}

    @impl true
    def handle_call({:block, test}, _from, state) do
      send(test, {:blocked, self()})

      receive do
        :release -> {:reply, :ok, state}
      end
    end

    def handle_call(:hold, _from, state) do
      large = :crypto.strong_rand_bytes(65_536)
      slice = binary_part(large, 0, 512)
      {:reply, :ok, %{state | held: [slice | state.held]}}
    end

    def handle_call(:garbage, _from, state) do
      _large = :crypto.strong_rand_bytes(262_144)
      {:reply, :ok, state}
    end
  end

  setup do
    on_exit(fn ->
      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      Application.delete_env(:insider, :live_disclosure)
    end)

    :ok
  end

  defp blocked_server(name \\ nil) do
    options = if name, do: [name: name], else: []
    {:ok, server} = GenServer.start(Server, self(), options)
    on_exit(fn -> Process.exit(server, :kill) end)
    test = self()
    caller = spawn(fn -> GenServer.call(server, {:block, test}, :infinity) end)
    assert_receive {:blocked, ^server}
    {server, caller}
  end

  defp pid_text(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  describe "process" do
    test "summarises a backed-up server's mailbox by shape and counts calls from exited callers" do
      {server, _caller} = blocked_server(__MODULE__.Pricing)

      # Callers that time out and exit leave their calls queued behind the
      # blocked one.
      for item <- ["apple", "pear"] do
        {caller, ref} =
          spawn_monitor(fn -> catch_exit(GenServer.call(server, {:price, item}, 1)) end)

        assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      end

      send(server, {:queued, 1})

      assert {:ok, result} =
               Live.process(%{"name" => "Insider.Live.InspectTest.Pricing", "messages" => 2})

      assert result["schema"] == "insider.live-process/v1"
      assert result["name"] == "Insider.Live.InspectTest.Pricing"
      assert result["pid"] == pid_text(server)
      assert result["insider"] == false
      assert result["session"] == nil
      assert result["info"]["message_queue_len"] == 3
      assert result["info"]["initial_call"] == "Insider.Live.InspectTest.Server.init/1"
      assert result["info"]["links"] == %{"processes" => 0, "ports" => 0}

      mailbox = result["mailbox"]
      assert mailbox["read"] == true and mailbox["length"] == 3

      assert Enum.sort_by(mailbox["shapes"], & &1["shape"]) == [
               %{
                 "shape" => "{:\"$gen_call\", {pid, list}, {:price, binary}}",
                 "size_class" => "under_1kib",
                 "count" => 2
               },
               %{"shape" => "{:queued, integer}", "size_class" => "under_64b", "count" => 1}
             ]

      assert [%{"shape" => _first}, %{"shape" => _second}] = mailbox["first"]
      assert mailbox["calls"] == %{"count" => 2, "callers_alive" => 0, "callers_exited" => 2}

      # No message value leaves the node.
      refute Jason.encode!(result) =~ "apple"

      [top | _rest] = result["stacktrace"]["frames"]
      assert top["function"] == "Insider.Live.InspectTest.Server.handle_call/3"
      assert top["file"] =~ "inspect_test.exs"
      assert is_integer(top["line"])
    end

    # The shape bound counted graphemes, not bytes.
    test "a shape of multibyte tags stays within 160 bytes in shapes and first" do
      tag = String.to_atom(String.duplicate("漢", 60))
      message = {tag, {tag, tag}, {tag, tag}}
      {server, _caller} = blocked_server()
      send(server, message)

      assert {:ok, result} = Live.process(%{"pid" => pid_text(server), "messages" => 1})
      assert [%{"shape" => first}] = result["mailbox"]["first"]
      assert [%{"shape" => shape}] = result["mailbox"]["shapes"]

      for text <- [first, shape, ProcessInspect.shape(message)] do
        assert byte_size(text) <= 160 and String.valid?(text)
        assert String.ends_with?(text, "...")
      end
    end

    test "a shape shows an atom only as a tuple's tag, in every profile" do
      assert ProcessInspect.shape({:price, :apple, "x"}) == "{:price, atom, binary}"
      assert ProcessInspect.shape(:bare) == "atom"
      assert ProcessInspect.shape({:password, :review_plain_credential}) == "{:password, atom}"
      assert ProcessInspect.shape({1, 2, 3, 4, 5, 6, 7}) =~ ", ..}"
      assert ProcessInspect.shape({{{:deep}}}) == "{{tuple}}"
      assert ProcessInspect.shape(%URI{}) == "%URI{}"

      for {term, shape} <- [
            {[], "[]"},
            {[1], "list"},
            {%{}, "map"},
            {<<1::3>>, "bitstring"},
            {1.5, "float"},
            {self(), "pid"},
            {make_ref(), "reference"},
            {fn -> :ok end, "fun"}
          ],
          do: assert(ProcessInspect.shape(term) == shape)

      for {term, class} <- [
            {:a, "under_64b"},
            {String.duplicate("a", 500), "under_1kib"},
            {String.duplicate("a", 5_000), "under_64kib"},
            {String.duplicate("a", 70_000), "64kib_or_more"}
          ],
          do: assert(ProcessInspect.size_class(term) == class)
    end

    # An atom value, such as a credential in
    # `{:password, atom}`, left the node in rich shapes and stayed in the
    # session history after the host narrowed to strict.
    test "an atom value never leaves in a result or in history, rich or strict, live or archived" do
      {server, _caller} = blocked_server()
      send(server, {:password, :review_plain_credential})
      send(server, {:tag, :review_non_tag_atom})
      send(server, :review_bare_atom)

      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      assert {:ok, result} = Live.process(%{"pid" => pid_text(server), "messages" => 3})
      assert result["disclosure_profile"] == "rich"
      assert result["session"]["recorded"] == true

      shapes = Enum.map(result["mailbox"]["first"], & &1["shape"])
      assert shapes == ["{:password, atom}", "{:tag, atom}", "atom"]

      # The inspection event is archived by an amendment, then the host
      # narrows to strict.
      assert {:ok, _amended} = Live.amend(id, %{"logger_level" => "error"})
      Application.put_env(:insider, :live_disclosure, :strict)

      assert {:ok, batch} = Live.events_since(id, 0, %{"view" => %{"sources" => ["inspect"]}})
      assert batch["disclosure_profile"] == "strict"

      # Views never hide the amendment marker; the inspection is the other.
      assert [%{"event" => %{"attributes" => attributes}}] =
               Enum.filter(batch["events"], &(&1["event"]["kind"] == "inspect.process"))

      assert attributes["mailbox_shapes"] |> Enum.map(& &1["shape"]) |> Enum.sort() ==
               ["atom", "{:password, atom}", "{:tag, atom}"]

      for text <- [Jason.encode!(result), Jason.encode!(batch)],
          value <- ["review_plain_credential", "review_non_tag_atom", "review_bare_atom"],
          do: refute(text =~ value)
    end

    test "a queue over the read bound is reported by length alone" do
      {server, _caller} = blocked_server()
      Enum.each(1..(ProcessInspect.mailbox_read_max() + 1), &send(server, &1))

      assert {:ok, %{"mailbox" => mailbox}} = Live.process(%{"pid" => pid_text(server)})
      assert mailbox["read"] == false
      assert mailbox["reason"] == "queue_over_read_max"
      assert mailbox["shapes"] == []
    end

    test "past the shape bound every further shape is counted as one other row" do
      {server, _caller} = blocked_server()
      # 300 distinct tags: 255 shapes are kept and 45 fold into "other".
      Enum.each(1..300, &send(server, {String.to_atom("inspect_test_shape_#{&1}")}))

      assert {:ok, %{"mailbox" => mailbox}} = Live.process(%{"pid" => pid_text(server)})
      assert mailbox["sampled"] == 300
      assert mailbox["distinct_shapes"] == 256

      assert [%{"shape" => "other", "size_class" => "mixed", "count" => 45} | rest] =
               mailbox["shapes"]

      assert Enum.map(rest, & &1["count"]) == List.duplicate(1, 19)
    end

    test "the binaries a process refers to are counted with their full size" do
      {:ok, holder} = GenServer.start(Server, self())
      on_exit(fn -> Process.exit(holder, :kill) end)

      assert {:ok, %{"binaries" => before}} = Live.process(%{"pid" => pid_text(holder)})
      Enum.each(1..3, fn _ -> GenServer.call(holder, :hold) end)
      assert {:ok, %{"binaries" => held}} = Live.process(%{"pid" => pid_text(holder)})

      # Each 512-byte slice keeps its 64 KiB binary alive.
      assert held["count"] >= before["count"] + 3
      assert held["bytes"] >= before["bytes"] + 3 * 65_536
    end

    test "a port in a message shows as port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> safe_close(port) end)
      assert ProcessInspect.shape({:owner, port}) == "{:owner, port}"
      assert ProcessInspect.shape(port) == "port"
    end

    test "names and pids that reach no process, protected processes, and malformed options are refused" do
      unknown = "No.Such.Inspected#{System.unique_integer([:positive])}"
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      for {options, expected} <- [
            {%{"name" => unknown}, %{"code" => "unknown_process_name", "name" => unknown}},
            {%{"name" => "Insider.Live.InspectTest"}, %{"code" => "process_not_found"}},
            {%{"pid" => pid_text(dead)}, %{"code" => "process_not_found"}},
            {%{"name" => "code_server"}, %{"code" => "protected_process"}},
            {%{}, %{"code" => "invalid_options", "field" => "name"}},
            {%{"name" => "a", "pid" => "<0.1.0>"},
             %{"code" => "invalid_options", "field" => "pid"}},
            {%{"pid" => "<1.2.3>"}, %{"code" => "invalid_options", "field" => "pid"}},
            {%{"name" => "not a name"}, %{"code" => "invalid_options", "field" => "name"}},
            {%{"name" => "code_server", "frames" => 0},
             %{"code" => "invalid_options", "field" => "frames"}},
            {%{"name" => "code_server", "other" => 1},
             %{"code" => "invalid_options", "field" => "other"}}
          ] do
        assert {:error, error} = Live.process(options)
        assert Map.take(error, Map.keys(expected)) == expected, inspect(options)
      end

      assert {:error, %{"field" => "options"}} = Live.process([])
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> unknown) end
    end
  end

  describe "bin_leak" do
    test "names the process that keeps sub-binaries after a collection apart from one that frees garbage" do
      {:ok, holder} = GenServer.start(Server, self(), name: __MODULE__.ImageCache)
      on_exit(fn -> Process.exit(holder, :kill) end)
      Enum.each(1..20, fn _ -> GenServer.call(holder, :hold) end)

      assert {:ok, result} = Live.bin_leak(%{"top" => 3})
      assert result["schema"] == "insider.live-bin-leak/v1"
      assert result["implementation"] == "native"
      assert result["observer_effect"] == "garbage_collected_every_scanned_process"
      assert result["gc_pending"] == 0 and result["collected"] > 0
      assert result["skipped_protected"] > 0

      [first | _rest] = result["by_retained_bytes"]
      assert first["name"] == "Insider.Live.InspectTest.ImageCache"
      assert first["binary_count_after"] == 20
      assert first["binary_bytes_after"] == 20 * 65_536
      assert first["freed_bytes"] == 0
      assert is_integer(result["insider"]["process_count"])
    end

    # The holder was ranked first in
    # by_retained_bytes, but canonical JSON sorts keys, so by_freed_bytes
    # (garbage, here the Logger file handler) printed first and an agent
    # reading the head of the document concluded bin_leak did not name it.
    test "the biggest holder comes first in the document, named, ahead of the garbage list" do
      {:ok, holder} = GenServer.start(Server, self(), name: __MODULE__.ImageCache)
      on_exit(fn -> Process.exit(holder, :kill) end)
      Enum.each(1..20, fn _ -> GenServer.call(holder, :hold) end)
      {:ok, litter} = GenServer.start(Server, self())
      on_exit(fn -> Process.exit(litter, :kill) end)
      GenServer.call(litter, :garbage)

      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      assert {:ok, result} = Live.bin_leak(%{"top" => 5})

      assert %{
               "name" => "Insider.Live.InspectTest.ImageCache",
               "pid" => pid,
               "binary_bytes_after" => bytes,
               "binary_count_after" => 20,
               "freed_bytes" => 0
             } = result["biggest_holder"]

      assert pid == pid_text(holder) and bytes == 20 * 65_536
      assert Enum.any?(result["by_freed_bytes"], &(&1["pid"] == pid_text(litter)))

      # In the exported document the holder comes before any ranking, so
      # an agent that reads only the head of it sees the holder's name.
      json = Canonical.encode(result)
      {holder_at, _} = :binary.match(json, ~s("biggest_holder"))
      {freed_at, _} = :binary.match(json, ~s("by_freed_bytes"))
      {retained_at, _} = :binary.match(json, ~s("by_retained_bytes"))
      assert holder_at < freed_at and holder_at < retained_at
      assert binary_part(json, 0, 600) =~ "Insider.Live.InspectTest.ImageCache"

      # The session's inspect.bin_leak event names it too.
      assert {:ok, batch} = Live.events_since(id, 0, %{"view" => %{"sources" => ["inspect"]}})
      assert [%{"event" => %{"attributes" => attributes}}] = batch["events"]
      assert attributes["biggest_holder"]["name"] == "Insider.Live.InspectTest.ImageCache"
    end

    test "human text names the biggest holder first and separates garbage" do
      {:ok, holder} = GenServer.start(Server, self(), name: __MODULE__.ImageCache)
      on_exit(fn -> Process.exit(holder, :kill) end)
      Enum.each(1..20, fn _ -> GenServer.call(holder, :hold) end)

      assert {:ok, %{"text" => text} = result} = Live.bin_leak(%{"top" => 3, "human" => true})
      [first, second | _rest] = String.split(text, "\n")
      assert first =~ "bin_leak"
      assert second =~ "Insider.Live.InspectTest.ImageCache"
      assert second =~ "1.3 MiB" and second =~ "20 binaries" and second =~ "0 B freed"
      assert text =~ "Freed by the collection"
      refute Map.has_key?(elem(Live.bin_leak(%{"top" => 3}), 1), "text")
      assert result["biggest_holder"]["name"] == "Insider.Live.InspectTest.ImageCache"

      assert {:error, %{"code" => "invalid_options", "field" => "human"}} =
               Live.bin_leak(%{"human" => "yes"})
    end

    test "biggest_holder is nil when no inspected process holds binaries" do
      assert BinLeak.biggest_holder([]) == nil

      text = BinLeak.text(complete_scan(%{"scanned" => 3}))
      assert text =~ "No inspected process holds binaries"
      assert text =~ "Evidence complete: 3 processes scanned"
      refute text =~ "application process"
    end

    # The text claimed absence while
    # the scan had read no application process.
    test "human text reports a cut scan, pending collections and protected processes, and never claims absence then" do
      {:ok, holder} = GenServer.start(Server, self())
      on_exit(fn -> Process.exit(holder, :kill) end)
      GenServer.call(holder, :hold)
      {:ok, protection} = ProtectedTargets.new()

      assert {:ok, cut} =
               Inspect.run("bin_leak", %{top: 5, human: true}, :rich, protection, max_scan: 1)

      assert cut["truncated_by"] == ["scan_limit"]
      assert cut["text"] =~ "Evidence incomplete"
      assert cut["text"] =~ "scan limit"
      refute cut["text"] =~ "No inspected process holds binaries."
      refute cut["text"] =~ "nothing"

      pending =
        BinLeak.text(
          complete_scan(%{
            "scanned" => 9,
            "gc_pending" => 4,
            "skipped_protected" => 2,
            "truncated_by" => ["deadline"]
          })
        )

      assert pending =~ "Evidence incomplete"
      assert pending =~ "4 collections did not finish"
      assert pending =~ "2 protected processes not read"
      assert pending =~ "None found among the processes read"
      refute pending =~ "No inspected process holds binaries."
    end

    # Export masking expanded the text
    # after it was measured, so names that redact to longer markers pushed
    # it past its bound.
    test "human text whose names redact to longer markers stays within its bound after export" do
      holders =
        for index <- 1..50 do
          # Each short `password=a` becomes a much longer marker.
          name = :"#{String.duplicate("password=a ", 11)}#{index}"
          {:ok, pid} = GenServer.start(Server, self(), name: name)
          if index == 1, do: Enum.each(1..10, fn _ -> GenServer.call(pid, :hold) end)
          GenServer.call(pid, :hold)
          GenServer.call(pid, :garbage)
          pid
        end

      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)

      assert {:ok, result} = Live.bin_leak(%{"top" => 50, "human" => true})
      text = result["text"]
      assert byte_size(text) <= BinLeak.text_bytes_max()
      assert byte_size(Canonical.encode(result)) <= Inspect.bounds()["result_bytes_max"]
      assert text =~ "[REDACTED:"
      refute text =~ "password=a "

      lines = String.split(text, "\n", trim: true)
      assert Enum.at(lines, 1) =~ pid_text(hd(holders))
      assert Enum.any?(lines, &String.starts_with?(&1, "Evidence "))
      assert Enum.any?(lines, &(&1 =~ "more lines not shown"))
    end

    # The text could not shrink, so a
    # human request with long names exceeded the result bound.
    test "human text is bounded, keeps the biggest holder, and fits the result bound with the rankings" do
      holders =
        for index <- 1..50 do
          name = :"#{String.duplicate("漢", 80)}#{index}"
          {:ok, pid} = GenServer.start(Server, self(), name: name)
          if index == 1, do: Enum.each(1..10, fn _ -> GenServer.call(pid, :hold) end)
          GenServer.call(pid, :hold)
          GenServer.call(pid, :garbage)
          pid
        end

      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)

      for options <- [%{"top" => 50}, %{"top" => 50, "human" => true}] do
        assert {:ok, result} = Live.bin_leak(options)
        assert byte_size(Canonical.encode(result)) <= Inspect.bounds()["result_bytes_max"]
        assert result["biggest_holder"]["pid"] == pid_text(hd(holders))
      end

      assert {:ok, %{"text" => text}} = Live.bin_leak(%{"top" => 50, "human" => true})
      assert byte_size(text) <= BinLeak.text_bytes_max()
      assert text |> String.split("\n") |> Enum.at(1) =~ pid_text(hd(holders))
      assert text =~ ~r/more (holders|lines) not shown/
    end

    defp complete_scan(fields) do
      Map.merge(
        %{
          "biggest_holder" => nil,
          "by_retained_bytes" => [],
          "by_freed_bytes" => [],
          "gc_pending" => 0,
          "skipped_protected" => 0,
          "truncated_by" => [],
          "vm_binary_bytes_before" => 10,
          "vm_binary_bytes_after" => 10
        },
        fields
      )
    end

    test "out-of-range options are refused" do
      assert {:error, %{"code" => "invalid_options", "field" => "top"}} =
               Live.bin_leak(%{"top" => 51})

      assert {:error, %{"field" => "options"}} = Live.bin_leak(:nope)
    end
  end

  describe "ports" do
    test "counts by type, filters by type and owner, and gives the full name only in rich" do
      owner = spawn_link(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(owner, :stop) end)
      ports = for _ <- 1..3, do: Port.open({:spawn, "cat"}, [:binary])
      Enum.each(ports, &Port.connect(&1, owner))
      on_exit(fn -> Enum.each(ports, &safe_close/1) end)

      context = %{owner: pid_text(owner)}

      assert {:ok, result} = Live.ports(%{"type" => "cat", "owner" => context.owner})
      assert result["schema"] == "insider.live-ports/v1"
      assert result["implementation"] == "native"
      assert result["matched"] == 3 and result["matched_os_process_count"] == 3
      assert [%{"owner_pid" => owner_pid, "count" => 3}] = result["owners"]
      assert owner_pid == context.owner
      assert Enum.all?(result["ports"], &(&1["type"] == "cat" and &1["name"] == "cat"))
      assert Enum.all?(result["ports"], &is_integer(&1["os_pid"]))

      assert %{"type" => "cat", "count" => count} =
               Enum.find(result["types"], &(&1["type"] == "cat"))

      assert count >= 3

      assert {:ok, %{"matched" => 0}} = Live.ports(%{"type" => "no_such_type"})

      Application.put_env(:insider, :live_disclosure, :strict)
      assert {:ok, strict} = Live.ports(%{"type" => "cat", "top" => 1})
      assert [row] = strict["ports"]
      refute Map.has_key?(row, "name")
    end

    # The derived type exported a
    # tab-separated credential argument in rich, strict, and history.
    test "a tab-separated credential argument reaches no ports field, rich or strict, nor history" do
      port = Port.open({:spawn, "sh\t-c\tcat\t--password=/review_type_secret"}, [:binary])
      on_exit(fn -> safe_close(port) end)
      true = Port.command(port, "ready\n")
      assert_receive {^port, {:data, "ready\n"}}, 5_000
      port_text = port |> :erlang.port_to_list() |> List.to_string()
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

      assert {:ok, rich} = Live.ports(%{"top" => 200})
      assert %{"type" => "sh"} = Enum.find(rich["ports"], &(&1["port"] == port_text))

      Application.put_env(:insider, :live_disclosure, :strict)
      assert {:ok, strict} = Live.ports(%{"type" => "sh", "top" => 200})
      assert strict["disclosure_profile"] == "strict"
      assert %{"type" => "sh"} = Enum.find(strict["ports"], &(&1["port"] == port_text))

      assert {:ok, history} =
               Live.events_since(id, 0, %{"view" => %{"sources" => ["inspect"]}})

      assert [_rich, _strict] = history["events"]

      for document <- [rich, strict, history] do
        decoded = document |> Jason.encode!() |> Jason.decode!() |> Jason.encode!()
        refute decoded =~ "review_type_secret"
      end
    end

    # Recon:port_types read every port, past the
    # scan bound.
    test "every count comes from the one capped read of ports" do
      ports = for _ <- 1..3, do: Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> Enum.each(ports, &safe_close/1) end)
      {:ok, protection} = ProtectedTargets.new()

      assert {:ok, result} =
               Inspect.run("ports", %{type: nil, owner: nil, top: 20}, :rich, protection,
                 recon: true,
                 max_scan: 2
               )

      assert result["implementation"] == "native"
      assert result["scanned"] <= 2 and result["port_count"] >= 3
      assert result["truncated_by"] == ["scan_limit"]
      assert result["types"] |> Enum.map(& &1["count"]) |> Enum.sum() <= 2
    end

    # Top did not bound the type list.
    test "top bounds the type list as well as the ports and owners" do
      cat = Port.open({:spawn, "cat"}, [:binary])
      {:ok, socket} = :gen_udp.open(0)
      on_exit(fn -> safe_close(cat) end)
      on_exit(fn -> :gen_udp.close(socket) end)

      assert {:ok, %{"types" => all}} = Live.ports(%{"top" => 20})

      assert Enum.any?(all, &(&1["type"] == "cat")) and
               Enum.any?(all, &(&1["type"] == "udp_inet"))

      assert {:ok, result} = Live.ports(%{"top" => 1})
      assert [_type] = result["types"]
      assert [_owner] = result["owners"]
      assert [_port] = result["ports"]
    end

    # A credential in a spawn
    # command left the node in ports[].name, including escaped quotes, a
    # nested shell command, and a value that starts with `-`. A command
    # line cannot be parsed with confidence, so any credential name in its
    # arguments masks the whole argument list after the program.
    test "a port command naming a credential anywhere in its arguments exports only its program" do
      assert {:ok, %{"session_id" => _id}} = Live.start(%{"components" => ["logger"]})

      commands = [
        {~s(sh -c "exec cat" --password review_plain_credential --api-key=review_key x),
         ["review_plain_credential", "review_key"]},
        {~s(sh -c "exec cat" --password "prefix\\"review_escaped_secret"),
         ["review_escaped_secret"]},
        # A nested shell command that names the credential and keeps `cat`
        # running, so the port is still open when it is read.
        {~s(sh -c "cat; : --password review_nested_secret"), ["review_nested_secret"]},
        {~s(sh -c "exec cat" --password -review_negative_secret), ["review_negative_secret"]},
        {~s(sh -c "exec cat" PASSWORD=review_env_secret), ["review_env_secret"]},
        {~s(sh -c "exec cat" --pass\\ word review_split_secret --Auth-Token review_case_secret),
         ["review_case_secret"]},
        # A shell line continuation splits the
        # credential name; no other credential keyword is present.
        {"sh -c \"exec cat\" --pass\\\nword review_line_value", ["review_line_value"]},
        {"sh -c \"exec cat\" --pa$''ssword review_expansion_value", ["review_expansion_value"]},
        # Tabs separate the program from its
        # arguments; the first space comes only before the value.
        {"sh\t-c\tcat\t--password review_tab_value", ["review_tab_value"]},
        # The program boundary is the command's
        # only control character, and no credential keyword appears.
        {"sh\t-c cat review_boundary_value", ["review_boundary_value"]}
      ]

      for {command, secrets} <- commands do
        port = Port.open({:spawn, command}, [:binary])
        on_exit(fn -> safe_close(port) end)
        true = Port.command(port, "ready\n")
        assert_receive {^port, {:data, "ready\n"}}, 5_000
        port_text = port |> :erlang.port_to_list() |> List.to_string()

        assert {:ok, result} = Live.ports(%{"top" => 200})
        assert %{"name" => name} = Enum.find(result["ports"], &(&1["port"] == port_text))
        assert name == "sh [REDACTED:credential_key]", command
        decoded = result |> Jason.encode!() |> Jason.decode!() |> Jason.encode!()
        for secret <- secrets, do: refute(decoded =~ secret, command)
        assert Enum.any?(result["redactions"], &(&1["reason"] == "credential_key"))
        assert result["session"]["recorded"] == true
        safe_close(port)
      end

      assert Inspect.Ports.mask_command("cat -u --token=t1 -p 1") ==
               "cat [REDACTED:credential_key]"

      # Arguments a shell may rewrite (an escape, a control character, an
      # expansion or a command substitution) are masked whole, whatever
      # they name.
      for command <- [
            "cat a\\b",
            "cat --pa\\\nss v",
            "cat -u\tv",
            "cat \"$HOME\"",
            "cat `x`",
            "cat -u\rv"
          ],
          do: assert(Inspect.Ports.mask_command(command) == "cat [REDACTED:credential_key]")

      # A command whose arguments name no credential and hold nothing a
      # shell may rewrite keeps them.
      assert Inspect.Ports.mask_command(~s(sh -c "exec cat" -u)) == ~s(sh -c "exec cat" -u)
      assert Inspect.Ports.mask_command("cat") == "cat"
      # A program that names a credential or holds anything a shell may
      # rewrite makes the boundary itself doubtful: the whole command goes.
      for command <- [
            "/opt/secrets/cat -u",
            "s\\h\t-c cat --password v",
            "$SHELL -c cat",
            "\t--password v"
          ],
          do: assert(Inspect.Ports.mask_command(command) == "[REDACTED:credential_key]")

      # Any whitespace or control character ends the program.
      assert Inspect.Ports.mask_command("sh\t-c\tcat\t--password v") ==
               "sh [REDACTED:credential_key]"

      assert Inspect.Ports.mask_command("sh\n--password v") == "sh [REDACTED:credential_key]"

      # A sole control character at the boundary masks the rest too.
      for separator <- ["\t", "\n", "\r"],
          do:
            assert(
              Inspect.Ports.mask_command("sh" <> separator <> "-c cat v") ==
                "sh [REDACTED:credential_key]"
            )
    end

    test "an owner name with no process and malformed filters are refused" do
      assert {:error, %{"code" => "process_not_found"}} =
               Live.ports(%{"owner" => "Insider.Live.InspectTest"})

      assert {:error, %{"code" => "invalid_options", "field" => "type"}} =
               Live.ports(%{"type" => "bad type"})

      assert {:error, %{"code" => "invalid_options", "field" => "type"}} =
               Live.ports(%{"type" => 7})

      assert {:error, %{"code" => "invalid_options", "field" => "owner"}} =
               Live.ports(%{"owner" => "<9.9.9>"})
    end
  end

  describe "alloc" do
    test "reports allocators through recon_alloc and is component_unavailable without recon" do
      {:ok, protection} = ProtectedTargets.new()

      assert {:ok, result} =
               Inspect.run("alloc", %{top: 2}, :rich, protection, recon: Inspect.recon())

      assert result["schema"] == "insider.live-alloc/v1"
      assert result["allocated_bytes"] >= result["used_bytes"]
      assert result["usage_percent"] in 0..100
      assert map_size(result["allocated_types"]) > 0
      assert [largest, next] = result["fragmentation"]
      assert largest["mbcs_carriers_bytes"] >= next["mbcs_carriers_bytes"]

      assert {:error,
              %{
                "code" => "component_unavailable",
                "component" => "recon",
                "reason" => "not_loaded"
              }} =
               Inspect.run("alloc", %{top: 2}, :rich, protection, recon: false)

      assert {:error, %{"field" => "top"}} = Live.alloc(%{"top" => 0})
    end
  end

  describe "JSON twins" do
    test "each inspection's JSON is the canonical encoding of its map result" do
      cases = [
        {&Live.JSON.process/1, &Live.process/1, %{"pid" => "<1.2.3>"}, "pid"},
        {&Live.JSON.process/1, &Live.process/1, %{pid: "<0.1.0>"}, "options"},
        {&Live.JSON.bin_leak/1, &Live.bin_leak/1, %{"top" => 51}, "top"},
        {&Live.JSON.ports/1, &Live.ports/1, %{"type" => 7}, "type"},
        {&Live.JSON.ports/1, &Live.ports/1, :nope, "options"},
        {&Live.JSON.alloc/1, &Live.alloc/1, %{"top" => 0}, "top"},
        {&Live.JSON.alloc/1, &Live.alloc/1, [top: 1], "options"}
      ]

      for {json, map, options, field} <- cases do
        assert {:error, %{"code" => "invalid_options", "field" => ^field} = error} = map.(options)
        assert json.(options) == Canonical.encode(%{"error" => error})
      end

      # A malformed trace id is refused before any session is looked up.
      assert {:error, %{"code" => "invalid_options", "field" => "trace_id"} = invalid} =
               Live.trace("live-none", 42)

      assert Live.JSON.trace("live-none", 42) == Canonical.encode(%{"error" => invalid})

      assert {:error, %{"code" => "unknown_session"} = unknown} =
               Live.amend("live-none", %{"max_events" => 64})

      assert Live.JSON.amend("live-none", %{"max_events" => 64}) ==
               Canonical.encode(%{"error" => unknown})
    end

    test "the default-option twins read as the map API's defaults" do
      assert {:ok, alloc} = Live.alloc(%{})
      assert %{"ok" => %{"schema" => schema}} = Jason.decode!(Live.JSON.alloc())
      assert schema == alloc["schema"]

      assert %{"ok" => %{"schema" => "insider.live-ports/v1"}} = Jason.decode!(Live.JSON.ports())
      assert {:ok, reports} = Live.reports()
      assert Live.JSON.reports() == Canonical.encode(%{"ok" => reports})
    end
  end

  describe "bounds and the session" do
    test "a third concurrent inspection is busy and leaves nothing behind" do
      slots = [Insider.Live.Inspect.Slot1, Insider.Live.Inspect.Slot2]

      holders =
        for slot <- slots do
          test = self()

          spawn(fn ->
            Process.register(self(), slot)
            send(test, {:holding, slot})
            receive do: (:release -> :ok)
          end)
        end

      for slot <- slots, do: assert_receive({:holding, ^slot})
      assert {:error, %{"code" => "busy"}} = Live.bin_leak()
      Enum.each(holders, &send(&1, :release))

      # The busy worker never registered, so a slot frees as soon as a
      # holder exits.
      monitors = Enum.map(holders, &Process.monitor/1)
      for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})
      assert {:ok, _result} = Live.bin_leak(%{"top" => 1})
    end

    # When the inspection stops waiting for the
    # session, the write may still happen, so the result never says false.
    test "an inspection whose session record outlives its wait reports an unknown outcome, not false" do
      {server, _caller} = blocked_server()
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})
      session = :sys.get_state(Insider.Collector.Session.Manager).active.pid

      :ok = :sys.suspend(session)

      result =
        try do
          Live.process(%{"pid" => pid_text(server)})
        after
          :ok = :sys.resume(session)
        end

      assert {:ok, %{"session" => recorded}} = result

      assert recorded == %{"session_id" => id, "recorded" => nil, "reason" => "outcome_unknown"}

      # A later inspection is recorded after whatever became of that one.
      assert {:ok, %{"session" => %{"recorded" => true}}} = Live.ports()
    end

    test "a running session records each inspection as an inspect event its readers can view" do
      {server, _caller} = blocked_server()
      send(server, {:queued, 1})
      assert {:ok, %{"session_id" => id}} = Live.start(%{"components" => ["logger"]})

      assert {:ok, %{"session" => session}} = Live.process(%{"pid" => pid_text(server)})
      assert session == %{"session_id" => id, "recorded" => true, "reason" => nil}
      assert {:ok, %{"session" => %{"recorded" => true}}} = Live.ports()
      assert {:ok, %{"session" => %{"recorded" => true}}} = Live.bin_leak(%{"top" => 1})

      assert {:ok, batch} =
               Live.events_since(id, 0, %{"view" => %{"sources" => ["inspect"]}})

      kinds = Enum.map(batch["events"], & &1["event"]["kind"])
      assert kinds == ["inspect.process", "inspect.ports", "inspect.bin_leak"]

      [process | _rest] = batch["events"]
      assert process["event"]["subject"]["value"] == pid_text(server)
      assert process["event"]["severity"] == "info"
      attributes = process["event"]["attributes"]
      assert attributes["operation"] == "process"
      assert attributes["mailbox_length"] == 1
      assert [%{"shape" => "{:queued, integer}"}] = attributes["mailbox_shapes"]

      assert {:ok, _stopped} = Live.stop(id)

      # A stopped session takes no more events.
      assert {:ok, %{"session" => nil}} = Live.ports()
    end

    # Process results were never cut, and the
    # others were cut before masks, metadata, and session status were added.
    test "a process result with long source paths fits the result bound, session status included" do
      file = String.duplicate("d/", 5_000) <> "deep_frames.ex"
      module = :"Elixir.Insider.Live.InspectTest.LongFile#{System.unique_integer([:positive])}"

      Code.compile_string(
        """
        defmodule #{inspect(module)} do
          def a(t), do: b(t) + 1
          def b(t), do: c(t) + 1
          def c(t), do: d(t) + 1
          def d(t), do: e(t) + 1
          def e(t), do: f(t) + 1
          def f(t), do: g(t) + 1
          def g(t), do: h(t) + 1
          def h(t), do: (send(t, {:deep, self()}); receive do: (:go -> 0))
        end
        """,
        file
      )

      test = self()
      deep = spawn(fn -> module.a(test) end)
      on_exit(fn -> Process.exit(deep, :kill) end)
      assert_receive {:deep, ^deep}
      assert {:ok, %{"session_id" => _id}} = Live.start(%{"components" => ["logger"]})

      assert {:ok, result} = Live.process(%{"pid" => pid_text(deep), "frames" => 8})
      assert result["session"]["recorded"] == true
      assert byte_size(Canonical.encode(result)) <= Inspect.bounds()["result_bytes_max"]
      frames = Enum.filter(result["stacktrace"]["frames"], &(&1["file"] =~ "deep_frames.ex"))
      assert Enum.count_until(frames, 7) == 7
      assert Enum.all?(frames, &(byte_size(&1["file"]) <= 256 and &1["file"] =~ ~r/\A\.\.\./))
    end

    test "a ports result at its largest top is cut to the result bound and counts what it dropped" do
      owners =
        for index <- 1..50 do
          name = :"#{String.duplicate("o", 240)}#{index}"
          test = self()

          spawn(fn ->
            Process.register(self(), name)
            sockets = for _ <- 1..4, do: elem(:gen_udp.open(0), 1)
            send(test, {:open, self()})
            receive do: (:stop -> Enum.each(sockets, &:gen_udp.close/1))
          end)
        end

      # Cleanup first, so a failed wait never leaves the socket owners (and
      # their registered names and udp ports) to the tests after this one;
      # opening 200 sockets can take longer than the default 100 ms under load.
      on_exit(fn -> Enum.each(owners, &send(&1, :stop)) end)
      for owner <- owners, do: assert_receive({:open, ^owner}, 5_000)
      assert {:ok, %{"session_id" => _id}} = Live.start(%{"components" => ["logger"]})

      assert {:ok, result} = Live.ports(%{"type" => "udp_inet", "top" => 200})
      assert result["matched"] >= 200
      assert result["omitted"] > 0
      assert result["session"]["recorded"] == true
      assert byte_size(Canonical.encode(result)) <= Inspect.bounds()["result_bytes_max"]
    end

    test "fit cuts nested lists longest first and says when fixed fields cannot fit" do
      map = %{"a" => %{"b" => Enum.to_list(1..100)}, "c" => [1, 2]}
      assert {:ok, fitted} = Inspect.fit(map, [["a", "b"], ["c"]], 60)
      assert fitted["omitted"] > 0 and fitted["c"] == [1, 2]
      assert byte_size(Canonical.encode(fitted)) <= 60

      assert :too_large = Inspect.fit(%{"fixed" => String.duplicate("x", 100)}, [], 50)
      assert Inspect.bound_text("abcdef", 5, :head) == "ab..."
      assert Inspect.bound_text("abcdéf", 6, :tail) == "...éf"
      assert Inspect.bound_text("éééé", 6, :head) == "é..."
    end

    test "event attributes are cut to the event bound and say what was omitted" do
      rows =
        for index <- 1..60,
            do: %{"type" => "type_#{index}_" <> String.duplicate("x", 400), "count" => index}

      attributes =
        Inspect.event_attributes("ports", %{
          "implementation" => "native",
          "port_count" => 60,
          "types" => rows,
          "owners" => rows
        })

      assert attributes["omitted"] > 0
      assert byte_size(Jason.encode!(attributes)) <= Inspect.bounds()["event_bytes_max"]
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
