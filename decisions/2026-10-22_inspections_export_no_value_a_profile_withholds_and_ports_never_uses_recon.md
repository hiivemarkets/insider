# Inspections export no value a profile withholds, and ports never uses recon

Supersedes these clauses of
`2026-10-22_inspections_use_recon_only_where_it_respects_protected_targets.md`:
"return at most 64 KiB", "`ports` counts types with `recon:port_types/0`",
"in strict, atoms only as tags", "the full name appears only in a `ports`
result under the rich profile", and the consequence "With recon on a node,
`ports` counts include Insider's own ports in `types`". The rest of that
record stands.

## Context

Four review rounds of the inspections found credentials and
values leaving the node: an atom value in a rich mailbox shape
(`{:password, :secret}`), the same shape kept in session history after the
host narrowed to strict, and credential arguments in port command lines
that escaped name-based masking through escaped quotes, nested shell
commands, leading dashes, line continuations, and tab-separated
arguments. They also found results over the 64 KiB bound, and
`recon:port_types/0` reading every port past the scan bound.

## Decision

- A mailbox shape shows an atom only as a tuple's first element (its tag),
  in every profile; any other atom, a bare atom message included, is
  `atom`. A shape is cut to 160 bytes of valid UTF-8.
- Inspection history is strict-safe when it is recorded: an `inspect.*`
  event holds no value the strict profile would withhold, so a host that
  narrows later exports the same events and the disclosure boundary needs
  no inspection rule.
- A port's command line, returned only in the rich profile, is masked
  structurally, not by recognising forms. It is split once at the first
  whitespace or control character into the program and the rest. The rest
  is masked whole when the command names a credential anywhere (as
  `Insider.Redaction.Credentials` defines them, quotes ignored) or holds
  anything a shell may rewrite (a backslash, any control character, `$`,
  or a backtick). When the program itself holds either, the whole command
  is masked. Nothing is kept after the program once the command is masked.
- The exported result, its masks, metadata, and session status included,
  is at most 64 KiB of canonical JSON: lists are cut longest first and
  counted in `omitted`, and free-form strings are bounded where they are
  read. A result whose fixed fields alone cannot fit is `unavailable` with
  reason `result_bytes`. Only that exported result is projected into the
  session.
- `ports` never calls recon: every field comes from one read of at most
  50,000 ports. Only `alloc` uses recon.

## Why

Command lines and Erlang terms cannot be parsed with confidence against
every shell and escape form; each review round found another. A rule that
masks everything after the program as soon as any doubt arises cannot leak
a later argument, whatever separates it. The cost is that a command line
naming a credential loses its harmless arguments too, which a debugging
agent can live without.

## Consequences

- A port spawned with `--password` anywhere, or with any escape, tab, `$`,
  or backtick, shows only its program (or nothing, when the program is
  ambiguous).
- Agents learn a message's structure and tag, never an atom value.
- `ports` counts exclude Insider's own ports on every node, with or without
  recon.
