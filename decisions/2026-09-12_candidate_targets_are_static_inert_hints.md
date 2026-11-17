# Candidate targets are static inert hints

## Decision

Include a bounded target list in each ExUnit candidate when an application-env
mutation or Telemetry attachment has literal target arguments. Each entry
records only its kind, operation, identity, source lines, and resolution status.
A root-qualified `Elixir.Application` call may be resolved. An unqualified
`Application` call is syntactic because an unexpanded macro could shadow it;
visible alias shadowing is rejected. At scanner revision v3, alias-expanded and
dynamic identities were recorded as unresolved. The later safe lexical-alias
decision narrows that limitation without changing this inert-hint boundary.

Targets are inert investigation hints. They do not read runtime state, retain a
configured value or callback, generate code, select an oracle, execute a test,
or promote the candidate to a confirmed defect.

## Evidence

Most early findings confirmed against a real application used the same
value-free application-env before/after oracle. Before configuring that
oracle, the agent had to reopen each candidate source and manually resolve
the application and key even though Insider had already parsed the relevant
call site.

A check of this change against a real application emitted the syntactic
application `logger`, key `default_handler`, operation `put_env`, and the
exact call-site line for the highest-ranked untriaged candidate. Those
arguments matched the separately configured runtime oracle that confirmed a
state change. No formatter, redactor, credential, trace payload, or
application-env value entered the candidate.

## Consequences

- Agents can move from candidate selection to a separately authorized runtime
  observation with explicit knowledge of whether the target is resolved,
  syntactic, or unresolved.
- Candidate content identity and the configuration fingerprint change with the
  target extraction semantics through scanner revision v3.
- A candidate emits at most 64 deduplicated targets and reports truncation.
- Literal configured values and callback bodies remain outside the target list.
- Unsupported or dynamic target resolution and target-local execution remain separate,
  evidence-gated work.
