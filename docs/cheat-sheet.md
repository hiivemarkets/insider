# Cheat sheet

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The most-used observer commands, grouped by task. Run them from
`tools/insider_lab` in a checkout, or write `insider-lab live` in place of
`mix insider.live` with the escript from Hex
(`mix escript.install hex insider_lab`). Replace `SESSION_ID`, `TRACE_ID`,
and the pid with the values that earlier commands print.

## Contents

- [Set up](#set-up)
- [Check the node](#check-the-node)
- [Start a session](#start-a-session)
- [Mark, act, and read](#mark-act-and-read)
- [Follow a request or a process](#follow-a-request-or-a-process)
- [Stop and report](#stop-and-report)
- [Several agents at once](#several-agents-at-once)

## Set up

Make a private cookie once, and boot the target with it. Then set `N` in
each shell. `N` is an array, so it works in bash and zsh. See
[Boot the target](live/live-api-and-transports.md#boot-the-target).

```sh
(umask 077 && openssl rand -hex 24 > ~/.my_app.cookie)
N=(--node "my_app@$(hostname -s)" --cookie-file "$HOME/.my_app.cookie")
```

## Check the node

See [Welcome document](live/live-welcome-and-reports.md#welcome-document) and
[Load Insider into the target](live/live-api-and-transports.md#load-insider-into-the-target).

```sh
# Is live observation allowed here? --load installs Insider if it is missing
mix insider.live capabilities "${N[@]}" --load
# The agent quick start
mix insider.live welcome "${N[@]}"
# The whole reference
mix insider.live welcome "${N[@]}" --full
```

## Start a session

See [Live observation](live/live-api-and-transports.md#live-observation) and
[Lease](live/live-api-and-transports.md#lease).

```sh
# Record Logger and Telemetry events (the default events this node has)
mix insider.live start "${N[@]}" --component logger --component telemetry --logger-level info
# Add OpenTelemetry spans when the node runs the OpenTelemetry SDK
mix insider.live start "${N[@]}" --component logger --component otel --component telemetry --logger-level info
# State, lease, readers, and recording options
mix insider.live status "${N[@]}" --session SESSION_ID
# Change a recording option of the running session
mix insider.live amend "${N[@]}" --session SESSION_ID --telemetry-measurement duration --reader agent-a
```

## Mark, act, and read

See [Pairing marks](live/live-sessions-and-readers.md#pairing-marks),
[Pairing chart](live/live-sessions-and-readers.md#pairing-chart),
[Digest](live/live-digest-filters-and-trends.md#digest),
[Known-normal baseline](live/live-digest-filters-and-trends.md#known-normal-baseline), and
[Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).

```sh
# Serve a live chart for the programmer; give them the URL it prints
mix insider.live chart "${N[@]}" --session SESSION_ID --serve
# Mark the moment before you act
mix insider.live mark "${N[@]}" --session SESSION_ID --label 'about to click Confirm' --reader agent-a
# What happened since the mark, as plain text
mix insider.live digest "${N[@]}" --session SESSION_ID --since-mark 'about to click Confirm' --human
# The events since the newest mark, one line each
mix insider.live events "${N[@]}" --session SESSION_ID --since-mark --format compact
# The events from the start. Continue from the next_cursor it prints
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --limit 100
# Mark the anomalies of the last 5 minutes as normal, so digests lead with new ones
mix insider.live baseline "${N[@]}" --session SESSION_ID --human
# A chart of what happened since the mark, as one HTML file
mix insider.live chart "${N[@]}" --session SESSION_ID --since-mark
```

## Follow a request or a process

See [Read one request as a trace](live/live-otel-traces.md#read-one-request-as-a-trace),
[Timeline of a process or request](live/live-otel-traces.md#timeline-of-a-process-or-request),
and [One-shot inspections](live/live-runtime-evidence.md#one-shot-inspections).

```sh
# One request as a tree of spans and events
mix insider.live trace "${N[@]}" --session SESSION_ID --trace-id TRACE_ID --human
# Everything one process did, in time order
mix insider.live timeline "${N[@]}" --session SESSION_ID --pid '<0.1234.0>' --human
# One process now: status, memory, links, stack, and mailbox shapes
mix insider.live process "${N[@]}" --name MyApp.Worker
```

## Stop and report

See [Stop and check the cleanup receipt](live/live-api-and-transports.md#stop-and-check-the-cleanup-receipt)
and [Agent reports](live/live-welcome-and-reports.md#agent-reports).

```sh
# Stop, then check the cleanup receipt in the result
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a
#=> {…,"result":{"receipt":{"schema":"insider.collector-session-receipt/v1",…},"state":"stopped",…},…}
# Report a difference between the docs and what you observed
mix insider.live report --category doc_mismatch --message 'welcome says X; observed Y'
```

## Several agents at once

Each `mix insider.live` command takes Mix's build lock. Build the escript
once, and concurrent commands no longer wait. See
[Several agents at once: the escript](live/live-api-and-transports.md#several-agents-at-once-the-escript).

```sh
mix escript.build
./insider-lab live status "${N[@]}" --session SESSION_ID
```
