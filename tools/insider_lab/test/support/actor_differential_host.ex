defmodule Insider.Test.ActorDifferentialHost do
  @moduledoc false

  # A fixture host for the actor differential oracle: an in-memory bid store
  # whose withdrawal endpoint applies a configurable access policy. Bids
  # belong to a bidder and a seller, and any other user is a stranger.
  # Responses have a GraphQL mutation's shape.

  use Agent

  def start_link(_options), do: Agent.start_link(fn -> %{bids: %{}, sequence: 0} end)

  @doc "Creates one open bid and returns its parties."
  def fixture(store) do
    Agent.get_and_update(store, fn state ->
      number = state.sequence + 1
      bid_id = "bid-#{number}"

      bid = %{
        status: :open,
        amount: 9,
        bidder: "bidder-#{number}",
        seller: "seller-#{number}"
      }

      fixture = %{
        store: store,
        bid_id: bid_id,
        bidder: bid.bidder,
        seller: bid.seller,
        stranger: "stranger-#{number}"
      }

      {fixture, %{state | sequence: number, bids: Map.put(state.bids, bid_id, bid)}}
    end)
  end

  @doc """
  Withdraws the bid as `user`. `policy` decides whether the user may, and
  `write` decides what the store records (`:on_grant`, `:never`, `:always`).
  """
  def withdraw(fixture, user, policy, write \\ :on_grant) do
    bid = bid(fixture)
    granted = policy.(user, bid)

    if write == :always or (granted and write == :on_grant) do
      Agent.update(fixture.store, fn state ->
        put_in(state, [:bids, fixture.bid_id, :status], :withdrawn)
      end)
    end

    if granted do
      %{
        "data" => %{
          "withdrawBid" => %{
            "__typename" => "WithdrawBidSuccess",
            "withdrawnBidId" => fixture.bid_id
          }
        }
      }
    else
      %{
        "data" => %{"withdrawBid" => nil},
        "errors" => [
          %{
            "code" => "UNAUTHORIZED",
            "message" => "You're not allowed to access that resource",
            "path" => ["withdrawBid"]
          }
        ]
      }
    end
  end

  def bid(fixture), do: Agent.get(fixture.store, &Map.fetch!(&1.bids, fixture.bid_id))

  @doc "State projection free of ids, so fixtures built for different actors compare."
  def state(fixture) do
    bid = bid(fixture)
    %{status: bid.status, amount: bid.amount}
  end

  def bidder_only(user, bid), do: user == bid.bidder
  def any_party(user, bid), do: user in [bid.bidder, bid.seller]
  def nobody(_user, _bid), do: false
  def everybody(_user, _bid), do: true

  def granted?(response),
    do:
      match?(
        %{"data" => %{"withdrawBid" => %{"__typename" => "WithdrawBidSuccess"}}},
        response
      )
end
