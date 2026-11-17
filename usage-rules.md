# Insider usage rules

Rules for agents using Insider, a runtime-evidence library for BEAM
applications, built for coding agents.
Short on purpose. Each rule names its guide: `deps/insider/guides/<path>.md`
in a host app, or `guides/` in an Insider checkout.

## Where the docs are

- `deps/insider/guides/agents/*.md` and this file: the guides for exactly the
  Insider the app uses. With a `path:` dependency, read that checkout's
  `guides/` instead.
- On a running node, the welcome document is the authoritative contract:
  `Insider.Live.welcome()` / `Insider.Live.JSON.welcome()` (the quick start;
  `%{"full" => true}` for the full reference), or
  `mix insider.live welcome --node … --cookie-file …` (`--full`) from the
  Insider checkout's `tools/insider_lab`, or `insider-lab live welcome …`
  after `mix escript.install hex insider_lab`.
- `deps/insider/docs/README.md` (or `docs/README.md` in a checkout) indexes
  the full reference. Its task table names the one section to read for a
  task, with its size. The guides point into it.

## Live observation

- Read the welcome quick start before anything else and keep its `hash`;
  `capabilities` reports the current hash. Read `--full` when you need an
  option's exact syntax or an error code. See
  `guides/agents/live-observation.md`.
- Live observation works only where the node resolves to development, test,
  or ci. Never try to assert or work around the environment.
- One session per node. Start with the fewest components that can show the
  effect, then act, `digest` the session for the overview, and read
  `events_since` from your cursor for detail, keeping `next_cursor`.
  Non-empty `gaps` means evidence was lost.
- Reads renew the lease; `status` and subscriptions do not. `stop` when done
  and check the receipt.
- Sharing a node with other agents: pass `--reader NAME` to reads, watches,
  stops and amends; `amend` changes recording options for everyone without
  losing history; never `--force` a stop over a peer's active reads without
  asking. Concurrent agents use the escript (`./insider-lab live`).
- Disclosure depends on the node's profile. Check the welcome's
  `effective_disclosure.profile` (also `runtime.disclosure_profile`) before
  you rely on any payload. Development and test default to `rich`: events
  carry Logger message text and metadata, Telemetry metadata and
  measurements, with credentials masked. In the `strict` profile (the ci
  default, or `config :insider, :live_disclosure, :strict`), event payloads,
  Logger message text, and Telemetry metadata never leave the node. In
  either profile, do not try to recover what was withheld or masked another
  way. See the welcome's `disclosure` rules.

## Reporting Insider's own bugs

- You must report Insider bugs and every behaviour that differs from the
  welcome document: `mix insider.live report --category doc_mismatch
  --message '…'`, or `Insider.Live.JSON.report(%{"category" => …,
  "message" => …})`. Categories: `bug`, `doc_mismatch`,
  `missing_capability`, `confusing_output`.
- Say what you expected (cite the welcome field) and what happened. Never put
  payloads, log text, option values, or secrets in a report.
- Reports stay local. Only the developer sends them upstream, with
  `mix insider.live reports submit --confirm`. `reports submit --dry-run`
  only previews, whatever opt-in is set. Cite your session with
  `report --session ID`; `reports` groups the shared queue by node and
  session.

## Other agent tooling

- ExUnit candidates and oracles: `guides/agents/candidates-cli.md`,
  `guides/agents/oracles.md`.
- What Insider refuses to do, and why: `guides/agents/refusals.md`. Stop at a
  refusal; do not look for a weaker path.
