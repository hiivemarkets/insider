# Third-party notices

## Elixir coverage reporting

`test/support/coverage_tool.ex` adapts summary and reporting logic from
Elixir's `Mix.Tasks.Test.Coverage`:

- Source: <https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/mix/lib/mix/tasks/test.coverage.ex>
- Copyright: 2021 The Elixir Team
- Copyright: 2012 Plataformatec
- License: Apache License 2.0; see [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)

The adapted file carries matching SPDX and modification notices. Elixir and
its contributors do not endorse Insider.

## recon

The Insider Lab observer depends on [recon](https://github.com/ferd/recon)
and its `--load` pushes recon's compiled modules, unmodified, into a
development, test, or ci target that lacks it. Insider's core uses recon
(for `alloc`) only when the node already has it loaded and never depends
on it; the root project uses it for tests and Dialyzer only.

- Source: <https://hex.pm/packages/recon> (2.5.6)
- Copyright: 2012-2024 Fred Hebert
- License: BSD 3-Clause; see [`LICENSES/BSD-3-Clause-recon.txt`](LICENSES/BSD-3-Clause-recon.txt)

Fred Hebert and recon's contributors do not endorse Insider.
