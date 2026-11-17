defmodule Insider.Collector.Calls.Tracing do
  @moduledoc false

  # The call trace's isolated trace session (`:trace`, OTP 28 and later).
  # Everything it sets lives in its own session: the function patterns and
  # the process flags. It never calls the node-global `:erlang.trace/3` or
  # `:erlang.trace_pattern/3`, so another tool's tracing (recon_trace, dbg,
  # a second Insider session) is neither replaced nor cleared, and removing
  # it touches nothing it did not set. OTP 27 has only node-global tracing,
  # where clearing a flag can clear another tool's, so the component is
  # refused there (`preflight/0`).
  #
  # The receiver gets `{:trace_ts, pid, :call, {m, f, args}, ns}`, and, when
  # results are traced, `:return_from` and `:exception_from` messages with
  # a monotonic timestamp in nanoseconds (`{m, f, arity}` without
  # arguments). The excluded processes, the receiver and the collector, are
  # never traced: their flags are cleared before any function pattern is
  # set, so tracing a function they call cannot feed back.
  #
  # - `stop_calls/1` removes the function patterns, so no new call is
  #   traced, but keeps the process flags: the result of a call already
  #   running is still delivered (its return trace was set when it began).
  # - `remove/1` destroys the session and then proves, from outside it, that
  #   the session and each of its function patterns are gone.

  @name :insider_calls

  @type backend :: %{session: term(), weak: term(), functions: [mfa()]}

  @doc """
  Whether call tracing can run on this node: OTP 28 and later have
  isolated trace sessions.
  """
  @spec preflight() :: :ok | {:error, :requires_otp_28}
  def preflight do
    if otp_release() >= 28, do: :ok, else: {:error, :requires_otp_28}
  end

  @doc """
  The match specification for `results`: calls only, or calls with their
  exceptions and returns (`exception_trace` delivers both).
  """
  @spec match_spec(:none | :exceptions | :all) :: list()
  def match_spec(:none), do: [{:_, [], []}]
  def match_spec(_results), do: [{:_, [], [{:exception_trace}]}]

  @doc """
  The match specification of a watched write under strict (call messages
  carry only the arity): the call's message is its key, the first argument
  (the first two for `Application.put_env` and `:application.set_env`) when
  each is an atom or a binary of at most 128 bytes, else the sentinel
  `{:insider_unnamed_key}`, so no other argument is copied to the receiver.
  (`{:message, false}` would suppress the call message, and with it the
  call's record and the trace's limits.)
  """
  @spec write_spec(mfa(), :none | :exceptions | :all) :: list()
  def write_spec({m, f, arity}, results) do
    results_body = if results == :none, do: [], else: [{:exception_trace}]
    pair? = {m, f} in [{Application, :put_env}, {:application, :set_env}] and arity >= 2
    names = if pair?, do: [:"$1", :"$2"], else: [:"$1"]
    head = names ++ List.duplicate(:_, arity - length(names))
    guard = names |> Enum.map(&name_guard/1) |> Enum.reduce(&{:andalso, &2, &1})
    message = if pair?, do: {{:"$1", :"$2"}}, else: :"$1"

    [
      {head, [guard], [{:message, message} | results_body]},
      {:_, [], [{:message, {{:insider_unnamed_key}}} | results_body]}
    ]
  end

  defp name_guard(variable),
    do:
      {:orelse, {:is_atom, variable},
       {:andalso, {:is_binary, variable}, {:"=<", {:byte_size, variable}, 128}}}

  @doc """
  Starts tracing `functions` (each must match exactly one loaded function)
  for every process except `excluded`, delivering to `receiver`. With
  `arguments: false` a call message carries only the arity, so no argument
  is ever copied to the receiver. The process flags are set, and the
  excluded processes cleared, before any function pattern exists, so no
  excluded process is ever traced.
  """
  @spec install(pid(), [pid()], [mfa()], :none | :exceptions | :all, boolean(), [mfa()]) ::
          {:ok, backend()} | {:error, atom()}
  def install(receiver, excluded, functions, results, arguments, writes \\ [])
      when is_pid(receiver) do
    case preflight() do
      :ok -> install_isolated(receiver, excluded, functions, results, arguments, writes)
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :trace_unavailable}
  catch
    _kind, _reason -> {:error, :trace_unavailable}
  end

  defp install_isolated(receiver, excluded, functions, results, arguments, writes) do
    {_strong, weak} = session = :trace.session_create(@name, receiver, [])
    spec = match_spec(results)

    flags =
      if arguments, do: [:call, :monotonic_timestamp], else: [:call, :monotonic_timestamp, :arity]

    try do
      _processes = :trace.process(session, :all, true, flags)
      Enum.each(excluded, &:trace.process(session, &1, false, flags))

      # Under strict a watched write sends only its key.
      spec_of = fn mfa ->
        if not arguments and mfa in writes, do: write_spec(mfa, results), else: spec
      end

      if Enum.all?(functions, &(:trace.function(session, &1, spec_of.(&1), [:local]) == 1)) do
        {:ok, %{session: session, weak: weak, functions: functions}}
      else
        _destroyed = :trace.session_destroy(session)
        {:error, :function_not_traceable}
      end
    rescue
      _error ->
        _destroyed = :trace.session_destroy(session)
        {:error, :trace_unavailable}
    end
  end

  @doc """
  Removes the function patterns: no new call is traced. The results of
  calls already running are still delivered.
  """
  @spec stop_calls(backend()) :: :ok | :error
  def stop_calls(%{session: session, functions: functions}) do
    Enum.each(functions, &:trace.function(session, &1, false, [:local]))
    :ok
  rescue
    _error -> :error
  end

  @doc "Removes the patterns and the process flags: nothing more is delivered."
  @spec stop_all(backend()) :: :ok | :error
  def stop_all(%{session: session} = backend) do
    with :ok <- stop_calls(backend) do
      _processes = :trace.process(session, :all, false, [:call])
      :ok
    end
  rescue
    _error -> :error
  end

  @doc """
  Asks the runtime to mark the point after every trace message already
  sent: the receiver gets `{:trace_delivered, :all, reference}` after them.
  """
  @spec delivered(backend() | nil) :: {:ok, reference()} | :error
  def delivered(%{session: session}), do: {:ok, :trace.delivered(session, :all)}
  def delivered(_backend), do: :error

  @doc "Whether the function patterns are still set in this session."
  @spec patterns(backend() | nil) :: non_neg_integer()
  def patterns(nil), do: 0

  def patterns(%{session: session, functions: functions}) do
    Enum.count(functions, &(:trace.info(session, &1, :traced) != {:traced, false}))
  rescue
    _error -> 0
  end

  @doc """
  Destroys the session and checks, from outside it, that it and each of its
  function patterns are gone. `"session"` is `"removed"`, `"already_removed"`,
  or `"unavailable"`; `"traced_after"` counts the functions the session
  still traced afterwards (`nil` when that could not be checked).
  """
  @spec remove(backend() | nil) :: map()
  def remove(nil), do: %{"session" => "not_installed", "functions" => 0, "traced_after" => 0}

  def remove(%{session: session, weak: weak, functions: functions}) do
    destroyed =
      try do
        if :trace.session_destroy(session), do: "removed", else: "already_removed"
      rescue
        _error -> "unavailable"
      end

    %{
      "session" => destroyed,
      "functions" => length(functions),
      "traced_after" => traced_after(weak, functions)
    }
  end

  @doc """
  The functions `weak` (a session's weak reference) still traces, checked
  through the runtime's own session inventory; `nil` when it cannot answer.
  """
  @spec traced_after(term(), [mfa()]) :: non_neg_integer() | nil
  def traced_after(weak, functions) do
    if weak in :trace.session_info(:all),
      do: length(functions),
      else: Enum.count(functions, &(weak in List.wrap(:trace.session_info(&1))))
  rescue
    _error -> nil
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> List.to_integer()
end
