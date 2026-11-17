defmodule Insider.Lab.Output do
  @moduledoc """
  The single writer for the machine output of every Lab Mix task and the
  `insider-lab` escript.

  Their documents are UTF-8 bytes. `IO.binwrite/2` re-encodes every byte as a
  Latin-1 character on a device in Unicode mode, as standard output is under
  Mix, so `…` would print as `â€¦`; this writer hands the bytes to such a
  device as characters and to a Latin-1 device unchanged.
  """

  @doc """
  Writes the UTF-8 bytes of `iodata` to `device` unchanged and returns `:ok`,
  or the device's `{:error, reason}`. Integers in `iodata` are bytes, never
  code points.
  """
  @spec write(iodata(), IO.device()) :: :ok | {:error, term()}
  def write(iodata, device \\ :standard_io) do
    case :io.getopts(device) do
      options when is_list(options) ->
        # A Unicode device reads integers in a list as code points, so it
        # gets one binary, which it reads as UTF-8.
        if Keyword.get(options, :encoding) == :unicode,
          do: IO.write(device, IO.iodata_to_binary(iodata)),
          else: IO.binwrite(device, iodata)

      {:error, _reason} = error ->
        error
    end
  end
end
