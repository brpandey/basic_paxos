# Basic Paxos ('single decree')

[Paxos](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf) is an algorithm to gain consensus in a distributed system.


The three roles are performed by "three classes of agents": proposers, acceptors, and learners.
The learner agent has been omitted for the sake of simplicity, but a leader agent has been added.

The coordinated actions of proposers and acceptors results in 2-phases to achieve consensus: 

Phase 1) Prepare-Promise 
![Prepare-Promise](/priv/images/adrian-colyer-paxos-prepare.jpg)

Phase 2) Commit(Accept)-Accepted
![Commit-Accepted](/priv/images/adrian-colyer-paxos-accept.jpg)

The basic safety requirements for consensus as described in [Paxos Made Simple](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf) by Leslie Lamport 
1) Only a value that has been proposed may be chosen
2) Only a single value is chosen, and
3) A process never learns that a value has been chosen unless it actually has been

Paxos is similiar to 2PC yet it doesn't need responses from all the nodes just a majority and
uses monotonic ordering of proposals to be able to block older proposals that have not completed

Note: Not fault tolerant yet, as the ids, highest promises or accepted values to disk are not persisted.

To play with this using iex start a few terminal windows and run these commands
```elixir
$ iex --name paxos1@127.0.0.1 -S mix
$ iex --name paxos2@127.0.0.1 -S mix
$ iex --name paxos3@127.0.0.1 -S mix

# Then in one of the windows type
$ iex(paxos1@127.0.0.1)2> Leader.start("pizza2")

# And you may see something like this
{:ok,
 [
   nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1", :"paxos3@127.0.0.1"],
   status: :accepted,
   round: [{1576471057770255244, "paxos2@127.0.0.1"}],
   value: ["pizza2"],
   declines: []
 ]}
```

Lastly, to run tests, ensure the Erlang port mapper daemon is running

```elixir 
$ epmd -daemon 
```

These were good resources helpful to understanding Paxos

1) [Paxos made simple - the morning paper](https://blog.acolyer.org/2015/03/04/paxos-made-simple/)
2) [Understanding Paxos - CS Rutgers](https://www.cs.rutgers.edu/~pxk/417/notes/paxos.html)
3) [L9 Paxos Simplified](https://www.youtube.com/watch?v=SRsK-ZXTeZ0)
4) [Consensus algorithms, Paxos and Raft](https://www.youtube.com/watch?v=fcFqFfsAlSQ)
5) [Paxos lecture - Raft User Study](https://www.youtube.com/watch?v=JEpsBg0AO6o)
(Note on 5 - The algorithmic details (abort if receive a single promise decline, and using >= vs == on phase 2 proposal id checks) are 
different from other resources, however the error cases were well described)

Below are some unit tests

```elixir

    test "single proposer, majority of acceptors crash and then later self-heal", %{nodes: nodes} do
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
                nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                        :"paxos3@127.0.0.1"],
                status: :accepted,
                round: [{_uid, "paxos2@127.0.0.1"}],
                value: ["pizza2"],
                declines: []
              ]}
      = Leader.start("pizza2")
    end
```

```elixir

  # Illustrates the algorithm under dueling proposers who are able to potentially 
  # block older proposals from a commit/accept

  # By tweaking the start times of the proposers we can create these conditions
  # Below we are using 3 nodes (which is the minimum quorum) to Proposer values:
  # p1 value is "pizza" and p2 value is hamburger
  # As well as two delays values for p1 and p2 respectively

  # NOTE: These delay values were set given my local machine and may not work equally on other machines
  # Feel free to uncomment the @describetag :skip

  describe "Two asynchronous proposers trying two proposal values in potentially overlapping rounds" do
    #@describetag :skip

    test "2a - first proposer value pizza is accepted in both rounds", %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [10, 124]

      assert [
        ok: [
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
          status: :accepted,
          round: [{uid1, "paxos1@127.0.0.1"}],
          value: ["pizza"],
          declines: []
        ],
        ok: [
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
          status: :accepted,
          round: [{uid2, "paxos2@127.0.0.1"}],
          value: ["pizza"],
          declines: []
        ]
      ] = start_async_proposers(nodes, values, delays)

      # Since proposer 1 started well before proposer 2, we expect its proposer id to be less
      assert uid1 < uid2
    end

    test "2b - second proposer value hamburger is accepted, first round is declined", %{nodes: nodes} do
      values = ["pizza", "hamburger"]
      delays = [0, 40]

      # the second proposer is able to cut off the first proposer from phase 2, leaving p1 with an
      # unsuccesful consensus (note we have turned proposer retries off for this round)

      assert [
        error: [
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
          status: :sorry
        ],
        ok: [
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
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
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
          status: :accepted,
          round: [{uid1, "paxos1@127.0.0.1"}],
          value: ["hamburger"],
          declines: []
        ],
        ok: [
          nodes: [:"paxos1@127.0.0.1", :"paxos2@127.0.0.1",
                  :"paxos3@127.0.0.1"],
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

```


Thanks! 
Bibek
