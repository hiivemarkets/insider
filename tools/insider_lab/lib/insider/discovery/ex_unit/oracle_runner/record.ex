defmodule Insider.Discovery.ExUnit.OracleRunner.Record do
  @moduledoc false

  # `insider.oracle-run/v1`: the saved, versioned record of one oracle run. It
  # holds identities, caller inputs, environment variable names, digests, and
  # the oracle's own value-free report. It never holds a passthrough value.
  #
  # Validation is structural and semantic: a record whose verdict contradicts
  # its own evidence (a complete run whose command never started, whose suite
  # executed nothing, or whose outcome disagrees with the oracle's report) is
  # rejected, so `exit_status/1` is only ever computed for a coherent record.

  alias Insider.Discovery.ExUnit.OracleRunner.Oracle
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy
  alias Insider.Discovery.ExUnit.OracleRunner.Profile
  alias Insider.Discovery.ExUnit.OracleRunner.Selection
  alias Insider.Discovery.ExUnit.OracleRunner.SafePath
  alias Insider.Event.Canonical

  @schema "insider.oracle-run/v1"
  @maximum_bytes 262_144
  @changed_path_limit 32
  @keys ~w(cleanup command completeness completeness_reason duration_ms exit finished_at
           limitations oracle oracle_result outcome output profile run_id runtime schema
           started_at status suite target)
  @outcomes ~w(confirmed contract_disproved not_reproduced not_observed infrastructure_failure)
  @reasons %{
    "complete" => [nil],
    "empty_selection" => ["no_tests_executed"],
    "unsupported_source" => ~w(mix_project_missing target_not_git_work_tree umbrella_project
                               mix_env_not_test unsupported_mix_internals
                               test_alias_present test_alias_missing
                               target_has_nested_repository target_path_unreadable),
    "truncated" => ["output_truncated"],
    "infrastructure_failure" => ~w(command_not_found command_spawn_failed deadline_exceeded
                                   target_fingerprint_unavailable
                                   target_fingerprint_budget_exceeded target_changed
                                   process_cleanup_uncertain runner_marker_invalid
                                   target_path_unreadable
                                   duplicate_runner_marker helpers_not_loaded
                                   result_line_missing duplicate_result_line
                                   result_line_too_long result_line_invalid context_mismatch
                                   result_identity_mismatch suite_not_completed
                                   test_command_failed)
  }
  @exit_statuses %{
    "empty_selection" => 3,
    "unsupported_source" => 4,
    "truncated" => 5,
    "infrastructure_failure" => 70
  }
  @outcome_exit_statuses %{"not_reproduced" => 0, "confirmed" => 2, "not_observed" => 6}
  @limitations [
    "concurrent_target_changes_are_not_attributed",
    "descendants_outside_the_process_group_are_not_tracked",
    "fingerprint_excludes_ignored_paths",
    "mix_command_may_add_unrecorded_environment",
    "oracle_result_does_not_establish_causality",
    "redacted_output_policy_matches_exact_values_only",
    "runner_depends_on_internal_mix_apis"
  ]
  @terminations ~w(exited deadline_exceeded spawn_failed not_started)
  @verdicts ~w(unchanged changed unverified)
  @process_cleanups ~w(exited group_terminated uncertain not_started)
  @policies ~w(allowlisted redacted)
  @budget_keys ~w(max_content_bytes max_files max_listing_bytes timeout_ms)
  @digest ~r/\A[0-9a-f]{64}\z/
  @revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @run_id ~r/\A[0-9a-f]{32}\z/
  @variable ~r/\A[A-Z_][A-Z0-9_]{0,127}\z/
  @oracle_variables ~w(INSIDER_ORACLE_APPLICATION INSIDER_ORACLE_CONTEXT INSIDER_ORACLE_KEY
                       INSIDER_ORACLE_KEYS INSIDER_ORACLE_TELEMETRY_EVENT)
  # Sorted input names each oracle accepts; KEY and KEYS never appear together.
  @input_names %{
    "application_env" => [
      ~w(INSIDER_ORACLE_APPLICATION INSIDER_ORACLE_CONTEXT INSIDER_ORACLE_KEY),
      ~w(INSIDER_ORACLE_APPLICATION INSIDER_ORACLE_CONTEXT INSIDER_ORACLE_KEYS)
    ],
    "telemetry_dead_handlers" => [~w(INSIDER_ORACLE_CONTEXT INSIDER_ORACLE_TELEMETRY_EVENT)],
    "otel_global_state" => [~w(INSIDER_ORACLE_CONTEXT)]
  }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec limitations() :: [String.t()]
  def limitations, do: @limitations

  @spec completeness_states() :: [String.t()]
  def completeness_states, do: Map.keys(@reasons)

  @spec reasons(String.t()) :: [String.t() | nil]
  def reasons(completeness), do: Map.fetch!(@reasons, completeness)

  @spec exit_status(map()) :: non_neg_integer()
  def exit_status(%{"completeness" => "complete", "outcome" => outcome}),
    do: Map.fetch!(@outcome_exit_statuses, outcome)

  def exit_status(%{"completeness" => completeness}), do: Map.fetch!(@exit_statuses, completeness)

  @spec status(String.t(), String.t()) :: String.t()
  def status("complete", outcome), do: outcome
  def status(completeness, _outcome), do: completeness

  @doc false
  @spec executed(map()) :: integer()
  def executed(suite), do: suite["total"] - (suite["excluded"] || 0) - (suite["skipped"] || 0)

  @doc false
  @spec suite?(term()) :: boolean()
  def suite?(nil), do: true

  def suite?(%{"total" => total} = suite) when is_integer(total) and total >= 0 do
    Enum.sort(Map.keys(suite)) == ["excluded", "failures", "skipped", "total"] and
      Enum.all?(Map.values(suite), &(is_nil(&1) or non_negative?(&1)))
  end

  def suite?(_suite), do: false

  @doc false
  @spec runtime?(term()) :: boolean()
  def runtime?(nil), do: true

  def runtime?(%{"elixir" => elixir, "host_helpers" => helpers, "otp" => otp} = runtime) do
    map_size(runtime) == 3 and short_text?(elixir) and short_text?(otp) and non_negative?(helpers)
  end

  def runtime?(_runtime), do: false

  @spec encode(map()) :: {:ok, binary()} | {:error, String.t()}
  def encode(record) do
    with {:ok, valid} <- validate(record), do: {:ok, Canonical.encode(valid)}
  end

  @spec decode(term()) :: {:ok, map()} | {:error, String.t()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum_bytes do
    case Jason.decode(bytes) do
      {:ok, %{"schema" => @schema} = record} -> validate(record)
      {:ok, %{"schema" => _other}} -> {:error, "unsupported_schema"}
      {:ok, _other} -> {:error, "invalid_record"}
      {:error, _error} -> {:error, "invalid_json"}
    end
  end

  def decode(bytes) when is_binary(bytes), do: {:error, "record_too_large"}
  def decode(_bytes), do: {:error, "invalid_record"}

  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(record) when is_map(record) and not is_struct(record) do
    if unsafe_path?(record), do: {:error, "unsafe_path"}, else: validate_fields(record)
  rescue
    _error -> {:error, "invalid_record"}
  end

  def validate(_record), do: {:error, "invalid_record"}

  # The recorded file names are joined onto a run directory below, so each one
  # that is present as a string must be a plain relative name. This is checked
  # first and reported with its own closed reason.
  @path_fields [
    ["oracle", "source_file"],
    ["command", "runner_files", "bootstrap", "file"],
    ["command", "runner_files", "overlay", "file"]
  ]

  defp unsafe_path?(record) do
    Enum.any?(@path_fields, fn field ->
      case nested(record, field) do
        value when is_binary(value) -> not SafePath.relative?(value)
        _absent_or_other -> false
      end
    end)
  end

  defp nested(value, []), do: value

  defp nested(%{} = map, [key | rest]) when not is_struct(map),
    do: nested(Map.get(map, key), rest)

  defp nested(_value, _path), do: nil

  defp validate_fields(record) do
    if Enum.sort(Map.keys(record)) == Enum.sort(@keys) and record["schema"] == @schema and
         string?(record["run_id"], @run_id) and times?(record) and oracle?(record["oracle"]) and
         target?(record["target"]) and profile?(record["profile"]) and
         command?(record["command"]) and exit?(record["exit"]) and output?(record["output"]) and
         suite?(record["suite"]) and runtime?(record["runtime"]) and
         cleanup?(record["cleanup"]) and record["limitations"] == @limitations and
         verdict?(record) and byte_size(Canonical.encode(record)) <= @maximum_bytes do
      {:ok, record}
    else
      {:error, "invalid_record"}
    end
  end

  defp verdict?(%{"completeness" => completeness, "completeness_reason" => reason} = record) do
    Map.has_key?(@reasons, completeness) and reason in Map.fetch!(@reasons, completeness) and
      record["outcome"] in @outcomes and
      record["status"] == status(completeness, record["outcome"]) and
      inputs?(record) and runner_environment?(record) and result?(record) and
      coherent?(completeness, record)
  end

  defp verdict?(_record), do: false

  # The oracle inputs use exactly the selectors the named oracle accepts, with
  # no conflicting pair, and the child environment carries exactly those
  # inputs and no other oracle selector.
  defp inputs?(%{"oracle" => %{"id" => id, "inputs" => inputs}, "command" => command}) do
    names = inputs |> Map.keys() |> Enum.sort()
    set = command["environment"]["set"]

    names in Map.fetch!(@input_names, id) and
      Map.take(set, @oracle_variables) == inputs
  end

  # The runner writes the same child-environment record for every run, so it
  # is checked on every record. `set` is exactly the runner's own assignments
  # (bootstrap, overlay, and oracle under one run directory, the target's own
  # `mix.exs`, the profile's alias mode, `MIX_ENV=test`), the oracle inputs, and
  # the profile's database suffix; no other name carries a value. The
  # passthrough lists are unique, disjoint, in the profile's order, and
  # together are exactly the profile's declared names; `inherited` is a subset
  # of `HOME` and `PATH`.
  defp runner_environment?(%{"command" => command} = record) do
    %{"set" => set} = environment = command["environment"]
    profile = record["profile"]["document"]

    with {:ok, run_directory} <- run_directory(set["MIX_EXS"], command["runner_files"]),
         {:ok, suffix} <- suffix(profile, set) do
      set ==
        record
        |> runner_assignments(run_directory, profile)
        |> Map.merge(record["oracle"]["inputs"])
        |> Map.merge(suffix) and
        passthrough?(environment, profile["passthrough_env"]) and
        ordered_subset?(environment["inherited"], Profile.inherited())
    else
      _invalid -> false
    end
  end

  defp run_directory(mix_exs, %{"bootstrap" => %{"file" => file}}) when is_binary(mix_exs) do
    directory = String.replace_suffix(mix_exs, "/" <> file, "")

    if directory != mix_exs and Path.type(directory) == :absolute,
      do: {:ok, directory},
      else: :error
  end

  defp run_directory(_mix_exs, _files), do: :error

  # Joins happen only after `unsafe_path?/1` accepted every name, and each still
  # goes through the same helper, so a name that is not a plain relative name
  # cannot produce a path outside the run directory.
  defp runner_assignments(record, run_directory, profile) do
    files = record["command"]["runner_files"]

    %{
      "MIX_ENV" => "test",
      "MIX_EXS" => under(run_directory, files["bootstrap"]["file"]),
      "INSIDER_ORACLE_RUNNER_HOST_MIX_EXS" => under(record["target"]["root"], "mix.exs"),
      "INSIDER_ORACLE_RUNNER_ORACLE" => under(run_directory, record["oracle"]["source_file"]),
      "INSIDER_ORACLE_RUNNER_OVERLAY" =>
        with(
          path when is_binary(path) <- under(run_directory, files["overlay"]["file"]),
          do: Path.dirname(path)
        ),
      "INSIDER_ORACLE_RUNNER_TEST_ALIAS" => profile["test_alias"]
    }
  end

  defp under(run_directory, file) do
    case SafePath.join_under(run_directory, file) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  # The profile's suffix as the runner resolved it: a literal must match, and an
  # environment-sourced value must be present and well formed.
  defp suffix(profile, set) do
    case Profile.resolve(profile, set) do
      {:ok, %{db_suffix: nil}} -> {:ok, %{}}
      {:ok, %{db_suffix: {variable, value}}} -> {:ok, %{variable => value}}
      {:error, _reason} -> :error
    end
  end

  defp passthrough?(%{"passthrough_present" => present, "passthrough_absent" => absent}, declared) do
    present ++ absent == Enum.uniq(present ++ absent) and
      Enum.sort(present ++ absent) == Enum.sort(declared) and
      ordered_subset?(present, declared) and ordered_subset?(absent, declared)
  end

  defp ordered_subset?(names, allowed),
    do: Enum.uniq(names) == names and Enum.filter(allowed, &(&1 in names)) == names

  # A present oracle report must be a valid report of the named oracle that
  # echoes the run's context input.
  defp result?(%{"oracle_result" => nil}), do: true

  defp result?(%{"oracle_result" => result, "oracle" => oracle}) do
    Oracle.valid_report?(oracle["id"], result) and
      result["context"] == oracle["inputs"]["INSIDER_ORACLE_CONTEXT"] and
      Oracle.bound?(oracle["id"], result, oracle["inputs"])
  end

  defp coherent?("infrastructure_failure", record),
    do: record["outcome"] == "infrastructure_failure"

  defp coherent?("unsupported_source", record),
    do: record["outcome"] == "not_observed" and is_nil(record["oracle_result"])

  defp coherent?("empty_selection", record) do
    record["outcome"] == "not_observed" and is_map(record["suite"]) and
      executed(record["suite"]) <= 0 and record["exit"]["termination"] == "exited" and
      unchanged_target?(record)
  end

  # `complete` and `truncated` carry evidence: the command exited 0 after a
  # nonempty, failure-free suite with runtime markers, the target fingerprint
  # did not change, the process group was cleaned up, and the outcome is the
  # one the oracle's report status maps to.
  defp coherent?(completeness, record) do
    %{"oracle" => oracle, "oracle_result" => result, "suite" => suite} = record

    is_map(result) and record["outcome"] == Oracle.outcome(oracle["id"], result["status"]) and
      record["exit"] == %{"status" => 0, "termination" => "exited"} and is_map(suite) and
      executed(suite) > 0 and suite["failures"] == 0 and is_map(record["runtime"]) and
      record["cleanup"]["process"] in ["exited", "group_terminated"] and
      unchanged_target?(record) and record["output"]["truncated"] == (completeness == "truncated") and
      command_ran?(record)
  end

  # The recorded command is the profile's prefix running the real `test` task
  # on a valid, nonempty selection, from the target root, with a resolved
  # executable for the profile's first element.
  defp command_ran?(%{
         "command" => command,
         "profile" => %{"document" => profile},
         "target" => target
       }) do
    [program | prefix] = profile["mix_command"]
    executable = command["executable"]

    is_binary(executable) and
      if(Path.type(program) == :absolute,
        do: executable == program,
        else: Path.basename(executable) == program
      ) and
      command["cwd"] == target["root"] and
      match?({:ok, _paths}, Selection.parse(command["test_arguments"])) and
      command["arguments"] == prefix ++ ["test" | command["test_arguments"]]
  end

  defp unchanged_target?(%{"target" => target, "cleanup" => cleanup}) do
    is_map(target["fingerprint_before"]) and
      target["fingerprint_before"] == target["fingerprint_after"] and
      target["changed_path_count"] == 0 and cleanup["verdict"] == "unchanged"
  end

  defp times?(record) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(record["started_at"] || ""),
         {:ok, finished, _offset} <- DateTime.from_iso8601(record["finished_at"] || "") do
      DateTime.compare(started, finished) != :gt and non_negative?(record["duration_ms"])
    else
      _error -> false
    end
  end

  defp oracle?(
         %{
           "id" => id,
           "inputs" => inputs,
           "result_prefix" => prefix,
           "schema" => schema,
           "source_file" => file,
           "source_sha256" => digest
         } = oracle
       ) do
    spec = id in Oracle.ids() && Oracle.fetch!(id)

    map_size(oracle) == 6 and is_map(spec) and prefix == spec.prefix and schema == spec.schema and
      file == "oracle/" <> spec.file and string?(digest, @digest) and string_map?(inputs)
  end

  defp oracle?(_oracle), do: false

  defp target?(
         %{
           "changed_path_count" => count,
           "changed_paths" => paths,
           "fingerprint_after" => after_fingerprint,
           "fingerprint_before" => before_fingerprint,
           "fingerprint_budget" => budget,
           "fingerprint_error" => error,
           "fingerprint_method" => "git-ls-files-sha256/v1",
           "git_revision" => revision,
           "root" => root
         } = target
       ) do
    map_size(target) == 9 and absolute?(root) and
      (is_nil(revision) or string?(revision, @revision)) and budget?(budget) and
      fingerprint?(before_fingerprint) and fingerprint?(after_fingerprint) and
      fingerprint_error?(error, before_fingerprint, after_fingerprint) and
      changed_paths?(count, paths, before_fingerprint, after_fingerprint)
  end

  defp target?(_target), do: false

  defp budget?(budget) do
    plain_map?(budget) and Enum.sort(Map.keys(budget)) == @budget_keys and
      Enum.all?(Map.values(budget), &positive?/1)
  end

  # An error explains a missing fingerprint; no error may sit beside two.
  defp fingerprint_error?(nil, _before, _after), do: true

  defp fingerprint_error?(error, before_fingerprint, after_fingerprint) do
    error in Insider.Discovery.ExUnit.OracleRunner.Target.errors() and
      (is_nil(before_fingerprint) or is_nil(after_fingerprint))
  end

  # Present exactly when both fingerprints are; at most 32 listed, sorted.
  defp changed_paths?(nil, nil, before_fingerprint, after_fingerprint),
    do: is_nil(before_fingerprint) or is_nil(after_fingerprint)

  defp changed_paths?(count, paths, before_fingerprint, after_fingerprint)
       when is_map(before_fingerprint) and is_map(after_fingerprint) do
    non_negative?(count) and string_list?(paths) and
      length(paths) == min(count, @changed_path_limit) and paths == Enum.sort(paths) and
      count == 0 == (before_fingerprint == after_fingerprint)
  end

  defp changed_paths?(_count, _paths, _before, _after), do: false

  defp fingerprint?(nil), do: true

  defp fingerprint?(%{"files" => files, "sha256" => digest} = fingerprint),
    do: map_size(fingerprint) == 2 and non_negative?(files) and string?(digest, @digest)

  defp fingerprint?(_fingerprint), do: false

  defp profile?(
         %{"document" => document, "name" => name, "path" => path, "sha256" => digest} = profile
       ) do
    map_size(profile) == 4 and plain_map?(document) and document["name"] == name and
      absolute?(path) and string?(digest, @digest) and Canonical.sha256(document) == digest and
      match?({:ok, _profile}, Profile.validate(document))
  end

  defp profile?(_profile), do: false

  defp command?(
         %{
           "arguments" => arguments,
           "cwd" => cwd,
           "environment" => environment,
           "executable" => executable,
           "runner_files" => runner_files,
           "test_arguments" => test_arguments,
           "timeout_ms" => timeout
         } = command
       ) do
    map_size(command) == 7 and string_list?(arguments) and absolute?(cwd) and
      (is_nil(executable) or absolute?(executable)) and string_list?(test_arguments) and
      positive?(timeout) and environment?(environment) and runner_files?(runner_files)
  end

  defp command?(_command), do: false

  defp environment?(
         %{
           "inherited" => inherited,
           "passthrough_absent" => absent,
           "passthrough_present" => present,
           "set" => set
         } = environment
       ) do
    map_size(environment) == 4 and string_map?(set) and
      Enum.all?(Map.keys(set), &string?(&1, @variable)) and
      Enum.all?([inherited, absent, present], &variables?/1)
  end

  defp environment?(_environment), do: false

  defp runner_files?(%{"bootstrap" => bootstrap, "overlay" => overlay} = files),
    do: map_size(files) == 2 and runner_file?(bootstrap) and runner_file?(overlay)

  defp runner_files?(_files), do: false

  defp runner_file?(%{"file" => file, "sha256" => digest} = entry),
    do: map_size(entry) == 2 and relative_file?(file, "runner/") and string?(digest, @digest)

  defp runner_file?(_entry), do: false

  defp exit?(%{"status" => status, "termination" => termination} = exit) do
    map_size(exit) == 2 and termination in @terminations and
      (is_nil(status) or (is_integer(status) and status in 0..255)) and
      termination == "exited" == is_integer(status)
  end

  defp exit?(_exit), do: false

  defp output?(
         %{
           "bytes_omitted" => omitted,
           "bytes_total" => total,
           "file" => "output.txt",
           "limit_bytes" => limit,
           "lines_withheld" => withheld,
           "policy" => policy,
           "redactions" => redactions,
           "truncated" => truncated
         } = output
       ) do
    {withheld_reason, rest} = Map.pop(output, "withheld", :absent)

    map_size(rest) == 8 and policy in @policies and non_negative?(omitted) and
      non_negative?(total) and positive?(limit) and omitted <= total and
      truncated == omitted > 0 and total - omitted <= limit and non_negative?(withheld) and
      non_negative?(redactions) and
      withheld_reason?(withheld_reason, policy, withheld, redactions)
  end

  defp output?(_output), do: false

  defp withheld_reason?(:absent, policy, withheld, _redactions),
    do: policy == "allowlisted" or withheld == 0

  defp withheld_reason?(reason, _policy, _withheld, redactions),
    do: reason in OutputPolicy.withheld_reasons() and redactions == 0

  defp cleanup?(%{"process" => process, "verdict" => verdict} = cleanup),
    do: map_size(cleanup) == 2 and process in @process_cleanups and verdict in @verdicts

  defp cleanup?(_cleanup), do: false

  defp relative_file?(file, prefix),
    do: SafePath.relative?(file) and String.starts_with?(file, prefix)

  defp absolute?(path), do: text?(path) and Path.type(path) == :absolute

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value)

  defp short_text?(value), do: is_binary(value) and byte_size(value) in 1..64
  defp string?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)
  defp string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)
  defp variables?(values), do: is_list(values) and Enum.all?(values, &string?(&1, @variable))
  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp string_map?(value),
    do:
      plain_map?(value) and
        Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end)

  defp non_negative?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0
end
