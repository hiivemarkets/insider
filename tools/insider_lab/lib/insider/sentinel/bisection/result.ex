defmodule Insider.Sentinel.Bisection.Result do
  @moduledoc """
  Live bisection output containing the canonical verdict and its evidence.

  The confirmation records are returned so the caller can retain and
  authenticate every artifact referenced by the bounded canonical record.
  This live struct is not itself a portable or content-addressed envelope.
  """

  alias Insider.Sentinel.Bisection.Record
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord

  @enforce_keys [:record, :confirmation_records]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          record: Record.t(),
          confirmation_records: [ConfirmationRecord.t()]
        }
end
