defmodule Insider.Contract.Definition do
  @moduledoc false

  @enforce_keys [:module, :id, :version, :fingerprint, :declarations, :ownership, :portable]
  defstruct [:module, :id, :version, :fingerprint, :declarations, :ownership, :portable]

  @type declaration :: %{
          kind: atom(),
          name: String.t(),
          arity: non_neg_integer(),
          sensitivity: atom(),
          environments: [atom()]
        }

  @type t :: %__MODULE__{
          module: module(),
          id: String.t(),
          version: pos_integer(),
          fingerprint: String.t(),
          declarations: [declaration()],
          ownership: [module()],
          portable: map()
        }
end
