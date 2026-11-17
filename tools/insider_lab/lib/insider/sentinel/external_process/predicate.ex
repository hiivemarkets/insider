defmodule Insider.Sentinel.ExternalProcess.Predicate do
  @moduledoc false

  @spec identity?(term()) :: boolean()
  def identity?(value), do: Insider.Sentinel.Verification.Ingress.identity?(value)

  @spec digest?(term()) :: boolean()
  def digest?(value), do: Insider.Detectors.Input.digest?(value)

  @spec id?(term()) :: boolean()
  def id?(value) when is_binary(value) do
    case value do
      "sha256:" <> digest -> digest?(digest)
      _other -> false
    end
  end

  def id?(_value), do: false
end
