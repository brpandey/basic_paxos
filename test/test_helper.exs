ExUnit.start()

defmodule Paxos.TestHelper do
  require Logger

  def start_async_proposers(nodes, values, delays, retry \\ true)
      when is_list(nodes) and is_list(values) and is_list(delays) do
    # Use Task Supervisor for async behaviour
    Logger.debug("Start async proposers, nodes: #{inspect(nodes)}, values: #{inspect(values)}")

    nodes_size = Enum.count(nodes)
    size = Enum.count(values) - 1

    # Given the potential proposal values we want to choose, allocate a certain node for each proposed value
    # wrapping around the nodes set if needed

    tasks =
      for i <- 0..size do
        node_index = Integer.mod(i, nodes_size)
        node = Enum.at(nodes, node_index)
        proposal_value = Enum.at(values, i)
        delay = Enum.at(delays, i)

        # We can run the proposers in parallel this way
        Task.Supervisor.async({Paxos.TaskSupervisor, node}, Paxos.Proposer, :start_delay, [
          proposal_value,
          delay,
          retry
        ])
      end

    # And then conversely yield to multiple tasks
    tasks_with_results = Task.yield_many(tasks, 5000)

    data = Enum.map(tasks_with_results, fn {_task, {:ok, val}} -> val end)

    Logger.debug("Tasks with results #{inspect(data)}")

    data
  end
end
