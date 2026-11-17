defmodule Insider.Live.Inspect.Alloc do
  @moduledoc false

  # `Insider.Live.alloc/1`: the VM's memory allocators through
  # `recon_alloc`: what they hold from the OS (allocated), what is in use,
  # the share in use, allocated bytes by allocator type, and the current
  # fragmentation of the allocator instances with the largest multiblock
  # carriers. It needs recon; without it the result is
  # `component_unavailable`. Usage shares are integer percentages. recon is
  # called only after `Insider.Live.Inspect.recon/0` found it loaded; a
  # failure inside it ends the worker (`unavailable`).

  @compile {:no_warn_undefined, [:recon_alloc]}

  alias Insider.Live.Error
  alias Insider.Live.Inspect

  @schema "insider.live-alloc/v1"

  @spec lists() :: [[String.t()]]
  def lists, do: [["fragmentation"]]

  @spec inspect(map(), Inspect.context()) :: {:ok, map()} | {:error, map()}
  def inspect(_parsed, %{recon: false}), do: unavailable("not_loaded")

  def inspect(%{top: top}, %{recon: true}) do
    {:ok,
     %{
       "schema" => @schema,
       "implementation" => "recon",
       "allocated_bytes" => :recon_alloc.memory(:allocated),
       "used_bytes" => :recon_alloc.memory(:used),
       "usage_percent" => percent(:recon_alloc.memory(:usage)),
       "allocated_types" =>
         :allocated_types
         |> :recon_alloc.memory()
         |> Map.new(fn {type, bytes} -> {Atom.to_string(type), bytes} end),
       "fragmentation" =>
         :current
         |> :recon_alloc.fragmentation()
         |> Enum.map(&instance/1)
         |> Enum.sort_by(&{-&1["mbcs_carriers_bytes"], &1["allocator"], &1["instance"]})
         |> Enum.take(top),
       "note" =>
         "usage_percent is used_bytes over allocated_bytes; a low mbcs_usage_percent with large mbcs_carriers_bytes is fragmentation"
     }}
  end

  defp unavailable(reason),
    do:
      {:error, Error.new("component_unavailable", %{"component" => "recon", "reason" => reason})}

  defp instance({{allocator, instance}, values}) do
    %{
      "allocator" => Atom.to_string(allocator),
      "instance" => instance,
      "sbcs_usage_percent" => percent(values[:sbcs_usage]),
      "mbcs_usage_percent" => percent(values[:mbcs_usage]),
      "sbcs_block_bytes" => values[:sbcs_block_size],
      "sbcs_carriers_bytes" => values[:sbcs_carriers_size],
      "mbcs_block_bytes" => values[:mbcs_block_size],
      "mbcs_carriers_bytes" => values[:mbcs_carriers_size]
    }
  end

  defp percent(share) when is_number(share), do: round(share * 100)
  defp percent(_share), do: nil

  @spec event(map()) :: {map(), [String.t()]}
  def event(result) do
    {result
     |> Map.take(["allocated_bytes", "used_bytes", "usage_percent", "allocated_types"])
     |> Map.put("fragmentation", Enum.take(result["fragmentation"], 3)), ["fragmentation"]}
  end
end
