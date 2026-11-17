# Live baselines hold hashed identities behind the digest gates

## Context

`2026-10-26_live_anomalies_fold_a_known_normal_baseline_and_leave_out_observer_traffic.md` stored each baselined anomaly's `signature` text and a rounded `measure`. A review found that a baseline could hide something new:

- A signature taken from a rich Logger message (an email address) stayed readable after the host narrowed to strict, and in a denied environment.
- A crash loop's signature named only its offender, so a different reason was hidden.
- Folding only the top mailbox, wait, or error hid a new one below a known maximum.
- Rounding rates to whole events per hour defeated the 10x rule at low rates.

This record supersedes the earlier record's `signature`/`measure` fields and its folding order. The rest of the earlier record stands.

## Decision

- **Opaque identities.** Each anomaly has an `identity`: the first 16 hex digits of a SHA-256 over its kind and what it is about. That covers a crash loop's offender and reason fingerprint, an error signature, a wait's method and path, a mailbox's process, a key, a burst's source.
  - Each anomaly also has a `count`, with `span_ms` for a `rate` (at least a minute) or `level`.
  - A baseline stores only `kind`, `identity`, `count`, `span_ms` and `unit`, so no profile narrows it.
- **The digest's gates.** Baseline operations pass the gates a digest read does.
  - Set, show and clear are refused in a denied environment, and on a running session they renew its lease.
  - `status` reads the baseline observing: it is refused where observation is not allowed, and never revokes or renews.
- **Folding per candidate.** Every qualifying candidate (each wait from 1 s, each error signature from 5, each mailbox from 100) is folded against the baseline first. Only then is the top new one of each kind chosen.
- **Building a baseline.** A baseline is built from every candidate in the window, and keeps the earlier entries the window does not have, up to 64.
- **Unrounded comparison.** Rates are compared by cross-multiplying counts and windows. Only the displayed rate is rounded.

## Why

A baseline exists to put what is new first. It must never hide what is new, and it must never become a side channel that outlives the profile and environment the evidence was read under. Hashed identities match the same thing again without holding any of it.

## Consequences

- `baseline --show` lists kinds, hashed identities and rates. To see what they hide, use `digest --show-baseline`, which goes through the current profile.
- An identity computed under rich differs from one computed under strict when a name is withheld under strict. After narrowing, a rich-baselined anomaly shows again rather than staying hidden.
- An anomaly's `signature` and `measure` fields are replaced by `identity`, `count`, `span_ms` and `unit` (unreleased, so no shim).
