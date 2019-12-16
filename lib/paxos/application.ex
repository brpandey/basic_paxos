defmodule Paxos.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    # We use libcluster so we don't have to connect the nodes explicitly
    topologies = [
      chat: [
        strategy: Cluster.Strategy.Gossip
      ]
    ]

    children = [
      {Cluster.Supervisor, [topologies, [name: Paxos.ClusterSupervisor]]},
      Paxos.Proposer,
      Paxos.Acceptor,
      Paxos.Leader,
      {Task.Supervisor, name: Paxos.TaskSupervisor}
    ]

    opts = [
      strategy: :one_for_one
    ]

    Supervisor.start_link(children, opts)
  end
end
