defmodule Insider.TestSupport.SandboxBody do
  @behaviour Insider.Sentinel.Sandbox.Body

  @impl true
  def identity, do: %{"id" => "test.sandbox-body", "version" => 1}

  @impl true
  def run(arguments) do
    test = Process.whereis(Insider.TestSupport.SandboxBodyProbe)
    mode = arguments.input["mode"]
    send(test, {:sandbox_body_started, arguments.owner_id, self(), mode})

    case mode do
      "success" ->
        {:ok, %{"outcome" => "completed"}}

      "error" ->
        {:error, :body_failed, %{"outcome" => "failed"}}

      "block" ->
        receive do
          {:cancel_sandbox_body, reference}
          when reference == arguments.cancellation_reference ->
            send(test, {:sandbox_body_cancelled, arguments.owner_id, self()})
            {:cancelled, %{"outcome" => "cancelled"}}
        end

      "ignore_cancel" ->
        receive do
          :never -> {:ok, %{}}
        end

      "trap_exit" ->
        Process.flag(:trap_exit, true)
        trap_exit_loop(test, arguments.owner_id)
    end
  end

  defp trap_exit_loop(test, owner_id) do
    receive do
      {:EXIT, _pid, _reason} ->
        send(test, {:sandbox_body_survived_exit, owner_id, self()})
        trap_exit_loop(test, owner_id)

      {:cancel_sandbox_body, _reference} ->
        trap_exit_loop(test, owner_id)

      :stop ->
        exit(:kill)
    end
  end
end
