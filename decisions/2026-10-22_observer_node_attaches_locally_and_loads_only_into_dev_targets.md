# The observer node attaches only to local targets and loads code only into development targets

## Decision

The Lab's `mix insider.live` and `insider-lab live` are the
Erlang-distribution transport for `Insider.Live`. They are Lab-only
development tooling and grant no authority over a staging or production node.

- **Local targets only.** A target host must be a loopback address, this
  machine's own host name, or a name that resolves only to loopback addresses.
  Anything else is refused before distribution starts.
- **Cookie handling.** The cookie comes only from a regular file with no group
  or other permission bits. It is never read from argv or the environment,
  never printed, and is set only for the one target node. Targets set their
  cookie from a file at boot (`-e`), not with `--cookie`.
- **One short-lived hidden observer per command.** Each invocation starts a
  uniquely named observer with `hidden: true, dist_listen: false`. It never
  listens and never registers with epmd. It connects to exactly one target and
  stops distribution before exiting. Every remote call is `:erpc.call/5` under
  one caller-chosen timeout (`--timeout-ms`, at most 60 s), which applies
  separately to the epmd lookup, the connection and each remote call. Remote
  failures are reduced to a code and an exception module name, so no remote
  value is echoed.
- **Environment authority stays with the target.** The observer never asserts
  an environment. `Insider.Live` decides in the target. For `--load`, which
  runs before Insider exists there, the observer reads the same host facts the
  target would use: the `:insider` `:environment` setting (including boot
  arguments), then the Mix environment only when `:mix` is started. It refuses
  anything except development, test, and ci.
- **Replacement semantics.** By default a missing, different or unstarted
  Insider is refused (exit 3). `--load` is the only path that changes target
  code. It pushes the observer's own compiled `:insider` application, plus
  `jason` and `telemetry` when the target cannot resolve them. A different
  Insider is stopped and unloaded first, its application environment is carried
  into the new spec, and each module is purged and loaded with
  `:code.load_binary/3`. The target must then report the observer's version
  with `Insider.Live` loaded and started.
- **Schema ownership.** The observer owns `insider.live-observer/v1` and
  `insider.live-observer-error/v1` and their closed error vocabulary on the
  existing Lab exit statuses. Target results and target errors
  (`insider.live-*`) pass through unchanged, and target errors are marked
  `"source": "target"`. The README table and a test pin the vocabulary.

## Why

Agents need to observe any running BEAM node, not only Phoenix nodes with
Tidewave. Erlang distribution is the native channel, but it grants full code
execution to anyone holding the cookie. Limiting targets to this machine,
keeping the cookie out of process listings and output, never listening, and
gating code loading on the target's own environment keeps the observer a
development tool and not a remote-execution path. Version checking by default
avoids silently driving an incompatible API, and an explicit `--load` makes
the one code-changing action visible and opt-in.

## Consequences

- A release or remote node cannot be observed this way. That is intended.
- Version matching uses the `:insider` vsn plus the presence of
  `Insider.Live`. Two builds with the same vsn look identical.
- `--load` replaces code in a running development node, and purging can kill
  processes running old Insider code. Only Insider's own processes are expected
  to.
