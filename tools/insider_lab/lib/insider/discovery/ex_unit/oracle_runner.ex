defmodule Insider.Discovery.ExUnit.OracleRunner do
  @moduledoc false

  # Runs one fixed oracle artifact against one selected test command in a
  # target Mix project without editing the target. The oracle and the runner's
  # two fixed files are copied into the caller's run directory and executed
  # from there, so the recorded digests name the exact bytes that ran.

  alias Insider.Discovery.ExUnit.OracleRunner.Command
  alias Insider.Discovery.ExUnit.OracleRunner.Oracle
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy
  alias Insider.Discovery.ExUnit.OracleRunner.Record
  alias Insider.Discovery.ExUnit.OracleRunner.SafePath
  alias Insider.Discovery.ExUnit.OracleRunner.Target

  @refused_prefix "INSIDER_ORACLE_RUNNER_REFUSED="
  @helpers_prefix "INSIDER_ORACLE_RUNNER_HELPERS="
  @suite_prefix "INSIDER_ORACLE_RUNNER_SUITE="
  @bootstrap "runner/mix.exs"
  @overlay "runner/overlay/test_helper.exs"
  @changed_path_limit 32

  @type request :: %{
          run_id: String.t(),
          oracle_id: String.t(),
          inputs: [{String.t(), String.t()}],
          context: String.t(),
          profile: %{document: map(), path: String.t(), sha256: String.t()},
          resolved: map(),
          inherited: [{String.t(), String.t()}],
          root: String.t(),
          output: String.t(),
          test_arguments: [String.t()],
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          output_policy: String.t(),
          fingerprint_budget: map(),
          paths: %{String.t() => Path.t()}
        }

  @spec oracle_ids() :: [String.t()]
  def oracle_ids, do: Oracle.ids()

  @spec execute(request()) :: {:ok, map(), binary()} | {:error, String.t()}
  def execute(request) do
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)
    oracle = Oracle.fetch!(request.oracle_id)

    with {:ok, paths} <- runner_paths(request.output, request.root, oracle),
         :ok <- create_output(request.output),
         {:ok, staged} <- stage(request.output, oracle) do
      request = Map.put(request, :paths, paths)
      observed = observe(request, oracle, staged)
      saved = OutputPolicy.apply(request.output_policy, observed.command, secrets(request))
      duration = System.monotonic_time(:millisecond) - started
      times = {started_at, DateTime.utc_now(), duration}
      record = record(request, oracle, staged, observed, saved, times)
      save(request.output, record, saved.text)
    end
  end

  defp secrets(request), do: Enum.map(request.resolved.passthrough, &elem(&1, 1))

  defp create_output(output) do
    case File.mkdir(output) do
      :ok -> :ok
      {:error, _reason} -> {:error, "output_unavailable"}
    end
  end

  # Copies the oracle and the two runner files into the run directory. The
  # oracle must be the closed registry's own entry, and every source and
  # destination name must be a plain relative name that stays under its base,
  # checked before anything is read or written.
  @doc false
  @spec stage(Path.t(), map()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def stage(output, oracle) do
    case plan(output, oracle) do
      {:ok, copies} -> copy(copies)
      :error -> {:error, "artifact_path_unsafe"}
    end
  end

  # The runner-owned paths the child receives, taken from the same validated
  # staging plan as the files `stage/2` writes, so the two cannot diverge; the
  # host `mix.exs` goes through the same helper under the resolved root.
  @doc false
  @spec runner_paths(Path.t(), Path.t(), map()) ::
          {:ok, %{String.t() => Path.t()}} | {:error, String.t()}
  def runner_paths(output, root, oracle) do
    with {:ok, copies} <- plan(output, oracle),
         {:ok, host} <- SafePath.join_under(root, "mix.exs") do
      destination = fn relative -> copies |> List.keyfind(relative, 0) |> elem(2) end

      {:ok,
       %{
         "MIX_EXS" => destination.(@bootstrap),
         "INSIDER_ORACLE_RUNNER_HOST_MIX_EXS" => host,
         "INSIDER_ORACLE_RUNNER_ORACLE" => destination.("oracle/" <> oracle.file),
         "INSIDER_ORACLE_RUNNER_OVERLAY" => Path.dirname(destination.(@overlay))
       }}
    else
      _unsafe -> {:error, "artifact_path_unsafe"}
    end
  end

  defp plan(output, oracle) do
    if registered?(oracle) do
      resolve_copies(output, Application.app_dir(:insider_lab, "priv"), [
        {"oracle/" <> oracle.file, "oracles/" <> oracle.file},
        {@bootstrap, "oracle_runner/mix.exs"},
        {@overlay, "oracle_runner/overlay/test_helper.exs"}
      ])
    else
      :error
    end
  end

  defp registered?(%{id: id, file: file}) when is_binary(id),
    do: id in Oracle.ids() and Oracle.fetch!(id).file == file

  defp registered?(_oracle), do: false

  defp resolve_copies(output, priv, pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {relative, source}, {:ok, copies} ->
      with {:ok, destination} <- SafePath.join_under(output, relative),
           {:ok, source} <- SafePath.join_under(priv, source) do
        {:cont, {:ok, copies ++ [{relative, source, destination}]}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp copy(copies) do
    Enum.reduce_while(copies, {:ok, %{}}, fn {relative, source, destination}, {:ok, staged} ->
      with {:ok, bytes} <- File.read(source),
           :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, bytes, [:exclusive]) do
        {:cont, {:ok, Map.put(staged, relative, sha256(bytes))}}
      else
        _error -> {:halt, {:error, "artifact_write_failed"}}
      end
    end)
  end

  defp observe(request, oracle, staged) do
    executable = resolve_executable(hd(request.profile.document["mix_command"]))
    {preflight, revision, {before, before_entries}} = preflight(request, executable)

    command =
      if preflight do
        Command.finish(
          Command.new_state(%{max_output_bytes: request.max_output_bytes, prefixes: []}),
          "not_started",
          nil,
          "not_started"
        )
      else
        Command.run(%{
          executable: executable,
          arguments: arguments(request),
          cd: request.root,
          environment: child_environment(request),
          timeout_ms: request.timeout_ms,
          max_output_bytes: request.max_output_bytes,
          prefixes: [oracle.prefix, @refused_prefix, @helpers_prefix, @suite_prefix]
        })
      end

    {after_fingerprint, after_entries} =
      if before_entries, do: fingerprint(request), else: {nil, nil}

    %{
      executable: executable,
      revision: revision,
      before: before,
      after: after_fingerprint,
      changed_paths:
        if(before_entries && after_entries,
          do: Target.changed_paths(before_entries, after_entries)
        ),
      command: command,
      classification:
        classify(%{
          oracle: oracle,
          inputs: Map.new(request.inputs),
          context: request.context,
          preflight: preflight,
          command: command,
          before: before,
          after: after_fingerprint
        }),
      staged: staged
    }
  end

  defp preflight(request, executable) do
    cond do
      not File.regular?(Path.join(request.root, "mix.exs")) ->
        {{:unsupported, "mix_project_missing"}, nil, {nil, nil}}

      is_nil(Target.toplevel(request.root)) ->
        {{:unsupported, "target_not_git_work_tree"}, nil, {nil, nil}}

      true ->
        revision = Target.revision(request.root)

        case fingerprint(request) do
          {{:ok, _fingerprint}, _entries} = before when is_nil(executable) ->
            {{:infrastructure, "command_not_found"}, revision, before}

          {{:ok, _fingerprint}, _entries} = before ->
            {nil, revision, before}

          {{:error, reason}, nil} = before
          when reason in ["target_has_nested_repository", "target_path_unreadable"] ->
            {{:unsupported, reason}, revision, before}

          {{:error, reason}, nil} = before ->
            {{:infrastructure, fingerprint_reason(reason)}, revision, before}
        end
    end
  end

  defp fingerprint(request) do
    case Target.fingerprint(request.root, request.fingerprint_budget) do
      {:ok, fingerprint, entries} -> {{:ok, fingerprint}, entries}
      {:error, _reason} = error -> {error, nil}
    end
  end

  defp fingerprint_reason("target_path_unreadable"), do: "target_path_unreadable"

  defp fingerprint_reason(reason) do
    if Target.budget_error?(reason),
      do: "target_fingerprint_budget_exceeded",
      else: "target_fingerprint_unavailable"
  end

  defp resolve_executable(name) do
    cond do
      Path.type(name) == :absolute -> if File.regular?(name), do: name
      String.contains?(name, "/") -> nil
      true -> System.find_executable(name)
    end
  end

  defp arguments(request) do
    [_executable | prefix] = request.profile.document["mix_command"]
    prefix ++ ["test" | request.test_arguments]
  end

  # Runner assignments come first and win: a passthrough or inherited entry with
  # a runner-assigned name is dropped, even if a profile check were bypassed.
  @doc false
  @spec child_environment(request()) :: [{String.t(), String.t()}]
  def child_environment(request) do
    owned = runner_set(request)
    names = MapSet.new(owned, &elem(&1, 0))

    caller =
      Enum.reject(
        request.resolved.passthrough ++ request.inherited,
        &MapSet.member?(names, elem(&1, 0))
      )

    owned ++ Enum.uniq_by(caller, &elem(&1, 0))
  end

  # Runner-owned paths come only from `request.paths`, built by
  # `runner_paths/3` from the validated staging plan.
  defp runner_set(request) do
    paths = request.paths

    [
      {"MIX_ENV", "test"},
      {"MIX_EXS", Map.fetch!(paths, "MIX_EXS")},
      {"INSIDER_ORACLE_RUNNER_HOST_MIX_EXS",
       Map.fetch!(paths, "INSIDER_ORACLE_RUNNER_HOST_MIX_EXS")},
      {"INSIDER_ORACLE_RUNNER_ORACLE", Map.fetch!(paths, "INSIDER_ORACLE_RUNNER_ORACLE")},
      {"INSIDER_ORACLE_RUNNER_OVERLAY", Map.fetch!(paths, "INSIDER_ORACLE_RUNNER_OVERLAY")},
      {"INSIDER_ORACLE_RUNNER_TEST_ALIAS", request.profile.document["test_alias"]}
      | request.inputs
    ] ++ List.wrap(request.resolved.db_suffix)
  end

  @doc false
  @spec classify(map()) :: map()
  def classify(facts) do
    result = result(facts)
    suite = marker(facts.command, @suite_prefix, &suite?/1)
    runtime = marker(facts.command, @helpers_prefix, &runtime?/1)
    {completeness, reason} = verdict(facts, result, suite, runtime)
    oracle_result = ok_value(result)

    %{
      completeness: completeness,
      reason: reason,
      outcome: outcome(completeness, oracle_result, facts.oracle),
      oracle_result: oracle_result,
      suite: ok_value(suite),
      runtime: ok_value(runtime),
      verdict: cleanup_verdict(facts.before, facts.after)
    }
  end

  defp verdict(facts, result, suite, runtime) do
    first_failure([
      fn -> preflight_failure(facts.preflight) end,
      fn -> termination_failure(facts.command.termination) end,
      fn -> target_failure(facts.before, facts.after) end,
      fn -> process_failure(facts.command.process) end,
      fn -> refusal(facts.command) end,
      fn -> marker_failure(runtime, "helpers_not_loaded") end,
      fn -> result_failure(result) end,
      fn -> marker_failure(suite, "suite_not_completed") end,
      fn -> selection_failure(suite) end,
      fn ->
        if facts.command.status != 0, do: {"infrastructure_failure", "test_command_failed"}
      end,
      fn -> if facts.command.bytes_omitted > 0, do: {"truncated", "output_truncated"} end
    ])
  end

  defp first_failure(checks), do: Enum.find_value(checks, {"complete", nil}, & &1.())

  defp preflight_failure(nil), do: nil
  defp preflight_failure({:unsupported, reason}), do: {"unsupported_source", reason}
  defp preflight_failure({:infrastructure, reason}), do: {"infrastructure_failure", reason}

  defp termination_failure("spawn_failed"), do: {"infrastructure_failure", "command_spawn_failed"}

  defp termination_failure("deadline_exceeded"),
    do: {"infrastructure_failure", "deadline_exceeded"}

  defp termination_failure(_termination), do: nil

  defp target_failure({:ok, same}, {:ok, same}), do: nil

  defp target_failure({:ok, _before}, {:ok, _after}),
    do: {"infrastructure_failure", "target_changed"}

  defp target_failure({:ok, _before}, {:error, reason}),
    do: {"infrastructure_failure", fingerprint_reason(reason)}

  defp target_failure(_before, _after),
    do: {"infrastructure_failure", "target_fingerprint_unavailable"}

  defp process_failure("uncertain"), do: {"infrastructure_failure", "process_cleanup_uncertain"}
  defp process_failure(_process), do: nil

  defp refusal(command) do
    case marker(command, @refused_prefix, &refusal?/1) do
      :missing -> nil
      {:ok, %{"reason" => reason}} -> {"unsupported_source", reason}
      _invalid -> {"infrastructure_failure", "runner_marker_invalid"}
    end
  end

  defp refusal?(%{"reason" => reason} = marker),
    do: map_size(marker) == 1 and reason in Record.reasons("unsupported_source")

  defp refusal?(_marker), do: false

  defp marker_failure({:ok, _value}, _missing), do: nil
  defp marker_failure(:missing, missing), do: {"infrastructure_failure", missing}

  defp marker_failure(:duplicate, _missing),
    do: {"infrastructure_failure", "duplicate_runner_marker"}

  defp marker_failure(:invalid, _missing), do: {"infrastructure_failure", "runner_marker_invalid"}

  defp result_failure({:ok, _report}), do: nil
  defp result_failure({:error, reason}), do: {"infrastructure_failure", reason}

  defp selection_failure({:ok, suite}) do
    if Record.executed(suite) <= 0, do: {"empty_selection", "no_tests_executed"}
  end

  defp outcome("infrastructure_failure", _result, _oracle), do: "infrastructure_failure"

  defp outcome(completeness, _result, _oracle)
       when completeness in ["unsupported_source", "empty_selection"],
       do: "not_observed"

  defp outcome(_completeness, %{"status" => status}, oracle),
    do: Map.fetch!(oracle.outcomes, status)

  defp cleanup_verdict({:ok, same}, {:ok, same}), do: "unchanged"
  defp cleanup_verdict({:ok, _before}, {:ok, _after}), do: "changed"
  defp cleanup_verdict(_before, _after), do: "unverified"

  defp result(%{command: command, oracle: oracle, context: context, inputs: inputs}) do
    with :ok <- single_line(command, oracle.prefix),
         {:ok, report} <- decode_object(hd(command.lines[oracle.prefix] || [])),
         true <- Oracle.valid_report?(oracle.id, report) do
      cond do
        report["context"] != context -> {:error, "context_mismatch"}
        not Oracle.bound?(oracle.id, report, inputs) -> {:error, "result_identity_mismatch"}
        true -> {:ok, report}
      end
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, "result_line_invalid"}
    end
  end

  defp single_line(command, prefix) do
    cond do
      prefix in command.overlong -> {:error, "result_line_too_long"}
      Map.get(command.counts, prefix, 0) == 0 -> {:error, "result_line_missing"}
      Map.fetch!(command.counts, prefix) > 1 -> {:error, "duplicate_result_line"}
      true -> :ok
    end
  end

  defp marker(command, prefix, valid?) do
    case {Map.get(command.counts, prefix, 0), prefix in command.overlong} do
      {_count, true} ->
        :invalid

      {0, false} ->
        :missing

      {1, false} ->
        with {:ok, value} <- decode_object(hd(command.lines[prefix])),
             true <- valid?.(value) do
          {:ok, value}
        else
          _invalid -> :invalid
        end

      {_count, false} ->
        :duplicate
    end
  end

  defp decode_object(line) do
    case Jason.decode(line) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp suite?(suite), do: Record.suite?(suite) and is_map(suite)
  defp runtime?(runtime), do: Record.runtime?(runtime) and is_map(runtime)

  defp ok_value({:ok, value}), do: value
  defp ok_value(_other), do: nil

  defp record(request, oracle, staged, observed, saved, {started_at, finished_at, duration}) do
    classification = observed.classification
    command = observed.command

    %{
      "schema" => Record.schema(),
      "run_id" => request.run_id,
      "status" => Record.status(classification.completeness, classification.outcome),
      "completeness" => classification.completeness,
      "completeness_reason" => classification.reason,
      "outcome" => classification.outcome,
      "started_at" => DateTime.to_iso8601(started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "duration_ms" => duration,
      "oracle" => %{
        "id" => request.oracle_id,
        "schema" => oracle.schema,
        "result_prefix" => oracle.prefix,
        "source_file" => "oracle/" <> oracle.file,
        "source_sha256" => Map.fetch!(staged, "oracle/" <> oracle.file),
        "inputs" => Map.new(request.inputs)
      },
      "oracle_result" => classification.oracle_result,
      "target" => target_record(request, observed),
      "profile" => %{
        "name" => request.profile.document["name"],
        "path" => request.profile.path,
        "sha256" => request.profile.sha256,
        "document" => request.profile.document
      },
      "command" => %{
        "executable" => observed.executable,
        "arguments" => arguments(request),
        "cwd" => request.root,
        "test_arguments" => request.test_arguments,
        "timeout_ms" => request.timeout_ms,
        "environment" => %{
          "set" => request |> runner_set() |> Map.new(),
          "inherited" => Enum.map(request.inherited, &elem(&1, 0)),
          "passthrough_present" => request.resolved.present,
          "passthrough_absent" => request.resolved.absent
        },
        "runner_files" => %{
          "bootstrap" => %{"file" => @bootstrap, "sha256" => Map.fetch!(staged, @bootstrap)},
          "overlay" => %{"file" => @overlay, "sha256" => Map.fetch!(staged, @overlay)}
        }
      },
      "exit" => %{"termination" => command.termination, "status" => command.status},
      "output" => output_record(request, command, saved),
      "suite" => classification.suite,
      "runtime" => classification.runtime,
      "cleanup" => %{"verdict" => classification.verdict, "process" => command.process},
      "limitations" => Record.limitations()
    }
  end

  # `withheld` appears only when a redaction bound withheld the whole output,
  # so records without it keep the v1 shape.
  defp output_record(request, command, saved) do
    output = %{
      "file" => "output.txt",
      "policy" => request.output_policy,
      "limit_bytes" => request.max_output_bytes,
      "bytes_total" => command.bytes_total,
      "bytes_omitted" => command.bytes_omitted,
      "truncated" => command.bytes_omitted > 0,
      "lines_withheld" => saved.lines_withheld,
      "redactions" => saved.redactions
    }

    if saved.withheld, do: Map.put(output, "withheld", saved.withheld), else: output
  end

  defp target_record(request, observed) do
    %{
      "root" => request.root,
      "git_revision" => observed.revision,
      "fingerprint_method" => Target.fingerprint_method(),
      "fingerprint_budget" => request.fingerprint_budget,
      "fingerprint_before" => ok_value(observed.before),
      "fingerprint_after" => ok_value(observed.after),
      "fingerprint_error" => fingerprint_error(observed.before, observed.after),
      "changed_path_count" => observed.changed_paths && length(observed.changed_paths),
      "changed_paths" =>
        observed.changed_paths && Enum.take(observed.changed_paths, @changed_path_limit)
    }
  end

  defp fingerprint_error({:error, reason}, _after), do: reason
  defp fingerprint_error(_before, {:error, reason}), do: reason
  defp fingerprint_error(_before, _after), do: nil

  defp save(output, record, text) do
    with {:ok, encoded} <- Record.encode(record),
         :ok <- File.write(Path.join(output, "output.txt"), text, [:exclusive]),
         :ok <- File.write(Path.join(output, "run.json"), encoded <> "\n", [:exclusive]) do
      {:ok, record, encoded}
    else
      _error -> {:error, "artifact_write_failed"}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
