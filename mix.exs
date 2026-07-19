defmodule TelemetryAttr.MixProject do
  use Mix.Project

  @version "1.0.0"
  @scm_url "https://github.com/supranode/telemetry_attr"

  def project do
    [
      app: :telemetry_attr,
      description: description(),
      version: @version,
      elixir: "~> 1.17",
      deps: deps(),
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [docs: :docs]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},

      # Docs dependencies
      {:ex_doc, "~> 0.40.3", only: :docs}
    ]
  end

  defp description do
    """
    Declarative telemetry for Elixir with @telemetry annotations.
    Add events to your functions without the boilerplate.
    """
  end

  defp package do
    [
      maintainers: ["Fernando Tapia Rico"],
      licenses: ["MIT"],
      links: %{"GitHub" => @scm_url},
      files: ~w(mix.exs README.md lib)
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "TelemetryAttr",
      source_url: @scm_url
    ]
  end
end
