defmodule Exmaster.MixProject do
  use Mix.Project

  def project do
    [
      app: :exmaster,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [],
      releases: [exmaster: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Exmaster.Application, []}]
  end
end
