defmodule Insider.TestSupport.AcceptanceRunner do
  @moduledoc false

  @callback minimum_duration_ms(term()) :: pos_integer()
  @callback run(:faulty | :healthy, integer(), pid(), term()) ::
              {:ok, Insider.Fixtures.Observation.t()}
              | {:timeout, map(), [String.t()], non_neg_integer()}
end

defmodule Insider.TestSupport.AcceptanceFixtureRunner do
  @moduledoc false

  @behaviour Insider.TestSupport.AcceptanceRunner

  alias Insider.Fixtures

  # The leaked-task fixture has at most two sequential one-second waits. The
  # extra 100 ms is reserved for its unconditional cleanup path.
  @impl true
  def minimum_duration_ms(_configuration), do: 2_100

  @impl true
  def run(variant, _deadline, _dispatcher, _configuration),
    do: {:ok, Fixtures.run!(:leaked_task, variant)}
end

defmodule Insider.TestSupport.AcceptanceTimeoutRunner do
  @moduledoc false

  @behaviour Insider.TestSupport.AcceptanceRunner

  @cleanup_wait_ms 100

  @impl true
  def minimum_duration_ms(owner) when is_pid(owner), do: 1

  @impl true
  def run(_variant, deadline, dispatcher, owner)
      when is_integer(deadline) and is_pid(dispatcher) and is_pid(owner) do
    started_at = System.monotonic_time(:microsecond)
    host = self()
    resource = spawn(fn -> resource_loop(host) end)
    resource_monitor = Process.monitor(resource)
    dispatcher_monitor = Process.monitor(dispatcher)
    timer_ref = make_ref()
    remaining = max(0, deadline - System.monotonic_time(:millisecond)) + @cleanup_wait_ms
    timer = Process.send_after(self(), {:acceptance_runner_deadline, timer_ref}, remaining)

    send(owner, {:acceptance_work_started, self(), dispatcher, resource})

    receive do
      {:DOWN, ^dispatcher_monitor, :process, ^dispatcher, _reason} -> :ok
      {:acceptance_runner_deadline, ^timer_ref} -> :ok
    end

    cancel_timer(timer, timer_ref)
    Process.demonitor(dispatcher_monitor, [:flush])
    Process.exit(resource, :kill)

    cleanup =
      receive do
        {:DOWN, ^resource_monitor, :process, ^resource, _reason} -> %{status: :complete}
      after
        @cleanup_wait_ms -> %{status: :uncertain}
      end

    send(owner, {:acceptance_work_cleaned, self(), resource, cleanup.status})

    uncertainty =
      if cleanup.status == :complete,
        do: ["fixture reached its deadline after work began and cleanup completed"],
        else: ["fixture reached its deadline and resource termination was not confirmed"]

    duration_us = System.monotonic_time(:microsecond) - started_at
    {:timeout, cleanup, uncertainty, duration_us}
  end

  defp resource_loop(host) do
    host_monitor = Process.monitor(host)

    receive do
      :stop -> Process.demonitor(host_monitor, [:flush])
      {:DOWN, ^host_monitor, :process, ^host, _reason} -> :ok
    end
  end

  defp cancel_timer(timer, timer_ref) do
    if Process.cancel_timer(timer) == false do
      receive do
        {:acceptance_runner_deadline, ^timer_ref} -> :ok
      after
        0 -> :ok
      end
    end
  end
end

defmodule Insider.TestSupport.AcceptanceHost do
  @moduledoc false

  use GenServer

  alias Insider.Fixtures.Observation
  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Protocol.Value
  alias Insider.TestSupport.AcceptanceFixtureRunner

  @provider "insider.test_support.acceptance_host"
  @grant_lifetime_ms 60_000
  @maximum_heap_words 16_777_216
  @fixture "leaked_task"
  @variants ["faulty", "healthy"]
  @option_keys [:capability_reference, :runner]

  @type runner :: {module(), term()}
  @type state :: %{context: Context.t(), runner: runner(), minimum_duration_ms: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options,
      spawn_opt: [
        {:max_heap_size, %{size: @maximum_heap_words, kill: true, error_logger: false}}
      ]
    )
  end

  @doc "Returns a CLI dispatcher whose runtime owner outlives the calling worker."
  @spec dispatcher(GenServer.server()) :: (Request.t() -> Result.t())
  def dispatcher(host), do: &GenServer.call(host, {:dispatch, &1}, :infinity)

  @impl true
  def init(options) do
    with true <- valid_options?(options),
         capability_reference <- Keyword.fetch!(options, :capability_reference),
         runner <- Keyword.get(options, :runner, {AcceptanceFixtureRunner, nil}),
         {:ok, minimum_duration_ms} <- validate_runner(runner),
         {:ok, context} <- context(capability_reference) do
      {:ok, %{context: context, runner: runner, minimum_duration_ms: minimum_duration_ms}}
    else
      _invalid -> {:stop, :invalid_acceptance_host}
    end
  end

  @impl true
  def handle_call({:dispatch, %Request{} = request}, {dispatcher, _tag}, state) do
    result =
      case Policy.authorize(request, state.context) do
        {:ok, decision} -> dispatch_authorized(request, state, decision, dispatcher)
        {:error, %Error{} = error} -> Protocol.failure(request, error)
      end

    {:reply, result, state}
  end

  def handle_call(_request, _from, state), do: {:reply, :invalid_request, state}

  @impl true
  def handle_info({:acceptance_runner_deadline, _timer_ref}, state), do: {:noreply, state}

  defp context(capability_reference) do
    target = %{node: Atom.to_string(node())}

    with {:ok, grant} <-
           Grant.new(
             reference: capability_reference,
             audit_id: "phase-a-fixture-observation",
             scopes: ["scenario.execute"],
             target: target,
             expires_at_monotonic: System.monotonic_time(:millisecond) + @grant_lifetime_ms
           ) do
      Context.new(
        environment: :test,
        actor: "insider-phase-a-acceptance-host",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "runtime.capabilities" => %{
            available: true,
            provider: @provider,
            isolation: :read_only
          },
          "scenario.run" => %{
            available: true,
            provider: @provider,
            isolation: :session_local
          }
        }
      )
    end
  end

  defp dispatch_authorized(request, state, decision, dispatcher) do
    if Policy.dispatchable?(decision) do
      execute(request, state, decision, dispatcher)
    else
      timeout_before_start(request, decision, "authorization expired before dispatch")
    end
  end

  defp execute(
         %Request{operation: "runtime.capabilities"} = request,
         state,
         decision,
         _dispatcher
       ) do
    value = %{
      "schema" => "insider.capabilities/v1",
      "protocol" => Protocol.version(),
      "operations" => Policy.capabilities(state.context),
      "fixture_observation" => %{
        "operation" => "scenario.run",
        "params" => %{"fixture" => [@fixture], "variant" => @variants},
        "requires_capability" => true
      }
    }

    Protocol.success(request, value, result_options(decision, %{status: :not_required}, 0))
  end

  defp execute(%Request{operation: "scenario.run"} = request, state, decision, dispatcher) do
    case fixture_variant(request.params) do
      {:ok, variant} -> run_fixture(request, state, decision, variant, dispatcher)
      :error -> invalid_fixture_request(request, decision)
    end
  end

  defp execute(request, _state, _decision, _dispatcher),
    do: Protocol.unsupported(request, :acceptance_host_operation)

  defp run_fixture(request, state, decision, variant, dispatcher) do
    remaining = decision.dispatch_deadline_monotonic - System.monotonic_time(:millisecond)

    if Policy.dispatchable?(decision) and remaining > state.minimum_duration_ms do
      run_fixture_started(request, state.runner, decision, variant, dispatcher)
    else
      timeout_before_start(
        request,
        decision,
        "fixture was not started because its cleanup budget did not fit"
      )
    end
  end

  defp run_fixture_started(request, {runner, configuration}, decision, variant, dispatcher) do
    started_at = System.monotonic_time(:microsecond)

    case runner.run(variant, decision.dispatch_deadline_monotonic, dispatcher, configuration) do
      {:ok, %Observation{} = observation} ->
        duration_us = System.monotonic_time(:microsecond) - started_at
        finish_fixture(request, decision, observation, duration_us)

      {:timeout, cleanup, uncertainty, duration_us} ->
        Protocol.timeout(
          request,
          result_options(decision, cleanup, duration_us, uncertainty: uncertainty)
        )

      _invalid ->
        execution_failed(request, decision)
    end
  rescue
    _error -> execution_failed(request, decision)
  catch
    _kind, _reason -> execution_failed(request, decision)
  end

  defp execution_failed(request, decision) do
    Protocol.failure(
      request,
      Error.new(:operation_failed, "fixture execution failed"),
      result_options(decision, %{status: :uncertain}, 0,
        uncertainty: ["fixture cleanup could not be independently confirmed"]
      )
    )
  end

  defp finish_fixture(request, decision, %Observation{} = observation, duration_us) do
    alive_after_cleanup = Enum.count(observation.resources, &Process.alive?/1)
    event_count = length(observation.events)
    value = portable_observation(observation, alive_after_cleanup)

    cond do
      observation.cleanup.status != :complete or alive_after_cleanup != 0 ->
        Protocol.failure(
          request,
          Error.new(:operation_failed, "fixture cleanup was incomplete"),
          result_options(decision, %{status: :partial}, duration_us,
            consumption: consumption(value, event_count, duration_us),
            uncertainty: ["one or more fixture resources may remain alive"]
          )
        )

      event_count > decision.effective_limits.max_events or
          not Value.bounded_data?(value, decision.effective_limits.max_bytes) ->
        Protocol.failure(
          request,
          Error.new(:operation_failed, "fixture evidence exceeded limits"),
          result_options(decision, %{status: :complete}, duration_us,
            consumption: consumption(value, event_count, duration_us)
          )
        )

      true ->
        Protocol.success(
          request,
          value,
          result_options(decision, %{status: :complete}, duration_us,
            consumption: consumption(value, event_count, duration_us)
          )
        )
    end
  end

  defp portable_observation(observation, alive_after_cleanup) do
    %{
      "kind" => "fixture_observation",
      "run_id" => observation.run_id,
      "fixture" => Atom.to_string(observation.scenario),
      "variant" => Atom.to_string(observation.variant),
      "events" => Enum.map(observation.events, &portable_event/1),
      "samples" => observation.samples,
      "settled" => observation.settled,
      "resources" => %{
        "observed" => length(observation.resources),
        "alive_after_cleanup" => alive_after_cleanup
      }
    }
  end

  defp portable_event(event) do
    %{
      "sequence" => event.sequence,
      "kind" => Atom.to_string(event.kind),
      "monotonic_time" => event.monotonic_time,
      "metadata" => Map.get(event, :metadata, %{})
    }
  end

  defp fixture_variant(%{"fixture" => @fixture, "variant" => "faulty"} = params)
       when map_size(params) == 2,
       do: {:ok, :faulty}

  defp fixture_variant(%{"fixture" => @fixture, "variant" => "healthy"} = params)
       when map_size(params) == 2,
       do: {:ok, :healthy}

  defp fixture_variant(_params), do: :error

  defp invalid_fixture_request(request, decision) do
    error =
      Error.new(:invalid_request, "acceptance fixture request is not declared", %{
        fixture: @fixture,
        variants: @variants
      })

    Protocol.failure(request, error, result_options(decision, %{status: :not_required}, 0))
  end

  defp timeout_before_start(request, decision, uncertainty) do
    Protocol.timeout(
      request,
      result_options(decision, %{status: :not_required}, 0, uncertainty: [uncertainty])
    )
  end

  defp result_options(decision, cleanup, duration_us, options \\ []) do
    [
      effective_limits: decision.effective_limits,
      policy_fingerprint: decision.policy_fingerprint,
      cleanup: cleanup,
      duration_us: duration_us
    ]
    |> Keyword.merge(options)
  end

  defp consumption(value, event_count, duration_us) do
    %{
      evidence_bytes: :erlang.external_size(value),
      events: event_count,
      targets: 1,
      duration_us: duration_us
    }
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and Keyword.keys(options) -- @option_keys == [] and
      Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
      Keyword.has_key?(options, :capability_reference)
  end

  defp validate_runner({module, configuration}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :minimum_duration_ms, 1) and
         function_exported?(module, :run, 4) do
      case module.minimum_duration_ms(configuration) do
        duration when is_integer(duration) and duration in 1..60_000 -> {:ok, duration}
        _invalid -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp validate_runner(_runner), do: :error
end
