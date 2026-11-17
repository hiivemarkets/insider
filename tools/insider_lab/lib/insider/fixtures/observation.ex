defmodule Insider.Fixtures.Observation do
  @moduledoc """
  Bounded evidence emitted by a deterministic fault fixture.

  Observations contain measurements, not detector verdicts. This lets the same
  fixture exercise future detectors without teaching those detectors the answer.
  """

  @enforce_keys [:run_id, :scenario, :variant]
  defstruct run_id: nil,
            scenario: nil,
            variant: nil,
            events: [],
            samples: %{},
            settled: %{},
            resources: [],
            cleanup: %{status: :complete}

  @type event :: %{
          required(:sequence) => pos_integer(),
          required(:kind) => atom(),
          required(:monotonic_time) => integer(),
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          run_id: pos_integer(),
          scenario: atom(),
          variant: :faulty | :healthy,
          events: [event()],
          samples: map(),
          settled: map(),
          resources: [pid()],
          cleanup: %{required(:status) => :complete}
        }
end
