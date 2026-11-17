defmodule Insider.Live.ObanJobsTest do
  # One live session per node.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Insider.Collector.Session.Manager
  alias Insider.Live

  @stop [:oban, :job, :stop]
  @ms System.convert_time_unit(1, :millisecond, :native)

  setup do
    on_exit(fn ->
      Application.delete_env(:insider, :environment)

      case Live.capabilities()["active_session_id"] do
        nil -> :ok
        id -> Live.stop(id, %{"force" => true})
      end

      assert_eventually(fn -> match?(%{active: nil}, :sys.get_state(Manager)) end)
    end)
  end

  defp start do
    assert {:ok, %{"session_id" => id}} =
             Live.start(%{
               "components" => ["telemetry"],
               "telemetry_events" => [Enum.map(@stop, &Atom.to_string/1)],
               "telemetry_min_duration_ms" => 0
             })

    id
  end

  # Oban Pro's decorator stores the decorated call's argument as a
  # `term-` prefixed, unpadded Base64 Erlang term, which readers otherwise
  # decode by hand.
  defp job do
    arg = :erlang.term_to_binary(["2ded1cd-b694", %{password: "hunter2", note: "fund order"}])

    %{
      __struct__: Oban.Job,
      id: 19_933_484,
      worker: "Oban.Pro.Decorator",
      queue: "notifications",
      attempt: 1,
      max_attempts: 20,
      state: "executing",
      args: %{
        "mod" => "MyApp.Auditor",
        "fun" => "write_record",
        "arg" => "term-" <> Base.encode64(arg, padding: false)
      }
    }
  end

  defp run_job do
    Task.await(
      Task.async(fn ->
        :telemetry.execute(@stop, %{duration: 3 * @ms}, %{job: job(), state: :success, conf: nil})
      end)
    )
  end

  defp stop_event(id) do
    assert_eventually(fn ->
      match?({:ok, %{"events" => [_ | _]}}, Live.events_since(id, 0))
    end)

    {:ok, %{"events" => [%{"event" => event} | _]}} = Live.events_since(id, 0)
    event
  end

  test "a job event names the worker, queue, attempt, state, and the decoded, masked args (rich)" do
    id = start()
    run_job()
    event = stop_event(id)

    assert event["attributes"]["oban"] == %{
             "job_id" => 19_933_484,
             "worker" => "Oban.Pro.Decorator",
             "queue" => "notifications",
             "attempt" => 1,
             "max_attempts" => 20,
             "state" => "success",
             "args_keys" => ["arg", "fun", "mod"]
           }

    assert %{
             "mod" => "MyApp.Auditor",
             "fun" => "write_record",
             "arg" => [
               "2ded1cd-b694",
               %{"password" => "[REDACTED:credential_key]", "note" => "fund order"}
             ]
           } = event["payload"]["oban_args"]

    refute Jason.encode!(event) =~ "hunter2"

    assert {:ok, trace} =
             Live.timeline(id, %{"pid" => event["subject"]["value"], "human" => true})

    assert trace["text"] =~
             ~s(oban.job.stop 3.000ms info worker=Oban.Pro.Decorator queue=notifications attempt=1/20 state=success ) <>
               ~s(args={"arg":["2ded1cd-b694",{"note":"fund order","password":"[REDACTED:credential_key]"}],"fun":"write_record","mod":"MyApp.Auditor"})
  end

  test "under strict a job event shows the args' keys, never their values" do
    Application.put_env(:insider, :environment, :ci)
    id = start()
    run_job()
    event = stop_event(id)

    assert %{"worker" => "Oban.Pro.Decorator", "args_keys" => ["arg", "fun", "mod"]} =
             event["attributes"]["oban"]

    assert event["payload"] == nil
    refute Jason.encode!(event) =~ "write_record"
  end

  # The emitting process does bounded work only; args are
  # decoded when read, and a compressed term (unbounded expansion) is never
  # decoded.
  test "the job's attributes cost bounded work in the emitting process, however wide its args" do
    wide = %{job() | args: Map.new(1..100_000, &{"key_#{&1}", &1})}
    metadata = %{job: wide, state: :success}

    {reductions, attributes} =
      Task.await(
        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)
          attributes = Insider.Collector.ObanJob.attributes(metadata)
          {:reductions, later} = Process.info(self(), :reductions)
          {later - before, attributes}
        end)
      )

    assert reductions < 20_000
    assert Enum.count(attributes["args_keys"]) == 16
    assert attributes["args_keys_truncated"] == true
  end

  test "decoding at read time: padded or not, never a compressed term, never past the bounds" do
    plain = :erlang.term_to_binary(["a", 1])
    big = :erlang.term_to_binary(String.duplicate("x", 100_000), [:compressed])

    assert Insider.Collector.ObanJob.decode(%{
             "arg" => "term-" <> Base.encode64(plain, padding: false)
           }) ==
             %{"arg" => ["a", 1]}

    assert Insider.Collector.ObanJob.decode(%{"arg" => "term-" <> Base.encode64(plain)}) == %{
             "arg" => ["a", 1]
           }

    compressed = "term-" <> Base.encode64(big, padding: false)
    assert byte_size(compressed) < 2_048
    assert Insider.Collector.ObanJob.decode(%{"arg" => compressed}) == %{"arg" => compressed}
    assert Insider.Collector.ObanJob.decode(%{"arg" => "term-%%%"}) == %{"arg" => "term-%%%"}
  end

  defp assert_eventually(predicate, attempts \\ 150)

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
