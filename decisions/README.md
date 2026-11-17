# Decision log

Durable decisions that shaped Insider, one Markdown file per decision.

A decision record explains why a boundary sits where it does, so a later change
can move it deliberately instead of eroding it by accident. It is evidence about
intent, not an authorization: recording a decision never grants staging,
production, publication, or any other capability that a separate human gate is
required to give.

## Naming

```text
decisions/YYYY-MM-DD_snake_case_title.md
```

The date is the day the decision was taken. Filenames sort chronologically, and
that ordering is the log; there is no separate index to keep current.

## Structure

```markdown
# Sentence-case statement of the decision

## Decision

What was decided, in the present tense, precisely enough that a reader can tell
whether a future change violates it.

## Why

The reasoning and the alternatives rejected. Use `## Evidence` instead when
measurements, fixtures, or artifacts carry the argument, or `## Context` before
`## Decision` when the surrounding constraint has to be stated first.

## Consequences

What this makes true, what it forecloses, and what it explicitly leaves to a
later decision.
```

## When to write one

Write a decision record when a change:

- sets or moves a trust, packaging, authority, policy, or protocol boundary;
- denies, defers, or gates a capability;
- makes a schema, wire format, or public contract commitment; or
- accepts a constraint that a later change would have to revisit rather than
  simply edit.

Routine implementation, refactors, bug fixes, and performance work do not need a
decision record. Those belong in `CHANGELOG.md` when they have a release
consequence.

## Superseding

Decisions are append-only. To change one, add a new dated file that names the
decision it replaces and explains what new evidence or constraint forced the
change. Do not rewrite or delete a superseded record: the fact that the earlier
reasoning was held, and then abandoned, is itself the useful part.

The records were edited once, in place, before the repository went public, to
remove internal context. Append-only applies from then on.
