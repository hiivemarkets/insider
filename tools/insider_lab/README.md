# Insider Lab

Insider Lab is the development and disposable-environment project for
Insider, published to Hex as `insider_lab`. It depends on the root `:insider`
collector/evidence core, but the core has no reverse dependency.

Lab owns fixtures, semantic contracts and invariants, scenarios, Sentinel,
external-process and sandbox seams, the restart-capture fixture harness, and
the CLI, Mix task, and escript interfaces. These capabilities are intentionally
absent from the production artifact and must not be treated as a staging or
production authority boundary.

## Install the CLI from Hex

```sh
mix escript.install hex insider_lab
insider-lab live --help
```

Mix installs the `insider-lab` escript in its escripts directory and prints
that directory. Add it to your `PATH`. The escript carries the Insider it was
built with, at the Lab's version, and `--load` pushes that Insider into a
development node. Changes are listed in the repository
[CHANGELOG](https://github.com/hiivemarkets/insider/blob/main/CHANGELOG.md).

## Run the Lab from a checkout

In this repository the Lab depends on the core by path, and shares the root
`deps/`, `_build/` and `mix.lock`. Its Hex package depends on `insider` from
Hex at the same version. `INSIDER_LAB_HEX=1` selects that form here, to build
or publish the package (`INSIDER_LAB_HEX=1 mix hex.build`). It then uses its
own `deps/` and `mix.lock` in this directory, which Git ignores. See
[Releasing](https://github.com/hiivemarkets/insider/blob/main/docs/development.md#releasing).

Run Lab separately:

```sh
mix deps.get --check-locked
mix format --check-formatted
mix test
```

The Lab project owns the command-line interfaces, the agent-requested ExUnit
candidate inventory, and optional execution components:

```sh
mix insider capabilities
mix insider inspect --name Elixir.MyApp.Supervisor
mix insider.candidates --root /path/to/project --path test
mix insider.privacy_corpus --corpus priv/privacy_corpus/example.json --environment production
mix insider.oracle --profile host.json --root /path/to/project --output /tmp/run-1 --oracle application_env --application logger --key default_handler -- test/some_test.exs
mix insider.live capabilities --node my_app@$(hostname -s) --cookie-file ~/.my_app.cookie
mix escript.build
./insider-lab --discover
./insider-lab live capabilities --node my_app@$(hostname -s) --cookie-file ~/.my_app.cookie
```

These tasks compile the Lab before they run, with Mix's compiler progress and
build-lock messages on stderr. Stdout carries only the task's own output (its
JSON document, or the text formats and help a task documents), so it can be
parsed even on the first call after a Lab source change or while another
`mix` in the same checkout holds the build lock. A tool that merges stderr into
stdout sees those notices in front of the JSON; run the escript
(`./insider-lab`) there, which starts no Mix and prints neither.

`mix insider.live` (and `insider-lab live`) attaches a short-lived, hidden
observer node to another BEAM node on this machine over Erlang distribution
and drives that node's `Insider.Live` session: `welcome` (the agent's
generated contract; start here), `capabilities`, `discover` (the
Telemetry event names the target can emit; `--prefix a.b` narrows them),
`start` (`--telemetry-event 'PREFIX.*'` subscribes to every discovered name
below the prefix), `amend`, `events`, `digest`, `trends`, `trace` and `timeline` (one trace, process, or
request; see [OpenTelemetry spans and traces](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-otel-traces.md#opentelemetry-spans-and-traces)),
`status`, `handoff`, `renew`, `stop`, the long-running `watch` and
`otlp-receive` (a loopback-only OTLP/HTTP trace receiver that records a
frontend's spans in the session; see
[Frontend traces](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-otel-traces.md#frontend-traces-otlp-http-receiver)),
and the one-shot inspections
`process` (`--name NAME` or `--pid PID`: process_info, stacktrace, and the
mailbox by message shape), `bin_leak`, `ports` (`--type`, `--owner`), and
`alloc` (needs recon on the target, which `--load` pushes when it lacks
it); [Telemetry discovery](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-runtime-evidence.md#telemetry-discovery)
and [One-shot inspections](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-runtime-evidence.md#one-shot-inspections)
are the reference. `report` files an
agent's report about Insider into the observer's local queue, `reports`
lists it (copying a target's in-node reports first when given `--node`), and
`reports submit` files GitHub issues through `gh` only with `--confirm` or a
host opt-in, otherwise printing what it would send. `reports submit --dry-run`
always previews, overriding every opt-in; each result names its effective
`authorization`, and a real submission writes it to standard error before
its first `gh` call. `--fingerprint` (repeatable) and `--session` select the
reports `reports` and `reports submit` cover (a session matches any of a
report's `occurrences`, since a duplicate keeps only the newest context),
`reports` groups the shared
queue by node and session, and `report --session ID` cites a session in the
report's context (otherwise the last target command's session). The
[documentation index](https://github.com/hiivemarkets/insider/blob/main/docs/README.md)
lists the reference sections ("Welcome document", "Digest", "Summary trends",
"Several agents on one session", "Agent reports", "Observer node") that
document target setup, `--load`, reports, the output formats, and the
exit-code and error vocabulary.
`start --disclosure strict` asks the target for a stricter disclosure profile
than its host default; a richer request returns the target's
`disclosure_denied` error.

`digest --session S` prints `insider.live-digest/v1` for the events the
session recorded in the last minute, up to the newest receipt when it starts
(counts, crash loops with their period, top error signatures, latency tables
with exemplar receipts and lost exemplars, trends, Logger bursts, longest
mailboxes, VM deltas, filtered and gaps, and hints that name the window they
cover). `--since latest-DURATION` (`ms`, `s`, `m` or `h`, 1 s to 24 h, by
the Recorder's admission time), `--since N` (after a receipt; 0 is the
session start) or `--since latest-N` (the newest N receipts) chooses another
window, and `--since-mark [LABEL]` reads after the newest pairing mark (or
the newest with that label); its `window` reports `since`, `from_wall_time`,
`start_exact`, `mark`, `as_of` and `age_ms`. `mark --session S --label
'about to click Confirm'` marks the moment before the developer acts, and
`marks --session S --human` lists the marks; `events` and `timeline` take
`--since-mark` too (on `events` in place of `--cursor`). `--human` prints a
few plain-text lines for the developer instead, with a `Window:` line that
names the window (and the mark it starts at) and the age of its newest event.
`chart --session S` (`--since`, default `latest-15m`, or `--since-mark`)
writes the session as one self-contained HTML page for the programmer an
agent pairs with (requests, latency, waits, errors, the longest mailbox,
memory and evictions over time, the marks, the anomalies, and the digest's
lead lines; inline SVG, no script, mode 0600) to `--out PATH` or the system
temp directory and prints its path; `chart --serve` serves it live on
127.0.0.1 at a secret URL instead, for `--for` (default 30m) or until the
session ends, without renewing the lease. See
[Pairing chart](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-sessions-and-readers.md#pairing-chart).
`trends --session S` (default `--since 0`, the session start) prints
`insider.live-trends/v1` for its window: each summarised
Telemetry kind's and Logger burst's windows in fixed units, and the Poller
series per sample (binary bytes and port count, ports per type, mailbox
length per ranked or watched process) with change, growth per minute and
maximum; `--kind KIND` (repeatable; `logger_summary` for the bursts,
`vm_sample`, `port_top`, `process_top` or `process_watch` for the Poller
series) and `--windows N` narrow it.
Summaries come from `start` flags: `--telemetry-summary KIND` with
`--telemetry-summary-interval-ms`, `--telemetry-duration-scope
KIND=handler|caller` (repeatable; declares how a summarised kind's duration
was measured, else its scope is unknown; `amend --reset
telemetry-duration-scope` clears it), and `--logger-summary RULE` with
`--logger-summary-interval-ms` (Logger bursts per message template, call
site, and level).
`events` and `watch` take `--format json` (default: each event without the
fields that are constant, null, or empty), `--format full` (exactly as the
target returns them), or `--format compact` (one line per event and a `#`
line per batch with cursors, disclosure profile, gaps, and filtered counts;
a Poller event's line carries its content, such as `port_top`'s
`by_type=cat:39(+3)` and `ets_top`'s tables by memory and size).

```sh
N=(--node "my_app@$(hostname -s)" --cookie-file ~/.my_app.cookie)
mix insider.live digest "${N[@]}" --session live-6 --since latest-1000 --human
mix insider.live trends "${N[@]}" --session live-6 --human
mix insider.live events "${N[@]}" --session live-6 --cursor 0 --format compact
mix insider.live watch "${N[@]}" --session live-6 --from-cursor latest --for 60s --format compact
```

Several agents can share one session: every read (`events`, `watch`,
`digest`, `trends`, `trace`, `timeline`), `stop`, and `amend` take
`--reader NAME`, and `status` lists named readers with their own views; the
`--view-*` flags, given with `--reader`, become that reader's view for its
later reads (`--view-clear` clears it): `--view-exclude-signature` hides a
known error signature, and `--view-service`, `--view-route`, and
`--view-trace` keep only the traces a reader cares about; `stop` refuses with
`readers_active` while another named reader is active unless `--force`, and
a stopped session stays readable for a drain window; `amend` changes the
recording options of a running session without losing its history
(`--reset FLAG`, such as `--reset watch-process`, returns one to its
default); `handoff`
prints what another agent needs to continue. `start --component calls --calls
MOD.FUN/ARITY` (with `--calls-results`, `--calls-max`, `--calls-rate-max`,
`--calls-rate-ms`, and `--calls-max-bytes`) traces calls for the session on
OTP 28 and later, removed at stop, lease expiry, or amend; see
[Call traces](https://github.com/hiivemarkets/insider/blob/main/docs/live/live-runtime-evidence.md#call-traces). Concurrent agents should run
the escript (`mix escript.build`, then `./insider-lab live …`): it starts no
Mix, so it never waits on the build lock. It runs on two schedulers that
sleep rather than spin, which removes most of a call's start-up cost on a
loaded host. A `capabilities` call measured 0.8–1.7 s at a load average of
about 156 (14.6–19.9 s before), 2.5–4.5 s at about 261, and 0.5–0.8 s at
28–31; calls still slow down as load rises. `installation.insider_commit`
names the commit it was built from. `installation.same_build` is false when
the target runs another Insider build (another version, commit, or local
change). `--load` never replaces it, started or not: it refuses with
`load_build_differs`, naming both builds, whether a session is active, and
the remedy. Only `--force-load` replaces Insider code, and it ends any session.

`mix insider.candidates` writes one JSON inventory to stdout and exits `0`
(complete and clean), `2` (complete with candidates), `3` (`empty_selection`),
`4` (`unsupported_source`), `5` (`truncated`), `64` (invalid arguments), or
`70` (inventory failure); only `0` means nothing was found in a complete scan.
Each candidate target may carry a static `oracle` hint naming one of
the fixed, value-free ExUnit oracle artifacts in `priv/oracles/`:

| Artifact | Schema | Target selector | Optional |
| --- | --- | --- | --- |
| `priv/oracles/application_env_test.exs` | `insider.application-env-oracle/v1` | `INSIDER_ORACLE_APPLICATION` plus exactly one of `INSIDER_ORACLE_KEY` (one key) or `INSIDER_ORACLE_KEYS` (1 to 16 comma-separated keys) | `INSIDER_ORACLE_CONTEXT` |
| `priv/oracles/telemetry_dead_handlers_test.exs` | `insider.telemetry-dead-handlers-oracle/v1` | `INSIDER_ORACLE_TELEMETRY_EVENT` (comma-separated atom path) | `INSIDER_ORACLE_CONTEXT` |
| `priv/oracles/otel_global_state_test.exs` | `insider.otel-global-state-oracle/v1` | none (fixed globals; no inventory hint, the `otel_global_capture` signal has no target) | `INSIDER_ORACLE_CONTEXT` |

Inventory `oracle` hints always name the single-key `INSIDER_ORACLE_KEY` form.
An agent installs an artifact temporarily from the adopter's
`test/test_helper.exs`, runs one selected test command, then restores the
helper. The artifacts observe before/after state and emit one JSON line; they
never select or start tests. The OpenTelemetry artifact requires the adopter's
test VM to have `opentelemetry_api` loaded; the Lab depends on it only in the
`:test` environment for the artifact's own tests.
[Lab: ExUnit candidates and oracles](https://github.com/hiivemarkets/insider/blob/main/docs/lab-candidates-and-oracles.md)
describes all three in full, and `guides/agents/oracles.md` is the operating
manual.

`mix insider.oracle` runs one artifact against one selected test command
without editing the target. It starts `mix test` with `MIX_EXS` naming a fixed
bootstrap that compiles the target's `mix.exs`, bypasses the host's `test`
alias when an explicit `insider.oracle-host-profile/v1` file says so, and
prepends a run-local overlay to `:test_paths` whose helper requires the host
helpers and then the oracle. The child gets only `HOME`, `PATH`,
`MIX_ENV=test`, `MIX_EXS`, the oracle inputs, the declared database suffix,
and the profile's declared passthrough variables. Each run writes a new
caller-named directory, which must resolve outside the target and its Git work
tree, with `run.json` (`insider.oracle-run/v1`), an `output.txt` filtered by a
fail-closed output policy (`allowlisted` summaries by default, or `redacted`),
and copies of the oracle, bootstrap, and overlay that ran. Target
fingerprinting has time, listing, file-count, and content-byte budgets. Exit
status is `0`, `2`, or `6` for a complete run (`not_reproduced`, `confirmed`,
`not_observed`), `3` (`empty_selection`), `4` (`unsupported_source`), `5`
(`truncated`), `70` (`infrastructure_failure`), or `64` (invalid input, no
directory). The bootstrap and overlay live in `priv/oracle_runner/`.

`priv/probes/actor_differential.exs` defines
`InsiderLab.ActorDifferentialOracle`, which an agent-written probe test in the
target requires and calls with `run/1`. It runs one operation as several
declared actors, each against a fresh fixture built by a caller-supplied
function, requires healthy controls first, and returns and prints one
value-free `insider.actor-differential-oracle/v1` verdict
(`INSIDER_ACTOR_DIFFERENTIAL_ORACLE=`). It is not a `mix insider.oracle`
kind; see `guides/agents/oracles.md`.

`priv/probes/fault_rerun.exs` defines `InsiderLab.FaultRerunOracle`, which an
agent-written probe test calls with `run/1` to run a background worker once
with no fault as a healthy control, then with a declared provider fault and
again as the retry. It stubs every exported arity of the declared provider
functions through a caller-supplied installer, compares each run's effects
with a caller projection of committed references grouped by boundary, and
returns and prints one
value-free `insider.fault-rerun-oracle/v1` verdict
(`INSIDER_FAULT_RERUN_ORACLE=`) naming orphaned, repeated, or missing effects.
See `guides/agents/oracles.md`.

`mix insider.privacy_corpus` projects a caller-supplied synthetic corpus
through the exact Logger and Telemetry ingress handler code paths and prints an
`insider.privacy-corpus-report/v1` document that names retained fields and
canary coordinates without values. `priv/privacy_corpus/example.json` is a
schema example with fake values; the application corpus and the review of
every retained field remain human work.

```elixir
config :insider_lab, components: [:contract, :scenario, :sentinel]
```

The default Lab component is `:contract`; the root `:insider` application
starts none of these components.

The Lab, installed from Hex or run from a checkout, grants no ambient
provider, credential, repository, publication, or deployment authority.
Trusted host configuration can explicitly enable sandbox providers and a
draft-only provider with disclosure authorization. Draft effects are disabled
by default. These seams grant no merge or deployment authority.

The Phase 6 offline repair chain lives entirely in this project under
`Insider.Sentinel`: `CodingAgent.Handoff` and `CodingAgent.CandidateSubmission`,
`Verification`, `RepairReport.Manifest`, `DraftProposal`, `SourceOwnership`,
`Dedup`, `Minimizer`, `Bisection`, and the `DraftCreation.Executor` gate.
[Sentinel and the proof workflow](https://github.com/hiivemarkets/insider/blob/main/docs/sentinel-and-proof-workflow.md)
describes each artifact and its limits, and
`guides/agents/sentinel-chain.md` maps the chain in order;
`test/insider/sentinel/repair_orchestration_integration_test.exs` runs the
documented chain end to end on a live sandbox executor with the test provider
and disclosure authority, and proves that one candidate identity threads
through every artifact. Nothing in this chain contacts a repository, network,
model, or real provider.

`mix docs` in this directory writes an API reference for the Lab-only modules
to `doc/` (gitignored). The guides themselves are generated from the
repository root.
