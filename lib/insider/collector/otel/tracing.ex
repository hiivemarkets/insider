defmodule Insider.Collector.Otel.Tracing do
  @moduledoc false

  # Captures finished spans without touching the node's OpenTelemetry
  # configuration: no span processor, exporter, tracer, or sampler is
  # added, replaced, or reconfigured. The SDK ends every recorded span in
  # `otel_span_utils:end_span/2`, which returns the finished span record
  # before the node's own processors receive it. A call trace on that one
  # function, with a match specification that sends only the return value
  # (`{:message, false}` and `{:return_trace}`), delivers each finished span
  # to the receiver as a trace message. The span's processors and exporters
  # run exactly as before, including `traces_exporter: :none`.
  #
  # It runs only on OTP 28 and later, in an isolated trace session
  # (`:trace`), which cannot conflict with any other tracer on the node and
  # whose cleanup touches nothing else. OTP 27 has only node-global tracing,
  # where a process has one tracer and clearing a flag can clear another
  # tool's, so the component is refused there (`preflight/0`).
  #
  # `pause/1` turns delivery off and `resume/1` on again. Span ends while
  # paused are not observed at all; a counting trace session (`call_count`)
  # was tried and did not count span ends made concurrently with the switch
  # (on OTP 29, 8 producers: 29,000 of 80,000 span ends were neither
  # delivered nor counted), so a pause is reported as a loss of unknown size.
  @mfa {:otel_span_utils, :end_span, 2}
  @match_spec [{:_, [], [{:message, false}, {:return_trace}]}]

  # The SDK is optional and absent from Insider's own dependencies.
  @compile {:no_warn_undefined, [:otel_resource, :otel_tracer_provider]}
  # Dialyzer's PLT holds no OpenTelemetry modules; the calls are guarded.
  @dialyzer {:nowarn_function, service_name: 0}

  @type backend :: %{session: term()}

  @doc "The traced function: the SDK's span end."
  @spec traced_function() :: mfa()
  def traced_function, do: @mfa

  @doc """
  Whether the OpenTelemetry SDK is present on this node: its span-end
  function can be loaded. The SDK need not be started; until it is, no span
  ends.
  """
  @spec sdk_present?() :: boolean()
  def sdk_present? do
    {module, function, arity} = @mfa
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  @doc "Whether the SDK application is running, so spans can end."
  @spec sdk_running?() :: boolean()
  def sdk_running?, do: List.keymember?(Application.started_applications(), :opentelemetry, 0)

  @doc """
  The `service.name` of the SDK's global tracer provider resource, or `nil`.
  """
  @spec service_name() :: String.t() | nil
  def service_name do
    resource = :otel_tracer_provider.resource()
    {:attributes, _count, _length, _dropped, map} = :otel_resource.attributes(resource)

    case Map.get(map, :"service.name", Map.get(map, "service.name")) do
      name when is_binary(name) -> if String.valid?(name), do: name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  Whether the capture can run on this node: the SDK is present and the
  runtime has isolated trace sessions (OTP 28 and later).
  """
  @spec preflight() :: :ok | {:error, :sdk_absent | :requires_otp_28}
  def preflight do
    cond do
      not sdk_present?() -> {:error, :sdk_absent}
      otp_release() < 28 -> {:error, :requires_otp_28}
      true -> :ok
    end
  end

  @doc "Starts delivering finished spans to `receiver`."
  @spec install(pid()) :: {:ok, backend()} | {:error, atom()}
  def install(receiver) when is_pid(receiver) do
    case preflight() do
      :ok -> install_isolated(receiver)
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :trace_unavailable}
  catch
    _kind, _reason -> {:error, :trace_unavailable}
  end

  @doc """
  Asks the runtime to mark the point after every span already ended: the
  receiver gets `{:trace_delivered, :all, reference}` after their trace
  messages.
  """
  @spec delivered(backend()) :: {:ok, reference()} | :error
  def delivered(%{session: session}), do: {:ok, :trace.delivered(session, :all)}
  def delivered(_backend), do: :error

  @doc "Stops delivering span messages; spans that end meanwhile are not observed."
  @spec pause(backend()) :: :ok | :error
  def pause(%{session: session}) do
    _patterns = :trace.function(session, @mfa, false, [:global])
    :ok
  rescue
    _error -> :error
  end

  @doc "Delivers span messages again after `pause/1`."
  @spec resume(backend()) :: :ok | :error
  def resume(%{session: session}) do
    1 = :trace.function(session, @mfa, @match_spec, [:global])
    :ok
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc "Stops the capture. Returns the cleanup observation."
  @spec remove(backend() | nil) :: String.t()
  def remove(nil), do: "not_installed"

  def remove(%{session: session}) do
    if :trace.session_destroy(session), do: "removed", else: "already_removed"
  rescue
    _error -> "unavailable"
  catch
    _kind, _reason -> "unavailable"
  end

  @doc "Whether the span-end function is still traced by this backend."
  @spec installed?(backend() | nil) :: boolean()
  def installed?(nil), do: false

  def installed?(%{session: session}) do
    # The session answers, paused or not, until it is destroyed.
    match?({:all, [_ | _]}, :trace.info(session, @mfa, :all))
  rescue
    _error -> false
  end

  defp install_isolated(receiver) do
    session = :trace.session_create(:insider_otel, receiver, [])

    try do
      1 = :trace.function(session, @mfa, @match_spec, [:global])
      _processes = :trace.process(session, :all, true, [:call])
      {:ok, %{session: session}}
    rescue
      _error ->
        _destroyed = :trace.session_destroy(session)
        {:error, :trace_unavailable}
    end
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> List.to_integer()
end
