defmodule Insider.Discovery.ExUnit.OracleRunner.SafePath do
  @moduledoc false

  # The one rule for every relative file name the runner joins onto a run
  # directory, whether it comes from the closed oracle registry when staging or
  # from a decoded run record: a plain relative name, valid UTF-8 without
  # control bytes, with no empty, `.`, or `..` segment, that `Path.safe_relative/2`
  # returns unchanged. `join_under/2` additionally requires the expanded result
  # to stay under the expanded base.

  @maximum_bytes 4_096

  @spec relative?(term()) :: boolean()
  def relative?(path) when is_binary(path) and byte_size(path) in 1..@maximum_bytes do
    String.valid?(path) and not Enum.any?(:binary.bin_to_list(path), &(&1 < 0x20 or &1 == 0x7F)) and
      Path.type(path) == :relative and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
      Path.safe_relative(path, "/nonexistent-insider-base") == {:ok, path}
  end

  def relative?(_path), do: false

  @spec join_under(Path.t(), term()) :: {:ok, Path.t()} | :error
  def join_under(base, path) do
    base = Path.expand(base)
    joined = Path.expand(Path.join(base, path))

    if relative?(path) and String.starts_with?(joined, base <> "/"),
      do: {:ok, joined},
      else: :error
  end
end
