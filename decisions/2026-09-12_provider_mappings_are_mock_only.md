# Provider mappings are mock-only

## Decision

Insider may produce deterministic, provider-shaped Sentry event and Datadog
Events v2 request bodies only inside an Insider value that is unambiguously
marked `mock: true` and `delivery_status: not_attempted`.

Insider will not include a Sentry or Datadog SDK, HTTP client, endpoint, DSN,
API key, credential, transport, queue, retry, callback receiver, or send
operation. Tests use frozen local fixtures and pure mapping functions. They do
not create vendor data.

The host-client boundary is a type/behaviour contract only. Any future host
implementation, live delivery, staging rollout, or production rollout requires
a separate security, privacy, and operations decision.

## Context

A host may have no Sentry integration, or may send Datadog data indirectly
through structured logs, a metrics agent, or OpenTelemetry. Host test suites
commonly disable network exporters, capture telemetry and spans in-process, and
stub HTTP integrations rather than call a live service.

Mocked provider data was chosen deliberately so that tests never pollute, or
need to clean up, a real Sentry or Datadog account.

## Consequences

- Provider mappings can be checked against realistic, frozen shapes without
  creating external state.
- A successful mapping proves only deterministic local projection; it is not a
  delivery receipt or evidence of provider acceptance.
- Provider schema drift remains a compatibility risk and must be rechecked
  before any future live integration.
- Production and staging observation remain disabled.
