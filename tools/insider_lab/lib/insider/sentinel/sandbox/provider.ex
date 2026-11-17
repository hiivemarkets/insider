defmodule Insider.Sentinel.Sandbox.Provider do
  @moduledoc """
  Behaviour for trusted disposable-target adapters.

  Providers must register every resource under `owner_id` before creating it,
  make cleanup idempotent, and support cleanup by owner even when acquisition
  did not return. Provider modules are trusted runtime configuration and must
  never be selected by converting wire strings to atoms.
  """

  alias Insider.Sentinel.Sandbox.Target

  @type deadline :: integer()
  @type owner_id :: binary()
  @type resource_reference :: %{String.t() => String.t()}

  @callback identity() :: map()
  @callback acquire(owner_id(), Target.t(), deadline()) :: :ok | {:error, atom()}
  @callback observe(owner_id(), deadline()) :: {:ok, map()} | {:error, atom()}
  @callback cleanup(owner_id(), deadline()) :: :ok | {:error, atom()}
  @callback inventory(owner_id(), deadline()) ::
              {:ok, [resource_reference()]} | {:error, atom()}
end
