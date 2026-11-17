defmodule Insider.Identity.Generation do
  @moduledoc """
  Immutable evidence for one declared process incarnation.

  The PID is a physical address, not the stable identity. The generation token
  is scoped by node and boot ID, and the subject is explicitly declared by the
  process rather than inferred from its address or registration name.
  """

  alias Insider.Identity.Subject

  @enforce_keys [
    :id,
    :node,
    :boot_id,
    :pid,
    :subject,
    :logical_operation_id,
    :declared_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          node: String.t(),
          boot_id: String.t(),
          pid: pid(),
          subject: Subject.t(),
          logical_operation_id: String.t() | nil,
          declared_at: integer()
        }

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = generation) do
    expected = struct(__MODULE__)

    map_size(generation) == map_size(expected) and
      Enum.sort(Map.keys(generation)) == Enum.sort(Map.keys(expected)) and
      bounded_string?(generation.id, 128) and bounded_string?(generation.node, 256) and
      bounded_string?(generation.boot_id, 128) and is_pid(generation.pid) and
      Subject.valid?(generation.subject) and
      (is_nil(generation.logical_operation_id) or
         bounded_string?(generation.logical_operation_id, 128)) and
      is_integer(generation.declared_at)
  end

  def valid?(_generation), do: false

  defp bounded_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)
end
