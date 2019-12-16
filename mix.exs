defmodule Paxos.MixProject do
  use Mix.Project

  def project do
    [
      app: :paxos,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Paxos.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:local_cluster, "~> 1.0", only: [:dev, :test]},
      {:schism, "~> 1.0", only: [:dev, :test]},
      {:retry, "~> 0.9.0", override: true},
      {:libcluster, "~> 3.1"},
      {:hashids, "~> 2.0"}
    ]
  end
end
