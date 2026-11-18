# Insider Lab

Insider Lab is the command-line observer for
[Insider](https://insider.hexdocs.pm/readme.html), published to Hex as
`insider_lab`. It holds the `insider-lab` escript and the Mix tasks that
observe a running BEAM node from outside, and the ExUnit candidates and
oracles that help an agent prove a bug with a test. Its API reference is on
[insider-lab.hexdocs.pm](https://insider-lab.hexdocs.pm/readme.html). The
guides and the full reference live with the core, on
[insider.hexdocs.pm](https://insider.hexdocs.pm/docs-index.html).

**Two packages, one version.** Install this one, `insider_lab`, to observe
a node: `mix escript.install hex insider_lab`. Your app needs no
dependency. The core, `insider`, is the library the escript loads into the
node. It has no Mix tasks, so an app that depends only on `insider` has no
`mix insider.live`. Add `{:insider, "~> 0.1", only: :dev}` to an app only
for its agents (the usage rules and guides in `deps/insider/`) or for
Tidewave `project_eval`. The two packages always release at the same
version.

The Lab is for development and disposable environments. Its code is absent
from a production build, and it grants no provider, credential, repository,
publication, or deployment authority.

## What it gives you

- **`insider-lab live`**, or `mix insider.live` in a checkout. It attaches a
  hidden observer to a development node over Erlang distribution, loads
  Insider into it when needed, and drives one bounded, masked session:
  start, mark, digest, events, trace, chart, stop, and more.
- **`mix insider.candidates`**. A JSON inventory of the ExUnit tests worth
  running for a suspected bug, each with a hint that names a fixed oracle.
- **`mix insider.oracle`** and the oracles in `priv/oracles/`. One selected
  test command runs with a value-free before and after check, without
  editing the target.
- **`mix insider`** and **`mix insider.privacy_corpus`**. The protocol CLI,
  and a leak check of the Logger and Telemetry handlers.
- **Sentinel**. Offline reproduction and repair evidence, on disposable targets.

## Install from Hex

```sh
mix escript.install hex insider_lab
insider-lab live --help
```

Mix prints the directory it installs the escript in. Put it on your `PATH`,
and install again to update. The escript carries the Insider of its version,
and `--load` pushes it into a development node. Your app needs no change.

## Quick start

Boot your app as a named dev node with a private cookie file, as
[Getting started](https://insider.hexdocs.pm/getting-started.html) shows.
Then run these five commands. Replace `ID` with the `session_id` that
`start` returns.

```sh
N=(--node "my_app@$(hostname -s)" --cookie-file "$HOME/.my_app.cookie")
insider-lab live capabilities "${N[@]}" --load   # first contact
insider-lab live welcome "${N[@]}"              # the agent's quick start
insider-lab live start "${N[@]}" --component logger --component telemetry
insider-lab live digest "${N[@]}" --session ID --human
insider-lab live stop "${N[@]}" --session ID    # read the cleanup receipt
```

`start` records the default Telemetry events your node has, such as Phoenix
and Ecto events, and lists the others under `telemetry_skipped_defaults`. On
an app with none, it records Logger alone and says so in `telemetry_hint`.

## Run from a checkout

```sh
cd tools/insider_lab
mix deps.get --check-locked
mix insider.live capabilities "${N[@]}" --load
mix escript.build
./insider-lab live status "${N[@]}"
```

In this repository the Lab builds against the core next to it. Its Hex
package depends on `insider` from Hex at the same version, and
`INSIDER_LAB_HEX=1` selects that form here. Several agents at once should
use the escript, because it starts no Mix and never waits on the build lock.

## Documentation and license

- [Documentation index](https://insider.hexdocs.pm/docs-index.html): which section to read for which task.
- [Cheat sheet](https://insider.hexdocs.pm/cheat-sheet.html) and
  [Glossary](https://insider.hexdocs.pm/glossary.html): the everyday commands and terms.
- [Live API and transports](https://insider.hexdocs.pm/live-api-and-transports.html):
  every operation, flag, error code and exit status of the observer.
- [Lab: ExUnit candidates and oracles](https://insider.hexdocs.pm/lab-candidates-and-oracles.html)
  and [Lab: CLI transport and privacy corpus](https://insider.hexdocs.pm/lab-cli.html).
- [Sentinel and the proof workflow](https://insider.hexdocs.pm/sentinel-and-proof-workflow.html).
- Changes are in the [CHANGELOG](https://github.com/hiivemarkets/insider/blob/main/CHANGELOG.md).
- The Lab is licensed under the MIT License, see [`LICENSE`](https://github.com/hiivemarkets/insider/blob/main/tools/insider_lab/LICENSE).
