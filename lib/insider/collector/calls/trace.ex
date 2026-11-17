defmodule Insider.Collector.Calls.Trace do
  @moduledoc false

  # The call trace's bookkeeping, separate from the trace session so it can
  # be exercised with the runtime's own trace message shapes on any OTP
  # release. `handle/2` takes one trace message and returns the records to
  # write as events and the action the trace session must take:
  #
  # - Each traced call is a `call` record with a `call_id`; when results
  #   are traced, its frame waits on the calling process's stack until its
  #   `return_from` or `exception_from` arrives, which pairs the result with
  #   the call (`call_id`, `duration_us`, and for an exception the call's
  #   arguments). The runtime delivers each process's messages in order and
  #   every traced call has exactly one result, so a stack per process pairs
  #   exactly, recursion included. A call shed after `max_calls` still takes
  #   its place on the stack (a frame without a `call_id`), so its result is
  #   shed rather than taken for an outer call's. At most `@frames_max`
  #   frames wait; beyond that, or if a result does not match the frame on
  #   top of its stack, pairing is no longer exact and the whole trace stops
  #   (`pairing_limit`, `pairing_lost`): no pairing is ever guessed.
  # - Only the first `@open_max` waiting frames keep their rendered
  #   arguments; an exception of a later one says
  #   `"arguments_omitted" => "open_frames_limit"`.
  # - Limits, as recon_trace's: after `max_calls` calls no new call is
  #   traced (`:stop_calls`), but the results of the calls already running
  #   are still recorded; more than `rate_max` trace messages within
  #   `rate_ms` (by the messages' own timestamps) stop everything
  #   (`:stop_all`). Either writes one `call.stopped` record with the
  #   reason. A message that arrives after its limit is counted as `shed`.
  # - Values are rendered by `Insider.Collector.Rich` (credentials masked,
  #   `max_bytes` JSON bytes each) only in the rich profile; the strict one
  #   renders nothing, so its payloads are `nil`, and its call messages
  #   carry only the arity (`{m, f, arity}`).

  alias Insider.Collector.Rich
  alias Insider.Event
  alias Insider.Redaction.Credentials
  alias Insider.Identity.Subject

  @open_max 256
  @frames_max 16_384

  @type results :: :none | :exceptions | :all
  @type action :: nil | :stop_calls | :stop_all
  @type entry :: %{
          kind: String.t(),
          severity: :info | :warning | :error,
          pid: pid() | nil,
          at_ns: integer(),
          attributes: map(),
          payload: map() | nil
        }
  @type t :: %__MODULE__{}

  # Watched writes (`watch_writes`): a call of one of these functions is a
  # write of an in-memory value, and its record says so (`"write"`) with
  # the key it writes (`"key"`): the first argument, or the first two for
  # `Application.put_env` and `:application.set_env`, when each is an atom
  # or a binary of at most @key_bytes, credential-masked. Under strict the
  # call message carries only the arity, so the write's match spec sends
  # the key alone as the message (`Insider.Collector.Calls.Tracing`).
  @key_bytes 128
  @pair_keys [{Application, :put_env}, {:application, :set_env}]

  defstruct [
    :functions,
    :results,
    :max_calls,
    :rate_max,
    :rate_ms,
    :max_bytes,
    :rich,
    writes: MapSet.new(),
    phase: :tracing,
    calls: 0,
    window_ns: nil,
    window_count: 0,
    open: %{},
    open_count: 0,
    received: 0,
    shed: 0,
    invalid: 0
  ]

  @doc """
  A new trace. `functions` pairs each traced `{module, function, arity}`
  with its label (`"MOD.FUN/ARITY"`), `rate` is `{max, per_ms}`.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    {rate_max, rate_ms} = Keyword.fetch!(options, :rate)

    %__MODULE__{
      functions: Map.new(Keyword.fetch!(options, :functions)),
      writes: MapSet.new(Keyword.get(options, :writes, [])),
      results: Keyword.fetch!(options, :results),
      max_calls: Keyword.fetch!(options, :max_calls),
      rate_max: rate_max,
      rate_ms: rate_ms,
      max_bytes: Keyword.fetch!(options, :max_bytes),
      rich: Keyword.get(options, :rich, false)
    }
  end

  @doc "The most waiting call frames that keep their rendered arguments."
  @spec open_max() :: pos_integer()
  def open_max, do: @open_max

  @doc "The most call frames waiting for their result before pairing stops."
  @spec frames_max() :: pos_integer()
  def frames_max, do: @frames_max

  @doc "Scalar accounting for the collector's status."
  @spec counts(t()) :: map()
  def counts(trace) do
    %{
      received: trace.received,
      shed: trace.shed,
      invalid: trace.invalid,
      calls: trace.calls,
      open: trace.open_count,
      stopped: if(trace.phase == :tracing, do: 0, else: 1)
    }
  end

  @doc "Handles one trace message."
  @spec handle(t(), term()) :: {t(), [entry()], action()}
  def handle(trace, {:trace_ts, pid, :call, {m, f, args}, ns})
      when is_pid(pid) and (is_list(args) or is_integer(args)) and is_integer(ns),
      do: handle_call(trace, pid, {m, f, args}, :none, ns)

  # A watched write under strict: the match spec's message is its key.
  def handle(trace, {:trace_ts, pid, :call, {m, f, args}, message, ns})
      when is_pid(pid) and (is_list(args) or is_integer(args)) and is_integer(ns),
      do: handle_call(trace, pid, {m, f, args}, {:key, message}, ns)

  def handle(trace, {:trace_ts, pid, port, {m, f, a}, value, ns})
      when port in [:return_from, :exception_from] and is_pid(pid) and is_integer(ns) do
    trace = %{trace | received: trace.received + 1}

    with true <- trace.phase != :stopped,
         {:ok, label} <- Map.fetch(trace.functions, {m, f, a}),
         {:ok, trace} <- within_rate(trace, ns) do
      case pop(trace, pid, label) do
        {:ok, trace, %{id: nil}} -> {shed(trace), [], nil}
        {:ok, trace, frame} -> {trace, result(trace, port, pid, label, frame, value, ns), nil}
        :empty -> {shed(trace), [], nil}
        :mismatch -> fail(shed(trace), "pairing_lost", ns)
      end
    else
      false -> {shed(trace), [], nil}
      :error -> {%{trace | invalid: trace.invalid + 1}, [], nil}
      {:rate, trace, records} -> {trace, records, :stop_all}
    end
  end

  def handle(trace, _message),
    do: {%{trace | received: trace.received + 1, invalid: trace.invalid + 1}, [], nil}

  defp handle_call(trace, pid, {m, f, args}, message, ns) do
    trace = %{trace | received: trace.received + 1}
    arity = if is_list(args), do: length(args), else: args

    case Map.fetch(trace.functions, {m, f, arity}) do
      {:ok, label} ->
        if MapSet.member?(trace.writes, {m, f, arity}),
          do:
            traced_call(trace, pid, {label, key({m, f}, args, message)}, masked({m, f}, args), ns),
          else: traced_call(trace, pid, {label, nil}, args, ns)

      :error ->
        {%{trace | invalid: trace.invalid + 1}, [], nil}
    end
  end

  # `{:write, key}` for a watched write, the key `nil` when it is no name.
  defp key(mf, _args, {:key, message}), do: {:write, key_text(mf, message)}

  defp key(mf, [first, second | _rest], :none) when mf in @pair_keys,
    do: {:write, key_text(mf, {first, second})}

  defp key(mf, [first | _rest], :none), do: {:write, key_text(mf, first)}
  defp key(_mf, _args, :none), do: {:write, nil}

  # The values a watched write stores, after its key, are masked whole
  # (`[masked: N bytes]`, a term's external size) when the key is
  # credential-named or the value is a secret-shaped binary, before they are
  # rendered, kept on the stack, or recorded; the renderer masks what is
  # nested inside the rest.
  defp masked(mf, args) when is_list(args) do
    {keys, values} = Enum.split(args, if(mf in @pair_keys, do: 2, else: 1))
    credential? = Enum.any?(keys, &Credentials.credential_key?/1)
    keys ++ Enum.map(values, &if(credential? or secret?(&1), do: mask_value(&1), else: &1))
  end

  defp masked(_mf, arity), do: arity

  defp secret?(value) when is_binary(value), do: Credentials.mask_text(value) != value
  defp secret?(_value), do: false

  defp mask_value(value) when is_binary(value), do: "[masked: #{byte_size(value)} bytes]"
  defp mask_value(value), do: "[masked: #{:erlang.external_size(value)} bytes]"

  defp key_text(_mf, {first, second}) do
    with a when is_binary(a) <- name(first),
         b when is_binary(b) <- name(second),
         do: a <> " " <> b,
         else: (_none -> nil)
  end

  defp key_text(_mf, value), do: name(value)

  defp name(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: value |> Atom.to_string() |> name()

  defp name(value) when is_binary(value) and byte_size(value) <= @key_bytes do
    if String.valid?(value), do: Credentials.mask_text(value)
  end

  defp name(_value), do: nil

  @doc """
  The `insider.event/v1` of one record. `context` has `:node`, `:boot_id`,
  `:clock_id` (monotonic microseconds), `:authority`, `:source_instance_id`,
  `:sequence`, and `:offset_ns`, the OS clock's offset from monotonic time,
  which turns the trace timestamp into a wall time on the clock the other
  collectors use. A payload that does not fit an event
  is withheld, and the event says so with `"payload_withheld"`.
  """
  @spec event(entry(), map()) :: {:ok, Event.t()} | {:error, term()}
  def event(record, context) do
    fields = [
      id: context.source_instance_id <> "-" <> Integer.to_string(context.sequence, 36),
      node: context.node,
      boot_id: context.boot_id,
      source: "calls",
      kind: record.kind,
      severity: record.severity,
      monotonic_time: div(record.at_ns, 1_000),
      clock_id: context.clock_id,
      source_instance_id: context.source_instance_id,
      source_sequence: context.sequence,
      wall_time: DateTime.from_unix!(div(record.at_ns + context.offset_ns, 1_000), :microsecond),
      subject: subject(record.pid, context.node),
      causality: %{
        trace_id: nil,
        span_id: nil,
        parent_event_id: nil,
        logical_operation_id: nil,
        process_generation: nil
      },
      attributes: record.attributes,
      payload: record.payload,
      authority: context.authority,
      redactions: [],
      extensions: %{}
    ]

    case Event.new(fields) do
      {:ok, event} ->
        {:ok, event}

      {:error, _unfit} when record.payload != nil ->
        attributes = Map.put(record.attributes, "payload_withheld", true)
        Event.new(Keyword.merge(fields, payload: nil, attributes: attributes))

      {:error, _reason} = error ->
        error
    end
  end

  defp subject(nil, _node), do: nil

  defp subject(pid, node),
    do: Subject.new!("process", pid |> :erlang.pid_to_list() |> to_string(), node)

  @doc """
  Stops everything because the collector is overloaded: its queue
  (`"overload"`) or the bytes its waiting messages hold (`"ingress_bytes"`).
  One `call.stopped` record, unless the trace has already stopped.
  """
  @spec overload(t(), integer(), String.t()) :: {t(), [entry()], action()}
  def overload(trace, ns, reason \\ "overload")
  def overload(%{phase: :stopped} = trace, _ns, _reason), do: {trace, [], nil}
  def overload(trace, ns, reason), do: fail(trace, reason, ns)

  defp fail(trace, reason, ns),
    do: {%{trace | phase: :stopped}, [stopped(trace, reason, ns)], :stop_all}

  defp shed(trace), do: %{trace | shed: trace.shed + 1}

  defp traced_call(%{phase: :stopped} = trace, _pid, _label, _args, _ns),
    do: {shed(trace), [], nil}

  defp traced_call(trace, pid, {label, nil}, args, ns),
    do: traced_call(trace, pid, label, args, ns)

  defp traced_call(%{phase: :tracing} = trace, pid, {label, {:write, key}}, args, ns) do
    {trace, records, action} = traced_call(trace, pid, label, args, ns)

    records =
      Enum.map(records, fn
        %{kind: "call", attributes: %{"function" => ^label}} = record ->
          %{record | attributes: Map.merge(record.attributes, %{"write" => true, "key" => key})}

        record ->
          record
      end)

    {trace, records, action}
  end

  defp traced_call(trace, pid, {label, _write}, args, ns),
    do: traced_call(trace, pid, label, args, ns)

  # A call shed after `max_calls` keeps its place on its process's stack.
  defp traced_call(%{phase: :draining} = trace, pid, label, _args, ns) do
    case push(shed(trace), pid, frame(label, nil, ns, nil)) do
      {:ok, trace} -> {trace, [], nil}
      :full -> fail(shed(trace), "pairing_limit", ns)
    end
  end

  defp traced_call(trace, pid, label, args, ns) do
    case within_rate(trace, ns) do
      {:ok, trace} -> call(trace, pid, label, args, ns)
      {:rate, trace, records} -> {trace, records, :stop_all}
    end
  end

  defp frame(label, id, ns, args),
    do: %{label: label, id: id, ns: ns, args: args, args_omitted: false}

  defp call(trace, pid, label, args, ns) do
    call_id = trace.calls + 1
    arguments = if is_list(args), do: render(trace, args)
    trace = %{trace | calls: call_id}

    record = %{
      kind: "call",
      severity: :info,
      pid: pid,
      at_ns: ns,
      attributes: %{"function" => label, "call_id" => call_id},
      payload: if(trace.rich, do: %{"arguments" => arguments})
    }

    case push(trace, pid, frame(label, call_id, ns, arguments)) do
      :full ->
        {trace, records, action} = fail(trace, "pairing_limit", ns)
        {trace, [record | records], action}

      {:ok, trace} when call_id >= trace.max_calls ->
        trace = %{trace | phase: :draining}
        {trace, [record, stopped(trace, "calls_max", ns)], :stop_calls}

      {:ok, trace} ->
        {trace, [record], nil}
    end
  end

  defp result(%{results: :all} = trace, :return_from, pid, label, frame, value, ns) do
    [
      %{
        kind: "call.return",
        severity: :info,
        pid: pid,
        at_ns: ns,
        attributes: paired(label, frame, ns),
        payload: if(trace.rich, do: %{"result" => render(trace, value)})
      }
    ]
  end

  defp result(%{results: results} = trace, :exception_from, pid, label, frame, value, ns)
       when results in [:exceptions, :all] do
    {class, reason} = class_reason(value)
    {exception, normalized} = exception(class, reason)

    attributes =
      label
      |> paired(frame, ns)
      |> Map.merge(%{"class" => class, "exception" => exception})
      |> put_omitted(trace.rich and frame.args_omitted)

    payload =
      if trace.rich,
        do: %{"reason" => render(trace, normalized), "arguments" => frame.args}

    [
      %{
        kind: "call.exception",
        severity: :error,
        pid: pid,
        at_ns: ns,
        attributes: attributes,
        payload: payload
      }
    ]
  end

  defp result(_trace, _port, _pid, _label, _frame, _value, _ns), do: []

  defp paired(label, frame, ns),
    do: %{
      "function" => label,
      "call_id" => frame.id,
      "duration_us" => div(max(ns - frame.ns, 0), 1_000)
    }

  defp class_reason({class, reason}) when class in [:error, :exit, :throw],
    do: {Atom.to_string(class), reason}

  defp class_reason(value), do: {"unknown", value}

  # An `:error` reason is normalised as `rescue` would see it (`:badarith`
  # is an `ArithmeticError`); the struct's module names the exception.
  defp exception("error", reason) do
    case Exception.normalize(:error, reason, []) do
      %module{__exception__: true} = normalized -> {short(module), normalized}
      _other -> {nil, reason}
    end
  rescue
    _error -> {nil, reason}
  end

  defp exception(_class, reason), do: {nil, reason}

  defp short(module), do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp render(%{rich: false}, _value), do: nil
  defp render(trace, value), do: Rich.render(value, trace.max_bytes)

  defp stopped(trace, reason, ns) do
    %{
      kind: "call.stopped",
      severity: :warning,
      pid: nil,
      at_ns: ns,
      attributes: %{
        "reason" => reason,
        "calls" => trace.calls,
        "calls_max" => trace.max_calls,
        "rate_max" => trace.rate_max,
        "rate_ms" => trace.rate_ms,
        "open" => trace.open_count,
        "results_still_recorded" => reason == "calls_max" and trace.results != :none
      },
      payload: nil
    }
  end

  # The rate counts every trace message by its own timestamp, in windows of
  # `rate_ms` that start at the first message after the previous window.
  defp within_rate(trace, ns) do
    window_ns = trace.rate_ms * 1_000_000

    trace =
      if is_nil(trace.window_ns) or ns - trace.window_ns >= window_ns,
        do: %{trace | window_ns: ns, window_count: 1},
        else: %{trace | window_count: trace.window_count + 1}

    if trace.window_count > trace.rate_max do
      trace = %{trace | phase: :stopped, shed: trace.shed + 1}
      {:rate, trace, [stopped(trace, "calls_rate", ns)]}
    else
      {:ok, trace}
    end
  end

  defp put_omitted(attributes, true),
    do: Map.put(attributes, "arguments_omitted", "open_frames_limit")

  defp put_omitted(attributes, false), do: attributes

  defp push(%{results: :none} = trace, _pid, _frame), do: {:ok, trace}
  defp push(%{open_count: count}, _pid, _frame) when count >= @frames_max, do: :full

  defp push(trace, pid, frame) do
    frame =
      if trace.open_count >= @open_max and frame.args != nil,
        do: %{frame | args: nil, args_omitted: true},
        else: frame

    {:ok,
     %{
       trace
       | open: Map.update(trace.open, pid, [frame], &[frame | &1]),
         open_count: trace.open_count + 1
     }}
  end

  # Results arrive innermost first, so the frame on top of the process's
  # stack is the call this result belongs to. Another function's frame on
  # top means pairing is no longer exact. An empty stack belongs to no
  # call this trace saw.
  defp pop(trace, pid, label) do
    case Map.get(trace.open, pid) do
      [%{label: ^label} = frame | rest] ->
        open =
          if rest == [], do: Map.delete(trace.open, pid), else: Map.put(trace.open, pid, rest)

        {:ok, %{trace | open: open, open_count: trace.open_count - 1}, frame}

      [_other | _rest] ->
        :mismatch

      nil ->
        :empty
    end
  end
end
