defmodule Insider.Live.Error do
  @moduledoc false

  # The closed `"code"` vocabulary of `Insider.Live` error maps.
  # `docs/live/live-welcome-and-reports.md` ("Error codes") and the welcome
  # document list every code; adding one is
  # a contract change.
  @messages %{
    "amend_failed" =>
      "the amended collector session failed to start; rolled_back says whether the previous " <>
        "configuration is collecting again, otherwise status carries the ended session",
    "busy" =>
      "the collector session is overloaded, or two discoveries or two inspections are already running",
    "component_unavailable" =>
      "a requested component cannot run on this node (a missing library or an older OTP release); component and reason name it",
    "disclosure_denied" =>
      "the requested disclosure profile is richer than the host profile allows",
    "environment_denied" => "live observation is allowed only in development, test, and ci",
    "invalid_cursor" =>
      "the cursor is not an integer of at least 0 or \"latest\", or is beyond next_receipt; " <>
        "oldest_receipt and next_receipt name the receipts it may read",
    "invalid_options" => "options are malformed, unknown, or out of bounds",
    "mark_not_found" =>
      "the session has no pairing mark, or none with this label; marks counts them and labels lists the newest labels. " <>
        "Make one with mark before the programmer acts",
    "readers_active" =>
      "another reader read within reader_active_ms or is subscribed; readers names them. " <>
        "Stop with force to stop anyway: a stopped session stays readable for stopped_readable_ms",
    "invalid_subscriber" => "the subscriber must be a pid",
    "process_not_found" =>
      "no process is registered under this name, or the pid is not a live process on this node",
    "protected_process" =>
      "the process is protected by the host or the fixed OTP inventory, so Insider never reads it",
    "session_already_active" => "a collector session is already active on this node",
    "session_terminal" => "the live session has ended; its status carries the cleanup receipt",
    "start_failed" => "the collector session failed to start and left no active session",
    "subscriber_limit" => "the session already has the maximum number of subscribers",
    "timeout" =>
      "the operation exceeded its time bound; for ingest_spans the outcome is unknown (some, all or none of the spans may be recorded), and a retry of the same spans skips those still in the session's last 16,384 ingested span ids",
    "unavailable" =>
      "the Insider application or its live owner is not running, or a discovery or inspection worker failed",
    "unknown_session" => "no active or retained live session has this id",
    "unknown_process_name" =>
      "a process name is not an existing atom on this node, so no process can be registered under it",
    "unknown_telemetry_event" =>
      "a telemetry event segment is not an existing atom on this node, or a prefix matches no discovered event",
    "untraceable_function" =>
      "a calls function cannot be traced: reason is unknown_atom (its module or name is not an atom on this node), " <>
        "not_loaded (its module is not loaded), not_found (the module has no such function and arity), " <>
        "or protected (a runtime-preloaded module or Insider's own)"
  }

  @spec codes() :: [String.t()]
  def codes, do: @messages |> Map.keys() |> Enum.sort()

  @spec messages() :: %{String.t() => String.t()}
  def messages, do: @messages

  @spec new(String.t(), map()) :: map()
  def new(code, details \\ %{}) when is_map_key(@messages, code) and is_map(details) do
    Map.merge(details, %{
      "schema" => "insider.live-error/v1",
      "code" => code,
      "message" => Map.fetch!(@messages, code)
    })
  end
end
