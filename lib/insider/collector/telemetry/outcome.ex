defmodule Insider.Collector.Telemetry.Outcome do
  @moduledoc false

  # Whether a Telemetry event reports a failure. It is decided in the
  # emitting process from the event name and a few fixed metadata shapes:
  # the tag of a result, the class of an HTTP status, the kind of a caught
  # exception, whether an error is present, and whether an Absinthe
  # blueprint's result has GraphQL errors. No other metadata value is
  # read, and the decision records nothing about the metadata.
  #
  # The record-time gate uses it to let errors past a minimum duration and
  # to count a summary's `errors`; the Telemetry collector uses it for the
  # event's severity. A summary's error count and the events a reader keeps
  # with a minimum severity of `error` therefore follow the same rule.

  @failure_kinds [:error, :exit, :throw]

  # The rule as the welcome document states it, one row per clause below,
  # in the order they are tried. A test checks every row's example.
  @rules [
    %{
      "when" => "the event name ends in exception",
      "examples" => ["phoenix.router_dispatch.exception", "oban.job.exception"],
      "severity" => "error"
    },
    %{
      "when" => "metadata result is {:error, _} or :error",
      "examples" => [
        "a failed Ecto repo query",
        "finch.request.stop",
        "phoenix.socket_connected"
      ],
      "severity" => "error"
    },
    %{
      "when" => "metadata conn.status or status is 500 to 599",
      "examples" => [
        "phoenix.endpoint.stop",
        "phoenix.router_dispatch.stop",
        "bandit.request.stop",
        "phoenix.error_rendered"
      ],
      "severity" => "error"
    },
    %{
      "when" => "metadata kind is error, exit, or throw",
      "examples" => ["a :telemetry.span exception", "phoenix.error_rendered"],
      "severity" => "error"
    },
    %{
      "when" => "metadata error is present and not nil or false",
      "examples" => ["oban.plugin.stop", "bandit.request.stop"],
      "severity" => "error"
    },
    %{
      "when" =>
        "metadata blueprint (an Absinthe operation) has GraphQL errors, even in an HTTP 200",
      "examples" => ["absinthe.execute.operation.stop"],
      "severity" => "error"
    }
  ]

  @doc "The failure rule, row by row, for the welcome document."
  @spec rules() :: [map()]
  def rules, do: @rules

  @doc "Whether the event `name` with `metadata` reports a failure."
  @spec error?([atom()], term()) :: boolean()
  def error?(name, metadata) when is_list(name),
    do: List.last(name) == :exception or failed?(metadata)

  def error?(_name, metadata), do: failed?(metadata)

  @doc """
  Whether `metadata` has one of the failure shapes. The gate keeps the
  exception test of the event name precomputed and calls only this.
  """
  @spec failed?(term()) :: boolean()
  def failed?(%{result: {:error, _reason}}), do: true
  def failed?(%{result: :error}), do: true
  def failed?(%{conn: %{status: status}}) when status in 500..599, do: true
  def failed?(%{status: status}) when status in 500..599, do: true
  def failed?(%{kind: kind}) when kind in @failure_kinds, do: true
  def failed?(%{error: error}) when error not in [nil, false], do: true
  def failed?(%{blueprint: %{result: %{errors: [_ | _]}}}), do: true
  def failed?(_metadata), do: false
end
