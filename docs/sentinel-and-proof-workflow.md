# Sentinel and the proof workflow

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The Lab-only Sentinel: the collector-to-Sentinel handoff, scenarios, sandbox
leases, confirmation, verification, regression, minimization and bisection,
then the offline repair chain from coding-agent handoff to draft proposal.

## Contents

- [Collector-to-Sentinel handoff](#collector-to-sentinel-handoff)
  - [Manifest](#manifest)
  - [Scenarios](#scenarios)
  - [Sandbox lifecycle](#sandbox-lifecycle)
- [Confirmation and verification](#confirmation-and-verification)
  - [Confirmation](#confirmation)
  - [External process](#external-process)
  - [Exit-status telemetry](#exit-status-telemetry)
  - [Verification](#verification)
- [Regression and minimization](#regression-and-minimization)
  - [Regression](#regression)
  - [Minimizer](#minimizer)
- [Bisection](#bisection)
  - [Bisection search](#bisection-search)
  - [Bisection record](#bisection-record)
- [Proof workflow](#proof-workflow)
  - [Complete proof](#complete-proof)
  - [Coding-agent handoff](#coding-agent-handoff)
  - [Repair report](#repair-report)
  - [Draft proposal](#draft-proposal)
- [Draft creation and source ownership](#draft-creation-and-source-ownership)
  - [Draft creation](#draft-creation)
  - [Source ownership](#source-ownership)
- [Deduplication](#deduplication)
  - [Dedup ledger](#dedup-ledger)
  - [Dedup receipts](#dedup-receipts)

## Collector-to-Sentinel handoff

The collector-to-Sentinel handoff is a separate, thin reference. It is not a
second copy of the evidence.

### Manifest

```elixir
scenario = %{
  "status" => "available",
  "fingerprint" => scenario_fingerprint
}

{:ok, manifest} = Insider.Sentinel.Manifest.new(capsule, scenario)
{:ok, bytes} = Insider.Sentinel.Manifest.canonical_binary(manifest)

# At untrusted Sentinel ingress, validate both documents together.
{:ok, manifest} =
  Insider.Sentinel.Manifest.validate_with_capsule(manifest, canonical_capsule_bytes)

# Readiness also requires and validates the exact capsule evidence.
{:ok, readiness} =
  Insider.Sentinel.Manifest.readiness(manifest, canonical_capsule_bytes)
```

The manifest binds the exact canonical capsule ID, byte size, and full-byte
digest. It correlates code, configuration, dependency, runtime, and target
states to capsule provenance. It keeps unavailable and policy-redacted
prerequisites distinct. Its fixed policy permits confirmation only and
prohibits source mutation. It requires a disposable target and requires
cleanup. These serialized claims are never authority. The external runtime
must independently prove its environment and target class, and it must
authorize every effect.

### Scenarios

A portable reproduction scenario pins one exact semantic contract. It
describes a bounded reset, ordered actions, observations, semantic waits, a
seed, and expected finding fingerprints. Scenarios are data-only recipes.
External strings resolve only through a trusted contract-module allowlist.
Sentinel separately authorizes every callback on a disposable target.
Scenario completion means only that the recipe ran. Clean-target confirmation
must still observe the expected detector output. Cancellation stops future
work and attempts the final reset. It never claims to roll back mutations or
to prove independently that all resources were cleaned.

### Sandbox lifecycle

Sentinel's sandbox lifecycle keeps portable target data separate from
platform authority. A bounded trusted provider allowlist supplies resource
mechanics. The core owns authorization, deadlines, owner leases, cancellation,
provenance comparison, and cleanup ordering. The core does not itself invoke a
shell, filesystem, network, node, container, or cloud API. A lease is complete
only after independent owner inventory is empty. When the inventory is
non-empty or unavailable, the lease stays partial or uncertain and
quarantined. Sentinel does not report it as reclaimed.

**Body modules.** The host can configure an optional, bounded allowlist of
body modules. A body module is trusted work that runs after exact provenance
observation and before cleanup, on the same owner lease. Portable documents
never select body modules or carry callbacks. Runs without a body keep the
acquire-observe-cleanup lifecycle.

**Body receipts.** A body receipt is the bounded record that a body returns
when it ends. Provider cleanup begins only after a valid bounded body receipt
and observed body-owner termination. Without that terminal evidence, the lease
stays quarantined with uncertain cleanup. The lease registry records the body
before its start gate opens. So an abrupt runner death cannot race a surviving
body against provider cleanup. On shutdown, the executor forcibly stops and
observes registered bodies before its bounded provider cleanup pass.
Sandbox results keep bounded terminal body receipts even when cancellation,
body failure, timeout, or later cleanup makes the operational result
non-successful. So the domain finding is not erased. Result v1 deliberately
permits bounded partial values for every non-success status, including
`unsupported`. Protocol errors and status stay authoritative. A partial value
is evidence, never a success signal.
Cooperative body stopping uses the earlier of two times: the configured grace
from the stop request, and the absolute cutoff reserved before provider
cleanup. So delayed Runner handling cannot silently grant a fresh grace
period.

## Confirmation and verification

### Confirmation

The Lab-only `Insider.Sentinel.Confirmation.run/6` is the first in-process
clean-target confirmation seam. Before any provider effect, it validates the
exact manifest, capsule, scenario, and target provenance together. It requires
the capsule's primary finding in the scenario's expected set. A trusted,
allowlisted target adapter then arms its fixed observer. It executes the
scenario against the live owner lease and finalizes a run-correlated bounded
receipt.
The canonical record distinguishes five outcomes: matching failure, repaired
(only through a configured positive oracle), unrelated failure,
nonreproduction, and infrastructure failure. Confirmation also requires exact
observed target provenance, complete zero-loss evidence, and complete
inventory-backed cleanup. This proof of concept proves the same-owner
in-VM/adapter boundary.

### External process

A private, bounded external-process primitive extends that proof across an
OS-process boundary. It uses a host-fixed provider, profile, and body. The
executable, argument template, provider, body, environment, working directory,
and cleanup implementation stay trusted host configuration. Portable data
cannot select them.
Actual arguments must exactly equal the profile's declared public fingerprint
projection. The runtime does not infer whether arbitrary profile-supplied
bytes are secret. So the trusted profile and the host allowlist stay
responsible for public-only arguments. Durable command fingerprints exclude
environment values and their hashes.
The process emits one strict canonical machine report. The report binds the
sandbox-issued owner fingerprint, observed target fingerprint, scenario,
expected finding, observer, result, and arm/scenario/finalize ordering. The
runner discards raw stdout and stderr. Only the validated report and its
digest enter confirmation v2 or verification-receipt v2 evidence. A nonzero
exit can be valid failing-before evidence when the exact report carries the
expected finding. Verification v2 requires exit zero.
The body does not return until its direct Port is down. The provider's
independent owner inventory stays authoritative for lease cleanup. SHA-256
provides content identity, not authenticity. Insider trusts a report only
through the configured adapter that produced and validated it. Adopter
adapters must pin their source and dependency inputs and isolate each attempt.
They must verify cleanup and must not keep credentials, raw output, or
temporary paths. They are trusted proof adapters, not general command runners
or production executors.

### Exit-status telemetry

When the runner observes the direct exit status, it emits
`[:insider, :sentinel, :external_process, :exit_status_observed]` exactly
once. The measurement is `%{count: 1}`. The metadata holds only the validated,
host-issued `owner_fingerprint` needed to distinguish concurrent runs. The
event exposes no command, PID, raw lease, path, or environment value.
This event does not claim Port-down or process-group state. It does not
identify a descendant, prove a leak, or grant cleanup authority. A clean
verdict still requires exit status, Port-down, and a negative process-group
probe. The runner classifies a probe as `alive` only after a successful
liveness probe. It classifies it as `down` only on the fixed C-locale
`No such process` diagnostic. Permission, execution, and unrecognized probe
failures stay `unknown` and fail closed for cleanup.
Telemetry handlers execute synchronously. Their work consumes the existing
logical deadline and cannot refresh it. But a slow or stuck handler can delay
timeout, cancellation, and owner-down handling beyond that deadline. So hosts
must treat handlers for this event as trusted, bounded runtime code.

### Verification

The Lab-only `Insider.Sentinel.Verification.run/7` owns the complete bounded
verification sequence. It executes exactly two fresh live confirmations
against the regression baseline. It does not dispatch candidate work unless
`Regression.classify/2` reports `failed`. It then performs exactly two
independent post-repair sandbox runs through a host-allowlisted body module.
The portable candidate contains only a fixed format name and at most 16 KiB of
opaque bytes. It cannot select a module, command, or path. Each successful
verification receipt binds the candidate and regression to the exact scenario,
observer, oracle, owner, and target. It also binds independently observed
post-repair provenance, zero-loss evidence, and passed static, runtime, and
resource gates.
The canonical verification record is `verified` only when both live
post-repair attempts observe no failure. They must agree on changed code and
on unchanged configuration/dependencies/runtime/target provenance. They must
carry distinct positive oracle receipts. They must clean up completely and
leave the executor at zero active and quarantined leases.
Otherwise the record is a canonical `invalid` record with sorted
machine-readable reasons. SHA-256 is content identity, not authenticity. A
trusted host must produce and execute the live runs, and it must independently
allowlist the candidate body. Neither candidate bytes nor an offline record
grant execution authority.
Opaque candidate bytes can contain arbitrary text, including paths or
commands. This text is data, not authority. Only the host-selected body
defines an interpretation. The whole sequence shares one validated request.
Its `deadline_monotonic` stays the single absolute deadline. Later phases do
not receive a refreshed timeout budget.

## Regression and minimization

### Regression

The Lab-only `Insider.Sentinel.Regression` materializes a canonical, data-only
regression recipe. It takes one exact eligible confirmation record and its
exact portable scenario. It embeds both validated wire documents. It derives
the expected incident fingerprint and the trusted observer identity. It fixes
a two-run, disposable, mutation-prohibited, cleanup-required execution policy.
The artifact has no commands, callbacks, paths, generated source files, or
caller policy knobs. Its SHA-256 address gives deterministic identity. It
gives integrity when you compare it with a separately trusted digest. It does
not give authenticity. Materializing the recipe does not prove that the
incident failed again.
The Lab-only `Insider.Sentinel.Regression.classify/2` evaluates exactly two
structurally and semantically valid canonical confirmation records. It reports
`failed` only when both distinct observation runs bind the same source
capsule, manifest, scenario, expected incident, observer, and exact baseline
target, with complete evidence and cleanup. These cases are inconclusive:
reuse of the embedded source record or its observation-run identity, and
duplicate, incomplete, unrelated, nonreproduced, repaired, or cross-bound
runs.
Classification does not authenticate who produced a record. It does not prove
that the asserted execution really occurred. Durable failing-before proof
requires a trusted runtime to execute the scenario and observer and produce
the live records. The integration suite shows that workflow with one live
source confirmation followed by two fresh live confirmations. Positive
passing-after repair proof stays a separate verification responsibility.

### Minimizer

The Lab-only `Insider.Sentinel.Minimizer.run/6` reduces a confirmed regression
without inventing executable forms. Version one considers only deterministic
deletion of whole existing scenario steps. It preserves each kept step's exact
bytes and order. It also preserves the contract, seed, reset, expectation,
and limits.
The original regression must first fail in two fresh confirmations. Then each
candidate runs in three fresh disposable confirmations. The first
materializes a candidate regression. The other two must satisfy
`Regression.classify/2`. Three clean nonreproductions reject a deletion. Mixed
matching and nonreproduced outcomes stop as nondeterministic. Infrastructure,
evidence, or cleanup uncertainty stops as inconclusive.
The search is a bounded greedy restart-after-accept algorithm. Its duration
ceiling covers the effectful execution-search phase, from the clean-executor
preflight through final cleanup. Bounded input validation and final pure
canonical/evidence validation are outside that measured interval. Completion
means only that no single remaining whole step can be removed under that
policy. It does not claim a globally smallest reproducer. Candidate or
duration exhaustion returns the best regression found so far, with
`not_proven` minimality.
The canonical minimization record declares that duration scope. It keeps the
policy, attempt counts, search elapsed time, per-run and aggregate event/byte
ceilings, and trial decisions. It also keeps referenced confirmation
identities, final cleanup counts, and uncertainty. The live result returns
every referenced confirmation record to its caller.
Standalone record validation proves canonical structure and internal sequence
coherence. `validate_with_evidence/6` recomputes the source, target, candidate
manifests, fresh-record decisions, and final regression from the complete kept
graph. The confirmation, manifest, capsule, and regression artifacts stay part
of that graph. SHA-256 gives content identity, not authenticity. Argument
shrinking and StreamData-derived inputs stay future schema work, not an
implicit runtime dependency.

## Bisection

### Bisection search

The Lab-only `Insider.Sentinel.Bisection.run/6` binary-searches a confirmed
regression. It searches over a host-declared ordered list of two to sixty-four
disposable sandbox targets, oldest to newest. Insider never reads a
repository, orders revisions, checks anything out, mutates source, or uses a
network to get that list. The record pins those controls as
`repository_read=none`, `checkout=none`, `source_mutation=prohibited`,
`git_authority=none`, and `network_effect=none`.
Bisection first proves both endpoints with two fresh confirmations each. The
oldest must not reproduce and the newest must. Otherwise the record is
`inconclusive` with reason `baseline_not_bracketed`. Each midpoint then runs
two fresh confirmations through the same `Confirmation.run/6` path. Mixed
clean outcomes at one index stop as `probe_nondeterministic`. Infrastructure,
evidence, or binding uncertainty in a probe stops as `probe_inconclusive`. An
index whose first probe is not clean stops there without a second probe. An
executor that reports active or quarantined work after any probe or at final
cleanup stops as `executor_not_clean`. An executor whose counts the search
cannot get before the deadline stops as `executor_state_unknown`.
A probe is clean only when its requested and observed target fingerprints both
equal the declared target it was dispatched to.

### Bisection record

A completed bisection record isolates one adjacent pair of declared targets on
the search path: `boundary_nonreproduced_index` and
`boundary_reproducing_index`. It carries the declared target identity and
fingerprint at the reproducing index, and `proof=adjacent_boundary_isolated`.
The search never probes indices off its binary-search path. So reading that
pair as the earliest reproducing target is the host's assumption that outcomes
are monotonic across its list. Bisection does not detect a regression that was
fixed and later reintroduced earlier in the list. The record's fixed
`limitations` state `outcome_monotonicity_is_a_host_assumption`,
`indices_off_the_search_path_are_not_probed`, and
`target_causality_is_not_claimed`. The record does not claim that the target
caused the failure.
Probe or duration exhaustion returns the best-known
`[boundary_nonreproduced_index, boundary_reproducing_index]` bracket with
`proof=not_proven`. As in the minimizer, the duration ceiling covers the
effectful search from the clean-executor preflight through final cleanup. The
live result returns every referenced confirmation record.

**Cleanup.** The record's `cleanup` carries the executor counts observed when
the search stopped. It is `complete` only when both counts were observed as
zero. Otherwise it is `incomplete` or `unknown`, with the matching executor
reason. When a confirmation returns a protocol error, the search returns that
error with `bisection_cleanup` and `bisection_confirmation_runs` details
instead of a record. When the search cannot get executor counts at the
preflight or at a post-probe count check, it stops as `inconclusive` with
`executor_state_unknown` and `unknown` cleanup. An exception or exit that
escapes the search itself (for example from a provider) surfaces as
`operation_failed` with no cleanup count at all. Teardown belongs to the
sandbox runner, not to the search.

**Validation.** Standalone record validation replays the recorded trials as
one deterministic search path over the recorded target list.
`validate_with_evidence/6` also binds the source regression, capsule,
manifest, the exact ordered targets, and every referenced confirmation record.
It rederives each index decision from the records it references.
Confirmation binds every target's five prerequisite fingerprints to the
manifest. So targets in one list currently share the capsule's provenance
fingerprint and differ by provider identity. A confirmation record carries
fingerprints but not a target identity. So when fingerprints coincide, the
evidence graph binds each probe to its declared fingerprint, not to one
declared target id. The design boundary is recorded in
`decisions/2026-10-01_bisection_is_offline_over_declared_targets.md`.

## Proof workflow

The synthetic fixture harness covers restart storms, growing mailboxes, leaked
tasks, late effects, incomplete Telemetry spans, invariant failures, and
recorder overload. Each failure has a nearby healthy control and uses per-run
identities. Each synchronizes without sleeps and completes deterministic
cleanup. Adopters can extend the same bounded workflow to their own isolated
fixtures:

```text
known failure or flaky test
-> structured detection
-> bounded causal incident capsule
-> clean-target reproduction
-> failing regression
-> candidate repair
-> passing-after verification
-> evidence-rich draft output
```

### Complete proof

The proof is complete only when all of these hold: the same bounded causal
fingerprint appears before the repair, and a regression fails before and
passes afterward. The healthy control stays quiet, and resources are cleaned
up. Overhead is measured, and an independent reviewer validates the evidence.

### Coding-agent handoff

Before a candidate exists, Lab can make one bounded, self-contained coding
agent handoff. The input is the exact confirmed regression and two fresh
matching failed confirmations:

```elixir
{:ok, handoff} =
  Insider.Sentinel.CodingAgent.Handoff.new(
    capsule,
    sentinel_manifest,
    regression,
    [first_failed_confirmation, second_failed_confirmation]
  )

{:ok, candidate} =
  Insider.Sentinel.Verification.Candidate.new(diff, "unified-diff/v1")

{:ok, submission} =
  Insider.Sentinel.CodingAgent.CandidateSubmission.new(handoff, candidate)
```

The handoff accepts no caller-authored instructions or causal claims. It
embeds the already bounded canonical capsule, manifest, regression, and fresh
runs. It fixes the requested output to the existing verification-candidate
schema. The submission only binds those inert candidate bytes to the exact
handoff. It does not invoke a model, run a command, or apply a patch. It does
not read or mutate a repository, use credentials or a network, or contact a
provider. It does not claim repair success. By itself it grants no
disclosure, publication, or draft-creation authority.
The intended chain is: confirmed source plus two fresh failures → handoff →
declared-unverified candidate submission → fresh isolated before/after
verification → repair report → offline draft proposal. A declared-unverified
submission is one that the agent declares as a fix but that no verification
run has checked yet. Verification never reuses the
handoff's earlier failure runs. Standalone decoding proves structure and
content identity. The `validate_with_evidence` functions recompute the exact
graph before a host passes the candidate into the separately authorized
verification path.

### Repair report

From verified evidence, Lab can produce a canonical repair-report manifest for
agents and deterministic Markdown for review. Lab recomputes the report from
the exact capsule, pre-execution Sentinel manifest, and Lab Sentinel
verification record. The report references all three cryptographically:

```elixir
{:ok, report} =
  Insider.Sentinel.RepairReport.Manifest.new(capsule, sentinel_manifest, verification)

{:ok, markdown} =
  Insider.Sentinel.RepairReport.render_markdown(
    report,
    capsule,
    sentinel_manifest,
    verification
  )
```

Standalone report validation proves canonical structure and content identity.
`validate_with_evidence/4` is the evidence-bearing operation. It validates the
three inputs and recomputes every derived field before it accepts the report.
The renderer calls that operation automatically. It accepts no
caller-authored causal or success prose. A valid but inconclusive verification
stays visibly `invalid`. You can still report it for diagnosis.
The report derives cleanup from the complete release/count/fingerprint
predicate, not from its coarse status field alone. Both tables show release
and remaining resource counts. The proof includes the final active and
quarantined executor counts. So a resource-leak verdict cannot look clean.
The report shows the candidate diff for review. The capsule's redaction policy
does not cover that diff. The bound machine manifest keeps its exact bytes,
and the Markdown normalizes whitespace-only lines. So reports are internal
artifacts until a future candidate-disclosure policy exists. SHA-256 provides
identity, not authenticity. A verified report proves only the declared bounded
scenario. It does not claim general freedom from bugs.

### Draft proposal

Lab verified evidence can also produce a canonical offline draft proposal:

```elixir
{:ok, proposal} =
  Insider.Sentinel.DraftProposal.new(
    capsule,
    sentinel_manifest,
    verification,
    report
  )
```

The proposal is an inert local artifact, not a created pull request. It
rechecks the five-run matrix, cleanup, gates, provenance, and exact evidence
identities. It contains no repository or provider operation. It records
`network_effect=none` and `repository_mutation=none`. It carries no disclosure
approval, so it cannot independently authorize provider creation. Standalone
proposal decoding proves only structure and content identity.
`validate_with_evidence/5` recomputes the proposal from the exact evidence
graph.

## Draft creation and source ownership

### Draft creation

Lab contains a fail-closed draft-creation boundary for host-integrated
providers. Effects are off by default. A host can enable them deliberately in
an isolated Lab process. Then the executor accepts provider and
disclosure-authority modules only from host configuration. Portable identities
select within that exact allowlist and can never resolve a module.
Before the disclosure-authorization or draft-creation callback runs, the
executor recomputes the verified proposal from its capsule, manifest,
verification, and repair report. It validates the exact coding-agent handoff
and candidate submission. It requires the proposal and submission to bind the
same candidate.
The configured authority must approve the exact provider-visible payload for
one destination fingerprint. The executor binds that decision into a
canonical request. The provider result becomes a canonical receipt. Every
request is draft-only and requires human review. It carries no credentials and
exposes neither merge nor deploy. This phase has no real GitHub or network
provider.

**Retries.** The executor bounds pending evidence admission and serializes
attempts. It keeps a bounded in-memory receipt cache. So exact sequential and
concurrent retries in one live executor return the same receipt. If a caller
selects a different disclosure authority for an intent already attempted, the
executor reports a visible conflict, not a cache hit.
This is not crash-safe exactly-once execution. Provider implementations must
enforce the supplied idempotency key in their own system. `created` and
`existing` are provider-reported, not independently verified remote state.
The executor keeps a provider timeout as `provider_outcome_unknown`, because
stopping the local callback cannot prove that no external effect occurred.
Staging and production stay disabled. They require separate human security,
privacy, and operations decisions.

### Source ownership

An eligible proposal can have a separate Lab-only source-ownership routing
companion. It accepts declaration bytes directly. It never reads a working
tree, Git metadata, or a repository. It derives paths only from the
proposal's exact `unified-diff/v1` candidate. It supports a deliberately
small, provider-neutral declaration syntax like CODEOWNERS. The last matching
rule wins, and unmatched paths stay unassigned:

```elixir
{:ok, routing} =
  Insider.Sentinel.SourceOwnership.new(
    proposal,
    """
    lib/insider/sentinel/** sentinel-team
    test/ test-team
    """
  )
```

Owner labels such as `sentinel-team` are opaque routing hints that the caller
declares. They are not verified people, provider principals, reviewers,
assignees, permissions, or authorization. The companion records
`assignment=prohibited`, `authorization=prohibited`, `mutation=none`, and
`network_effect=none`. Standalone decoding verifies only its structure and
content identity. `validate_with_proposal/3` recomputes it from the exact
proposal and exact declaration bytes. Unsafe, binary, rename/copy, malformed,
duplicate, or out-of-bound candidate paths fail closed and produce no routing
artifact.

## Deduplication

### Dedup ledger

You can deduplicate capsules before a proposal exists. The Lab-only
`Insider.Sentinel.Dedup` ledger first accepts exact canonical capsule bytes.
It then accepts a canonical proposal only after it recomputes the proposal
from its exact capsule, Sentinel manifest, verification record, and repair
report. It also requires that exact capsule to be already kept.
The ledger groups artifacts by a SHA-256 projection of the capsule finding
fingerprint. An exact canonical artifact is an idempotent duplicate. A
different content identity in that group is kept as new evidence. Distinct
finding fingerprints create distinct groups.

```elixir
{:ok, ledger} = Insider.Sentinel.Dedup.new()
{:ok, ledger, capsule_receipt} =
  Insider.Sentinel.Dedup.ingest_capsule(ledger, canonical_capsule_bytes)

{:ok, ledger, proposal_receipt} =
  Insider.Sentinel.Dedup.ingest_proposal(
    ledger,
    canonical_proposal_bytes,
    canonical_capsule_bytes,
    canonical_manifest_bytes,
    canonical_verification_bytes,
    canonical_repair_report_bytes
  )
```

The default ledger admits at most 32 groups and 8 total artifacts per group.
It admits a 2,097,152-byte single graph input, 2,097,152 retained canonical
bytes, and 256 retained-artifact receipt slots. A host can reduce all five
host-local limits at construction. Each has a hard upper bound. The Lab state
must keep canonical evidence bytes to revalidate itself, so it is internal
sensitive state. Only receipts are privacy-minimal.
The ledger has no eviction. A valid input that it cannot keep returns a
canonical `capacity_refused` receipt and leaves the ledger unchanged. The
receipt counter counts accepted unique artifacts, not attempts. So duplicate
and refused receipts are deterministic projections that do not mutate state.
Malformed, noncanonical, oversized, wrong-schema, integrity-forged,
graph-unverified, or proposal-to-capsule-unbound input fails before state
mutation.

### Dedup receipts

A dedup receipt contains only a hashed group ID, content-addressed capsule and
proposal references, a bounded `evidence_bytes` admission total, and bounded
counts. `evidence_bytes` is exactly the canonical evidence evaluated for that
receipt. For a capsule it is the capsule bytes alone. For a proposal it is the
capsule plus proposal, manifest, verification-record, and repair-report bytes.
With it, receipt validation proves that the reported retained capacity can
cover the admission. It does not expose those additional graph references or
their contents.
Duplicate and refusal receipts carry the same prospective or retained
admission total. Their counters still describe unchanged state. Receipts
contain no capsule or proposal body, candidate diff, finding payload,
secret-capable payload, provider, repository, network, Git, assignment,
authorization, or mutation field.
Standalone draft-proposal validation still proves only canonical structure and
content identity. A future handoff must revalidate its full evidence graph
before it treats the proposal as eligible evidence.
