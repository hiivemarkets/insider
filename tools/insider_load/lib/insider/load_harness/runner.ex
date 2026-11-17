defmodule Insider.LoadHarness.Runner do
  @moduledoc false

  alias Insider.Load.Report
  alias Insider.LoadHarness.ArtifactStore
  alias Insider.LoadHarness.Phase
  alias Insider.LoadHarness.Profile
  alias Insider.LoadHarness.Revision
  alias Insider.LoadHarness.RuntimeIdentity

  @spec run(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(profile_path, output, options \\ [])

  def run(profile_path, output, options)
      when is_binary(profile_path) and is_binary(output) and is_list(options) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    started_monotonic = System.monotonic_time(:millisecond)
    project_root = Keyword.get_lazy(options, :project_root, &project_root/0)

    with true <- Keyword.keyword?(options) and Keyword.keys(options) -- [:project_root] == [],
         {:ok, profile} <- Profile.load(profile_path),
         {:ok, revision} <- Revision.capture(project_root),
         :ok <- require_clean_revision(revision) do
      {baseline, baseline_uncertainty, instrumented, instrumented_uncertainty} =
        measured_phases(profile)

      ended_at = DateTime.utc_now() |> DateTime.truncate(:second)
      duration_ms = max(System.monotonic_time(:millisecond) - started_monotonic, 1)

      attributes = %{
        "schema" => "insider.load-report/v1",
        "revision" => revision["revision"],
        "inputs" => %{
          "mix_lock_sha256" => revision["mix_lock_sha256"],
          "profile_sha256" => profile.canonical_sha256,
          "seed" => profile.seed,
          "mode" => profile.mode
        },
        "runtime" => RuntimeIdentity.capture(),
        "interval" => %{
          "started_at_utc" => DateTime.to_iso8601(started_at),
          "ended_at_utc" => DateTime.to_iso8601(ended_at),
          "duration_ms" => duration_ms
        },
        "production_capacity" => false,
        "budget_evaluation" => "not_approved",
        "outcome" => outcome(baseline, instrumented),
        "baseline" => baseline,
        "instrumented" => instrumented,
        "comparison" => comparison(baseline, instrumented),
        "uncertainty" => uncertainty(baseline_uncertainty ++ instrumented_uncertainty)
      }

      finalize(output, attributes, profile)
    else
      false -> fail(output, :invalid_options)
      {:error, reason} when is_atom(reason) -> fail(output, reason)
    end
  rescue
    _error -> fail(output, :load_run_failed)
  catch
    _kind, _reason -> fail(output, :load_run_failed)
  end

  def run(_profile_path, _output, _options), do: {:error, :invalid_options}

  defp fail(output, reason) do
    case ArtifactStore.write_failure(output, reason) do
      {:ok, _manifest} -> {:error, reason}
      {:error, :output_exists} -> {:error, :output_exists}
      {:error, _publication_error} -> {:error, {:failure_publication_failed, reason}}
    end
  end

  defp finalize(output, attributes, profile) do
    with {:ok, report} <- Report.new(attributes),
         {:ok, artifact} <- ArtifactStore.write(output, report, profile) do
      {:ok, %{report: report, manifest: artifact.manifest, output: artifact.output}}
    else
      {:error, {:failure_published, reason}} -> {:error, reason}
      {:error, {:failure_publication_failed, _reason} = error} -> {:error, error}
      {:error, %Insider.Protocol.Error{}} -> fail(output, :invalid_report)
      {:error, reason} when is_atom(reason) -> fail(output, reason)
      _other -> fail(output, :internal_failure)
    end
  end

  @doc false
  @spec comparison(map(), map()) :: map()
  def comparison(baseline, instrumented) do
    base_host = baseline["summary"]["host"]
    observed_host = instrumented["summary"]["host"]
    base_runtime = baseline["summary"]["runtime"]
    observed_runtime = instrumented["summary"]["runtime"]

    %{
      "throughput_change_basis_points" =>
        basis_points(
          observed_host["throughput_per_second"],
          base_host["throughput_per_second"]
        ),
      "error_delta" => observed_host["errors"] - base_host["errors"],
      "missed_operations_delta" =>
        observed_host["missed_operations"] - base_host["missed_operations"],
      "latency_p99_change_basis_points" =>
        basis_points(observed_host["latency_p99_us"], base_host["latency_p99_us"]),
      "cpu_time_change_basis_points" =>
        basis_points(observed_runtime["cpu_time_us"], base_runtime["cpu_time_us"]),
      "scheduler_change_basis_points" =>
        basis_points(
          observed_runtime["scheduler_utilization_permyriad"],
          base_runtime["scheduler_utilization_permyriad"]
        ),
      "memory_change_bytes" => observed_runtime["memory_bytes"] - base_runtime["memory_bytes"],
      "garbage_collections_delta" =>
        observed_runtime["garbage_collections"] - base_runtime["garbage_collections"],
      "process_count_delta" => observed_runtime["process_count"] - base_runtime["process_count"],
      "port_count_delta" => observed_runtime["port_count"] - base_runtime["port_count"]
    }
  end

  defp basis_points(_observed, 0), do: 0
  defp basis_points(observed, baseline), do: div((observed - baseline) * 10_000, baseline)

  defp outcome(%{"status" => "passed"}, %{"status" => "passed"}), do: "passed"
  defp outcome(_baseline, _instrumented), do: "failed"

  defp measured_phases(profile) do
    case enable_scheduler_wall_time() do
      {:ok, previous} ->
        try do
          {baseline, baseline_uncertainty} = Phase.run(profile, :baseline)
          {instrumented, instrumented_uncertainty} = Phase.run(profile, :instrumented)
          {baseline, baseline_uncertainty, instrumented, instrumented_uncertainty}
        after
          _ = restore_scheduler_wall_time(previous)
        end

      :unavailable ->
        {baseline, baseline_uncertainty} = Phase.run(profile, :baseline)
        {instrumented, instrumented_uncertainty} = Phase.run(profile, :instrumented)
        {baseline, baseline_uncertainty, instrumented, instrumented_uncertainty}
    end
  end

  defp enable_scheduler_wall_time do
    {:ok, :erlang.system_flag(:scheduler_wall_time, true)}
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp restore_scheduler_wall_time(previous) when is_boolean(previous),
    do: :erlang.system_flag(:scheduler_wall_time, previous)

  defp restore_scheduler_wall_time(_previous), do: :ok

  defp require_clean_revision(%{"revision" => %{"clean" => true}}), do: :ok
  defp require_clean_revision(%{"revision" => %{"clean" => false}}), do: {:error, :dirty_revision}

  defp uncertainty(phase_uncertainty) do
    base = [
      "Synthetic host evidence does not establish production capacity.",
      "No service-specific overhead or recovery budget has been approved.",
      "Baseline and instrumented phases run sequentially on one host.",
      "Latency quantiles are fixed-bucket upper-bound approximations.",
      "SHA-256 establishes artifact identity, not authenticity."
    ]

    (base ++ phase_uncertainty)
    |> Enum.uniq()
    |> Enum.take(32)
  end

  defp project_root do
    project_directory = Mix.Project.project_file() |> Path.dirname()
    Path.expand("../..", project_directory)
  end
end
