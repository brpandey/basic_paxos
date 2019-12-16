defmodule Paxos.Helper do
  @moduledoc """
  Provides helper utility routines around defguards,
  proposal numbers, ids, and so on
  """

  require Logger

  @hash_id Hashids.new(salt: "2pc")
  @skip_nodes [:"manager@127.0.0.1"]

  ############################################################################
  # Defguards allow customization of guards beyond the provided Kernel methods
  # They allow a simpler read and writing of the paxos algorithm
  # Unfortunately defguards don't support pattern matching

  # {time, node} = x
  defguardp is_id(x) when is_integer(elem(x, 0)) and is_binary(elem(x, 1))
  defguardp is_id_pair(x1, x2) when is_id(x1) and is_id(x2)

  # check if t1 > t2
  defguardp is_id_pair_time_gt(x1, x2) when is_id_pair(x1, x2) and elem(x1, 0) > elem(x2, 0)

  # check if t1 == t2
  defguardp is_id_pair_time_eq(x1, x2) when is_id_pair(x1, x2) and elem(x1, 0) == elem(x2, 0)

  # check if hostid1 > hostid2, the host id is effectively the node id
  defguardp is_id_pair_host_gt(x1, x2) when is_id_pair(x1, x2) and elem(x1, 1) > elem(x2, 1)

  # if the first time is greater than the second time, it is from a higher round
  # t1 > than t2, where x = {time, {node, pid}}
  # else if the times are the same, then compare the ids using erlang term ordering

  defguard is_higher_proposal(p1, p2)
           when is_id_pair(p1, p2) and
                  (is_id_pair_time_gt(p1, p2) or
                     (is_id_pair_time_eq(p1, p2) and is_id_pair_host_gt(p1, p2)))

  defguard is_round(x) when is_id(x)
  defguard is_skip_node(n) when n in @skip_nodes

  ############################################################################
  # Sequence numbers are a key part of paxos which form the round or proposal id.
  # We use a tuple with the first element the current microseconds value, which is an increasing integer 
  # The second is the proposer's node id

  # Helper methods for proposal id
  def empty_proposal_id() do
    # {time, node}
    {0, ""}
  end

  def init_proposal_id() do
    node_name = node() |> Atom.to_string()
    # time, node}
    {0, node_name}
  end

  # Proposers
  # Increment the ballot number by fetching the next time
  def next_proposal_id({_time, id}) when is_binary(id) do
    time = :os.system_time(:nanosecond)
    {time, id}
  end

  def get_node_id({_time, node}), do: node

  ############################################################################

  # We override the default multi_call node list with our own node_list() which
  # omits any nodes we don't wish to include
  def node_list() do
    list = [node() | Node.list()]

    Enum.reject(list, fn x ->
      case x do
        x when x in @skip_nodes -> true
        _ -> false
      end
    end)
  end

  # Seed random number generator
  def seed_prng() do
    <<a::32, b::32, c::32>> = :crypto.strong_rand_bytes(12)
    _ = :rand.seed(:exsplus, {a, b, c})
  end

  def sleep_uniform(msecs) when is_integer(msecs) do
    random = :rand.uniform(msecs)
    Logger.debug("sleep uniform delay is #{inspect(random)}, node is #{inspect(node())}")
    Process.sleep(random)
  end

  # To determine the largest server id, we take the server name and map it
  # to some unique value, which will provide some variability,
  # instead of using the literal server name for String greater comparisons
  def get_unique_node_id() do
    # split the node name from the ip address
    [name, _ip] = node() |> Atom.to_string() |> String.split("@")
    _id = Hashids.encode(@hash_id, String.to_charlist(name))
  end
end
