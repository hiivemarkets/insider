defmodule Insider.Discovery.ExUnit.Inventory do
  @moduledoc """
  Produces a bounded, deterministic inventory of ExUnit isolation-risk signals.

  Entries are candidates for agent-directed investigation. Static source
  signals never establish runtime causality or confirmation.
  """

  @schema "insider.exunit-candidate-inventory/v2"
  @scanner_revision "ast-v8-telemetry-event-targets"
  @maximum_targets_per_candidate 64
  @application_env_oracle_schema "insider.application-env-oracle/v1"
  @telemetry_event_oracle_schema "insider.telemetry-dead-handlers-oracle/v1"
  # Bounds copied from the fixed artifacts in priv/oracles so a hint is emitted
  # only when the artifact can accept the encoded identity unchanged.
  @oracle_maximum_name_bytes 255
  @oracle_maximum_event_segments 16
  @oracle_maximum_event_bytes 2_048
  # `:telemetry_test.attach_event_handlers/2` identifies its handler by the
  # returned reference, which no static detach signature can name.
  @telemetry_test_attachment {:telemetry_test, :attach_event_handlers}
  @defaults %{
    paths: ["test"],
    max_files: 5_000,
    max_total_bytes: 67_108_864,
    max_candidates: 500,
    max_duration_ms: 10_000
  }
  @maximums %{
    max_files: 20_000,
    max_total_bytes: 67_108_864,
    max_candidates: 2_000,
    max_duration_ms: 60_000
  }
  @option_keys [:paths, :max_files, :max_total_bytes, :max_candidates, :max_duration_ms]
  @scope_forms [:setup, :setup_all, :test, :def, :defp]
  @lexical_alias_forms [
    :fn,
    :defmodule,
    :def,
    :defp,
    :if,
    :unless,
    :case,
    :cond,
    :with,
    :for,
    :receive,
    :try,
    :->
  ]

  @signals %{
    "application_env_absence_not_restored" =>
      {12, "cleanup converts a previously absent application environment entry into a value"},
    "application_env_cleanup_present" =>
      {2, "mutates application environment and declares matching cleanup"},
    "application_env_mutation" =>
      {8, "mutates application environment without visible matching cleanup"},
    "explicit_test_serialization" => {3, "declares async: false"},
    "global_telemetry_cleanup_present" =>
      {1, "attaches a VM-global telemetry handler and declares matching cleanup"},
    "global_telemetry_handler" =>
      {7, "attaches a VM-global telemetry handler without visible matching cleanup"},
    "otel_global_capture" => {7, "changes or captures shared OpenTelemetry state"},
    "sleep_or_timer_wait" => {4, "uses elapsed time for synchronization"}
  }

  @spec scan(Path.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def scan(root, options \\ [])

  def scan(root, options) when is_binary(root) and is_list(options) do
    with {:ok, config} <- config(options),
         {:ok, expanded_root} <- root(root) do
      bounded_scan(expanded_root, config)
    end
  rescue
    _error -> {:error, :inventory_failed}
  catch
    _kind, _reason -> {:error, :inventory_failed}
  end

  def scan(_root, _options), do: {:error, :invalid_options}

  defp bounded_scan(root, config) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn -> send(caller, {reply_ref, do_scan(root, config)}) end,
        [
          :monitor,
          {:max_heap_size, %{size: 67_108_864, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :inventory_failed}
    after
      config.max_duration_ms ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok)
        {:error, :scan_timeout}
    end
  end

  defp do_scan(root, config) do
    with {:ok, walk} <- files(root, config.paths, config.max_files) do
      {:ok, inventory(root, walk, config)}
    end
  end

  defp config(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      config = Map.merge(@defaults, Map.new(options))

      valid? =
        keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @option_keys)) and
          paths?(config.paths) and
          Enum.all?(@maximums, fn {key, maximum} -> bounded?(Map.fetch!(config, key), maximum) end)

      if valid?, do: {:ok, config}, else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp root(root) do
    expanded = Path.expand(root)

    case File.lstat(expanded) do
      {:ok, %{type: :directory}} -> {:ok, expanded}
      _other -> {:error, :invalid_root}
    end
  end

  # Walks with lstat so directory symlinks are reported without enumerating
  # their targets. It stops after max_files + 1 eligible files.
  defp files(root, paths, max_files) do
    initial = %{files: MapSet.new(), unsupported: [], file_limit?: false}

    with {:ok, selectors} <- validate_selectors(root, paths) do
      result =
        Enum.reduce_while(selectors, initial, fn selector, accumulator ->
          case walk(selector, root, max_files, accumulator) do
            {:halt, next} -> {:halt, next}
            {:cont, next} -> {:cont, next}
          end
        end)

      selected = result.files |> MapSet.to_list() |> Enum.sort() |> Enum.take(max_files)
      {:ok, %{result | files: selected}}
    end
  end

  defp validate_selectors(root, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn selector, {:ok, selectors} ->
      expanded = Path.expand(selector, root)

      case validate_selector(root, expanded) do
        :ok -> {:cont, {:ok, [expanded | selectors]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, selectors} -> {:ok, Enum.reverse(selectors)}
      error -> error
    end
  end

  defp validate_selector(root, expanded) do
    if inside?(expanded, root) do
      expanded
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.reduce_while(root, fn component, parent ->
        path = Path.join(parent, component)

        case File.lstat(path) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :selector_symlink}}
          {:ok, _stat} -> {:cont, path}
          {:error, :enoent} -> {:halt, {:error, :selector_not_found}}
          {:error, _reason} -> {:halt, {:error, :selector_unavailable}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        _final_path -> :ok
      end
    else
      {:error, :selector_outside_root}
    end
  end

  defp walk(path, root, max_files, accumulator) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        unsupported = unsupported(root, path, "symlink_not_scanned")
        {:cont, %{accumulator | unsupported: [unsupported | accumulator.unsupported]}}

      {:ok, %{type: :regular}} ->
        add_file(path, max_files, accumulator)

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> walk_entries(Enum.sort(entries), path, root, max_files, accumulator)
          {:error, _reason} -> unavailable(path, root, accumulator)
        end

      {:ok, _other} ->
        {:cont, accumulator}

      {:error, _reason} ->
        unavailable(path, root, accumulator)
    end
  end

  defp walk_entries(entries, directory, root, max_files, accumulator) do
    Enum.reduce_while(entries, {:cont, accumulator}, fn entry, {:cont, current} ->
      case walk(Path.join(directory, entry), root, max_files, current) do
        {:cont, next} -> {:cont, {:cont, next}}
        {:halt, next} -> {:halt, {:halt, next}}
      end
    end)
  end

  defp add_file(path, max_files, accumulator) do
    if String.ends_with?(path, "_test.exs") do
      files = MapSet.put(accumulator.files, path)

      if MapSet.size(files) > max_files do
        {:halt, %{accumulator | files: files, file_limit?: true}}
      else
        {:cont, %{accumulator | files: files}}
      end
    else
      {:cont, accumulator}
    end
  end

  defp unavailable(path, root, accumulator) do
    item = unsupported(root, path, "source_unavailable")
    {:cont, %{accumulator | unsupported: [item | accumulator.unsupported]}}
  end

  defp inventory(root, walk, config) do
    initial = %{candidates: [], unsupported: [], sources: [], bytes: 0, byte_limit?: false}

    result =
      Enum.reduce_while(walk.files, initial, fn file, accumulator ->
        case read_bounded(file, config.max_total_bytes - accumulator.bytes) do
          {:ok, source} ->
            {:cont, scan_file(root, file, source, accumulator)}

          :limit ->
            {:halt, %{accumulator | byte_limit?: true}}

          {:error, reason} ->
            item = unsupported(root, file, reason)
            {:cont, %{accumulator | unsupported: [item | accumulator.unsupported]}}
        end
      end)

    candidates =
      result.candidates
      |> Enum.sort_by(&{-&1["score"], &1["path"]})
      |> Enum.take(config.max_candidates)

    truncation_reasons =
      []
      |> maybe_reason(walk.file_limit?, "file_limit")
      |> maybe_reason(result.byte_limit?, "byte_limit")
      |> maybe_reason(length(result.candidates) > length(candidates), "candidate_limit")
      |> Enum.sort()

    unsupported = Enum.sort_by(walk.unsupported ++ result.unsupported, & &1["path"])
    completeness = completeness(truncation_reasons, unsupported, walk.files)

    %{
      "schema" => @schema,
      "scanner_revision" => @scanner_revision,
      "classification" => "candidate_inventory",
      "status" => status(completeness, candidates),
      "completeness" => completeness,
      "root" => root,
      "paths" => config.paths,
      "candidate_count" => length(candidates),
      "candidates" => candidates,
      "eligible_file_count" => length(walk.files),
      "scanned_file_count" => length(result.sources),
      "scanned_bytes" => result.bytes,
      "unsupported" => unsupported,
      "truncated" => truncation_reasons != [],
      "truncation_reasons" => truncation_reasons,
      "configuration_fingerprint" => fingerprint(config_wire(config)),
      "source_fingerprint" => fingerprint(Enum.sort(result.sources)),
      "limitations" => [
        "static_signals_do_not_confirm_runtime_causality",
        "only_explicit_reason_patterns_are_visible",
        "only_elixir_test_sources_are_interpreted"
      ]
    }
  end

  # One state per scan, by fixed precedence: a hit bound, then sources that
  # could not be analyzed, then a selection with no eligible test file. The
  # other conditions stay visible in `truncation_reasons`, `unsupported`, and
  # `eligible_file_count`.
  defp completeness([_reason | _reasons], _unsupported, _files), do: "truncated"
  defp completeness([], [_item | _items], _files), do: "unsupported_source"
  defp completeness([], [], []), do: "empty_selection"
  defp completeness([], [], _files), do: "complete"

  defp status("complete", []), do: "clean"
  defp status("complete", _candidates), do: "candidates"
  defp status(incomplete, _candidates), do: incomplete

  defp read_bounded(_file, remaining) when remaining <= 0, do: :limit

  defp read_bounded(file, remaining) do
    with {:ok, io} <- File.open(file, [:read, :binary]) do
      try do
        case IO.binread(io, remaining + 1) do
          data when is_binary(data) and byte_size(data) <= remaining -> {:ok, data}
          data when is_binary(data) -> :limit
          :eof -> {:ok, ""}
          {:error, _reason} -> {:error, "source_unavailable"}
        end
      after
        File.close(io)
      end
    else
      {:error, _reason} -> {:error, "source_unavailable"}
    end
  end

  defp scan_file(root, file, source, accumulator) do
    relative = Path.relative_to(file, root)
    source_fingerprint = fingerprint(source)
    source_entry = {relative, source_fingerprint}
    static_atom_marker = make_ref()

    accumulator = %{
      accumulator
      | bytes: accumulator.bytes + byte_size(source),
        sources: [source_entry | accumulator.sources]
    }

    case Code.string_to_quoted(source,
           file: relative,
           columns: true,
           static_atoms_encoder: fn name, meta ->
             encode_static_atom(name, meta, static_atom_marker)
           end
         ) do
      {:ok, ast} ->
        case candidate(relative, source_fingerprint, ast) do
          nil -> accumulator
          candidate -> %{accumulator | candidates: [candidate | accumulator.candidates]}
        end

      {:error, _reason} ->
        item = %{"path" => relative, "reason" => "invalid_elixir_syntax"}
        %{accumulator | unsupported: [item | accumulator.unsupported]}
    end
  end

  defp candidate(path, source_fingerprint, ast) do
    facts = ast_facts(ast)

    if facts.exunit? do
      {targets, targets_truncated?} = bounded_targets(facts.targets)

      reasons =
        facts
        |> normalize_signals()
        |> Enum.map(fn {code, lines} ->
          {weight, evidence} = Map.fetch!(@signals, code)

          %{
            "code" => code,
            "weight" => weight,
            "lines" => Enum.sort(lines),
            "evidence" => evidence
          }
        end)
        |> Enum.sort_by(& &1["code"])

      if reasons != [] do
        %{
          "id" => fingerprint({path, source_fingerprint, reasons, targets, targets_truncated?}),
          "classification" => "candidate",
          "path" => path,
          "source_fingerprint" => source_fingerprint,
          "score" => Enum.sum(Enum.map(reasons, & &1["weight"])),
          "reasons" => reasons,
          "target_count" => length(targets),
          "targets" => targets,
          "targets_truncated" => targets_truncated?
        }
      end
    end
  end

  defp ast_facts(ast) do
    ast = strip_subtrees(ast, :quote)
    executable = strip_subtrees(ast, :on_exit)
    scoped = scoped_mutation_evidence(ast)

    initial = %{
      exunit?: false,
      signals: scoped.signals,
      targets: scoped.targets
    }

    {_ast, facts} =
      Macro.prewalk(executable, initial, fn node, facts -> {node, observe_ast(node, facts)} end)

    facts
  end

  defp scoped_mutation_evidence(ast) do
    case top_level_defmodules(ast) do
      [_module] ->
        scan_scopes(ast, {module_body_aliases(ast), module_body_application_aliases(ast)})

      [] ->
        scan_scopes(ast, {:disabled, []})

      _modules ->
        ast
        |> block_expressions()
        |> Enum.reduce(%{signals: %{}, targets: []}, fn expression, evidence ->
          aliases =
            case expression do
              {:defmodule, _, _} ->
                {module_body_aliases(expression), module_body_application_aliases(expression)}

              _other ->
                {:disabled, []}
            end

          scoped = scan_scopes(expression, aliases)

          %{
            signals: merge_signal_maps(evidence.signals, scoped.signals),
            targets: evidence.targets ++ scoped.targets
          }
        end)
    end
  end

  defp scan_scopes(ast, aliases) do
    initial = %{signals: %{}, targets: [], aliases: aliases, alias_stack: []}

    {_ast, evidence} =
      Macro.traverse(
        ast,
        initial,
        fn
          {:defmodule, _meta, _arguments} = node, evidence ->
            nested = {module_body_aliases(node), module_body_application_aliases(node)}

            {node,
             %{evidence | aliases: nested, alias_stack: [evidence.aliases | evidence.alias_stack]}}

          {form, _meta, arguments} = node, evidence
          when form in @scope_forms and is_list(arguments) ->
            scoped = mutation_evidence(node, evidence.aliases)

            {node,
             %{
               evidence
               | signals: merge_signal_maps(evidence.signals, scoped.signals),
                 targets: scoped.targets ++ evidence.targets
             }}

          node, evidence ->
            {node, evidence}
        end,
        fn
          {:defmodule, _meta, _arguments} = node, %{alias_stack: [outer | rest]} = evidence ->
            {node, %{evidence | aliases: outer, alias_stack: rest}}

          node, evidence ->
            {node, evidence}
        end
      )

    %{signals: evidence.signals, targets: evidence.targets}
  end

  defp mutation_evidence(scope, {outer_aliases, outer_application_aliases}) do
    aliases = aliases_from_scope_body(scope, outer_aliases)
    cleanup_aliases = application_aliases_from_scope_body(scope, outer_application_aliases)
    cleanup = cleanup_facts(scope, cleanup_aliases)

    initial = %{
      application_mutations: %{},
      application_deletions: MapSet.new(),
      application_cleanups: cleanup.application_cleanups,
      application_put_cleanups: cleanup.application_put_cleanups,
      absence_destroying_cleanups: cleanup.absence_destroying_cleanups,
      telemetry_attachments: %{},
      telemetry_cleanups: cleanup.telemetry_cleanups,
      aliases: aliases,
      application_aliases: outer_application_aliases,
      application_alias_stack: [],
      targets: []
    }

    {_ast, facts} =
      scope
      |> strip_subtrees(:on_exit)
      |> Macro.traverse(
        initial,
        fn
          {form, _meta, arguments} = node, facts
          when form in @lexical_alias_forms and is_list(arguments) ->
            {node, enter_application_scope(facts, form)}

          {:alias, meta, arguments} = node, facts ->
            declarations =
              record_application_aliases(arguments, position(meta), facts.application_aliases)

            {node, %{facts | application_aliases: declarations}}

          node, facts ->
            {node, observe_mutation_ast(node, facts)}
        end,
        fn
          {form, _meta, arguments} = node, %{application_alias_stack: [_outer | _rest]} = facts
          when form in @lexical_alias_forms and is_list(arguments) ->
            {node, exit_application_scope(facts)}

          node, facts ->
            {node, facts}
        end
      )

    %{signals: normalize_mutation_signals(facts), targets: facts.targets}
  end

  defp enter_application_scope(facts, form) do
    declarations = if form == :defmodule, do: [], else: facts.application_aliases

    %{
      facts
      | application_aliases: declarations,
        application_alias_stack: [facts.application_aliases | facts.application_alias_stack]
    }
  end

  defp exit_application_scope(%{application_alias_stack: [outer | rest]} = facts),
    do: %{facts | application_aliases: outer, application_alias_stack: rest}

  defp cleanup_facts(ast, application_aliases) do
    initial = %{
      application_cleanups: MapSet.new(),
      application_put_cleanups: MapSet.new(),
      absence_destroying_cleanups: MapSet.new(),
      telemetry_cleanups: MapSet.new()
    }

    {_ast, facts} =
      Macro.prewalk(ast, initial, fn
        {:on_exit, _meta, arguments} = node, facts ->
          app = find_application_signatures(arguments, application_aliases)
          puts = find_application_put_signatures(arguments, application_aliases)
          telemetry = find_telemetry_detach_signatures(arguments)
          absence = if contains_absence_destroying_default?(node), do: app, else: MapSet.new()

          {node,
           %{
             facts
             | application_cleanups: MapSet.union(facts.application_cleanups, app),
               application_put_cleanups: MapSet.union(facts.application_put_cleanups, puts),
               absence_destroying_cleanups:
                 MapSet.union(facts.absence_destroying_cleanups, absence),
               telemetry_cleanups: MapSet.union(facts.telemetry_cleanups, telemetry)
           }}

        node, facts ->
          {node, facts}
      end)

    facts
  end

  defp observe_ast({:use, meta, [module | options]}, facts) do
    module = module_name(module)

    if module in ["ExUnit.Case", "ExUnit.CaseTemplate"] or String.ends_with?(module, "Case") do
      facts = %{facts | exunit?: true}

      if Enum.any?(options, &(is_list(&1) and Keyword.get(&1, :async) == false)),
        do: signal(facts, "explicit_test_serialization", meta),
        else: facts
    else
      facts
    end
  end

  defp observe_ast({{:., _dot_meta, [module, function]}, meta, _arguments}, facts) do
    module = module_name(module)

    cond do
      module in ["Process", ":timer"] and function == :sleep ->
        signal(facts, "sleep_or_timer_wait", meta)

      otel_module?(module) and function in [:set_tracer_provider, :set_text_map_propagator] ->
        signal(facts, "otel_global_capture", meta)

      true ->
        facts
    end
  end

  defp observe_ast({:setup_otel_capture, meta, arguments}, facts) when is_list(arguments),
    do: signal(facts, "otel_global_capture", meta)

  defp observe_ast({:test, _meta, [name | _arguments]}, facts) when is_binary(name),
    do: %{facts | exunit?: true}

  defp observe_ast(_node, facts), do: facts

  defp observe_mutation_ast({{:., _dot_meta, [module, function]}, meta, arguments}, facts) do
    case {module_name(module), function} do
      {"Application", function} when function in [:put_env, :delete_env] ->
        if application_callee?(module, facts.application_aliases, position(meta)) do
          facts
          |> signature_signal(:application_mutations, application_signature(arguments), meta)
          |> mark_application_deletion(function, arguments)
          |> add_application_target(function, arguments, meta, "syntactic")
        else
          facts
        end

      {"Elixir.Application", function} when function in [:put_env, :delete_env] ->
        facts
        |> signature_signal(:application_mutations, application_signature(arguments), meta)
        |> mark_application_deletion(function, arguments)
        |> add_application_target(function, arguments, meta, "resolved")

      {":telemetry", function} when function in [:attach, :attach_many] ->
        facts
        |> signature_signal(:telemetry_attachments, first_argument_signature(arguments), meta)
        |> add_telemetry_target(function, arguments, meta)
        |> add_telemetry_event_targets(function, arguments, meta)

      {":telemetry_test", :attach_event_handlers} ->
        facts
        |> signature_signal(:telemetry_attachments, @telemetry_test_attachment, meta)
        |> add_telemetry_event_targets(:attach_event_handlers, arguments, meta)

      _other ->
        facts
    end
  end

  defp observe_mutation_ast(_node, facts), do: facts

  defp normalize_signals(facts), do: facts.signals

  defp normalize_mutation_signals(facts) do
    # A second delete cannot restore a value removed by the first one.
    non_restoring_deletions =
      MapSet.difference(facts.application_deletions, facts.application_put_cleanups)

    application_cleanups =
      MapSet.difference(facts.application_cleanups, non_restoring_deletions)

    %{}
    |> merge_signature_signals(
      facts.application_mutations,
      application_cleanups,
      facts.absence_destroying_cleanups,
      "application_env_mutation",
      "application_env_cleanup_present",
      "application_env_absence_not_restored"
    )
    |> merge_signature_signals(
      facts.telemetry_attachments,
      facts.telemetry_cleanups,
      MapSet.new(),
      "global_telemetry_handler",
      "global_telemetry_cleanup_present",
      nil
    )
  end

  defp merge_signature_signals(signals, mutations, cleanups, dangerous, raw, clean, lossy) do
    Enum.reduce(mutations, signals, fn {signature, lines}, accumulator ->
      code =
        cond do
          lossy && MapSet.member?(dangerous, signature) -> lossy
          MapSet.member?(cleanups, signature) -> clean
          true -> raw
        end

      Map.update(accumulator, code, lines, &(lines ++ &1))
    end)
  end

  defp merge_signal_maps(left, right) do
    Map.merge(left, right, fn _code, left_lines, right_lines ->
      Enum.uniq(left_lines ++ right_lines)
    end)
  end

  defp add_application_target(facts, operation, arguments, meta, status) do
    identity =
      case arguments do
        [application, key | _rest] ->
          with {:ok, application} <- static_atom(application),
               {:ok, key, key_status} <- static_key(key, facts.aliases, position(meta)) do
            status = if key_status == :alias, do: "syntactic", else: status

            target = %{
              "application" => application,
              "key" => key,
              "kind" => "application_env",
              "operation" => Atom.to_string(operation),
              "oracle" => application_env_oracle(application, key),
              "status" => status
            }

            if status == "syntactic",
              do: Map.put(target, "reason", syntactic_reason(key_status)),
              else: target
          else
            _error -> unresolved_target("application_env", operation)
          end

        _arguments ->
          unresolved_target("application_env", operation)
      end

    add_target(facts, identity, meta)
  end

  defp add_telemetry_target(facts, operation, arguments, meta) do
    identity =
      case arguments do
        [handler | _rest] ->
          case static_atom(handler) do
            {:ok, handler} ->
              %{
                "handler" => handler,
                "kind" => "telemetry_handler",
                "operation" => Atom.to_string(operation),
                "oracle" => nil,
                "status" => "resolved"
              }

            :error ->
              unresolved_target("telemetry_handler", operation)
          end

        _arguments ->
          unresolved_target("telemetry_handler", operation)
      end

    add_target(facts, identity, meta)
  end

  # `:telemetry.attach/4` names one event; `:telemetry.attach_many/4` and
  # `:telemetry_test.attach_event_handlers/2` name a list of events. A dynamic
  # list or element becomes one unresolved target; identical unresolved targets
  # from the same call collapse during deduplication.
  defp add_telemetry_event_targets(facts, operation, arguments, meta) do
    operation
    |> telemetry_event_arguments(arguments)
    |> Enum.reduce(facts, fn event, facts ->
      add_target(facts, telemetry_event_target(operation, event), meta)
    end)
  end

  defp telemetry_event_arguments(:attach, [_handler, event | _rest]), do: [event]

  defp telemetry_event_arguments(_operation, [_first, events | _rest]) when is_list(events),
    do: events

  defp telemetry_event_arguments(_operation, [_first, events | _rest]), do: [events]
  defp telemetry_event_arguments(_operation, _arguments), do: [nil]

  defp telemetry_event_target(operation, event) when is_list(event) and event != [] do
    case static_atoms(event) do
      {:ok, segments} ->
        %{
          "event" => segments,
          "kind" => "telemetry_event",
          "operation" => Atom.to_string(operation),
          "oracle" => telemetry_event_oracle(segments),
          "status" => "resolved"
        }

      :error ->
        unresolved_target("telemetry_event", operation)
    end
  end

  defp telemetry_event_target(operation, _event),
    do: unresolved_target("telemetry_event", operation)

  defp unresolved_target(kind, operation, reason \\ "dynamic_identity"),
    do: %{
      "kind" => kind,
      "operation" => Atom.to_string(operation),
      "oracle" => nil,
      "reason" => reason,
      "status" => "unresolved"
    }

  # Oracle hints are static data: the fixed artifact's schema and the exact
  # environment inputs it validates. They are omitted when the artifact would
  # reject or reinterpret the encoded identity, or when the value could not be
  # passed through the environment at all (NUL and other control characters).
  defp application_env_oracle(application, key) do
    if oracle_name?(application) and oracle_name?(key) do
      %{
        "schema" => @application_env_oracle_schema,
        "inputs" => %{
          "INSIDER_ORACLE_APPLICATION" => application,
          "INSIDER_ORACLE_KEY" => key
        }
      }
    end
  end

  defp telemetry_event_oracle(segments) do
    encoded = Enum.join(segments, ",")

    if length(segments) <= @oracle_maximum_event_segments and
         byte_size(encoded) <= @oracle_maximum_event_bytes and
         Enum.all?(segments, &oracle_segment?/1) do
      %{
        "schema" => @telemetry_event_oracle_schema,
        "inputs" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => encoded}
      }
    end
  end

  defp oracle_name?(name),
    do: byte_size(name) in 1..@oracle_maximum_name_bytes and control_free?(name)

  defp oracle_segment?(segment), do: oracle_name?(segment) and not String.contains?(segment, ",")

  # Bytes below 0x20 are exactly the ASCII control code points in UTF-8;
  # continuation bytes never fall in that range.
  defp control_free?(<<byte, rest::binary>>) when byte >= 0x20, do: control_free?(rest)
  defp control_free?(<<>>), do: true
  defp control_free?(_name), do: false

  defp add_target(facts, target, meta) do
    target = Map.put(target, "lines", [Keyword.get(meta, :line, 0)])
    %{facts | targets: [target | facts.targets]}
  end

  defp bounded_targets(targets) do
    targets =
      targets
      |> Enum.group_by(&Map.drop(&1, ["lines"]))
      |> Enum.map(fn {identity, entries} ->
        lines = entries |> Enum.flat_map(& &1["lines"]) |> Enum.uniq() |> Enum.sort()
        Map.put(identity, "lines", lines)
      end)
      |> Enum.sort_by(&fingerprint/1)

    {Enum.take(targets, @maximum_targets_per_candidate),
     length(targets) > @maximum_targets_per_candidate}
  end

  defp static_atom(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp static_atom({marker, value}) when is_reference(marker) and is_binary(value),
    do: {:ok, value}

  defp static_atom(_value), do: :error

  defp static_key(value, aliases, position) do
    case static_atom(value) do
      {:ok, key} -> {:ok, key, :literal}
      :error -> static_alias_key(value, aliases, position)
    end
  end

  defp static_alias_key({:__aliases__, _meta, parts}, aliases, position)
       when is_list(parts) and parts != [] do
    with {:ok, names} <- static_atoms(parts) do
      case resolve_alias_names(names, aliases, position) do
        {:ok, key} -> {:ok, key, :alias}
        :error -> :error
      end
    end
  end

  defp static_alias_key(_value, _aliases, _line), do: :error

  defp static_atoms(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, names} ->
      case static_atom(part) do
        {:ok, name} -> {:cont, {:ok, [name | names]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  defp resolve_alias_names(["Elixir" | rest], _aliases, _position) when rest != [],
    do: {:ok, Enum.join(["Elixir" | rest], ".")}

  defp resolve_alias_names(_names, aliases, _position) when not is_map(aliases), do: :error

  defp resolve_alias_names([local | rest], aliases, position) do
    case Map.get(aliases, local) do
      %{position: alias_position, target: target} when alias_position < position ->
        {:ok, Enum.join([target | rest], ".")}

      _unresolved ->
        :error
    end
  end

  defp module_body_aliases(ast) do
    case top_level_defmodules(ast) do
      [{:defmodule, _meta, [_name, body]}] -> aliases_from_module_body(body)
      _other -> :disabled
    end
  end

  defp top_level_defmodules({:__block__, _meta, expressions}),
    do: Enum.filter(expressions, &match?({:defmodule, _, _}, &1))

  defp top_level_defmodules({:defmodule, _meta, _arguments} = module), do: [module]
  defp top_level_defmodules(_ast), do: []

  defp aliases_from_module_body(body) do
    expressions = body |> Keyword.get(:do) |> block_expressions()

    if Enum.any?(expressions, &unsupported_module_alias?/1) do
      :disabled
    else
      aliases_from_expressions(expressions, %{})
    end
  end

  defp module_body_application_aliases(ast) do
    case top_level_defmodules(ast) do
      [{:defmodule, _meta, [_name, body]}] ->
        body
        |> Keyword.get(:do)
        |> block_expressions()
        |> application_aliases_from_expressions([])

      _other ->
        []
    end
  end

  defp unsupported_module_alias?({:alias, _meta, _arguments}), do: false

  defp unsupported_module_alias?({form, _meta, arguments})
       when form in @scope_forms and is_list(arguments),
       do: false

  defp unsupported_module_alias?(expression),
    do: contains?(expression, &match?({:alias, _, _}, &1))

  defp aliases_from_scope_body(_scope, :disabled), do: :disabled

  defp aliases_from_scope_body({_form, _meta, arguments} = scope, outer)
       when is_list(arguments) do
    expressions =
      arguments
      |> List.last()
      |> case do
        body when is_list(body) -> body |> Keyword.get(:do) |> block_expressions()
        _other -> []
      end

    if alias_count(scope) > Enum.count(expressions, &match?({:alias, _, _}, &1)) do
      :disabled
    else
      aliases_from_expressions(expressions, outer)
    end
  end

  defp aliases_from_scope_body(_scope, outer), do: outer

  defp application_aliases_from_scope_body({_form, _meta, arguments}, outer)
       when is_list(arguments) do
    arguments
    |> List.last()
    |> case do
      body when is_list(body) -> body |> Keyword.get(:do) |> block_expressions()
      _other -> []
    end
    |> application_aliases_from_expressions(outer)
  end

  defp application_aliases_from_scope_body(_scope, outer), do: outer

  # Key aliases can be disabled without losing a lexical Application binding.
  # Keep all simple declarations so chained aliases still resolve in that mode.
  defp application_aliases_from_expressions(expressions, outer) do
    Enum.reduce(expressions, outer, fn
      {:alias, meta, arguments}, declarations ->
        record_application_aliases(arguments, position(meta), declarations)

      _expression, declarations ->
        declarations
    end)
  end

  defp record_application_aliases(arguments, at, declarations) do
    aliases = visible_application_aliases(declarations, at)

    case simple_alias(arguments, aliases, at) do
      {:ok, local, target} ->
        [{at, local, target} | declarations]

      :error ->
        case grouped_application_aliases(arguments, aliases, at) do
          {:ok, entries} ->
            Enum.reduce(entries, declarations, fn {local, target}, acc ->
              [{at, local, target} | acc]
            end)

          :error ->
            if application_alias_declaration?(arguments),
              do: [{at, "Application", :unknown} | declarations],
              else: declarations
        end
    end
  end

  defp visible_application_aliases(declarations, at) do
    Enum.reduce(declarations, %{}, fn {position, local, target}, aliases ->
      if position < at and not Map.has_key?(aliases, local) do
        value = if is_binary(target), do: %{position: position, target: target}, else: :ambiguous
        Map.put(aliases, local, value)
      else
        aliases
      end
    end)
  end

  defp grouped_application_aliases(
         [{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}],
         aliases,
         at
       )
       when is_list(members) do
    with {:ok, names} <- static_atoms(base),
         {:ok, prefix} <- grouped_alias_prefix(names, aliases, at) do
      Enum.reduce_while(members, {:ok, []}, fn
        {:__aliases__, _, parts}, {:ok, entries} ->
          case static_atoms(parts) do
            {:ok, names} when names != [] ->
              {:cont,
               {:ok, [{List.last(names), prefix <> "." <> Enum.join(names, ".")} | entries]}}

            _other ->
              {:halt, :error}
          end

        _other, _entries ->
          {:halt, :error}
      end)
    end
  end

  defp grouped_application_aliases(_arguments, _aliases, _at), do: :error

  defp grouped_alias_prefix(["Elixir"], _aliases, _at), do: {:ok, "Elixir"}
  defp grouped_alias_prefix(names, aliases, at), do: resolve_alias_declaration(names, aliases, at)

  defp application_alias_declaration?([target, options]) when is_list(options) do
    case Keyword.fetch(options, :as) do
      {:ok, {:__aliases__, _, [:Application]}} -> true
      {:ok, _other} -> false
      :error -> application_alias_declaration?([target])
    end
  end

  defp application_alias_declaration?([target]) do
    {_target, found?} =
      Macro.prewalk(target, false, fn
        {:__aliases__, _meta, parts} = node, found? ->
          {node, found? or List.last(parts) == :Application}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp application_alias_declaration?(_arguments), do: false

  defp aliases_from_expressions(expressions, initial) do
    Enum.reduce_while(expressions, initial, fn
      {:alias, meta, arguments}, aliases ->
        case add_module_alias(aliases, arguments, meta) do
          :disabled -> {:halt, :disabled}
          next -> {:cont, next}
        end

      _expression, aliases ->
        {:cont, aliases}
    end)
  end

  defp alias_count(term) do
    {_term, count} =
      Macro.prewalk(term, 0, fn
        {:alias, _meta, _arguments} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]

  defp add_module_alias(aliases, arguments, meta) do
    alias_position = position(meta)

    case simple_alias(arguments, aliases, alias_position) do
      {:ok, local, target} ->
        entry = %{position: alias_position, target: target}
        Map.update(aliases, local, entry, fn _existing -> :ambiguous end)

      :error ->
        :disabled
    end
  end

  defp simple_alias([target], aliases, position),
    do: simple_alias(target, nil, aliases, position)

  defp simple_alias([target, options], aliases, position) when is_list(options),
    do: simple_alias(target, Keyword.get(options, :as), aliases, position)

  defp simple_alias(_arguments, _aliases, _position), do: :error

  defp simple_alias({:__aliases__, _meta, parts}, explicit_local, aliases, position)
       when is_list(parts) do
    with {:ok, names} <- static_atoms(parts),
         true <- names != [],
         {:ok, local} <- alias_local_name(explicit_local, List.last(names)),
         {:ok, target} <- resolve_alias_declaration(names, aliases, position) do
      {:ok, local, target}
    else
      _error -> :error
    end
  end

  defp simple_alias(_target, _explicit_local, _aliases, _position), do: :error

  defp resolve_alias_declaration(["Elixir" | rest] = names, _aliases, _position)
       when rest != [],
       do: {:ok, Enum.join(names, ".")}

  defp resolve_alias_declaration(_names, aliases, _position) when not is_map(aliases), do: :error

  defp resolve_alias_declaration([local | rest] = names, aliases, position) do
    case Map.get(aliases, local) do
      %{position: alias_position, target: target} when alias_position < position ->
        {:ok, Enum.join([target | rest], ".")}

      nil ->
        {:ok, "Elixir." <> Enum.join(names, ".")}

      _unresolved ->
        :error
    end
  end

  defp alias_local_name(nil, default), do: {:ok, default}

  defp alias_local_name({:__aliases__, _meta, [local]}, _default),
    do: static_atom(local)

  defp alias_local_name(_explicit, _default), do: :error

  defp syntactic_reason(:alias), do: "lexical_alias_without_macro_expansion"
  defp syntactic_reason(:literal), do: "unqualified_module"

  defp position(meta),
    do: {Keyword.get(meta, :line, 0), Keyword.get(meta, :column, 0)}

  defp static_atom_part(value), do: elem(static_atom(value), 1)

  defp application_callee?(module, declarations, call_position) do
    case module_name(module) do
      "Elixir.Application" ->
        true

      "Application" ->
        case Enum.find(declarations, fn {position, local, _target} ->
               local == "Application" and position < call_position
             end) do
          nil -> true
          {_position, _local, "Elixir.Application"} -> true
          _shadow_or_unknown -> false
        end

      _other ->
        false
    end
  end

  defp signal(facts, code, meta) do
    line = Keyword.get(meta, :line, 0)
    %{facts | signals: Map.update(facts.signals, code, [line], &[line | &1])}
  end

  defp signature_signal(facts, _field, nil, _meta), do: facts

  defp signature_signal(facts, field, signature, meta) do
    line = Keyword.get(meta, :line, 0)
    values = Map.update(Map.fetch!(facts, field), signature, [line], &[line | &1])
    Map.put(facts, field, values)
  end

  defp mark_application_deletion(facts, :delete_env, arguments) do
    case application_signature(arguments) do
      nil ->
        facts

      signature ->
        %{facts | application_deletions: MapSet.put(facts.application_deletions, signature)}
    end
  end

  defp mark_application_deletion(facts, _function, _arguments), do: facts

  defp find_application_signatures(term, application_aliases),
    do: find_application_signatures(term, [:put_env, :delete_env], application_aliases)

  defp find_application_put_signatures(term, application_aliases),
    do: find_application_signatures(term, [:put_env], application_aliases)

  defp find_application_signatures(term, functions, application_aliases) do
    initial = %{
      signatures: MapSet.new(),
      application_aliases: application_aliases,
      application_alias_stack: []
    }

    {_term, facts} =
      Macro.traverse(
        term,
        initial,
        fn
          {form, _meta, arguments} = node, facts
          when form in @lexical_alias_forms and is_list(arguments) ->
            {node, enter_application_scope(facts, form)}

          {:alias, meta, arguments} = node, facts ->
            declarations =
              record_application_aliases(arguments, position(meta), facts.application_aliases)

            {node, %{facts | application_aliases: declarations}}

          {{:., _meta, [module, function]}, meta, arguments} = node, facts ->
            signature =
              if function in functions and
                   application_callee?(module, facts.application_aliases, position(meta)),
                 do: application_signature(arguments)

            if signature,
              do: {node, %{facts | signatures: MapSet.put(facts.signatures, signature)}},
              else: {node, facts}

          node, facts ->
            {node, facts}
        end,
        fn
          {form, _meta, arguments} = node, %{application_alias_stack: [_outer | _rest]} = facts
          when form in @lexical_alias_forms and is_list(arguments) ->
            {node, exit_application_scope(facts)}

          node, facts ->
            {node, facts}
        end
      )

    facts.signatures
  end

  defp find_telemetry_detach_signatures(term),
    do:
      find_signatures(term, fn
        {{:., _meta, [:telemetry, :detach]}, _, arguments} -> first_argument_signature(arguments)
        _node -> nil
      end)

  defp find_signatures(term, mapper) do
    {_term, signatures} =
      Macro.prewalk(term, MapSet.new(), fn node, signatures ->
        case mapper.(node) do
          nil -> {node, signatures}
          signature -> {node, MapSet.put(signatures, signature)}
        end
      end)

    signatures
  end

  defp application_signature([app, key | _rest]), do: {ast_identity(app), ast_identity(key)}
  defp application_signature(_arguments), do: nil
  defp first_argument_signature([argument | _rest]), do: ast_identity(argument)
  defp first_argument_signature(_arguments), do: nil

  defp ast_identity(ast) do
    ast
    |> Macro.prewalk(fn
      {name, meta, arguments} when is_list(meta) -> {name, [], arguments}
      node -> node
    end)
    |> :erlang.term_to_binary([:deterministic])
  end

  defp contains_absence_destroying_default?(term),
    do:
      contains?(term, fn
        {:||, _meta, [_value, []]} -> true
        _node -> false
      end)

  defp contains?(term, predicate) do
    {_term, found?} =
      Macro.prewalk(term, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end

  defp strip_subtrees(ast, name),
    do:
      Macro.prewalk(ast, fn
        {^name, meta, _arguments} -> {:__insider_ignored__, meta, []}
        node -> node
      end)

  defp encode_static_atom(name, _meta, marker) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:ok, {marker, name}}
  end

  defp module_name({:__aliases__, _meta, parts}),
    do: Enum.map_join(parts, ".", &static_atom_part/1)

  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_module), do: "unknown"
  defp otel_module?("OpenTelemetry" <> _rest), do: true
  defp otel_module?(":otel" <> _rest), do: true
  defp otel_module?(_module), do: false

  defp unsupported(root, file, reason),
    do: %{"path" => Path.relative_to(file, root), "reason" => reason}

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp paths?(paths),
    do:
      is_list(paths) and paths != [] and length(paths) <= 32 and
        Enum.all?(paths, &(is_binary(&1) and byte_size(&1) in 1..1_024))

  defp bounded?(value, maximum), do: is_integer(value) and value in 1..maximum
  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp config_wire(config),
    do: %{
      "paths" => config.paths,
      "max_files" => config.max_files,
      "max_total_bytes" => config.max_total_bytes,
      "max_candidates" => config.max_candidates,
      "max_duration_ms" => config.max_duration_ms,
      "scanner_revision" => @scanner_revision,
      "signals" =>
        @signals |> Enum.map(fn {code, {weight, _}} -> {code, weight} end) |> Enum.sort()
    }

  defp fingerprint(value) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end
end
