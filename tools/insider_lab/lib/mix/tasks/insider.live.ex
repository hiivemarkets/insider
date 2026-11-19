defmodule Mix.Tasks.Insider.Live do
  @shortdoc "Observes a live Insider session in another local BEAM node"
  @moduledoc """
  The observer, as a Mix task of the `insider_lab` package. The core
  package, `insider`, has no Mix tasks. Outside an Insider checkout, use the
  escript instead: `mix escript.install hex insider_lab`, then
  `insider-lab live`, with the same operations, flags and output
  (`insider-lab --help` describes the escript).

  Attaches to another BEAM node on this machine over Erlang distribution and
  drives its `Insider.Live` session, printing canonical JSON.
  [Observer node](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-api-and-transports.md#observer-node-erlang-distribution)
  in the root `docs/` is the reference for target setup and every flag.

      mix insider.live --help
      mix insider.live help start
      mix insider.live capabilities --node my_app@localhost --cookie-file ~/.my_app.cookie --load
      mix insider.live welcome --node my_app@localhost --cookie-file ~/.my_app.cookie
      mix insider.live welcome --node my_app@localhost --cookie-file PATH --full
      mix insider.live start --node my_app@localhost --cookie-file PATH --component logger
      mix insider.live events --node my_app@localhost --cookie-file PATH --session ID --cursor 0
      mix insider.live watch --node my_app@localhost --cookie-file PATH --session ID --from-cursor latest --for 60s
      mix insider.live stop --node my_app@localhost --cookie-file PATH --session ID
      mix insider.live report --category doc_mismatch --message 'welcome says X; observed Y'
      mix insider.live reports [--node my_app@localhost --cookie-file PATH]
      mix insider.live reports submit [--confirm]

  `--help`, `help OPERATION`, and `OPERATION --help` print usage text with
  each flag's value syntax and examples, and exit 0. Help, usage errors, and
  the commands the target prints in hints and `next` fields name
  `mix insider.live` here and `insider-lab live` in the escript. Operations: `welcome`,
  `capabilities`, `start`, `events`, `status`, `renew`, `stop`, `watch`,
  `report`, `reports`, and `reports submit`. An agent starts with `welcome`,
  the target's agent quick start (`--full` for the whole generated
  reference). Each target
  invocation starts a hidden, non-listening observer node, refuses a host that
  is not loopback or this machine, reads the cookie from a file readable only
  by its owner, and stops distribution before exiting. `watch` prints one JSON
  document per line until SIGTERM, `--for DURATION` (`500ms`, `30s`, `5m`, at
  most `24h`), `--max-events N`, the end of the session, or the loss of the
  target; only its first line carries the envelope, and its last (`stopped`)
  line the `next_cursor` to resume from.

  `report` and `reports` use the observer's local report queue in
  `INSIDER_LIVE_REPORTS_DIR` (default `insider-live` under the system
  temporary directory). `reports submit` files GitHub issues through `gh`
  only with `--confirm` or `config :insider, :live_report_submission, :github`
  in the observer or the target; otherwise it prints what it would send.

  `start` takes record-time filters: `--logger-level`, `--logger-include` and
  `--logger-exclude` (repeatable; `domain:a.b`, `application:name`, or
  `module:Name`), `--exclude-origin` (repeatable; `oban`, `application:name`,
  `module:Name`, or `none` alone), `--telemetry-min-duration-ms`,
  `--telemetry-event-min-duration KIND=MS` (repeatable), `--telemetry-summary
  KIND` (repeatable), and `--telemetry-summary-interval-ms`. `events` takes
  `--cursor N|latest`, `--limit`, `--max-bytes`, and `--scan-limit`; `watch`
  takes `--from-cursor N|latest`. Both take a read-time view: `--view-source`,
  `--view-kind`, and `--view-exclude-kind` (repeatable), and
  `--view-min-severity`.

  A target without Insider, or with a different Insider version, is refused.
  `--load` only installs: it pushes this project's compiled Insider application
  into a target without Insider and starts it, or starts this same build where
  it is loaded but stopped. It never replaces another Insider build
  (`load_build_differs`); `--force-load` does, and ends any session, so save
  its evidence first. Both are refused unless the target reports a
  development, test or ci environment.

  Exit status: `0` ok, `1` error, `3` unsupported target or refused load, `64`
  invalid input (`usage`, or `invalid_options` naming the flag and its
  expected value), `70` observer failure, `124` timeout.
  [Error codes](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-welcome-and-reports.md#error-codes)
  in the root `docs/` lists every error code.
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    # `--load` pushes this project's compiled Insider. The project's alias for
    # this task compiles it first, with compiler output on standard error.
    status = Insider.Lab.Live.CLI.run(arguments, &Insider.Lab.Output.write/1)
    if status != 0, do: exit({:shutdown, status})
  end
end
