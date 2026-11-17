# The live welcome opens with an agent quick start and is delivered once per node incarnation

## Decision

- **Quick start by default.** `Insider.Live.welcome/1` (and the observer's
  `welcome`) returns a short agent quick start by default: numbered steps,
  the five core observer commands with real flags, the first-contact
  `--load` command, symptom recipes, a pointer to the full reference, and
  `runtime`. `welcome(%{"full" => true})` (`welcome --full`) returns the
  whole reference, which also holds the quick start and recipes. Both carry
  the full reference's hash.
- **Each form has its own schema.** The quick start is
  `insider.live-welcome-quick-start/v1`; the full reference is
  `insider.live-welcome/v2`. Version 1 was what the default `welcome`
  returned, so a consumer of v1 that calls the default now sees a different
  schema instead of a v1 document with its reference fields missing. A
  reader tells the forms apart by `schema`, never by which fields are present.
  A pointer (in `capabilities`, or the observer's later commands) advertises
  the quick start's schema, which its `read_with` commands return, and its
  `full_reference` advertises v2; both carry the full reference's hash.
- **Recipes name what is missing.** A symptom Insider cannot show yet (a
  growing mailbox, unknown event names) is a recipe with `status`
  `not_available` and a note that it is planned, instead of being left out.
- **One table per observer fact, in the welcome.** Every observer flag's
  value syntax and the `Insider.Live` option it sets, the observer's error
  codes with their statuses and exit codes, and each command's summary and
  examples live in `Insider.Live.Welcome`. The Lab observer reads its error
  codes and exit statuses from there and builds `--help`, `help OPERATION`,
  and every `invalid_options` hint from the same tables.
- **One name for malformed options.** The observer's own code is
  `invalid_options`, like the target's; `source` and the exit status tell
  them apart. Every observer `invalid_options` names the flag, the problem,
  and the expected value or accepted flags; a target `invalid_options`
  passing through the observer gains the flag that set its `field` and that
  flag's syntax. The observer's own argument errors and `non_loopback_host`
  never echo the value: it may be a secret typed into the wrong place. An
  unknown flag is named only when it is shaped like a flag name, and a
  positional argument is never named. Errors the target returns pass through
  unchanged and can name a value they reject (`unknown_telemetry_event`
  names the event); that is outside this rule.
- **Delivery per node incarnation.** The observer records welcome delivery
  per node name and distribution creation (`:erlang.system_info(:creation)`
  on the target), and printing `welcome` counts as delivery. A restarted
  node with the same name gets the quick start again; records without a
  creation are ignored.

## Why

An agent new to Insider rated the welcome 3/5: an 18 KB reference in
alphabetical key order with the guide in the middle, no observer value
syntax, a `--help` that was a usage error, and an `invalid_option` code
missing from the documented `invalid_options`. Its first useful actions
(start, read, stop, opt into measurements) fit in twenty lines. The
delivery record was keyed by node name only and outlived node restarts, so
a second agent, or the same agent after a restart, got a pointer instead of
the document it was promised, and `welcome` itself did not count, so the
next command repeated the whole document.

## Consequences

- A quick start, recipe, or example command that no longer parses with the
  observer's parser fails the Lab suite, as does an observer switch without
  a value-syntax row.
- The default welcome changes shape; callers that need `operations` or
  `options` pass `%{"full" => true}`.
- Every observer on a machine shares the delivery record in the reports
  directory, so a second agent on the same node incarnation gets a pointer;
  `welcome` prints the quick start at any time.
