defmodule Insider.TestSupport.ExternalLeaseRegistry do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.TestSupport.ExternalConfirmationBody
  alias Insider.TestSupport.ExternalVerificationBody

  @marker ".insider-lease"
  @terminal ".insider-terminal"
  @finalized ".insider-finalized"
  @pid_file ".insider-pid"
  @allowed_bodies [ExternalConfirmationBody, ExternalVerificationBody]

  def reserve(owner_id, provenance) do
    target_fingerprint = provenance["fingerprint"]
    owner_fingerprint = "sha256:" <> digest(owner_id)
    token = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    token_sha256 = digest(token)
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "insider-external-lease-" <> suffix)
    lease_fingerprint = digest(owner_fingerprint <> target_fingerprint <> token_sha256)

    state = %{
      audit: [],
      lease_fingerprint: lease_fingerprint,
      owner_fingerprint: owner_fingerprint,
      phase: :reserved,
      provenance: provenance,
      retain_audit:
        provenance["retain_audit"] == true or
          String.starts_with?(
            get_in(provenance, ["components", "code", "attributes", "mode"]) || "",
            "external_audit"
          ),
      root: root,
      target_fingerprint: target_fingerprint,
      token: token,
      token_sha256: token_sha256
    }

    :persistent_term.put({__MODULE__, :owner, owner_id}, state)
    :persistent_term.put({__MODULE__, :fingerprint, owner_fingerprint}, owner_id)
    add_target_owner(target_fingerprint, owner_id)

    with :ok <- File.mkdir(root),
         :ok <- File.write(Path.join(root, @marker), marker(state, "acquired", 0), [:exclusive]) do
      put(owner_id, %{state | phase: :acquired, audit: [%{"acquired" => 0}]})
      :ok
    end
  end

  def arm(owner_id, body, binding) when body in @allowed_bodies do
    state = get(owner_id)

    if state.phase == :acquired and binding["owner_fingerprint"] == state.owner_fingerprint and
         binding["target_fingerprint"] == state.target_fingerprint and
         binding["lease_fingerprint"] == state.lease_fingerprint do
      armed =
        state
        |> Map.merge(%{
          expected_fingerprint: binding["expected_fingerprint"],
          observer: binding["observer"],
          phase: :armed,
          scenario_id: binding["scenario_id"]
        })
        |> Map.update!(:audit, &(&1 ++ [%{"armed" => 1}]))

      :ok = File.write(Path.join(state.root, @marker), marker(armed, "armed", 1))
      arm_fingerprint = digest(marker(armed, "armed", 1))
      put(owner_id, armed)

      {:ok,
       %{
         arm_fingerprint: arm_fingerprint,
         directory: state.root,
         fingerprint: state.lease_fingerprint,
         token: state.token
       }}
    else
      :error
    end
  rescue
    _error -> :error
  end

  def arm(_owner_id, _body, _binding), do: :error

  def finalize(owner_id, body, draft) when body in @allowed_bodies do
    state = get(owner_id)
    report = draft.receipt_fields["report"]
    digest = draft.receipt_fields["machine_output_digest"]

    with true <- state.phase == :armed,
         true <- report["owner_fingerprint"] == state.owner_fingerprint,
         true <- report["target_fingerprint"] == state.target_fingerprint,
         true <- report["lease_fingerprint"] == state.lease_fingerprint,
         {:ok, terminal} <- File.read(Path.join(state.root, @terminal)),
         {:ok, %{"phase" => "scenario", "report_digest" => ^digest, "seq" => 2}} <-
           Jason.decode(terminal),
         :ok <-
           File.write(
             Path.join(state.root, @finalized),
             Canonical.encode(%{"phase" => "finalized", "report_digest" => digest, "seq" => 3}),
             [:exclusive]
           ) do
      put(owner_id, %{
        state
        | phase: :finalized,
          audit: state.audit ++ [%{"scenario" => 2}, %{"finalized" => 3}]
      })

      {:ok, %{"armed" => 1, "scenario" => 2, "finalized" => 3}}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end

  def finalize(_owner_id, _body, _draft), do: :error

  def cleanup(owner_id, preserve?) do
    state = get(owner_id)
    pid = read_pid(state.root)
    alive = process_alive?(pid)
    if alive, do: signal(pid, "KILL")
    down = await_down(pid, System.monotonic_time(:millisecond) + 150)

    unless preserve?, do: File.rm_rf(state.root)

    audit = %{
      "process_down_before_provider_cleanup" => not alive,
      "process_down_after_provider_cleanup" => down,
      "protocol" => state.audit,
      "root_removed" => not File.exists?(state.root)
    }

    if state.retain_audit,
      do: :persistent_term.put({__MODULE__, :audit, state.owner_fingerprint}, audit)

    unless preserve?, do: erase(owner_id, state.owner_fingerprint)
    :ok
  rescue
    _error -> :error
  end

  def inventory(owner_id) do
    state = :persistent_term.get({__MODULE__, :owner, owner_id}, nil)

    cond do
      is_nil(state) ->
        []

      File.exists?(state.root) ->
        [%{"id_fingerprint" => "sha256:" <> digest(state.root), "kind" => "external-lease"}]

      true ->
        []
    end
  end

  def audit(owner_fingerprint),
    do: :persistent_term.get({__MODULE__, :audit, owner_fingerprint}, nil)

  def purge_audit(owner_fingerprint),
    do: :persistent_term.erase({__MODULE__, :audit, owner_fingerprint})

  def force_purge(owner_fingerprint) do
    case :persistent_term.get({__MODULE__, :fingerprint, owner_fingerprint}, nil) do
      nil ->
        purge_audit(owner_fingerprint)

      owner_id ->
        state = get(owner_id)
        File.rm_rf(state.root)
        erase(owner_id, owner_fingerprint)
        purge_audit(owner_fingerprint)
    end
  end

  def child_started_for_target?(target_fingerprint) do
    {__MODULE__, :target, target_fingerprint}
    |> :persistent_term.get([])
    |> Enum.any?(fn owner_id ->
      case :persistent_term.get({__MODULE__, :owner, owner_id}, nil) do
        nil -> false
        state -> File.exists?(Path.join(state.root, @pid_file))
      end
    end)
  rescue
    _error -> false
  end

  defp marker(state, phase, seq) do
    base = %{
      "lease_fingerprint" => state.lease_fingerprint,
      "owner_fingerprint" => state.owner_fingerprint,
      "phase" => phase,
      "seq" => seq,
      "target_fingerprint" => state.target_fingerprint,
      "token_sha256" => state.token_sha256
    }

    if phase == "armed" do
      Map.merge(base, %{
        "expected_fingerprint" => state.expected_fingerprint,
        "observer" => state.observer,
        "scenario_id" => state.scenario_id
      })
    else
      base
    end
    |> Canonical.encode()
  end

  defp get(owner_id), do: :persistent_term.get({__MODULE__, :owner, owner_id})
  defp put(owner_id, state), do: :persistent_term.put({__MODULE__, :owner, owner_id}, state)

  defp erase(owner_id, owner_fingerprint) do
    state = get(owner_id)
    :persistent_term.erase({__MODULE__, :owner, owner_id})
    :persistent_term.erase({__MODULE__, :fingerprint, owner_fingerprint})
    remove_target_owner(state.target_fingerprint, owner_id)
  end

  defp add_target_owner(target_fingerprint, owner_id) do
    update_target_owners(target_fingerprint, fn owners ->
      [owner_id | owners] |> Enum.uniq() |> Enum.sort()
    end)
  end

  defp remove_target_owner(target_fingerprint, owner_id) do
    update_target_owners(target_fingerprint, &List.delete(&1, owner_id))
  end

  defp update_target_owners(target_fingerprint, update) do
    key = {__MODULE__, :target, target_fingerprint}

    lock = {{__MODULE__, :target_index, target_fingerprint}, self()}

    :global.trans(lock, fn ->
      case update.(:persistent_term.get(key, [])) do
        [] -> :persistent_term.erase(key)
        owners -> :persistent_term.put(key, owners)
      end
    end)
  end

  defp read_pid(root) do
    case File.read(Path.join(root, @pid_file)) do
      {:ok, value} ->
        case Integer.parse(value) do
          {pid, "\n"} when pid > 0 -> pid
          _other -> nil
        end

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  defp await_down(nil, _deadline), do: true

  defp await_down(pid, deadline) do
    cond do
      not process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          5 -> await_down(pid, deadline)
        end
    end
  end

  defp process_alive?(nil), do: false

  defp process_alive?(pid) do
    case System.cmd(kill_executable(), ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _error -> true
  end

  defp signal(pid, signal) do
    System.cmd(kill_executable(), ["-" <> signal, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp kill_executable do
    Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) || raise "kill unavailable"
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

defmodule Insider.TestSupport.ExternalProcessProfile do
  @moduledoc false

  @scheduler_bounds "+S 1:1 +SDcpu 1:1 +SDio 1 +A 1"

  @program ~S'''
  marker = File.read!(".insider-lease")
  token = System.fetch_env!("INSIDER_LEASE_TOKEN")
  token_digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  captures = Regex.named_captures(~r/\{"expected_fingerprint":"(?<expected>[0-9a-f]{64})","lease_fingerprint":"(?<lease>[0-9a-f]{64})","observer":\{"id":"(?<observer>[a-z0-9_.-]+)","version":(?<version>[0-9]+)\},"owner_fingerprint":"(?<owner>sha256:[0-9a-f]{64})","phase":"armed","scenario_id":"(?<scenario>sha256:[0-9a-f]{64})","seq":1,"target_fingerprint":"(?<target>[0-9a-f]{64})","token_sha256":"(?<token>[0-9a-f]{64})"\}/, marker)
  true = captures["token"] == token_digest
  mode = List.first(System.argv())
  if mode == "ignore_term" do
    :ok = :os.set_signal(:sigterm, :ignore)
    File.write!(".insider-term-ignored", "ready", [:exclusive])
  end
  File.write!(".insider-pid", [System.pid(), "\n"], [:exclusive])
  owner = if mode == "mismatched_owner", do: "sha256:" <> String.duplicate("0", 64), else: captures["owner"]
  target = if mode == "mismatched_target", do: String.duplicate("f", 64), else: captures["target"]
  lease = if mode == "mismatched_lease", do: String.duplicate("e", 64), else: captures["lease"]
  observed = if mode in ["empty", "empty_exit2"], do: "[]", else: if(mode == "nonmatching_exit2", do: "[\"#{String.duplicate("f", 64)}\"]", else: "[\"#{captures["expected"]}\"]")
  scenario_status = if mode in ["exit2", "empty_exit2", "nonmatching_exit2"], do: "failed", else: "completed"
  report = "{\"expected_fingerprint\":\"#{captures["expected"]}\",\"lease_fingerprint\":\"#{lease}\",\"observed_fingerprints\":#{observed},\"observer\":{\"id\":\"#{captures["observer"]}\",\"version\":#{captures["version"]}},\"owner_fingerprint\":\"#{owner}\",\"scenario_id\":\"#{captures["scenario"]}\",\"scenario_status\":\"#{scenario_status}\",\"target_fingerprint\":\"#{target}\"}"
  report_digest = :crypto.hash(:sha256, report) |> Base.encode16(case: :lower)
  terminal = "{\"phase\":\"scenario\",\"report_digest\":\"#{report_digest}\",\"seq\":2}"

  case mode do
    mode when mode in ["blocking", "ignore_term"] -> receive do _ -> :ok end
    "controlled_deadline_exit" ->
      File.write!(".insider-terminal", terminal, [:exclusive])
      IO.puts("INSIDER_REPORT " <> report)
      File.write!(".insider-output-ready", "ready", [:exclusive])
      wait = fn wait ->
        if File.exists?(".insider-release") do
          :ok
        else
          receive do after 1 -> wait.(wait) end
        end
      end
      wait.(wait)
    "flood" -> IO.write(String.duplicate("x", 70_000)); receive do _ -> :ok end
    "secret" -> IO.puts(System.fetch_env!("INSIDER_SECRET_CANARY")); File.write!(".insider-terminal", terminal, [:exclusive]); IO.puts("INSIDER_REPORT " <> report)
    "echo_only" -> IO.puts("INSIDER_REPORT " <> String.duplicate("x", 10))
    mode when mode in ["exit2", "empty_exit2", "nonmatching_exit2"] -> File.write!(".insider-terminal", terminal, [:exclusive]); IO.puts("INSIDER_REPORT " <> report); System.halt(2)
    _ -> File.write!(".insider-terminal", terminal, [:exclusive]); IO.puts("INSIDER_REPORT " <> report)
  end
  '''

  @behaviour Insider.Sentinel.ExternalProcess

  @impl true
  def identity, do: %{"id" => "test.external-process.success", "version" => 1}

  @impl true
  def command(binding, lease), do: command(binding, lease, "success")

  def command(_binding, lease, mode) do
    arguments = ["--erl", @scheduler_bounds, "-e", @program, "--", mode]

    {:ok,
     %{
       executable: System.find_executable("elixir"),
       arguments: arguments,
       fingerprint_arguments: arguments,
       cd: lease.directory,
       env: [
         {"INSIDER_LEASE_TOKEN", lease.token},
         {"INSIDER_SECRET_CANARY", "TOP_SECRET_DO_NOT_RETAIN"},
         {"PATH", System.fetch_env!("PATH")}
       ],
       argument_policy: "public-exact/v1"
     }}
  end
end

defmodule Insider.TestSupport.ExternalProcessProfileLingeringGroup do
  @behaviour Insider.Sentinel.ExternalProcess

  @script ~S'''
  printf '%s' "$$" > .insider-direct-pid
  printf '%s' "$INSIDER_TERMINAL_JSON" > .insider-terminal
  printf 'INSIDER_REPORT %s\n' "$INSIDER_REPORT_JSON"
  (exec sleep 30) </dev/null >/dev/null 2>&1 &
  printf '%s' "$!" > .insider-lingering-pid
  printf alive > .insider-lingering
  '''

  @impl true
  def identity, do: %{"id" => "test.external-process.lingering-group", "version" => 1}

  @impl true
  def command(binding, lease) do
    report = %{
      "expected_fingerprint" => binding["expected_fingerprint"],
      "lease_fingerprint" => binding["lease_fingerprint"],
      "observed_fingerprints" => [binding["expected_fingerprint"]],
      "observer" => binding["observer"],
      "owner_fingerprint" => binding["owner_fingerprint"],
      "scenario_id" => binding["scenario_id"],
      "scenario_status" => "completed",
      "target_fingerprint" => binding["target_fingerprint"]
    }

    report_json = Insider.Event.Canonical.encode(report)

    terminal_json =
      Insider.Event.Canonical.encode(%{
        "phase" => "scenario",
        "report_digest" => sha256(report_json),
        "seq" => 2
      })

    {:ok,
     %{
       executable: System.find_executable("sh"),
       arguments: ["-c", @script],
       fingerprint_arguments: ["-c", @script],
       cd: lease.directory,
       env: [
         {"INSIDER_REPORT_JSON", report_json},
         {"INSIDER_TERMINAL_JSON", terminal_json},
         {"PATH", System.fetch_env!("PATH")}
       ],
       argument_policy: "public-exact/v1"
     }}
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

for mode <- [
      :blocking,
      :controlled_deadline_exit,
      :echo_only,
      :empty,
      :empty_exit2,
      :exit2,
      :flood,
      :ignore_term,
      :mismatched_lease,
      :mismatched_owner,
      :mismatched_target,
      :nonmatching_exit2,
      :secret
    ] do
  module =
    Module.concat(Insider.TestSupport, "ExternalProcessProfile#{Macro.camelize(to_string(mode))}")

  defmodule module do
    @behaviour Insider.Sentinel.ExternalProcess
    @mode Atom.to_string(mode)

    @impl true
    def identity, do: %{"id" => "test.external-process.#{@mode}", "version" => 1}

    @impl true
    def command(binding, lease),
      do: Insider.TestSupport.ExternalProcessProfile.command(binding, lease, @mode)
  end
end

defmodule Insider.TestSupport.ExternalVerificationBody do
  @moduledoc false
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Provenance
  alias Insider.Scenario
  alias Insider.Sentinel.ExternalProcess
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Receipt
  alias Insider.TestSupport.ExternalLeaseRegistry
  alias Insider.TestSupport.ExternalProcessProfileEmpty

  @impl true
  def identity, do: %{"id" => "test.external-verification", "version" => 1}

  @impl true
  def run(arguments) do
    with {:ok, candidate} <- Candidate.decode_map(arguments.input["candidate"]),
         {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         binding <- binding(arguments, scenario),
         {:ok, lease} <- ExternalLeaseRegistry.arm(arguments.owner_id, __MODULE__, binding),
         {:ok, draft} <-
           ExternalProcess.run(
             ExternalProcessProfileEmpty,
             binding,
             lease,
             arguments.deadline,
             arguments.stop_deadline,
             arguments.cancellation_reference
           ),
         {:ok, protocol} <- ExternalLeaseRegistry.finalize(arguments.owner_id, __MODULE__, draft),
         {:ok, external} <- ExternalProcess.finalize(draft, protocol),
         true <- external["exit_status"] == 0,
         true <- work_active?(arguments.deadline),
         {:ok, receipt} <- receipt(arguments, candidate, scenario, external, protocol),
         true <- work_active?(arguments.deadline) do
      {:ok, receipt}
    else
      _other -> {:error, :external_verification_failed, %{}}
    end
  end

  defp receipt(arguments, candidate, scenario, external, protocol) do
    pre = arguments.observed_provenance
    {:ok, post} = post_provenance(pre, candidate)
    post = Provenance.to_wire_map(post)
    code = post["components"]["code"]["fingerprint"]
    owner = external["owner_fingerprint"]

    gates =
      for name <- ["resources", "runtime", "static"], into: %{} do
        {name,
         %{
           "code_fingerprint" => code,
           "receipt_digest" => digest(owner <> name),
           "status" => "passed"
         }}
      end

    Receipt.new_external(
      regression_id: arguments.input["regression_id"],
      candidate_id: candidate.id,
      scenario_id: scenario.id,
      expected_fingerprint: arguments.input["expected_fingerprint"],
      observer: arguments.input["observer"],
      owner_fingerprint: owner,
      observation_run_fingerprint: owner,
      pre_provenance: pre,
      post_provenance: post,
      observed_fingerprints: [],
      evidence: Map.merge(evidence(protocol), %{"post_provenance_observed" => true}),
      oracle: %{
        "identity" => arguments.input["oracle"],
        "receipt_digest" => digest(owner <> candidate.id <> "oracle"),
        "status" => "passed"
      },
      gates: gates,
      external_execution: external
    )
  end

  defp evidence(%{"armed" => 1, "finalized" => 3, "scenario" => 2}),
    do: %{
      "armed_before_scenario" => true,
      "complete" => true,
      "dropped" => 0,
      "finalized_after_scenario" => true,
      "gaps" => 0,
      "scenario_status" => "completed",
      "truncated" => false
    }

  defp binding(arguments, scenario) do
    state = :persistent_term.get({ExternalLeaseRegistry, :owner, arguments.owner_id})

    %{
      "expected_fingerprint" => arguments.input["expected_fingerprint"],
      "lease_fingerprint" => state.lease_fingerprint,
      "observer" => arguments.input["observer"],
      "owner_fingerprint" => state.owner_fingerprint,
      "scenario_id" => scenario.id,
      "target_fingerprint" => arguments.observed_provenance["fingerprint"]
    }
  end

  defp post_provenance(pre, candidate) do
    components = pre["components"]

    Provenance.new(
      code: {:available, %{"candidate" => candidate.content_sha256}},
      configuration: {:available, components["configuration"]["attributes"]},
      dependencies: {:available, components["dependencies"]["attributes"]},
      runtime: {:available, components["runtime"]["attributes"]},
      target: {:available, components["target"]["attributes"]}
    )
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp work_active?(deadline), do: System.monotonic_time(:millisecond) < deadline
end

defmodule Insider.TestSupport.ExternalLeaseProvider do
  @moduledoc false
  @behaviour Insider.Sentinel.Sandbox.Provider

  alias Insider.TestSupport.ExternalLeaseRegistry

  @impl true
  def identity, do: %{"id" => "test.external-lease", "version" => 1}

  @impl true
  def acquire(owner_id, target, _deadline),
    do: ExternalLeaseRegistry.reserve(owner_id, target.provenance)

  @impl true
  def observe(owner_id, _deadline),
    do: {:ok, :persistent_term.get({ExternalLeaseRegistry, :owner, owner_id}).provenance}

  @impl true
  def cleanup(owner_id, _deadline) do
    state = :persistent_term.get({ExternalLeaseRegistry, :owner, owner_id})

    preserve? =
      get_in(state.provenance, ["components", "code", "attributes", "mode"]) == "cleanup_partial"

    ExternalLeaseRegistry.cleanup(owner_id, preserve?)
  end

  @impl true
  def inventory(owner_id, _deadline), do: {:ok, ExternalLeaseRegistry.inventory(owner_id)}
end

defmodule Insider.TestSupport.ExternalConfirmationBody do
  @moduledoc false
  @behaviour Insider.Sentinel.Sandbox.Body

  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation.Receipt
  alias Insider.Sentinel.ExternalProcess
  alias Insider.TestSupport.ExternalLeaseRegistry

  @observer %{"id" => "test.external-observer", "version" => 1}

  @impl true
  def identity, do: %{"id" => "test.external-confirmation", "version" => 1}

  @impl true
  def run(arguments), do: run(arguments, Insider.TestSupport.ExternalProcessProfile)

  def run(arguments, profile) do
    with true <- arguments.input["observer"] == @observer,
         {:ok, scenario} <- Scenario.decode_map(arguments.input["scenario"]),
         binding <- binding(arguments, scenario),
         {:ok, lease} <- ExternalLeaseRegistry.arm(arguments.owner_id, __MODULE__, binding),
         {:ok, draft} <-
           ExternalProcess.run(
             profile,
             binding,
             lease,
             arguments.deadline,
             arguments.stop_deadline,
             arguments.cancellation_reference
           ),
         {:ok, protocol} <- ExternalLeaseRegistry.finalize(arguments.owner_id, __MODULE__, draft),
         {:ok, external} <- ExternalProcess.finalize(draft, protocol),
         :ok <- valid_exit?(external, arguments.input["repair_oracle"]),
         report <- external["report"],
         true <- work_active?(arguments.deadline),
         result <-
           Receipt.new_external(
             manifest_id: arguments.input["manifest_id"],
             capsule_id: arguments.input["capsule_id"],
             scenario_id: scenario.id,
             target_id: arguments.target.id,
             expected_fingerprint: arguments.input["expected_fingerprint"],
             owner_fingerprint: binding["owner_fingerprint"],
             observed_target_fingerprint: binding["target_fingerprint"],
             observation_run_fingerprint: binding["owner_fingerprint"],
             observer: @observer,
             lease_execution: "confirmed",
             scenario_status: report["scenario_status"],
             observed_incident_fingerprints: report["observed_fingerprints"],
             evidence: evidence(protocol),
             repair_oracle: nil,
             reason: if(report["scenario_status"] == "failed", do: "scenario_failed", else: nil),
             external_execution: external
           ),
         true <- work_active?(arguments.deadline) do
      result
    else
      _other -> {:error, :external_execution_failed, %{}}
    end
  end

  defp valid_exit?(%{"exit_status" => 0}, _oracle), do: :ok

  defp valid_exit?(external, nil) do
    report = external["report"]

    if external["exit_status"] in 1..255 and report["scenario_status"] == "failed" and
         report["observed_fingerprints"] == [report["expected_fingerprint"]],
       do: :ok,
       else: :error
  end

  defp valid_exit?(_external, _oracle), do: :error

  defp evidence(%{"armed" => 1, "scenario" => 2, "finalized" => 3}),
    do: %{
      "armed_before_scenario" => true,
      "complete" => true,
      "dropped" => 0,
      "finalized_after_scenario" => true,
      "gaps" => 0,
      "truncated" => false
    }

  defp binding(arguments, scenario) do
    state = :persistent_term.get({ExternalLeaseRegistry, :owner, arguments.owner_id})

    %{
      "expected_fingerprint" => arguments.input["expected_fingerprint"],
      "lease_fingerprint" => state.lease_fingerprint,
      "observer" => @observer,
      "owner_fingerprint" => state.owner_fingerprint,
      "scenario_id" => scenario.id,
      "target_fingerprint" => arguments.observed_provenance["fingerprint"]
    }
  end

  defp work_active?(deadline), do: System.monotonic_time(:millisecond) < deadline
end

for mode <- [
      :blocking,
      :empty_exit2,
      :exit2,
      :nonmatching_exit2
    ] do
  module =
    Module.concat(
      Insider.TestSupport,
      "ExternalConfirmationBody#{Macro.camelize(to_string(mode))}"
    )

  profile =
    Module.concat(Insider.TestSupport, "ExternalProcessProfile#{Macro.camelize(to_string(mode))}")

  defmodule module do
    @behaviour Insider.Sentinel.Sandbox.Body
    @profile profile

    @impl true
    def identity, do: @profile.identity()

    @impl true
    def run(arguments), do: Insider.TestSupport.ExternalConfirmationBody.run(arguments, @profile)
  end
end
