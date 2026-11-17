defmodule Insider.TestSupport.BisectionProviders do
  @moduledoc """
  Eight distinct sandbox provider identities sharing the capsule provenance.

  Confirmation binds every target's five prerequisite fingerprints to the
  manifest, so an ordered bisection list in the Lab differs by provider
  identity; each identity stands for one host-prepared disposable target.

  `raise_on_acquire/1` arms one declared target, by id, so that its provider
  raises after acquisition is recorded. Target ids embed the capsule
  provenance, so the seam never leaks across concurrently running tests.
  """

  @provider_id "test.bisection-sandbox"
  @versions 1..8

  @spec identity(pos_integer()) :: map()
  def identity(version) when version in @versions,
    do: %{"id" => @provider_id, "version" => version}

  @spec modules() :: [module()]
  def modules, do: Enum.map(@versions, &module/1)

  @spec module(pos_integer()) :: module()
  def module(version) when version in @versions,
    do: Module.concat(Insider.TestSupport, "BisectionSandboxProvider#{version}")

  @spec raise_on_acquire(String.t()) :: :ok
  def raise_on_acquire(target_id), do: :persistent_term.put({__MODULE__, target_id}, :raise)

  @spec disarm(String.t()) :: boolean()
  def disarm(target_id), do: :persistent_term.erase({__MODULE__, target_id})

  @doc false
  @spec acquire(binary(), Insider.Sentinel.Sandbox.Target.t(), integer()) ::
          :ok | {:error, atom()}
  def acquire(owner_id, target, deadline) do
    result = Insider.TestSupport.ConfirmationProvider.acquire(owner_id, target, deadline)

    if :persistent_term.get({__MODULE__, target.id}, nil) == :raise,
      do: raise("controlled bisection provider failure"),
      else: result
  end
end

for version <- 1..8 do
  defmodule Module.concat(Insider.TestSupport, "BisectionSandboxProvider#{version}") do
    @behaviour Insider.Sentinel.Sandbox.Provider

    alias Insider.TestSupport.ConfirmationProvider

    @version version

    @impl true
    def identity, do: %{"id" => "test.bisection-sandbox", "version" => @version}

    @impl true
    defdelegate acquire(owner_id, target, deadline), to: Insider.TestSupport.BisectionProviders

    @impl true
    defdelegate observe(owner_id, deadline), to: ConfirmationProvider

    @impl true
    defdelegate cleanup(owner_id, deadline), to: ConfirmationProvider

    @impl true
    defdelegate inventory(owner_id, deadline), to: ConfirmationProvider
  end
end

defmodule Insider.TestSupport.BisectionBody do
  @moduledoc """
  Reproduces the incident on declared provider versions chosen per seed.

  The plan lives in `:persistent_term` under the scenario seed. A plan with
  `reproducing_versions` reproduces on exactly that set, which may be
  nonmonotonic; otherwise targets whose provider version is at least
  `flip_version` reproduce. A target whose version equals
  `nondeterministic_version` alternates per run.

  Optional exit-path controls, each keyed by provider version:

    * `inconclusive: {version, mode}` runs the confirmation body in a fixed
      mode (`:unrelated` or `:incomplete`) so the probe yields clean records
      that classify as neither reproduced nor nonreproduced;
    * `crash_version` raises inside the body, so the sandbox cannot confirm
      body termination and quarantines the lease;
    * `gate: {version, pid}` sends `{:bisection_probe_started, version, self()}`
      to `pid` and waits for `:bisection_probe_continue` before running;
    * `hold_ms: {version, ms}` spends a fixed, known duration before running
      so a test can reason about the search clock deterministically.
  """

  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Scenario
  alias Insider.TestSupport.ConfirmationBody

  @impl true
  def identity, do: %{"id" => "test.bisection-body", "version" => 1}

  @impl true
  def run(arguments) do
    with {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         plan when is_map(plan) <- :persistent_term.get({__MODULE__, scenario.seed}, :missing) do
      version = arguments.target.provider["version"]
      gate(plan, version)
      hold(plan, version)
      crash(plan, version)
      ConfirmationBody.run(arguments, mode(plan, version))
    else
      _other -> {:error, :bisection_plan_missing, %{}}
    end
  end

  defp gate(%{gate: {version, pid}}, version) do
    send(pid, {:bisection_probe_started, version, self()})

    receive do
      :bisection_probe_continue -> :ok
    end
  end

  defp gate(_plan, _version), do: :ok

  defp hold(%{hold_ms: {version, ms}}, version), do: Process.sleep(ms)
  defp hold(_plan, _version), do: :ok

  defp crash(%{crash_version: version}, version),
    do: raise("controlled bisection body failure")

  defp crash(_plan, _version), do: :ok

  defp mode(%{inconclusive: {version, mode}}, version), do: mode
  defp mode(plan, version), do: {:required_execution, select(plan, version)}

  defp select(%{nondeterministic_version: version, counter: counter}, version),
    do: if(rem(:atomics.add_get(counter, 1, 1), 2) == 1, do: :matching, else: :none)

  defp select(%{reproducing_versions: versions}, version) when is_list(versions),
    do: if(version in versions, do: :matching, else: :none)

  defp select(%{flip_version: flip}, version), do: if(version >= flip, do: :matching, else: :none)
end
