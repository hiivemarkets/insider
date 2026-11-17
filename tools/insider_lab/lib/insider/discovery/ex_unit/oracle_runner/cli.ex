defmodule Insider.Discovery.ExUnit.OracleRunner.CLI do
  @moduledoc false

  alias Insider.Discovery.ExUnit.OracleRunner
  alias Insider.Discovery.ExUnit.OracleRunner.OutputPolicy
  alias Insider.Discovery.ExUnit.OracleRunner.Profile
  alias Insider.Discovery.ExUnit.OracleRunner.Record
  alias Insider.Discovery.ExUnit.OracleRunner.Selection
  alias Insider.Discovery.ExUnit.OracleRunner.Target

  @error_schema "insider.oracle-run-error/v1"
  # Every switch is `:keep` so that a repeated scalar is visible and refused.
  @switches [
    profile: [:string, :keep],
    root: [:string, :keep],
    output: [:string, :keep],
    oracle: [:string, :keep],
    application: [:string, :keep],
    key: [:string, :keep],
    keys: [:string, :keep],
    event: [:string, :keep],
    context: [:string, :keep],
    timeout_ms: [:integer, :keep],
    max_output_bytes: [:integer, :keep],
    output_policy: [:string, :keep],
    fingerprint_timeout_ms: [:integer, :keep],
    fingerprint_max_bytes: [:integer, :keep]
  ]
  @timeout_range 1_000..7_200_000
  @output_range 4_096..67_108_864
  @default_timeout_ms 900_000
  @default_output_bytes 1_048_576
  @fingerprint_timeout_range 1_000..3_600_000
  @fingerprint_bytes_range 1..68_719_476_736
  @maximum_symlinks 40
  @maximum_input_bytes 4_095
  @maximum_context_bytes 1_024

  @spec run([String.t()], %{String.t() => String.t()}) :: {binary(), non_neg_integer()}
  def run(arguments, environment \\ System.get_env()) when is_list(arguments) do
    with {:ok, runner_arguments, test_arguments} <- split(arguments),
         {:ok, options} <- parse(runner_arguments),
         {:ok, request} <- request(options, test_arguments, environment) do
      case OracleRunner.execute(request) do
        {:ok, record, encoded} -> {encoded <> "\n", Record.exit_status(record)}
        {:error, "output_unavailable"} -> invalid("output_unavailable")
        {:error, reason} -> failed(reason)
      end
    else
      {:error, reason} -> invalid(reason)
    end
  rescue
    _error -> failed("runner_failed")
  end

  defp split(arguments) do
    case Enum.split_while(arguments, &(&1 != "--")) do
      {runner, ["--" | test]} -> {:ok, runner, test}
      {_runner, []} -> {:error, "missing_test_selection"}
    end
  end

  defp parse(arguments) do
    case OptionParser.parse(arguments, strict: @switches) do
      {options, [], []} ->
        if Enum.any?(
             Keyword.keys(@switches),
             &match?([_, _ | _], Keyword.get_values(options, &1))
           ),
           do: {:error, "invalid_arguments"},
           else: {:ok, options}

      _other ->
        {:error, "invalid_arguments"}
    end
  end

  defp request(options, test_arguments, environment) do
    run_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with {:ok, oracle_id} <- oracle_id(options[:oracle]),
         {:ok, root} <- root(options[:root]),
         {:ok, output} <- output(options[:output], root),
         {:ok, oracle_inputs} <- oracle_inputs(oracle_id, options),
         {:ok, context} <- context(options[:context], run_id),
         {:ok, timeout_ms} <- bounded(options, :timeout_ms, @default_timeout_ms, @timeout_range),
         {:ok, output_bytes} <-
           bounded(options, :max_output_bytes, @default_output_bytes, @output_range),
         {:ok, policy} <- output_policy(Keyword.get(options, :output_policy, "allowlisted")),
         {:ok, budget} <- fingerprint_budget(options),
         :ok <- test_arguments(test_arguments, root),
         {:ok, profile} <- profile(options[:profile]),
         {:ok, resolved} <- Profile.resolve(profile.document, environment) do
      {:ok,
       %{
         run_id: run_id,
         oracle_id: oracle_id,
         inputs: oracle_inputs ++ [{"INSIDER_ORACLE_CONTEXT", context}],
         context: context,
         profile: profile,
         resolved: resolved,
         inherited:
           for(
             name <- Profile.inherited(),
             Map.has_key?(environment, name),
             do: {name, environment[name]}
           ),
         root: root,
         output: output,
         test_arguments: test_arguments,
         timeout_ms: timeout_ms,
         max_output_bytes: output_bytes,
         output_policy: policy,
         fingerprint_budget: budget
       }}
    end
  end

  defp oracle_id(id) do
    if id in OracleRunner.oracle_ids(), do: {:ok, id}, else: {:error, "unknown_oracle"}
  end

  defp root(nil), do: {:error, "missing_root"}

  # The target and the run directory are compared by their resolved
  # filesystem locations, so a symlink cannot place the run inside the target.
  defp root(root) do
    case real_path(root) do
      {:ok, real} -> if File.dir?(real), do: {:ok, real}, else: {:error, "invalid_root"}
      :error -> {:error, "invalid_root"}
    end
  end

  defp output(nil, _root), do: {:error, "missing_output"}

  # Containment is decided on the resolved location first, so a path inside the
  # target is reported as such even when its parent does not exist yet.
  defp output(output, root) do
    expanded = Path.expand(output)
    name = Path.basename(expanded)

    with {:ok, parent} <- resolve_nearest(Path.dirname(expanded)),
         resolved = Path.join(parent, name),
         :outside <-
           if(Enum.any?(protected(root), &inside?(resolved, &1)), do: :inside, else: :outside),
         true <- File.dir?(parent) and name not in ["", ".", ".."],
         {:error, :enoent} <- File.lstat(resolved) do
      {:ok, resolved}
    else
      :inside -> {:error, "output_inside_target"}
      _unavailable -> {:error, "output_unavailable"}
    end
  end

  # The resolved location of the nearest existing ancestor, with the missing
  # trailing components appended unchanged.
  defp resolve_nearest(path) do
    case real_path(path) do
      {:ok, resolved} ->
        {:ok, resolved}

      :error ->
        parent = Path.dirname(path)

        if parent == path,
          do: :error,
          else:
            with(
              {:ok, resolved} <- resolve_nearest(parent),
              do: {:ok, Path.join(resolved, Path.basename(path))}
            )
    end
  end

  # The root, and the whole Git work tree when the root is inside one.
  defp protected(root) do
    case Target.toplevel(root) do
      nil -> [root]
      toplevel -> [root | List.wrap(ok_path(real_path(toplevel)))]
    end
  end

  defp ok_path({:ok, path}), do: path
  defp ok_path(:error), do: nil

  defp inside?(path, directory), do: String.starts_with?(path <> "/", directory <> "/")

  defp real_path(path, depth \\ 0)
  defp real_path(_path, depth) when depth > @maximum_symlinks, do: :error

  defp real_path(path, depth) do
    [top | parts] = Path.split(Path.expand(path))
    walk(top, parts, depth)
  end

  defp walk(current, [], _depth), do: {:ok, current}

  defp walk(current, [part | rest], depth) do
    next = Path.join(current, part)

    case File.read_link(next) do
      {:ok, target} -> real_path(Path.join([Path.expand(target, current) | rest]), depth + 1)
      {:error, :einval} -> walk(next, rest, depth)
      {:error, _reason} -> :error
    end
  end

  defp output_policy(policy) do
    if policy in OutputPolicy.policies(),
      do: {:ok, policy},
      else: {:error, "invalid_output_policy"}
  end

  defp fingerprint_budget(options) do
    defaults = Target.default_budget()

    with {:ok, timeout} <-
           bounded(
             options,
             :fingerprint_timeout_ms,
             defaults["timeout_ms"],
             @fingerprint_timeout_range
           ),
         {:ok, bytes} <-
           bounded(
             options,
             :fingerprint_max_bytes,
             defaults["max_content_bytes"],
             @fingerprint_bytes_range
           ) do
      {:ok, %{defaults | "timeout_ms" => timeout, "max_content_bytes" => bytes}}
    end
  end

  defp oracle_inputs("application_env", options) do
    case {options[:application], options[:key], options[:keys], options[:event]} do
      {application, key, nil, nil} when is_binary(application) and is_binary(key) ->
        inputs([{"INSIDER_ORACLE_APPLICATION", application}, {"INSIDER_ORACLE_KEY", key}])

      {application, nil, keys, nil} when is_binary(application) and is_binary(keys) ->
        inputs([{"INSIDER_ORACLE_APPLICATION", application}, {"INSIDER_ORACLE_KEYS", keys}])

      _other ->
        {:error, "invalid_oracle_inputs"}
    end
  end

  defp oracle_inputs("telemetry_dead_handlers", options) do
    case {options[:event], options[:application], options[:key], options[:keys]} do
      {event, nil, nil, nil} when is_binary(event) ->
        inputs([{"INSIDER_ORACLE_TELEMETRY_EVENT", event}])

      _other ->
        {:error, "invalid_oracle_inputs"}
    end
  end

  defp oracle_inputs("otel_global_state", options) do
    if Enum.all?([:application, :key, :keys, :event], &is_nil(options[&1])),
      do: {:ok, []},
      else: {:error, "invalid_oracle_inputs"}
  end

  # The oracle performs its own exact validation; the runner only refuses
  # values that could not pass through the environment unchanged.
  defp inputs(inputs) do
    if Enum.all?(inputs, fn {_name, value} -> text?(value, @maximum_input_bytes) end),
      do: {:ok, inputs},
      else: {:error, "invalid_oracle_inputs"}
  end

  defp context(nil, run_id), do: {:ok, "insider-oracle-run:" <> run_id}

  defp context(context, _run_id) do
    if text?(context, @maximum_context_bytes) and String.printable?(context),
      do: {:ok, context},
      else: {:error, "invalid_context"}
  end

  defp bounded(options, key, default, range) do
    value = Keyword.get(options, key, default)
    if value in range, do: {:ok, value}, else: {:error, "invalid_bounds"}
  end

  defp test_arguments(arguments, root) do
    with {:ok, paths} <- Selection.parse(arguments) do
      if Enum.all?(paths, &File.exists?(Path.join(root, &1))),
        do: :ok,
        else: {:error, "invalid_test_selection"}
    end
  end

  defp profile(nil), do: {:error, "missing_profile"}
  defp profile(path), do: Profile.load(path)

  defp text?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      not Enum.any?(:binary.bin_to_list(value), &(&1 < 0x20 or &1 == 0x7F))
  end

  defp invalid(reason), do: error("invalid_input", reason, nil, 64)
  defp failed(reason), do: error("failed", reason, "infrastructure_failure", 70)

  defp error(status, reason, completeness, exit_status) do
    document = %{
      "schema" => @error_schema,
      "status" => status,
      "reason" => reason,
      "completeness" => completeness
    }

    {Jason.encode!(document) <> "\n", exit_status}
  end
end
