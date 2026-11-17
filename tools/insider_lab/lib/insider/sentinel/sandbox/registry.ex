defmodule Insider.Sentinel.Sandbox.Registry do
  @moduledoc false

  use GenServer

  require Logger

  alias Insider.Event.Canonical
  alias Insider.Sentinel.Sandbox.CleanupOwnership
  alias Insider.Sentinel.Sandbox.ProviderCall

  @identity_timeout_ms 500
  @inventory_reserve_ms 50
  @maximum_resources 64
  @ownership_call_timeout_ms 50
  @shutdown_cancel_grace_ms 100
  @shutdown_cleanup_timeout_ms 500
  @shutdown_kill_grace_ms 50
  @shutdown_ownership_grace_ms 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec resolve(GenServer.server(), map()) :: {:ok, module()} | :error
  def resolve(registry, identity), do: GenServer.call(registry, {:resolve, identity})

  @spec allow_body(GenServer.server(), module()) :: {:ok, map()} | :error
  def allow_body(registry, module), do: GenServer.call(registry, {:allow_body, module})

  @spec register(GenServer.server(), binary(), pid(), module(), term(), integer()) :: :ok | :error
  def register(registry, owner_id, runner, provider, target, cleanup_deadline),
    do:
      GenServer.call(
        registry,
        {:register, owner_id, runner, provider, target, cleanup_deadline}
      )

  @spec cleanup(GenServer.server(), binary(), integer(), pid(), reference()) :: :ok | :error
  def cleanup(registry, owner_id, deadline, recipient, reference),
    do: GenServer.call(registry, {:cleanup, owner_id, deadline, recipient, reference})

  @spec cleanup_empty(GenServer.server(), binary()) :: {:ok, map()} | :error
  def cleanup_empty(registry, owner_id),
    do: GenServer.call(registry, {:cleanup_empty, owner_id})

  @spec quarantine_active(GenServer.server(), binary(), pid()) :: {:ok, map()} | :error
  def quarantine_active(registry, owner_id, worker),
    do: GenServer.call(registry, {:quarantine_active, owner_id, worker})

  @spec register_active(GenServer.server(), binary(), pid()) :: :ok | :error
  def register_active(registry, owner_id, worker),
    do: GenServer.call(registry, {:register_active, owner_id, worker})

  @spec clear_active(GenServer.server(), binary(), pid()) :: :ok | :error
  def clear_active(registry, owner_id, worker),
    do: GenServer.call(registry, {:clear_active, owner_id, worker})

  @spec counts(GenServer.server()) :: %{active: non_neg_integer(), quarantined: non_neg_integer()}
  def counts(registry), do: GenServer.call(registry, :counts)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    providers = Keyword.get(options, :providers, [])
    bodies = Keyword.get(options, :bodies, [])
    {:ok, cleanup_ownership} = CleanupOwnership.start_link()
    cleanup_ownership_monitor = Process.monitor(cleanup_ownership)

    case {provider_map(providers), body_map(bodies)} do
      {{:ok, provider_map}, {:ok, body_map}} ->
        {:ok,
         %{
           cleanup_ownership: cleanup_ownership,
           cleanup_ownership_monitor: cleanup_ownership_monitor,
           bodies: body_map,
           leases: %{},
           providers: provider_map
         }}

      _error ->
        {:stop, :invalid_sandbox_providers}
    end
  end

  @impl true
  def handle_call({:resolve, identity}, _from, state) do
    key = provider_key(identity)

    case Map.fetch(state.providers, key) do
      {:ok, provider} -> {:reply, {:ok, provider}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:allow_body, module}, _from, state) do
    case Map.fetch(state.bodies, module) do
      {:ok, identity} -> {:reply, {:ok, identity}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(
        {:register, owner_id, runner, provider, target, cleanup_deadline},
        _from,
        state
      ) do
    valid =
      is_binary(owner_id) and is_pid(runner) and is_atom(provider) and
        is_integer(cleanup_deadline) and not Map.has_key?(state.leases, owner_id) and
        provider in Map.values(state.providers)

    if valid do
      monitor = Process.monitor(runner)

      lease = %{
        cleanup_deadline: cleanup_deadline,
        cleanup_job: nil,
        active_worker: nil,
        monitor: monitor,
        provider: provider,
        runner: runner,
        status: :active,
        target: target,
        waiters: []
      }

      {:reply, :ok, put_in(state, [:leases, owner_id], lease)}
    else
      {:reply, :error, state}
    end
  end

  def handle_call({:cleanup, owner_id, deadline, recipient, reference}, _from, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{status: :quarantined}} ->
        {:reply, :error, state}

      {:ok, %{active_worker: active_worker}} when not is_nil(active_worker) ->
        {:reply, :error, state}

      {:ok, lease} ->
        waiter = {recipient, reference}
        lease = %{lease | waiters: [waiter | lease.waiters]}

        {lease, state} =
          ensure_cleanup(owner_id, lease, min(deadline, lease.cleanup_deadline), state)

        {:reply, :ok, put_in(state, [:leases, owner_id], lease)}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:cleanup_empty, owner_id}, _from, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{active_worker: nil, cleanup_job: nil, status: :active} = lease} ->
        Process.demonitor(lease.monitor, [:flush])

        proof = %{
          status: :complete,
          release: :not_required,
          remaining_count: 0,
          remaining_fingerprint: nil
        }

        {:reply, {:ok, proof}, %{state | leases: Map.delete(state.leases, owner_id)}}

      _missing_or_started ->
        {:reply, :error, state}
    end
  end

  def handle_call({:register_active, owner_id, worker}, _from, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{status: :active, cleanup_job: nil, active_worker: nil} = lease}
      when is_pid(worker) ->
        active_worker = %{down: false, monitor: Process.monitor(worker), pid: worker}
        {:reply, :ok, put_in(state, [:leases, owner_id], %{lease | active_worker: active_worker})}

      _missing_or_transitioned ->
        {:reply, :error, state}
    end
  end

  def handle_call({:clear_active, owner_id, worker}, _from, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{status: :active, active_worker: %{monitor: monitor, pid: ^worker}} = lease} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, put_in(state, [:leases, owner_id], %{lease | active_worker: nil})}

      _missing_or_transitioned ->
        {:reply, :error, state}
    end
  end

  def handle_call({:quarantine_active, owner_id, worker}, _from, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{status: :active, cleanup_job: nil, active_worker: %{pid: ^worker}} = lease} ->
        updated = %{lease | status: :quarantined}
        {:reply, {:ok, uncertain_unreleased_proof()}, put_in(state, [:leases, owner_id], updated)}

      {:ok, %{status: :active, cleanup_job: nil, active_worker: nil} = lease}
      when is_pid(worker) ->
        active_worker = %{down: false, monitor: Process.monitor(worker), pid: worker}
        updated = %{lease | active_worker: active_worker, status: :quarantined}
        {:reply, {:ok, uncertain_unreleased_proof()}, put_in(state, [:leases, owner_id], updated)}

      _missing_or_transitioned ->
        {:reply, :error, state}
    end
  end

  def handle_call(:counts, _from, state) do
    quarantined = Enum.count(state.leases, fn {_owner, lease} -> lease.status == :quarantined end)
    {:reply, %{active: map_size(state.leases) - quarantined, quarantined: quarantined}, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, ownership, reason},
        %{cleanup_ownership: ownership, cleanup_ownership_monitor: monitor} = state
      ) do
    warn_unconfirmed_ownership(state)
    {:stop, {:shutdown, {:cleanup_ownership_down, reason}}, state}
  end

  def handle_info(
        {:EXIT, ownership, reason},
        %{cleanup_ownership: ownership} = state
      ) do
    warn_unconfirmed_ownership(state)
    {:stop, {:shutdown, {:cleanup_ownership_exit, reason}}, state}
  end

  def handle_info({:sandbox_cleanup_result, owner_id, job, proof}, state) do
    case Map.fetch(state.leases, owner_id) do
      {:ok, %{cleanup_job: %{pid: ^job}} = lease} ->
        Process.demonitor(lease.cleanup_job.monitor, [:flush])
        notify_waiters(lease.waiters, proof)

        if proof.status == :complete do
          Process.demonitor(lease.monitor, [:flush])
          {:noreply, %{state | leases: Map.delete(state.leases, owner_id)}}
        else
          Process.demonitor(lease.monitor, [:flush])
          updated = %{lease | cleanup_job: nil, status: :quarantined, waiters: []}
          {:noreply, put_in(state, [:leases, owner_id], updated)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case find_runner(state.leases, monitor, pid) do
      {owner_id, %{status: :quarantined} = lease} ->
        updated = %{lease | runner: nil}
        {:noreply, put_in(state, [:leases, owner_id], updated)}

      {owner_id, %{active_worker: active_worker} = lease} when not is_nil(active_worker) ->
        updated = %{lease | runner: nil, status: :quarantined}
        {:noreply, put_in(state, [:leases, owner_id], updated)}

      {owner_id, lease} ->
        lease = %{lease | runner: nil}
        {lease, state} = ensure_cleanup(owner_id, lease, lease.cleanup_deadline, state)
        {:noreply, put_in(state, [:leases, owner_id], lease)}

      nil ->
        handle_non_runner_down(state, monitor, pid)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    shutdown_deadline = System.monotonic_time(:millisecond) + @shutdown_cleanup_timeout_ms
    leases = stop_active_workers(state.leases)

    jobs = shutdown_cleanup_jobs(leases, shutdown_deadline, state.cleanup_ownership)

    pending = Enum.reject(jobs, &job_terminated?(&1, shutdown_deadline))

    Enum.each(pending, &cancel_cleanup_job/1)
    cancel_deadline = System.monotonic_time(:millisecond) + @shutdown_cancel_grace_ms
    stubborn = Enum.reject(pending, &job_terminated?(&1, cancel_deadline))

    kill_deadline = System.monotonic_time(:millisecond) + @shutdown_kill_grace_ms

    forced =
      forced_cleanup_processes(stubborn, state.cleanup_ownership, kill_deadline, reason)

    Enum.each(forced, fn process -> Process.exit(process.pid, :kill) end)
    unconfirmed = Enum.reject(forced, &process_terminated?(&1, kill_deadline))

    if unconfirmed != [] do
      Logger.warning("sandbox shutdown could not confirm cleanup process termination",
        cleanup_job_count: Enum.count(unconfirmed, &(&1.kind == :job)),
        provider_callback_count: Enum.count(unconfirmed, &(&1.kind == :provider))
      )
    end

    stop_cleanup_ownership(state, reason)

    :ok
  end

  defp stop_active_workers(leases) do
    deadline = System.monotonic_time(:millisecond) + @shutdown_kill_grace_ms

    Enum.each(leases, fn
      {_owner_id, %{active_worker: %{down: false} = worker}} -> Process.exit(worker.pid, :kill)
      _inactive_or_already_down -> :ok
    end)

    Enum.into(leases, %{}, fn {owner_id, lease} ->
      case lease.active_worker do
        nil ->
          {owner_id, lease}

        %{down: true} ->
          {owner_id, %{lease | active_worker: nil, status: :active}}

        worker ->
          if process_terminated?(
               %{kind: :body, monitor: worker.monitor, pid: worker.pid},
               deadline
             ) do
            {owner_id, %{lease | active_worker: nil, status: :active}}
          else
            {owner_id, %{lease | status: :quarantined}}
          end
      end
    end)
  end

  defp ensure_cleanup(_owner_id, %{cleanup_job: job} = lease, _deadline, state)
       when not is_nil(job),
       do: {lease, state}

  defp ensure_cleanup(owner_id, lease, deadline, state) do
    job = start_cleanup_job(lease.provider, owner_id, deadline, state.cleanup_ownership)

    {%{
       lease
       | cleanup_job: job,
         status: :cleaning
     }, state}
  end

  defp shutdown_cleanup_jobs(leases, shutdown_deadline, ownership) do
    {jobs, prepared} =
      Enum.reduce(leases, {[], []}, fn
        {_owner_id, %{status: :quarantined}}, accumulated ->
          accumulated

        {_owner_id, %{active_worker: active_worker}}, accumulated
        when not is_nil(active_worker) ->
          accumulated

        {owner_id, %{cleanup_job: nil} = lease}, {jobs, prepared} ->
          deadline = min(lease.cleanup_deadline, shutdown_deadline)
          {job, gate} = prepare_cleanup_job(lease.provider, owner_id, deadline, ownership)
          {[{owner_id, job} | jobs], [{job, gate} | prepared]}

        {owner_id, %{cleanup_job: job}}, {jobs, prepared} ->
          {[{owner_id, job} | jobs], prepared}
      end)

    authorizations = Enum.map(prepared, fn {job, _gate} -> {job.cancel_reference, job.pid} end)
    timeout = max(0, shutdown_deadline - System.monotonic_time(:millisecond))

    case CleanupOwnership.authorize_many(ownership, authorizations, timeout) do
      :ok -> Enum.each(prepared, &begin_cleanup_job/1)
      :error -> Enum.each(prepared, fn {job, _gate} -> Process.exit(job.pid, :kill) end)
    end

    jobs
  end

  defp job_terminated?({_owner_id, %{monitor: monitor, pid: job}}, deadline) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ^monitor, :process, ^job, _reason} -> true
    after
      timeout -> false
    end
  end

  defp cancel_cleanup_job({_owner_id, job}) do
    send(job.pid, {:cancel_provider_call, job.cancel_reference})
  end

  defp forced_cleanup_processes(stubborn, ownership, kill_deadline, terminate_reason) do
    job_processes =
      Enum.map(stubborn, fn {_owner_id, job} ->
        %{kind: :job, monitor: job.monitor, pid: job.pid}
      end)

    provider_pids =
      if cleanup_ownership_down?(terminate_reason) do
        {:ok, []}
      else
        CleanupOwnership.close_all_active(
          ownership,
          min(
            @ownership_call_timeout_ms,
            max(0, kill_deadline - System.monotonic_time(:millisecond))
          )
        )
      end

    providers =
      provider_pids
      |> active_provider_pids()
      |> Enum.map(fn pid ->
        %{kind: :provider, monitor: Process.monitor(pid), pid: pid}
      end)

    if provider_pids == :error do
      Logger.warning("sandbox shutdown could not inspect cleanup provider ownership")
    end

    job_processes ++ providers
  end

  defp process_terminated?(process, deadline) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, monitor, :process, pid, _reason}
      when monitor == process.monitor and pid == process.pid ->
        true
    after
      timeout -> false
    end
  end

  defp active_provider_pids({:ok, providers}), do: providers
  defp active_provider_pids(:error), do: []

  defp cleanup_ownership_down?({:shutdown, {:cleanup_ownership_down, _reason}}), do: true
  defp cleanup_ownership_down?({:shutdown, {:cleanup_ownership_exit, _reason}}), do: true
  defp cleanup_ownership_down?(_reason), do: false

  defp warn_unconfirmed_ownership(%{leases: leases}) when map_size(leases) > 0 do
    Logger.warning("sandbox cleanup ownership lost; provider termination is unconfirmed",
      lease_count: map_size(leases)
    )
  end

  defp warn_unconfirmed_ownership(_state), do: :ok

  defp stop_cleanup_ownership(_state, {:shutdown, {:cleanup_ownership_down, _reason}}), do: :ok
  defp stop_cleanup_ownership(_state, {:shutdown, {:cleanup_ownership_exit, _reason}}), do: :ok

  defp stop_cleanup_ownership(state, _reason) do
    ownership = state.cleanup_ownership
    Process.exit(ownership, :kill)

    deadline = System.monotonic_time(:millisecond) + @shutdown_ownership_grace_ms

    unless process_terminated?(
             %{
               kind: :cleanup_ownership,
               monitor: state.cleanup_ownership_monitor,
               pid: ownership
             },
             deadline
           ) do
      Logger.warning("sandbox shutdown could not confirm cleanup ownership termination")
    end
  end

  defp start_cleanup_job(provider, owner_id, deadline, ownership) do
    {job, gate} = prepare_cleanup_job(provider, owner_id, deadline, ownership)

    timeout =
      min(@ownership_call_timeout_ms, max(0, deadline - System.monotonic_time(:millisecond)))

    case CleanupOwnership.authorize(ownership, job.cancel_reference, job.pid, timeout) do
      :ok -> begin_cleanup_job({job, gate})
      :error -> Process.exit(job.pid, :kill)
    end

    job
  end

  defp prepare_cleanup_job(provider, owner_id, deadline, ownership) do
    parent = self()
    cancel_reference = make_ref()
    gate = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:begin_cleanup_job, ^gate} -> :ok
        end

        Process.flag(:trap_exit, true)
        proof = cleanup_proof(provider, owner_id, deadline, cancel_reference, ownership)
        send(parent, {:sandbox_cleanup_result, owner_id, self(), proof})
      end)

    job = %{cancel_reference: cancel_reference, deadline: deadline, pid: pid, monitor: monitor}
    {job, gate}
  end

  defp begin_cleanup_job({job, gate}), do: send(job.pid, {:begin_cleanup_job, gate})

  defp cleanup_proof(provider, owner_id, deadline, cancel_reference, ownership) do
    release_deadline = max(System.monotonic_time(:millisecond), deadline - @inventory_reserve_ms)

    call_options = [
      cancel_reference: cancel_reference,
      link: true,
      ownership: {ownership, cancel_reference}
    ]

    release =
      ProviderCall.call(
        provider,
        :cleanup,
        [owner_id, release_deadline],
        release_deadline,
        call_options
      )

    case release do
      %{result: {:error, :provider_cancelled}} ->
        uncertain_proof(release)

      _other ->
        if termination_observed?(release) do
          inventory =
            ProviderCall.call(provider, :inventory, [owner_id, deadline], deadline, call_options)

          inventory_proof(release, inventory)
        else
          uncertain_proof(release)
        end
    end
  end

  defp inventory_proof(release, %{termination: {:observed, _reason}, result: result}) do
    case validate_inventory(result) do
      {:ok, []} ->
        complete_proof(release)

      {:ok, resources} ->
        %{
          status: :partial,
          release: release_status(release),
          remaining_count: length(resources),
          remaining_fingerprint: resource_fingerprint(resources)
        }

      :error ->
        uncertain_proof(release)
    end
  end

  defp inventory_proof(release, _unconfirmed_inventory), do: uncertain_proof(release)

  defp complete_proof(release) do
    %{
      status: :complete,
      release: release_status(release),
      remaining_count: 0,
      remaining_fingerprint: nil
    }
  end

  defp uncertain_proof(release) do
    %{
      status: :uncertain,
      release: release_status(release),
      remaining_count: 0,
      remaining_fingerprint: nil
    }
  end

  defp uncertain_unreleased_proof do
    %{
      status: :uncertain,
      release: :not_attempted,
      remaining_count: 0,
      remaining_fingerprint: nil
    }
  end

  defp validate_inventory({:ok, resources}) do
    valid =
      Insider.Protocol.Value.bounded_list?(resources, @maximum_resources) and
        Enum.all?(resources, &valid_resource?/1) and
        Enum.sort_by(resources, &resource_key/1) == resources and
        Enum.uniq_by(resources, &resource_key/1) == resources

    if valid, do: {:ok, resources}, else: :error
  end

  defp validate_inventory(_inventory), do: :error

  defp valid_resource?(%{"kind" => kind, "id_fingerprint" => "sha256:" <> digest} = resource),
    do: map_size(resource) == 2 and vocabulary?(kind) and valid_digest?(digest)

  defp valid_resource?(_resource), do: false

  defp resource_key(resource), do: {resource["kind"], resource["id_fingerprint"]}

  defp release_status(%{result: :ok, termination: {:observed, _reason}}), do: :complete
  defp release_status(_outcome), do: :failed

  defp termination_observed?(%{termination: {:observed, _reason}}), do: true
  defp termination_observed?(_outcome), do: false

  defp resource_fingerprint(resources) do
    digest = :crypto.hash(:sha256, Canonical.encode(resources)) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end

  defp notify_waiters(waiters, proof) do
    Enum.each(waiters, fn {recipient, reference} ->
      send(recipient, {:sandbox_cleanup, reference, proof})
    end)
  end

  defp find_runner(leases, monitor, pid) do
    Enum.find_value(leases, fn {owner_id, lease} ->
      if lease.monitor == monitor and lease.runner == pid, do: {owner_id, lease}
    end)
  end

  defp handle_cleanup_job_down(state, monitor, pid) do
    case Enum.find_value(state.leases, fn {owner_id, lease} ->
           if not is_nil(lease.cleanup_job) and lease.cleanup_job.monitor == monitor and
                lease.cleanup_job.pid == pid,
              do: {owner_id, lease}
         end) do
      {owner_id, lease} ->
        proof = %{
          status: :uncertain,
          release: :failed,
          remaining_count: 0,
          remaining_fingerprint: nil
        }

        notify_waiters(lease.waiters, proof)
        Process.demonitor(lease.monitor, [:flush])
        updated = %{lease | cleanup_job: nil, status: :quarantined, waiters: []}
        {:noreply, put_in(state, [:leases, owner_id], updated)}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_non_runner_down(state, monitor, pid) do
    case find_active_worker(state.leases, monitor, pid) do
      {owner_id, %{status: :quarantined} = lease} ->
        updated = %{lease | active_worker: nil}
        {:noreply, put_in(state, [:leases, owner_id], updated)}

      {owner_id, lease} ->
        updated = %{lease | active_worker: %{lease.active_worker | down: true}}
        {:noreply, put_in(state, [:leases, owner_id], updated)}

      nil ->
        handle_cleanup_job_down(state, monitor, pid)
    end
  end

  defp find_active_worker(leases, monitor, pid) do
    Enum.find_value(leases, fn {owner_id, lease} ->
      case lease.active_worker do
        %{monitor: ^monitor, pid: ^pid} -> {owner_id, lease}
        _other -> nil
      end
    end)
  end

  defp provider_map(providers) do
    deadline = System.monotonic_time(:millisecond) + @identity_timeout_ms

    with true <- Insider.Protocol.Value.bounded_list?(providers, 16),
         true <- Enum.all?(providers, &is_atom/1),
         identities <- Enum.map(providers, &{provider_identity(&1, deadline), &1}),
         true <- Enum.all?(identities, fn {identity, _provider} -> valid_identity?(identity) end),
         keys <- Enum.map(identities, fn {identity, _provider} -> provider_key(identity) end),
         true <- Enum.uniq(keys) == keys do
      {:ok,
       Map.new(identities, fn {identity, provider} -> {provider_key(identity), provider} end)}
    else
      _other -> :error
    end
  end

  defp body_map(bodies) do
    deadline = System.monotonic_time(:millisecond) + @identity_timeout_ms

    with true <- Insider.Protocol.Value.bounded_list?(bodies, 16),
         true <- Enum.all?(bodies, &is_atom/1),
         identities <- Enum.map(bodies, &{provider_identity(&1, deadline), &1}),
         true <- Enum.all?(identities, fn {identity, _body} -> valid_identity?(identity) end),
         keys <- Enum.map(identities, fn {identity, _body} -> provider_key(identity) end),
         true <- Enum.uniq(keys) == keys do
      {:ok, Map.new(identities, fn {identity, body} -> {body, identity} end)}
    else
      _other -> :error
    end
  end

  defp provider_identity(provider, deadline) do
    case ProviderCall.call(provider, :identity, [], deadline) do
      %{result: identity, termination: {:observed, _reason}} -> identity
      _untrusted -> :invalid
    end
  end

  defp valid_identity?(%{"id" => id, "version" => version} = identity),
    do:
      map_size(identity) == 2 and vocabulary?(id) and is_integer(version) and
        version in 1..1_000_000

  defp valid_identity?(_identity), do: false

  defp provider_key(%{"id" => id, "version" => version}), do: {id, version}
  defp provider_key(_identity), do: nil

  defp vocabulary?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp vocabulary?(_value), do: false

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_digest), do: false
end
