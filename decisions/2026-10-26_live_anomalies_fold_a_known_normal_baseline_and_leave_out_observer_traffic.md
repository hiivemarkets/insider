# Live anomalies fold a known-normal baseline and leave out observer traffic

## Context

In testing, the digest's anomalies were mostly dev noise: a restart loop of a key fetcher, and Tidewave's own MCP requests. The agent wrote "digest anomalies are env noise" and found no lead. An anomaly list that is always the same trains a reader to skip it.

## Decision

- **Every anomaly has two new fields.** A `signature` holds its kind and what it is about (an offender, a key, an error signature, a route); it never holds a value. A `measure` is a whole count per hour of the window (at least one minute), or a level.
- **`baseline` marks anomalies as known-normal.** It records the signatures and measures of a window's anomalies as known-normal for the session (`insider.live-baseline/v1`).
  - At most 64 signatures.
  - The session keeps the baseline for its life and its read-only window.
  - `--show` reads it, and `--clear` removes it.
  - A window with no anomalies leaves the baseline unchanged.
- **Digests and `status` fold baselined anomalies.**
  - They lead with the new anomalies.
  - The baselined ones are counted in one line, and listed with `--show-baseline`.
  - A baselined anomaly whose measure reaches 10 times its baseline comes back, saying so.
- **Observer traffic is set apart.** Requests to an observer's own endpoint (`/tidewave`) are counted in `requests.observer` and left out of the request waits and bursts. This needs a rich profile, because only then do requests have paths. The text says so once.

## Why

A reader acts on the first line it reads. Folding what the reader already knows, and saying so in one line, keeps that line for what is new without hiding anything. The 10x rule keeps a known noise from masking a real change in it. The observer's own calls are the agent's own tools, not the app's behaviour.

## Consequences

- `insider.live-baseline/v1`, the anomalies' `signature` and `measure`, and the digest's `anomalies_known`, `baseline` and `requests.observer` fields are public contract.
- A signature in the baseline hides a new anomaly with the same identity until it reaches 10 times its baseline. Readers clear the baseline when the environment changes.
- Under strict, requests have no path, so observer requests count with the app's.
