# The observer's --load only installs, and only --force-load replaces Insider code

## Decision

This record supersedes the replacement rules of three earlier records:
- `2026-10-23_observer_load_matches_builds_and_never_silently_ends_a_session.md`
  ("With `--load`" and "Session safety");
- `2026-10-23_observer_load_replaces_only_a_cold_target_unless_forced.md`
  ("Cold targets" and "Started targets");
- `2026-10-23_observer_cold_load_never_stops_or_kills_and_builds_include_the_version.md`
  ("A cold load uses no stopping operation" and "A race fails closed").

Still in force:
- the build identity: version, commit and module hash, from the last of those
  records;
- the unknown-build handling and the "without `--load`" reporting;
- the force override;
- the environment gate of
  `2026-10-22_observer_node_attaches_locally_and_loads_only_into_dev_targets.md`.

- **`--load` only installs.** It pushes Insider into a target with no Insider
  code loaded: no `:insider` application spec and no Insider module loaded
  (`Insider` or `Insider.*`, other than the Lab's `Insider.Lab.*` tooling). A
  partial install, any Insider module without the spec, counts as present. It
  also starts this build where it is loaded but stopped, and pushes only recon
  into a target that already runs this build. It never replaces Insider code.
- **Any other build is refused.** A target with another build loaded, started
  or not, gets `load_build_differs` (exit 3) and nothing changes. The error
  carries:
  - `target_build` and `observer_build`;
  - `session_active`: `true` with `session_id`, `false`, or `"unknown"` when
    the owner does not answer or the call fails;
  - the remedy, which is `--force-load`. It replaces the build and ends any
    session, and the session's evidence does not survive it, even when the
    session is stopped first, because the stopped session's retention lives
    in the Insider that is replaced. Read and save what is needed first:
    `events`, `digest`, `handoff`.
- **Only `--force-load` replaces.** It stops, unloads, purges and pushes
  Insider, then verifies that the target reports the observer's build.
- **Compatibility.** `load_build_differs` stays in the
  `insider.live-observer/v1` vocabulary. The `raced` detail and the test seam
  of the previous record are removed; neither was ever released.

## Why

Each narrower rule left a window. A check that a session is idle, or that
Insider is not started, can be invalidated before the replacement acts:
- Insider can start after the unload;
- a session can start after the check.

Three review rounds each found such a window. An observer that never replaces
existing Insider code without an explicit force has no check to race with.
The only replacement is the one the caller asked for, knowing that it ends
sessions.

## Consequences

- Moving any development node to a new Insider build takes `--force-load`,
  even when Insider is stopped there. Evidence needed from its sessions must
  be read and saved first.
- `session_active` in the refusal is advice: a snapshot taken when the
  refusal was built.
- First contact with a node that has no Insider is unchanged: `--load`
  installs it.
- **Residual, not supported:** two observers installing into one target at
  the same moment. So is an Insider start between the absence check and the
  first push. Both windows existed before this decision, in the original
  first-contact install, and the result of such a race is undefined. No
  lifecycle exclusion is built for it.
