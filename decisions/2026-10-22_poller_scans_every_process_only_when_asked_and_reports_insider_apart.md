# The Poller scans every process only when asked and reports Insider apart

## Context

The Poller sampled VM scalars and at most 32 explicit processes, and never
enumerated the node's processes. An agent test of Insider Live could not
find the backed-up GenServer behind a "slower the longer it runs" bug, and
mistook the growth of Insider's own Recorder table in `vm_sample.ets_bytes`
for an application ETS leak.

## Decision

- The Poller enumerates every local process or ETS table only when configured
  with `top_processes` or `top_ets_tables`. The core default is off; Insider
  Live turns both on (default 5 entries) with the poller component.
- A process scan reads only `group_leader`, `message_queue_len`, `memory`,
  and `reductions` with `process_info/2`; ranked processes are then named
  with `registered_name`, `current_function`, `initial_call`, and the one
  dictionary key `$initial_call`. No message, other dictionary key, or ETS
  object is ever read. An ETS scan reads only `:ets.info/2` metadata.
- Processes the protected-target policy covers (the fixed OTP inventory and
  host declarations) are never read by a scan; they are counted. Their
  tables are ranked, named from the inventory.
- Insider's own processes, its control plane and every process whose group
  leader is the `:insider` application master, and the tables they own are
  summed apart and never ranked. Reading their scalar counters is the one
  inspection of the control plane this allows, and only in aggregate.
- Reductions are ranked by the delta since the previous scan, with the poll
  interval as the window, as `recon:proc_window/3` does with a sleep. The
  Poller keeps one reductions count per scanned process between scans, at
  most 50,000. Insider does not depend on `recon`.
- Watched names resolve only to existing atoms and are resolved again each
  cycle, so a restarted process is followed.

## Consequences

- An agent can name a backed-up or growing process and table from Insider
  alone, and `vm_sample` carries `insider_ets_bytes` and
  `insider_processes_bytes` next to the VM totals.
- A scan is synchronous runtime inspection of every unprotected process each
  interval; Live's default interval is 5 s, and a scan's probe timeout is
  1 s within a 5 s cycle deadline. Its cost is in `bench/poller_probes.exs`.
- A ranking event must fit the 4 KiB event attribute bound, so the process
  rankings take at most 5 entries and the ETS rankings 10; entries that do
  not fit are dropped and counted in `omitted`.
- Production and staging enablement of these scans is not decided here; the
  Poller remains bound by the same ingress and environment gates.
