defmodule Insider.Sentinel.Sandbox.ProviderCall do
  @moduledoc false

  alias Insider.Protocol.Value
  alias Insider.Sentinel.Sandbox.CleanupOwnership

  @maximum_output_bytes 65_536
  @dispatch_reserve_ms 5
  @ownership_timeout_ms 50
  @termination_grace_ms 50

  @type termination :: :not_started | {:observed, term()} | :unconfirmed
  @type outcome :: %{result: term(), termination: termination()}

  @spec start(pid(), module(), atom(), list(), integer(), keyword()) ::
          {:ok, map()} | {:error, :provider_deadline_expired, :not_started}
  def start(recipient, provider, function, arguments, deadline, options \\ []) do
    if live_deadline?(deadline) do
      reference = make_ref()
      ownership = Keyword.get(options, :ownership)
      gate = if ownership, do: make_ref()

      linked = Keyword.get(options, :link, false) or not is_nil(ownership)
      spawn_options = [:monitor] ++ if(linked, do: [:link], else: [])

      {pid, monitor} =
        :erlang.spawn_opt(
          fn ->
            await_start(gate)

            result =
              if dispatch_deadline?(deadline),
                do: invoke(provider, function, arguments),
                else: {:insider_provider_call, :not_started, :provider_deadline_expired}

            send(recipient, {reference, result})
          end,
          spawn_options
        )

      register_ownership(ownership, pid, deadline)
      if gate, do: send(pid, {:begin_provider_call, gate})
      {:ok, %{monitor: monitor, ownership: ownership, pid: pid, reference: reference}}
    else
      {:error, :provider_deadline_expired, :not_started}
    end
  end

  @spec call(module(), atom(), list(), integer(), keyword()) :: outcome()
  def call(provider, function, arguments, deadline, options \\ []) do
    cancel_reference = Keyword.get(options, :cancel_reference)

    case start(self(), provider, function, arguments, deadline, options) do
      {:ok, call} -> await_result(call, deadline, cancel_reference)
      {:error, reason, :not_started} -> %{result: {:error, reason}, termination: :not_started}
    end
  end

  defp await_result(call, deadline, cancel_reference) do
    receive do
      {reference, result} when reference == call.reference ->
        await_completed_termination(call, result, deadline, cancel_reference)

      {:DOWN, monitor, :process, pid, reason}
      when monitor == call.monitor and pid == call.pid ->
        release_ownership(call, deadline)
        %{result: {:error, :provider_failed}, termination: {:observed, reason}}

      {:cancel_provider_call, reference}
      when is_reference(cancel_reference) and reference == cancel_reference ->
        terminate_call(call, :provider_cancelled)
    after
      remaining(deadline) -> terminate_call(call, :provider_timeout)
    end
  end

  defp await_completed_termination(call, result, deadline, cancel_reference) do
    receive do
      {:DOWN, monitor, :process, pid, reason}
      when monitor == call.monitor and pid == call.pid ->
        release_ownership(call, deadline)
        %{result: result, termination: {:observed, reason}}

      {:cancel_provider_call, reference}
      when is_reference(cancel_reference) and reference == cancel_reference ->
        terminate_call(call, :provider_cancelled)
    after
      remaining(deadline) -> terminate_call(call, :provider_timeout)
    end
  end

  defp terminate_call(call, reason) do
    Process.exit(call.pid, :kill)

    termination =
      receive do
        {:DOWN, monitor, :process, pid, reason}
        when monitor == call.monitor and pid == call.pid ->
          release_ownership(call, System.monotonic_time(:millisecond))
          {:observed, reason}
      after
        @termination_grace_ms -> :unconfirmed
      end

    %{result: {:error, reason}, termination: termination}
  end

  defp await_start(nil), do: :ok

  defp await_start(gate) do
    receive do
      {:begin_provider_call, ^gate} -> :ok
    end
  end

  defp register_ownership(nil, _pid, _deadline), do: :ok

  defp register_ownership({ownership, key}, pid, deadline),
    do: :ok = CleanupOwnership.register(ownership, key, pid, ownership_timeout(deadline))

  defp release_ownership(%{ownership: {ownership, key}, pid: pid}, deadline),
    do: CleanupOwnership.unregister(ownership, key, pid, ownership_timeout(deadline))

  defp release_ownership(_call, _deadline), do: :ok

  defp ownership_timeout(deadline),
    do: min(@ownership_timeout_ms, max(0, deadline - System.monotonic_time(:millisecond)))

  defp invoke(provider, function, arguments) do
    result = apply(provider, function, arguments)

    if Value.bounded_data?(result, @maximum_output_bytes),
      do: result,
      else: {:error, :invalid_output}
  catch
    _kind, _reason -> {:error, :provider_failed}
  end

  defp live_deadline?(deadline),
    do: is_integer(deadline) and deadline > System.monotonic_time(:millisecond)

  defp dispatch_deadline?(deadline),
    do:
      is_integer(deadline) and
        deadline - System.monotonic_time(:millisecond) > @dispatch_reserve_ms

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
