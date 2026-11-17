defmodule Insider.Recorder.Snapshot do
  @moduledoc "Immutable, bounded view of a sealed recorder window."

  @enforce_keys [
    :instance_id,
    :recorder_started_at,
    :freeze_id,
    :trigger_event_id,
    :opening_receipt,
    :closing_receipt,
    :freeze_status,
    :completeness,
    :gaps,
    :counters,
    :retained_count,
    :retained_bytes,
    :classification_bytes,
    :events
  ]
  defstruct @enforce_keys

  @type entry :: %{
          receipt: pos_integer(),
          received_at: integer(),
          priority: :normal | :protected,
          event: Insider.Event.t(),
          classification: Insider.Recorder.Classification.t()
        }
  @type t :: %__MODULE__{
          instance_id: String.t(),
          recorder_started_at: integer(),
          freeze_id: String.t(),
          trigger_event_id: String.t(),
          opening_receipt: pos_integer(),
          closing_receipt: pos_integer(),
          freeze_status: :complete,
          completeness: :complete | :incomplete,
          gaps: [atom()],
          counters: map(),
          retained_count: non_neg_integer(),
          retained_bytes: non_neg_integer(),
          classification_bytes: non_neg_integer(),
          events: [entry()]
        }
end
