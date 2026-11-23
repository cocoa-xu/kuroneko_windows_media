defmodule Kuroneko.WindowsMedia.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/cocoa-xu/kuroneko_windows_media"

  def project do
    [
      app: :kuroneko_windows_media,
      version: @version,
      elixir: "~> 1.15",
      description: description(),
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]]
    ]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.build": :docs, dialyzer: :test, credo: :test]]
  end

  defp description do
    "Windows installer USB drives from their ISOs, for Kuroneko's virtual disk: " <>
      "a maker that lays the ISO out on FAT32 and splits a WIM too large for it."
  end

  defp package do
    [
      licenses: ["GPL-3.0-or-later"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE", ".formatter.exs"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:credo, "~> 1.7", only: :test, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end
end
