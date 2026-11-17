defmodule Insider.Lab.Live.Installation do
  @moduledoc false

  # Verifies that the target runs the same Insider as this observer and, only
  # when asked with `--load` on a development, test or ci target, pushes the
  # observer's compiled Insider application (and any of its runtime
  # dependencies the target cannot resolve) and starts it. "The same" is the
  # same build (`Insider.Live.Build`: version, commit and loaded module
  # hashes). `--load` only installs: it pushes Insider into a target with no
  # Insider code at all, starts this build where it is loaded but stopped,
  # and otherwise refuses another build with `load_build_differs`, started or
  # not. Only `--force-load` replaces Insider code, and it ends any session.
  # `--load` also pushes recon (BSD-3-Clause) when the target cannot resolve
  # it, as a loaded library that Insider's inspections use when present; it
  # is never started and a target that has recon keeps its own.

  alias Insider.Lab.Live.Observer
  alias Insider.Live.Build

  @allowed_environments ["development", "test", "ci"]
  @environments [:development, :test, :ci, :staging, :production]
  @mix_environments %{
    dev: "development",
    test: "test",
    ci: "ci",
    staging: "staging",
    prod: "production"
  }
  # Applications every Elixir node provides; they are never pushed.
  @platform_applications [:kernel, :stdlib, :elixir, :logger, :crypto, :compiler]
  # Libraries `--load` adds beside Insider's own dependencies.
  @extra_applications [:recon]

  @type report :: %{String.t() => term()}
  @typedoc "`false` (no flag), `:load` (`--load`), or `:force` (`--force-load`)."
  @type load :: false | :load | :force

  @doc false
  @spec ensure(node(), load(), pos_integer()) :: {:ok, report()} | Observer.failure()
  def ensure(node, load, timeout_ms) do
    local = local_version()
    build = Insider.Lab.Live.ObserverBuild.identity()

    with {:ok, state} <- target_state(node, timeout_ms) do
      case {verdict(state, local, build), load} do
        {ready, false} when ready in [:ready, :other_build] ->
          {:ok, report(local, build, state.build, "none", [], nil)}

        {:ready, _load} ->
          ready_load(node, state, local, build, load, timeout_ms)

        {failure, false} ->
          verdict_failure(failure, local)

        {_needs_load, _load} ->
          load(node, state, local, build, load, timeout_ms)
      end
    end
  end

  defp local_version do
    _loaded = Application.load(:insider)
    :insider |> Application.spec(:vsn) |> to_string()
  end

  defp target_state(node, timeout_ms) do
    with {:ok, version} <-
           Observer.call(node, :application, :get_key, [:insider, :vsn], timeout_ms),
         {:ok, live} <- live_loaded(node, version, timeout_ms),
         {:ok, build} <- target_build(node, live, timeout_ms),
         {:ok, started} <- Observer.call(node, :application, :which_applications, [], timeout_ms) do
      {:ok,
       %{
         version: target_version(version),
         live: live,
         build: build,
         started: List.keymember?(started, :insider, 0)
       }}
    end
  end

  defp target_version({:ok, version}), do: to_string(version)
  defp target_version(:undefined), do: nil

  defp live_loaded(_node, :undefined, _timeout_ms), do: {:ok, false}

  defp live_loaded(node, _version, timeout_ms) do
    with {:ok, loaded} <- Observer.call(node, :code, :ensure_loaded, [Insider.Live], timeout_ms) do
      {:ok, match?({:module, Insider.Live}, loaded)}
    end
  end

  # `nil` when the target has no Insider.Live, or an Insider from before
  # builds were identified; either is another build than this observer's.
  defp target_build(_node, false, _timeout_ms), do: {:ok, nil}

  defp target_build(node, true, timeout_ms) do
    case Observer.call(node, Build, :identity, [], timeout_ms) do
      {:ok, %{"commit" => _commit, "beams_sha256" => _hash} = build} -> {:ok, build}
      {:ok, _other} -> {:ok, nil}
      {:error, "remote_exception", _details} -> {:ok, nil}
      failure -> failure
    end
  end

  defp verdict(%{version: nil}, _local, _build), do: :missing

  defp verdict(%{version: version}, local, _build) when version != local,
    do: {:mismatch, "version"}

  defp verdict(%{live: false}, _local, _build), do: {:mismatch, "live_api_missing"}
  defp verdict(%{started: false}, _local, _build), do: :not_started
  defp verdict(%{build: build}, _local, build), do: :ready
  defp verdict(_state, _local, _build), do: :other_build

  defp verdict_failure(:missing, local),
    do: {:error, "insider_missing", %{"observer_insider_version" => local}}

  defp verdict_failure({:mismatch, reason}, local),
    do:
      {:error, "insider_version_mismatch",
       %{"observer_insider_version" => local, "reason" => reason}}

  defp verdict_failure(:not_started, local),
    do: {:error, "insider_not_started", %{"observer_insider_version" => local}}

  defp load(node, state, local, build, load, timeout_ms) do
    with {:ok, environment, source} <- target_environment(node, timeout_ms),
         :ok <- allowed(environment, source),
         :ok <- replaceable(node, state, build, load, timeout_ms),
         {:ok, pushed} <- install(node, state, local, build, timeout_ms),
         {:ok, extras} <- missing_extras(node, timeout_ms),
         :ok <- push_all(node, extras, [], timeout_ms),
         :ok <- start(node, timeout_ms),
         {:ok, after_load} <- target_state(node, timeout_ms),
         :ready <- verdict(after_load, local, build) do
      pushed = pushed ++ Enum.map(extras, &Atom.to_string/1)
      action = if pushed == [], do: "started", else: "loaded"
      {:ok, report(local, build, after_load.build, action, pushed, environment)}
    else
      {:error, _code, _details} = failure -> failure
      _not_ready -> {:error, "load_failed", %{"reason" => "not_ready_after_load"}}
    end
  end

  # A target that already runs this build gets only the libraries it lacks,
  # under the same environment rule.
  defp ready_load(node, state, local, build, load, timeout_ms) do
    case missing_extras(node, timeout_ms) do
      {:ok, []} -> {:ok, report(local, build, state.build, "none", [], nil)}
      {:ok, _extras} -> load(node, state, local, build, load, timeout_ms)
      failure -> failure
    end
  end

  # `--force-load`, the same build, or a target with no Insider code at all
  # (no `:insider` spec and no `Insider` module loaded; see `insider_module?/1`)
  # may be loaded. Any other build loaded there, started or not, including a
  # partial install, is refused with what the caller needs to decide: both
  # builds and whether a session runs. Nothing therefore replaces Insider
  # code unless the caller forced it. Two observers installing into one
  # target at the same moment are not supported.
  defp replaceable(_node, _state, _build, :force, _timeout_ms), do: :ok
  defp replaceable(_node, %{build: build}, build, _load, _timeout_ms), do: :ok

  defp replaceable(node, %{version: nil} = state, build, load, timeout_ms) do
    case Observer.call(node, :code, :all_loaded, [], timeout_ms) do
      {:ok, loaded} when is_list(loaded) ->
        if Enum.any?(loaded, fn {module, _file} -> insider_module?(module) end),
          do: replaceable(node, %{state | version: "unknown"}, build, load, timeout_ms),
          else: :ok

      {:ok, _unexpected} ->
        {:error, "unexpected_response", %{"function" => ":code.all_loaded/0"}}

      failure ->
        failure
    end
  end

  defp replaceable(node, state, build, _load, timeout_ms) do
    {active, session} = session_state(node, timeout_ms)

    {:error, "load_build_differs",
     %{
       "target_build" => state.build,
       "observer_build" => build,
       "session_active" => active,
       "session_id" => session,
       "remedy" => build_differs_remedy(session)
     }}
  end

  # `true` with the session id, `false`, or `"unknown"` when the target's
  # owner does not answer or its Insider cannot report one.
  defp session_state(node, timeout_ms) do
    case Observer.call(node, Insider.Live, :capabilities, [], timeout_ms) do
      {:ok, %{"owner_responsive" => true, "active_session_id" => id}} when is_binary(id) ->
        {true, id}

      {:ok, %{"owner_responsive" => true, "active_session_id" => nil}} ->
        {false, nil}

      _unknown ->
        {"unknown", nil}
    end
  end

  defp build_differs_remedy(session) do
    save =
      if session,
        do: "read and save what you need from session #{session} first (events, digest, handoff)",
        else: "read and save what you need from any session first (events, digest, handoff)"

    "the target has another Insider build loaded, and --load never replaces Insider code: " <>
      "repeat with --force-load, which replaces it and ends any session; its evidence does not survive, " <>
      "even if you stop it first, so #{save}"
  end

  # Insider's own modules: `Insider` and `Insider.*`, except the Lab's
  # `Insider.Lab.*`, which is observer and test tooling, not the collector.
  defp insider_module?(module) do
    case Atom.to_string(module) do
      "Elixir.Insider" -> true
      "Elixir.Insider.Lab." <> _rest -> false
      "Elixir.Insider." <> _rest -> true
      _other -> false
    end
  end

  # The extra libraries this observer has and the target cannot resolve.
  defp missing_extras(node, timeout_ms) do
    @extra_applications
    |> Enum.filter(&locally_loadable?/1)
    |> Enum.reduce_while({:ok, []}, fn application, {:ok, missing} ->
      case resolvable?(node, application, timeout_ms) do
        {:ok, true} -> {:cont, {:ok, missing}}
        {:ok, false} -> {:cont, {:ok, missing ++ [application]}}
        {:error, _code, _details} = failure -> {:halt, failure}
      end
    end)
  end

  # The same rule `Insider.Live` applies inside the target once Insider is
  # loaded: the `:insider` `:environment` application setting wins, then a
  # running Mix's env; a node with neither is unconfigured and refused. Before
  # Insider is loaded, a setting given on the target's command line
  # (`-insider environment development`) is not yet application env, so it is
  # read from the boot arguments that would become it.
  defp target_environment(node, timeout_ms) do
    with {:ok, configured} <-
           Observer.call(node, :application, :get_env, [:insider, :environment], timeout_ms) do
      case configured do
        {:ok, environment} when environment in @environments ->
          {:ok, Atom.to_string(environment), "application_env"}

        {:ok, _other} ->
          {:ok, "unrecognized", "application_env"}

        :undefined ->
          boot_environment(node, timeout_ms)
      end
    end
  end

  defp boot_environment(node, timeout_ms) do
    with {:ok, arguments} <- Observer.call(node, :init, :get_argument, [:insider], timeout_ms) do
      case boot_setting(arguments) do
        nil -> mix_environment(node, timeout_ms)
        value -> {:ok, boot_value(value), "application_env"}
      end
    end
  end

  defp boot_setting({:ok, settings}) do
    Enum.find_value(settings, fn
      [~c"environment", value] -> List.to_string(value)
      _other -> nil
    end)
  end

  defp boot_setting(:error), do: nil

  defp boot_value(value) do
    if value in Enum.map(@environments, &Atom.to_string/1), do: value, else: "unrecognized"
  end

  # Mix modules are on every Elixir node's code path, so only a started
  # `:mix` application makes `Mix.env/0` a fact about this node.
  defp mix_environment(node, timeout_ms) do
    with {:ok, started} <- Observer.call(node, :application, :which_applications, [], timeout_ms) do
      if List.keymember?(started, :mix, 0),
        do: running_mix_environment(node, timeout_ms),
        else: {:ok, "unconfigured", "none"}
    end
  end

  defp running_mix_environment(node, timeout_ms) do
    case Observer.call(node, Mix, :env, [], timeout_ms) do
      {:ok, environment} when is_map_key(@mix_environments, environment) ->
        {:ok, Map.fetch!(@mix_environments, environment), "mix_env"}

      {:ok, _other} ->
        {:ok, "unrecognized", "mix_env"}

      {:error, "remote_exception", _details} ->
        {:ok, "unconfigured", "none"}

      {:error, _code, _details} = failure ->
        failure
    end
  end

  defp allowed(environment, _source) when environment in @allowed_environments, do: :ok

  defp allowed(environment, source),
    do:
      {:error, "load_refused",
       %{
         "environment" => environment,
         "environment_source" => source,
         "allowed" => @allowed_environments
       }}

  defp install(
         _node,
         %{version: version, live: true, build: build},
         local,
         build,
         _timeout_ms
       )
       when version == local,
       do: {:ok, []}

  defp install(node, state, _local, _build, timeout_ms) do
    with {:ok, applications} <- push_plan(node, timeout_ms),
         {:ok, environment} <-
           Observer.call(node, :application, :get_all_env, [:insider], timeout_ms),
         :ok <- unload_previous(node, state, timeout_ms),
         :ok <- push_all(node, applications, environment, timeout_ms) do
      {:ok, Enum.map(applications, &Atom.to_string/1)}
    end
  end

  # Insider first, plus every non-platform runtime dependency the target
  # cannot already resolve, dependencies before dependents.
  defp push_plan(node, timeout_ms) do
    :insider
    |> dependency_closure([])
    |> Enum.reduce_while({:ok, []}, fn application, {:ok, plan} ->
      case resolvable?(node, application, timeout_ms) do
        {:ok, true} when application != :insider -> {:cont, {:ok, plan}}
        {:ok, _missing} -> {:cont, {:ok, [application | plan]}}
        {:error, _code, _details} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, plan} -> {:ok, Enum.reverse(plan)}
      failure -> failure
    end
  end

  # Applications this observer cannot load itself (an absent optional
  # dependency) are left out; a required one the target also lacks then fails
  # at start with `load_failed`.
  defp dependency_closure(application, seen) do
    cond do
      application in seen or application in @platform_applications ->
        seen

      not locally_loadable?(application) ->
        seen

      true ->
        application
        |> dependencies()
        |> Enum.reduce(seen, &dependency_closure/2)
        |> Kernel.++([application])
    end
  end

  defp locally_loadable?(application) do
    case Application.load(application) do
      :ok -> true
      {:error, {:already_loaded, ^application}} -> true
      {:error, _reason} -> false
    end
  end

  defp dependencies(application),
    do: application |> Application.spec(:applications) |> List.wrap()

  defp resolvable?(node, application, timeout_ms) do
    file = ~c"#{application}.app"

    with {:ok, key} <-
           Observer.call(node, :application, :get_key, [application, :vsn], timeout_ms),
         {:ok, path} <- Observer.call(node, :code, :where_is_file, [file], timeout_ms) do
      {:ok, key != :undefined or path != :non_existing}
    end
  end

  # Only `--force-load` reaches a target with Insider loaded (`replaceable/5`
  # refuses it otherwise). That Insider is stopped, which ends any session,
  # and unloaded. Its environment, read before the unload, is carried into
  # the pushed spec so the target's own configuration (including
  # `:environment`) still applies.
  defp unload_previous(_node, %{version: nil}, _timeout_ms), do: :ok

  defp unload_previous(node, _state, timeout_ms) do
    with {:ok, _stopped} <- Observer.call(node, :application, :stop, [:insider], timeout_ms),
         {:ok, _unloaded} <- Observer.call(node, :application, :unload, [:insider], timeout_ms) do
      :ok
    end
  end

  defp push_all(node, applications, environment, timeout_ms) do
    Enum.reduce_while(applications, :ok, fn application, :ok ->
      case push(node, application, environment, timeout_ms) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp push(node, application, environment, timeout_ms) do
    with :ok <- push_modules(node, application, timeout_ms),
         {:ok, spec} <- application_spec(application, environment),
         {:ok, :ok} <- Observer.call(node, :application, :load, [spec], timeout_ms) do
      :ok
    else
      {:ok, {:error, _reason}} ->
        {:error, "load_failed",
         %{"reason" => "application_load_failed", "application" => Atom.to_string(application)}}

      failure ->
        failure
    end
  end

  defp push_modules(node, application, timeout_ms) do
    application
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn module, :ok ->
      case push_module(node, module, timeout_ms) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp push_module(node, module, timeout_ms) do
    with {^module, binary, file} <- :code.get_object_code(module),
         {:ok, _purged} <- Observer.call(node, :code, :purge, [module], timeout_ms),
         {:ok, {:module, ^module}} <-
           Observer.call(node, :code, :load_binary, [module, file, binary], timeout_ms) do
      :ok
    else
      :error ->
        {:error, "load_failed",
         %{"reason" => "object_code_unavailable", "module" => inspect(module)}}

      {:ok, _refused} ->
        {:error, "load_failed", %{"reason" => "module_load_refused", "module" => inspect(module)}}

      {:error, _code, _details} = failure ->
        failure
    end
  end

  defp application_spec(application, insider_environment) do
    {:ok, keys} = :application.get_all_key(application)
    environment = if application == :insider, do: insider_environment, else: []
    {:ok, {:application, application, Keyword.put(keys, :env, environment)}}
  end

  defp start(node, timeout_ms) do
    case Observer.call(node, :application, :ensure_all_started, [:insider], timeout_ms) do
      {:ok, {:ok, _started}} ->
        :ok

      {:ok, {:error, {application, _reason}}} when is_atom(application) ->
        {:error, "load_failed",
         %{"reason" => "application_start_failed", "application" => Atom.to_string(application)}}

      {:ok, {:error, _reason}} ->
        {:error, "load_failed", %{"reason" => "application_start_failed"}}

      {:error, _code, _details} = failure ->
        failure
    end
  end

  # `insider_commit` is the commit this observer's Insider was built from
  # (an escript keeps the one it was built at). `observer_build` and
  # `target_build` are the two `Insider.Live.Build` identities; when they
  # differ, the target runs other Insider code than this observer would
  # push, and `remedy` says how to replace it.
  defp report(local, build, target_build, action, pushed, environment) do
    same? = target_build == build

    %{
      "insider_version" => local,
      "insider_commit" => build["commit"],
      "observer_build" => build,
      "target_build" => target_build,
      "same_build" => same?,
      "action" => action,
      "pushed_applications" => pushed,
      "environment" => environment
    }
    |> then(fn report ->
      if same?,
        do: report,
        else:
          Map.put(
            report,
            "remedy",
            "the target runs another Insider build than this observer; --load never replaces it, " <>
              "--force-load does and ends any session, whose evidence does not survive: " <>
              "read and save what you need (events, digest, handoff) first"
          )
    end)
  end
end
