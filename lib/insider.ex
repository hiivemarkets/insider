defmodule Insider do
  @moduledoc """
  Runtime evidence for the BEAM. The CLI that observes a node is the separate
  `insider_lab` package: `mix escript.install hex insider_lab`, then
  `insider-lab live capabilities --node NAME@HOST --cookie-file PATH --load`
  for first contact, and `insider-lab live welcome` with the same flags.

  This package, `insider`, is the core library: the collectors, the Recorder,
  redaction, and `Insider.Live`, which the CLI calls in the node. It has no
  Mix tasks, by design, so an app that depends only on `insider` reports
  `The task "insider.live" could not be found` for `mix insider.live`. Run
  `insider-lab live` instead. The app needs no dependency to be observed:
  `--load` pushes the CLI's own Insider into the node. Add
  `{:insider, "~> 0.1", only: :dev}` only for the agent guides and usage rules
  in `deps/insider/`, or for Tidewave `project_eval`. The two packages always
  release at the same version.

  [Getting started](docs/getting-started.md) has the quick start, and
  [insider vs insider_lab](docs/glossary.md#insider-vs-insider_lab) says
  which package to install for what.
  """
end
