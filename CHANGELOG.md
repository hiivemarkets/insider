# Changelog

All notable changes to Insider will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-11-18

A documentation and packaging release: every entry point says which of the
two packages does what.

### Changed

- The two Hex packages now name each other. The `insider` package's
  description says that the command-line observer and its Mix tasks ship
  separately as `insider_lab`, and its hex.pm page links
  "CLI (insider_lab)". The `insider_lab` description says that it is the
  command-line observer for `insider`, and its page links "Core (insider)".
- The README, Getting started, the documentation index, the cheat sheet,
  the glossary (a new entry, "insider vs insider_lab"), `usage-rules.md`,
  the Lab README, and the `Insider`, `Insider.Live` and
  `Mix.Tasks.Insider.Live` moduledocs say which package to install for
  what. Install `insider_lab` to observe a node, with no dependency in the
  app. Add `insider` to an app only for its agents or for Tidewave. The core
  has no Mix tasks, so `mix insider.live` in an app that depends only on
  `insider` reports that the task could not be found, and these documents
  say so and name `insider-lab live` instead. The two always release at the
  same version.
- The cheat sheet and `usage-rules.md` now write observer commands as
  `insider-lab live`, the escript from Hex, and mention `mix insider.live`
  only for an Insider checkout.
- The welcome's first quick-start step, a new `transports.observer.package`
  field, and the observer's `--help` name `insider_lab` as the observer and
  say that the `insider` package has no Mix tasks. The welcome's `hash`
  changes accordingly.
- Every entry point's first command against a node is now
  `capabilities … --load`, which loads Insider into a node without it. In
  0.1.1, `usage-rules.md`, the host `AGENTS.md` snippet in Getting started,
  the agent guide and the `mix insider.live` moduledoc started with
  `welcome`, which returns `insider_missing` on such a node.
  The welcome's second quick-start step now names that command, and the
  observer's `--help` lists it first among the core commands.

## [0.1.1] - 2026-11-18

A patch release: the quick start works on an app without Phoenix.

### Fixed

- The quick start's `start --component logger --component telemetry` no
  longer fails on a node without Phoenix, Oban, Absinthe, Bandit, Cowboy or
  an Ecto repository, such as a new `mix new` app. In 0.1.0 it was refused
  with `invalid_options` for `telemetry_events`. Without `--telemetry-event`,
  a session now records the quiet default Telemetry events that exist on the
  node and lists the others in the start and amend results under
  `telemetry_skipped_defaults`, each with the reason `not_on_target`. When
  none exists, the session runs without the telemetry component and the
  result carries `telemetry_hint`. Telemetry alone with no default is still
  `invalid_options`, now with the same hint. An explicit event name whose
  atoms do not exist is still `unknown_telemetry_event`. The cheat sheet's
  first start command no longer needs the OpenTelemetry SDK. See
  `decisions/2026-11-17_live_start_skips_quiet_default_telemetry_events_the_node_lacks.md`.

- An amendment whose components leave `telemetry` out no longer fails on
  the session's kept `telemetry_events` or `telemetry_measurements`. They
  return to their defaults, as kept Poller and call-trace options already
  did. Given in the same amendment, they are still `invalid_options`.

- The Sentinel sandbox executor no longer refuses a valid provider or body
  allowlist with `invalid_sandbox_providers` when a module's first load is
  slow, as it can be on a busy node in interactive mode. The modules now
  load before the 500 ms identity deadline starts, so the deadline bounds
  only their identity callbacks.

### Changed

- The Lab README, the landing page of the Lab's hexdocs, is now a short
  page: what the Lab is, the Hex install, a five-command quick start,
  running from a checkout, and links to the reference on
  insider.hexdocs.pm. The details it alone held moved into `docs/`: the Lab
  Mix tasks' stdout and stderr and the escript's schedulers
  (`docs/lab-cli.md`), the Lab's authority boundary
  (`docs/architecture.md`), and where the oracle runner's bootstrap lives
  (`docs/lab-candidates-and-oracles.md`).

- The release workflow (`release.yml`) publishes when a push to `main`
  changes the version in both `mix.exs` files, not on a pushed tag. It
  publishes only the packages whose version Hex lacks, refuses a version
  that is not greater than the releases on Hex, publishes both packages
  from one commit, and waits for each staged release to be approved on
  hex.pm. A separate job, the only one that can write to the repository
  and one that runs no project code, then tags the published commit
  `vVERSION`. Re-running a failed run or `workflow_dispatch` finishes a
  failed or pending release. Hex staged-publishing approval replaces the
  `release` environment's required reviewers as the human gate.
  `docs/development.md` "Releasing" has the procedure.

## [0.1.0] - 2026-11-17

The first release on Hex.

### Added

- Hex packages. `insider` (the core) and `insider_lab` (the observer CLI,
  the Mix tasks and the escript) carry a description, the MIT license, and
  links to the source, this changelog and their hexdocs. Hexdocs source
  links point at the release tag. Install the CLI with
  `mix escript.install hex insider_lab`. The welcome quick start, its
  `tandem.escript` and `transports.observer` entries, and the observer's
  `--help` name that install next to the checkout route. In this
  repository the Lab still
  builds against the core by path. `INSIDER_LAB_HEX=1` builds its package,
  which depends on `insider` from Hex. The Lab package ships its own copy
  of the license and recon's BSD-3-Clause notice.

- A tag-triggered release workflow (`release.yml`) publishes both packages
  through a Hex workload identity, in a GitHub `release` environment with
  required reviewers, with no stored key. The first release is published
  by hand. `docs/development.md` "Releasing" has both procedures.

- Project license and community files: `LICENSE` (MIT),
  `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), `SECURITY.md`, and
  `CONTRIBUTING.md`, linked from the README "Community" section. `LICENSE`
  names its copyright holder. `SECURITY.md` responds on a best-effort basis
  with no fixed response times, and a 90-day default disclosure embargo.
  Conduct reports and private
  vulnerability reports go to the shared open-source mailbox,
  opensource@clarity.com. Contributions carry a Developer Certificate of
  Origin sign-off (`git commit -s`), and a pull request discloses AI
  assistance in the template's new "AI assistance" section. Bugs and
  proposals go to GitHub issues.

- Live pairing chart: a picture of the session for the programmer an
  agent pairs with. Observer `chart` writes one self-contained HTML file
  (inline SVG, no script, a CSP that allows none, every string escaped, mode
  0600) and prints its path: a headline (the most notable change and how
  long after the mark before it), requests, latency p50/p95, waits before
  the endpoint, errors by signature, the longest mailbox, memory and
  evictions on the local wall clock, marks as lines, the window since a mark
  shaded, the digest's anomalies as numbered markers, and the digest's lead
  lines. `--serve` serves it on 127.0.0.1 at a random token, refreshing every
  second (wrong Host 421, non-GET 405, no CORS), until `--for` (default 30m)
  or the session ends. It renews no lease, its first read included (the new
  read option `"renew" => false`), and reads the window again when the host
  narrows the profile. The page says what it could not read (past 20,000
  events, an early-stopped digest, evictions). An existing `--out` path, a
  symlink included, is refused. It reads with its own reader through the
  session's disclosure. The welcome's `pairing` recipe starts with it. The
  idea is credited to Orion (https://github.com/LivewareProblems/Orion),
  whose live latency chart inspired it. No Orion code is used.

- Live observer smoothness (observers rated Insider 5.0 useful but 3.5
  smooth, with 13 failing command lines across 6 runs). A read without `--session` reads
  the node's active session (`stop`, `amend` and `otlp-receive` still need
  it); `--reader` is accepted on `status`, `welcome`, `capabilities`,
  `handoff`, `renew` and `marks`; `--trace` is `--trace-id`; `help OPERATION`
  ignores appended target flags; a flag an operation does not take names the
  operations that do (`accepted_by`). Compact batches add `# lost:` (evicted
  events, why, and whether the first event shown is not the one after the
  cursor) and `# more:` (the bound that cut the read, the cursor to continue
  from, and its maximum); `trace` and `timeline` text say the same when cut,
  and every `Lost:` line says why events were evicted and what keeps them.

- Live repeated query shapes (two of three runs found the right spans and
  still blamed another repeated query). `trace` groups a
  request's Ecto queries by table and statement shape, never parameters,
  across the whole tree, with the caller (Ecto's repo stacktrace, else the
  parent span, else unknown, saying which) and the total time, and leads its
  text with them (`order_items × 25 from MyApp.Orders.fetch/2, 31 ms
  total`). The digest lists them per trace and adds an `n_plus_one`
  anomaly for one shape repeated 10 times or more in one request.

- Live Oban job events are readable (every run decoded Oban's args by
  hand). `oban.job.*` events carry `attributes.oban` (worker, queue,
  attempt, state, args keys) in every profile, and in the rich profile
  `payload.oban_args`, the args with Oban Pro's `term-` values decoded when
  read (`binary_to_term` with `:safe`, never a compressed term), masked and
  bounded; the emitting process does constant work. Trace, timeline, and
  compact lines show them; Oban job spans show the worker, queue, and
  attempt.

- Live pairing marks: an agent watching while a programmer acts in
  the app no longer guesses times or cursors. `mark` (`--label 'about to
  click Confirm'`, `--reader`) records the moment as the newest receipt, its
  time, label and reader, and a `live.mark` event; its reply's `next` is the
  command to read since it. `digest`, `trends` and `timeline` take `"since"`
  `"mark"` or `"mark:LABEL"`, and `events_since/3` the same as its cursor
  (observer `--since-mark [LABEL]`, in place of `--since` or `--cursor`): the
  digest's `Window:` line says `since mark 'LABEL' (HH:MM:SS UTC, N s ago)`,
  never counts marks, and says when nothing was recorded since the mark.
  `marks` (`--human`) lists them. Labels are one line, credential-masked in
  every profile (strict keeps marks), and cut to 120 bytes (a label, or a
  lookup label, past 1,024 input bytes or not valid UTF-8 is refused before
  any work); a session keeps
  its newest 256 marks through amendments and after a stop. An unknown label
  is the new error `mark_not_found`, which lists the newest labels. The
  welcome quick start and a `pairing` recipe say how.

- Live known-normal baseline (most of the digest's anomalies were known
  dev noise that hid the new one). `baseline --session S [--since latest-5m]` marks the
  current candidate anomalies normal for the session (kinds, hashed
  identities, and counts; never names or values); later digests and
  `status` fold each candidate against it before choosing the top one
  ("2 known-normal anomalies hidden (baseline set 14:02; --show-baseline)")
  and lead with what is new. One at 10x its rate (compared unrounded) comes
  back, saying so; a crash loop's reason is part of its identity.
  `--show` and `--clear` read and remove it; `digest --show-baseline`
  lists the hidden ones. Each anomaly has an `identity` and a `count`.

- Live digests leave an observer's own requests (`/tidewave`, Tidewave's
  MCP calls) out of the request waits and bursts, count them in
  `requests.observer`, and say so once.

- Compact GraphQL lines keep the decisive fields: an anonymous operation is
  named by its top-level fields, and the line adds `types=[…]` and, in the
  rich profile, `args=` (bounded, masked), `actor=`, `client=`, and the
  `trace` id, so `--format full | jq` is no longer needed for them.

- Live `changes`: who changed an in-memory value (a dev feature flag was
  flipped by another user's request, and its store kept only
  its current value). Start option `watch_writes` (`--watch-write
  MOD.FUN/ARITY`, with the calls component) traces a store's write
  functions within the call-trace bounds, recording each write's key (and,
  rich only, its value; strict copies only the key out of the caller).
  `changes --key K` names each write's writer from one request of its own
  process (its process, GraphQL operation, route, user agent, user id
  (rich), and trace), or says it is unattributed. A value under a
  credential-named key, or a secret-shaped value, is recorded as
  `[masked: N bytes]`. The digest's anomalies add `value_changes`, a key
  written more than once and by whom ("at least N" when writes were evicted
  or not examined).

- Live kept mutation records. A session with the telemetry component keeps
  a compact record of each GraphQL mutation (operation, result, error
  counts, trace, process, time) in a ring of 4,096 apart from the Recorder,
  so a flood cannot evict what a mutation did; `status` counts each loss
  (`dropped`, `missed_receipts`), kept records pass the reader's view, and
  `trace` names the kept mutations it does not show, and whether their
  events were evicted.

- Live kept mutation records name the client and the response types, and
  list by record id. A rich session's
  `absinthe.execute.operation.stop` carries `graphql.client` (the request's
  user agent and remote address, remembered from Phoenix's endpoint start);
  each kept record adds `user_agent`, `typenames` (a `ValidationError`
  inside a 200 reads `result=ok types=[ValidationError]`), and `ids` from
  its arguments; `mutations [--id ID] [--human]` lists them.

- Live keeps the traces of mutation requests by default:
  with the telemetry component, the trace of a request that ran a GraphQL
  mutation is retained without `--retain-traces` (at most 16, with a
  1,024-event lookback for its earlier events; losses counted as `lost`
  and `evicted_traces`). The default never costs what `--retain` and
  `--retain-traces` keep: past the bounds mutation traces go first, and a
  trace the automatic pool lets go keeps its events in the lookback.

- Live `trace --values` shows a mutation's inputs (rich only): the current
  mutation's converted arguments by schema name, credential-masked and
  bounded as the response values, under `arguments.`, selectable with
  `--values-path`.

- Live digest and status lead with anomalies. The digest's
  `anomalies` rank request bursts, pre-handler waits from 1 s, error spikes,
  restart loops, mailbox or run-queue pressure, and evictions, one line each
  with the next command, and `--human` prints them right after the first
  line. A burst in a window with evictions says other bursts may be missing,
  and an evicted window says a burst among the lost events is not counted.
  `status` adds the last minute's anomalies without renewing the lease. A
  read that sets or clears a reader's stored view says so (`view_note`,
  compact `# note:`), and a `--human` digest through a stored view that hid
  events says so on its second line with `--view-clear`. Before this, a
  burst line was read about 10 minutes late, and a sticky view hid 1,266
  events. The digest's text no longer has separate `Pre-handler waits:` and
  `Request burst:` lines; the anomalies replace them.

- Live request waits and bursts. Each request's wait before
  Phoenix's endpoint telemetry began (in dev the code reloader and the plugs
  before `Plug.Telemetry`) is paired from `bandit.request.stop` (or
  `cowboy.request.stop`, both new quiet defaults) and `phoenix.endpoint.stop`:
  the digest's `Pre-handler waits:` line names the slowest, and trace and
  timeline add a `Wait:` line. The digest's `Request burst:` line flags
  arrivals far over the usual rate with their top sources (user agent or
  address in the rich profile) and the requests they overlapped. New welcome
  recipe "app hangs", which says Insider's inspection works over
  distribution while the request path is stalled. Before this, hangs took
  11.6 minutes to place and nobody linked them to another client's bursts.

- Live per-trace retention. `trace --retain` pins a trace: its
  events the Recorder still holds and every later one are kept apart from
  the Recorder and survive its eviction. `--retain-traces N` (start or
  amend) keeps the N most recently active traces. Bounded (8 pins, 4,096
  events, 4 MiB) with every loss counted; `trace` reports `retention`
  (kept, restored, lost, missed) in its result and a `Retained:` line, and
  the first read of an evicted, unkept trace says how to pin one. Before
  this, a trace came back empty after 35,263 evictions.
- Live `trace --values` (rich profile only; strict refuses with
  `disclosure_denied`): the trace's GraphQL response data as credential-masked,
  bounded `path = value` fields, narrowed with `--values-path`. The rich
  `absinthe.execute.operation.stop` payload records the response `data`
  (`graphql_data`) instead of a rendering of the blueprint. Diagnosing an
  API contract mismatch needed the numbers.

- Live GraphQL outcome on spans and Telemetry events. A GraphQL
  error inside an HTTP 200 was invisible. Absinthe's
  `absinthe.execute.operation.stop` (now a quiet default when Absinthe is
  loaded, recorded at any duration) and the operation's span carry
  `attributes.graphql`: operation name and type, `result` (`ok`,
  `user_errors`, `partial`, `errors`), error count, codes and paths, and a
  payload's validation error count, fields and types; never messages or
  values, and only the type, result and counts under the strict profile.
  GraphQL errors are severity `error` and payload validation errors
  `warning`; the digest's `error_signatures`, the trace text, and compact
  lines show both. New welcome recipe "GraphQL error in a 200".
- Live `trace --human` prints the span tree as text: each span
  under its parent with its duration, status and GraphQL outcome, and the
  events joined to it. `"collapse"` (`--collapse sql,auth`) folds each run
  of matching siblings into one counted line and `"hide"` (`--hide`) drops
  matching spans and events; both take `sql`, `auth`, or a name prefix, and
  `omitted` counts them, so an 844-span trace reads in a screen. The
  observer's `trace --human` and `timeline --human` print the text alone,
  not the JSON around it.
- Live compact otel lines show the span's name, kind, duration, status,
  GraphQL outcome, and trace id; they showed only `otel.span
  info PID`. The digest's new `shared_readers` hint says, when sources
  evicted while two or more readers share the session, that they share one
  Recorder and how to keep it (digest and trends, summaries, views, reading
  often); the welcome's lost-events and several-agents recipes say the same.

- Every Live read takes a reader, and each reader has its own view.
  `digest`, `trends`, `trace`, and `timeline` accept
  `"reader"` (`--reader NAME`) like `events` and `watch`, and list the
  reader in `status`. A view given with a reader becomes that reader's own
  view for its later reads (`--view-clear` clears it); `status.readers[]`
  shows it. New view keys: `exclude_signatures` (`--view-exclude-signature`:
  a digest signature id, a supervisor `reason_fingerprint` prefix, or a
  module name, such as an environment's known JWKS crash loop), and
  `services`, `routes`, and `traces` (`--view-service`, `--view-route`,
  `--view-trace`), which keep whole traces across services, resolved from
  the services and routes of the newest 4,096 ingested traces. Digest error
  signatures carry an `id`. Results say which reader and view they were
  read through and what the view hid (`filtered.view.exclude_signatures`,
  `filtered.view.scope`, `filtered_view`). Views never change what is
  recorded.
- Live digest covers the last minute by default. `"since"`
  takes `"latest-DURATION"` (whole `ms`, `s`, `m`, or `h`, 1 s to 24 h) and
  defaults to `"latest-60s"`: the window starts at the first event the
  Recorder admitted that recently. Admission times follow receipt order
  (an event's own `wall_time` may not: a Logger call can pass its own
  time), so the start is found by a binary search of owner probes that
  read past withheld receipts and neither renew the lease nor keep a
  cursor baseline. A probe that cannot decide is taken as recent, so the
  window may start early (`start_exact` `false`) but never drops a recent
  event; a search the budget cannot finish is a `timeout`. A digest
  without `--since` no longer reads a long session from its start and,
  out of budget, reports minutes-old history. `trends` keeps its
  session-start default and accepts the same values. The digest `window`
  carries `since`, `from_wall_time`, `start_exact`, `as_of`, and `age_ms`;
  the human text adds a `Window:` line (what was asked for, its start, end,
  and the newest event's age) and a staleness line for an old window not
  limited in time; each hint carries the `window` it was worked out over,
  and its `Next (receipts A-B, the last 60 s):` line says so.

- Live welcome names the tools that pair well with Insider.
  Both welcome forms carry `pairs_with`: Credo, Argus, recon, Tidewave, and
  observer_cli (for humans, not agents), each with when to use it, how to
  tell it is there, and how to run it; `runtime.pairs_with_available`
  reports which the node has: an already-loaded module (including one
  `--load` pushed, which is not on the code path), a beam on the code path,
  or an executable on PATH; detection loads and runs nothing. `mix insider.live --help` and the agent guide
  list the same tools.

- Live next-command hints. The digest's `"hints"`
  (and one `Next:` line each in `--human`) give the exact command to run
  next, with its reason and counts, as observer `command` and as `amend/2`
  `options`: for a crash loop or repeated exception, `trace_calls`, the
  `amend --component calls --calls MOD.FUN/ARITY --calls-results exceptions`
  that records the failing call, with the function taken from the crash's
  stack (`call_candidates`) or the crashing child's GenServer callbacks and
  the session's components kept, or, before OTP 28,
  `trace_calls_unavailable` with the `:recon_trace.calls/2` call to run by
  hand; and for each source the Recorder evicted over its share, the
  amendment that stops it (`reduce_logger` with `--logger-summary`,
  `reduce_telemetry` with `--telemetry-summary`, `reduce_poller`, and
  `raise_capacity`) with the per-source counts from `recorder.sources`. An
  events batch that shows a crash or exception carries the same call-trace
  hint, and `--format compact` prints it as a `# hint:` line. The welcome's
  crash-loop recipe leads with the call trace, and a new "lost events"
  recipe covers evictions. Only Logger messages are suggested for a
  summary: a flood of reports (never summarised) gets a `logger_reports`
  hint without a command. Functions are compared as `--calls` resolves
  them, so an `Elixir.`-prefixed or quoted-atom spelling never yields a
  duplicate the session refuses.
- Live digest separates Insider's own footprint. `vm.target`
  holds the node's processes, process memory, and ETS without Insider's
  own, and `--human` prints them that way, with Insider's own beside them
  and the port count, instead of attributing the Recorder's table to the
  application.
- Live trends of Poller evidence and compact Poller lines.
  `trends` adds `"poller"`: per-sample series of `binary_bytes` and
  `port_count` (`vm_sample`), ports per type (`port_top`), and mailbox
  length per ranked or watched process (`process_top`, `process_watch`),
  each with its unit, first-to-last change and direction, growth per
  minute (`per_min`), maximum, and points; `--kind vm_sample|port_top|
  process_top|process_watch` narrows to them. `--format compact` now
  prints `ets_top`, `port_top`, `process_top`, `process_sample`,
  `process_watch` and `poll_cycle` content (rankings as `name:value`),
  where `ets_top` and `port_top` printed only `-`, and `vm_sample` adds
  `port_count` and `binary_bytes`. New welcome recipe "growth over time".

- Live summary exemplars, trend windows and Logger bursts. Each Telemetry
  summary names up to three of its interval's slowest events and its first
  error as `"exemplars"` (receipt, roles, `duration_us`, error), recorded
  in full just before it, so `events --cursor RECEIPT-1 --limit 1` opens
  the actual event; candidates come from the values of the emitting
  process's one counter update (at most 4 per histogram bucket). The
  interval's first error takes a reserved path, not the shared inbox, so
  it is kept whenever it reaches the collector. Summaries carry
  `"window_started_at"`, `"window_ended_at"`, `"exemplars_lost"` (the
  interval's candidates lost: inbox full, normalisation failed, recorder
  refused, or receipt unknown), `"first_error_retained"`, and
  `"duration_scope"`: `"measured_in"` is `"handler"` or `"caller"` only when
  the session declares it with the new start option
  `"telemetry_duration_scopes"` (`--telemetry-duration-scope
  KIND=handler|caller`), else `"unknown"`; `"emitter"` only reports whether
  the exemplars were emitted inside an OTP server (and which module) or a
  plain process, never what the duration measured. New operation
  `trends/2` (observer `trends`, `insider.live-trends/v1`) lists each
  series' windows in fixed units (`rate_per_min`, `p95_us`, `error_pct`)
  with the first-to-last change and each window's exemplar losses; a
  declared handler series next to a declared caller series gets a
  conditional note, never a queueing conclusion. The digest adds
  `"trends"`, `"logger_bursts"`, and exemplar receipts and losses in its
  latency rows and text. New start options `"logger_summaries"`
  (`--logger-summary RULE`) and `"logger_summary_interval_ms"` count
  matching Logger messages per normalised message template, call site and
  level instead of recording each: one `logger_summary` event per burst per
  interval, its first message recorded as the exemplar
  (`"exemplar_lost"` when it was not); `filtered.logger.summarized` counts
  them. At most 64 bursts are told apart per interval; the rest fold into
  one overflow row per level (`"overflow"`, `"distinct_lost"`). Lost
  exemplars and folded distinctions are read gaps `telemetry_exemplar_lost`,
  `logger_exemplar_lost`, and `logger_summary_overflow`. Strict disclosure
  withholds burst templates and call sites (their fingerprints are kept),
  the emitting module, and summary and exemplar durations without an
  allowed measurement, one drop record per value (exemplar durations at
  `index:N`).

  Security: a burst template is credential-masked before it is normalised,
  in every profile, and that masked template is what is grouped,
  fingerprinted, stored and exported (the mask is reported at
  `attributes.summary.template`). Normalising first could change a secret's
  shape, such as a high-entropy token's only digit becoming `N`, so that
  the export mask no longer recognised it and the template disclosed what
  the exemplar withheld. A token cut by the 160-byte template bound is
  dropped, and a masking failure yields a redaction marker.
- Live one-shot inspections, after recon: `Insider.Live.process/1`
  (observer `process --name NAME | --pid PID`) returns a `process_info`
  subset, the current stacktrace's top frames, link and monitor counts,
  binary count and bytes, and a mailbox summary by message shape and size
  class with the first shapes and the queued `GenServer.call`s whose callers
  exited, never a message value or `sys:get_state` (a shape shows an atom
  only as a tuple's tag, in every profile); `bin_leak/1` collects every
  unprotected process and ranks what each still references
  (`by_retained_bytes`) and what was freed (`by_freed_bytes`); `ports/1`
  counts ports by type and lists those of a `--type` or `--owner` with owner
  and OS pid, from one read of at most 50,000 ports, and in the rich profile
  each command line, masked structurally: split once at the first
  whitespace or control character, everything after the program is masked
  when the command names a credential anywhere or holds anything a shell
  may rewrite (an escape, a control character, `$`, a backtick), and the
  whole command when the program itself is in doubt; `alloc/1`
  reports allocators through `recon_alloc` (`component_unavailable` without
  recon). Each is bounded (3 s deadline, heap guard, two at once; the
  exported result, masks and session status included, at most 64 KiB, its
  lists cut and counted in `omitted`), passes the disclosure profile and
  credential masking, and is recorded in a running session as an
  `inspect.*` event (new view source `inspect`) through the new
  `Insider.Collector.Session.record_event/3`. New errors
  `process_not_found` and `protected_process`; `alloc/1` without recon returns
  the existing `component_unavailable`.
  Only `alloc` uses recon (BSD-3-Clause), when the node has it; the
  observer's `--load` pushes it. The welcome adds the operations,
  binary-leak and port-leak recipes, and a `process` step in the
  growing-mailbox recipe.
- Poller port census `port_top` (`"top_ports"`, observer `--top-ports`,
  default 5 with the poller): ports by type (the program's name, `other`
  when the program names a credential or holds an escape, a control
  character, `$`, or a backtick) with OS-process counts and each
  type's growth since the previous census, the owners holding the most,
  `port_count_delta` over the poll window, and Insider's own ports apart.
- Live call traces. The new `"calls"` component (observer `--component calls
  --calls MOD.FUN/ARITY`, repeatable) traces calls to loaded functions, like
  `recon_trace`, but owned by the session rather than the caller: it is
  removed at stop, lease expiry, and amend, and the cleanup receipt's
  `cleanup.call_trace` shows `traced_after` `0`, checked against the
  runtime's trace-session inventory. Each call is a `call` event and, with
  `"calls_results"` (`exceptions` by default, `all`, `none`), each failure a
  `call.exception` (severity error: `call_id`, `duration_us`, `class`, and
  the `exception` module such as `ArithmeticError`) and each return a
  `call.return`, paired with its call. In the rich profile the arguments,
  result, and reason are rendered with credentials masked and capped at
  `"calls_max_bytes"` (default 1,024); the strict profile collects none.
  `"calls_max"` (default 100) stops new calls while still recording running
  calls' results; more than `"calls_rate_max"` messages per `"calls_rate_ms"`
  stop the trace; each stop is a `call.stopped` event and later messages the
  `calls_shed` gap. It uses an isolated OTP 28+ trace session and never
  touches another tool's tracing; on OTP 27 it is refused with the new
  `component_unavailable` error. Unknown, unloaded, preloaded, or Insider
  functions are the new `untraceable_function` error. The digest gains
  `calls` (per function counts, durations, and failures with the arguments
  of the first), error signatures name the traced function, the compact
  format prints call events, and the welcome gains a "failing call" recipe.
  An amendment whose components leave `"calls"` out now drops its options.
  Ingress has a documented soft byte bound (development and test only):
  strict call messages carry only the arity; an inlet measures every trace
  message, charging a top-level sub-binary the binary it keeps alive, and
  stops the trace when more than 8 MiB wait for the collector
  (`ingress_bytes`); a 64 MiB heap limit is the last resort. The inlet's
  own mailbox and nested sub-binaries are not bounded; README "Call traces"
  gives measured worst cases. Flush and stop drain through the inlet, and
  what a stop could not drain, including a message the inlet held
  mid-admission, is the `calls_undrained` gap (`calls_undrained_unknown`
  when that count is only a lower bound). A call shed after
  `"calls_max"` keeps its place in pairing, and pairing that can no longer
  be exact stops the trace (`pairing_limit`, `pairing_lost`).

- Live process and ETS evidence. With the `"poller"` component each poller
  interval (new `"poller_interval_ms"`, default 5 s) records `process_top`:
  the top `"top_processes"` (default 5) processes by `message_queue_len`, by
  `memory`, and by `reductions_delta` since the previous scan (recon's
  `proc_count` and `proc_window`, with the poll interval as the window), each
  named by registered name, `$initial_call`, and current function; and
  `ets_top`: the top `"top_ets_tables"` (default 5) tables by memory and by
  size with their owner. `"watch_processes"` (observer `--watch-process
  NAME`, repeatable) records a `process_watch` sample of each named process
  every interval, following restarts; an unknown name is the new
  `unknown_process_name` error. Scans read only scalar `process_info/2`
  items, the group leader, and the `$initial_call` dictionary key, never
  messages or ETS objects, and skip protected processes. Insider's own
  processes and tables are never ranked: they are summed under
  `metrics.insider` and copied into `vm_sample` as `insider_process_count`,
  `insider_processes_bytes`, `insider_ets_tables`, and `insider_ets_bytes`,
  so the Recorder's growing buffer no longer looks like an application ETS
  leak. Every poller event now carries `wall_time`. The welcome's growing
  mailbox recipe replaces its placeholder, and a memory growth recipe is
  new. The core `Insider.Collector.Poller` takes the scans and watches only
  when configured (`top_processes`, `top_ets_tables`, `watch_names`). Host
  protection takes precedence over Insider's own exemption, and an
  incomplete process footprint (scan limit, or a skipped host-protected
  process that is or may be Insider's) is reported unavailable in
  `vm_sample`, never as a total.
- Live Telemetry discovery. `Insider.Live.discover/1` (JSON twin and
  `mix insider.live discover [--prefix a.b]`) returns
  `insider.live-telemetry-discovery/v1`: the event names with an attached
  handler and the literal event lists in `:telemetry.execute/2,3` and
  `:telemetry.span/3` calls (spans expanded to `start`, `stop`,
  `exception`) of loaded application modules, each with its sources and
  module. It reads import tables and debug info only, never calls a
  debug-info backend or application code, skips files that no longer hold
  the loaded code, and is bounded (2 s deadline in a heap-guarded worker,
  20,000 modules, 4,096 names, 2 MiB of debug info and 2,000,000 walked
  nodes per module in its own reader, 8 sources per name, 512 returned,
  two at once) with `truncated_by` naming every bound that dropped
  evidence (`deadline`, `modules`, `names`, `too_large`, `walk`, `sources`,
  `events`). Release layouts are scanned: only the OTP and Elixir
  applications' own `ebin` directories are skipped. A malformed
  `"telemetry_events"` is `invalid_options` before any scan. A
  `"telemetry_events"` entry ending in `"*"`
  (`--telemetry-event 'shop.*'`) subscribes to every discovered name below
  the prefix, within the 64-event bound, and the start result lists the
  expansion under `telemetry_event_prefixes`. `status/1` reports
  `telemetry_subscriptions` (each event's `state`, `subscribed` or
  `detached`, and `seen`), so an accepted name that was never emitted reads
  `subscribed`, `seen` 0. The welcome's unknown-event-names recipe now uses
  them. A recorded Telemetry event costs one more counter increment in the
  emitting process (its seen count).
- Live digest and compact output. `Insider.Live.digest/2` (JSON
  twin and the observer's `digest --session S [--since N|latest-N]
  [--human]`) summarises a window of the session in one call:
  `insider.live-digest/v1` with counts by kind, severity, source, and
  supervisor offender, crash loops with their period and reason
  fingerprint, the top error signatures (kind, offender, exception module,
  normalised message head; HTML pages named, never quoted), latency tables
  from summaries and recorded durations, the longest mailboxes, VM deltas,
  and the window's `filtered` and `gaps`. The window is fixed when the
  digest starts (`upto`, the newest receipt then; later arrivals are left for
  the next digest), and one 3,000 ms budget (`bounds.digest_budget_ms`)
  covers the `latest-N` lookup and every read. `--human` prints a few
  plain-text lines for the developer; it calls a p95 near 5 s "consistent
  with GenServer.call timeouts" only when a disclosed failure carries that
  exit (`call_timeouts`, `logged_call_timeouts`). See the decision record
  `2026-10-22_live_digest_reads_a_fixed_window_…`. The observer's `events`
  and `watch` take `--format compact`:
  one line per event (receipt, wall time, source, kind, severity, subject,
  key attributes; of a rendered conn only method, path, route and status)
  and a `#` line per batch with the cursors, disclosure profile, gaps, and
  filtered counts.
- Bounded live reads. `events_since/3` takes `"upto"`, the newest receipt a
  read may return (from its starting cursor, after `"latest"` resolves, to
  the newest receipt; otherwise `invalid_options` with field `"upto"`). The
  read stops there and counts its receipt-range losses only up to it, from
  the receipts themselves, and is complete (`truncated_by` `nil`) when it
  reaches it. The digest reads its window this way, so its losses are exact
  whatever order the Recorder evicts in: a later eviction is no longer
  counted in the window and a withheld receipt in it is no longer hidden.
- Live time and units. Telemetry events carry `wall_time`, read in the
  emitting process (a summary's is when it was recorded), and Poller samples
  the time they were taken. Every Telemetry time measurement a read
  discloses as an integer is repeated in microseconds under
  `attributes.durations_us`. The full welcome reference gains `time`, which
  says what `wall_time` and `monotonic_time` mean per source and the unit of
  every duration.
- Several agents can share a live session. Reads and subscriptions take
  `"reader"` (observer `--reader NAME`), and `status/1` lists named readers
  with their cursor, lag, last read, and subscription. `stop/2` refuses with
  `readers_active` while another named reader is active, unless `"force"`
  (`--force`). A stopped session stays readable for 120 s, so peers can
  drain it. `amend/2` (`mix insider.live amend`) changes a running session's
  components, events, measurements, filters, and poller options without
  losing its history, cursors, readers, or subscribers, and readers see a
  `live.session_amended` event; a `"telemetry_events"` prefix such as
  `shop.*` is expanded as at start and listed under
  `telemetry_event_prefixes`. An option given as `nil` (observer
  `--reset FLAG`) returns to its default, and kept poller options return to
  theirs when the amended components leave the poller out (a components
  reset included).
  `handoff_record/1` (`mix insider.live handoff`) returns what another agent needs
  to continue the session, its poller configuration included. Every
  configuration says that recording options apply to every reader, while
  views are per reader (`"scope"`). The welcome adds a `tandem` section and
  the "missing values" and "several agents" recipes. New error codes:
  `readers_active` and `amend_failed`.
- The Lab escript (`mix escript.build`, then `./insider-lab live …`) is the
  documented observer for concurrent agents, because it never waits on
  Mix's build lock. Observer documents report
  `installation.insider_commit`, so an agent can tell when to rebuild a
  stale escript.
- `mix insider.live reports submit --dry-run` always previews, overriding
  `--confirm` and every host opt-in. The result's `authorization` names the
  effective opt-in and what was overridden, and a real submission writes it
  to standard error before its first `gh` call. `reports` and
  `reports submit` select by `--fingerprint` (repeatable) or `--session`;
  `report --session` cites a session, and otherwise a report cites the
  session of the last target command (new report context key `session`;
  older records are read with it as `nil`). `reports` groups the shared
  queue by node and session, from each report's `occurrences`, so the same
  report filed in two sessions stays selectable by each. `--session` accepts an ASCII identifier
  and refuses anything else as `invalid_options`.
- The welcome (quick start and full) states `effective_disclosure`: the
  node's current profile, its source, and what it lets leave the node.
- Frontend traces in a live session. The Lab's
  `mix insider.live otlp-receive --session ID` is a loopback-only OTLP/HTTP
  trace receiver (protobuf or JSON, gzip, at most 4 MiB, default
  `127.0.0.1:4318`, `--port`, `--bind`, `--for`) that forwards each span to
  the new `Insider.Live.ingest_spans/2` (and JSON twin), which records it as
  an `otel.span` event under the session's span contract, disclosure
  profile, and credential masking, with `service` from the exporter's
  resource. It prints one NDJSON line per export with its counts and trace
  ids, renews the lease, and stops on SIGTERM, `--for`, or the end of the
  session. New observer codes `non_loopback_bind` and `port_unavailable`;
  welcome recipe "follow a frontend action". Ingest runs in the live owner,
  ordered with start and stop, so spans never reach a later session; export
  lines carry only counts and trace ids; the receiver accepts the next
  connection only after its previous report was written. A `timeout` from
  `ingest_spans` means the outcome is unknown; ingest is idempotent per
  `{trace_id, span_id}` while the id is among the session's last 16,384
  ingested ids (`duplicate` and `seen_evicted` counted), the receiver
  retries a timed-out chunk once and then answers `503 target_timeout`, a
  `busy` ingest (the owner's admission full) is answered `503 target_busy`
  and the receiver keeps receiving, every amendment (even one rolled back)
  resets dedupe without counting it as `seen_evicted`, and
  a busy or timed-out lease renewal is retried once after a jittered backoff,
  the delay capped to leave 250 ms before the lease's estimated end.
  Decision records
  `2026-10-22_otlp_ingress_is_a_loopback_lab_receiver_that_only_the_target_masks`,
  `2026-10-22_otlp_ingest_timeout_is_outcome_unknown_with_bounded_dedupe`, and
  `2026-10-22_otlp_receiver_renewal_retry_is_capped_by_the_lease`.

- Live OpenTelemetry spans and traces. The new `"otel"`
  component records every span the node's OpenTelemetry SDK ends as an
  `otel.span` event, by tracing the SDK's span end in an isolated trace
  session (OTP 28+; on OTP 27 `start/1` returns `component_unavailable`
  with reason `requires_otp_28`), without adding or changing any
  processor, exporter, tracer, or sampler; `traces_exporter: :none` still
  exports nothing. Throttled rather than admission-controlled (trace
  messages cannot be refused by their receiver): a valve pauses the trace
  above 1,024 waiting spans; every read overlapping a pause reports
  `otel_paused`, or `otel_paused_ongoing` while it lasts, with an unknown
  count, and spans received above that are shed before being built. The
  bound is soft and the component is for development and test only. Also
  `otel_shed`/`otel_invalid` gaps, origin and `"otel_min_duration_ms"`
  filters counted under `filtered.otel`, rich-only span attributes and
  status messages, and clean removal on stop. `Insider.Collector.Otel.ingest/1`
  records span maps from outside the node. `Insider.Live.trace/3` returns
  one trace's span tree merged in time order with the Logger and Telemetry
  events of the same trace (or of a span's process inside its window), and
  `Insider.Live.timeline/2` one process's or request's events across every
  source; both report what they could not join and are bounded (JSON
  twins and observer `trace`/`timeline` commands). Logger and Telemetry
  events take the SDK's `otel_trace_id`/`otel_span_id` as causality, Logger
  subjects name their node, and Telemetry events carry their emission
  wall time. New error code `component_unavailable`. The `oban` origin now
  covers oban_pro, oban_met, and oban_web processes. Welcome: trace and
  timeline operations, the 5xx recipe reads the failing request's trace,
  and a new slow-request recipe. A stop or amendment seals the otel
  capture with the other ingress components before its last copy, and the
  otel losses (`otel_invalid`, `otel_shed`, pauses) carry through
  amendments and the drain window; a pause ongoing at a seal ends with that
  capture, and the paused state is never summed across segments, so a
  later segment's pause is `otel_paused_ongoing` on every read while it
  lasts; `amend` takes `--otel-min-duration-ms`
  and `--reset otel-min-duration-ms`.

- Live welcome agent quick start. `Insider.Live.welcome/1` (and the
  observer's `welcome`) now returns `insider.live-welcome-quick-start/v1`
  by default, about twenty lines: numbered steps,
  the five core observer commands with real flags, the first-contact
  `--load` command, "measurements are opt-in" (in the strict profile; rich
  returns every measurement unless some are selected), and how to stop, plus
  symptom recipes (latency, crash loop, 5xx, and placeholders for a
  growing mailbox and unknown event names).
  `welcome(%{"full" => true})` and `mix insider.live welcome --full` return
  the full reference, now `insider.live-welcome/v2` because the default no
  longer returns it; it also lists every observer flag's value
  syntax (such as `module:NAME`) and the observer's error codes with their
  exit statuses. `capabilities/0` reports `quiet_default_telemetry_events`.
- `mix insider.live --help`, `help OPERATION`, and `OPERATION --help` print
  usage text with each flag's value syntax and examples and exit 0, without
  a target.
- Live reading scales to sparse views and late joiners. `events_since/3`
  accepts cursor `"latest"` (the observer's `--cursor latest`), an empty
  batch at the newest receipt from which to tail, and a `"scan_limit"`
  read option (1 to 1,000, default 1,000; `--scan-limit`) that bounds the
  retained events a read examines. Every batch reports `"truncated_by"`
  (`limit`, `max_bytes`, `scan_limit`, `deadline`, or `nil`). `status/1`
  reports `"next_receipt"` and the Recorder's fill (`"recorder"`:
  `oldest_receipt`, `retained_events`, `retained_bytes`, `max_events`,
  `max_bytes`), and `invalid_cursor` names `oldest_receipt` and
  `next_receipt`. `subscribe/3` takes `"cursor"` (an integer or `"latest"`)
  and `"max_events"`, a total event budget the owner enforces. The
  observer's `watch` gains `--from-cursor N|latest`, `--for DURATION`, and
  `--max-events`; its `stopped` line reports `events` and the
  `next_cursor` to resume from.

- Live sessions are quiet by default and filter in the node before
  recording. Without options a session records Logger events at `warning`
  or more severe, OTP crash, supervisor, and SASL reports, each Ecto
  repository's queries over 100 ms (discovered from `:ecto_repos`), every
  Phoenix request, and every error, and nothing Oban's own machinery emits.
  Record-time filters (`logger_level`, `logger_include`, `logger_exclude`,
  `exclude_origins`, `telemetry_min_duration_ms`,
  `telemetry_event_min_duration_ms`) run in the emitting process through a
  gate kept in `:persistent_term`; a dropped event costs one decision and
  one counter increment. `telemetry_summaries` folds a high-volume event
  into one summary event per interval with count, errors, and latency
  p50/p95/max. `events_since/3` and the new `subscribe/3` take a per-reader
  `"view"` over the same recorded stream, and every batch reports
  `"filtered"` counts per filter, record-time since the cursor and
  read-time for the view, so silence is never ambiguous. The observer gains
  `--logger-level`, `--logger-include`, `--logger-exclude`,
  `--exclude-origin`, `--telemetry-min-duration-ms`,
  `--telemetry-event-min-duration`, `--telemetry-summary`,
  `--telemetry-summary-interval-ms`, and `--view-*` flags.

- Live record-time gates have a supervised cleanup owner,
  `Insider.Live.Gates`, started before the live owner. It erases a gate
  when its session ends, its owner dies, or its start is interrupted, and
  holds at most 8 (`start/1` then returns `busy`). Gate creation is bounded
  to 500 ms: `start/1` returns `timeout` when the keeper is late (the
  creation is aborted) and `unavailable` when it is down; the start reserve
  is 3,500 ms (including 200 ms for the disclosure profile's Ecto
  redact-field collection). Summary tables pass to the live owner if the
  keeper dies, so
  summaries survive a keeper restart; a summary sample that cannot be
  stored is reported as the gap `telemetry_summary_lost`, never as
  `summarized`. In the strict profile a summary's duration statistics follow the
  host measurement allowlist (rich summaries carry them unchecked), a sample's fields always land in one interval, and a stopped
  or expired session's terminal batch carries its pending summary.

- Live disclosure profiles, chosen by the host with
  `config :insider, :live_disclosure`: `rich` (the default in development and
  test) returns Logger message text and metadata, Telemetry metadata such as a
  repo query's `source` and `query`, and all measurements, rendered by
  `Insider.Collector.Rich` within fixed size, width, depth, node, and time
  bounds and without calling application code (no `report_cb`, no struct
  `Inspect` implementations); `strict` (the default in ci; environments where
  live observation is denied report only strict) is the previous boundary.
  `start/1` accepts `"disclosure"` to narrow a
  session, and a richer request is the new `disclosure_denied` error.
  `capabilities/0` reports `disclosure_profile`, `disclosure_profile_source`,
  `disclosure_profiles`, and `masking_policy_id`; session start and status
  report the effective profile and the masking policy id. The Lab observer's
  `start` accepts `--disclosure`. The Logger and Telemetry collectors accept
  `rich: true`.
- `Insider.Redaction.Credentials` (`insider-credential-masking/v1`) masks
  values under credential-named keys and secret-shaped strings (HTTP `Bearer`
  and `Basic` credentials, JWTs, PEM blocks, provider key formats such as
  `sk_live_…`, URL passwords, credential assignments, and high-entropy tokens)
  at every nesting level of every live event in every profile, and leaves a
  `mask` redaction record with its reason for each.
- Live observation of a running node, with or without Phoenix:
  `Insider.Live` (`capabilities/0`, `start/1`, `events_since/3`, `renew/1`,
  `status/1`, `stop/1`, `subscribe/2`, `unsubscribe/2`) and
  `Insider.Live.JSON`, which returns each result as one canonical JSON
  document for Tidewave `project_eval`. Arguments and results are plain,
  distribution-safe terms for a later Erlang-distribution observer node. A
  supervised, named `Insider.Live.Owner`, started under `Insider.Supervisor`
  only when the node resolves to development, test, or ci from
  `config :insider, :environment` or its Mix environment, owns the one
  collector session, so the caller can exit. A renewable lease (default 2
  minutes) stops an abandoned session through the normal cleanup path and
  leaves a receipt that `status/1` reports. Reads return redacted events after
  a recorder cursor, without a freeze, with exact eviction and withheld counts
  and counter-delta gaps for admission and ingress losses under a closed reason
  vocabulary; errors use a closed `code` vocabulary. Subscribers are monitored,
  bounded, and receive a terminal batch with the receipt. In the strict
  disclosure profile, Logger message content, report fields, and metadata are
  never collected, and every event crosses a fixed live disclosure boundary:
  only W3C-shaped `trace_id` and
  `span_id` causality survive, binary supervisor ids are digested, and
  Telemetry measurements are numeric values from a host allowlist
  (`config :insider, :live_telemetry_measurements`). Calls take one of
  16 owner admission slots (`busy` otherwise) and carry an absolute deadline;
  a request handled too late is refused before any side effect. The
  environment is checked on every observation: if it stops being allowed, the
  active session is stopped as `revoked`, retried on a timer if cleanup
  fails, and observation returns `environment_denied`.
- Lab observer node: `mix insider.live` and `insider-lab live` drive
  `Insider.Live` in another local BEAM node over Erlang distribution
  (`capabilities`, `start`, `events`, `status`, `renew`, `stop`, and a
  long-running NDJSON `watch` that renews the lease, unsubscribes on SIGTERM,
  and ends on target loss). Each command starts a hidden, non-listening
  observer node, refuses non-loopback hosts, reads the cookie only from an
  owner-only file, calls with `:erpc` under explicit timeouts, and prints
  canonical JSON with a closed error vocabulary on the existing Lab exit
  statuses. A target without Insider or with a different version is refused;
  `--load` pushes the observer's Insider (and missing `jason`/`telemetry`)
  with `:code.load_binary/3` and starts it, only on development, test, or ci
  targets.
- Live welcome document: `Insider.Live.welcome/0` and
  `Insider.Live.JSON.welcome/0` return `insider.live-welcome/v1`, generated
  from the code's own tables: every operation with its options, defaults, and
  bounds, the error codes, components, allowed measurement names, report
  categories, the disclosure profile, the observer and Tidewave transports
  with example invocations, the Insider version and compiled Git commit, a
  short agent guide (first steps, the act-then-read loop, stopping, and the
  duty to report), and the node's runtime facts. `hash` is the SHA-256 of
  everything except `hash` and `runtime`; `capabilities/0` carries it under
  `welcome`. Drift-guard tests compare the document with the exported
  functions, option behaviour, the error codes the source can return, and the
  observer's command table. `mix insider.live welcome` prints it, and the
  first observer command against a target carries it under `"welcome"`
  (later ones a pointer).
- Agent reports about Insider itself: `Insider.Live.report/1`,
  `Insider.Live.reports/0`, their JSON twins, and `mix insider.live report
  --category C --message M`, with the closed categories `bug`,
  `doc_mismatch`, `missing_capability`, and `confusing_output`, a 2,048-byte
  message, and automatic context (version, commit, welcome hash, node,
  environment, last operation and error code; never payloads or option
  values). The node keeps a bounded, deduplicated in-memory queue
  (`Insider.Live.Reports`, started only where live observation is allowed,
  with the owner's admission slots and deadlines); the observer keeps the
  same rule in a JSONL queue under `INSIDER_LIVE_REPORTS_DIR`, validating
  every row on read and keeping the submission ledger to queued
  fingerprints. `mix insider.live reports` lists it, copying a target's queue
  with `--node`, and `reports submit` files GitHub issues on
  `hiivemarkets/insider` through `gh`, deduplicated by fingerprint, only with
  `--confirm` or `config :insider, :live_report_submission, :github` (a
  target's setting covers only that target's own reports); otherwise it
  prints what it would send. New observer error codes:
  `report_queue_unavailable` and `report_submit_failed`.
- `usage-rules.md` and `guides/agents/live-observation.md`, listed with
  `guides/` in the `mix.exs` package files so `mix usage_rules.sync` finds
  them, and a host `AGENTS.md` snippet in the README.
- `Insider.Recorder.read_since/3`, a cursor read of retained entries in
  receipt order that needs no freeze trigger, takes no admission lock, and
  reports the exact eviction count for the read range.
- `Insider.Collector.Session.read_events/3`, which drains the visible
  ingress inboxes and returns events redacted under the session's trusted
  classification policy, with Recorder and ingress loss counters.
- A Lab-only fault-and-rerun oracle for background workers,
  `tools/insider_lab/priv/probes/fault_rerun.exs`
  (`InsiderLab.FaultRerunOracle.run/1`), for agent-written probe tests. It
  stubs every exported arity of up to 16 declared provider functions through a
  caller-supplied installer, runs the worker once with no fault as a healthy
  control, then against a fresh fixture with a fault declared at one provider
  call (a returned error, a raise, or a lost response) and again as the retry,
  up to 8 attempts. It compares the distinct effect identities of each run
  with the provider ids a caller projection of committed rows returns,
  grouped by the boundary that creates them, so equal ids from two providers
  never match. The control must succeed, reach the fault position, and make
  exactly the expected, referenced effects, or the call is
  `infrastructure_failure`. Fault runs are `confirmed` (`orphaned_effect`,
  `repeated_effect`, `missing_effect`), `not_reproduced` (`converged_once`),
  or `not_observed` (`fault_not_reached`, `effect_outside_attempt` for a
  declared effect made after `perform` returned or outside the attempts,
  `retry_did_not_succeed`, an adapter failure, or an incomparable value). A
  declared arity list that does not match the exported
  arities is refused before any adapter runs. A boundary with an idempotency
  `key` replays the first response for a repeated key: a concurrent caller
  waits up to 2 s for the first caller's response, and responses are cached
  for at most 512 keys within a 1 MiB, 65,536-term budget and 8 MiB per
  scenario. A key that cannot be compared or replayed (including a responder
  re-entering its own key) is `key_not_comparable`, never a confirmed repeat.
  It prints one
  `insider.fault-rerun-oracle/v1` line per call with call counts per arity,
  result tags, exception modules, and per-call labels of HMAC-keyed effect and
  key fingerprints, never an argument, response, id, key, or reference value;
  at most 512 calls are recorded per scenario. See
  `decisions/2026-10-21_fault_rerun_oracle_owns_the_provider_recorder.md`.

- A Lab-only actor differential access-control oracle,
  `tools/insider_lab/priv/probes/actor_differential.exs`
  (`InsiderLab.ActorDifferentialOracle.run/1`), for agent-written probe tests.
  It runs one host operation as up to 16 declared actors, each against a
  fixture rebuilt by a caller-supplied function, and compares each outcome and
  an optional id-free state projection with the declared rule. Entitled
  controls must be granted and change the declared effect keys, and refusal
  controls must be refused without changing state; an unhealthy control or a
  malformed declaration is `infrastructure_failure` with no verdict. Compared
  actors are `confirmed` (`wrongly_granted`, `state_changed_while_refused`,
  `wrongly_refused`, `granted_without_effect`), `not_reproduced`, or
  `not_observed` (including a starting state that differs from the control's
  or cannot be compared). It prints one `insider.actor-differential-oracle/v1`
  line per call holding field paths and kinds, GraphQL type names, error
  codes, and per-call HMAC equality, never a response or state value. A value
  is fingerprinted only after a walk of at most 65,536 terms bounds its
  serialized size to 1 MiB, and an unfingerprinted value never compares
  equal. See
  `decisions/2026-10-21_actor_differential_oracle_is_a_probe_library.md`.

- `mix insider.oracle`, a Lab-only runner for the three fixed ExUnit oracles
  that never edits the target checkout. It starts `mix test` with `MIX_EXS`
  naming a fixed bootstrap that compiles the target's `mix.exs`, bypasses a
  declared host `test` alias, and prepends a run-local overlay to
  `:test_paths`, whose helper requires the host helpers and then the oracle;
  no host `run` alias is involved. An explicit
  `insider.oracle-host-profile/v1` file declares the `mix` command, alias
  handling, passthrough variable names, and database suffix; every other
  variable is removed from the child. The run directory must resolve, after
  symlinks, outside the target and its Git work tree. Each run writes a
  versioned `insider.oracle-run/v1` record (oracle id and SHA-256, inputs,
  exact command, target revision, fingerprint budget, and before/after content
  fingerprints with changed paths, profile fingerprint, timestamps, exit
  status, output policy, oracle report, cleanup verdict, completeness state,
  and outcome), output filtered by a fail-closed policy (`allowlisted`
  summaries by default, or exact-value `redacted`), and copies of the files
  that ran. Target fingerprinting has time, listing, file-count, and
  content-byte budgets, and a target containing a Git submodule or nested
  repository is refused (`target_has_nested_repository`), since Git lists none
  of its files, and any path the fingerprint cannot read (including Git's
  stderr-only "could not open directory" warnings) is refused or fails the run
  as `target_path_unreadable`. Runner-assigned variables (`MIX_EXS`, `MIX_ENV`,
  `INSIDER_ORACLE_*`) cannot be passed through and always win; redaction runs
  on raw bytes, so multiline values are removed whole; and the live run and the
  decoder reject reports of the wrong shape or for a different application,
  key list, or event than requested, and records whose verdict contradicts
  their evidence. Non-`complete` states
  (`empty_selection`, `unsupported_source`, `truncated`,
  `infrastructure_failure`) exit `3`, `4`, `5`, and `70`; a missing result
  line is always `infrastructure_failure`. See
  `decisions/2026-10-21_oracle_runner_uses_a_test_path_overlay_and_saves_versioned_runs.md`.
- Generated documentation with ex_doc (`mix docs`, a `dev`-only dependency;
  the production dependency graph and artifact gate are unchanged). New
  `guides/people/` pages (overview, how a session works, safety model, what
  exists today, try it locally) and `guides/agents/` operating contracts
  (`mix insider.candidates`, the three oracle artifacts, `mix insider` and the
  protocol envelope, the Sentinel chain, `mix insider.privacy_corpus`, the
  load harness and `scripts/verify-load-evidence`, refusals, reading a
  report). Lab gains the same `dev`-only dependency so
  `(cd tools/insider_lab && mix docs)` renders its API reference. README
  corrections made while grounding the guides: the Sentinel paragraph no
  longer lists checkout, dependency restoration, source changes, or draft PR
  creation as implemented; bisection's unavailable-executor outcome is
  `inconclusive`/`executor_state_unknown` rather than `operation_failed`;
  `mix insider` input errors (`insider.mix-task.error/v1`, exit 64) and its
  fixed diagnostic budget, CLI JSON depth/width limits and protocol budget
  defaults, the privacy corpus task's `staging`/`production`-only environment
  and 16 MiB file bound, the `--max-candidates`/`--max-duration-ms` switches,
  per-`defmodule` alias scoping, control-byte oracle-hint omission, the
  4,095-byte `INSIDER_ORACLE_KEYS` bound, invalid-context `null` echo, the
  tick-or-segment lag definition, and `LICENSES/` in the layout table. The Lab
  README table now lists `INSIDER_ORACLE_KEYS` and `INSIDER_ORACLE_CONTEXT`
  and names `Bisection` in the Phase 6 chain; the Load README verifier output
  list includes `directory`.
- A third fixed Lab-only value-free ExUnit oracle,
  `tools/insider_lab/priv/oracles/otel_global_state_test.exs`
  (`insider.otel-global-state-oracle/v1`), that fingerprints the
  OpenTelemetry default tracer and text-map injector/extractor globals before
  the suite and after it, reports `changed`, `unchanged`, `inconclusive`, or
  `operational_failure` (`opentelemetry_api_not_loaded`, `invalid_context`),
  records whether the `opentelemetry` SDK application was loaded and started,
  echoes `INSIDER_ORACLE_CONTEXT`, and never emits tracer or propagator module
  names or configuration. The Lab gains `opentelemetry_api` as a `:test`-only
  dependency for the artifact's tests; the root application is unchanged.
- A live Lab integration test that runs the documented Phase 6 offline repair
  chain end to end on a real sandbox executor—three fresh confirmations,
  regression, coding-agent handoff, candidate submission, verification, repair
  report, draft proposal, source-ownership routing, dedup ledger, and the
  draft-creation executor with its test provider—and proves that one candidate
  identity threads through every artifact. README status now records which
  Phase 6 artifacts exist and what remains before any provider authority.
- A read-only `Insider.Policy.ProtectedTargets.audit_matrix/1` export and the
  committed, test-pinned `docs/protected-target-audit-matrix.json`
  (`insider.protected-target-audit-matrix/v1`) that enumerate, per supported
  OTP major, every fixed registration name and control-target class with the
  denial decision the policy produces. The matrix is derived from policy data
  without runtime inspection and contains no PIDs or timestamps; application
  targets and an exception-review owner remain undeclared.
- Load reports localize missed scheduled operations: each phase summary gains a
  `scheduling` section with per-segment (`warmup`, `steady`, `overload`,
  `recovery`) and per-cause (`skipped_tick`, `segment_end_remainder`) counts
  plus `max_tick_lag_us`, and a report whose sums do not reconcile with
  `missed_operations` is invalid. A phase that fails before its workload
  completes reports its unexecuted `steady` and `overload` work as
  `segment_end_remainder` misses so the failed report remains valid and keeps
  its original failure reason. `scripts/verify-load-evidence` recomputes the
  digests and identities of emitted evidence directories offline and prints one
  JSON verdict line per directory. Pass/fail gates and profiles are unchanged.
- A Lab-only `Insider.Sentinel.Bisection` that binary-searches a host-declared
  ordered list of two to sixty-four disposable sandbox targets for one
  adjacent nonreproduced/reproduced pair bracketing a confirmed regression,
  with two fresh confirmations per probed index, proven endpoints before any
  midpoint, nondeterministic, inconclusive, and unclean-executor stops,
  bounded probe and duration budgets, and a canonical
  `insider.bisection-record/v1` whose fixed controls record no repository
  read, checkout, source mutation, Git authority, or network effect, and whose
  fixed limitations record that outcome monotonicity is a host assumption and
  that indices off the search path are never probed. Standalone validation
  replays the search path; `validate_with_evidence/6` rederives every index
  decision from the referenced confirmation records. Completion reports the
  adjacent boundary pair with `proof=adjacent_boundary_isolated`, never an
  earliest reproducing target or a cause.
- A Lab-only privacy corpus runner (`Insider.Lab.PrivacyCorpus`,
  `mix insider.privacy_corpus`) that projects caller-supplied synthetic Logger
  and Telemetry items through the exact ingress handler code paths for a
  selected ingress profile and emits a canonical
  `insider.privacy-corpus-report/v1` with retained field names, bounded
  suppression counts, item kinds, and canary-token coordinates, never the
  values of retained fields. It is
  bounded, fails closed on unknown shapes and unused tokens, creates no atoms
  from corpus input, and ships a fake-valued schema example. The application
  corpus and the review of every retained field remain human work; a clean
  report grants no staging or production authority.
- A Lab-only, agent-requested ExUnit candidate inventory with executable-AST
  signal detection, adopter case-template support, identity-matched cleanup
  ranking, non-following bounded traversal, source/configuration fingerprints,
  explicit scan/truncation accounting, and a JSON-first
  `mix insider.candidates` interface. Literal application-env and Telemetry
  targets are emitted without configured values; unqualified callees are marked
  syntactic, and simple visible aliases produce declaration-ordered syntactic
  identities without code loading or expansion. Ambiguous and dynamic targets
  stay unresolved. It performs
  no background scanning or test execution and labels every result as a
  candidate rather than a confirmed defect.
- Candidate inventory `telemetry_event` targets (scanner revision
  `ast-v8-telemetry-event-targets`): one resolved entry per literal event path
  passed to `:telemetry.attach/4`, `:telemetry.attach_many/4`, or
  `:telemetry_test.attach_event_handlers/2`, with dynamic lists or elements
  left unresolved. `:telemetry_test.attach_event_handlers/2` is ranked as a
  VM-global handler attachment without cleanup credit because its handler id
  is the returned reference. Every target now carries a static `oracle` hint
  naming the fixed Lab artifact schema and environment inputs that match the
  identity (`null` for handler ids, unresolved targets, and identities the
  artifact would reject); the hint installs and authorizes nothing.
- A fixed Lab-only ExUnit application-env oracle artifact that reports bounded,
  value-free before/after evidence for one agent-selected target without
  spawning tests, interning target names, or exporting its per-run HMAC key.
- A fixed Lab-only ExUnit Telemetry dead-handler oracle that reports bounded
  before/after counts for one agent-selected event without emitting handler
  identities, destination PIDs, functions, configuration, or event payloads.
- The application-env oracle accepts `INSIDER_ORACLE_KEYS`, a bounded
  comma-separated set of 1 to 16 distinct keys in one application, as an
  alternative to the single `INSIDER_ORACLE_KEY`; exactly one selector must be
  set. Multi-key reports keep the v1 schema, add a per-key `targets` list, and
  derive an aggregate `status`; the single-key shape is unchanged apart from
  additive fields.
- Both oracle artifacts echo an optional opaque `INSIDER_ORACLE_CONTEXT` (up to
  1,024 printable UTF-8 bytes without control characters) verbatim as
  `context`, report `null` when it is unset, fail closed with `invalid_context`
  otherwise, and declare `context_is_caller_supplied_and_unverified` as a
  limitation in every report, including operational failures. The artifacts
  never interpret the context.
- A separate non-published synthetic load/soak harness with fixed profiles,
  revision- and runtime-bound canonical evidence, structural failure gates, and
  CI retention across the supported Elixir/OTP matrix without claiming an
  approved production budget or enabling production observation.
- Bounded, canonical observability trigger and export contracts. External
  signals remain inert requests without collection authority, while outbound
  summaries are re-derived from validated redacted capsules and carry no raw
  events, artifacts, endpoints, credentials, callbacks, or delivery claims.
- Deterministic Sentry ingestion-event and Datadog Events v2 mock mappings in a
  capsule-bound canonical envelope that always reports `mock: true` and
  `delivery_status: not_attempted`, plus a contract-only host handoff behaviour.
  No provider client, transport, delivery lifecycle, or rollout support is
  included.
- A revision-aware production-readiness dossier, evidence index,
  planning-only staged-canary runbook, and canonical non-authoritative input
  worksheet. They retain missing evidence and human approval as blockers and
  grant no staging or production authority.
- A Lab-only, disabled-by-default draft-creation gate that recomputes exact
  verified evidence, requires destination-specific disclosure approval, and
  emits bounded canonical receipts through host-allowlisted, provider-idempotent
  draft-only integrations without exposing credentials, merge, or deployment.
- A Lab-only canonical coding-agent boundary. A self-contained handoff is
  emitted only from an exact ready capsule/manifest/regression graph plus two
  fresh matching failed confirmations; a returned repair reuses the bounded
  verification-candidate schema and remains inert, disclosure-unattested, and
  explicitly unverified until the existing isolated verifier reruns it.
- A host-owned supervised Collector Session that composes the permitted
  Logger, Telemetry, Poller, and Recorder collectors under one immutable
  protected-target binding. It denies staging/production before side effects,
  permits one globally owned active session, provides bounded health and
  cleanup evidence, retains at most 32 terminal receipts, and isolates its
  `one_for_all` session root from unrelated application children.
- A host-owned immutable protected-target policy for Runtime and Poller, with
  structured pre-probe denials for fixed OTP registrations, the bound Insider
  control plane, and additive host declarations. Explicit ingress profiles now
  mechanically disable Logger payload/message semantics and require Telemetry
  allowlists for denied staging/production readiness profiles.
- A physical production-artifact boundary: root `:insider` now ships only the
  collector/evidence core, while Sentinel, fixtures, contract/invariant and
  scenario execution, CLI/Mix/escript surfaces, and the restart-capture fixture
  harness live in the non-published dependent `tools/insider_lab` project. A
  fail-closed fresh source, beam, application, release, and isolated-VM
  inventory gate verifies that Lab capabilities are absent from production
  artifacts.
- A canonical offline draft-proposal artifact that accepts only recomputed,
  verified five-run repair evidence and grants no network or repository
  authority; publication remains blocked pending disclosure attestation.
- A Lab-only canonical source-ownership companion bound to an exact
  draft-proposal v1, its bounded simple unified-diff candidate, and direct
  provider-neutral declaration bytes. It emits only opaque,
  declared-unverified routing labels, uses last-match-wins semantics, leaves
  unmatched paths unassigned, and grants no identity, assignment,
  authorization, repository, network, provider, or mutation authority.
- A Lab-only bounded offline incident/proposal deduplication ledger. Canonical
  capsules may enter before proposal eligibility; proposals bind to a retained
  exact capsule only after full evidence-graph recomputation. Exact artifact
  repeats are idempotent, new content in a hashed finding group is retained as
  new evidence, capacity refuses visibly without eviction, retained bytes are
  physically detached, bounded, and self-revalidated, and canonical receipts
  retain only content-addressed references, a bounded numeric admission total,
  and bounded counts.
- A production observation threat model, fail-closed readiness matrix, and
  separate revision-bound human gates for a bounded staging canary and a later
  production release.
- An `Insider.Runtime` facade and `mix insider` task for bounded, scalar-only
  same-node process inspection with machine-readable capabilities and results.
- A run-correlated Sentinel lifecycle signal when an external exit status is
  observed, without claiming Port-down or process-group state.
- Initial Mix application and supervision-tree scaffold.
- Agent engineering guardrails, local Git hooks, and CI quality matrix.
- Versioned, bounded request and effect-honest result protocol with typed
  failures and hostile-input-safe decoding.
- Deny-by-default capability and environment policy with trusted runtime
  context, effective limits, safe discovery, and bounded audit evidence.
- Deterministic faulty and healthy fixture pairs backed by real OTP process,
  supervision, mailbox, monitor, timeout, and Telemetry signals.
- A bounded, atom-safe event v1 vocabulary with canonical JSON, extensible
  string kinds, explicit stream ordering, and conflict-aware causality.
- Explicit same-node logical identity declarations with bounded generation
  tracking, monitor cleanup, and conflict-safe event attachment.
- A bounded priority flight recorder with direct non-mailbox admission, visible
  loss accounting, rate shedding, and one-shot causal-window snapshots.
- A structured OTP Logger collector with pre-translation capture, a fixed-slot
  handoff inbox, bounded term shaping, and explicit overload health counters.
- A bounded restart-recurrence detector using explicit OTP supervisor semantics,
  trusted receipt time, distinct child incarnations, and deduplicated findings.
- A fail-closed redaction boundary with fingerprinted pure-data policies,
  bounded hostile-term traversal, and deterministic Event-compatible manifests.
- Bounded portable provenance with independently addressable code,
  configuration, dependency, runtime, and target evidence plus explicit
  unavailable and policy-redacted states.
- Offline-validating incident capsules with enforced root-aware redaction,
  content and event-chain integrity, and digest-only large-artifact references.
- Failure-isolated VM and explicit-process polling with scalar-only evidence,
  hard target/deadline bounds, and visible timeout and truncation accounting.
- A bounded mailbox-growth detector requiring sustained queue growth without
  observed reductions, with evidence-gap resets and declared buffer exclusions.
- Versioned application semantic contracts with deterministic discovery,
  explicit sensitivity and ownership, and bounded failure-isolated callbacks.
- A detector-neutral finding envelope with exact restart and mailbox schemas,
  evidence correlation, and byte-preserving legacy restart capsule support.
- Semantic invariant evaluation with machine-readable callback outcomes,
  policy-aware evidence, confirmed recorder-backed findings, and offline
  capsule round trips.
- A canonical collector-to-Sentinel manifest that binds exact capsule bytes,
  preserves prerequisite availability and redaction, and fixes a
  non-authoritative disposable confirmation posture.
- Canonical portable reproduction scenarios with bounded semantic steps,
  deterministic seeds, expected finding fingerprints, and cleanup-reserved
  disposable execution.
- A provider-driven disposable-target lifecycle with exact observed provenance,
  owner-scoped leases, synchronous cancellation, inventory-backed cleanup
  evidence, and quarantine for unproven reclamation.
- An optional trusted sandbox body-owner seam that runs bounded allowlisted work
  on the live owner lease between exact provenance observation and provider
  cleanup, with receipt-and-termination gating, declared stop-phase bounds for
  TERM-to-KILL escalation, and quarantine when stopping cannot be proved.
- Clean-target confirmation records that jointly bind manifest, capsule,
  scenario, requested and observed target, lease owner, observer run, repair
  oracle, complete evidence, and inventory-backed cleanup before confirming an
  exact incident fingerprint.
- Canonical data-only regression recipes that embed an eligible source
  confirmation and exact scenario, plus a bounded two-fresh-run classifier that
  reports consistent failing-before evidence without treating source replay or
  repair evidence as proof.
- A bounded whole-step scenario minimizer that requires two fresh baseline
  confirmations and three fresh isolated confirmations per candidate, stops on
  nondeterminism or cleanup uncertainty, returns best-known evidence on
  exhaustion, and emits a canonical one-step-minimality record with an explicit
  execution-search duration scope without claiming global minimality.
- A bounded verification orchestrator that proves two fresh failing-before
  confirmations before dispatch, executes two independent host-allowlisted
  post-repair sandbox runs, and emits a canonical verdict bound to opaque
  candidate bytes, exact oracle receipts, provenance, gates, and zero-resource
  cleanup.
- A private bounded external-process seam with host-fixed profiles, canonical
  same-owner machine receipts, raw-output non-retention, direct process cleanup,
  and backward-compatible confirmation and verification receipt v2 bindings.
- A bounded, content-addressed repair-report manifest derived from exact capsule,
  Sentinel handoff, and verification evidence, plus deterministic Markdown that
  exposes the causal invariant, declarative reproducer, five-run proof, candidate
  diff, provenance changes, redaction boundary, verification matrix, coherent
  cleanup and executor counts, and known uncertainty without accepting caller-
  authored success claims.
- Bounded partial protocol result values on every non-success status, including
  unsupported operations, allowing a sandbox to retain a valid body receipt
  when timeout, cancellation, body failure, or cleanup controls operational
  status without converting evidence into success.
- Recorder-owned sensitivity companions bound to exact event bytes and redaction
  policy fingerprints, with automatic fail-closed capsule export and separate
  bounded storage accounting.
- A bounded Telemetry allowlist collector with optional exact-width
  OpenTelemetry correlation, fixed-slot ingress, lifecycle-gap health, safe
  handler-failure evidence, and ownership-aware cleanup.
- Process-subject attribution for synchronous Telemetry emitters and an opt-in
  Logger payload-omission boundary for privacy-sensitive causal capture.
- An opt-in bounded ERTS system-event collector using isolated OTP 28-29 trace
  sessions and an explicit conflict-refusing OTP 27 compatibility mode, with
  trusted runtime-context gating, closed local-identity projections,
  mailbox-overload self-disable, and receiver-termination cleanup evidence.
- A transport-only CLI with direct term, canonical JSON, and recoverable NDJSON
  framing, machine-readable operation availability, bounded isolated dispatch,
  hostile-input-safe decoding, and deterministic protocol-aware exit statuses.
- An executable, test-compiled Phase A harness that honestly advertises and
  runs one real faulty or healthy fixture through trusted policy and bounded
  portable results, with supervised cleanup independent of CLI caller timeout.
- A reusable restart-capture seam that causally fans trusted normalized events
  through the recorder and recurrence detector into one offline-valid redacted
  capsule, plus a test-only dual-authorized, intent-idempotent fixture host
  proving faulty/healthy, overload, started timeout, cancellation,
  export-failure, caller-death cleanup, recorder-crash isolation, fixed-cache
  conflict/capacity behavior, and cleanup outcomes. The real restart fixture
  now owns its Agent, supervisor, and workers below a caller-monitoring process,
  enabling lease-token cancellation and host-death cleanup without a synthetic
  lifecycle fixture. Its resource notifications are opt-in, preserving ordinary
  fixture mailbox isolation. The shipped capture owner now also exposes a
  correlated reserve/publish/acknowledge admission before recorder work, plus a
  phase-checked begin/execute/cancel lifecycle. Duplicate lifecycle messages are
  idempotent, and one retained inventory drives cleanup and accounting. The acceptance host distinguishes published
  resource PIDs from reserved but unmaterialized slots and accounts for
  all ten unique fixture and capture resources and the full admission-to-cleanup
  duration, including cancellation after capture admission.

### Changed

- The production-readiness evidence index is now
  `insider.production-readiness-evidence-index/v2`. Each evidence set and
  the assessed revision name a `revision` label of the pre-release snapshot
  in place of `git_revision` and `tree_sha`, because that history is not in
  this repository. Report identities and file hashes are unchanged.

- Documentation layout: the README is now a short synopsis (what Insider is,
  a quick start, when to use it and when not, Insider and Tidewave, status
  and safety). Its reference sections moved, with their examples, into topic
  files under `docs/`, and `docs/README.md` indexes them with a task table
  that names the file, the section anchor, and its approximate size. Stale
  claims found during the move were corrected (lease-renewing calls, observer
  flags, the welcome quick start's ten steps, built-in duration minimums,
  view sources, session collectors, Digest authorization masking, status and
  roadmap). `AGENTS.md` links the index and states what belongs in the README
  versus `docs/`. `usage-rules.md`, the guides, the Lab README, moduledocs,
  and the documentation tests point at the new files. `mix docs` renders
  `docs/` in groups that match the index, opens on the README, copies
  `docs/assets/`, and builds with no warnings. The package `files` include
  `docs/`. `test/documentation_links_test.exs` checks every relative link,
  anchor, and image, that linked headings get the same anchor on GitHub and
  in ex_doc, the index sizes, the 600-line limit per topic file, and that
  every file under `docs/` is an ex_doc extra.

- Documentation audit round: `docs/glossary.md` (terms such as receipt,
  lease, baseline and profile, which mean different things in Live, the Lab
  and the load harness) and `docs/cheat-sheet.md` (the most-used observer
  commands) are new. The index has three areas (Use Insider Live, Lab and
  research, Production readiness and development) and new rows for hangs,
  pinned traces, response values, N+1 queries, Oban jobs, timelines, the
  baseline, the cleanup receipt, the default session, a node you did not
  start, and flaky tests. Long sections are split, so no indexed section is
  over 150 lines. The Live files gain command examples for every operation, a
  complete observer flag reference, a cleanup-receipt section, and a table of
  what each disclosure profile shows and withholds. The disclosure docs state
  that `rich` assumes development data holds no real personal data, and say
  to set `:strict` when it does. `Current status` is a set of tables. The
  README, `AGENTS.md`, the usage rules, and the architecture page use one
  product definition. The shipped docs and the welcome drop evaluation
  anecdotes and company examples. The docs tests now also check each topic
  file's back-link line and contents list, closed code fences, and section
  size per index row, and the readiness test rejects internal company,
  evaluation, and ticket names in the README, `docs/`, the guides, and the
  usage rules. `mix docs` copies the readiness JSON beside the pages, titles
  the people overview "Overview", orders the guides, and groups
  `Insider.Lab.Output`.

- The welcome quick start's first step, `mix insider.live --help`, and the
  agent guide now say that stdout carries only the observer's JSON while
  Mix's `Compiling` and `Waiting for lock on the build directory` notices go
  to stderr, and point agents whose tool merges the two streams, or several
  agents in one checkout, to the `insider-lab` escript, which prints neither.
  A Lab test runs every machine-output task while another process holds the
  build lock and parses each one's stdout.

- Coverage: on OTP 27, the modules that only run on OTP 28 and later
  (`Insider.Collector.Calls`, `Calls.Tracing`, and `Otel.Tracing`, which need
  isolated trace sessions) are left out of the coverage total, since only
  their `requires_otp_28` refusal runs there. On OTP 28 and later they are
  counted, and the 90% floor is unchanged on every OTP release.
- An inspection's session record that its caller stopped waiting for
  reports `recorded` `nil` with `reason` `outcome_unknown`, never `false`:
  the session refuses a record that arrives after its deadline, but one
  already handed to the Recorder may complete after it.
- The observer's `events` and `watch` print a lean event envelope by
  default (`--format json`): each event drops the fields that are the same
  for every event (`schema`, `node`, `boot_id`, `clock_id`,
  `source_instance_id`, `source_sequence`, `monotonic_time`, `authority`)
  and those that are null or empty; `--format full` prints events exactly
  as the target returns them. Every `insider.live-events/v1` batch now
  carries `disclosure_profile`, the profile its events crossed. The Live
  quick start has six core commands (`digest` after `start`), its recipes
  start with a triage digest, and each available symptom recipe reads with
  `digest` before `events`.
- The observer's malformed-option code is `invalid_options`, the same name
  as the target's (it was `invalid_option`). Its details name the flag
  (`option`), the `problem`, the expected value or accepted flags
  (`expected`), and the `help` command; a target `invalid_options` passing
  through the observer gains the flag that set its `field` and that flag's
  syntax. The observer's own argument errors and `non_loopback_host` never
  echo a value, which may be a secret typed into the wrong place; errors the
  target returns pass through and can name a value they reject (such as
  `unknown_telemetry_event`'s event). A quick start, recipe, or example command that no longer
  parses with the observer's parser fails the Lab suite.
- A live read's `"limit"` and `"max_bytes"` now count only the events it
  returns, never the ones its view hid, and `"max_bytes"` counts their
  canonical JSON bytes rather than stored bytes; a read stopped by either
  ends just before the next event it would have shown, consuming the hidden
  ones in between. The view is applied event by event inside the read
  (`Insider.Live.View.hides/2` replaces `filter/2`), so a sparse view no
  longer starves.
- The observer's `watch` prints the envelope (`schema`, `status`,
  `operation`, `target`, `installation`, and the first-contact `welcome`)
  once, on its `subscribed` line, which also carries the subscription;
  `batch` and `stopped` lines carry only `kind` and their own fields.

- `mix insider.candidates` no longer reports an empty, partial, or truncated
  scan as clean. The inventory is now `insider.exunit-candidate-inventory/v2`
  with a `completeness` field (`complete`, `empty_selection`,
  `unsupported_source`, `truncated`); `status` is `clean` or `candidates` only
  for a `complete` scan and otherwise names the completeness state. New exits:
  `3` `empty_selection` (no `_test.exs` file selected), `4`
  `unsupported_source` (invalid syntax, a skipped symlink, or an unreadable
  path; candidates found are still reported), and `5` `truncated` (a file,
  byte, or candidate bound was hit). Failed scans (exit `70`) add
  `completeness: infrastructure_failure` to the unchanged v1 error document.
  Candidate entries, fingerprints, and `scanner_revision` are unchanged.

- The non-published Load project no longer starts an empty supervisor;
  dependency startup and its clean-revision evidence gate remain unchanged.
- `Insider.Event.validate_encoded/1` validates an event and returns its
  canonical binary from a single pass. Validating the aggregate byte bound
  already produces that encoding, so `Recorder.record/2`, `Recorder.freeze/2`,
  and incident source entry building no longer validate twice and encode three
  times per event. The recorder admission benchmark drops from a p50 of
  ~42.4 us to ~23.2 us per record on the development host, restoring headroom
  under its 50 us development p95 budget. `validate/1` and `canonical_binary/1`
  keep their existing signatures, results, and errors.
- Recorder rate-window expiry now deletes stale ETS rows in place instead of
  copying every rate entry on each admission. In an eight-round development-host
  run at 256 keys, p95 admission fell from 32.90 to 27.35 us per record.

### Fixed

- A collector session start that ran past its budget now fails with a
  `startup_failed` receipt whose `cleanup.startup` is `timeout`, with
  `start_budget_ms` and `start_elapsed_ms`. When the session itself found
  its start authorization expired, the Manager returned the bare reason, so
  Live reported `start_failed` without a receipt (or, through another path,
  startup `other`). The session supervisor also starts before the Manager,
  so a start admitted right after a root restart can no longer lose its
  worker and leave the start slot held.

- The Live quick start failed in zsh, the macOS default shell: the welcome,
  the hints, `mix insider.live --help`, and the docs set the target flags as
  one string, `N="--node … --cookie-file …"`, and zsh passed the unquoted
  `$N` as one word (`invalid_options`, exit 64). They now set an array,
  `N=(--node NAME@HOST --cookie-file PATH)`, and every generated command
  passes `"${N[@]}"`. The `watch` example quotes its `'phoenix.*'` view
  pattern, which zsh refused as a glob with no match. A Lab test runs every
  welcome example and every observer command line in the docs through bash
  and zsh, when present, and parses the words with the observer's parser.

- Live `trace` and `timeline` read the session newest first. A
  recent request or trace is found in a long session even when the
  four-second budget ends before the oldest receipt (a
  `timeline --request-id` read from the oldest found 1,413 of 16,000 events
  and returned no items). A scan that ends early reports `scan_truncated` with
  the receipts it did not read, and `scan` gains `direction` and `unread`.
  Cumulative losses are the session's totals since it started, read by
  internal reads that ignore and issue no cursor baseline, so a page
  cursor another reader issued cannot turn them into a smaller delta.
- Live `bin_leak` names the biggest binary holder first: the
  result's new `biggest_holder` is the process that still references the
  most binary bytes after the collection, and it sorts ahead of
  `by_freed_bytes` in the canonical JSON, where an agent reading the head of
  the document saw only the garbage list and concluded the leak was not
  named. `--human` (option `"human"`) prints the holders
  first as plain text, then what the collection freed, and says when the
  evidence is incomplete (scan limit, unfinished collections, protected
  processes), never claiming an absence then; the text is at most 8 KiB
  and the result's lists are cut around it to the result bound.
- `insider-lab live` calls no longer take 7-25 s on a loaded host. Two
  fixed costs dominated each call:
  - Booting a VM with one busy-waiting scheduler per core took 10-17 s before
    `main` ran at load averages of 100-160. The escript now embeds
    `+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none`.
  - The observer's own build identity loaded and hashed every Insider module
    on each call. It is now computed once at compile time
    (`Insider.Lab.Live.ObserverBuild`), and Mix recompiles it when the build
    changes.

  Measured against the same target: a `capabilities` call went from 14.6-19.9 s
  to 0.8-1.7 s at a load average of about 156, and from about 0.55 s to about
  0.45 s at load about 24.

- Tests run from a Git hook can no longer change the repository the hook
  runs for. Git exports `GIT_DIR` and `GIT_INDEX_FILE` to hooks, and git
  commands the tests ran in scratch directories acted on the real repository
  instead (on 2026-10-23 that set `core.bare=true` and committed to a real
  branch). `pre-commit` and `pre-push` now unset `GIT_DIR`, `GIT_WORK_TREE`,
  `GIT_INDEX_FILE`, `GIT_COMMON_DIR` and `GIT_OBJECT_DIRECTORY` before mix.
  Every test helper that runs git clears them for its child processes. So do
  the oracle runner's target listing and the load harness's revision capture.
  Each project has a regression test that runs its git-using tests with those
  variables pointing at a sentinel repository and checks the sentinel is
  unchanged.

- `--load` no longer leaves a target on another build of the same Insider
  version. The observer compares build identities: the application version,
  the commit, and a SHA-256 over the loaded `:insider` modules' MD5s (new
  `Insider.Live.Build`). `--load` only installs: it pushes Insider into a
  target with no Insider code, or starts this build where it is loaded but
  stopped, and verifies that the target then reports this build. Any other
  build loaded on the target, started or not, is refused with the new
  `load_build_differs` error (exit 3). The error reports both builds, whether
  a session is active (or `"unknown"` when the owner does not answer), and
  the remedy: the new `--force-load`, which replaces Insider and ends any
  session. See
  `decisions/2026-10-23_observer_load_only_installs_and_only_force_replaces.md`.
  `installation` in every observer document now carries `observer_build`,
  `target_build`, `same_build`, and a `remedy` when the builds differ.
  The observer's `insider_version_mismatch` and `insider_not_started`
  messages, the welcome quick start, the README and `mix insider.live --help`
  say the same: `--load` installs or starts this build only, and replacing
  another Insider takes `--force-load`, after saving the session's evidence.
- A Poller process scan on a busy node usually records the rankings it
  reached instead of a timeout with none. Each `process_info/2` answer comes
  from its target, so the scan waited for every busy process to be
  scheduled: with four spinning processes per scheduler a scan of 3,000
  processes took 2.5 s at the median, past its 1 s probe timeout, and CI
  once recorded a `process_top` with no rankings. A scan now stops
  issuing scan requests at 5/8 of its probe timeout (`unavailable`
  `scan_deadline`) and naming requests at 7/8 (`process_names`); one
  outstanding request can still outlast the timeout. An unfinished scan's
  Insider totals are incomplete, and the next scan gives a process it did
  not reach no reductions delta (`reductions_delta` unavailable) rather
  than its lifetime count.
- A Lab contract invocation whose callback exceeded its deadline is reported
  as `:timeout` / `:deadline_exceeded` even when the caller handles the
  result after the dispatch deadline. Under load the caller could reach
  the result with no time left to release the runner, which had already
  stopped, and reported `:executor_failed` instead (a flaky
  `ContractTest` on the Lab 1.17 lane). The caller now confirms the runner's
  exit on the monitor it already holds before asking the executor to
  release it.

- Recorder admission no longer spins. The writer next in line for the
  ticket lock looped on `:erlang.yield/0` until its turn. A process that is
  always runnable keeps its scheduler from sleeping or taking work from
  another, so the host's own processes waited behind it. Every waiter now
  sleeps until its turn's release wakes it or a 1 ms poll ends, and a dead
  holder is passed on after 64 polls (nominally 64 ms). On GitHub's
  2-scheduler runners the load harness's overload phase missed a 10 ms tick
  (50 operations) in 4 of 6 jobs before this change, and none after it;
  instrumented CPU time and garbage collections went back to what they were
  before the ticket lock. See
  `decisions/2026-10-23_recorder_admission_waiters_sleep_and_never_spin.md`.

- Live otel draining is bounded and never silent. A read's drain stops at
  its one-second deadline even while spans keep arriving (it used to run
  past the read's call bound and return `otel_accounting_unavailable`) and
  leaves the rest `pending` for the next read. A seal or stop that cannot
  drain its backlog in time counts what it leaves as `otel_abandoned`, or
  reports `otel_accounting_unavailable` when even the count cannot finish,
  instead of discarding those spans.

- Compiler progress no longer precedes Lab Mix task output on standard
  output. `mix insider`, `insider.live`, `insider.oracle`,
  `insider.candidates`, and `insider.privacy_corpus` compile the project
  first with Mix's progress (`Compiling N files (.ex)`) on standard error, so
  the first call after a Lab source change prints the same standard output
  as any other call. Output formats are unchanged. Every Lab task and the
  `insider-lab` escript write through one UTF-8-safe writer
  (`Insider.Lab.Output`), so non-ASCII text such as `…` no longer prints as
  `â€¦`.
- `mix insider.oracle` output redaction is bounded in time and memory. All
  passthrough values are matched in one scan that merges overlapping matches
  and writes each replacement straight into the output, and lines are
  filtered in one more pass, so no list of spans or lines is held: 64
  overlapping values over a 1 MiB capture take about 150 ms and a constant
  heap, where before they exhausted a 16-million-word heap. Values over 64,
  over 1 KiB each, or over 16 KiB in all, more than 16,384 replaced spans, and
  a scan over its work budget fail closed: nothing is saved, `output.txt`
  states the reason, and the run record gets an `output.withheld` field that
  names it. See
  `decisions/2026-10-22_oracle_runner_bounds_output_redaction_and_withholds_past_the_bound.md`.

- Live loss reporting across a stop or amendment. A component whose final
  status the seal could not read now leaves
  `<component>_accounting_unavailable` on every later read of the session,
  through later amendments and the drain window, while keeping the loss
  counts the copy before the seal had read. Boundaries a stop or amendment
  could not copy to the end are reported as at most one
  `segment_end_unread` gap per read, with `"boundaries"`, from at most eight
  stored ranges, so the gap list stays bounded however many there are.
- A Logger flood no longer evicts other sources' evidence. The Recorder
  reserves each event source a share of its events and bytes
  (`source_shares` and `other_share`; by default `logger` 25%, `telemetry`
  15%, `poller` 25%, `otel` 10%, `inspect` 5%, `system_monitor` 5%, others
  5%). When it is full, a source over its share evicts its own oldest
  entries, and a source within its share takes room from those over
  theirs. On a shop test target, rich Logger at info had filled the 4 MiB
  Recorder in about four minutes and evicted the early Poller samples.
  Protected entries keep their precedence. `Insider.Recorder.fill/1` and
  `status/1` report per-source usage and evictions under `sources`, and
  Live `status` under `recorder.sources`; the welcome describes the shares
  under `recorder`. These per-source counts and the cumulative
  `evicted` counter, now their sum, are conservative: an eviction is
  counted before its entry is deleted, so a writer killed in between can
  make them exceed the real evictions, never fall short. Receipt-range
  `evicted` gaps stay exact.
- Insider no longer grows while serving large Live reads. A read is served
  in pages of at most 100 entries and 128 KiB (`bounds.read_page_entries`,
  `bounds.read_page_bytes`) and keeps only the events it returns, and the
  owner, Manager, and Session collect their garbage after replying. A 1 MiB read from a full
  Recorder peaked at 4.1 MB in the owner, 4.1 MB in the session Manager, and
  7.7 MB in the Session, which kept 2.5 to 9.6 MB afterwards; it now peaks at
  3.0, 0.14, and 0.29 MB over their collected heaps, and no process keeps
  anything of it (`bench/live_read_memory.exs`, which now also reads while
  the owner keeps stopped sessions readable and through an amended
  session's archive). Archive pages, and pages joining the archive to the
  Recorder, keep the same 128 KiB bound, counting archived entries by
  external term size. Live `status` reports Insider's own memory
  as `insider_memory`, and the collector session's read reply names the
  bound that ended a page as `"truncated_by"`.
- `usage-rules.md` and the agent guide no longer say payloads, Logger
  message text, and Telemetry metadata never leave the node in every
  profile; that holds only in `strict`, and `rich` is the development and
  test default. A drift guard keeps both documents in line with the
  welcome's disclosure defaults.
- Credential masking no longer reads a port as a URL password:
  `http://127.0.0.1:4100` at the end of a value, before a query or
  fragment, or inside inspect text, and IPv6 hosts such as
  `http://[::1]:4000` stay readable, and an `@` in a later JSON field never
  turns a port into a password. URL userinfo is now decided by a bounded,
  linear scan of each URL's authority that fails closed: real `user:pass@`
  userinfo is masked whatever RFC 3986 characters it holds (apostrophes,
  `,`, `;`, `)` and numeric prefixes included), userinfo without a password
  is masked whole, and a password a cut left at the end of a value or of a
  quoted value is masked. An ambiguous unquoted list such as
  `http://h:4100,a@b` is masked, and a provider key or JWT inside userinfo
  never hides the rest of the password. A port is one to five digits, and an
  authority longer than 2,048 bytes is masked whole up to its last `@`. An
  all-digit password of one to five digits cut exactly at its end reads as
  a port.

- The observer delivers the welcome once per target node incarnation (its
  name and distribution creation), not once per node name forever: a
  restarted node, or a node first contacted after another, gets the quick
  start again. Printing `welcome` now counts as delivery, so the next
  command carries a pointer instead of repeating the document.
- Live subscriber batches are contiguous: each starts at the previous
  batch's `next_cursor`. A poll whose view hid every event was not sent but
  advanced the subscriber's cursor, so the next batch began there and the
  hidden receipts fell outside every batch's range while its view counts
  included them (one agent report saw cursor 555 after next_cursor 516).
- Concurrent `Insider.Recorder` writers no longer lose events to the
  admission lock (`recorder_contended`). Admission is now a ticket
  lock: a writer that finds the lock held waits for its turn and writers
  are admitted in arrival order, instead of dropping at once. A waiting
  writer sleeps until woken through a process alias that is drained before
  the call returns, so no message is left in its mailbox; dead holders and
  dead or abandoned waiters are passed over. A writer gives up, as
  `:contended`, only when the lock has not changed hands for the new
  `start_link/1` option `admission_stall_ms` (0 to 5,000, default 1,000; 0
  is a single attempt). The Recorder must be called from collector or other
  Insider-owned processes, never from application processes. Memory, size,
  event and rate bounds, receipt order, and loss accounting are unchanged.
  On a plain peer with Logger and Telemetry each emitting 600 events/s
  through one Live session, the base revision lost 152 of 3,592 events as
  `recorder_contended` and this change lost none; at 3,000 events/s each,
  only rate limits, inbox shedding and eviction lost events.
  `bench/recorder_contention.exs` gates the write path with 1, 2, 4 and 8
  writers, timing every call against the same round's single writer: no
  contended loss, per-call p50 and p95 within margins of N times one
  writer's, and a minimum share of one writer's throughput, over the median
  of 8 rounds whose before-and-after probes saw no scheduler-thread
  preemption (an advisory screen: a pause inside a round goes unseen, so
  run it on an idle host); otherwise it exits 2 (inconclusive).
  The base revision lost about 90,000 of 128,000 writes with 8 writers.

- Live Telemetry events that report a failure are now severity `error`,
  so a `"min_severity" => "error"` view keeps them: every `*.exception`
  event, and any event whose metadata has `result` `{:error, _}` or
  `:error`, `conn.status` or `status` 500 to 599, `kind` `:error`, `:exit`, or
  `:throw`, or a non-`nil`, non-`false` `error`. Live recorded
  `phoenix.router_dispatch.exception` and a 500's `phoenix.endpoint.stop`
  as `info` before. The rule (`Insider.Collector.Telemetry.Outcome`) reads
  only the event name and those shapes, never other metadata, and is the
  same one summaries use for `errors` and minimum durations use to keep
  errors. The welcome document gains a `severity` table generated from it
  and from the Logger level mapping.
- A Telemetry measurement a live session did not select now leaves a `drop`
  record in the read entry's `redactions` (`policy_id`
  `insider-live-telemetry`), as the welcome's disclosure rules promise: it
  names the measurement when the host allowlist has it, and counts the rest
  without names; in the strict profile the uncollected metadata keys leave
  one counted record. Counts are exact. The core Telemetry collector records
  this evidence in each event's `"omitted"` attribute (never in the event's
  `redactions`, which stays the export manifest that incident capsules
  require to be empty), names withheld measurements only when they are in
  its new `nameable_measurements` option, records the counts alone if
  the names would not fit the attributes bound, and records the event
  without the evidence if even the counts would not, counting it as
  `omissions_unrecorded` (Live gap `telemetry_omissions_unrecorded`). The welcome's strict
  rules now say plainly that Logger content is not collected at all.
- The observer's report queue moves from the system temporary directory,
  which a reboot can wipe, to `insider-live` in the user's durable state
  directory (`~/Library/Application Support` on macOS, `$XDG_STATE_HOME` or
  `~/.local/state` elsewhere); `INSIDER_LIVE_REPORTS_DIR` still overrides
  it. Reports filed with pre-release builds in `$TMPDIR/insider-live` are
  not carried over or read; the queue there was never released, and a
  person can still open `observer-reports.jsonl` in that directory by hand.
- Report context carries the observer's last local failure
  (`last_local_operation`, `last_local_error_code`), such as a `usage`
  error, beside the last target operation; the issue body labels both.
  Queued records without these keys are read with them as `nil`.
- `scripts/verify-load-evidence` fails closed when `manifest.json` or
  `report.json` is not byte-identical to its canonical encoding, reporting
  `manifest_not_canonical` or `report_not_canonical` with `ok: false`. It used
  to skip identity recomputation and still report `ok: true` for such files,
  so a manifest with a substituted `id` and digest plus a trailing newline
  passed. `id_recomputed` is now true whenever `ok` is.
- A startup worker that dies after child admission now keeps the session start
  slot quarantined until the session root resets; a second session cannot take
  ownership of an unreported child.
- The Load harness stages bounded artifacts in restricted private directories
  and publishes them exclusively. It leaves foreign or partial public files
  intact on publication failure and emits a verified failure-only artifact
  when output remains empty. Git status has a hard elapsed-time bound, and
  profile and lockfile reads have byte bounds.
- Lab's advisory ExUnit scanner tracks `Application` shadowing by module and
  declaration order even when unsupported aliases disable key resolution.
  It no longer credits shadowed or repeated application-environment deletion
  as restoration and rejects malformed scan options and repeated scalar CLI
  switches without rejecting repeated paths.
- Lab minimization preserves the cleanup observation that stopped a search,
  emits verifiable one-run baseline evidence on quarantine, and retains
  exhausted or nondeterministic evidence when a later cleanup check fails.
- Lab bisection stops an index as `probe_inconclusive` on its first unclean
  confirmation instead of spending a second. Two probes that failed before
  observation produced one content-addressed confirmation record twice, which
  no trial may reference, so the search returned `invalid_bisection_record`
  with no record at all. Record validation accepts a one-attempt inconclusive
  trial only when its single record is itself unclean.

- `scripts/verify-production-artifact` now boots the release through
  `bin/insider`. It used to run the first executable in `bin/`, which on Linux
  can be the Windows `insider.bat`, so the gate failed on every CI runtime.
- The external-process cancellation test now preserves `cleanup_uncertain` as
  an honest bounded outcome, binds its exact Linux descendant to the owned
  process group, and separately proves fixture reclamation instead of treating
  an arbitrary later disappearance as part of the library verdict.
- The Poller failure-accounting regression now reserves its maximum bounded
  cycle window for two deliberate provider failures, so unrelated scheduler
  contention does not ordinarily turn the second failure into a valid
  truncated probe.
- The normal-exit process-group test now creates its work deadline inside the
  executing task and observes pending completion without extending the wait,
  so scheduler admission is not charged to the descendant-drain assertion.
- Contract lifecycle tests now give asynchronous callback-start handshakes the
  same explicit bounded second used by adjacent capacity and termination
  assertions, avoiding the implicit 100 ms scheduler-contention flake.
- External process execution now survives caller death long enough to terminate
  and reap the complete owned process group instead of orphaning its BEAM child.
  Negative process-group probes and signals use a portable option boundary, and
  cleanup waits boundedly when the direct port exits before its last descendant.
- Restart-capture continuation tests now retain strict event ordering while
  allowing a bounded second for lifecycle notifications on constrained CI
  runners.
- Identity-bearing host commands now hash stdout separately from platform
  diagnostics, preventing stderr warnings from changing an otherwise identical
  code or patch digest while preserving nonzero-status failure.
- Logger and Telemetry hot-path benchmarks now fail when they exercise a rescue
  path, violate latency budgets, or fail exact admission/shedding accounting.
- Contract invocation now synchronously releases its completed supervised
  runner before returning, so sequential callbacks cannot be falsely shed as
  overload while the executor is still reconciling the prior child exit.
- Poller deadline verification now coordinates an active probe before advancing
  the absolute deadline, eliminating a scheduler-dependent test race while
  asserting the exact number of probes started and truncated.
- Sandbox execution now reserves a caller-declared bounded provider-cleanup
  phase independently from body stopping, and protocol/scenario duration bounds
  can explicitly authorize target-application verification up to ten minutes
  while retaining the five-second default.

- Restart capture now accepts a correlated terminal result during recorder
  admission and drains the owner's following `DOWN`, so a deadline before
  readiness is not misreported as owner failure or left in the caller mailbox.
- Made the local coverage gate generate the same threshold summary and HTML
  evidence with bounded file-descriptor use on macOS and Linux.

- Executor shutdown now gives active sandbox worker termination and
  owner-scoped cleanup a shared bounded drain phase before the lease registry
  exits, directly cancels blocked cleanup process trees, reports termination
  that remains unconfirmed, and quarantines unconfirmed target work.
- Detector errors now discard hostile invalid Event IDs instead of copying
  unbounded or invalid UTF-8 identifiers into diagnostic output.
- Logger fixture capture now uses a bounded collector flush barrier, preventing
  freeze and snapshot from racing an asynchronous collector drain.
