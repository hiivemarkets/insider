defmodule Insider.Collector.ObanJob do
  @moduledoc false

  # An Oban job event's job, readable. Without it, readers decode
  # Oban args by hand. Oban Pro's decorator stores the decorated call's
  # argument as a `term-` prefixed, unpadded Base64 Erlang term.
  #
  # Two halves, so the emitting application process does bounded work only:
  #
  # - `attributes/1`, in the emitting process, every profile: the job's
  #   `job_id`, `worker`, `queue`, `attempt`, `max_attempts`, its `state`
  #   (the stop's outcome, else the job's), and `args_keys`, the args'
  #   top-level keys among the first @scan_keys the map iterator yields
  #   (identifier-shaped, at most @max_keys, sorted), with
  #   `args_keys_truncated` when there were more. Constant work, whatever
  #   the args hold. These are the code's names and counts, never a value.
  # - `terms/1`, in the emitting process, rich only: the args' top-level
  #   `term-` strings among the same first @scan_keys entries, at most
  #   @max_terms of at most @term_bytes each, kept by reference (the rich
  #   renderer would mask them as high-entropy text before they could be
  #   decoded).
  # - `decode/1`, when a rich event is read (`Insider.Live.Disclosure`): the
  #   args as the rich payload rendered them, with those terms decoded
  #   (Base64, padded or not; `binary_to_term` with `:safe`, so no atom is
  #   created). A compressed term is never decoded (its expansion is
  #   unbounded), nor one that does not decode: both stay as they were. The
  #   caller renders and masks the result.

  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]
  @scan_keys 64
  @max_keys 16
  @key_bytes 64
  @term_bytes 2_048
  @max_terms 4
  @depth 6
  @name_bytes 128

  @doc "Whether `name` is an Oban job event."
  @spec event?([atom()]) :: boolean()
  def event?(name), do: name in @events

  @doc "Whether `kind` is an Oban job event's kind."
  @spec kind?(term()) :: boolean()
  def kind?(kind), do: kind in ["oban.job.start", "oban.job.stop", "oban.job.exception"]

  @doc "The job's names and counts, or `nil` when the metadata has no job."
  @spec attributes(map()) :: map() | nil
  def attributes(%{job: %{} = job} = metadata) do
    {keys, truncated?} = keys(Map.get(job, :args))

    %{
      "job_id" => integer(Map.get(job, :id)),
      "worker" => name(Map.get(job, :worker)),
      "queue" => name(Map.get(job, :queue)),
      "attempt" => integer(Map.get(job, :attempt)),
      "max_attempts" => integer(Map.get(job, :max_attempts)),
      "state" => name(Map.get(metadata, :state) || Map.get(job, :state)),
      "args_keys" => keys
    }
    |> then(&if(truncated?, do: Map.put(&1, "args_keys_truncated", true), else: &1))
  rescue
    _error -> nil
  end

  def attributes(_metadata), do: nil

  @doc "The args' top-level `term-` strings, by key, bounded; `nil` when none."
  @spec terms(map()) :: map() | nil
  def terms(%{job: %{args: %{} = args}}) when not is_struct(args) do
    {visited, _more?} = take(:maps.next(:maps.iterator(args)), @scan_keys, [], args)

    terms =
      for {key, "term-" <> rest = value} <- visited,
          name = key(key),
          name != nil,
          byte_size(rest) <= @term_bytes,
          do: {name, value}

    case Enum.take(terms, @max_terms) do
      [] -> nil
      terms -> Map.new(terms)
    end
  rescue
    _error -> nil
  end

  def terms(_metadata), do: nil

  # At most @scan_keys entries are visited, through the map's iterator.
  defp keys(%{} = args) when not is_struct(args) do
    {visited, more?} = take(:maps.next(:maps.iterator(args)), @scan_keys, [], args)
    keys = visited |> Enum.map(&key(elem(&1, 0))) |> Enum.reject(&is_nil/1) |> Enum.sort()
    {Enum.take(keys, @max_keys), more? or length(keys) > @max_keys}
  end

  defp keys(_args), do: {[], false}

  defp take(:none, _left, acc, _args), do: {acc, false}
  defp take(_iterator, 0, acc, _args), do: {acc, true}

  defp take({key, value, next}, left, acc, args),
    do: take(:maps.next(next), left - 1, [{key, value} | acc], args)

  @doc """
  Rendered job args with Oban Pro's `term-` values decoded, at read time.
  Anything else, and any value that does not decode, stays as it was.
  """
  @spec decode(term(), map() | nil) :: term()
  def decode(args, terms \\ nil)

  def decode(%{} = args, %{} = terms) when not is_struct(args),
    do: args |> Map.merge(terms) |> walk(0)

  def decode(args, _terms), do: walk(args, 0)

  defp walk("term-" <> encoded = original, _depth) when byte_size(encoded) <= @term_bytes do
    with {:ok, binary} <- base64(encoded),
         false <- compressed?(binary),
         {:ok, term} <- to_term(binary) do
      term
    else
      _undecodable -> original
    end
  end

  defp walk(%{} = map, depth) when not is_struct(map) and depth < @depth,
    do: Map.new(map, fn {key, value} -> {key, walk(value, depth + 1)} end)

  defp walk(list, depth) when is_list(list) and depth < @depth,
    do: Enum.map(list, &walk(&1, depth + 1))

  defp walk(value, _depth), do: value

  # External term format version 131, then tag 80: a zlib-compressed term.
  defp compressed?(<<131, 80, _rest::binary>>), do: true
  defp compressed?(_binary), do: false

  defp base64(encoded) do
    case Base.decode64(encoded, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> Base.decode64(encoded)
    end
  end

  defp to_term(binary) do
    # Reviewed (scanners flag "binary_to_term can lead to RCE"): the input is a
    # `term-` value from the app's own Oban job row, at most 2 KiB and never
    # compressed; `:safe` creates no atoms; this runs at read time in the
    # session owner, in dev/test/ci only; and the result is walked as data
    # and masked, never called. See decisions/2026-10-27_live_oban_args_*.
    # nosec
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _error -> :error
  end

  defp key(key) when is_atom(key), do: key |> Atom.to_string() |> key()

  defp key(key) when is_binary(key) and byte_size(key) <= @key_bytes do
    if String.match?(key, ~r/\A[A-Za-z_][A-Za-z0-9_.-]*\z/), do: key
  end

  defp key(_key), do: nil

  defp name(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "") |> name()

  defp name(value) when is_binary(value) and byte_size(value) <= @name_bytes do
    if String.match?(value, ~r/\A[A-Za-z_][A-Za-z0-9_.:-]*\z/), do: value
  end

  defp name(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil
end
