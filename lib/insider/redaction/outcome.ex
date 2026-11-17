defmodule Insider.Redaction.Outcome do
  @moduledoc "A fully sanitized value and its deterministic disclosure manifest."

  @enforce_keys [:value, :manifest, :policy_id, :policy_fingerprint, :consumption]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          value: term(),
          manifest: [map()],
          policy_id: String.t(),
          policy_fingerprint: String.t(),
          consumption: %{
            nodes: pos_integer(),
            input_bytes: non_neg_integer(),
            output_bytes: pos_integer(),
            manifest_records: non_neg_integer()
          }
        }
end
