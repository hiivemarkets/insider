# `mix insider.candidates`

Operating contract for the Lab-only ExUnit candidate inventory. Every name,
bound, and status below is copied from
`tools/insider_lab/lib/insider/discovery/ex_unit/inventory.ex` and
`inventory_cli.ex` at the current revision. A candidate is a static hint; it is
never a confirmed defect, runtime cause, security impact, or financial impact.

## Invocation

Run from `tools/insider_lab`. Compile first in a separate step: a cold Mix
project writes compilation progress to stdout before the task starts, and the
task's own output is exactly one JSON object followed by a newline.

```sh
mix compile
mix insider.candidates --root /path/to/project
mix insider.candidates --root /path/to/project --path test/integration
mix insider.candidates --root /path/to/project --path test/a_test.exs --path test/b_test.exs
```

| Switch | Type | Default | Maximum | Notes |
|---|---|---|---|---|
| `--root` | string | current working directory | | Must be an existing directory (`lstat`, not followed). |
| `--path` | string, repeatable | `test` | 32 selectors of 1 to 1,024 bytes each | File or directory selectors relative to root. Exact paths only; no globs. |
| `--max-files` | integer | 5,000 | 20,000 | Eligible files are those ending in `_test.exs`. |
| `--max-bytes` | integer | 67,108,864 | 67,108,864 | Total source bytes read. |
| `--max-candidates` | integer | 500 | 2,000 | Candidates kept after ranking. |
| `--max-duration-ms` | integer | 10,000 | 60,000 | Whole-scan deadline; the scan runs in a monitored process whose `max_heap_size` is 67,108,864 words, and a killed scan reports `inventory_failed`. |

Repeating a scalar switch (`--root`, `--max-*`) is an argument error. Unknown
switches and positional arguments are argument errors.

## Exit status

| Exit | Meaning | stdout |
|---|---|---|
| `0` | clean: complete scan, no candidates (`status` `clean`, `completeness` `complete`) | inventory JSON |
| `2` | complete scan with candidates (`status` `candidates`, `completeness` `complete`) | inventory JSON |
| `3` | no eligible `_test.exs` file in the selection (`status` and `completeness` `empty_selection`) | inventory JSON |
| `4` | one or more files could not be analyzed (`status` and `completeness` `unsupported_source`) | inventory JSON, including every candidate found |
| `5` | a file, byte, or candidate bound was hit (`status` and `completeness` `truncated`) | inventory JSON, including the candidates kept |
| `64` | invalid arguments or options | `insider.exunit-candidate-inventory-error/v1` with `status` `invalid_input` and `reason` `invalid_arguments` or `invalid_options` |
| `70` | inventory could not be completed | same error schema with `status` `failed`, `completeness` `infrastructure_failure`, and a reason such as `invalid_root`, `selector_not_found`, `selector_symlink`, `selector_unavailable`, `selector_outside_root`, `scan_timeout`, or `inventory_failed` |

Only `0` means "nothing found". Treat `3`, `4`, and `5` as incomplete evidence
and `70` as an infrastructure failure; none of them is "no candidates". Exit
`1` is never an inventory result: Mix uses it for an uncaught crash.

## Completeness

Every inventory carries exactly one `completeness` state, chosen by this fixed
precedence:

1. `truncated`: `truncation_reasons` is non-empty.
2. `unsupported_source`: `unsupported` is non-empty (a skipped symlink, an
   unreadable path, or invalid Elixir syntax).
3. `empty_selection`: `eligible_file_count` is `0`.
4. `complete`: otherwise.

A lower-precedence condition that also holds stays visible in its own field;
for example a truncated scan still lists its `unsupported` files. `status` is
`clean` or `candidates` only when `completeness` is `complete`, and equals the
`completeness` state otherwise.

## Inventory document

Schema `insider.exunit-candidate-inventory/v2`. Version 2 adds `completeness`
and changes `status` so `clean` no longer means only "no candidates"; the rest
of the document is unchanged from v1. Top-level keys:

| Key | Content |
|---|---|
| `schema` | `insider.exunit-candidate-inventory/v2` |
| `scanner_revision` | `ast-v8-telemetry-event-targets` at this revision |
| `classification` | `candidate_inventory` |
| `status` | `clean`, `candidates`, `empty_selection`, `unsupported_source`, or `truncated` |
| `completeness` | `complete`, `empty_selection`, `unsupported_source`, or `truncated` |
| `root` | expanded root path |
| `paths` | selectors as given |
| `candidate_count`, `candidates` | ranked list, highest `score` first, ties by `path` |
| `eligible_file_count` | `_test.exs` files found by the walk |
| `scanned_file_count`, `scanned_bytes` | files and bytes actually read |
| `unsupported` | list of `{path, reason}` with reason `symlink_not_scanned`, `source_unavailable`, or `invalid_elixir_syntax` |
| `truncated`, `truncation_reasons` | any of `file_limit`, `byte_limit`, `candidate_limit` |
| `configuration_fingerprint` | SHA-256 over the effective options, scanner revision, and signal weights |
| `source_fingerprint` | SHA-256 over the sorted `{relative path, source fingerprint}` pairs |
| `limitations` | `static_signals_do_not_confirm_runtime_causality`, `only_explicit_reason_patterns_are_visible`, `only_elixir_test_sources_are_interpreted` |

Each candidate:

| Key | Content |
|---|---|
| `id` | SHA-256 over path, source fingerprint, reasons, targets, and truncation flag |
| `classification` | `candidate` |
| `path` | relative to root |
| `source_fingerprint` | SHA-256 of the file bytes |
| `score` | sum of reason weights |
| `reasons` | sorted by `code`; each has `code`, `weight`, `lines`, `evidence` |
| `target_count`, `targets`, `targets_truncated` | at most 64 deduplicated targets across all kinds |

### Signal codes and weights

| Code | Weight | Evidence text |
|---|---|---|
| `application_env_absence_not_restored` | 12 | cleanup converts a previously absent application environment entry into a value |
| `application_env_mutation` | 8 | mutates application environment without visible matching cleanup |
| `global_telemetry_handler` | 7 | attaches a VM-global telemetry handler without visible matching cleanup |
| `otel_global_capture` | 7 | changes or captures shared OpenTelemetry state |
| `sleep_or_timer_wait` | 4 | uses elapsed time for synchronization |
| `explicit_test_serialization` | 3 | declares `async: false` |
| `application_env_cleanup_present` | 2 | mutates application environment and declares matching cleanup |
| `global_telemetry_cleanup_present` | 1 | attaches a VM-global telemetry handler and declares matching cleanup |

Cleanup credit is given only when the same application-env key or Telemetry
handler id is released in the same lexical `test`, `setup`, `setup_all`, `def`,
or `defp` scope. `:telemetry_test.attach_event_handlers/2` never receives
cleanup credit because its handler id is the returned reference.

## Targets

Three kinds. All carry `kind`, `operation`, `status`, and `oracle`.

| Kind | Identity fields | Status values |
|---|---|---|
| `application_env` | `application`, `key` | `resolved` (root-qualified `Elixir.Application` call), `syntactic` (with `reason` `unqualified_module` for an unqualified `Application` call or `lexical_alias_without_macro_expansion` for a visibly aliased key), `unresolved` |
| `telemetry_handler` | `handler` (literal id passed to `:telemetry.attach/4` or `attach_many/4`) | `resolved`, `unresolved` |
| `telemetry_event` | `event` (list of segment strings; one entry per literal event in `:telemetry.attach/4`, `attach_many/4`, or `:telemetry_test.attach_event_handlers/2`) | `resolved`, `unresolved` |

Unresolved targets carry `reason` `dynamic_identity` and `oracle: null`.
Configured values, callbacks, and executable terms are never included.

### The `oracle` hint

A static re-encoding of the identity already in the target, naming the fixed
artifact and the exact environment inputs it validates. It installs,
starts, and authorizes nothing.

- `application_env` with status `resolved` or `syntactic`:
  `{"schema": "insider.application-env-oracle/v1", "inputs": {"INSIDER_ORACLE_APPLICATION": app, "INSIDER_ORACLE_KEY": key}}`.
- `telemetry_event` with status `resolved`:
  `{"schema": "insider.telemetry-dead-handlers-oracle/v1", "inputs": {"INSIDER_ORACLE_TELEMETRY_EVENT": "seg1,seg2,..."}}`.
- `null` for `telemetry_handler`, for unresolved targets, and whenever the
  artifact would reject or reinterpret the identity: a name or segment outside
  1 to 255 bytes, more than 16 segments, an encoded event longer than 2,048
  bytes, a segment containing a comma, or any byte below `0x20` (which could
  not pass through the environment unchanged).

The `otel_global_capture` signal has no target and therefore no hint; the
OpenTelemetry artifact takes no selector.

A `syntactic` identity must be validated by you before use: a macro could
shadow `Application` or alter the alias environment, and the scanner does not
load or expand adopter code.

## `scanner_revision` caveat

Candidate `id` values and `configuration_fingerprint` depend on the target
extraction semantics of the scanner revision. Compare inventories only when
`scanner_revision` matches; a new revision can change which targets a file
yields and therefore its candidate identity even when `source_fingerprint` is
unchanged.

## What the scan does not do

It reads only exact selectors inside the declared root, rejects missing,
escaping, or symlinked selectors, and does not follow symlinks during the
walk. It parses Elixir with `Code.string_to_quoted/2` and inspects executable
AST only, so examples inside strings or quoted syntax are not behavior. It does
not expand globs, load or evaluate target source, run tests, read credentials,
contact providers, start a background scan or scheduler, invoke a model, or
grant staging or production authority. Concurrent replacement of files during a
scan is outside its trust boundary.
