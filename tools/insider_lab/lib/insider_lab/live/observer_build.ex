defmodule Insider.Lab.Live.ObserverBuild do
  @moduledoc false

  # The observer's own `Insider.Live.Build` identity, which every observer
  # document reports. The identity hashes every Insider module, and
  # computing it per call loaded them all: under load that was up to a
  # second of each escript call. The observer pushes and runs
  # exactly the Insider it was compiled with, so the identity is fixed here
  # at compile time. Mix recompiles this module whenever that build changes.

  _loaded = Application.load(:insider)
  @identity Insider.Live.Build.identity()

  @spec identity() :: %{String.t() => String.t() | nil}
  def identity, do: @identity

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    _loaded = Application.load(:insider)
    Insider.Live.Build.identity() != @identity
  end
end
