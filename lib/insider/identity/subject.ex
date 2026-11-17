defmodule Insider.Identity.Subject do
  @moduledoc """
  Portable, application-declared diagnostic identity.

  Subjects are string-keyed maps so they can be embedded directly in an
  `Insider.Event` without atom creation at an external trust boundary.
  """

  alias Insider.Protocol.Error

  @type t :: %{
          required(String.t()) => String.t() | nil
        }

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(namespace, value, scope \\ nil) do
    subject = %{"namespace" => namespace, "scope" => scope, "value" => value}

    if valid?(subject) do
      {:ok, subject}
    else
      invalid("subject must contain bounded namespace, scope, and value strings")
    end
  end

  @spec new!(term(), term(), term()) :: t()
  def new!(namespace, value, scope \\ nil) do
    case new(namespace, value, scope) do
      {:ok, subject} -> subject
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{"namespace" => namespace, "scope" => scope, "value" => value} = subject)
      when map_size(subject) == 3 do
    vocabulary?(namespace) and bounded_id?(value) and (is_nil(scope) or bounded_id?(scope))
  end

  def valid?(_subject), do: false

  defp bounded_id?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp vocabulary?(value) do
    bounded_id?(value) and String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)
  end

  defp invalid(message),
    do: {:error, Error.new(:invalid_identity, message)}
end
