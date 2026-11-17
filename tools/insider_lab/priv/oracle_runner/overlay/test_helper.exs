# Fixed `mix insider.oracle` overlay helper. The bootstrap puts this directory first
# in `:test_paths`, so Mix requires this file before any host helper. It requires
# the host helpers in their declared order (Mix then sees them as already
# required), reports that they finished, and then requires the oracle copy named
# by `INSIDER_ORACLE_RUNNER_ORACLE`. The oracle therefore loads after the host's
# suite baseline and before any test file, exactly as an appended
# `Code.require_file/1` line in `test/test_helper.exs` would, without editing it.
defmodule InsiderLab.OracleRunnerOverlay do
  @moduledoc false

  @helpers_prefix "INSIDER_ORACLE_RUNNER_HELPERS="
  @suite_prefix "INSIDER_ORACLE_RUNNER_SUITE="

  def install(overlay) do
    host_paths = Enum.reject(Mix.Project.config()[:test_paths], &(Path.expand(&1) == overlay))
    Enum.each(host_paths, &Code.require_file(Path.join(&1, "test_helper.exs")))

    ExUnit.after_suite(fn result ->
      IO.puts([@suite_prefix, :json.encode(suite_summary(result))])
    end)

    IO.puts([
      @helpers_prefix,
      :json.encode(%{
        "elixir" => System.version(),
        "host_helpers" => length(host_paths),
        "otp" => System.otp_release()
      })
    ])

    Code.require_file(System.fetch_env!("INSIDER_ORACLE_RUNNER_ORACLE"))
  end

  defp suite_summary(result) do
    for key <- [:excluded, :failures, :skipped, :total], into: %{} do
      value = Map.get(result, key)
      {Atom.to_string(key), if(is_integer(value), do: value)}
    end
  end
end

InsiderLab.OracleRunnerOverlay.install(Path.expand(__DIR__))
