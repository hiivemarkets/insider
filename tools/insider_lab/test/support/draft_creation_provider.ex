defmodule Insider.TestSupport.DraftCreationProvider do
  @behaviour Insider.Sentinel.DraftCreation.Provider

  @identity %{
    "destination_fingerprint" => String.duplicate("a", 64),
    "id" => "test.draft-creation-provider",
    "version" => 1
  }

  @impl true
  def identity, do: @identity

  @impl true
  def create(request, idempotency_key, _deadline) do
    record({:provider, request, idempotency_key})

    case mode(:provider) do
      :created ->
        {:ok, response(request, idempotency_key, "created")}

      :existing ->
        {:ok, response(request, idempotency_key, "existing")}

      :rejected ->
        {:error, :rejected}

      :rate_limited ->
        {:error, :rate_limited}

      :malformed ->
        {:ok, %{"outcome" => "created"}}

      :wrong_key ->
        {:ok, response(request, "sha256:" <> String.duplicate("f", 64), "created")}

      :wrong_intent ->
        {:ok,
         %{
           response(request, idempotency_key, "created")
           | "intent_id" => "sha256:" <> String.duplicate("f", 64)
         }}

      :not_draft ->
        {:ok, %{response(request, idempotency_key, "created") | "draft" => false}}

      :review_optional ->
        {:ok, %{response(request, idempotency_key, "created") | "review_required" => false}}

      {:block, observer} when is_pid(observer) ->
        send(observer, {:draft_provider_blocked, self()})

        receive do
          :release_draft_provider ->
            {:ok, response(request, idempotency_key, "created")}
        end

      :crash ->
        raise "draft provider crashed"

      :timeout ->
        receive do: (:never -> :unreachable)
    end
  end

  def reset do
    :persistent_term.erase({__MODULE__, :provider_mode})
    :persistent_term.erase({__MODULE__, :authority_mode})
    :persistent_term.erase({__MODULE__, :calls})
  end

  def set_provider_mode(mode), do: :persistent_term.put({__MODULE__, :provider_mode}, mode)
  def set_authority_mode(mode), do: :persistent_term.put({__MODULE__, :authority_mode}, mode)

  def provider_calls do
    calls()
    |> Enum.filter(&match?({:provider, _, _}, &1))
    |> Enum.reverse()
  end

  def authority_calls do
    calls()
    |> Enum.filter(&match?({:authority, _, _}, &1))
    |> Enum.reverse()
  end

  defp response(request, idempotency_key, outcome),
    do: %{
      "draft" => true,
      "draft_reference" => "draft://test/42",
      "idempotency_key" => idempotency_key,
      "intent_id" => request["intent_id"],
      "outcome" => outcome,
      "review_required" => true
    }

  defp mode(:provider), do: :persistent_term.get({__MODULE__, :provider_mode}, :created)
  defp mode(:authority), do: :persistent_term.get({__MODULE__, :authority_mode}, :approved)

  defp calls, do: :persistent_term.get({__MODULE__, :calls}, [])
  defp record(call), do: :persistent_term.put({__MODULE__, :calls}, [call | calls()])

  defmodule DisclosureAuthority do
    @behaviour Insider.Sentinel.DraftCreation.DisclosureAuthority

    @identity %{"id" => "test.draft-disclosure-authority", "version" => 1}

    @impl true
    def identity, do: @identity

    @impl true
    def authorize(payload_reference, provider, _deadline) do
      Insider.TestSupport.DraftCreationProvider.record_authority(payload_reference, provider)

      case Insider.TestSupport.DraftCreationProvider.authority_mode() do
        :approved ->
          count = length(Insider.TestSupport.DraftCreationProvider.authority_calls())
          {:approved, "policy-decision-#{count}"}

        :denied ->
          {:denied, :candidate_disclosure_not_approved}

        :invalid ->
          {:approved, String.duplicate("x", 513)}

        :crash ->
          raise "disclosure authority crashed"

        :timeout ->
          receive do: (:never -> :unreachable)
      end
    end
  end

  def authority_mode, do: mode(:authority)
  def record_authority(payload, provider), do: record({:authority, payload, provider})

  defmodule Alternate do
    @behaviour Insider.Sentinel.DraftCreation.Provider

    @impl true
    def identity,
      do: %{
        "destination_fingerprint" => String.duplicate("b", 64),
        "id" => "test.alternate-draft-provider",
        "version" => 1
      }

    @impl true
    def create(_request, _idempotency_key, _deadline), do: {:error, :rejected}
  end

  defmodule Duplicate do
    @behaviour Insider.Sentinel.DraftCreation.Provider

    @impl true
    def identity, do: Insider.TestSupport.DraftCreationProvider.identity()

    @impl true
    def create(_request, _idempotency_key, _deadline), do: {:error, :rejected}
  end

  defmodule AlternateAuthority do
    @behaviour Insider.Sentinel.DraftCreation.DisclosureAuthority

    @impl true
    def identity, do: %{"id" => "test.alternate-disclosure-authority", "version" => 1}

    @impl true
    def authorize(_payload_reference, _provider, _deadline), do: {:denied, :not_approved}
  end

  defmodule DuplicateAuthority do
    @behaviour Insider.Sentinel.DraftCreation.DisclosureAuthority

    @impl true
    def identity, do: Insider.TestSupport.DraftCreationProvider.DisclosureAuthority.identity()

    @impl true
    def authorize(_payload_reference, _provider, _deadline), do: {:denied, :not_approved}
  end

  defmodule InvalidIdentity do
    @behaviour Insider.Sentinel.DraftCreation.Provider

    @impl true
    def identity, do: %{"id" => "missing-destination", "version" => 1}

    @impl true
    def create(_request, _idempotency_key, _deadline), do: {:error, :rejected}
  end
end
