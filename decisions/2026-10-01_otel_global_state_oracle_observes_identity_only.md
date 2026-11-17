# OpenTelemetry global-state oracle observes identity only

## Context

The candidate inventory ranks test modules that call an
`OpenTelemetry`/`:otel*` `set_tracer_provider` or `set_text_map_propagator`,
or a `setup_otel_capture` helper, with the `otel_global_capture` signal. Those
calls write process-global `persistent_term` entries that outlive the test, so
a test that replaces the tracer or propagator and does not restore it changes
the behaviour of every later test in the VM. The two existing fixed oracles
observe application environment and Telemetry handlers; neither can see this
state.

The installed `opentelemetry_api` (1.5.x) exposes readers for exactly three
globals: `:opentelemetry.get_tracer/0` (the global tracer provider's default
tracer), `get_text_map_injector/0`, and `get_text_map_extractor/0`. It has no
tracer-provider accessor, and `set_text_map_propagator/1` writes the injector
and extractor together. The default tracer term carries SDK configuration (the
provider PID, sampler, and ID generator); the propagator terms name the
installed modules and their composite configuration.

## Decision

Ship a third fixed Lab-only ExUnit artifact,
`tools/insider_lab/priv/oracles/otel_global_state_test.exs`
(`insider.otel-global-state-oracle/v1`, prefix
`INSIDER_OTEL_GLOBAL_STATE_ORACLE=`). It reads the three exposed globals
before the suite and from an ExUnit after-suite callback and compares per-run
HMAC-SHA256 fingerprints of their deterministic external term form. The
observed globals are fixed, so the artifact takes no target selector; it
accepts only the shared, validated-first `INSIDER_ORACLE_CONTEXT`.

Report per-global `changed`, `unchanged`, or `inconclusive` (unreadable, or
more than 1 MiB of external size) in a `targets` list, an aggregate status that
is `changed` if any global changed, and four booleans recording whether the
`opentelemetry` SDK application was loaded and started at each capture. Never
emit the tracer or propagator module names, tracer configuration, propagator
terms, or the HMAC key. A test VM without the `opentelemetry_api` application
loaded is `operational_failure` with reason `opentelemetry_api_not_loaded`.

`opentelemetry_api` becomes a Lab `:test`-only dependency so the artifact's
own tests can exercise the real API in a child VM. The root `:insider`
application does not depend on it, and the production artifact gate is
unchanged. The adopter must already depend on `opentelemetry_api` for the
artifact to observe anything.

The inventory emits `otel_global_capture` as a ranking signal without a
target, so no `oracle` hint is added for this artifact.

## Consequences

- An agent can confirm that a selected test leaves OpenTelemetry tracer or
  propagator globals different without a bespoke probe and without disclosing
  which tracer, sampler, exporter, or propagator the adopter uses.
- The oracle deliberately does not observe named tracers, per-application
  tracers, the module-to-application map, baggage, context, metrics, or logs
  globals, nor SDK process state beyond loaded/started booleans; the
  `only_default_tracer_and_text_map_propagator_are_observed` limitation
  records this.
- A fingerprint change is bounded observation, not proof of causality,
  production impact, or repair correctness. The caller still binds test and
  revision.
- Starting the SDK during a test changes the default tracer and is reported
  as `changed`; the SDK booleans let the agent read that case.
- A future `opentelemetry_api` major that renames or removes an accessor
  makes that global `inconclusive` rather than failing the run or emitting a
  value.
- Compile or test-file load failure can prevent the after-suite callback;
  missing output is infrastructure failure, never clean evidence.
