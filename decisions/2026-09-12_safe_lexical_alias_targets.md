# Safe lexical aliases can identify static candidate targets

## Decision

Interpret a deliberately small subset of visible Elixir alias forms when
emitting static ExUnit candidate targets. Scanner revision v4 accepts simple
aliases declared directly in the sole top-level module body or directly in the
enclosing test, setup, or function body, including an explicit `as:` name, only
when the declaration precedes the call and the local name is never rebound.
Visible chained aliases are interpreted in declaration order.

An alias-derived target is always `syntactic`, even when the application call
is root-qualified. Without macro expansion, a source scanner cannot prove that
a `use` or other macro did not alter the alias environment. A multi-segment key
with no visible declaration therefore remains unresolved rather than being
treated as an absolute module name.

Aliases nested below the directly enclosing body, grouped aliases, multiple
top-level modules, rebinding, computed terms, and unsupported syntax remain unresolved. The
scanner parses executable AST but does not compile, load, macro-expand, or
evaluate adopter code. Target strings do not create atoms and contain no
configured values.

## Evidence

An evaluation against a real application produced two new
application-environment findings from passing test modules. The candidate
inventory found and ranked both, and the packaged value-free oracle confirmed
both state changes, but their module key identities were unresolved alias
forms. The agent had to reopen the source and translate each key manually.

Against those same pinned source files, scanner revision v4 emitted a direct
syntactic application/module-key hint for the visibly aliased target while
leaving the other macro-sensitive module form unresolved. This reduces repeated
translation without representing an unexpanded alias as runtime fact.

## Consequences

- Agents can use this common target class as input to a separately selected
  oracle after validating the artifact's explicit syntactic-alias caveat.
- Candidate identities and the configuration fingerprint change with scanner
  revision v4.
- Unsupported lexical cases fail closed to `unresolved/dynamic_identity`.
- Alias resolution remains a static hint; runtime confirmation, provenance
  binding, command execution, and defect promotion remain separate work.
