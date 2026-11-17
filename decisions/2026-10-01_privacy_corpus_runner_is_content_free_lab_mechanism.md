# Privacy corpus runner is a content-free Lab mechanism

## Context

The production-readiness dossier lists, as a blocking gap, running an
application-specific privacy corpus through the exact Logger and Telemetry
ingress allowlists and reviewing every retained or exported field. The corpus
content belongs to the adopting application and the review belongs to its
security and privacy owners. Neither can be supplied by this repository, but a
reviewer needs a repeatable way to see exactly which field names the denied
staging and production profiles let through, without the mechanism itself
becoming a second copy of the allowlists or a channel that exports values.

## Decision

Ship `Insider.Lab.PrivacyCorpus` and `mix insider.privacy_corpus` in the
non-published Lab project only. The runner takes a caller-supplied
`insider.privacy-corpus/v1` map of synthetic Logger and Telemetry items plus a
declared canary-token set and an `IngressProfile` environment. Every item is
handed to the real `Insider.Collector.Logger.Handler.log/2` and
`Insider.Collector.Telemetry.Handler.handle_event/4` with the Logger settings
the collector derives from that profile and the caller's exact
`Insider.Collector.Telemetry.Policy`; no allowlist is reimplemented. The
report, `insider.privacy-corpus-report/v1`, carries retained field paths,
bounded suppression counts, the union of retained paths, and canary hits as
`{index, field}` coordinates. Beyond those it carries only each item's source,
disposition, and handler-classified event `kind`, the caller's policy `id` and
fingerprint, the environment, Logger settings, profile and corpus
fingerprints, bounds, and fixed control and limitation names. It never carries
the value of a retained field.

Inputs are bounded to 4,096 items, 65,536 external bytes per item, and 32
tokens of at most 128 bytes. Unknown item shapes, undeclared keys, and declared
tokens that occur nowhere in the items fail closed. Corpus keys and event-name
segments are renamed only to atoms that already exist; an embedded JSON policy
whose names do not resolve fails closed, and the Mix task loads Insider's own
modules first so the resolvable set does not depend on prior task activity.
The task exits `0` with no hits and `2` with hits.

## Why

- Calling the collector handlers directly is the only way to exercise the
  denied profiles, because the supervising collectors refuse to start under
  staging and production. The core tests already use this path.
- A second allowlist implementation in Lab would drift from the core and turn
  the report into evidence about Lab rather than about Insider.
- Reporting names, kinds, and coordinates, never retained values, keeps a
  report safe to share with reviewers even when a corpus deliberately contains
  sensitive-looking fakes.
- Rejecting a token that occurs nowhere in the items prevents a vacuous "no
  hits" result.
- Creating atoms from a corpus file would make a diagnostic artifact an
  atom-table mutation surface; existing-atom resolution matches the Lab
  oracles. The cost is that an application's own policy must be supplied as a
  struct from a VM where that application is loaded.
- Alternatives rejected: a root-artifact runner (the production artifact must
  not read files or carry Lab tooling), a Logger or Telemetry collector started
  in a development profile (its Logger settings differ from the denied
  profiles), and a separate policy file flag (the corpus and its allowlist are
  reviewed together).

## Consequences

- Reviewers can enumerate the exact retained field paths for the denied
  profiles from a committed example and from their own corpus.
- Hashed, truncated, and charlist-encoded derivatives are not substring-matched;
  tokens should be short literal strings.
- The runner does not exercise Recorder classification, redaction, lifecycle
  health, or the supervised session; those remain covered by their own tests.
- The Telemetry event assembly is mirrored from the collector so field paths
  match the recorded Event; a live-collector drift test pins that mirror.
- The application corpus, the field review, and any approval remain human
  work. A report with no hits is bounded evidence about the supplied items and
  grants no staging or production authority.
