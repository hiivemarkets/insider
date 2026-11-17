defmodule Insider.Policy.ProtectedTargets do
  @moduledoc """
  Immutable host-owned classification for targets that Insider must not inspect.

  The policy is additive: host declarations can protect more same-node processes,
  but callers cannot remove BEAM/OTP or Insider-control-plane protections.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Value

  @maximum_host_targets 32
  @maximum_control_targets 32
  @maximum_audit_otp_majors 8
  @inventory_version "otp_elixir_runtime_registry/v1"
  @audit_matrix_schema "insider.protected-target-audit-matrix/v1"
  # OTP majors in the supported toolchain matrix. The audit matrix enumerates
  # the fixed inventory for each one from data alone; it never resolves names.
  @supported_otp_majors ["27", "28", "29"]
  # Control-plane target classes bound by `bind_collector/2` and
  # `bind_session/4`. These are classes, not PIDs: the matrix is PID-free.
  @control_target_classes [
    "collector_process",
    "insider_supervisor",
    "recorder_process",
    "session_component_process",
    "session_manager",
    "session_process",
    "session_root_supervisor",
    "session_supervisor"
  ]
  # `classify/2` evaluates these classes in precedence order and stops at the
  # first match. Every protected class produces the same denial decision.
  @classification_table [
    %{
      "class" => "invalid",
      "decision" => "protected",
      "precedence" => 0,
      "reason" => "non_pid_target"
    },
    %{
      "class" => "remote_or_invalid",
      "decision" => "protected",
      "precedence" => 1,
      "reason" => "remote_node_pid"
    },
    %{
      "class" => "host_declared",
      "decision" => "protected",
      "maximum_targets" => @maximum_host_targets,
      "precedence" => 2,
      "reason" => "additive_host_declaration"
    },
    %{
      "class" => "insider_control_plane",
      "decision" => "protected",
      "maximum_targets" => @maximum_control_targets,
      "precedence" => 3,
      "reason" => "collector_session_binding"
    },
    %{
      "class" => "beam_otp",
      "decision" => "protected",
      "precedence" => 4,
      "reason" => "fixed_registry_inventory"
    },
    %{
      "class" => "none",
      "decision" => "allowed",
      "precedence" => 5,
      "reason" => "no_matching_protection"
    }
  ]
  @audit_controls %{
    "application_targets" => "undeclared",
    "exception_mechanism" => "none",
    "exception_review_owner" => "undeclared",
    "host_declarations" => "additive_only",
    "mutation" => "none",
    "runtime_inspection" => "none"
  }
  @audit_limitations [
    "absent_registrations_are_not_protected_on_that_runtime",
    "inventory_is_release_independent_so_rows_repeat_across_majors",
    "matrix_describes_policy_data_not_host_registration_state",
    "system_monitor_protected_subject_filtering_is_deferred"
  ]
  # Conservative, release-independent OTP/Elixir runtime registry inventory.
  # We resolve names locally at classification time rather than accepting a
  # name or PID from an adapter. Absent names do not broaden authority; hosts
  # may only add protections, never subtract from this inventory.
  @otp_names [
    Logger.Supervisor,
    Insider.Supervisor,
    :alarm_handler,
    :init,
    :kernel_sup,
    :application_controller,
    :code_server,
    :elixir_code_server,
    :elixir_config,
    :elixir_sup,
    :erl_prim_loader,
    :erl_signal_server,
    :erts_code_purger,
    :file_server_2,
    :global_group,
    :global_group_check,
    :global_name_server,
    :inet_db,
    :kernel_refc,
    :kernel_safe_sup,
    :logger,
    :logger_sup,
    :logger_handler_watcher,
    :logger_proxy,
    :logger_std_h_default,
    :net_kernel,
    :net_sup,
    :net_sup_dynamic,
    :net_tickint,
    :auth,
    :erl_epmd,
    :release_handler,
    :rex,
    :sasl_safe_sup,
    :sasl_sup,
    :socket_registry,
    :standard_error,
    :standard_error_sup,
    :standard_error_writer,
    :user,
    :user_drv,
    :user_drv_reader,
    :user_drv_writer
  ]

  @enforce_keys [
    :control_targets,
    :fingerprint,
    :host_targets,
    :inventory_version,
    :otp_major,
    :registration_names
  ]
  defstruct [
    :control_targets,
    :fingerprint,
    :host_targets,
    :inventory_version,
    :otp_major,
    :registration_names
  ]

  @type t :: %__MODULE__{
          control_targets: [pid()],
          host_targets: [pid()],
          fingerprint: String.t(),
          inventory_version: String.t(),
          otp_major: String.t(),
          registration_names: [String.t()]
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(options \\ [])

  def new(options) when is_list(options) do
    targets = Keyword.get(options, :host_targets, [])

    if Keyword.keyword?(options) and Keyword.keys(options) == Enum.uniq(Keyword.keys(options)) and
         Keyword.keys(options) -- [:host_targets] == [] and
         Value.bounded_list?(targets, @maximum_host_targets) and Enum.all?(targets, &local_pid?/1) and
         targets == Enum.uniq(targets) do
      registration_names = registration_names()
      otp_major = otp_major()

      {:ok,
       %__MODULE__{
         control_targets: [],
         host_targets: targets,
         inventory_version: @inventory_version,
         otp_major: otp_major,
         registration_names: registration_names,
         fingerprint: fingerprint(targets, [], registration_names, otp_major)
       }}
    else
      {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  end

  def new(_options), do: {:error, :invalid_policy}

  @doc false
  @spec bind_collector(t(), pid()) :: {:ok, t()} | {:error, :invalid_policy}
  def bind_collector(%__MODULE__{} = policy, recorder_pid) when is_pid(recorder_pid) do
    # `self/0`, the recorder, and the fixed registered Insider supervisor are
    # host-derived session controls, not an adapter-provided inventory. We do
    # not infer arbitrary links: a direct caller can be linked during startup
    # without belonging to the collector control plane.
    if valid?(policy) and local_pid?(recorder_pid) do
      insider_supervisor = Process.whereis(Insider.Supervisor)

      targets =
        (policy.control_targets ++ [self(), recorder_pid, insider_supervisor])
        |> Enum.filter(&local_pid?/1)
        |> Enum.uniq()

      if Value.bounded_list?(targets, @maximum_control_targets) do
        {:ok,
         %{
           policy
           | control_targets: targets,
             fingerprint:
               fingerprint(
                 policy.host_targets,
                 targets,
                 policy.registration_names,
                 policy.otp_major
               )
         }}
      else
        {:error, :invalid_policy}
      end
    else
      {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  end

  def bind_collector(_policy, _recorder_pid), do: {:error, :invalid_policy}

  @doc false
  @spec bind_session(t(), pid(), pid(), [pid()]) :: {:ok, t()} | {:error, :invalid_policy}
  def bind_session(%__MODULE__{} = policy, session_pid, recorder_pid, component_pids)
      when is_pid(session_pid) and is_pid(recorder_pid) and is_list(component_pids) do
    session_control_targets = [
      Process.whereis(Insider.Supervisor),
      Process.whereis(Insider.Collector.Session.RootSupervisor),
      Process.whereis(Insider.Collector.Session.Manager),
      Process.whereis(Insider.Collector.Session.Supervisor)
    ]

    targets =
      (policy.control_targets ++
         [session_pid, recorder_pid] ++ session_control_targets ++ component_pids)
      |> Enum.filter(&local_pid?/1)
      |> Enum.uniq()

    if valid?(policy) and Value.bounded_list?(targets, @maximum_control_targets) do
      {:ok,
       %{
         policy
         | control_targets: targets,
           fingerprint:
             fingerprint(
               policy.host_targets,
               targets,
               policy.registration_names,
               policy.otp_major
             )
       }}
    else
      {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  end

  def bind_session(_policy, _session_pid, _recorder_pid, _component_pids),
    do: {:error, :invalid_policy}

  @spec classify(t(), pid()) :: {:allowed, map()} | {:protected, map()}
  def classify(%__MODULE__{} = policy, target) when is_pid(target) do
    cond do
      not local_pid?(target) ->
        {:protected, evidence("remote_or_invalid", policy)}

      target in policy.host_targets ->
        {:protected, evidence("host_declared", policy)}

      target in policy.control_targets ->
        {:protected, evidence("insider_control_plane", policy)}

      target in otp_targets() ->
        {:protected, evidence("beam_otp", policy)}

      true ->
        {:allowed, evidence("none", policy)}
    end
  end

  def classify(_policy, _target), do: {:protected, %{"class" => "invalid"}}

  @doc false
  # What a whole-node scan (the Poller's process and ETS rankings) needs from
  # this policy, resolved once per scan, with `classify/2`'s precedence:
  #
  #   * `protected`: the processes a scan must not read, each with its fixed
  #     registration name (`nil` for a host declaration). Host declarations
  #     always stay; Insider's control plane is exempt only from the fixed
  #     OTP inventory (`Insider.Supervisor` is in both).
  #   * `insider`: Insider's control-plane processes a scan may read, only to
  #     report them in aggregate.
  #   * `insider_protected`: control-plane processes a host also declared.
  #     They are Insider's but must not be read, so a scan's Insider totals
  #     cannot be complete while there are any.
  #   * `host_declared`: every host declaration. Whether one belongs to
  #     Insider's application cannot be learned without reading it, so a scan
  #     that skips a live one cannot claim complete Insider totals either.
  @spec scan_inventory(t()) :: %{
          protected: %{pid() => atom() | nil},
          insider: [pid()],
          insider_protected: [pid()],
          host_declared: [pid()]
        }
  def scan_inventory(%__MODULE__{} = policy) do
    named =
      for name <- @otp_names, pid = Process.whereis(name), is_pid(pid), into: %{} do
        {pid, name}
      end

    protected =
      named
      |> Map.drop(policy.control_targets)
      |> then(&Map.merge(Map.new(policy.host_targets, fn pid -> {pid, nil} end), &1))

    {insider_protected, insider} =
      Enum.split_with(policy.control_targets, &(&1 in policy.host_targets))

    %{
      protected: protected,
      insider: insider,
      insider_protected: insider_protected,
      host_declared: policy.host_targets
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = policy) do
    with {:ok, base} <- new(host_targets: policy.host_targets) do
      case policy.control_targets do
        [] ->
          base == policy

        targets ->
          Value.bounded_list?(targets, @maximum_control_targets) and
            Enum.all?(targets, &local_pid?/1) and
            targets == Enum.uniq(targets) and
            policy.inventory_version == @inventory_version and
            policy.registration_names == registration_names() and policy.otp_major == otp_major() and
            policy.fingerprint ==
              fingerprint(
                policy.host_targets,
                targets,
                policy.registration_names,
                policy.otp_major
              )
      end
    end
  end

  def valid?(_value), do: false

  @doc """
  Derives the read-only protected-target audit matrix from the fixed inventory.

  The matrix enumerates, per supported OTP major, every fixed registration name
  and control-target class with the denial decision and reason `classify/2`
  produces for it. It is pure data: no name is resolved, no PID or timestamp is
  included, and the same options yield identical bytes on every toolchain.
  Application targets and an exception-review owner remain undeclared.
  """
  @spec audit_matrix(keyword()) :: {:ok, map()} | {:error, :invalid_options}
  def audit_matrix(options \\ [])

  def audit_matrix(options) when is_list(options) do
    otp_majors = Keyword.get(options, :otp_majors, @supported_otp_majors)

    if Keyword.keyword?(options) and Keyword.keys(options) -- [:otp_majors] == [] and
         Keyword.keys(options) == Enum.uniq(Keyword.keys(options)) and
         Value.bounded_list?(otp_majors, @maximum_audit_otp_majors) and
         Enum.all?(otp_majors, &otp_major_string?/1) and otp_majors == Enum.uniq(otp_majors) do
      body = %{
        "schema" => @audit_matrix_schema,
        "inventory_version" => @inventory_version,
        "policy_module" => Atom.to_string(__MODULE__),
        "otp_majors" => Enum.sort(otp_majors),
        "classification" => @classification_table,
        "inventories" => otp_majors |> Enum.sort() |> Enum.map(&audit_inventory/1),
        "controls" => @audit_controls,
        "limitations" => @audit_limitations
      }

      {:ok, Map.put(body, "fingerprint", Canonical.sha256(body))}
    else
      {:error, :invalid_options}
    end
  end

  def audit_matrix(_options), do: {:error, :invalid_options}

  defp otp_major_string?(value),
    do: is_binary(value) and byte_size(value) in 1..3 and value =~ ~r/\A[0-9]+\z/

  defp audit_inventory(otp_major) do
    names = registration_names()

    registry_rows =
      Enum.map(names, fn name ->
        audit_row(otp_major, "beam_otp", "registered_name", name, "fixed_registry_inventory")
      end)

    control_rows =
      Enum.map(@control_target_classes, fn class ->
        audit_row(
          otp_major,
          "insider_control_plane",
          "control_target_class",
          class,
          "collector_session_binding"
        )
      end)

    %{
      "otp_major" => otp_major,
      "base_policy_fingerprint" => fingerprint([], [], names, otp_major),
      "rows" => registry_rows ++ control_rows
    }
  end

  defp audit_row(otp_major, class, target_kind, target, reason) do
    %{
      "otp_major" => otp_major,
      "class" => class,
      "target_kind" => target_kind,
      "target" => target,
      "decision" => "protected",
      "reason" => reason
    }
  end

  defp otp_targets, do: @otp_names |> Enum.map(&Process.whereis/1) |> Enum.filter(&is_pid/1)
  defp registration_names, do: @otp_names |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  defp otp_major,
    do: :erlang.system_info(:otp_release) |> to_string() |> String.split(".") |> hd()

  defp fingerprint(host_targets, control_targets, registration_names, otp_major) do
    Canonical.sha256(%{
      "control_targets" => control_targets |> Enum.map(&pid_string/1) |> Enum.sort(),
      "host_targets" => host_targets |> Enum.map(&pid_string/1) |> Enum.sort(),
      "inventory_version" => @inventory_version,
      "otp_major" => otp_major,
      "registration_names" => registration_names
    })
  end

  defp local_pid?(pid), do: is_pid(pid) and node(pid) == node()
  defp pid_string(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  defp evidence(class, policy),
    do: %{"class" => class, "policy_fingerprint" => policy.fingerprint}
end
