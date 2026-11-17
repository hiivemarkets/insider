# Agent-requested candidate inventory is Lab-only

## Decision

Expose a bounded ExUnit source inventory through the non-published Lab project.
The calling agent requests a scan, selects a candidate, and owns the
investigation strategy. Insider does not run continuously, choose the next
candidate, maintain a work queue, execute tests, or invoke a coding model.

The inventory emits only candidates supported by executable-AST source signals.
It never promotes a static correlation to a confirmed runtime failure. Source
and scanner configuration are fingerprinted, and every bounded omission or
unsupported source remains visible.

## Evidence

An early evaluation against a real application showed that the root Runtime
API could inspect an explicit process with bounded evidence, but an agent had
no operation for finding likely test-isolation targets. An initial line-based
inventory also matched code examples inside strings and missed tests built on
application case templates. Parsing the AST eliminated the observed string
false positive and expanded coverage to the actual test architecture. Quoted
syntax is ignored, and cleanup is credited only when it names the same
application key or Telemetry handler as the mutation within the same lexical
test, setup, or function scope.

The same evaluation exceeded the initial 16 MiB default after scanning only part
of a large test tree. The default is therefore 64 MiB, still a hard maximum,
with explicit byte and truncation accounting.

Adversarial review found that wildcard traversal could enumerate through a
directory symlink before rejecting the resulting file. The inventory now walks
with `lstat`, never descends through symlinks, stops after proving a file-limit
overflow, reads at most one sentinel byte beyond the remaining allowance, and
has a caller-visible deadline. Parsing uses a static-atom encoder so untrusted
identifiers cannot consume the VM-global atom table. The target must be a stable
local checkout; concurrent tree mutation remains outside this slice's trust
boundary.

## Consequences

- The production root artifact remains free of source scanning and Mix-task
  orchestration.
- Candidate output is useful for agent prioritization but requires a separate
  runtime oracle before confirmation.
- Target readiness, target-local capture, detector confirmation, and reusable
  cross-run receipts remain later evidence-gated slices.
- Source-target identity and cleanup-shape depth can be expanded only when real
  evaluation results justify them.
