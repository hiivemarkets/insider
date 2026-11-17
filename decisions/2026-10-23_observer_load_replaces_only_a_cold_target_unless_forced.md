# The observer's --load replaces another build only on a cold target unless forced

## Decision

This supersedes the **With `--load`** and **Session safety** parts of
`2026-10-23_observer_load_matches_builds_and_never_silently_ends_a_session.md`.
The target-side reservation (`Insider.Lab.Live.Replacement`, which suspended
`Insider.Live.Owner`) is removed. That record's build identity, unknown-build
handling, "without `--load`" rule, and force override still apply.

- **Cold targets.** `--load` replaces another build, of the same or another
  version, only when the target's `:insider` application is not started. It
  stops nothing that runs, so no session can be lost. Afterwards the target
  must report the observer's build, or the result is `load_failed`.
- **Started targets.** When Insider is started and its build differs, `--load`
  refuses with `load_build_differs` (exit 3) and changes nothing. The error
  carries:
  - `target_build` and `observer_build`;
  - `session_active`, from the target's `Insider.Live.capabilities/0`:
    `true` with `session_id`, `false`, or `"unknown"` when the owner does not
    answer, does not report itself responsive, or the call fails;
  - a `remedy`: stop any session (naming the `stop` command when the session
    is known), then pass `--force-load`; or pass `--force-load` now, which
    ends any session.
- **Force.** `--force-load` replaces a started Insider whatever its session
  state, and ends any session. The environment gate still applies.
- **Same build.** `--load` is a no-op for Insider (it may still push recon).
- **Compatibility.** These additions to `insider.live-observer/v1` are
  additive: `load_build_differs` joins the closed error vocabulary, and
  `load_session_active` (never released) is gone.

## Why

The reservation tried to make "no session runs" and "stop Insider" one step
on a live target. Review found that overlapping reservations released each
other, that nothing fenced owner creation or restart, and that timeout
cleanup could kill the recovery guardian. Each fix would have widened a
locking protocol layered on another process's mailbox.

Never replacing a started Insider without an explicit force removes the
check-then-act window altogether. The session check becomes advice for the
caller, not a guard. A cold target has no session to lose, and a started one
is replaced only when the caller has accepted ending its session.

## Consequences

- Moving a running development node to a new build takes `--force-load`,
  normally after `stop`.
- `session_active` in the refusal is a snapshot; it can change before the
  caller acts. That is harmless, because only `--force-load` acts, and it
  states that it ends any session.
- A target that vendors an Insider of the same version but another build is
  reported (`same_build: false`) and never changed without `--force-load`
  while it runs.
