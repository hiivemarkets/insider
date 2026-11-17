# Actor differential oracle is a library that agent-written probes require

## Context

Access-control probes kept being written by hand in the same shape: build a
fixture, run one GraphQL operation as the entitled party and as parties who
should be refused, check that the entitled party succeeds, and compare
responses and database rows. For example, in `MyApp`, a shop, the owner of a
bid may call `withdrawBid` and a stranger may not. Each hand-built copy chose
its own controls and printed raw responses, including other users' data, into
run output.

The fixtures, the way an actor authenticates, the request, and what counts as
success are host knowledge. They exist only inside a test in the host's own
test VM. Insider must not hold host-specific code.

## Decision

Lab ships `tools/insider_lab/priv/probes/actor_differential.exs`, a
self-contained source file defining `InsiderLab.ActorDifferentialOracle`. An
agent-written ExUnit probe in the target loads it with `Code.require_file/1`
and calls `run/1` with a declaration. It is not a `mix insider.oracle` kind.

- **Host adapters are caller-supplied functions.** The declaration names the
  operation, a `fixture` function, actors (`name`, `access: :allow | :deny`,
  optional `control: true`, and an `as` function that returns the actor's
  credential for a fixture), a `request` function, an `allowed?` predicate on
  the response, and optionally a `state` projection and the `effect` keys a
  permitted request must change. Unknown fields, missing fields, wrong arities,
  more than 16 actors, no entitled control, or no compared actor make the call
  an `infrastructure_failure` with a closed `reason`, and no adapter runs.
- **Controls gate every verdict.** Entitled controls run first, then refusal
  controls, then compared actors. An entitled control must be granted, raise
  nothing, and change every `effect` key; a refusal control must be refused,
  raise nothing, leave every state key unchanged, and start from the first
  control's state. One unhealthy control makes the call
  `infrastructure_failure` (`control_unhealthy` or `denial_control_unhealthy`)
  and no compared actor is attempted.
- **A fresh fixture per actor.** Each attempt builds its own fixture, so one
  actor's mutation cannot change what the next actor sees. A compared actor
  whose initial state fingerprint differs from the control's is `not_observed`
  (`initial_state_differs_from_control`), and so is one whose initial state
  cannot be compared because a value on either side could not be fingerprinted
  (`initial_state_not_comparable`); for an additional control either is
  unhealthy. The state projection must therefore be free of ids and
  timestamps.
- **Verdicts in the shared vocabulary.** A refused-rule actor that is granted,
  or that changes state while refused, is `confirmed`; an entitled actor that
  is refused or granted without the effect is `confirmed`; an actor whose
  attempt failed or whose state could not be compared is `not_observed`;
  otherwise `not_reproduced`. The call's outcome is `confirmed` if any
  compared actor is, else `not_observed` if any is, else `not_reproduced`. It
  never reports `contract_disproved`: a declared set of actors cannot show the
  code meets its contract. Completeness uses the runner's states `complete`,
  `truncated` (a response summary hit a bound; the outcome still holds), and
  `infrastructure_failure`.
- **Value-free, bounded report.** `insider.actor-differential-oracle/v1` holds,
  per actor, the observed access, the failing stage with the exception module
  only, field paths with their kinds (at most 64 paths, depth 8, 4,096 nodes,
  255-byte paths; keys that are not identifiers become `*`), `__typename`
  values and error codes under `errors` or `extensions` (identifiers only, at
  most 16 each), and per state key whether it changed and whether it equals
  the control before and after. Equality uses HMAC-SHA-256 with a random key
  drawn per call and never exported. A value is fingerprinted only after a
  walk of at most 65,536 terms shows its external-format size is at most
  1,048,576 bytes (containers charged 5 bytes, leaves their exact size), so a
  small term that shares a subterm many times is never sized or serialized in
  full. Functions are never fingerprinted. An unfingerprinted value is
  unknown, never equal to anything. No response or state value is printed.
- **One line per call.** `run/1` prints one `INSIDER_ACTOR_DIFFERENTIAL_ORACLE=`
  line, starting on a fresh line, and returns the same report.

## Why

The runner kind was considered and rejected for now. The runner exists to
install a fixed observer around a host's own test without editing the
checkout. Here the probe is the agent's own disposable file and the
differential is the test body, so an overlay would add nothing it needs. The
runner's record also accepts exactly one result line of a fixed shape per run,
and a probe often holds several differentials. Adding the kind would mean
changing the runner's report validation, CLI, record decoder, and committed
fixture for no gain in what the oracle can observe.

A compiled Lab module cannot be used because the host test VM does not load
Lab. A single source file has no dependency beyond OTP 27's `:json`, like the
fixed oracle artifacts. It lives in `priv/probes/` rather than `priv/oracles/`
because those artifacts are installed from `test_helper.exs` and observe a
whole suite. This one is called from inside a test.

Requiring controls, rather than trusting the `allowed?` predicate, is what
makes a verdict meaningful: a predicate that never matches fails the entitled
control, and a predicate that always matches fails a refusal control when one
is declared, which is why the guide asks for one.

## Consequences

- An agent writes the fixture and auth adapters once per target area. The
  oracle supplies ordering, controls, state diffing, verdicts, and the
  value-free report. During development, the oracle was validated against a
  real application by reproducing hand-built access probes with the same
  verdicts.
- Saved run records, the output allowlist, and target fingerprints are not
  applied, because the probe runs through the host's own test command. A probe
  that prints values itself is outside this oracle's guarantees.
- Attempts run in the calling test process, so the bound on time is the
  ExUnit test timeout. The fixture is rebuilt for each actor, so a host whose
  fixture cannot be built twice in one test cannot use it as is.
- The declaration is the access rule, so the oracle cannot judge whether the
  rule is right, and a `not_reproduced` covers only the declared actors.
- `insider.actor-differential-oracle/v1` is a versioned contract. A field
  change needs a new schema version. A runner kind that saves these reports
  remains a later decision.
