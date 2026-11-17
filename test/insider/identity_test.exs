defmodule Insider.IdentityTest do
  use ExUnit.Case, async: true

  alias Insider.Event
  alias Insider.Identity
  alias Insider.Identity.Generation
  alias Insider.Identity.Subject
  alias Insider.Protocol.Error

  test "a process explicitly declares one bounded generation and attaches it to events" do
    registry = start_supervised!({Identity, node: "node-a", boot_id: "boot-a"})
    subject = Subject.new!("worker", "billing-sync", "tenant-7")

    assert {:ok, %Generation{} = generation} =
             Identity.declare(registry, subject, logical_operation_id: "job-42")

    assert generation.pid == self()
    assert generation.node == "node-a"
    assert generation.boot_id == "boot-a"
    assert Identity.active?(registry, generation)

    assert {:error, %Error{code: :invalid_identity}} =
             Identity.declare(registry, subject)

    assert {:error, %Error{code: :invalid_identity}} =
             Identity.declare(registry, subject, logical_operation_id: 123)

    assert Process.alive?(registry)

    event = event(node: "node-a", boot_id: "boot-a", subject: nil)
    assert {:ok, attached} = Identity.attach(registry, event, generation)
    assert attached.subject == subject
    assert attached.causality.process_generation == generation.id
    assert attached.causality.logical_operation_id == "job-42"
  end

  test "generation validation rejects forged shapes before identity use" do
    registry = start_supervised!({Identity, node: "node-a", boot_id: "boot-a"})
    {:ok, generation} = Identity.declare(registry, Subject.new!("worker", "billing-sync"))

    refute Generation.valid?(Map.put(generation, :unexpected, true))
    refute Generation.valid?(%{})
  end

  test "monitor cleanup removes dead generations and restarts cannot inherit them" do
    registry = start_supervised!({Identity, node: "node-a", boot_id: "boot-a"})
    subject = Subject.new!("worker", "same-logical-actor")
    first = declare_from_child(registry, subject)

    assert Identity.active?(registry, first)
    stop_and_wait(first.pid)
    refute eventually(fn -> Identity.active?(registry, first) end)

    second = declare_from_child(registry, subject)
    on_exit(fn -> if Process.alive?(second.pid), do: Process.exit(second.pid, :kill) end)

    refute first.id == second.id

    assert Identity.relation(first, second) == %{
             physical: :different,
             process_generation: :different,
             logical_actor: :same,
             logical_operation: :unknown
           }
  end

  test "capacity is bounded and freed when a declaring process exits" do
    registry = start_supervised!({Identity, node: "node-a", boot_id: "boot-a", max_active: 1})
    subject = Subject.new!("worker", "one")
    first = declare_from_child(registry, subject)

    parent = self()

    blocked =
      spawn(fn ->
        send(
          parent,
          {:blocked, self(), Identity.declare(registry, Subject.new!("worker", "two"))}
        )

        receive do: (:stop -> :ok)
      end)

    assert_receive {:blocked, ^blocked, {:error, %Error{code: :invalid_identity}}}
    stop_and_wait(blocked)
    stop_and_wait(first.pid)
    refute eventually(fn -> Identity.active?(registry, first) end)

    replacement = declare_from_child(registry, Subject.new!("worker", "two"))

    on_exit(fn ->
      if Process.alive?(replacement.pid), do: Process.exit(replacement.pid, :kill)
    end)

    assert Identity.active?(registry, replacement)
  end

  test "missing and conflicting evidence is never guessed or overwritten" do
    registry = start_supervised!({Identity, node: "node-a", boot_id: "boot-a"})
    subject = Subject.new!("worker", "declared")
    {:ok, generation} = Identity.declare(registry, subject)

    unknown_operation = %{generation | id: "other", logical_operation_id: nil}

    reused_address = Identity.relation(generation, unknown_operation)
    assert reused_address.physical == :same
    assert reused_address.process_generation == :different
    assert reused_address.logical_operation == :unknown

    other_node = %{generation | node: "node-b"}
    other_boot = %{generation | boot_id: "boot-b"}

    assert Identity.relation(generation, other_node) == %{
             physical: :different,
             process_generation: :different,
             logical_actor: :unknown,
             logical_operation: :unknown
           }

    assert Identity.relation(generation, other_boot) == %{
             physical: :unknown,
             process_generation: :different,
             logical_actor: :unknown,
             logical_operation: :unknown
           }

    absent = %Generation{
      id: nil,
      node: nil,
      boot_id: nil,
      pid: self(),
      subject: nil,
      logical_operation_id: nil,
      declared_at: nil
    }

    assert Identity.relation(absent, absent) == %{
             physical: :unknown,
             process_generation: :unknown,
             logical_actor: :unknown,
             logical_operation: :unknown
           }

    assert {:error, %Error{code: :invalid_identity}} =
             Identity.attach(
               registry,
               event(node: "node-a", boot_id: "boot-a", subject: Subject.new!("worker", "other")),
               generation
             )

    forged_event = %{event(node: "node-a", boot_id: "boot-a", subject: nil) | causality: nil}

    assert {:error, %Error{code: :invalid_event}} =
             Identity.attach(registry, forged_event, generation)

    assert {:error, %Error{code: :invalid_identity}} =
             Identity.attach(
               registry,
               event(node: "node-b", boot_id: "boot-a", subject: nil),
               generation
             )

    pre_correlated =
      event(node: "node-a", boot_id: "boot-a", subject: nil)
      |> Map.update!(:causality, &Map.put(&1, :logical_operation_id, "request-7"))

    assert {:ok, attached} = Identity.attach(registry, pre_correlated, generation)
    assert attached.causality.logical_operation_id == "request-7"

    refute Identity.active?(registry, %{generation | id: "forged"})
    refute Identity.active?(registry, %{generation | id: String.duplicate("x", 1_000_000)})
    refute function_exported?(Identity, :lookup, 2)
  end

  test "subject contract is exact, portable, and bounded" do
    assert {:ok, %{"namespace" => "worker", "scope" => nil, "value" => "jobs"}} =
             Subject.new("worker", "jobs")

    refute Subject.valid?(%{
             "namespace" => "worker",
             "scope" => nil,
             "value" => "jobs",
             "pid" => self()
           })

    refute Subject.valid?(%{"namespace" => "Worker", "scope" => nil, "value" => "jobs"})

    refute Subject.valid?(%{
             "namespace" => "worker",
             "scope" => nil,
             "value" => String.duplicate("x", 129)
           })

    assert {:error, %Error{code: :invalid_identity}} = Subject.new("Worker", "jobs")

    assert_raise ArgumentError, ~r/subject must contain bounded namespace/, fn ->
      Subject.new!("Worker", "jobs")
    end
  end

  defp declare_from_child(registry, subject) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:declared, self(), Identity.declare(registry, subject)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:declared, ^pid, {:ok, %Generation{} = generation}}
    generation
  end

  defp stop_and_wait(pid) do
    reference = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^reference, :process, ^pid, :normal}
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    # The test process and registry receive independent DOWN signals, so neither
    # message orders the other. This bounded poll observes monitor cleanup
    # without pretending there is a causal barrier between the two recipients.
    if fun.() do
      true
    else
      Process.sleep(2)
      eventually(fun, attempts - 1)
    end
  end

  defp event(overrides) do
    Event.new!(
      Keyword.merge(
        [
          id: "evt-identity",
          node: "node-a",
          boot_id: "boot-a",
          source: "agent",
          kind: "identity.attached",
          severity: :info,
          monotonic_time: 1,
          clock_id: "clock-a",
          source_instance_id: "identity-test",
          source_sequence: 1,
          wall_time: nil,
          subject: nil,
          causality: %{
            trace_id: nil,
            span_id: nil,
            parent_event_id: nil,
            logical_operation_id: nil,
            process_generation: nil
          },
          attributes: %{},
          payload: nil,
          authority: "policy-test",
          redactions: [],
          extensions: %{}
        ],
        overrides
      )
    )
  end
end
