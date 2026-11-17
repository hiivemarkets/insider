defmodule Insider.Live.Revision do
  @moduledoc false

  # The Git commit this copy of Insider was compiled from, read once at
  # compile time from the repository files themselves; no command runs. Only
  # the Insider checkout's own `.git` is consulted, so a copy vendored into
  # another repository (a Hex dependency under `deps/`) reports `nil` rather
  # than the host's commit. Mix recompiles this module when the commit moves.

  @root Path.expand("../../..", __DIR__)
  @commit Insider.Live.Revision.Git.head_commit(@root)

  @spec commit() :: String.t() | nil
  def commit, do: @commit

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Insider.Live.Revision.Git.head_commit(@root) != @commit
end
