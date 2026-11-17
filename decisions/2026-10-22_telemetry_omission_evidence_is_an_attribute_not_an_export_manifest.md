# Telemetry omission evidence is an attribute, not an export manifest

## Context

`2026-10-22_live_severity_comes_from_failure_shapes_and_unselected_values_leave_drop_records.md`
had the Telemetry collector write a `drop` record into each recorded event's
`redactions` for what its allowlist policy did not record. A review of the
stacked branch found that this breaks incident capsules. `Event.redactions`
is the export authority's manifest, and the capsule boundary
(`Insider.Incident.Source`, `Insider.Incident.Capsule`) requires it to be
empty on recorded events. So one unselected metadata key made a whole
snapshot unexportable. A second review found that the evidence could also
push an event past Event v1's attribute bound and lose the event.

## Decision

This supersedes the "Drop records at collection" choice and its consequence
in that record. Everything else in it stands.

- **Where the evidence lives.** The collector records omission evidence in the
  event's `"omitted"` attribute (`Insider.Collector.Telemetry.Omitted`). It
  holds:
  - the policy id;
  - the exact numbers of withheld measurements and metadata keys;
  - the withheld measurements that the `nameable_measurements` option lists.

  The attribute is present only when something was withheld. `Event.redactions`
  stays empty, and the capsule boundary's rule is unchanged.
- **The evidence never costs the event.** If the names do not fit Event v1's
  attribute bound, the event is recorded with the counts alone. If even those
  do not fit, it is recorded without the evidence, and the collector's
  `omissions_unrecorded` status counts the loss. Live reports that count as
  the `telemetry_omissions_unrecorded` gap.
- **Live lifts the evidence.** `Insider.Live.Disclosure` turns well-formed
  evidence into the same `drop` records in the read entry's `redactions`, and
  removes the attribute. Malformed evidence, including a present `nil`, is
  withheld whole with one boundary drop record.

## Why

Omission evidence and export manifests answer different questions. The
first says what a collector never recorded. The second says what an export
authority removed from recorded data. Capsules rely on recorded events
carrying no caller-asserted export manifest, so collection evidence must not
use that field. An attribute is ordinary, bounded, validated event data that
any consumer can read or ignore. Recording the event first and its evidence
second keeps the evidence from ever costing the evidence it describes.

## Consequences

- A Telemetry event that left something out carries an `"omitted"` attribute
  of at most about 1.2 KB. Consumers other than Live see it as an attribute.
- An event saturated with selected fields may carry no omission evidence; the
  loss is counted, never silent.
- The Lab privacy-corpus runner mirrors the attribute. Its retained-field
  report therefore lists the evidence's counts and policy id, never withheld
  names or values.
