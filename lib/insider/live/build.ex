defmodule Insider.Live.Build do
  @moduledoc false

  # The identity of the Insider build this node runs: the `:insider`
  # application version as loaded, the commit the build was compiled from,
  # and a SHA-256 over the MD5 of every module of that application as
  # currently loaded. Two builds of one version from different commits, or
  # from a modified working tree, therefore differ. So do the same modules
  # under another application version, and a node where only some modules
  # were replaced. `mix insider.live --load` compares the target's identity
  # with its own.

  @spec identity() :: %{String.t() => String.t() | nil}
  def identity do
    %{
      "version" => version(),
      "commit" => Insider.Live.Revision.commit(),
      "beams_sha256" => beams_sha256()
    }
  end

  defp version do
    case :application.get_key(:insider, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> nil
    end
  end

  defp beams_sha256 do
    modules =
      case :application.get_key(:insider, :modules) do
        {:ok, modules} -> modules
        :undefined -> []
      end

    modules
    |> Enum.sort()
    |> Enum.map(&[Atom.to_string(&1), 0, loaded_md5(&1)])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp loaded_md5(module) do
    case :code.ensure_loaded(module) do
      {:module, ^module} -> module.module_info(:md5)
      {:error, _reason} -> "unloaded"
    end
  end
end
