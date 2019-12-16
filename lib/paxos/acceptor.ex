defmodule Paxos.Acceptor do
  @moduledoc """
  The acceptor process for the paxos algorithm,
  which accepts two message types: prepare and commit/accept requests.

  The first phase of the paxos protocol is the PREPARE-PROMISE handshake
  where the proposer sends a prepare message and the client responds with a promise not
  to accept a lower numbered value

  The second phase of the paxos protocol is the COMMIT-ACCEPTED handhshake
  It is often described as the ACCEPT-ACCEPTED handshake.
  """

  require Logger
  use GenServer
  import Paxos.Helper

  @empty_accepted {empty_proposal_id(), nil}
  @decline_response :sorry

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link() do
    GenServer.start_link(__MODULE__, :ok, name: Paxos.Acceptor)
  end

  def init(_) do
    Logger.debug("Starting acceptor server #{node()}")

    # Initialize to empty proposal number, numbers that are lower than any other
    # sequence number

    # When we start we have not promised anything or accepted a value
    # promise not to accept any ballot below this number, default empty proposal number
    highest_promise = empty_proposal_id()

    # the highest ballot number accepted, along with the value that has been accepted
    # default is {empty proposal number, 0}
    highest_accepted = @empty_accepted

    {:ok, {highest_promise, highest_accepted}}
  end

  # Phase 1 : Prepare-Promise
  # A prepare request will only turn into a promise if we haven't
  # already made any higher promises that prevents us.  If the proposal id is higher than promise
  def handle_call({:prepare, proposal_id}, _from, state) do
    {data, state} = do_prepare(proposal_id, state)
    {:reply, data, state}
  end

  # Phase 2 : Commit-Accepted
  # If the proposal id matches the highest promise state then proceed
  # Note we only keep the highest promise (not all the past promises set)
  def handle_call({:commit, proposal_id, value}, _from, {proposal_id, _}) do
    state = {proposal_id, {proposal_id, value}}
    data = {:accepted, proposal_id, value}
    {:reply, data, state}
  end

  # If the proposal id is less than the highest promise then decline to give a promise
  # Note: we only keep the highest promise (not all the past promises set)
  def handle_call({:commit, proposal_id, _v}, _from, {highest_promise, _} = state)
      when proposal_id < highest_promise do
    {:reply, @decline_response, state}
  end

  # Private helpers

  # Case 1
  # The proposal number is less than or equal to a proposal number we have already promised to
  # Respond politely that we are not interested in this consensus round
  defp do_prepare(lower_proposal_id, {highest_promise, _} = state)
       when is_higher_proposal(lower_proposal_id, highest_promise) == false do
    Logger.debug(
      "Acceptor prepare 1) #{node()} proposal: #{inspect(lower_proposal_id)} is not higher than highest promise: #{
        inspect(highest_promise)
      }"
    )

    {@decline_response, state}
  end

  # Case 2
  # Higher proposal n received and we don't have an accepted proposal and corresponding value,
  # Respond back with a promise not to accept any more proposals numbered less than n
  defp do_prepare(higher_proposal_id, {highest_promise, @empty_accepted})
       when is_higher_proposal(higher_proposal_id, highest_promise) do
    # Replace the highest_promise value with the proposal id
    state = {higher_proposal_id, @empty_accepted}

    Logger.debug(
      "Acceptor prepare 2) #{node()} proposal: #{inspect(higher_proposal_id)} received and we don't have accepted proposal yet"
    )

    {{:promise, higher_proposal_id}, state}
  end

  # Case 3
  # Higher proposal received and the acceptor has already accepted an earlier prepare message
  # Respond back with promise along with the current accepted value and the round/proposal_id we voted for this
  defp do_prepare(higher_proposal_id, {highest_promise, highest_accepted})
       when is_higher_proposal(higher_proposal_id, highest_promise) do
    # Return back 3-tuple with: # promise tag, proposal_id, highest accepted value
    data = {:promise, higher_proposal_id, highest_accepted}

    # Update the highest_promise with this proposal id
    state = {higher_proposal_id, highest_accepted}

    Logger.debug(
      "Acceptor prepare 3) #{node()} proposal: #{inspect(higher_proposal_id)} received and earlier acceptance available #{
        inspect(highest_accepted)
      }"
    )

    {data, state}
  end
end
