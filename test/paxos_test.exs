defmodule PaxosTest do
  use ExUnit.Case

  alias Paxos.{Leader}
  import Paxos.TestHelper
  require Logger

  setup_all do
    Application.ensure_all_started(:paxos)
    :ok
  end

  # Note: Proposer will retry if declined commits are wrapped in an error tuple, right now they are wrapped in an ok tuple

  # Start nodes, specify peer set size as param option
  setup context do
    size =
      case context[:case_key] do
        :medium -> 5
        _ -> 3
      end

    nodes = setup_nodes(size)

    on_exit(fn ->
      Logger.debug("Stopping nodes on Local Cluster -- CLEANUP")
      LocalCluster.stop_nodes(nodes)
      Process.sleep(1_000)
    end)

    {:ok, nodes: nodes}
  end

  describe "single proposer" do
    test "single proposer successfully working with set of acceptors", %{nodes: _nodes} do
      {:ok,
       [
         nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
         status: :accepted,
         round: [{_uid, "paxos2@127.0.0.1"}],
         value: ["pizza1"],
         declines: []
       ]} = Leader.start("pizza1")
    end

    test "single proposer working with set of acceptors, majority of which crash and then later self-heal",
         %{nodes: nodes} do
      [n1, n2, n3] = nodes

      # Partitioning n2 from n1 and n3
      Schism.partition([n2])

      # Wait for partition to occur
      Process.sleep(8_000)

      # Not enough peers for a min quorum
      assert {:error, "prepare_nodes_below_min_quorum"} = Leader.start("pizza2")

      # Reintroduce n2 back into cluster
      Schism.heal([n1, n2, n3])

      Process.sleep(8_000)

      # Verify we can achieve consensus now
      assert {:ok,
              [
                nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                status: :accepted,
                round: [{_uid, "paxos2@127.0.0.1"}],
                value: ["pizza2"],
                declines: []
              ]} =
               Leader.start("pizza2")
    end

    @tag case_key: :medium
    test "single proposer with first and second leader node dying", %{nodes: nodes} do
      [n1, n2, n3, n4, n5] = nodes

      # Wait for leader node to be selected
      Process.sleep(4_000)

      # The leader node is the same for all the peers
      assert n5 == Leader.get_leader({Leader, n1})
      assert n5 == Leader.get_leader({Leader, n2})
      assert n5 == Leader.get_leader({Leader, n3})
      assert n5 == Leader.get_leader({Leader, n4})
      assert n5 == Leader.get_leader({Leader, n5})

      # In the given nodes set we know that node 5 has the highest server id, so kill that
      LocalCluster.stop_nodes([n5])

      Process.sleep(2_000)

      # We have a quorum size of 4, with the leader being node 2
      assert {:ok,
              [
                nodes: [
                  :"paxos1@127.0.0.1",
                  :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1",
                  :"paxos4@127.0.0.1"
                ],
                status: :accepted,
                round: [{_uid, "paxos2@127.0.0.1"}],
                value: ["pizza2"],
                declines: []
              ]} = Leader.start("pizza2")

      # Try again, killing the next leader

      # The leader node is the same for all the peers
      assert n2 == Leader.get_leader({Leader, n1})
      assert n2 == Leader.get_leader({Leader, n2})
      assert n2 == Leader.get_leader({Leader, n3})
      assert n2 == Leader.get_leader({Leader, n4})

      # In the given nodes set we know that node 2 has the highest server id, so kill that
      LocalCluster.stop_nodes([n2])

      Process.sleep(2_000)

      # We still have a min quorum size of 3, and node 4 is the new leader node
      assert {:ok,
              [
                nodes: [:"paxos1@127.0.0.1", :"paxos3@127.0.0.1", :"paxos4@127.0.0.1"],
                status: :accepted,
                round: [{_uid, "paxos4@127.0.0.1"}],
                value: ["pizza2"],
                declines: []
              ]} = Leader.start("pizza3")
    end

    @tag case_key: :medium
    test "single proposer working with set of acceptors, majority of which crash, leaving a min quorum of 3",
         %{nodes: nodes} do
      [_n1, n2, _n3, n4, n5] = nodes

      # Partitioning n2 from n1 and n3
      Schism.partition([n2, n4, n5])

      # Wait for partition to occur
      Process.sleep(8_000)

      # We have a min quorum of 3, with n5 being the leader
      assert {:ok,
              [
                nodes: [:"paxos2@127.0.0.1", :"paxos4@127.0.0.1", :"paxos5@127.0.0.1"],
                status: :accepted,
                round: [{_uid, "paxos5@127.0.0.1"}],
                value: ["pizza2"],
                declines: []
              ]} = Leader.start("pizza2")
    end
  end

  # Illustrate the algorithm under dueling proposers who are able to cut the other off from a commit/accept
  # based on whether that proposer was able to get promises and the initial majority of accepts

  # By tweaking the start times of the proposers we can create these conditions
  # Below we are using 3 nodes (which is the minimum quorum) to Proposer values:
  # p1 value is "pizza" and p2 value is hamburger
  # As well as two delays values for p1 and p2 respectively

  # NOTE: These delay values were set given my local machine and may not work equally on other machines
  # Feel free to uncomment the @describetag :skip

  describe "Two asynchronous proposers trying two proposal values in potentially overlapping rounds" do
    # @describetag :skip

    test "2a - first proposer value pizza is accepted in both rounds (proposers don't overlap)",
         %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [10, 124]

      assert [
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid1, "paxos1@127.0.0.1"}],
                 value: ["pizza"],
                 declines: []
               ],
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid2, "paxos2@127.0.0.1"}],
                 value: ["pizza"],
                 declines: []
               ]
             ] = start_async_proposers(nodes, values, delays)

      # Since proposer 1 started well before proposer 2, we expect its proposer id to be less
      assert uid1 < uid2
    end

    test "2b - second proposer value hamburger is accepted in second round, and the first round is declined",
         %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [0, 40]

      # the second proposer is able to cut off the first proposer from phase 2, leaving p1 with an
      # unsuccesful consensus (note we have turned proposer retries off for this round)

      assert [
               error: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :sorry
               ],
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid, "paxos2@127.0.0.1"}],
                 value: ["hamburger"],
                 declines: []
               ]
             ] = start_async_proposers(nodes, values, delays, false)
    end

    test "2b - with proposer retries enable to remedy previous decline", %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [0, 40]

      assert [
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid1, "paxos1@127.0.0.1"}],
                 value: ["hamburger"],
                 declines: []
               ],
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid2, "paxos2@127.0.0.1"}],
                 value: ["hamburger"],
                 declines: []
               ]
             ] = start_async_proposers(nodes, values, delays, true)

      # proposer 1 retries after an initial fail, and hence its round id is after proposer 2
      # even though it initially started first (0)
      assert uid1 > uid2
    end

    test "2c - second proposer value hamburger is accepted in both rounds (proposers don't overlap)",
         %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [133, 5]

      assert [
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid1, "paxos1@127.0.0.1"}],
                 value: ["hamburger"],
                 declines: []
               ],
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid2, "paxos2@127.0.0.1"}],
                 value: ["hamburger"],
                 declines: []
               ]
             ] = start_async_proposers(nodes, values, delays, false)

      # p1 since it sleeps for much greater time starts much later than p2 who is able to set the prepare and commit first
      assert uid1 > uid2
    end

    test "2d - first proposer value pizza is accepted and the second proposer round is declined",
         %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [24, 11]

      # Since the start times are so close, p1 is able to cut off p2 with a promise right after p1's.
      # Allowing p1 to have its value accepted

      assert [
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{_uid, "paxos1@127.0.0.1"}],
                 value: ["pizza"],
                 declines: []
               ],
               error: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :sorry
               ]
             ] = start_async_proposers(nodes, values, delays, false)
    end

    test "2d - with proposer retries enabled to remedy previous decline", %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [24, 11]

      assert [
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid1, "paxos1@127.0.0.1"}],
                 value: ["pizza"],
                 declines: []
               ],
               ok: [
                 nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
                 status: :accepted,
                 round: [{uid2, "paxos2@127.0.0.1"}],
                 value: ["pizza"],
                 declines: []
               ]
             ] = start_async_proposers(nodes, values, delays, true)

      # the second proposer initially is cut off, but since retries are enabled now, it is able to
      # grab p1's value.  Hence its proposal id value is higher than p1's even though p2 started earlier
      assert uid2 > uid1
    end
  end

  def setup_nodes(size) when is_integer(size) do
    :ok = LocalCluster.start()
    LocalCluster.start_nodes("paxos", size)
  end
end
