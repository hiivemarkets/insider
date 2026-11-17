# Live decodes Oban args when they are read, and query shapes fail closed

## Context

A review of `2026-10-27_live_groups_query_shapes_and_decodes_oban_args_in_the_rich_profile.md` found these problems:

- **Unbounded work in the emitting process.** Decoding Oban args there did unbounded work in the application's own process. Wide args were copied whole. Compressed terms could expand from 10 KB to 8 MB.
- **Literals in shapes.** Literals survived in statement shapes: dollar-quoted strings, booleans, exponents, and strings cut by the renderer.
- **Wrong caller.** A table-only caller fallback could name the wrong statement's caller.
- **Groups without evidence.** Strict query events, which disclose no table, were grouped as one table.

This record supersedes that record's decoding site and normalization rules. The rest of it stands.

## Decision

- **Constant work in the emitting process.**
  - `attributes.oban` visits at most the first 64 entries of the args map through its iterator.
  - In the rich profile, the args' top-level `term-` strings are kept by reference: at most 4, of at most 2 KiB each.
- **Decoding when the event is read** (`Insider.Live.Disclosure`). Decoding uses Base64, then `binary_to_term` with `:safe`.
  - A compressed term is never decoded.
  - The rendered result is masked.
- **A lexical SQL normalizer.** One pass replaces every literal form with `?` and folds literal lists, arrays and `VALUES` rows.
  - It gives no shape for an unterminated string, a cut statement, or one over 16 KiB.
- **Evidence only:**
  - A caller comes from a repo query event of the same table and shape.
  - Strict query events are counted as ungrouped.
  - A group with an unknown shape is shown, but it is never an N+1 anomaly.
  - The digest exports what its query analysis read (`query_evidence`), and says when it was capped.

## Why

A hook in the application's process must cost the same whatever the application passes it. A shape is a promise that no literal is in it, so a statement that cannot be fully read gets no shape at all, rather than a partial one. Blaming the wrong query was the miss this feature exists to fix.

## Consequences

- Only top-level `term-` args are decoded. A nested one stays encoded.
- `oban_terms` is held only in the raw recorded entry. Every read drops it after decoding.
- A strict session's N+1 anomaly needs statement evidence, so strict sessions get none.
