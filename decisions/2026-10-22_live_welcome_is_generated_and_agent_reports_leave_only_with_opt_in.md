# The live welcome document is generated from code, and agent reports leave the machine only with an opt-in

## Decision

- **Welcome contract.** `Insider.Live.welcome/0` returns
  `insider.live-welcome/v1`, built on each call from the tables the code
  uses: `Insider.Live.Options.describe/0`, the error table, the owner and
  option bounds, the measurement allowlist, the report rules, and the
  operation and observer-command tables in `Insider.Live.Welcome`. Tests fail
  when the document and the exported functions, option behaviour, the error
  codes the source can return, or the Lab observer's command table disagree.
  Hand-written prose is limited to the guide and summaries.
- **Version by content.** `hash` is the SHA-256 of the canonical JSON of
  every key except `hash` and `runtime`. It changes with anything the
  document promises, including host configuration that changes the contract
  (the measurement allowlist and report submission), and never with runtime
  state. `capabilities/0` carries it.
- **Commit identity without a command.** The compiled Git commit is read from
  the checkout's own `.git` files at compile time (no subprocess; the core
  may not contain one), only from the Insider checkout itself, and the module
  recompiles when it moves. Outside a checkout it is `nil`.
- **Reports are local first.** `report/1` and the observer's `report` accept
  only a closed category and a bounded message; context is added by Insider
  and never includes payloads, option values, or error details. The node
  queue is bounded memory because production code may not write files; the
  observer queue is bounded JSONL with the same deduplication rule.
- **Upstream only with an opt-in.** `mix insider.live reports submit` runs
  `gh` only with `--confirm` or `config :insider, :live_report_submission,
  :github` in the observer or the target. Otherwise it prints the issues it
  would file and runs nothing. Issues go to `hiivemarkets/insider`, one per
  fingerprint, after a search for an existing one; the node's host name is
  not sent.

## Why

Agents must learn what Insider can do when they connect and must report
where Insider is wrong or differs from what it told them. A hand-written
document drifts as the contract changes (filters and disclosure profiles are
next), so it is generated and guarded by tests instead. A content hash lets a
report name exactly the promise that was broken. Sending data to an external
service needs an explicit human or host decision, so filing issues is never
the default and the dry run shows every byte that would be sent.

## Consequences

- Adding an operation, option, error code, or observer command without
  updating the welcome tables fails the suite.
- The in-node queue does not survive a node restart; `mix insider.live reports
  --node …` copies it to the observer's persistent queue.
- Filters and disclosure profiles extend the `filters` and `disclosure` keys;
  doing so changes the hash, which is the intended signal to agents.
