defmodule Insider.TestSupport.SandboxProvider do
  @behaviour Insider.Sentinel.Sandbox.Provider

  alias Insider.Provenance

  @state Insider.TestSupport.SandboxProviderState

  @impl true
  def identity, do: %{"id" => "test.sandbox", "version" => 1}

  @impl true
  def acquire(owner_id, target, _deadline) do
    mode = get_in(target.provenance, ["components", "code", "attributes", "mode"])
    unique = get_in(target.provenance, ["components", "code", "attributes", "unique"])
    intents = allocation_intents(owner_id, resource_count(mode))

    Agent.update(@state, fn state ->
      state
      |> put_in([:resources, owner_id], intents)
      |> put_in([:targets, owner_id], target.provenance)
    end)

    notify({:sandbox_allocation_intent, owner_id, self(), mode, unique})
    if mode in ["intent_block", "intent_trap_cleanup_block"], do: await_release()

    resources = Enum.map(intents, &Map.put(&1, :pid, spawn_link(fn -> resource_loop() end)))

    Agent.update(@state, fn state ->
      put_in(state, [:resources, owner_id], resources)
    end)

    Enum.each(resources, &Process.unlink(&1.pid))
    notify({:sandbox_acquired, owner_id, self(), mode, unique})

    case mode do
      "crash" ->
        raise "provider crash"

      "acquire_error" ->
        {:error, :acquisition_failed}

      mode when mode in ["barrier", "block", "cancel_block", "shutdown_cleanup_block"] ->
        await_release()

      _mode ->
        :ok
    end
  end

  @impl true
  def observe(owner_id, _deadline) do
    provenance = Agent.get(@state, &get_in(&1, [:targets, owner_id]))
    mode = get_in(provenance, ["components", "code", "attributes", "mode"])

    case mode do
      "observe_block" ->
        notify({:sandbox_observe_started, owner_id, self()})
        await_release()
        {:ok, provenance}

      "mismatch" ->
        {:ok, mismatch_provenance()}

      "observe_error" ->
        {:error, :observation_failed}

      "invalid_observation" ->
        {:ok, %{}}

      _mode ->
        {:ok, provenance}
    end
  end

  @impl true
  def cleanup(owner_id, _deadline) do
    mode =
      Agent.get(@state, fn state ->
        get_in(state, [:targets, owner_id, "components", "code", "attributes", "mode"])
      end)

    if mode == "intent_trap_cleanup_block", do: Process.flag(:trap_exit, true)

    if mode in [
         "cleanup_block",
         "intent_block",
         "intent_trap_cleanup_block",
         "shutdown_cleanup_block"
       ] do
      notify({:sandbox_cleanup_started, owner_id, self()})
      await_release()
    end

    {mode, resources} =
      Agent.get_and_update(@state, fn state ->
        provenance = get_in(state, [:targets, owner_id])
        mode = get_in(provenance, ["components", "code", "attributes", "mode"])
        resources = get_in(state, [:resources, owner_id]) || []

        state =
          if mode in ["leftover", "max_leftover"] do
            state
          else
            update_in(state, [:resources], &Map.delete(&1, owner_id))
          end

        {{mode, resources}, state}
      end)

    if mode not in ["leftover", "max_leftover"], do: Enum.each(resources, &terminate_resource/1)

    notify({:sandbox_cleanup, owner_id})
    if mode == "cleanup_error", do: {:error, :cleanup_failed}, else: :ok
  end

  @impl true
  def inventory(owner_id, _deadline) do
    {mode, resources} =
      Agent.get(@state, fn state ->
        provenance = get_in(state, [:targets, owner_id])
        mode = get_in(provenance, ["components", "code", "attributes", "mode"])
        {mode, get_in(state, [:resources, owner_id]) || []}
      end)

    case mode do
      "inventory_error" ->
        {:error, :inventory_failed}

      "invalid_inventory" ->
        {:ok, [:raw_resource_identifier]}

      "bad_digest_inventory" ->
        {:ok, [%{"id_fingerprint" => "sha256:not-a-digest", "kind" => "beam-process"}]}

      "too_many_inventory" ->
        {:ok,
         for index <- 1..65 do
           digest = :crypto.hash(:sha256, Integer.to_string(index)) |> Base.encode16(case: :lower)
           %{"id_fingerprint" => "sha256:" <> digest, "kind" => "beam-process"}
         end}

      _mode ->
        references =
          resources
          |> Enum.map(&%{"id_fingerprint" => &1.id_fingerprint, "kind" => "beam-process"})
          |> Enum.sort_by(& &1["id_fingerprint"])

        {:ok, references}
    end
  end

  defp mismatch_provenance do
    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => "different"}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    Provenance.to_wire_map(provenance)
  end

  defp notify(message) do
    test = Agent.get(@state, & &1.test)
    send(test, message)
  end

  defp await_release do
    receive do
      :release_sandbox_acquire -> :ok
    end
  end

  defp resource_count("max_leftover"), do: 64
  defp resource_count(_mode), do: 1

  defp allocation_intents(owner_id, count) do
    for index <- 1..count do
      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary({owner_id, index}))
        |> Base.encode16(case: :lower)

      %{id_fingerprint: "sha256:" <> digest, pid: nil}
    end
  end

  defp terminate_resource(%{pid: pid}) when is_pid(pid), do: Process.exit(pid, :kill)
  defp terminate_resource(%{pid: nil}), do: :ok

  defp resource_loop do
    receive do
      :stop -> :ok
    end
  end
end
