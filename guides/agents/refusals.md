# What Insider will refuse to do

Insider fails closed. When an input, environment, or state is outside what a
component can prove safe, the component returns a typed refusal and does not
fall back to a weaker behavior. This page lists those refusals so an agent can
recognize them, understand why they exist, and stop instead of working around
them. Each entry names where the refusal lives.

## Environments and authority

- **Observe in staging or production.** `Insider.Collector.Session.start/2`,
  `Insider.Runtime.describe/3`, `Insider.Collector.SystemMonitor`, and the
  Lab runtime adapters accept only `development`, `test`, and `ci`. The
  refusal happens before any process, filter, handler, timer, or monitor
  exists. (The privacy corpus runner is the deliberate exception: it takes
  `staging` or `production` precisely to project items through the denied
  profiles' allowlists without observing anything.) Why: enabling either
  environment is a separate, revision-bound human decision recorded outside
  the code; the readiness dossier grants none.
- **Trust an environment or capability a request claims.** Requests are
  evaluated against trusted runtime context supplied at host startup
  (`Insider.Policy.Context`); the `environment` and `capability` fields in a
  request are inputs to a policy decision, not the decision. Why: a transport
  cannot authenticate its caller.
- **Remove a protected target.** `Insider.Runtime.HostPolicy` and
  `Insider.Policy.ProtectedTargets` let a host add protected PIDs and names
  but never remove the versioned OTP/Elixir inventory or Insider's own session
  processes. Why: observing a supervisor's own infrastructure is an observer
  effect on the thing being measured.
- **Accept textual PIDs.** `mix insider inspect` takes `--name` only. Why: a
  PID string copied from another BEAM can alias an unrelated local process.
- **Infer a free session slot.** A session start that times out while its
  `DynamicSupervisor.start_child/2` call is queued stays quarantined until the
  call reports; a new session is never permitted on inferred absence. Why:
  the collector may still be starting.
- **Remove a Logger filter it did not install.** The session uses the fixed
  `:insider_logger` primary-filter id and permits one active session globally;
  an unrelated holder of that id is never removed.

## Evidence and redaction

- **Emit partial redaction output.** `Insider.Redaction.redact/3` returns
  `:redaction_failed` with nothing else on invalid terms, exceeded limits,
  deadlines, or a malformed or forged policy. Undeclared secret data drops by
  default. Why: a partially redacted artifact is indistinguishable from a
  fully redacted one to its consumer.
- **Let an event choose its own classification.** Recorder classification is
  a trusted binding supplied at construction; Event fields cannot select or
  downgrade it.
- **Truncate a capsule silently.** `Insider.Incident.Capsule` rejects
  snapshots over 64 events, 32 artifact references, or 1 MiB. Why: a truncated
  capsule would verify as complete.
- **Wait on a stuck recorder, or let an application process wait at all.**
  `Insider.Recorder.record/2` never sends to the recorder process and is
  called only from collector processes. Writers that meet at its admission
  lock wait for their turn in arrival order and give up with
  `{:dropped, :contended}` when the lock has not changed hands for
  `admission_stall_ms` (default 1 s); it also returns `{:dropped, reason}`
  under pressure, rate limits, invalid input, closure, or recorder loss, and
  the snapshot keeps the gap. Why: the host application must never block on
  observation; a held-up collector backs up into its own bounded inbox.
- **Report an unavailable metric as zero.** The load harness and poller use
  typed availability; a required metric that is unavailable fails the gate.

## Static analysis and oracles

- **Treat a candidate as a defect.** The inventory labels every result
  `candidate` and lists `static_signals_do_not_confirm_runtime_causality`.
  It never equates a source heuristic with runtime behavior.
- **Guess a dynamic identity.** Rebound aliases, multi-alias forms,
  multiple-module files, dynamic event lists, and non-literal arguments become
  `unresolved` targets with `oracle: null`. Why: a wrong identity would send
  an oracle at the wrong state.
- **Follow symlinks, expand globs, or leave the root.** Selectors are exact
  paths validated component by component with `lstat`; a symlink anywhere in
  a selector is `selector_symlink`; a path outside the root is
  `selector_outside_root`.
- **Load or execute target code.** The scanner parses with
  `Code.string_to_quoted/2` and never compiles, evaluates, or runs tests.
- **Intern caller input.** All three oracle artifacts, the privacy corpus
  runner, and `mix insider inspect` resolve names only against atoms that
  already exist. Why: atom creation from untrusted input is unbounded.
- **Export the HMAC key or a configured value.** Oracle reports carry
  presence and per-run fingerprints only; a value over 1,048,576 external
  bytes makes the key `inconclusive` rather than being serialized anyway.
- **Count silence as unchanged.** If no `INSIDER_*_ORACLE=` line appears, the
  after-suite callback never ran. That is an infrastructure failure.
- **Accept a canary token that occurs nowhere.** The privacy corpus runner
  fails closed on tokens absent from every item. Why: an unused token proves
  nothing and would inflate a clean result.

## Sentinel

- **Mutate source, read a repository, or use the network.** Every portable
  artifact records it: manifest and regression `source_mutation=prohibited`;
  bisection `repository_read=none`, `checkout=none`, `git_authority=none`,
  `network_effect=none`; handoff and proposal `repository_mutation=none`,
  `network_effect=none`. The core itself never invokes a shell, filesystem,
  network, node, container, or cloud API.
- **Let portable data select code.** Scenario strings resolve only through a
  trusted contract-module allowlist; body modules, providers, and disclosure
  authorities come only from host configuration; candidate bytes are data and
  only a host-selected body interprets them. An external-process command's
  arguments must exactly equal the profile's declared public fingerprint
  projection.
- **Report cleanup it did not observe.** A lease is `complete` only after
  independent owner inventory is empty; otherwise it is partial or uncertain
  and quarantined. A timeout cannot retract an inspection already delivered,
  so timeout results carry `cleanup.status` `uncertain` and say so.
- **Classify a regression from reused runs.** `Regression.classify/2` is
  inconclusive if either record is the embedded source run or shares its
  observation-run identity. Verification never reuses the handoff's failure
  runs.
- **Dispatch a candidate before the baseline fails.** `Verification.run/7`
  will not run post-repair attempts unless `classify/2` reports `failed`.
- **Round up an inconclusive verification.** A record with any reason is
  `invalid`, and the repair report keeps it visibly so.
- **Claim an earliest culprit or a cause.** Bisection reports one adjacent
  boundary pair under the host's monotonicity assumption and records
  `target_causality_is_not_claimed`.
- **Create a draft without a configured authority.** The draft-creation
  executor is disabled by default, has only test providers, requires a
  disclosure authority to approve the exact payload, and treats a provider
  timeout as `provider_outcome_unknown`. It never exposes merge or deploy.
- **Evict from the dedup ledger.** A valid input that cannot be retained is
  `capacity_refused` and the ledger is unchanged. Why: silent eviction would
  turn a duplicate into new evidence.

## Transport

- **Parse ETF or textual Erlang terms from untrusted input.** The CLI accepts
  JSON or NDJSON only; canonical encoding is an output guarantee, not an
  input requirement.
- **Return an uncorrelated result.** A dispatcher result whose protocol,
  request id, operation, or target does not match the request is an
  `operation_failed` error with `cleanup.status` `uncertain`.
- **Exceed its byte, frame, depth, or width limits.** 16 MiB input and output,
  1,000 frames, depth 8, width 1,000; violations are
  `insider.cli.error/v1` with exit 64, or correlated `operation_failed`
  frames for oversized results in `invoke_ndjson/2`.

## Packaging

- **Ship Lab in the production artifact.** `scripts/verify-production-artifact`
  fails if any Lab-only source entry, module, or release application appears
  in the built release, and boots the release to prove the modules cannot
  load. `test/production_artifact_boundary_test.exs` also fails if `mix.exs`
  declares an escript, `insider_lab`, or a provider HTTP client.
- **Publish from an agent session.** A maintainer publishes the first release
  by hand. Later releases need the `release` environment's reviewers and a
  maintainer's approval of the staged release on Hex.

If you need one of these behaviors, the answer is a new decision record and a
reviewed change, not a workaround.
