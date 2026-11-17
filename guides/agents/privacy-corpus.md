# `mix insider.privacy_corpus`

A Lab-only, content-free mechanism for one gap the readiness dossier names: an
application-specific privacy corpus must be run through the exact Logger and
Telemetry ingress allowlists with every retained field reviewed. Insider ships
the runner; the corpus content and the field review remain human work. Values
below are copied from `tools/insider_lab/lib/insider_lab/privacy_corpus.ex`
and `privacy_corpus/cli.ex`.

## Invocation

```sh
(cd tools/insider_lab && mix insider.privacy_corpus \
  --corpus priv/privacy_corpus/example.json --environment production)
```

| Switch | Accepted |
|---|---|
| `--corpus` | path to one regular file of at most 16,777,216 bytes containing a JSON object |
| `--environment` | `production` or `staging` only; the task exists to test the denied profiles |

Both switches are required and may appear once. The function API,
`Insider.Lab.PrivacyCorpus.run/2`, accepts any `IngressProfile` environment
and an optional `telemetry_policy:` struct.

| Exit | Meaning | stdout |
|---|---|---|
| `0` | `status` is `no_canary_hits` | `insider.privacy-corpus-report/v1` |
| `2` | `status` is `canary_hits` | same report |
| `64` | invalid arguments or invalid corpus | `insider.privacy-corpus-error/v1` with `status` `invalid_input`, a `reason` such as `invalid_arguments`, `corpus_too_large`, `corpus_unreadable`, `invalid_json`, `invalid_corpus`, `corpus_limit_exceeded`, `item_limit_exceeded`, `telemetry_policy_atom_missing`, and an `index` when the failure is item-specific |
| `70` | run could not be completed | same error schema with `status` `failed` and `reason` `privacy_corpus_failed` |

## Corpus document (`insider.privacy-corpus/v1`)

Exactly the keys `schema`, `canary_tokens`, `items`, and optionally
`telemetry_policy`. Bounds: at most 4,096 items; at most 65,536 bytes of
external size per item; at most 32 distinct canary tokens of at most 128 bytes
each. Every declared token must occur somewhere in the items, otherwise the
corpus fails closed; a token that is nowhere cannot prove anything.

Items are plain maps with a `source` of `logger` (requires `level`, `message`,
`source`; optional `metadata`) or `telemetry` (requires `event_name`,
`source`). Unknown item shapes and undeclared keys fail closed. Telemetry event
names are at most 8 segments of at most 64 bytes; segments resolve only to
atoms that already exist after Lab loads Insider's own modules, and the runner
creates no atoms from corpus input. An application's own policy must therefore
be supplied as a `%Insider.Collector.Telemetry.Policy{}` through the function
API from a VM where that application is loaded. `priv/privacy_corpus/example.json`
is a schema example with fake values.

## Report (`insider.privacy-corpus-report/v1`)

| Key | Content |
|---|---|
| `status` | `no_canary_hits` or `canary_hits` |
| `environment`, `ingress_profile_fingerprint` | the selected profile |
| `logger_settings` | `include_message_semantics`, `include_payload`, `structural_only` as the profile derives them |
| `telemetry_policy` | the caller's policy `id` and fingerprint |
| `corpus_fingerprint` | SHA-256 of the corpus |
| `item_count`, `canary_token_count`, `canary_hit_count` | counts |
| `canary_hits` | `{index, field}` coordinates where a declared token appeared in projected output |
| `items` | per item: `index`, `source`, `disposition`, `kind` (a bounded name the handler derives, such as `supervisor_child_terminated`), `retained_fields`, `suppressed` counters |
| `retained_fields_union` | sorted union of retained field paths |
| `suppressed_totals` | bounded counters per source |
| `envelope_fields`, `bounds` | fixed names and the four limits |
| `controls` | `bounded_items_bytes_and_canary_tokens`, `field_values_are_never_reported`, `no_atoms_created_from_corpus`, `projection_uses_collector_handler_code_paths`, `unknown_item_shapes_fail_closed` |
| `limitations` | `charlist_and_integer_encoded_text_is_not_matched`, `hashed_or_truncated_derivatives_are_not_matched`, `json_corpora_cannot_express_pids_tuples_or_atoms`, `recorder_classification_and_lifecycle_health_are_not_exercised`, `retained_field_review_requires_human_judgment`, `synthetic_corpus_does_not_prove_application_coverage` |

The values of retained fields are never emitted.

## What a result means

The runner hands each item to the real `Insider.Collector.Logger.Handler` and
`Insider.Collector.Telemetry.Handler` code paths with the profile-derived
settings and the exact policy, so the retained paths are what those handlers
would retain. It does not run the recorder, classification, or lifecycle
health, and substring matching cannot see hashed, truncated, charlist, or
integer-encoded derivatives of a token. A report with no hits is bounded
evidence about the supplied items only. It is not application coverage, not a
redaction approval, and grants no staging or production authority.
