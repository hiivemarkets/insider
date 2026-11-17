defmodule Insider.Lab.Live.Reports do
  @moduledoc false

  # The observer side of agent reports. Reports filed with
  # `mix insider.live report`, and those copied from a target's in-node queue,
  # live in one bounded JSONL queue under the reports directory, with the same
  # deduplicating rule as the node (`Insider.Live.Report.put/2`). The
  # directory is per user and survives reboots (`default_directory/0`). It
  # also holds the observer's last-call context (the target, operation, error
  # code, environment and welcome hash of the last target command, and the
  # last local failure), which becomes the context of the next report, the
  # ledger of fingerprints already filed upstream, and per-source import
  # watermarks. Every change takes a lock file and replaces the file
  # atomically, so concurrent observers cannot interleave records. Only the
  # holder removes a lock: one left behind by an observer that was killed
  # inside the few-millisecond critical section is reported with its path
  # rather than broken automatically, because no staleness check can tell it
  # apart from a live holder without a race.
  #
  # `submit/4` files one GitHub issue per selected, unsubmitted fingerprint
  # on hiivemarkets/insider through `gh`, but only when the caller has an
  # opt-in (`--confirm` or the host's `:live_report_submission` setting) and
  # did not ask for `--dry-run`. Without one it returns what it would send
  # and runs nothing. With one it announces the effective authorization
  # before its first `gh` call. A submission holds its own lock from reading
  # the queue to recording the last issue, so two observers cannot file the
  # same fingerprint twice.

  alias Insider.Discovery.ExUnit.OracleRunner.Command
  alias Insider.Event.Canonical
  alias Insider.Live.Report
  alias Insider.Live.Revision

  @queue "observer-reports.jsonl"
  @state "observer-state.json"
  @ledger "submitted.jsonl"
  @imports "imports.jsonl"
  @queue_lock ".lock"
  @submit_lock ".submit.lock"
  @max_watermarks 1_000
  @max_sources 16
  @max_occurrences 16
  @local_source "observer"
  @unknown_source "unknown"
  @fingerprint ~r/\A[0-9a-f]{16}\z/
  @welcomed "welcomed.json"
  @max_welcomed 64
  @max_file_bytes 4 * 1_024 * 1_024
  @lock_attempts 200
  @lock_wait_ms 10
  @gh_timeout_ms 30_000
  @gh_output_bytes 65_536
  @title_bytes 80
  @failure_bytes 200
  @fingerprint_marker "insider-report-fingerprint:"
  @directory_variable "INSIDER_LIVE_REPORTS_DIR"
  @directory_name "insider-live"

  @type failure :: {:error, String.t(), map()}
  @type gh :: ([String.t()] -> {binary(), integer() | nil})
  @typedoc """
  Which reports a listing or submission covers: every report whose
  fingerprint is in `fingerprints` (all when empty) and one of whose
  retained `"occurrences"` cites `session` (any when `nil`). The report's
  `"context"` is only its latest context, and may cite another session.
  """
  @type selection :: %{fingerprints: [String.t()], session: String.t() | nil}
  @all %{fingerprints: [], session: nil}

  @doc """
  The reports directory: `INSIDER_LIVE_REPORTS_DIR` when set, else
  `insider-live` in the user's durable state directory:
  `~/Library/Application Support` on macOS, `$XDG_STATE_HOME` (an absolute
  path) or `~/.local/state` elsewhere, and the local application data
  directory on Windows.
  """
  @spec default_directory() :: Path.t()
  def default_directory, do: directory_for(System.get_env(), :os.type(), System.user_home!())

  @doc false
  @spec directory_for(%{String.t() => String.t()}, {atom(), atom()}, Path.t()) :: Path.t()
  def directory_for(environment, os_type, home) do
    case Map.get(environment, @directory_variable, "") do
      "" -> state_directory(environment, os_type, home)
      directory -> directory
    end
  end

  defp state_directory(_environment, {:unix, :darwin}, home),
    do: Path.join([home, "Library", "Application Support", @directory_name])

  defp state_directory(_environment, {:win32, _name}, _home),
    do: :filename.basedir(:user_data, @directory_name, %{os: :windows})

  # The XDG base directory specification ignores a relative path.
  defp state_directory(environment, _os_type, home) do
    case Map.get(environment, "XDG_STATE_HOME", "") do
      "/" <> _absolute = state -> Path.join(state, @directory_name)
      _unset -> Path.join([home, ".local", "state", @directory_name])
    end
  end

  @doc """
  Records the outcome of a target command as the context of the next report.
  The welcome hash, environment and session carry over from earlier
  commands against the same target, and the last local failure carries over
  always. Context is best effort: a failure to write it is ignored.
  """
  @spec remember(Path.t(), map()) :: :ok
  def remember(directory, call) do
    update_state(directory, fn previous ->
      carried = if previous["node"] == call["node"], do: previous, else: %{}

      Map.merge(previous, %{
        "node" => call["node"],
        "operation" => call["operation"],
        "error_code" => call["error_code"],
        "welcome_hash" => call["welcome_hash"] || carried["welcome_hash"],
        "environment" => call["environment"] || carried["environment"],
        "session" => call["session"] || carried["session"]
      })
    end)
  end

  @doc """
  Records an observer failure that never reached a target, such as a usage
  error, as the next report's local failure context. `operation` is the
  command's operation, or `nil` when the command named none. Best effort.
  """
  @spec remember_local(Path.t(), String.t() | nil, String.t()) :: :ok
  def remember_local(directory, operation, code) do
    update_state(directory, fn previous ->
      Map.merge(previous, %{"local_operation" => operation, "local_error_code" => code})
    end)
  end

  defp update_state(directory, update) do
    _written =
      locked(directory, fn ->
        replace(Path.join(directory, @state), [update.(read_state(directory))])
      end)

    :ok
  end

  @doc """
  The welcome hash delivered for this incarnation of `node` (its name and
  distribution `creation`, which changes when the node restarts), or `nil`
  if none was. Any observer on this machine sharing the directory counts.
  """
  @spec welcomed(Path.t(), String.t(), non_neg_integer()) :: String.t() | nil
  def welcomed(directory, node, creation) do
    case read_rows(Path.join(directory, @welcomed), &welcomed?/1) do
      {:ok, rows, _invalid} ->
        Enum.find_value(rows, &(&1["node"] == node && &1["creation"] == creation && &1["hash"]))

      _unreadable ->
        nil
    end
  end

  @doc """
  Records that the welcome with `hash` was delivered for this incarnation of
  `node`, replacing the node's earlier record (best effort).
  """
  @spec mark_welcomed(Path.t(), String.t(), non_neg_integer(), String.t()) :: :ok
  def mark_welcomed(directory, node, creation, hash) do
    path = Path.join(directory, @welcomed)
    row = %{"node" => node, "creation" => creation, "hash" => hash}

    _written =
      locked(directory, fn ->
        with {:ok, rows, _invalid} <- read_rows(path, &welcomed?/1) do
          rows = Enum.reject(rows, &(&1["node"] == node)) ++ [row]
          replace(path, Enum.take(rows, -@max_welcomed))
        end
      end)

    :ok
  end

  # A row of the first format, without `creation`, is invalid, so that node
  # is welcomed again.
  defp welcomed?(%{"node" => node, "creation" => creation, "hash" => hash} = row),
    do:
      map_size(row) == 3 and bounded_string?(node, 256) and is_integer(creation) and
        creation in 0..0xFFFFFFFF and bounded_string?(hash, 64)

  defp welcomed?(_row), do: false

  @doc """
  Files a validated report into the observer queue. Its context cites the
  report's own `:session` when given, else the session of the last target
  command.
  """
  @spec file(Path.t(), %{category: String.t(), message: String.t()}, DateTime.t()) ::
          {:ok, map()} | failure()
  def file(directory, report, now) do
    state = read_state(directory)

    context = %{
      "transport" => "observer",
      "insider_version" => insider_version(),
      "insider_commit" => Revision.commit(),
      "welcome_hash" => state["welcome_hash"],
      "node" => state["node"],
      "environment" => state["environment"],
      "session" => Map.get(report, :session) || state["session"],
      "last_operation" => state["operation"],
      "last_error_code" => state["error_code"],
      "last_local_operation" => state["local_operation"],
      "last_local_error_code" => state["local_error_code"]
    }

    record = Report.new(report, context, now)

    locked(directory, fn ->
      with {:ok, queue, _invalid} <- read_queue(directory) do
        {queue, receipt} = put_sourced(queue, record, @local_source)

        with :ok <- replace(Path.join(directory, @queue), queue) do
          {:ok,
           Map.merge(receipt, %{
             "schema" => "insider.live-report-receipt/v1",
             "queue" => "observer"
           })}
        end
      end
    end)
  end

  # Each observer row is a report record plus `"sources"`: `"observer"` for a
  # local filing and the node name for each node it was imported from. A
  # target's own submission opt-in covers only rows whose sources are that
  # target alone, so merging duplicates can never widen what it authorizes.
  #
  # Deduplication keeps only the newest context, so each row also keeps
  # `"occurrences"`: how many times each node and session cited in a
  # context reported it, least recently reported first, at most
  # `@max_occurrences` (the oldest is dropped beyond). Session selection and
  # grouping read them; the row's `count` stays the total, and GitHub
  # deduplication stays one issue per fingerprint.
  defp put_sourced(queue, record, source) do
    existing = Enum.find(queue, &(&1["fingerprint"] == record["fingerprint"]))
    previous = if existing, do: existing["sources"], else: []
    sources = [source | previous] |> Enum.uniq() |> Enum.sort() |> Enum.take(@max_sources)
    occurrences = add_occurrence((existing && existing["occurrences"]) || [], record)
    {queue, receipt} = Report.put(queue, record)

    queue =
      List.update_at(
        queue,
        -1,
        &Map.merge(&1, %{"sources" => sources, "occurrences" => occurrences})
      )

    {queue, Map.put(receipt, "report", List.last(queue))}
  end

  defp add_occurrence(occurrences, %{"context" => context, "count" => count}) do
    {node, session} = {context["node"], context["session"]}

    {matched, rest} =
      Enum.split_with(occurrences, &(&1["node"] == node and &1["session"] == session))

    previous = Enum.reduce(matched, 0, &(&1["count"] + &2))
    occurrence = %{"node" => node, "session" => session, "count" => previous + count}
    Enum.take(rest ++ [occurrence], -@max_occurrences)
  end

  @doc """
  Copies the in-node reports of `node` into the observer queue. Each node
  record's count is cumulative, so only the occurrences beyond the last
  import from the same node, fingerprint and first-report time are added. A
  node that restarted starts new records, which import in full.
  """
  @spec import(Path.t(), String.t(), [term()]) :: {:ok, map()} | failure()
  def import(directory, node, records) when is_list(records) do
    {valid, invalid} =
      records |> Enum.map(&Report.upgrade/1) |> Enum.split_with(&Report.record?/1)

    locked(directory, fn ->
      with {:ok, queue, _invalid} <- read_queue(directory),
           {:ok, marks, _invalid} <- read_rows(Path.join(directory, @imports), &watermark?/1) do
        marks = for %{"key" => key, "count" => count} <- marks, do: {key, count}

        {queue, marks, added} =
          Enum.reduce(valid, {queue, marks, 0}, &merge_imported(node, &1, &2))

        marks = marks |> Enum.take(-@max_watermarks) |> Enum.map(&watermark/1)

        with :ok <- replace(Path.join(directory, @queue), queue),
             :ok <- replace(Path.join(directory, @imports), marks) do
          {:ok,
           %{"records" => length(valid), "new_occurrences" => added, "invalid" => length(invalid)}}
        end
      end
    end)
  end

  defp merge_imported(node, record, {queue, marks, added}) do
    key = Enum.join([node, record["fingerprint"], record["first_reported_at"]], " ")
    seen = List.keyfind(marks, key, 0, {key, 0}) |> elem(1)
    delta = record["count"] - seen

    if delta > 0 do
      {queue, _receipt} = put_sourced(queue, %{record | "count" => delta}, node)
      {queue, List.keydelete(marks, key, 0) ++ [{key, record["count"]}], added + delta}
    else
      {queue, marks, added}
    end
  end

  defp watermark({key, count}), do: %{"key" => key, "count" => count}

  defp watermark?(%{"key" => key, "count" => count} = row),
    do: map_size(row) == 2 and bounded_string?(key, 1_024) and is_integer(count) and count > 0

  defp watermark?(_row), do: false

  @doc """
  Lists the selected reports of the observer queue, oldest first, with each
  report's submission, and groups their fingerprints by the node and session
  their retained occurrences cite (with a session selection, only that
  session's occurrences). The queue is shared by every observer run on this
  machine; the groups tell one run's reports from another's.
  """
  @spec list(Path.t(), selection()) :: {:ok, map()} | failure()
  def list(directory, selection \\ @all) do
    with {:ok, queue, invalid} <- read_queue(directory),
         {:ok, ledger, invalid_ledger} <- read_rows(Path.join(directory, @ledger), &ledger?/1) do
      submitted = Map.new(ledger, &{&1["fingerprint"], &1})
      selected = select(queue, selection)
      queued = MapSet.new(queue, & &1["fingerprint"])

      {:ok,
       %{
         "schema" => "insider.live-reports/v1",
         "queue" => "observer",
         "directory" => directory,
         "queue_max" => Report.max_reports(),
         "queued" => length(queue),
         "selection" => %{
           "fingerprints" => selection.fingerprints,
           "session" => selection.session,
           "unmatched_fingerprints" =>
             Enum.reject(selection.fingerprints, &MapSet.member?(queued, &1))
         },
         "invalid_lines" => invalid + invalid_ledger,
         "groups" => groups(selected, selection.session),
         "reports" =>
           Enum.map(selected, &Map.put(&1, "submitted", Map.get(submitted, &1["fingerprint"])))
       }}
    end
  end

  # A session selection keeps the reports any occurrence of which cites the
  # session, each with `"selected_count"`, the occurrences from that session.
  defp select(queue, %{fingerprints: fingerprints, session: session}) do
    for report <- queue,
        fingerprints == [] or report["fingerprint"] in fingerprints,
        selected = selected_occurrences(report, session),
        selected != [] do
      if is_nil(session),
        do: report,
        else: Map.put(report, "selected_count", Enum.reduce(selected, 0, &(&1["count"] + &2)))
    end
  end

  defp selected_occurrences(report, nil), do: report["occurrences"]

  defp selected_occurrences(report, session),
    do: Enum.filter(report["occurrences"], &(&1["session"] == session))

  # One group per node and session that the selected reports' occurrences
  # cite, in the order first met, with its fingerprints and occurrence count.
  defp groups(reports, session) do
    occurrences =
      for report <- reports,
          occurrence <- selected_occurrences(report, session),
          do:
            {{occurrence["node"], occurrence["session"]}, report["fingerprint"],
             occurrence["count"]}

    keys = occurrences |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    grouped = Enum.group_by(occurrences, &elem(&1, 0))

    for {node, session} = key <- keys do
      members = Map.fetch!(grouped, key)

      %{
        "node" => node,
        "session" => session,
        "fingerprints" => members |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
        "count" => Enum.reduce(members, 0, &(elem(&1, 2) + &2))
      }
    end
  end

  @doc """
  Files every selected, unsubmitted report the opt-in covers as a GitHub
  issue, or describes what it would file when `opt_in` is `nil` (a dry
  run). `"confirm"` and `"observer_config"` cover every report;
  `{"target_config", node}` covers only reports whose sole source is `node`,
  and counts the rest as `not_authorized`. Before creating an issue it
  searches the repository for the fingerprint, so a report filed from
  another machine, or one whose ledger entry has been compacted away, is
  linked rather than duplicated.

  Options: `:selection` (default every report), `:authorization` (the
  caller's description of its decision, returned as `"authorization"`), and
  `:announce`, which receives that authorization with `"will_submit"`
  before the first `gh` call of a real submission.
  """
  @spec submit(Path.t(), String.t() | {String.t(), String.t()} | nil, gh(), keyword()) ::
          {:ok, map()} | failure()
  def submit(directory, opt_in, gh, options \\ []) do
    selection = Keyword.get(options, :selection, @all)
    authorization = Keyword.get(options, :authorization, %{})
    announce = Keyword.get(options, :announce, fn _authorization -> :ok end)

    if opt_in,
      do: send_selected(directory, opt_in, gh, selection, authorization, announce),
      else: preview(directory, selection, authorization)
  end

  defp preview(directory, selection, authorization) do
    with {:ok, listed} <- list(directory, selection) do
      {submitted, pending} = Enum.split_with(listed["reports"], & &1["submitted"])

      {:ok,
       %{
         "repository" => Report.repository(),
         "authorization" => authorization,
         "selection" => listed["selection"],
         "already_submitted" => length(submitted),
         "dry_run" => true,
         "opt_in" => nil,
         "would_create" => Enum.map(pending, &issue/1),
         "how_to_send" =>
           "rerun without --dry-run and with --confirm, or set config :insider, :live_report_submission, :github in the host"
       }}
    end
  end

  defp send_selected(directory, opt_in, gh, selection, authorization, announce) do
    {kind, scope} = if is_tuple(opt_in), do: opt_in, else: {opt_in, nil}

    locked(
      directory,
      fn ->
        with {:ok, listed} <- list(directory, selection) do
          {submitted, pending} = Enum.split_with(listed["reports"], & &1["submitted"])
          {covered, uncovered} = Enum.split_with(pending, &covered?(&1, scope))
          _announced = announce.(Map.put(authorization, "will_submit", length(covered)))
          results = Enum.map(covered, &send_issue(directory, issue(&1), gh))

          {:ok,
           %{
             "repository" => Report.repository(),
             "authorization" => authorization,
             "selection" => listed["selection"],
             "already_submitted" => length(submitted),
             "dry_run" => false,
             "opt_in" => kind,
             "opt_in_target" => scope,
             "not_authorized" => length(uncovered),
             "results" => results
           }}
        end
      end,
      @submit_lock,
      1
    )
  end

  defp covered?(_report, nil), do: true
  defp covered?(%{"sources" => sources}, node), do: sources == [node]

  defp issue(report) do
    title = "[agent report] #{report["category"]}: #{title_text(report["message"])}"
    body = body(report)

    # One issue per fingerprint, whatever selected it: the body carries the
    # total count, and `selected_count` how many of those the selected
    # session reported.
    %{
      "fingerprint" => report["fingerprint"],
      "selected_count" => report["selected_count"],
      "title" => title,
      "body" => body,
      "command" => create_arguments(title, body)
    }
  end

  defp title_text(message) do
    line = message |> String.split("\n", parts: 2) |> hd()

    if byte_size(line) <= @title_bytes,
      do: line,
      else: String.slice(line, 0, @title_bytes - 1) <> "…"
  end

  # The node's host name stays on this machine; only its name part is sent.
  defp body(report) do
    context = report["context"]

    """
    An agent filed this report through Insider Live (`#{context["transport"]}` transport).

    **Category:** #{report["category"]}
    **Reported:** #{report["count"]} time(s), first #{report["first_reported_at"]}, last #{report["last_reported_at"]}

    #{Enum.map_join(String.split(report["message"], "\n"), "\n", &("> " <> &1))}

    | Context | Value |
    |---|---|
    | Insider version | #{cell(context["insider_version"])} |
    | Insider commit | #{cell(context["insider_commit"])} |
    | Welcome hash | #{cell(context["welcome_hash"])} |
    | Node | #{cell(node_name(context["node"]))} |
    | Environment | #{cell(context["environment"])} |
    | Last target operation | #{cell(context["last_operation"])} |
    | Last target error code | #{cell(context["last_error_code"], "none")} |
    | Last local failure | #{cell(context["last_local_error_code"], "none")} |
    | Last local failure operation | #{cell(context["last_local_operation"], "none")} |

    #{@fingerprint_marker} #{report["fingerprint"]}
    """
  end

  defp cell(value, absent \\ "unknown")
  defp cell(nil, absent), do: absent
  defp cell(value, _absent), do: "`" <> String.replace(value, ["`", "|", "\n"], "") <> "`"

  defp node_name(nil), do: nil
  defp node_name(node), do: node |> String.split("@", parts: 2) |> hd()

  defp create_arguments(title, body),
    do: ["issue", "create", "--repo", Report.repository(), "--title", title, "--body", body]

  defp send_issue(directory, issue, gh) do
    search = [
      "issue",
      "list",
      "--repo",
      Report.repository(),
      "--state",
      "all",
      "--search",
      "\"#{@fingerprint_marker} #{issue["fingerprint"]}\" in:body",
      "--json",
      "url",
      "--limit",
      "1"
    ]

    case run_gh(gh, search) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, [%{"url" => url} | _]} -> record(directory, issue, "existing", url)
          {:ok, []} -> create(directory, issue, gh)
          _other -> failed(issue, "unexpected gh issue list output", 0)
        end

      {:failed, output, status} ->
        failed(issue, output, status)
    end
  end

  defp create(directory, issue, gh) do
    case run_gh(gh, issue["command"]) do
      {:ok, output} ->
        record(
          directory,
          issue,
          "created",
          output |> String.trim() |> String.split() |> List.last()
        )

      {:failed, output, status} ->
        failed(issue, output, status)
    end
  end

  defp run_gh(gh, arguments) do
    case gh.(arguments) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:failed, output, status}
    end
  end

  # The ledger keeps an entry only while its fingerprint is in the queue, so
  # it never holds more than `Report.max_reports/0` rows. A report that comes
  # back after eviction is pending again, and the upstream fingerprint search
  # in `send_issue/3` links it to its existing issue instead of filing anew.
  defp record(directory, issue, action, url) do
    entry = %{
      "fingerprint" => issue["fingerprint"],
      "action" => action,
      "url" => url,
      "submitted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    result =
      locked(directory, fn ->
        with {:ok, ledger, _invalid} <- read_rows(Path.join(directory, @ledger), &ledger?/1),
             {:ok, queue, _invalid} <- read_queue(directory) do
          queued = MapSet.new(queue, & &1["fingerprint"])

          ledger =
            (ledger ++ [entry])
            |> Enum.filter(&MapSet.member?(queued, &1["fingerprint"]))
            |> Enum.take(-Report.max_reports())

          replace(Path.join(directory, @ledger), ledger)
        end
      end)

    case result do
      :ok -> Map.put(entry, "status", "ok")
      {:error, _code, _details} -> Map.put(entry, "status", "ok_unrecorded")
    end
  end

  defp ledger?(%{"fingerprint" => fingerprint, "action" => action, "url" => url} = row) do
    map_size(row) == 4 and is_binary(fingerprint) and String.match?(fingerprint, @fingerprint) and
      action in ["created", "existing"] and (is_nil(url) or bounded_string?(url, 512)) and
      timestamp?(row["submitted_at"])
  end

  defp ledger?(_row), do: false

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _at, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  # A row written before observer rows carried `"sources"` (the first queue
  # format) is a plain, valid report record. It is kept with the source
  # `"unknown"`, which no target's own opt-in covers, so only `--confirm` or
  # the observer's own setting can submit it. A row written before the local
  # failure context keys gets them as `nil` (`Report.upgrade/1`).
  # A row written before `"occurrences"` gets one, from its context and
  # count.
  defp observer_row(%{"sources" => sources} = row) do
    record = Report.upgrade(Map.drop(row, ["sources", "occurrences"]))

    if is_list(sources) and sources != [] and length(sources) <= @max_sources and
         Enum.all?(sources, &bounded_string?(&1, 256)) and Report.record?(record) do
      with occurrences when is_list(occurrences) <- occurrences(row, record),
           do: Map.merge(record, %{"sources" => sources, "occurrences" => occurrences})
    end
  end

  defp observer_row(row) do
    record = Report.upgrade(row)

    if Report.record?(record),
      do:
        Map.merge(record, %{"sources" => [@unknown_source], "occurrences" => occurrences(record)})
  end

  defp occurrences(%{"occurrences" => occurrences}, _record) do
    if is_list(occurrences) and occurrences != [] and length(occurrences) <= @max_occurrences and
         Enum.all?(occurrences, &occurrence?/1),
       do: occurrences
  end

  defp occurrences(_row, record), do: occurrences(record)

  defp occurrences(record), do: add_occurrence([], record)

  defp occurrence?(%{"node" => node, "session" => session, "count" => count} = occurrence),
    do:
      map_size(occurrence) == 3 and (is_nil(node) or bounded_string?(node, 256)) and
        (is_nil(session) or bounded_string?(session, 256)) and is_integer(count) and count > 0

  defp occurrence?(_occurrence), do: false

  defp bounded_string?(value, max), do: is_binary(value) and byte_size(value) in 1..max

  defp failed(issue, output, status) do
    %{
      "fingerprint" => issue["fingerprint"],
      "status" => "failed",
      "exit_status" => status,
      "output" => output |> String.trim() |> String.split("\n") |> hd() |> bounded()
    }
  end

  defp bounded(text) do
    if byte_size(text) <= @failure_bytes,
      do: text,
      else: String.slice(text, 0, @failure_bytes - 1) <> "…"
  end

  @doc "The `gh` runner: bounded in time and output, inheriting the environment."
  @spec gh([String.t()]) :: {binary(), integer() | nil}
  def gh(arguments) do
    case System.find_executable("gh") do
      nil ->
        {"gh is not installed", 127}

      executable ->
        result =
          Command.run(%{
            executable: executable,
            arguments: arguments,
            cd: File.cwd!(),
            environment: Enum.reject(System.get_env(), fn {_name, value} -> value == "" end),
            timeout_ms: @gh_timeout_ms,
            max_output_bytes: @gh_output_bytes,
            prefixes: []
          })

        {result.head <> result.tail, if(result.termination == "exited", do: result.status)}
    end
  end

  defp insider_version do
    _loaded = Application.load(:insider)

    case Application.spec(:insider, :vsn) do
      nil -> nil
      version -> List.to_string(version)
    end
  end

  defp read_state(directory) do
    case read_rows(Path.join(directory, @state), &is_map/1) do
      {:ok, [state], 0} -> state
      _absent -> %{}
    end
  end

  defp read_queue(directory), do: read_rows(Path.join(directory, @queue), &observer_row/1)

  # Every row that does not decode to a JSON object or that `valid?` rejects
  # is counted and dropped, so no malformed row reaches listing or
  # submission. `valid?` returns `true` to keep a row, a map to keep it
  # migrated, and anything else to drop it.
  defp read_rows(path, valid?) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, [], 0}

      {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes ->
        case File.read(path) do
          {:ok, contents} -> rows(contents, valid?)
          {:error, reason} -> unavailable(path, reason)
        end

      {:ok, _other} ->
        unavailable(path, :not_a_bounded_regular_file)

      {:error, reason} ->
        unavailable(path, reason)
    end
  end

  defp rows(contents, valid?) do
    decoded =
      for line <- String.split(contents, "\n", trim: true) do
        case Jason.decode(line) do
          {:ok, %{} = row} -> accepted(valid?.(row), row)
          _invalid -> nil
        end
      end

    valid = Enum.reject(decoded, &is_nil/1)
    {:ok, valid, length(decoded) - length(valid)}
  end

  defp accepted(true, row), do: row
  defp accepted(%{} = migrated, _row), do: migrated
  defp accepted(_rejected, _row), do: nil

  defp replace(path, values) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"
    contents = Enum.map(values, &[Canonical.encode(&1), "\n"])

    with :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _removed = File.rm(temporary)
        unavailable(path, reason)
    end
  end

  # `attempts` bounds the wait at `@lock_wait_ms` each; a submission does not
  # wait for another one.
  defp locked(directory, fun, name \\ @queue_lock, attempts \\ @lock_attempts) do
    lock = Path.join(directory, name)

    with :ok <- ensure_directory(directory),
         :ok <- acquire(lock, attempts) do
      try do
        fun.()
      after
        File.rm(lock)
      end
    end
  end

  defp ensure_directory(directory) do
    if File.dir?(directory) do
      :ok
    else
      with :ok <- File.mkdir_p(directory), :ok <- File.chmod(directory, 0o700) do
        :ok
      else
        {:error, reason} -> unavailable(directory, reason)
      end
    end
  end

  defp acquire(lock, 0) do
    {:error, "report_queue_unavailable",
     %{
       "path" => lock,
       "reason" => "locked",
       "hint" =>
         "another observer holds this lock; if no mix insider.live command is running, remove the file"
     }}
  end

  defp acquire(lock, attempts) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        File.close(device)

      {:error, :eexist} ->
        if attempts > 1, do: Process.sleep(@lock_wait_ms)
        acquire(lock, attempts - 1)

      {:error, reason} ->
        unavailable(lock, reason)
    end
  end

  defp unavailable(path, reason),
    do:
      {:error, "report_queue_unavailable",
       %{"path" => path, "reason" => reason |> inspect() |> bounded()}}
end
