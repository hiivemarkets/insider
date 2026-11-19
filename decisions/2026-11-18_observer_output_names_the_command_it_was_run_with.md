# Observer output names the command it was run with, and the escript has its own help

## Context

The observer runs in two forms with the same operations, flags and output:
the escript, `insider-lab live`, and the Mix task in an Insider checkout,
`mix insider.live`. The target's `Insider.Live` writes the commands it
suggests (hints, `next` fields, `Next:` lines in human text, the welcome's
examples) in the Mix task's form, because it is also called directly from
Elixir and cannot know which observer, if any, will print them. The Lab's
help text and error `help` fields also named only the Mix task. An agent
that ran the escript was shown commands it could not run as written.

The escript itself had no help: `insider-lab`, `insider-lab --help` and
`insider-lab help` printed a bare `usage` error, and the observer's help was
reachable only as `insider-lab live --help`.

## Decision

- `Insider.Lab.Live.CLI.run/3` takes `invocation:`, the command that was
  run. The Mix task passes nothing, so it is `mix insider.live`; the
  escript's `live` passes `insider-lab live`. `parse/2` takes the same value.
- Help (`--help`, `help OPERATION`, `OPERATION --help`), the `help` field
  and message of the observer's own errors, and the fields of a target's
  document that carry commands name that form. Before it renders a
  document, the observer rewrites `mix insider.live` to the invocation
  wherever it is followed by an operation name, `OPERATION`, `help` or
  `--help`, in these fields only: the welcome (delivered, pointed to, or the
  `welcome` result), a result's `next`, `help` and `resume` commands, the
  `command` of each hint and anomaly, the `Next:` and `next:` lines of a
  human `text`, and an error's `help`. The compact welcome line names the
  form too.
- Everything else in a document is left exactly as the target wrote it:
  captured events and their payloads, mark labels, reader names, session
  ids, and every object key. A value the observer prints can be passed
  back to it, so a mark labelled `mix insider.live start` is found again by
  that label.
- `mix insider.live` followed by anything else is a sentence about the Mix
  task ("run mix insider.live from tools/insider_lab", "in place of mix
  insider.live,") and stays as written.
- The core keeps writing the Mix task's form. Its output and the welcome
  hash do not depend on the observer.
- `insider-lab` alone, `--help`, `-h` and `help` print a short plain-text
  help to stdout and exit `0`: what the escript is, `live OPERATION`, the
  protocol modes `--discover`, `--json` and `--ndjson`, and the next steps
  `insider-lab live --help` and first contact with `--load`. Any other
  argument stays an `insider.cli.error/v1` `usage` error with exit `64`; it
  gains a top-level `"help": "insider-lab --help"` field. `--discover`,
  `--json` and `--ndjson` are unchanged.

## Why

The commands an observer prints are instructions to the agent that ran it,
so they belong in that agent's form. Writing them in the right form in the
core would need the core to know its caller, and an Elixir caller or
Tidewave has none. Rewriting in the observer keeps the core's output the
same for every caller and needs no new field in the target's documents.

Rewriting only the fields that carry commands keeps the rest of a
document true to the node: a label, a name or a logged message that
happens to look like a command is data, and printing it changed would
make it impossible to pass back (an earlier draft rewrote the whole
encoded output, and a mark labelled `mix insider.live start` could no
longer be found). Rewriting only before an operation word keeps prose
about the Mix task true.

Help on no arguments is what a newcomer tries first. The protocol modes
never took an empty argument list, so nothing relied on it being an error.

## Consequences

- A test pins each form for help, usage and option errors, a target's
  `next` command and the welcome's quick start, and that the sentences
  about the Mix task are left alone.
- A test pins that captured data, object keys and mark labels are left as
  the node wrote them in the escript's output, and that a mark is found
  again by the label it was given.
- A new field that carries a command must be added to the observer's list
  of command fields, or it prints in the Mix task's form.
- The escript prints `insider-lab live` even when it was started as
  `./insider-lab live` from a checkout build; both run the same program.
- A third form would be one more `invocation:` value; the core does not
  change.
