defmodule Insider.TestRecorderClassification do
  @moduledoc false

  alias Insider.Redaction.Policy

  def binding do
    {:ok, policy} =
      Policy.new(
        id: "test-recorder-policy",
        maximum_sensitivity: :internal,
        rules: []
      )

    {:internal, policy}
  end
end
