# Getting started

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

Install the observer CLI, attach Insider to a running development node, give
your agent the welcome document, and read one quiet window per task. Then
decide whether your app should depend on Insider, and set up the Insider
repository itself.

## Contents

- [Observe a running node in five minutes](#observe-a-running-node-in-five-minutes)
  - [1. Install the CLI](#1-install-the-cli)
  - [2. Boot the target with a short name and a private cookie](#2-boot-the-target-with-a-short-name-and-a-private-cookie)
  - [3. Six commands, plus a mark](#3-six-commands-plus-a-mark)
  - [4. Or use Tidewave `project_eval`](#4-or-use-tidewave-project_eval)
  - [Attach to a node you did not start](#attach-to-a-node-you-did-not-start)
  - [Tips](#tips)
- [Add Insider to your app](#add-insider-to-your-app)
- [Work on the Insider repository](#work-on-the-insider-repository)
- [Brief the agents of your host app](#brief-the-agents-of-your-host-app)

## Observe a running node in five minutes

You need the observer CLI and a development node on this machine. The node
does not depend on Insider: the observer loads Insider into it at run time.

### 1. Install the CLI

Insider ships as two Hex packages, always at the same version:

- **`insider_lab`** is the CLI: the `insider-lab` escript and the Mix tasks
  (`mix insider.live` and the others). Install it to observe a node. Most
  people need only this, and the app needs no dependency.
- **`insider`** is the core library that the CLI loads into the node. It
  has no Mix tasks. Add it to your app only for its agents or for Tidewave.
  See [Add Insider to your app](#add-insider-to-your-app).

Install the CLI from Hex:

```sh
mix escript.install hex insider_lab
```

Mix installs it in its escripts directory, usually `~/.mix/escripts`, and
prints that directory. Add it to your `PATH`. Install again to update.

In an Insider checkout, use the Mix task from `tools/insider_lab` instead:
`mix insider.live` takes the same operations and flags as
`insider-lab live`. Or build the escript there with `mix escript.build` and
run `./insider-lab live`.

### 2. Boot the target with a short name and a private cookie

Make the cookie file with `umask 077`, so that only you can read it. The
observer refuses a cookie file with group or other permission bits.

```sh
(umask 077 && openssl rand -hex 24 > ~/.my_app.cookie)
elixir --sname my_app \
  -e 'Node.set_cookie(String.to_atom(String.trim(File.read!(Path.expand("~/.my_app.cookie")))))' \
  -S mix run --no-halt
```

With Phoenix, run `-S mix phx.server` instead. The node is named
`my_app@<short host name>`.

### 3. Six commands, plus a mark

Run these from any directory. Set `N` as an array, as shown. It then splits
into words in bash and in zsh. Replace `ID` with the `session_id` that
`start` returns.

```sh
N=(--node "my_app@$(hostname -s)" --cookie-file "$HOME/.my_app.cookie")
insider-lab live capabilities "${N[@]}" --load   # first contact: loads Insider if the node lacks it
insider-lab live welcome "${N[@]}"              # the agent's quick start
insider-lab live start "${N[@]}" --component logger --component telemetry
insider-lab live digest "${N[@]}" --session ID --human
insider-lab live events "${N[@]}" --session ID --cursor 0 --format compact
insider-lab live stop "${N[@]}" --session ID    # check the cleanup receipt

# Mark a window, act, then read only what came after the mark
insider-lab live mark "${N[@]}" --session ID --label 'about to click Confirm'
insider-lab live digest "${N[@]}" --session ID --since-mark --human
```

`--since-mark` without a label reads from the newest mark. `digest`,
`trends`, `events` and `timeline` all accept it.

A read without `--session` uses the node's active session. `stop`, `amend`
and `otlp-receive` still need `--session`. See
[Default session](live/live-api-and-transports.md#default-session).

### 4. Or use Tidewave `project_eval`

In a Phoenix development server with Tidewave, evaluate the same operations
through `Insider.Live.JSON`:

```elixir
Insider.Live.JSON.welcome()
Insider.Live.JSON.start(%{"components" => ["logger", "telemetry"]})
```

The [Tidewave section](live/live-api-and-transports.md#tidewave-project_eval)
shows how to load Insider's compiled ebin first. If your app depends on
Insider, it is already there. See [Add Insider to your app](#add-insider-to-your-app).

### Attach to a node you did not start

The observer can attach to any local development node that already has a
name. You need three things:

- The node's exact name, for example `my_app@myhost`. A different host part
  is refused as an unknown node.
- A cookie file that holds the node's cookie, with mode `0600` or stricter.
- A development, test or ci environment on the node. The node decides this.

If the node does not run Insider, `capabilities` reports `insider_missing`.
Run it again with `--load`. If the node runs another Insider build,
`--load` reports `load_build_differs`. `--force-load` replaces that build and
ends its session, so save the session's evidence first. See
[Load Insider into the target](live/live-api-and-transports.md#load-insider-into-the-target)
and
[Exit statuses and error codes](live/live-api-and-transports.md#exit-statuses-and-error-codes).

### Tips

- Point your agent at the welcome document and let it drive. The welcome is
  generated from the code, so it matches the Insider that is loaded.
- Use Insider next to Tidewave, not instead of it.
- Found something wrong? Run
  `insider-lab live report --category bug --message '…'`. Reports stay local
  until you send them.
- Live observation works only on development, test and ci nodes. See
  [Disclosure and safety](disclosure-and-safety.md).

The full flag reference is under
[Observer flag reference](live/live-api-and-transports.md#observer-flag-reference),
and `insider-lab live --help` prints it. The [cheat sheet](cheat-sheet.md)
has the commands you use most.

## Add Insider to your app

Observation needs no dependency: `--load` pushes the observer's own Insider
into the node. Add the core, `insider`, to your app only if you want one of
these:

- The agent guides and the usage rules under `deps/insider/`, for the
  agents of your app and for `mix usage_rules.sync`.
- Insider in the node for Tidewave `project_eval`, with no ebin to load
  first.

Add it for development only:

```elixir
# in the deps of your app's mix.exs
{:insider, "~> 0.1", only: :dev}
```

The node then starts its own Insider. The observer works with it. It
reports `same_build: false` when the two copies were compiled apart, and
`--load` does not replace the node's copy. See
[Load Insider into the target](live/live-api-and-transports.md#load-insider-into-the-target).

The core gives your app no Mix task. `mix insider.live` in your app reports
`The task "insider.live" could not be found`, because that task is in
`insider_lab`. Keep running `insider-lab live` from the escript.

## Work on the Insider repository

Use a supported Elixir/OTP pair (1.17/27, 1.19/28, or 1.20/29; maintainer
tools need Elixir 1.18 or newer). From the repository root:

```sh
mix setup      # deps.get, then activate .githooks/
mix quality    # format, warnings-as-errors, full unit suite, Credo + ex_slop
(cd tools/insider_lab && mix deps.get && mix test)
```

To look for test-isolation candidates in another Elixir project, compile Lab
once and point the inventory at that project's test tree:

```sh
(cd tools/insider_lab && mix compile)
(cd tools/insider_lab && mix insider.candidates --root /path/to/project --path test)
```

A candidate is a hint, not a confirmed defect. The fixed runtime oracles that can
confirm one are described under
[Agent-requested ExUnit candidates](lab-candidates-and-oracles.md#agent-requested-exunit-candidates).

## Brief the agents of your host app

A host application whose agents use Insider Live can add this to its own
`AGENTS.md` (adjust the node name and cookie path):

```markdown
## Insider Live (runtime observation)

This app can be observed while it runs with Insider Live, in development only.

- Before observing, read the welcome quick start and follow it:
  `insider-lab live welcome --node my_app@$(hostname -s) --cookie-file ~/.my_app.cookie`
  (`--full` for the whole reference, `insider-lab live --help` for the
  flags), or `Insider.Live.JSON.welcome()` through Tidewave `project_eval`.
  Install the CLI with `mix escript.install hex insider_lab`. The CLI is the
  `insider_lab` package. This app has no `mix insider.live` task.
- Loop: start one session, act, then read `events_since` from your cursor.
  Stop the session when you are done.
- You must report Insider bugs and anything that behaves differently from the
  welcome document: `insider-lab live report --category doc_mismatch --message '…'`
  (or `Insider.Live.JSON.report/1`). Never include payloads or secrets.
  Reports stay local. The developer sends them with `insider-lab live reports submit`.
- Rules and guides: `deps/insider/usage-rules.md` and
  `deps/insider/guides/agents/live-observation.md` when Insider is a
  dependency, otherwise <https://hexdocs.pm/insider>.
```

With [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/insider/usage-rules.md`.
