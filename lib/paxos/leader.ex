defmodule Paxos.Leader do
  @moduledoc """
  Leader handles leader election on startup and upon node down
  and also implements distinguished proposer

  Multiple simultaneous proposers is more complex and may create a live lock situation
  A single leader or distinguished proposer solves this
  """

  require Logger
  use GenServer
  import Paxos.Helper

  alias Paxos.Proposer

  @timeout 10_000
  @leader_choose_delay 2_000

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

  def start(server \\ __MODULE__, val) do
    try do
      GenServer.call(server, {:start, val}, @timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.debug("Leader Round Exiting (timeout)")
    end
  end

  def get_leader(server \\ __MODULE__) do
    GenServer.call(server, :get_leader)
  end

  ##########################
  # GenServer callbacks

  def init(_) do
    Process.flag(:trap_exit, true)

    :ok = :net_kernel.monitor_nodes(true, [])

    # Wait for all the nodes to connect, then find leader with highest server id
    Process.send_after(self(), :resync_empty_leader, @leader_choose_delay * 2)

    {:ok, ""}
  end

  #  def handle_continue(:choose_leader, :ok) do
  #    
  #    {:noreply, find_leader(@leader_choose_delay)}
  #  end

  def handle_call(:get_leader, _from, leader), do: {:reply, leader, leader}

  def handle_call({:start, val}, _from, leader) do
    leader =
      case leader do
        "" -> find_leader(@leader_choose_delay)
        _ -> leader
      end

    Logger.debug("Leader is #{inspect(leader)} on node #{inspect(node())}")

    data = Proposer.start({Proposer, leader}, val)
    {:reply, data, leader}
  end

  # If the node that goes down is the leader node, then find a new leader
  def handle_info({:nodedown, node}, node) do
    {:noreply, find_leader(@leader_choose_delay)}
  end

  def handle_info({:nodedown, _node}, leader) do
    {:noreply, leader}
  end

  def handle_info({:nodeup, _node}, leader) do
    {:noreply, leader}
  end

  # If we have an empty leader, recheck for a new leader
  def handle_info(:resync_empty_leader, "") do
    Logger.debug("Re-syncing leader status to replace empty leader")
    {:noreply, find_leader()}
  end

  def handle_info(:resync_empty_leader, leader), do: {:noreply, leader}

  defp find_leader(delay \\ 0) when is_integer(delay) do
    Process.sleep(delay)

    # Choose leader proposer server based on which propser has the highest server id
    # Hashing the server node name provides some variability to "highest" versus the literal node name

    # Note: Apparently there is some research which suggests using the lowest server id as leader as more optimal..
    # Ask self and peers for everyone's proposer id and choose the highest

    # Each leader on each node keeps track of the highest server id
    {list, _} = GenServer.multi_call(node_list(), Proposer, :get_id, 15_000)

    # {_node, _value}
    id = {"", ""}

    {leader_node, _} =
      res =
      Enum.reduce(list, id, fn
        {node, val}, {n_acc, v_acc} ->
          cond do
            val > v_acc -> {node, val}
            true -> {n_acc, v_acc}
          end
      end)

    case leader_node do
      # If we have empty leader node, look again
      "" -> Process.send_after(self(), :resync_empty_leader, @leader_choose_delay)
      _ -> :ok
    end

    Logger.debug("highest server id is #{inspect(res)}")

    leader_node
  end
end
