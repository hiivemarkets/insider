# Live summaries name their exemplars and losses, trends have a fixed schema, and a duration's scope is only declared

## Decision

- **Telemetry summary exemplars.** Each `telemetry.summary/v1` summary carries
  `"exemplars"`: at most the interval's 3 slowest candidates and its first
  error, each `%{"receipt", "roles", "duration_us", "error"}`, recorded in
  full before the summary with `attributes.exemplar_of`. A sample is a
  candidate when its one `:ets.update_counter/3` call shows it is the
  interval's first error, or one of the first 4 samples of the histogram
  bucket holding the running maximum. Ordinary candidates share the
  collector's bounded inbox; the first error takes a reserved path, one slot
  per kind per interval, so it is kept whenever it reaches the collector.
- **Loss is reported, never silent.** A summary carries `"exemplars_lost"`
  (its candidates lost before it was recorded: inbox full, normalisation
  failed, Recorder refused, or receipt unknown) and `"first_error_retained"`
  (`nil` without errors, `true` when the first error is an exemplar, `false`
  when it was lost). Candidates lost that way or arriving after their
  interval was summarised are counted in the gate and read as the gap
  `telemetry_exemplar_lost`. Both collectors' status maps count exemplar
  losses by reason: `exemplars_shed`, `exemplars_invalid`, `exemplars_late`,
  and `exemplars_unrecorded`.
- **A duration's scope is only declared.** `"duration_scope"` is
  `%{"measured_in", "declared", "emitter"}`. `measured_in` is `"handler"` or
  `"caller"` only for a kind the session lists in the start option
  `"telemetry_duration_scopes"` (observer `--telemetry-duration-scope
  KIND=handler|caller`, at most 16, each a summarised kind), and `"unknown"`
  otherwise. `emitter` reports only the context the exemplars were emitted
  in (`"otp_server"` with its module for an initial call `{M, :init, 1}`,
  `"process"`, or `"mixed"`). Nothing reads a scope from `emitter`. A
  declared handler series next to a declared caller series gets only the
  conditional note that, if both describe the same operation, the
  difference is time outside the handler, such as queueing.
- **`insider.live-trends/v1`.** `trends/2` (observer `trends`) reads a digest
  window and returns, per summarised Telemetry kind, each window's
  `started_at`, `ended_at`, `interval_ms`, `count`, `rate_per_min`,
  `errors`, `error_pct`, `p50_us`, `p95_us`, `max_us`, exemplar receipts,
  `exemplars_lost`, and `first_error_retained`, with the first-to-last
  change and direction; and per Logger burst (template fingerprint, call
  site fingerprint, level, and each level's overflow row) each window's
  count, rate, exemplar receipt, and losses. Units are fixed and listed
  under `"units"`: microseconds, events per minute as integers, whole
  percent of the count, milliseconds, and ISO 8601 UTC. A change is `flat`
  within 10% of its first value. Options: `"since"`, `"kinds"` (at most
  64), `"windows"` (1 to 500, default 60), `"human"`.
- **`logger_summary` projection.** `"logger_summaries"` rules count matching
  Logger messages per level, normalised message template (the first 160
  bytes, or a `{format, args}` message's format, with numbers, pids, and hex
  masked), and call site. At most 64 distinct keys are admitted per
  interval with a concurrency-safe counter; past that, each level folds into
  one overflow row and the folded distinctions are counted (a lower bound).
  Per interval the collector records at most one event per admitted key
  plus one overflow row per level, each with `"summary" => %{"count",
  "level", "template", "template_fingerprint", "call_site",
  "call_site_fingerprint", "call_sites", "exemplar_receipt",
  "exemplar_lost", "interval_ms", "window_started_at", "window_ended_at"}`;
  the overflow row has `"overflow" => true`, `"distinct_lost"`, and no
  template or call site. Lost burst exemplars read as `logger_exemplar_lost`,
  folded distinctions as `logger_summary_overflow`.
- **Disclosure.** Strict withholds summary and exemplar durations unless
  every name in `"duration_measurements"` is allowlisted, with one drop
  record per withheld value; an exemplar's path is `[key:attributes,
  key:summary, key:exemplars, index:N, key:duration_us]`, the `index:N`
  segment the redaction manifests already use for list elements. Strict
  withholds `duration_scope.emitter.module` and a burst's `template` and
  `call_site`, keeping both fingerprints. The template text is collected
  only in the rich profile.

## Why

An agent reading a p95 needs the events behind it, and a summary that
silently lost its first error under load is worse than no exemplar: the
first review saw a 257-sample interval with one error report three
non-error exemplars and no gap. Counting each loss where it happens, and
reserving the first error's path, keeps the summary honest about what it
could not keep without adding hot-path work.

Process identity was rejected as a scope signal. An OTP server can itself
call another server, so a duration emitted inside one can be caller time;
the review measured a 30 ms caller wait labelled as server callback time.
Only the code that emits the event knows what it timed, so the session
declares it, and two declared series still do not establish that they
measure the same operation.

Keying bursts by call site alone merged distinct failures logged through one
helper, and an unbounded key set let a dynamic metadata line grow the
table without limit. A template-and-call-site key with an admission cap at
ingress bounds memory, interval work, and exemplars, and reports what it
folded.

Integer units keep the trends document inside the plain-term contract. The
10% flat band sits above the 6.25% bucket precision so a percentile's
rounding never reads as a trend.

## Consequences

- The slowest exemplar is exact to within one histogram bucket; a slow
  sample that arrives after the maximum moved to a higher bucket is not a
  candidate. Choosing exemplars exactly would need per-sample work in the
  emitting process, which this forecloses.
- `duration_scope` without a declaration makes no handler or caller claim.
  Changing that needs an event contract that states what each event times.
- `distinct_lost` is a lower bound (hashed distinctions can collide), and
  an overflow row cannot name the templates it folded.
- Adding fields to `insider.live-trends/v1` is compatible; changing a unit,
  the flat band, or the series key needs a new schema version.
