# Runtime facade and Mix task

## Decision

Expose bounded runtime diagnostics through `Insider.Runtime`, with a Mix task
as the primary coding-agent interface and direct Elixir calls as the IEx
interface. Start no mutation-oriented verification executors by default.

The first operation describes one explicit same-node process using the existing
scalar-only Erlang poller provider. The Mix task resolves registered names only
after starting the adopter application and does not accept textual PIDs. A PID
copied from a different BEAM can alias an unrelated process in the task's node.

## Why

A separate Mix invocation cannot inspect another BEAM's PID without a remote
connection and its associated authentication and deployment decisions.
Registered-name resolution makes the local development workflow immediately
useful while keeping distributed-node access outside this bounded slice.

Using the existing protocol, policy, result, provider, and wire layers avoids a
second diagnostic contract. Keeping scenario and Sentinel executors opt-in also
lets an adopter use read-only diagnostics without starting mutation-oriented
machinery. The lightweight contract executor remains enabled for compatibility
with the existing semantic-observation API.

## Consequences

- JSON is the default and only Mix-task output in this slice.
- Direct IEx callers must declare `:development`, `:test`, or `:ci` as trusted
  environment context.
- Staging, production, remote-node connection, discovery of target processes,
  and richer diagnostic operations remain future decisions.
- `:scenario` component configuration starts the contract executor it depends
  on. The default component set is `[:contract]`.
