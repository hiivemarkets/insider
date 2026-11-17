# The observer's --load matches builds, not versions, and never silently ends a session

## Decision

This supersedes the version-only matching in the replacement semantics of
`2026-10-22_observer_node_attaches_locally_and_loads_only_into_dev_targets.md`.
Its other parts are unchanged: local targets only, cookie handling, and the
development, test, and ci gate on every load.

- **Build identity.** `Insider.Live.Build.identity/0` is
  `%{"commit" => commit, "beams_sha256" => hash}`.
  - `commit` is `Insider.Live.Revision.commit/0`, which is `nil` outside a Git
    checkout.
  - `hash` is the lowercase hex SHA-256 over every module of the `:insider`
    application, sorted by name, as `name <> <<0>> <> module_info(:md5)`.
    A module that cannot load contributes `"unloaded"`.
  - It is computed on the node that is asked, so it describes the code that
    node actually runs.
  - Two builds are the same only when both fields are equal.
- **Unknown builds.** A target that has `Insider.Live` but no
  `Insider.Live.Build` (an Insider from before this decision) has build `nil`.
  `nil` is never the observer's build.
- **Without `--load`.** Another build of the same version is not refused. The
  command runs and `installation` reports `same_build: false` and a `remedy`,
  so targets that vendor the same version keep working. A missing,
  other-version, or unstarted Insider is still refused (exit 3).
- **With `--load`.** Another build is replaced: it is stopped, unloaded, and
  the observer's build is pushed and started. The target must then report the
  observer's build, or the result is `load_failed`.
- **Session safety.** Stopping Insider ends its session, so `--load` stops it
  only under a target-side reservation (`Insider.Lab.Live.Replacement`). The
  observer pushes that module into the target and drops it again afterwards.
  - The reservation suspends `Insider.Live.Owner`, through which every
    session start passes, and reads the owner's state while it is suspended.
  - If no session runs, the owner stays suspended until the stop, so a start
    sent after the check waits unanswered and never runs before Insider
    stops.
  - It refuses with `load_session_active` (exit 3) when a session runs
    (`reason: session_active`, with the session id). It also refuses when the
    state cannot be read: an owner that does not answer, or a state without a
    readable session (`reason: session_state_unknown`). Unknown fails closed.
  - A guardian resumes the owner if the stop does not arrive within twice the
    command's timeout, and a refusal resumes it at once. A lost observer
    therefore never leaves the target suspended.
- **Force override.** `--force-load` is `--load` without the reservation. It
  replaces Insider even while a session runs, which ends that session. It is
  the only way an observer command ends a session other than `stop`, and the
  environment gate still applies.
- **Compatibility.** The changes to `insider.live-observer/v1` are additive:
  - `installation` gains `observer_build`, `target_build`, `same_build`, and
    `remedy` when the builds differ;
  - the error vocabulary gains `load_session_active`.

  No field changes meaning.

## Why

With version-only matching, a target started from an older checkout of the
same version kept its old code after `--load`, and every document said
`action: none`. Agents then tested stale code without noticing.

Comparing commits alone misses a modified working tree and a partial push.
Hashing the loaded modules catches both.

Replacing code under a running session would silently destroy evidence
another agent is reading, so the default must refuse. Reading the session
state and stopping Insider in two separate steps would leave a window in
which a session could start and be destroyed. Suspending the owner closes it
using only OTP, which works against any older build. An owner that cannot
answer may be serving a session, so treating it as idle would be guessing.

## Consequences

- A target whose owner is hung cannot be replaced without `--force-load`.
- While a reservation is held, a session start in the target waits for up to
  twice the command's timeout. It then fails, because Insider stopped, or
  proceeds, because the reservation expired.
- The observer pushes one Lab module into development targets for the length
  of a replacement.
- Same-build checks cost one extra remote call per command.
