defmodule Insider.Recorder.Priority do
  @moduledoc false

  alias Insider.Event

  @protected_kinds ~w(
    process_crashed
    supervisor_child_terminated
    invariant_failed
    code_changed
    config_changed
    deploy_changed
    agent_command
    agent_result
    agent_cancelled
    agent_cleanup
  )

  @type t :: :normal | :protected

  @spec classify(Event.t()) :: t()
  def classify(%Event{source: "agent"}), do: :protected
  def classify(%Event{kind: kind}) when kind in @protected_kinds, do: :protected
  def classify(%Event{}), do: :normal
end
