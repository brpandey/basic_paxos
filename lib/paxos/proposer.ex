defmodule Paxos.Proposer do
  @moduledoc """
  A Proposer seeks consensus in the paxos algorithm.

  In the prepare phase it selects a new distinct proposal number n and sends it
  to all acceptors with the intent of a) securing a majority of promises not to accept a proposal
  numbered less than n and b) learning the highest accepted proposal value so far from the acceptors.

  In the commit/accept phase it uses the consensus value v learned from the majority of promises
  received to then issue a specific proposal with number n and value v (or perhaps its own if non provided)
  to all acceptors.  
  """

  require Logger
  use GenServer
  use Retry
  import Paxos.Helper
  alias Paxos.Acceptor

  # Time out for the prepare and commit broadcasts and replies!
  @timeout 7_000

  # @handshake_timeout 3_000 # Not working with multi_call

  @decline_response :sorry
  @no_accepted_proposals {empty_proposal_id(), nil}
  @min_quorum 3

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  # Client API methods

  # Supervision tree instantiates the GenServer
  def start_link() do
    GenServer.start_link(__MODULE__, {}, name: __MODULE__)
  end

  # The proposer works in rounds.  In each round, the proposer will try to achieve acceptance
  # of the proposed value or atleast try to get acceptors to achieve agreement on any previous value.
  # It will keep trying but with a higher round number

  def start_delay(server \\ __MODULE__, value, delay, retry) do
    # sleep_uniform(delay)
    Logger.debug("About to sleep for #{inspect(delay)} #{inspect(node())}")
    Process.sleep(delay)

    case retry do
      true -> start(server, value)
      false -> start_simple(server, value)
    end
  end

  # If the round consensus attempt does not succeed, a new round is initiated
  def start(server \\ __MODULE__, value) do
    # If we have an error tuple return from the GenServer call we
    # retry with exponential backoff up and until 10 seconds before starting the next round

    retry with: exp_backoff() |> randomize() |> expiry(@timeout) do
      Logger.debug("In Proposer retry loop, #{inspect(server)}")
      start_simple(server, value)
    end
  end

  def start_simple(server \\ __MODULE__, value) do
    try do
      # We retry only if the data returned is an error tuple
      GenServer.call(server, {:start, value})
    catch
      :exit, {:timeout, _trace} ->
        {:error, :timeout}

      :exit, msg ->
        Logger.debug("msg is #{inspect(msg)}")
        {:error, :catch_all_error}
    end
  end

  # GenServer callbacks

  def init(_) do
    Process.flag(:trap_exit, true)

    # Enable monitoring of nodes in order to have an accurate view of what quorum means at any time
    :ok = :net_kernel.monitor_nodes(true, [])

    round = init_proposal_id()
    size = node_list() |> Enum.count()
    id = get_unique_node_id()

    seed_prng()

    # Return round, size
    {:ok, {round, id, size}}
  end

  # Used to assist leader election
  def handle_call(:get_id, _from, {_round, id, _size} = state) do
    {:reply, id, state}
  end

  # Run single round wrapped behind GenServer/actor msg queue
  def handle_call({:start, val}, _from, {round, id, size}) do
    Logger.debug(
      "Proposer #{inspect(node())}, peers #{inspect(Node.list())}, start round, #{inspect(round)}, trying with value #{
        inspect(val)
      }"
    )

    # Starts the new round, initiating both the prepare and commit handshakes with the peer nodes
    round = next_proposal_id(round)
    data = single_round(round, val, size)

    {:reply, data, {round, id, size}}
  end

  def handle_info({:nodedown, node}, state) when is_skip_node(node) do
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, {round, id, size}) do
    Logger.debug("proposer node down, node is #{node}")
    {:noreply, {round, id, size - 1}}
  end

  def handle_info({:nodeup, node}, state) when is_skip_node(node) do
    {:noreply, state}
  end

  def handle_info({:nodeup, node}, {round, id, size}) do
    Logger.debug("proposer node up, node is #{node}")
    {:noreply, {round, id, size + 1}}
  end

  # The proposer works in rounds.  In each round, the proposer will try to achieve acceptance
  # of the proposed value or atleast try to get acceptors to achieve agreement on any value.
  defp single_round(round, value, size) when is_round(round) and is_integer(size) do
    # We send multi-cast requests to neighboring peers

    # Starting first with the prepare handshake,
    # After determining consensus results, we attempt the propose handshake if warranted

    round
    |> prepare()
    |> collect(value, size, :promise)
    |> commit()
    |> collect(size, :accepted)
  end

  # Handshake methods

  # Handshake #1
  # A round/ballot is initialized by multi-casting a prepare message to all acceptors
  defp prepare(round) do
    {list, _} = GenServer.multi_call(node_list(), Acceptor, {:prepare, round})

    Logger.debug(
      "Proposer 1) PREPARE multi call for round #{inspect(round)}, results: #{inspect(list)}"
    )

    {round, Enum.sort(list)}
  end

  # Handshake #2
  defp commit({:error, _msg} = tuple), do: tuple

  defp commit({round, value}) do
    {list, _} = GenServer.multi_call(node_list(), Acceptor, {:commit, round, value})

    Logger.debug(
      "Proposer 2) COMMIT multi call results for round #{inspect(round)}, results: #{
        inspect(list)
      }"
    )

    {:ok, Enum.sort(list)}
  end

  ##############################################################################################################
  # Private Helper methods

  # NOTE: TODO FIX, if the size changes during the proposer start handle_call we will have an inaccurate
  # quorum count

  # The proposer collects all promises and also the accepted value with the highest proposal_id/round number so far
  defp collect({round, list}, value, size, :promise) when is_list(list) and is_integer(size) do
    if size < Enum.count(list) do
      raise "We've received more prepare responses than nodes available, this shouldn't be happening"
    end

    # If we have a majority of promises, iterate through the success nodes list to find the
    # highest accepted proposal number and corresponding value
    data = is_majority?(list, size) |> pick_consensus_value(round, value)

    Logger.debug(
      "Proposer 1.5) consensus value after PREPARE for round: #{inspect(round)}, size is #{size}, results #{
        inspect(data)
      }"
    )

    data
  end

  # The proposer collects accepted responses
  defp collect({:error, _msg} = tuple, _size, :accepted), do: tuple

  defp collect({:ok, list}, size, :accepted) when is_list(list) and is_integer(size) do
    if size < Enum.count(list) do
      raise "We've received more accepted responses than nodes available, this shouldn't be happening"
    end

    # If we have a quorum of accepted responses, return success
    {flag, _list} = is_majority?(list, size)

    # A list of 4 MapSets, for node, round, value, declines
    acc_list = {[MapSet.new(), MapSet.new(), MapSet.new()], MapSet.new()}

    # Compact results into accumulators
    {[nodes_acc, round_acc, value_acc], declines_acc} =
      Enum.reduce(list, acc_list, fn {node, v},
                                     {[nodes_acc, round_acc, value_acc] = succ_acc, declines_acc} ->
        case v do
          {:accepted, round, value} ->
            nodes_acc = MapSet.put(nodes_acc, node)
            round_acc = MapSet.put(round_acc, round)
            value_acc = MapSet.put(value_acc, value)
            {[nodes_acc, round_acc, value_acc], declines_acc}

          @decline_response ->
            {succ_acc, MapSet.put(declines_acc, node)}

          unknown ->
            Logger.debug("Received unexpected response value #{inspect(unknown)} ")
            {succ_acc, declines_acc}
        end
      end)

    # Compact result of accumulators into keyword list based on the results success
    # The wrapping of {:ok, _} or {:error, _} tuple is important because the retry macro
    # will only retry if it is an error tuple that is returned
    data =
      case flag do
        true ->
          {:ok,
           [
             nodes: MapSet.to_list(nodes_acc),
             status: :accepted,
             round: MapSet.to_list(round_acc),
             value: MapSet.to_list(value_acc),
             declines: MapSet.to_list(declines_acc)
           ]}

        false ->
          {:error, [nodes: MapSet.to_list(declines_acc), status: @decline_response]}
      end

    Logger.debug("Proposer 2.1) Commit cleaned up results, results are #{inspect(data)}")
    data
  end

  # Determine whether we have a majority of successful replies

  # NOTE: Some implementations note that if there is a single decline response we have to restart again
  # This constraint is relaxed, so that only a quorum needs to provide successful responses

  defp is_majority?(_list, size) when size < @min_quorum, do: {false, :less_than_min_quorum, []}

  defp is_majority?(list, size) when is_list(list) and is_integer(size) and size >= @min_quorum do
    {_nodes, responses} = Enum.unzip(list)

    # If node set size is atleast 3, we need to have atleast 2 promises
    # If node set size is atleast 4, we need to have atleast 3 promises
    # If node set size is atleast 5, we need to have atleast 3 promises
    quorum = Kernel.trunc(size / 2) + 1
    responses = Enum.reject(responses, fn x -> x == @decline_response end)
    flag = Enum.count(responses) >= quorum

    Logger.debug(
      "Proposer is majority? #{node()}, flag #{inspect(flag)}, promises #{inspect(responses)}, size is #{
        inspect(size)
      }"
    )

    {flag, responses}
  end

  # Pick the consensus value, if any, from the promises response messages during phase 1 of the protocol
  # If none of the responses have an earlier accepted value use the current proposer's desired value
  defp pick_consensus_value({false, :less_than_min_quorum, _p}, _r, _v),
    do: {:error, "prepare_nodes_below_min_quorum"}

  defp pick_consensus_value({false, _p}, _r, _v), do: {:error, "prepare_consensus_not_reached"}

  defp pick_consensus_value({true, promises}, round, proposer_value) when is_list(promises) do
    # Inspect the promise values selecting the highest accepted proposal id
    # and its associated value (should one exist)
    # if one doesn't exist, than the proposer can use its own value
    case Enum.reduce(promises, @no_accepted_proposals, fn x, acc -> reduce_promises(x, acc) end) do
      @no_accepted_proposals -> {round, proposer_value}
      {_highest_accepted_prop_id, highest_val} -> {round, highest_val}
    end
  end

  # Reduce promises helper routines

  # NOTE: Could optimize by removing proposal_id in promise response since ultimately
  # they aren't being used (_pr_id), making the promise message
  # either :promise or :promise, {accepted_proposal_id, accepted_proposal_value}

  # Case 1
  # Promise received without receiving an accepted proposal so return
  # the highest accumulated proposal id and value seen so far
  defp reduce_promises({:promise, _pr_id}, {acc_id, acc_val}) do
    {acc_id, acc_val}
  end

  # Case 2
  # Promise received with the details of an already accepted proposal
  # This promise contains a higher accepted proposal id than what we've seen so far, so we use the existing value
  defp reduce_promises({:promise, _pr_id, {a_id, max_val}}, {acc_id, _acc_val})
       when is_higher_proposal(a_id, acc_id) do
    {a_id, max_val}
  end

  # Case 3
  # Promise received with the details of an already accepted proposal
  # This promise does not contain a higher proposal since it follows case 2
  defp reduce_promises({:promise, _pr_id, {_a_id, _max_val}}, {acc_id, acc_val}) do
    {acc_id, acc_val}
  end
end
