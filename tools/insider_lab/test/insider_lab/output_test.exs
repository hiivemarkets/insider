defmodule Insider.Lab.OutputTest do
  # Every Lab Mix task prints one machine-readable document on standard
  # output. These tests run each task as an agent would and parse what it
  # printed: in this VM, where standard output is a Unicode-mode device as it
  # is under Mix, and in a fresh `mix` after a change that recompiles the Lab.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Insider.Lab.Output
  alias Insider.Test.OracleRunnerFixture, as: Fixture

  @text "a → b…"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "insider-lab-output-" <> suffix <> "-é…")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "write/2" do
    test "keeps UTF-8 bytes intact on Unicode and Latin-1 devices" do
      bytes = ~s({"title":"#{@text}"}\n)

      for encoding <- [:unicode, :latin1] do
        {:ok, device} = StringIO.open("", encoding: encoding)
        assert :ok = Output.write(bytes, device)
        assert {"", ^bytes} = StringIO.contents(device)
      end

      # The defect this guards against: raw bytes on a Unicode-mode device.
      {:ok, device} = StringIO.open("", encoding: :unicode)
      IO.binwrite(device, bytes)
      refute StringIO.contents(device) == {"", bytes}
    end

    test "writes every iodata shape as its bytes, never as code points" do
      expected = ~s({"title":"#{@text}"}\n)
      text_bytes = :binary.bin_to_list(@text)

      shapes = [
        :binary.bin_to_list(expected),
        [~s({"title":"), text_bytes, ~s("}), ?\n],
        [[~s({"ti), [?t, ?l, ?e]], [~s(":"), [hd(text_bytes) | [tl(text_bytes)]]], ~s("}\n)]
      ]

      for encoding <- [:unicode, :latin1], iodata <- shapes do
        {:ok, device} = StringIO.open("", encoding: encoding)
        assert :ok = Output.write(iodata, device)
        assert {"", ^expected} = StringIO.contents(device), inspect({encoding, iodata})
      end
    end

    test "returns the device's error instead of raising" do
      {:ok, device} = StringIO.open("")
      StringIO.close(device)
      assert {:error, _reason} = Output.write("{}\n", device)
    end
  end

  describe "non-ASCII round trip through each task's standard output" do
    test "insider.live" do
      document =
        run_task(Mix.Tasks.Insider.Live, ["report", "--category", "bug", "--message", @text])

      assert document["result"]["report"]["message"] == @text
    end

    test "insider.candidates", %{tmp_dir: tmp_dir} do
      path = candidates_target(tmp_dir)
      document = run_task(Mix.Tasks.Insider.Candidates, ["--root", tmp_dir, "--path", path])
      assert document["paths"] == [path]
    end

    test "insider.privacy_corpus", %{tmp_dir: tmp_dir} do
      corpus = privacy_corpus(tmp_dir)

      document =
        run_task(Mix.Tasks.Insider.PrivacyCorpus, [
          "--corpus",
          corpus,
          "--environment",
          "production"
        ])

      fields = Enum.flat_map(document["items"], & &1["retained_fields"])
      assert "attributes.metadata.#{@text}" in fields
    end

    test "insider.oracle", %{tmp_dir: tmp_dir} do
      root = Fixture.create(tmp_dir, git?: false, tests: [plain: ":ok"])
      output = Path.join(tmp_dir, "run")

      document = run_task(Mix.Tasks.Insider.Oracle, oracle_arguments(tmp_dir, root, output), 4)
      assert document["command"]["cwd"] == resolved(root)
    end

    test "insider" do
      name = :"Elixir.Insider.Lab.OutputTest.Ré…"
      target = spawn(fn -> receive(do: (:stop -> :ok)) end)
      Process.register(target, name)
      on_exit(fn -> send(target, :stop) end)

      document = run_task(Mix.Tasks.Insider, ["inspect", "--name", Atom.to_string(name)])
      assert document["value"]["metrics"]["registered_name"] == Atom.to_string(name)
    end
  end

  describe "standard output after a change that recompiles the Lab" do
    # Each case runs the task in a fresh `mix` against a copy of this build
    # without the Lab's compiled modules, so Mix recompiles the Lab before
    # the task starts, as it does after an edit to a Lab source.
    setup :copy_build

    test "insider.live", context do
      {stdout, 0} =
        fresh_mix(context, ["insider.live", "report", "--category", "bug", "--message", @text])

      assert Jason.decode!(stdout)["result"]["report"]["message"] == @text
    end

    test "insider.candidates", %{tmp_dir: tmp_dir} = context do
      path = candidates_target(tmp_dir)
      {stdout, 0} = fresh_mix(context, ["insider.candidates", "--root", tmp_dir, "--path", path])
      assert Jason.decode!(stdout)["paths"] == [path]
    end

    test "insider.privacy_corpus", %{tmp_dir: tmp_dir} = context do
      arguments = ["--corpus", privacy_corpus(tmp_dir), "--environment", "production"]
      {stdout, 0} = fresh_mix(context, ["insider.privacy_corpus" | arguments])
      assert Jason.decode!(stdout)["schema"] == "insider.privacy-corpus-report/v1"
    end

    test "insider.oracle", %{tmp_dir: tmp_dir} = context do
      root = Fixture.create(tmp_dir, git?: false, tests: [plain: ":ok"])
      arguments = oracle_arguments(tmp_dir, root, Path.join(tmp_dir, "run"))
      {stdout, 4} = fresh_mix(context, ["insider.oracle" | arguments])
      assert Jason.decode!(stdout)["command"]["cwd"] == resolved(root)
    end

    test "insider", context do
      {stdout, 0} = fresh_mix(context, ["insider", "capabilities"])
      assert Jason.decode!(stdout)["status"] == "ok"
    end
  end

  describe "standard output while another Mix holds the build lock" do
    # Several agents running Lab tasks from one checkout contend for Mix's
    # build lock (Elixir 1.18 and later), and each waiting `mix` prints
    # "Waiting for lock on the build directory". This test holds that lock,
    # starts every machine-output task (`insider.live` twice) at once, waits
    # until each has reported the wait, then releases the lock.
    setup :copy_build

    @tag skip: if(Code.ensure_loaded?(Mix.Sync.Lock), do: false, else: "no Mix build lock")
    test "every task prints the wait on stderr and only its document on stdout",
         %{tmp_dir: tmp_dir, build: build} do
      root = Fixture.create(tmp_dir, git?: false, tests: [plain: ":ok"])
      path = candidates_target(tmp_dir)

      invocations = [
        {["insider.live", "report", "--category", "bug", "--message", @text], 0,
         &(&1["result"]["report"]["message"] == @text)},
        {["insider.live", "reports"], 0, &(&1["result"]["schema"] == "insider.live-reports/v1")},
        {["insider.candidates", "--root", tmp_dir, "--path", path], 0, &(&1["paths"] == [path])},
        {[
           "insider.privacy_corpus",
           "--corpus",
           privacy_corpus(tmp_dir),
           "--environment",
           "production"
         ], 0, &(&1["schema"] == "insider.privacy-corpus-report/v1")},
        {["insider.oracle" | oracle_arguments(tmp_dir, root, Path.join(tmp_dir, "run"))], 4,
         &(&1["command"]["cwd"] == resolved(root))},
        {["insider", "capabilities"], 0, &(&1["status"] == "ok")}
      ]

      # A variable, so Elixir 1.17, which has no such module, compiles this.
      lock = Mix.Sync.Lock

      runs =
        lock.with_lock(build, fn ->
          for {{arguments, _status, _check}, index} <- Enum.with_index(invocations) do
            run = start_mix(build, arguments, Path.join(build, "stdout-#{index}"))

            assert await_stderr(run, "Waiting for lock on the build directory") =~
                     ~r/held by process/

            run
          end
        end)

      for {run, {arguments, status, check}} <- Enum.zip(runs, invocations) do
        assert {^status, _stderr} = await_exit(run), inspect(arguments)
        document = run.stdout |> File.read!() |> Jason.decode!()
        assert check.(document), inspect({arguments, document})
      end
    end
  end

  # A copy of this build that a child `mix` can use and lock on its own.
  defp copy_build(%{tmp_dir: tmp_dir}) do
    source = Mix.Project.build_path()
    # Resolved, because Mix relinks the recompiled Lab's `priv` relative to
    # this path, and the temporary directory is behind a symbolic link.
    build = Path.join(resolved(tmp_dir), "build")
    File.cp_r!(source, build)

    # Mix links `priv` and similar directories relatively; the copy needs
    # them to resolve from its new place.
    for link <- Path.wildcard(Path.join(source, "lib/*/*")),
        {:ok, target} <- [File.read_link(link)] do
      copy = Path.join(build, Path.relative_to(link, source))
      File.rm!(copy)
      File.ln_s!(Path.expand(target, Path.dirname(link)), copy)
    end

    {:ok, build: build}
  end

  # Starts `mix ARGUMENTS` against `build` with its standard output in the
  # file `stdout` and its standard error arriving as port messages.
  defp start_mix(build, arguments, stdout) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", ~s(exec mix "$@" 2>&1 >"$LAB_STDOUT"), "sh" | arguments],
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"MIX_BUILD_PATH", String.to_charlist(build)},
          {~c"LAB_STDOUT", String.to_charlist(stdout)}
        ]
      ])

    %{port: port, stdout: stdout, stderr: ""}
  end

  # Receives standard error until it contains `text`; returns it so far.
  defp await_stderr(%{port: port} = run, text) do
    receive do
      {^port, {:data, data}} ->
        stderr = run.stderr <> data

        if String.contains?(stderr, text),
          do: stderr,
          else: await_stderr(%{run | stderr: stderr}, text)

      {^port, {:exit_status, status}} ->
        flunk("mix exited #{status} before printing #{inspect(text)}: #{run.stderr}")
    after
      120_000 -> flunk("mix printed no #{inspect(text)} within 120 s: #{run.stderr}")
    end
  end

  defp await_exit(%{port: port} = run) do
    receive do
      {^port, {:data, data}} -> await_exit(%{run | stderr: run.stderr <> data})
      {^port, {:exit_status, status}} -> {status, run.stderr}
    after
      120_000 -> flunk("mix did not exit within 120 s: #{run.stderr}")
    end
  end

  defp run_task(task, arguments, expected_status \\ 0) do
    output =
      capture_io(fn ->
        status =
          try do
            task.run(arguments)
            0
          catch
            :exit, {:shutdown, status} -> status
          end

        send(self(), {:status, status})
      end)

    assert_received {:status, ^expected_status}
    Jason.decode!(output)
  end

  # Returns the task's standard output and exit status, after asserting that
  # Mix recompiled and reported it on standard error.
  defp fresh_mix(%{build: build}, arguments) do
    lab = Path.join([build, "lib", "insider_lab"])
    File.rm!(Path.join([lab, ".mix", "compile.elixir"]))
    File.rm_rf!(Path.join(lab, "ebin"))
    stderr = Path.join(build, "stderr")

    {stdout, status} =
      System.cmd("sh", ["-c", ~s(exec mix "$@" 2>"$LAB_STDERR"), "sh" | arguments],
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build}, {"LAB_STDERR", stderr}]
      )

    assert File.read!(stderr) =~ ~r/^Compiling \d+ files? \(\.ex\)$/m
    {stdout, status}
  end

  defp candidates_target(tmp_dir) do
    path = "test/é…_test.exs"
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, path), """
    defmodule Insider.Lab.OutputTest.Target do
      use ExUnit.Case, async: true
      test "plain", do: :ok
    end
    """)

    path
  end

  defp privacy_corpus(tmp_dir) do
    path = Path.join(tmp_dir, "corpus.json")

    "../../priv/privacy_corpus/example.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> put_in(["telemetry_policy", "metadata"], %{"scenario" => @text})
    |> Jason.encode!()
    |> then(&File.write!(path, &1))

    path
  end

  # The oracle reports the target with symbolic links resolved.
  defp resolved(path) do
    {resolved, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(resolved)
  end

  defp oracle_arguments(tmp_dir, root, output) do
    ["--profile", Fixture.profile(tmp_dir), "--root", root, "--output", output] ++
      ["--oracle", "application_env", "--application", "logger", "--key", "lab_output_key"] ++
      ["--", "test/plain_test.exs"]
  end
end
