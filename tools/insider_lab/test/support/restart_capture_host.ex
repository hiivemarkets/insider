defmodule Insider.TestSupport.RestartCaptureRunner do
  @moduledoc false

  @callback minimum_duration_ms(term()) :: pos_integer()
  @callback run(
              :faulty | :healthy,
              Insider.Protocol.Request.t(),
              Insider.Policy.Decision.t(),
              Insider.Policy.Decision.t(),
              pid(),
              reference(),
              term()
            ) :: Insider.Incident.RestartCapture.result()
end

defmodule Insider.TestSupport.RestartCaptureFixtureRunner do
  @moduledoc false

  @behaviour Insider.TestSupport.RestartCaptureRunner

  alias Insider.Event
  alias Insider.Fixtures.RestartStorm.Owner, as: FixtureOwner
  alias Insider.Incident.ExportPolicy
  alias Insider.Incident.RestartCapture
  alias Insider.Incident.RestartCapture.Owner, as: CaptureOwner
  alias Insider.Protocol.Error
  alias Insider.Provenance
  alias Insider.Redaction.Policy, as: RedactionPolicy

  @max_events 16
  @max_bytes 262_144
  @observer_effect "synchronous_fixture_lifecycle_projection"

  @impl true
  def minimum_duration_ms(configuration) when is_pid(configuration), do: 1
  def minimum_duration_ms(_configuration), do: 2_100

  @impl true
  def run(variant, request, capture, export, dispatcher, lease, configuration) do
    observer = if is_pid(configuration), do: configuration
    run_id = System.unique_integer([:positive, :monotonic])
    started_at = System.monotonic_time(:microsecond)

    {:ok, fixture_owner, token} =
      FixtureOwner.start(run_id, variant, observer: self())

    fixture_monitor = Process.monitor(fixture_owner)
    dispatcher_monitor = Process.monitor(dispatcher)

    receive do
      {:restart_storm_ready, ^token, ^fixture_owner, resources} ->
        notify(
          observer,
          {:capture_work_started, request.request_id, lease, fixture_owner, resources}
        )

        begun = is_nil(observer)
        if begun, do: send(fixture_owner, {:begin, token})

        await_fixture(%{
          begun: begun,
          capture: capture,
          configuration: configuration,
          dispatcher: dispatcher,
          dispatcher_monitor: dispatcher_monitor,
          export: export,
          fixture_monitor: fixture_monitor,
          fixture_owner: fixture_owner,
          lease: lease,
          observer: observer,
          request: request,
          capture_pids: MapSet.new(),
          capture_slots: MapSet.new(),
          resources: add_resources(MapSet.new([fixture_owner]), resources),
          started_at: started_at,
          token: token,
          variant: variant
        })
    end
  end

  defp await_fixture(state) do
    receive do
      {:restart_storm_resource, token, resource, kind} when token == state.token ->
        notify(state.observer, {:capture_resource, state.lease, resource, kind})
        await_fixture(track(state, resource))

      {:continue_capture, lease} when lease == state.lease and not state.begun ->
        send(state.fixture_owner, {:begin, state.token})
        await_fixture(%{state | begun: true})

      {:restart_storm_complete, token, observation, %{status: :complete}}
      when token == state.token ->
        state = %{state | resources: add_resources(state.resources, observation.resources)}
        await_fixture_down(observation, state)

      {:cancel_capture, lease} when lease == state.lease ->
        stop_fixture(:cancelled, state)

      {:dispatcher_down, lease} when lease == state.lease ->
        stop_fixture(:timeout, state)

      {:DOWN, monitor, :process, dispatcher, _reason}
      when monitor == state.dispatcher_monitor and dispatcher == state.dispatcher ->
        stop_fixture(:timeout, state)

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.fixture_monitor and owner == state.fixture_owner ->
        fixture_failed(state)
    after
      max(0, state.export.dispatch_deadline_monotonic - System.monotonic_time(:millisecond)) ->
        stop_fixture(:timeout, state)
    end
  end

  defp stop_fixture(status, state) do
    send(state.fixture_owner, {:cancel, state.token})

    receive do
      {:restart_storm_stopped, token, _owner_status, resources, cleanup}
      when token == state.token ->
        state = %{state | resources: add_resources(state.resources, resources)}
        {cleanup, state} = confirm_fixture_owner_down(state, cleanup)
        finish_lifecycle(status, cleanup, state)

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.fixture_monitor and owner == state.fixture_owner ->
        finish_lifecycle(status, %{status: :uncertain}, state)
    after
      1_100 -> finish_lifecycle(status, %{status: :uncertain}, state)
    end
  end

  defp finish_lifecycle(status, cleanup, state) do
    Process.demonitor(state.dispatcher_monitor, [:flush])
    accounting = lifecycle_accounting(cleanup, state)
    notify_cleaned(state, accounting)
    {status, accounting}
  end

  defp confirm_fixture_owner_down(state, cleanup) do
    receive do
      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.fixture_monitor and owner == state.fixture_owner ->
        {cleanup, state}
    after
      100 ->
        Process.demonitor(state.fixture_monitor, [:flush])
        {%{status: :uncertain}, state}
    end
  end

  defp await_fixture_down(observation, state) do
    receive do
      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.fixture_monitor and owner == state.fixture_owner ->
        start_capture(observation, state)
    after
      100 -> fixture_failed(state)
    end
  end

  defp start_capture(observation, state) do
    options =
      capture_options(
        observation,
        state.capture,
        state.export,
        state.request,
        state.configuration
      )

    case RestartCapture.start_async(project(observation), options, state.started_at) do
      {:ok, owner, reference} ->
        capture_monitor = Process.monitor(owner)
        notify(state.observer, {:capture_resource, state.lease, owner, {:capture, :owner}})

        await_capture(
          Map.merge(state, %{
            capture_monitor: capture_monitor,
            capture_owner: owner,
            capture_pids: MapSet.put(state.capture_pids, owner),
            capture_reference: reference,
            capture_slots: MapSet.put(state.capture_slots, :owner),
            capture_started: false,
            pending_resource_ack: nil,
            resources: MapSet.put(state.resources, owner),
            terminal: nil
          })
        )

      outcome ->
        finish_command(outcome, state)
    end
  end

  defp await_capture(state) do
    receive do
      {:capture_owner_started, reference, owner}
      when reference == state.capture_reference and owner == state.capture_owner ->
        if state.terminal do
          CaptureOwner.cancel(owner, reference)
        else
          CaptureOwner.admit(owner, reference)
        end

        await_capture(state)

      {:capture_resource_reserved, reference, kind}
      when reference == state.capture_reference ->
        notify(
          state.observer,
          {:capture_resource_reserved, state.lease, {:capture, kind}}
        )

        await_capture(%{state | capture_slots: MapSet.put(state.capture_slots, kind)})

      {:capture_resource, reference, resource, kind}
      when reference == state.capture_reference ->
        state =
          state
          |> track(resource)
          |> Map.update!(:capture_pids, &MapSet.put(&1, resource))
          |> Map.update!(:capture_slots, &MapSet.put(&1, kind))

        notify(state.observer, {:capture_resource, state.lease, resource, {:capture, kind}})

        acknowledge? = kind == :recorder and is_nil(state.observer) and is_nil(state.terminal)

        if acknowledge?,
          do: CaptureOwner.acknowledge(state.capture_owner, reference, kind, resource)

        execute? =
          kind == :worker and is_nil(state.observer) and is_nil(state.terminal) and
            not state.capture_started

        if execute?, do: CaptureOwner.execute(state.capture_owner, state.capture_reference)

        pending_resource_ack =
          if kind == :recorder and not acknowledge?, do: {:recorder, resource}, else: nil

        await_capture(%{
          state
          | capture_started: state.capture_started or execute?,
            pending_resource_ack: pending_resource_ack
        })

      {:capture_owner_ready, reference, owner}
      when reference == state.capture_reference and owner == state.capture_owner ->
        if state.terminal do
          CaptureOwner.cancel(owner, reference)
        else
          CaptureOwner.begin(owner, reference)
        end

        await_capture(state)

      {:continue_capture, lease} when lease == state.lease and not state.capture_started ->
        case state.pending_resource_ack do
          {:recorder, recorder} ->
            CaptureOwner.acknowledge(
              state.capture_owner,
              state.capture_reference,
              :recorder,
              recorder
            )

            await_capture(%{state | pending_resource_ack: nil})

          nil ->
            CaptureOwner.execute(state.capture_owner, state.capture_reference)
            await_capture(%{state | capture_started: true})
        end

      {:capture_result, reference, outcome} when reference == state.capture_reference ->
        await_capture_down(outcome, state)

      {:cancel_capture, lease} when lease == state.lease ->
        CaptureOwner.cancel(state.capture_owner, state.capture_reference)
        await_capture(%{state | terminal: :cancelled})

      {:dispatcher_down, lease} when lease == state.lease ->
        CaptureOwner.cancel(state.capture_owner, state.capture_reference)
        await_capture(%{state | terminal: :timeout})

      {:DOWN, monitor, :process, dispatcher, _reason}
      when monitor == state.dispatcher_monitor and dispatcher == state.dispatcher ->
        CaptureOwner.cancel(state.capture_owner, state.capture_reference)
        await_capture(%{state | terminal: :timeout})

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.capture_monitor and owner == state.capture_owner ->
        capture_failed(state)
    after
      remaining_ms(state) ->
        CaptureOwner.cancel(state.capture_owner, state.capture_reference)
        await_capture(%{state | terminal: :timeout})
    end
  end

  defp await_capture_down(outcome, state) do
    receive do
      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.capture_monitor and owner == state.capture_owner ->
        outcome = terminal_outcome(state.terminal, outcome)
        finish_command(outcome, state)
    after
      100 ->
        Process.exit(state.capture_owner, :kill)

        receive do
          {:DOWN, monitor, :process, owner, _reason}
          when monitor == state.capture_monitor and owner == state.capture_owner ->
            finish_command(mark_uncertain(outcome), state)
        after
          100 -> capture_failed(state)
        end
    end
  end

  defp finish_command(outcome, state) do
    Process.demonitor(state.dispatcher_monitor, [:flush])
    outcome = account_command(outcome, state)
    notify_cleaned(state, accounting(outcome))
    outcome
  end

  defp fixture_failed(state) do
    accounting = lifecycle_accounting(%{status: :uncertain}, state)
    Process.demonitor(state.dispatcher_monitor, [:flush])
    notify_cleaned(state, accounting)

    {:error, Error.new(:operation_failed, "restart fixture owner failed"), accounting}
  end

  defp capture_failed(state) do
    accounting = lifecycle_accounting(%{status: :uncertain}, state)
    Process.demonitor(state.dispatcher_monitor, [:flush])
    notify_cleaned(state, accounting)
    {:error, Error.new(:operation_failed, "restart capture owner failed"), accounting}
  end

  defp lifecycle_accounting(cleanup, state) do
    {resource_pids, resources, unmaterialized} = command_resource_counts(state)

    %{
      cleanup: cleanup,
      consumption: %{
        capsule_bytes: 0,
        duration_us: elapsed(state),
        events: 0,
        resource_pids: resource_pids,
        resources: resources,
        unmaterialized_resource_slots: unmaterialized
      },
      loss: %{counters: %{}, gaps: []},
      observer_effect: @observer_effect,
      truncation: %{dropped_events: 0, status: :none}
    }
  end

  defp account_command({:ok, capsules, accounting}, state),
    do: {:ok, capsules, update_accounting(accounting, state)}

  defp account_command({:error, %Error{} = error, accounting}, state),
    do: {:error, error, update_accounting(accounting, state)}

  defp account_command({status, accounting}, state) when status in [:timeout, :cancelled],
    do: {status, update_accounting(accounting, state)}

  defp update_accounting(accounting, state) do
    {resource_pids, resources, unmaterialized} = command_resource_counts(state, accounting)

    %{
      accounting
      | consumption:
          Map.merge(accounting.consumption, %{
            duration_us: elapsed(state),
            resource_pids: resource_pids,
            resources: resources,
            unmaterialized_resource_slots: unmaterialized
          })
    }
  end

  defp command_resource_counts(state, inner_accounting \\ nil) do
    inner = if inner_accounting, do: inner_accounting.consumption, else: %{}
    observed_capture_pids = MapSet.size(state.capture_pids)
    inner_capture_pids = Map.get(inner, :resource_pids, 0)
    capture_pids = max(observed_capture_pids, inner_capture_pids)
    unobserved_capture_pids = capture_pids - observed_capture_pids
    resource_pids = MapSet.size(state.resources) + unobserved_capture_pids
    capture_slots = max(MapSet.size(state.capture_slots), Map.get(inner, :resources, 0))
    unmaterialized = max(0, capture_slots - capture_pids)
    {resource_pids, resource_pids + unmaterialized, unmaterialized}
  end

  defp terminal_outcome(nil, outcome), do: outcome
  defp terminal_outcome(status, {_outcome_status, accounting}), do: {status, accounting}
  defp terminal_outcome(status, {:ok, _capsules, accounting}), do: {status, accounting}
  defp terminal_outcome(status, {:error, _error, accounting}), do: {status, accounting}

  defp mark_uncertain({:ok, capsules, accounting}),
    do: {:ok, capsules, %{accounting | cleanup: %{status: :uncertain}}}

  defp mark_uncertain({:error, error, accounting}),
    do: {:error, error, %{accounting | cleanup: %{status: :uncertain}}}

  defp mark_uncertain({status, accounting}),
    do: {status, %{accounting | cleanup: %{status: :uncertain}}}

  defp accounting({:ok, _capsules, accounting}), do: accounting
  defp accounting({:error, _error, accounting}), do: accounting
  defp accounting({_status, accounting}), do: accounting

  defp notify_cleaned(state, accounting) do
    notify(
      state.observer,
      {:capture_work_cleaned, state.lease, MapSet.to_list(state.resources),
       accounting.cleanup.status}
    )
  end

  defp track(state, resource), do: %{state | resources: MapSet.put(state.resources, resource)}

  defp add_resources(resources, additions),
    do: Enum.reduce(additions, resources, &MapSet.put(&2, &1))

  defp elapsed(state), do: System.monotonic_time(:microsecond) - state.started_at

  defp remaining_ms(state) do
    max(0, state.export.dispatch_deadline_monotonic - System.monotonic_time(:millisecond))
  end

  defp notify(owner, message) when is_pid(owner), do: send(owner, message)
  defp notify(_owner, _message), do: :ok

  @doc false
  def project(observation) do
    workers = Enum.drop(observation.resources, 2)

    observation.events
    |> Enum.filter(&(&1.kind == :worker_crashed))
    |> Enum.map(fn measured ->
      generation = measured.metadata.generation
      pid = workers |> Enum.at(generation - 1) |> :erlang.pid_to_list() |> to_string()
      observed_at = measured.monotonic_time |> System.convert_time_unit(:native, :microsecond)

      event =
        Event.new!(
          id: "restart-#{observation.run_id}-#{generation}",
          node: Atom.to_string(node()),
          boot_id: "fixture-boot-#{observation.run_id}",
          source: "logger",
          kind: "supervisor_child_terminated",
          severity: :error,
          monotonic_time: generation,
          clock_id: "fixture-lifecycle-order",
          source_instance_id: "restart-fixture-#{observation.run_id}",
          source_sequence: generation,
          wall_time: nil,
          subject: nil,
          causality: %{
            trace_id: nil,
            span_id: nil,
            parent_event_id: nil,
            logical_operation_id: "restart-fixture-#{observation.run_id}",
            process_generation: Integer.to_string(generation)
          },
          attributes: %{
            "domain" => ["otp", "sasl"],
            "label" => "supervisor.child_terminated",
            "message_type" => "report",
            "offender_id" => "Elixir.Insider.Fixtures.RestartStorm.Worker",
            "offender_pid" => pid,
            "reason_class" => "abnormal",
            "reason_fingerprint" => reason_fingerprint(),
            "restart_type" => "permanent",
            "semantic_projection" => "otp_supervisor/v1",
            "supervisor" => "Elixir.Insider.Fixtures.RestartStorm",
            "termination_context" => "child_terminated"
          },
          payload: %{"fixture_secret" => "must-not-export"},
          authority: "trusted-test-fixture-projector/v1",
          redactions: [],
          extensions: %{}
        )

      {event, observed_at}
    end)
  end

  @doc false
  def capture_options(observation, capture, export, _request, configuration \\ nil) do
    alive = Enum.count(observation.resources, &Process.alive?/1)

    [
      authority: [
        capture_audit_id: capture.grant_audit_id,
        export_audit_id: export.grant_audit_id
      ],
      deadline_monotonic_ms: export.dispatch_deadline_monotonic,
      export_policy: export_policy!(configuration),
      max_bytes: @max_bytes,
      max_events: @max_events,
      observer_effect: @observer_effect,
      provenance:
        provenance!(
          observation.variant,
          observation.cleanup.status,
          length(observation.resources),
          alive
        )
    ]
  end

  @doc false
  def capture_options(observation, deadline, _request_id) do
    alive = Enum.count(observation.resources, &Process.alive?/1)

    [
      authority: [capture_audit_id: "direct-capture", export_audit_id: "direct-export"],
      deadline_monotonic_ms: deadline,
      export_policy: export_policy!(nil),
      max_bytes: @max_bytes,
      max_events: @max_events,
      observer_effect: @observer_effect,
      provenance:
        provenance!(
          observation.variant,
          observation.cleanup.status,
          length(observation.resources),
          alive
        )
    ]
  end

  defp provenance!(variant, cleanup, resource_count, alive) do
    {:ok, provenance} =
      Provenance.capture(
        code: {:unavailable, :not_built},
        dependencies: {:unavailable, :not_built},
        configuration:
          {:available,
           %{
             "byte_budget" => @max_bytes,
             "event_budget" => @max_events,
             "observer_effect" => @observer_effect,
             "projection" => "measured_restart_fixture/v1",
             "resource_budget" => 10
           }},
        target:
          {:available,
           %{
             "alive_after_fixture_cleanup" => alive,
             "class" => "test_disposable",
             "fixture" => "restart_storm",
             "fixture_cleanup" => Atom.to_string(cleanup),
             "fixture_resources_observed" => resource_count,
             "variant" => Atom.to_string(variant)
           }}
      )

    provenance
  end

  defp export_policy!(configuration) do
    {:ok, redaction_policy} =
      RedactionPolicy.new(
        id: "phase-b-restart-capture",
        maximum_sensitivity: :internal,
        rules: [
          [
            id: "fixture-secret",
            path: ["payload", "fixture_secret"],
            sensitivity: :secret,
            action: :mask
          ]
        ],
        max_nodes: 16_384,
        max_input_bytes: 1_048_576,
        max_output_bytes: 1_048_576,
        max_duration_ms: 2_000
      )

    {:ok, export_policy} =
      ExportPolicy.new(
        redaction_policy,
        [
          finding: if(configuration == :reject_export, do: :secret, else: :internal),
          snapshot: :internal,
          event: :internal,
          provenance: :internal,
          authority: :internal,
          artifacts: :internal
        ],
        max_duration_ms: 2_000
      )

    export_policy
  end

  defp reason_fingerprint do
    :crypto.hash(:sha256, "fixture_crash") |> Base.encode16(case: :lower)
  end
end

defmodule Insider.TestSupport.RestartCaptureImmediateRunner do
  @moduledoc false

  @behaviour Insider.TestSupport.RestartCaptureRunner

  @impl true
  def minimum_duration_ms(owner) when is_pid(owner), do: 1
  def minimum_duration_ms({owner, :crash}) when is_pid(owner), do: 1

  @impl true
  def run(_variant, request, _capture, _export, _dispatcher, _lease, {owner, :crash}) do
    send(owner, {:immediate_capture_crash, request.request_id})
    exit(:injected_lease_crash)
  end

  def run(_variant, request, _capture, _export, _dispatcher, _lease, owner) do
    send(owner, {:immediate_capture_run, request.idempotency_key})

    {:ok, [],
     %{
       cleanup: %{status: :not_required},
       consumption: %{capsule_bytes: 0, duration_us: 1, events: 0, resources: 0},
       loss: %{counters: %{}, gaps: []},
       observer_effect: "none",
       truncation: %{dropped_events: 0, status: :none}
     }}
  end
end

defmodule Insider.TestSupport.RestartCaptureHost do
  @moduledoc false

  use GenServer

  alias Insider.Event.Canonical
  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.TestSupport.RestartCaptureFixtureRunner

  @provider "insider.test_support.restart_capture_host"
  @fixture "restart_storm"
  @variants ["faulty", "healthy"]
  @max_duration_ms 3_000
  @max_events 16
  @max_bytes 262_144
  @resource_budget 10
  @cache_entries 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @spec dispatcher(GenServer.server()) :: (Request.t() -> Result.t())
  def dispatcher(host), do: &GenServer.call(host, {:dispatch, &1}, :infinity)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    capture_reference = Keyword.fetch!(options, :capability_reference)
    export_reference = Keyword.get(options, :export_capability_reference, "phase-b-export")
    runner = Keyword.get(options, :runner, {RestartCaptureFixtureRunner, nil})

    with {:ok, minimum_duration_ms} <- validate_runner(runner),
         {:ok, capture_grant} <- grant(capture_reference, "phase-b-capture", "incident.capture"),
         {:ok, export_grant} <- grant(export_reference, "phase-b-export", "incident.export"),
         {:ok, context} <-
           Context.new(
             environment: :test,
             actor: "insider-phase-b-acceptance-host",
             target_class: :disposable,
             grants: [capture_grant, export_grant],
             deployment_limits: %{
               max_duration_ms: @max_duration_ms,
               max_events: @max_events,
               max_bytes: @max_bytes,
               max_targets: 1
             },
             features: %{
               "incident.capture" => %{
                 available: true,
                 provider: @provider,
                 isolation: :session_local
               },
               "incident.export" => %{
                 available: true,
                 provider: @provider,
                 isolation: :session_local
               }
             }
           ) do
      {:ok,
       %{
         cache: %{},
         context: context,
         export_reference: export_reference,
         minimum_duration_ms: minimum_duration_ms,
         lease: nil,
         runner: runner
       }}
    else
      _invalid -> {:stop, :invalid_restart_capture_host}
    end
  end

  @impl true
  def handle_call({:dispatch, %Request{} = request}, _from, %{lease: lease} = state)
      when not is_nil(lease) do
    {:reply, overloaded(request), state}
  end

  def handle_call({:dispatch, %Request{} = request}, {dispatcher, _tag} = from, state) do
    case authorize_dispatch(request, state) do
      {:reply, result} ->
        {:reply, result, state}

      {:run, variant, capture, export} ->
        {:noreply, start_lease(request, variant, capture, export, dispatcher, from, state)}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, :invalid_request, state}

  @impl true
  def handle_info({:capture_lease_outcome, reference, worker, outcome}, state) do
    case state.lease do
      %{reference: ^reference, worker: ^worker} = lease ->
        {:noreply, %{state | lease: %{lease | outcome: outcome}}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, worker, reason}, state) do
    case state.lease do
      %{worker_monitor: ^monitor, worker: ^worker} = lease -> finish_lease(lease, reason, state)
      %{caller_monitor: ^monitor, dispatcher: ^worker} = lease -> caller_gone(lease, state)
      _other -> {:noreply, state}
    end
  end

  def handle_info({:cancel_capture, lease_reference}, state) do
    case state.lease do
      %{reference: ^lease_reference, worker: worker} ->
        send(worker, {:cancel_capture, lease_reference})

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:continue_capture, lease_reference}, state) do
    case state.lease do
      %{reference: ^lease_reference, worker: worker} ->
        send(worker, {:continue_capture, lease_reference})

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lease: %{worker: worker}}) do
    Process.exit(worker, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp authorize_dispatch(request, state) do
    with {:ok, variant} <- capture_variant(request),
         {:ok, capture} <- Policy.authorize(request, state.context),
         true <- Policy.dispatchable?(capture),
         true <- sufficient_budget?(capture.effective_limits, state.minimum_duration_ms),
         {:ok, export_request} <- export_request(request, state.export_reference),
         {:ok, export} <- Policy.authorize(export_request, state.context),
         true <- Policy.dispatchable?(export),
         {:ok, disposition} <- cache_disposition(request, state.cache) do
      case disposition do
        {:cached, outcome} -> {:reply, success(request, capture, export, variant, outcome, true)}
        :new -> {:run, variant, capture, export}
      end
    else
      {:error, %Error{} = error} -> {:reply, Protocol.failure(request, error)}
      false -> {:reply, Protocol.timeout(request, cleanup: %{status: :not_required})}
      :error -> {:reply, invalid_request(request)}
    end
  end

  defp start_lease(request, variant, capture, export, dispatcher, from, state) do
    {module, configuration} = state.runner
    host = self()
    reference = make_ref()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          outcome =
            module.run(
              variant,
              request,
              capture,
              export,
              dispatcher,
              reference,
              configuration
            )

          send(host, {:capture_lease_outcome, reference, self(), outcome})
        end,
        [:link, :monitor]
      )

    lease = %{
      caller_monitor: Process.monitor(dispatcher),
      capture: capture,
      dispatcher: dispatcher,
      export: export,
      from: from,
      outcome: nil,
      reference: reference,
      request: request,
      variant: variant,
      worker: worker,
      worker_monitor: worker_monitor
    }

    %{state | lease: lease}
  end

  defp finish_lease(%{outcome: nil} = lease, _reason, state) do
    reply_if_live(lease, execution_failed(lease.request, lease.capture))
    {:noreply, release_lease(state, lease)}
  end

  defp finish_lease(lease, _reason, state) do
    result =
      protocol_result(
        lease.request,
        lease.capture,
        lease.export,
        lease.variant,
        lease.outcome
      )

    state =
      case lease.outcome do
        {:ok, _capsules, _accounting} -> cache_success(state, lease.request, lease.outcome)
        _outcome -> state
      end

    reply_if_live(lease, result)
    {:noreply, release_lease(state, lease)}
  end

  defp caller_gone(lease, state) do
    send(lease.worker, {:dispatcher_down, lease.reference})
    {:noreply, %{state | lease: %{lease | caller_monitor: nil, dispatcher: nil, from: nil}}}
  end

  defp reply_if_live(%{from: nil}, _result), do: :ok
  defp reply_if_live(%{from: from}, result), do: GenServer.reply(from, result)

  defp release_lease(state, lease) do
    if lease.caller_monitor, do: Process.demonitor(lease.caller_monitor, [:flush])
    notify_lease_released(state.runner, lease.request.request_id)
    %{state | lease: nil}
  end

  defp notify_lease_released({RestartCaptureFixtureRunner, owner}, request_id)
       when is_pid(owner),
       do: send(owner, {:capture_lease_released, request_id})

  defp notify_lease_released(_runner, _request_id), do: :ok

  defp protocol_result(request, capture, export, variant, outcome) do
    case outcome do
      {:ok, _capsules, _accounting} ->
        success(request, capture, export, variant, outcome, false)

      {:timeout, accounting} ->
        Protocol.timeout(request, result_options(capture, accounting))

      {:cancelled, accounting} ->
        Protocol.cancelled(request, result_options(capture, accounting))

      {:error, %Error{} = error, accounting} ->
        Protocol.failure(request, error, result_options(capture, accounting))
    end
  end

  defp success(request, capture, export, variant, {:ok, capsules, accounting}, cached) do
    value = %{
      "schema" => "insider.restart-capture-result/v1",
      "fixture" => @fixture,
      "variant" => Atom.to_string(variant),
      "capsules" => Enum.map(capsules, &capsule_bytes!/1),
      "capsule_ids" => Enum.map(capsules, & &1.id),
      "deduplicated_retry" => cached,
      "authorization" => %{
        "capture_audit_id" => capture.grant_audit_id,
        "capture_decision_id" => Policy.audit(capture).decision_id,
        "export_audit_id" => export.grant_audit_id,
        "export_decision_id" => Policy.audit(export).decision_id
      },
      "evidence" => portable_accounting(accounting),
      "fixed_budgets" => %{
        "max_bytes" => @max_bytes,
        "max_duration_ms" => @max_duration_ms,
        "max_events" => @max_events,
        "max_resources" => @resource_budget,
        "max_idempotency_entries" => @cache_entries
      }
    }

    effects =
      if cached,
        do: [],
        else: [Effect.new(:fixture_executed, @fixture, details: %{"variant" => value["variant"]})]

    options =
      if cached,
        do: cached_result_options(capture, capsules),
        else: result_options(capture, accounting, effects: effects)

    Protocol.success(request, value, options)
  end

  defp cached_result_options(decision, capsules) do
    capsule_bytes =
      Enum.reduce(capsules, 0, fn capsule, total ->
        total + byte_size(capsule_bytes!(capsule))
      end)

    [
      cleanup: %{status: :not_required},
      confidence: :medium,
      consumption: %{capsule_bytes: capsule_bytes, duration_us: 0, events: 0, resources: 0},
      dropped: %{},
      duration_us: 0,
      effective_limits: decision.effective_limits,
      policy_fingerprint: decision.policy_fingerprint,
      uncertainty: []
    ]
  end

  defp result_options(decision, accounting, additional \\ []) do
    consumption = Map.delete(accounting.consumption, :recorder_status)

    [
      cleanup: accounting.cleanup,
      confidence: :medium,
      consumption: consumption,
      dropped: %{
        evidence_events: accounting.truncation.dropped_events,
        recorder: accounting.loss.counters
      },
      duration_us: consumption.duration_us,
      effective_limits: decision.effective_limits,
      policy_fingerprint: decision.policy_fingerprint,
      uncertainty: uncertainty(accounting)
    ]
    |> Keyword.merge(additional)
  end

  defp portable_accounting(accounting) do
    %{
      "cleanup" => %{"status" => Atom.to_string(accounting.cleanup.status)},
      "consumption" => portable_map(Map.delete(accounting.consumption, :recorder_status)),
      "loss" => %{
        "counters" => portable_map(accounting.loss.counters),
        "gaps" => Enum.map(accounting.loss.gaps, &Atom.to_string/1)
      },
      "observer_effect" => accounting.observer_effect,
      "truncation" => portable_map(accounting.truncation)
    }
  end

  defp portable_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), portable_value(value)} end)

  defp portable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp portable_value(value), do: value

  defp capsule_bytes!(capsule) do
    {:ok, bytes} = Insider.Incident.Capsule.canonical_binary(capsule)
    bytes
  end

  defp uncertainty(%{cleanup: %{status: :complete}}), do: []
  defp uncertainty(_accounting), do: ["capture resource cleanup was not confirmed"]

  defp capture_variant(%Request{
         operation: "incident.capture",
         idempotency_key: key,
         params: params
       })
       when is_binary(key) do
    case params do
      %{"fixture" => @fixture, "variant" => "faulty"} when map_size(params) == 2 ->
        {:ok, :faulty}

      %{"fixture" => @fixture, "variant" => "healthy"} when map_size(params) == 2 ->
        {:ok, :healthy}

      _invalid ->
        :error
    end
  end

  defp capture_variant(_request), do: :error

  defp cache_disposition(request, cache) do
    fingerprint = intent_fingerprint(request)

    case Map.get(cache, request.idempotency_key) do
      nil when map_size(cache) < @cache_entries ->
        {:ok, :new}

      nil ->
        {:error,
         Error.new(
           :operation_failed,
           "idempotency cache is at fixed capacity",
           %{
             reason: "overloaded"
           },
           retryable: true
         )}

      {^fingerprint, outcome} ->
        {:ok, {:cached, outcome}}

      {_other, _outcome} ->
        {:error, Error.new(:invalid_request, "idempotency key conflict")}
    end
  end

  defp cache_success(%{cache: cache} = state, request, outcome) do
    entry = {intent_fingerprint(request), outcome}
    %{state | cache: Map.put(cache, request.idempotency_key, entry)}
  end

  defp intent_fingerprint(request) do
    %{
      "budget" => Map.from_struct(request.budget),
      "operation" => request.operation,
      "params" => request.params,
      "target" => request.target
    }
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp export_request(request, export_reference) do
    Protocol.request("incident.export",
      request_id: request.request_id <> ":export",
      environment: request.environment,
      timeout_ms: max(1, request.deadline_monotonic - System.monotonic_time(:millisecond)),
      budget: Map.from_struct(request.budget),
      caller: "trusted-restart-capture-host",
      capability: export_reference,
      idempotency_key: request.idempotency_key,
      redaction_policy: request.redaction_policy,
      target: request.target
    )
  end

  defp grant(reference, audit_id, scope) do
    Grant.new(
      reference: reference,
      audit_id: audit_id,
      scopes: [scope],
      target: %{node: Atom.to_string(node())},
      expires_at_monotonic: System.monotonic_time(:millisecond) + 60_000
    )
  end

  defp validate_runner({module, configuration}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :minimum_duration_ms, 1) and
         function_exported?(module, :run, 7) do
      case module.minimum_duration_ms(configuration) do
        duration when is_integer(duration) and duration in 1..2_500 -> {:ok, duration}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp validate_runner(_runner), do: :error

  defp sufficient_budget?(limits, minimum_duration_ms),
    do:
      limits.max_duration_ms >= minimum_duration_ms and limits.max_events >= @max_events and
        limits.max_bytes >= @max_bytes

  defp invalid_request(request) do
    Protocol.failure(
      request,
      Error.new(:invalid_request, "restart capture request is not declared", %{
        fixture: @fixture,
        variants: @variants
      })
    )
  end

  defp execution_failed(request, decision) do
    Protocol.failure(
      request,
      Error.new(:operation_failed, "restart capture runner failed"),
      effective_limits: decision.effective_limits,
      cleanup: %{status: :uncertain},
      uncertainty: ["capture resource cleanup was not confirmed"]
    )
  end

  defp overloaded(request) do
    Protocol.failure(
      request,
      Error.new(
        :operation_failed,
        "restart capture host is at fixed capacity",
        %{
          reason: "overloaded"
        },
        retryable: true
      ),
      cleanup: %{status: :not_required}
    )
  end
end
