# Live start skips quiet default Telemetry events the node lacks

## Context

The quick start runs `start --component logger --component telemetry`
without naming events, so the session records the quiet default Telemetry
events. In 0.1.0 those defaults came only from Phoenix, Oban, Absinthe,
Bandit, Cowboy and the configured Ecto repositories. On a node without any
of them, such as a new `mix new` app, the list was empty, and the start was
refused with `invalid_options` for `telemetry_events`. The observer showed the
expected value of `--telemetry-event`, so the quick start failed on the first
plain app it met.

## Decision

- Without `"telemetry_events"`, the telemetry component records the quiet
  defaults that exist on the node: their application is loaded and every
  segment is already an atom. It skips the others.
- The start and amendment results list the skipped defaults under
  `telemetry_skipped_defaults`, each as
  `{"event": "phoenix.endpoint.stop", "reason": "not_on_target"}`. The list
  is `[]` when the session names its events or does not ask for Telemetry.
  It is not a configuration value, so `status` does not show it and an
  amendment never counts it as changed.
- When no default is left, the session runs without the telemetry
  component. The result's `components` says so, and `telemetry_hint` reads
  "no default Telemetry events exist on this node; pass --telemetry-event or
  use discover". Telemetry measurements selected for it are dropped with it.
- When the telemetry component was the only one, nothing is left to record,
  and the start stays `invalid_options` for `telemetry_events`. The error
  now carries `telemetry_skipped_defaults` and the same hint.
- An explicit event name is never skipped. A name whose segments are not
  already atoms stays `unknown_telemetry_event`.

## Why

- **The quick start must work on any development node.** A default is a
  convenience, so a missing one is reported, not refused.
- **No atom is created.** A default is used only when its atoms exist, as
  before, so the caller still cannot grow the atom table.
- **Leave the component out rather than run it empty.** The Telemetry
  collector's policy needs at least one event, and its handler and cleanup
  checks rely on that. A component with nothing to record would add a
  collector that proves nothing. Leaving it out keeps the collector contract
  unchanged and makes `components` say what runs.
- **Explicit names stay strict.** A name the caller gives is a claim about
  the node, and a typo there must fail loudly.

## Consequences

- The `start` option description no longer says `telemetry_events` is
  required without quiet events. It describes the skip instead.
- An agent that sees `telemetry_hint` can add events later with
  `amend --telemetry-event`, which brings the telemetry component back.
  The session keeps the telemetry component in its requested options, so
  an amendment that leaves `telemetry` out returns the kept
  `telemetry_events` and `telemetry_measurements` to their defaults, as it
  already did for Poller and call-trace options.
- The bounds, the disclosure profiles, and the quiet defaults of a start
  without options are unchanged.
