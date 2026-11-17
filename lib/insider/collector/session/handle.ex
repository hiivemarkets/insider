defmodule Insider.Collector.Session.Handle do
  @moduledoc """
  Opaque local capability for one host-owned collector session incarnation.

  It is deliberately not a protocol value and must not be forwarded to
  adapters. The manager compares the private reference with its live/retained
  entry before accepting stop, kill, or health requests.
  """

  @enforce_keys [:id, :incarnation, :manager, :token]
  defstruct [:id, :incarnation, :manager, :token]

  @type t :: %__MODULE__{
          id: String.t(),
          incarnation: String.t(),
          manager: pid(),
          token: reference()
        }
end
