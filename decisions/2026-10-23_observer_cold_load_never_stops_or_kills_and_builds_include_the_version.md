# The observer's cold --load never stops or kills anything, and builds include the version

## Decision

This supersedes two parts of earlier records:
- the build identity format in
  `2026-10-23_observer_load_matches_builds_and_never_silently_ends_a_session.md`;
- the "Cold targets" rule in
  `2026-10-23_observer_load_replaces_only_a_cold_target_unless_forced.md`.

The rest of both records still applies.

- **Identity.** `Insider.Live.Build.identity/0` is
  `%{"version" => vsn, "commit" => commit, "beams_sha256" => hash}`, where
  `vsn` is the `:insider` application version as loaded on that node. The same
  modules under another application version are another build.
- **A cold load uses no stopping operation.** Without `--force-load` the
  observer never calls `:application.stop/1` or `:code.purge/1`.
  - It unloads the previous spec with `:application.unload/1`. That call
    refuses a running application, and does not stop it.
  - It pushes each module with `:code.soft_purge/1`, then
    `:code.load_binary/3`, then `:code.soft_purge/1` again. `load_binary` keeps
    the previous version as old code. A soft purge that fails means a process
    runs Insider code.
  - After the push and before starting Insider, it checks again that Insider
    is not started with another build.
- **A race fails closed.** If Insider started after the target was found cold,
  the load stops where it is and refuses with `load_build_differs`, with
  `"raced": true` and a fresh `session_active`. The signal can be:
  - the unload is refused;
  - a soft purge fails;
  - the spec is already loaded again;
  - or the check after the push finds Insider started.

  Whatever was loaded stays loaded, and no process is killed, so no session
  is lost. The target can then run a mix of builds. That is reported (the
  target's build differs) and is fixed only with `--force-load`.
- **Force is unchanged.** `--force-load` stops, unloads, purges, and pushes,
  as before.

## Why

Review found two ways an unforced `--load` could still end a session:
- Insider could start between the cold check and the unconditional
  `:application.stop/1`;
- equal module hashes under another application version passed the
  same-build check while installation still replaced the build.

Replacing the stopping operations with ones that refuse when code is in use
closes the first without any lock. Including the version makes "same build"
mean the same thing in both checks.

## Consequences

- A raced cold load can leave the target with new modules loaded and the old
  build's processes on old code. The refusal says so (`raced`), and
  `--force-load` repairs it.
- A target where any process still holds old Insider code, even with Insider
  stopped, cannot take a cold load. It needs `--force-load`.
- Every observer document's `observer_build` and `target_build` gain
  `version`. Builds from before this change, which have no `version`, never
  equal current ones.
